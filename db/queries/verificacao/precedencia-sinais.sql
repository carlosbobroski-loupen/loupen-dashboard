-- db/queries/verificacao/precedencia-sinais.sql
-- Subtask 3.6. Prova de precedência ESTRITA (DEF-4): constrói um caso onde
-- dois sinais casam simultaneamente (S1 via Ad ID presente, S5 via
-- LeadSource no vocabulário outbound — lead seed-precedencia-s1-vs-s5,
-- migration 022) e prova que vence o de ordem MENOR (S1), nunca um OR
-- implícito que deixaria o resultado ambíguo/dependente de ordem de
-- avaliação do CASE.

SELECT r.sinal_id, r.segmento, r.categoria
FROM lead l, LATERAL fn_classify_origin(l.id) r
WHERE l.source_system = 'seed_test' AND l.source_id = 'seed-precedencia-s1-vs-s5';

DO $$
DECLARE
  v_sinal text;
  v_segmento text;
BEGIN
  SELECT r.sinal_id, r.segmento INTO v_sinal, v_segmento
  FROM lead l, LATERAL fn_classify_origin(l.id) r
  WHERE l.source_system = 'seed_test' AND l.source_id = 'seed-precedencia-s1-vs-s5';

  IF v_sinal IS DISTINCT FROM 'S1' OR v_segmento IS DISTINCT FROM 'Marketing' THEN
    RAISE EXCEPTION 'Precedência violada (DEF-4): lead com S1 E S5 casando simultaneamente deveria classificar por S1/Marketing (menor ordem), mas classificou sinal=%, segmento=%.', v_sinal, v_segmento;
  END IF;
  RAISE NOTICE 'Precedência OK: S1 venceu sobre S5, como esperado (first-match-wins, ordem estrita).';
END $$;
