# Architecture — Platform Ops

## Visão geral

O `platform-ops` é a plataforma operacional compartilhada da empresa. Ele não contém código de produto: centraliza GitOps, deploy, promoção entre ambientes, rollback, gestão de versões, inventário de ambientes e servidores, observabilidade, runbooks, templates e automações, para **todos** os SaaS operados pela empresa (Vantry, AcadFlow, StratoSage e produtos futuros).

A decisão arquitetural fundamental é: **Git é a única fonte da verdade do estado desejado de toda a infraestrutura operacional.** Este documento descreve como essa decisão se materializa em componentes, fluxos e estrutura de repositório. As justificativas detalhadas de cada decisão — motivação, alternativas rejeitadas, trade-offs — vivem nas ADRs correspondentes, referenciadas ao longo deste documento. Este documento é a visão consolidada; as ADRs são a fonte de verdade de *por que* cada decisão foi tomada.

## Princípio arquitetural central

> O repositório de aplicação é dono do **código**. O `platform-ops` é dono do **estado desejado**. Nenhum dos dois lados conhece os detalhes internos do outro além do contrato explícito entre eles: uma imagem de artefato versionada e imutável.

Esse princípio, formalizado na [ADR-001](../adr/ADR-001-gitops-strategy.md), é o que garante que a plataforma sirva qualquer número de produtos sem crescer em complexidade proporcional ao número de produtos.

## Diagrama de componentes

```
                                   ORGANIZAÇÃO
        ┌──────────────────────────────────────────────────────────────┐
        │                                                                │
        │   Repositórios de Aplicação (um por SaaS)                     │
        │   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌───────────┐  │
        │   │  Vantry   │   │ AcadFlow  │   │StratoSage │   │  futuro   │  │
        │   │  (código, │   │  (código, │   │  (código, │   │  produto  │  │
        │   │  testes,  │   │  testes,  │   │  testes,  │   │    N      │  │
        │   │  build,   │   │  build,   │   │  build,   │   │           │  │
        │   │  imagem)  │   │  imagem)  │   │  imagem)  │   │           │  │
        │   └────┬─────┘   └────┬─────┘   └────┬─────┘   └─────┬─────┘  │
        │        │              │              │                │        │
        │        └──────────────┴──────┬───────┴────────────────┘        │
        │                               │ imagens versionadas             │
        │                               │ (registry)                     │
        │                               ▼                                │
        │                 ┌─────────────────────────────┐                │
        │                 │        platform-ops            │                │
        │                 │  (este repositório — único)    │                │
        │                 ├─────────────────────────────┤                │
        │                 │  adr/        decisões           │                │
        │                 │  apps/       estado desejado     │                │
        │                 │              por produto/ambiente│                │
        │                 │  servers/    inventário de infra │                │
        │                 │  docs/       documentação          │                │
        │                 │              operacional            │                │
        │                 │  templates/  onboarding padronizado │                │
        │                 │  .github/    automação da esteira   │                │
        │                 └──────────────┬────────────────┘                │
        │                                │                                 │
        │                                │ agente de reconciliação         │
        │                                │ (convergência de estado)        │
        │                                ▼                                │
        │            ┌───────────────────────────────────────┐            │
        │            │      Infraestrutura (servers/)            │            │
        │            │  ┌───────────┐ ┌───────────┐ ┌────────┐  │            │
        │            │  │ servidor A │ │ servidor B │ │  ...   │  │            │
        │            │  │ (múltiplos │ │            │ │        │  │            │
        │            │  │  produtos/ │ │            │ │        │  │            │
        │            │  │  ambientes │ │            │ │        │  │            │
        │            │  │  possíveis)│ │            │ │        │  │            │
        │            │  └───────────┘ └───────────┘ └────────┘  │            │
        │            └───────────────────────────────────────┘            │
        │                                                                │
        └──────────────────────────────────────────────────────────────┘
```

## Fluxo ponta a ponta

