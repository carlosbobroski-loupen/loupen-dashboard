-- db/migrations/004_identity_graph.sql
-- Subtask 2.6. Identity graph para resolução de identidade cross-source
-- (EC-7), validado no spike 1.8/1.1. Tier 1 (determinístico: e-mail,
-- telefone E.164, ConvertedAccountId, UUID do RD Station) grava
-- identity_edge com confidence alta. Tier 2 (probabilístico: pg_trgm sobre
-- nome/empresa) grava identity_candidate com confidence < 1 e status
-- 'provavel'/'conflito' — NUNCA confirma merge automático (R18).
--
-- R18/invariante estrutural: nem identity_edge nem identity_candidate têm
-- FK para lead/contact/account/opportunity — a ligação com o registro de
-- origem é por (source_system, source_record_id) em texto solto, de
-- propósito, para que NENHUM DELETE em cascata deste grafo possa destruir
-- um registro de origem. O grafo pode ser recalculado do zero sem perder
-- dado nenhum das tabelas canônicas.

CREATE TABLE IF NOT EXISTS person (
  id              bigserial PRIMARY KEY,
  canonical_id    uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  nome_canonico   text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- Tier 1 — determinístico. confidence=1 é o caso normal (match exato de
-- identificador forte); a coluna existe para nunca fechar a porta a uma
-- fonte determinística de confiança fracionária no futuro, sem mudar forma.
CREATE TABLE IF NOT EXISTS identity_edge (
  id                  bigserial PRIMARY KEY,
  person_id           bigint NOT NULL REFERENCES person(id),
  identifier_type     text NOT NULL CHECK (identifier_type IN ('email', 'telefone_e164', 'converted_account_id', 'rdstation_uuid')),
  identifier_value    text NOT NULL,
  source_system       text NOT NULL,
  source_record_id    text NOT NULL,
  confidence          numeric NOT NULL DEFAULT 1.0 CHECK (confidence > 0 AND confidence <= 1),
  resolved_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_record_id, identifier_type)
);
COMMENT ON COLUMN identity_edge.source_record_id IS
  'Referência SOLTA (texto, sem FK) ao registro de origem (lead/contact/etc). Deliberado: nenhuma FK aqui significa que apagar um identity_edge nunca pode cascatear e destruir o registro de origem (R18).';
COMMENT ON COLUMN identity_edge.identifier_value IS
  'Telefone já normalizado em E.164 quando identifier_type=telefone_e164 — a normalização roda no n8n antes do insert (resíduo declarado e aceito em §3.3, ver notes da subtask 2.6).';

-- Tier 2 — probabilístico (pg_trgm/fuzzystrmatch). NUNCA confirma merge:
-- confidence < 1 é INVARIANTE DE BANCO, não de aplicação.
CREATE TABLE IF NOT EXISTS identity_candidate (
  id            bigserial PRIMARY KEY,
  person_a_id   bigint NOT NULL REFERENCES person(id),
  person_b_id   bigint NOT NULL REFERENCES person(id),
  score         numeric NOT NULL CHECK (score >= 0 AND score <= 1),
  confidence    numeric NOT NULL CHECK (confidence < 1),
  signal        text,
  status        text NOT NULL CHECK (status IN ('provavel', 'conflito')),
  explicacao    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (person_a_id <> person_b_id),
  UNIQUE (person_a_id, person_b_id)
);
COMMENT ON TABLE identity_candidate IS
  'Tier 2 de EC-7: candidato de identidade, NUNCA um merge confirmado. status=''provavel'' ou ''conflito'' — a UI exibe como candidato, nunca como fato (ver assets/js/attribution.js.renderVinculoIdentidade na Etapa A, mesmo contrato).';
COMMENT ON CONSTRAINT identity_candidate_confidence_check ON identity_candidate IS
  'INVARIANTE DE BANCO (não de aplicação): todo vínculo Tier 2 tem confidence < 1 — nunca pode ser gravado como certeza.';

-- Índice de trigrama sobre nome do lead — é o que torna similarity() sobre
-- nome (Tier 2) executável em escala, em vez de scan sequencial completo a
-- cada geração de candidato.
CREATE INDEX IF NOT EXISTS idx_lead_nome_trgm ON lead USING gin (nome gin_trgm_ops);
