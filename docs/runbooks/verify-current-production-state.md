# Runbook — Verificar o estado real em execução antes de confiar em `versions.env`

**Quando usar:** antes do primeiro deploy real do `platform-ops` sobre a infraestrutura Vantry
já existente. `apps/vantry/production/versions.env` declara `adbfe3d3451ed372bd55308bbe977dec2d83ed35`
como versão atual, informado como "o último SHA promovido" — mas, por princípio (ver ADR-001 e
Sprint 1), esse valor **não deve ser tratado como verdade só porque está em Git** até ser
confirmado contra os containers realmente em execução na VPS.

## Procedimento

Na VPS (via SSH, usuário `deploy`):

```
docker inspect --format='{{.Config.Image}}' contractor-platform-backend-1
docker inspect --format='{{.Config.Image}}' contractor-platform-frontend-1
docker inspect --format='{{.Config.Image}}' contractor-platform-caddy-1
```

Cada comando retorna algo como:

```
ghcr.io/chicaomsc/contractor-platform-backend:<SHA>
```

Compare o `<SHA>` de cada um com o valor declarado em `apps/vantry/production/versions.env`.

`scripts/deploy.sh` já faz exatamente essa verificação automaticamente, a cada execução, antes
de qualquer mudança (ver Etapa 5 da Sprint 1) — mas na primeira execução real, faça essa
conferência manualmente primeiro, para decidir com segurança se `versions.env` precisa ser
corrigido antes do primeiro deploy via pipeline.

## Se os três SHAs baterem com `versions.env`

Nenhuma ação necessária. O primeiro deploy via `scripts/deploy.sh` será idempotente (não
recria containers) — ver [docs/deployment-flow.md](../deployment-flow.md).

## Se algum SHA divergir

1. **Não edite a VPS manualmente para "corrigir" a divergência.** Isso mascararia o problema
   sem deixar rastro (ver ADR-001 — Git é a fonte da verdade; a VPS deve convergir para o Git,
   nunca o contrário).
2. Abra um PR corrigindo `apps/vantry/production/versions.env` para refletir o SHA
   **realmente em execução** — isso restaura a consistência entre estado desejado e estado
   real, que é o pré-requisito para o pipeline operar com segurança.
3. Só depois disso, planeje o deploy da versão que efetivamente se deseja promover, como um
   segundo PR/execução separada.

## Verificar também o Postgres (não gerenciado por versão, mas relevante para o healthcheck)

```
docker exec contractor-platform-postgres-1 pg_isready -U platform -d platform_db
```

Deve retornar `accepting connections`. Se não retornar, o healthcheck de qualquer deploy via
`platform-ops` falhará por esse motivo — mesmo que backend/frontend/caddy estejam corretos.

## Nota (Sprint 1.1)

Este runbook cobre o contrato legado (`versions.env`, SHA de commit), que é o que
Vantry/Production usa hoje. Quando este app migrar para `release.yml`, `scripts/deploy.sh`
passa a verificar também o **digest** de cada imagem (não só a tag) antes de qualquer mudança —
ver [docs/versioning.md](../versioning.md). O procedimento manual acima continua válido como
primeira verificação antes da migração.
