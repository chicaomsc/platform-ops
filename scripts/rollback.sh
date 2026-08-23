#!/usr/bin/env bash
#
# scripts/rollback.sh — reverte o ambiente para uma versão anterior conhecida-
# boa (ADR-003). É a mesma mecânica de convergência do deploy.sh, aplicada em
# sentido inverso — nenhuma automação separada de "desfazer".
#
# Sprint 1.1 (ver docs/versioning.md): rollback é sempre por TAG + DIGEST em
# conjunto quando o digest existe, nunca só por tag quando ele existe.
# Semanticamente, um operador pensa "reverter para 1.2.0"; tecnicamente, o
# script reverte para um par tag+digest explícito (ou o baseline capturado
# automaticamente, que já contém ambos) — nunca "a tag que hoje se chama
# 1.2.0" sem confirmar que o digest bate com o que foi de fato registrado
# como bom anteriormente, QUANDO um digest está disponível para comparar.
#
# Sprint 2A.3 — dois modos temporários, distintos (ver docs/versioning.md e
# docs/release-management.md "Política de depreciação"):
#   - release.yml (contrato novo): digest é SEMPRE obrigatório. A
#     integridade por digest não é enfraquecida por esta sprint.
#   - versions.env (contrato legado, só apps na allowlist de migração —
#     hoje só vantry): nunca existiu digest verificável (RepoDigests
#     confirmado ausente na VPS real — Sprint 2A). Exigir digest aqui seria
#     impedir rollback de funcionar exatamente onde ele é mais necessário.
#     Tag continua sempre obrigatória; digest ausente gera aviso, não erro.
# Este script detecta o modo (via load_release_state/CONTRACT_MODE) e ajusta
# a validação de acordo — não há flag nova para isso, o comportamento já
# correto de "baseline sem digest gera aviso" (existente desde a Sprint 1.1
# para o caminho de leitura do state file) passou a valer também para
# overrides explícitos passados via flag, que é como deploy.sh invoca o
# rollback automático.
#
# Pode ser invocado de duas formas:
#
#   1) Automático, a partir de deploy.sh, logo após uma falha de healthcheck,
#      já com tag+digest explícitos (o baseline capturado antes do deploy
#      que falhou — digest vazio em modo legado, e agora corretamente aceito):
#        scripts/rollback.sh --app vantry --env production --auto \
#          --to-backend-tag <tag> --to-backend-digest <sha256:... ou vazio> \
#          --to-frontend-tag <tag> --to-frontend-digest <sha256:... ou vazio> \
#          --to-caddy-tag <tag> --to-caddy-digest <sha256:... ou vazio>
#
#   2) Manual, por um operador, a qualquer momento:
#        scripts/rollback.sh --app vantry --env production
#      Sem as flags --to-*, lê o último snapshot confiável registrado em
#      rollback_state_file (tag+digest da versão em execução imediatamente
#      antes do deploy mais recente) — este é o mecanismo equivalente a um
#      conceitual "--use-last-known-good": já é o comportamento padrão sem
#      nenhuma flag adicional, reaproveitando o baseline existente em vez de
#      introduzir uma nova interface. Para reverter a uma versão mais antiga
#      que essa, as flags --to-*-tag (sempre) e --to-*-digest (obrigatórias
#      em modo release; opcionais, com aviso, em modo legado) — o digest
#      normalmente vem do histórico de commits de release.yml (`git show
#      <commit>:apps/<app>/<env>/release.yml`). --to-release é apenas um
#      rótulo para log/clareza e exige as flags de tag junto — o script não
#      faz lookup automático de digest histórico nesta sprint.
#
# Em ambos os casos, ao final, executa scripts/healthcheck.sh novamente para
# confirmar que a versão revertida está de fato saudável — rollback não é
# considerado bem-sucedido apenas por "o comando não retornou erro".
#
# Uso:
#   scripts/rollback.sh --app <nome> --env <ambiente> [--auto] [--to-release <semver>] \
#       [--to-backend-tag <tag> --to-backend-digest <sha256:...> \
#        --to-frontend-tag <tag> --to-frontend-digest <sha256:...> \
#        --to-caddy-tag <tag> --to-caddy-digest <sha256:...>]
#
# Códigos de saída:
#   0  - rollback executado e confirmado saudável
#   10 - uso inválido
#   11 - erro de configuração declarativa ou formato inválido
#   12 - erro de conectividade SSH
#   13 - nenhum baseline disponível (state file ausente/vazio) e nenhuma
#        versão-alvo explícita foi passada
#   20 - digest pós-pull da versão de rollback não bateu com o declarado —
#        abortado ANTES de subir o container
#   21 - rollback aplicado, mas o healthcheck da versão revertida também falhou
#        (situação crítica — intervenção manual imediata necessária)

