-- db/queries/verificacao/moeda-por-pessoa.sql
--
-- Verificação da migration 091 — a busca por PESSOA passa a devolver receita em
-- moeda única. Irmão de `moeda-conversao.sql` (que verifica a 090, no grão de
-- OPORTUNIDADE). Este verifica o grão de PESSOA e o CONTRATO da função.
--
-- REGRA DESTE ARQUIVO (a mesma da 090): toda asserção vem acompanhada do TESTE
-- NEGATIVO que prova que ela CONSEGUE FALHAR. Uma verificação que passa vazia
-- não é verificação, é decoração.
--
-- ⚠️ UM DOS TESTES "ÓBVIOS" DESTA MIGRATION É FALSO, E ESTÁ DOCUMENTADO NA
-- SEÇÃO 4: executar a função como `crm_ingest` NÃO testa o GRANT de função.
--
-- Rodar inteiro:
--   set -a; . ./.env; set +a
--   /opt/homebrew/opt/libpq/bin/psql "$NEON_DATABASE_URL" \
--     -f db/queries/verificacao/moeda-por-pessoa.sql

\pset pager off

\echo ''
\echo '══ 0. A ASSINATURA NOVA ════════════════════════════════════════════════'
SELECT pg_get_function_result(oid) AS assinatura
FROM pg_proc WHERE proname = 'fn_search_pessoas';

\echo ''
\echo '══ 1. O CRU SAIU, O CONVERTIDO ENTROU ══════════════════════════════════'
-- As duas primeiras colunas TÊM de vir FALSE. Teste negativo na seção 1b.
SELECT
  pg_get_function_result(oid) ~ '\mamount_ganho numeric'       AS ainda_tem_amount_ganho_cru,
  pg_get_function_result(oid) ~ '\mmrr_ganho numeric'          AS ainda_tem_mrr_ganho_cru,
  pg_get_function_result(oid) ~ 'amount_ganho_brl'             AS tem_amount_ganho_brl,
  pg_get_function_result(oid) ~ 'contrato_valor_brl'           AS tem_contrato_valor_brl,
  pg_get_function_result(oid) ~ 'qtd_ganhas_sem_conversao'     AS tem_qtd_ganhas_sem_conversao,
  pg_get_function_result(oid) ~ 'conversao_indisponivel_motivo' AS tem_motivo,
  pg_get_function_result(oid) ~ 'moedas_ganho'                 AS tem_moedas_ganho
FROM pg_proc WHERE proname = 'fn_search_pessoas';

\echo ''
\echo '══ 1b. TESTE NEGATIVO: o regex acima SABE achar o cru ══════════════════'
-- Sem isto, "ainda_tem_amount_ganho_cru = false" poderia significar apenas que
-- o regex está errado. Aqui ele roda contra a assinatura ANTIGA (v2 / migration
-- 087), colada como literal, e TEM de vir TRUE nas duas primeiras.
WITH antiga(sig) AS (VALUES (
  'TABLE(pessoa_chave text, ..., estagio_mais_avancado text, mrr_ganho numeric, amount_ganho numeric, trimestre text, ...)'
))
SELECT sig ~ '\mamount_ganho numeric' AS regex_pega_o_amount_cru,
       sig ~ '\mmrr_ganho numeric'    AS regex_pega_o_mrr_cru,
       sig ~ 'amount_ganho_brl'       AS antiga_ja_tinha_brl  -- tem de ser FALSE
FROM antiga;

\echo ''
\echo '══ 2. ANTES x DEPOIS — AS 11 PESSOAS DE MOEDA MISTURADA ════════════════'
-- `v2_amount_ganho_cru` é exatamente o número que a versão anterior da função
-- devolvia (a coluna crua, que continua na view). `v3_amount_ganho_brl` é o que
-- ela devolve agora. O erro NÃO tem sinal fixo: email:2490 aparecia com METADE
-- do valor; a de MXN+USD aparecia com 3,4x. Não há fator de correção possível.
SELECT
  left(f.pessoa_chave, 28)        AS pessoa,
  f.qtd_ganhas,
  f.moedas_ganho,
  round(v.amount_ganho, 2)        AS v2_amount_ganho_cru,
  round(f.amount_ganho_brl, 2)    AS v3_amount_ganho_brl,
  round(f.contrato_valor_brl, 2)  AS v3_contrato_valor_brl,
  f.qtd_ganhas_sem_conversao      AS v3_sem_conversao,
  round(v.mrr_ganho, 2)           AS v2_mrr_ganho_cru
FROM fn_search_pessoas('{"so_com_oportunidade":true}'::jsonb, 5000, 0) f
JOIN view_pessoa_jornada_desfecho v USING (pessoa_chave)
WHERE array_length(f.moedas_ganho, 1) > 1
ORDER BY f.amount_ganho_brl DESC NULLS LAST;

