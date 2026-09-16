-- db/migrations/098_lista_da_aba_oportunidades.sql
--
-- A LISTA QUE FICA EMBAIXO DOS CARDS, COM O MESMO RECORTE DOS CARDS.
--
-- A migration 097 entregou os agregados (`fn_oportunidades_cards`,
-- `fn_oportunidades_funil`, `fn_oportunidades_por_segmento`). Falta a lista:
-- o usuário que lê "987 ganhas" precisa poder clicar e ver QUAIS.
--
-- POR QUE UMA FUNÇÃO SEPARADA, E NÃO UM SELECT DIRETO NA VIEW:
--
--   1. O PREDICADO TEM DE SER O MESMO. Se o endpoint da lista montar o WHERE
--      em JavaScript e o dos cards vier de `fn_oportunidades_cards`, os dois
--      divergem no primeiro filtro novo que alguém acrescentar, e a tela passa
--      a dizer "987 ganhas" em cima de uma lista com 984. Aqui o predicado é
--      literalmente o mesmo texto, no mesmo lugar, e o `total_filtrado` vem
--      calculado sob ele -- não é `count()` do array que o front recebeu.
--
--   2. `plan_cache_mode = 'force_custom_plan'`. Este é o objeto com MAIS
--      filtros opcionais da camada (nove). É exatamente a forma que degradou
--      `fn_search_pessoas` de 259 ms para 207 s neste banco (migration 089):
--      com `($n IS NULL OR col = $n)` e sem o valor em tempo de planejamento,
--      o planejador multiplica nove seletividades default, estima `rows=1` dos
--      dois lados de cada join e escolhe nested loop. Um SELECT solto na view,
--      vindo do PgBouncer como prepared statement, cairia na mesma armadilha
--      a partir da quinta execução -- e só o backend quente da role do n8n
--      mostraria o defeito, o que faz ele parecer intermitente.
--
-- ⚠️ `total_filtrado` REPETE O PREDICADO em vez de usar `count(*) OVER ()`. A
-- window function contaria só as linhas que sobrevivem ao LIMIT em alguns
-- planos, e o número que sustenta a paginação não pode depender do plano
-- escolhido. É a mesma dívida consciente registrada na migration 089: duas
-- avaliações do predicado, ~2x o custo, em troca de um total que não mente.
--
-- ORDENAÇÃO: `NULLS LAST` é EXPLÍCITO em todas as chaves. Em PostgreSQL
-- `ORDER BY x DESC` põe NULL PRIMEIRO, e neste épico uma verificação passou em
-- branco exatamente assim -- comparou a primeira linha de um ORDER BY DESC, que
-- era NULL, contra outro NULL, e declarou verde. Aqui isso encheria a primeira
-- página com as 838 oportunidades sem `amount` sempre que alguém ordenasse por
-- valor.
--
-- NÃO cria tabela, não apaga linha, não mexe em permissão de role além do
-- GRANT EXECUTE do objeto novo.

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
  lead_source_id                  text,
  lead_nome                       text,
  lead_vinculo_regra              text,
  qtd_leads_candidatos            bigint,
  segmento_aba                    text,
  categoria                       text,
  detalhe                         text,
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
  v_fase      jsonb := p_filtros->'fase';
  v_desfecho  jsonb := p_filtros->'desfecho';
  v_rt        jsonb := p_filtros->'record_type';
  v_moeda     jsonb := p_filtros->'moeda';
  v_vinculo   jsonb := p_filtros->'lead_vinculo_regra';
  -- Dois interruptores de AUDITORIA, não de negócio. Existem para responder
  -- "me mostre as ganhas que não entraram na receita" sem que alguém tenha de
  -- escrever SQL à mão e errar o predicado.
  v_so_divergentes boolean := coalesce((p_filtros->>'so_divergentes')::boolean, false);
  v_so_sem_valor   boolean := coalesce((p_filtros->>'so_sem_valor')::boolean, false);
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
    AND fn_filtro_casa(v.fase,               v_fase)
    AND fn_filtro_casa(v.desfecho,           v_desfecho)
    AND fn_filtro_casa(v.record_type,        v_rt)
    AND fn_filtro_casa(v.moeda,              v_moeda)
    AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
    AND (NOT v_so_divergentes OR v.divergencia_origem_vs_fase IS NOT NULL)
    AND (NOT v_so_sem_valor   OR v.amount_brl IS NULL)
    AND (v_busca IS NULL
         OR v.conta_nome ILIKE '%' || v_busca || '%'
         OR v.lead_nome  ILIKE '%' || v_busca || '%'
         OR v.source_id  =  v_busca);

  RETURN QUERY
  SELECT
    v.opportunity_id, v.source_id, v.conta_id, v.conta_nome, v.record_type,
    v.estagio, v.fase, v.fase_ordem,
    v.desfecho, v.desfecho_motivo, v.divergencia_origem_vs_fase,
    v.criada_em, v.close_date_origem, v.dias_entre_criacao_e_close_date,
    v.close_date_antes_da_criacao,
    v.amount, v.moeda, v.amount_brl, v.conversao_indisponivel_motivo,
    v.mrr, v.duracao_meses_contrato,
    v.lead_id, v.lead_source_id, v.lead_nome, v.lead_vinculo_regra,
    v.qtd_leads_candidatos,
    v.segmento_aba, v.categoria, v.detalhe,
    v_total
  FROM view_oportunidade_analitica v
  WHERE (v_de  IS NULL OR v.criada_em >= v_de)
    AND (v_ate IS NULL OR v.criada_em <  v_ate)
    AND fn_filtro_casa(v.segmento_aba,       v_seg)
    AND fn_filtro_casa(v.fase,               v_fase)
    AND fn_filtro_casa(v.desfecho,           v_desfecho)
    AND fn_filtro_casa(v.record_type,        v_rt)
    AND fn_filtro_casa(v.moeda,              v_moeda)
    AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
    AND (NOT v_so_divergentes OR v.divergencia_origem_vs_fase IS NOT NULL)
    AND (NOT v_so_sem_valor   OR v.amount_brl IS NULL)
    AND (v_busca IS NULL
         OR v.conta_nome ILIKE '%' || v_busca || '%'
         OR v.lead_nome  ILIKE '%' || v_busca || '%'
         OR v.source_id  =  v_busca)
  ORDER BY
    -- NULLS LAST em TODAS as chaves. Ver o cabeçalho: sem isto, ordenar por
    -- valor traria as 838 sem `amount` na frente de todas as vendas.
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
  'LISTA DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR OPORTUNIDADE (o mesmo de view_oportunidade_analitica). O predicado é IDÊNTICO ao de fn_oportunidades_cards para que a lista nunca contradiga o card que está acima dela; total_filtrado é recalculado sob o MESMO predicado (não é count do array paginado) e serve de paginação. Filtros: de/ate (`de` INCLUSIVO, `ate` EXCLUSIVO, sobre criada_em), busca (conta_nome, lead_nome ou source_id exato), segmento, fase, desfecho, record_type, moeda, lead_vinculo_regra, so_divergentes, so_sem_valor, ordenar_por (recentes|valor|fase — valor inválido levanta exceção em vez de cair num padrão em silêncio). Migration 098.';

GRANT EXECUTE ON FUNCTION public.fn_search_oportunidades(jsonb, integer, integer) TO crm_ingest;

COMMIT;
