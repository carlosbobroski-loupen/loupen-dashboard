-- db/queries/verificacao/s7-s8-nao-classificam.sql
-- Subtask 3.6. INV-6: S7 (participação em workflow, lead_touchpoint) e S8
-- (owner do time comercial) NUNCA classificam origem — usar qualquer um
-- para decidir segmento reintroduziria o bucket residual por outra porta.
-- Lead seed-s7-s8-nao-classificam (migration 023) tem origem Marketing
-- (S3) MAS também tem touchpoint de workflow E owner comercial — prova
-- que o resultado continua Marketing apesar dos dois.

SELECT r.segmento, r.sinal_id,
  (SELECT count(*) FROM lead_touchpoint lt WHERE lt.lead_id = l.id) AS tem_touchpoint,
  (o.nome IS NOT NULL) AS tem_owner_comercial
FROM lead l
LEFT JOIN owner o ON o.id = l.owner_id
CROSS JOIN LATERAL fn_classify_origin(l.id) r
WHERE l.source_system = 'seed_test' AND l.source_id = 'seed-s7-s8-nao-classificam';

DO $$
DECLARE
  v_segmento text;
  v_sinal text;
BEGIN
  SELECT r.segmento, r.sinal_id INTO v_segmento, v_sinal
  FROM lead l, LATERAL fn_classify_origin(l.id) r
  WHERE l.source_system = 'seed_test' AND l.source_id = 'seed-s7-s8-nao-classificam';

  IF v_segmento IS DISTINCT FROM 'Marketing' OR v_sinal IS DISTINCT FROM 'S3' THEN
    RAISE EXCEPTION 'INV-6 violado: lead com touchpoint de workflow (S7) e owner comercial (S8) deveria continuar classificado por S3/Marketing (a origem real), mas retornou sinal=%, segmento=%. S7/S8 vazaram para a classificação de origem.', v_sinal, v_segmento;
  END IF;
  RAISE NOTICE 'INV-6 OK: S7 (workflow) e S8 (owner comercial) presentes, mas NÃO alteraram o segmento — continua Marketing/S3.';
END $$;
