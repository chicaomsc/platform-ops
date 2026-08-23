#!/usr/bin/env bash
#
# scripts/healthcheck.sh — valida a saúde real da aplicação após um deploy.
#
# Não se limita a "o container está rodando": para cada serviço declarado em
# apps/<app>/<env>/metadata.yml, executa a verificação configurada (HTTP com
# status esperado, ou comando dentro do container) diretamente na VPS, com
# timeout, intervalo e número de tentativas explícitos (ADR-003, Sprint 1
# Etapa 4). Reutilizável para qualquer app/ambiente que siga a mesma
# convenção declarativa — nada aqui é específico do Vantry.
#
# Sprint 2A.1 — cada check tem seu PRÓPRIO orçamento de tempo (START_TS
# capturado individualmente, dentro do bloco gerado para cada check), não um
# orçamento global compartilhado entre todos os checks do script remoto. Bug
# de auditoria: antes, um check que esgotasse suas tentativas consumia o
# relógio compartilhado, deixando os checks seguintes com orçamento quase
# zerado mesmo que estivessem saudáveis (só não falhavam se passassem na
# primeira tentativa). `timeout_seconds` em metadata.yml continua sendo um
# teto por check, não uma espera fixa — um check que passa na primeira
# tentativa retorna imediatamente.
#
# Uso:
#   scripts/healthcheck.sh --app <nome> --env <ambiente>
#
# Códigos de saída:
#   0  - todos os checks passaram
#   10 - uso inválido
#   11 - erro de configuração declarativa (metadata.yml/versions.env/servers)
#   12 - erro de conectividade SSH
#   20 - um ou mais checks falharam dentro do timeout/retries configurado

set -euo pipefail

# shellcheck disable=SC2034 # usado indiretamente por log()/warn()/die() em lib/common.sh
SCRIPT_NAME="healthcheck.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: $0 --app <nome> --env <ambiente>

Exemplo:
  $0 --app vantry --env production
EOF
}

APP=""
ENVIRONMENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
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

TIMEOUT_SECONDS="$(yq_get "$METADATA_FILE" '.healthcheck.timeout_seconds')"
INTERVAL_SECONDS="$(yq_get "$METADATA_FILE" '.healthcheck.interval_seconds')"
RETRIES="$(yq_get "$METADATA_FILE" '.healthcheck.retries')"

if [[ "$CONTRACT_MODE" == "release" ]]; then
  log "Healthcheck de ${APP}/${ENVIRONMENT} — release ${RELEASE_VERSION} em ${SSH_HOST} (timeout=${TIMEOUT_SECONDS}s intervalo=${INTERVAL_SECONDS}s retries=${RETRIES})"
else
  log "Healthcheck de ${APP}/${ENVIRONMENT} em ${SSH_HOST} (timeout=${TIMEOUT_SECONDS}s intervalo=${INTERVAL_SECONDS}s retries=${RETRIES})"
fi

CHECKS_JSON="$(yq eval -o=json '.healthcheck.checks' "$METADATA_FILE")"
[[ "$CHECKS_JSON" != "null" && -n "$CHECKS_JSON" ]] || die "nenhum check declarado em ${METADATA_FILE} (.healthcheck.checks)" 11

CHECK_COUNT="$(printf '%s' "$CHECKS_JSON" | jq 'length')"
[[ "$CHECK_COUNT" -gt 0 ]] || die "lista de healthcheck.checks está vazia em ${METADATA_FILE}" 11

# --- Monta o script remoto: um loop de retry por check, tudo executado na VPS ---
# shellcheck disable=SC2016 # aspas simples são intencionais: o texto gerado é
# um script que só é avaliado depois, remotamente, na VPS — não aqui.

REMOTE_SCRIPT="$(mktemp)"
trap 'rm -f "$REMOTE_SCRIPT"' EXIT