\echo ''
\echo '══ 2b. TESTE NEGATIVO: a seção 2 não pode vir vazia ════════════════════'
-- Se `pessoas_moeda_mista` virar 0, a seção 2 passa vazia e não prova NADA.
-- Ela tem de ser > 0 enquanto a org for multi-moeda.
SELECT count(*) FILTER (WHERE array_length(moedas_ganho,1) > 1) AS pessoas_moeda_mista,
       count(*) FILTER (WHERE moedas_ganho IS NOT NULL)         AS pessoas_com_ganha,
       count(*) FILTER (WHERE amount_ganho_brl IS DISTINCT FROM amount_ganho) AS onde_cru_e_brl_divergem
FROM view_pessoa_jornada_desfecho;

\echo ''
\echo '══ 2c. DECOMPOSIÇÃO DO PIOR CASO — de onde saem os dois números ════════'
-- 72.520,00 BRL + 23.500,10 USD.
--   soma crua  = 96.020,10  (reais somados com dólares: sem unidade)
--   convertido = 72.520,00 + 23.500,10/0,19604 = 192.394,01
SELECT o.source_id, o.stage_name, vr.moeda, o.amount AS amount_cru,
       vr.taxa_conversao, round(vr.amount_brl, 2) AS amount_brl
FROM view_pessoa p
JOIN lead l    ON l.id = p.sf_lead_id
JOIN account a ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
JOIN opportunity o ON o.account_id = a.id
JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name AND f.fase = 'ganho'
JOIN view_receita vr ON vr.opportunity_id = o.id
WHERE p.pessoa_chave = 'email:2490';

\echo ''
\echo '══ 2d. POR QUE `mrr_ganho` SAIU E NÃO FOI SUBSTITUÍDO ══════════════════'
-- (i) NÃO EXISTE mrr_brl no banco. Esta consulta lista TODA coluna de MRR:
--     todas cruas. A 090 converteu `amount`, não converteu MRR.
SELECT table_name, column_name
FROM information_schema.columns
WHERE column_name ILIKE '%mrr%'
ORDER BY 1, 2;

-- (ii) A COLUNA não tem unidade nem quando a LINHA tem. Qualquer total de
--      rodapé sobre a lista somaria reais do grupo BRL com pesos do grupo MXN.
SELECT coalesce(array_to_string(moedas_ganho, '+'), '(sem moeda)') AS moedas,
       count(*) AS pessoas,
       count(*) FILTER (WHERE mrr_ganho IS NOT NULL) AS com_mrr,
       round(sum(mrr_ganho), 2) AS soma_mrr_cru
FROM view_pessoa_jornada_desfecho
WHERE moedas_ganho IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '══ 3. NADA SE PERDEU NO CAMINHO ════════════════════════════════════════'
-- Trocar a projeção não pode mudar quantas linhas a função devolve nem o total
-- que ela reporta. `total_funcao` = `total_view` = `linhas_devolvidas`.
SELECT
  (SELECT total_filtrado FROM fn_search_pessoas('{}'::jsonb, 1, 0))                AS total_funcao,
  (SELECT count(*) FROM view_pessoa_jornada_desfecho WHERE NOT de_lista_importada) AS total_view,
  (SELECT count(*) FROM fn_search_pessoas('{}'::jsonb, 10000, 0))                  AS linhas_devolvidas,
  (SELECT count(*) FROM fn_search_pessoas('{}'::jsonb, 10000, 0)
     WHERE amount_ganho_brl IS NOT NULL)                                           AS com_receita_brl,
  (SELECT count(*) FROM fn_search_pessoas('{}'::jsonb, 10000, 0)
     WHERE qtd_ganhas_sem_conversao > 0)                                           AS ganhas_sem_conversao;

\echo ''
\echo '══ 4. O GRANT — E POR QUE O TESTE ÓBVIO É UM VERDE FALSO ═══════════════'
-- ⚠️ MEDIDO EM 2026-09-16 E CONTRARIA A REGRA CORRENTE DESTE ÉPICO.
--
-- "Prove o grant conectando pelo pooler como crm_ingest" vale para SEQUÊNCIA
-- (migration 049) e para VIEW (migration 090), porque PUBLIC não tem privilégio
-- default nesses objetos. NÃO vale para FUNÇÃO: `CREATE FUNCTION` já concede
-- EXECUTE a PUBLIC por padrão. Reproduza:
--
--   -- como owner:
--   CREATE FUNCTION fn_probe_091() RETURNS int LANGUAGE sql STABLE AS $x$ SELECT 42 $x$;
--   SELECT proacl FROM pg_proc WHERE proname='fn_probe_091';   -- NULL
--   -- pelo pooler, COMO crm_ingest, SEM nenhum grant:
--   SELECT fn_probe_091();                                     -- devolve 42. NÃO nega.
--   DROP FUNCTION fn_probe_091();
--
-- Ou seja: a chamada como crm_ingest prova ALCANCE ponta a ponta (role, pooler,
-- search_path, assinatura) — e isso é útil. Mas passa com grant e sem grant.
--
-- 4a. A asserção que DE FATO distingue (e o negativo dela está logo abaixo):
SELECT proname,
       coalesce(proacl::text[], '{}') @> ARRAY['crm_ingest=X/neondb_owner'] AS grant_explicito,
       coalesce(proacl::text, '(nulo = default: PUBLIC tem EXECUTE)')       AS acl
