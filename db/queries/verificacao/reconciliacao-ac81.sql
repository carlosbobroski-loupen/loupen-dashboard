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
-- ESCOPO (acrescentado em 2026-09-09). Esta asserção EXCLUI as execuções
-- anotadas com `[METRICA-INVALIDA-PRE-062]`.
--
-- Motivo: a seção LeadConversion, entre as migrations 047 e 062, media a
-- coisa errada — `rows_source` contava linhas de staging (fazendo a
-- deduplicação legítima do contrato §1.7 parecer perda de dado) e
-- `rows_target` contava recém-inseridos (dando 0 em reexecução idempotente
-- CORRETA). Cinco execuções ficaram com métrica inválida e dado correto.
--
-- A migration 063 anotou essas cinco preservando os valores originais na
-- mensagem. Elas NÃO foram recomputadas (ingest_run não guarda batch_id, não
-- há como ligar execução ao lote), NÃO foram marcadas como `partial` (os
-- lotes estavam corretos) e NÃO foram deletadas (é registro de auditoria).
--
-- Escopo documentado é melhor que história reescrita — e melhor que asserção
-- permanentemente vermelha, que é uma asserção que todo mundo aprende a
-- ignorar.
DO $$
DECLARE
  ofensoras integer;
  anotadas  integer;
BEGIN
  SELECT count(*) INTO ofensoras
  FROM ingest_run
  WHERE status = 'ok' AND rows_source <> rows_target
    AND coalesce(error_message, '') NOT LIKE '[METRICA-INVALIDA-PRE-062]%';

  SELECT count(*) INTO anotadas
  FROM ingest_run WHERE error_message LIKE '[METRICA-INVALIDA-PRE-062]%';

  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'AC-8.1/INV-2 violado: % execução(ões) de ingestão reportam status=ok com rows_source != rows_target — sincronização parcial disfarçada de completa (o defeito de EC-6).', ofensoras;
  END IF;

  IF anotadas > 0 THEN
    RAISE NOTICE 'AC-8.1 OK. % execução(ões) na janela de métrica inválida pré-062 foram excluídas do teste (ver migration 063 — dado correto, medição errada).', anotadas;
  ELSE
    RAISE NOTICE 'AC-8.1 OK: nenhuma execução com status=ok e rows_source != rows_target.';
  END IF;
END $$;
