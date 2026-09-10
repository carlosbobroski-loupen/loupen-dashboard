-- db/migrations/064_normaliza_plataforma_e_campanha.sql
-- Subtask 8.21 — normaliza plataforma e campanha de mídia paga (eixo B).
--
-- Encontrado ao recalcular a cobertura do eixo B, que subiu de 7,6% para
-- 19,2% depois da correção da forma plana (migration 060). Ao listar as
-- campanhas, três problemas apareceram de uma vez.
--
-- ── 1. UMA CAMPANHA CONTADA DUAS VEZES (bug meu) ──────────────────────────
-- `[SB]+CAMPANHA_WEBINAR` (12 leads) e `[SB] CAMPANHA_WEBINAR` (10) são a
-- MESMA campanha. Em query string, `+` significa espaço — é
-- application/x-www-form-urlencoded. `decodeURIComponent` NÃO converte `+`,
-- só `%20`. Como a fonte manda as duas grafias (`%5BSB%5D+CAMPANHA...` e
-- `[SB]+CAMPANHA...`), o resultado foi uma campanha real partida em duas
-- linhas — direto na visão de ROI por campanha, que é o objetivo do painel.
--
-- ── 2. QUERY STRING INTEIRA DENTRO DE UM CAMPO (problema de origem) ───────
-- 11 eventos têm `cf_midia` E `cf_utm_source` com o valor
-- `utm_source=LinkedIn%20Ads&utm_medium=cpc&utm_campaign=810534183` — a
-- string toda, num campo que devia conter só a fonte. Alguém colou a UTM
-- inteira no campo customizado. A campanha real (`810534183`, LinkedIn) fica
-- enterrada e o painel não a vê.
--
-- Extrair dali NÃO é inventar dado: o valor está literalmente no campo, só
-- está no lugar errado. O que seria invenção é adivinhar campanha onde não há.
--
-- ── 3. VOCABULÁRIO DE PLATAFORMA INCONSISTENTE (problema de origem) ───────
-- Valores reais medidos: META(34) instagram(29) facebook(19) RD+Station(17)
-- ig(7) google(6) GoogleAds(3) fb(3) Facebook(1) chatgpt.com(1).
-- Filtrar por `facebook` perdia `fb`, `Facebook` e `META`.
--
-- ── POR QUE NA VIEW E NÃO NA INGESTÃO ─────────────────────────────────────
-- Mesma razão de `cargo_grupo` e `tamanho_empresa`: são funções puras sobre
-- tabela de regra. Normalizar na gravação exigiria sobrescrever valor já
-- ingerido (perdendo o bruto, que é a evidência) e reingerir tudo a cada
-- regra nova. Derivando na view, o bruto fica intacto e regra nova vale
-- retroativamente.
--
-- ── O QUE NÃO FIZ ─────────────────────────────────────────────────────────
-- NÃO fundi `Meta`, `Instagram` e `Facebook` num só. A fonte distingue
-- plataforma (`utm_source=META`) de posicionamento (`cf_midia=Instagram`), e
-- colapsá-los seria decidir por conta própria que o usuário não quer separar
-- Instagram de Facebook. O agrupamento aqui é só de GRAFIA — caixa e
-- abreviação —, nunca de significado.

-- ---------------------------------------------------------------------------
-- Tabela de regras de plataforma. Semeada só com valores OBSERVADOS.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS plataforma_regra (
  id         bigserial PRIMARY KEY,
  padrao     text NOT NULL,
  canonico   text NOT NULL,
  prioridade int  NOT NULL DEFAULT 100,
  observado  boolean NOT NULL DEFAULT false,
  criado_em  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (padrao)
);
COMMENT ON TABLE plataforma_regra IS
  'Normaliza GRAFIA de plataforma (caixa e abreviação), nunca significado. `padrao` é casado com ILIKE contra o valor bruto; menor prioridade vence. Meta, Instagram e Facebook ficam SEPARADOS de propósito: a fonte distingue plataforma de posicionamento e fundi-los seria decidir pelo usuário.';

INSERT INTO plataforma_regra (padrao, canonico, prioridade, observado) VALUES
  ('instagram', 'Instagram',  10, true),
  ('ig',        'Instagram',  10, true),
  ('facebook',  'Facebook',   10, true),
  ('fb',        'Facebook',   10, true),
  ('meta',      'Meta',       10, true),
  ('google',    'Google',     10, true),
  ('googleads', 'Google',     10, true),
  ('google ads','Google',     10, true),
  ('linkedin',    'LinkedIn', 10, true),
  ('linkedin ads','LinkedIn', 10, true),
  ('rd station',  'RD Station', 10, true),
  ('chatgpt.com', 'ChatGPT',    10, true)
ON CONFLICT (padrao) DO NOTHING;

