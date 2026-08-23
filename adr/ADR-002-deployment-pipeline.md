# ADR-002 — Deployment Pipeline

## Status

Aceito — 2026-08-23

Depende de: [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)

## Contexto

A ADR-001 estabelece que o Git é a fonte única da verdade do estado desejado, e que deploy é a convergência do estado real para esse estado declarado. Esta ADR define a **esteira** que produz e consome essa declaração — desde o commit no repositório de aplicação até a versão rodando no servidor-alvo.

Esta ADR descreve exclusivamente **arquitetura da esteira**. Nenhum workflow, script ou pipeline de CI é implementado aqui — isso é trabalho de sprint de implementação, fora do escopo da Sprint 0.

## Problema que estamos resolvendo

Sem uma definição explícita da esteira:

- Cada produto tende a implementar sua própria noção de "o que significa fazer deploy", com etapas diferentes, critérios diferentes e pontos de falha diferentes.
- Não fica claro onde termina a responsabilidade do CI da aplicação e onde começa a responsabilidade da plataforma — o risco concreto é lógica de deploy vazando para dentro do repositório de aplicação (violando a fronteira definida na ADR-001).
- Sem estágios explícitos, não há um ponto único onde aplicar controles (aprovação, validação, gate de segurança) de forma consistente entre produtos.

## Decisão

A esteira de deploy é dividida em **dois pipelines desacoplados**, conectados por um único ponto de integração: a imagem de artefato versionada e imutável.

```
PIPELINE 1 — Integração Contínua (vive no repositório de aplicação)
──────────────────────────────────────────────────────────────────
  commit/PR → build → testes → build de imagem Docker → publicação
  no registry com tag imutável (SHA de commit)

                              │
                              │  (ponto de integração: imagem versionada)
                              ▼

PIPELINE 2 — Entrega Contínua / GitOps (vive no platform-ops)
──────────────────────────────────────────────────────────────────
  PR de atualização de versions.env do ambiente-alvo
      → revisão (ver ADR-005 para critério por ambiente)
      → merge
      → agente de reconciliação detecta divergência entre
        estado desejado (Git) e estado real (infraestrutura)
      → convergência (deploy efetivo no servidor-alvo)
      → health check (ver ADR-003)
      → estado real == estado desejado (deploy concluído)
        ou rollback automático (ver ADR-003) se health check falhar
```

Os dois pipelines nunca compartilham execução direta: o Pipeline 1 não tem credenciais nem conhecimento de infraestrutura de destino; o Pipeline 2 não conhece o código-fonte, apenas a referência de versão. A única interface entre eles é a **tag de imagem imutável no registry**, referenciada por `versions.env`.

### Estágios do Pipeline 1 — Integração Contínua (repositório de aplicação)

1. **Build** — compilação/instalação de dependências do produto.
2. **Testes** — unitários, integração, contrato. Critério de gate: todos obrigatórios devem passar antes de prosseguir.
3. **Build de imagem** — empacotamento em imagem Docker.
4. **Publicação** — push da imagem para o registry, com tag imutável derivada do SHA do commit (ver ADR-001, "Estratégia de versionamento"). Uma imagem publicada nunca é sobrescrita.

Este pipeline é de responsabilidade e propriedade exclusiva de cada repositório de aplicação. O `platform-ops` não o define, não o executa e não impõe sua implementação — apenas exige, como contrato de integração, que o resultado seja uma imagem versionada de forma imutável e publicada em um registry acessível pelo Pipeline 2.

### Estágios do Pipeline 2 — Entrega Contínua / GitOps (platform-ops)

1. **Declaração de intenção** — um PR neste repositório propõe atualizar a versão declarada (`versions.env`) de um ambiente de um produto.
2. **Revisão e aprovação** — critério de aprovação varia por ambiente-alvo (Development, Staging, Production), formalmente definido na ADR-005.
3. **Merge** — a nova versão passa a ser o estado desejado oficial daquele ambiente. Este é o evento auditável (quem, quando, de qual versão para qual versão).
4. **Detecção de divergência** — o agente de reconciliação compara periodicamente (ou por gatilho de webhook de merge) o estado desejado declarado com o estado real observado na infraestrutura.
5. **Convergência (deploy efetivo)** — o agente de reconciliação aplica a mudança necessária para que o estado real alcance o estado desejado.
6. **Verificação de saúde (health check)** — critério de sucesso da convergência; detalhado na ADR-003. Se falhar, aciona rollback automático.
7. **Confirmação de estado estável** — deploy é considerado concluído quando o estado real converge e os health checks passam de forma sustentada por um período de observação.

## Motivação

Separar os dois pipelines por uma interface estritamente definida (imagem imutável) é o que torna a arquitetura escalável para múltiplos SaaS: o Pipeline 1 pode ser tecnicamente diferente entre produtos (linguagens, frameworks, ferramentas de build distintas) sem que isso afete o `platform-ops` em nada, desde que o contrato de saída (imagem versionada publicada) seja respeitado. O Pipeline 2 é idêntico em mecânica para todo produto, o que é o que permite operar N produtos com uma única automação.

