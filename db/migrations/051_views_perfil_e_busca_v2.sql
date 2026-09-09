-- db/migrations/051_views_perfil_e_busca_v2.sql
-- Subtask 8.8 — a camada de leitura que os filtros novos do contrato exigem.
--
-- TRÊS OBJETOS, COM PAPÉIS SEPARADOS DE PROPÓSITO
--
--   view_lead_perfil    um registro por LEAD. Serve a lista e a ficha.
--   view_campanha_lead  um registro por (origem, LEAD). Serve a visão por
--                       campanha, cujo grão é diferente (§1.7).
--   fn_search_leads v2  os 13 filtros combináveis, por interseção (AC-1.1).
--
-- POR QUE DUAS VIEWS E NÃO UMA
-- O grão de contagem depende da visão (data-contract.md §1.7, decisão do
-- usuário): na visão geral um lead conta UMA vez; na visão por campanha ele
-- conta em CADA campanha em que converteu. São perguntas diferentes e não
-- cabem no mesmo registro sem que alguém, em algum momento, some a coluna
-- errada. Separar em duas views torna o erro difícil de cometer: quem lê
-- view_campanha_lead sabe que está num grão multiplicado, porque o nome diz.
--
-- POR QUE cargo_grupo E tamanho_empresa SÃO DERIVADOS AQUI
-- São funções puras sobre tabela de regra. Materializá-los numa coluna
-- ficaria obsoleto no instante em que uma regra nova entrasse — e regra nova
-- é exatamente o que a migration 050 acabou de fazer (14 delas, tiradas dos
-- 31 valores reais). Derivar na view garante que a próxima regra vale
-- retroativamente, sem reprocessar ingestão.