-- ---------------------------------------------------------------------------
-- fn_decodificar_utm — decodifica um valor de query string CORRETAMENTE.
--
-- É a correção do bug 1. Em x-www-form-urlencoded, `+` é espaço; a decodificação
-- percentual sozinha não resolve. A ordem importa: troca `+` por espaço ANTES
-- de decodificar `%XX`, senão um `%2B` legítimo (mais literal) viraria espaço.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_decodificar_utm(p_valor text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
BEGIN
  IF p_valor IS NULL OR btrim(p_valor) = '' THEN RETURN NULL; END IF;

  -- `+` -> espaco primeiro; assim %2B (mais literal) sobrevive a decodificacao.
  v := replace(p_valor, '+', ' ');

  BEGIN
    -- convert_from(decode(...,'escape')) resolve %XX. Se a string tiver um %
    -- solto (nao seguido de hexa), isto levanta excecao — daí o bloco.
    v := convert_from(decode(replace(v, '%', '\x'), 'escape'), 'UTF8');
  EXCEPTION WHEN others THEN
    -- Nao decodificou: devolve com o `+` ja tratado, que ainda e melhor que o
    -- bruto. Nao inventa e nao perde.
    NULL;
  END;

  RETURN btrim(v);
END;
$$;
COMMENT ON FUNCTION fn_decodificar_utm(text) IS
  'Decodifica valor de query string tratando `+` como espaço (x-www-form-urlencoded), que decodeURIComponent NÃO faz — foi o bug que partiu `[SB] CAMPANHA_WEBINAR` em duas campanhas. Troca `+` antes de resolver %XX para que %2B (mais literal) sobreviva.';

-- ---------------------------------------------------------------------------
-- fn_extrair_utm — pega um parâmetro de dentro de uma string que É uma query
-- string. É a correção do bug 2: 11 eventos têm a UTM inteira dentro de
-- `cf_midia`/`cf_utm_source`.
--
-- Devolve NULL quando o valor não parece query string — assim o chamador usa
-- COALESCE e o comportamento normal não muda.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_extrair_utm(p_valor text, p_param text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_match text[];
BEGIN
  IF p_valor IS NULL OR p_valor NOT LIKE '%utm_%=%' THEN RETURN NULL; END IF;

  SELECT regexp_match(p_valor, p_param || '=([^&]*)') INTO v_match;
  IF v_match IS NULL OR v_match[1] IS NULL OR btrim(v_match[1]) = '' THEN
    RETURN NULL;
  END IF;

  RETURN fn_decodificar_utm(v_match[1]);
END;
$$;
COMMENT ON FUNCTION fn_extrair_utm(text, text) IS
  'Extrai um parâmetro utm_* de dentro de um valor que É uma query string. Existe porque 11 eventos reais têm a UTM inteira colada dentro de cf_midia/cf_utm_source — o dado está literalmente no campo, só no lugar errado, e extraí-lo não é inventar. Devolve NULL quando o valor não parece query string, para o chamador usar COALESCE.';

-- ---------------------------------------------------------------------------
-- fn_normalizar_plataforma
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_normalizar_plataforma(p_bruto text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_limpo text;
  v_canon text;
BEGIN
  IF p_bruto IS NULL OR btrim(p_bruto) = '' THEN RETURN NULL; END IF;

  -- Se o valor for uma query string, a plataforma esta no utm_source dela.
  v_limpo := COALESCE(fn_extrair_utm(p_bruto, 'utm_source'), fn_decodificar_utm(p_bruto));
  IF v_limpo IS NULL OR btrim(v_limpo) = '' THEN RETURN NULL; END IF;

  SELECT r.canonico INTO v_canon
  FROM plataforma_regra r
  WHERE btrim(lower(v_limpo)) = lower(r.padrao)
  ORDER BY r.prioridade, r.id
  LIMIT 1;

  -- Sem regra: devolve o valor decodificado como está. Aparece cru na aba
  -- Qualidade de dados, que é o sinal para escrever regra — igual a cargo.
  RETURN COALESCE(v_canon, btrim(v_limpo));
END;
$$;
COMMENT ON FUNCTION fn_normalizar_plataforma(text) IS
  'Normaliza grafia de plataforma via plataforma_regra, extraindo de query string quando o valor bruto é uma. Valor sem regra volta decodificado e cru — visível na aba Qualidade de dados, que é o sinal para escrever regra.';

-- ---------------------------------------------------------------------------
-- fn_normalizar_campanha
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_normalizar_campanha(p_bruto text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_bruto IS NULL OR btrim(p_bruto) = '' THEN RETURN NULL; END IF;
  -- Query string inteira no campo -> tira o utm_campaign de dentro.
  -- Caso normal -> só decodifica (tratando `+` como espaço).
  RETURN NULLIF(btrim(COALESCE(
    fn_extrair_utm(p_bruto, 'utm_campaign'),
    fn_decodificar_utm(p_bruto)
  )), '');
END;
$$;
COMMENT ON FUNCTION fn_normalizar_campanha(text) IS
  'Decodifica o nome de campanha (tratando `+` como espaço) e, quando o valor bruto é uma query string inteira, extrai o utm_campaign de dentro. Sem isto, `[SB]+CAMPANHA_WEBINAR` e `[SB] CAMPANHA_WEBINAR` contavam como duas campanhas — 22 leads partidos ao meio na visão de ROI.';

GRANT SELECT ON plataforma_regra TO crm_ingest;