1. Um repositório de aplicação builda, testa e publica uma imagem versionada e imutável (Pipeline 1 — [ADR-002](../adr/ADR-002-deployment-pipeline.md)).
2. Um PR no `platform-ops` declara a intenção de rodar essa versão em um ambiente de um produto (`apps/<produto>/<ambiente>/versions.env` ou, no contrato mais recente, `release.yml` — ver [docs/versioning.md](versioning.md)).
3. O PR é revisado segundo o critério do ambiente-alvo ([ADR-005](../adr/ADR-005-environment-promotion.md) — Development, Staging ou Production têm exigências de aprovação diferentes).
4. Após merge, o agente de reconciliação detecta a divergência entre estado desejado (Git) e estado real (infraestrutura) e converge a infraestrutura para o novo estado (Pipeline 2 — [ADR-002](../adr/ADR-002-deployment-pipeline.md)).
5. Health checks pós-deploy validam a nova versão. Falha aciona rollback automático; sucesso sustentado confirma o deploy ([ADR-003](../adr/ADR-003-rollback-strategy.md)).
6. Segredos necessários em qualquer etapa são resolvidos por referência, nunca por valor versionado ([ADR-004](../adr/ADR-004-secrets-management.md)).

## Componentes

### Repositórios de aplicação
Um por SaaS. Donos de código, testes, build e imagem Docker. Não têm conhecimento de infraestrutura de destino, credenciais de produção, nem lógica de deploy/rollback. Ver [ADR-001](../adr/ADR-001-gitops-strategy.md) para a fronteira exata de responsabilidade.

### `platform-ops` (este repositório)
Único, compartilhado por todos os produtos. Dono do estado desejado, das decisões arquiteturais (ADRs), do inventário de infraestrutura, da documentação operacional e dos templates de onboarding. Nunca contém código de produto.

### Agente de reconciliação
Componente de implementação (não coberto por Sprint 0) responsável por observar o estado desejado declarado em `apps/` e convergir a infraestrutura real para esse estado — o mecanismo técnico por trás do Pipeline 2 da [ADR-002](../adr/ADR-002-deployment-pipeline.md).

### Gerenciador de segredos
Sistema externo (a ser definido em sprint de implementação) que armazena valores reais de credenciais, referenciado — nunca versionado — a partir do `platform-ops`. Ver [ADR-004](../adr/ADR-004-secrets-management.md).

### Inventário de servidores (`servers/`)
Desacoplado do inventário de aplicações. Um ambiente de um produto referencia onde deve rodar; um servidor não precisa conhecer a priori quais produtos hospeda. Permite consolidação e escala horizontal sem redesenho estrutural.

## Responsabilidades — resumo

| | Repositório de Aplicação | `platform-ops` |
|---|---|---|
| Código-fonte | ✅ | ❌ |
| Testes | ✅ | ❌ |
| Build | ✅ | ❌ |
| Imagem Docker | ✅ (build e publicação) | ❌ (apenas referência de versão) |
| Estado desejado | ❌ | ✅ |
| Deploy / convergência | ❌ | ✅ |
| Promoção entre ambientes | ❌ | ✅ |
| Rollback | ❌ | ✅ |
| Inventário de ambientes/servidores | ❌ | ✅ |
| Segredos (referência) | ❌ | ✅ |
| Segredos (valor) | ❌ (apenas os próprios de CI, via GitHub Secrets do repo) | ❌ (nunca — vive no gerenciador de segredos externo) |
| Observabilidade / runbooks | ❌ | ✅ |

## Estrutura de repositório

A estrutura de diretórios já existente no scaffold está correta para o objetivo desta plataforma e é formalizada, não redesenhada, por este documento:

