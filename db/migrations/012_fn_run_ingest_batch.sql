-- db/migrations/012_fn_run_ingest_batch.sql
-- Subtask 2.13. [AUTO-DECISION — ADR-015] Uma procedure, chamada UMA vez
-- por execução de workflow do n8n, depois do insert em staging. Faz upsert
-- idempotente (ON CONFLICT em source_system/source_id, P-ING-1) de staging
-- para as tabelas canônicas, atualiza sync_state/ingest_run e retorna a
-- reconciliação — tudo em UMA transação (all-or-nothing por lote).
--
-- ESCOPO REAL DESTA VERSÃO (honesto, não invenção de cobertura que não
-- existe): mapeamento concreto implementado para Salesforce
-- Owner/Account/Lead/Opportunity — os objetos nomeados em 2.16 com os
-- nomes de campo já confirmados em project_salesforce_integration
-- (LeadSource, Campanha_LinkedIn__c, ConvertedAccountId, RecordType.Name,
-- Amount=MRR, StageName). RD Station/ads/sheets (stg_rdstation/stg_ads/
-- stg_sheets) ainda NÃO têm mapeamento de campos implementado aqui — a
-- procedure detecta staging pendente dessas fontes no batch e grava um
-- ingest_run(status='failed') com esse motivo explícito, em vez de
-- processar silenciosamente zero linhas e parecer sucesso. O mapeamento
-- real de RD Station/ads chega quando os workflows de 2.17/2.18 existirem
-- e a forma real do payload dessas APIs estiver confirmada — não antes,
-- para não inventar campo que ninguém validou contra a fonte real.
--
-- RECONCILIAÇÃO NESTA VERSÃO É POR LOTE (staged vs. escrito no canônico
-- NESTE batch), não a reconciliação TOTAL origem↔destino histórica (a que
-- resolve o 44-de-236 de EC-6). A reconciliação total exige o n8n consultar
-- a contagem TOTAL na origem (Bulk API/REST) e comparar contra
-- `SELECT count(*) FROM opportunity WHERE source_system='salesforce'` — não
-- cabe dentro de uma procedure de assinatura fixa (batch_id) chamada por
-- lote incremental. Isso é responsabilidade explícita de 2.16/2.17/2.18
-- (o nó de workflow grava esse número separadamente em sync_state).

CREATE OR REPLACE FUNCTION fn_run_ingest_batch(p_batch_id text)
RETURNS TABLE (
  object_type   text,
  rows_source   integer,
  rows_target   integer,
  status        text
) AS $$
DECLARE
  v_rows_source integer;
  v_rows_target integer;
  v_pendente_nao_mapeado integer;
