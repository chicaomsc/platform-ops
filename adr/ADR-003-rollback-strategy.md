# ADR-003 — Rollback Strategy

## Status

Aceito — 2026-08-23

Depende de: [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md), [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)

## Contexto

Sob o modelo GitOps definido na ADR-001, o estado desejado de cada ambiente é uma declaração versionada em Git (`versions.env`). Isso torna rollback, por construção, uma operação simétrica ao deploy: **não é um mecanismo separado, é a mesma mecânica de convergência (ADR-002) aplicada a uma versão anterior do estado desejado.** Esta ADR define quando e como essa reversão acontece — automática ou manualmente — e quais critérios determinam que uma versão precisa ser revertida.

## Problema que estamos resolvendo

Sem uma estratégia de rollback formalmente definida:

- Reverter um deploy problemático tende a virar uma ação manual e ad-hoc no servidor, quebrando a premissa de fonte única da verdade (ADR-001) e deixando o Git desatualizado em relação ao que realmente está rodando.
- Sem critérios objetivos de saúde, a decisão de "isso precisa de rollback" fica dependente de percepção humana sob pressão de incidente, aumentando o tempo até a mitigação (MTTR).
- Sem uma política clara do que é automático vs. manual, cada incidente é resolvido de forma improvisada, sem repetibilidade.

## Decisão

Rollback é a **reversão do estado desejado declarado em Git para uma versão anterior conhecida-boa**, seguida da mesma convergência descrita na ADR-002. Existem dois modos, não mutuamente exclusivos:

### Rollback automático

Disparado pelo próprio Pipeline 2 (ADR-002), sem intervenção humana, imediatamente após uma promoção, quando os **health checks pós-deploy** falham dentro da janela de observação.

**Critérios de acionamento (health checks):**

- **Liveness** — o processo/serviço da nova versão sobe e permanece de pé (não cai em crash loop).
- **Readiness** — o serviço responde a um endpoint/sinal de prontidão dentro do tempo esperado.
- **Verificação funcional mínima** — um conjunto pequeno e obrigatório de verificações de que a aplicação está servindo corretamente (ex.: rota de saúde retorna sucesso, dependências críticas — banco, filas — estão acessíveis).
- **Janela de observação** — a nova versão precisa permanecer saudável por um período mínimo de observação contínua antes de ser considerada estável; falha de saúde durante essa janela aciona reversão automática para a versão imediatamente anterior.

Se qualquer critério obrigatório falhar dentro da janela de observação, o agente de reconciliação reverte automaticamente o estado desejado do ambiente para a última versão conhecida-boa (a versão que estava implantada e saudável imediatamente antes da promoção), sem esperar por decisão humana. O rollback automático é ele próprio registrado como um evento em Git (commit automatizado), preservando a auditoria.

Rollback automático é aplicável, no mínimo, a **Staging e Production**. Development pode operar sem rollback automático, dado seu propósito de iteração rápida (ver ADR-005).

### Rollback manual

Disparado por decisão humana, através do mesmo mecanismo declarativo — um PR revertendo `versions.env` para uma versão anterior — quando:

- Um problema é detectado que os health checks automáticos não capturam (ex.: regressão funcional silenciosa, degradação percebida por métricas de negócio, relato de usuário).
- É necessário reverter uma versão que já passou da janela de observação inicial e está rodando establemente há mais tempo, mas se mostrou problemática depois.
- A decisão de reverter envolve trade-offs que exigem julgamento humano (ex.: a nova versão tem um bug conhecido, mas também uma correção crítica de segurança — decidir se o custo de reverter supera o de conviver com o bug).

Rollback manual segue o mesmo fluxo de aprovação de uma promoção normal para aquele ambiente (ver ADR-005), com uma exceção: para incidentes em Production classificados como críticos, o critério de aprovação pode ser reduzido a um único aprovador (rollback de emergência), formalizado como parte do runbook de incidente correspondente — não como uma exceção silenciosa à política, mas como uma via explicitamente definida.

### Versionamento (pré-condição para rollback)

Rollback só é possível porque a ADR-001 exige que toda versão implantada seja imutável e held de forma permanente no registry de imagens. **Nenhuma imagem publicada é removida ou sobrescrita.** O histórico de `versions.env` no Git é, por si, o índice de "para qual versão eu poderia reverter agora" — cada commit anterior representa um estado desejado válido e reproduzível.

## Motivação

Tratar rollback como "deploy de uma versão anterior" em vez de um mecanismo separado elimina uma classe inteira de complexidade: não existe lógica de reversão a manter, testar e operar paralelamente à lógica de deploy — é a mesma lógica, com a direção da versão invertida. Isso é uma consequência direta e deliberada da decisão GitOps da ADR-001.

## Benefícios

- **Simetria com deploy.** Nenhuma automação nova é necessária além da já definida na ADR-002; rollback reaproveita 100% do mecanismo de convergência.
- **Velocidade em incidentes.** Rollback automático por falha de health check reduz o tempo de mitigação sem esperar por triagem humana.
- **Auditoria preservada.** Todo rollback, automático ou manual, é um commit em Git — nunca uma ação silenciosa em servidor.
- **Previsibilidade.** Critérios objetivos de acionamento automático removem ambiguidade sobre quando um rollback deveria ter acontecido.

## Limitações

