-- db/queries/verificacao/moeda-conversao.sql
--
-- Verificação da migration 090 — conversão de moeda e vínculo lead->oportunidade.
--
-- REGRA DESTE ARQUIVO: toda asserção vem acompanhada do TESTE NEGATIVO que
-- prova que ela CONSEGUE FALHAR. Uma verificação que passa vazia — porque o
-- filtro não pegou linha nenhuma, ou porque a comparação é trivialmente
-- verdadeira — não é verificação, é decoração. Este projeto já foi enganado
-- por isso seis vezes nesta epic.
--
-- Rodar inteiro:
--   set -a; . ./.env; set +a
--   /opt/homebrew/opt/libpq/bin/psql "$NEON_DATABASE_URL" \
--     -f db/queries/verificacao/moeda-conversao.sql

\echo ''
\echo '══ 0. A TAXA VEIO DA ORIGEM, NÃO DO CÓDIGO ═════════════════════════════'
-- Se currency_rate estiver vazia, TUDO abaixo daria NULL e "passaria" sem
-- dizer nada. Esta consulta é a guarda contra isso.
SELECT iso_code, conversion_rate, is_corporate, is_active,
       round(1 / conversion_rate, 6) AS reais_por_unidade,
       source_id, collected_at
FROM currency_rate
ORDER BY is_corporate DESC, iso_code;

\echo ''
\echo '══ 1. USD E MXN EXISTEM NO BANCO — ANTES ERAM INVISÍVEIS ═══════════════'
-- Antes da 090 esta consulta devolveria UMA linha, com currency_iso_code NULL
-- e 8.076 oportunidades: o campo não era ingerido. 23% do volume da janela
-- estava em moeda estrangeira e o banco não sabia.
SELECT coalesce(currency_iso_code, '(sem moeda)') AS moeda,
       count(*)                                                   AS oportunidades,
       count(*) FILTER (WHERE stage_name = 'Ganho')               AS ganhas,
       count(*) FILTER (WHERE stage_name = 'Ganho'
                          AND created_at_source >= '2025-09-14')  AS ganhas_na_janela,
       sum(amount) FILTER (WHERE stage_name = 'Ganho')            AS soma_crua_ganhas
FROM opportunity
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '══ 2. UMA LINHA USD, CONFERIDA À MÃO CONTRA A DIVISÃO ══════════════════'
-- A maior oportunidade USD ganha da janela. `conta_a_mao` repete a divisão com
-- a taxa escrita literalmente, fora da view — se a view usasse outra regra
-- (multiplicação, fallback, arredondamento), `diferenca` deixaria de ser zero.
SELECT o.source_id,
       o.amount,
       o.currency_iso_code             AS moeda,
       vr.taxa_conversao,
       vr.amount_brl,
       o.amount / 0.19604              AS conta_a_mao,
       vr.amount_brl - (o.amount / 0.19604) AS diferenca
FROM opportunity o
JOIN view_receita vr ON vr.opportunity_id = o.id
WHERE o.currency_iso_code = 'USD'
  AND o.stage_name = 'Ganho'
  AND o.created_at_source >= '2025-09-14'
  -- `AND o.amount IS NOT NULL` NÃO é decoração: sem ele, `ORDER BY amount DESC`
  -- coloca os NULL na frente (NULLS FIRST é o default do Postgres no DESC) e as
  -- três linhas voltam em branco. A verificação "passava" sem comparar nada.
  -- Aconteceu na primeira execução deste arquivo, em 2026-09-16.
  AND o.amount IS NOT NULL
ORDER BY o.amount DESC
LIMIT 3;

\echo ''
\echo '   TESTE NEGATIVO 2 — a comparação consegue dar diferente de zero?'
-- Mesma consulta com a taxa ERRADA de propósito (0,19605 em vez de 0,19604).
-- Se `diferenca` continuasse zero aqui, a comparação acima não estaria
-- comparando nada.
SELECT o.source_id,
       vr.amount_brl,
       o.amount / 0.19605 AS conta_com_taxa_errada,
       vr.amount_brl - (o.amount / 0.19605) AS diferenca_deve_ser_nao_zero
