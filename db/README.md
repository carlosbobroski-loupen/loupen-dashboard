# Banco de dados — CRM Lead Intelligence (Etapa B)

Convenções fixadas no provisionamento (subtask 2.1 do plano). Estas decisões são
**irreversíveis na prática** (CON-15/R15: trocar região ou major depois exige recriar o
projeto e recarregar tudo) — por isso ficam documentadas aqui, não apenas na cabeça de
quem provisionou.

## Projeto

- **Provedor:** Neon (Postgres serverless, free tier)
- **Região:** `aws-sa-east-1` (AWS South America East 1 — São Paulo) — CON-15, decisão do
  usuário de 2026-09-04, confirmada disponível no Free na tela de criação (spike 1.1).
- **Postgres major:** 18 — fixado no provisionamento pelo mesmo motivo de
  irreversibilidade acima (intervalo suportado era PG 14-18, spec.md §4.1 deliberadamente
  não escolhia).
- **Extensões habilitadas:** `pg_trgm`, `fuzzystrmatch` (EC-7 Tier 2 — resolução
  probabilística de identidade, ver spike 1.1 em `docs/stories/epic-crm-lead-intelligence/
  plan/validation-log.md`).

## Conexão

- **Sempre usar o endpoint `-pooler`** (connection pooling do Neon via PgBouncer), nunca o
  endpoint direto — P-ING-6. Formato:
  ```
  postgresql://<user>:<password>@<endpoint>-pooler.sa-east-1.aws.neon.tech/<database>?sslmode=require&channel_binding=require
  ```
- `sslmode=require` é obrigatório (Neon não aceita conexão sem TLS).
- **A variável `NEON_DATABASE_URL` NUNCA é commitada.** Vive em `.env` na raiz do repo
  (já coberto por `.gitignore`). Todo comando `psql`/script deste diretório assume que ela
  já está exportada no shell (`set -a; source .env; set +a` antes de rodar).

## Estrutura

```
db/
├── README.md                    (este arquivo)
├── migrations/*.sql             Schema versionado, forward-only, aplicado em ordem
│                                 lexical (ver subtask 2.2, db/apply.sh)
└── queries/verificacao/*.sql    Asserções SQL versionadas — zero linhas retornadas
                                  significa que a invariante vale; linhas retornadas
                                  SÃO o relatório da violação (spec.md §5.1/§6.1)
```

## Roles

- **`neondb_owner`** — dono do schema, usado só para migrations (`db/apply.sh`) e
  administração manual. Nunca usado por workflows de ingestão.
- **`crm_ingest`** — role dedicada de menor privilégio (INV-1) para o n8n. Apenas
  `SELECT`/`INSERT`/`UPDATE` em todas as tabelas + `EXECUTE` em `fn_run_ingest_batch`.
  Sem DDL, sem `DROP`, sem `TRUNCATE` — testado na prática (ver validation-log.md,
  subtask 2.15). Credencial correspondente no n8n: "Neon CRM Ingest (crm_ingest,
  least-privilege)". Connection string em `NEON_INGEST_DATABASE_URL` no `.env`.

## Como aplicar migrations

```bash
set -a; source .env; set +a      # exporta NEON_DATABASE_URL
bash db/apply.sh                  # aplica tudo o que falta, em ordem
bash db/apply.sh --dry-run        # só lista o que seria aplicado, sem tocar no banco
```

O runner (`db/apply.sh`) é **forward-only** e idempotente:

- Aplica `db/migrations/*.sql` em **ordem lexical** (por isso o prefixo numérico
  `000_`…`044_` é obrigatório em todo arquivo novo; a ordem é fixada com `sort`, não
  deixada para o locale do shell).
- Registra cada arquivo aplicado em `schema_migrations(name, checksum, applied_at)`.
- **Recusa reaplicar um arquivo cujo conteúdo mudou depois de aplicado** — checksum
  diferente é erro, não reaplicação silenciosa. Consequência prática: **nunca editar uma
  migration já aplicada.** Para corrigir algo, criar uma migration NOVA (é o que fazem
  041 e 042, que corrigem bugs de 039/040).
- Usa `psql` com `ON_ERROR_STOP=1`: a primeira falha aborta, sem deixar meia migration
  aplicada em silêncio.
- Se `psql` não estiver no `PATH`, cai para `/opt/homebrew/opt/libpq/bin/psql`
  (Homebrew/macOS). Para outro caminho, exportar `PSQL_BIN`.

Funções são substituídas com `CREATE OR REPLACE` numa migration nova, nunca editando a
original — é assim que `fn_run_ingest_batch` chegou à v8 (012 → 014 → 016 → 026 → 040 →
042 → 043 → 044) sem que nenhum checksum anterior mude.

### Não existe rollback automático

**Forward-only significa forward-only: não há `down migration`, não há `apply.sh --revert`,
não há como desfazer.** Consequências práticas, que precisam estar claras antes de rodar
qualquer coisa em produção:

- Cada arquivo `.sql` roda dentro de uma transação implícita do `psql`, então uma migration
  que **falha no meio** não deixa metade aplicada. Isso protege contra falha, não contra
  arrepiar-se depois.
