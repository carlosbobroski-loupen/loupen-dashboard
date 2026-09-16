-- db/queries/verificacao/leads-e-categoria-na-aba.sql
--
-- VERIFICAÇÃO DAS MIGRATIONS 103 E 104.
--
-- REGRA DESTE ÉPICO: uma asserção só vale depois de eu PROVAR QUE ELA CONSEGUE
-- FALHAR. Já houve SETE "verdes" vazios aqui. O último foi um `||` cujo segundo
-- operando era sempre verdadeiro — a expressão inteira nunca podia ser falsa, e
-- ninguém percebeu porque ela imprimia 'OK'.
--
-- Por isso cada bloco abaixo tem duas metades: o estado REAL, e ao lado a MESMA
-- checagem escrita de forma incompleta (ou o mesmo banco num estado quebrado de
-- propósito, dentro de transação revertida) mostrando a diferença. Um bloco que
-- só imprime 'OK' não está verificando nada.
--
-- Rodar inteiro:
--   psql "$NEON_DATABASE_URL" -f db/queries/verificacao/leads-e-categoria-na-aba.sql
--
-- Nenhum bloco deixa efeito: todos os que escrevem terminam em ROLLBACK.
--
-- ⚠️ ESTE ARQUIVO COMPARA CONTRA CONSTANTES MEDIDAS EM 2026-09-16, logo após a
-- migration 103: 7.054 leads e 5.407 oportunidades na janela de 12 meses, 12
-- leads `Evento`, 792 oportunidades sem categoria. Elas são a FOTO do dia e vão
-- envelhecer — inclusive porque a janela é relativa a `now()`: rodar amanhã já
-- devolve outro total de leads, sem que nada tenha quebrado. Quando um número
-- fixo envelhecer o teste acusa 'FALHOU', e o certo é ATUALIZAR A CONSTANTE
-- depois de conferir POR QUE mudou —
-- nunca apagar o teste, e nunca reescrevê-lo comparando a função consigo mesma.
-- Comparação auto-referente é sempre verde; é isso que este arquivo existe para
-- não repetir.

\set ON_ERROR_STOP on
\pset pager off

-- ═════════════════════════════════════════════════════════════════════════════
-- A. AS CONTAGENS DE LEAD BATEM COM A QUERY DIRETA — E A CHECAGEM TEM DENTES
-- ═════════════════════════════════════════════════════════════════════════════
-- A função soma leads de `lead` + `lead_origin_classification` com DOIS
-- predicados que é fácil esquecer: `valid_to IS NULL` (só a versão vigente) e
-- `NOT is_teste`. Esquecer o primeiro conta cada lead uma vez por versão;
-- esquecer o segundo mistura fixtures com dado real. A1 compara com a query
-- CERTA; A2 e A3 mostram o tamanho do estrago de cada esquecimento, provando
-- que a comparação de A1 é sensível aos dois.

\echo '--- A1. por_segmento x query direta, janela de 12 meses: zero linhas = invariante vale ---'
WITH da_funcao AS (
  SELECT segmento_aba AS seg, qtd_leads_gerados, qtd_leads_com_oportunidade
  FROM fn_oportunidades_por_segmento(jsonb_build_object('de', (now() - interval '12 months')::text))
),
direta AS (
  SELECT c.segmento AS seg,
         count(*)                                                                   AS leads,
         count(*) FILTER (WHERE l.converted_opportunity_id IS NOT NULL
                             OR l.converted_account_id     IS NOT NULL)             AS com_opp
  FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE NOT l.is_teste
    AND l.created_at_source >= now() - interval '12 months'
  GROUP BY c.segmento
)
SELECT coalesce(f.seg, d.seg)                       AS segmento,
       f.qtd_leads_gerados                          AS funcao_leads,
       d.leads                                      AS direta_leads,
       f.qtd_leads_com_oportunidade                 AS funcao_com_opp,
       d.com_opp                                    AS direta_com_opp,
       'FALHOU — a funcao e a query direta discordam' AS veredito
