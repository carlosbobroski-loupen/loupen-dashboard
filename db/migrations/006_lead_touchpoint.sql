-- db/migrations/006_lead_touchpoint.sql
-- Subtask 2.8. Modelo de INFLUÊNCIA (multi-touch), P7 de spec.md §3.5 —
-- deliberadamente separado do modelo de ORIGEM (single-touch, que vive em
-- lead_origin_classification, migration 008). Os dois NUNCA são colapsados
-- no mesmo campo: um lead pode ter origem=Marketing E ainda assim aparecer
-- aqui tocado por um workflow que não o originou.
--
-- É AQUI, E SOMENTE AQUI, que S7 (participação em workflow do RD Station)
-- grava. S7 NUNCA classifica origem (automação de marketing toca leads que
-- não foram originados por marketing) — se um código em qualquer lugar
-- usar lead_touchpoint para decidir segmento, isso é o próprio bug que
-- esta epic existe para corrigir, só que reintroduzido por outra porta.

CREATE TABLE IF NOT EXISTS lead_touchpoint (
  id                bigserial PRIMARY KEY,
  lead_id           bigint NOT NULL REFERENCES lead(id),
  occurred_on       date NOT NULL,
  fonte             text NOT NULL,
  campanha          text,
  tipo              text NOT NULL,
  workflow_ref_id   bigint REFERENCES automation_workflow(id),
  collected_at      timestamptz NOT NULL,
  ingested_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE lead_touchpoint IS
  'Modelo de INFLUÊNCIA (multi-touch, P7/§3.5) — nunca usado para decidir segmento (Marketing/Comercial/NaoAtribuido), que é sempre single-touch e vive em lead_origin_classification (migration 008). S7 grava aqui e SOMENTE aqui.';
COMMENT ON COLUMN lead_touchpoint.occurred_on IS
  'DATE, não timestamptz — de propósito (CON-3/NFR-4/EC-10). Eventos de workflow do RD Station só atualizam 1x/dia na origem (ver automation_workflow.data_atualizacao_origem); armazenar como DATE impede tecnicamente qualquer comparação intradiária que fingiria uma precisão que a fonte não tem.';
