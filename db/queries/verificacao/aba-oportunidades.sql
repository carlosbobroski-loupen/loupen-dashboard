-- db/queries/verificacao/aba-oportunidades.sql
--
-- VERIFICAÇÃO DAS MIGRATIONS 097, 098 E 100.
--
-- REGRA DESTE ÉPICO: uma asserção só vale depois de eu PROVAR QUE ELA CONSEGUE
-- FALHAR. Já houve seis "verdes" vazios aqui; um deles passou em branco porque
-- `ORDER BY ... DESC` põe NULL primeiro e a checagem comparou nada com nada.
-- Por isso cada bloco abaixo tem duas metades: o estado REAL e um estado
-- QUEBRADO DE PROPÓSITO dentro de uma transação revertida, mostrando a mesma
-- checagem acusando.
--
-- Rodar inteiro:
--   psql "$NEON_DATABASE_URL" -f db/queries/verificacao/aba-oportunidades.sql
--
-- Nenhum bloco deixa efeito: todos os que escrevem terminam em ROLLBACK.
--
-- ⚠️ DOIS BLOCOS (C3 e D3) COMPARAM CONTRA CONSTANTES DE 2026-09-16 -- 987
-- ganhas e R$ 3.819.632,79 na janela de 12 meses. Elas são a FOTO do dia em que
-- a camada foi construída e vão envelhecer com a próxima ingestão. Quando
-- envelhecerem o teste acusa 'FALHOU' e o certo é ATUALIZAR A CONSTANTE depois
-- de conferir por que mudou -- nunca apagar o teste. Escrever essas duas
-- checagens de forma auto-referente (comparar a função consigo mesma) as
-- tornaria sempre verdes, que é o modo de falha que este arquivo existe para
-- não repetir.

\set ON_ERROR_STOP on
\pset pager off

-- ═════════════════════════════════════════════════════════════════════════════
-- A. A SOMA FECHA — E A CHECAGEM CONSEGUE ACUSAR QUANDO NÃO FECHA
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- A1. estado real: as 6 contagens somam o universo inteiro ---'
SELECT total_oportunidades, qtd_ganhas, qtd_perdidas, qtd_abertas,
       qtd_fora_de_fase, qtd_estagio_nao_declarado, qtd_declaracao_incompleta,
       soma_fecha, soma_fecha_diferenca,
       CASE WHEN soma_fecha THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_cards('{}'::jsonb);

\echo '--- A2. a view e a tabela contam o mesmo universo (nenhuma linha some no join) ---'
SELECT (SELECT count(*) FROM view_oportunidade_analitica)                          AS na_view,
       (SELECT count(*) FROM opportunity WHERE source_system = 'salesforce')       AS na_tabela,
       CASE WHEN (SELECT count(*) FROM view_oportunidade_analitica)
                 = (SELECT count(*) FROM opportunity WHERE source_system='salesforce')
            THEN 'OK' ELSE 'FALHOU — o join com lead/conta multiplicou ou perdeu linha' END AS veredito;

\echo '--- A3. TESTE NEGATIVO: forço 4 linhas para um estágio que a origem não declara ---'
\echo '---     (transação revertida). Uma checagem de 4 baldes PERDE essas 4;'
\echo '---     a de 6 baldes continua fechando. É isso que prova que ela tem dentes.'
BEGIN;
  UPDATE opportunity
     SET stage_name = 'Estagio Fantasma 097'
   WHERE source_system = 'salesforce' AND stage_name = 'Lista';

  SELECT
    total_oportunidades,
    qtd_fora_de_fase,
    qtd_estagio_nao_declarado,
    -- A checagem COMPLETA (a que a função devolve)
    soma_fecha                                          AS soma_6_baldes_fecha,
    -- A checagem INCOMPLETA, escrita de propósito sem o balde novo
    (qtd_ganhas + qtd_perdidas + qtd_abertas + qtd_fora_de_fase) = total_oportunidades
                                                        AS soma_4_baldes_fecha,
    total_oportunidades - (qtd_ganhas + qtd_perdidas + qtd_abertas + qtd_fora_de_fase)
                                                        AS linhas_que_a_checagem_incompleta_perde,
    CASE WHEN soma_fecha
          AND NOT ((qtd_ganhas + qtd_perdidas + qtd_abertas + qtd_fora_de_fase) = total_oportunidades)
         THEN 'OK — a asserção acusou o desequilíbrio forçado'
         ELSE 'FALHOU — a asserção não distingue os dois casos, logo não vale nada' END AS veredito
  FROM fn_oportunidades_cards('{}'::jsonb);
ROLLBACK;

\echo '--- A4. o funil também fecha: as fases + a linha fora-de-fase = o total ---'
SELECT sum(qtd_da_coorte_agora) AS soma_das_fases,
       max(total_da_coorte)     AS total_da_coorte,
       count(*) FILTER (WHERE fase IS NULL) AS tem_linha_fora_de_fase,
       CASE WHEN sum(qtd_da_coorte_agora) = max(total_da_coorte)
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_funil('{}'::jsonb);

