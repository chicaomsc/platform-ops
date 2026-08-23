# Release Management — guia operacional

Guia de **uso** do sistema de release, complementar a [ADR-006](../adr/ADR-006-release-management.md)
(por que) e [ADR-007](../adr/ADR-007-artifact-provenance.md) (proveniência/integridade). Para os
conceitos de SemVer/commit/digest em si, ver [docs/versioning.md](versioning.md) — este documento
assume essa leitura.

## Contrato oficial: `release.yml`

**Convenção de nome escolhida para todo o `platform-ops`: `release.yml` (não `.yaml`)** —
consistente com `metadata.yml` e `servers/*.yml`, já estabelecidos desde a Sprint 0. Nenhum outro
nome de arquivo é usado para este propósito em nenhum app.

### Schema (`apiVersion: platform-ops/v1`)

```yaml
apiVersion: platform-ops/v1
kind: Release

metadata:
  application: <nome-do-app>       # deve bater com o diretório apps/<app>/
  environment: <ambiente>           # deve bater com o diretório .../<ambiente>/

release:
  version: "<MAJOR.MINOR.PATCH>"    # SemVer, imutável (ver ADR-006)
  sourceCommit: "<sha40>"           # SHA completo do commit que originou a release
  createdAt: "<ISO8601>"            # ex.: 2026-08-23T14:00:00Z

components:
  backend:
    image: <registry>/<repo>          # caminho completo, sem tag
    tag: "<MAJOR.MINOR.PATCH>"        # normalmente igual a release.version
    digest: "sha256:<64 hex>"
  frontend:
    image: ...
    tag: ...
    digest: ...
  caddy:
    image: ...
    tag: ...
    digest: ...
```

Todos os campos são obrigatórios — nenhum tem valor default. `scripts/lib/common.sh` valida:
formato de `apiVersion`/`kind` (exatos), `metadata.application`/`metadata.environment` (batem com
o app/ambiente solicitado na linha de comando), `release.version`/`components.*.tag` (SemVer),
`release.sourceCommit` (SHA40), `release.createdAt` (ISO8601), `components.*.digest`
(`sha256:<64 hex>`), ausência de tags móveis (`latest`/`main`/`stable`), e **imutabilidade
histórica** (ver abaixo).

### Por que `image` é repetido em cada componente

`metadata.yml` também tem `registry.images.*` com os mesmos caminhos. Isso é duplicação
deliberada (ver [ADR-007](../adr/ADR-007-artifact-provenance.md)): `release.yml` fica
autocontido — alguém lendo só esse arquivo (ex.: gerando uma GitHub Release, ou auditando depois)
não precisa cruzar com `metadata.yml` para saber exatamente qual imagem foi implantada. Em modo
`release`, os scripts usam o `image` do manifest, não voltam a consultar `metadata.yml`.

## Imutabilidade — como é aplicada

`validate_release_immutability` (`scripts/lib/common.sh`) roda a cada `deploy.sh`/`rollback.sh`,
**antes de qualquer SSH**: procura, no histórico de commits do `platform-ops`
(`git log --follow -- release.yml`), toda declaração anterior da mesma `release.version`. Se
encontrar uma com `sourceCommit` ou algum digest diferente do que está sendo declarado agora,
recusa com uma mensagem explícita — a correção correta é usar a próxima versão (ex.: `1.2.1`),
nunca redeclarar `1.2.0`. Uma redeclaração idêntica (mesmos valores, ex.: um commit que só
reformata o arquivo) não é bloqueada.

## Política de depreciação — `versions.env`

| | |
|---|---|
| **Arquivo** | `apps/<app>/<env>/versions.env` |
| **Status** | **DEPRECATED** |
| **Permitido para** | Apenas `vantry` (allowlist técnica em `scripts/lib/common.sh`, `_LEGACY_ALLOWED_APPS`), durante a migração |
| **Proibido para** | Qualquer app novo — bloqueado tecnicamente, não apenas por convenção: `load_release_state` recusa (`exit 11`) se um app fora da allowlist tentar usar `versions.env` |
| **Remoção** | Do código de suporte legado: em sprint própria, após a primeira release oficial de Vantry estar validada em produção sob `release.yml`. Do arquivo em si (`apps/vantry/production/versions.env`): por PR, assim que `release.yml` for criado para Vantry/Production e confirmado funcionando (ver "Caminho para a primeira release 1.0.0" abaixo) |
| **Coexistência** | Nunca definitiva — só durante a migração de um app específico. Se `release.yml` e `versions.env` existirem juntos para o mesmo app/ambiente, `release.yml` vence e um aviso é emitido pedindo a remoção do legado |

Não há suporte eterno a dois contratos — a coexistência é uma ponte, não um destino.

## Estratégia GitHub Release (contrato/documentação — não implementado)

Quando a automação de publicação existir (fora do escopo desta sprint), cada release deve gerar
uma GitHub Release no repositório de aplicação contendo:

- Versão (título: `vMAJOR.MINOR.PATCH`)
- Release notes (ver template abaixo)
- Source commit (link direto para o commit)
- Imagens publicadas (link/referência para cada uma: backend, frontend, caddy)
- Digests de cada imagem
- Link para o changelog (comparação com a release anterior)
- Data de publicação
- Autor/pipeline que gerou a release (humano que cortou a release, ou identificação do workflow de CI)

