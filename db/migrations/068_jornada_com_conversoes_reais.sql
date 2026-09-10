-- db/migrations/068_jornada_com_conversoes_reais.sql
-- Subtask 8.25 — a jornada do lead passa a incluir os eventos que a ingestão
-- do RD Station trouxe. Sem isto a ficha do lead mostra tudo MENOS as
-- conversões.
--
-- ── O QUE ESTAVA FALTANDO ─────────────────────────────────────────────────
-- `view_jornada_unificada` (migration 037) une 4 fontes: conversion_event
-- (direto e via identidade), lead_touchpoint e criação de oportunidade. Foi
-- escrita antes de `lead_conversion_event` (045) e `lead_funnel_stage_event`
-- (039) terem dado.
--
-- Resultado: a ficha do lead não mostrava NENHUM dos 767 eventos de conversão
-- reais nem nenhuma das 475 mudanças de estágio de funil. O lead aparecia com
-- uma jornada vazia enquanto o banco tinha a história inteira dele.
--
-- ── COLUNAS NOVAS, ACRESCENTADAS NO FIM ───────────────────────────────────
-- `CREATE OR REPLACE VIEW` permite acrescentar coluna no FIM (o problema da
-- migration 066 era inserir no meio). As 7 colunas do contrato original ficam
-- intactas na mesma ordem, então nenhum consumidor existente quebra.
--
-- As novas existem porque a ficha precisa mostrar, POR EVENTO, o que a
-- firmografia versionada revelou: cargo e tamanho de empresa mudam entre
-- conversões do mesmo lead. Verificado em dado real — o mesmo contato aparece
-- como `Diretor` num evento e `CEO, Founder, Sócio` noutro. Mostrar só o
-- valor atual do cadastro esconderia essa evolução, que é justamente o que
-- conta a história do lead.
--
-- Todas ficam NULL nos ramos que não as têm. Isso é honesto: um touchpoint de
-- workflow não tem cargo, e preencher com o valor do cadastro seria atribuir
-- ao evento uma informação que ele não carrega.
--
-- ── GRANULARIDADE ─────────────────────────────────────────────────────────
-- Conversão do RD tem `event_timestamp` real ao segundo → 'timestamp'.
-- Estágio de funil é 'dia' (CON-3), pelo mesmo motivo do touchpoint: a API do
-- RD só expõe o estado atual, então a granularidade real é "por execução do
-- pull", nunca intradiária.

CREATE OR REPLACE VIEW view_jornada_unificada AS
-- 1) Eventos de conversão já ligados diretamente a um lead.
SELECT
  ce.lead_id,
  ce.occurred_at,
  ce.date_traceable,
  ce.source_system,
  ce.tipo,
  ce.ativo_de_origem AS detalhe,
  'timestamp' AS granularidade,
  NULL::text AS origem_conversao,
  NULL::text AS campanha_midia,
  NULL::text AS plataforma,
  NULL::text AS cargo_no_evento,
  NULL::text AS tamanho_no_evento,
  NULL::text AS primeiro_toque,
  NULL::text AS ultimo_toque,
  NULL::text AS atribuicao_status
FROM conversion_event ce
WHERE ce.lead_id IS NOT NULL

UNION ALL

-- 2) Eventos de conversão de contact (RD Station) resolvidos a um lead
-- (Salesforce) via identidade (EC-7).
SELECT
  l.id AS lead_id,
  ce.occurred_at,
  ce.date_traceable,
  ce.source_system,
  ce.tipo,
  ce.ativo_de_origem AS detalhe,
  'timestamp' AS granularidade,
  NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text
FROM conversion_event ce
JOIN contact c ON c.id = ce.contact_id
JOIN identity_edge ie_contact ON ie_contact.source_system = c.source_system AND ie_contact.source_record_id = c.source_id
JOIN identity_edge ie_lead ON ie_lead.person_id = ie_contact.person_id AND ie_lead.source_system <> c.source_system
JOIN lead l ON l.source_system = ie_lead.source_system AND l.source_id = ie_lead.source_record_id
WHERE ce.contact_id IS NOT NULL AND ce.lead_id IS NULL

