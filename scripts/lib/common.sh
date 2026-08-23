#!/usr/bin/env bash
# scripts/lib/common.sh
#
# Funções compartilhadas por deploy.sh, healthcheck.sh e rollback.sh.
# Este arquivo é sempre "source"ado, nunca executado diretamente — não define
# `set -euo pipefail` por conta própria; cada script principal já faz isso
# antes de dar source aqui.
#
# Nada neste arquivo lê, imprime ou transmite valores de segredo. Toda
# informação usada é lida de apps/<app>/<env>/metadata.yml, release.yml OU
# versions.env, e servers/<server>.yml — nenhum desses arquivos contém
# segredos (ADR-004).
#
# Contrato de versão (ver docs/versioning.md, docs/release-management.md,
# ADR-006, ADR-007): suporta dois formatos de estado desejado, mutuamente
# exclusivos por app/ambiente:
#   - release.yml (novo, schema platform-ops/v1 — preferido quando presente):
#     SemVer + sourceCommit + createdAt + imagem/tag/digest por componente.
#   - versions.env (LEGADO/DEPRECATED — ver docs/release-management.md
#     "Política de depreciação"): apenas SHA de commit por componente, sem
#     digest declarado. Permitido apenas para apps na allowlist de migração
#     (hoje: vantry) — qualquer app novo é bloqueado nesse contrato.

# --- Logging -----------------------------------------------------------

_log_prefix() { printf '%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; }

log()  { printf '[%s] [%s] %s\n' "$(_log_prefix)" "${SCRIPT_NAME:-platform-ops}" "$*"; }
warn() { printf '[%s] [%s] AVISO: %s\n' "$(_log_prefix)" "${SCRIPT_NAME:-platform-ops}" "$*" >&2; }
die()  { printf '[%s] [%s] ERRO: %s\n' "$(_log_prefix)" "${SCRIPT_NAME:-platform-ops}" "$*" >&2; exit "${2:-1}"; }

# --- Pré-requisitos ------------------------------------------------------

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "comando obrigatório não encontrado no PATH: ${cmd}" 11
}

require_common_cmds() {
  require_cmd yq
  require_cmd jq
  require_cmd ssh
  require_cmd timeout
}

# --- Validação de formato (ver docs/versioning.md) ------------------------

# validate_semver <valor> <origem_para_mensagem_de_erro>
# Aceita apenas MAJOR.MINOR.PATCH numérico (sem pré-release/build metadata
# nesta sprint — ver docs/release-management.md "Política de prerelease").
validate_semver() {
  local value="$1" origin="$2"
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "versão SemVer inválida em ${origin}: '${value}' (esperado MAJOR.MINOR.PATCH, ex.: 1.2.0)" 11
}

# validate_git_sha <valor> <origem_para_mensagem_de_erro>
# Exige SHA completo (40 hex) — nunca abreviado, para proveniência inequívoca.
validate_git_sha() {
  local value="$1" origin="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || \
    die "sourceCommit inválido em ${origin}: '${value}' (esperado SHA git completo, 40 caracteres hex)" 11
}

# validate_digest <valor> <origem_para_mensagem_de_erro>
validate_digest() {
  local value="$1" origin="$2"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] || \
    die "digest OCI inválido em ${origin}: '${value}' (esperado sha256:<64 hex>)" 11
}

# validate_iso8601 <valor> <origem_para_mensagem_de_erro>
validate_iso8601() {
  local value="$1" origin="$2"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || \
    die "createdAt inválido em ${origin}: '${value}' (esperado ISO8601, ex.: 2026-08-23T14:00:00Z)" 11
}