BEGIN
  -- Owner (Salesforce) — sem dependência, processado primeiro.
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'Owner';
  IF v_rows_source > 0 THEN
    INSERT INTO owner (source_system, source_id, nome, email, collected_at)
    SELECT 'salesforce', s.payload->>'Id', s.payload->>'Name', s.payload->>'Email', s.collected_at
    FROM stg_salesforce s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'Owner'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, email = EXCLUDED.email, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status)
    VALUES ('salesforce', 'Owner', now(), now(), v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END);
    object_type := 'Owner'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- Account (Salesforce) — depende de nada além de existir.
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'Account';
  IF v_rows_source > 0 THEN
    INSERT INTO account (source_system, source_id, nome, collected_at)
    SELECT 'salesforce', s.payload->>'Id', s.payload->>'Name', s.collected_at
    FROM stg_salesforce s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'Account'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status)
    VALUES ('salesforce', 'Account', now(), now(), v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END);
    object_type := 'Account'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- Lead (Salesforce) — origem_bruta/campanha_linkedin_bruta preservados
  -- sem transformação (P6); classificação de origem NÃO acontece aqui
  -- (fn_classify_origin é phase-3, wiring é subtask 3.9, deliberadamente
  -- separado desta procedure).
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'Lead';
  IF v_rows_source > 0 THEN
    INSERT INTO lead (source_system, source_id, nome, empresa, email, telefone, status, origem_bruta, campanha_linkedin_bruta, converted_account_id, owner_id, created_at_source, collected_at)
    SELECT
      'salesforce', s.payload->>'Id', s.payload->>'Name', s.payload->>'Company', s.payload->>'Email', s.payload->>'Phone',
      s.payload->>'Status', s.payload->>'LeadSource', s.payload->>'Campanha_LinkedIn__c', s.payload->>'ConvertedAccountId',
      o.id, NULLIF(s.payload->>'CreatedDate','')::timestamptz, s.collected_at
    FROM stg_salesforce s
    LEFT JOIN owner o ON o.source_system = 'salesforce' AND o.source_id = s.payload->>'OwnerId'
    WHERE s.batch_id = p_batch_id AND s.object_type = 'Lead'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, empresa = EXCLUDED.empresa, email = EXCLUDED.email, telefone = EXCLUDED.telefone,
      status = EXCLUDED.status, origem_bruta = EXCLUDED.origem_bruta, campanha_linkedin_bruta = EXCLUDED.campanha_linkedin_bruta,
      converted_account_id = EXCLUDED.converted_account_id, owner_id = EXCLUDED.owner_id,
      collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status)
    VALUES ('salesforce', 'Lead', now(), now(), v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END);
    object_type := 'Lead'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- Opportunity (Salesforce) — RecordType.Name vem aninhado no payload
  -- padrão da API (CON-4: sinal de Produto/Serviço). Amount é MRR bruto,
  -- NUNCA valor de contrato (ver COMMENT em opportunity.amount, migration 002).
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'Opportunity';
  IF v_rows_source > 0 THEN
    INSERT INTO opportunity (source_system, source_id, account_id, record_type_name, stage_name, amount, duracao_meses_contrato, owner_id, created_at_source, closed_at_source, collected_at)
    SELECT
      'salesforce', s.payload->>'Id', a.id, s.payload#>>'{RecordType,Name}', s.payload->>'StageName',
      NULLIF(s.payload->>'Amount','')::numeric, NULLIF(s.payload->>'DuracaoMesesContrato__c','')::integer,
      o.id, NULLIF(s.payload->>'CreatedDate','')::timestamptz, NULLIF(s.payload->>'CloseDate','')::timestamptz, s.collected_at
    FROM stg_salesforce s
    LEFT JOIN account a ON a.source_system = 'salesforce' AND a.source_id = s.payload->>'AccountId'
    LEFT JOIN owner o ON o.source_system = 'salesforce' AND o.source_id = s.payload->>'OwnerId'
    WHERE s.batch_id = p_batch_id AND s.object_type = 'Opportunity'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      account_id = EXCLUDED.account_id, record_type_name = EXCLUDED.record_type_name, stage_name = EXCLUDED.stage_name,
      amount = EXCLUDED.amount, duracao_meses_contrato = EXCLUDED.duracao_meses_contrato, owner_id = EXCLUDED.owner_id,
      closed_at_source = EXCLUDED.closed_at_source, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status)
    VALUES ('salesforce', 'Opportunity', now(), now(), v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END);
    object_type := 'Opportunity'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- Fontes ainda sem mapeamento implementado (RD Station, ads, sheets):
  -- se o batch tem staging pendente dessas fontes, isso é reportado como
  -- FALHA EXPLÍCITA, nunca como sucesso silencioso de zero linhas.
  SELECT count(*) INTO v_pendente_nao_mapeado
  FROM (
    SELECT batch_id FROM stg_rdstation WHERE batch_id = p_batch_id
    UNION ALL
    SELECT batch_id FROM stg_ads WHERE batch_id = p_batch_id
    UNION ALL
    SELECT batch_id FROM stg_sheets WHERE batch_id = p_batch_id
  ) pendentes;

  IF v_pendente_nao_mapeado > 0 THEN
    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status, error_message)
    VALUES ('rdstation_ads_sheets', 'nao_mapeado', now(), now(), v_pendente_nao_mapeado, 0, 'failed',
      'Mapeamento staging→canônico para RD Station/ads/sheets ainda não implementado nesta procedure (ver header de 012_fn_run_ingest_batch.sql) — staging recebido mas NÃO processado, reportado como falha explícita.');
    object_type := 'nao_mapeado'; rows_source := v_pendente_nao_mapeado; rows_target := 0; status := 'failed';
    RETURN NEXT;
  END IF;

  RETURN;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_run_ingest_batch(text) IS
  'Chamada única por execução de workflow n8n (ADR-015), após insert em staging. Upsert idempotente por batch_id, transação única (all-or-nothing). Reconciliação é POR LOTE, não a reconciliação total origem↔destino (essa é responsabilidade do workflow n8n, ver header do arquivo).';