set -euo pipefail

# shellcheck disable=SC2034 # usado indiretamente por log()/warn()/die() em lib/common.sh
SCRIPT_NAME="rollback.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: $0 --app <nome> --env <ambiente> [--auto] [--to-release <semver>] \\
       [--to-backend-tag <tag> --to-backend-digest <sha256:...> \\
        --to-frontend-tag <tag> --to-frontend-digest <sha256:...> \\
        --to-caddy-tag <tag> --to-caddy-digest <sha256:...>]

Exemplos:
  # Rollback manual, usando o último baseline conhecido:
  $0 --app vantry --env production

  # Rollback manual para uma versão específica do histórico (release.yml):
  $0 --app vantry --env production --to-release 1.2.0 \\
     --to-backend-tag 1.2.0  --to-backend-digest sha256:aaa... \\
     --to-frontend-tag 1.2.0 --to-frontend-digest sha256:bbb... \\
     --to-caddy-tag 1.2.0    --to-caddy-digest sha256:ccc...

  # Rollback manual para um SHA específico do histórico, contrato legado
  # (versions.env — sem digest, aceito com aviso):
  $0 --app vantry --env production \\
     --to-backend-tag <sha>  --to-backend-digest "" \\
     --to-frontend-tag <sha> --to-frontend-digest "" \\
     --to-caddy-tag <sha>    --to-caddy-digest ""
EOF
}

APP=""
ENVIRONMENT=""
AUTO_MODE=0
TO_RELEASE_LABEL=""
TO_BACKEND_TAG=""; TO_BACKEND_DIGEST=""
TO_FRONTEND_TAG=""; TO_FRONTEND_DIGEST=""
TO_CADDY_TAG=""; TO_CADDY_DIGEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --auto) AUTO_MODE=1; shift ;;
    --to-release) TO_RELEASE_LABEL="$2"; shift 2 ;;
    --to-backend-tag) TO_BACKEND_TAG="$2"; shift 2 ;;
    --to-backend-digest) TO_BACKEND_DIGEST="$2"; shift 2 ;;
    --to-frontend-tag) TO_FRONTEND_TAG="$2"; shift 2 ;;
    --to-frontend-digest) TO_FRONTEND_DIGEST="$2"; shift 2 ;;
    --to-caddy-tag) TO_CADDY_TAG="$2"; shift 2 ;;
    --to-caddy-digest) TO_CADDY_DIGEST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "argumento desconhecido: $1"; usage; exit 10 ;;
  esac
done

[[ -n "$APP" ]] || { usage; die "--app é obrigatório" 10; }
[[ -n "$ENVIRONMENT" ]] || { usage; die "--env é obrigatório" 10; }

require_common_cmds
cd "$REPO_ROOT"

load_release_state "$APP" "$ENVIRONMENT"
SERVER_NAME="$(yq_get "$METADATA_FILE" '.server')"
load_server "$SERVER_NAME"

