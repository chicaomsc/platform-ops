# Versioning — SemVer, proveniência e identidade de artefato

Documento conceitual introduzido na Sprint 1.1, complementar às ADRs. Explica os três conceitos
distintos que compõem uma release, como eles se relacionam, o contrato declarativo
(`release.yml`), e o caminho de migração a partir do modelo baseado em SHA da Sprint 1
(`versions.env`, ainda em uso por Vantry/Production).

## Os três conceitos

Antes da Sprint 1.1, o `platform-ops` usava o SHA de commit do repositório de aplicação
diretamente como "a versão" de cada componente. Isso confundia três coisas que são,
conceitualmente, distintas:

### 1. Release Version (SemVer)

A identidade do **produto/release**, do ponto de vista de quem opera e de quem consome (outro
time, um changelog, um operador disparando um deploy). Formato `MAJOR.MINOR.PATCH` (Semantic
Versioning — [semver.org](https://semver.org)):

- **MAJOR** — mudança incompatível ou grande quebra de contrato.
- **MINOR** — nova funcionalidade compatível.
- **PATCH** — correção compatível.

Não é incrementada automaticamente a cada deploy — é uma decisão humana, feita no momento de
cortar uma release. Um operador pensa "vou implantar a 1.2.0", não "vou implantar
`adbfe3d34...`".

### 2. Source Commit

O SHA de commit **completo** (40 caracteres hex) do repositório de aplicação
(`chicaomsc/contractor-plataform`) que originou a release. Responde "exatamente qual código-
fonte gerou isto" — proveniência, não identidade operacional. Uma release `1.2.0` tem exatamente
um `sourceCommit`.

### 3. Artifact Digest (OCI Digest)

O digest de conteúdo (`sha256:...`, 64 caracteres hex) de cada imagem Docker/OCI publicada.
Responde "exatamente qual artefato binário está rodando" — é a única das três identidades que é
criptograficamente verificável e genuinamente imutável (um digest é o hash do conteúdo; uma tag,
mesmo "imutável por política", é apenas um ponteiro que *poderia* ser reescrito no registry).

## Relação entre os três

```
Release (1.2.0)
   └── Source Commit (adbfe3d3451ed372bd55308bbe977dec2d83ed35)
          └── Docker Images (backend, frontend, caddy)
                 └── OCI Digests (sha256:..., um por imagem)
```

Uma release SemVer é uma **etiqueta humana** sobre um conjunto de artefatos imutáveis. O
`platform-ops` deve conseguir provar, a qualquer momento, que:

```
Vantry 1.2.0  =  commit adbfe3d3...  =  backend@sha256:A  =  frontend@sha256:B  =  caddy@sha256:C
```

Tag SemVer e SHA de commit são convenientes para humanos e para auditoria; o digest é o que
garante, tecnicamente, que o artefato implantado é exatamente o que foi declarado — não uma tag
com o mesmo nome apontando para outra coisa (seja por erro, seja por um registry comprometido).

## O contrato declarativo: `release.yml`

A partir da primeira release SemVer real, `apps/<app>/<env>/release.yml` passa a ser o estado
desejado (substituindo `versions.env` para esse app/ambiente — ver "Migração" abaixo). O schema
completo (formalizado como `platform-ops/v1` na Sprint 1.2), o detalhamento campo a campo, e a
política de depreciação de `versions.env` vivem em
[docs/release-management.md](release-management.md) — este documento foca nos conceitos
(SemVer/commit/digest); aquele, no contrato e no uso. Resumo do schema:

```yaml
apiVersion: platform-ops/v1
kind: Release
metadata:
  application: vantry
  environment: production
release:
  version: "1.2.0"
  sourceCommit: "<sha40>"
  createdAt: "<ISO8601>"
components:
  backend:
    image: ghcr.io/.../backend
    tag: "1.2.0"
    digest: "sha256:..."
  # frontend, caddy: mesma forma
```

Note que `image` é repetido por componente — decisão deliberada da Sprint 1.2 (ver
[ADR-007](../adr/ADR-007-artifact-provenance.md)): o manifest fica autocontido, sem exigir
cruzamento com `metadata.yml` para saber qual imagem foi implantada. `metadata.yml` continua
tendo `registry.images.*`, usado apenas quando o app está em modo legado (`versions.env`, que não
carrega `image`).

### Por que um arquivo dedicado, e não `versions.env` expandido

Decisão registrada e justificada na condução da Sprint 1.1 (ver relatório): o modelo é
genuinamente hierárquico (uma release → um commit → três componentes → tag+digest cada), o que
um arquivo YAML representa naturalmente e um arquivo flat `KEY=VALUE` representaria como oito
variáveis soltas sem relação explícita entre si. O custo de leitura via `yq` já existe (usado
para `metadata.yml` desde a Sprint 1); não é uma dependência nova.

### Imutabilidade aplicada tecnicamente (Sprint 1.2)

Além da verificação "ao vivo" (tag já em execução com digest diferente do declarado, Sprint 1.1),
a Sprint 1.2 adicionou verificação **histórica**: antes de qualquer SSH, o histórico de commits
do próprio `platform-ops` é consultado (`git log --follow` sobre `release.yml`) para garantir que
a versão declarada, se já vista antes, sempre apontou para o mesmo `sourceCommit` e os mesmos
digests. Ver [ADR-006](../adr/ADR-006-release-management.md) e
[ADR-007](../adr/ADR-007-artifact-provenance.md) para o detalhamento completo, e
[docs/release-management.md](release-management.md) para o comportamento operacional.

### Publicação das imagens

Cada release publica, para cada componente, duas tags apontando para o mesmo digest:

```
ghcr.io/chicaomsc/contractor-platform-backend:1.2.0            # tag de release, SemVer
ghcr.io/chicaomsc/contractor-platform-backend:sha-adbfe3d3...  # tag de rastreabilidade
```

A tag SemVer (`1.2.0`) é **imutável por política** — nunca sobrescrita. A tag `sha-<commit>` é
puramente informativa/de rastreabilidade (permite localizar a imagem a partir do commit, sem
precisar saber qual release SemVer o consumiu). `latest`/`main`/`stable` nunca são usadas em
produção — os scripts (`scripts/lib/common.sh`) recusam essas tags explicitamente.

## Verificação de digest em tempo de deploy

`scripts/deploy.sh` e `scripts/rollback.sh`, em modo `release`, verificam o digest de cada
imagem **depois do pull e antes do `up -d`**: comparam o digest realmente baixado
(`docker image inspect`) com o declarado em `release.yml`. Três resultados possíveis:

- **Confirmado** — segue para `up -d`.
- **Divergente** — aborta imediatamente, container não é tocado. Indica release.yml com digest
  errado, ou a tag foi sobrescrita no registry (violação de política) — nunca é silenciosamente
  ignorado.
- **Não verificável** (`RepoDigests` vazio) — segue com aviso explícito nos logs; não é tratado
  como erro (pode ocorrer em ambientes de teste/imagens locais), mas fica registrado.

Adicionalmente, antes mesmo de tentar o pull, os scripts recusam prosseguir se a tag declarada
já está em execução com um digest **diferente** do declarado agora — isso significaria que uma
release SemVer já publicada estaria sendo redeclarada com identidade diferente, o que nunca deve
acontecer silenciosamente (ver ADR-001 e ADR-003, seções atualizadas na Sprint 1.1).

## Rollback

Semanticamente, um operador pensa "reverter de 1.2.1 para 1.2.0". Tecnicamente,
`scripts/rollback.sh` reverte por **par tag+digest** sempre que o digest existe (contrato
`release.yml`) — nunca "a tag que hoje se chama 1.2.0", sempre "o artefato cujo digest era X
quando estava rodando". Dois modos:

- **Automático**, a partir de `deploy.sh`: usa o snapshot de tag+digest capturado (via `docker
  inspect`, direto do que estava de fato rodando) imediatamente antes do deploy que falhou.
- **Manual**: sem override, lê o mesmo snapshot; com override, exige a tag (sempre) e o digest
  (obrigatório em modo `release.yml`; opcional, com aviso, em modo `versions.env` legado — ver
  [deployment-flow.md § Rollback legado vs. rollback release](deployment-flow.md#rollback-legado-vs-rollback-release-temporário--sprint-2a3),
  Sprint 2A.3) — o operador busca o digest histórico no commit correspondente de `release.yml`
  (`git show <commit>:apps/<app>/<env>/release.yml`). Esta sprint não implementa lookup
  automático de release histórica por número de versão — ver "Extensões futuras" abaixo.

## Migração: do modelo legado ao novo contrato

```
Estado legado (Sprint 1)                Primeira release SemVer oficial       Novo contrato GitOps
─────────────────────────               ──────────────────────────────       ────────────────────
versions.env declara SHA de       ──▶    Time decide cortar a "1.0.0":  ──▶   release.yml passa a
commit por componente                    - build a partir de um commit        existir para o app/
(BACKEND_VERSION=<sha>, etc.)              específico                          ambiente; versions.env
                                          - publica backend/frontend/caddy     é removido POR PR
Nenhum digest declarado.                   com tag "1.0.0" (além da tag        humano, depois de
scripts/deploy.sh/healthcheck.sh/          sha-<commit>, mantida)              confirmado que não é
rollback.sh operam em "modo               - confirma no registry que as        mais necessário.
legado" (ver lib/common.sh                  3 imagens existem sob essa tag
load_release_state) — funcionando         - preenche release.yml com o       Scripts detectam
sem alteração.                              version/sourceCommit reais e      release.yml
                                             os digests reais publicados       automaticamente
                                                                               (prioridade sobre
                                                                               versions.env).
```

**Importante:** `apps/vantry/production/versions.env` **não foi alterado nem removido** na
Sprint 1.1. `release.yml` não foi criado para Vantry/Production nesta sprint — não existe hoje
nenhum artefato Vantry publicado sob uma tag SemVer real, e atribuir `1.0.0` ao SHA atualmente
em produção seria fabricar uma release que nunca foi de fato publicada sob essa identidade. A
migração real acontece quando a primeira release `1.0.0` for cortada e publicada de verdade —
nesse momento, `apps/vantry/production/release.yml` é criado com os valores reais confirmados
(nunca antes disso), e um PR subsequente remove `versions.env`.

## Recomendação futura: metadados de versão expostos pela aplicação

Fora do escopo de implementação desta sprint (nenhuma mudança em código de aplicação foi feita
ou é proposta aqui) — registrado como recomendação para quando fizer sentido priorizar: o
backend poderia expor, no mesmo endpoint de health ou em um endpoint próprio, algo como

```json
{ "version": "1.2.0", "commit": "adbfe3d3451ed372bd55308bbe977dec2d83ed35", "buildTime": "..." }
```

Isso permitiria a `scripts/healthcheck.sh` confirmar, na própria aplicação em runtime, que a
release declarada é a que está de fato respondendo — uma camada adicional de verificação além do
digest da imagem (que confirma o artefato, não necessariamente que o processo em execução dentro
dele está servindo a versão esperada). Não implementado nesta sprint.

## Extensões futuras (fora de escopo agora)

- Suporte a pré-release/build metadata SemVer (`1.2.0-rc.1`, `1.2.0+build.5`) — hoje `validate_semver`
  em `scripts/lib/common.sh` aceita apenas `MAJOR.MINOR.PATCH` numérico puro. Ver "Política de
  pré-release" em [ADR-006](../adr/ADR-006-release-management.md).
- Lookup automático de digest histórico por número de release (hoje exige localizar manualmente
  no histórico de commits de `release.yml`).
- Registro/índice de releases publicadas, para permitir `rollback --to-release X` sem exigir os
  digests explícitos.
- Roadmap de supply chain (SBOM, Cosign, SLSA provenance, vulnerability scanning, attestations) —
  ver [ADR-007](../adr/ADR-007-artifact-provenance.md), seção dedicada.
- Automação de geração de `release.yml` e publicação de GitHub Release a partir do repositório de
  aplicação — contrato pronto ([docs/release-management.md](release-management.md)), automação
  não implementada.