- **Health checks automáticos não capturam tudo.** Regressões funcionais sutis, problemas de dados ou degradação de negócio não aparecem como falha de liveness/readiness — por isso rollback manual continua sendo necessário como complemento, não substituído pelo automático.
- **Rollback não desfaz efeitos colaterais externos.** Reverter a versão de código implantada não reverte migrações de banco de dados já aplicadas, mensagens já publicadas em filas, ou side effects em sistemas externos. A compatibilidade entre versões consecutivas do artefato (especialmente em relação a schema de dados) é responsabilidade do repositório de aplicação, fora do escopo desta ADR — mas é uma dependência crítica para que rollback seja seguro.
- **Janela de observação é uma troca entre velocidade e segurança.** Uma janela curta detecta problemas mais rápido, mas aumenta o risco de considerar uma versão "estável" prematuramente; uma janela longa é mais segura, mas atrasa a confirmação de deploys bem-sucedidos. O valor exato é uma decisão de implementação/tunning, não fixada nesta ADR.

## Consequências

- Toda promoção para Staging e Production deve, a partir da implementação desta arquitetura, ser seguida automaticamente de uma janela de observação com health checks obrigatórios — nenhuma promoção é considerada "concluída" antes disso.
- Repositórios de aplicação devem garantir compatibilidade retroativa mínima (especialmente de schema de dados) entre uma versão e sua predecessora imediata, para que rollback seja operacionalmente seguro — este requisito deve ser comunicado aos times de produto.
- Runbooks (`docs/runbooks/`, fora do escopo de conteúdo desta sprint) deverão formalizar, por produto/ambiente quando necessário, o procedimento de rollback manual de emergência e seus critérios de aprovação reduzida.

## Alternativas consideradas

1. **Rollback como mecanismo técnico separado** (ex.: snapshot de infraestrutura, backup/restore de container), independente da declaração de estado em Git.
2. **Somente rollback manual**, sem reversão automática por health check.
3. **Somente rollback automático**, sem via manual, com toda reversão disparada exclusivamente por critérios de saúde monitorados.

## Alternativas rejeitadas

1. **Rollback como mecanismo técnico separado** — rejeitado porque duplica a lógica de convergência já definida na ADR-002 em um caminho de código paralelo, aumentando a superfície de manutenção e criando risco de os dois mecanismos divergirem em comportamento. Também quebraria a auditoria unificada em Git, já que um rollback por snapshot não produziria necessariamente um commit correspondente.

2. **Somente rollback manual** — rejeitado por aumentar desnecessariamente o tempo de mitigação em falhas objetivamente detectáveis (crash loop, readiness falhando), que não exigem julgamento humano para serem revertidas. Em Production, minutos de indisponibilidade adicional por espera de triagem humana são um custo real e evitável.

3. **Somente rollback automático** — rejeitado porque nem todo problema que justifica reversão é detectável por health check (ver "Limitações" acima). Depender exclusivamente de critérios automáticos deixaria sem resposta formal exatamente os casos mais difíceis — regressões silenciosas — que costumam ser os mais custosos.

## Atualização (Sprint 1.1) — rollback por tag+digest, não só por tag

Evolução, não substituição — rollback continua sendo "a mesma mecânica de convergência,
aplicada à versão anterior" (a decisão central desta ADR não muda). O refinamento é sobre
**qual identidade** define "a versão anterior" (ver [docs/versioning.md](../docs/versioning.md)).

**Antes:** rollback restaurava uma tag (SHA de commit) anterior — implicitamente confiava que a
tag ainda apontava para o mesmo conteúdo que apontava quando estava rodando.

**Agora:** rollback restaura um **par tag+digest**. O snapshot capturado antes de cada deploy
(usado tanto pelo rollback automático quanto como referência para rollback manual) passa a
registrar o digest realmente em execução — obtido via `docker inspect`, não declarado por nós —
além da tag. Ao reverter, o digest da imagem baixada é verificado contra esse snapshot antes de
subir o container, pela mesma razão detalhada na atualização da ADR-002: uma tag, mesmo
"imutável por política", não é uma garantia técnica — o digest é. **Nunca se reverte para "a tag
que hoje se chama X" sem confirmar que aponta para o digest esperado.**

Isso vale tanto em modo `release.yml` quanto em modo legado (`versions.env`) — a captura de
digest via `docker inspect` não depende do contrato declarativo, é sempre feita a partir do que
o Docker relata como realmente em execução.

**Rollback semântico por release (`1.2.1 → 1.2.0`):** o operador continua pensando em termos de
release SemVer; tecnicamente, reverter para uma release mais antiga que o último snapshot exige
fornecer explicitamente o par tag+digest correspondente (hoje obtido do histórico de commits de
`release.yml`) — não há, nesta sprint, um índice de releases que permita "reverter para 1.2.0"
sem esse dado. Ver "Extensões futuras" em [docs/versioning.md](../docs/versioning.md).

**O que não muda:** os critérios de acionamento automático (health check), a distinção entre
rollback automático e manual, e a recomendação de que rollback automático deveria, no alvo final
da arquitetura, gerar um commit automatizado em Git — gap já registrado como desvio conhecido na
Sprint 1 (`docs/deployment-flow.md`) e ainda não fechado nesta sprint.

## Referências cruzadas

- [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)
- [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)
- [ADR-005 — Environment Promotion](./ADR-005-environment-promotion.md)
- [docs/versioning.md](../docs/versioning.md) — detalhamento completo do refinamento da Sprint 1.1
