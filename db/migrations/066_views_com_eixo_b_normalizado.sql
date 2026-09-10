-- db/migrations/066_views_com_eixo_b_normalizado.sql
-- Subtask 8.23 — aplica fn_normalizar_campanha / fn_normalizar_plataforma
-- (migrations 064/065) nas duas views de leitura.
--
-- EFEITO ESPERADO, medido antes desta migration:
--   `[SB]+CAMPANHA_WEBINAR` (12 leads) + `[SB] CAMPANHA_WEBINAR` (10)
--   passam a ser UMA campanha de 22 leads. Eram a mesma o tempo todo — o `+`
--   de query string nao estava sendo tratado como espaco.
--
--   11 eventos de LinkedIn Ads e 2 de Facebook Ads, cuja UTM inteira estava
--   colada dentro de `cf_midia`/`cf_utm_source`, passam a ter campanha e
--   plataforma legiveis (`810534183` / LinkedIn, `Rescue-licenca-eco-meta` /
--   Facebook).
--
--   As grafias de plataforma (META, instagram, ig, facebook, fb, Facebook,
--   google, GoogleAds) colapsam nas canonicas.
--
-- POR QUE NA VIEW: mesma razao de cargo_grupo e tamanho_empresa. O bruto fica
-- intacto na tabela (e agora exposto ao lado, como `*_bruta`, para a aba
-- Qualidade de dados poder mostrar o que a fonte mandou), e regra nova em
-- plataforma_regra vale retroativamente sem reingerir nada.
--
-- COLUNAS NOVAS: `campanha_midia_bruta` e `plataforma_bruta`. Existem porque
-- normalizar sem guardar o original transforma a normalizacao num ato de fe —
-- ninguem consegue conferir se a regra fez a coisa certa.

-- DROP + CREATE em vez de CREATE OR REPLACE.
--
-- Motivo, encontrado tentando: `CREATE OR REPLACE VIEW` so permite
-- ACRESCENTAR coluna no fim, e o `SELECT *, trimestre` desta view faz
-- `trimestre` ser a ultima — qualquer coluna nova na subquery cai antes dele
-- e o Postgres recusa com "cannot change name of view column".
--
-- Verificado antes de dropar (pg_depend/pg_rewrite): NENHUMA view depende de
-- view_lead_perfil. As funcoes que a consultam (fn_search_leads,
-- fn_opcoes_filtro, fn_qualidade_dados) resolvem o nome em tempo de execucao
-- e nao criam dependencia rigida.
--
-- O GRANT e refeito no fim do arquivo: DROP leva os privilegios com ele, e
-- esquecer isso quebraria a API com "permission denied" — que e exatamente o
-- modo de falha da migration 049.
DROP VIEW IF EXISTS view_lead_perfil;

CREATE VIEW view_lead_perfil AS
SELECT *,
       to_char(data_conversao, 'YYYY') || '-Q' || to_char(data_conversao, 'Q') AS trimestre
