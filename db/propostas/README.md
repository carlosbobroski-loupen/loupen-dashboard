# db/propostas — SQL escrito, deliberadamente FORA do runner

Este diretório guarda migrations **escritas e revisáveis, mas não aplicadas e não
aplicáveis por `db/apply.sh`**. O runner varre apenas `db/migrations/*.sql`; nada
daqui é lido por ele, por decisão, não por acidente.

Um arquivo vive aqui quando o trabalho técnico está pronto mas **a decisão que ele
implementa não é técnica** — é de política da empresa, e precisa de gente com
autoridade para ratificá-la. Deixar esse arquivo em `db/migrations/` tem custo real:
o runner tenta aplicá-lo a cada rodada, aborta no meio, e todas as migrations
seguintes deixam de ser aplicadas. Foi exatamente o que aconteceu (ver "Histórico"
abaixo).

## 074_retencao_e_anonimizacao_lgpd.sql

**Status:** escrita em 2026-09-14. **NÃO aplicada.** Movida para cá em 2026-09-16
(`git mv`, histórico preservado).

### O que ela faz

Implementa uma política de retenção e anonimização de dado pessoal:

| Item | Regra proposta |
|---|---|
| Retenção identificável | 18 meses contados do **último evento** do lead |
| Depois disso | anonimização **irreversível** |
| `nome` | vira `'Lead #<id>'` |
| `telefone` | vira `NULL` |
| `email` | vira `'anon:' \|\| sha256(lower(email) \|\| salt)` |
| `empresa` | **fica** (dado firmográfico B2B, não dado pessoal) |
| Eventos, atribuição, funil, agregados | **sobrevivem** — deixam de ser dado pessoal e continuam servindo à análise |

Objetos que ela criaria:

- `privacidade_config` — tabela chave/valor que guarda o `salt_email`, gerado uma
  única vez com `gen_random_bytes(32)` e **nunca** versionado nem rotacionado
  (rotacionar quebraria a correspondência com hashes já gravados).
- `fn_lead_ultimo_evento(bigint)` — último sinal de vida do lead em qualquer fonte.
- `fn_anonimizar_lead(bigint)` — anonimiza UM lead, idempotente. Serve tanto à
  retenção quanto a pedido de eliminação do titular.
- `fn_anonimizar_retencao(int DEFAULT 18, boolean DEFAULT false)` — aplica a
  retenção. **Modo seco por padrão**: com `p_executar = false` devolve quem *seria*
  anonimizado sem escrever nada. Só `p_executar = true` escreve.

### Por que não foi aplicada

1. **É decisão de política, não chamada técnica.** Anonimização é irreversível e
   define por quanto tempo a Loupen guarda dado pessoal identificável. Quem
   responde por LGPD na empresa precisa ratificar 18 meses (ou trocar o número)
   antes de qualquer execução. O arquivo diz isso no próprio cabeçalho e **não é
   parecer jurídico**.
2. **A criação foi barrada pela política de permissão do agente** por tocar em PII
   e definir um `UPDATE` destrutivo — comportamento correto.
3. **Ela aborta hoje, mesmo se alguém tentar.** O `INSERT` do salt chama
   `gen_random_bytes()`, que vem da extensão **`pgcrypto`, não instalada** neste
   banco (instaladas: `plpgsql`, `pg_trgm`, `fuzzystrmatch`). `pgcrypto` está
   disponível no Neon, mas exige `CREATE EXTENSION pgcrypto;` **antes** — o que é
   por si só uma mudança que merece decisão explícita.

### Quem precisa aprovar

O responsável por LGPD / privacidade na Loupen (decisão de negócio), com o aval do
dono do dado. Enquanto isso não existir por escrito, o arquivo fica aqui.

### Como aplicar, se e quando for aprovada

1. Ratificação por escrito da janela de retenção (18 meses ou outro número) e da
   lista de campos anonimizados.
2. `CREATE EXTENSION IF NOT EXISTS pgcrypto;` — decisão à parte, registrada.
3. `git mv db/propostas/074_*.sql db/migrations/0NN_*.sql` com um número **novo**,
   no fim da fila. Renumerar é obrigatório: o ledger é forward-only e o slot 074
   já está vago no histórico; reinserir um 074 depois da 093 quebraria a ordem
   lexical de aplicação.
4. `bash db/apply.sh --dry-run`, depois `bash db/apply.sh`.
5. Conferir **sem escrever nada**: `SELECT count(*) FROM fn_anonimizar_retencao(18, false);`
   Com a janela de 12 meses carregada hoje o resultado esperado é **zero** —
   nenhum lead tem 18 meses sem evento. A função existe para o futuro e para
   atender pedido de eliminação do titular, não para rodar agora.

### Resíduo já limpo

Uma tentativa anterior de aplicar a 074 chegou a criar `privacidade_config` e
abortou logo em seguida no `gen_random_bytes` — a tabela ficou no banco, **vazia**.
Em 2026-09-16 foi confirmado que estava com 0 linhas e sem nenhum dependente (nenhuma
view, FK, função, trigger ou referência em código do repositório) e ela foi removida
com `DROP TABLE ... RESTRICT`. Nenhum salt foi perdido, porque nenhum chegou a ser
gerado. Se a 074 for aprovada, o `CREATE TABLE IF NOT EXISTS` a recria.

## Histórico — por que este diretório existe

Com a 074 parada em `db/migrations/`, `bash db/apply.sh` abortava nela e **nunca
chegava nas migrations seguintes**. O efeito colateral foi grave: as migrations 075
a 093 passaram a ser aplicadas à mão por `psql`, e o ledger `schema_migrations`
ficou congelado na 073 — banco e ledger fora de sincronia duas vezes. A
reconciliação está documentada na seção "Reconciliação do ledger" de `db/README.md`.
