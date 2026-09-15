-- db/migrations/087_busca_pessoas_pivo_campanha.sql
--
-- O PIVÔ CAMPANHA→LEADS ESTAVA MORTO. Esta migration é o que o ressuscita.
--
-- Quando a aba Leads passou a consumir `fn_search_pessoas` (migration 084), o
-- filtro `campanha` não veio junto. O cliente contornou mandando a campanha no
-- parâmetro `busca` -- e `busca` casa contra NOME, EMPRESA e E-MAIL, nunca
-- contra campanha. Resultado medido: clicar em "ver leads desta campanha"
-- devolvia ZERO linhas para qualquer campanha da base. O pivô não estava
-- degradado, estava morto, e a tela dizia "nenhum lead encontrado" como se
-- fosse resposta legítima.
--
-- POR QUE DOIS CAMPOS COM OR, E NÃO UM SÓ
--
-- A migration 054 já registrou este erro uma vez: `campanha`,
-- `origem_conversao` e `campanha_midia` são TRÊS coisas distintas, e tratar
-- uma como apelido da outra fez o pivô devolver vazio. Aqui o pivô precisa
-- achar a pessoa por qualquer um dos dois sinais que carregam nome de
-- campanha, porque eles cobrem populações diferentes -- medido em
-- 2026-09-15 sobre view_pessoa_jornada_desfecho (6.844 pessoas):
--
--   origens_conversao IS NOT NULL ......... 491 pessoas
--   utm_campaign      IS NOT NULL ......... 107 pessoas
--   utm_campaign também presente em origens_conversao ..... 65 pessoas
--
-- Ou seja: 42 pessoas só são alcançáveis pelo lado utm_campaign, e a maior
-- parte das 491 só pelo lado origens_conversao. Por campanha a divergência
-- fica explícita:
--
--   [SB]+CAMPANHA_WEBINAR ....... 0 por origens_conversao, 13 por utm_campaign
--   GOTO_GERAL_LEADS_2601 ....... 6 por origens_conversao,  5 por utm_campaign
--   Webinar-GoTo-07-26 .......... 86 por origens_conversao, 0 por utm_campaign
--
-- Escolher um lado só perde leads reais em silêncio, nos dois sentidos. Por
-- isso o predicado é OR entre os dois campos, e os dois CONTINUAM existindo
-- como filtros independentes: `origem_conversao` (eixo A) e `plataforma`
-- (eixo B) não foram tocados. `campanha` é um filtro de PIVÔ, que atravessa
-- os dois eixos de propósito -- não é apelido de nenhum deles.
--
-- GRÃO: no grão de PESSOA a origem de conversão é um ARRAY
-- (`origens_conversao`), não o escalar `valor_bruto` de `fn_search_leads` v3.
-- Uma pessoa tem N conversões; casar contra o array é o equivalente exato do
-- match escalar que o pivô tinha no grão de registro.
--
-- OS TRÊS LUGARES: o predicado entra no CTE `filtrado` (que produz
-- `total_filtrado`), no bloco de ocultos por lista importada e no RETURN QUERY.
-- Aplicar em dois e esquecer o terceiro faria o rodapé "N de M" mentir -- que é
-- exatamente o defeito que esta função existe para não ter (ver 084).
--
-- Sem mudança de assinatura nem de RETURNS TABLE: CREATE OR REPLACE basta, e
-- preserva GRANT e COMMENT existentes (reemitidos abaixo por idempotência).

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
  source_id_ficha        text,
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
  -- Filtro de PIVO (migration 087). Distinto de v_origem e de v_plataforma:
  -- atravessa os dois eixos porque o nome de campanha aparece nos dois.
  v_campanha   text    := nullif(p_filtros->>'campanha', '');
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
      AND (v_campanha   IS NULL
           OR v.origens_conversao @> ARRAY[v_campanha]
           OR v.utm_campaign = v_campanha)
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
      AND (v_categoria IS NULL OR v.categoria = v_categoria)
      AND (v_campanha  IS NULL
           OR v.origens_conversao @> ARRAY[v_campanha]
           OR v.utm_campaign = v_campanha);
  END IF;

  RETURN QUERY
  SELECT
    v.pessoa_chave, v.nome, v.empresa, v.fontes, v.rd_lead_id, v.sf_lead_id, v.source_id_ficha,
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
    AND (v_campanha   IS NULL
         OR v.origens_conversao @> ARRAY[v_campanha]
         OR v.utm_campaign = v_campanha)
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
  'Busca por PESSOA (view_pessoa_jornada_desfecho) com busca textual em nome/empresa/e-mail, filtros e paginacao real. Devolve `total_filtrado` na MESMA chamada, sobre o mesmo predicado -- total calculado a parte foi como o dashboard antigo produzia numero que nao batia com a lista. `total_ocultos_lista` diz quantos a regra de lista importada tirou de cena, porque exclusao silenciosa e proibida (contrato §1.6). v2 (migration 087): filtro `campanha` de primeira classe, que casa contra origens_conversao OU utm_campaign -- e o que sustenta o pivo campanha->leads (AC-4.1). NAO e apelido de `origem_conversao` nem de `plataforma`, que seguem independentes (mesmo erro que a migration 054 corrigiu). Ver migrations 084 e 087.';

GRANT EXECUTE ON FUNCTION fn_search_pessoas(jsonb, integer, integer) TO crm_ingest;
