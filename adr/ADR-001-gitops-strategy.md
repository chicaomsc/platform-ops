# ADR-001 — GitOps Strategy

## Status

Aceito — 2026-08-23

## Sumário

Esta ADR define a estratégia fundamental do `platform-ops`: um modelo GitOps em que o Git é a única fonte da verdade para o **estado desejado** de todos os SaaS operados pela empresa, através de todos os ambientes e servidores. Toda ADR subsequente neste repositório (ADR-002 a ADR-005) é uma especialização desta decisão.

---

## Objetivo do Platform Ops

O `platform-ops` é a plataforma operacional da empresa — não uma aplicação. Seu papel é centralizar, para **todos** os produtos SaaS (Vantry, AcadFlow, StratoSage e futuros produtos), as seguintes responsabilidades:

- GitOps (fonte única da verdade do estado desejado)
- Deploy e promoção entre ambientes
- Estratégias de rollback
- Gestão de versões
- Inventário e configuração de ambientes e servidores
- Observabilidade
- Runbooks operacionais
- Templates reutilizáveis para novos produtos
- Automações de esteira

O `platform-ops` deve ser **agnóstico de produto**. Nenhum artefato aqui deve conter lógica, regra de negócio ou acoplamento específico de um único SaaS. Tudo que é específico de produto vive no repositório da aplicação; tudo que é específico de *operação* vive aqui.

## Problema que estamos resolvendo

Antes desta plataforma, cada SaaS resolveria deploy, promoção, rollback e gestão de segredos de forma isolada e provavelmente inconsistente entre si. Isso gera, à medida que o número de produtos cresce:

1. **Reinvenção de processo por produto.** Cada novo SaaS reimplementa (com variações) a mesma esteira de deploy, promoção e rollback.
2. **Conhecimento operacional fragmentado.** Não existe um único lugar onde se possa responder "o que está rodando em produção, em qual versão, desde quando".
3. **Deriva de configuração (configuration drift).** Sem uma fonte única da verdade, o estado real dos servidores diverge silenciosamente do que se *pretendia* implantar, e essa divergência só é descoberta quando causa incidente.
4. **Ausência de auditoria.** Sem um histórico versionado do estado desejado, mudanças em produção (quem, quando, por quê) não são rastreáveis de forma confiável.
5. **Acoplamento entre "escrever código" e "operar o sistema".** Times de produto ficam bloqueados em conhecimento de infraestrutura para fazer deploy, e mudanças operacionais (ex.: rollback de emergência) exigem tocar no repositório de aplicação.

À medida que a empresa passa de um para múltiplos SaaS, esse problema deixa de ser um incômodo local e passa a ser um risco estrutural: sem uma plataforma comum, o custo de operar N produtos cresce mais rápido que N.

## Contexto atual

O `platform-ops` está em sua Sprint 0: existe uma estrutura de diretórios inicial (`adr/`, `apps/`, `docs/`, `scripts/`, `servers/`, `templates/`, `.github/workflows/`), sem conteúdo ou automação implementada. Já existe um primeiro produto de referência mapeado na estrutura (`apps/vantry/production/`), com dois arquivos-conceito: `metadata.yml` (metadados do estado desejado) e `versions.env` (versão implantada). Esse padrão, embora ainda vazio de conteúdo, já expressa corretamente a intenção arquitetural deste ADR e será formalizado, não substituído.

Nenhuma automação de deploy, promoção ou rollback existe ainda. Esta ADR é deliberadamente anterior a qualquer implementação.

## Decisão

**O Git é a única fonte da verdade do estado desejado de todos os ambientes de todos os produtos.**

Adotamos um modelo GitOps com **separação estrita entre dois tipos de repositório**:

- **Repositório de aplicação** (um por SaaS — ex.: `vantry`, `acadflow`, `stratosage`): dono do código-fonte, testes, build e da imagem de artefato (Docker). Sua responsabilidade termina na publicação de um artefato versionado e imutável.
- **Repositório de plataforma** (`platform-ops`, este repositório, único e compartilhado): dono do *estado desejado* — qual versão de qual artefato deve estar rodando em qual ambiente, em qual servidor, com qual configuração. Nenhum código de aplicação vive aqui; apenas declarações de estado, ADRs, automações operacionais e documentação.

