-- db/queries/verificacao/receita-fr10.sql
-- Subtask 3.8. FR-10/EC-5: (a) oportunidade NÃO Ganha nunca expõe valor de
-- contrato; (b) Ganha sem duração conhecida nunca recebe duração default —
-- contrato fica indisponível, com o motivo explícito.

-- Parte 1 — relatório humano.
SELECT opportunity_id, source_id, stage_name, mrr, duracao_meses_contrato, contrato_valor, contrato_indisponivel_motivo
FROM view_receita
WHERE (stage_name IS DISTINCT FROM 'Ganho' AND contrato_valor IS NOT NULL)
   OR (stage_name = 'Ganho' AND duracao_meses_contrato IS NULL AND contrato_valor IS NOT NULL);

-- Parte 2 — asserção.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM view_receita
  WHERE (stage_name IS DISTINCT FROM 'Ganho' AND contrato_valor IS NOT NULL)
     OR (stage_name = 'Ganho' AND duracao_meses_contrato IS NULL AND contrato_valor IS NOT NULL);
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'FR-10/EC-5 violado: % linha(s) de view_receita expõem contrato_valor indevidamente (não-Ganha com contrato, ou Ganha sem duração com contrato calculado por prazo presumido).', ofensoras;
  END IF;
END $$;
