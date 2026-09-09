-- db/migrations/053_fn_opcoes_filtro.sql
-- Subtask 8.10 — as listas de opção de cada filtro, com contagem.
--
-- POR QUE ISTO EXISTE E NÃO É HARDCODE NA INTERFACE
-- Os 4 filtros da v1 do contrato foram inventados. A raiz do erro foi a
-- interface (e a spec) decidirem sozinhas quais valores existem. Aqui a lista
-- de opções vem do dado: se `cf_atuacao_da_empresa` está vazio, ele não
-- aparece como opção; se um cargo novo surgir, ele aparece sem ninguém
-- alterar código.
--
-- A CONTAGEM POR OPÇÃO NÃO É ENFEITE
-- É o que torna o filtro navegável em vez de adivinhado. Ver `c_level (42)`
-- ao lado de `operacional (3)` diz onde vale filtrar. E permite a regra de
-- ouro de UX de filtro: nunca oferecer uma opção que devolve zero.
--
-- GRÃO: um lead conta uma vez por opção nesta função — é a visão geral
-- (§1.7). `origem_conversao` é a exceção necessária: um lead pertence a
-- todas as origens em que converteu, então a soma dessa lista é maior que o
-- total de leads. Está marcado na própria resposta (`grao: "multiplicado"`)
-- para que a interface possa rotular, como o contrato exige.

CREATE OR REPLACE FUNCTION fn_opcoes_filtro(p_incluir_teste boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_out jsonb;
BEGIN
  WITH base AS (
    SELECT * FROM view_lead_perfil
    WHERE p_incluir_teste OR NOT is_teste
  ),
  -- Uma CTE por dimensão. Ordem: contagem desc, depois alfabética — a opção
  -- mais usada primeiro é o que faz um multi-select longo ser utilizável.
  d_segmento AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT segmento AS valor, count(*) AS n FROM base
          WHERE segmento IS NOT NULL GROUP BY 1) t
  ),
  d_estagio AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT estagio_funil AS valor, count(*) AS n FROM base
          WHERE estagio_funil IS NOT NULL AND btrim(estagio_funil) <> '' GROUP BY 1) t
  ),
  d_cargo AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT cargo_grupo AS valor, count(*) AS n FROM base
          WHERE cargo_grupo IS NOT NULL GROUP BY 1) t
  ),
  d_tamanho AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT tamanho_empresa AS valor, count(*) AS n FROM base
          WHERE tamanho_empresa IS NOT NULL GROUP BY 1) t
  ),
  d_atendido AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT atendido_por AS valor, count(*) AS n FROM base
          WHERE atendido_por IS NOT NULL GROUP BY 1) t
  ),
  d_plataforma AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT plataforma AS valor, count(*) AS n FROM base
          WHERE plataforma IS NOT NULL GROUP BY 1) t
  ),
  d_trimestre AS (
    -- Trimestre ordena por VALOR desc (cronológico), não por contagem: é uma
    -- dimensão temporal, e ordenar trimestre por volume seria ilegível.
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY valor DESC) AS j
    FROM (SELECT trimestre AS valor, count(*) AS n FROM base
          WHERE trimestre IS NOT NULL GROUP BY 1) t
  ),
  d_campanha AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT campanha_midia AS valor, count(*) AS n FROM base
          WHERE campanha_midia IS NOT NULL GROUP BY 1) t
  ),
  d_tags AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT t AS valor, count(*) AS n FROM base b, unnest(b.tags) AS t GROUP BY 1) t
  ),
  -- Eixo A. Grão multiplicado de propósito (§1.7).
  d_origem AS (
    SELECT jsonb_agg(jsonb_build_object('valor', valor, 'leads', n) ORDER BY n DESC, valor) AS j
    FROM (SELECT o AS valor, count(DISTINCT b.lead_id) AS n
          FROM base b, unnest(b.origens_conversao) AS o GROUP BY 1) t
  ),
  totais AS (
    SELECT jsonb_build_object(
      'leads',            (SELECT count(*) FROM base),
      'leads_teste',      (SELECT count(*) FROM view_lead_perfil WHERE is_teste),
      'leads_sem_conversao', (SELECT count(*) FROM base WHERE qtd_conversoes = 0),
      'eventos_conversao',(SELECT count(*) FROM lead_conversion_event),
      'origens_distintas',(SELECT count(DISTINCT origem_conversao) FROM lead_conversion_event)
    ) AS j
  )
  SELECT jsonb_build_object(
    'segmento',         COALESCE((SELECT j FROM d_segmento),   '[]'::jsonb),
    'estagio_funil',    COALESCE((SELECT j FROM d_estagio),    '[]'::jsonb),
    'cargo_grupo',      COALESCE((SELECT j FROM d_cargo),      '[]'::jsonb),
    'tamanho_empresa',  COALESCE((SELECT j FROM d_tamanho),    '[]'::jsonb),
    'atendido_por',     COALESCE((SELECT j FROM d_atendido),   '[]'::jsonb),
    'plataforma',       COALESCE((SELECT j FROM d_plataforma), '[]'::jsonb),
    'trimestre',        COALESCE((SELECT j FROM d_trimestre),  '[]'::jsonb),
    'campanha_midia',   COALESCE((SELECT j FROM d_campanha),   '[]'::jsonb),
    'tags',             COALESCE((SELECT j FROM d_tags),       '[]'::jsonb),
    'origem_conversao', COALESCE((SELECT j FROM d_origem),     '[]'::jsonb),
    'totais',           (SELECT j FROM totais),
    -- Metadado que a interface é OBRIGADA a respeitar: onde o grão é
    -- multiplicado, a soma da coluna passa do total e precisa de rótulo.
    'grao', jsonb_build_object(
      'origem_conversao', 'multiplicado',
      'tags',             'multiplicado',
      'nota', 'Um lead pode aparecer em mais de uma origem de conversao e em mais de uma tag; nessas duas dimensoes a soma da coluna de leads e legitimamente maior que o total. Rotular na interface (data-contract.md 1.7).'
    )
  ) INTO v_out;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION fn_opcoes_filtro(boolean) IS
  'Listas de opção de cada filtro, com contagem de leads, tiradas do DADO e não de enum hardcoded — é a correção estrutural do erro que produziu os 4 filtros inventados da v1 do contrato. O campo `grao` marca as dimensões (origem_conversao, tags) em que a soma da coluna passa do total, porque a interface é obrigada a rotular isso (data-contract.md §1.7).';

GRANT EXECUTE ON FUNCTION fn_opcoes_filtro(boolean) TO crm_ingest;