-- ---------------------------------------------------------------------------
-- Helper de filtro: aceita ausência, array (OR interno = multi-select) ou
-- string única. Extraído porque o mesmo padrão aparece em 8 dimensões, e
-- repeti-lo 8 vezes é como um bug de uma delas passa despercebido.
--
-- Um lead com o campo NULL NÃO casa com um filtro presente: `NULL = ANY(...)`
-- é NULL, que o WHERE trata como falso. É o comportamento certo — filtrar por
-- cargo não deve trazer quem não tem cargo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_filtro_casa(p_valor text, p_filtro jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_filtro IS NULL
      OR jsonb_typeof(p_filtro) = 'null'
      OR (jsonb_typeof(p_filtro) = 'array'
          AND (jsonb_array_length(p_filtro) = 0
               OR p_valor = ANY (SELECT jsonb_array_elements_text(p_filtro))))
      OR (jsonb_typeof(p_filtro) = 'string' AND p_valor = (p_filtro #>> '{}'));
$$;
COMMENT ON FUNCTION fn_filtro_casa(text, jsonb) IS
  'Casa um valor escalar contra um filtro jsonb que pode ser ausente, array (OR interno, multi-select) ou string. Ausência = sem restrição. Valor NULL nunca casa com filtro presente, de propósito.';

-- ---------------------------------------------------------------------------
-- view_lead_perfil — um registro por lead
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW view_lead_perfil AS
SELECT *,
       -- Trimestre calculado sobre data_conversao (a data que o negócio usa
       -- para "leads do trimestre"), com fallback para a criação do lead
       -- quando ele não tem nenhuma conversão registrada.
       to_char(data_conversao, 'YYYY') || '-Q' || to_char(data_conversao, 'Q') AS trimestre
FROM (
  WITH conv AS (
    SELECT e.lead_id,
           count(*)                                       AS qtd_conversoes,
           count(DISTINCT e.origem_conversao)             AS qtd_origens,
           min(e.occurred_at)                             AS primeira_conversao_at,
           max(e.occurred_at)                             AS ultima_conversao_at,
           array_agg(DISTINCT e.origem_conversao)         AS origens_conversao
    FROM lead_conversion_event e
    GROUP BY e.lead_id
  ),
  primeiro AS (
    SELECT DISTINCT ON (e.lead_id)
           e.lead_id, e.origem_conversao, e.primeiro_toque_bruto
    FROM lead_conversion_event e
    ORDER BY e.lead_id, e.occurred_at ASC, e.id ASC
  ),
  ultimo AS (
    SELECT DISTINCT ON (e.lead_id)
           e.lead_id, e.origem_conversao, e.ultimo_toque_bruto
    FROM lead_conversion_event e
    ORDER BY e.lead_id, e.occurred_at DESC, e.id DESC
  ),
  -- Eixo B é esparso (7,6% medido, 17% na fatia recente): pegar "o último
  -- evento" traria NULL quase sempre. Pega o último evento que TEM sinal de
  -- mídia paga, que é a pergunta real ("por qual campanha paga ele veio").
  midia AS (
    SELECT DISTINCT ON (e.lead_id)
           e.lead_id, e.utm_campaign, e.midia, e.utm_source, e.gclid
    FROM lead_conversion_event e
    WHERE e.utm_campaign IS NOT NULL OR e.midia IS NOT NULL OR e.utm_source IS NOT NULL
    ORDER BY e.lead_id, e.occurred_at DESC, e.id DESC
  ),
  estagio AS (
    SELECT DISTINCT ON (fse.lead_id) fse.lead_id, fs.nome AS estagio
    FROM lead_funnel_stage_event fse
    JOIN funnel_stage fs ON fs.id = fse.funnel_stage_ref_id
    ORDER BY fse.lead_id, fse.occurred_on DESC, fse.id DESC
  )
  SELECT
    l.id                                  AS lead_id,
    l.source_system,
    l.source_id,
    l.nome,
    l.empresa,
    -- AC-5.2: sempre um dos 3 valores, nunca omitido. Ausência de sinal cai
    -- em nao_atribuido, jamais em comercial.
    COALESCE(loc.segmento, 'nao_atribuido') AS segmento,
    loc.categoria,
    loc.valor_bruto,
    COALESCE(est.estagio, l.status)         AS estagio_funil,

    l.cargo,
    fn_cargo_grupo(l.cargo)                 AS cargo_grupo,
    l.tamanho_empresa_bruto,
    fn_normalizar_tamanho_empresa(l.tamanho_empresa_bruto) AS tamanho_empresa,
    l.atendido_por,
    COALESCE(l.tags, '{}'::text[])          AS tags,

    l.is_teste,
    l.teste_regra,

    l.created_at_source                     AS data_criacao,
    COALESCE(c.qtd_conversoes, 0)           AS qtd_conversoes,
    COALESCE(c.qtd_origens, 0)              AS qtd_origens,
    c.primeira_conversao_at,
    c.ultima_conversao_at,
    COALESCE(c.ultima_conversao_at, c.primeira_conversao_at, l.created_at_source) AS data_conversao,
    COALESCE(c.origens_conversao, '{}'::text[]) AS origens_conversao,

    -- Eixo A (§1.2) — nunca portador de investimento.
    p.origem_conversao                      AS origem_primeira_conversao,
    u.origem_conversao                      AS origem_ultima_conversao,
    p.primeiro_toque_bruto,
    u.ultimo_toque_bruto,

    -- Eixo B (§1.2) — único que pode receber investimento/ROI.
    m.utm_campaign                          AS campanha_midia,
    COALESCE(m.midia, m.utm_source)         AS plataforma,
    m.gclid IS NOT NULL                     AS tem_gclid,

    l.source_system                         AS fonte_dados
  FROM lead l
  LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
  LEFT JOIN conv     c   ON c.lead_id   = l.id
  LEFT JOIN primeiro p   ON p.lead_id   = l.id
  LEFT JOIN ultimo   u   ON u.lead_id   = l.id
  LEFT JOIN midia    m   ON m.lead_id   = l.id
  LEFT JOIN estagio  est ON est.lead_id = l.id
) base;

COMMENT ON VIEW view_lead_perfil IS
  'Um registro por LEAD. Serve a lista e a ficha. cargo_grupo e tamanho_empresa são derivados por função (nunca materializados) para que regra nova valha retroativamente sem reprocessar ingestão. campanha_midia/plataforma vêm do último evento COM sinal de mídia, não do último evento — o eixo B é esparso e o último evento traria NULL quase sempre.';

-- ---------------------------------------------------------------------------
-- view_campanha_lead — um registro por (origem de conversão, lead)
--
-- Este é o grão da visão por campanha (§1.7, decisão do usuário): um lead com
-- múltiplas conversões conta em TODAS as campanhas em que converteu.
--
-- CONSEQUÊNCIA QUE A INTERFACE É OBRIGADA A ROTULAR: a soma de leads desta
-- view é legitimamente MAIOR que o total de leads distintos. Sem o rótulo,
-- alguém soma a coluna e conclui que o número está errado.
--
-- A deduplicação de evento (mesmo lead, mesma origem, mesmo instante) já
-- aconteceu na gravação, pela UNIQUE de lead_conversion_event — verificada em
-- dado real: 18 duplicatas de fonte colapsadas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW view_campanha_lead AS
SELECT
  e.origem_conversao,
  e.lead_id,
  count(*)                AS conversoes_nesta_origem,
  min(e.occurred_at)      AS primeira_em,
  max(e.occurred_at)      AS ultima_em,
  to_char(min(e.occurred_at), 'YYYY') || '-Q' || to_char(min(e.occurred_at), 'Q') AS trimestre_primeira,
  -- Eixo B agregado dentro da origem: qual campanha paga apareceu junto.
  max(e.utm_campaign)     AS campanha_midia,
  max(COALESCE(e.midia, e.utm_source)) AS plataforma,
  bool_or(e.gclid IS NOT NULL)         AS tem_gclid,
  l.is_teste,
  l.segmento_cache        AS segmento
FROM lead_conversion_event e
JOIN (
  SELECT l.id, l.is_teste, COALESCE(loc.segmento, 'nao_atribuido') AS segmento_cache
  FROM lead l
  LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
) l ON l.id = e.lead_id
GROUP BY e.origem_conversao, e.lead_id, l.is_teste, l.segmento_cache;

COMMENT ON VIEW view_campanha_lead IS
  'Um registro por (origem_conversao, lead) — o grão da visão por campanha do data-contract.md §1.7. A soma de leads aqui é LEGITIMAMENTE maior que o total de leads distintos, porque um lead conta em cada campanha em que converteu; a interface é obrigada a rotular isso onde a coluna aparece.';

-- ---------------------------------------------------------------------------
-- fn_search_leads v2 — os 13 filtros do contrato, por interseção
--
-- Mantém a assinatura (p_filtros jsonb, p_limit, p_offset) e a coluna
-- total_count por window function, para que o cutover não mude a forma da
-- resposta (ADR-021). As colunas novas são acrescentadas ao final.
--
-- incluir_teste tem default FALSE: a base real tem 21% de dado de teste
-- (26 de 125 leads medidos), e trazê-lo por omissão inflaria toda contagem.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_search_leads(jsonb, integer, integer);

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
    -- Dado de teste: excluído por padrão, NUNCA deletado (§1.6).
    (v_incluir_teste OR NOT v.is_teste)

    -- Cada bloco abaixo é uma DIMENSÃO. Entre dimensões: AND (interseção
    -- real, AC-1.1). Dentro de uma dimensão: OR (multi-select).
    AND fn_filtro_casa(v.segmento,        p_filtros->'segmento')
    AND fn_filtro_casa(v.estagio_funil,   p_filtros->'estagio_funil')
    AND fn_filtro_casa(v.cargo_grupo,     p_filtros->'cargo_grupo')
    AND fn_filtro_casa(v.tamanho_empresa, p_filtros->'tamanho_empresa')
    AND fn_filtro_casa(v.atendido_por,    p_filtros->'atendido_por')
    AND fn_filtro_casa(v.plataforma,      p_filtros->'plataforma')
    AND fn_filtro_casa(v.campanha_midia,  p_filtros->'campanha_midia')
    AND fn_filtro_casa(v.trimestre,       p_filtros->'trimestre')

    -- origem_conversao casa contra QUALQUER origem do lead, não só a
    -- primeira: pela regra de contagem (§1.7) um lead pertence a todas as
    -- campanhas em que converteu, então filtrar por campanha tem de
    -- encontrá-lo por qualquer uma delas.
    AND (
      p_filtros->'origem_conversao' IS NULL
      OR jsonb_typeof(p_filtros->'origem_conversao') = 'null'
      OR EXISTS (
        SELECT 1 FROM unnest(v.origens_conversao) AS o(valor)
        WHERE fn_filtro_casa(o.valor, p_filtros->'origem_conversao')
      )
    )

    -- tags: multivalor nos DOIS lados. Interseção de arrays (&&) = "tem ao
    -- menos uma das tags escolhidas", que é como multi-select se comporta.
    AND (
      v_tags IS NULL OR jsonb_typeof(v_tags) = 'null'
      OR jsonb_array_length(v_tags) = 0
      OR v.tags && ARRAY(SELECT jsonb_array_elements_text(v_tags))
    )

    -- Período sobre data_conversao (§1.1: cobertura 100%).
    AND (v_ini IS NULL OR v.data_conversao >= v_ini)
    AND (v_fim IS NULL OR v.data_conversao <= v_fim)

  ORDER BY v.data_conversao DESC NULLS LAST, v.lead_id DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_search_leads(jsonb, integer, integer) IS
  'v2 (migration 051): 13 filtros combináveis por interseção (AC-1.1) sobre view_lead_perfil, todos com cobertura medida (data-contract.md §1.1). incluir_teste default false porque 21% da base real é dado de teste. origem_conversao casa contra QUALQUER origem do lead, não só a primeira, pela regra de contagem §1.7.';

GRANT SELECT ON view_lead_perfil, view_campanha_lead TO crm_ingest;