WORKDIR="$(yq_get "$METADATA_FILE" '.deploy_target.working_directory')"
COMPOSE_FILE="$(yq_get "$METADATA_FILE" '.deploy_target.compose_file')"
SECRETS_ENV_FILE="$(yq_get "$METADATA_FILE" '.deploy_target.secrets_env_file')"
ROLLBACK_STATE_FILE="$(yq_get "$METADATA_FILE" '.deploy_target.rollback_state_file')"
SERVICES="$(yq eval '.deploy_target.managed_services[]' "$METADATA_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

MODE_LABEL="manual"
[[ "$AUTO_MODE" -eq 1 ]] && MODE_LABEL="automático"
RELEASE_SUFFIX=""
[[ -n "$TO_RELEASE_LABEL" ]] && RELEASE_SUFFIX=" (rótulo: release ${TO_RELEASE_LABEL})"
log "Rollback (${MODE_LABEL}): app=${APP} env=${ENVIRONMENT} servidor=${SERVER_NAME} (${SSH_HOST})${RELEASE_SUFFIX}"

if ! ssh_exec "true" >/dev/null 2>&1; then
  die "não foi possível conectar via SSH em ${SSH_USER}@${SSH_HOST}:${SSH_PORT}" 12
fi

# --- Determina tag+digest alvo do rollback (sempre em par, nunca só tag) ---

ANY_OVERRIDE=0
for v in "$TO_BACKEND_TAG" "$TO_BACKEND_DIGEST" "$TO_FRONTEND_TAG" "$TO_FRONTEND_DIGEST" "$TO_CADDY_TAG" "$TO_CADDY_DIGEST"; do
  [[ -n "$v" ]] && ANY_OVERRIDE=1
done

if [[ "$ANY_OVERRIDE" -eq 1 ]]; then
  # Tag é sempre obrigatória nos três componentes, em qualquer contrato.
  if [[ -z "$TO_BACKEND_TAG" || -z "$TO_FRONTEND_TAG" || -z "$TO_CADDY_TAG" ]]; then
    die "as três flags --to-*-tag devem ser passadas juntas" 10
  fi
  # Digest: obrigatório no contrato novo (release.yml) — a integridade por
  # digest não é enfraquecida. No contrato legado (versions.env, allowlist
  # de migração), digest nunca existiu (ver ADR-007/docs/versioning.md) —
  # exigi-lo aqui é exatamente o Bug 2 da Sprint 2A.3: deploy.sh, no
  # rollback automático, sempre passa as seis flags, e em modo legado os
  # três *_DIGEST vêm vazios (nenhum RepoDigest jamais existiu) — isso é
  # esperado, não um erro de uso.
  if [[ "$CONTRACT_MODE" == "release" ]]; then
    if [[ -z "$TO_BACKEND_DIGEST" || -z "$TO_FRONTEND_DIGEST" || -z "$TO_CADDY_DIGEST" ]]; then
      die "as seis flags --to-*-tag/--to-*-digest devem ser passadas juntas em modo release (rollback exige tag E digest para cada componente — ver docs/versioning.md)" 10
    fi
  elif [[ -z "$TO_BACKEND_DIGEST" || -z "$TO_FRONTEND_DIGEST" || -z "$TO_CADDY_DIGEST" ]]; then
    warn "modo legado: rollback sem digest declarado para um ou mais componentes — prosseguindo sem verificação de digest para esses componentes (nunca existiu digest verificável neste contrato)."
  fi
  log "Versões-alvo fornecidas explicitamente: backend=${TO_BACKEND_TAG}@${TO_BACKEND_DIGEST:-<sem digest>} frontend=${TO_FRONTEND_TAG}@${TO_FRONTEND_DIGEST:-<sem digest>} caddy=${TO_CADDY_TAG}@${TO_CADDY_DIGEST:-<sem digest>}"
