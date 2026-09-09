-- db/queries/verificacao/i1-i2.sql
-- Subtask 3.4 (V5), escrita ANTES de fn_classify_origin (migration 021)
-- existir de verdade — compila contra o contrato de 3.3 e FALHA
-- semanticamente até 3.5 (o stub faz RAISE EXCEPTION 'not implemented').
-- Fica verde só depois da implementação real.
--
-- I1: nenhum caminho produz Comercial sem que S5 tenha casado (P3/INV-6 —
--     Comercial NUNCA é bucket residual).
-- I2: 100% das classificações têm sinal_id, valor_bruto (quando aplicável)
--     e razao (jsonb) com razao_legivel — NFR-7/AC-5.3, nenhuma
--     classificação sem razão auditável.

-- Smoke test do contrato — prova que a função responde para os leads
-- semeados de sinal conhecido (020_seed_leads_atribuicao.sql). Antes de
-- 3.5: RAISE 'not implemented' (vermelho esperado). Depois: retorna linhas.
SELECT l.source_id, (fn_classify_origin(l.id)).*
FROM lead l WHERE l.source_system = 'seed_test'
ORDER BY l.source_id;

-- Parte 1 — relatório humano das linhas ofensoras de I1.
SELECT id, lead_id, segmento, sinal_id, categoria
FROM lead_origin_classification
WHERE segmento = 'Comercial' AND (sinal_id IS DISTINCT FROM 'S5')
  AND valid_to IS NULL;

-- Parte 2 — asserção de I1 com exit code.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM lead_origin_classification
  WHERE segmento = 'Comercial' AND (sinal_id IS DISTINCT FROM 'S5') AND valid_to IS NULL;
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'I1 violado (P3/INV-6): % linha(s) com segmento=Comercial e sinal_id != S5 — Comercial voltou a ser bucket residual.', ofensoras;
  END IF;
END $$;

-- Parte 1 — relatório humano das linhas ofensoras de I2.
SELECT id, lead_id, segmento, sinal_id, valor_bruto, razao
FROM lead_origin_classification
WHERE valid_to IS NULL
  AND (sinal_id IS NULL OR razao IS NULL OR NOT (razao ? 'razao_legivel'));

-- Parte 2 — asserção de I2 com exit code.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM lead_origin_classification
  WHERE valid_to IS NULL
    AND (sinal_id IS NULL OR razao IS NULL OR NOT (razao ? 'razao_legivel'));
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'I2 violado (NFR-7/AC-5.3): % classificação(ões) corrente(s) sem sinal_id e/ou razao.razao_legivel — razão auditável obrigatória.', ofensoras;
  END IF;
END $$;