# _deny_mutable_tag <valor> <origem>
#
# Sprint 2A.1 — antes hardcoded (latest/main/stable); agora lê a lista de
# .registry.disallow_mutable_tags em METADATA_FILE (achado de auditoria: o
# campo já existia em metadata.yml mas nenhum código o consumia — "metadata
# falsa"). Se o campo não existir/vier vazio, cai no default histórico
# (latest/main/stable) — nunca menos restritivo que antes.
_deny_mutable_tag() {
  local value="$1" origin="$2"
  local denied_list
  denied_list="$(yq eval '.registry.disallow_mutable_tags[]' "${METADATA_FILE:-/dev/null}" 2>/dev/null || true)"
  [[ -n "$denied_list" ]] || denied_list=$'latest\nmain\nstable'

  local denied
  while IFS= read -r denied; do
    [[ -z "$denied" || "$denied" == "null" ]] && continue
    if [[ "$value" == "$denied" ]]; then
      die "tag móvel '${value}' não é permitida em ${origin} (declarada em registry.disallow_mutable_tags — ver ADR-001/ADR-003)" 11
    fi
  done <<< "$denied_list"
}

# --- Política de depreciação do contrato legado (ver docs/release-management.md) ---

# Apps autorizados a usar versions.env durante a migração. Nenhum app novo
# deve ser adicionado aqui — nasce direto em release.yml. Remover "vantry"
# desta lista (e o suporte legado no código) é o passo final da migração,
# feito em sprint própria depois da primeira release validada em produção.
_LEGACY_ALLOWED_APPS=(vantry)

_is_legacy_allowed() {
  local app="$1" allowed
  for allowed in "${_LEGACY_ALLOWED_APPS[@]}"; do
    [[ "$allowed" == "$app" ]] && return 0
  done
  return 1
}

# --- Imutabilidade de release (ver ADR-006, ADR-007) -----------------------

# validate_release_immutability <release_file> <version> <source_commit> \
#     <backend_digest> <frontend_digest> <caddy_digest>
#
# Verifica, usando o histórico de commits do próprio platform-ops (git log),
# que se a versão declarada já foi commitada anteriormente neste arquivo, ela
# sempre apontou para o mesmo sourceCommit e os mesmos digests. Uma release
# publicada é imutável — uma correção real incrementa a versão (ex.: 1.2.1),
# nunca reescreve 1.2.0. Roda inteiramente local (sem SSH) antes de qualquer
# conexão com a VPS. Se o arquivo nunca foi commitado (release nova) ou git
# não está disponível, não há nada a comparar — não é um erro.
validate_release_immutability() {
  local release_file="$1" version="$2" source_commit="$3"
  local backend_digest="$4" frontend_digest="$5" caddy_digest="$6"

  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "git indisponível ou fora de um repositório — verificação de imutabilidade histórica pulada"
    return 0
  fi

  local commits
  commits="$(git log --follow --format=%H -- "$release_file" 2>/dev/null || true)"
  [[ -n "$commits" ]] || return 0

  local commit hist_version hist_commit hist_backend hist_frontend hist_caddy hist_content
  for commit in $commits; do
    hist_content="$(git show "${commit}:${release_file}" 2>/dev/null || true)"
    [[ -n "$hist_content" ]] || continue

    hist_version="$(printf '%s' "$hist_content" | yq eval '.release.version' - 2>/dev/null || true)"
    [[ "$hist_version" == "$version" ]] || continue

    hist_commit="$(printf '%s' "$hist_content" | yq eval '.release.sourceCommit' - 2>/dev/null || true)"
    if [[ "$hist_commit" != "$source_commit" ]]; then
      die "IMUTABILIDADE VIOLADA: release ${version} já foi declarada no commit ${commit} de ${release_file} com sourceCommit=${hist_commit}; agora está sendo declarada com sourceCommit=${source_commit}. Uma release publicada nunca muda de origem — use a próxima versão (ex.: um PATCH) em vez de redeclarar ${version}." 11
    fi

    hist_backend="$(printf '%s' "$hist_content" | yq eval '.components.backend.digest' - 2>/dev/null || true)"
    hist_frontend="$(printf '%s' "$hist_content" | yq eval '.components.frontend.digest' - 2>/dev/null || true)"
    hist_caddy="$(printf '%s' "$hist_content" | yq eval '.components.caddy.digest' - 2>/dev/null || true)"
    if [[ "$hist_backend" != "$backend_digest" || "$hist_frontend" != "$frontend_digest" || "$hist_caddy" != "$caddy_digest" ]]; then
      die "IMUTABILIDADE VIOLADA: release ${version} já foi declarada no commit ${commit} de ${release_file} com digest(s) diferente(s) dos atuais. Uma release publicada é imutável — use a próxima versão em vez de redeclarar ${version}." 11
    fi
  done
}