else
  [[ -z "$TO_RELEASE_LABEL" ]] || die "--to-release foi passado sem as seis flags --to-*-tag/--to-*-digest — este script não faz lookup automático de digest histórico nesta sprint (ver cabeçalho do arquivo)" 10
  log "Nenhuma versão-alvo explícita — lendo baseline de ${ROLLBACK_STATE_FILE} na VPS..."
  STATE_CONTENT="$(remote_read_rollback_state "$ROLLBACK_STATE_FILE")"
  [[ -n "$STATE_CONTENT" ]] || die "nenhum baseline encontrado em ${ROLLBACK_STATE_FILE} — passe as seis flags --to-*-tag/--to-*-digest explicitamente." 13
  # "|| true" em cada pipeline: um campo AUSENTE (não apenas vazio) num
  # arquivo de baseline corrompido/incompleto faria `grep` retornar 1 (sem
  # match); sob `set -euo pipefail`, isso mataria o script aqui, ANTES da
  # checagem explícita de "baseline incompleto" logo abaixo (die, exit 13) —
  # bug real encontrado nesta sprint via teste de baseline incompleto.
  # "|| true" garante que um campo ausente vire string vazia (tratada pela
  # checagem explícita), nunca uma saída abrupta sem mensagem clara.
  TO_BACKEND_TAG="$(printf '%s\n' "$STATE_CONTENT" | grep '^BACKEND_TAG=' | cut -d= -f2- || true)"
  TO_BACKEND_DIGEST="$(printf '%s\n' "$STATE_CONTENT" | grep '^BACKEND_DIGEST=' | cut -d= -f2- || true)"
  TO_FRONTEND_TAG="$(printf '%s\n' "$STATE_CONTENT" | grep '^FRONTEND_TAG=' | cut -d= -f2- || true)"
  TO_FRONTEND_DIGEST="$(printf '%s\n' "$STATE_CONTENT" | grep '^FRONTEND_DIGEST=' | cut -d= -f2- || true)"
  TO_CADDY_TAG="$(printf '%s\n' "$STATE_CONTENT" | grep '^CADDY_TAG=' | cut -d= -f2- || true)"
  TO_CADDY_DIGEST="$(printf '%s\n' "$STATE_CONTENT" | grep '^CADDY_DIGEST=' | cut -d= -f2- || true)"
  [[ -n "$TO_BACKEND_TAG" && -n "$TO_FRONTEND_TAG" && -n "$TO_CADDY_TAG" ]] || die "baseline em ${ROLLBACK_STATE_FILE} está incompleto" 13
  if [[ -z "$TO_BACKEND_DIGEST" || -z "$TO_FRONTEND_DIGEST" || -z "$TO_CADDY_DIGEST" ]]; then
    warn "baseline em ${ROLLBACK_STATE_FILE} não tem digest para um ou mais componentes (RepoDigests indisponível no momento da captura) — rollback prosseguirá sem verificação de digest para esses componentes."
  fi
  log "Baseline lido: backend=${TO_BACKEND_TAG}@${TO_BACKEND_DIGEST:-<sem digest>} frontend=${TO_FRONTEND_TAG}@${TO_FRONTEND_DIGEST:-<sem digest>} caddy=${TO_CADDY_TAG}@${TO_CADDY_DIGEST:-<sem digest>}"
fi

for v in "$TO_BACKEND_TAG" "$TO_FRONTEND_TAG" "$TO_CADDY_TAG"; do
  _deny_mutable_tag "$v" "versão-alvo de rollback"
done

# --- Aplica a versão-alvo: pull, verifica digest, depois sobe ---

log "Revertendo para: backend=${TO_BACKEND_TAG} frontend=${TO_FRONTEND_TAG} caddy=${TO_CADDY_TAG}"
if ! remote_pull_versions "$WORKDIR" "$COMPOSE_FILE" "$SECRETS_ENV_FILE" "$SERVICES" \
      "$TO_BACKEND_TAG" "$TO_FRONTEND_TAG" "$TO_CADDY_TAG" \
      "" "" ""; then
  die "docker compose pull falhou ao buscar a versão de rollback — nenhum container foi alterado" 20
