-- db/migrations/084_fn_search_pessoas.sql
--
-- A busca por PESSOA -- o que a aba Leads passa a consumir.
--
-- Substitui, para a lista, o papel de `fn_search_leads`, que é por REGISTRO de
-- origem. Mantém a mesma convenção de assinatura (p_filtros jsonb, p_limit,
-- p_offset) para não inventar um segundo padrão de chamada.
--
-- TRÊS COISAS QUE A BUSCA ATUAL NÃO TEM, e que são a razão desta migration:
--
-- 1. BUSCA TEXTUAL. Não existe um único campo de busca no produto inteiro
--    (`grep -c 'type="search"' index.html` = 0). Foi por isso que o usuário
--    teve que filtrar por marketing e varrer a tabela com o olho para achar um
--    lead específico -- e saiu com a impressão de que a ficha não mostrava
--    nada, quando na verdade ele não chegou a abrir a ficha certa.
--
-- 2. TOTAL SEPARADO DA PÁGINA. `fn_search_leads` devolve as linhas e a tela
--    imprime "200 de 490" a partir de um total que vem de outro lugar. Aqui o
--    total vem na mesma chamada, sobre o MESMO filtro -- senão a paginação
--    mente quando o filtro muda.
--
-- 3. OFFSET DE VERDADE. Hoje a lista trava em 200 e não tem "carregar mais":
--    290 dos 490 leads são inalcançáveis pela interface.
--
-- FILTRO DE LISTA IMPORTADA: por padrão `incluir_lista` é FALSE. Os 318 leads
-- do sorteio contam como lead mas saem do denominador de qualquer taxa (regra
-- da migration 071). A tela DEVE dizer quantos ocultou -- por isso a função
-- devolve `total_ocultos_lista` junto, e não só o total filtrado. Exclusão
-- silenciosa é proibida neste projeto desde o contrato de dados §1.6.

-- DROP antes: mudar o RETURNS TABLE muda o tipo de retorno, e CREATE OR REPLACE
-- recusa. A funcao ainda nao tem consumidor em producao (o workflow chama por
-- nome, nao por assinatura), entao e seguro.
DROP FUNCTION IF EXISTS fn_search_pessoas(jsonb, integer, integer);