FROM pg_proc
WHERE proname IN ('fn_search_pessoas', 'fn_search_leads')
ORDER BY proname;

-- 4b. TESTE NEGATIVO do 4a: rode o bloco CREATE/DROP do comentário acima e
--     inclua 'fn_probe_091' no IN() — `grant_explicito` vem FALSE para ela e
--     TRUE para fn_search_pessoas. Conferido em 2026-09-16.
--
-- 4c. ACHADO DE SEGURANÇA, registrado e NÃO corrigido aqui: como PUBLIC tem
--     EXECUTE por default, QUALQUER role deste banco executa fn_search_pessoas.
--     Fechar isso é `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC`, que mexe na
--     superfície de permissão de todas as funções — migration própria,
--     deliberada, não um efeito colateral desta.

\echo ''
\echo '══ 5. O plan_cache_mode SOBREVIVEU AO DROP FUNCTION ════════════════════'
-- DROP FUNCTION descarta o ALTER FUNCTION junto. Sem reemitir, a busca volta
-- dos ~285 ms para os ~207 s medidos na 089 (800x). Esta é a asserção:
SELECT proname,
       coalesce(proconfig::text, '(nulo — PLANO GENÉRICO, BUSCA QUEBRADA)') AS proconfig,
       coalesce(proconfig, '{}') @> ARRAY['plan_cache_mode=force_custom_plan'] AS ok
FROM pg_proc
WHERE proname IN ('fn_search_pessoas', 'fn_search_leads')
ORDER BY proname;

\echo ''
\echo '══ 5b. TESTE NEGATIVO do plan_cache_mode — SEM EXECUTAR NADA ═══════════'
-- Não reproduzo os 3m27s da 089: queimar 3 minutos de CPU num compute de
-- 230 MB derruba a aba inteira por contenção (a própria 089 mediu isso). O
-- EXPLAIN (GENERIC_PLAN) do PG16+ mostra a MESMA causa de graça.
--
-- O que olhar: no plano genérico o topo vem `rows=1` e a árvore inteira vira
-- Nested Loop; no custom vem `rows=50` com estimativas reais e Hash Join.
-- Medido em 2026-09-16:  genérico cost=17337  rows=1   |  custom cost=9345  rows=50
EXPLAIN (GENERIC_PLAN, COSTS ON)
SELECT v.pessoa_chave
FROM view_pessoa_jornada_desfecho v
WHERE ($1::text IS NULL OR v.segmento        = $1::text)
  AND ($2::text IS NULL OR v.categoria       = $2::text)
  AND ($3::text IS NULL OR v.plataforma      = $3::text)
  AND ($4::text IS NULL OR v.fase_mais_avancada = $4::text)
  AND ($5::text IS NULL OR v.trimestre       = $5::text)
  AND ($6::text IS NULL OR v.cargo_grupo     = $6::text)
  AND ($7::text IS NULL OR v.atendido_por    = $7::text)
  AND ($8::text IS NULL OR v.estagio_funil   = $8::text)
  AND ($9::text IS NULL OR v.tamanho_empresa = $9::text)
ORDER BY v.fase_ordem DESC NULLS LAST
LIMIT 50;

\echo ''
\echo '══ 6. TEMPO REAL — RODAR COMO crm_ingest, PELO POOLER ══════════════════'
-- ⚠️ Esta seção só vale executada pela conexão do n8n. Rode:
--   /opt/homebrew/opt/libpq/bin/psql "$NEON_INGEST_DATABASE_URL" -X \
--     -c '\timing on' \
--     -c "select count(*) from fn_search_pessoas('{}'::jsonb, 50, 0);" \
--     -c "select count(*) from fn_search_pessoas('{}'::jsonb, 50, 0);"
-- Medido em 2026-09-16, depois da 091: 275,8 ms · 288,2 ms · 288,9 ms
-- (antes da 091, mesma conexão: 420,1 ms · 295,7 ms · 276,0 ms — sem regressão).
-- Pools são separados por role: medir só pelo owner mascara o defeito.
SELECT current_user AS medindo_como,
       'rode a seção 6 pela URL de crm_ingest, não por esta' AS aviso;
