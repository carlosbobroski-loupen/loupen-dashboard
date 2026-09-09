-- db/queries/verificacao/evento-sem-data-fr3.sql
-- Subtask 3.12 (P1/FR-3/AC-3.2). O CHECK de conversion_event (migration
-- 005) só garante que occurred_at NULL implica date_traceable=false — não
-- garante a direção OPOSTA. Esta asserção fecha essa direção: se
-- date_traceable=false, occurred_at TEM de ser NULL — nenhum evento pode
-- ter uma data real gravada e SIMULTANEAMENTE se declarar não confiável
-- (isso seria pior que omitir: um valor presente que ninguém deveria usar,
-- mas que pode vazar pra UI/relatório mesmo assim).

-- Parte 1 — relatório humano.
SELECT id, source_system, tipo, occurred_at, date_traceable
FROM conversion_event
WHERE date_traceable = false AND occurred_at IS NOT NULL;

-- Parte 2 — asserção.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM conversion_event
  WHERE date_traceable = false AND occurred_at IS NOT NULL;
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'FR-3/AC-3.2 violado: % evento(s) com date_traceable=false MAS occurred_at preenchido — data presente e simultaneamente declarada não confiável, pior que omitir.', ofensoras;
  END IF;
  RAISE NOTICE 'FR-3/AC-3.2 OK: nenhum evento com data preenchida e date_traceable=false ao mesmo tempo.';
END $$;
