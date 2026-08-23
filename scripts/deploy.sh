#!/usr/bin/env bash
#
# scripts/deploy.sh — converge o estado real da VPS para o estado desejado
# declarado em apps/<app>/<env>/ (ADR-001, ADR-002).
#
# Suporta dois contratos de versão (ver docs/versioning.md, docs/release-management.md):
#   - release.yml (schema platform-ops/v1, preferido quando presente): SemVer
#     + sourceCommit + createdAt + imagem/tag/digest por componente. Antes de
#     qualquer conexão SSH, a imutabilidade da release é verificada contra o
#     histórico de commits do próprio platform-ops (load_release_state →
#     validate_release_immutability). Após o pull, o digest de cada imagem
#     baixada é verificado contra o declarado ANTES de subir o container —
#     nenhuma release é implantada sem prova de identidade do artefato.
#   - versions.env (LEGADO/DEPRECATED — permitido só para apps na allowlist
#     de migração, ver lib/common.sh): SHA de commit por componente, sem
#     digest declarado. Continua funcionando sem alteração para Vantry.
#
# Ao subir os containers (up -d), exporta também BACKEND_DIGEST_REF/
# FRONTEND_DIGEST_REF/CADDY_DIGEST_REF (formato <imagem>@sha256:...) — aditivo,
# preparando o terreno para quando o docker-compose.prod.yml migrar para
# pinning por digest (ver ADR-007 "Deploy por digest"); hoje nenhum compose
# file conhecido referencia essas variáveis, então isso não muda o
# comportamento real do deploy, que continua por tag.
#
# Fluxo:
#   1. identifica aplicação/ambiente e o contrato de versão em uso
#   2. lê versões/release declaradas
#   3. valida configuração (metadata.yml, servers/<server>.yml, formatos)
#   4. conecta no servidor-alvo via SSH
#   5. captura e registra a versão (tag+digest) realmente em execução
#   6. guarda de integridade: recusa prosseguir se a tag declarada já está
#      em execução mas com um digest diferente do declarado (ver Etapa 5/8
#      da Sprint 1.1 — nunca sobrescrever silenciosamente uma release)
#   7. docker compose pull
#   8. (modo release) verifica o digest de cada imagem baixada
#   9. docker compose up -d
#  10. aguarda healthcheck (scripts/healthcheck.sh)
#  11. em falha, aciona rollback automático (scripts/rollback.sh) — a menos
#      que --no-auto-rollback seja passado
#
# Não escreve, imprime nem transmite nenhum valor de segredo. O arquivo de
# segredos da VPS (secrets_env_file) é referenciado apenas por path, nunca
# lido pelo runner (ADR-004).
#
# Uso:
#   scripts/deploy.sh --app <nome> --env <ambiente> [--no-auto-rollback]
#
# Códigos de saída:
#   0  - deploy bem-sucedido (healthcheck passou)
#   10 - uso inválido
#   11 - erro de configuração declarativa (inclui formato inválido de
#        SemVer/SHA/digest, e digest divergente pré-pull)
#   12 - erro de conectividade SSH
#   30 - deploy falhou; nenhum baseline disponível para rollback automático,
#        OU digest pós-pull não bateu com o declarado (release corrompida/
#        adulterada no registry) — nunca sobe o container nesse caso
#   31 - deploy falhou; rollback automático executado com sucesso
#   32 - deploy falhou; rollback automático TAMBÉM falhou (intervenção manual necessária)

set -euo pipefail

# shellcheck disable=SC2034 # usado indiretamente por log()/warn()/die() em lib/common.sh
SCRIPT_NAME="deploy.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: $0 --app <nome> --env <ambiente> [--no-auto-rollback]

Exemplo:
  $0 --app vantry --env production
EOF
}

APP=""
ENVIRONMENT=""
AUTO_ROLLBACK=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --no-auto-rollback) AUTO_ROLLBACK=0; shift ;;
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
PROJECT="$(yq_get "$METADATA_FILE" '.deploy_target.compose_project_name')"
SECRETS_ENV_FILE="$(yq_get "$METADATA_FILE" '.deploy_target.secrets_env_file')"
ROLLBACK_STATE_FILE="$(yq_get "$METADATA_FILE" '.deploy_target.rollback_state_file')"
SERVICES="$(yq eval '.deploy_target.managed_services[]' "$METADATA_FILE" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ -n "$SERVICES" ]] || die "nenhum managed_services declarado em ${METADATA_FILE}" 11

