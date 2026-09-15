-- db/queries/verificacao/v1-matriz-transicao.sql
-- Subtask 3.15 (V1). Quantifica ASM-7 com NUMERO em vez de suposicao: compara,
-- lead a lead, a classificacao LEGADA do dashboard publicado com a do motor SQL.
--
-- A REGRA LEGADA, reproduzida fielmente de assets/js/views-legacy.js:1726-1734:
--
--   info           = o e-mail do lead bate com um lead da Central de Leads
--   pareceCampanha = standardizeCampanha(origem) != origem, ou seja, o LeadSource
--                    casa com CAMPANHA_RULES (views-legacy.js:53-60):
--                    rescue|logmein, webinar, goto|linkedin
--   isMarketing    = info OR pareceCampanha
--   Comercial      = NOT isMarketing   <-- EC-1: bucket residual, nao classificacao
--
-- APROXIMACAO DECLARADA, nao escondida: `info` no frontend consulta a Central de
-- Leads (planilha da automacao de anuncios). Aqui ele e aproximado por "existe um
-- lead do RD Station na base com o mesmo e-mail". As duas populacoes se sobrepoem
-- mas nao sao identicas -- a planilha tem historico que a nossa janela de 12 meses
-- nao cobre. Logo, o numero de "Marketing" pela regra legada aqui e um PISO.
--
-- Escopo: leads do Salesforce (a regra legada so roda na aba Oportunidades(SF)).

\echo '=== 1. MATRIZ DE TRANSICAO: regra legada x motor SQL ==='

WITH legado AS (
  SELECT
    l.id,
    CASE
      WHEN EXISTS (
             SELECT 1 FROM lead r
             WHERE r.source_system = 'rd_station'
               AND r.email IS NOT NULL AND l.email IS NOT NULL
               AND lower(r.email) = lower(l.email)
           )
        OR lower(coalesce(l.origem_bruta,'')) ~ '(rescue|logmein|webinar|goto|linkedin)'
      THEN 'Marketing' ELSE 'Comercial'
    END AS segmento_legado
  FROM lead l
  WHERE l.source_system = 'salesforce' AND NOT l.is_teste
),
novo AS (
  SELECT c.lead_id, c.segmento AS segmento_novo
  FROM lead_origin_classification c
  WHERE c.version = (SELECT max(version) FROM lead_origin_classification c2 WHERE c2.lead_id = c.lead_id)
)
SELECT
  g.segmento_legado                                  AS "regra legada",
  coalesce(n.segmento_novo,'(sem classificacao)')    AS "motor SQL",
  count(*)                                           AS leads,
  round(100.0*count(*) / sum(count(*)) OVER (), 1)   AS "% do total"
FROM legado g
LEFT JOIN novo n ON n.lead_id = g.id
GROUP BY 1,2
ORDER BY 3 DESC;

\echo ''
\echo '=== 2. O QUE MUDA DE FATO (so as transicoes, sem as permanencias) ==='

WITH legado AS (
  SELECT l.id,
    CASE
      WHEN EXISTS (SELECT 1 FROM lead r WHERE r.source_system='rd_station'
                    AND r.email IS NOT NULL AND l.email IS NOT NULL
                    AND lower(r.email)=lower(l.email))
        OR lower(coalesce(l.origem_bruta,'')) ~ '(rescue|logmein|webinar|goto|linkedin)'
      THEN 'Marketing' ELSE 'Comercial' END AS seg_legado
  FROM lead l WHERE l.source_system='salesforce' AND NOT l.is_teste
),
novo AS (
  SELECT c.lead_id, c.segmento AS seg_novo FROM lead_origin_classification c
  WHERE c.version = (SELECT max(version) FROM lead_origin_classification c2 WHERE c2.lead_id=c.lead_id)
)
SELECT g.seg_legado || ' -> ' || n.seg_novo AS transicao, count(*) AS leads
FROM legado g JOIN novo n ON n.lead_id = g.id
WHERE g.seg_legado IS DISTINCT FROM n.seg_novo
GROUP BY 1 ORDER BY 2 DESC;

\echo ''
\echo '=== 3. IMPACTO NO NUMERO QUE O NEGOCIO OLHA: leads por segmento ==='

WITH legado AS (
  SELECT l.id,
    CASE
      WHEN EXISTS (SELECT 1 FROM lead r WHERE r.source_system='rd_station'
                    AND r.email IS NOT NULL AND l.email IS NOT NULL
                    AND lower(r.email)=lower(l.email))
        OR lower(coalesce(l.origem_bruta,'')) ~ '(rescue|logmein|webinar|goto|linkedin)'
      THEN 'Marketing' ELSE 'Comercial' END AS seg_legado
  FROM lead l WHERE l.source_system='salesforce' AND NOT l.is_teste
),
novo AS (
  SELECT c.lead_id, c.segmento AS seg_novo FROM lead_origin_classification c
  WHERE c.version = (SELECT max(version) FROM lead_origin_classification c2 WHERE c2.lead_id=c.lead_id)
)
SELECT 'regra legada' AS origem, seg_legado AS segmento, count(*) AS leads FROM legado GROUP BY 1,2
UNION ALL
SELECT 'motor SQL', n.seg_novo, count(*) FROM legado g JOIN novo n ON n.lead_id=g.id GROUP BY 1,2
ORDER BY 1, 3 DESC;
