# Deployment Flow — guia operacional (Vantry / Production)

Este documento é o guia rápido de **como o pipeline funciona na prática**, complementar à
[ADR-002](../adr/ADR-002-deployment-pipeline.md) (esteira), [ADR-003](../adr/ADR-003-rollback-strategy.md)
(rollback), [ADR-006](../adr/ADR-006-release-management.md)/[ADR-007](../adr/ADR-007-artifact-provenance.md)
(release/proveniência) e [docs/versioning.md](versioning.md) +
[docs/release-management.md](release-management.md) (leitura obrigatória antes deste documento
se você não a leu ainda). Escopo: Sprint 1 até Sprint 1.2 — `workflow_dispatch` manual,
aplicação piloto Vantry, ambiente Production.

## Dois contratos de versão, coexistindo (apenas durante a migração)

`apps/<app>/<env>/` pode declarar o estado desejado de duas formas — nunca as duas ativas ao
mesmo tempo por escolha, mas os scripts toleram e avisam se ambas existirem:

- **`release.yml`** (oficial, schema `platform-ops/v1`, preferido quando presente) — SemVer +
  sourceCommit + createdAt + imagem/tag/digest por componente. Habilita verificação de digest e
  de **imutabilidade histórica** em tempo de deploy (ver [docs/release-management.md](release-management.md)).
- **`versions.env`** (LEGADO/DEPRECATED) — SHA de commit por componente, sem digest declarado.
  **É o que Vantry/Production usa hoje** — não foi migrado nesta sprint (ver "Migração" abaixo).
  Permitido tecnicamente **apenas** para apps na allowlist de migração (hoje: só `vantry`) —
  qualquer app novo é bloqueado (`exit 11`) ao tentar usar este contrato.

`scripts/lib/common.sh` (`load_release_state`) detecta automaticamente qual está presente.

## Visão geral do que existe hoje (modo legado, o caso real de Vantry/Production)

```
apps/vantry/production/versions.env  (estado desejado, em Git — modo legado)
            │
            │  workflow_dispatch (manual, GitHub Actions)
            ▼
.github/workflows/deploy-production.yml
            │
            │  SSH (chave dedicada, GitHub Environment "production")
            ▼
scripts/deploy.sh  ──────────────────────────────────────────┐
   1. lê apps/vantry/production/{metadata.yml,versions.env}   │
   2. lê servers/hetzner-prod-01.yml                           │
   3. confirma conectividade SSH                                │
   4. captura tag+digest REALMENTE em execução (docker inspect)  │
   5. grava baseline em deploy_target.rollback_state_file          │
   6. docker compose pull (serviços managed_services)                │
   7. (modo release apenas) verifica digest pós-pull                  │
   8. docker compose up -d (serviços managed_services)                  │
   9. chama scripts/healthcheck.sh ───────────────────────┐               │
                                                             │               │
        healthcheck OK ──────────────────────────► deploy concluído (exit 0)
                                                             │
        healthcheck FAIL ──► scripts/rollback.sh (automático, se habilitado)
                                     │
                                     ├─ rollback OK    → exit 31 (ver nota abaixo)
                                     └─ rollback FALHOU → exit 32 (crítico)
```

Nenhuma automação nesta sprint cria PR a partir do repositório da aplicação
(`chicaomsc/contractor-plataform`) — isso é um não-objetivo explícito da Sprint 1/1.1. A
atualização de `apps/vantry/production/versions.env` (ou, após migração, `release.yml`) é, por
enquanto, manual (PR humano).

## Scripts

Todos em `scripts/`, executáveis (`chmod +x`), reutilizáveis para qualquer app/ambiente que
siga a mesma convenção declarativa. Compartilham lógica comum em `scripts/lib/common.sh`
(logging, leitura de YAML via `yq`, validação de SemVer/SHA/digest, execução remota via SSH).
Dependências: `yq` (v4), `jq`, `ssh`, `timeout` (GNU coreutils — presente por padrão no runner
`ubuntu-latest`; ausente por padrão no macOS).

### `scripts/deploy.sh --app <nome> --env <ambiente> [--no-auto-rollback]`

Converge o estado real para o estado desejado. Em modo `release`, insere verificação de digest
entre pull e up (ver [docs/versioning.md](versioning.md)) e recusa prosseguir se a tag declarada
já está em execução com um digest diferente do declarado agora (guarda contra sobrescrita de
release). Ver cabeçalho do arquivo para o fluxo completo e a tabela de exit codes abaixo.

### `scripts/healthcheck.sh --app <nome> --env <ambiente>`

Sem mudanças de comportamento na Sprint 1.1, além de logar a release SemVer quando disponível.
Para cada check declarado em `metadata.yml` (`.healthcheck.checks`), roda um loop de retry
**inteiramente na VPS** (um único SSH por invocação, não um SSH por tentativa), respeitando
`timeout_seconds`, `interval_seconds` e `retries`. Nunca considera apenas "o container está
rodando" — HTTP exige o `expected_status` exato; `postgres` exige `pg_isready` bem-sucedido
dentro do container.

### `scripts/rollback.sh --app <nome> --env <ambiente> [--auto] [--to-release <semver>] [--to-backend-tag X --to-backend-digest sha256:... --to-frontend-tag Y --to-frontend-digest sha256:... --to-caddy-tag Z --to-caddy-digest sha256:...]`