Um agente de reconciliação (implementado a partir da Sprint 1) observa o estado desejado declarado neste repositório e o estado real da infraestrutura, e atua para eliminar a diferença entre os dois. Isso é o núcleo do modelo GitOps: **deploy é a convergência do estado real para o estado declarado em Git, não um comando imperativo disparado manualmente contra um servidor.**

### Fluxo completo da esteira

```
┌─────────────────────────┐         ┌────────────────────────────┐         ┌──────────────────────┐
│  Repositório da          │         │   platform-ops               │         │   Infraestrutura       │
│  Aplicação (ex: vantry)  │         │   (este repositório)         │         │   (servidores)         │
├─────────────────────────┤         ├────────────────────────────┤         ├──────────────────────┤
│                           │         │                              │         │                        │
│ 1. Push / PR merge        │         │                              │         │                        │
│ 2. CI: build + testes      │         │                              │         │                        │
│ 3. Build de imagem Docker  │         │                              │         │                        │
│ 4. Push da imagem versionada│──────▶ │ 5. PR de atualização de       │         │                        │
│    para o registry          │  ref.  │    versions.env do ambiente   │         │                        │
│                           │         │    de Development             │         │                        │
│                           │         │ 6. Revisão + merge (ver        │         │                        │
│                           │         │    ADR-005)                    │         │                        │
│                           │         │ 7. Agente de reconciliação     │────────▶│ 8. Convergência do     │
│                           │         │    detecta divergência         │         │    estado real para o  │
│                           │         │    entre estado desejado e     │         │    estado desejado     │
│                           │         │    estado real                 │         │ 9. Health checks       │
│                           │         │ 10. Promoção Dev → Staging →   │         │    (ADR-003)           │
│                           │         │     Production (ADR-005)       │         │                        │
└─────────────────────────┘         └────────────────────────────┘         └──────────────────────┘
```

O detalhamento técnico de cada etapa da esteira é objeto da ADR-002. O detalhamento do critério e mecânica de promoção é objeto da ADR-005. Rollback é objeto da ADR-003.

### Responsabilidades do repositório da aplicação

O repositório de cada SaaS é responsável por, e **apenas** por:

- Código-fonte do produto.
- Testes (unitários, integração, contrato).
- Build da aplicação.
- Construção e publicação da imagem Docker versionada e imutável (tag = versão semântica ou SHA de commit — ver "Estratégia de versionamento" abaixo).
- CI específico do produto (lint, testes, build) — vive no repositório da aplicação, não no `platform-ops`.

O repositório de aplicação **não sabe** onde ele está implantado, em qual servidor, com qual configuração de ambiente, nem como fazer rollback. Essa fronteira é deliberada: ela é o que permite que o `platform-ops` sirva qualquer número de produtos sem crescer em complexidade proporcional.

### Responsabilidades do Platform Ops

Este repositório é responsável por, e por tudo que é comum a todos os produtos:

- **Estado desejado**: qual versão de cada app está declarada para cada ambiente (`apps/<produto>/<ambiente>/`).
- **Deploy**: mecanismo de convergência do estado real para o estado declarado.
- **Promoção**: processo controlado de avanço de uma versão entre ambientes (Development → Staging → Production).
- **Rollback**: reversão controlada e auditável para uma versão anterior conhecida-boa.
- **Ambientes**: definição de quais ambientes existem e suas características (ADR-005).
- **Servidores**: inventário e configuração da infraestrutura de execução (`servers/`).
- **Operações**: observabilidade, runbooks, automações e templates compartilhados entre produtos.
- **Segredos operacionais** (referências, não valores — ver ADR-004).

### Fluxo de promoção

Resumo (detalhado na ADR-005): uma versão avança de ambiente em ambiente através de uma alteração declarativa no `platform-ops` (ex.: atualizar `versions.env` do ambiente-alvo), nunca por ação direta em um servidor. Cada promoção é um commit (ou merge de PR) auditável: quem promoveu, quando, de qual versão para qual versão.

### Fluxo de rollback

