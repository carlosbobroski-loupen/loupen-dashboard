-- db/migrations/011_staging_tables.sql
-- Subtask 2.12. Parte do ADR-015 (mecânica de invocação, formalizado em
-- 2.13). Staging existe para que o n8n faça UMA escrita em bloco por lote
-- (P-ING-3, transação única) e toda a lógica de negócio rode em SQL depois
-- (fn_run_ingest_batch, migration 012) — sem staging, ou o n8n transforma
-- (violando o domicílio da regra de CRIT-4) ou faz N round trips por
-- registro. O bruto é preservado em jsonb (P6); a idempotência de verdade
-- (reexecutar o mesmo batch_id não duplica nem corrompe a contagem) é
-- responsabilidade do ON CONFLICT em fn_run_ingest_batch sobre as tabelas
-- canônicas, não desta camada de staging (o payload bruto pode, sim,
-- acumular entradas de reexecução — é um log de entrada, não a fonte de
-- verdade).
--
-- Uma tabela por FONTE (não por objeto): object_type dentro do payload/
-- coluna diferencia Lead/Account/Opportunity/RecordType/Owner dentro de
-- stg_salesforce, por exemplo.

CREATE TABLE IF NOT EXISTS stg_salesforce (
  id             bigserial PRIMARY KEY,
  batch_id       text NOT NULL,
  source_system  text NOT NULL DEFAULT 'salesforce',
  object_type    text NOT NULL,
  payload        jsonb NOT NULL,
  collected_at   timestamptz NOT NULL,
  ingested_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS stg_rdstation (
  id             bigserial PRIMARY KEY,
  batch_id       text NOT NULL,
  source_system  text NOT NULL DEFAULT 'rd_station',
  object_type    text NOT NULL,
  payload        jsonb NOT NULL,
  collected_at   timestamptz NOT NULL,
  ingested_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS stg_ads (
  id             bigserial PRIMARY KEY,
  batch_id       text NOT NULL,
  source_system  text NOT NULL,
  object_type    text NOT NULL,
  payload        jsonb NOT NULL,
  collected_at   timestamptz NOT NULL,
  ingested_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN stg_ads.source_system IS
  'Sem DEFAULT único: esta tabela recebe de mais de uma plataforma via o workflow de ads ADAPTADO (2.18) — Meta Ads/Google Ads/LinkedIn Ads. O valor real vem do payload de origem, não é assumido.';

CREATE TABLE IF NOT EXISTS stg_sheets (
  id             bigserial PRIMARY KEY,
  batch_id       text NOT NULL,
  source_system  text NOT NULL DEFAULT 'google_sheets',
  object_type    text NOT NULL,
  payload        jsonb NOT NULL,
  collected_at   timestamptz NOT NULL,
  ingested_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stg_sheets IS
  'Carga histórica (ASM-5/OQ-9, subtask 2.22) a partir das planilhas Google Sheets já inventariadas em 1.12, dentro da janela de 6-12 meses decidida — não o histórico completo.';
