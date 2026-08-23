# Runbook — Rollback manual (Vantry / Production)

**Quando usar:** um problema foi identificado que o healthcheck automático não capturou (ver
[ADR-003](../../adr/ADR-003-rollback-strategy.md) — regressão funcional silenciosa, degradação
percebida, relato de usuário), ou é necessário reverter para uma versão anterior à imediatamente
anterior (mais antiga que o último baseline automático).

## Caso 1 — Reverter para a última versão conhecida-boa

Requer acesso ao repositório `platform-ops` com as credenciais SSH já configuradas localmente
(mesmo acesso usado para operar a VPS) e as ferramentas `yq`, `jq` instaladas.

```
scripts/rollback.sh --app vantry --env production
```

Sem `--to-*`, o script lê automaticamente o snapshot em
`apps/vantry/production/metadata.yml` → `deploy_target.rollback_state_file`
(`/opt/contractor-platform/infra/state/last-known-good.env` na VPS) — a versão que estava em
execução imediatamente antes do deploy mais recente — e reverte para ela, confirmando saúde ao
final.

## Caso 2 — Reverter para uma versão específica mais antiga

Tag é **sempre** obrigatória para os três componentes. Digest depende do contrato (Sprint 2A.3 —
ver [deployment-flow.md § Rollback legado vs. rollback release](../deployment-flow.md#rollback-legado-vs-rollback-release-temporário--sprint-2a3)):

- **Vantry/Production (contrato legado, `versions.env`):** nunca existiu digest verificável para
  essas imagens — identifique o SHA desejado no histórico de commits de
  `apps/vantry/production/versions.env` (`git log -p apps/vantry/production/versions.env`) e
  passe **só as três flags de tag**; omitir as flags de digest é aceito, com aviso.
- **Apps já migrados para `release.yml`:** digest é obrigatório — localize o commit de
  `release.yml` correspondente à release desejada (`git log -p apps/<app>/<env>/release.yml`) e
  copie tag+digest de cada componente a partir dele.

```
# Contrato legado (Vantry/Production hoje) — só tag, digest opcional:
scripts/rollback.sh --app vantry --env production \
  --to-backend-tag <sha>  --to-frontend-tag <sha>  --to-caddy-tag <sha>

# Contrato release.yml — tag e digest obrigatórios em conjunto:
scripts/rollback.sh --app vantry --env production --to-release 1.2.0 \
  --to-backend-tag 1.2.0  --to-backend-digest sha256:... \
  --to-frontend-tag 1.2.0 --to-frontend-digest sha256:... \
  --to-caddy-tag 1.2.0    --to-caddy-digest sha256:...
```

`--to-release` é apenas um rótulo para o log — não faz lookup automático; passá-lo sem as flags
de tag é um erro de uso deliberado (o script nunca adivinha um digest histórico).

## Depois de qualquer rollback manual

O script imprime um aviso lembrando: se a versão revertida deve se tornar o novo estado
desejado oficial (não apenas um remédio temporário), abra um PR atualizando
`apps/vantry/production/versions.env` (ou `release.yml`, conforme o contrato em uso) para os
mesmos valores — Git deve refletir a realidade (ADR-001). Sem esse PR, a próxima execução de
`deploy.sh` tentará promover novamente a versão problemática (pois é isso que o estado desejado
ainda declara).

## Se o rollback também falhar no healthcheck (exit `21`)

Situação crítica — a versão de rollback também está falhando. Isso é diferente do problema
original: pode indicar que a causa raiz não é a versão da aplicação (ex.: dependência externa
indisponível — banco, Cloudflare — ou problema de infraestrutura na própria VPS). Passos:

1. Rodar `scripts/healthcheck.sh --app vantry --env production` isoladamente para ver
   exatamente qual check está falhando e sua mensagem de erro.
2. Verificar Postgres separadamente (`docker exec contractor-platform-postgres-1 pg_isready -U
   platform -d platform_db`) — se o banco estiver indisponível, nenhuma versão de
   backend/frontend vai passar no healthcheck, e o problema não é a versão da imagem.
3. Se necessário, investigar diretamente na VPS (`docker compose -f
   /opt/contractor-platform/infra/compose/docker-compose.prod.yml logs --tail=200 backend`).

## Rollback automático (para contexto — não é uma ação manual)

`scripts/deploy.sh` já aciona rollback automaticamente quando o healthcheck pós-deploy falha
(salvo `--no-auto-rollback` ou `rollback.auto_trigger_on_healthcheck_failure: false` em
`metadata.yml`). Este runbook cobre apenas os casos em que uma ação humana precisa iniciar o
rollback.
