-- db/migrations/010_m3_scope_columns.sql
-- Subtask 2.11. Mitigação M3 (das três de NFR-3 — M1/M2 ficam pendentes
-- junto com NFR-3/RLS real, fase 2): colunas de escopo em toda tabela que
-- carrega PII, ANTES de qualquer carga histórica de dados (2.16+). Migration
-- separada de propósito (ALTER TABLE) para que a antecipação seja auditável
-- em um único arquivo, em vez de diluída na definição de cada tabela.
-- Habilita RLS futuro (fase 2) sem exigir migração de dados depois — a
-- lacuna que D12 identificou: schema com dados carregados exige migração,
-- schema vazio não.

ALTER TABLE lead        ADD COLUMN IF NOT EXISTS visibility_scope text;
ALTER TABLE lead        ADD COLUMN IF NOT EXISTS owner_team       text;

ALTER TABLE contact     ADD COLUMN IF NOT EXISTS visibility_scope text;
ALTER TABLE contact     ADD COLUMN IF NOT EXISTS owner_team       text;

ALTER TABLE opportunity ADD COLUMN IF NOT EXISTS visibility_scope text;
ALTER TABLE opportunity ADD COLUMN IF NOT EXISTS owner_team       text;

ALTER TABLE account     ADD COLUMN IF NOT EXISTS visibility_scope text;
ALTER TABLE account     ADD COLUMN IF NOT EXISTS owner_team       text;

COMMENT ON COLUMN lead.visibility_scope IS
  'M3 (mitigação de NFR-3, antecipada aqui por D12): coluna de escopo pronta para RLS da fase 2. NULL/sem uso na fase 1 — gate binário do Cloudflare Access é a proteção real desta fase (R10, risco aceito conscientemente pelo usuário em 2026-09-04).';
