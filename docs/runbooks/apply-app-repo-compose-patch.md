# Runbook — Aplicar patch de compatibilidade no repositório de aplicação

**Por quê:** a auditoria da Sprint 2A confirmou, com acesso real e somente-leitura à VPS de
produção, que `docker-compose.prod.yml` usa **`${APP_VERSION:-local}` único**, compartilhado por
`backend`/`frontend`/`caddy` — não `${BACKEND_VERSION}`/`${FRONTEND_VERSION}`/`${CADDY_VERSION}`
como `scripts/deploy.sh`/`rollback.sh` exportam. Sem este patch, um deploy real via
`platform-ops` executaria `docker compose pull`/`up -d` com a tag `local` para os três
componentes — não a versão pretendida.

**Onde:** repositório `chicaomsc/contractor-plataform`, arquivo `infra/compose/docker-compose.prod.yml`.
Este arquivo **não pertence ao `platform-ops`** — o patch abaixo deve ser aplicado por alguém com
acesso de escrita àquele repositório, nunca diretamente na VPS (isso quebraria GitOps — ver
ADR-001) nem por este repositório.

**Compatibilidade preservada:** `APP_VERSION` continua funcionando exatamente como hoje (ver
"Confirmação técnica" abaixo). Nenhum processo manual existente quebra. `APP_VERSION` passa a ser
o **fallback** usado apenas quando `BACKEND_VERSION`/`FRONTEND_VERSION`/`CADDY_VERSION` não estão
definidas — que é sempre o caso hoje, então o comportamento atual é idêntico até o
`platform-ops` começar a exportar as três variáveis novas (o que ele já faz, desde a Sprint 1).

## Confirmação técnica (antes de aplicar)

Testado localmente nesta sprint com Docker Compose real (v5.0.2, mesma geração da v5.4.0 em
produção) via `docker compose config`, sem subir nenhum container:

| Cenário | Resultado |
|---|---|
| Nem `BACKEND_VERSION` nem `APP_VERSION` definidas | resolve para `local` (idêntico ao comportamento atual) |
| Só `APP_VERSION` definida | resolve para o valor de `APP_VERSION` (idêntico ao comportamento atual) |
| `BACKEND_VERSION` **e** `APP_VERSION` definidas | `BACKEND_VERSION` vence (novo comportamento, o que queremos) |

A interpolação aninhada `${A:-${B:-default}}` é suportada nativamente pelo Compose Specification
— não é um workaround frágil.

## Patch

Aplicar em `infra/compose/docker-compose.prod.yml`, três ocorrências (uma por serviço):

```diff
--- a/infra/compose/docker-compose.prod.yml
+++ b/infra/compose/docker-compose.prod.yml
@@ -1,5 +1,10 @@
 # Contractor Platform — production container stack.
+#
+# APP_VERSION (legado/deprecated — Sprint 2A.1 do platform-ops): mantido como
+# fallback de compatibilidade para o processo manual existente. Novos deploys
+# via platform-ops usam BACKEND_VERSION/FRONTEND_VERSION/CADDY_VERSION
+# independentes, que têm prioridade quando definidas. Remover APP_VERSION
+# somente após a primeira release GitOps oficial (1.0.0) estar validada em
+# produção — ver platform-ops/docs/release-management.md.
 # Sprint 11A.1: backend/frontend/postgres containers.
 ...
@@
   backend:
-    image: ${BACKEND_IMAGE:-ghcr.io/chicaomsc/contractor-platform-backend}:${APP_VERSION:-local}
+    image: ${BACKEND_IMAGE:-ghcr.io/chicaomsc/contractor-platform-backend}:${BACKEND_VERSION:-${APP_VERSION:-local}}
@@
   frontend:
-    image: ${FRONTEND_IMAGE:-ghcr.io/chicaomsc/contractor-platform-frontend}:${APP_VERSION:-local}
+    image: ${FRONTEND_IMAGE:-ghcr.io/chicaomsc/contractor-platform-frontend}:${FRONTEND_VERSION:-${APP_VERSION:-local}}
@@
   caddy:
-    image: ${CADDY_IMAGE:-ghcr.io/chicaomsc/contractor-platform-caddy}:${APP_VERSION:-local}
+    image: ${CADDY_IMAGE:-ghcr.io/chicaomsc/contractor-platform-caddy}:${CADDY_VERSION:-${APP_VERSION:-local}}
```

(O contexto exato de linhas/números pode variar da última leitura desta sprint — aplicar pelo
conteúdo, não por número de linha; os três `image:` são inequívocos dentro de cada bloco de
serviço.)

## Validação depois de aplicar (no repositório de aplicação, sem subir nada em produção)

```
cd infra/compose
docker compose -f docker-compose.prod.yml config | grep -A1 'backend:\|frontend:\|caddy:' | grep image
# sem nenhuma variável definida → deve mostrar ...:local (idêntico a antes)
APP_VERSION=teste123 docker compose -f docker-compose.prod.yml config | grep image
# → deve mostrar ...:teste123 nos três (idêntico a antes)
APP_VERSION=teste123 BACKEND_VERSION=novo456 docker compose -f docker-compose.prod.yml config | grep image
# → backend deve mostrar ...:novo456; frontend/caddy continuam ...:teste123
```

## Depois de aplicado e validado

1. Confirmar no `platform-ops`: `docs/deployment-flow.md` → remover este item da lista de
   "pré-condições ainda não confirmadas".
2. Só então um primeiro deploy real via `scripts/deploy.sh`/workflow passará a controlar
   `backend`/`frontend`/`caddy` de forma verdadeiramente independente.
3. `APP_VERSION` continua existindo em `production.env` e no compose até a remoção formal
   planejada (ver `docs/release-management.md` "Caminho exato para migrar Vantry...", passo 8).