```
platform-ops/
├── README.md              # Porta de entrada: visão geral e navegação
├── adr/                    # Registro de decisões arquiteturais (este é o "porquê")
│   ├── ADR-001-gitops-strategy.md
│   ├── ADR-002-deployment-pipeline.md
│   ├── ADR-003-rollback-strategy.md
│   ├── ADR-004-secrets-management.md
│   ├── ADR-005-environment-promotion.md
│   ├── ADR-006-release-management.md
│   └── ADR-007-artifact-provenance.md
├── apps/                   # Estado desejado, por produto e por ambiente
│   └── <produto>/
│       └── <ambiente>/
│           ├── metadata.yml    # Metadados do estado desejado (referências, config não sensível)
│           ├── versions.env    # Contrato LEGADO/DEPRECATED: SHA de commit por componente (só apps na allowlist de migração)
│           └── release.yml     # Contrato oficial (schema platform-ops/v1, quando presente tem prioridade): SemVer + sourceCommit + createdAt + imagem/tag/digest por componente
├── docs/                    # Documentação operacional consolidada (o "como", em prosa)
│   ├── architecture.md         # Este documento
│   ├── deployment-flow.md      # Guia operacional da esteira
│   ├── secrets.md              # Guia operacional de segredos
│   ├── versioning.md           # SemVer, proveniência e identidade de artefato — conceitos
│   ├── release-management.md   # Contrato release.yml, política de depreciação, GitHub Release, release notes
│   └── runbooks/                # Procedimentos operacionais por cenário/incidente
├── scripts/                  # deploy.sh, healthcheck.sh, rollback.sh + lib/common.sh
├── servers/                   # Inventário de infraestrutura de execução
│   └── <servidor>.yml
├── templates/                  # Scaffolding padronizado para onboarding
│   ├── app/
│   │   └── release.yml            # Template genérico do manifest de release
│   ├── release-notes.md           # Template genérico de release notes
│   └── workflows/                 # Template de automação de esteira (ainda não implementado)
└── .github/
    └── workflows/
        └── deploy-production.yml   # workflow_dispatch manual — ver docs/deployment-flow.md
```

**Nota sobre `docs/deployment-flow.md` e `docs/secrets.md`:** desde a Sprint 1, ambos contêm o
guia operacional derivado (dia a dia — como disparar um deploy, quais secrets existem e onde) da
decisão e justificativa registradas, respectivamente, em [ADR-002](../adr/ADR-002-deployment-pipeline.md)
e [ADR-004](../adr/ADR-004-secrets-management.md). As ADRs continuam sendo a fonte da verdade do
*porquê*; os documentos em `docs/` são o *como*, escritos a partir da implementação real.

**Nota sobre `apps/vantry/production/`:** o par `metadata.yml` + `versions.env` já presente no
scaffold desde a Sprint 0 é o padrão de referência formalizado por este documento e pela
[ADR-001](../adr/ADR-001-gitops-strategy.md) para qualquer produto e qualquer ambiente. Na
Sprint 1, ambos foram preenchidos com o estado declarativo real do piloto Vantry. Na Sprint 1.1,
o conceito de "versão" foi refinado (SemVer + source commit + digest OCI — ver
[docs/versioning.md](versioning.md)); `release.yml` é o novo formato, mas **Vantry/Production
continua no contrato legado (`versions.env`) até a primeira release SemVer real ser publicada**
— nada foi migrado silenciosamente.

## Evolução futura

Esta arquitetura foi desenhada para os seguintes eixos de crescimento sem exigir revisão estrutural (detalhado na [ADR-001](../adr/ADR-001-gitops-strategy.md), seção "Estratégia de crescimento futuro"):

- **Novo produto** → nova pasta em `apps/`, a partir de `templates/app/`.
- **Novo ambiente por produto** → extensão pontual do conjunto padrão da [ADR-005](../adr/ADR-005-environment-promotion.md).
- **Novo servidor/provedor/região** → adição a `servers/`, sem impacto nos demais componentes.
- **Múltiplos times operando produtos diferentes** → a separação por produto em `apps/` permite, no futuro, controle de acesso granular por diretório.
- **Observabilidade unificada** → componente ainda não implementado; a estrutura já reserva o espaço conceitual (parte das responsabilidades centrais do `platform-ops` descritas na [ADR-001](../adr/ADR-001-gitops-strategy.md)), a ser detalhado em ADR própria quando entrar em escopo de implementação.

## Próximos passos

Ver relatório de Sprint 1.1 (comunicado separadamente) para o estado atual de pendências:
validação do pipeline contra a VPS real, provisionamento das credenciais SSH dedicadas, e
fechamento do gap de commit automatizado pós-rollback (ver "Atualização (Sprint 1.1)" na
[ADR-003](../adr/ADR-003-rollback-strategy.md)). O `agente de reconciliação` descrito acima como
componente conceitual é, hoje, implementado de forma direta por `scripts/deploy.sh` executado
via `workflow_dispatch` manual — não um processo contínuo de observação — ver
[docs/deployment-flow.md](deployment-flow.md).
