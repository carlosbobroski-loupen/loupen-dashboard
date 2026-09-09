-- db/migrations/052_segmento_contrato_e_marcar_seed.sql
-- Subtask 8.9 — dois desalinhamentos encontrados ao consultar a view com dado
-- real. Nenhum dos dois é bug de código: um é o contrato descrevendo errado o
-- que o banco faz, o outro é resíduo dos meus próprios testes.
--
-- ── 1. VOCABULÁRIO DE SEGMENTO: O CONTRATO ESTAVA ERRADO ──────────────────
-- data-contract.md dizia que `segmento` é `marketing | comercial |
-- nao_atribuido` — três valores, minúsculos. O banco tem uma CHECK
-- constraint em lead_origin_classification com QUATRO valores em CamelCase:
--   Marketing, Comercial, NaoAtribuido, Parceiro
--
-- Quem estava errado era o contrato. `Parceiro` é uma classificação real,
-- prevista na constraint desde a migration que criou a tabela, e colapsá-la
-- em um dos outros três para "caber" no contrato destruiria informação de
-- negócio (parceiro não é marketing nem comercial).
--
-- Decisão: a API expõe o vocabulário em snake_case (convenção do contrato
-- para valores de query param), e o banco mantém o CamelCase interno. A
-- tradução fica numa função, não espalhada em CASE por consulta — assim
-- existe UM lugar para conferir se os dois lados batem.
--
-- ── 2. OS 13 LEADS DE SEED EM PRODUÇÃO ────────────────────────────────────
-- `lead` tem 13 registros com source_system = 'seed_test': fixtures dos meus
-- testes de ingestão, criados antes da ingestão real existir. Eles apareceram
-- na view com trimestre NULL e sem conversão, poluindo toda contagem.
--
-- Não são deletados — a regra do §1.6 é marcar, nunca deletar, e há 2
-- lead_touchpoint apontando para eles. Ficam com is_teste = true e regra
-- explícita, exatamente como qualquer outro dado de teste, e portanto somem
-- dos filtros por padrão sem que nada seja perdido.

-- ---------------------------------------------------------------------------
-- 1. Tradução do vocabulário
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_segmento_contrato(p_segmento text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_segmento
           WHEN 'Marketing'    THEN 'marketing'
           WHEN 'Comercial'    THEN 'comercial'
           WHEN 'Parceiro'     THEN 'parceiro'
           WHEN 'NaoAtribuido' THEN 'nao_atribuido'
           -- Ausência de classificação cai em nao_atribuido (AC-5.2), jamais
           -- em comercial. Valor desconhecido também: é melhor a API devolver
           -- nao_atribuido do que um valor que a interface não sabe pintar.
           ELSE 'nao_atribuido'
         END;
$$;
COMMENT ON FUNCTION fn_segmento_contrato(text) IS
  'Traduz o vocabulário interno de segmento (CamelCase, travado por CHECK em lead_origin_classification: Marketing/Comercial/NaoAtribuido/Parceiro) para o snake_case que a API expõe. Único ponto de tradução — se o CHECK ganhar um valor novo e esta função não, o valor novo cai em nao_atribuido e a divergência aparece na aba Qualidade de dados em vez de vazar cru para a interface.';

-- Asserção: todo valor permitido pela CHECK tem tradução própria. Se alguém
-- acrescentar um valor à constraint e esquecer desta função, isto falha aqui
-- em vez de silenciosamente virar `nao_atribuido` em produção.
DO $$
DECLARE
  v_sem_traducao text;
BEGIN
  SELECT string_agg(v, ', ') INTO v_sem_traducao
  FROM unnest(ARRAY['Marketing','Comercial','NaoAtribuido','Parceiro']) AS v
  WHERE fn_segmento_contrato(v) = 'nao_atribuido' AND v <> 'NaoAtribuido';

  IF v_sem_traducao IS NOT NULL THEN
    RAISE EXCEPTION 'Valor(es) de segmento sem traducao propria: %', v_sem_traducao;
  END IF;
  RAISE NOTICE 'OK: os 4 valores da CHECK de segmento tem traducao propria.';
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Marca os leads de seed como teste
-- ---------------------------------------------------------------------------
INSERT INTO lead_teste_regra (nome, campo, padrao, motivo) VALUES
  ('lead de seed de teste', 'source_system', '^seed_test$',
   'Fixtures das minhas proprias verificacoes de ingestao, criados antes de a ingestao real existir. Marcados em vez de deletados porque ha lead_touchpoint apontando para eles e porque a regra do contrato 1.6 e nunca deletar.')
ON CONFLICT (nome) DO NOTHING;

UPDATE lead
   SET is_teste = true,
       teste_regra = COALESCE(teste_regra, 'lead de seed de teste'),
       ingested_at = now()
 WHERE source_system = 'seed_test' AND NOT is_teste;

-- ---------------------------------------------------------------------------
-- 3. Views recriadas com o segmento traduzido
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW view_lead_perfil AS
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
    m.utm_campaign                          AS campanha_midia,
    COALESCE(m.midia, m.utm_source)         AS plataforma,
    m.gclid IS NOT NULL                     AS tem_gclid,
    l.source_system                         AS fonte_dados
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
  max(e.utm_campaign) AS campanha_midia,
  max(COALESCE(e.midia, e.utm_source)) AS plataforma,
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
