-- db/migrations/001_extensions.sql
-- Subtask 2.3. Extensões provadas no spike 1.1 (R4) — pg_trgm/fuzzystrmatch,
-- base do Tier 2 de resolução de identidade (EC-7, migration 004).

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