if [[ "$CONTRACT_MODE" == "release" ]]; then
  log "Deploy: app=${APP} env=${ENVIRONMENT} servidor=${SERVER_NAME} (${SSH_HOST}) — release ${RELEASE_VERSION} (commit ${SOURCE_COMMIT})"
else
  log "Deploy: app=${APP} env=${ENVIRONMENT} servidor=${SERVER_NAME} (${SSH_HOST}) — modo legado (sem release SemVer)"
fi
log "Serviços gerenciados: ${SERVICES}"
log "Versões desejadas: backend=${BACKEND_VERSION} frontend=${FRONTEND_VERSION} caddy=${CADDY_VERSION}"

# --- Conectividade -----------------------------------------------------

if ! ssh_exec "true" >/dev/null 2>&1; then
  die "não foi possível conectar via SSH em ${SSH_USER}@${SSH_HOST}:${SSH_PORT}" 12
fi
log "Conectividade SSH confirmada."

# --- 1. Captura o estado realmente em execução, ANTES de qualquer mudança ---

log "Capturando versões realmente em execução na VPS (baseline para rollback)..."
RUNNING_STATE="$(remote_capture_running_state "$PROJECT")"
RUNNING_BACKEND_TAG="$(printf '%s\n' "$RUNNING_STATE" | grep '^BACKEND_TAG=' | cut -d= -f2-)"
RUNNING_BACKEND_DIGEST="$(printf '%s\n' "$RUNNING_STATE" | grep '^BACKEND_DIGEST=' | cut -d= -f2-)"
RUNNING_FRONTEND_TAG="$(printf '%s\n' "$RUNNING_STATE" | grep '^FRONTEND_TAG=' | cut -d= -f2-)"
RUNNING_FRONTEND_DIGEST="$(printf '%s\n' "$RUNNING_STATE" | grep '^FRONTEND_DIGEST=' | cut -d= -f2-)"
RUNNING_CADDY_TAG="$(printf '%s\n' "$RUNNING_STATE" | grep '^CADDY_TAG=' | cut -d= -f2-)"
RUNNING_CADDY_DIGEST="$(printf '%s\n' "$RUNNING_STATE" | grep '^CADDY_DIGEST=' | cut -d= -f2-)"

if [[ -z "$RUNNING_BACKEND_TAG" || -z "$RUNNING_FRONTEND_TAG" || -z "$RUNNING_CADDY_TAG" ]]; then
  warn "Não foi possível determinar a versão em execução de todos os serviços (primeiro deploy via este pipeline?). Rollback automático não terá baseline nesta execução."
  HAS_BASELINE=0
else
  log "Estado atual em execução: backend=${RUNNING_BACKEND_TAG} frontend=${RUNNING_FRONTEND_TAG} caddy=${RUNNING_CADDY_TAG}"
  if [[ "$RUNNING_BACKEND_TAG" == "$BACKEND_VERSION" && "$RUNNING_FRONTEND_TAG" == "$FRONTEND_VERSION" && "$RUNNING_CADDY_TAG" == "$CADDY_VERSION" ]]; then
    log "Estado desejado já corresponde ao estado em execução — deploy será idempotente (docker compose up -d não recria containers inalterados)."
  fi
  log "Registrando baseline em ${ROLLBACK_STATE_FILE}..."
  if ! remote_write_rollback_state "$ROLLBACK_STATE_FILE" \
        "$RUNNING_BACKEND_TAG" "$RUNNING_BACKEND_DIGEST" \
        "$RUNNING_FRONTEND_TAG" "$RUNNING_FRONTEND_DIGEST" \
        "$RUNNING_CADDY_TAG" "$RUNNING_CADDY_DIGEST" >/dev/null; then
    die "falha ao registrar baseline de rollback em ${ROLLBACK_STATE_FILE} na VPS — abortando antes de qualquer mudança (verifique se o diretório é gravável pelo usuário ${SSH_USER})" 12
  fi
  HAS_BASELINE=1
fi

