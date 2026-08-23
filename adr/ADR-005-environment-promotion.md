# ADR-005 — Environment Promotion

## Status

Aceito — 2026-08-23

Depende de: [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md), [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)

## Contexto

A ADR-001 estabelece que cada produto declara seu estado desejado por ambiente em `apps/<produto>/<ambiente>/`. Esta ADR formaliza o conjunto de ambientes, a ordem e as regras de transição entre eles — ou seja, como uma versão avança de "recém-publicada" até "rodando em produção".

## Problema que estamos resolvendo

- Sem uma política de promoção explícita e padronizada, cada produto tenderia a definir seus próprios critérios de "quando uma versão está pronta para o próximo ambiente", tornando o comportamento do sistema imprevisível entre produtos.
- Sem clareza sobre **quem** tem autoridade para promover, o processo fica vulnerável tanto a excesso de burocracia (todo mundo precisa aprovar tudo) quanto a excesso de informalidade (qualquer um promove para produção sem critério).
- Sem critérios objetivos, a decisão de promover uma versão fica sujeita a julgamento ad-hoc, dificultando auditoria de "por que essa versão foi para produção".

## Decisão

Definimos três ambientes padrão, aplicáveis a todo produto operado por esta plataforma, com promoção estritamente sequencial e unidirecional:

```
Development  ──▶  Staging  ──▶  Production
```

Não existe promoção que pule um ambiente (ex.: Development direto para Production) nem promoção retroativa (retroação de versão é rollback — ADR-003 — não "promoção reversa"). Cada seta representa uma mudança declarativa de estado desejado (PR de atualização de `versions.env`), sujeita aos critérios abaixo.

### Development

**Propósito:** validação inicial de uma versão recém-publicada pelo Pipeline 1 (ADR-002), em condições próximas de produção, com tolerância alta a instabilidade.

- **Quem promove:** qualquer desenvolvedor do produto correspondente, sem aprovação adicional além da revisão de código já aplicada no repositório de aplicação.
- **Quando promove:** a cada nova imagem publicada pelo Pipeline 1 que o time deseje validar — tipicamente de forma contínua/automática a partir de uma branch principal do repositório de aplicação, embora a mecânica exata de automação seja decisão de implementação (fora do escopo desta ADR).
- **Como promove:** PR neste repositório atualizando `versions.env` do ambiente de Development do produto, com merge direto (sem exigência de segundo aprovador).
- **Critérios:** nenhum critério de qualidade além de "a imagem foi publicada com sucesso pelo Pipeline 1" (ou seja, build e testes automatizados já passaram no repositório de aplicação). Rollback automático (ADR-003) é opcional neste ambiente.

### Staging

**Propósito:** validação de uma versão em condições equivalentes a produção (infraestrutura, dados representativos, integração completa), como último portão antes de expor usuários reais.

- **Quem promove:** um responsável técnico do produto (ex.: tech lead ou equivalente designado por produto) ou automação condicionada a critérios objetivos (ex.: versão permaneceu estável em Development por um período mínimo). O nome exato do papel responsável é definido por produto, mas a exigência de que exista *um* responsável identificável é parte desta ADR.
- **Quando promove:** quando a versão for considerada candidata a produção — tipicamente após validação funcional em Development.
- **Como promove:** PR atualizando `versions.env` do ambiente de Staging, exigindo **no mínimo uma aprovação** de alguém além do autor do PR.
- **Critérios:** a versão deve estar rodando de forma saudável em Development (health checks da ADR-003 aplicáveis); recomenda-se, como prática, que a versão promovida para Staging seja a mesma testada em Development, sem alterações intermediárias — se algo mudar, o ciclo reinicia em Development.

### Production

**Propósito:** ambiente servindo usuários reais. Máxima exigência de critério e de rastreabilidade.

- **Quem promove:** requer aprovação explícita de um responsável com autoridade de release para o produto (papel formalmente designado por produto — pode coincidir com o mesmo responsável de Staging, mas a autorização para Production deve ser uma decisão distinta e registrada, não implícita pela aprovação de Staging).
- **Quando promove:** após a versão ter sido validada com sucesso em Staging, por um período mínimo de observação definido por produto (dependendo de criticidade/complexidade), sem regressões identificadas.
- **Como promove:** PR atualizando `versions.env` do ambiente de Production, exigindo **no mínimo uma aprovação formal** de autoridade de release, e sujeito às mesmas verificações de saúde pós-deploy da ADR-003 (com rollback automático obrigatório, não opcional, neste ambiente).
- **Critérios:** validação bem-sucedida e sustentada em Staging; ausência de incidentes abertos relacionados à versão candidata; conformidade com qualquer janela de mudança (change window) que a operação decida adotar por produto (ex.: evitar promoções em horários de pico, decisão de implementação/operação, não fixada nesta ADR).

### Resumo de critérios de aprovação por ambiente

| Ambiente | Quem aprova | Critério de entrada | Rollback automático |
|---|---|---|---|
| Development | Autor do PR (sem aprovação adicional) | Imagem publicada com sucesso pelo Pipeline 1 | Opcional |
| Staging | 1 aprovador além do autor | Estável em Development | Recomendado |
| Production | 1 aprovador com autoridade de release | Estável em Staging por período mínimo definido por produto | Obrigatório |

