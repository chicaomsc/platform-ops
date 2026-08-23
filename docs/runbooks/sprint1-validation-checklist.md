# Runbook — Checklist de validação da Sprint 1

Os 8 cenários pedidos na Etapa 9 da Sprint 1. Cada um foi **exercitado em dry-run** durante a
implementação (scripts reais, SSH/Docker/curl simulados por dublês locais, nenhuma chamada à
VPS real) — ver relatório da Sprint 1 para o resultado desses dry-runs. Este checklist descreve
como repetir cada verificação **contra a VPS real**, o que ainda não foi feito.

Pré-requisito para todos os itens: secrets `PROD_SSH_PRIVATE_KEY`/`PROD_SSH_KNOWN_HOSTS`
configurados (ver [setup-github-environment-ssh.md](setup-github-environment-ssh.md)) e
`versions.env` confirmado contra a realidade (ver
[verify-current-production-state.md](verify-current-production-state.md)).

## 1. Deploy da mesma versão (idempotência)

Rodar o workflow (ou `scripts/deploy.sh --app vantry --env production` localmente) com
`versions.env` já igual ao que está em execução. **Esperado:** log
"Estado desejado já corresponde ao estado em execução — deploy será idempotente"; `docker
compose up -d` não recria containers inalterados; exit `0`.

## 2. Deploy de uma nova versão válida

Atualizar `versions.env` (PR) para um SHA publicado e íntegro. Rodar o workflow. **Esperado:**
pull + up dos três serviços, healthcheck PASS, exit `0`.

## 3. Healthcheck com sucesso

Coberto pelo item 2 — confirmar nos logs as quatro linhas `OK <serviço>` (backend, frontend,
caddy, postgres) e `RESULT=PASS`.

## 4. Simulação controlada de versão inválida

Atualizar `versions.env` para uma tag de imagem que **não existe** no GHCR (ex.: um SHA
inventado). **Esperado:** `docker compose pull` falha na VPS; `deploy.sh` sai com erro claro
antes de tentar `up -d` (nenhum container é afetado, pois o pull acontece antes do up na mesma
chamada) — exit `30` (nenhum rollback necessário, pois nada mudou). *Atenção:* isso consome uma
tentativa real de pull contra o GHCR — usar um SHA claramente inválido, nunca uma tag de
produção real.

## 5. Rollback automático

Publicar uma imagem que sobe mas falha no endpoint de health (ex.: backend saudável no
`docker inspect` mas retornando 5xx em `/actuator/health/readiness`), declarar essa versão em
`versions.env` e rodar o deploy. **Esperado:** healthcheck FAIL → rollback automático dispara →
versão anterior restaurada → healthcheck PASS na versão revertida → exit `31` → aviso pedindo PR
manual para realinhar `versions.env` com a realidade (ver desvio documentado em
[deployment-flow.md](../deployment-flow.md)).

## 6. Rollback manual

Ver [manual-rollback.md](manual-rollback.md). Rodar `scripts/rollback.sh --app vantry --env
production` sem `--to-*` (usa o baseline) e depois uma vez com as seis flags
`--to-*-tag`/`--to-*-digest` explícitas, para exercitar os dois modos.

## 7. Concorrência de deploy

Disparar o workflow duas vezes em sequência rápida (dois `workflow_dispatch`). **Esperado:** o
`concurrency.group: deploy-vantry-production` do workflow enfileira a segunda execução até a
primeira terminar — nunca as duas rodando ao mesmo tempo. Verificável na aba Actions do GitHub
(a segunda execução aparece como "Queued", não "In progress", enquanto a primeira roda). Este
comportamento é garantido pelo GitHub Actions e não é testável localmente/fora do GitHub.

## 8. Ausência de secrets em logs

