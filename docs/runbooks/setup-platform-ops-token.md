# Runbook — Configurar `PLATFORM_OPS_TOKEN` (promoção automática de releases)

Procedimento manual, único, de configuração de acesso. Não executado por nenhuma
automação — feito uma vez por um administrador com acesso aos dois repositórios
(`chicaomsc/contractor-plataform` e `chicaomsc/platform-ops`).

## Por que este token existe

`contractor-plataform/.github/workflows/release-publish.yml` (job
`promote-platform-ops`) precisa abrir uma Pull Request neste repositório
(`platform-ops`) — atualizando `apps/vantry/production/release.yml` — sempre que
uma release SemVer é publicada. O `GITHUB_TOKEN` padrão de uma Actions run em
`contractor-plataform` só tem permissão sobre o próprio repositório; ele **não
consegue** escrever em `platform-ops`. É preciso um token dedicado.

## Por que um PAT fine-grained, não um GitHub App

Um GitHub App resolveria o mesmo problema, mas exige criar o App, gerenciar uma
chave privada, e instalar o App no repositório — complexidade real para um caso
de uso de **uma única automação, escrevendo em um único repositório, com duas
permissões**. Um Personal Access Token **fine-grained** (não o PAT clássico, que
não tem escopo por repositório) cobre exatamente o mesmo requisito de menor
privilégio — restrito a um repositório nomeado, com permissões nomeadas — sem a
sobrecarga operacional de um App. Se o número de automações cross-repo crescer no
futuro, reavaliar a migração para um GitHub App nesse momento; hoje seria
complexidade adicionada sem necessidade correspondente.

## Passo a passo

1. Uma conta com acesso de **admin** em `chicaomsc/platform-ops` deve gerar o
   token — recomenda-se uma conta de serviço/bot dedicada, se a organização já
   tiver uma; um PAT de conta pessoal funciona tecnicamente, mas liga o token à
   permanência daquela conta na organização.
2. GitHub → **Settings** (da conta que vai gerar o token) → **Developer settings**
   → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
3. **Resource owner:** a organização/conta dona de `chicaomsc/platform-ops`.
4. **Repository access:** **Only select repositories** → selecionar **apenas**
   `platform-ops`. Nunca "All repositories".
5. **Permissions** (repository permissions, não organization/account):
   - **Contents:** Read and write (criar branch, escrever `release.yml`, push).
   - **Pull requests:** Read and write (abrir a PR, e checar se uma já existe —
     idempotência).
   - Todas as demais permissões: **No access** (padrão — não alterar).
6. **Expiration:** definir uma data (recomendado 90–180 dias) e agendar a
   renovação — fine-grained tokens não suportam "no expiration" para tokens de
   organização na maioria das configurações; se este repositório permitir, ainda
   assim prefira uma expiração com renovação programada a "nunca expira".
7. Gerar o token. **Copiar o valor imediatamente** — o GitHub não mostra de novo.
8. Ir para `chicaomsc/contractor-plataform` → **Settings** → **Secrets and
   variables** → **Actions** → **New repository secret**.
9. Nome do secret: **`PLATFORM_OPS_TOKEN`** (exatamente este nome — é o que
   `release-publish.yml` referencia via `secrets.PLATFORM_OPS_TOKEN`).
10. Colar o valor do token, salvar.

## Verificação

Depois de configurado, a próxima release SemVer publicada em
`contractor-plataform` deve abrir automaticamente uma PR aqui em `platform-ops`,
branch `promote/vantry-<versão>`, título `chore(vantry): promote <versão> to
production`. Se o job `promote-platform-ops` falhar com a mensagem
`secrets.PLATFORM_OPS_TOKEN não está configurado`, o secret não foi criado (ou
foi criado com nome diferente) — revisar o passo 9.

## O que este token NUNCA deve ter

- Acesso a qualquer repositório além de `platform-ops`.
- Permissão de **Administration**, **Actions**, **Secrets**, ou qualquer escopo
  fora de Contents + Pull requests.
- Ser reaproveitado por qualquer outra automação além de
  `release-publish.yml`/job `promote-platform-ops`.

## Revogação / rotação

**Settings → Developer settings → Fine-grained tokens** → revogar o token
antigo, gerar um novo seguindo os mesmos passos, atualizar o secret em
`contractor-plataform` (passo 8–10). A PR de promoção em andamento (se houver)
não é afetada por uma rotação — só a próxima execução do workflow usa o novo
token.