FROM da_funcao f
FULL OUTER JOIN direta d ON d.seg = f.seg
-- `SemOrigem`/`NaoClassificado` só existem do lado da oportunidade: a função
-- devolve 0 leads e a query direta não devolve linha. Isso NÃO é divergência.
WHERE NOT (coalesce(f.qtd_leads_gerados, 0)          = coalesce(d.leads, 0)
       AND coalesce(f.qtd_leads_com_oportunidade, 0) = coalesce(d.com_opp, 0));

\echo '--- A2. TESTE NEGATIVO (sem escrever no banco): a MESMA comparação, com a'
\echo '---     query direta escrita SEM `valid_to IS NULL`. Tem de acusar.'
\echo '---     Os 12 leads reclassificados pela 103 passaram a ter 2 versões cada;'
\echo '---     sem o predicado o join conta 8.765 linhas onde há 7.054 leads.'
WITH da_funcao AS (
  SELECT sum(qtd_leads_gerados) AS leads
  FROM fn_oportunidades_por_segmento(jsonb_build_object('de', (now() - interval '12 months')::text))
),
direta_certa AS (
  SELECT count(*) AS leads FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE NOT l.is_teste AND l.created_at_source >= now() - interval '12 months'
),
direta_sem_valid_to AS (
  SELECT count(*) AS leads FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id
  WHERE NOT l.is_teste AND l.created_at_source >= now() - interval '12 months'
)
SELECT f.leads AS funcao, c.leads AS direta_certa, s.leads AS direta_sem_valid_to,
       s.leads - c.leads AS linhas_a_mais_do_esquecimento,
       CASE WHEN f.leads = c.leads AND f.leads <> s.leads
            THEN 'OK — a comparação distingue os dois casos, logo ela vale'
            ELSE 'FALHOU — a comparação não é sensível a valid_to, logo não verifica nada' END AS veredito
FROM da_funcao f, direta_certa c, direta_sem_valid_to s;

\echo '--- A3. TESTE NEGATIVO: a mesma comparação, sem `NOT is_teste`. Tem de acusar. ---'
WITH da_funcao AS (
  SELECT sum(qtd_leads_gerados) AS leads
  FROM fn_oportunidades_por_segmento(jsonb_build_object('de', (now() - interval '12 months')::text))
),
direta_certa AS (
  SELECT count(*) AS leads FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE NOT l.is_teste AND l.created_at_source >= now() - interval '12 months'
),
direta_com_teste AS (
  SELECT count(*) AS leads FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE l.created_at_source >= now() - interval '12 months'
)
SELECT f.leads AS funcao, c.leads AS direta_certa, t.leads AS direta_com_fixtures,
       t.leads - c.leads AS fixtures_que_entrariam,
       CASE WHEN f.leads = c.leads AND f.leads <> t.leads
            THEN 'OK — a comparação distingue os dois casos'
            ELSE 'FALHOU — a comparação não vê is_teste' END AS veredito
FROM da_funcao f, direta_certa c, direta_com_teste t;

\echo '--- A4. TESTE NEGATIVO COM ESCRITA (revertido): marco 20 leads de Marketing'
\echo '---     da janela como is_teste. A função TEM de encolher exatamente 20.'
BEGIN;
  CREATE TEMP TABLE _antes_a4 ON COMMIT DROP AS
    SELECT qtd_leads_gerados AS n
    FROM fn_oportunidades_por_segmento(jsonb_build_object('de', (now() - interval '12 months')::text))
    WHERE segmento_aba = 'Marketing';

  UPDATE lead SET is_teste = true WHERE id IN (
    SELECT l.id FROM lead l
    JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
    WHERE NOT l.is_teste AND c.segmento = 'Marketing'
      AND l.created_at_source >= now() - interval '12 months'
    ORDER BY l.id LIMIT 20
  );

  SELECT a.n AS marketing_antes,
         f.qtd_leads_gerados AS marketing_depois,
         a.n - f.qtd_leads_gerados AS diferenca,
         CASE WHEN a.n - f.qtd_leads_gerados = 20
              THEN 'OK — a contagem reagiu ao estado forçado, na medida exata'
              ELSE 'FALHOU — a contagem não reage a is_teste, ou reage errado' END AS veredito
  FROM _antes_a4 a,
       fn_oportunidades_por_segmento(jsonb_build_object('de', (now() - interval '12 months')::text)) f
  WHERE f.segmento_aba = 'Marketing';