Resumo (detalhado na ADR-003): como o estado desejado é declarativo e versionado em Git, rollback é a operação inversa de uma promoção — reverter a declaração de versão de um ambiente para uma versão anterior conhecida-boa, e deixar o agente de reconciliação convergir a infraestrutura para esse estado. Rollback nunca é uma ação ad-hoc no servidor.

### Estratégia de versionamento

- Toda imagem publicada por um repositório de aplicação é **imutável** e identificada por uma tag única (SHA de commit e, opcionalmente, versão semântica para releases marcadas).
- O `platform-ops` nunca referencia tags móveis (`latest`, `main`, `stable`). Cada declaração de estado desejado fixa uma versão exata e resolvível.
- O histórico de versões implantadas por ambiente é, por construção, o histórico de commits do arquivo de estado desejado — nenhum mecanismo adicional de auditoria é necessário.
- **Refinamento (Sprint 1.1):** esta decisão previu desde o início "versão semântica para releases marcadas" como opcional; a Sprint 1.1 formaliza esse refinamento — ver "Atualização (Sprint 1.1)" abaixo e [docs/versioning.md](../docs/versioning.md).

### Estratégia para múltiplos SaaS

Cada produto é uma unidade isolada dentro de `apps/<produto>/`. A estrutura interna de cada `apps/<produto>/` é idêntica entre produtos (mesmos arquivos, mesma semântica), o que permite:

- Onboarding de um novo SaaS por cópia de template (ver `templates/app/`), sem decisão arquitetural nova.
- Nenhum acoplamento entre produtos: uma mudança de estado desejado de um produto nunca afeta outro.
- Automação (agente de reconciliação, workflows) escrita uma única vez e aplicada a todos os produtos por convenção de estrutura, não por configuração especial por produto.

### Estratégia para múltiplos ambientes

Ambientes são um nível dentro de cada produto: `apps/<produto>/<ambiente>/`. O conjunto de ambientes (Development, Staging, Production) e as regras de transição entre eles são padronizados para todos os produtos pela ADR-005, para que operar N produtos não implique aprender N políticas de promoção distintas.

### Estratégia para múltiplos servidores

O inventário de servidores (`servers/`) é desacoplado do inventário de aplicações (`apps/`). Um ambiente de um produto referencia o(s) servidor(es) onde deve rodar; um servidor não precisa saber, a priori, quais produtos hospeda. Isso permite:

- Consolidar múltiplos produtos/ambientes em um mesmo servidor quando fizer sentido operacional (ex.: ambientes de Development de baixo tráfego).
- Adicionar novos servidores (escala horizontal, nova região, novo provedor) sem alterar a estrutura de `apps/`.

### Estratégia de crescimento futuro

Esta decisão é feita considerando explicitamente que o número de produtos e a escala de infraestrutura vão crescer. Os pontos de extensão previstos, sem exigir revisão desta ADR, são:

- **Novo produto**: nova pasta em `apps/<produto>/`, a partir do template padrão. Não exige mudança na esteira, na plataforma ou em ADRs existentes.
- **Novo ambiente por produto** (ex.: ambiente de demo, ambiente de sandbox de cliente): extensão do conjunto de ambientes da ADR-005, aplicável seletivamente por produto se necessário.
- **Novo provedor de infraestrutura**: adição ao inventário de `servers/`, sem impacto nos demais.
- **Múltiplas regiões / múltiplos clusters por produto**: suportado pela mesma estrutura, adicionando um nível de granularidade dentro de `apps/<produto>/<ambiente>/` quando isso se tornar necessário (não implementado na Sprint 0 — decisão adiada até haver necessidade real, para evitar abstração prematura).
- **Múltiplos times operando produtos diferentes**: a separação por produto em `apps/` permite, no futuro, permissões de PR granulares por diretório sem mudança estrutural.

## Motivação

A motivação central é fazer com que o **custo operacional de adicionar o N-ésimo produto seja aproximadamente constante**, não crescente. Isso só é possível se:

- Existe um único lugar que responde "o que está implantado, onde, e em qual versão" para qualquer produto.
- O processo de deploy, promoção e rollback é idêntico em mecânica para todo produto, variando apenas em dados (qual versão, qual ambiente), nunca em lógica.
- A auditoria e o histórico de mudanças operacionais são um subproduto gratuito do uso de Git (log de commits), em vez de um sistema à parte a ser mantido.

## Benefícios

- **Fonte única da verdade.** Elimina ambiguidade sobre o estado real pretendido do sistema.
- **Auditoria nativa.** Todo commit em `platform-ops` é, por si só, um registro de auditoria de quem mudou o quê, quando e por quê (mensagem de commit / PR).
- **Reversibilidade.** Qualquer mudança de estado desejado é revertida com a mesma mecânica de Git usada para aplicá-la.
- **Desacoplamento entre código e operação.** Times de produto não precisam de acesso ou conhecimento de infraestrutura para que uma versão avance de ambiente; times de plataforma não precisam tocar em código de aplicação para operar.
- **Escalabilidade organizacional.** Onboarding de um novo SaaS é um processo mecânico (cópia de template), não uma decisão de arquitetura.
- **Consistência.** Todos os produtos são operados da mesma forma, o que reduz a curva de aprendizado operacional e o risco de erro humano específico de produto.

## Limitações

- **Latência de reconciliação.** Um modelo GitOps *pull-based* (agente de reconciliação observando o repositório) introduz, por definição, uma janela de tempo entre o commit do estado desejado e a convergência real — não é instantâneo como um deploy imperativo (`ssh` + comando). Isso é uma troca deliberada por auditabilidade e segurança.
- **Dependência de disponibilidade do Git.** Se o provedor Git estiver indisponível, novas mudanças de estado desejado não podem ser declaradas — embora o estado já convergido continue rodando normalmente.
- **Curva de disciplina operacional.** O modelo só funciona se toda mudança realmente passar pelo Git. Uma alteração manual feita diretamente em um servidor ("hotfix silencioso") quebra a premissa de fonte única da verdade e introduz *drift* não detectado até a próxima reconciliação — que, dependendo da estratégia (ADR-002), pode reverter a mudança manual sem aviso. Isso deve ser comunicado claramente às equipes.
- **Não resolve, por si só, qualidade do artefato.** O `platform-ops` garante que a versão declarada é a que roda; não garante que essa versão está livre de bugs — essa responsabilidade permanece no repositório de aplicação (CI, testes).

## Consequências

- Toda alteração de infraestrutura operacional passa a exigir um PR neste repositório, revisável e rastreável.
- Nenhum deploy, promoção ou rollback deve ser feito por ação manual direta em servidor fora deste fluxo; se isso ocorrer, deve ser tratado como incidente de *drift*, não como operação válida.
- Repositórios de aplicação perdem (deliberadamente) a capacidade de decidir sozinhos quando e onde são implantados — isso passa a ser uma decisão explícita, feita via PR no `platform-ops` (ver ADR-005 para quem tem autoridade de promoção).
- A estrutura `apps/<produto>/<ambiente>/` definida no scaffold atual (`apps/vantry/production/metadata.yml` + `versions.env`) é confirmada e formalizada como o contrato de estado desejado para todo produto presente e futuro.

## Alternativas consideradas

1. **Deploy imperativo centralizado** (um script/pipeline que faz SSH ou chama a API de orquestração diretamente a partir do repositório de aplicação, sem repositório de plataforma).
2. **Um repositório de plataforma por produto** (`vantry-ops`, `acadflow-ops`, ...), em vez de um único `platform-ops` compartilhado.
3. **GitOps push-based**, onde o próprio CI do repositório de aplicação aplica a mudança diretamente na infraestrutura ao final do build, sem um estado desejado declarativo intermediário revisável.
4. **Ferramenta de orquestração de terceiros com painel próprio** (ex.: plataforma de deploy gerenciada) como fonte da verdade, em vez de Git.

## Alternativas rejeitadas

1. **Deploy imperativo centralizado** — rejeitado porque reintroduz exatamente o problema que motivou este ADR: nenhuma fonte da verdade declarativa, nenhuma auditoria nativa, e cada execução do pipeline é a única prova de que algo foi implantado (perdida se o log de CI expirar). Também acopla o repositório de aplicação a detalhes de infraestrutura que deveriam ser responsabilidade da plataforma.