CREATE OR REPLACE FUNCTION fn_search_pessoas(
  p_filtros jsonb   DEFAULT '{}'::jsonb,
  p_limit   integer DEFAULT 50,
  p_offset  integer DEFAULT 0
)
RETURNS TABLE(
  pessoa_chave           text,
  nome                   text,
  empresa                text,
  fontes                 text[],
  rd_lead_id             bigint,
  sf_lead_id             bigint,
  segmento               text,
  categoria              text,
  detalhe                text,
  de_lista_importada     boolean,
  qtd_conversoes         bigint,
  origens_conversao      text[],
  primeira_conversao_em  timestamptz,
  ultima_conversao_em    timestamptz,
  plataforma             text,
  utm_campaign           text,
  id_anuncio             text,
  criativo               text,
  cargo                  text,
  tamanho_empresa        text,
  existe_no_salesforce   boolean,
  status_no_salesforce   text,
  qtd_oportunidades      bigint,
  teve_reuniao           boolean,
  chegou_a_negociar      boolean,
  qtd_ganhas             bigint,
  qtd_perdidas           bigint,
  fase_mais_avancada     text,
  fase_ordem             integer,
  estagio_mais_avancado  text,
  mrr_ganho              numeric,
  amount_ganho           numeric,
  trimestre              text,
  cargo_grupo            text,
  atendido_por           text,
  estagio_funil          text,
  tags                   text[],
  total_filtrado         bigint,
  total_ocultos_lista    bigint
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_busca      text    := nullif(trim(p_filtros->>'busca'), '');
  v_segmento   text    := nullif(p_filtros->>'segmento', '');
  v_categoria  text    := nullif(p_filtros->>'categoria', '');
  v_fase       text    := nullif(p_filtros->>'fase', '');
  v_plataforma text    := nullif(p_filtros->>'plataforma', '');
  v_incluir_lista boolean := coalesce((p_filtros->>'incluir_lista')::boolean, false);
  v_so_com_opp boolean := coalesce((p_filtros->>'so_com_oportunidade')::boolean, false);
  -- Dimensoes que a barra de filtros da aba Leads ja oferecia. Trocar a lista
  -- pela versao por pessoa SEM elas seria perder capacidade em silencio.
  v_trimestre  text    := nullif(p_filtros->>'trimestre', '');
  v_cargo      text    := nullif(p_filtros->>'cargo_grupo', '');
  v_atendido   text    := nullif(p_filtros->>'atendido_por', '');
  v_estagio    text    := nullif(p_filtros->>'estagio_funil', '');
  v_tag        text    := nullif(p_filtros->>'tag', '');
  v_tamanho    text    := nullif(p_filtros->>'tamanho_empresa', '');
  v_origem     text    := nullif(p_filtros->>'origem_conversao', '');
  v_total      bigint;
  v_ocultos    bigint;
BEGIN
  WITH filtrado AS (
    SELECT v.*
    FROM view_pessoa_jornada_desfecho v
    WHERE (v_busca IS NULL
           OR v.nome    ILIKE '%' || v_busca || '%'
           OR v.empresa ILIKE '%' || v_busca || '%'
           OR EXISTS (SELECT 1 FROM lead l
                      WHERE l.id IN (v.rd_lead_id, v.sf_lead_id)
                        AND l.email ILIKE '%' || v_busca || '%'))
      AND (v_segmento   IS NULL OR v.segmento   = v_segmento)
      AND (v_categoria  IS NULL OR v.categoria  = v_categoria)
      AND (v_plataforma IS NULL OR v.plataforma = v_plataforma)
      AND (v_fase       IS NULL OR v.fase_mais_avancada = v_fase)
      AND (NOT v_so_com_opp OR v.qtd_oportunidades > 0)
      AND (v_trimestre  IS NULL OR v.trimestre       = v_trimestre)
      AND (v_cargo      IS NULL OR v.cargo_grupo     = v_cargo)
      AND (v_atendido   IS NULL OR v.atendido_por    = v_atendido)
      AND (v_estagio    IS NULL OR v.estagio_funil   = v_estagio)
      AND (v_tamanho    IS NULL OR v.tamanho_empresa = v_tamanho)
      AND (v_tag        IS NULL OR v.tags @> ARRAY[v_tag])
      AND (v_origem     IS NULL OR v.origens_conversao @> ARRAY[v_origem])
      AND (v_incluir_lista OR NOT v.de_lista_importada)
  )
  SELECT count(*) INTO v_total FROM filtrado;

  -- Quantos a regra de lista importada tirou de cena, sob o MESMO filtro.
  IF v_incluir_lista THEN
    v_ocultos := 0;
  ELSE
    SELECT count(*) INTO v_ocultos
    FROM view_pessoa_jornada_desfecho v
    WHERE v.de_lista_importada
      AND (v_busca IS NULL
           OR v.nome ILIKE '%' || v_busca || '%'
           OR v.empresa ILIKE '%' || v_busca || '%')
      AND (v_segmento  IS NULL OR v.segmento  = v_segmento)
      AND (v_categoria IS NULL OR v.categoria = v_categoria);
  END IF;

  RETURN QUERY
  SELECT
    v.pessoa_chave, v.nome, v.empresa, v.fontes, v.rd_lead_id, v.sf_lead_id,
    v.segmento, v.categoria, v.detalhe, v.de_lista_importada,
    v.qtd_conversoes, v.origens_conversao, v.primeira_conversao_em, v.ultima_conversao_em,
    v.plataforma, v.utm_campaign, v.id_anuncio, v.criativo,
    v.cargo, v.tamanho_empresa,
    v.existe_no_salesforce, v.status_no_salesforce, v.qtd_oportunidades,
    v.teve_reuniao, v.chegou_a_negociar, v.qtd_ganhas, v.qtd_perdidas,
    v.fase_mais_avancada, v.fase_ordem, v.estagio_mais_avancado,
    v.mrr_ganho, v.amount_ganho,
    v.trimestre, v.cargo_grupo, v.atendido_por, v.estagio_funil, v.tags,
    v_total, v_ocultos
  FROM view_pessoa_jornada_desfecho v
  WHERE (v_busca IS NULL
         OR v.nome    ILIKE '%' || v_busca || '%'
         OR v.empresa ILIKE '%' || v_busca || '%'
         OR EXISTS (SELECT 1 FROM lead l
                    WHERE l.id IN (v.rd_lead_id, v.sf_lead_id)
                      AND l.email ILIKE '%' || v_busca || '%'))
    AND (v_segmento   IS NULL OR v.segmento   = v_segmento)
    AND (v_categoria  IS NULL OR v.categoria  = v_categoria)
    AND (v_plataforma IS NULL OR v.plataforma = v_plataforma)
    AND (v_fase       IS NULL OR v.fase_mais_avancada = v_fase)
    AND (NOT v_so_com_opp OR v.qtd_oportunidades > 0)
    AND (v_trimestre  IS NULL OR v.trimestre       = v_trimestre)
    AND (v_cargo      IS NULL OR v.cargo_grupo     = v_cargo)
    AND (v_atendido   IS NULL OR v.atendido_por    = v_atendido)
    AND (v_estagio    IS NULL OR v.estagio_funil   = v_estagio)
    AND (v_tamanho    IS NULL OR v.tamanho_empresa = v_tamanho)
    AND (v_tag        IS NULL OR v.tags @> ARRAY[v_tag])
    AND (v_origem     IS NULL OR v.origens_conversao @> ARRAY[v_origem])
    AND (v_incluir_lista OR NOT v.de_lista_importada)
  -- Ordem: quem foi mais longe no funil primeiro, depois quem tem jornada mais
  -- rica, depois o mais recente. O lead que virou negócio é o que se procura.
  ORDER BY v.fase_ordem DESC NULLS LAST,
           v.qtd_oportunidades DESC,
           v.qtd_conversoes DESC,
           v.ultima_conversao_em DESC NULLS LAST,
           v.primeiro_registro_em DESC NULLS LAST
  LIMIT greatest(p_limit, 1) OFFSET greatest(p_offset, 0);
END $$;

COMMENT ON FUNCTION fn_search_pessoas(jsonb, integer, integer) IS
  'Busca por PESSOA (view_pessoa_jornada_desfecho) com busca textual em nome/empresa/e-mail, filtros e paginacao real. Devolve `total_filtrado` na MESMA chamada, sobre o mesmo predicado -- total calculado a parte foi como o dashboard antigo produzia numero que nao batia com a lista. `total_ocultos_lista` diz quantos a regra de lista importada tirou de cena, porque exclusao silenciosa e proibida (contrato §1.6). Ver migration 084.';

GRANT EXECUTE ON FUNCTION fn_search_pessoas(jsonb, integer, integer) TO crm_ingest;
