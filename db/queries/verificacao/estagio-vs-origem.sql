-- db/queries/verificacao/estagio-vs-origem.sql
--
-- Verificação da migration 092 — o estágio declarado pela origem.
--
-- Rodar:
--   set -a; . ./.env; set +a
--   /opt/homebrew/opt/libpq/bin/psql "$NEON_DATABASE_URL" -f db/queries/verificacao/estagio-vs-origem.sql
--
-- A ORDEM IMPORTA. A query 0 é um GUARDA: se `opportunity_stage` estiver
-- vazia, TODAS as checagens abaixo voltam limpas, e limpo viraria falso verde.
-- Os testes negativos (queries 5 a 7) existem porque na migration 091 a
-- asserção escolhida não conseguia falhar: testar GRANT de função executando
-- como `crm_ingest` não provava nada, porque `CREATE FUNCTION` já concede
-- EXECUTE a PUBLIC. Aqui a pergunta equivalente é: a checagem de inversão
-- consegue voltar VAZIA? Se não conseguir, ela não está medindo nada.

\echo '=== 0. GUARDA — a declaração da origem está carregada? ==================='
-- Sem esta linha, tudo abaixo é falso verde.
SELECT
  count(*)                                             AS estagios_declarados,
  count(*) FILTER (WHERE is_active)                    AS ativos,
  count(*) FILTER (WHERE is_won)                       AS is_won_true,
  min(collected_at)                                    AS coletado_em,
  CASE WHEN count(*) = 0
       THEN 'FALHA: opportunity_stage VAZIA. Nenhuma checagem abaixo vale.'
       WHEN count(*) FILTER (WHERE is_won) = 0
       THEN 'FALHA: nenhum estagio com is_won=true. Payload provavelmente truncado.'
       ELSE 'OK' END                                   AS veredito
FROM opportunity_stage;

\echo ''
\echo '=== 1. FIDELIDADE — a tabela reflete a origem? =========================='
-- Valores lidos direto do Salesforce em 2026-09-16 via SOQL
-- (SELECT Id, MasterLabel, ApiName, IsActive, IsWon, IsClosed,
--  DefaultProbability, ForecastCategoryName, SortOrder FROM OpportunityStage).
-- `Ganho` e `Pending Sale` são os dois casos que decidem a migration: um é a
-- única venda real da base, o outro é o que a intuição teria transformado em
-- venda. Os outros quatro são os órfãos da 079.
WITH esperado (api_name, is_won, is_closed, prob, forecast, is_active) AS (
  VALUES
    ('Ganho',                 true,  true,  100::numeric, 'Closed',   true),
    ('Pending Sale',          false, false,  95::numeric, 'Pipeline', true),
    ('Pending Payment',       false, false,  95::numeric, 'Pipeline', true),
    ('Processamento Interno', false, false,  95::numeric, 'Pipeline', true),
    ('Projeto para o Futuro', false, false,  20::numeric, 'Pipeline', true),
    ('Lista',                 false, false,  NULL,        'Omitted',  false)
)
SELECT
  e.api_name,
  os.is_won, os.is_closed, os.default_probability, os.forecast_category, os.is_active,
  CASE
    WHEN os.api_name IS NULL THEN 'FALHA: ausente da tabela'
    WHEN os.is_won             IS DISTINCT FROM e.is_won     THEN 'FALHA: is_won'
    WHEN os.is_closed          IS DISTINCT FROM e.is_closed   THEN 'FALHA: is_closed'
    WHEN os.default_probability IS DISTINCT FROM e.prob       THEN 'FALHA: default_probability'
    WHEN os.forecast_category  IS DISTINCT FROM e.forecast    THEN 'FALHA: forecast_category'
    WHEN os.is_active          IS DISTINCT FROM e.is_active   THEN 'FALHA: is_active'
    ELSE 'OK'
  END AS veredito
FROM esperado e
LEFT JOIN opportunity_stage os ON os.api_name = e.api_name
ORDER BY e.api_name;

\echo ''
\echo '=== 2. ÓRFÃOS — estágio da base sem fase, e por quê ====================='
-- Duas categorias que a tela renderiza igual e só o banco distingue:
-- DESCONHECIDO (ausente da tabela, ninguém decidiu) e
-- FORA POR DECISÃO (presente com fase NULL e motivo escrito).
SELECT
  o.stage_name,
  count(*) AS oportunidades,
  CASE WHEN f.stage_name IS NULL THEN 'DESCONHECIDO — ninguem decidiu'
       ELSE 'FORA DO FUNIL POR DECISAO DECLARADA' END AS categoria,
  f.motivo
FROM opportunity o
LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
WHERE o.source_system = 'salesforce'
  AND o.stage_name IS NOT NULL
  AND (f.stage_name IS NULL OR f.fase IS NULL)
GROUP BY o.stage_name, f.stage_name, f.motivo
ORDER BY 2 DESC;

\echo ''
\echo '=== 2b. CONTAGEM — antes (27 em 5 estagios) vs depois ==================='
SELECT
  count(*) FILTER (WHERE f.stage_name IS NULL)                        AS opps_estagio_desconhecido,
  count(DISTINCT o.stage_name) FILTER (WHERE f.stage_name IS NULL)    AS estagios_desconhecidos,
  count(*) FILTER (WHERE f.stage_name IS NOT NULL AND f.fase IS NULL) AS opps_fora_por_decisao,
  count(*) FILTER (WHERE f.fase IS NOT NULL)                          AS opps_com_fase,
  count(*)                                                            AS total
