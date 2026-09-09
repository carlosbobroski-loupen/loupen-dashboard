-- db/migrations/038_fn_search_leads.sql
-- Subtask 3.19. [AUTO-DECISION — ADR-019] FR-1 resolvido SERVER-SIDE, não
-- no cliente — ver razões completas na nota original do plano (NFR-2,
-- R8, CON-12, INV-2). AC-1.1: filtros combinados produzem INTERSEÇÃO
-- (AND entre dimensões), nunca substituição. Retorna a contagem TOTAL
-- (window function, INT-1/P-UI-6) para que a Etapa B tenha o mesmo
-- "resumo dos filtros ativos + total" que a Etapa A já implementa no
-- cliente contra o fixture — o contrato de resposta não muda no cutover,
-- só de onde o dado vem (a mesma inversão que motivou ADR-020/021).
--
-- p_filtros (jsonb), exemplo:
--   {"segmento": ["Marketing", "Parceiro"], "campanha": "Busca Paga | Google"}
-- segmento: array (ou string única) — combinado por OR dentro da própria
-- dimensão (é assim que um multi-select de segmento se comporta em
-- qualquer UI, incluindo a Etapa A); campanha: match exato contra
-- valor_bruto da classificação corrente — combinado por AND com segmento
-- (duas DIMENSÕES diferentes = interseção real, AC-1.1).

CREATE OR REPLACE FUNCTION fn_search_leads(
  p_filtros jsonb DEFAULT '{}'::jsonb,
  p_limit   integer DEFAULT 50,
  p_offset  integer DEFAULT 0
)
RETURNS TABLE (
  lead_id            bigint,
  source_id          text,
  nome               text,
  empresa            text,
  estagio_funil      text,
  segmento           text,
  categoria          text,
  sinal_id           text,
  valor_bruto        text,
  created_at_source  timestamptz,
  total_count        bigint
) AS $$
DECLARE
  v_segmentos jsonb;
BEGIN
  v_segmentos := p_filtros->'segmento';

  RETURN QUERY
  SELECT
    l.id, l.source_id, l.nome, l.empresa, l.status,
    loc.segmento, loc.categoria, loc.sinal_id, loc.valor_bruto,
    l.created_at_source,
    count(*) OVER () AS total_count
  FROM lead l
  LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
  WHERE
    -- segmento: array OU string única no jsonb, combinado por OR interno
    -- (multi-select), ausência do filtro = sem restrição.
    (
      v_segmentos IS NULL
      OR (jsonb_typeof(v_segmentos) = 'array' AND loc.segmento = ANY (SELECT jsonb_array_elements_text(v_segmentos)))
      OR (jsonb_typeof(v_segmentos) = 'string' AND loc.segmento = (v_segmentos #>> '{}'))
    )
    -- campanha: match exato contra valor_bruto — AND com o filtro acima
    -- (dimensão diferente, AC-1.1: interseção real).
    AND (
      NOT (p_filtros ? 'campanha')
      OR loc.valor_bruto = p_filtros->>'campanha'
    )
    -- estagio_funil: match exato, mesma lógica de interseção.
    AND (
      NOT (p_filtros ? 'estagio_funil')
      OR l.status = p_filtros->>'estagio_funil'
    )
  ORDER BY l.created_at_source DESC NULLS LAST, l.id
  LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_search_leads(jsonb, integer, integer) IS
  'FR-1/AC-1.1: busca de leads combinável por interseção, resolvida no banco (ADR-019). total_count via window function (INT-1) — o resumo de filtros ativos é responsabilidade do consumidor (mesmo contrato da Etapa A/data-api.js), esta função só garante que o TOTAL correto sempre acompanha a página retornada.';
