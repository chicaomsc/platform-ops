# ADR-004 — Secrets Management

## Status

Aceito — 2026-08-23

Depende de: [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)

## Contexto

A ADR-001 declara o Git como fonte única da verdade do **estado desejado**. Isso cria um risco explícito que precisa de uma fronteira clara: estado desejado não é sinônimo de "tudo que configura um ambiente" — segredos (credenciais, chaves, tokens) **nunca** podem ser parte do que é versionado em texto plano em Git, mesmo em um repositório privado. Esta ADR define essa fronteira sem ambiguidade.

## Problema que estamos resolvendo

- Sem uma política explícita, a tendência natural em um modelo "tudo é declarativo em Git" é declarar segredos junto com o resto da configuração — o que transforma qualquer vazamento de acesso ao repositório (mesmo privado) em um vazamento de credenciais de produção.
- Um repositório Git preserva histórico permanentemente; um segredo commitado por engano continua exposto no histórico mesmo após ser removido do estado atual, exigindo reescrita de histórico e rotação de credencial — um custo alto e evitável.
- Múltiplos produtos e múltiplos ambientes multiplicam o número de segredos distintos a gerenciar (JWT, banco, Cloudflare, SSH, tokens de terceiros) — sem uma convenção única, cada produto tende a inventar sua própria forma de lidar com isso.

## Decisão

**Regra fundamental: o Git armazena *referências* a segredos, nunca *valores* de segredos.**

O `platform-ops` declara *quais* segredos um ambiente de um produto precisa (nome lógico, propósito, onde o valor real deve ser buscado em tempo de deploy), mas o valor real nunca transita por um commit, PR, log de CI ou arquivo versionado.

### O que pode ficar no Git

- **Referências nomeadas a segredos** (ex.: nome da secret no cofre/gerenciador de segredos, sem o valor).
- **Metadados de segredo**: qual produto/ambiente o consome, propósito, rotação esperada, responsável.
- **Configuração não sensível**: URLs públicas, nomes de serviço, flags de feature, timeouts, réplicas, e qualquer valor cujo vazamento não representa risco de segurança.
- **Estrutura de quais segredos existem por ambiente**, sem os valores (ex.: um `metadata.yml` pode declarar que o ambiente de produção do produto X depende de um segredo de banco de dados e de um JWT signing key, referenciando seus nomes no gerenciador de segredos).

### O que nunca pode ficar no Git

- Qualquer valor de credencial em texto plano: senhas, chaves privadas, tokens de acesso, connection strings completas com credenciais embutidas.
- Chaves SSH privadas.
- JWT signing keys / secrets.
- Tokens de API de terceiros (Cloudflare, provedores de infraestrutura, integrações).
- GitHub Secrets **não são geridos como arquivo** — são configurados diretamente na plataforma do GitHub (Settings → Secrets), nunca refletidos como arquivo neste repositório.
- Arquivos `.env` com valores reais preenchidos (apenas `.env.example`/templates sem valores, se necessário como documentação de quais variáveis existem).
- Qualquer segredo específico de ambiente embutido diretamente em `versions.env`, `metadata.yml` ou qualquer arquivo de estado desejado.

### Tratamento por tipo de segredo

| Tipo | Onde vive o valor real | O que fica no `platform-ops` |
|---|---|---|
| **JWT signing keys** | Gerenciador de segredos (cofre), injetado em tempo de execução/deploy | Referência ao nome da secret e qual serviço a consome |
| **Credenciais de banco de dados** | Gerenciador de segredos, escopado por ambiente | Referência ao nome da secret; nunca connection string completa |
| **Tokens Cloudflare** | Gerenciador de segredos ou GitHub Secrets (se usado apenas em automação de CI/CD) | Referência de qual automação consome, sem o valor |
| **Chaves SSH** | Gerenciador de segredos / agente SSH do agente de reconciliação; nunca em arquivo versionado | Referência ao servidor/uso, nunca a chave privada |
| **Tokens de terceiros (APIs externas)** | Gerenciador de segredos, escopado por produto/ambiente | Referência de qual produto/ambiente consome |
| **GitHub Secrets** | Configurados nativamente na plataforma GitHub, por repositório/ambiente | Nada além de documentação de quais secrets são esperadas e seu propósito |
| **Variáveis por ambiente (não sensíveis)** | Diretamente em `metadata.yml`/`versions.env` deste repositório | O valor completo, versionado normalmente |

### Injeção em tempo de deploy

O valor real de um segredo é resolvido e injetado **apenas no momento da convergência** (ADR-002), pelo agente de reconciliação, a partir do gerenciador de segredos — nunca antes disso, nunca em um artefato intermediário persistido (log, cache, arquivo temporário não descartado). O repositório de aplicação (ADR-001) também nunca tem acesso a segredos de ambientes além dos estritamente necessários ao seu próprio pipeline de CI (ex.: credencial de publicação no registry de imagens), e essas credenciais de CI são geridas via GitHub Secrets do próprio repositório de aplicação, fora do `platform-ops`.