FROM opportunity o
LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
WHERE o.source_system = 'salesforce' AND o.stage_name IS NOT NULL;

\echo ''
\echo '=== 3. INVERSOES — nosso julgamento contra a probabilidade da origem ===='
-- TEM de trazer No-Show (reuniao, ordem 3, prob 15) abaixo de Coleta de Cenario
-- (qualificacao, ordem 2, prob 30). Se vier vazia, a checagem esta quebrada --
-- nao o mapeamento perfeito.
SELECT stage_name, fase, ordem, default_probability,
       estagio_anterior, fase_anterior, prob_anterior, inversao_pontos
FROM view_fase_vs_origem
WHERE diagnostico = 'inversao de probabilidade'
ORDER BY inversao_pontos DESC, stage_name;

\echo ''
\echo '=== 4. PANORAMA — uma linha por estagio, com diagnostico ================'
SELECT diagnostico, count(*) AS estagios,
       string_agg(stage_name, ', ' ORDER BY stage_name) AS quais
FROM view_fase_vs_origem GROUP BY 1 ORDER BY 2 DESC;

\echo ''
\echo '=== 5. TESTE NEGATIVO A — a checagem de inversao consegue voltar VAZIA? ='
-- Se a resposta for nao, "0 inversoes" nunca significaria nada.
-- Reordena as fases pela PROPRIA probabilidade declarada (ordenacao monotonica
-- por construcao) e roda a MESMA view -- nao uma copia da logica, a view.
BEGIN;
  WITH monot AS (
    SELECT f.stage_name,
           dense_rank() OVER (ORDER BY os.default_probability) AS nova_ordem
    FROM opportunity_stage_fase f
    JOIN opportunity_stage os ON os.api_name = f.stage_name
    WHERE f.fase IS NOT NULL AND os.default_probability IS NOT NULL
      AND NOT coalesce(os.is_closed, false)
  )
  UPDATE opportunity_stage_fase f
     SET ordem = m.nova_ordem
    FROM monot m WHERE m.stage_name = f.stage_name;
  SELECT count(*) AS inversoes_com_ordem_monotonica,
         CASE WHEN count(*) = 0 THEN 'OK — a checagem sabe ficar quieta'
              ELSE 'FALHA: acusa inversao onde a ordem segue a propria probabilidade' END AS veredito
  FROM view_fase_vs_origem WHERE diagnostico = 'inversao de probabilidade';
ROLLBACK;

\echo ''
\echo '=== 6. TESTE NEGATIVO B — a checagem pega a venda inventada? ============'
-- O erro que esta migration existe para impedir: mapear Pending Sale como
-- ganho. A origem diz is_won=false. O diagnostico TEM de virar divergente.
BEGIN;
  UPDATE opportunity_stage_fase SET fase = 'ganho', ordem = 5 WHERE stage_name = 'Pending Sale';
  SELECT stage_name, fase, is_won, diagnostico,
         CASE WHEN diagnostico LIKE 'desfecho divergente%' THEN 'OK — a venda inventada e acusada'
              ELSE 'FALHA: mapear Pending Sale como ganho passa em silencio' END AS veredito
  FROM view_fase_vs_origem WHERE stage_name = 'Pending Sale';
ROLLBACK;

\echo ''
\echo '=== 7. TESTE NEGATIVO C — a view le mesmo opportunity_stage? ============'
-- Se a tabela de origem sumir, a view NAO pode ficar verde. Esvazia e confere.
BEGIN;
  DELETE FROM opportunity_stage;
  SELECT count(*) FILTER (WHERE diagnostico = 'estagio ausente da origem') AS ausentes,
         count(*) FILTER (WHERE diagnostico = 'ok')                        AS ainda_ok,
         count(*) FILTER (WHERE diagnostico = 'inversao de probabilidade') AS inversoes,
         CASE WHEN count(*) FILTER (WHERE diagnostico = 'ok') = 0
                   AND count(*) FILTER (WHERE diagnostico = 'estagio ausente da origem') > 0
              THEN 'OK — origem vazia grita, nao silencia'
              ELSE 'FALHA: a view fica verde sem dado de origem' END AS veredito
  FROM view_fase_vs_origem;
ROLLBACK;

\echo ''
\echo '=== 8. RECEITA INTACTA — a 092 nao pode ter mexido em ganho ============='
-- ATENCAO AO DENOMINADOR: `SELECT ... WHERE fase='ganho'` SEM filtrar
-- source_system devolve 2.553 Ganhas e R$ 12.437.110,01 -- e 3.000,00 desse
-- total sao DINHEIRO DE FIXTURE. Ha 3 linhas com source_system='seed_test' na
-- tabela opportunity (migration 025, source_id LIKE 'seed-%'), duas delas
-- Ganhas com amount 1.000 e 2.000 e SEM currency_iso_code. A 092 nao criou
-- isso; so ficou visivel ao conferir a receita.
--
-- O numero do Salesforce e 2.551 Ganhas / R$ 12.434.110,01.
SELECT
  o.source_system,
  count(*)                        AS ganhas,
  round(sum(o.amount), 2)         AS amount_cru_moeda_misturada,
  round(sum(vr.amount_brl), 2)    AS receita_brl,
  count(*) FILTER (WHERE o.currency_iso_code IS NULL) AS sem_moeda
FROM opportunity o
JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name AND f.fase = 'ganho'
LEFT JOIN view_receita vr ON vr.opportunity_id = o.id
GROUP BY ROLLUP (o.source_system)
ORDER BY o.source_system NULLS LAST;
