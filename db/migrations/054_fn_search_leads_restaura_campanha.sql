-- db/migrations/054_fn_search_leads_restaura_campanha.sql
-- Subtask 8.11 — RESTAURA um filtro que eu removi por engano na 051.
--
-- O QUE EU QUEBREI
-- fn_search_leads v1 (migration 038) tinha um filtro `campanha`, que casava
-- contra `lead_origin_classification.valor_bruto` — o valor bruto do sinal de
-- atribuição. É o que sustenta o pivô campanha→leads da interface (subtask
-- 5.11, AC-4.1): clicar numa campanha e ver os leads dela, com caminho de
-- volta.
--
-- Ao escrever a v2 eu listei as 13 dimensões novas e simplesmente não
-- recoloquei `campanha`. Pior: no cliente eu tratei `campanha` como APELIDO
-- de `campanha_midia`, que é o eixo B (UTM de mídia paga). São coisas
-- diferentes — `valor_bruto` é o sinal de atribuição, presente em qualquer
-- lead classificado; `utm_campaign` é veiculação paga, presente em 7,6%.
-- Confundi-los faria o pivô devolver vazio quase sempre.
--
-- COMO FOI PEGO
-- Pela suíte Playwright: 4 specs falharam, todos os quatro sobre o filtro de
-- campanha. Se eu tivesse aceitado a quebra dos specs como "efeito esperado
-- do cutover" — que foi a minha primeira leitura —, a regressão teria
-- passado. Os testes existiam justamente para isso.
--
-- TRÊS CONCEITOS QUE AGORA CONVIVEM SEM SE MISTURAR
--   campanha         valor_bruto do sinal de atribuição (o pivô da interface)
--   origem_conversao eixo A — ativo/oferta que converteu (100% de cobertura)
--   campanha_midia   eixo B — veiculação paga, ÚNICA que recebe investimento
--
-- Os três são filtros independentes e combináveis por interseção.

CREATE OR REPLACE FUNCTION fn_search_leads(
  p_filtros jsonb DEFAULT '{}'::jsonb,
  p_limit   integer DEFAULT 50,
  p_offset  integer DEFAULT 0
)
RETURNS TABLE (
  lead_id                   bigint,
  source_id                 text,
  nome                      text,
  empresa                   text,
  estagio_funil             text,
  segmento                  text,
  categoria                 text,
  valor_bruto               text,
  created_at_source         timestamptz,
  data_conversao            timestamptz,
  trimestre                 text,
  origem_conversao          text,
  origem_ultima_conversao   text,
  qtd_conversoes            bigint,
  tags                      text[],
  cargo                     text,
  cargo_grupo               text,
  tamanho_empresa           text,
  atendido_por              text,
  campanha_midia            text,
  plataforma                text,
  is_teste                  boolean,
  fonte_dados               text,
  total_count               bigint
) AS $$
DECLARE
  v_tags          jsonb := p_filtros->'tags';
  v_incluir_teste boolean := COALESCE((p_filtros->>'incluir_teste')::boolean, false);
  v_ini           timestamptz := NULLIF(p_filtros->>'periodo_inicio','')::timestamptz;
  v_fim           timestamptz := NULLIF(p_filtros->>'periodo_fim','')::timestamptz;
BEGIN
  RETURN QUERY
  SELECT
    v.lead_id, v.source_id, v.nome, v.empresa, v.estagio_funil,
    v.segmento, v.categoria, v.valor_bruto,
    v.data_criacao, v.data_conversao, v.trimestre,
    v.origem_primeira_conversao, v.origem_ultima_conversao,
    v.qtd_conversoes, v.tags,
    v.cargo, v.cargo_grupo, v.tamanho_empresa, v.atendido_por,
    v.campanha_midia, v.plataforma,
    v.is_teste, v.fonte_dados,
    count(*) OVER () AS total_count
  FROM view_lead_perfil v
  WHERE
    (v_incluir_teste OR NOT v.is_teste)

    AND fn_filtro_casa(v.segmento,        p_filtros->'segmento')
    AND fn_filtro_casa(v.estagio_funil,   p_filtros->'estagio_funil')
    AND fn_filtro_casa(v.cargo_grupo,     p_filtros->'cargo_grupo')
    AND fn_filtro_casa(v.tamanho_empresa, p_filtros->'tamanho_empresa')
    AND fn_filtro_casa(v.atendido_por,    p_filtros->'atendido_por')
    AND fn_filtro_casa(v.plataforma,      p_filtros->'plataforma')
    AND fn_filtro_casa(v.campanha_midia,  p_filtros->'campanha_midia')
    AND fn_filtro_casa(v.trimestre,       p_filtros->'trimestre')

    -- RESTAURADO (v3): match exato contra valor_bruto da classificação
    -- corrente. Sustenta o pivô campanha→leads (AC-4.1). NÃO é o mesmo que
    -- campanha_midia acima — ver cabeçalho.
    AND fn_filtro_casa(v.valor_bruto,     p_filtros->'campanha')

    AND (
      p_filtros->'origem_conversao' IS NULL
      OR jsonb_typeof(p_filtros->'origem_conversao') = 'null'
      OR EXISTS (
        SELECT 1 FROM unnest(v.origens_conversao) AS o(valor)
        WHERE fn_filtro_casa(o.valor, p_filtros->'origem_conversao')
      )
    )

    AND (
      v_tags IS NULL OR jsonb_typeof(v_tags) = 'null'
      OR jsonb_array_length(v_tags) = 0
      OR v.tags && ARRAY(SELECT jsonb_array_elements_text(v_tags))
    )

    AND (v_ini IS NULL OR v.data_conversao >= v_ini)
    AND (v_fim IS NULL OR v.data_conversao <= v_fim)

  ORDER BY v.data_conversao DESC NULLS LAST, v.lead_id DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_search_leads(jsonb, integer, integer) IS
  'v3 (migration 054): restaura o filtro `campanha` (valor_bruto da classificação de atribuição) que a v2 removeu por engano — é o que sustenta o pivô campanha→leads (AC-4.1), e é DISTINTO de campanha_midia (eixo B, UTM de mídia paga) e de origem_conversao (eixo A). Os três convivem como filtros independentes e combináveis por interseção.';
