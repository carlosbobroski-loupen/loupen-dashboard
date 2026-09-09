-- db/migrations/059_fn_qualidade_dados_atribuicao.sql
-- Subtask 8.16 — faz a aba de qualidade usar `atribuicao_status` (057/058).
--
-- Antes desta migration o bloco de atribuição contava apenas
-- `primeiro_toque_bruto IS NULL`, somando num número só dois problemas
-- diferentes. Agora separa:
--
--   ok        a fonte mandou `traffic_source` e decodificamos
--   ausente   a fonte NÃO mandou — limitação da origem, sem ação nossa
--   ilegivel  mandou e não conseguimos ler — BUG NOSSO, tem correção
--   nao_medido evento ingerido antes da 057 e ainda não reprocessado
--
-- `ilegivel` é o número que importa vigiar: se ele crescer, a decodificação
-- de base64 quebrou para alguma forma nova de payload, e isso é acionável.
-- `ausente` alto é desconfortável mas não é defeito de software.
--
-- `nao_medido` existe porque a 057 deliberadamente não retroagiu a coluna:
-- sem reingerir, não há como saber qual dos dois casos era, e preencher um
-- palpite apagaria a lacuna em vez de mostrá-la. Uma reingestão zera este
-- número (a 058 permite completar o status sem tocar outro campo).

CREATE OR REPLACE FUNCTION fn_qualidade_dados()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_out jsonb;
BEGIN
  WITH
  regras AS (
    SELECT jsonb_agg(jsonb_build_object(
             'regra',  r.nome,
             'campo',  r.campo,
             'padrao', r.padrao,
             'motivo', r.motivo,
             'ativa',  r.ativo,
             'leads',  COALESCE(c.n, 0)
           ) ORDER BY COALESCE(c.n, 0) DESC, r.nome) AS j
    FROM lead_teste_regra r
    LEFT JOIN (
      SELECT teste_regra, count(*) AS n
      FROM lead WHERE is_teste AND teste_regra IS NOT NULL
      GROUP BY teste_regra
    ) c ON c.teste_regra = r.nome
  ),
  orfaos AS (
    SELECT count(*) AS n FROM lead WHERE is_teste AND teste_regra IS NULL
  ),
  cargos_sem_regra AS (
    SELECT jsonb_agg(jsonb_build_object('cargo', cargo, 'leads', n)
                     ORDER BY n DESC, cargo) AS j
    FROM (
      SELECT l.cargo, count(*) AS n
      FROM lead l
      WHERE l.cargo IS NOT NULL AND btrim(l.cargo) <> ''
        AND fn_cargo_grupo(l.cargo) = 'outros'
      GROUP BY l.cargo
      LIMIT 25
    ) t
  ),
  tamanhos_nao_lidos AS (
    SELECT jsonb_agg(jsonb_build_object('valor', tamanho_empresa_bruto, 'leads', n)
                     ORDER BY n DESC) AS j
    FROM (
      SELECT l.tamanho_empresa_bruto, count(*) AS n
      FROM lead l
      WHERE l.tamanho_empresa_bruto IS NOT NULL
        AND btrim(l.tamanho_empresa_bruto) <> ''
        AND fn_normalizar_tamanho_empresa(l.tamanho_empresa_bruto) = 'nao_informado'
      GROUP BY 1
      LIMIT 25
    ) t
  ),
  cobertura AS (
    SELECT jsonb_build_object(
      'leads_total',            (SELECT count(*) FROM lead),
      'leads_visiveis',         (SELECT count(*) FROM lead WHERE NOT is_teste),
      'leads_marcados_teste',   (SELECT count(*) FROM lead WHERE is_teste),
      'com_cargo',              (SELECT count(*) FROM lead WHERE NOT is_teste AND cargo IS NOT NULL),
      'com_tamanho',            (SELECT count(*) FROM lead WHERE NOT is_teste AND tamanho_empresa_bruto IS NOT NULL),
      'com_tags',               (SELECT count(*) FROM lead WHERE NOT is_teste AND tags IS NOT NULL AND array_length(tags,1) > 0),
      'com_atendente',          (SELECT count(*) FROM lead WHERE NOT is_teste AND atendido_por IS NOT NULL),
      'sem_conversao',          (SELECT count(*) FROM lead l WHERE NOT l.is_teste
                                   AND NOT EXISTS (SELECT 1 FROM lead_conversion_event e WHERE e.lead_id = l.id))
    ) AS j
  ),
  atribuicao AS (
    SELECT jsonb_build_object(
      'eventos_total',      count(*),
      -- Os três estados reais + o não medido (evento anterior à 057).
      'ok',                 count(*) FILTER (WHERE atribuicao_status = 'ok'),
      'ausente',            count(*) FILTER (WHERE atribuicao_status = 'ausente'),
      'ilegivel',           count(*) FILTER (WHERE atribuicao_status = 'ilegivel'),
      'nao_medido',         count(*) FILTER (WHERE atribuicao_status IS NULL),
      -- Mantidos para não quebrar quem já lê estes campos.
      'com_primeiro_toque', count(*) FILTER (WHERE primeiro_toque_bruto IS NOT NULL),
      'sessao_direta',      count(*) FILTER (WHERE primeiro_toque_bruto = '(none)'),
      'com_utm',            count(*) FILTER (WHERE utm_campaign IS NOT NULL OR utm_source IS NOT NULL),
      'com_gclid',          count(*) FILTER (WHERE gclid IS NOT NULL),
      'sem_atribuicao',     count(*) FILTER (WHERE primeiro_toque_bruto IS NULL AND ultimo_toque_bruto IS NULL)
    ) AS j
    FROM lead_conversion_event
  )
  SELECT jsonb_build_object(
    'regras_teste',       COALESCE((SELECT j FROM regras), '[]'::jsonb),
    'marcados_sem_regra', (SELECT n FROM orfaos),
    'cargos_sem_regra',   COALESCE((SELECT j FROM cargos_sem_regra), '[]'::jsonb),
    'tamanhos_nao_lidos', COALESCE((SELECT j FROM tamanhos_nao_lidos), '[]'::jsonb),
    'cobertura',          (SELECT j FROM cobertura),
    'atribuicao',         (SELECT j FROM atribuicao)
  ) INTO v_out;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION fn_qualidade_dados() IS
  'Cumpre data-contract.md §1.6 (exclusão de dado de teste POR REGRA) e §1.3 (valores sem regra de classificação). Desde a migration 059 separa a atribuição em ok/ausente/ilegivel/nao_medido — `ilegivel` é o único acionável do nosso lado, `ausente` é limitação da fonte, e somá-los (como fazia antes) escondia essa diferença.';
