-- db/migrations/034_fn_record_touchpoint.sql
-- Subtask 3.13. Função de gravação do modelo de INFLUÊNCIA (multi-touch,
-- P7/§3.5) — é AQUI, e SOMENTE AQUI, que S7 (participação em workflow do
-- RD Station) grava. Nunca escreve em lead_origin_classification, nunca
-- chama fn_classify_origin — influência e origem são modelos
-- deliberadamente separados (ver COMMENT de lead_touchpoint, migration 006).
--
-- ESCOPO REAL: esta função é o mecanismo de escrita; a ingestão real de
-- eventos de workflow do RD Station (a segunda metade de P-ING-5, pull
-- agendado GET /platform/contacts/{uuid}/events) ainda não está
-- construída — quando existir, chama esta função por evento, não insere
-- direto em lead_touchpoint.

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
  RETURNING id INTO v_touchpoint_id;

  RETURN v_touchpoint_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_record_touchpoint(text, text, date, text, text, text, text, text, timestamptz) IS
  'S7 grava influência AQUI e SOMENTE AQUI (P7/§3.5) — nunca em lead_origin_classification, nunca chama fn_classify_origin. Mecanismo de escrita pronto; a ingestão real de eventos de workflow do RD Station (pull agendado) ainda não está construída (ver TODO em edge-routing.md/2.17).';