fi
log "docker compose pull (rollback) concluído."

TO_BACKEND_DIGEST_REF=""; TO_FRONTEND_DIGEST_REF=""; TO_CADDY_DIGEST_REF=""

for spec in \
  "backend:${BACKEND_IMAGE}:${TO_BACKEND_TAG}:${TO_BACKEND_DIGEST}" \
  "frontend:${FRONTEND_IMAGE}:${TO_FRONTEND_TAG}:${TO_FRONTEND_DIGEST}" \
  "caddy:${CADDY_IMAGE}:${TO_CADDY_TAG}:${TO_CADDY_DIGEST}"; do
  comp="${spec%%:*}"
  rest="${spec#*:}"
  image="${rest%%:*}"
  rest2="${rest#*:}"
  tag="${rest2%%:*}"
  digest="${rest2#*:}"

  if [[ -z "$digest" ]]; then
    warn "sem digest declarado para ${comp} — verificação pulada para este componente (baseline capturado sem RepoDigests)."
    continue
  fi

  result="$(remote_verify_digest "${image}:${tag}" "$digest")"
  case "$result" in
    MATCH)
      log "Digest confirmado para ${comp} (${image}:${tag} = ${digest})"
      if [[ "$comp" == "backend" ]]; then TO_BACKEND_DIGEST_REF="${image}@${digest}"
      elif [[ "$comp" == "frontend" ]]; then TO_FRONTEND_DIGEST_REF="${image}@${digest}"
      else TO_CADDY_DIGEST_REF="${image}@${digest}"; fi
      ;;
    UNKNOWN)
      warn "Não foi possível confirmar o digest de ${comp} (${image}:${tag}) — prosseguindo sem verificação para este componente."
      ;;
    MISMATCH:*)
      die "INTEGRIDADE COMPROMETIDA: ${comp} de rollback (${image}:${tag}) foi baixado com digest ${result#MISMATCH:}, esperado ${digest}. Abortando ANTES de subir o container." 20
      ;;
  esac
done

if ! remote_up_versions "$WORKDIR" "$COMPOSE_FILE" "$SECRETS_ENV_FILE" "$SERVICES" \
      "$TO_BACKEND_TAG" "$TO_FRONTEND_TAG" "$TO_CADDY_TAG" \
      "$TO_BACKEND_DIGEST_REF" "$TO_FRONTEND_DIGEST_REF" "$TO_CADDY_DIGEST_REF"; then
  die "docker compose up -d falhou ao aplicar a versão de rollback — VPS pode estar em estado inconsistente" 20
fi
log "docker compose up -d (rollback) concluído."

# --- Confirma saúde da versão revertida ---

log "Confirmando saúde da versão revertida..."
if "${SCRIPT_DIR}/healthcheck.sh" --app "$APP" --env "$ENVIRONMENT"; then
  log "RESULT=ROLLBACK_SUCCESS — versão revertida confirmada saudável: backend=${TO_BACKEND_TAG} frontend=${TO_FRONTEND_TAG} caddy=${TO_CADDY_TAG}"
  if [[ "$AUTO_MODE" -eq 0 ]]; then
    warn "AÇÃO NECESSÁRIA: se esta versão deve se tornar o novo estado desejado oficial, abra um PR atualizando apps/${APP}/${ENVIRONMENT}/release.yml (ou versions.env, em modo legado) para backend=${TO_BACKEND_TAG} frontend=${TO_FRONTEND_TAG} caddy=${TO_CADDY_TAG} (ADR-001 — Git deve refletir a realidade)."
  fi
  exit 0
else
  die "RESULT=ROLLBACK_FAILED — a versão revertida (backend=${TO_BACKEND_TAG} frontend=${TO_FRONTEND_TAG} caddy=${TO_CADDY_TAG}) também falhou no healthcheck. Intervenção manual imediata necessária." 21
fi
