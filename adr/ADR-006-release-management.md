# ADR-006 — Release Management

## Status

Aceito — 2026-08-23

Depende de: [ADR-001](./ADR-001-gitops-strategy.md), [ADR-002](./ADR-002-deployment-pipeline.md), [ADR-003](./ADR-003-rollback-strategy.md) (seções "Atualização Sprint 1.1")

Relacionada: [ADR-007 — Artifact Provenance](./ADR-007-artifact-provenance.md)

## Contexto

As ADRs 001–003, refinadas na Sprint 1.1, estabeleceram que "versão" é composta por três identidades — SemVer, Source Commit, Artifact Digest (ver [docs/versioning.md](../docs/versioning.md)). O que faltava formalizar é o conceito de **release** em si: o que é, quem a cria, quando ela nasce, o que a torna imutável, e como ela se relaciona com promoção (ADR-005) e rollback (ADR-003). Esta ADR fecha essa lacuna.

## Propósito de uma release

Uma release é a unidade atômica de "o que pode ser implantado". Ela amarra, sob um único identificador humano (SemVer), um conjunto específico e imutável de artefatos (uma imagem OCI por componente) construídos a partir de um único commit de código-fonte. Uma release é o que um operador promove entre ambientes (ADR-005) e o que um rollback reverte para (ADR-003) — nunca um SHA solto, nunca uma tag `latest`.

Uma release **não é** um deploy. Uma release pode ser publicada e nunca implantada em nenhum ambiente; um deploy é a ação de convergir a infraestrutura de um ambiente específico para uma release específica (ADR-002).

## Semantic Versioning

