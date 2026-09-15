-- db/migrations/077_view_marketing_rd_salesforce.sql
--
-- A camada de leitura do OBJETIVO CENTRAL do epico, dito pelo usuario em
-- 2026-09-15: "pegar os leads que estao no RD Station, que foram gerados por
-- marketing, fazer analise desses mesmos leads dentro do Salesforce e trazer
-- no dashboard".
--
-- Ate hoje isso era impossivel por tres motivos, todos corrigidos antes desta
-- migration:
--   1. o grafo de identidade tinha 18 arestas -- RD e Salesforce nao estavam
--      ligados (resolvido rodando fn_identity_tier1_resolve: 8.704 arestas)
--   2. o crosswalk so conhecia LeadSource do Salesforce, entao TODOS os 475
--      leads do RD eram 'NaoAtribuido' -- o conjunto "gerados por marketing"
--      era vazio por construcao (resolvido pela migration 075)
--   3. fn_reclassificar_lead so versionava quando o SINAL mudava, nunca quando
--      a REGRA mudava, entao a correcao acima nao chegava na tabela
--      (resolvido pela migration 076)
--
-- GRAO: uma linha por lead de marketing do RD Station. NAO multiplica por
-- oportunidade -- as oportunidades vem agregadas em colunas de contagem e
-- valor. Quem precisa do grao por oportunidade usa view_receita (§1.7 do
-- data-contract: o grao tem de estar no nome e no comentario, para ninguem
-- somar a coluna errada).
--
-- A LIGACAO e por identity_edge tipo 'email', que e Tier 1. Nao usa
-- Identificador_RD__c porque esse campo NAO foi trazido na carga de 12 meses
-- (falha registrada no validation-log). Quando for trazido, ele vira a chave
-- preferencial e o e-mail passa a ser fallback -- a view muda, o contrato nao.

CREATE OR REPLACE VIEW view_marketing_rd_sf AS
WITH rd AS (
  SELECT
    l.id                AS rd_lead_id,
    l.source_id         AS rd_uuid,
    l.nome,
    l.empresa,
    l.created_at_source AS criado_em,
    l.lista_regra,
    ie.person_id,
    c.categoria,
    c.detalhe,
    c.valor_bruto       AS origem_conversao
  FROM lead l
  JOIN identity_edge ie
    ON ie.source_system = l.source_system
   AND ie.source_record_id = l.source_id
   AND ie.identifier_type = 'email'
  JOIN lead_origin_classification c
    ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE l.source_system = 'rd_station'
    AND NOT l.is_teste
    AND c.segmento = 'Marketing'
),
sf AS (
  SELECT
    ie.person_id,
    min(l.id)                       AS sf_lead_id,
    min(l.status)                   AS sf_status,
    min(a.id)                       AS account_id,
    min(a.nome)                     AS conta_nome
  FROM lead l
  JOIN identity_edge ie
    ON ie.source_system = l.source_system
   AND ie.source_record_id = l.source_id
   AND ie.identifier_type = 'email'
  LEFT JOIN account a
    ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
  WHERE l.source_system = 'salesforce'
  GROUP BY ie.person_id
),
opp AS (
  SELECT
    sf.person_id,
    count(DISTINCT o.id)                                            AS qtd_oportunidades,
    count(DISTINCT o.id) FILTER (WHERE o.stage_name = 'Ganho')      AS qtd_ganhas,
    sum(o.amount)        FILTER (WHERE o.stage_name = 'Ganho')      AS amount_ganho,
    sum(o.mrr)           FILTER (WHERE o.stage_name = 'Ganho')      AS mrr_ganho,
    max(o.record_type_name)                                         AS record_type
  FROM sf JOIN opportunity o ON o.account_id = sf.account_id
  GROUP BY sf.person_id
)
SELECT
  rd.rd_lead_id, rd.rd_uuid, rd.nome, rd.empresa, rd.criado_em,
  rd.categoria, rd.detalhe, rd.origem_conversao,
  (rd.lista_regra IS NOT NULL)                AS de_lista_importada,
  rd.lista_regra,
  (sf.sf_lead_id IS NOT NULL)                 AS achado_no_salesforce,
  sf.sf_status                                AS status_no_salesforce,
  (sf.account_id IS NOT NULL)                 AS virou_conta,
  sf.conta_nome,
  coalesce(opp.qtd_oportunidades, 0)          AS qtd_oportunidades,
  coalesce(opp.qtd_ganhas, 0)                 AS qtd_ganhas,
  opp.amount_ganho,
  opp.mrr_ganho,
  opp.record_type
FROM rd
LEFT JOIN sf  ON sf.person_id  = rd.person_id
LEFT JOIN opp ON opp.person_id = rd.person_id;

COMMENT ON VIEW view_marketing_rd_sf IS
  'UMA LINHA POR LEAD DE MARKETING DO RD STATION, com o desfecho dele no Salesforce. Oportunidades vem AGREGADAS em colunas de contagem/valor -- a view NAO multiplica por oportunidade. Ligacao por identity_edge tipo email (Tier 1). Ver migration 077.';

-- Agregado para os KPIs da aba. Funcao e nao view para que a aba peca UMA
-- linha em vez de trazer 305 e somar no cliente -- somar no cliente e como o
-- dashboard antigo produzia total que nao batia com a lista.
CREATE OR REPLACE FUNCTION fn_marketing_funil()
RETURNS TABLE(
  leads_marketing      bigint,
  de_lista             bigint,
  achados_no_sf        bigint,
  viraram_conta        bigint,
  oportunidades        bigint,
  ganhas               bigint,
  amount_ganho         numeric,
  mrr_ganho            numeric
)
LANGUAGE sql STABLE AS $$
  SELECT
    count(*),
    count(*) FILTER (WHERE de_lista_importada),
    count(*) FILTER (WHERE achado_no_salesforce),
    count(*) FILTER (WHERE virou_conta),
    coalesce(sum(qtd_oportunidades), 0),
    coalesce(sum(qtd_ganhas), 0),
    sum(amount_ganho),
    sum(mrr_ganho)
  FROM view_marketing_rd_sf;
$$;

COMMENT ON FUNCTION fn_marketing_funil() IS
  'KPIs do funil marketing RD -> Salesforce, em UMA linha. Ver migration 077.';

-- Quebra por categoria de origem, para a aba mostrar de onde vem o resultado.
CREATE OR REPLACE FUNCTION fn_marketing_funil_por_categoria()
RETURNS TABLE(
  categoria       text,
  detalhe         text,
  leads           bigint,
  achados_no_sf   bigint,
  viraram_conta   bigint,
  oportunidades   bigint,
  ganhas          bigint
)
LANGUAGE sql STABLE AS $$
  SELECT
    coalesce(categoria, '(sem categoria)'),
    coalesce(detalhe, '—'),
    count(*),
    count(*) FILTER (WHERE achado_no_salesforce),
    count(*) FILTER (WHERE virou_conta),
    coalesce(sum(qtd_oportunidades), 0),
    coalesce(sum(qtd_ganhas), 0)
  FROM view_marketing_rd_sf
  GROUP BY 1, 2
  ORDER BY 3 DESC;
$$;

GRANT SELECT ON view_marketing_rd_sf TO crm_ingest;
GRANT EXECUTE ON FUNCTION fn_marketing_funil() TO crm_ingest;
GRANT EXECUTE ON FUNCTION fn_marketing_funil_por_categoria() TO crm_ingest;