# --- Leitura de estado declarativo ----------------------------------------

# yq_get <file> <expr> [--optional]
# Sai com erro (11) se o caminho não existir/for null, a menos que --optional
# seja passado, caso em que retorna string vazia.
yq_get() {
  local file="$1" expr="$2" optional="${3:-}"
  [[ -f "$file" ]] || die "arquivo declarativo não encontrado: ${file}" 11
  local value
  value="$(yq eval "$expr" "$file" 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    if [[ "$optional" == "--optional" ]]; then
      printf ''
      return 0
    fi
    die "campo obrigatório ausente em ${file}: ${expr}" 11
  fi
  printf '%s' "$value"
}

# load_release_state <app> <environment>
#
# Popula APP_DIR, METADATA_FILE e CONTRACT_MODE ("release" ou "legacy"), e
# exporta, para os três componentes, de forma UNIFORME independente do modo:
#   BACKEND_VERSION / FRONTEND_VERSION / CADDY_VERSION   (tag a usar no deploy)
#   BACKEND_DIGEST  / FRONTEND_DIGEST  / CADDY_DIGEST     (vazio em modo legado)
#   BACKEND_IMAGE   / FRONTEND_IMAGE   / CADDY_IMAGE      (caminho completo do registry)
# e, em modo "release": RELEASE_VERSION, SOURCE_COMMIT, RELEASE_CREATED_AT.
#
# Prefere release.yml (schema platform-ops/v1 — ver docs/release-management.md)
# quando presente; cai para versions.env (legado, permitido só para apps na
# allowlist de migração) caso contrário. Nunca os dois ao mesmo tempo — se
# ambos existirem, release.yml vence e um aviso é emitido.
load_release_state() {
  local app="$1" environment="$2"
  APP_DIR="apps/${app}/${environment}"
  METADATA_FILE="${APP_DIR}/metadata.yml"
  local release_file="${APP_DIR}/release.yml"
  local versions_file="${APP_DIR}/versions.env"

  [[ -d "$APP_DIR" ]] || die "ambiente declarativo não encontrado: ${APP_DIR}" 11
  [[ -f "$METADATA_FILE" ]] || die "metadata.yml ausente: ${METADATA_FILE}" 11

  RELEASE_VERSION=""
  SOURCE_COMMIT=""
  RELEASE_CREATED_AT=""
  BACKEND_DIGEST=""; FRONTEND_DIGEST=""; CADDY_DIGEST=""

  if [[ -f "$release_file" ]]; then
    CONTRACT_MODE="release"
    if [[ -f "$versions_file" ]]; then
      warn "release.yml e versions.env coexistem em ${APP_DIR} — release.yml tem prioridade; remova versions.env por PR quando confirmar que não é mais necessário (ver docs/release-management.md)"
    fi

    local api_version kind manifest_app manifest_env
    api_version="$(yq_get "$release_file" '.apiVersion')"
    kind="$(yq_get "$release_file" '.kind')"
    [[ "$api_version" == "platform-ops/v1" ]] || die "apiVersion não suportado em ${release_file}: '${api_version}' (esperado platform-ops/v1)" 11
    [[ "$kind" == "Release" ]] || die "kind inválido em ${release_file}: '${kind}' (esperado Release)" 11

    manifest_app="$(yq_get "$release_file" '.metadata.application')"
    manifest_env="$(yq_get "$release_file" '.metadata.environment')"
    [[ "$manifest_app" == "$app" ]] || die "metadata.application em ${release_file} ('${manifest_app}') não corresponde ao app solicitado ('${app}')" 11
    [[ "$manifest_env" == "$environment" ]] || die "metadata.environment em ${release_file} ('${manifest_env}') não corresponde ao ambiente solicitado ('${environment}')" 11

    RELEASE_VERSION="$(yq_get "$release_file" '.release.version')"
    SOURCE_COMMIT="$(yq_get "$release_file" '.release.sourceCommit')"
    RELEASE_CREATED_AT="$(yq_get "$release_file" '.release.createdAt')"
    validate_semver "$RELEASE_VERSION" "${release_file} (.release.version)"
    validate_git_sha "$SOURCE_COMMIT" "${release_file} (.release.sourceCommit)"
    validate_iso8601 "$RELEASE_CREATED_AT" "${release_file} (.release.createdAt)"

    BACKEND_IMAGE="$(yq_get "$release_file" '.components.backend.image')"
    BACKEND_VERSION="$(yq_get "$release_file" '.components.backend.tag')"
    BACKEND_DIGEST="$(yq_get "$release_file" '.components.backend.digest')"
    FRONTEND_IMAGE="$(yq_get "$release_file" '.components.frontend.image')"
    FRONTEND_VERSION="$(yq_get "$release_file" '.components.frontend.tag')"
    FRONTEND_DIGEST="$(yq_get "$release_file" '.components.frontend.digest')"
    CADDY_IMAGE="$(yq_get "$release_file" '.components.caddy.image')"
    CADDY_VERSION="$(yq_get "$release_file" '.components.caddy.tag')"
    CADDY_DIGEST="$(yq_get "$release_file" '.components.caddy.digest')"

    validate_semver "$BACKEND_VERSION" "${release_file} (.components.backend.tag)"
    validate_semver "$FRONTEND_VERSION" "${release_file} (.components.frontend.tag)"
    validate_semver "$CADDY_VERSION" "${release_file} (.components.caddy.tag)"
    validate_digest "$BACKEND_DIGEST" "${release_file} (.components.backend.digest)"
    validate_digest "$FRONTEND_DIGEST" "${release_file} (.components.frontend.digest)"
    validate_digest "$CADDY_DIGEST" "${release_file} (.components.caddy.digest)"

    validate_release_immutability "$release_file" "$RELEASE_VERSION" "$SOURCE_COMMIT" \
      "$BACKEND_DIGEST" "$FRONTEND_DIGEST" "$CADDY_DIGEST"

  elif [[ -f "$versions_file" ]]; then
    if ! _is_legacy_allowed "$app"; then
      die "app '${app}' está usando o contrato legado (versions.env), proibido para apps fora da allowlist de migração (ver docs/release-management.md — Política de Depreciação). Apps novos devem nascer diretamente com release.yml (ver templates/app/release.yml)." 11
    fi
    # shellcheck disable=SC2034 # usado pelos chamadores (deploy.sh/healthcheck.sh/rollback.sh)
    CONTRACT_MODE="legacy"
    warn "usando contrato legado e DEPRECATED (versions.env, baseado em SHA de commit, sem digest declarado) — permitido apenas durante a migração de '${app}'; ver docs/release-management.md"

    # shellcheck disable=SC1090,SC1091
    set -a
    source "$versions_file"
    set +a

    : "${BACKEND_VERSION:?BACKEND_VERSION não declarado em ${versions_file}}"
    : "${FRONTEND_VERSION:?FRONTEND_VERSION não declarado em ${versions_file}}"
    : "${CADDY_VERSION:?CADDY_VERSION não declarado em ${versions_file}}"

    # shellcheck disable=SC2034 # usadas pelos chamadores (deploy.sh/rollback.sh)
    BACKEND_IMAGE="$(yq_get "$METADATA_FILE" '.registry.images.backend')"
    # shellcheck disable=SC2034
    FRONTEND_IMAGE="$(yq_get "$METADATA_FILE" '.registry.images.frontend')"
    # shellcheck disable=SC2034
    CADDY_IMAGE="$(yq_get "$METADATA_FILE" '.registry.images.caddy')"
  else
    die "nem release.yml nem versions.env encontrados em ${APP_DIR}" 11
  fi

  _deny_mutable_tag "$BACKEND_VERSION" "${APP_DIR} (backend)"
  _deny_mutable_tag "$FRONTEND_VERSION" "${APP_DIR} (frontend)"
  _deny_mutable_tag "$CADDY_VERSION" "${APP_DIR} (caddy)"
}

