-- db/migrations/007_sync_state_ingest_run.sql
-- Subtask 2.9. FR-8 nasce aqui: fecha o gap concreto que originou esta
-- epic (Oportunidades(SF) com 44 de 236 linhas e totais fixos no código,
-- EC-6). Com o n8n como ponto único de ingestão E de leitura (R7), a
-- contagem origem↔destino deixa de ser boa prática e passa a ser o ÚNICO
-- detector do modo de falha. Toda coluna de contagem é NOT NULL para
-- impedir a leitura "sem divergência" quando o que houve foi ausência de
-- medição — omitir a contagem não pode parecer sucesso silencioso.

CREATE TABLE IF NOT EXISTS sync_state (
  source        text NOT NULL,
  object        text NOT NULL,
  last_run_at   timestamptz NOT NULL,
  rows_source   integer NOT NULL,
  rows_target   integer NOT NULL,
  PRIMARY KEY (source, object)
);
COMMENT ON TABLE sync_state IS
  'Watermark por fonte/objeto (P-ING-2) — última execução, contagem na origem e no destino. rows_source/rows_target NOT NULL de propósito: ausência de medição nunca pode ser lida como "zero divergência".';

CREATE TABLE IF NOT EXISTS ingest_run (
  id              bigserial PRIMARY KEY,
  source          text NOT NULL,
  object          text NOT NULL,
  started_at      timestamptz NOT NULL,
  finished_at     timestamptz,
  rows_source     integer NOT NULL,
  rows_target     integer NOT NULL,
  status          text NOT NULL CHECK (status IN ('ok', 'partial', 'failed')),
  error_message   text
);
COMMENT ON TABLE ingest_run IS
  'Uma linha por execução de ingestão (FR-8/NFR-1/INV-2). status=ok COM rows_source<>rows_target é a contradição que reconciliacao-ac81.sql detecta — sincronização parcial nunca pode se apresentar como completa (EC-6, o defeito que originou esta epic).';
