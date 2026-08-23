# Runbook — Provisionar acesso SSH do GitHub Environment `production`

**Quando usar:** antes da primeira execução real do workflow `deploy-production.yml`. Esta é
uma ação de provisionamento de credencial, fora do escopo de automação do `platform-ops` —
feita manualmente, uma vez, por um operador com acesso à VPS e ao repositório GitHub.

## Pré-requisitos

- Acesso sudo à VPS `hetzner-prod-01` (46.225.52.238) com um usuário que já tenha SSH válido.
- Permissão de administrador no repositório GitHub para criar Environments e secrets.

## Passo 1 — Gerar uma chave dedicada (nunca reutilizar uma chave pessoal)

Em uma máquina de confiança (não a VPS, não um laptop compartilhado):

```
ssh-keygen -t ed25519 -C "platform-ops-deploy" -f ./platform-ops-deploy-key -N ""
```

Isso gera `platform-ops-deploy-key` (privada) e `platform-ops-deploy-key.pub` (pública).

## Passo 2 — Autorizar a chave pública na VPS

Como o usuário `deploy` (que já existe, já tem sudo e pertence ao grupo `docker`):

```
ssh deploy@46.225.52.238
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "<conteúdo de platform-ops-deploy-key.pub>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Não é necessário criar um novo usuário — a arquitetura atual já usa `deploy` para todo acesso
operacional (ver `servers/hetzner-prod-01.yml`).

## Passo 3 — Capturar o known_hosts (pinado, não descoberto em runtime)

Da mesma máquina de confiança:

```
ssh-keyscan -t ed25519 46.225.52.238
```

Guarde a linha de saída completa (formato `46.225.52.238 ssh-ed25519 AAAA...`) — será o valor de
`PROD_SSH_KNOWN_HOSTS`. Confirme visualmente que o fingerprint bate com o que a VPS realmente
apresenta (ex.: comparando com `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` executado
diretamente na VPS via um canal já confiável) — o objetivo é evitar aceitar uma chave de host
via TOFU (trust-on-first-use) no primeiro run do workflow.

## Passo 4 — Criar o Environment `production` no GitHub

No repositório `platform-ops` no GitHub: Settings → Environments → New environment →
`production`.

Configurar proteção do Environment (não é feito pelo workflow — é configuração do GitHub):
- **Required reviewers**: pelo menos um aprovador com autoridade de release (ver
  [ADR-005](../../adr/ADR-005-environment-promotion.md)).
- Opcional: restringir a branches específicas (ex.: apenas `main`).

## Passo 5 — Adicionar os secrets ao Environment `production`

Dentro do Environment recém-criado, Add secret:

| Nome | Valor |
|---|---|
| `PROD_SSH_PRIVATE_KEY` | Conteúdo completo de `platform-ops-deploy-key` (a chave **privada**) |
| `PROD_SSH_KNOWN_HOSTS` | A linha capturada no Passo 3 |

## Passo 6 — Destruir a cópia local da chave privada

```
shred -u ./platform-ops-deploy-key 2>/dev/null || rm -P ./platform-ops-deploy-key
rm ./platform-ops-deploy-key.pub
```

A partir daqui, a única cópia da chave privada deve existir no GitHub Environment secret e em
`~/.ssh/authorized_keys` na VPS (que não expõe a chave privada, apenas a pública).

## Validação

Execute o workflow uma vez via `workflow_dispatch` (Actions → Deploy Production (Vantry) → Run
workflow). O passo **Configurar acesso SSH** deve completar sem erro; o passo seguinte deve
conseguir conectar. Se falhar em `Permission denied (publickey)`, revalide o Passo 2. Se falhar
em `Host key verification failed`, revalide o Passo 3.