FROM opportunity o
JOIN view_receita vr ON vr.opportunity_id = o.id
WHERE o.currency_iso_code = 'USD' AND o.stage_name = 'Ganho'
  AND o.created_at_source >= '2025-09-14' AND o.amount IS NOT NULL
ORDER BY o.amount DESC
LIMIT 1;

\echo ''
\echo '══ 3. A SOMA CONVERTIDA DIFERE DA CRUA — E FECHA COM A ORIGEM ══════════'
-- O número da direita é o que o Salesforce devolve para as mesmas 992 linhas.
-- Em org multi-moeda, SUM(Amount) no SOQL vem JÁ CONVERTIDO para a moeda
-- corporativa — por isso ele bate com a coluna convertida e não com a crua.
--   BRL 701 -> 1.742.219,98 | USD 238 -> 1.871.669,00 | MXN 53 -> 229.425,81
--   total  -> 3.843.314,79
SELECT count(*)                                        AS ganhas_na_janela,
       sum(o.amount)                                   AS soma_crua_moedas_misturadas,
       sum(vr.amount_brl)                              AS soma_convertida_brl,
       sum(vr.amount_brl) - sum(o.amount)              AS quanto_faltava,
       round(100 * (sum(vr.amount_brl) - sum(o.amount)) / sum(o.amount), 2) AS erro_percentual,
       3843314.79                                      AS total_do_salesforce,
       sum(vr.amount_brl) - 3843314.79                 AS residuo_contra_a_origem,
       count(*) FILTER (WHERE o.amount IS NOT NULL
                          AND vr.amount_brl IS NULL)   AS ganhas_sem_conversao
FROM opportunity o
JOIN view_receita vr ON vr.opportunity_id = o.id
WHERE o.stage_name = 'Ganho' AND o.created_at_source >= '2025-09-14';

\echo ''
\echo '   ...e o mesmo por moeda, contra os números lidos no Salesforce'
SELECT o.currency_iso_code AS moeda,
       count(*)            AS ganhas,
       sum(o.amount)       AS soma_crua,
       sum(vr.amount_brl)  AS soma_brl,
       CASE o.currency_iso_code
         WHEN 'BRL' THEN 1742219.98
         WHEN 'USD' THEN 1871669.00
         WHEN 'MXN' THEN  229425.81
       END                 AS soma_brl_lida_no_salesforce
FROM opportunity o
JOIN view_receita vr ON vr.opportunity_id = o.id
WHERE o.stage_name = 'Ganho' AND o.created_at_source >= '2025-09-14'
GROUP BY 1 ORDER BY 1;

\echo ''
\echo '══ 4. MOEDA DESCONHECIDA DÁ NULL, NUNCA amount × 1 ═════════════════════'
-- Caso NATURAL, não fabricado: três oportunidades de seed (2026-09-07) que
-- nunca vieram do Salesforce e por isso não têm moeda. `deu_null` tem de ser
-- `t` e `caiu_em_fallback_x1` tem de ser `f` em todas.
SELECT o.source_id, o.stage_name, o.amount, o.currency_iso_code,
       vr.amount_brl, vr.contrato_valor_brl,
       vr.conversao_indisponivel_motivo,
       (vr.amount_brl IS NULL)                  AS deu_null,
       (vr.amount_brl IS NOT DISTINCT FROM o.amount) AS caiu_em_fallback_x1
FROM opportunity o
JOIN view_receita vr ON vr.opportunity_id = o.id
WHERE o.currency_iso_code IS NULL
ORDER BY o.source_id;