# load_server <server_name>
# Popula SSH_HOST, SSH_PORT, SSH_USER a partir de servers/<server_name>.yml
load_server() {
  local server_name="$1"
  SERVER_FILE="servers/${server_name}.yml"
  [[ -f "$SERVER_FILE" ]] || die "servidor não encontrado: ${SERVER_FILE}" 11

  SSH_HOST="$(yq_get "$SERVER_FILE" '.public_ip')"
  SSH_PORT="$(yq_get "$SERVER_FILE" '.ssh.port')"
  SSH_USER="$(yq_get "$SERVER_FILE" '.ssh.user')"
}

# --- Execução remota -------------------------------------------------------

# Sprint 2A.1 — três conceitos de timeout, deliberadamente separados (ver
# achado de auditoria: SSH_TIMEOUT_SECONDS=30 no workflow matava a sessão do
# healthcheck antes do seu próprio orçamento de retry se esgotar):
#   SSH_CONNECT_TIMEOUT_SECONDS  - só o estabelecimento da conexão TCP/SSH
#                                   (mapeia para `-o ConnectTimeout`)
#   DEPLOY_COMMAND_TIMEOUT_SECONDS - teto para comandos rápidos via ssh_exec
#                                   (conectividade, pull, up, verificação de
#                                   digest, leitura/escrita de rollback state)
#   HEALTHCHECK_TIMEOUT_SECONDS  - teto para a sessão via ssh_exec_stdin, que
#                                   roda o loop de retry inteiro do healthcheck
#                                   remotamente (precisa ser maior que o pior
#                                   caso documentado de cold start — ver
#                                   metadata.yml de vantry/production)
# Nenhuma dessas variáveis controla, sozinha, "a duração do deploy inteiro" —
# esse acoplamento era exatamente o bug.

