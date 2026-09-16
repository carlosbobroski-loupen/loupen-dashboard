-- db/migrations/106_a_ressalva_de_rejeitado_citava_evidencia_que_nao_discrimina.sql
--
-- A RESSALVA DE `Rejeitado` NA 105 ESTAVA CERTA NA CONCLUSÃO E ERRADA NA PROVA.
--
-- A migration 105 marcou `Rejeitado` como "em boa parte automação, não
-- julgamento comercial" e sustentou isso com dois números:
--
--   (a) "a taxa de rejeição por semana de criação vai de 0,0% a 93,5%"
--   (b) "90,9% dos rejeitados foram criados antes de 2026-08-17"
--
-- O teste negativo do próprio arquivo de verificação derrubou os dois, horas
-- depois de aplicar a 105. Medido em 2026-09-16, leads Salesforce não-teste,
-- janela de 12 meses, semanas de criação com 30+ leads:
--
--   amplitude semanal da participação de cada status
--   ------------------------------------------------
--   Aberto ............ 94,6 pontos   ← MAIOR que Rejeitado
--   Rejeitado ......... 93,5 pontos
--   Descalificado ..... 78,2 pontos
--   Qualificado ....... 60,0 pontos
--
-- TODO status oscila assim, porque a coorte semanal desta base é dominada por
-- importações em lote: uma semana com 593 leads de uma lista e outra com 39
-- orgânicos não são amostras comparáveis de nada. O número (a) não distingue
-- `Rejeitado` de `Aberto` — logo não é evidência de automação, é evidência de
-- que a base entra em lote.
--
-- E o número (b) quase não discrimina: a TAXA BASE é 82,2% — de TODOS os 6.531
-- leads Salesforce da janela, 5.369 foram criados antes de 2026-08-17. Os 90,9%
-- de `Rejeitado` são um lift de **1,11×** sobre a base. Citar 90,9% sem citar
-- 82,2% ao lado transforma um sinal fraco em prova aparente. É a mesma forma do
-- defeito que esta epic inteira existe para desfazer: um número com o FORMATO
-- de evidência.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- A EVIDÊNCIA QUE SOBREVIVEU, E POR QUE ELA É DE OUTRA NATUREZA
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A conclusão continua de pé — só muda o que a sustenta. O teste certo mantém a
-- CAMPANHA CONSTANTE e varia só o mês, em vez de comparar coortes de origens
-- diferentes. Reproduzido no banco em 2026-09-16:
--
--   origem_bruta                          leads   rejeitados   %
--   -----------------------------------   -----   ----------   -----
--   LOGMEIN_RESCUE-LICENCA-ECO_07-26         77           67   87,0%
--   LOGMEIN_RESCUE-LICENCA-ECO_08-26         17           14   82,4%
--   LOGMEIN_RESCUE-LICENCA-ECO_09_26_        39            3    7,7%
--
-- Mesma campanha, mesmo produto, mesma oferta, meses consecutivos: 87% → 82% →
-- 8%. Aqui a campanha está controlada, então a variação não pode ser explicada
-- por "os leads de setembro eram melhores". Sobra o calendário.
--
-- `GOTO_INSTITUCIONAL_07` (37 leads, 94,6% rejeitados) reforça o mesmo padrão
-- na mesma janela de julho.
--
-- E `Descalificado` — que a 105 já tratava — discrimina sozinho, com folga:
-- 699 de 700 criados numa janela de TRÊS SEMANAS = 99,9%, contra 11,5% do
-- segundo colocado (`Rejeitado`) e 2,1% de `Aberto` na mesma janela. Lift de
-- 8,7× sobre o runner-up. Esse número podia ficar, e fica.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE MUDA, E O QUE NÃO
-- ═════════════════════════════════════════════════════════════════════════════
-- Muda: o TEXTO de `status_ressalva` na linha `Rejeitado`, o texto da linha
-- `Descalificado` (ganha o lift que o torna verificável), e o COMMENT da função.
-- A ressalva passa a dizer também O QUE FOI TESTADO E REJEITADO como prova —
-- sem isso, alguém reintroduz a amplitude semanal daqui a três meses achando que
-- descobriu algo.
--
-- Não muda: assinatura, colunas, ordem de saída, filtros, grão, GRANT. Nenhum
-- outro objeto é tocado. `CREATE OR REPLACE` sem `DROP` porque o RETURNS TABLE
-- é idêntico ao da 105 — mas o `SET plan_cache_mode` é REESCRITO, porque
-- `CREATE OR REPLACE` substitui as cláusulas SET pelas do novo comando e
-- omiti-las apagaria a proteção da migration 089.
--
-- Some do corpo o contador `n_antes_varredura`: ele existia só para alimentar o
-- número (b), que caiu. Deixá-lo calculado e não usado é convite para alguém
-- reexibi-lo.
--
-- 🚫 NÃO TOCA em `fn_run_ingest_batch` (regra do db/README.md), nem em
-- `lead`, `lead_origin_classification`, `funnel_stage`, `leadsource_crosswalk`,
-- permissões ou qualquer dado. Nenhuma linha é lida para escrita.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_funil_status_do_lead(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  status                            text,
  status_rotulo                     text,
  status_ordem                      integer,
  ordem_declarada                   boolean,
  qtd_leads                         bigint,
  pct_do_recorte                    numeric,
  qtd_leads_que_viraram_oportunidade bigint,
  status_e_carimbo_de_conversao     boolean,
  qtd_status_com_conversao          bigint,
  status_ressalva                   text,
  total_do_recorte                  bigint,
  total_que_virou_oportunidade      bigint,
  qtd_status_sem_ordem_declarada    bigint
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de   timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate  timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_seg  jsonb := p_filtros->'segmento';
  v_cat  jsonb := p_filtros->'categoria';
BEGIN
  RETURN QUERY
  WITH recorte AS (
    SELECT
      -- string vazia e NULL são a MESMA ausência e caem na MESMA linha.
      nullif(trim(l.status), '')                     AS status,
      l.source_system,
      (l.converted_opportunity_id IS NOT NULL
       OR l.converted_account_id  IS NOT NULL)       AS virou_opp
    FROM lead l
    -- INNER JOIN: medido, ZERO dos 7.605 leads não-teste estão sem
    -- classificação vigente. O bloco B da verificação confere esse zero a cada
    -- execução, para que o dia em que deixar de valer apareça.
    JOIN lead_origin_classification c
      ON c.lead_id = l.id AND c.valid_to IS NULL
    WHERE NOT l.is_teste
      AND (v_de  IS NULL OR l.created_at_source >= v_de)
      AND (v_ate IS NULL OR l.created_at_source <  v_ate)
      AND fn_filtro_casa(c.segmento,  v_seg)
      AND fn_filtro_casa(c.categoria, v_cat)
  ),
  tot AS (
    SELECT count(*) AS n, count(*) FILTER (WHERE virou_opp) AS virou FROM recorte
  ),
  agg AS (
    SELECT
      r.status                                               AS st,
      count(*)                                               AS n,
      count(*) FILTER (WHERE r.virou_opp)                    AS virou,
      count(*) FILTER (WHERE r.source_system = 'rd_station') AS n_rd
      -- REMOVIDO na 106: `n_antes_varredura`. Alimentava a afirmação
      -- "90,9% criados antes de 2026-08-17", que caiu quando se mediu a taxa
      -- base (82,2%). Número calculado e não usado é número esperando para ser
      -- reexibido sem o denominador.
    FROM recorte r
    GROUP BY r.status
  ),
  com_ordem AS (
    SELECT a.*, f.ordem
    FROM agg a
    LEFT JOIN funnel_stage f ON f.origem = 'salesforce' AND f.nome = a.st
  ),
  sem_ordem AS (SELECT count(*) AS n FROM com_ordem WHERE ordem IS NULL),
  conv AS (SELECT count(*) AS n_status FROM com_ordem WHERE virou > 0)
  SELECT
    o.st,
    coalesce(o.st, '(sem status — campo não existe no RD Station)'),
    o.ordem,
    o.ordem IS NOT NULL,
    o.n,
    round(100.0 * o.n / nullif(t.n, 0), 2),
    o.virou,
    (o.virou > 0 AND cv.n_status = 1),
    cv.n_status,
    CASE
      WHEN o.st IS NULL THEN format(
        'AUSÊNCIA ESTRUTURAL, não falha de ingestão: `status` é campo do Salesforce e %s destes %s leads vêm do RD Station, onde o campo não existe — do mesmo jeito que um lead do RD não pode ter ConvertedOpportunityId. Medido em 2026-09-16: cobertura de status é 0%% no RD (0 de 521) e 100%% no Salesforce (7.084 de 7.084), nunca 93%% espalhados.',
        o.n_rd, o.n)
      WHEN o.virou > 0 AND cv.n_status = 1 THEN format(
        '🚫 ESTA LINHA NÃO É ETAPA DE FUNIL: é o CARIMBO DA CONVERSÃO. Converter um Lead no Salesforce grava este status junto com ConvertedOpportunityId, e neste recorte os %s leads convertidos estão TODOS aqui — os outros %s status somam ZERO conversões. Dividir %s por %s devolve a marca do carimbo, não desempenho comercial. Use a contagem; a razão não mede passagem de etapa.',
        t.virou, (SELECT count(*) - 1 FROM com_ordem), o.virou, o.n)
      WHEN o.virou > 0 AND cv.n_status > 1 THEN format(
        '⚠️ A PREMISSA DA MIGRATION 105 MUDOU: até 2026-09-16 `Qualificado` era o ÚNICO status com conversões (carimbo do Salesforce). Agora são %s status diferentes convertendo. Reavaliar o cabeçalho da 105 antes de ler qualquer razão desta coluna.',
        cv.n_status)
      -- ── A RESSALVA CORRIGIDA PELA 106 ────────────────────────────────────
      -- Ela diz as três coisas, nesta ordem: a conclusão, a prova que a
      -- sustenta, e AS PROVAS QUE FORAM TESTADAS E CAÍRAM. A terceira parte é
      -- o que impede a amplitude semanal de voltar daqui a três meses vestida
      -- de descoberta.
      WHEN o.st = 'Rejeitado' THEN
        '⚠️ EM BOA PARTE AUTOMAÇÃO, NÃO JULGAMENTO COMERCIAL. '
        || 'O QUE SUSTENTA (medido 2026-09-16, com a CAMPANHA MANTIDA CONSTANTE): '
        || '`LOGMEIN_RESCUE-LICENCA-ECO` rejeitou 87,0% dos leads de 07-26 (67 de 77), '
        || '82,4% dos de 08-26 (14 de 17) e 7,7% dos de 09_26_ (3 de 39). Mesma campanha, '
        || 'mesma oferta, meses consecutivos — com a campanha controlada, a variação não pode '
        || 'ser "os leads de setembro eram melhores". `GOTO_INSTITUCIONAL_07` repete o padrão '
        || '(37 leads, 94,6% rejeitados). '
        || '🚫 O QUE FOI TESTADO E NÃO SUSTENTA, e a migration 105 citava por engano: '
        || '(a) a amplitude semanal de rejeição (0,0%–93,5%) NÃO discrimina, porque `Aberto` '
        || 'varia 94,6 pontos nas mesmas semanas — a base inteira entra em lote; '
        || '(b) "90,9% dos rejeitados criados antes de 2026-08-17" quase não discrimina, '
        || 'porque a TAXA BASE é 82,2% (5.369 de 6.531 leads da janela), um lift de só 1,11×. '
        || 'Ler esta linha como "leads ruins" continua errado — mas a prova é a campanha '
        || 'controlada, não a coorte de criação.'
      WHEN o.st = 'Descalificado' THEN
        '⚠️ LOTE, NÃO JULGAMENTO — e balde que nenhum card de "rejeição" conta. '
        || 'Medido 2026-09-16: 699 dos 700 leads com este status foram criados numa janela de '
        || 'TRÊS SEMANAS (2026-06-29 a 2026-07-19) = 99,9%, contra 11,5% de `Rejeitado` e 2,1% '
        || 'de `Aberto` na MESMA janela. Lift de 8,7× sobre o segundo colocado — diferente da '
        || 'coorte de `Rejeitado`, esta concentração discrimina de verdade. '
        || 'A rejeição real desta base é maior do que qualquer número de `Rejeitado` exibido, '
        || 'porque está repartida entre dois status.'
    END,
    t.n,
    t.virou,
    s.n
  FROM com_ordem o
  CROSS JOIN tot t
  CROSS JOIN sem_ordem s
  CROSS JOIN conv cv
  -- Ordem por VOLUME: sem `funnel_stage` povoado para salesforce não existe
  -- ordem de etapa, e ordenar por `status_ordem` sugeriria uma sequência que
  -- ninguém declarou.
  ORDER BY o.n DESC, o.st NULLS LAST;
END;
$function$;

COMMENT ON FUNCTION public.fn_funil_status_do_lead(jsonb) IS
  'ONDE OS LEADS PARAM. GRÃO: UMA LINHA POR lead.status. A POPULAÇÃO CONTADA É LEAD, NUNCA OPORTUNIDADE — é essa distinção que impede de voltar a dividir um lado pelo outro (contrato §1.7). pct_do_recorte é participação no total de LEADS do recorte e as participações somam 100%. 🚫 NÃO EXISTE pct_virou_oportunidade, de propósito: medido em 2026-09-16, TODOS os leads convertidos desta base têm status=Qualificado e NENHUM outro status tem uma única conversão — Qualificado é o CARIMBO da conversão no Salesforce, não uma etapa que converte 93%. status_e_carimbo_de_conversao marca essa linha, qtd_status_com_conversao expõe a premissa (é 1) e status_ressalva explica. ⚠️ Rejeitado é em boa parte AUTOMAÇÃO, e a prova é a comparação com a CAMPANHA CONSTANTE: LOGMEIN_RESCUE-LICENCA-ECO rejeitou 87,0% em 07-26, 82,4% em 08-26 e 7,7% em 09_26_. 🚫 CORRIGIDO PELA MIGRATION 106: a 105 sustentava isso com a amplitude semanal (0,0%-93,5%) e com "90,9% criados antes de 2026-08-17", e os DOIS caíram no teste negativo — Aberto varia 94,6 pontos nas mesmas semanas, e a taxa base da coorte é 82,2% (lift de 1,11x). Os dois números continuam citados na ressalva, agora como provas REFUTADAS, para que ninguém os reintroduza. Descalificado é um segundo balde de rejeição cuja concentração DISCRIMINA: 99,9% em três semanas contra 11,5% do segundo colocado. ⚠️ status_ordem vem de funnel_stage e HOJE É NULL EM TODAS AS LINHAS porque a tabela tem ZERO linhas com origem=salesforce; a saída é ordenada por VOLUME e ordem_declarada=false diz isso linha a linha. ⚠️ a linha (sem status) é 100% RD Station: cobertura de status é 0% no RD e 100% no Salesforce, nunca 93% espalhados. Filtros: de, ate, segmento, categoria — todos valem para a população inteira que a função conta. Migrations 105 + 106.';

GRANT EXECUTE ON FUNCTION public.fn_funil_status_do_lead(jsonb) TO crm_ingest;

COMMIT;