{
  echo 'set -uo pipefail'
  echo "TIMEOUT_SECONDS=${TIMEOUT_SECONDS}"
  echo "INTERVAL_SECONDS=${INTERVAL_SECONDS}"
  echo "RETRIES=${RETRIES}"
  echo 'OVERALL_STATUS=0'
  echo 'FAILED_CHECKS=""'
  echo ''

  for i in $(seq 0 $((CHECK_COUNT - 1))); do
    row="$(printf '%s' "$CHECKS_JSON" | jq -c ".[$i]")"
    service="$(printf '%s' "$row" | jq -r '.service')"
    type="$(printf '%s' "$row" | jq -r '.type')"

    echo "# --- check: ${service} (${type}) — orçamento de tempo próprio, não compartilhado com os demais checks (Sprint 2A.1) ---"
    echo 'START_TS=$(date +%s)'
    echo "attempt=0"
    echo "ok=0"
    echo 'while [[ $attempt -lt '"${RETRIES}"' ]]; do'
    echo '  attempt=$((attempt+1))'
    echo '  elapsed=$(( $(date +%s) - START_TS ))'
    echo '  if [[ $elapsed -ge '"${TIMEOUT_SECONDS}"' ]]; then'
    echo "    echo \"FAIL ${service} timeout_excedido elapsed=\${elapsed}s\""
    echo '    break'
    echo '  fi'

    if [[ "$type" == "http" ]]; then
      url="$(printf '%s' "$row" | jq -r '.url')"
      expected="$(printf '%s' "$row" | jq -r '.expected_status')"
      echo "  status=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 '${url}' || echo 000)"
      echo "  if [[ \"\${status}\" == \"${expected}\" ]]; then"
      echo "    echo \"OK ${service} status=\${status}\""
      echo '    ok=1'
      echo '    break'
      echo '  fi'
      echo "  echo \"retry ${service} tentativa=\${attempt}/${RETRIES} status=\${status} esperado=${expected}\""
    elif [[ "$type" == "exec" ]]; then
      container="$(printf '%s' "$row" | jq -r '.container')"
      cmd="$(printf '%s' "$row" | jq -r '.command')"
      echo "  if docker exec '${container}' ${cmd} >/tmp/hc_out_${i}.log 2>&1; then"
      echo "    echo \"OK ${service} comando_ok\""
      echo '    ok=1'
      echo '    break'
      echo '  fi'
      echo "  echo \"retry ${service} tentativa=\${attempt}/${RETRIES} comando_falhou: \$(tail -c 200 /tmp/hc_out_${i}.log 2>/dev/null)\""
    else
      echo "  echo \"FAIL ${service} tipo_de_check_desconhecido:${type}\""
      echo '  break'
    fi

    echo '  sleep '"${INTERVAL_SECONDS}"
    echo 'done'
    echo 'if [[ $ok -ne 1 ]]; then'
    echo '  OVERALL_STATUS=1'
    echo "  FAILED_CHECKS=\"\${FAILED_CHECKS} ${service}\""
    echo "  echo \"FAIL ${service} esgotou_tentativas\""
    echo 'fi'
    echo ''
  done

  echo 'if [[ $OVERALL_STATUS -eq 0 ]]; then'
  echo '  echo "RESULT=PASS"'
  echo 'else'
  echo '  echo "RESULT=FAIL checks_falhos:${FAILED_CHECKS}"'
  echo 'fi'
  echo 'rm -f /tmp/hc_out_*.log'
  echo 'exit $OVERALL_STATUS'
} > "$REMOTE_SCRIPT"

set +e
REMOTE_OUTPUT="$(ssh_exec_stdin "$REMOTE_SCRIPT" 2>&1)"
REMOTE_EXIT=$?
set -e

printf '%s\n' "$REMOTE_OUTPUT" | while IFS= read -r line; do log "vps: ${line}"; done

INTERNAL_OK=1
if [[ $REMOTE_EXIT -ne 0 ]]; then
  INTERNAL_OK=0
fi

# --- Validação externa opcional (executada do runner, não da VPS) ---

EXTERNAL_ENABLED="$(yq_get "$METADATA_FILE" '.healthcheck.external_validation.enabled' --optional)"
EXTERNAL_OK=1
if [[ "$EXTERNAL_ENABLED" == "true" ]]; then
  EXT_URL="$(yq_get "$METADATA_FILE" '.healthcheck.external_validation.url')"
  EXT_EXPECTED="$(yq_get "$METADATA_FILE" '.healthcheck.external_validation.expected_status')"
  log "Validação externa: ${EXT_URL}"
  EXT_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$EXT_URL" || echo 000)"
  if [[ "$EXT_STATUS" == "$EXT_EXPECTED" ]]; then
    log "Validação externa OK (status=${EXT_STATUS})"
  else
    warn "Validação externa falhou (status=${EXT_STATUS}, esperado=${EXT_EXPECTED})"
    EXTERNAL_OK=0
  fi
else
  log "Validação externa desabilitada em metadata.yml (external_validation.enabled=false) — pulando"
fi

if [[ $INTERNAL_OK -eq 1 && $EXTERNAL_OK -eq 1 ]]; then
  log "Healthcheck: PASS"
  exit 0
else
  die "Healthcheck: FAIL (interno_ok=${INTERNAL_OK} externo_ok=${EXTERNAL_OK})" 20
fi
