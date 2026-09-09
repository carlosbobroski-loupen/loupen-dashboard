-- db/queries/verificacao/spike-00-extensions.sql
-- Subtask 1.1 do plano (implementation.yaml) — Spike nº 0, R4, premissa
-- central do desenho de identidade (EC-7 Tier 2). Prova que pg_trgm e
-- fuzzystrmatch estão disponíveis no projeto Neon (Free) e que similarity()
-- e levenshtein() de fato funcionam — não apenas que a extensão "existe" no
-- catálogo, mas que a função é chamável e devolve um resultado plausível.
--
-- Uso: psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/queries/verificacao/spike-00-extensions.sql
--
-- ON_ERROR_STOP=1 é o que faz este script FALHAR o processo (exit != 0) se
-- qualquer CREATE EXTENSION ou chamada de função der erro — não só imprimir
-- e seguir. Se falhar aqui, o Tier 2 de EC-7 precisa de outra solução e a
-- escolha de banco reabre (spec.md §4.4 item 0). Não improvisar workaround.

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

DO $$
DECLARE
  sim double precision;
  dist integer;
BEGIN
  -- similarity() de pg_trgm — usado no Tier 2 de identidade (nome/empresa
  -- parecidos, sem match determinístico de e-mail/telefone/ConvertedAccountId).
  SELECT similarity('Joao Pereira Lima', 'João P. Lima') INTO sim;
  IF sim IS NULL THEN
    RAISE EXCEPTION 'pg_trgm.similarity() retornou NULL — extensão presente mas função não operante';
  END IF;

  -- levenshtein() de fuzzystrmatch — mesma finalidade, sinal complementar.
  SELECT levenshtein('Joao Pereira Lima', 'João P. Lima') INTO dist;
  IF dist IS NULL THEN
    RAISE EXCEPTION 'fuzzystrmatch.levenshtein() retornou NULL — extensão presente mas função não operante';
  END IF;

  RAISE NOTICE 'OK: pg_trgm.similarity() = %, fuzzystrmatch.levenshtein() = % (spike 1.1 passou)', sim, dist;
END $$;

-- Consulta final também serve como evidência a colar em validation-log.md.
SELECT
  'Joao Pereira Lima' AS nome_a,
  'João P. Lima' AS nome_b,
  similarity('Joao Pereira Lima', 'João P. Lima') AS similarity_score,
  levenshtein('Joao Pereira Lima', 'João P. Lima') AS levenshtein_distance,
  current_setting('server_version') AS pg_version;
