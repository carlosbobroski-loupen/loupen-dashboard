# ADR-016: Versionamento efetivo-datado append-only para reclassificação de atribuição

**Status:** Aceito · **Data:** 2026-09-07 · **Épico:** `epic-crm-lead-intelligence`

## Contexto

`critique-2.json.carryForwardToPlan` deixou aberto "o DDL da estrutura de versionamento de reclassificação exigida por I4".

O problema real por trás disso: este épico existe porque leads de campanha estavam sendo classificados como Comercial **sem forma de auditar por quê**. Corrigir a regra de classificação sem corrigir a auditabilidade só troca um número errado por outro número não verificável. I4 exige poder responder, para qualquer lead, três perguntas ao mesmo tempo:

- **quem** classificou (a regra, a versão da regra, o processo)
- **quando**
- **de-para** — qual era a classificação antes e por que mudou

E I3 acrescenta uma restrição que parece pequena e não é: o *first-touch* (a primeira atribuição de origem de um lead) tem de ser gravado **uma vez** e nunca sobrescrito por reingestão — senão toda re-sincronização reescreve a história da origem.

## Decisão

Tabela **efetivo-datada append-only**:

```
lead_origin_classification(
  id, lead_id, version, segmento, categoria, detalhe,
  campanha_id, sinal_id, valor_bruto, razao jsonb NOT NULL,
  is_first_touch, ruleset_version FK, classified_at, classified_by,
  supersedes_id FK self, reclass_reason, valid_from, valid_to
)
```

com **índice único parcial em `(lead_id) WHERE valid_to IS NULL`** (garante uma única versão corrente por lead e torna a leitura do estado atual barata) e `UNIQUE(lead_id, version)`.

**Três invariantes NO BANCO, não na aplicação:**

- **(a) trigger `BEFORE UPDATE`** que dá `RAISE` a menos que a única coluna alterada seja `valid_to` → **I4**: reclassificação é `INSERT` de nova versão, nunca `UPDATE` do histórico.
- **(b) trigger** que dá `RAISE` em `INSERT` de uma segunda linha com `is_first_touch = true` para o mesmo lead → **I3**: first-touch gravado uma vez, nunca sobrescrito por reingestão.
- **(c) `CHECK`**: `classified_by LIKE 'reclass:%'` implica `reclass_reason IS NOT NULL` → reclassificação sem razão registrada é **impossível de gravar**.

`attribution_ruleset(version, definition_hash, migration_file, activated_at)` liga cada classificação à versão da regra que a produziu. Sem isso, a matriz de transição de uma mudança de regra (3.15) não é reproduzível — não se saberia qual regra gerou qual resultado.

Estar no banco, e não na aplicação, é o ponto: um invariante que vive em código de aplicação vale até alguém escrever um script de correção que não passe por esse código.

## Alternativas rejeitadas

**Coluna de versão simples** (`version INT` sobrescrita a cada reclassificação). Rejeitada: responde "quando" e "qual é agora", mas perde o **de-para** — a classificação anterior desaparece, e a pergunta que originou o épico ("por que este lead virou Comercial?") continua sem resposta.

**Tabela de log lateral** (canônica sobrescrita + log de auditoria separado). Rejeitada por dois motivos: (1) o log pode divergir da canônica, porque nada no banco força os dois a andarem juntos — e um log de auditoria em que não se confia é pior que nenhum, porque dá falsa segurança; (2) exige duas escritas e duas leituras para reconstruir a história.

## Consequências

**Positivas:**
- As três perguntas de I4 são respondidas por **uma** query, sem reconstrução.
- O estado corrente é lido por índice parcial — barato, apesar do histórico.
- Os invariantes são testáveis e testados: `i3-i4.sql` prova por execução que um `UPDATE` no histórico falha e que um segundo `is_first_touch` falha.

**Negativas / limites aceitos:**
- Escrita mais cara (fecha versão + insere nova) e **toda leitura precisa do filtro `valid_to IS NULL`** — esquecê-lo devolve o histórico inteiro em vez do estado atual. É a armadilha real desta escolha; mitigada pelo índice parcial e por as views (`view_lead_360`, `view_cobertura_atribuicao`) já embutirem o filtro, de modo que consumidores não repitam a decisão.
- O volume é da ordem de centenas/milhares de leads (NFR-2), não big data — o custo extra é irrelevante nessa escala. Numa escala muito maior, essa conta mudaria.

## Ver também

- `db/migrations/008_attribution_classification_versioned.sql` (DDL)
- `db/migrations/009_attribution_append_only_triggers.sql` (os três invariantes)
- `db/queries/verificacao/i3-i4.sql` (prova por execução)
- `db/migrations/026_fn_run_ingest_batch_atribuicao.sql` (quem grava as versões, e como respeita I3/I4)
- ADR-015 (a mecânica de invocação que aciona esta gravação)
