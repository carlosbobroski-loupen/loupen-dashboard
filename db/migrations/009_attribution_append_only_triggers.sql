-- db/migrations/009_attribution_append_only_triggers.sql
-- Subtask 2.10. Os dois invariantes de I3/I4 postos NO BANCO, não só na
-- aplicação — a reclassificação é INSERT de nova versão, nunca UPDATE do
-- histórico (I4), e first-touch é gravado uma única vez por lead (I3).

-- I4: qualquer UPDATE em lead_origin_classification é rejeitado, A MENOS
-- que a ÚNICA coluna alterada seja valid_to (fechar uma versão corrente
-- para abrir espaço à próxima, no mesmo INSERT que a cria).
CREATE OR REPLACE FUNCTION fn_lead_origin_classification_no_mutate()
RETURNS trigger AS $$
BEGIN
  IF (to_jsonb(OLD) - 'valid_to') IS DISTINCT FROM (to_jsonb(NEW) - 'valid_to') THEN
    RAISE EXCEPTION 'I4 violado: lead_origin_classification é append-only — só valid_to pode ser atualizado (fechar uma versão). Para reclassificar, faça INSERT de uma nova versão, nunca UPDATE do histórico.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lead_origin_classification_no_mutate ON lead_origin_classification;
CREATE TRIGGER trg_lead_origin_classification_no_mutate
  BEFORE UPDATE ON lead_origin_classification
  FOR EACH ROW EXECUTE FUNCTION fn_lead_origin_classification_no_mutate();

-- I3: first-touch é gravado uma única vez por lead, nunca sobrescrito por
-- reingestão. Uma segunda linha com is_first_touch=true para o mesmo lead
-- é rejeitada no INSERT, não silenciosamente substituída.
CREATE OR REPLACE FUNCTION fn_lead_origin_classification_first_touch_once()
RETURNS trigger AS $$
BEGIN
  IF NEW.is_first_touch THEN
    IF EXISTS (
      SELECT 1 FROM lead_origin_classification
      WHERE lead_id = NEW.lead_id AND is_first_touch = true
    ) THEN
      RAISE EXCEPTION 'I3 violado: já existe uma classificação first-touch para o lead % — first-touch é gravado uma única vez e nunca sobrescrito por reingestão.', NEW.lead_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lead_origin_classification_first_touch_once ON lead_origin_classification;
CREATE TRIGGER trg_lead_origin_classification_first_touch_once
  BEFORE INSERT ON lead_origin_classification
  FOR EACH ROW EXECUTE FUNCTION fn_lead_origin_classification_first_touch_once();