2. **Um repositório de plataforma por produto** — rejeitado por não escalar: replicaria N vezes a mesma lógica operacional (esteira, promoção, rollback), tornando qualquer melhoria de processo um trabalho de propagação manual para N repositórios. Viola diretamente o objetivo de "nada específico de um único produto" e o requisito de escalabilidade — o custo de adicionar o N-ésimo produto deixaria de ser constante.

3. **GitOps push-based** — rejeitado porque, embora ainda use Git como origem, ele aplica a mudança de forma imperativa a partir do CI da aplicação, exigindo que o repositório de aplicação tenha credenciais de acesso à infraestrutura de produção. Isso viola a separação de responsabilidades definida nesta ADR (repositório de aplicação não deve saber onde/como é implantado) e amplia a superfície de risco de segurança (credenciais de infraestrutura espalhadas por N repositórios de produto em vez de centralizadas em um único agente de reconciliação).

4. **Ferramenta de orquestração de terceiros como fonte da verdade** — rejeitado por criar dependência de um sistema externo proprietário como origem do estado, quando Git já oferece, nativamente e sem custo adicional, versionamento, histórico, revisão por PR e capacidade de reversão. Não descarta o uso de ferramentas de terceiros como *mecanismo* de reconciliação (isso é uma decisão de implementação, não de arquitetura) — apenas rejeita que uma ferramenta de terceiros seja a *fonte da verdade*.

## Atualização (Sprint 1.1) — Release Versioning & Artifact Provenance

Esta seção registra uma **evolução** da decisão original, não sua substituição. A decisão
fundamental desta ADR — Git como única fonte da verdade do estado desejado — permanece
inalterada. O que evolui é o que, exatamente, "uma versão" significa.

**Refinamento:** "versão" deixa de ser um único identificador (SHA de commit) e passa a ser três
identidades distintas e relacionadas, detalhadas em [docs/versioning.md](../docs/versioning.md):

1. **Release Version** (SemVer — `MAJOR.MINOR.PATCH`) — identidade do produto/release, para
   humanos e para promoção entre ambientes.
2. **Source Commit** (SHA completo) — proveniência exata do código-fonte.
3. **Artifact Digest** (`sha256:...`) — identidade imutável e criptograficamente verificável do
   artefato OCI realmente implantado.

**Motivação do refinamento:** um SHA de commit identifica código-fonte, não necessariamente o
artefato binário resultante (o mesmo commit pode, em tese, gerar builds diferentes em
circunstâncias anômalas), e não comunica nada sobre compatibilidade/risco para quem promove
entre ambientes (ADR-005) — um SHA não diz se uma mudança é MAJOR, MINOR ou PATCH. SemVer resolve
a comunicação humana; o SHA continua necessário para proveniência; o digest OCI é o que faltava
para uma prova técnica completa de identidade do artefato — nenhum dos três substitui os outros.

**O que muda no contrato declarativo:** `apps/<app>/<env>/release.yml` passa a ser o formato
preferido de estado desejado (detalhado em [docs/versioning.md](../docs/versioning.md)),
coexistindo com o formato legado (`versions.env`, exatamente como definido nesta ADR original)
até a migração de cada app/ambiente. **Nenhum app/ambiente é migrado silenciosamente** — a
Sprint 1.1 não alterou `apps/vantry/production/versions.env`.

**O que não muda:** a proibição de tags móveis (`latest`/`main`/`stable`), a imutabilidade de
tags publicadas, e o princípio de que o histórico de commits do estado desejado é a auditoria.

## Referências cruzadas

- [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)
- [ADR-003 — Rollback Strategy](./ADR-003-rollback-strategy.md)
- [ADR-004 — Secrets Management](./ADR-004-secrets-management.md)
- [ADR-005 — Environment Promotion](./ADR-005-environment-promotion.md)
- [docs/architecture.md](../docs/architecture.md)
- [docs/versioning.md](../docs/versioning.md) — detalhamento completo do refinamento da Sprint 1.1
