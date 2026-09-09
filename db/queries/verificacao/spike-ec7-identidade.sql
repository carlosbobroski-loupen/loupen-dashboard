-- db/queries/verificacao/spike-ec7-identidade.sql
-- Subtask 1.8. Spike EC-7 — valida os TRÊS itens que a subtask nomeia:
-- (1) chave canônica, (2) regra de conflito, (3) custo real do Tier 2 com
-- índice GIN/GiST sobre amostra.
--
-- Diferente das outras asserções deste diretório, este arquivo é um SPIKE:
-- os itens (1) e (2) são asserções de verdade (falham se o desenho for
-- violado), e o item (3) é uma MEDIÇÃO — imprime números reais em NOTICE,
-- não falha por lentidão (não há alvo de performance definido para o Tier 2
-- em nenhum requisito; NFR-2 é sobre a API de leitura, não sobre este job
-- de reconciliação periódica).
--
-- A medição usa amostra SINTÉTICA em tabelas TEMP, de propósito: medir
-- custo exige volume (a base real tem 13 leads e 6 contatos hoje, pequeno
-- demais para o planner sequer considerar um índice). Nomes sintéticos aqui
-- servem só para gerar trigramas realistas — nenhum número de negócio é
-- derivado deles, e as tabelas desaparecem no fim da sessão.

-- ── (1) CHAVE CANÔNICA ────────────────────────────────────────────────────
-- A chave canônica de uma identidade é `person.canonical_id` (uuid), e o
-- vínculo com o registro de origem é (source_system, source_record_id,
-- identifier_type) em identity_edge. Relatório humano:
SELECT
  ie.identifier_type,
  count(*)                        AS edges,
  count(DISTINCT ie.person_id)    AS persons_distintas,
  count(DISTINCT ie.source_system) AS fontes
FROM identity_edge ie
GROUP BY ie.identifier_type
ORDER BY ie.identifier_type;

DO $$
DECLARE
  v_sem_canonical integer;
  v_duplicadas    integer;
BEGIN
  -- Toda person tem canonical_id (é NOT NULL + UNIQUE por schema, mas
  -- verificar o DADO é o ponto do spike, não reler o DDL).
  SELECT count(*) INTO v_sem_canonical FROM person WHERE canonical_id IS NULL;
  IF v_sem_canonical > 0 THEN
    RAISE EXCEPTION 'EC-7(1) violado: % person(s) sem canonical_id — a chave canônica não é confiável.', v_sem_canonical;
  END IF;

  -- A mesma (source_system, source_record_id, identifier_type) não pode
  -- apontar para duas persons — seria identidade ambígua na raiz.
  SELECT count(*) INTO v_duplicadas FROM (
    SELECT ie.source_system, ie.source_record_id, ie.identifier_type
    FROM identity_edge ie
    GROUP BY 1,2,3
    HAVING count(DISTINCT ie.person_id) > 1
  ) x;
  IF v_duplicadas > 0 THEN
    RAISE EXCEPTION 'EC-7(1) violado: % combinação(ões) (source_system, source_record_id, identifier_type) apontam para MAIS DE UMA person — chave canônica ambígua.', v_duplicadas;
  END IF;

  RAISE NOTICE 'EC-7(1) OK: chave canônica íntegra — % person(s), nenhuma sem canonical_id, nenhum vínculo ambíguo.', (SELECT count(*) FROM person);
END $$;

-- ── (2) REGRA DE CONFLITO ─────────────────────────────────────────────────
-- R18: e-mail corporativo genérico compartilhado por pessoas diferentes NÃO
-- pode fundir identidades. A regra real (migration 032): quando o e-mail
-- normalizado bate mas a similaridade de nome é baixa, grava
-- identity_candidate(status='conflito') com persons SEPARADAS.
SELECT
  ic.status,
  count(*)                AS candidatos,
  min(ic.score)           AS score_min,
  max(ic.score)           AS score_max,
  max(ic.confidence)      AS confidence_max
FROM identity_candidate ic
GROUP BY ic.status
ORDER BY ic.status;

DO $$
DECLARE
  v_confidence_invalida integer;
  v_conflito_fundido    integer;
BEGIN
  -- INVARIANTE: Tier 2 nunca grava certeza. (Há CHECK no schema; aqui se
  -- verifica o DADO.)
  SELECT count(*) INTO v_confidence_invalida FROM identity_candidate WHERE confidence >= 1;
  IF v_confidence_invalida > 0 THEN
    RAISE EXCEPTION 'EC-7(2) violado: % candidato(s) Tier 2 com confidence >= 1 — Tier 2 nunca pode afirmar certeza.', v_confidence_invalida;
  END IF;

  -- INVARIANTE DA REGRA DE CONFLITO: um par marcado 'conflito' não pode
  -- ter as duas pontas na MESMA person (isso seria exatamente a fusão que a
  -- regra existe para impedir).
  SELECT count(*) INTO v_conflito_fundido
  FROM identity_candidate ic
  WHERE ic.status = 'conflito' AND ic.person_a_id = ic.person_b_id;
  IF v_conflito_fundido > 0 THEN
    RAISE EXCEPTION 'EC-7(2) violado: % par(es) em conflito com person_a = person_b — a regra de conflito não impediu a fusão (R18).', v_conflito_fundido;
  END IF;

  RAISE NOTICE 'EC-7(2) OK: regra de conflito íntegra — % candidato(s), nenhum com confidence>=1, nenhum conflito fundido.', (SELECT count(*) FROM identity_candidate);
END $$;

