-- db/migrations/045_lead_conversion_event.sql
-- Subtask 8.2 — a lacuna que a revisão de contrato de 2026-09-09 expôs.
--
-- CONTEXTO DO ERRO QUE ESTA MIGRATION CORRIGE
-- O contrato de dados original definiu 4 filtros (segmento, canal, campanha,
-- período) sem que ninguém tivesse enumerado os campos que a fonte entrega.
-- Inventário executado em 2026-09-09 contra a API de produção do RD Station
-- encontrou 35 campos, e uma medição de cobertura em 250 contatos reais
-- (0 erros) decidiu quais viram filtro. Ver data-contract.md §1.1.
--
-- ACHADO QUE DEFINE A MODELAGEM DESTA TABELA
-- O payload de cada evento de conversão carrega a firmografia do MOMENTO da
-- conversão, não o estado atual do cadastro. Verificado nos dados reais: o
-- mesmo contato aparece como `Diretor` num evento e `CEO, Founder, Sócio`
-- noutro; `cf_tamanho_da_empresa` vai de `1 a 19 funcionários` para
-- `20 a 99 funcionários`. O cadastro guarda só o último valor — o evento
-- guarda a história. Logo: firmografia e atribuição são atributos DO EVENTO,
-- e gravá-las apenas em `lead` perderia informação que a fonte já tem.
--
-- occurred_at é timestamptz (e NÃO date como em lead_funnel_stage_event,
-- migration 039): o endpoint de eventos do RD expõe `event_timestamp` real
-- ao segundo. A granularidade é genuinamente intradiária aqui.
--
-- DEDUPLICAÇÃO (data-contract.md §1.7)
-- Encontrei nos dados reais o MESMO evento, mesmo contato, mesmo
-- event_timestamp ao segundo, repetido — diferindo só na codificação
-- percentual de um acento na URL de sessão. É duplicata de fonte. A UNIQUE
-- abaixo é a regra de negócio, não só trava técnica: dois eventos do mesmo
-- lead, mesma origem, mesmo instante SÃO o mesmo evento.

CREATE TABLE IF NOT EXISTS lead_conversion_event (
  id                       bigserial PRIMARY KEY,
  lead_id                  bigint NOT NULL REFERENCES lead(id),

  -- Eixo A do contrato (§1.2): `conversion_identifier` da fonte. Cobertura
  -- medida de 100%. NUNCA portador de valor de investimento.
  origem_conversao         text NOT NULL,
  event_type               text NOT NULL DEFAULT 'CONVERSION',
  occurred_at              timestamptz NOT NULL,

  -- Firmografia no instante do evento (ver cabeçalho).
  empresa_bruta            text,
  cargo                    text,
  tamanho_empresa_bruto    text,
  tamanho_empresa          text,

  -- Atribuição. `traffic_source` chega da fonte como `encoded_` + base64 de
  -- um JSON com first_session/current_session; a decodificação acontece no
  -- n8n (JS tem base64 nativo) e o valor CRU de cada sessão é preservado
  -- aqui para auditoria — quando não há UTM, a fonte manda a URL da sessão
  -- ou o literal `(none)`, e ambos são informação.
  primeiro_toque_bruto     text,
  ultimo_toque_bruto       text,

  -- Eixo B do contrato (§1.2): único eixo que pode receber investimento.
  -- Cobertura medida de 7,6% — baixa de propósito registrada, não é bug.
  utm_source               text,
  utm_medium               text,
  utm_campaign             text,
  utm_content              text,
  utm_term                 text,
  utm_id                   text,
  gclid                    text,
  midia                    text,
  campanha_de_origem       text,

  source_system            text NOT NULL DEFAULT 'rd_station',
  collected_at             timestamptz NOT NULL,
  ingested_at              timestamptz NOT NULL DEFAULT now(),

  UNIQUE (lead_id, origem_conversao, occurred_at)
);
COMMENT ON TABLE lead_conversion_event IS
  'Evento de conversão do RD Station com a firmografia e a atribuição DO MOMENTO da conversão (verificado nos dados reais: cargo e tamanho de empresa mudam entre eventos do mesmo contato). Grão de dedup em (lead_id, origem_conversao, occurred_at) é regra de negócio — data-contract.md §1.7. origem_conversao é o eixo A e nunca recebe investimento; utm_campaign é o eixo B e é o único que recebe (§1.2).';