## Benefícios

- **Independência tecnológica por produto.** O `platform-ops` nunca precisa conhecer a stack de um SaaS específico.
- **Superfície de credenciais mínima.** Apenas o Pipeline 2 (dentro do `platform-ops`) precisa de acesso à infraestrutura de destino; o Pipeline 1 de cada produto nunca tem essas credenciais.
- **Ponto único de gate.** Toda mudança de estado real passa, sem exceção, pela revisão de PR no `platform-ops` — não existe caminho alternativo de deploy.
- **Rastreabilidade completa.** O histórico de merges no `platform-ops` é, por si só, o histórico completo de deploys de todos os produtos, em todos os ambientes.
- **Falha isolada.** Uma falha no Pipeline 1 de um produto (ex.: build quebrado) não afeta a operação de outros produtos nem a integridade do Pipeline 2.

## Limitações

- **Dois sistemas a operar.** Times precisam entender que "a build passou" (Pipeline 1) e "a versão está implantada" (Pipeline 2) são eventos distintos e desacoplados no tempo — uma imagem publicada não implica implantação automática em nenhum ambiente além do que a política de promoção definir (ADR-005).
- **Latência de reconciliação** (herdada da ADR-001) — o tempo entre merge do PR de estado desejado e a convergência real depende da frequência de verificação do agente de reconciliação.
- **Dependência de um registry de imagens disponível e confiável** como ponto de integração entre os dois pipelines.

## Consequências

- Nenhum repositório de aplicação deve conter lógica de deploy, credenciais de infraestrutura ou conhecimento de servidores/ambientes — se isso existir hoje em algum produto, é uma violação desta arquitetura a ser corrigida na migração para a plataforma.
- Toda mudança de versão implantada, em qualquer produto e ambiente, deve ser rastreável a um PR mergeado neste repositório.
- O `platform-ops` deve prover, como parte da implementação (fora do escopo desta sprint), um agente de reconciliação e um mecanismo de health check reutilizável por todos os produtos.

## Alternativas consideradas

1. **Pipeline único e monolítico**, do commit da aplicação até o deploy em produção, sem separação entre CI e CD/GitOps.
2. **CD por push direto do CI da aplicação** (o job de CI, ao final do build, executa o deploy diretamente).
3. **Um pipeline de entrega contínua por produto**, dentro de cada repositório de aplicação, em vez de um pipeline de entrega único e compartilhado no `platform-ops`.

## Alternativas rejeitadas

1. **Pipeline único e monolítico** — rejeitado porque acopla ciclo de vida de código (rápido, frequente, por produto) ao ciclo de vida de infraestrutura (mais lento, sujeito a aprovação, compartilhado). Um pipeline monolítico também exigiria que o repositório de aplicação tivesse conhecimento e credenciais de todos os ambientes de destino, o que viola a fronteira de responsabilidade definida na ADR-001.

2. **CD por push direto do CI da aplicação** — rejeitado pelo mesmo motivo detalhado na ADR-001: introduz a necessidade de credenciais de infraestrutura de produção dentro de cada repositório de aplicação (multiplicando a superfície de risco por N produtos) e elimina o ponto único de revisão/gate que o modelo de PR no `platform-ops` garante.

3. **Um pipeline de entrega contínua por produto** — rejeitado porque reintroduziria, na prática, N implementações da mesma lógica de reconciliação e promoção, o oposto do objetivo de escalabilidade desta plataforma. A mecânica de "convergir estado real para estado desejado" é idêntica para qualquer produto; deve existir uma única vez.

## Atualização (Sprint 1.1) — verificação de digest no Pipeline 2

Evolução, não substituição — os dois pipelines e o ponto de integração único (imagem
versionada) permanecem exatamente como definidos acima. O refinamento afeta apenas o **estágio
5 (convergência)** do Pipeline 2, quando o app/ambiente já usa o contrato `release.yml` (ver
[docs/versioning.md](../docs/versioning.md)):

Entre "pull" e "up -d" (que antes eram uma única etapa lógica) insere-se uma etapa de
**verificação de digest**: o digest da imagem efetivamente baixada é comparado ao digest
declarado em `release.yml` antes de qualquer container ser recriado. Divergência aborta o
deploy imediatamente, sem alterar nenhum container — nunca sobe uma imagem cujo conteúdo não
bate com o que foi declarado como estado desejado, mesmo que a *tag* seja a esperada. Isso
fecha uma lacuna da versão original desta ADR: "imagem imutável" era uma política (tag não
sobrescrita), não uma garantia verificada em tempo de deploy.

Em app/ambiente ainda no contrato legado (`versions.env`, sem digest declarado), o Pipeline 2
continua exatamente como descrito acima, sem a etapa de verificação — nenhuma quebra.

## Referências cruzadas

- [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)
- [ADR-003 — Rollback Strategy](./ADR-003-rollback-strategy.md)
- [ADR-005 — Environment Promotion](./ADR-005-environment-promotion.md)
- [docs/versioning.md](../docs/versioning.md) — detalhamento completo do refinamento da Sprint 1.1