Mesma mecânica de convergência do `deploy.sh`, aplicada à versão anterior. Sem as flags `--to-*`,
lê o snapshot (tag+digest) mais recente em `deploy_target.rollback_state_file` na VPS. Com
override manual, exige as **seis flags em conjunto** (tag e digest de cada componente) — rollback
nunca é só por tag, sempre tag+digest verificados (ver
[docs/versioning.md](versioning.md#rollback)). `--to-release` é apenas um rótulo para clareza de
log, não faz lookup automático. Sempre confirma saúde da versão revertida antes de reportar
sucesso.

## Códigos de saída

| Script | Código | Significado |
|---|---|---|
| todos | `0` | sucesso |
| todos | `10` | uso inválido (argumento ausente/desconhecido, ou flags de rollback incompletas) |
| todos | `11` | erro de configuração declarativa: arquivo ausente/incompleto; SemVer/SHA/digest/ISO8601 com formato inválido; `apiVersion`/`kind`/`metadata.application`/`metadata.environment` não batem com o schema ou o app/ambiente solicitado; guarda de integridade "ao vivo" (tag já em execução com digest diferente do declarado); **imutabilidade histórica violada** (release já declarada antes com `sourceCommit`/digest diferente — ver ADR-007); ou app fora da allowlist tentando usar `versions.env` |
| todos | `12` | erro de conectividade/execução SSH |
| `healthcheck.sh` | `20` | um ou mais checks falharam dentro do timeout/retries |
| `deploy.sh` | `30` | deploy falhou (pull/up falhou, ou digest pós-pull divergente — nenhum container é alterado nesse caso); rollback automático não foi tentado (desabilitado, ou sem baseline) |
| `deploy.sh` | `31` | deploy falhou; rollback automático **executado com sucesso** — ver nota abaixo |
| `deploy.sh` / `rollback.sh` | `32` / `21` | deploy falhou **e** rollback também falhou, OU rollback aplicado mas reprovado no healthcheck — situação crítica, intervenção manual imediata |
| `rollback.sh` | `13` | nenhum baseline disponível e nenhuma versão-alvo explícita fornecida |
| `rollback.sh` | `20` | digest pós-pull da versão de rollback não bateu com o declarado — abortado antes de subir o container |

## Nota importante: desvio conhecido em relação à ADR-003

A [ADR-003](../adr/ADR-003-rollback-strategy.md) declara que "o rollback automático é ele
próprio registrado como um evento em Git (commit automatizado)". **Isso ainda NÃO está
implementado** (Sprint 1 e Sprint 1.1). Quando `deploy.sh` executa um rollback automático (exit
`31`), o estado real da VPS reverte, mas o estado desejado em Git (`versions.env` ou
`release.yml`, conforme o contrato em uso) continua declarando a versão que falhou — uma
divergência intencionalmente temporária. O script imprime um aviso explícito pedindo PR manual.
Fechar esse gap é trabalho de sprint futura.

## Como disparar um deploy

1. Confirmar que `apps/vantry/production/versions.env` está com o SHA desejado (PR revisado e
   mergeado, seguindo a política de aprovação da [ADR-005](../adr/ADR-005-environment-promotion.md)).
2. No GitHub, Actions → **Deploy Production (Vantry)** → Run workflow (branch `main`).
3. Acompanhar o log do passo **Deploy — vantry/production** e o resumo do job.

## Migração para `release.yml` (quando a primeira release SemVer real existir)

Ver [docs/versioning.md](versioning.md#migração-do-modelo-legado-ao-novo-contrato) para o
caminho completo. Resumo: nada muda até a primeira release `1.0.0` ser de fato publicada com
imagens GHCR sob essa tag — só então `apps/vantry/production/release.yml` é criado (com valores
reais confirmados) e, em PR separado, `versions.env` é removido.

## Pré-condições (atualizado — Sprint 2A auditou com acesso real à VPS de produção)

- ~~`docker-compose.prod.yml` precisa referenciar `${BACKEND_VERSION}`/`${FRONTEND_VERSION}`/`${CADDY_VERSION}`~~
  **CONFIRMADO INCOMPATÍVEL** (não mais "não inspecionado"): o arquivo real usa
  `${APP_VERSION:-local}` único. Patch explícito preparado — ver
  [docs/runbooks/apply-app-repo-compose-patch.md](runbooks/apply-app-repo-compose-patch.md).
  **Bloqueador até ser aplicado no repositório de aplicação.**
- ~~O diretório pai de `rollback_state_file` precisa existir e ser gravável~~ **CONFIRMADO
  RESOLVIDO**: o diretório não existe hoje, mas o usuário `deploy` tem permissão de criá-lo
  (`mkdir -p`, já embutido em `remote_write_rollback_state`) — testado e revertido nesta sprint,
  sem alterar produção. Não é mais um bloqueador.
- Os secrets `PROD_SSH_PRIVATE_KEY` e `PROD_SSH_KNOWN_HOSTS` ainda não existem no GitHub
  Environment `production` — ver
  [docs/runbooks/setup-github-environment-ssh.md](runbooks/setup-github-environment-ssh.md).
  **Nota de design:** host e usuário SSH (`PROD_SSH_HOST`/`PROD_SSH_USER`, nomes sugeridos na
  Sprint 1) não são tratados como secret nesta implementação — vêm de
  `servers/hetzner-prod-01.yml` (`.public_ip` / `.ssh.user`), que já é a fonte da verdade não
  secreta desses dados (ADR-004). Apenas a chave privada e o known_hosts são, de fato, secrets.
- **Novo (Sprint 2A):** nenhum componente tem digest OCI verificável hoje na VPS (`RepoDigests`
  ausente) — tratado como `legacy / provenance unavailable`, não bloqueia o contrato legado
  (`versions.env`, que nunca declarou digest), mas impede criar `release.yml` oficial para
  Vantry/Production com valores reais até uma publicação real via GHCR — ver
  [docs/release-management.md](release-management.md).