- Desfazer uma mudança já aplicada e bem-sucedida exige **escrever uma migration nova** que
  faça o inverso (ex.: um `DROP COLUMN` para reverter um `ADD COLUMN`). Essa migration
  inversa é código como qualquer outro: revisada, versionada, aplicada.
- Para mudança destrutiva (`DROP`/`ALTER TYPE`/`DELETE` em massa), **testar antes num branch
  do Neon**, não direto no banco principal. O Neon Free permite branch de banco — é o
  mecanismo de segurança disponível aqui, no lugar do rollback que não existe.
- A role `crm_ingest` (usada pelo n8n) **não tem DDL nem `DROP`/`TRUNCATE`** de propósito
  (INV-1): nenhum workflow de ingestão pode causar dano estrutural, aconteça o que
  acontecer. DDL só com `neondb_owner`, só via `apply.sh`.

### Rodando sem `psql` instalado

Nada aqui depende de ter `psql` na máquina. Tanto as migrations quanto as asserções são
SQL puro e rodam colando o conteúdo do arquivo no **console SQL do Neon** (ou em qualquer
cliente Postgres: DBeaver, pgAdmin, TablePlus). O que se perde ao fazer isso à mão:

- o registro em `schema_migrations` e a proteção de checksum (o `apply.sh` é quem faz isso)
  — por isso migrations devem ir por `apply.sh` sempre que possível;
- o *exit code* das asserções. No console, o sinal equivalente é a mensagem: um
  `RAISE NOTICE` de sucesso apareceu, ou um `ERROR:` com o nome do requisito violado.

## Como executar as asserções

```bash
set -a; source .env; set +a
psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/queries/verificacao/<arquivo>.sql
```

Rodar **todas** (é o que vale antes de considerar qualquer subtask fechada):

```bash
set -a; source .env; set +a
for f in db/queries/verificacao/*.sql; do
  psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>&1 \
    && echo "OK:      $(basename $f)" \
    || echo "FALHOU:  $(basename $f)"
done
```

Não há runner de teste (CON-10/CON-12 excluem Jest/pgTAP/qualquer toolchain com
dependência). `psql` + `ON_ERROR_STOP=1` **é** o runner: exit code 0 = passou, exit code
≠ 0 = falhou. Isso é suficiente para CI e para uso manual, sem instalar nada.

## Convenção de asserção

Todo arquivo em `db/queries/verificacao/` tem **duas partes**:

1. **Relatório humano** — um ou mais `SELECT` que listam as linhas ofensoras (§6.1). São
   os dados que uma pessoa lê para entender *o que* violou. Zero linhas = invariante vale.
2. **Asserção** — um bloco `DO $$ ... $$` que conta as ofensoras e dá `RAISE EXCEPTION`
   se houver alguma. É isso que faz o `psql` sair com código ≠ 0 e o CI falhar.

Regras que valem para todas:

- **`RAISE NOTICE` no caminho de sucesso.** Uma asserção que passa silenciosamente é
  indistinguível de uma que não rodou.
- **A mensagem de exceção nomeia o requisito** (`AC-9.1`, `P-ING-2`, `EC-7`, `FR-11`…) e
  diz o número real encontrado — quem lê o erro não deveria precisar abrir o arquivo.
- **Nunca `SELECT 1/(subquery HAVING count=N)`** como forma de falhar. Esse padrão (usado
  na versão original do plano) **não falha** quando a condição é falsa: a subquery devolve
  zero linhas ou `NULL`, e `NULL/algo` é `NULL`, não divisão por zero. Usar
  `1/CASE WHEN <cond> THEN 1 ELSE 0 END`, ou um `DO` block explícito — que é o padrão
  adotado aqui.
- **Teste por execução, não por leitura de código,** quando o requisito é sobre
  comportamento. `nfr6-novo-canal.sql` ingere um canal inédito de verdade;
  `integracao-ingestao.sql` roda a ingestão duas vezes para provar idempotência. Ler a
  função e concluir que ela "parece idempotente" não é asserção.
- **Toda asserção que escreve, limpa depois — e verifica a limpeza.** E se tocar dado
  real, salva e restaura (ver o comentário de aviso em `integracao-ingestao.sql`: uma
  versão anterior daquele arquivo destruiu o watermark de produção justamente por não
  fazer isso).

### Asserções que MEDEM em vez de falhar

`spike-ec7-identidade.sql` é a exceção deliberada: os itens de chave canônica e regra de
conflito são asserções normais, mas a parte de **custo** apenas imprime números via
`RAISE NOTICE` e não falha por lentidão — nenhum requisito define alvo de performance para
o Tier 2 (NFR-2 é sobre a API de leitura, não sobre esse job periódico). Uma asserção que
falhasse num limite inventado seria pior que nenhuma.

## Estado atual

- **45** migrations aplicadas (`000_`…`044_`)
- **17** asserções em `db/queries/verificacao/`, todas passando juntas

## Por que não Prisma/Flyway/Drizzle

CON-10 (custo zero) e CON-12 (sem build step) excluem qualquer ferramenta de migration
com toolchain própria. O runner é `db/apply.sh` — bash + `psql`, forward-only, com
checksum e `ON_ERROR_STOP` (subtask 2.2), registrado numa tabela `schema_migrations`
própria, sem dependência de Node/npm.