# --- 2. Guarda de integridade: a mesma tag já está rodando com outro digest? ---
#
# Se a tag declarada já está em execução, mas com um digest diferente do
# declarado agora, isso significa uma de duas coisas: (a) release.yml foi
# escrito com o digest errado para uma tag já implantada, ou (b) a tag
# "imutável" foi sobrescrita no registry — uma violação de política grave
# (ADR-001/ADR-003: releases SemVer nunca são sobrescritas). Em ambos os
# casos, seguir adiante silenciosamente seria exatamente o cenário que a
# introdução de digests deveria prevenir. Aborta sem tocar em nada.
if [[ "$CONTRACT_MODE" == "release" && "$HAS_BASELINE" -eq 1 ]]; then
  if [[ "$RUNNING_BACKEND_TAG" == "$BACKEND_VERSION" && -n "$RUNNING_BACKEND_DIGEST" && "$RUNNING_BACKEND_DIGEST" != "$BACKEND_DIGEST" ]]; then
    die "INTEGRIDADE COMPROMETIDA: backend:${BACKEND_VERSION} já está em execução com digest ${RUNNING_BACKEND_DIGEST}, mas release.yml declara ${BACKEND_DIGEST} para essa mesma tag. Uma release SemVer nunca deve ter dois digests diferentes. Não prosseguindo — corrija release.yml ou investigue se a tag foi sobrescrita no registry." 11
  fi
  if [[ "$RUNNING_FRONTEND_TAG" == "$FRONTEND_VERSION" && -n "$RUNNING_FRONTEND_DIGEST" && "$RUNNING_FRONTEND_DIGEST" != "$FRONTEND_DIGEST" ]]; then
    die "INTEGRIDADE COMPROMETIDA: frontend:${FRONTEND_VERSION} já está em execução com digest ${RUNNING_FRONTEND_DIGEST}, mas release.yml declara ${FRONTEND_DIGEST} para essa mesma tag. Não prosseguindo." 11
  fi
  if [[ "$RUNNING_CADDY_TAG" == "$CADDY_VERSION" && -n "$RUNNING_CADDY_DIGEST" && "$RUNNING_CADDY_DIGEST" != "$CADDY_DIGEST" ]]; then
    die "INTEGRIDADE COMPROMETIDA: caddy:${CADDY_VERSION} já está em execução com digest ${RUNNING_CADDY_DIGEST}, mas release.yml declara ${CADDY_DIGEST} para essa mesma tag. Não prosseguindo." 11
  fi
fi

# --- 3. Pull das versões desejadas ---

log "Executando docker compose pull com as versões desejadas..."
if ! remote_pull_versions "$WORKDIR" "$COMPOSE_FILE" "$SECRETS_ENV_FILE" "$SERVICES" \
      "$BACKEND_VERSION" "$FRONTEND_VERSION" "$CADDY_VERSION" \
      "" "" ""; then
  die "docker compose pull falhou na VPS — ver saída acima (nenhum container foi alterado)" 30
fi
log "docker compose pull concluído."

# --- 4. (modo release) verificação de digest pós-pull, ANTES de subir ---

BACKEND_DIGEST_REF=""; FRONTEND_DIGEST_REF=""; CADDY_DIGEST_REF=""

if [[ "$CONTRACT_MODE" == "release" ]]; then
  for spec in \
    "backend:${BACKEND_IMAGE}:${BACKEND_VERSION}:${BACKEND_DIGEST}" \
    "frontend:${FRONTEND_IMAGE}:${FRONTEND_VERSION}:${FRONTEND_DIGEST}" \
    "caddy:${CADDY_IMAGE}:${CADDY_VERSION}:${CADDY_DIGEST}"; do
    comp="${spec%%:*}"
    rest="${spec#*:}"
    image="${rest%%:*}"
    rest2="${rest#*:}"
    tag="${rest2%%:*}"
    digest="${rest2#*:}"

    result="$(remote_verify_digest "${image}:${tag}" "$digest")"
    case "$result" in
      MATCH)
        log "Digest confirmado para ${comp} (${image}:${tag} = ${digest})"
        if [[ "$comp" == "backend" ]]; then BACKEND_DIGEST_REF="${image}@${digest}"
        elif [[ "$comp" == "frontend" ]]; then FRONTEND_DIGEST_REF="${image}@${digest}"
        else CADDY_DIGEST_REF="${image}@${digest}"; fi
        ;;
      UNKNOWN)
        warn "Não foi possível confirmar o digest de ${comp} (${image}:${tag}) — RepoDigests vazio na VPS. Prosseguindo sem verificação para este componente (ver docs/versioning.md)."
        ;;
      MISMATCH:*)
        die "INTEGRIDADE COMPROMETIDA: ${comp} (${image}:${tag}) foi baixado com digest ${result#MISMATCH:}, mas release.yml declara ${digest}. Abortando ANTES de subir o container — nenhuma release é implantada sem prova de identidade do artefato." 30
        ;;
    esac
  done