\echo '--- A5. o corte por segmento também fecha (definição 8) ---'
SELECT sum(qtd_oportunidades) AS soma_dos_segmentos,
       max(total_do_recorte)  AS total,
       -- migration 100: `SemLeadIdentificado` virou `SemOrigem` (a origem passou
       -- a existir em 99,98% das linhas) e `NaoClassificado` nasceu. Os dois
       -- baldes TÊM de existir na saída: é a garantia de que o desconhecido
       -- aparece em vez de se esconder num segmento já existente.
       count(*) FILTER (WHERE segmento_aba IN ('SemOrigem','NaoClassificado')) AS tem_balde_do_desconhecido,
       CASE WHEN sum(qtd_oportunidades) = max(total_do_recorte)
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_por_segmento('{}'::jsonb);

-- ═════════════════════════════════════════════════════════════════════════════
-- B. WIN RATE: OS DOIS NÚMEROS LADO A LADO, PARA O MESMO RECORTE
-- ═════════════════════════════════════════════════════════════════════════════
-- O defeito da aba antiga em uma linha. Não é arredondamento: é denominador.

\echo '--- B1. universo inteiro e janela de 12 meses ---'
SELECT 'universo inteiro' AS recorte, total_oportunidades, qtd_ganhas, qtd_perdidas,
       qtd_decididas, win_rate_sobre_todas_pct, win_rate_decididas_pct,
       round(win_rate_decididas_pct - win_rate_sobre_todas_pct, 2) AS diferenca_pp
FROM fn_oportunidades_cards('{}'::jsonb)
UNION ALL
SELECT '12 meses', total_oportunidades, qtd_ganhas, qtd_perdidas,
       qtd_decididas, win_rate_sobre_todas_pct, win_rate_decididas_pct,
       round(win_rate_decididas_pct - win_rate_sobre_todas_pct, 2)
FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb);

\echo '--- B2. o denominador correto NÃO cai quando o pipeline cresce ---'
\echo '---     (era exatamente esse o defeito: 3÷44 piora só por abrir oportunidade)'
SELECT qtd_decididas AS denominador_decididas,
       total_oportunidades AS denominador_todas,
       qtd_abertas + qtd_fora_de_fase AS abertas_que_inflavam_o_denominador_errado,
       CASE WHEN qtd_decididas < total_oportunidades
            THEN 'OK — os dois denominadores são de fato diferentes neste recorte'
            ELSE 'INCONCLUSIVO — sem oportunidade aberta os dois coincidem e o teste não prova nada' END AS veredito
FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb);

-- ═════════════════════════════════════════════════════════════════════════════
-- C. RECEITA: BATE COM view_receita, E O QUE FICOU DE FORA APARECE
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- C1. reconciliação ao centavo contra view_receita, mesmo recorte ---'
WITH pela_camada AS (
  SELECT receita_ganha_brl, qtd_ganhas_no_valor, qtd_ganhas_fora_do_valor, qtd_ganhas
  FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb)
),
pela_view_receita AS (
  -- MESMO recorte, montado à mão a partir da view que já estava em produção:
  -- só salesforce, só as criadas na janela, só Ganho.
  SELECT sum(r.amount_brl)                          AS receita,
         count(*) FILTER (WHERE r.amount_brl IS NOT NULL) AS com_valor,
         count(*) FILTER (WHERE r.amount_brl IS NULL)     AS sem_valor,
         count(*)                                   AS ganhas
  FROM view_receita r
  JOIN opportunity o ON o.id = r.opportunity_id
  WHERE o.source_system = 'salesforce'
    AND o.stage_name = 'Ganho'
    AND o.created_at_source >= '2025-09-16' AND o.created_at_source < '2026-09-16'
)
SELECT round(c.receita_ganha_brl, 2) AS camada_097,
       round(v.receita, 2)           AS view_receita,
       round(c.receita_ganha_brl - v.receita, 2) AS diferenca,
       c.qtd_ganhas_no_valor, v.com_valor,
       c.qtd_ganhas_fora_do_valor, v.sem_valor,
       c.qtd_ganhas, v.ganhas,
       CASE WHEN round(c.receita_ganha_brl, 2) = round(v.receita, 2)
             AND c.qtd_ganhas = v.ganhas
             AND c.qtd_ganhas_fora_do_valor = v.sem_valor
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM pela_camada c, pela_view_receita v;

\echo '--- C2. as ganhas sem valor são CONTADAS e MOTIVADAS, não somem ---'
SELECT qtd_ganhas, qtd_ganhas_no_valor, qtd_ganhas_fora_do_valor,
       ganhas_fora_do_valor_motivos,
       CASE WHEN qtd_ganhas_no_valor + qtd_ganhas_fora_do_valor = qtd_ganhas
            THEN 'OK' ELSE 'FALHOU — ganha que não está nem dentro nem fora da soma' END AS veredito
FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb);