FROM (
  WITH conv AS (
    SELECT e.lead_id,
           count(*)                               AS qtd_conversoes,
           count(DISTINCT e.origem_conversao)     AS qtd_origens,
           min(e.occurred_at)                     AS primeira_conversao_at,
           max(e.occurred_at)                     AS ultima_conversao_at,
           array_agg(DISTINCT e.origem_conversao) AS origens_conversao
    FROM lead_conversion_event e
    GROUP BY e.lead_id
  ),
  primeiro AS (
    SELECT DISTINCT ON (e.lead_id) e.lead_id, e.origem_conversao, e.primeiro_toque_bruto
    FROM lead_conversion_event e ORDER BY e.lead_id, e.occurred_at ASC, e.id ASC
  ),
  ultimo AS (
    SELECT DISTINCT ON (e.lead_id) e.lead_id, e.origem_conversao, e.ultimo_toque_bruto
    FROM lead_conversion_event e ORDER BY e.lead_id, e.occurred_at DESC, e.id DESC
  ),
  midia AS (
    SELECT DISTINCT ON (e.lead_id) e.lead_id, e.utm_campaign, e.midia, e.utm_source, e.gclid
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
    l.id AS lead_id, l.source_system, l.source_id, l.nome, l.empresa,
    fn_segmento_contrato(loc.segmento)      AS segmento,
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
    p.origem_conversao                      AS origem_primeira_conversao,
    u.origem_conversao                      AS origem_ultima_conversao,
    p.primeiro_toque_bruto,
    u.ultimo_toque_bruto,
    -- Eixo B normalizado (migrations 064/065). Ordem do COALESCE importa:
    -- o utm_campaign dedicado vence; so depois se tenta extrair de dentro de
    -- midia/utm_source, e `fn_extrair_utm` devolve NULL quando o valor NAO e
    -- uma query string — sem isso, uma midia como 'Instagram' seria
    -- reportada como nome de campanha.
    COALESCE(
      fn_normalizar_campanha(m.utm_campaign),
      fn_extrair_utm(m.midia,      'utm_campaign'),
      fn_extrair_utm(m.utm_source, 'utm_campaign')
    )                                       AS campanha_midia,
    fn_normalizar_plataforma(COALESCE(m.midia, m.utm_source)) AS plataforma,
    m.gclid IS NOT NULL                     AS tem_gclid,
    l.source_system                         AS fonte_dados,
    -- O bruto vive ao lado do normalizado porque normalizar sem guardar o
    -- original transforma a normalizacao num ato de fe: ninguem consegue
    -- conferir se a regra fez a coisa certa. A aba Qualidade de dados usa
    -- estas duas para mostrar o que a fonte mandou.
    m.utm_campaign                          AS campanha_midia_bruta,
    COALESCE(m.midia, m.utm_source)         AS plataforma_bruta
  FROM lead l
  LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
  LEFT JOIN conv c ON c.lead_id = l.id
  LEFT JOIN primeiro p ON p.lead_id = l.id
  LEFT JOIN ultimo u ON u.lead_id = l.id
  LEFT JOIN midia m ON m.lead_id = l.id
  LEFT JOIN estagio est ON est.lead_id = l.id
) base;

CREATE OR REPLACE VIEW view_campanha_lead AS
SELECT
  e.origem_conversao,
  e.lead_id,
  count(*)            AS conversoes_nesta_origem,
  min(e.occurred_at)  AS primeira_em,
  max(e.occurred_at)  AS ultima_em,
  to_char(min(e.occurred_at), 'YYYY') || '-Q' || to_char(min(e.occurred_at), 'Q') AS trimestre_primeira,
  -- Mesma normalizacao da view_lead_perfil (064/065): sem ela
  -- `[SB]+CAMPANHA_WEBINAR` e `[SB] CAMPANHA_WEBINAR` apareciam como duas
  -- campanhas, partindo 22 leads ao meio na visao de ROI.
  COALESCE(
    fn_normalizar_campanha(max(e.utm_campaign)),
    fn_extrair_utm(max(e.midia),      'utm_campaign'),
    fn_extrair_utm(max(e.utm_source), 'utm_campaign')
  ) AS campanha_midia,
  fn_normalizar_plataforma(max(COALESCE(e.midia, e.utm_source))) AS plataforma,
  bool_or(e.gclid IS NOT NULL) AS tem_gclid,
  l.is_teste,
  l.segmento_cache    AS segmento
FROM lead_conversion_event e
JOIN (
  SELECT l.id, l.is_teste, fn_segmento_contrato(loc.segmento) AS segmento_cache
  FROM lead l
  LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
) l ON l.id = e.lead_id
GROUP BY e.origem_conversao, e.lead_id, l.is_teste, l.segmento_cache;

-- DROP levou os privilegios; sem isto a API volta a dar "permission denied",
-- que e o mesmo modo de falha que a migration 049 corrigiu.
GRANT SELECT ON view_lead_perfil, view_campanha_lead TO crm_ingest;