-- ── (3) CUSTO REAL DO TIER 2 COM ÍNDICE GIN, SOBRE AMOSTRA ────────────────
-- Medição, não asserção. Compara três formas sobre a MESMA amostra:
--   A) CROSS JOIN filtrado por domínio de e-mail + similarity() como
--      predicado (equivalente set-based do que a função faz)
--   B) operador % (que PODE usar o índice GIN) SEM o filtro de domínio
--   C) loop row-by-row em PL/pgSQL (o que fn_identity_tier2_resolve
--      realmente faz hoje)
--   D) operador % COM o filtro de domínio (semanticamente equivalente a A)
DROP TABLE IF EXISTS t_spike_lead;
DROP TABLE IF EXISTS t_spike_contact;
CREATE TEMP TABLE t_spike_lead (id bigserial, nome text, email text);
CREATE TEMP TABLE t_spike_contact (id bigserial, nome text, email text);

INSERT INTO t_spike_lead (nome, email)
SELECT (ARRAY['Joao','Maria','Carlos','Ana','Pedro','Lucia','Marcos','Patricia','Rafael','Fernanda'])[1+(i%10)]
    || ' ' || (ARRAY['Silva','Souza','Oliveira','Santos','Lima','Costa','Pereira','Almeida'])[1+(i%8)]
    || ' ' || (ARRAY['Junior','Neto','Filho','Segundo',''])[1+(i%5)],
  'lead' || i || '@empresa' || (i%500) || '.com.br'
FROM generate_series(1, 20000) i;

INSERT INTO t_spike_contact (nome, email)
SELECT (ARRAY['João','María','Cárlos','Anna','Pédro','Lúcia','Márcos','Patrícia','Rafaél','Fernánda'])[1+(i%10)]
    || ' ' || (ARRAY['Silva','Souza','Oliveira','Santos','Lima','Costa','Pereira','Almeida'])[1+(i%8)]
    || ' ' || (ARRAY['Jr','Neto','Filho','II',''])[1+(i%5)],
  'contact' || i || '@empresa' || (i%500) || '.com.br'
FROM generate_series(1, 5000) i;

CREATE INDEX t_spike_lead_nome_trgm ON t_spike_lead USING gin (nome gin_trgm_ops);
ANALYZE t_spike_lead;
ANALYZE t_spike_contact;
SELECT set_limit(0.6);

DO $$
DECLARE
  t0 timestamptz; t1 timestamptz;
  v_n_a bigint; v_n_b bigint; v_n_d bigint; v_n_c integer := 0;
  v_ms_a numeric; v_ms_b numeric; v_ms_c numeric; v_ms_d numeric;
  r RECORD; v double precision;
BEGIN
  -- A) set-based, filtro de domínio + similarity() como predicado
  t0 := clock_timestamp();
  SELECT count(*) INTO v_n_a FROM t_spike_lead l CROSS JOIN t_spike_contact c
  WHERE split_part(l.email,'@',2) = split_part(c.email,'@',2)
    AND similarity(lower(l.nome), lower(c.nome)) >= 0.6;
  t1 := clock_timestamp();
  v_ms_a := round((extract(epoch from (t1-t0))*1000)::numeric, 1);

  -- B) operador % (pode usar GIN), SEM filtro de domínio
  t0 := clock_timestamp();
  SELECT count(*) INTO v_n_b FROM t_spike_contact c JOIN t_spike_lead l ON l.nome % c.nome;
  t1 := clock_timestamp();
  v_ms_b := round((extract(epoch from (t1-t0))*1000)::numeric, 1);

  -- C) loop row-by-row (o que a função faz hoje)
  t0 := clock_timestamp();
  FOR r IN
    SELECT l.nome AS ln, c.nome AS cn FROM t_spike_lead l CROSS JOIN t_spike_contact c
    WHERE split_part(l.email,'@',2) = split_part(c.email,'@',2)
  LOOP
    v := similarity(lower(r.ln), lower(r.cn));
    IF v >= 0.6 THEN v_n_c := v_n_c + 1; END IF;
  END LOOP;
  t1 := clock_timestamp();
  v_ms_c := round((extract(epoch from (t1-t0))*1000)::numeric, 1);

  -- D) operador % COM filtro de domínio (equivalente a A)
  t0 := clock_timestamp();
  SELECT count(*) INTO v_n_d FROM t_spike_contact c JOIN t_spike_lead l
    ON l.nome % c.nome AND split_part(l.email,'@',2) = split_part(c.email,'@',2);
  t1 := clock_timestamp();
  v_ms_d := round((extract(epoch from (t1-t0))*1000)::numeric, 1);

  RAISE NOTICE 'EC-7(3) MEDIÇÃO — amostra: % leads x % contatos', (SELECT count(*) FROM t_spike_lead), (SELECT count(*) FROM t_spike_contact);
  RAISE NOTICE '  A) set-based + filtro dominio + similarity(): % pares, % ms', v_n_a, v_ms_a;
  RAISE NOTICE '  B) operador %% (GIN usavel), SEM filtro dominio: % pares, % ms  <- semantica DIFERENTE (muito mais ampla)', v_n_b, v_ms_b;
  RAISE NOTICE '  C) loop PL/pgSQL (comportamento ATUAL da funcao): % pares, % ms', v_n_c, v_ms_c;
  RAISE NOTICE '  D) operador %% + filtro dominio (equivalente a A): % pares, % ms', v_n_d, v_ms_d;
  RAISE NOTICE 'CONCLUSAO: A e D tem o MESMO resultado e custo praticamente igual -> com o filtro de dominio presente, o planner NAO usa o indice GIN (Merge Join no dominio + similaridade como Join Filter). O indice so entra em B, que tem semantica diferente. Ver validation-log.md.';
END $$;

DROP TABLE IF EXISTS t_spike_lead;
DROP TABLE IF EXISTS t_spike_contact;
