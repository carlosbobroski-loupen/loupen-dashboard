-- db/queries/verificacao/amount-semantica-por-recordtype.sql
--
-- A MIGRATION 088 DECIDIU que `Opportunity.Amount` é o VALOR TOTAL da
-- oportunidade. Esta query existe porque o dado da base contradiz parcialmente
-- essa decisão, e o projeto tem a regra de que número desconfortável aparece,
-- não some. Ela reproduz a medição a qualquer momento — sem ela, quem reabrir a
-- discussão teria de redescobrir tudo do zero.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- COMO LER O RESULTADO — a interpretação está escrita aqui de propósito, para
-- quem rodar não precisar deduzir:
--
--   razao_amount_sobre_mrr ≈ 1
--     -> Amount carrega o MESMO número que MRR__c.
--        Amount se comporta como MENSAL nesse RecordType.
--        CONTRADIZ a decisão da 088.
--
--   razao_amount_sobre_mrr ≈ duracao_meses_contrato (mediana na coluna ao lado)
--     -> Amount ≈ MRR × prazo.
--        Amount se comporta como VALOR TOTAL do contrato nesse RecordType.
--        CONFIRMA a decisão da 088.
--
--   razao_amount_sobre_mrr_x_meses ≈ 1
--     -> mesma leitura que a linha de cima, normalizada: 1 significa que Amount
--        equivale ao contrato inteiro. Se der ≈ 1/meses (ex.: 0,083 para 12),
--        Amount é mensal.
--
--   parece_mensal / parece_total / nao_bate_com_nenhuma
--     -> contagem linha a linha, com tolerância de ±10%. É o número que
--        realmente resolve a dúvida: a mediana esconde bimodalidade, a
--        contagem não. `nao_bate_com_nenhuma` alto = o RecordType é
--        INCONSISTENTE, não é "mensal" nem "total".
--
-- IMPORTANTE: um RecordType sem MRR__c preenchido (com_mrr = 0) não aparece nas
-- razões. Ausência de razão NÃO é evidência a favor de nenhuma hipótese —
-- é ausência de dado, e a coluna `com_mrr` mostra isso explicitamente.
-- ─────────────────────────────────────────────────────────────────────────────

-- Parte 1 — cobertura e razões medianas por RecordType.
SELECT
  coalesce(o.record_type_name, '(sem RecordType)')             AS record_type,
  count(*)                                                     AS ganhas,
  count(*) FILTER (WHERE o.amount IS NOT NULL)                 AS com_amount,
  count(*) FILTER (WHERE o.mrr IS NOT NULL)                    AS com_mrr,
  count(*) FILTER (WHERE o.amount IS NOT NULL
                     AND o.mrr IS NOT NULL AND o.mrr <> 0)     AS com_ambos,
  count(*) FILTER (WHERE o.duracao_meses_contrato IS NOT NULL) AS com_duracao,
  round(percentile_cont(0.5) WITHIN GROUP (
          ORDER BY o.amount / nullif(o.mrr, 0))::numeric, 3)   AS razao_amount_sobre_mrr,
  round(percentile_cont(0.5) WITHIN GROUP (
          ORDER BY o.amount / nullif(o.mrr * o.duracao_meses_contrato, 0))::numeric, 4)
                                                               AS razao_amount_sobre_mrr_x_meses,
  round(percentile_cont(0.5) WITHIN GROUP (
          ORDER BY o.duracao_meses_contrato)::numeric, 1)      AS meses_mediano
FROM opportunity o
WHERE o.stage_name = 'Ganho'
GROUP BY 1
ORDER BY 2 DESC;

-- Parte 2 — a contagem linha a linha, que é o que de fato decide.
-- Tolerância de ±10% em cada hipótese. Linhas sem Amount, sem MRR__c ou com
-- MRR__c = 0 ficam de fora: não sustentam nenhuma das duas leituras.
SELECT
  coalesce(o.record_type_name, '(sem RecordType)') AS record_type,
  count(*)                                         AS avaliaveis,
  count(*) FILTER (
    WHERE abs(o.amount / o.mrr - 1) <= 0.10
  )                                                AS parece_mensal,
  count(*) FILTER (
    WHERE o.duracao_meses_contrato > 0
      AND abs(o.amount / o.mrr - o.duracao_meses_contrato)
          <= 0.10 * o.duracao_meses_contrato
  )                                                AS parece_total,
  count(*) FILTER (
    WHERE NOT (abs(o.amount / o.mrr - 1) <= 0.10)
      AND NOT (o.duracao_meses_contrato > 0
               AND abs(o.amount / o.mrr - o.duracao_meses_contrato)
                   <= 0.10 * o.duracao_meses_contrato)
  )                                                AS nao_bate_com_nenhuma
FROM opportunity o
WHERE o.stage_name = 'Ganho'
  AND o.amount IS NOT NULL
  AND o.mrr IS NOT NULL
  AND o.mrr <> 0
GROUP BY 1
ORDER BY 2 DESC;

-- Parte 3 — o total consolidado, uma linha, para o veredito rápido.
SELECT
  count(*)                                                   AS avaliaveis,
  count(*) FILTER (WHERE abs(amount / mrr - 1) <= 0.10)      AS parece_mensal,
  count(*) FILTER (WHERE duracao_meses_contrato > 0
                     AND abs(amount / mrr - duracao_meses_contrato)
                         <= 0.10 * duracao_meses_contrato)   AS parece_total,
  round(100.0 * count(*) FILTER (WHERE abs(amount / mrr - 1) <= 0.10)
        / nullif(count(*), 0), 1)                            AS pct_mensal
FROM opportunity
WHERE stage_name = 'Ganho'
  AND amount IS NOT NULL
  AND mrr IS NOT NULL
  AND mrr <> 0;