UNION ALL

-- 3) Touchpoints de influência (S7) — granularidade SEMPRE 'dia' (CON-3).
SELECT
  lt.lead_id,
  lt.occurred_on::timestamptz,
  true AS date_traceable,
  lt.fonte AS source_system,
  lt.tipo,
  lt.campanha AS detalhe,
  'dia' AS granularidade,
  NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text
FROM lead_touchpoint lt

UNION ALL

-- 4) Criação de oportunidade — marco derivado do dado já canônico.
SELECT
  l.id AS lead_id,
  o.created_at_source,
  o.created_at_source IS NOT NULL,
  o.source_system,
  'criacao_oportunidade',
  o.stage_name,
  'timestamp',
  NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text
FROM opportunity o
JOIN account a ON a.id = o.account_id
JOIN lead l ON l.source_system = a.source_system AND l.converted_account_id = a.source_id

UNION ALL

-- 5) NOVO — conversões do RD Station (lead_conversion_event, migration 045).
-- É o corpo real da jornada: 767 eventos hoje. Traz a firmografia e a
-- atribuição DO INSTANTE, normalizadas pelas mesmas funções que a lista usa
-- (064/065), para que campanha e plataforma apareçam iguais nos dois lugares.
SELECT
  e.lead_id,
  e.occurred_at,
  true AS date_traceable,
  e.source_system,
  'conversao' AS tipo,
  e.origem_conversao AS detalhe,
  'timestamp' AS granularidade,
  e.origem_conversao,
  COALESCE(
    fn_normalizar_campanha(e.utm_campaign),
    fn_extrair_utm(e.midia,      'utm_campaign'),
    fn_extrair_utm(e.utm_source, 'utm_campaign')
  ) AS campanha_midia,
  fn_normalizar_plataforma(COALESCE(e.midia, e.utm_source)) AS plataforma,
  e.cargo AS cargo_no_evento,
  e.tamanho_empresa AS tamanho_no_evento,
  e.primeiro_toque_bruto AS primeiro_toque,
  e.ultimo_toque_bruto AS ultimo_toque,
  e.atribuicao_status
FROM lead_conversion_event e

UNION ALL

-- 6) NOVO — mudança de estágio de funil (lead_funnel_stage_event, 039).
-- 475 eventos hoje. Granularidade 'dia' porque a API do RD só expõe o estado
-- ATUAL: a data real é "quando o pull rodou", não "quando o estágio mudou".
SELECT
  fse.lead_id,
  fse.occurred_on::timestamptz,
  true AS date_traceable,
  fse.fonte AS source_system,
  'mudanca_estagio' AS tipo,
  fs.nome AS detalhe,
  'dia' AS granularidade,
  NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text
FROM lead_funnel_stage_event fse
JOIN funnel_stage fs ON fs.id = fse.funnel_stage_ref_id;

COMMENT ON VIEW view_jornada_unificada IS
  'FR-3: jornada cronológica única. A migration 068 acrescentou as duas fontes que faltavam — lead_conversion_event (o corpo real da jornada) e lead_funnel_stage_event —, sem as quais a ficha do lead mostrava tudo MENOS as conversões. Colunas novas no fim (origem_conversao..atribuicao_status) trazem a firmografia e a atribuição DO INSTANTE de cada conversão, porque cargo e tamanho de empresa mudam entre eventos do mesmo lead (verificado em dado real). NULL nos ramos que não têm o dado — preencher com o valor do cadastro atribuiria ao evento uma informação que ele não carrega. granularidade declara timestamp vs dia (CON-3/EC-10): nunca comparar dois eventos "dia" como se a ordem intradiária importasse.';

GRANT SELECT ON view_jornada_unificada TO crm_ingest;