\echo '--- C3. TESTE NEGATIVO da reconciliação: uma ganha a mais tem de QUEBRAR o C1 ---'
\echo '---     (transação revertida: mudo uma Perdida para Ganho e confiro que a camada se move)'
BEGIN;
  UPDATE opportunity SET stage_name = 'Ganho'
   WHERE id = (SELECT id FROM opportunity
                WHERE source_system='salesforce' AND stage_name='Perdido'
                  AND amount IS NOT NULL
                  AND created_at_source >= '2025-09-16' AND created_at_source < '2026-09-16'
                ORDER BY id LIMIT 1);

  SELECT qtd_ganhas AS ganhas_apos_a_injecao,
         987        AS ganhas_antes,
         CASE WHEN qtd_ganhas = 988
              THEN 'OK — a camada enxerga a linha injetada; a asserção de C1 reagiria'
              ELSE 'FALHOU — a camada não se moveu, logo C1 estava verde por acaso' END AS veredito
  FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb);
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. MOEDA DESCONHECIDA DÁ NULL, NUNCA amount × 1
-- ═════════════════════════════════════════════════════════════════════════════
-- Não há caso natural: as 8.073 linhas têm moeda, e as 3 moedas estão em
-- currency_rate. Forço um, e reverto.

\echo '--- D1. estado real: nenhuma linha com moeda fora de currency_rate ---'
SELECT count(*) FILTER (WHERE moeda IS NULL)                                AS sem_moeda,
       count(*) FILTER (WHERE moeda IS NOT NULL AND taxa_conversao IS NULL) AS moeda_sem_taxa,
       count(*)                                                             AS total
FROM view_oportunidade_analitica;

\echo '--- D2. TESTE FORÇADO: moeda "XYZ" numa ganha com valor (transação revertida) ---'
BEGIN;
  CREATE TEMP TABLE _alvo ON COMMIT DROP AS
    SELECT id, amount, currency_iso_code,
           (SELECT round(v.amount_brl, 2) FROM view_oportunidade_analitica v WHERE v.opportunity_id = o.id) AS brl_antes
    FROM opportunity o
    WHERE o.source_system='salesforce' AND o.stage_name='Ganho'
      AND o.amount IS NOT NULL AND o.currency_iso_code = 'USD'
    ORDER BY o.amount DESC NULLS LAST, o.id
    LIMIT 1;

  UPDATE opportunity SET currency_iso_code = 'XYZ' WHERE id = (SELECT id FROM _alvo);

  SELECT a.amount,
         a.brl_antes,
         v.moeda,
         v.taxa_conversao,
         v.amount_brl                     AS brl_depois,
         v.conversao_indisponivel_motivo,
         CASE
           WHEN v.amount_brl IS NULL
            AND v.conversao_indisponivel_motivo LIKE '%XYZ%'
           THEN 'OK — moeda desconhecida virou NULL com motivo declarado'
           WHEN v.amount_brl = a.amount
           THEN 'FALHOU — caiu no fallback amount × 1, que é fabricar número'
           ELSE 'FALHOU — resultado inesperado'
         END AS veredito
  FROM _alvo a JOIN view_oportunidade_analitica v ON v.opportunity_id = a.id;

  \echo '--- D3. e a receita do card cai EXATAMENTE o valor convertido, não o valor cru ---'
  SELECT (SELECT round(brl_antes, 2) FROM _alvo)             AS brl_da_linha_removida,
         (SELECT amount FROM _alvo)                          AS amount_cru_da_linha,
         round(3819632.79 - c.receita_ganha_brl, 2)          AS queda_na_receita,
         c.qtd_ganhas_fora_do_valor                          AS ganhas_fora_do_valor_agora,
         c.ganhas_fora_do_valor_motivos,
         CASE WHEN round(3819632.79 - c.receita_ganha_brl, 2)
                   = (SELECT round(brl_antes, 2) FROM _alvo)
              THEN 'OK — a receita caiu o valor EM BRL; se tivesse caído o valor cru, seria fallback ×1'
              ELSE 'FALHOU' END AS veredito
  FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb) c;
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. PERÍODO ANTERIOR: A MARCA ACENDE QUANDO NÃO HÁ DADO
-- ═════════════════════════════════════════════════════════════════════════════
-- A aba antiga desenhava toda seta contra zero porque a planilha não tinha
-- período anterior. Aqui a ausência é um BOOLEANO, não um zero.

\echo '--- E1. três recortes: com dado, sem dado, e sem período fechado ---'
SELECT '2025-09→2026-09 (anterior = 2024-09→2025-09)' AS recorte,
       periodo_anterior_de::date, periodo_anterior_ate::date,
       periodo_anterior_tem_dado, ant_total_oportunidades,
       left(coalesce(periodo_anterior_sem_dado_motivo, '(sem ressalva)'), 70) AS motivo
FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb)
UNION ALL
SELECT '2015 (anterior = 2014, base começa em 2015-12-29)',
       periodo_anterior_de::date, periodo_anterior_ate::date,
       periodo_anterior_tem_dado, ant_total_oportunidades,
       left(coalesce(periodo_anterior_sem_dado_motivo, '(sem ressalva)'), 70)
