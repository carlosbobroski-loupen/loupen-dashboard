-- db/migrations/083_view_pessoa_jornada_desfecho.sql
--
-- A PERGUNTA DO USUÁRIO, ESCRITA EM SQL.
--
-- Dita por ele em 2026-09-15: "cada lead vai ter várias entradas -- conversão
-- de mídia paga, conversão em evento, conversão em e-book. A gente vai ter um
-- array de várias informações, tudo atrelado pelo RD Station. Lá no Salesforce
-- a gente vai olhar o que gerou de oportunidade, se teve negociação, perda,
-- ganho, reunião agendada."
--
-- GRÃO: UMA LINHA POR PESSOA (view_pessoa, migration 082).
--   Lado esquerdo  -> RD Station: o ARRAY de conversões e a atribuição.
--   Lado direito   -> Salesforce: o DESFECHO, em colunas.
--
-- As oportunidades vêm AGREGADAS. A view não multiplica linha por oportunidade
-- -- esse é o defeito que `view_lead_360` tem no próprio nome (diz "360 do
-- lead", tem grão de oportunidade) e que a §1.7 do data-contract existe para
-- impedir.
--
-- O DESFECHO vem de `opportunity_stage_fase` (migration 079), que traduz os 29
-- valores de stage_name em seis fases ordenadas. Estágio que a tabela não
-- conhece NÃO é colapsado num balde: ele conta em `qtd_estagio_sem_fase`, que
-- aparece na tela. São 5 valores hoje (Lista, Pending Sale, Pending Payment,
-- Processamento Interno, Projeto para o Futuro) -- nenhum diz sozinho se a
-- venda aconteceu, e chutar contaminaria a taxa de ganho.
--
-- RECEITA: expõe as duas bases de cálculo (`amount` e `mrr`) porque a decisão
-- de qual sustenta receita está em aberto desde a migration 073/080. Quem
-- consome DEVE rotular qual está exibindo.

CREATE OR REPLACE VIEW view_pessoa_jornada_desfecho AS
WITH
-- ── ESQUERDA: o array de conversões do RD ────────────────────────────────────
conv AS (
  SELECT
    p.pessoa_chave,
    count(*)                                                    AS qtd_conversoes,
    min(e.occurred_at)                                          AS primeira_conversao_em,
    max(e.occurred_at)                                          AS ultima_conversao_em,
    array_agg(DISTINCT e.origem_conversao)
      FILTER (WHERE e.origem_conversao IS NOT NULL)             AS origens_conversao,
    -- Atribuição de mídia paga. O valor do ÚLTIMO evento que trouxe cada sinal,
    -- não um min() arbitrário -- a última conversão é a que atribui.
    (array_agg(e.utm_campaign ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_campaign IS NOT NULL))[1]            AS utm_campaign,
    (array_agg(e.midia ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.midia IS NOT NULL))[1]                   AS plataforma,
    (array_agg(e.utm_id ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_id IS NOT NULL))[1]                  AS id_anuncio,
    (array_agg(e.utm_content ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_content IS NOT NULL))[1]             AS criativo,
    (array_agg(e.utm_term ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_term IS NOT NULL))[1]                AS publico,
    count(*) FILTER (WHERE e.utm_campaign IS NOT NULL)          AS qtd_conversoes_pagas,
    (array_agg(e.cargo ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.cargo IS NOT NULL))[1]                   AS cargo,
    (array_agg(e.tamanho_empresa ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.tamanho_empresa IS NOT NULL))[1]         AS tamanho_empresa
  FROM view_pessoa p
  JOIN lead_conversion_event e ON e.lead_id = p.rd_lead_id
  GROUP BY p.pessoa_chave
),
-- ── DIREITA: contas da pessoa. TODAS, sem colapsar ───────────────────────────
contas AS (
  SELECT DISTINCT p.pessoa_chave, a.id AS account_id, a.nome AS conta_nome
  FROM view_pessoa p
  JOIN lead l  ON l.id = p.sf_lead_id
  JOIN account a ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
),
-- ── DIREITA: o desfecho comercial, agregado ──────────────────────────────────
desfecho AS (
  SELECT
    ct.pessoa_chave,
    count(DISTINCT ct.account_id)                                     AS qtd_contas,
    count(DISTINCT o.id)                                              AS qtd_oportunidades,
    bool_or(f.fase = 'reuniao')                                       AS teve_reuniao,
    bool_or(f.fase = 'negociacao')                                    AS chegou_a_negociar,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'ganho')              AS qtd_ganhas,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'perdido')            AS qtd_perdidas,
    count(DISTINCT o.id) FILTER (WHERE f.fase IS NULL)                AS qtd_estagio_sem_fase,
    -- Desempate explicito: ganho vence perdido (migration 085).
    (array_agg(f.fase ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS fase_mais_avancada,
    max(f.ordem)                                                      AS fase_ordem,
    (array_agg(o.stage_name ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS estagio_mais_avancado,
    max(o.record_type_name)                                           AS record_type,
    max(o.closed_at_source)                                           AS ultima_movimentacao_em,
    sum(o.amount) FILTER (WHERE f.fase = 'ganho')                     AS amount_ganho,
    sum(o.mrr)    FILTER (WHERE f.fase = 'ganho')                     AS mrr_ganho,
    sum(o.amount * o.duracao_meses_contrato) FILTER (WHERE f.fase = 'ganho')
                                                                      AS contrato_por_amount,
    sum(o.mrr    * o.duracao_meses_contrato) FILTER (WHERE f.fase = 'ganho')
                                                                      AS contrato_por_mrr,
    string_agg(DISTINCT ct.conta_nome, ' · ')                         AS conta_nome
  FROM contas ct
  JOIN opportunity o ON o.account_id = ct.account_id
  LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  GROUP BY ct.pessoa_chave
),
-- Classificação de origem: a do registro do RD quando existe, senão a do SF.
-- O RD tem o sinal de conversão; o SF tem o LeadSource. Regra declarada.
classif AS (
  SELECT
    p.pessoa_chave,
    coalesce(crd.segmento,  csf.segmento)  AS segmento,
    coalesce(crd.categoria, csf.categoria) AS categoria,
    coalesce(crd.detalhe,   csf.detalhe)   AS detalhe,
    CASE WHEN crd.segmento IS NOT NULL THEN 'rd_station' ELSE 'salesforce' END AS classificado_por
  FROM view_pessoa p
  LEFT JOIN lead_origin_classification crd ON crd.lead_id = p.rd_lead_id AND crd.valid_to IS NULL
  LEFT JOIN lead_origin_classification csf ON csf.lead_id = p.sf_lead_id AND csf.valid_to IS NULL
)
SELECT
  p.pessoa_chave,
  p.nome,
  p.empresa,
  p.chave_origem,
  p.fontes,
  p.rd_lead_id,
  p.sf_lead_id,
  p.primeiro_registro_em,
  -- ── atribuição ──
  cl.segmento,
  cl.categoria,
  cl.detalhe,
  cl.classificado_por,
  lrd.lista_regra,
  (lrd.lista_regra IS NOT NULL)                       AS de_lista_importada,
  -- ── esquerda: a jornada ──
  coalesce(cv.qtd_conversoes, 0)                      AS qtd_conversoes,
  cv.origens_conversao,
  cv.primeira_conversao_em,
  cv.ultima_conversao_em,
  cv.utm_campaign,
  cv.plataforma,
  cv.id_anuncio,
  cv.criativo,
  cv.publico,
  coalesce(cv.qtd_conversoes_pagas, 0)                AS qtd_conversoes_pagas,
  coalesce(cv.cargo, lrd.cargo, lsf.cargo)            AS cargo,
  cv.tamanho_empresa,
  -- ── direita: o desfecho ──
  (p.sf_lead_id IS NOT NULL)                          AS existe_no_salesforce,
  lsf.status                                          AS status_no_salesforce,
  coalesce(d.qtd_contas, 0)                           AS qtd_contas,
  d.conta_nome,
  coalesce(d.qtd_oportunidades, 0)                    AS qtd_oportunidades,
  coalesce(d.teve_reuniao, false)                     AS teve_reuniao,
  coalesce(d.chegou_a_negociar, false)                AS chegou_a_negociar,
  coalesce(d.qtd_ganhas, 0)                           AS qtd_ganhas,
  coalesce(d.qtd_perdidas, 0)                         AS qtd_perdidas,
  coalesce(d.qtd_estagio_sem_fase, 0)                 AS qtd_estagio_sem_fase,
  d.fase_mais_avancada,
  d.fase_ordem,
  d.estagio_mais_avancado,
  d.record_type,
  d.ultima_movimentacao_em,
  d.amount_ganho,
  d.mrr_ganho,
  d.contrato_por_amount,
  d.contrato_por_mrr,
  -- ── dimensoes de filtro (ver JOIN com view_lead_perfil abaixo) ──
  coalesce(prd.trimestre,      psf.trimestre)      AS trimestre,
  coalesce(prd.cargo_grupo,    psf.cargo_grupo)    AS cargo_grupo,
  coalesce(prd.atendido_por,   psf.atendido_por)   AS atendido_por,
  coalesce(prd.estagio_funil,  psf.estagio_funil)  AS estagio_funil,
  coalesce(prd.tags,           psf.tags)           AS tags,
  coalesce(prd.fonte_dados,    psf.fonte_dados)    AS fonte_dados
FROM view_pessoa p
LEFT JOIN lead lrd      ON lrd.id = p.rd_lead_id
LEFT JOIN lead lsf      ON lsf.id = p.sf_lead_id
-- Dimensoes que a barra de filtros da aba Leads ja usa. Vem de view_lead_perfil
-- para NAO reimplementar as regras de normalizacao (cargo_grupo, tamanho,
-- trimestre) numa segunda view -- duas implementacoes da mesma regra divergem,
-- e foi assim que o ramo do webhook divergiu do ramo do pull por 33 migrations.
-- Preferencia pelo registro do RD (tem a firmografia); Salesforce como reserva.
LEFT JOIN view_lead_perfil prd ON prd.lead_id = p.rd_lead_id
LEFT JOIN view_lead_perfil psf ON psf.lead_id = p.sf_lead_id
LEFT JOIN conv cv       ON cv.pessoa_chave = p.pessoa_chave
LEFT JOIN desfecho d    ON d.pessoa_chave  = p.pessoa_chave
LEFT JOIN classif cl    ON cl.pessoa_chave = p.pessoa_chave;

COMMENT ON VIEW view_pessoa_jornada_desfecho IS
  'A PERGUNTA CENTRAL DO ÉPICO. GRÃO: UMA LINHA POR PESSOA. Esquerda = array de conversões do RD (origens_conversao) + atribuição de mídia paga (id_anuncio, criativo, público). Direita = desfecho comercial do Salesforce em colunas (teve_reuniao, chegou_a_negociar, fase_mais_avancada, ganhas, perdidas), traduzido por opportunity_stage_fase. NÃO multiplica por oportunidade. Receita exposta nas DUAS bases (amount e mrr) -- a decisão de qual vale está em aberto. Migration 083.';

GRANT SELECT ON view_pessoa_jornada_desfecho TO crm_ingest;
