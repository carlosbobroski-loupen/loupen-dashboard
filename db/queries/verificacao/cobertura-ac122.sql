-- db/queries/verificacao/cobertura-ac122.sql
-- Subtask 3.14. Generalização do espírito de AC-12.2 (cobertura de
-- atribuição sempre exposta como métrica, nunca omitida) para todos os
-- canais já classificados — o literal de AC-12.1/12.2 é sobre WhatsApp/
-- SDR IA (FR-12, DEFERRED); esta sessão não ingere esse canal, então o
-- teste aqui é o princípio geral, não o caso específico deferido.

-- Parte 1 — relatório humano.
SELECT canal, periodo, total, atribuidos, nao_atribuidos, pct_cobertura
FROM view_cobertura_atribuicao
WHERE total > 0 AND pct_cobertura IS NULL;

-- Parte 2 — asserção: nenhuma linha com total>0 pode ter cobertura NULL.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM view_cobertura_atribuicao
  WHERE total > 0 AND pct_cobertura IS NULL;
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'AC-12.2 (generalizado) violado: % linha(s) de view_cobertura_atribuicao com total>0 e pct_cobertura NULL — cobertura nunca pode ser omitida quando há base.', ofensoras;
  END IF;
  RAISE NOTICE 'AC-12.2 (generalizado) OK: cobertura sempre exposta quando há base.';
END $$;