ROLLBACK;

\echo '--- A5. as duas funções concordam sobre o total de leads do mesmo recorte ---'
\echo '---     (por_segmento agrupa por segmento, por_categoria por par;'
\echo '---      se o total divergir, uma das duas está filtrando escondido)'
SELECT (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_segmento(jsonb_build_object('de',(now()-interval '12 months')::text))) AS por_segmento,
       (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_categoria(jsonb_build_object('de',(now()-interval '12 months')::text))) AS por_categoria,
       CASE WHEN (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_segmento(jsonb_build_object('de',(now()-interval '12 months')::text)))
               = (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_categoria(jsonb_build_object('de',(now()-interval '12 months')::text)))
            THEN 'OK' ELSE 'FALHOU' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. A PARTIÇÃO DO VÍNCULO FECHA — E DUAS CONTAGENS NÃO BASTARIAM
-- ═════════════════════════════════════════════════════════════════════════════
-- O pedido original era "rastreadas + só_por_leadsource = o total do segmento".
-- Não fecha: `lead_vinculo_regra` tem seis valores, não quatro. Na janela de 12
-- meses fecharia por acidente (sem_origem = 0 lá); na base inteira não fecha.
-- B2 é a prova de que a versão de dois baldes seria um verde vazio.

\echo '--- B1. base INTEIRA: as 4 contagens somam o total do segmento, linha a linha ---'
SELECT segmento_aba, qtd_oportunidades,
       qtd_opps_rastreadas_ate_lead, qtd_opps_so_por_leadsource,
       qtd_opps_lead_sem_classificacao, qtd_opps_sem_origem,
       soma_vinculo_fecha,
       CASE WHEN soma_vinculo_fecha THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_por_segmento('{}'::jsonb)
ORDER BY qtd_oportunidades DESC;

\echo '--- B2. TESTE NEGATIVO (dado real, sem escrita): a checagem de DOIS baldes'
\echo '---     — a que o pedido descrevia — perde as linhas de SemOrigem.'
SELECT segmento_aba, qtd_oportunidades,
       (qtd_opps_rastreadas_ate_lead + qtd_opps_so_por_leadsource) AS soma_2_baldes,
       qtd_oportunidades - (qtd_opps_rastreadas_ate_lead + qtd_opps_so_por_leadsource) AS linhas_perdidas,
       soma_vinculo_fecha AS soma_4_baldes_fecha,
       CASE WHEN soma_vinculo_fecha
             AND (qtd_opps_rastreadas_ate_lead + qtd_opps_so_por_leadsource) <> qtd_oportunidades
            THEN 'OK — aqui a checagem de 2 baldes falharia e a de 4 não'
            ELSE 'sem divergência nesta linha' END AS veredito
FROM fn_oportunidades_por_segmento('{}'::jsonb)
WHERE qtd_opps_sem_origem > 0 OR qtd_opps_lead_sem_classificacao > 0;

\echo '--- B3. TESTE NEGATIVO COM ESCRITA (revertido): apago o LeadSource de 40'
\echo '---     oportunidades. Elas viram `sem_origem`; a soma de 4 baldes TEM de'
\echo '---     continuar fechando e a de 2 TEM de quebrar em pelo menos 40.'
BEGIN;
  UPDATE opportunity SET lead_source = NULL
   WHERE id IN (SELECT id FROM opportunity
                 WHERE source_system = 'salesforce' AND lead_source IS NOT NULL
                 ORDER BY id LIMIT 40);

  SELECT
    bool_and(soma_vinculo_fecha)                                         AS todas_as_linhas_fecham_com_4,
    sum(qtd_opps_sem_origem)                                             AS agora_sem_origem,
    sum(qtd_oportunidades - qtd_opps_rastreadas_ate_lead - qtd_opps_so_por_leadsource) AS perda_da_checagem_de_2,
    CASE WHEN bool_and(soma_vinculo_fecha)
              AND sum(qtd_oportunidades - qtd_opps_rastreadas_ate_lead - qtd_opps_so_por_leadsource) >= 40
         THEN 'OK — a de 4 aguentou o estado forçado, a de 2 não'
         ELSE 'FALHOU' END AS veredito
  FROM fn_oportunidades_por_segmento('{}'::jsonb);
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. A SOMA DAS CATEGORIAS FECHA — INCLUINDO A LINHA DE CATEGORIA AUSENTE
-- ═════════════════════════════════════════════════════════════════════════════
-- Foi somar o desconhecido a um balde existente que produziu o "100% atribuído
-- a marketing" da aba antiga. Aqui a linha sem categoria é linha, e C2 mostra
-- exatamente quanto some da soma quando ela é ignorada.

