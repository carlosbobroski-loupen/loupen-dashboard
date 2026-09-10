-- db/migrations/067_qualidade_plataformas_sem_regra.sql
-- Subtask 8.24 — expoe na aba Qualidade de dados as plataformas cujo valor
-- bruto nao casou com nenhuma regra de `plataforma_regra`.
--
-- Mesmo papel de `cargos_sem_regra` (contrato 1.3): o valor sem regra e o
-- SINAL para escrever regra, e esconde-lo faria a normalizacao parecer
-- completa quando nao esta. Foi exatamente essa lista, no caso dos cargos,
-- que revelou em minutos que minha regra `'Outro'` (match exato) nao pegava
-- `Outros` — 27 leads.
--
-- Mostra o bruto E o normalizado lado a lado, porque a pergunta util nao e
-- so "qual valor nao tem regra", e "o que a funcao fez com ele na falta de
-- regra" — que hoje e devolver o valor decodificado como esta.

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
             'regra',  r.nome, 'campo', r.campo, 'padrao', r.padrao,
             'motivo', r.motivo, 'ativa', r.ativo, 'leads', COALESCE(c.n, 0)
           ) ORDER BY COALESCE(c.n, 0) DESC, r.nome) AS j
    FROM lead_teste_regra r
    LEFT JOIN (
      SELECT teste_regra, count(*) AS n
      FROM lead WHERE is_teste AND teste_regra IS NOT NULL
      GROUP BY teste_regra
    ) c ON c.teste_regra = r.nome
  ),
  orfaos AS (SELECT count(*) AS n FROM lead WHERE is_teste AND teste_regra IS NULL),
  cargos_sem_regra AS (
    SELECT jsonb_agg(jsonb_build_object('cargo', cargo, 'leads', n) ORDER BY n DESC, cargo) AS j
    FROM (
      SELECT l.cargo, count(*) AS n FROM lead l
      WHERE l.cargo IS NOT NULL AND btrim(l.cargo) <> ''
        AND fn_cargo_grupo(l.cargo) = 'outros'
      GROUP BY l.cargo LIMIT 25
    ) t
  ),
  tamanhos_nao_lidos AS (
    SELECT jsonb_agg(jsonb_build_object('valor', tamanho_empresa_bruto, 'leads', n) ORDER BY n DESC) AS j
    FROM (
      SELECT l.tamanho_empresa_bruto, count(*) AS n FROM lead l
      WHERE l.tamanho_empresa_bruto IS NOT NULL AND btrim(l.tamanho_empresa_bruto) <> ''
        AND fn_normalizar_tamanho_empresa(l.tamanho_empresa_bruto) = 'nao_informado'
      GROUP BY 1 LIMIT 25
    ) t
  ),
  -- Plataformas cujo valor bruto nao casou com nenhuma regra de
  -- plataforma_regra. Mesmo papel de `cargos_sem_regra`: e o sinal para
  -- escrever regra, e escondê-lo faria a normalizacao parecer completa.
  plataformas_sem_regra AS (
    SELECT jsonb_agg(jsonb_build_object('valor', bruto, 'normalizado', norm, 'leads', n)
                     ORDER BY n DESC, bruto) AS j
    FROM (
      SELECT v.plataforma_bruta AS bruto,
             v.plataforma       AS norm,
             count(*)           AS n
      FROM view_lead_perfil v
      WHERE v.plataforma_bruta IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM plataforma_regra r
          WHERE lower(btrim(COALESCE(fn_extrair_utm(v.plataforma_bruta,'utm_source'),
                                     fn_decodificar_utm(v.plataforma_bruta)))) = lower(r.padrao)
        )
      GROUP BY 1, 2 LIMIT 25
    ) t
  ),
  cobertura AS (
    SELECT jsonb_build_object(
      'leads_total',          (SELECT count(*) FROM lead),
      'leads_visiveis',       (SELECT count(*) FROM lead WHERE NOT is_teste),
      'leads_marcados_teste', (SELECT count(*) FROM lead WHERE is_teste),
      'com_cargo',            (SELECT count(*) FROM lead WHERE NOT is_teste AND cargo IS NOT NULL),
      'com_tamanho',          (SELECT count(*) FROM lead WHERE NOT is_teste AND tamanho_empresa_bruto IS NOT NULL),
      'com_tags',             (SELECT count(*) FROM lead WHERE NOT is_teste AND tags IS NOT NULL AND array_length(tags,1) > 0),
      'com_atendente',        (SELECT count(*) FROM lead WHERE NOT is_teste AND atendido_por IS NOT NULL),
      'sem_conversao',        (SELECT count(*) FROM lead l WHERE NOT l.is_teste
                                 AND NOT EXISTS (SELECT 1 FROM lead_conversion_event e WHERE e.lead_id = l.id))
    ) AS j
  ),
  -- Agrupamento DINÂMICO. `nao_medido` é o rótulo do NULL, para que a
  -- interface não precise tratar ausência como caso especial.
  atrib_estados AS (
    SELECT jsonb_agg(jsonb_build_object('status', st, 'eventos', n) ORDER BY n DESC) AS j
    FROM (
      SELECT COALESCE(atribuicao_status, 'nao_medido') AS st, count(*) AS n
      FROM lead_conversion_event GROUP BY 1
    ) t
  ),
  atribuicao AS (
    SELECT jsonb_build_object(
      'eventos_total', count(*),
      'com_utm',       count(*) FILTER (WHERE utm_campaign IS NOT NULL OR utm_source IS NOT NULL),
      'com_gclid',     count(*) FILTER (WHERE gclid IS NOT NULL),
      'com_midia',     count(*) FILTER (WHERE midia IS NOT NULL),
      'sessao_direta', count(*) FILTER (WHERE primeiro_toque_bruto = '(none)'),
      -- Eventos sem NENHUM sinal de origem: nem sessão, nem utm, nem mídia.
      -- É o número honesto de "não sabemos de onde veio", e é menor que
      -- qualquer contagem por status isolado.
      'sem_nenhum_sinal', count(*) FILTER (
        WHERE primeiro_toque_bruto IS NULL AND ultimo_toque_bruto IS NULL
          AND utm_source IS NULL AND utm_campaign IS NULL AND midia IS NULL)
    ) AS j
    FROM lead_conversion_event
  )
  SELECT jsonb_build_object(
    'regras_teste',       COALESCE((SELECT j FROM regras), '[]'::jsonb),
    'marcados_sem_regra', (SELECT n FROM orfaos),
    'cargos_sem_regra',   COALESCE((SELECT j FROM cargos_sem_regra), '[]'::jsonb),
    'tamanhos_nao_lidos', COALESCE((SELECT j FROM tamanhos_nao_lidos), '[]'::jsonb),
    'plataformas_sem_regra', COALESCE((SELECT j FROM plataformas_sem_regra), '[]'::jsonb),
    'cobertura',          (SELECT j FROM cobertura),
    'atribuicao',         (SELECT j FROM atribuicao)
                          || jsonb_build_object('estados', COALESCE((SELECT j FROM atrib_estados), '[]'::jsonb))
  ) INTO v_out;

  RETURN v_out;
END;
$$;


COMMENT ON FUNCTION fn_qualidade_dados() IS
  'Cumpre data-contract.md 1.6 (exclusao por regra) e 1.3 (valores sem regra: cargo, tamanho e, desde a migration 067, plataforma). O bloco de atribuicao AGRUPA por status em vez de enumerar valores conhecidos. Expoe tambem sem_nenhum_sinal: eventos sem sessao, sem utm e sem midia — o numero honesto de "nao sabemos de onde veio".';
