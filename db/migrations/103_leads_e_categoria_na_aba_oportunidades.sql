-- db/migrations/103_leads_e_categoria_na_aba_oportunidades.sql
--
-- A ABA MOSTRA O SEGMENTO DA OPORTUNIDADE E MAIS NADA. FALTAM DUAS CAMADAS:
-- QUANTOS LEADS AQUELE SEGMENTO GEROU, E QUAL CATEGORIA (EVENTO, PAID, INBOUND).
--
-- O dono do produto pediu duas coisas, e a segunda já existia sem ele saber:
--
--   1. Ver os LEADS ao lado das oportunidades — "marketing gera N leads, dos
--      quais alguns viram oportunidade".
--   2. Ver a CATEGORIA, em especial eventos. Ele achava que precisava criá-la.
--      Ela existe desde a 018/075: `Marketing / Evento/Webinar`, 10 regras em
--      `leadsource_crosswalk`, 724 leads classificados hoje. O que faltava era
--      a camada EXPOR — `view_oportunidade_analitica` já projeta `categoria`
--      desde a migration 100, e nenhuma das três funções da aba a agregava.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🔴 A MEDIÇÃO QUE DEFINE O DESENHO: LEAD E OPORTUNIDADE SÃO DUAS POPULAÇÕES
-- ═════════════════════════════════════════════════════════════════════════════
--
-- O pedido natural seria uma coluna "taxa de conversão = oportunidades ÷ leads".
-- Medido em 2026-09-16, janela de 12 meses (`created_at_source >= now() - 12
-- meses`, `NOT is_teste`), sobre `lead` + `lead_origin_classification` vigente:
--
--   segmento       leads   com converted_opportunity_id   com converted_account_id   com algum
--   ------------   -----   ---------------------------    ------------------------   ---------
--   Comercial      3.643            55                            56                    56  (1,5%)
--   Marketing      1.785           104                           102                   104  (5,8%)
--   NaoAtribuido   1.551            91                            93                    94  (6,1%)
--   Parceiro          75            64                            63                    64 (85,3%)
--
-- E do outro lado, das 300 oportunidades de Marketing criadas na mesma janela:
--
--   lead_vinculo_regra = 'oportunidade' .....  103
--   lead_vinculo_regra = 'conta' ............   51
--   lead_vinculo_regra = 'leadsource' .......  146   ← sem lead nenhum na base
--
-- Ou seja: 94,2% dos leads de Marketing NUNCA viram oportunidade rastreável, e
-- 48,7% das oportunidades de Marketing NUNCA tiveram lead. Os dois baldes se
-- tocam em 154 linhas e divergem em milhares. Dividir um pelo outro devolveria
-- um número com cara de taxa de conversão que NÃO mede conversão: mede o quanto
-- duas populações atribuídas por caminhos diferentes se parecem em tamanho.
--
-- É exatamente o defeito da aba antiga, que dividia "Qualificados" por "Em
-- cadência" — dois estados mutuamente exclusivos — e chamava o resultado de
-- "conversão de 88,9%".
--
-- POR ISSO ESTA MIGRATION NÃO CRIA COLUNA DE TAXA LEAD→OPORTUNIDADE. Ela
-- entrega as duas contagens SEPARADAS e, ao lado, o único número que de fato
-- liga as duas populações: quantas oportunidades daquele segmento chegaram lá
-- por um lead rastreado (`qtd_opps_rastreadas_ate_lead`) contra quantas
-- chegaram só pela picklist da própria oportunidade (`qtd_opps_so_por_leadsource`).
-- Esses dois, sim, são numerador e denominador do MESMO conjunto.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 PREMISSA QUE NÃO SOBREVIVEU: "rastreadas + só_por_leadsource = o total"
-- ═════════════════════════════════════════════════════════════════════════════
--
-- O pedido dizia que as duas contagens acima deveriam fechar com o total de
-- oportunidades do segmento. Elas não fecham, e o motivo está medido:
-- `lead_vinculo_regra` tem SEIS valores (migration 100), não três.
--
--   lead_vinculo_regra         base inteira    janela 12m
--   -----------------------    ------------    ----------
--   leadsource                      6.158          4.104
--   leadsource_desconhecido         1.394            797
--   oportunidade                      322            318
--   conta                             199            188
--   sem_origem                          2              0
--   lead_sem_classificacao              0              0
--
-- `sem_origem` (nem lead nem LeadSource) existe: são 2 registros. Na janela de
-- 12 meses são zero, então uma checagem de dois baldes passaria VERDE hoje e
-- mentiria sobre a base inteira. `lead_sem_classificacao` é zero hoje mas é
-- estado alcançável do CASE (lead existe, classificação vigente não).
--
-- A saída tem QUATRO contagens, uma por grupo, cobrindo os seis valores sem
-- ELSE implícito, e `soma_vinculo_fecha` confere a partição A CADA CHAMADA —
-- o mesmo mecanismo do `soma_fecha` da migration 097. Uma checagem que só
-- consegue passar não é checagem.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 SEGUNDA DIVERGÊNCIA DECLARADA: OS DOIS LADOS NÃO FALAM O MESMO VOCABULÁRIO
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `lead_origin_classification.segmento` tem CHECK de 4 valores:
--   Marketing · Comercial · NaoAtribuido · Parceiro
--
-- `view_oportunidade_analitica.segmento_aba` tem 6:
--   os 4 acima + NaoClassificado (LeadSource que o crosswalk não traduz)
--                + SemOrigem     (nem lead nem LeadSource)
--
-- Os dois valores extras nascem do lado da OPORTUNIDADE e não têm contraparte
-- no lado do lead — um lead sem origem vira `NaoAtribuido/Direto-Desconhecido`,
-- nunca `SemOrigem`. Forçar um domínio no outro (mapear NaoClassificado para
-- NaoAtribuido, por exemplo) apagaria a distinção que a migration 100 existe
-- para preservar: `NaoAtribuido` é decisão TOMADA, `NaoClassificado` é ausência
-- de decisão.
--
-- A junção é FULL OUTER JOIN, e cada linha declara de onde veio em
-- `segmento_presente_em` / `categoria_presente_em`:
--   'ambos'            — existe nos dois lados
--   'so_oportunidade'  — o zero de leads é ESTRUTURAL, não um zero medido
--   'so_lead'          — o segmento gerou leads e nenhuma oportunidade no recorte
-- Nenhuma linha some por não ter par. Sumir é a exclusão silenciosa do §1.6.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 TERCEIRA DIVERGÊNCIA: OS FILTROS DA ABA SÃO DE OPORTUNIDADE, NÃO DE LEAD
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `fase`, `desfecho`, `record_type`, `moeda` e `lead_source` são atributos que
-- só existem em `opportunity`. Um lead não tem fase de oportunidade nem moeda.
--
-- Aplicá-los ao lado do lead é impossível; ignorá-los em SILÊNCIO faria a tela
-- mostrar "Marketing: 26 oportunidades ganhas, 1.785 leads" com o recorte de
-- oportunidade apertado e o de lead aberto, sem nenhum aviso. Por isso as
-- contagens de lead honram SOMENTE o período (`de`/`ate`) — mais `segmento` e
-- `categoria` em `fn_oportunidades_por_categoria`, que existem dos dois lados —
-- e `leads_filtros_ignorados` devolve, em texto, a lista dos filtros que foram
-- pedidos e NÃO puderam ser aplicados ao lead. NULL = nenhum filtro divergente,
-- os dois lados olham o mesmo recorte.
--
-- O período do lead é sobre `lead.created_at_source` (0 nulos hoje entre os
-- 7.605 não-teste); `qtd_leads_fora_por_data_ausente` conta quem ficaria de
-- fora por não ter data, em vez de deixar a diferença sem explicação.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- A LIMPEZA DO ITEM 3 — MEDIDA, NÃO PALPITADA
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Os valores de `origem_bruta` que hoje caem em `NaoAtribuido / Outro (requer
-- nota)`, medidos em 2026-09-16:
--
--   GoTo ....................... 325     Evento ..................  12
--   Presença LOTR Fresh ........  19     WhatsApp ................   4
--   Inbound ....................  12     LastPass ................   2
--   SITE_GoTo_Fale conosco .....   1     Tráfego Direto ..........   1
--   LogMeIn_2.0 ................   1
--
-- UM só é inequivocamente evento: o literal `Evento` (12 leads). Ele ganha
-- regra abaixo. Os outros oito ficam onde estão e viram relato, não regra:
-- `Presença LOTR Fresh` (19) pode ser presença em evento ou nome de lista;
-- `GoTo` é o parceiro, não um canal; `Inbound` é genérico demais para virar
-- categoria. Chutar qualquer um deles seria refazer, em escala menor, o
-- "100% atribuído a marketing" que esta epic existe para desfazer.
--
-- 🚫 NÃO SÃO MEXIDOS os 9 leads `Outbound ERP Summit`, hoje em
-- `Comercial / Outbound SDR/Vendas`. Eles estão CERTOS: prospecção ativa
-- feita num evento é outbound, não lead de evento. O nome do evento no valor
-- bruto é isca para o erro — a palavra "Summit" não decide segmento.
--
-- Efeito medido do `Evento` novo, ANTES de aplicar (ver o arquivo de
-- verificação para o antes-e-depois completo):
--   · 12 leads saem de `NaoAtribuido/Outro (requer nota)` para
--     `Marketing/Evento/Webinar`. 3 deles estão na janela de 12 meses.
--   · 2 oportunidades ligadas a esses leads por `converted_opportunity_id`
--     mudam junto (vínculo 'oportunidade', a classificação do lead manda).
--   · 14 oportunidades com `Opportunity.LeadSource = 'Evento'` saem de
--     `NaoClassificado` para `Marketing/Evento/Webinar` — o crosswalk serve
--     aos DOIS lados. 5 delas estão na janela de 12 meses.
--
-- A migration 076 existe porque `fn_reclassificar_lead` só versionava quando
-- `valor_bruto` mudava — regra nova com sinal bruto inalterado passava em
-- branco. Aqui é exatamente esse caso, então o DO block abaixo NÃO confia:
-- conta antes, roda, conta depois e ABORTA a migration se algum dos 12 não
-- tiver chegado em `Marketing/Evento/Webinar`.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE ESTA MIGRATION NÃO TOCA
-- ═════════════════════════════════════════════════════════════════════════════
-- `fn_run_ingest_batch` (regra do db/README.md — duas reversões silenciosas já
-- aconteceram nela nesta epic), `view_oportunidade_analitica`,
-- `fn_oportunidades_cards`, `fn_oportunidades_funil`, `fn_search_oportunidades`
-- (a 104 cuida do filtro de categoria dela), `fn_classify_origin`,
-- `fn_reclassificar_lead`, `opportunity`, `lead`, permissões de role. Nenhuma
-- linha é apagada. Uma linha é INSERIDA em `leadsource_crosswalk` e 12 leads
-- ganham uma VERSÃO nova de classificação — o histórico anterior continua lá,
-- com `valid_to` preenchido.
--
-- `fn_oportunidades_por_segmento` precisa de DROP antes do CREATE porque o
-- RETURNS TABLE ganha colunas, e `CREATE OR REPLACE` não muda tipo de retorno.
-- O DROP descarta o `ALTER FUNCTION ... SET plan_cache_mode` e o `GRANT`, então
-- os dois são REESCRITOS abaixo. Sem o `force_custom_plan`, filtro opcional na
-- forma `($n IS NULL OR col = $n)` degradou `fn_search_pessoas` de 259 ms para
-- 207 s neste mesmo banco (migration 089).

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. UM AJUDANTE: "ESTE FILTRO FOI REALMENTE PEDIDO?"
-- ═════════════════════════════════════════════════════════════════════════════
-- `fn_filtro_casa` responde "este valor passa?". Falta a pergunta gêmea: "o
-- chamador pediu restrição aqui?". As duas TÊM de concordar sobre o que conta
-- como filtro ausente (chave ausente, jsonb null, array vazio) — se
-- divergirem, `leads_filtros_ignorados` avisaria de um filtro que não está
-- filtrando nada, ou pior, ficaria calado sobre um que está.