# ssh_exec <comando remoto>
# Executa via SSH com timeout, batch mode e verificação estrita de host key.
# known_hosts é sempre resolvido pelo ambiente que chama o script (workflow
# ou operador local) — nunca gerado por TOFU (trust-on-first-use) aqui.
ssh_exec() {
  local remote_cmd="$1"
  local connect_timeout="${SSH_CONNECT_TIMEOUT_SECONDS:-10}"
  local cmd_timeout="${DEPLOY_COMMAND_TIMEOUT_SECONDS:-600}"
  timeout "${cmd_timeout}" ssh \
    -p "${SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout="${connect_timeout}" \
    "${SSH_USER}@${SSH_HOST}" \
    -- "$remote_cmd"
}

# ssh_exec_stdin <script local>
# Envia um script local via stdin e o executa remotamente com `bash -s`.
# Usado para rodar loops de verificação (healthcheck) inteiramente no lado
# da VPS, evitando múltiplos round-trips de SSH. Usa HEALTHCHECK_TIMEOUT_SECONDS
# (não DEPLOY_COMMAND_TIMEOUT_SECONDS) — a sessão precisa sobreviver ao pior
# caso somado de todos os checks, cada um com seu próprio orçamento (ver
# healthcheck.sh).
ssh_exec_stdin() {
  local local_script="$1"; shift
  local connect_timeout="${SSH_CONNECT_TIMEOUT_SECONDS:-10}"
  local cmd_timeout="${HEALTHCHECK_TIMEOUT_SECONDS:-300}"
  timeout "${cmd_timeout}" ssh \
    -p "${SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout="${connect_timeout}" \
    "${SSH_USER}@${SSH_HOST}" \
    -- "bash -s -- $*" < "$local_script"
}

# --- Estado de rollback (não secreto) --------------------------------------

