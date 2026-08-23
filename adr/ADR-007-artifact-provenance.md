# ADR-007 — Artifact Provenance

## Status

Aceito — 2026-08-23

Depende de: [ADR-001](./ADR-001-gitops-strategy.md), [ADR-002](./ADR-002-deployment-pipeline.md), [ADR-006 — Release Management](./ADR-006-release-management.md)

## Contexto

A ADR-006 define o que é uma release. Esta ADR define, em profundidade técnica, como se prova — não apenas se declara — que um artefato implantado corresponde exatamente ao que foi declarado. É a formalização e o detalhamento técnico do refinamento introduzido na Sprint 1.1 ("Atualização" nas ADR-001/002/003), agora como decisão própria com espaço para tratar proveniência, rastreabilidade, integridade e o roadmap de supply chain que a Sprint 1.1 apenas mencionou.

## Os três identificadores e suas funções

```
Vantry 1.2.0
    ↓  (identifica semanticamente — para humanos, para promoção, para changelog)
commit abc123...
    ↓  (identifica o código-fonte — proveniência)
backend:1.2.0
    ↓  (tag — ponteiro humano-legível, mutável por natureza técnica ainda que imutável por política)
sha256:AAA...
    (digest — identidade criptográfica do conteúdo, a única genuinamente imutável)
```

**Tag identifica semanticamente.** `1.2.0` é uma etiqueta — conveniente, memorável, ordenável — mas tecnicamente é só um ponteiro no registry, que *poderia* ser reescrito (por erro operacional, por um ator malicioso com acesso ao registry, ou por uma ferramenta mal configurada). "Imutável" para uma tag é uma política que este pipeline aplica e verifica, não uma garantia inerente ao formato.

**Git SHA identifica o código.** Responde "qual código-fonte gerou isto" — essencial para auditoria e para debugar, mas não diz nada, por si só, sobre o artefato binário resultante (o mesmo commit poderia, em tese, ser buildado de formas diferentes em builds não reprodutíveis).

**Digest identifica criptograficamente.** `sha256:...` é o hash do conteúdo da imagem — dois digests iguais garantem, matematicamente, bytes idênticos. É a única das três identidades que não depende de confiança em um sistema externo (o registry) permanecer correto ao longo do tempo — pode ser recalculado e conferido a qualquer momento.

## Release Manifest — proveniência como estrutura

O manifest (`release.yml`, schema `platform-ops/v1` — contrato completo em [docs/release-management.md](../docs/release-management.md)) é o registro estruturado que amarra os três identificadores:

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
    image: ghcr.io/chicaomsc/contractor-platform-backend
    tag: "1.2.0"
    digest: "sha256:..."
  # frontend, caddy: mesma forma
