-- db/migrations/055_fn_qualidade_dados.sql
-- Subtask 8.12 — cumpre duas promessas escritas no contrato de dados que
-- ainda não tinham implementação.
--
-- §1.6 prometia: "a aba Qualidade de dados mostra quantos leads cada regra
-- excluiu". A marcação existia (lead.is_teste + lead.teste_regra), a
-- contagem por regra não. Sem ela, a promessa de "exclusão nunca silenciosa"
-- era só uma intenção: o lead saía dos filtros e ninguém via por quê.
--
-- §1.3 prometia: "a aba Qualidade de dados mostra os `outros` mais
-- frequentes para que a tabela evolua com evidência". Mesma situação.
--
-- A função devolve UM jsonb porque é isso que a aba consome de uma vez — e
-- porque manter a forma da resposta no banco (em vez de montá-la em JS no
-- n8n) deixa o formato versionado junto com as migrations.
--
-- DUAS COISAS QUE ESTA FUNÇÃO EXPÕE DE PROPÓSITO, MESMO SENDO DESCONFORTÁVEIS
--
--   1. `cargos_sem_regra` — se voltar não-vazio, alguém tem de escrever
--      regra. Esconder isso faria `cargo_grupo` parecer completo quando não
--      está.
--   2. `eventos_sem_atribuicao` — 72% dos eventos do primeiro lote real não
--      têm `traffic_source` decodificável. Eu havia apresentado a atribuição
--      de primeiro/último toque como "nativa e de graça"; é nativa, mas não
--      é universal, e o número tem de aparecer na tela em vez de só no log.

CREATE OR REPLACE FUNCTION fn_qualidade_dados()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_out jsonb;
BEGIN
  WITH
  -- Uma linha por REGRA, inclusive as que não pegaram ninguém. LEFT JOIN de
  -- propósito: regra com 0 leads é informação (ou a regra está errada, ou o
  -- problema que ela cobre não ocorre mais), e omiti-la esconderia isso.
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
  -- Lead marcado como teste SEM regra registrada não deveria existir: quem
  -- marca sempre grava a regra. Se aparecer, é sinal de marcação feita fora
  -- do caminho previsto (UPDATE manual, por exemplo) e a aba tem de mostrar.
  orfaos AS (
    SELECT count(*) AS n FROM lead WHERE is_teste AND teste_regra IS NULL
  ),
  -- §1.3: os cargos que nenhuma regra classificou.
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
  -- Tamanho de empresa em texto livre que a normalização não conseguiu ler.
  -- Distinto de "campo vazio": aqui o dado existe e não foi entendido.
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
      'eventos_total',            count(*),
      'com_primeiro_toque',       count(*) FILTER (WHERE primeiro_toque_bruto IS NOT NULL),
      'sem_atribuicao',           count(*) FILTER (WHERE primeiro_toque_bruto IS NULL AND ultimo_toque_bruto IS NULL),
      'sessao_direta',            count(*) FILTER (WHERE primeiro_toque_bruto = '(none)'),
      'com_utm',                  count(*) FILTER (WHERE utm_campaign IS NOT NULL OR utm_source IS NOT NULL),
      'com_gclid',                count(*) FILTER (WHERE gclid IS NOT NULL)
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
  'Cumpre as promessas do data-contract.md §1.6 (contagem de exclusão POR REGRA — exclusão silenciosa é proibida) e §1.3 (cargos que nenhuma regra classificou, para a tabela de regras evoluir com evidência). Expõe de propósito os números desconfortáveis: cargos sem regra, tamanhos não lidos e eventos sem atribuição decodificável.';

GRANT EXECUTE ON FUNCTION fn_qualidade_dados() TO crm_ingest;