\echo '--- C1. janela de 12 meses: soma das categorias = total do recorte ---'
SELECT sum(qtd_oportunidades)                                  AS soma_das_categorias,
       max(total_do_recorte)                                   AS total_do_recorte,
       count(*) FILTER (WHERE categoria IS NULL)               AS linhas_sem_categoria,
       sum(qtd_leads_gerados)                                  AS soma_dos_leads,
       max(total_leads_do_recorte)                             AS total_leads,
       CASE WHEN sum(qtd_oportunidades) = max(total_do_recorte)
             AND sum(qtd_leads_gerados) = max(total_leads_do_recorte)
             AND count(*) FILTER (WHERE categoria IS NULL) >= 1
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_por_categoria(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- C2. TESTE NEGATIVO: a mesma soma IGNORANDO a linha de categoria ausente ---'
SELECT sum(qtd_oportunidades)                                            AS soma_completa,
       sum(qtd_oportunidades) FILTER (WHERE categoria IS NOT NULL)       AS soma_sem_a_linha_nula,
       max(total_do_recorte)                                             AS total,
       sum(qtd_oportunidades) FILTER (WHERE categoria IS NULL)           AS oportunidades_que_sumiriam,
       CASE WHEN sum(qtd_oportunidades) = max(total_do_recorte)
             AND sum(qtd_oportunidades) FILTER (WHERE categoria IS NOT NULL) <> max(total_do_recorte)
            THEN 'OK — a checagem distingue somar e não somar a linha nula'
            ELSE 'FALHOU — ou não há linha nula, ou a checagem não a enxerga' END AS veredito
FROM fn_oportunidades_por_categoria(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- C3. TESTE NEGATIVO COM ESCRITA (revertido): troco o LeadSource de 60'
\echo '---     oportunidades por um valor que o crosswalk não conhece. Elas caem'
\echo '---     na linha SEM CATEGORIA, e a soma TEM de continuar fechando.'
BEGIN;
  UPDATE opportunity SET lead_source = 'Valor Inexistente 103'
   WHERE id IN (SELECT o.id FROM opportunity o
                 JOIN leadsource_crosswalk x ON x.valor_bruto = o.lead_source
                WHERE o.source_system = 'salesforce'
                  AND NOT EXISTS (SELECT 1 FROM lead l WHERE l.converted_opportunity_id = o.source_id)
                ORDER BY o.id LIMIT 60);

  SELECT sum(qtd_oportunidades)                             AS soma,
         max(total_do_recorte)                              AS total,
         sum(qtd_oportunidades) FILTER (WHERE categoria IS NULL) AS na_linha_sem_categoria,
         CASE WHEN sum(qtd_oportunidades) = max(total_do_recorte)
              THEN 'OK — a soma aguentou 60 linhas mudando de balde'
              ELSE 'FALHOU — a partição vazou' END AS veredito
  FROM fn_oportunidades_por_categoria('{}'::jsonb);
ROLLBACK;

\echo '--- C4. grão: nenhum par (segmento_aba, categoria) aparece duas vezes ---'
SELECT count(*) AS linhas, count(DISTINCT (segmento_aba, categoria)) AS pares_distintos,
       CASE WHEN count(*) = count(DISTINCT (segmento_aba, categoria))
            THEN 'OK' ELSE 'FALHOU — o FULL OUTER duplicou a linha de categoria nula' END AS veredito
FROM fn_oportunidades_por_categoria('{}'::jsonb);

-- ═════════════════════════════════════════════════════════════════════════════
-- D. A LIMPEZA DO `Evento`: ANTES, DEPOIS, E A PROVA DE QUE A REGRA AGIU
-- ═════════════════════════════════════════════════════════════════════════════
-- A migration 076 existe porque `fn_reclassificar_lead` só versionava quando o
-- `valor_bruto` mudava — regra nova com sinal bruto inalterado passava em
-- branco. Este é exatamente esse caso, então não basta ver o "depois": é
-- preciso ver as DUAS versões e o motivo dizendo que foi a REGRA que mudou.

\echo '--- D1. o antes e o depois, lead a lead, no histórico versionado ---'
SELECT l.id AS lead_id,
       c.version,
       c.valid_to IS NULL          AS vigente,
       c.segmento, c.categoria, c.sinal_id,
       c.classified_by,
       left(c.reclass_reason, 120) AS motivo
FROM lead l
JOIN lead_origin_classification c ON c.lead_id = l.id
WHERE l.origem_bruta = 'Evento'
ORDER BY l.id, c.version;

\echo '--- D2. o resumo: 12 leads, todos vigentes em Marketing/Evento/Webinar,'
\echo '---     todos com versão anterior preservada em NaoAtribuido ---'
SELECT count(*) FILTER (WHERE c.valid_to IS NULL AND c.segmento = 'Marketing'
                          AND c.categoria = 'Evento/Webinar')             AS vigentes_em_evento,
       count(*) FILTER (WHERE c.valid_to IS NOT NULL
                          AND c.segmento = 'NaoAtribuido')                AS versoes_anteriores_preservadas,
       count(*) FILTER (WHERE c.valid_to IS NULL AND c.segmento = 'NaoAtribuido') AS sobrou_em_naoatribuido,
       count(*) FILTER (WHERE c.reclass_reason LIKE '%a REGRA mudou%')    AS reclassificados_por_mudanca_de_regra,
       CASE WHEN count(*) FILTER (WHERE c.valid_to IS NULL AND c.segmento='Marketing' AND c.categoria='Evento/Webinar') = 12
             AND count(*) FILTER (WHERE c.valid_to IS NOT NULL AND c.segmento='NaoAtribuido') = 12
             AND count(*) FILTER (WHERE c.valid_to IS NULL AND c.segmento='NaoAtribuido') = 0
             AND count(*) FILTER (WHERE c.reclass_reason LIKE '%a REGRA mudou%') = 12
            THEN 'OK — reclassificação rodou, versionou, e o motivo é mudança de regra'
            ELSE 'FALHOU' END AS veredito
FROM lead l
JOIN lead_origin_classification c ON c.lead_id = l.id
WHERE l.origem_bruta = 'Evento';

\echo '--- D3. TESTE NEGATIVO COM ESCRITA (revertido): tiro a regra `Evento` do'
\echo '---     crosswalk e reclassifico. Os 12 TÊM de voltar para NaoAtribuido.'
\echo '---     Se não voltarem, a classificação não vem do crosswalk e D2 é vazio.'
BEGIN;
  DELETE FROM leadsource_crosswalk WHERE valor_bruto = 'Evento';
  SELECT count(*) FILTER (WHERE fn_reclassificar_lead(id)) AS versionou_de_volta
  FROM lead WHERE origem_bruta = 'Evento';

  SELECT count(*) FILTER (WHERE c.segmento = 'NaoAtribuido')                       AS voltaram,
         count(*) FILTER (WHERE c.segmento = 'Marketing')                          AS ficaram,
         CASE WHEN count(*) FILTER (WHERE c.segmento = 'NaoAtribuido') = 12
              THEN 'OK — a regra do crosswalk É o que classifica; D2 não é verde vazio'
              ELSE 'FALHOU — tirar a regra não mudou nada, logo D2 não prova nada' END AS veredito
  FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE l.origem_bruta = 'Evento';
ROLLBACK;

\echo '--- D4. o efeito no lado da OPORTUNIDADE (o crosswalk serve aos dois) ---'
SELECT segmento_aba, categoria, lead_vinculo_regra, count(*) AS opps,
       count(*) FILTER (WHERE criada_em >= now() - interval '12 months') AS na_janela
FROM view_oportunidade_analitica
WHERE lead_source = 'Evento'
   OR lead_id IN (SELECT id FROM lead WHERE origem_bruta = 'Evento')
GROUP BY 1,2,3 ORDER BY 4 DESC;

\echo '--- D5. o que NÃO foi mexido, e continua onde estava (por decisão) ---'
SELECT c.segmento, c.categoria, c.valor_bruto, count(*) AS leads
FROM lead_origin_classification c
WHERE c.valid_to IS NULL
  AND (c.valor_bruto = 'Outbound ERP Summit'
    OR (c.segmento = 'NaoAtribuido' AND c.categoria = 'Outro (requer nota)'))
GROUP BY 1,2,3
ORDER BY 4 DESC;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. OS DOIS LADOS NÃO SE FUNDEM: NENHUMA TAXA LEAD→OPORTUNIDADE FOI CRIADA
-- ═════════════════════════════════════════════════════════════════════════════
-- Esta é uma checagem ESTRUTURAL, não numérica. Ela existe porque a decisão de
-- não entregar a taxa é fácil de reverter por engano seis meses depois — basta
-- alguém achar a divisão "óbvia". O motivo está no cabeçalho da migration 103:
-- 94,2% dos leads de Marketing nunca viraram oportunidade e 48,7% das
-- oportunidades de Marketing nunca tiveram lead.

\echo '--- E1. nenhuma coluna de saída das duas funções é taxa/conversão lead→opp ---'
SELECT p.proname,
       count(*) FILTER (WHERE a.nome ~* '(taxa|conversao|conversão).*lead|lead.*(taxa|conversao|conversão)') AS colunas_suspeitas,
       CASE WHEN count(*) FILTER (WHERE a.nome ~* '(taxa|conversao|conversão).*lead|lead.*(taxa|conversao|conversão)') = 0
            THEN 'OK' ELSE 'FALHOU — alguém recriou a divisão de dois baldes que não se rastreiam' END AS veredito
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL unnest(p.proargnames) AS a(nome)
WHERE n.nspname = 'public'
  AND p.proname IN ('fn_oportunidades_por_segmento','fn_oportunidades_por_categoria')
GROUP BY p.proname;

\echo '--- E2. TESTE NEGATIVO: a mesma regex encontra o nome proibido quando ele existe ---'
SELECT 'taxa_conversao_lead_oportunidade' ~* '(taxa|conversao|conversão).*lead|lead.*(taxa|conversao|conversão)' AS acha_o_proibido,
       'qtd_leads_gerados'                ~* '(taxa|conversao|conversão).*lead|lead.*(taxa|conversao|conversão)' AS acha_o_permitido,
       CASE WHEN 'taxa_conversao_lead_oportunidade' ~* '(taxa|conversao|conversão).*lead|lead.*(taxa|conversao|conversão)'
             AND NOT ('qtd_leads_gerados' ~* '(taxa|conversao|conversão).*lead|lead.*(taxa|conversao|conversão)')
            THEN 'OK — a regex de E1 discrimina, logo E1 não é sempre verde'
            ELSE 'FALHOU — a regex de E1 não vale nada' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. OS FILTROS QUE NÃO VALEM PARA O LEAD SÃO DECLARADOS, NÃO IGNORADOS
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- F1. sem filtro divergente, leads_filtros_ignorados é NULL ---'
SELECT DISTINCT leads_filtros_ignorados IS NULL AS silencioso,
       CASE WHEN leads_filtros_ignorados IS NULL THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_por_segmento(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- F2. com filtros de oportunidade, ele NOMEIA cada um deles ---'
SELECT DISTINCT leads_filtros_ignorados,
       CASE WHEN leads_filtros_ignorados = 'fase, desfecho, record_type, moeda, lead_source'
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_por_segmento('{"fase":["proposta"],"desfecho":["ganha"],"record_type":["Novo"],"moeda":["BRL"],"lead_source":["Webinar"]}'::jsonb);

\echo '--- F3. TESTE NEGATIVO: array vazio e null NÃO contam como filtro pedido'
\echo '---     (têm de concordar com fn_filtro_casa, que os trata como sem restrição) ---'
SELECT DISTINCT leads_filtros_ignorados,
       CASE WHEN leads_filtros_ignorados IS NULL
            THEN 'OK — array vazio e null não geram aviso falso'
            ELSE 'FALHOU — fn_filtro_ativo e fn_filtro_casa discordam' END AS veredito
FROM fn_oportunidades_por_segmento('{"fase":[],"desfecho":null,"moeda":[]}'::jsonb);

\echo '--- F4. em por_categoria, `segmento` e `categoria` NÃO entram nos ignorados'
\echo '---     (eles existem dos dois lados e são de fato aplicados ao lead) ---'
SELECT DISTINCT leads_filtros_ignorados,
       max(qtd_leads_gerados) OVER () AS maior_contagem_de_lead,
       CASE WHEN leads_filtros_ignorados IS NULL THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_oportunidades_por_categoria('{"segmento":["Marketing"],"categoria":["Evento/Webinar"]}'::jsonb);

\echo '--- F5. TESTE NEGATIVO do F4: filtrar por Marketing TEM de reduzir a'
\echo '---     contagem de leads; se não reduzir, o filtro não chegou no lead ---'
SELECT (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_categoria('{}'::jsonb))                        AS leads_sem_filtro,
       (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_categoria('{"segmento":["Marketing"]}'::jsonb)) AS leads_so_marketing,
       CASE WHEN (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_categoria('{"segmento":["Marketing"]}'::jsonb))
                 < (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_categoria('{}'::jsonb))
            THEN 'OK — o filtro de segmento alcança o lado do lead'
            ELSE 'FALHOU — o filtro não está sendo aplicado ao lead' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. MIGRATION 104: O FILTRO DE CATEGORIA NA LISTA
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- G1. o filtro seleciona, e total_filtrado concorda com a agregação ---'
WITH lista AS (
  SELECT max(total_filtrado) AS total, count(*) AS linhas, count(DISTINCT categoria) AS cats
  FROM fn_search_oportunidades(
    jsonb_build_object('de', (now() - interval '12 months')::text,
                       'categoria', jsonb_build_array('Evento/Webinar')), 500, 0)
),
agregada AS (
  SELECT sum(qtd_oportunidades) AS total
  FROM fn_oportunidades_por_categoria(jsonb_build_object('de', (now() - interval '12 months')::text))
  WHERE categoria = 'Evento/Webinar'
)
SELECT l.total AS total_filtrado_da_lista, a.total AS total_da_agregacao,
       l.linhas, l.cats AS categorias_distintas_na_pagina,
       CASE WHEN l.total = a.total AND l.cats = 1
            THEN 'OK — a lista e o card contam o mesmo conjunto'
            ELSE 'FALHOU — a lista de detalhe não bate com o número do card' END AS veredito
FROM lista l, agregada a;

\echo '--- G2. TESTE NEGATIVO: sem o filtro, o total TEM de ser muito maior ---'
SELECT (SELECT max(total_filtrado) FROM fn_search_oportunidades(jsonb_build_object('de',(now()-interval '12 months')::text), 1, 0)) AS sem_filtro,
       (SELECT max(total_filtrado) FROM fn_search_oportunidades(jsonb_build_object('de',(now()-interval '12 months')::text,'categoria',jsonb_build_array('Evento/Webinar')), 1, 0)) AS com_filtro,
       CASE WHEN (SELECT max(total_filtrado) FROM fn_search_oportunidades(jsonb_build_object('de',(now()-interval '12 months')::text,'categoria',jsonb_build_array('Evento/Webinar')), 1, 0))
                 < (SELECT max(total_filtrado) FROM fn_search_oportunidades(jsonb_build_object('de',(now()-interval '12 months')::text), 1, 0))
            THEN 'OK — o filtro filtra de verdade'
            ELSE 'FALHOU — o parâmetro está sendo ignorado' END AS veredito;

\echo '--- G3. categoria inexistente devolve VAZIO, nunca a base inteira ---'
SELECT coalesce(max(total_filtrado), 0) AS total, count(*) AS linhas,
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FALHOU — filtro desconhecido caiu em "sem restrição"' END AS veredito
FROM fn_search_oportunidades('{"categoria":["Categoria Que Nao Existe"]}'::jsonb, 50, 0);

-- ═════════════════════════════════════════════════════════════════════════════
-- H. PERMISSÃO E PLANO — CONFERIDOS PELO CATÁLOGO, NÃO POR EXECUÇÃO
-- ═════════════════════════════════════════════════════════════════════════════
-- 🔴 ARMADILHA MEDIDA EM 2026-09-16, e a razão de este bloco ter sido
-- REESCRITO antes de ser entregue: `has_function_privilege('crm_ingest', ...,
-- 'EXECUTE')` devolve TRUE PARA QUALQUER FUNÇÃO deste banco, tenha GRANT ou
-- não — porque no PostgreSQL toda função nasce com `EXECUTE` para `PUBLIC`.
-- Uma checagem escrita com ela seria o oitavo verde vazio desta epic: passaria
-- igual se o GRANT tivesse sido esquecido. A prova real é `proacl` conter a
-- entrada nominal `crm_ingest=X`. H3 demonstra a armadilha em vez de descrevê-la.

\echo '--- H1. o GRANT NOMINAL existe no ACL (não é o PUBLIC default) + plan_cache_mode ---'
SELECT p.proname,
       (p.proacl::text[] && ARRAY['crm_ingest=X/neondb_owner'])   AS grant_nominal_no_acl,
       p.proconfig,
       CASE
         -- fn_filtro_ativo é SQL IMMUTABLE sem filtro opcional: não há plano a
         -- degradar, e uma cláusula SET IMPEDIRIA o inlining da função no
         -- predicado. Mesma decisão de fn_filtro_casa (097), que também não tem.
         WHEN p.proname = 'fn_filtro_ativo'
           THEN CASE WHEN (p.proacl::text[] && ARRAY['crm_ingest=X/neondb_owner']) AND p.proconfig IS NULL
                     THEN 'OK (sem SET de propósito — inlining)'
                     ELSE 'FALHOU' END
         WHEN (p.proacl::text[] && ARRAY['crm_ingest=X/neondb_owner'])
          AND 'plan_cache_mode=force_custom_plan' = ANY (coalesce(p.proconfig, ARRAY[]::text[]))
           THEN 'OK'
         ELSE 'FALHOU — sem GRANT nominal, ou o DROP/REPLACE comeu o plan_cache_mode'
       END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('fn_oportunidades_cards','fn_oportunidades_funil',
                    'fn_oportunidades_por_segmento','fn_oportunidades_por_categoria',
                    'fn_search_oportunidades','fn_filtro_ativo')
ORDER BY p.proname;

\echo '--- H1b. TESTE NEGATIVO: has_function_privilege NÃO distingue. As funções'
\echo '---     abaixo NÃO têm GRANT nominal nenhum (proacl nulo) e mesmo assim ela'
\echo '---     diz "pode". É por isso que H1 lê proacl e não ela. ---'
SELECT p.proname,
       p.proacl IS NULL                                        AS acl_vazio_sem_grant_nenhum,
       has_function_privilege('crm_ingest', p.oid, 'EXECUTE')  AS has_function_privilege_diz,
       CASE WHEN p.proacl IS NULL AND has_function_privilege('crm_ingest', p.oid, 'EXECUTE')
            THEN 'OK — a armadilha está demonstrada: H1 não pode usar esta função'
            ELSE 'FALHOU — a premissa de H1 mudou; reavaliar o bloco inteiro' END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('fn_filtro_casa','fn_classify_origin')
ORDER BY p.proname;

\echo '--- H2. as migrations 103 e 104 estão no ledger com checksum ---'
SELECT name, left(checksum, 16) AS checksum_16, applied_at,
       CASE WHEN checksum IS NOT NULL AND length(checksum) = 64 THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM schema_migrations WHERE name ~ '^10[34]_' ORDER BY name;