fi

# --- 5. Sobe os containers ---

log "Executando docker compose up -d..."
if ! remote_up_versions "$WORKDIR" "$COMPOSE_FILE" "$SECRETS_ENV_FILE" "$SERVICES" \
      "$BACKEND_VERSION" "$FRONTEND_VERSION" "$CADDY_VERSION" \
      "$BACKEND_DIGEST_REF" "$FRONTEND_DIGEST_REF" "$CADDY_DIGEST_REF"; then
  die "docker compose up -d falhou na VPS — ver saída acima" 30
fi
log "docker compose up -d concluído."

# --- 6. Healthcheck ---

log "Aguardando healthcheck..."
if "${SCRIPT_DIR}/healthcheck.sh" --app "$APP" --env "$ENVIRONMENT"; then
  if [[ "$CONTRACT_MODE" == "release" ]]; then
    log "Deploy concluído com sucesso: Vantry ${RELEASE_VERSION} (commit ${SOURCE_COMMIT})"
  else
    log "Deploy concluído com sucesso: backend=${BACKEND_VERSION} frontend=${FRONTEND_VERSION} caddy=${CADDY_VERSION}"
  fi
  log "RESULT=DEPLOY_SUCCESS"
  exit 0
fi

# --- 7. Falha de healthcheck: rollback automático (se habilitado e com baseline) ---

warn "Healthcheck falhou após o deploy da versão desejada."

AUTO_TRIGGER="$(yq_get "$METADATA_FILE" '.rollback.auto_trigger_on_healthcheck_failure' --optional)"
if [[ "$AUTO_ROLLBACK" -eq 0 ]]; then
  die "Healthcheck falhou. Rollback automático desabilitado via --no-auto-rollback. Estado da VPS permanece na versão que falhou — ação manual necessária (scripts/rollback.sh)." 30
fi
if [[ "$AUTO_TRIGGER" != "true" ]]; then
  die "Healthcheck falhou. rollback.auto_trigger_on_healthcheck_failure=false em ${METADATA_FILE} — ação manual necessária (scripts/rollback.sh)." 30
fi
if [[ "$HAS_BASELINE" -ne 1 ]]; then
  die "Healthcheck falhou e não há baseline confiável para rollback automático (provável primeiro deploy). Intervenção manual necessária." 30
fi

warn "Acionando rollback automático para a última versão confirmada em execução..."
if "${SCRIPT_DIR}/rollback.sh" --app "$APP" --env "$ENVIRONMENT" --auto \
    --to-backend-tag "$RUNNING_BACKEND_TAG" --to-backend-digest "$RUNNING_BACKEND_DIGEST" \
    --to-frontend-tag "$RUNNING_FRONTEND_TAG" --to-frontend-digest "$RUNNING_FRONTEND_DIGEST" \
    --to-caddy-tag "$RUNNING_CADDY_TAG" --to-caddy-digest "$RUNNING_CADDY_DIGEST"; then
  warn "RESULT=DEPLOY_FAILED_ROLLBACK_SUCCESS — deploy da versão desejada falhou; VPS revertida com sucesso para backend=${RUNNING_BACKEND_TAG} frontend=${RUNNING_FRONTEND_TAG} caddy=${RUNNING_CADDY_TAG}."
  if [[ "$CONTRACT_MODE" == "release" ]]; then
    warn "AÇÃO NECESSÁRIA: o estado desejado em Git (release.yml) ainda declara a release ${RELEASE_VERSION}, que falhou. Abra um PR revertendo apps/${APP}/${ENVIRONMENT}/release.yml para manter o estado desejado consistente com a realidade (ver ADR-003 e ADR-001 — desvio documentado no relatório da Sprint 1)."
  else
    warn "AÇÃO NECESSÁRIA: o estado desejado em Git (versions.env) ainda declara a versão que falhou. Abra um PR revertendo apps/${APP}/${ENVIRONMENT}/versions.env para manter o estado desejado consistente com a realidade (ver ADR-003 e ADR-001 — desvio documentado no relatório da Sprint 1)."
  fi
  exit 31
else
  die "RESULT=DEPLOY_FAILED_ROLLBACK_FAILED — deploy falhou E o rollback automático também falhou. A VPS pode estar em estado inconsistente. Intervenção manual imediata necessária." 32
fi