Nada disso é publicado automaticamente nesta sprint — nenhuma GitHub Release real foi criada.

## Release notes — template

Ver [templates/release-notes.md](../templates/release-notes.md) para o arquivo completo,
genérico (sem valores de Vantry). Seções vazias não são obrigatórias na versão final — omitir
uma seção sem conteúdo, não deixá-la em branco:

```markdown
# <App> <MAJOR.MINOR.PATCH>

## Added
## Changed
## Fixed
## Security
## Infrastructure
## Known Issues

## Artifact Provenance

Backend:
- tag:
- digest:

Frontend:
- tag:
- digest:

Caddy:
- tag:
- digest:

Source Commit:
```

## Processo futuro de geração do manifest (contrato pronto, automação não implementada)

```
Application Repo
    │  build
    ▼
publish images (tag SemVer + tag sha-<commit>)
    │
    ▼
resolve digests (consultar o registry — nunca calcular localmente e assumir)
    │
    ▼
gerar release.yml (schema platform-ops/v1 — este documento)
    │
    ▼
GitHub Release (título + notas + manifest anexado/linkado)
    │
    ▼
PR no platform-ops (declarar a release para um ambiente)
```

O contrato (`release.yml`) já está pronto para essa automação consumir — nenhuma automação de
PR entre repositórios é criada nesta sprint (não objetivo explícito).

## Deploy por digest

Ver [ADR-007](../adr/ADR-007-artifact-provenance.md) "Deploy por digest". Resumo: os scripts já
exportam `BACKEND_DIGEST_REF`/`FRONTEND_DIGEST_REF`/`CADDY_DIGEST_REF`
(`<imagem>@sha256:...`) de forma aditiva ao lado das variáveis de tag; nenhum
`docker-compose.prod.yml` conhecido as referencia hoje, então o deploy real continua por tag. A
migração do compose file para consumir essas variáveis é um passo futuro, não forçado nesta
sprint por depender de um arquivo fora deste repositório e não confirmado.

## Caminho exato para migrar Vantry para a primeira release oficial `1.0.0`

**Atualizado pela auditoria da Sprint 2A / correções da Sprint 2A.1.** A auditoria confirmou, com
acesso real e somente-leitura à VPS de produção, que as imagens `backend`/`frontend`/`caddy`
atualmente em execução **não têm `RepoDigests`** — ou seja, não existe hoje nenhum digest OCI
verificável para o estado legado em produção. Isso é tratado como **`legacy / provenance
unavailable`** (ver `apps/vantry/production/versions.env`), nunca como a release `1.0.0` — o
digest de uma release oficial deve ser **produzido no pipeline de build/publicação e consumido**
pelo `platform-ops`, nunca descoberto retrospectivamente por inspeção da VPS (ver
[ADR-007](../adr/ADR-007-artifact-provenance.md)). Isso também confirmou que
`docker-compose.prod.yml` real usa `${APP_VERSION}` único — ver o patch necessário no repositório
de aplicação antes do passo 2 abaixo.

0. **Pré-requisito — aplicar o patch de compatibilidade no repositório de aplicação**
   (`chicaomsc/contractor-plataform`): ver runbook
   [apply-app-repo-compose-patch.md](runbooks/apply-app-repo-compose-patch.md). Sem isso, um
   deploy real via `platform-ops` publicaria/executaria a tag `local`, não a versão pretendida.
1. **Confirmar o estado real em produção** — já feito na Sprint 2A (ver nota acima e
   `docs/runbooks/verify-current-production-state.md`).
2. **No repositório de aplicação**: escolher o commit exato para a release `1.0.0` (pode ser o
   mesmo `adbfe3d3451ed372bd55308bbe977dec2d83ed35` já confirmado em execução, ou um commit mais
   novo), criar a tag `v1.0.0`, publicar as três imagens (`backend`, `frontend`, `caddy`) com tag
   `1.0.0` **e** `sha-<commit>` via um pull real do GHCR (o que popula `RepoDigests`
   automaticamente), confirmar no registry os digests reais publicados — **nunca calculados ou
   inferidos localmente**.
3. **Criar `apps/vantry/production/release.yml`** (schema acima) com os valores reais
   confirmados no passo 2. Se o valor de tag/digest não puder ser obtido do registry, **não
   publicar a release** — registrar como bloqueio, não como `UNKNOWN` aceito.
4. **PR único**: adiciona `release.yml`, mantém `versions.env` intacto (não remover ainda —
   `deploy.sh` prefere `release.yml` automaticamente).
5. **Rodar `scripts/deploy.sh --app vantry --env production`** (via workflow) — se
   `release.version` bater com o que já está em execução, o deploy é idempotente e apenas
   confirma; se for uma versão nova, segue o fluxo normal de deploy com verificação de digest.
6. **Validar** healthcheck e o resultado end-to-end (ver
   `docs/runbooks/sprint1-validation-checklist.md`).
7. **Só depois de validado em produção**, abrir um segundo PR removendo
   `apps/vantry/production/versions.env`.
8. **Em sprint própria**, remover o suporte de código legado (`_LEGACY_ALLOWED_APPS`, o branch
   `elif` de `versions.env` em `load_release_state`) — não antes de nenhum app depender dele.

Nenhum passo deste caminho foi executado nesta sprint — documentado, não realizado. Ver relatório
da Sprint 2A.1 para o veredito explícito READY/NOT READY.