CREATE OR REPLACE FUNCTION public.fn_filtro_ativo(p_filtro jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT p_filtro IS NOT NULL
     AND jsonb_typeof(p_filtro) <> 'null'
     AND NOT (jsonb_typeof(p_filtro) = 'array' AND jsonb_array_length(p_filtro) = 0);
$function$;

COMMENT ON FUNCTION public.fn_filtro_ativo(jsonb) IS
  'O complemento de fn_filtro_casa: responde se o chamador de fato PEDIU restrição neste filtro. Ausência de chave, jsonb null e array vazio contam como "não pediu" — exatamente os três casos que fn_filtro_casa trata como "sem restrição". As duas funções precisam concordar: é essa concordância que faz leads_filtros_ignorados dizer a verdade. Migration 103.';

GRANT EXECUTE ON FUNCTION public.fn_filtro_ativo(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A REGRA NOVA: `Evento` É EVENTO
-- ═════════════════════════════════════════════════════════════════════════════
-- Uma LINHA no crosswalk, com `decidido_em` e `fonte_decisao` dizendo de onde
-- a decisão veio. Nunca um CASE dentro de view — foi essa disciplina que
-- permitiu medir o efeito antes de aplicar.

INSERT INTO leadsource_crosswalk
  (valor_bruto, segmento,    categoria,        detalhe, sinal_id, decidido_em,      fonte_decisao)
VALUES
  ('Evento',    'Marketing', 'Evento/Webinar', NULL,    'S3',     DATE '2026-09-16',
   'Migration 103 — varredura dos 9 valores de origem_bruta parados em NaoAtribuido/Outro (requer nota) em 2026-09-16. `Evento` e o unico inequivoco dos nove (12 leads); os outros oito ficaram sem regra de proposito. Detalhe NULL porque o valor bruto nao nomeia QUAL evento -- inventar um nome aqui seria dado fabricado.')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A RECLASSIFICAÇÃO — COM A PROVA DE QUE RODOU
-- ═════════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_antes_naoatribuido  int;
  v_antes_marketing     int;
  v_versionou           int := 0;
  v_id                  bigint;
  v_depois_marketing    int;
  v_depois_naoatribuido int;
  v_total_evento        int;
BEGIN
  SELECT count(*) INTO v_total_evento FROM lead WHERE origem_bruta = 'Evento';

  SELECT count(*) FILTER (WHERE c.segmento = 'NaoAtribuido'),
         count(*) FILTER (WHERE c.segmento = 'Marketing' AND c.categoria = 'Evento/Webinar')
    INTO v_antes_naoatribuido, v_antes_marketing
  FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE l.origem_bruta = 'Evento';

  FOR v_id IN SELECT id FROM lead WHERE origem_bruta = 'Evento' ORDER BY id LOOP
    IF fn_reclassificar_lead(v_id) THEN
      v_versionou := v_versionou + 1;
    END IF;
  END LOOP;

  SELECT count(*) FILTER (WHERE c.segmento = 'Marketing' AND c.categoria = 'Evento/Webinar'),
         count(*) FILTER (WHERE c.segmento = 'NaoAtribuido')
    INTO v_depois_marketing, v_depois_naoatribuido
  FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE l.origem_bruta = 'Evento';

  RAISE NOTICE 'Reclassificacao de origem_bruta = ''Evento'': % leads no total.', v_total_evento;
  RAISE NOTICE '  antes:  NaoAtribuido=%  Marketing/Evento-Webinar=%', v_antes_naoatribuido, v_antes_marketing;
  RAISE NOTICE '  depois: NaoAtribuido=%  Marketing/Evento-Webinar=%', v_depois_naoatribuido, v_depois_marketing;
  RAISE NOTICE '  fn_reclassificar_lead versionou % lead(s).', v_versionou;

  -- A ASSERÇÃO QUE A MIGRATION 076 ENSINOU A ESCREVER. Um RAISE NOTICE com o
  -- número certo não prova nada se ninguém lê a saída do apply.sh; esta
  -- exceção aborta a transação inteira e não deixa a regra entrar sem efeito.
  IF v_depois_marketing <> v_total_evento THEN
    RAISE EXCEPTION
      'A regra entrou no crosswalk mas a reclassificacao nao pegou: % de % leads com origem_bruta=''Evento'' estao em Marketing/Evento-Webinar.',
      v_depois_marketing, v_total_evento
      USING HINT = 'fn_reclassificar_lead so versiona quando o RESULTADO muda (migration 076). Se este erro apareceu, fn_classify_origin nao esta lendo leadsource_crosswalk, ou o valor bruto tem espaco/caixa diferente de ''Evento''.';
  END IF;

  IF v_depois_naoatribuido <> 0 THEN
    RAISE EXCEPTION 'Sobraram % leads ''Evento'' em NaoAtribuido depois da reclassificacao.', v_depois_naoatribuido;
  END IF;
END
$mig$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. SEGMENTO — AGORA COM O LADO DO LEAD
-- ═════════════════════════════════════════════════════════════════════════════
-- Contrato de filtros inalterado (de, ate, fase, desfecho, record_type, moeda,
-- lead_source) e as 14 colunas da 097/100 ficam nas MESMAS posições, na mesma
-- ordem. As 11 colunas novas entram no fim — quem já consome por nome não
-- percebe, quem consome por posição não quebra.

DROP FUNCTION IF EXISTS public.fn_oportunidades_por_segmento(jsonb);

CREATE OR REPLACE FUNCTION public.fn_oportunidades_por_segmento(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  -- ── as 14 colunas da 097/100, intocadas ──────────────────────────────────
  segmento_aba                     text,
  qtd_oportunidades                bigint,
  pct_do_total                     numeric,
  qtd_ganhas                       bigint,
  qtd_perdidas                     bigint,
  qtd_nao_decididas                bigint,
  qtd_decididas                    bigint,
  win_rate_decididas_pct           numeric,
  receita_ganha_brl                numeric,
  pct_da_receita                   numeric,
  qtd_ganhas_fora_do_valor         bigint,
  pipeline_aberto_brl              numeric,
  total_do_recorte                 bigint,
  receita_total_do_recorte         numeric,
  -- ── DE ONDE VEIO A ATRIBUIÇÃO. Partição TOTAL dos 6 lead_vinculo_regra ───
  -- Estes dois primeiros SÃO numerador e denominador do mesmo conjunto: das
  -- oportunidades deste segmento, quantas chegaram por um lead que existe na
  -- nossa base contra quantas chegaram só pela picklist da própria
  -- oportunidade. É o número que liga os dois lados sem inventar uma taxa.
  qtd_opps_rastreadas_ate_lead     bigint,
  qtd_opps_so_por_leadsource       bigint,
  qtd_opps_lead_sem_classificacao  bigint,
  qtd_opps_sem_origem              bigint,
  soma_vinculo_fecha               boolean,
  -- ── O LADO DO LEAD. Populações separadas, contagens separadas ────────────
  qtd_leads_gerados                bigint,
  qtd_leads_com_oportunidade       bigint,
  qtd_leads_fora_por_data_ausente  bigint,
  total_leads_do_recorte           bigint,
  -- ── as duas declarações que impedem leitura errada dos zeros ─────────────
  segmento_presente_em             text,
  leads_filtros_ignorados          text
)
LANGUAGE plpgsql
STABLE
-- Migration 089: sem isto, filtro opcional na forma ($n IS NULL OR col=$n) faz
-- o planejador multiplicar seletividades default, estimar rows=1 e escolher
-- nested loop. 800x de degradação medidos neste banco. O DROP acima descartou
-- o ALTER original — esta linha é o que o repõe.
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de       timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate      timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_fase     jsonb := p_filtros->'fase';
  v_desfecho jsonb := p_filtros->'desfecho';
  v_rt       jsonb := p_filtros->'record_type';
  v_moeda    jsonb := p_filtros->'moeda';
  v_ls       jsonb := p_filtros->'lead_source';
  v_ignorados text;
BEGIN
  -- Nenhum destes cinco existe em `lead`. A lista é montada aqui, uma vez, e
  -- devolvida em TODAS as linhas: a tela precisa poder rotular o card de leads
  -- com "este recorte não vale para os leads" sem adivinhar.
  v_ignorados := nullif(array_to_string(ARRAY[
    CASE WHEN fn_filtro_ativo(v_fase)     THEN 'fase'        END,
    CASE WHEN fn_filtro_ativo(v_desfecho) THEN 'desfecho'    END,
    CASE WHEN fn_filtro_ativo(v_rt)       THEN 'record_type' END,
    CASE WHEN fn_filtro_ativo(v_moeda)    THEN 'moeda'       END,
    CASE WHEN fn_filtro_ativo(v_ls)       THEN 'lead_source' END
  ]::text[], ', '), '');

  RETURN QUERY
  WITH recorte AS (
    SELECT v.*
    FROM view_oportunidade_analitica v
    WHERE (v_de  IS NULL OR v.criada_em >= v_de)
      AND (v_ate IS NULL OR v.criada_em <  v_ate)
      AND fn_filtro_casa(v.fase,        v_fase)
      AND fn_filtro_casa(v.desfecho,    v_desfecho)
      AND fn_filtro_casa(v.record_type, v_rt)
      AND fn_filtro_casa(v.moeda,       v_moeda)
      AND fn_filtro_casa(v.lead_source, v_ls)
  ),
  tot AS (
    SELECT count(*) AS n,
           sum(amount_brl) FILTER (WHERE desfecho = 'ganha') AS receita
    FROM recorte
  ),
  -- ── lado OPORTUNIDADE ────────────────────────────────────────────────────
  agg_opp AS (
    SELECT
      r.segmento_aba                                                       AS seg,
      count(*)                                                             AS n,
      count(*) FILTER (WHERE r.desfecho = 'ganha')                         AS ganhas,
      count(*) FILTER (WHERE r.desfecho = 'perdida')                       AS perdidas,
      count(*) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase'))      AS nao_decididas,
      count(*) FILTER (WHERE r.desfecho IN ('ganha','perdida'))            AS decididas,
      sum(r.amount_brl) FILTER (WHERE r.desfecho = 'ganha')                AS receita,
      count(*) FILTER (WHERE r.desfecho = 'ganha' AND r.amount_brl IS NULL) AS ganhas_sem_valor,
      sum(r.amount_brl) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase')) AS pipeline,
      -- Os quatro baldes do vínculo. Escritos como quatro FILTER explícitos e
      -- não como um CASE com ELSE: um valor novo em lead_vinculo_regra tem de
      -- QUEBRAR soma_vinculo_fecha, não se esconder no último balde.
      count(*) FILTER (WHERE r.lead_vinculo_regra IN ('oportunidade','conta'))           AS v_rastreadas,
      count(*) FILTER (WHERE r.lead_vinculo_regra IN ('leadsource','leadsource_desconhecido')) AS v_leadsource,
      count(*) FILTER (WHERE r.lead_vinculo_regra = 'lead_sem_classificacao')            AS v_sem_classe,
      count(*) FILTER (WHERE r.lead_vinculo_regra = 'sem_origem')                        AS v_sem_origem
    FROM recorte r
    GROUP BY r.segmento_aba
  ),
  -- ── lado LEAD. Outra população, outro universo, outro grão ───────────────
  -- `NOT is_teste` exclui os 39 fixtures (migration 025 e seguintes) pelo
  -- mesmo motivo que a view exclui seed_test: por predicado, não por sorte.
  leads_base AS (
    SELECT c.segmento                                        AS seg,
           l.created_at_source                               AS criado_em,
           (l.converted_opportunity_id IS NOT NULL
            OR l.converted_account_id IS NOT NULL)           AS tem_opp
    FROM lead l
    JOIN lead_origin_classification c
      ON c.lead_id = l.id AND c.valid_to IS NULL
    WHERE NOT l.is_teste
  ),
  agg_lead AS (
    SELECT
      b.seg,
      count(*) FILTER (WHERE b.criado_em IS NOT NULL
                         AND (v_de  IS NULL OR b.criado_em >= v_de)
                         AND (v_ate IS NULL OR b.criado_em <  v_ate))               AS n,
      count(*) FILTER (WHERE b.criado_em IS NOT NULL
                         AND (v_de  IS NULL OR b.criado_em >= v_de)
                         AND (v_ate IS NULL OR b.criado_em <  v_ate)
                         AND b.tem_opp)                                              AS com_opp,
      -- Só é "ficou de fora por falta de data" se houvesse recorte de período.
      -- Sem `de` nem `ate` o lead entra na contagem mesmo sem data.
      count(*) FILTER (WHERE b.criado_em IS NULL
                         AND (v_de IS NOT NULL OR v_ate IS NOT NULL))                AS sem_data
    FROM leads_base b
    GROUP BY b.seg
  ),
  tot_lead AS (SELECT coalesce(sum(n), 0)::bigint AS n FROM agg_lead)
  SELECT
    coalesce(o.seg, a.seg),
    coalesce(o.n, 0),
    round(100.0 * coalesce(o.n, 0) / nullif(t.n, 0), 2),
    coalesce(o.ganhas, 0),
    coalesce(o.perdidas, 0),
    coalesce(o.nao_decididas, 0),
    coalesce(o.decididas, 0),
    round(100.0 * o.ganhas / nullif(o.decididas, 0), 2),
    o.receita,
    round(100.0 * o.receita / nullif(t.receita, 0), 2),
    coalesce(o.ganhas_sem_valor, 0),
    o.pipeline,
    t.n,
    t.receita,
    coalesce(o.v_rastreadas, 0),
    coalesce(o.v_leadsource, 0),
    coalesce(o.v_sem_classe, 0),
    coalesce(o.v_sem_origem, 0),
    (coalesce(o.v_rastreadas,0) + coalesce(o.v_leadsource,0)
     + coalesce(o.v_sem_classe,0) + coalesce(o.v_sem_origem,0)) = coalesce(o.n, 0),
    coalesce(a.n, 0),
    coalesce(a.com_opp, 0),
    coalesce(a.sem_data, 0),
    tl.n,
    CASE WHEN o.seg IS NOT NULL AND a.seg IS NOT NULL THEN 'ambos'
         WHEN o.seg IS NOT NULL                       THEN 'so_oportunidade'
         ELSE                                              'so_lead' END,
    v_ignorados
  -- FULL OUTER: NaoClassificado e SemOrigem não existem do lado do lead, e um
  -- segmento pode gerar lead sem gerar oportunidade no recorte. Nos dois casos
  -- a linha aparece com zero do outro lado, e `segmento_presente_em` diz que o
  -- zero é estrutural. INNER JOIN aqui apagaria 797 oportunidades de
  -- NaoClassificado da tela sem aviso.
  FROM agg_opp o
  FULL OUTER JOIN agg_lead a ON a.seg = o.seg
  CROSS JOIN tot t
  CROSS JOIN tot_lead tl
  ORDER BY coalesce(o.n, 0) DESC, coalesce(a.n, 0) DESC, coalesce(o.seg, a.seg);
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) IS
  'MARKETING vs COMERCIAL DA ABA OPORTUNIDADES, COM O LADO DO LEAD AO LADO. GRÃO: UMA LINHA POR SEGMENTO, vindo de um FULL OUTER JOIN entre o segmento_aba da oportunidade (6 valores) e o segmento do lead (4 valores — o CHECK de lead_origin_classification não tem NaoClassificado nem SemOrigem). segmento_presente_em diz se a linha existe nos dois lados; um zero com segmento_presente_em=so_oportunidade é ESTRUTURAL, não medido. 🚫 NÃO DIVIDA qtd_oportunidades POR qtd_leads_gerados: medido em 2026-09-16 na janela de 12 meses, 94,2% dos 1.785 leads de Marketing nunca viraram oportunidade rastreável e 48,7% das 300 oportunidades de Marketing nunca tiveram lead (chegaram por Opportunity.LeadSource). São duas populações atribuídas por caminhos diferentes; a razão entre elas não mede conversão, do mesmo jeito que "Qualificados ÷ Em cadência" não media na aba antiga. O número que LIGA as duas é qtd_opps_rastreadas_ate_lead sobre qtd_oportunidades — esses sim são do mesmo conjunto. As quatro contagens de vínculo (rastreadas / so_por_leadsource / lead_sem_classificacao / sem_origem) são partição TOTAL dos 6 valores de lead_vinculo_regra e soma_vinculo_fecha confere a cada chamada. ⚠️ As contagens de lead honram SOMENTE de/ate: fase, desfecho, record_type, moeda e lead_source não existem em lead, e leads_filtros_ignorados lista, em texto, os que foram pedidos e não puderam ser aplicados. Universo do lead: NOT is_teste, período sobre created_at_source. Migrations 097 + 100 + 103.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. CATEGORIA — A CAMADA QUE O DONO DO PRODUTO ACHAVA QUE PRECISAVA CRIAR
-- ═════════════════════════════════════════════════════════════════════════════
-- GRÃO: uma linha por PAR (segmento_aba, categoria), não por categoria solta.
-- Medido em 2026-09-16: nenhuma categoria aparece sob dois segmentos, nem em
-- `leadsource_crosswalk` nem em `lead_origin_classification` — a dependência é
-- funcional HOJE. Chavear pelo par custa nada e evita que uma regra futura
-- ("Webinar" sob Comercial, por exemplo) funda duas linhas em silêncio.
--
-- CATEGORIA NULL É LINHA PRÓPRIA. Do lado da oportunidade ela é NULL sempre que
-- segmento_aba é NaoClassificado ou SemOrigem — 797 oportunidades na janela de
-- 12 meses. Somá-las a qualquer categoria existente é literalmente o mecanismo
-- que produziu o "100% atribuído a marketing". `categoria_rotulo` dá um nome à
-- linha para a tela não imprimir vazio, e `categoria` continua NULL para quem
-- for filtrar.

CREATE OR REPLACE FUNCTION public.fn_oportunidades_por_categoria(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  -- ── a chave, e o segmento junto para a tela poder agrupar ────────────────
  segmento_aba                     text,
  categoria                        text,
  categoria_rotulo                 text,
  -- ── oportunidades: o mesmo vocabulário de fn_oportunidades_por_segmento ──
  qtd_oportunidades                bigint,
  pct_do_total                     numeric,
  qtd_ganhas                       bigint,
  qtd_perdidas                     bigint,
  qtd_nao_decididas                bigint,
  qtd_decididas                    bigint,
  win_rate_decididas_pct           numeric,
  receita_ganha_brl                numeric,
  pct_da_receita                   numeric,
  qtd_ganhas_fora_do_valor         bigint,
  pipeline_aberto_brl              numeric,
  -- ── de onde veio a atribuição ────────────────────────────────────────────
  qtd_opps_rastreadas_ate_lead     bigint,
  qtd_opps_so_por_leadsource       bigint,
  qtd_opps_lead_sem_classificacao  bigint,
  qtd_opps_sem_origem              bigint,
  soma_vinculo_fecha               boolean,
  -- ── o lado do lead ───────────────────────────────────────────────────────
  qtd_leads_gerados                bigint,
  qtd_leads_com_oportunidade       bigint,
  qtd_leads_fora_por_data_ausente  bigint,
  -- ── os totais do recorte, para conferir a soma na própria saída ──────────
  total_do_recorte                 bigint,
  receita_total_do_recorte         numeric,
  total_leads_do_recorte           bigint,
  -- ── as declarações ──────────────────────────────────────────────────────
  categoria_presente_em            text,
  leads_filtros_ignorados          text
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de        timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate       timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_seg       jsonb := p_filtros->'segmento';
  v_cat       jsonb := p_filtros->'categoria';
  v_fase      jsonb := p_filtros->'fase';
  v_desfecho  jsonb := p_filtros->'desfecho';
  v_rt        jsonb := p_filtros->'record_type';
  v_moeda     jsonb := p_filtros->'moeda';
  v_ls        jsonb := p_filtros->'lead_source';
  v_ignorados text;
BEGIN
  -- `segmento` e `categoria` existem nos DOIS lados e por isso NÃO entram na
  -- lista de ignorados: eles são aplicados ao lead também. Os outros cinco são
  -- atributos de `opportunity` e não têm contraparte.
  v_ignorados := nullif(array_to_string(ARRAY[
    CASE WHEN fn_filtro_ativo(v_fase)     THEN 'fase'        END,
    CASE WHEN fn_filtro_ativo(v_desfecho) THEN 'desfecho'    END,
    CASE WHEN fn_filtro_ativo(v_rt)       THEN 'record_type' END,
    CASE WHEN fn_filtro_ativo(v_moeda)    THEN 'moeda'       END,
    CASE WHEN fn_filtro_ativo(v_ls)       THEN 'lead_source' END
  ]::text[], ', '), '');

  RETURN QUERY
  WITH recorte AS (
    SELECT v.*
    FROM view_oportunidade_analitica v
    WHERE (v_de  IS NULL OR v.criada_em >= v_de)
      AND (v_ate IS NULL OR v.criada_em <  v_ate)
      AND fn_filtro_casa(v.segmento_aba, v_seg)
      -- ⚠️ fn_filtro_casa devolve false para valor NULL quando há filtro
      -- presente (comentário da própria função). Consequência DECLARADA: pedir
      -- categoria=['Evento/Webinar'] remove a linha de categoria ausente do
      -- resultado. Isso é correto — quem filtra por uma categoria pediu aquela
      -- categoria — mas significa que total_do_recorte encolhe junto, e é por
      -- isso que ele vem na saída em vez de ser assumido.
      AND fn_filtro_casa(v.categoria,    v_cat)
      AND fn_filtro_casa(v.fase,         v_fase)
      AND fn_filtro_casa(v.desfecho,     v_desfecho)
      AND fn_filtro_casa(v.record_type,  v_rt)
      AND fn_filtro_casa(v.moeda,        v_moeda)
      AND fn_filtro_casa(v.lead_source,  v_ls)
  ),
  tot AS (
    SELECT count(*) AS n,
           sum(amount_brl) FILTER (WHERE desfecho = 'ganha') AS receita
    FROM recorte
  ),
  agg_opp AS (
    SELECT
      r.segmento_aba                                                       AS seg,
      r.categoria                                                          AS cat,
      count(*)                                                             AS n,
      count(*) FILTER (WHERE r.desfecho = 'ganha')                         AS ganhas,
      count(*) FILTER (WHERE r.desfecho = 'perdida')                       AS perdidas,
      count(*) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase'))      AS nao_decididas,
      count(*) FILTER (WHERE r.desfecho IN ('ganha','perdida'))            AS decididas,
      sum(r.amount_brl) FILTER (WHERE r.desfecho = 'ganha')                AS receita,
      count(*) FILTER (WHERE r.desfecho = 'ganha' AND r.amount_brl IS NULL) AS ganhas_sem_valor,
      sum(r.amount_brl) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase')) AS pipeline,
      count(*) FILTER (WHERE r.lead_vinculo_regra IN ('oportunidade','conta'))           AS v_rastreadas,
      count(*) FILTER (WHERE r.lead_vinculo_regra IN ('leadsource','leadsource_desconhecido')) AS v_leadsource,
      count(*) FILTER (WHERE r.lead_vinculo_regra = 'lead_sem_classificacao')            AS v_sem_classe,
      count(*) FILTER (WHERE r.lead_vinculo_regra = 'sem_origem')                        AS v_sem_origem
    FROM recorte r
    -- GROUP BY com NULL: o PostgreSQL agrupa todos os NULL numa linha só, que é
    -- exatamente o desejado — UMA linha "sem categoria", nunca uma por
    -- oportunidade e nunca somada a outra categoria.
    GROUP BY r.segmento_aba, r.categoria
  ),
  leads_base AS (
    SELECT c.segmento                                        AS seg,
           c.categoria                                       AS cat,
           l.created_at_source                               AS criado_em,
           (l.converted_opportunity_id IS NOT NULL
            OR l.converted_account_id IS NOT NULL)           AS tem_opp
    FROM lead l
    JOIN lead_origin_classification c
      ON c.lead_id = l.id AND c.valid_to IS NULL
    WHERE NOT l.is_teste
      AND fn_filtro_casa(c.segmento,  v_seg)
      AND fn_filtro_casa(c.categoria, v_cat)
  ),
  agg_lead AS (
    SELECT
      b.seg, b.cat,
      count(*) FILTER (WHERE b.criado_em IS NOT NULL
                         AND (v_de  IS NULL OR b.criado_em >= v_de)
                         AND (v_ate IS NULL OR b.criado_em <  v_ate))               AS n,
      count(*) FILTER (WHERE b.criado_em IS NOT NULL
                         AND (v_de  IS NULL OR b.criado_em >= v_de)
                         AND (v_ate IS NULL OR b.criado_em <  v_ate)
                         AND b.tem_opp)                                              AS com_opp,
      count(*) FILTER (WHERE b.criado_em IS NULL
                         AND (v_de IS NOT NULL OR v_ate IS NOT NULL))                AS sem_data
    FROM leads_base b
    GROUP BY b.seg, b.cat
  ),
  tot_lead AS (SELECT coalesce(sum(n), 0)::bigint AS n FROM agg_lead),
  -- ── O CONJUNTO DE CHAVES: A UNIÃO DOS DOIS LADOS ─────────────────────────
  -- Aqui NÃO dá para usar FULL OUTER JOIN direto. A chave inclui `categoria`,
  -- que é NULL na linha de categoria ausente, e casar NULL com NULL exige
  -- `IS NOT DISTINCT FROM` — que o PostgreSQL recusa como condição de FULL
  -- JOIN ("FULL JOIN is only supported with merge-joinable or hash-joinable
  -- join conditions"). Usar `=` em vez disso faria a linha de categoria
  -- ausente aparecer DUPLICADA (uma vinda de cada lado) no dia em que o lado
  -- do lead tiver categoria nula — a coluna é nullable no schema, mesmo com
  -- 0 de 7.631 classificações vigentes nulas hoje.
  --
  -- A saída é a mesma de um FULL OUTER JOIN, montada com UNION (que trata
  -- NULL como igual para deduplicar) + dois LEFT JOIN, onde
  -- `IS NOT DISTINCT FROM` é permitido.
  chaves AS (
    SELECT seg, cat FROM agg_opp
    UNION
    SELECT seg, cat FROM agg_lead
  )
  SELECT
    k.seg,
    k.cat,
    coalesce(k.cat, '(sem categoria — origem não classificada)'),
    coalesce(o.n, 0),
    round(100.0 * coalesce(o.n, 0) / nullif(t.n, 0), 2),
    coalesce(o.ganhas, 0),
    coalesce(o.perdidas, 0),
    coalesce(o.nao_decididas, 0),
    coalesce(o.decididas, 0),
    round(100.0 * o.ganhas / nullif(o.decididas, 0), 2),
    o.receita,
    round(100.0 * o.receita / nullif(t.receita, 0), 2),
    coalesce(o.ganhas_sem_valor, 0),
    o.pipeline,
    coalesce(o.v_rastreadas, 0),
    coalesce(o.v_leadsource, 0),
    coalesce(o.v_sem_classe, 0),
    coalesce(o.v_sem_origem, 0),
    (coalesce(o.v_rastreadas,0) + coalesce(o.v_leadsource,0)
     + coalesce(o.v_sem_classe,0) + coalesce(o.v_sem_origem,0)) = coalesce(o.n, 0),
    coalesce(a.n, 0),
    coalesce(a.com_opp, 0),
    coalesce(a.sem_data, 0),
    t.n,
    t.receita,
    tl.n,
    -- `o.n`/`a.n` são count(*): nunca nulos DENTRO de uma linha existente.
    -- Nulo aqui só pode significar "este lado não tem esta chave", que é
    -- exatamente o que a coluna declara.
    CASE WHEN o.n IS NOT NULL AND a.n IS NOT NULL THEN 'ambos'
         WHEN o.n IS NOT NULL                     THEN 'so_oportunidade'
         ELSE                                          'so_lead' END,
    v_ignorados
  FROM chaves k
  LEFT JOIN agg_opp  o ON o.seg IS NOT DISTINCT FROM k.seg
                      AND o.cat IS NOT DISTINCT FROM k.cat
  LEFT JOIN agg_lead a ON a.seg IS NOT DISTINCT FROM k.seg
                      AND a.cat IS NOT DISTINCT FROM k.cat
  CROSS JOIN tot t
  CROSS JOIN tot_lead tl
  ORDER BY coalesce(o.n, 0) DESC, coalesce(a.n, 0) DESC,
           k.seg, k.cat NULLS LAST;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_por_categoria(jsonb) IS
  'CATEGORIA DA ABA OPORTUNIDADES (Evento/Webinar, Paid Social, Inbound Web, Outbound SDR/Vendas, ...). GRÃO: UMA LINHA POR PAR (segmento_aba, categoria) — medido em 2026-09-16 nenhuma categoria aparece sob dois segmentos, mas a chave é o par para que uma regra futura não funda duas linhas em silêncio. CATEGORIA NULL É LINHA PRÓPRIA E DECLARADA (categoria_rotulo = "(sem categoria — origem não classificada)"): são as oportunidades cujo segmento_aba é NaoClassificado ou SemOrigem, 797 na janela de 12 meses. Somá-las a uma categoria existente é o mecanismo exato que produziu o "100% atribuído a marketing" da aba antiga. Como fn_oportunidades_por_segmento, traz o lado do LEAD ao lado (qtd_leads_gerados / qtd_leads_com_oportunidade) e 🚫 NÃO oferece taxa lead→oportunidade: as duas populações são atribuídas por caminhos diferentes e se cruzam pouco (ver o COMMENT de fn_oportunidades_por_segmento). Filtros: de, ate, segmento, categoria, fase, desfecho, record_type, moeda, lead_source. segmento e categoria valem para os dois lados; os outros cinco só para a oportunidade e aparecem em leads_filtros_ignorados. ⚠️ filtrar por categoria remove a linha de categoria ausente (fn_filtro_casa não casa NULL com filtro presente) e total_do_recorte encolhe junto — por isso ele vem na saída. Migration 103.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_por_categoria(jsonb) TO crm_ingest;

COMMIT;
