-- db/queries/verificacao/reconciliacao-ac81.sql
-- Subtask 2.9. AC-8.1/INV-2: nenhuma execução de ingestão pode reportar
-- status='ok' (completa) enquanto rows_source != rows_target (divergência
-- real). É o detector direto do defeito de EC-6 (44 de 236 linhas
-- apresentadas como se fosse a base completa).
--
-- Convenção de asserção (documentada também em db/README.md e retomada
-- formalmente em 2.20): cada arquivo tem duas partes —
--   1. um SELECT que lista as linhas ofensoras (relatório humano, §6.1);
--   2. um bloco DO $$ ... RAISE EXCEPTION ... que garante exit code != 0
--      quando a invariante é violada, verificável por máquina.
--
-- Uso: psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/queries/verificacao/reconciliacao-ac81.sql

-- Parte 1 — relatório humano das execuções ofensoras.
SELECT
  id, source, object, status, rows_source, rows_target,
  (rows_source - rows_target) AS divergencia_nao_reportada,
  started_at, finished_at
FROM ingest_run
WHERE status = 'ok' AND rows_source <> rows_target
ORDER BY started_at DESC;

-- Parte 2 — asserção com exit code.
DO $$
DECLARE
  ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras
  FROM ingest_run
  WHERE status = 'ok' AND rows_source <> rows_target;

  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'AC-8.1/INV-2 violado: % execução(ões) de ingestão reportam status=ok com rows_source != rows_target — sincronização parcial disfarçada de completa (o defeito de EC-6).', ofensoras;
  END IF;
END $$;
