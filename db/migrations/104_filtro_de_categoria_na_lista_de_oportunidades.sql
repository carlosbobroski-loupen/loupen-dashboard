-- db/migrations/104_filtro_de_categoria_na_lista_de_oportunidades.sql
--
-- A LISTA DE DETALHE NÃO CONSEGUE RESPONDER "QUAIS SÃO ESSAS 33 DE EVENTO?"
--
-- A migration 103 fez a aba mostrar `categoria` — e com ela a linha que o dono
-- do produto pediu: `Marketing / Evento/Webinar`, 33 oportunidades na janela de
-- 12 meses. O passo seguinte da tela é clicar nessa linha e ver QUAIS são.
--
-- VERIFICADO ANTES DE ESCREVER, não assumido. O corpo vivo de
-- `fn_search_oportunidades` (migration 098, atualizada pela 100) foi lido do
-- catálogo em 2026-09-16. Ela já PROJETA `categoria`, `detalhe` e
-- `origem_sinal_id` na saída — a 100 acrescentou as três — e aceita nove
-- filtros: de, ate, busca, segmento, fase, desfecho, record_type, moeda,
-- lead_vinculo_regra, lead_source, mais os três interruptores de auditoria
-- (so_divergentes, so_sem_valor, so_nao_classificado) e ordenar_por.
--
-- `categoria` NÃO está entre eles. É a única coisa que falta, e é o que esta
-- migration acrescenta. Nada mais muda: mesma saída, mesma ordenação, mesmo
-- contrato de paginação.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE ACONTECE COM A LINHA DE CATEGORIA AUSENTE, DECLARADO
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `fn_filtro_casa` devolve false para valor NULL sempre que há filtro presente
-- — está no COMMENT dela desde a 097, e é de propósito. Consequência aqui: a
-- tela NÃO consegue pedir "me mostre as sem categoria" passando
-- `categoria: null` (isso é interpretado como "sem restrição", pela mesma
-- regra). O caminho para essas 792 oportunidades já existe e continua sendo
-- `so_nao_classificado: true`, que é o interruptor escrito para isso.
--
-- Inventar aqui um `categoria: "__sem_categoria__"` criaria um valor mágico que
-- não existe em lugar nenhum do vocabulário — o tipo de coisa que funciona na
-- demo e some numa refatoração. Duas portas para o mesmo conjunto, uma delas
-- inventada, é pior do que uma porta declarada.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE ESTA MIGRATION NÃO TOCA
-- ═════════════════════════════════════════════════════════════════════════════
-- Nada além do corpo de `fn_search_oportunidades`. `fn_run_ingest_batch` fica
-- intocada (regra do db/README.md). Nenhum DDL de tabela, nenhuma linha
-- apagada, nenhuma permissão alterada.
--
-- `CREATE OR REPLACE` e não `DROP` + `CREATE`: o RETURNS TABLE é idêntico ao da
-- 100, coluna por coluna, então o tipo de retorno não muda. Mas o
-- `SET plan_cache_mode TO 'force_custom_plan'` É REESCRITO abaixo mesmo assim:
-- `CREATE OR REPLACE FUNCTION` substitui as cláusulas SET pelas que o novo
-- comando declarar, e omiti-las apagaria o ALTER da 098. Sem ele, os agora
-- ONZE filtros opcionais na forma `($n IS NULL OR col = $n)` fazem o
-- planejador multiplicar seletividades default, estimar rows=1 e escolher
-- nested loop — 800x de degradação medidos neste banco na migration 089
-- (259 ms → 207 s em `fn_search_pessoas`).

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_search_oportunidades(
  p_filtros jsonb    DEFAULT '{}'::jsonb,
  p_limit   integer  DEFAULT 50,
  p_offset  integer  DEFAULT 0
)
RETURNS TABLE (
  opportunity_id                  bigint,
  source_id                       text,
  conta_id                        bigint,
  conta_nome                      text,
  record_type                     text,
  estagio                         text,
  fase                            text,
  fase_ordem                      integer,
  desfecho                        text,
  desfecho_motivo                 text,
  divergencia_origem_vs_fase      text,
  criada_em                       timestamptz,
  close_date_origem               timestamptz,
  dias_entre_criacao_e_close_date numeric,
  close_date_antes_da_criacao     boolean,
  amount                          numeric,
  moeda                           text,
  amount_brl                      numeric,
  conversao_indisponivel_motivo   text,
  mrr                             numeric,
  duracao_meses_contrato          integer,
  lead_id                         bigint,
  lead_salesforce_id              text,
  lead_nome                       text,
  lead_source                     text,
  lead_vinculo_regra              text,
  qtd_leads_candidatos            bigint,
  segmento_aba                    text,
  categoria                       text,
  detalhe                         text,
  origem_sinal_id                 text,
  total_filtrado                  bigint
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de        timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate       timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_busca     text  := nullif(trim(p_filtros->>'busca'), '');
  v_seg       jsonb := p_filtros->'segmento';
  v_cat       jsonb := p_filtros->'categoria';   -- migration 104
  v_fase      jsonb := p_filtros->'fase';
  v_desfecho  jsonb := p_filtros->'desfecho';
  v_rt        jsonb := p_filtros->'record_type';
  v_moeda     jsonb := p_filtros->'moeda';
  v_vinculo   jsonb := p_filtros->'lead_vinculo_regra';
  v_ls        jsonb := p_filtros->'lead_source';   -- migration 100
  -- Interruptores de AUDITORIA, não de negócio. Existem para responder "me
  -- mostre as ganhas que não entraram na receita" e "quais são as que ninguém
  -- classificou" sem que alguém escreva SQL à mão e erre o predicado.
  v_so_divergentes boolean := coalesce((p_filtros->>'so_divergentes')::boolean, false);
  v_so_sem_valor   boolean := coalesce((p_filtros->>'so_sem_valor')::boolean, false);
  v_so_nao_class   boolean := coalesce((p_filtros->>'so_nao_classificado')::boolean, false);
  v_ordem     text  := coalesce(nullif(p_filtros->>'ordenar_por', ''), 'recentes');
  v_total     bigint;
BEGIN
  IF v_ordem NOT IN ('recentes', 'valor', 'fase') THEN
    RAISE EXCEPTION 'ordenar_por inválido: "%". Aceitos: recentes, valor, fase.', v_ordem
      USING HINT = 'Cair num ORDER BY padrão em silêncio faria a tela mostrar uma ordem que ninguém pediu.';
  END IF;

  SELECT count(*) INTO v_total
  FROM view_oportunidade_analitica v
  WHERE (v_de  IS NULL OR v.criada_em >= v_de)
    AND (v_ate IS NULL OR v.criada_em <  v_ate)
    AND fn_filtro_casa(v.segmento_aba,       v_seg)
    AND fn_filtro_casa(v.categoria,          v_cat)
    AND fn_filtro_casa(v.fase,               v_fase)
    AND fn_filtro_casa(v.desfecho,           v_desfecho)
    AND fn_filtro_casa(v.record_type,        v_rt)
    AND fn_filtro_casa(v.moeda,              v_moeda)
    AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
    AND fn_filtro_casa(v.lead_source,        v_ls)
    AND (NOT v_so_divergentes OR v.divergencia_origem_vs_fase IS NOT NULL)
    AND (NOT v_so_sem_valor   OR v.amount_brl IS NULL)
    AND (NOT v_so_nao_class   OR v.segmento_aba IN ('NaoClassificado','SemOrigem'))
    AND (v_busca IS NULL
         OR v.conta_nome  ILIKE '%' || v_busca || '%'
         OR v.lead_nome   ILIKE '%' || v_busca || '%'
         OR v.lead_source ILIKE '%' || v_busca || '%'
         OR v.source_id   =  v_busca);

  RETURN QUERY
  SELECT
    v.opportunity_id, v.source_id, v.conta_id, v.conta_nome, v.record_type,
    v.estagio, v.fase, v.fase_ordem,
    v.desfecho, v.desfecho_motivo, v.divergencia_origem_vs_fase,
    v.criada_em, v.close_date_origem, v.dias_entre_criacao_e_close_date,
    v.close_date_antes_da_criacao,
    v.amount, v.moeda, v.amount_brl, v.conversao_indisponivel_motivo,
    v.mrr, v.duracao_meses_contrato,
    v.lead_id, v.lead_salesforce_id, v.lead_nome,
    v.lead_source, v.lead_vinculo_regra, v.qtd_leads_candidatos,
    v.segmento_aba, v.categoria, v.detalhe, v.origem_sinal_id,
    v_total
  FROM view_oportunidade_analitica v
  -- O MESMO conjunto de predicados da contagem acima, na mesma ordem. Se os
  -- dois blocos divergirem, `total_filtrado` passa a contar um universo e a
  -- página a mostrar outro — e a tela exibe "1 a 50 de 5.407" sobre uma lista
  -- que tem 33 linhas, sem erro nenhum em lugar nenhum.
  WHERE (v_de  IS NULL OR v.criada_em >= v_de)
    AND (v_ate IS NULL OR v.criada_em <  v_ate)
    AND fn_filtro_casa(v.segmento_aba,       v_seg)
    AND fn_filtro_casa(v.categoria,          v_cat)
    AND fn_filtro_casa(v.fase,               v_fase)
    AND fn_filtro_casa(v.desfecho,           v_desfecho)
    AND fn_filtro_casa(v.record_type,        v_rt)
    AND fn_filtro_casa(v.moeda,              v_moeda)
    AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
    AND fn_filtro_casa(v.lead_source,        v_ls)
    AND (NOT v_so_divergentes OR v.divergencia_origem_vs_fase IS NOT NULL)
    AND (NOT v_so_sem_valor   OR v.amount_brl IS NULL)
    AND (NOT v_so_nao_class   OR v.segmento_aba IN ('NaoClassificado','SemOrigem'))
    AND (v_busca IS NULL
         OR v.conta_nome  ILIKE '%' || v_busca || '%'
         OR v.lead_nome   ILIKE '%' || v_busca || '%'
         OR v.lead_source ILIKE '%' || v_busca || '%'
         OR v.source_id   =  v_busca)
  ORDER BY
    -- NULLS LAST em TODAS as chaves: sem isto, ordenar por valor traria as 838
    -- sem `amount` na frente de todas as vendas, porque em PostgreSQL
    -- `ORDER BY x DESC` põe NULL PRIMEIRO.
    CASE WHEN v_ordem = 'valor'    THEN v.amount_brl END  DESC NULLS LAST,
    CASE WHEN v_ordem = 'fase'     THEN v.fase_ordem END  DESC NULLS LAST,
    CASE WHEN v_ordem = 'recentes' THEN v.criada_em  END  DESC NULLS LAST,
    v.criada_em DESC NULLS LAST,
    -- Desempate final determinístico: sem ele, duas chamadas com o mesmo
    -- OFFSET podem devolver a mesma linha duas vezes e pular outra.
    v.opportunity_id DESC
  LIMIT  greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$function$;

COMMENT ON FUNCTION public.fn_search_oportunidades(jsonb, integer, integer) IS
  'A LISTA DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR OPORTUNIDADE, paginada. total_filtrado é o tamanho do conjunto INTEIRO depois dos filtros (não da página) e é calculado com EXATAMENTE os mesmos predicados da página. Filtros: de, ate, busca, segmento, categoria (migration 104), fase, desfecho, record_type, moeda, lead_vinculo_regra, lead_source. Interruptores de auditoria: so_divergentes, so_sem_valor, so_nao_classificado. Ordenação: recentes | valor | fase — valor inválido levanta exceção em vez de cair num padrão silencioso. ⚠️ filtrar por categoria NÃO alcança as oportunidades de categoria NULL (fn_filtro_casa não casa NULL com filtro presente, de propósito): para essas 792 da janela de 12 meses o caminho é so_nao_classificado=true. Migrations 098 + 100 + 104.';

GRANT EXECUTE ON FUNCTION public.fn_search_oportunidades(jsonb, integer, integer) TO crm_ingest;

COMMIT;
