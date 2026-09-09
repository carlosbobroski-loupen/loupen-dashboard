-- db/queries/verificacao/join-conversao-accountid.sql
-- Subtask 3.17. Duas checagens: (a) view_lead_360 realmente usa
-- converted_account_id como chave de join (estrutural, lê a definição);
-- (b) NENHUMA view/função do schema faz join de lead para opportunity
-- usando origem_bruta/LeadSource (CON-4, varredura de definição).

-- (a) view_lead_360 referencia converted_account_id na sua definição.
DO $$
DECLARE v_def text;
BEGIN
  SELECT definition INTO v_def FROM pg_views WHERE schemaname='public' AND viewname='view_lead_360';
  IF v_def IS NULL OR v_def !~* 'converted_account_id' THEN
    RAISE EXCEPTION 'AC-2.2 violado: view_lead_360 não referencia converted_account_id na sua definição.';
  END IF;
  RAISE NOTICE 'AC-2.2(a) OK: view_lead_360 usa converted_account_id.';
END $$;

-- (b) nenhuma view do schema faz JOIN opportunity usando origem_bruta.
SELECT schemaname, viewname
FROM pg_views
WHERE schemaname = 'public'
  AND definition ~* 'opportunity'
  AND definition ~* 'origem_bruta';

DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM pg_views
  WHERE schemaname = 'public' AND definition ~* 'opportunity' AND definition ~* 'origem_bruta';
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'CON-4 violado: % view(s) referenciam opportunity E origem_bruta na mesma definição — risco de join por LeadSource em vez de ConvertedAccountId.', ofensoras;
  END IF;
  RAISE NOTICE 'CON-4(b) OK: nenhuma view mistura opportunity e origem_bruta.';
END $$;