CREATE INDEX IF NOT EXISTS ix_lead_conversion_event_lead
  ON lead_conversion_event (lead_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_lead_conversion_event_origem
  ON lead_conversion_event (origem_conversao);
CREATE INDEX IF NOT EXISTS ix_lead_conversion_event_ocorrencia
  ON lead_conversion_event (occurred_at);
-- Eixo B é esparso (7,6%): índice parcial em vez de índice cheio.
CREATE INDEX IF NOT EXISTS ix_lead_conversion_event_utm_campaign
  ON lead_conversion_event (utm_campaign)
  WHERE utm_campaign IS NOT NULL;


-- ---------------------------------------------------------------------------
-- Normalização de tamanho de empresa (data-contract.md §1.4)
--
-- `cf_tamanho_da_empresa` é TEXTO LIVRE e os 91 preenchimentos medidos usam
-- escalas INCOMPATÍVEIS. Valores reais observados, com frequência:
--   38x `1 a 19 funcionários`      19x `1 a 9 funcionários`
--    9x `10 a 49 funcionários`      6x `100 a 249 funcionários`
--    6x `1.000+ funcionários`       5x `500 a 999 funcionários`
--    4x `50 a 99 funcionários`      2x `20 a 99 funcionários`
--    1x `mais de 1000 funcionários` 1x `250 a 499 funcionários`
--
-- As únicas fronteiras comuns às duas escalas são 99/100 e 999/1000. Três
-- faixas é o máximo de granularidade honesta: uma quarta exigiria decidir de
-- que lado do corte cai `10 a 49`, o que seria invenção (Artigo IV).
--
-- Implementação: extrai o MAIOR número do texto e classifica pelo limite
-- superior. Verificado contra os 10 valores reais acima — todos mapeiam sem
-- ambiguidade. O ponto de milhar é removido antes (`1.000+` → `1000+`).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_normalizar_tamanho_empresa(p_bruto text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_limpo  text;
  v_maior  bigint;
BEGIN
  IF p_bruto IS NULL OR btrim(p_bruto) = '' THEN
    RETURN 'nao_informado';
  END IF;

  -- Remove separador de milhar para que `1.000+` vire `1000+` e não 1 e 000.
  v_limpo := replace(replace(p_bruto, '.', ''), ',', '');

  SELECT max(n::bigint) INTO v_maior
  FROM regexp_matches(v_limpo, '(\d+)', 'g') AS m(arr),
       LATERAL unnest(m.arr) AS n;

  IF v_maior IS NULL THEN
    RETURN 'nao_informado';
  ELSIF v_maior >= 1000 THEN
    RETURN 'grande';
  ELSIF v_maior >= 100 THEN
    RETURN 'media';
  ELSE
    RETURN 'pequena';
  END IF;
END;
$$;
COMMENT ON FUNCTION fn_normalizar_tamanho_empresa(text) IS
  'Colapsa cf_tamanho_da_empresa (texto livre, escalas conflitantes) nas 3 faixas canônicas do data-contract.md §1.4. Verificada contra os 10 valores reais observados em 250 contatos.';


-- ---------------------------------------------------------------------------
-- Agrupamento de cargo (data-contract.md §1.3)
--
-- `job_title` tem 90,0% de preenchimento — a melhor cobertura firmográfica
-- da base — mas é texto livre, inutilizável como filtro direto.
--
-- A tabela abaixo é semeada SOMENTE com os valores que eu observei de fato
-- nos dados reais desta conta. NÃO invento uma taxonomia de cargos completa:
-- a lista de valores distintos só existe depois da primeira ingestão cheia,
-- e é dela que as regras restantes devem sair. Tudo sem regra cai em
-- `outros`, e a aba Qualidade de dados expõe os `outros` mais frequentes
-- para a tabela evoluir com evidência.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cargo_grupo_regra (
  id          bigserial PRIMARY KEY,
  padrao      text NOT NULL,
  grupo       text NOT NULL,
  prioridade  int  NOT NULL DEFAULT 100,
  observado   boolean NOT NULL DEFAULT false,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (padrao)
);
COMMENT ON TABLE cargo_grupo_regra IS
  'Mapeia job_title (texto livre) para cargo_grupo. padrao é casado com ILIKE contra o cargo; menor prioridade vence. observado=true marca as regras derivadas de valores REAIS já vistos na base — as demais devem ser semeadas a partir da lista de distintos da primeira ingestão, nunca inventadas (Artigo IV).';

INSERT INTO cargo_grupo_regra (padrao, grupo, prioridade, observado) VALUES
  ('%CEO%',       'c_level',   10, true),
  ('%Founder%',   'c_level',   10, true),
  ('%Sócio%',     'c_level',   10, true),
  ('%Diretor%',   'diretoria', 20, true),
  ('%Gerente%',   'gerencia',  30, true)
ON CONFLICT (padrao) DO NOTHING;

CREATE OR REPLACE FUNCTION fn_cargo_grupo(p_cargo text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_grupo text;
BEGIN
  IF p_cargo IS NULL OR btrim(p_cargo) = '' THEN
    RETURN 'nao_informado';
  END IF;

  SELECT r.grupo INTO v_grupo
  FROM cargo_grupo_regra r
  WHERE p_cargo ILIKE r.padrao
  ORDER BY r.prioridade, r.id
  LIMIT 1;

  RETURN COALESCE(v_grupo, 'outros');
END;
$$;
COMMENT ON FUNCTION fn_cargo_grupo(text) IS
  'Resolve cargo_grupo via cargo_grupo_regra. Retorna outros quando nenhuma regra casa (visível na aba Qualidade de dados) e nao_informado quando o cargo é vazio — os dois casos são distintos de propósito.';


-- ---------------------------------------------------------------------------
-- Dados de teste na base de produção (data-contract.md §1.6)
--
-- A base de produção do RD Station contém dados de teste. Observado de fato:
-- contatos criados em rajada em 04-05/09/2026 com e-mails sintéticos
-- sequenciais e nomes genéricos repetidos; um gclid literal
-- `TEST_GCLID_12345`; e UTMs preenchidas com as próprias palavras
-- `fonte`, `midia`, `nome`, `termo`, `conteúdo`, `campanha` — alguém
-- testando formulário.
--
-- REGRA: marcar, nunca deletar. O lead entra no banco com is_teste e os
-- filtros o excluem por padrão. Exclusão silenciosa é proibida — a aba
-- Qualidade de dados mostra quantos leads cada regra pegou.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_teste_regra (
  id          bigserial PRIMARY KEY,
  nome        text NOT NULL,
  campo       text NOT NULL,
  padrao      text NOT NULL,
  ativo       boolean NOT NULL DEFAULT true,
  motivo      text NOT NULL,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (nome)
);
COMMENT ON TABLE lead_teste_regra IS
  'Regras auditáveis de marcação de dado de teste (data-contract.md §1.6). campo indica sobre o que casar (email, gclid, utm, origem_conversao); padrao é ILIKE. Nunca embutir essas regras em query solta: elas precisam ser inspecionáveis e a contagem por regra tem de aparecer na aba Qualidade de dados.';

INSERT INTO lead_teste_regra (nome, campo, padrao, motivo) VALUES
  ('gclid literal de teste', 'gclid', 'TEST_%',
   'Observado o valor literal TEST_GCLID_12345 nos dados reais.'),
  ('utm com nome do proprio campo', 'utm', 'fonte|midia|nome|termo|conteudo|conteúdo|campanha',
   'Observadas UTMs preenchidas com as palavras dos campos — formulário sendo testado, não campanha real.'),
  ('email sintetico sequencial', 'email', '^(ana|joao|maria|carla|pedro)[0-9]{3}@gmail\.com$',
   'Observados contatos em rajada em 04-05/09/2026 com e-mails sequenciais e nomes genéricos repetidos.')
ON CONFLICT (nome) DO NOTHING;

-- is_teste no lead: default false para que nenhum lead existente mude de
-- estado com esta migration. A marcação é feita pela ingestão.
ALTER TABLE lead ADD COLUMN IF NOT EXISTS is_teste boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN lead.is_teste IS
  'data-contract.md §1.6 — marcado pela ingestão via lead_teste_regra. Os filtros excluem por padrão (incluir_teste=false), mas o registro NUNCA é deletado.';
CREATE INDEX IF NOT EXISTS ix_lead_is_teste ON lead (is_teste) WHERE is_teste;