\echo ''
\echo '   TESTE NEGATIVO 4 — moeda PRESENTE mas ausente de currency_rate.'
\echo '   Forçado em transação desfeita: não existe caso natural hoje.'
BEGIN;
  UPDATE opportunity SET currency_iso_code = 'JPY'
   WHERE source_id = 'seed-opp-ganha-com-duracao';
  SELECT o.source_id, o.amount, o.currency_iso_code,
         vr.amount_brl,
         vr.conversao_indisponivel_motivo,
         (vr.amount_brl IS NULL) AS deu_null
  FROM opportunity o JOIN view_receita vr ON vr.opportunity_id = o.id
  WHERE o.source_id = 'seed-opp-ganha-com-duracao';

  \echo '   ...e agora dando uma taxa ao JPY: a asserção TEM de virar falsa.'
  INSERT INTO currency_rate (iso_code, conversion_rate, collected_at)
  VALUES ('JPY', 2, now());
  SELECT o.source_id, o.amount, vr.amount_brl,
         (vr.amount_brl IS NULL) AS deu_null_agora_deve_ser_f
  FROM opportunity o JOIN view_receita vr ON vr.opportunity_id = o.id
  WHERE o.source_id = 'seed-opp-ganha-com-duracao';
ROLLBACK;

\echo ''
\echo '   TESTE NEGATIVO 4b — taxa zero é recusada pelo CHECK?'
BEGIN;
  SAVEPOINT sp;
  INSERT INTO currency_rate (iso_code, conversion_rate, collected_at)
  VALUES ('ZZZ', 0, now());   -- deve estourar currency_rate_taxa_positiva
  ROLLBACK TO SAVEPOINT sp;
ROLLBACK;

\echo ''
\echo '══ 5. A EXCLUSÃO NÃO É SILENCIOSA NA CAMADA DE PESSOA ══════════════════'
-- sum() ignora NULL. Se uma ganha não converter, ela some da soma — a menos
-- que dê para CONTÁ-LA. Estas colunas são o rastro exigido pelo contrato §1.6.
SELECT count(*)                                                  AS pessoas_com_ganha,
       sum(amount_ganho)                                         AS soma_crua,
       sum(amount_ganho_brl)                                     AS soma_brl,
       sum(qtd_ganhas_sem_conversao)                             AS ganhas_fora_da_soma,
       count(*) FILTER (WHERE conversao_indisponivel_motivo IS NOT NULL) AS pessoas_com_motivo,
       count(*) FILTER (WHERE array_length(moedas_ganho,1) > 1)  AS pessoas_que_misturavam_moeda
FROM view_pessoa_jornada_desfecho
WHERE qtd_ganhas > 0;

\echo ''
\echo '   As pessoas cuja soma CRUA misturava moedas — o defeito, por pessoa:'
SELECT nome, empresa, qtd_ganhas, moedas_ganho,
       amount_ganho AS soma_crua, amount_ganho_brl AS soma_brl,
       round(amount_ganho_brl - amount_ganho, 2) AS quanto_faltava
FROM view_pessoa_jornada_desfecho
WHERE array_length(moedas_ganho, 1) > 1
ORDER BY (amount_ganho_brl - amount_ganho) DESC NULLS LAST
LIMIT 10;

\echo ''
\echo '══ 6. Lead.ConvertedOpportunityId — O VÍNCULO INDIVIDUAL ═══════════════'
SELECT count(*)                                            AS leads_salesforce,
       count(converted_account_id)                         AS com_conta,
       count(converted_opportunity_id)                     AS com_oportunidade,
       count(DISTINCT converted_account_id)                AS contas_distintas,
       count(DISTINCT converted_opportunity_id)            AS oportunidades_distintas,
       count(*) FILTER (WHERE converted_account_id IS NULL
                          AND converted_opportunity_id IS NOT NULL) AS so_pelo_novo_campo
FROM lead WHERE source_system = 'salesforce';

\echo ''
\echo '   Quantos leads o join POR CONTA super-credita hoje (>1 oportunidade):'
SELECT count(*) AS leads_com_conta_de_varias_oportunidades,
       sum(n)   AS linhas_que_view_lead_360_devolve_para_eles
FROM (
  SELECT l.id, count(*) AS n
  FROM lead l
  JOIN account a ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
  JOIN opportunity o ON o.account_id = a.id
  GROUP BY l.id HAVING count(*) > 1
) t;
