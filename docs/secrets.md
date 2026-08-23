# Secrets — guia operacional (Vantry / Production)

Guia rápido complementar à [ADR-004](../adr/ADR-004-secrets-management.md) (que registra a
decisão e a justificativa). Este documento lista, para o piloto Vantry, exatamente quais
segredos existem, onde vivem, e confirma que nenhum deles está — ou deveria estar — neste
repositório.

## Segredos que já existem na VPS e permanecem lá

Vivem em `/opt/contractor-platform/infra/env/production.env`, fora deste repositório. O
`platform-ops` referencia esse arquivo **apenas pelo path**
(`apps/vantry/production/metadata.yml` → `deploy_target.secrets_env_file`) para que
`docker compose --env-file` o utilize — nunca lê, copia, imprime ou versiona seu conteúdo.

- `POSTGRES_PASSWORD`
- `JWT_SECRET`
- `CLOUDFLARE_API_TOKEN`
- (e quaisquer outros já presentes nesse arquivo, não inventariados aqui — este repositório não
  tem, nem deveria ter, visibilidade sobre o conteúdo do arquivo)

Nenhuma ação desta sprint move, duplica ou lê esses valores.

## Segredos que passam a existir no GitHub (Environment `production`)

Necessários para o workflow `deploy-production.yml` operar via SSH. **Ainda não configurados**
— ver [docs/runbooks/setup-github-environment-ssh.md](runbooks/setup-github-environment-ssh.md)
para o procedimento de criação.

| Secret | Conteúdo | Uso |
|---|---|---|
| `PROD_SSH_PRIVATE_KEY` | Chave privada SSH **dedicada** ao deploy do platform-ops (nunca uma chave pessoal) | Carregada em um `ssh-agent` efêmero no runner; nunca escrita em disco no workspace, nunca impressa |
| `PROD_SSH_KNOWN_HOSTS` | Entrada `known_hosts` da VPS `hetzner-prod-01` (fingerprint pinado, não descoberto via `ssh-keyscan` em tempo de execução) | Escrita em `~/.ssh/known_hosts` no runner antes de qualquer conexão, para `StrictHostKeyChecking=yes` funcionar |

Host (`46.225.52.238`) e usuário (`deploy`) **não são secrets** nesta arquitetura — vêm de
`servers/hetzner-prod-01.yml`, versionado normalmente (ver ADR-004: IP público e usuário de
deploy não são credenciais).

## O que nunca vai para o GitHub

Por instrução explícita da Sprint 1 e por decisão arquitetural (ADR-004): `POSTGRES_PASSWORD`,
`JWT_SECRET` e `CLOUDFLARE_API_TOKEN` não têm — e não têm previsão de ter — nenhuma necessidade
de existir como secret do GitHub. O workflow de deploy nunca precisa desses valores: eles são
consumidos pela aplicação diretamente na VPS, via `production.env`, que o `docker compose`
carrega localmente. O GitHub só precisa da credencial mínima para *executar* o deploy (SSH), não
das credenciais que a *aplicação* usa em runtime.

## Verificação: nenhum segredo em log

- Nenhum script (`deploy.sh`, `healthcheck.sh`, `rollback.sh`, `lib/common.sh`) usa `set -x`.
- Nenhum script imprime o conteúdo de `production.env` — apenas referencia seu path.
- O passo **Configurar acesso SSH** do workflow não ecoa a chave privada em nenhum momento; ela
  é passada via `ssh-add -` (stdin) e o GitHub Actions mascara automaticamente qualquer valor
  registrado como secret que apareça em log.
- Ver [docs/runbooks/sprint1-validation-checklist.md](runbooks/sprint1-validation-checklist.md),
  item 8, para o procedimento de verificação manual de ausência de segredos em log.