## Motivação

Separar referência de valor é o único jeito de manter a promessa central da ADR-001 (Git como fonte única da verdade do estado desejado, com histórico auditável e público entre a equipe) sem transformar esse mesmo histórico em um ativo de altíssimo risco. Um repositório privado não é controle de segurança suficiente para segredos de produção — acesso de leitura ao repositório (times, CI, integrações, ex-colaboradores com tokens não revogados) não deveria implicar acesso a credenciais de produção.

## Benefícios

- **Superfície de vazamento reduzida.** Comprometer o repositório Git nunca compromete uma credencial real.
- **Rotação simplificada.** Trocar o valor de um segredo não exige nenhum commit — é uma operação isolada no gerenciador de segredos, sem tocar no estado desejado declarado.
- **Least privilege natural.** Acesso de leitura ao `platform-ops` (necessário para todo colaborador entender o estado do sistema) não implica acesso a segredos — os dois sistemas de permissão são independentes.
- **Auditoria de acesso a segredos centralizada** no gerenciador de segredos, em vez de fragmentada entre histórico de Git e sistemas variados por produto.

## Limitações

- **Dependência de um gerenciador de segredos externo confiável e disponível.** A escolha específica da ferramenta é uma decisão de implementação, não coberta por esta ADR.
- **Referências desatualizadas são um risco silencioso.** Se um segredo é rotacionado ou removido do gerenciador sem atualizar a referência (ou vice-versa), a falha só aparece em tempo de deploy — não há como o Git, sozinho, validar que uma referência ainda é válida.
- **Segredos usados apenas em automação de GitHub Actions** (GitHub Secrets nativos) vivem em um sistema de permissão diferente do gerenciador de segredos de infraestrutura, exigindo disciplina para manter os dois inventariados de forma consistente na documentação.

## Consequências

- Nenhum PR neste repositório deve, em hipótese alguma, ser aprovado se introduzir um valor de segredo — isso deve ser tratado como incidente de segurança (rotação imediata da credencial exposta), não apenas como revert do commit, já que o histórico de Git preserva o valor mesmo após remoção.
- A implementação (fora do escopo desta sprint) deve prover um mecanismo padronizado, reutilizável por todo produto, de resolução de referência → valor em tempo de deploy.
- Onboarding de um novo produto deve incluir, como parte do template (`templates/app/`), a convenção de como declarar referências a segredos — não os segredos em si.

## Alternativas consideradas

1. **Segredos criptografados versionados em Git** (ex.: valor cifrado no próprio repositório, decifrado em tempo de deploy com uma chave mestra).
2. **Um gerenciador de segredos por produto**, em vez de uma convenção e (possivelmente) uma instância compartilhada gerida pelo `platform-ops`.
3. **Confiar inteiramente em GitHub Secrets** para todo tipo de segredo, incluindo os usados em runtime de aplicação (não apenas em CI).

## Alternativas rejeitadas

1. **Segredos criptografados versionados em Git** — considerada, mas rejeitada como padrão default desta arquitetura porque desloca o problema em vez de eliminá-lo: a segurança do sistema inteiro passaria a depender da proteção de uma única chave mestra de decriptação, e o histórico de Git ainda preservaria permanentemente o texto cifrado (risco caso o algoritmo/chave seja comprometido no futuro). Não é descartada como técnica complementar em casos específicos de implementação, mas não é a política padrão desta ADR — a política padrão é ausência total de valor de segredo em Git, cifrado ou não.

2. **Um gerenciador de segredos por produto** — rejeitado pela mesma razão estrutural das ADRs anteriores: multiplica por N produtos um problema (gestão segura de segredos) que deveria ter solução única e compartilhada, aumentando custo operacional e risco de inconsistência (um produto com política mais fraca que outro).

3. **Confiar inteiramente em GitHub Secrets para tudo** — rejeitado porque GitHub Secrets é adequado para segredos consumidos **dentro de um workflow de CI/CD** (ex.: credencial de publicação de imagem), mas não foi desenhado como gerenciador de segredos de runtime de aplicação (rotação, escopo granular por ambiente/servidor, auditoria de acesso em tempo de execução). Usá-lo para tudo forçaria segredos de produção a transitar por execuções de workflow, ampliando desnecessariamente a superfície de exposição.

## Referências cruzadas

- [ADR-001 — GitOps Strategy](./ADR-001-gitops-strategy.md)
- [ADR-002 — Deployment Pipeline](./ADR-002-deployment-pipeline.md)
