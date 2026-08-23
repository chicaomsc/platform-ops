# platform-ops

Plataforma operacional da empresa. Este repositório **não é uma aplicação** — não contém código de produto, testes de produto ou lógica de negócio. Ele centraliza, para todos os SaaS operados pela empresa, tudo que é comum à operação:

- GitOps (estado desejado como fonte única da verdade)
- Deploy e promoção entre ambientes
- Estratégia de rollback
- Gestão de versões
- Ambientes e servidores
- Observabilidade
- Runbooks operacionais
- Templates de onboarding
- Automações de esteira

Serve todos os produtos da empresa — Vantry, AcadFlow, StratoSage e produtos futuros — sob a mesma arquitetura e o mesmo processo. Nada aqui é específico de um único produto.

## Princípio central

> O repositório de cada aplicação é dono do **código**. O `platform-ops` é dono do **estado desejado**. Deploy é a convergência automática do estado real da infraestrutura para o estado declarado neste repositório — nunca uma ação manual em servidor.

Detalhes completos em [`docs/architecture.md`](docs/architecture.md) e na [ADR-001](adr/ADR-001-gitops-strategy.md).

## Onde encontrar o quê

| Preciso de... | Vá para |
|---|---|
| Entender uma decisão arquitetural e por que foi tomada | [`adr/`](adr/) |
| Visão geral consolidada da arquitetura, diagrama e estrutura | [`docs/architecture.md`](docs/architecture.md) |
| Entender SemVer, proveniência e digest OCI | [`docs/versioning.md`](docs/versioning.md) |
| Contrato oficial de release, política de depreciação, GitHub Release, release notes | [`docs/release-management.md`](docs/release-management.md) |
| Saber qual versão está implantada em qual ambiente de qual produto | `apps/<produto>/<ambiente>/release.yml` (oficial) ou `versions.env` (legado/deprecated, só Vantry) |
| Metadados de configuração (não sensível) de um ambiente | `apps/<produto>/<ambiente>/metadata.yml` |
| Inventário de servidores | [`servers/`](servers/) |
| Procedimento para um cenário operacional específico | `docs/runbooks/` |
| Template para adicionar um novo produto (nasce em `release.yml`) | [`templates/app/release.yml`](templates/app/release.yml) |
| Template de release notes | [`templates/release-notes.md`](templates/release-notes.md) |
| Automações de esteira (CI/CD da própria plataforma) | `.github/workflows/` |

## Decisões arquiteturais (ADRs)

| ADR | Título | Resumo |
|---|---|---|
| [ADR-001](adr/ADR-001-gitops-strategy.md) | GitOps Strategy | Git como fonte única da verdade do estado desejado; fronteira entre repositório de aplicação e `platform-ops` |
| [ADR-002](adr/ADR-002-deployment-pipeline.md) | Deployment Pipeline | Esteira completa: CI da aplicação → publicação de imagem → CD/GitOps do `platform-ops` |
| [ADR-003](adr/ADR-003-rollback-strategy.md) | Rollback Strategy | Rollback automático (health check) e manual; critérios e mecânica |
| [ADR-004](adr/ADR-004-secrets-management.md) | Secrets Management | O que pode e o que nunca pode estar em Git; tratamento por tipo de segredo |
| [ADR-005](adr/ADR-005-environment-promotion.md) | Environment Promotion | Fluxo Development → Staging → Production: quem promove, quando e com qual critério |
| [ADR-006](adr/ADR-006-release-management.md) | Release Management | O que é uma release, SemVer, lifecycle, imutabilidade, fronteira Application Repo / Platform Ops |
| [ADR-007](adr/ADR-007-artifact-provenance.md) | Artifact Provenance | Tag vs. commit vs. digest; verificação técnica de integridade e imutabilidade; roadmap de supply chain |

ADR-001, ADR-002 e ADR-003 têm uma seção "Atualização (Sprint 1.1)" registrando a evolução do
conceito de versão (SemVer/commit/digest) — ver [`docs/versioning.md`](docs/versioning.md) e
[`docs/release-management.md`](docs/release-management.md) para o detalhamento completo.

## Estrutura do repositório

```
platform-ops/
├── adr/          # Decisões arquiteturais (o "porquê")
├── apps/         # Estado desejado por produto e ambiente (a fonte da verdade operacional)
├── docs/         # Documentação operacional consolidada (o "como")
├── scripts/      # Automações de suporte
├── servers/      # Inventário de infraestrutura
├── templates/    # Scaffolding padronizado para onboarding de novos produtos/workflows
└── .github/      # CI/CD da própria plataforma
```

Detalhamento completo de cada diretório em [`docs/architecture.md`](docs/architecture.md#estrutura-de-repositório).

## Status atual

- **Sprint 0** — arquitetura e documentação definidas (ADRs 001–005, `docs/architecture.md`).
- **Sprint 1** — fundação executável do GitOps validada com Vantry como piloto: estado
  declarativo real (`apps/vantry/production/`), inventário de servidor
  (`servers/hetzner-prod-01.yml`), scripts de deploy/healthcheck/rollback
  (`scripts/`) e o primeiro workflow real, manual (`.github/workflows/deploy-production.yml`).
  Ainda **não validado contra a VPS real** — ver
  [docs/runbooks/sprint1-validation-checklist.md](docs/runbooks/sprint1-validation-checklist.md)
  e o relatório da Sprint 1. Criação automática de PR a partir do repositório da aplicação e
  promoção automática entre ambientes permanecem fora do escopo.
- **Sprint 1.1** — refinamento de versionamento: SemVer + source commit + digest OCI como três
  identidades distintas (ver [`docs/versioning.md`](docs/versioning.md)), novo contrato
  declarativo `release.yml` (coexistindo com `versions.env`), verificação de digest em tempo de
  deploy/rollback. Vantry/Production **permanece no contrato legado** — nenhuma release SemVer
  real foi publicada ainda. ADR-001/002/003 atualizadas como evolução (não reescritas). Nenhum
  deploy real, criação de release no GitHub ou publicação de imagem foi feita nesta sprint.
- **Sprint 1.2** — Release Management & Artifact Provenance: ADR-006 e ADR-007 (ver
  [`docs/release-management.md`](docs/release-management.md)), schema oficial `release.yml`
  (`apiVersion: platform-ops/v1`, incluindo `image`/`createdAt`), política de depreciação formal
  e tecnicamente aplicada para `versions.env` (allowlist restrita a Vantry), verificação de
  **imutabilidade histórica** via `git log` (uma release já publicada nunca pode mudar de
  `sourceCommit` ou digest), preparação aditiva para deploy por digest
  (`*_DIGEST_REF`), templates genéricos (`templates/app/release.yml`,
  `templates/release-notes.md`). Vantry/Production **continua no contrato legado** — nenhuma
  release real foi publicada, nenhum deploy real ou GitHub Release foi feito.
