-- db/migrations/086_jornada_expoe_o_anuncio.sql
--
-- Leva ate a FICHA o que a lista ja mostra: o ID do anuncio, o criativo e o
-- publico da conversao.
--
-- POR QUE ESTA MIGRATION EXISTE, e e desconfortavel: o commit 04ee64b consertou
-- a INGESTAO desses campos (o webhook do RD jogava fora utm_id, utm_content e
-- utm_term), e eles passaram a existir em lead_conversion_event. Mas
-- view_jornada_unificada, que alimenta a aba "Jornada" da ficha, projeta 15
-- colunas e NENHUMA delas e essas tres. Ou seja: o dado entrou no banco e
-- continuou sem chegar na tela. O usuario abriria a ficha do lead que ele
-- mesmo apontou e veria campanha e plataforma -- e continuaria sem ver
-- utm_id=120256183649680492 nem o criativo V5_AMARELO.
--
-- Consertar a entrada sem consertar a saida e meio conserto.
--
-- Os cinco ramos que nao tem esses campos (conversion_event legado, touchpoint,
-- criacao de oportunidade, workflow, mudanca de estagio) declaram NULL
-- explicitamente, como ja fazem com campanha_midia e plataforma. NULL declarado
-- diz "este tipo de evento nao carrega isso"; coluna ausente diria "ninguem
-- pensou no assunto".

DROP VIEW IF EXISTS view_jornada_unificada;

CREATE VIEW view_jornada_unificada AS
SELECT ce.lead_id,
    ce.occurred_at,
    ce.date_traceable,
    ce.source_system,
    ce.tipo,
    ce.ativo_de_origem AS detalhe,
    'timestamp'::text AS granularidade,
    NULL::text AS origem_conversao,
    NULL::text AS campanha_midia,
    NULL::text AS plataforma,
    NULL::text AS cargo_no_evento,
    NULL::text AS tamanho_no_evento,
    NULL::text AS primeiro_toque,
    NULL::text AS ultimo_toque,
    NULL::text AS atribuicao_status,
    NULL::text AS id_anuncio,
    NULL::text AS criativo,
    NULL::text AS publico
   FROM conversion_event ce
  WHERE ce.lead_id IS NOT NULL
UNION ALL
 SELECT l.id AS lead_id,
    ce.occurred_at,
    ce.date_traceable,
    ce.source_system,
    ce.tipo,
    ce.ativo_de_origem AS detalhe,
    'timestamp'::text AS granularidade,
    NULL::text AS origem_conversao,
    NULL::text AS campanha_midia,
    NULL::text AS plataforma,
    NULL::text AS cargo_no_evento,
    NULL::text AS tamanho_no_evento,
    NULL::text AS primeiro_toque,
    NULL::text AS ultimo_toque,
    NULL::text AS atribuicao_status,
    NULL::text AS id_anuncio,
    NULL::text AS criativo,
    NULL::text AS publico
   FROM conversion_event ce
     JOIN contact c ON c.id = ce.contact_id
     JOIN identity_edge ie_contact ON ie_contact.source_system = c.source_system AND ie_contact.source_record_id = c.source_id
     JOIN identity_edge ie_lead ON ie_lead.person_id = ie_contact.person_id AND ie_lead.source_system <> c.source_system
     JOIN lead l ON l.source_system = ie_lead.source_system AND l.source_id = ie_lead.source_record_id
  WHERE ce.contact_id IS NOT NULL AND ce.lead_id IS NULL
UNION ALL
 SELECT lt.lead_id,
    lt.occurred_on::timestamp with time zone AS occurred_at,
    true AS date_traceable,
    lt.fonte AS source_system,
    lt.tipo,
    lt.campanha AS detalhe,
    'dia'::text AS granularidade,
    NULL::text AS origem_conversao,
    NULL::text AS campanha_midia,
    NULL::text AS plataforma,
    NULL::text AS cargo_no_evento,
    NULL::text AS tamanho_no_evento,
    NULL::text AS primeiro_toque,
    NULL::text AS ultimo_toque,
    NULL::text AS atribuicao_status,
    NULL::text AS id_anuncio,
    NULL::text AS criativo,
    NULL::text AS publico
   FROM lead_touchpoint lt
UNION ALL
 SELECT l.id AS lead_id,
    o.created_at_source AS occurred_at,
    o.created_at_source IS NOT NULL AS date_traceable,
    o.source_system,
    'criacao_oportunidade'::text AS tipo,
    o.stage_name AS detalhe,
    'timestamp'::text AS granularidade,
    NULL::text AS origem_conversao,
    NULL::text AS campanha_midia,
    NULL::text AS plataforma,
    NULL::text AS cargo_no_evento,
    NULL::text AS tamanho_no_evento,
    NULL::text AS primeiro_toque,
    NULL::text AS ultimo_toque,
    NULL::text AS atribuicao_status,
    NULL::text AS id_anuncio,
    NULL::text AS criativo,
    NULL::text AS publico
   FROM opportunity o
     JOIN account a ON a.id = o.account_id
     JOIN lead l ON l.source_system = a.source_system AND l.converted_account_id = a.source_id
UNION ALL
 SELECT e.lead_id,
    e.occurred_at,
    true AS date_traceable,
    e.source_system,
    'conversao'::text AS tipo,
    e.origem_conversao AS detalhe,
    'timestamp'::text AS granularidade,
    e.origem_conversao,
    COALESCE(fn_normalizar_campanha(e.utm_campaign), fn_extrair_utm(e.midia, 'utm_campaign'::text), fn_extrair_utm(e.utm_source, 'utm_campaign'::text)) AS campanha_midia,
    fn_normalizar_plataforma(COALESCE(e.midia, e.utm_source)) AS plataforma,
    e.cargo AS cargo_no_evento,
    e.tamanho_empresa AS tamanho_no_evento,
    e.primeiro_toque_bruto AS primeiro_toque,
    e.ultimo_toque_bruto AS ultimo_toque,
    e.atribuicao_status,
    e.utm_id      AS id_anuncio,
    e.utm_content AS criativo,
    e.utm_term    AS publico
   FROM lead_conversion_event e
UNION ALL
 SELECT fse.lead_id,
    fse.occurred_on::timestamp with time zone AS occurred_at,
    true AS date_traceable,
    fse.fonte AS source_system,
    'mudanca_estagio'::text AS tipo,
    fs.nome AS detalhe,
    'dia'::text AS granularidade,
    NULL::text AS origem_conversao,
    NULL::text AS campanha_midia,
    NULL::text AS plataforma,
    NULL::text AS cargo_no_evento,
    NULL::text AS tamanho_no_evento,
    NULL::text AS primeiro_toque,
    NULL::text AS ultimo_toque,
    NULL::text AS atribuicao_status,
    NULL::text AS id_anuncio,
    NULL::text AS criativo,
    NULL::text AS publico
   FROM lead_funnel_stage_event fse
     JOIN funnel_stage fs ON fs.id = fse.funnel_stage_ref_id;

COMMENT ON VIEW view_jornada_unificada IS
  'GRAO: UM EVENTO POR LINHA. Une conversao (direta e via identidade), touchpoint, criacao de oportunidade, workflow e mudanca de estagio. Desde a migration 086 expoe tambem id_anuncio (utm_id), criativo (utm_content) e publico (utm_term) no ramo de conversao -- ate entao o dado entrava no banco e nao chegava na ficha.';

GRANT SELECT ON view_jornada_unificada TO crm_ingest;