# remote_capture_running_state <compose_project>
# Consulta, via `docker inspect`, a TAG e o DIGEST da imagem realmente em
# execução para backend/frontend/caddy, e grava em stdout no formato
# KEY=VALUE (um por linha): BACKEND_TAG, BACKEND_DIGEST, FRONTEND_TAG,
# FRONTEND_DIGEST, CADDY_TAG, CADDY_DIGEST. O digest é capturado
# independentemente do modo (release/legado) — é informação que o próprio
# Docker relata sobre o que está de fato rodando, não uma declaração nossa;
# serve de base verificável para rollback mesmo em modo legado.
# Serviço sem container em execução resulta em valores vazios — o chamador
# decide se isso é aceitável (ex.: primeiro deploy).
remote_capture_running_state() {
  local project="$1"
  local remote_cmd
  remote_cmd=$(cat <<EOF
for svc in backend frontend caddy; do
  container="${project}-\${svc}-1"
  image="\$(docker inspect --format='{{.Config.Image}}' "\${container}" 2>/dev/null || true)"
  tag="\${image##*:}"
  [[ "\${tag}" == "\${image}" ]] && tag=""
  repo_digest="\$(docker inspect --format='{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "\${container}" 2>/dev/null || true)"
  digest="\${repo_digest##*@}"
  [[ "\${digest}" == "\${repo_digest}" ]] && digest=""
  if [[ "\${svc}" == "backend" ]]; then
    echo "BACKEND_TAG=\${tag}"
    echo "BACKEND_DIGEST=\${digest}"
  elif [[ "\${svc}" == "frontend" ]]; then
    echo "FRONTEND_TAG=\${tag}"
    echo "FRONTEND_DIGEST=\${digest}"
  else
    echo "CADDY_TAG=\${tag}"
    echo "CADDY_DIGEST=\${digest}"
  fi
done
EOF
  )
  ssh_exec "$remote_cmd"
}

# remote_verify_digest <image_ref_completo_com_tag> <digest_esperado>
# Imprime exatamente uma palavra em stdout:
#   MATCH          - digest da imagem já baixada bate com o esperado
#   MISMATCH:<sha> - diverge; <sha> é o digest realmente encontrado
#   UNKNOWN        - não foi possível determinar o digest (RepoDigests vazio)
# Nunca falha por si só (sempre imprime algo e retorna 0) — o chamador decide
# a política (abortar em MISMATCH, avisar em UNKNOWN).
remote_verify_digest() {
  local image_ref="$1" expected_digest="$2"
  local remote_cmd actual_full actual_digest
  remote_cmd="docker image inspect --format='{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' '${image_ref}' 2>/dev/null || true"
  actual_full="$(ssh_exec "$remote_cmd")"
  if [[ -z "$actual_full" || "$actual_full" != *"@"* ]]; then
    echo "UNKNOWN"
    return 0
  fi
  actual_digest="${actual_full##*@}"
  if [[ "$actual_digest" == "$expected_digest" ]]; then
    echo "MATCH"
  else
    echo "MISMATCH:${actual_digest}"
  fi
}

# remote_write_rollback_state <state_file_path> <backend_tag> <backend_digest> \
#     <frontend_tag> <frontend_digest> <caddy_tag> <caddy_digest>
# Escreve o snapshot de estado (não secreto) no path declarado em
# metadata.yml (rollback_state_file). Sobrescreve o anterior — este arquivo
# representa sempre "a última versão confirmada antes do deploy mais recente",
# nunca um histórico completo (o histórico completo é o log de commits do
# platform-ops — ver ADR-003). Digests vazios (modo legado sem RepoDigests
# disponível) são gravados como string vazia — o consumidor deve tratar isso
# como "identidade não verificável", não como erro.
#
# Sprint 2A.3 — escrita atômica: grava num arquivo temporário no MESMO
# diretório (garante que `mv` seja rename, não cópia entre filesystems —
# atômico no POSIX) e só então move para o path final. Um leitor concorrente
# (ex.: rollback.sh manual rodando ao mesmo tempo de um deploy) nunca vê um
# arquivo parcialmente escrito — ou vê o conteúdo antigo completo, ou o novo
# completo. `chmod 644`: legível por qualquer um (não é segredo — só
# tag/digest, nunca credencial), gravável apenas pelo dono (`deploy`).
remote_write_rollback_state() {
  local state_file="$1" backend_tag="$2" backend_digest="$3"
  local frontend_tag="$4" frontend_digest="$5" caddy_tag="$6" caddy_digest="$7"
  local dir tmp_file
  dir="$(dirname "$state_file")"
  tmp_file="${state_file}.tmp.$$"
  local remote_cmd
  remote_cmd="mkdir -p '${dir}' && printf 'BACKEND_TAG=%s\nBACKEND_DIGEST=%s\nFRONTEND_TAG=%s\nFRONTEND_DIGEST=%s\nCADDY_TAG=%s\nCADDY_DIGEST=%s\n' '${backend_tag}' '${backend_digest}' '${frontend_tag}' '${frontend_digest}' '${caddy_tag}' '${caddy_digest}' > '${tmp_file}' && chmod 644 '${tmp_file}' && mv -f '${tmp_file}' '${state_file}'"
  ssh_exec "$remote_cmd"
}