Adotado integralmente ([semver.org](https://semver.org)), formato `MAJOR.MINOR.PATCH`, sem pré-release/build metadata nesta fase (ver "Política de pré-release" abaixo).

### Critérios para MAJOR

Incrementar MAJOR quando a release introduz uma mudança que quebra compatibilidade do ponto de vista de quem opera ou integra com o sistema — exemplos: mudança de schema de dados sem migração compatível para trás (quebra rollback seguro — ver ADR-003), remoção ou mudança de contrato de uma API pública, mudança que exige intervenção manual coordenada além do deploy em si. Reseta MINOR e PATCH para 0.

### Critérios para MINOR

Incrementar MINOR quando a release adiciona funcionalidade de forma compatível com versões anteriores — o sistema continua funcionando exatamente como antes para quem não usa a funcionalidade nova, e rollback para a MINOR anterior continua seguro. Reseta PATCH para 0.

### Critérios para PATCH

Incrementar PATCH para correções compatíveis — bugs, patches de segurança, ajustes de infraestrutura/observabilidade que não alteram contrato nem adicionam funcionalidade. É o incremento mais frequente e mais barato de reverter.

### Quem decide

A decisão de qual nível incrementar é humana, tomada no momento de cortar a release, por quem tem contexto do conjunto de mudanças incluído — tipicamente o time do repositório de aplicação. Esta ADR não prescreve um processo automatizado de inferência de MAJOR/MINOR/PATCH a partir de commits (ex.: Conventional Commits) — pode ser adotado no futuro como ferramenta de apoio, mas a decisão final permanece humana nesta fase.

## Git tags

Cada release corresponde a uma tag Git no repositório de aplicação, no formato `vMAJOR.MINOR.PATCH` (ex.: `v1.2.0`), apontando exatamente para o `sourceCommit` declarado na release. A tag é o mecanismo padrão do Git para dar nome permanente a um commit — reaproveitado aqui em vez de inventar um mecanismo próprio. Tags de release nunca são movidas nem recriadas apontando para outro commit.

## GitHub Releases

Formalizado como contrato (não implementado como automação nesta sprint — ver [docs/release-management.md](../docs/release-management.md) "Estratégia GitHub Release" para o template e o processo futuro). Uma GitHub Release é a face pública/auditável de uma release: título, notas, e os artefatos publicados, tudo em um único lugar referenciável por humanos e por ferramentas externas.

## Release notes

Template formal em [docs/release-management.md](../docs/release-management.md) — inclui proveniência de artefato (tag+digest por componente) como seção obrigatória, não apenas texto livre de mudanças.

## Release lifecycle

```
1. Desenvolvimento no repositório de aplicação (commits em branches/PRs normais)
        │
2. Decisão de cortar uma release: escolhido um commit, decidido o nível SemVer
        │
3. Build a partir desse commit exato (Pipeline 1 — ADR-002)
        │
4. Publicação das imagens OCI (uma por componente), com duas tags cada:
   a versão SemVer (ex.: 1.2.0) e a tag de rastreabilidade (sha-<commit>)
        │
5. Resolução dos digests reais publicados (o registry é a fonte da verdade
   do digest — nunca calculado localmente e assumido)
        │
6. Geração do Release Manifest (release.yml) com version, sourceCommit,
   createdAt e tag+digest por componente — ver ADR-007
        │
7. Publicação da GitHub Release (título, notas, manifest anexado/linkado)
        │
8. PR no platform-ops declarando a release para um ambiente (hoje: manual;
   ver "Responsabilidade de criação" abaixo)
        │
9. A partir daqui, a release é IMUTÁVEL — nenhum passo anterior é repetido
   para essa mesma versão. Uma correção é uma NOVA release (PATCH).
```

Não há, nesta fase, um estado formal de "rascunho"/"draft" de release dentro do `platform-ops` — uma release só existe, do ponto de vista desta plataforma, quando aparece como PR válido de `release.yml`. Estados de rascunho (ex.: GitHub Release marcada como draft antes de finalizada) são internos ao processo do repositório de aplicação, fora do escopo desta ADR.

## Política de pré-release (futura, não implementada)

SemVer prevê sufixos de pré-release (`1.2.0-rc.1`) e build metadata (`1.2.0+build.5`). **Não suportados nesta sprint** — `validate_semver` em `scripts/lib/common.sh` aceita apenas `MAJOR.MINOR.PATCH` numérico puro. Quando adotado no futuro, pré-releases deverão: (a) nunca ser promovidas automaticamente para Production (ADR-005), (b) ser tratadas como imutáveis da mesma forma que uma release final, (c) ter uma convenção clara de quando um `-rc.N` "vira" a release final (mesmos artefatos exatos, apenas sem o sufixo, ou uma nova release?). Decisão adiada — registrar aqui como reconhecidamente pendente, não como decidida.

## Imutabilidade de releases

**Uma release publicada é imutável.** `1.2.0`, uma vez existente, aponta para sempre para o mesmo `sourceCommit` e os mesmos digests de artefato. Se um problema é encontrado, a correção é uma nova release (`1.2.1`), nunca uma reescrita de `1.2.0`.

Esta é a decisão mais importante desta ADR e é **tecnicamente aplicada**, não apenas documentada: `scripts/lib/common.sh` (`validate_release_immutability`) verifica, contra o histórico de commits do próprio `platform-ops`, que qualquer redeclaração de uma versão já vista antes tem exatamente o mesmo `sourceCommit` e os mesmos digests — caso contrário, o deploy é recusado antes de qualquer conexão com a VPS (ver [ADR-007](./ADR-007-artifact-provenance.md) para o detalhamento técnico).

## Relação entre release e source commit

Uma release tem exatamente um `sourceCommit`. Múltiplos componentes (backend/frontend/caddy) de uma mesma release, hoje, são tipicamente construídos a partir do mesmo commit (repositório monolítico da aplicação) — mas o modelo não impede, estruturalmente, que um componente seja versionado a partir de um commit diferente no futuro (ex.: se os componentes migrarem para repositórios separados). Se isso acontecer, esta ADR deve ser revisada para decidir se `sourceCommit` passa a ser por componente ou se o conceito de "release" muda.

## Relação entre release e artefatos OCI

Cada componente de uma release aponta para exatamente uma imagem OCI, identificada por tag (SemVer, para humanos) e digest (para verificação técnica) — ver [ADR-007](./ADR-007-artifact-provenance.md).

## Relação entre Application Repo e Platform Ops

Reafirma a fronteira da [ADR-001](./ADR-001-gitops-strategy.md), aplicada especificamente ao ciclo de vida de release:

| Etapa do lifecycle (ver acima) | Responsável |
|---|---|
| 1–7 (build, publish, resolve digest, gerar manifest, GitHub Release) | Repositório de aplicação |
| 8 (declarar a release como estado desejado de um ambiente, via PR) | `platform-ops` |
| Aprovação do PR de declaração | Conforme critério do ambiente-alvo (ADR-005) |
| Execução do deploy | `platform-ops` (ADR-002) |

O repositório de aplicação **produz** releases; o `platform-ops` **declara e implanta** releases. Uma release pode existir (estar publicada, com GitHub Release e imagens no registry) sem nunca ter sido declarada em nenhum ambiente do `platform-ops` — isso é normal, não um erro.

## Responsabilidade de criação de release

Do time/processo do repositório de aplicação — decide o commit, o nível SemVer, corta a tag, builda, publica. O `platform-ops` não participa dessa decisão nem a valida além de checar formato (SemVer válido, SHA válido, digest válido) e imutabilidade histórica.

## Responsabilidade de promoção

Inalterada da [ADR-005](./ADR-005-environment-promotion.md) — quem promove, quando e com qual critério por ambiente. O objeto promovido passa a ser, quando o app migrou, a release inteira (identificada pela versão SemVer) em vez de um SHA solto — mas o processo de aprovação por ambiente não muda.

## Política de rollback

Inalterada da [ADR-003](./ADR-003-rollback-strategy.md) (e sua atualização na Sprint 1.1). Reforço específico desta ADR: como releases são imutáveis, rollback para uma release anterior é sempre seguro do ponto de vista de "para onde estou voltando" — a única pergunta é se o artefato ainda está disponível no registry (não coberto por esta ADR — política de retenção de imagens é decisão de infraestrutura, fora de escopo).

## Releases independentes por SaaS

Cada produto (`apps/<produto>/`) tem sua própria sequência de versões SemVer, sem relação ou sincronização com a numeração de outros produtos. `vantry` estar em `1.4.0` não implica nada sobre a versão de `acadflow`. Isso é uma consequência direta da estrutura `apps/<produto>/<ambiente>/` já estabelecida na [ADR-001](./ADR-001-gitops-strategy.md) — nenhuma mudança estrutural necessária.

## Múltiplos componentes dentro da mesma release

Uma release (`release.version`) é a identidade umbrella; cada componente (`backend`, `frontend`, `caddy`) tem sua própria tag e digest declarados independentemente dentro do manifest (ver [ADR-007](./ADR-007-artifact-provenance.md) para o schema). Na prática, para o repositório monolítico atual, os três componentes de uma release compartilham o mesmo valor de tag (todos publicados como `1.2.0` a partir do mesmo commit) — mas o schema não força essa igualdade estruturalmente, permitindo que, se os componentes um dia forem versionados de forma independente (ex.: um hotfix de infraestrutura só no Caddy), isso seja representável sem redesenhar o contrato.

## Motivação

Sem uma ADR dedicada a release, a decisão de "o que uma release é" ficaria implícita e potencialmente inconsistente entre as ADRs 001–003 e a implementação. Formalizar aqui — incluindo os critérios de MAJOR/MINOR/PATCH, o lifecycle completo, e a fronteira de responsabilidade — dá a qualquer pessoa (ou a um futuro processo de automação de PR entre repositórios) uma referência única e não ambígua.

## Benefícios

- Elimina ambiguidade sobre "quando uma versão pode mudar" — resposta objetiva: nunca, depois de publicada.
- Critérios de MAJOR/MINOR/PATCH dão previsibilidade a quem promove (ADR-005) sobre o risco esperado de uma promoção.
- A fronteira Application Repo / Platform Ops, já estabelecida na ADR-001, é reafirmada especificamente para o fluxo de release, reduzindo o risco de o processo de automação futura (App Repo → PR automático) ser desenhado de forma inconsistente com a arquitetura existente.

## Limitações

- Critérios de MAJOR/MINOR/PATCH continuam dependendo de julgamento humano — esta ADR não elimina o risco de um MINOR ser, na prática, incompatível por erro humano.
- Pré-release/build metadata SemVer não são suportados — releases candidatas a produção não têm, hoje, um caminho formal de validação incremental antes de virarem a versão final (mitigado, em parte, pelo funil Development → Staging → Production da ADR-005, que continua se aplicando a qualquer release, final ou não).
- Nenhuma automação de geração de release existe ainda (build → manifest → GitHub Release) — esta ADR formaliza o contrato, não a ferramenta.

## Consequências

- Todo app que nasce a partir de agora usa `release.yml` desde o primeiro dia — nunca `versions.env` (ver [docs/release-management.md](../docs/release-management.md) "Política de Depreciação").
- `scripts/lib/common.sh` aplica tecnicamente a imutabilidade — qualquer violação bloqueia o deploy antes de qualquer conexão SSH.
- Templates (`templates/app/release.yml`, `templates/release-notes.md`) tornam o onboarding de um novo produto mecânico, consistente com o objetivo de escalabilidade da ADR-001.

## Alternativas consideradas

1. **Sem conceito formal de "release"** — continuar tratando cada deploy como uma declaração solta de SHA/tag/digest, sem uma identidade umbrella.
2. **Release como conceito auto-gerado por CI a cada merge** (toda merge na branch principal gera automaticamente uma nova PATCH release).
3. **Versionamento por data** (ex.: `2026.08.23`) em vez de SemVer.

## Alternativas rejeitadas

1. **Sem conceito formal de release** — rejeitado porque é exatamente o estado da Sprint 1.1: três identidades relacionadas mas sem uma unidade atômica clara de "o que é promovido/revertido". Isso já se mostrou insuficiente para responder perguntas como "essa mudança é um MAJOR ou um PATCH?" de forma consistente.

2. **Release automática a cada merge** — rejeitado porque elimina a decisão humana de nível SemVer (MAJOR/MINOR/PATCH), que carrega informação real sobre risco e compatibilidade; gerar uma release a cada merge também infla o número de releases publicadas sem benefício correspondente (a maioria dos merges não é, por si, uma unidade de mudança que faz sentido promover isoladamente).

3. **Versionamento por data** — rejeitado porque não comunica compatibilidade/risco (a informação central que MAJOR/MINOR/PATCH carrega) e não é o padrão do ecossistema de imagens de contêiner com o qual este pipeline já interage (tags de imagem, GitHub Releases — todos o ecossistema já assume SemVer como convenção).

## Referências cruzadas

- [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)
- [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)
- [ADR-003 — Rollback Strategy](./ADR-003-rollback-strategy.md)
- [ADR-005 — Environment Promotion](./ADR-005-environment-promotion.md)
- [ADR-007 — Artifact Provenance](./ADR-007-artifact-provenance.md)
- [docs/release-management.md](../docs/release-management.md)
- [docs/versioning.md](../docs/versioning.md)