Após qualquer execução do workflow, inspecionar o log completo (todas as etapas, incluindo
**Configurar acesso SSH**) buscando por `POSTGRES_PASSWORD`, `JWT_SECRET`, `CLOUDFLARE_API_TOKEN`, ou
qualquer trecho da chave privada. **Esperado:** nada encontrado — o GitHub Actions mascara
automaticamente valores de secret registrados, e nenhum script deste repositório imprime esses
valores deliberadamente (ver [docs/secrets.md](../secrets.md)).

## Resultado dos dry-runs desta sprint (sem VPS real)

| Cenário | Resultado do dry-run |
|---|---|
| 1. Idempotência | OK — log de idempotência emitido corretamente |
| 2/3. Deploy + healthcheck OK | OK — exit 0, 4/4 checks PASS |
| 4. Versão inválida | Não simulado em dry-run (requer GHCR real); lógica de fail-fast do `docker compose pull` coberta indiretamente pelo `set -euo pipefail` |
| 5. Rollback automático (sucesso) | OK — exit 31, aviso de PR pendente emitido |
| 5b. Rollback automático (também falha) | OK — exit 32, mensagem crítica emitida |
| 6. Rollback manual (baseline) | OK — exit 0, versão lida corretamente do state file |
| 7. Concorrência | Não testável fora do GitHub Actions |
| 8. Ausência de secrets em log | Verificado por leitura de código (nenhum script imprime `secrets_env_file`); não verificado em execução real do GitHub Actions |

## Sprint 1.1 — testes adicionais (SemVer, proveniência, digest)

Executados em dry-run com dublês locais, contra uma cópia isolada do repositório (nunca o
repositório real) simulando `apps/vantry/production/release.yml` com valores fabricados —
nenhum arquivo real foi criado. Ver [docs/versioning.md](../versioning.md).

| Cenário | Resultado do dry-run |
|---|---|
| SemVer válida (modo release) | OK — deploy prossegue normalmente |
| SemVer inválida (ex.: `"1.0"`) | OK — `deploy.sh` recusa antes de qualquer conexão SSH, exit `11`, mensagem aponta o campo exato |
| Source commit inválido (SHA curto) | OK — mesmo comportamento, exit `11` |
| Digest inválido (sem prefixo `sha256:`) | OK — mesmo comportamento, exit `11` |
| Digest divergente pós-pull (imagem baixada ≠ declarada) | OK — pull acontece, `up -d` **nunca é chamado**, container permanece na versão anterior, exit `30` |
| Tentativa de "alterar" uma release já existente (mesma tag rodando com digest diferente do agora declarado) | OK — bloqueado **antes do pull**, exit `11`, mensagem "INTEGRIDADE COMPROMETIDA" |
| Deploy idempotente da mesma release (modo release) | OK — mesma lógica do item 1, também funciona com `release.yml` |
| Rollback PATCH (ex.: 1.0.1 → 1.0.0), automático por falha de healthcheck | OK — exit 31, digest verificado no destino do rollback antes do `up -d` |
| Rollback "MINOR" (manual, explícito, com rótulo `--to-release`) | OK — exit 0, digest verificado, aviso de PR pendente |
| `--to-release` sem as seis flags de tag/digest | OK — erro de uso claro, exit `10`, sem tentar lookup mágico |
| Tag móvel (`latest`) em override de rollback | OK — rejeitado, exit `11` |
| Coexistência `release.yml` + `versions.env` | OK — aviso emitido, `release.yml` usado com prioridade |
| Ausência de `latest`/`main`/`stable` (modo release) | OK — mesma validação do modo legado, reutilizada |
| Ausência de secrets em log | Verificado por leitura de código; nenhum valor de `secrets_env_file` é lido ou impresso pelos novos trechos (`remote_verify_digest`, `remote_capture_running_state`) |

**Não testado nesta sprint (requer VPS/GHCR reais, fora do escopo — "não fazer deploy real"):**
verificação de digest contra um registry GHCR de verdade; publicação de imagens com tag SemVer
real; o cenário de "tag realmente sobrescrita no registry" (só simulado via dublê local).
