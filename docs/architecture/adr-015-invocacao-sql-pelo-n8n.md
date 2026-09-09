# ADR-015: Mecânica de invocação da função SQL de ingestão pelo n8n

**Status:** Aceito · **Data:** 2026-09-07 (atualizado 2026-09-09) · **Épico:** `epic-crm-lead-intelligence`

## Contexto

`critique-2.json.carryForwardToPlan` deixou explicitamente aberto "a mecânica de invocação da função SQL pelo n8n (nó, ordem, transação, tratamento de erro)". A pergunta importa porque duas decisões anteriores já estavam tomadas e criam uma tensão real entre si:

- **CRIT-4 / R14:** a regra de negócio (atribuição, receita, identidade) vive em SQL versionado, não em código de workflow — senão a lógica mais crítica do épico fica fora de controle de versão e sem teste.
- **R7 / CON-10:** o n8n é o ponto único de ingestão *e* de leitura, porque é o ativo que já existe e custa zero.

Ou seja: o n8n **tem** de chamar a lógica, mas **não pode** conter a lógica. Como exatamente essa chamada acontece determina se P-ING-1 (reexecução idempotente), P-ING-3 (uma escrita em bloco por lote) e EC-8 (falha parcial visível) se sustentam ou não.

## Decisão

**Um nó Postgres "Execute Query" por execução de workflow**, chamando `SELECT * FROM fn_run_ingest_batch($batch_id)` **depois** do insert em bloco no staging.

Ordem fixa:

1. O n8n coleta da origem e **conta** os registros na origem.
2. O n8n normaliza **somente telefone para E.164** — a única transformação permitida fora do SQL, resíduo declarado e aceito em `spec.md` §3.3.
3. **Um** insert em bloco em `stg_*` com um `batch_id` comum (P-ING-3 — não N inserts).
4. **Uma** chamada à procedure, com esse `batch_id`.
5. A procedure faz upsert `ON CONFLICT (source_system, source_id)` (P-ING-1), grava `rows_source`/`rows_target` e retorna a divergência.
6. O n8n grava/expõe o resultado retornado.

**Transação:** a procedure inteira é uma transação — *all-or-nothing* por lote. Em exceção ela faz `RAISE`, o nó falha, e o ramo de erro do workflow grava `ingest_run(status='failed', error_message)`. Assim falha parcial fica **visível** (NFR-1, EC-8) e o último dado válido permanece com sua idade real, jamais substituído por zero.

**Retry:** `retry-on-fail = 2` com backoff no nó. A idempotência vem do `ON CONFLICT` + `batch_id`, **não** da sorte de o retry não repetir trabalho.

**`batch_id` na prática:** `{{ $execution.id }}` do n8n — identificador que já existe, é único por execução e some da necessidade de gerar um.

## Alternativas rejeitadas

**Chamar a função por linha, em loop no n8n.** Rejeitada: gera N *round trips* por lote (quebra P-ING-3), e cada chamada é sua própria transação — não existe fronteira transacional do lote, então uma falha no meio deixa o lote metade aplicado sem nenhum registro dizendo isso.

**Transformar os dados num nó Code do n8n e gravar direto nas tabelas canônicas.** Rejeitada: devolveria a regra de negócio para fora do controle de versão, revertendo a resolução de CRIT-4 e reabrindo R14 — exatamente o defeito estrutural que este épico existe para corrigir. Um nó Code não tem migration, não tem teste SQL e não tem histórico revisável.

## Consequências

**Positivas:**
- P-ING-1 verificado por execução real, não por inspeção: `integracao-ingestao.sql` roda o mesmo `batch_id` duas vezes e prova que não duplica.
- Acrescentar uma fonte nova é acrescentar uma seção na procedure + um ramo no workflow; nenhuma lógica nova em JS.
- A fronteira transacional é óbvia e única: uma chamada, uma transação.

**Negativas / limites aceitos:**
- A reconciliação desta procedure é **por lote**, não a reconciliação TOTAL origem↔destino de EC-6. A contagem total na origem é responsabilidade do workflow n8n (2.16/2.17/2.18), que sabe consultar a origem — não cabe numa procedure de assinatura fixa `batch_id`.
- O `payload` bruto em staging acumula entradas a cada reexecução. É um log de entrada, não a fonte de verdade — aceito de propósito (`011_staging_tables.sql` documenta isso).

## Atualização de 2026-09-09 (o que a implementação real mudou)

A decisão se sustentou, com dois ajustes que só apareceram construindo:

1. **`sync_state` não estava sendo escrito por ninguém.** A versão original desta ADR previa que "o nó de workflow grava esse número separadamente em `sync_state`" — e nenhum workflow fazia isso. `sync_state` ficou vazia por 43 migrations, ou seja, **P-ING-2 (watermark incremental) não existia**. Corrigido na migration 044, movendo a escrita para **dentro do SQL** (`fn_registrar_ingest()`, que grava `ingest_run` e `sync_state` na mesma chamada). Motivo: dois escritores independentes para dois registros que descrevem o mesmo evento podem divergir; um escritor não pode. Isso **fortalece** a decisão original de manter a regra no SQL — a exceção que ela mesma abria era o furo.

2. **O watermark só avança em `status='ok'`.** Decisão nova, tomada em 044. Se avançasse numa execução `partial`, a consulta de delta seguinte começaria *depois* de registros que nunca foram ingeridos — perda silenciosa de dado, exatamente a classe de defeito (EC-6) que o épico existe para corrigir.

3. **Um `fn_run_ingest_batch` por cadeia paralela, sem nó de merge.** Nos workflows com ramos paralelos (2.17: funil / entrada / saída de workflow), cada ramo chama a procedure por conta própria em vez de sincronizar num merge. Seguro precisamente porque a chamada é idempotente por `batch_id` — e muito mais simples que coordenar três ramos.

## Ver também

- `db/migrations/012_fn_run_ingest_batch.sql` (versão original) e `044_sync_state_watermark.sql` (v8, atual)
- `db/queries/verificacao/integracao-ingestao.sql` (P-ING-1 e P-ING-2 testados por execução)
- `db/README.md` — convenção de asserção e ausência de rollback
- ADR-016 (versionamento de reclassificação, a outra metade da regra em SQL)
