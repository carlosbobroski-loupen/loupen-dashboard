-- db/migrations/041_fix_fn_record_touchpoint_on_conflict.sql
-- Bug real encontrado ao TESTAR 040 de verdade (não hipotético): `ON
-- CONFLICT ON CONSTRAINT` só funciona sobre uma constraint de verdade
-- (ADD CONSTRAINT ... UNIQUE), nunca sobre um índice único PARCIAL (CREATE
-- UNIQUE INDEX ... WHERE ...) — que é exatamente o que a migration 039
-- criou (uq_lead_touchpoint_workflow_evento tem WHERE workflow_ref_id IS
-- NOT NULL). Postgres não permite constraint parcial via ADD CONSTRAINT.
-- Erro real reproduzido: "constraint ... for table lead_touchpoint does
-- not exist". Corrigido usando a MESMA forma que o código já usa em outro
-- lugar (conversion_event, migration 026): ON CONFLICT (colunas) WHERE
-- <condição do índice> em vez de ON CONSTRAINT.

CREATE OR REPLACE FUNCTION fn_record_touchpoint(
  p_lead_source_system      text,
  p_lead_source_id          text,
  p_occurred_on             date,
  p_fonte                   text,
  p_tipo                    text,
  p_campanha                text DEFAULT NULL,
  p_workflow_source_system  text DEFAULT NULL,
  p_workflow_source_id      text DEFAULT NULL,
  p_collected_at            timestamptz DEFAULT now()
) RETURNS bigint AS $$
DECLARE
  v_lead_id bigint;
  v_workflow_id bigint;
  v_touchpoint_id bigint;
BEGIN
  SELECT l.id INTO v_lead_id FROM lead l
  WHERE l.source_system = p_lead_source_system AND l.source_id = p_lead_source_id;

  IF v_lead_id IS NULL THEN
    RAISE EXCEPTION 'fn_record_touchpoint: lead %/% não encontrado — touchpoint não pode ser gravado sem o lead existir.', p_lead_source_system, p_lead_source_id;
  END IF;

  IF p_workflow_source_id IS NOT NULL THEN
    SELECT aw.id INTO v_workflow_id FROM automation_workflow aw
    WHERE aw.source_system = p_workflow_source_system AND aw.source_id = p_workflow_source_id;
  END IF;

  INSERT INTO lead_touchpoint (lead_id, occurred_on, fonte, campanha, tipo, workflow_ref_id, collected_at)
  VALUES (v_lead_id, p_occurred_on, p_fonte, p_campanha, p_tipo, v_workflow_id, p_collected_at)
  ON CONFLICT (lead_id, workflow_ref_id, tipo, occurred_on) WHERE workflow_ref_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_touchpoint_id;

  RETURN v_touchpoint_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_record_touchpoint(text, text, date, text, text, text, text, text, timestamptz) IS
  'v3 (migration 041): corrige o ON CONFLICT de v2 (040), que usava ON CONSTRAINT sobre um índice único PARCIAL — sintaticamente inválido no Postgres, só descoberto testando de verdade. Agora usa ON CONFLICT (colunas) WHERE ..., mesma forma já usada em conversion_event (026).';
