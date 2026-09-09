-- db/migrations/005_conversion_events_partitioned.sql
-- Subtask 2.7. DM-10 (ConversionEvent) — o átomo da jornada (FR-3).
-- PARTICIONADA por período DESDE A PRIMEIRA MIGRATION (R8): particionar
-- depois de carregar dados é migração de dados, não uma opção adiável.
-- Esta é a tabela que é o vetor real de estouro dos 0,5 GB do Neon Free
-- (não a tabela de leads) — ver OQ-9 (janela de 6-12 meses).
--
-- AC-3.2 NO DDL: occurred_at é NULLABLE (evento sem data rastreável é
-- MARCADO, nunca recebe data arbitrária) e date_traceable é NOT NULL.
-- CHECK garante occurred_at IS NULL ⇒ date_traceable=false — nunca o
-- contrário (não é possível declarar "rastreável" sem data real).
-- AC-9.1: source_system e collected_at por evento.
-- CON-3/EC-10: granularidade declarada por fonte (ver ativo_de_origem) —
-- proíbe comparação intradiária sobre dados de workflow do RD Station
-- (que só atualiza 1x/dia, ver automation_workflow.data_atualizacao_origem
-- na migration 003).

CREATE TABLE IF NOT EXISTS conversion_event (
  id                bigserial NOT NULL,
  lead_id           bigint REFERENCES lead(id),
  contact_id        bigint REFERENCES contact(id),
  campaign_ref_id   bigint REFERENCES campaign(id),
  workflow_ref_id   bigint REFERENCES automation_workflow(id),
  tipo              text NOT NULL,
  ativo_de_origem   text,
  source_system     text NOT NULL,
  occurred_at       timestamptz,
  date_traceable    boolean NOT NULL,
  collected_at      timestamptz NOT NULL,
  ingested_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (occurred_at IS NOT NULL OR date_traceable = false)
  -- Sem PRIMARY KEY/UNIQUE aqui de propósito: colunas de chave em tabela
  -- particionada por RANGE têm de incluir a chave de partição, e occurred_at
  -- PRECISA ficar nullable (AC-3.2) — nullable é incompatível com PK/UNIQUE.
  -- `id` continua globalmente único na prática porque bigserial usa UMA
  -- sequência compartilhada entre todas as partições, mesmo sem constraint
  -- formal a impor isso.
) PARTITION BY RANGE (occurred_at);

COMMENT ON COLUMN conversion_event.occurred_at IS
  'NULLABLE de propósito (AC-3.2/EC-8): evento sem data rastreável fica com occurred_at=NULL e date_traceable=false — NUNCA recebe uma data inventada só para caber numa partição ou ordenação.';
COMMENT ON COLUMN conversion_event.date_traceable IS
  'CHECK garante: occurred_at NULL implica date_traceable=false. O inverso não é forçado por DDL (um evento com data real quase sempre é traceable=true, mas a coluna existe separada da nulidade para permitir o caso raro de "data presente mas não confiável", se necessário no futuro, sem mudar forma).';

-- Partições semestrais + DEFAULT para NULL (data não rastreável) e para
-- qualquer data fora do range coberto — nunca um INSERT falha por falta de
-- partição, e nunca um evento sem data fica sem lugar para existir.
CREATE TABLE IF NOT EXISTS conversion_event_default
  PARTITION OF conversion_event DEFAULT;

CREATE TABLE IF NOT EXISTS conversion_event_2026h1
  PARTITION OF conversion_event FOR VALUES FROM ('2026-01-01') TO ('2026-07-01');

CREATE TABLE IF NOT EXISTS conversion_event_2026h2
  PARTITION OF conversion_event FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');

CREATE TABLE IF NOT EXISTS conversion_event_2027h1
  PARTITION OF conversion_event FOR VALUES FROM ('2027-01-01') TO ('2027-07-01');
