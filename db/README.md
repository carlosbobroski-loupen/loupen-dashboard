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
├── propostas/*.sql              SQL escrito mas NÃO aplicado, deliberadamente fora
│                                 do runner (decisão pendente de aprovação humana) —
│                                 ver db/propostas/README.md
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

### Reconciliação do ledger — 2026-09-16

`schema_migrations` ficou congelado na `073` enquanto as migrations **075 a 093 já
estavam no banco**. Causa: a `074` (retenção/anonimização LGPD) estava parada em
`db/migrations/` sem aprovação e abortava o runner em `gen_random_bytes` (`pgcrypto`
não instalada); como `apply.sh` aborta na primeira falha, ele nunca chegava nas
seguintes — que passaram a ser aplicadas à mão por `psql`. A `074` foi movida para
`db/propostas/` (ver o README de lá) e o ledger foi acertado.

**As linhas `075_*` a `089_*` têm `applied_at = 2026-09-16` porque essa é a data da
RECONCILIAÇÃO, não a da aplicação.** O momento real em que cada uma rodou não foi
registrado por ninguém e não será inventado aqui; o que se sabe com certeza é que foi
entre a `073` (2026-09-15 14:54Z) e a `090` (2026-09-16 11:43Z). Isso está declarado
também em `COMMENT ON TABLE schema_migrations` e `COMMENT ON COLUMN
schema_migrations.applied_at`, para quem olhar só o banco. (`090`–`093` já estavam no
ledger com hora real de aplicação e não foram tocadas.)

Nenhuma linha foi registrada sem verificação. O que foi conferido no banco, objeto a
objeto, antes de registrar:

| Migration | Evidência no banco |
|---|---|
| 075 | 54 de 54 `valor_bruto` do arquivo presentes em `leadsource_crosswalk` |
| 076 | `fn_reclassificar_lead` existe e o `prosrc` bate **byte a byte** (normalizado) com o arquivo |
| 077 | `fn_marketing_funil` e `fn_marketing_funil_por_categoria` batem byte a byte; a view foi redefinida depois (080 → 093) |
| 078 | superada pela **081**, que é o mesmo corpo + `identificador_rd` e comprovadamente rodou (ver 081) |
| 079 | tabela `opportunity_stage_fase` com 29 linhas |
| 080 | superada: `view_receita`/`view_lead_360` estão na versão da 090 (têm `amount_brl`) e `view_marketing_rd_sf` na da 093 |
| 081 | coluna `lead.identificador_rd` + índice `idx_lead_identificador_rd` existem, e **308 leads têm o campo preenchido** — a versão 081 da função rodou em produção |
| 082 | colunas de `view_pessoa` idênticas à lista do arquivo (`pessoa_chave`…`fontes`) |
| 083 | superada pela 088/090 (`view_pessoa_jornada_desfecho` tem `amount_brl`) |
| 084 | superada pela 087/091 |
| 085 | `opportunity_stage_fase`: `fase='perdido'` está com `ordem = 5` |
| 086 | `view_jornada_unificada` expõe `id_anuncio`, `criativo`, `publico` |
| 087 | corpo atual de `fn_search_pessoas` contém o pivô de campanha |
| 088 | superada pela 090/093 |
| 089 | `pg_proc.proconfig = {plan_cache_mode=force_custom_plan}` nas duas funções |

"Superada" significa: o objeto foi redefinido por uma migration posterior
comprovadamente aplicada, o banco está **à frente** desse arquivo, e reaplicá-lo seria
**regressão**, não conserto. Em todos os casos o ledger encoda a mesma coisa — não rodar.

#### Sequela encontrada durante a conferência

`fn_run_ingest_batch` no banco era, byte a byte, a versão da **092** — que descende
da **073** e perdeu o que a 078 e a 081 tinham acrescentado. A 090 foi escrita sobre
o corpo da 073 (o topo do ledger na época, justamente por causa da dessincronia
acima) e **reverteu em silêncio duas migrations que já estavam aplicadas**. Nenhum
erro, nenhum aviso: a função continuou ingerindo tudo, só parou de gravar campos.

Medido no corpo vivo, por token (contagens de `grep`, não impressão):

| token | 073 | 078 | 081 | 090 | 092 | vivo (antes da 099) |
|---|---|---|---|---|---|---|
| `identificador_rd` (081) | 0 | 0 | **8** | 0 | 0 | **0** |
| `custom_fields` (078) | 0 | **14** | 14 | 0 | 0 | **0** |
| `Campanha de Origem` (078) | 0 | **2** | 2 | 0 | 0 | **0** |
| `last_conversion` | 9 | 39 | 39 | 9 | 9 | **9** |

⚠️ **`last_conversion` é armadilha de medição.** Ele aparece 9 vezes no corpo vivo,
mas 9 é o **valor de base da 073**, anterior à 078 — a 078 levava a 39 e trazia junto
`custom_fields`. Procurar só por `last_conversion` dá falso positivo e faz concluir
que "a 078 sobreviveu". Ela não sobreviveu. A checagem que decide é `custom_fields`
(ou `Campanha de Origem`), que está em **zero**.

**Estado: as duas reversões foram repostas em 2026-09-16.** Em ambos os casos a
função foi reemitida a partir do corpo **vivo**, com adição pura, e cada uma tem
asserção de comportamento que **falha contra o corpo anterior**:

| Perdida | Reposta por | Asserção |
|---|---|---|
| 081 — `identificador_rd` na ingestão do Lead do Salesforce | `099_repoe_identificador_rd_na_ingestao.sql` (diff: 3 inserções, 0 remoções) | `db/queries/verificacao/identificador-rd-na-ingestao.sql` |
| 078 — enriquecimento do lead pelo webhook do RD (UTM de `custom_fields`) | `101_repoe_enriquecimento_do_webhook_rd.sql` (diff: 123 linhas adicionadas, 0 removidas, 0 modificadas) | `db/queries/verificacao/webhook-rd-enriquece-o-lead.sql` |

Contagens no corpo vivo depois das duas: `identificador_rd` 3, `custom_fields` 14,
`Campanha de Origem` 2, `last_conversion` 39 — e `CurrencyType` 6,
`OpportunityStage` 5, `ConvertedOpportunityId` 1, ou seja, 090 e 092 intactas.

**Quanto se perdeu de fato:** nada. Medido antes de consertar — dos 24 eventos de
webhook que existem em `stg_rdstation`, os 24 já tinham virado linha em `lead` com
evento de UTM; o último entrou às 04:41Z e a reversão (090) foi às 11:43Z do mesmo
dia, então nenhum evento atravessou a janela quebrada. Não houve reprocessamento e
nenhuma linha de produção foi reescrita. A perda era **prospectiva e total**: o
próximo webhook não viraria lead nenhum — e a ingestão reportaria
`ConversionEvent 1 1 ok`, como se estivesse saudável. É esse o perigo desse modo
de falha, e é por isso que a asserção olha a coluna, não o status.

### Regra de processo: função se reescreve a partir do corpo VIVO

O que aconteceu acima não foi descuido isolado — é um modo de falha que se repete
sozinho, e a defesa precisa ser mecânica:

> **Reescrever uma função inteira a partir de um arquivo de migration antigo reverte,
> em silêncio, tudo que veio depois daquele arquivo.**

`CREATE OR REPLACE FUNCTION` substitui o corpo INTEIRO. Se o ponto de partida foi o
último `.sql` que você viu — ou o último que o ledger mostra, que pode estar
desatualizado — todas as migrations posteriores àquele arquivo somem sem barulho.

Ao alterar uma função existente, sempre:

1. **Parta do corpo vivo**, não de um arquivo:
   ```bash
   psql "$NEON_DATABASE_URL" -tA \
     -c "SELECT pg_get_functiondef('public.fn_x(text)'::regprocedure)" > /tmp/vivo.sql
   ```
2. **Edite por inserção e diffe contra o vivo.** O diff tem de ser adição pura. Uma
   linha que aparece como modificada só passa se a mudança for inserção de texto
   *dentro* da linha — o teste objetivo é reversibilidade: desfazer exatamente os
   trechos inseridos tem de devolver o corpo vivo byte a byte.
3. **Prove por comportamento, não por leitura.** "A função agora contém a string
   `x`" é asserção fraca: um comentário com a palavra `x` a satisfaz. Escreva uma
   asserção em `db/queries/verificacao/` que exercite o caminho real dentro de
   `BEGIN`/`ROLLBACK` e **confirme que ela falha contra o corpo anterior** antes de
   declarar verde.

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