```

`image` é declarado **dentro do manifest**, não apenas em `metadata.yml` — decisão deliberada desta ADR: duplica, sim, a informação de `metadata.yml` (`registry.images.*`), mas torna o manifest **autocontido** — um auditor, uma GitHub Release, ou uma ferramenta externa consegue reconstruir a proveniência completa de uma release lendo apenas `release.yml`, sem precisar cruzar com outro arquivo. `scripts/lib/common.sh` usa o `image` do manifest diretamente (não volta a consultar `metadata.yml`) em modo `release` — a duplicação é controlada e documentada, não acidental.

## Rastreabilidade

Toda imagem publicada carrega duas tags apontando para o mesmo digest: a versão SemVer (`1.2.0`) e uma tag de rastreabilidade (`sha-<commit>`) — permite localizar a imagem a partir do commit sem precisar saber, a priori, qual release SemVer o usou (útil para debugging e para builds intermediários que nunca viram uma release oficial).

## Integridade — verificação em tempo de deploy

Dois pontos de verificação técnica, implementados em `scripts/deploy.sh`/`scripts/rollback.sh` via `scripts/lib/common.sh`:

1. **Pré-pull (guarda de integridade "ao vivo"):** antes de qualquer mudança, se a tag declarada já está em execução na VPS com um digest diferente do agora declarado, o deploy é recusado — indicaria que a tag foi sobrescrita no registry ou que o manifest tem um digest errado para uma tag já implantada.

2. **Pós-pull, pré-up (verificação do artefato baixado):** o digest da imagem efetivamente baixada é comparado ao declarado no manifest. Divergência aborta antes de `up -d` — nenhum container roda um artefato cuja identidade não foi confirmada.

3. **Imutabilidade histórica (nova nesta ADR, ver "Imutabilidade" abaixo):** antes mesmo de conectar via SSH, o histórico de commits do próprio `platform-ops` é consultado para garantir que a versão declarada, se já vista antes, sempre apontou para o mesmo `sourceCommit` e os mesmos digests.

Três resultados possíveis em qualquer verificação de digest: `MATCH` (segue), `MISMATCH` (aborta, nunca silencioso), `UNKNOWN` — RepoDigests vazio, situação que pode ocorrer legitimamente (imagem local/de teste) — segue com aviso explícito, nunca tratado como sucesso silencioso nem como erro fatal.

## Imutabilidade — aplicação técnica via histórico Git

Esta é a peça nova mais significativa desta ADR frente à Sprint 1.1: a imutabilidade de uma release (ADR-006) não é apenas política documentada — é **verificada mecanicamente** contra o histórico do próprio repositório `platform-ops`.

`validate_release_immutability` (`scripts/lib/common.sh`) usa `git log --follow` sobre o `release.yml` do app/ambiente para encontrar todo commit anterior que já declarou a versão sendo processada agora. Para cada um, compara `sourceCommit` e os três digests. Qualquer divergência — mesmo que a intenção seja "só corrigir um erro de digitação no digest" — é bloqueada com uma mensagem explícita instruindo a usar a próxima versão. Esta verificação:

- Roda **antes de qualquer conexão SSH** — é puramente local, rápida, sem custo de rede.
- É automaticamente satisfeita (não bloqueia) quando a release nunca foi declarada antes, ou quando é redeclarada de forma idêntica (ex.: um commit que só reformata o YAML sem mudar valores).
- Depende do repositório `platform-ops` ser, de fato, um repositório Git com histórico — funciona apenas a partir do momento em que commits reais existirem (nesta sprint, o repositório ainda não tem nenhum commit — ver relatório).

## Supply chain — roadmap futuro (não implementado)

Reconhecido como direção futura, deliberadamente não implementado nesta sprint (nenhuma ferramenta instalada, nenhuma automação criada):

- **SBOM** (Software Bill of Materials) — inventário de dependências de cada imagem, gerado no momento do build. Permitiria responder "quais bibliotecas/versões estão em produção" sem inspecionar a imagem manualmente.
- **Cosign** (sigstore) — assinatura criptográfica de imagens, permitindo verificar não apenas *o que* foi publicado (digest) mas *que a publicação veio de fato do pipeline de CI autorizado* (autenticidade da origem, não só integridade do conteúdo).
- **SLSA provenance** — atestação formal, no formato do framework SLSA, de como um artefato foi construído (qual pipeline, quais inputs, qual nível de isolamento do build).
- **Vulnerability scanning** — verificação automática de CVEs conhecidas nas imagens antes da promoção para ambientes mais sensíveis (poderia se tornar um critério adicional de promoção na ADR-005).
- **Attestations** — metadados assinados e verificáveis anexados ao artefato (ex.: "este artefato passou nos testes X", "este artefato foi aprovado por Y").

Nenhum desses itens é necessário para a proveniência baseada em tag+digest+commit já implementada funcionar — eles adicionam camadas de **autenticidade** e **auditabilidade de processo** acima da camada de **integridade de conteúdo** que esta ADR já resolve. Prioridade e sequenciamento ficam para quando o pipeline de build/publish (hoje fora do repositório `platform-ops`) entrar em escopo de implementação.

## Deploy por digest — avaliação para esta sprint

Objetivo ideal de longo prazo: o runtime executa o artefato pelo digest (`ghcr.io/.../backend@sha256:...`), não apenas pela tag (`ghcr.io/.../backend:1.2.0`) — eliminando por completo a superfície de risco de uma tag reescrita, já que o `docker compose` resolveria diretamente o conteúdo imutável.

**Análise feita nesta sprint:** o mecanismo real de pull/up (`docker compose`) depende do `docker-compose.prod.yml` na VPS, que pertence à infraestrutura da aplicação — fora deste repositório, e cujo conteúdo exato **não foi inspecionado** (mesma pré-condição pendente desde a Sprint 1: o compose file precisa referenciar variáveis de tag por componente, e hoje não se sabe se/como ele suporta uma referência por digest).

**Decisão:** não forçar a mudança do mecanismo de pull real nesta sprint (isso exigiria alterar um arquivo fora do nosso controle e não confirmado, exatamente o caso que a Sprint 1.2 instruiu a não forçar). **Implementado, de forma aditiva e sem risco:** `remote_pull_versions`/`remote_up_versions` (`scripts/lib/common.sh`) agora também exportam `BACKEND_DIGEST_REF`/`FRONTEND_DIGEST_REF`/`CADDY_DIGEST_REF` (formato `<imagem>@sha256:...`) ao lado das variáveis de tag já existentes. Nenhum compose file conhecido referencia essas variáveis hoje — são inertes, não mudam o comportamento real do deploy, que continua por tag. Quando o `docker-compose.prod.yml` for confirmado e migrado para usar essas variáveis no lugar da tag, o deploy passa a ser por digest sem exigir nenhuma mudança adicional nos scripts.

## Motivação

Sem uma ADR dedicada, a distinção entre os três identificadores (formalizada na prática pela Sprint 1.1) corria o risco de ficar espalhada e sub-justificada entre várias ADRs. Esta ADR consolida a decisão técnica, formaliza o mecanismo de verificação de imutabilidade histórica (novo nesta sprint), e documenta explicitamente o roadmap de supply chain sem se comprometer prematuramente com ferramentas específicas.

## Benefícios

- Prova técnica, não apenas política, de identidade de artefato — divergência é sempre bloqueada, nunca apenas logada.
- Imutabilidade de release deixa de depender de disciplina humana e passa a ser verificada mecanicamente contra o histórico Git.
- Roadmap de supply chain documentado antecipadamente, permitindo que decisões de arquitetura futuras (ex.: onde armazenar SBOMs) considerem o que já existe em vez de redesenhar do zero.
- Caminho para deploy por digest preparado sem custo nem risco imediato (mudança aditiva, inerte até o compose file migrar).

## Limitações

- A verificação de imutabilidade histórica depende de o `platform-ops` ter, de fato, commits reais no histórico — não protege contra uma primeira declaração incorreta (garbage in, garbage out) nem substitui revisão de PR.
- `RepoDigests` vazio (`UNKNOWN`) é tratado como aviso, não bloqueio — um ambiente onde isso acontece sistematicamente (ex.: imagens nunca passam por um registry remoto) perderia a proteção de integridade sem um erro explícito de configuração além do log.
- Deploy por digest permanece não realizado de fato — a preparação aditiva não substitui a confirmação e possível migração do compose file real, que segue como pendência.
- Nenhuma verificação de assinatura (Cosign) ou proveniência formal (SLSA) existe — digest prova integridade de conteúdo, não autenticidade de origem (alguém com acesso de push ao registry ainda poderia publicar um artefato malicioso sob uma tag nova, sem violar nenhuma das verificações desta ADR).

## Consequências

- Todo app em modo `release` tem sua imutabilidade verificada automaticamente a cada deploy — nenhuma ação adicional do operador é necessária além de nunca reescrever manualmente o histórico de `release.yml`.
- Rebase ou reescrita de histórico (`git rebase`, `git filter-branch`) sobre commits que contêm `release.yml` de releases já publicadas deve ser evitado — quebraria a base sobre a qual a verificação de imutabilidade opera (`git log --follow`). Isso é consistente com boas práticas gerais de Git em repositórios compartilhados, não uma restrição nova imposta por esta ADR.
- A decisão de não forçar deploy por digest nesta sprint deixa uma pendência explícita, documentada em vez de forçada — ver relatório da Sprint 1.2.

## Alternativas consideradas

1. **Verificar imutabilidade só no momento do PR** (ex.: um workflow de CI que roda em todo PR ao `platform-ops` e recusa merge se violar imutabilidade), em vez de no momento do deploy.
2. **Confiar apenas na tag SemVer como imutável por convenção**, sem verificação de digest.
3. **Forçar a migração do compose file para deploy por digest nesta sprint**, mesmo sem confirmação do arquivo real.
4. **Adotar Cosign/SBOM já nesta sprint**, antecipando a necessidade.

## Alternativas rejeitadas

1. **Verificar imutabilidade só no PR** — não rejeitada como complementar (é, na verdade, uma evolução natural — ver "Pendências" no relatório), mas rejeitada como *substituta* da verificação em tempo de deploy: um PR poderia ser mergeado sem essa checagem (ex.: workflow de CI não configurado ainda), e a verificação em `deploy.sh` é a última linha de defesa antes de qualquer mudança real na VPS — mantê-la ali é estritamente mais seguro que confiar somente em um gate de CI.

2. **Confiar apenas na tag como imutável por convenção** — rejeitado pelo motivo central desta ADR: convenção não é prova. Um erro operacional ou um registry comprometido quebraria essa suposição silenciosamente, exatamente o cenário que motivou a introdução de digests na Sprint 1.1.

3. **Forçar a migração do compose file nesta sprint** — rejeitado explicitamente por instrução da Sprint 1.2 ("se exigir mudança grande no repo da aplicação/VPS, documente... e não force"). Mudar um arquivo fora deste repositório, não confirmado, sob a arquitetura de "não alterar produção" desta sprint, seria uma ação de alto risco e fora do escopo de controle direto do `platform-ops`.

4. **Adotar Cosign/SBOM já nesta sprint** — rejeitado por instrução explícita da Sprint 1.2 ("não instalar ferramentas agora"). Também seria prematuro arquiteturalmente: o pipeline de build/publish (onde essas ferramentas se encaixam) ainda não existe dentro do escopo implementado — adicionar ferramentas de assinatura/SBOM antes de ter o pipeline que as consumiria é otimização prematura.

## Referências cruzadas

- [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)
- [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)
- [ADR-003 — Rollback Strategy](./ADR-003-rollback-strategy.md)
- [ADR-006 — Release Management](./ADR-006-release-management.md)
- [docs/release-management.md](../docs/release-management.md)
- [docs/versioning.md](../docs/versioning.md)