FROM fn_oportunidades_cards('{"de":"2015-01-01","ate":"2016-01-01"}'::jsonb)
UNION ALL
SELECT 'sem de/ate (não existe período anterior)',
       periodo_anterior_de::date, periodo_anterior_ate::date,
       periodo_anterior_tem_dado, ant_total_oportunidades,
       left(coalesce(periodo_anterior_sem_dado_motivo, '(sem ressalva)'), 70)
FROM fn_oportunidades_cards('{}'::jsonb);

\echo '--- E2. veredito: a marca distingue os três casos ---'
SELECT
  (SELECT periodo_anterior_tem_dado FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb)) AS com_dado,
  (SELECT periodo_anterior_tem_dado FROM fn_oportunidades_cards('{"de":"2015-01-01","ate":"2016-01-01"}'::jsonb)) AS sem_dado,
  (SELECT periodo_anterior_tem_dado FROM fn_oportunidades_cards('{}'::jsonb))                                     AS sem_periodo,
  CASE WHEN (SELECT periodo_anterior_tem_dado FROM fn_oportunidades_cards('{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb))
        AND NOT (SELECT periodo_anterior_tem_dado FROM fn_oportunidades_cards('{"de":"2015-01-01","ate":"2016-01-01"}'::jsonb))
        AND NOT (SELECT periodo_anterior_tem_dado FROM fn_oportunidades_cards('{}'::jsonb))
       THEN 'OK — acende e apaga; não é constante disfarçada de teste'
       ELSE 'FALHOU' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. DIVERGÊNCIA ORIGEM × NOSSA FASE: EXPOSTA, NÃO RESOLVIDA EM SILÊNCIO
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- F1. estado real: 0 divergências (os 29 estágios em uso concordam) ---'
SELECT count(*) FILTER (WHERE divergencia_origem_vs_fase IS NOT NULL) AS divergentes,
       count(DISTINCT estagio)                                        AS estagios_em_uso
FROM view_oportunidade_analitica;

\echo '--- F2. TESTE NEGATIVO: declaro IsWon=true para "Perdido" (transação revertida) ---'
BEGIN;
  UPDATE opportunity_stage SET is_won = true WHERE api_name = 'Perdido';

  SELECT count(*) FILTER (WHERE divergencia_origem_vs_fase IS NOT NULL) AS divergentes,
         min(divergencia_origem_vs_fase)                                AS exemplo,
         count(*) FILTER (WHERE desfecho = 'ganha' AND fase = 'perdido') AS viraram_ganha,
         CASE WHEN count(*) FILTER (WHERE divergencia_origem_vs_fase IS NOT NULL) > 0
              THEN 'OK — a divergência forçada foi detectada e descrita'
              ELSE 'FALHOU — a coluna nunca acende, logo não protege de nada' END AS veredito
  FROM view_oportunidade_analitica;
ROLLBACK;

\echo '--- F3. confirma que o rollback desfez ---'
SELECT is_won, is_closed FROM opportunity_stage WHERE api_name = 'Perdido';

-- ═════════════════════════════════════════════════════════════════════════════
-- G. O VÍNCULO COM LEAD NÃO MULTIPLICA LINHA
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- G1. distribuição das regras de vínculo, e os empates expostos ---'
SELECT lead_vinculo_regra, count(*) AS oportunidades,
       count(*) FILTER (WHERE qtd_leads_candidatos > 1) AS com_empate_de_lead,
       max(qtd_leads_candidatos) AS max_candidatos
FROM view_oportunidade_analitica
GROUP BY 1 ORDER BY 2 DESC;

\echo '--- G2. o join por CONTA, se fosse feito sem agregar, duplicaria ---'
\echo '---     (é o defeito que a coluna lead_vinculo_regra existe para tornar visível)'
SELECT (SELECT count(*) FROM view_oportunidade_analitica)                AS linhas_da_view,
       (SELECT count(*)
          FROM opportunity o
          JOIN account a ON a.id = o.account_id
          JOIN lead   l ON l.converted_account_id = a.source_id
         WHERE o.source_system = 'salesforce')                            AS linhas_se_juntasse_por_conta_sem_agregar,
       CASE WHEN (SELECT count(*)
                    FROM opportunity o
                    JOIN account a ON a.id = o.account_id
                    JOIN lead   l ON l.converted_account_id = a.source_id
                   WHERE o.source_system = 'salesforce') > 511
            THEN 'OK — o join cru de fato duplica; a agregação prévia é o que segura o grão'
            ELSE 'INCONCLUSIVO' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- H. A LISTA NÃO CONTRADIZ O CARD
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- H1. total_filtrado da lista = qtd_ganhas do card, mesmo recorte ---'
SELECT (SELECT total_filtrado FROM fn_search_oportunidades(
          '{"de":"2025-09-16","ate":"2026-09-16","desfecho":"ganha"}'::jsonb, 1, 0)) AS lista,
       (SELECT qtd_ganhas FROM fn_oportunidades_cards(
          '{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb))                           AS card,
       CASE WHEN (SELECT total_filtrado FROM fn_search_oportunidades(
                    '{"de":"2025-09-16","ate":"2026-09-16","desfecho":"ganha"}'::jsonb, 1, 0))
                 = (SELECT qtd_ganhas FROM fn_oportunidades_cards(
                    '{"de":"2025-09-16","ate":"2026-09-16"}'::jsonb))
            THEN 'OK' ELSE 'FALHOU — lista e card usam predicados diferentes' END AS veredito;

\echo '--- H2. ordenar por valor NÃO traz as sem-valor na frente (NULLS LAST) ---'
SELECT amount_brl IS NULL AS primeira_linha_e_sem_valor,
       CASE WHEN amount_brl IS NOT NULL
            THEN 'OK' ELSE 'FALHOU — NULL subiu para o topo do ORDER BY DESC' END AS veredito
FROM fn_search_oportunidades('{"ordenar_por":"valor"}'::jsonb, 1, 0);

-- ═════════════════════════════════════════════════════════════════════════════
-- I. PERMISSÃO — CONFERIDA POR CATÁLOGO, NÃO POR EXECUÇÃO
-- ═════════════════════════════════════════════════════════════════════════════
-- Executar como crm_ingest NÃO prova nada: default privileges já dariam acesso.
-- O que vale é o ACL do objeto.

\echo '--- I1. GRANTs dos objetos novos ---'
SELECT c.relname AS objeto, 'view' AS tipo,
       has_table_privilege('crm_ingest', c.oid, 'SELECT') AS crm_ingest_pode_ler
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'view_oportunidade_analitica'
UNION ALL
SELECT p.proname, 'function',
       has_function_privilege('crm_ingest', p.oid, 'EXECUTE')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('fn_oportunidades_cards','fn_oportunidades_funil',
                    'fn_oportunidades_por_segmento','fn_search_oportunidades')
ORDER BY 2, 1;

\echo '--- I2. plan_cache_mode travado nas 4 funções (migration 089) ---'
SELECT p.proname, p.proconfig,
       CASE WHEN 'plan_cache_mode=force_custom_plan' = ANY(coalesce(p.proconfig, '{}'))
            THEN 'OK' ELSE 'FALHOU — sujeita ao plano genérico que degradou 800x' END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('fn_oportunidades_cards','fn_oportunidades_funil',
                    'fn_oportunidades_por_segmento','fn_search_oportunidades')
ORDER BY 1;


-- ═════════════════════════════════════════════════════════════════════════════
-- J. MIGRATION 100 — A TERCEIRA FORÇA DA ATRIBUIÇÃO
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- J1. cobertura de segmento: a marca da 097 era 6,44% ---'
SELECT 6.44                                          AS pct_antes_migration_100,
       c.pct_com_segmento                            AS pct_agora,
       c.qtd_com_segmento, c.qtd_nao_classificado, c.qtd_sem_origem,
       c.total_oportunidades,
       CASE WHEN c.pct_com_segmento > 6.44
            THEN 'OK — a cobertura subiu de fato'
            ELSE 'FALHOU — a releitura de Opportunity.LeadSource não chegou ao banco' END AS veredito
FROM fn_oportunidades_cards('{}'::jsonb) c;

\echo '--- J2. a partição de lead_vinculo_regra continua TOTAL ---'
SELECT sum(n) AS soma_das_regras,
       (SELECT count(*) FROM view_oportunidade_analitica) AS total,
       CASE WHEN sum(n) = (SELECT count(*) FROM view_oportunidade_analitica)
            THEN 'OK' ELSE 'FALHOU — linha sem regra de vínculo' END AS veredito
FROM (SELECT lead_vinculo_regra, count(*) AS n
        FROM view_oportunidade_analitica GROUP BY 1) t;

\echo '--- J3. TESTE NEGATIVO: LeadSource = NULL numa oportunidade SEM lead ---'
\echo '---     tem de cair em sem_origem / SemOrigem (transação revertida)'
BEGIN;
  CREATE TEMP TABLE _alvo_ls ON COMMIT DROP AS
    SELECT opportunity_id, lead_source, lead_vinculo_regra, segmento_aba
    FROM view_oportunidade_analitica
    WHERE lead_vinculo_regra = 'leadsource'
    ORDER BY opportunity_id
    LIMIT 1;

  UPDATE opportunity SET lead_source = NULL WHERE id = (SELECT opportunity_id FROM _alvo_ls);

  SELECT a.lead_source          AS lead_source_antes,
         a.lead_vinculo_regra   AS regra_antes,
         a.segmento_aba         AS segmento_antes,
         v.lead_vinculo_regra   AS regra_depois,
         v.segmento_aba         AS segmento_depois,
         CASE WHEN v.lead_vinculo_regra = 'sem_origem' AND v.segmento_aba = 'SemOrigem'
              THEN 'OK — sem LeadSource a linha cai no balde declarado, e a asserção sabe distinguir'
              ELSE 'FALHOU' END AS veredito
  FROM _alvo_ls a JOIN view_oportunidade_analitica v ON v.opportunity_id = a.opportunity_id;
ROLLBACK;

\echo '--- J4. TESTE NEGATIVO: LeadSource INVENTADO não pode virar Comercial ---'
\echo '---     (o defeito que produziu "100% atribuído a marketing" era exatamente este)'
BEGIN;
  CREATE TEMP TABLE _alvo_inv ON COMMIT DROP AS
    SELECT opportunity_id FROM view_oportunidade_analitica
    WHERE lead_vinculo_regra = 'leadsource' AND segmento_aba = 'Comercial'
    ORDER BY opportunity_id LIMIT 1;

  UPDATE opportunity SET lead_source = 'Canal Que Nao Existe 100'
   WHERE id = (SELECT opportunity_id FROM _alvo_inv);

  SELECT v.lead_source, v.lead_vinculo_regra, v.segmento_aba, v.segmento, v.categoria,
         CASE
           WHEN v.segmento_aba = 'NaoClassificado' AND v.segmento IS NULL
             THEN 'OK — valor desconhecido virou categoria declarada, e não caiu em Comercial'
           WHEN v.segmento_aba IN ('Comercial','Marketing','Parceiro','NaoAtribuido')
             THEN 'FALHOU — valor inventado foi absorvido por um segmento existente'
           ELSE 'FALHOU — resultado inesperado'
         END AS veredito
  FROM _alvo_inv a JOIN view_oportunidade_analitica v ON v.opportunity_id = a.opportunity_id;

  \echo '--- J4b. e ele aparece na fila de classificação pendente ---'
  SELECT valor_bruto, oportunidades,
         CASE WHEN valor_bruto = 'Canal Que Nao Existe 100'
              THEN 'OK — entra em view_leadsource_nao_classificado, com próximo passo'
              ELSE 'FALHOU' END AS veredito
  FROM view_leadsource_nao_classificado WHERE valor_bruto = 'Canal Que Nao Existe 100';
ROLLBACK;

\echo '--- J5. PRECEDÊNCIA: lead vinculado ganha do LeadSource ---'
\echo '---     estado real: as 520 linhas com lead NÃO são classificadas por leadsource'
SELECT count(*)                                                        AS com_lead,
       count(*) FILTER (WHERE lead_vinculo_regra IN ('oportunidade','conta')) AS classificadas_pelo_lead,
       count(*) FILTER (WHERE lead_source IS NOT NULL)                 AS que_tambem_tem_leadsource,
       CASE WHEN count(*) FILTER (WHERE lead_vinculo_regra IN ('oportunidade','conta')) = count(*)
             AND count(*) FILTER (WHERE lead_source IS NOT NULL) > 0
            THEN 'OK — o lead vence mesmo quando o LeadSource também existe (a precedência é exercida, não teórica)'
            ELSE 'INCONCLUSIVO' END AS veredito
FROM view_oportunidade_analitica
WHERE lead_id IS NOT NULL;

\echo '--- J5b. TESTE NEGATIVO da precedência: tiro o vínculo e a linha desce para leadsource ---'
BEGIN;
  CREATE TEMP TABLE _alvo_prec ON COMMIT DROP AS
    SELECT v.opportunity_id, v.lead_id, v.lead_vinculo_regra, v.segmento_aba, v.lead_source,
           l.converted_opportunity_id
    FROM view_oportunidade_analitica v JOIN lead l ON l.id = v.lead_id
    WHERE v.lead_vinculo_regra = 'oportunidade' AND v.lead_source IS NOT NULL
    ORDER BY v.opportunity_id LIMIT 1;

  UPDATE lead SET converted_opportunity_id = NULL, converted_account_id = NULL
   WHERE id = (SELECT lead_id FROM _alvo_prec);

  SELECT a.lead_vinculo_regra AS regra_antes, a.segmento_aba AS segmento_antes, a.lead_source,
         v.lead_vinculo_regra AS regra_depois, v.segmento_aba AS segmento_depois,
         CASE WHEN a.lead_vinculo_regra = 'oportunidade'
                   AND v.lead_vinculo_regra IN ('leadsource','leadsource_desconhecido')
              THEN 'OK — sem o lead a linha desce para a terceira força; a ordem é real'
              ELSE 'FALHOU' END AS veredito
  FROM _alvo_prec a JOIN view_oportunidade_analitica v ON v.opportunity_id = a.opportunity_id;
ROLLBACK;

\echo '--- J6. cobertura do crosswalk, medida contra o dado que chegou ---'
SELECT count(DISTINCT lead_source)                                          AS valores_distintos,
       count(DISTINCT lead_source) FILTER (WHERE lead_vinculo_regra <> 'leadsource_desconhecido') AS conhecidos_aprox,
       (SELECT count(*) FROM view_leadsource_nao_classificado)              AS valores_pendentes,
       (SELECT sum(oportunidades) FROM view_leadsource_nao_classificado)    AS oportunidades_pendentes,
       (SELECT round(sum(receita_ganha_brl),2) FROM view_leadsource_nao_classificado) AS receita_ganha_pendente
FROM view_oportunidade_analitica WHERE lead_source IS NOT NULL;

\echo '--- J7. `Otros` e `Outros` continuam DISTINTOS, como a origem os grava ---'
SELECT lead_source, count(*) AS oportunidades, max(segmento_aba) AS segmento
FROM view_oportunidade_analitica
WHERE lead_source IN ('Otros','Outros')
GROUP BY 1 ORDER BY 1;

SELECT CASE WHEN (SELECT count(DISTINCT lead_source) FROM view_oportunidade_analitica
                   WHERE lead_source IN ('Otros','Outros')) = 2
            THEN 'OK — dois valores, duas linhas; nenhuma normalização de texto os fundiu'
            ELSE 'FALHOU — alguém unificou por lower/unaccent em algum lugar' END AS veredito;

\echo '--- J8. a ingestão não estragou nada do que já estava certo ---'
SELECT (SELECT count(*) FROM view_oportunidade_analitica)                                  AS universo,
       (SELECT count(*) FROM opportunity WHERE source_system='salesforce')                 AS na_tabela,
       (SELECT count(*) FROM opportunity WHERE source_system='salesforce' AND currency_iso_code IS NULL) AS sem_moeda,
       (SELECT count(*) FROM view_oportunidade_analitica WHERE desfecho='ganha')           AS ganhas,
       (SELECT soma_fecha FROM fn_oportunidades_cards('{}'::jsonb))                        AS soma_fecha,
       CASE WHEN (SELECT count(*) FROM view_oportunidade_analitica)
                 = (SELECT count(*) FROM opportunity WHERE source_system='salesforce')
             AND (SELECT count(*) FROM opportunity WHERE source_system='salesforce' AND currency_iso_code IS NULL) = 0
             AND (SELECT soma_fecha FROM fn_oportunidades_cards('{}'::jsonb))
            THEN 'OK' ELSE 'FALHOU' END AS veredito;

\echo '--- J9. a watermark VOLTOU do piso (o reset foi consumido, não deixado) ---'
SELECT last_run_at,
       CASE WHEN last_run_at > timestamptz '2025-09-14T00:00:00Z'
            THEN 'OK — a próxima execução do n8n volta a ser incremental'
            ELSE 'FALHOU — o piso ficou gravado e o n8n vai reler 12 meses de hora em hora' END AS veredito
FROM sync_state WHERE source='salesforce' AND object='Opportunity';

\echo '--- J10. plan_cache_mode e GRANT sobreviveram ao DROP das duas funções ---'
SELECT p.proname,
       has_function_privilege('crm_ingest', p.oid, 'EXECUTE') AS crm_ingest_executa,
       ('plan_cache_mode=force_custom_plan' = ANY(coalesce(p.proconfig, '{}'))) AS plano_custom,
       CASE WHEN has_function_privilege('crm_ingest', p.oid, 'EXECUTE')
             AND 'plan_cache_mode=force_custom_plan' = ANY(coalesce(p.proconfig, '{}'))
            THEN 'OK' ELSE 'FALHOU — DROP FUNCTION descartou GRANT e/ou o SET, e ninguém reemitiu' END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('fn_oportunidades_cards','fn_search_oportunidades',
                    'fn_oportunidades_funil','fn_oportunidades_por_segmento')
ORDER BY 1;

SELECT c.relname AS view_nova,
       has_table_privilege('crm_ingest', c.oid, 'SELECT') AS crm_ingest_le,
       CASE WHEN has_table_privilege('crm_ingest', c.oid, 'SELECT')
            THEN 'OK' ELSE 'FALHOU — DROP VIEW descartou o grant' END AS veredito
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relname IN ('view_oportunidade_analitica','view_leadsource_nao_classificado')
ORDER BY 1;

-- ═════════════════════════════════════════════════════════════════════════════
-- J11. A GUARDA DO CORPO DA INGESTÃO — E A PROVA DE QUE ELA SABE FALHAR
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `fn_run_ingest_batch` é reemitida INTEIRA por quase toda migration que toca
-- ingestão, e `CREATE OR REPLACE` não faz merge: quem roda por último vence.
-- Isso já reverteu blocos em silêncio DUAS vezes nesta epic (a 090 partindo de
-- arquivo antigo; a 100 partindo de um dump do corpo vivo com 11 minutos de
-- idade, enquanto outro agente aplicava a 101 na mesma função).
--
-- ⚠️ A CHECAGEM É POR TOKEN, E O TOKEN IMPORTA. Procurar `last_conversion` para
-- saber se o bloco do webhook do RD está presente dá FALSO POSITIVO: ele
-- aparece 9 vezes já na base da 073, SEM o bloco (com ele, 42). O token que
-- DECIDE é `custom_fields` — zero sem, 14 com. Foi `custom_fields = 0` que
-- denunciou a segunda reversão.
--
-- Quem acrescentar um bloco novo à função TEM de acrescentar o token dele
-- aqui: esta guarda só protege o que ela conta.
--
-- ⚠️ Rode este arquivo A PARTIR DA RAIZ DO REPO: o teste negativo extrai o
-- corpo da 101 do arquivo real, por caminho relativo.

\echo '--- J11a. estado real: os CINCO blocos coexistem no corpo vivo ---'
WITH corpo AS (SELECT pg_get_functiondef('public.fn_run_ingest_batch'::regproc) AS d),
tokens(quem, token, esperado) AS (
  VALUES ('090 — moeda e taxa',       'CurrencyType',      6),
         ('092 — IsWon/IsClosed',     'OpportunityStage',  5),
         ('099 — identificador RD',   'identificador_rd',  5),
         ('100 — origem da opp',      'LeadSource',        3),
         ('101 — webhook do RD',      'custom_fields',    14)
)
SELECT t.quem, t.token, t.esperado,
       (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) AS encontrado,
       CASE WHEN (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) = t.esperado
            THEN 'OK'
            ELSE 'FALHOU — alguém reemitiu a função a partir de um corpo antigo e apagou este bloco' END AS veredito
FROM corpo c, tokens t
ORDER BY t.quem;

\echo '--- J11b. TESTE NEGATIVO: aplico o corpo da 101 por cima ---'
\echo '---       É LITERALMENTE o que um rebuild do zero faria: 101 > 100 na'
\echo '---       ordem lexical, e o arquivo da 101 não tem o bloco de lead_source.'
\echo '---       Extraído do arquivo REAL, para o teste não envelhecer em cópia.'
\! sed -n '/^CREATE OR REPLACE FUNCTION public\.fn_run_ingest_batch/,/^\$function\$;$/p' db/migrations/101_repoe_enriquecimento_do_webhook_rd.sql > /tmp/_verif_corpo_101.sql
\! test -s /tmp/_verif_corpo_101.sql && echo "corpo da 101 extraido: $(wc -l < /tmp/_verif_corpo_101.sql) linhas" || echo "FALHOU — extracao vazia; rode a partir da raiz do repo"

BEGIN;
  \i /tmp/_verif_corpo_101.sql

  WITH corpo AS (SELECT pg_get_functiondef('public.fn_run_ingest_batch'::regproc) AS d),
  tokens(quem, token, esperado) AS (
    VALUES ('090 — moeda e taxa',       'CurrencyType',      6),
           ('092 — IsWon/IsClosed',     'OpportunityStage',  5),
           ('099 — identificador RD',   'identificador_rd',  5),
           ('100 — origem da opp',      'LeadSource',        3),
           ('101 — webhook do RD',      'custom_fields',    14)
  )
  SELECT t.quem, t.token, t.esperado,
         (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) AS encontrado,
         CASE
           WHEN t.token = 'LeadSource'
            AND (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) <> t.esperado
             THEN 'OK — a guarda ACUSOU o bloco da 100 sumindo; ela sabe falhar'
           WHEN (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) = t.esperado
             THEN 'esperado — este bloco a 101 preserva'
           ELSE 'inesperado'
         END AS veredito
  FROM corpo c, tokens t
  ORDER BY t.quem;
ROLLBACK;

\echo '--- J11c. depois do ROLLBACK a guarda volta ao verde ---'
\echo '---       (sem esta terceira leitura, o teste negativo poderia ter deixado'
\echo '---        a produção quebrada e ninguém saberia)'
WITH corpo AS (SELECT pg_get_functiondef('public.fn_run_ingest_batch'::regproc) AS d),
tokens(quem, token, esperado) AS (
  VALUES ('090 — moeda e taxa',       'CurrencyType',      6),
         ('092 — IsWon/IsClosed',     'OpportunityStage',  5),
         ('099 — identificador RD',   'identificador_rd',  5),
         ('100 — origem da opp',      'LeadSource',        3),
         ('101 — webhook do RD',      'custom_fields',    14)
)
SELECT t.quem, t.token, t.esperado,
       (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) AS encontrado,
       CASE WHEN (length(c.d) - length(replace(c.d, t.token, ''))) / length(t.token) = t.esperado
            THEN 'OK' ELSE 'FALHOU — o rollback não desfez, e a produção está quebrada AGORA' END AS veredito
FROM corpo c, tokens t
ORDER BY t.quem;

\! rm -f /tmp/_verif_corpo_101.sql

\echo '--- J12. a 102 é a dona do corpo: maior número lexical que toca a função ---'
\! echo "arquivos que reemitem fn_run_ingest_batch:"; grep -l "CREATE OR REPLACE FUNCTION public.fn_run_ingest_batch" db/migrations/*.sql | sort | sed 's/^/  /'
\! echo "o ultimo deles TEM de ser a 102:"; test "$(grep -l 'CREATE OR REPLACE FUNCTION public.fn_run_ingest_batch' db/migrations/*.sql | sort | tail -1)" = "db/migrations/102_corpo_final_da_ingestao.sql" && echo "  OK -- 102 roda por ultimo num rebuild" || echo "  FALHOU -- outra migration roda depois da 102 e vai sobrescrever o corpo"