## Motivação

Um funil sequencial com critérios crescentes de rigor é o padrão que melhor equilibra velocidade de iteração (Development permanece barato e rápido) com segurança em produção (Production exige validação prévia e aprovação formal), sem exigir que cada produto reinvente essa política — ela é definida uma única vez, aqui, e vale para todos.

## Benefícios

- **Previsibilidade.** Toda pessoa na empresa sabe, sem precisar perguntar, o que é exigido para uma versão chegar a produção, independente do produto.
- **Rastreabilidade de decisão.** Cada promoção é um PR aprovado — "quem decidiu colocar essa versão em produção" tem sempre uma resposta objetiva.
- **Redução de risco incremental.** Cada ambiente atua como filtro: problemas triviais são pegos em Development (barato), problemas de integração em Staging (antes de afetar usuários), e Production só recebe versões já duplamente validadas.
- **Flexibilidade dentro de uma política comum.** Produtos podem definir seus próprios responsáveis e janelas de tempo mínimas sem precisar de uma ADR nova — a estrutura é compartilhada, os parâmetros são configuráveis por produto.

## Limitações

- **Não elimina a possibilidade de um bug passar por todos os ambientes.** Staging, por melhor que seja, nunca é idêntico a Production; validação em Staging reduz mas não elimina risco.
- **Latência de promoção.** Um funil sequencial obrigatório é, por definição, mais lento que deploy direto a produção — essa é uma troca deliberada por segurança, e deve ser dimensionada (períodos mínimos de observação) para não se tornar burocracia desnecessária.
- **Dependência de disciplina organizacional.** A política só é eficaz se times realmente designarem os responsáveis exigidos por ambiente (especialmente autoridade de release para Production) — a ADR define a exigência do papel, não impõe tecnicamente quem o ocupa.

## Consequências

- Todo novo produto onboardado (via `templates/app/`) deve, como parte do onboarding, ter formalmente designados: um responsável técnico (Staging) e uma autoridade de release (Production).
- Regras de proteção de branch/PR neste repositório (implementação futura, fora do escopo desta sprint) devem refletir tecnicamente os critérios de aprovação aqui definidos por caminho de diretório (`apps/<produto>/development/`, `.../staging/`, `.../production/`).
- Qualquer exceção a este funil (ex.: hotfix crítico de segurança que precise pular etapas) deve ser tratada como um runbook de emergência formalmente documentado (`docs/runbooks/`, fora do escopo de conteúdo desta sprint), não como uma prática informal recorrente.

## Alternativas consideradas

1. **Promoção direta para Production** (sem Staging obrigatório), com Staging como ambiente opcional de uso livre.
2. **Mais de três ambientes padrão** (ex.: incluir um ambiente de QA dedicado, separado de Staging).
3. **Critérios de aprovação idênticos para todos os ambientes** (mesma exigência de aprovação em Development, Staging e Production).
4. **Promoção automática integral, sem aprovação humana em nenhum ambiente**, condicionada apenas a testes automatizados e health checks.

## Alternativas rejeitadas

1. **Promoção direta para Production** — rejeitada porque remove o filtro intermediário que existe justamente para capturar problemas de integração antes que afetem usuários reais. Aceitável para produtos em estágio muito inicial (poucos usuários, tolerância alta a risco), mas não como política padrão da plataforma — se um produto específico precisar dessa flexibilidade, isso deve ser uma decisão explícita e documentada por produto, não o default da arquitetura.

2. **Mais de três ambientes padrão** — rejeitado por Sprint 0 como complexidade não justificada agora: cada ambiente adicional aumenta o custo de manutenção (infraestrutura, dados, automação) para todo produto, mesmo os que não precisariam da granularidade extra. Se um produto específico precisar de um ambiente adicional (ex.: sandbox de cliente), isso é suportado pela extensibilidade descrita na ADR-001 ("Estratégia de crescimento futuro") sem exigir revisão desta política padrão.

3. **Critérios de aprovação idênticos entre ambientes** — rejeitado porque contraria diretamente o objetivo de balancear velocidade (Development) com segurança (Production). Exigir aprovação formal em Development tornaria a iteração inicial lenta sem ganho de segurança proporcional (o ambiente já é de baixo risco por definição); não exigir aprovação em Production eliminaria o controle que justamente motiva esta ADR.

4. **Promoção 100% automática sem aprovação humana** — rejeitada como política padrão porque, embora reduza latência, remove o ponto de responsabilidade humana explícita sobre decisões de impacto direto a usuários reais (Production). Testes automatizados e health checks (ADR-003) são necessários mas não suficientes — cobrem classes conhecidas de falha, não julgamento de negócio (ex.: "esta é a janela certa para promover, dado o contexto atual da operação"). Automação total pode ser adotada no futuro, por produto, como evolução desta política, uma vez que o produto demonstre maturidade suficiente de testes e observabilidade — mas não é o ponto de partida.

## Referências cruzadas

- [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)
- [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)
- [ADR-003 — Rollback Strategy](./ADR-003-rollback-strategy.md)