# remote_read_rollback_state <state_file_path>
# Imprime o conteúdo do snapshot (KEY=VALUE por linha), ou nada se ausente.
remote_read_rollback_state() {
  local state_file="$1"
  ssh_exec "[[ -f '${state_file}' ]] && cat '${state_file}' || true"
}

# --- Deploy remoto (pull + up), reutilizado por deploy.sh e rollback.sh ---
#
# Ambos aceitam, além da tag por componente, uma referência de digest
# opcional (<repo>@sha256:...) por componente — exportada como
# BACKEND_DIGEST_REF/FRONTEND_DIGEST_REF/CADDY_DIGEST_REF. Isso é aditivo:
# hoje nenhum docker-compose.prod.yml conhecido referencia essas variáveis
# (o pull/up real continua acontecendo por TAG), mas a infraestrutura já
# fica pronta para quando o compose file migrar para pinning por digest (ver
# ADR-007 "Deploy por digest" e docs/release-management.md). Passar string
# vazia é seguro — a variável é exportada vazia e simplesmente ignorada por
# um compose file que não a referencia.

# remote_pull_versions <workdir> <compose_file> <secrets_env_file> <services> \
#     <backend_tag> <frontend_tag> <caddy_tag> \
#     <backend_digest_ref> <frontend_digest_ref> <caddy_digest_ref>
remote_pull_versions() {
  local workdir="$1" compose_file="$2" secrets_env="$3" services="$4"
  local backend="$5" frontend="$6" caddy="$7"
  local backend_ref="${8:-}" frontend_ref="${9:-}" caddy_ref="${10:-}"
  local remote_cmd
  remote_cmd=$(cat <<EOF
set -euo pipefail
cd '${workdir}'
export BACKEND_VERSION='${backend}'
export FRONTEND_VERSION='${frontend}'
export CADDY_VERSION='${caddy}'
export BACKEND_DIGEST_REF='${backend_ref}'
export FRONTEND_DIGEST_REF='${frontend_ref}'
export CADDY_DIGEST_REF='${caddy_ref}'
docker compose -f '${compose_file}' --env-file '${secrets_env}' pull ${services}
EOF
  )
  ssh_exec "$remote_cmd"
}

# remote_up_versions <workdir> <compose_file> <secrets_env_file> <services> \
#     <backend_tag> <frontend_tag> <caddy_tag> \
#     <backend_digest_ref> <frontend_digest_ref> <caddy_digest_ref>
remote_up_versions() {
  local workdir="$1" compose_file="$2" secrets_env="$3" services="$4"
  local backend="$5" frontend="$6" caddy="$7"
  local backend_ref="${8:-}" frontend_ref="${9:-}" caddy_ref="${10:-}"
  local remote_cmd
  remote_cmd=$(cat <<EOF
set -euo pipefail
cd '${workdir}'
export BACKEND_VERSION='${backend}'
export FRONTEND_VERSION='${frontend}'
export CADDY_VERSION='${caddy}'
export BACKEND_DIGEST_REF='${backend_ref}'
export FRONTEND_DIGEST_REF='${frontend_ref}'
export CADDY_DIGEST_REF='${caddy_ref}'
docker compose -f '${compose_file}' --env-file '${secrets_env}' up -d ${services}
EOF
  )
  ssh_exec "$remote_cmd"
}
