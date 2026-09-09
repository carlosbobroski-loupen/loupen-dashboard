-- db/migrations/026_fn_run_ingest_batch_atribuicao.sql
-- Subtask 3.9 (segunda metade de ADR-015). Acopla a chamada de
-- fn_classify_origin ao lote de ingestão de Lead (Salesforce): depois do
-- upsert, seleciona só os leads NOVOS ou com sinal alterado desde a
-- última classificação (origem_bruta ou campanha_linkedin_bruta
-- diferentes do valor_bruto já gravado), classifica, e grava como NOVA
-- VERSÃO em lead_origin_classification — nunca sobrescreve o histórico.
--
-- Tudo na MESMA transação da procedure: se a atribuição falhar, a
-- ingestão do lote inteiro não é gravada pela metade (a procedure inteira
-- já é uma transação, por ser uma função — nenhuma mudança aqui).
--
-- I3 na prática: is_first_touch é calculado (não existia versão anterior
-- para o lead) e a garantia real vem do TRIGGER de 2.10 — esta procedure
-- NÃO tenta capturar/ignorar erro do trigger; se tentar reescrever
-- first-touch, o trigger estoura e a procedure falha visivelmente (é bug,
-- não algo a esconder).
--
-- ESCOPO REAL: passo 5 do plano original ("gravar influência via 3.13")
-- NÃO está nesta versão — lead_touchpoint (S7) ainda não tem sua própria
-- função de gravação (3.13, ainda não implementada nesta sessão). Quando
-- existir, entra como um passo adicional aqui, sem mudar o que já
-- funciona.

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
  v_leads_classificados integer;
  v_lead_id_atribuicao bigint;
BEGIN
  -- Owner (Salesforce)
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

  -- Account (Salesforce)
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

  -- Lead (Salesforce)
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

    -- ── Atribuição (3.9): classifica leads deste batch cujo sinal bruto
    -- mudou (ou nunca foi classificado) desde a versão corrente. ──────────
    v_leads_classificados := 0;
    FOR v_lead_id_atribuicao IN
      SELECT l.id
      FROM lead l
      JOIN stg_salesforce s ON s.batch_id = p_batch_id AND s.object_type = 'Lead' AND s.payload->>'Id' = l.source_id
      LEFT JOIN lead_origin_classification cur ON cur.lead_id = l.id AND cur.valid_to IS NULL
      WHERE cur.id IS NULL
         OR cur.valor_bruto IS DISTINCT FROM COALESCE(l.campanha_linkedin_bruta, l.origem_bruta)
    LOOP
      DECLARE
        v_result RECORD;
        v_versao_atual lead_origin_classification%ROWTYPE;
        v_proxima_versao integer;
        v_ja_teve_first_touch boolean;
      BEGIN
        SELECT * INTO v_result FROM fn_classify_origin(v_lead_id_atribuicao);

        SELECT * INTO v_versao_atual FROM lead_origin_classification
        WHERE lead_id = v_lead_id_atribuicao AND valid_to IS NULL;

        SELECT EXISTS (
          SELECT 1 FROM lead_origin_classification WHERE lead_id = v_lead_id_atribuicao AND is_first_touch = true
        ) INTO v_ja_teve_first_touch;

        SELECT COALESCE(MAX(version), 0) + 1 INTO v_proxima_versao
        FROM lead_origin_classification WHERE lead_id = v_lead_id_atribuicao;

        IF v_versao_atual.id IS NOT NULL THEN
          -- Fecha a versão corrente (I4: só valid_to muda — permitido pelo trigger).
          UPDATE lead_origin_classification SET valid_to = now() WHERE id = v_versao_atual.id;
        END IF;

        INSERT INTO lead_origin_classification (
          lead_id, version, segmento, categoria, detalhe, campanha_id, sinal_id, valor_bruto, razao,
          is_first_touch, ruleset_version, classified_by, supersedes_id, reclass_reason, valid_from
        ) VALUES (
          v_lead_id_atribuicao, v_proxima_versao, v_result.segmento, v_result.categoria, v_result.detalhe,
          v_result.campanha_id, v_result.sinal_id, v_result.valor_bruto, v_result.razao,
          NOT v_ja_teve_first_touch,
          'v1-s1-s3-s5-s9-s6',
          CASE WHEN v_versao_atual.id IS NOT NULL THEN 'reclass:fn_run_ingest_batch' ELSE 'ingest:fn_run_ingest_batch' END,
          v_versao_atual.id,
          CASE WHEN v_versao_atual.id IS NOT NULL
            THEN format('Sinal bruto mudou de "%s" para "%s" entre execuções de ingestão.', v_versao_atual.valor_bruto, v_result.valor_bruto)
            ELSE NULL END,
          now()
        );
        v_leads_classificados := v_leads_classificados + 1;
      END;
    END LOOP;

    IF v_leads_classificados > 0 THEN
      object_type := 'Lead_Atribuicao'; rows_source := v_leads_classificados; rows_target := v_leads_classificados; status := 'ok';
      RETURN NEXT;
    END IF;
  END IF;

  -- Opportunity (Salesforce)
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

  -- ConversionEvent (RD Station)
  SELECT count(*) INTO v_rows_source FROM stg_rdstation s WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent';
  IF v_rows_source > 0 THEN
    INSERT INTO contact (source_system, source_id, nome, email, telefone, collected_at)
    SELECT
      'rd_station', s.payload->>'uuid',
      COALESCE(s.payload#>>'{last_conversion,content,Nome}', s.payload->>'name'),
      COALESCE(s.payload#>>'{last_conversion,content,email_lead}', s.payload->>'email'),
      COALESCE(s.payload#>>'{last_conversion,content,Telefone}', s.payload->>'personal_phone'),
      s.collected_at
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, email = EXCLUDED.email, telefone = EXCLUDED.telefone,
      collected_at = EXCLUDED.collected_at, ingested_at = now();

    INSERT INTO campaign (source_system, source_id, nome, codigo_leadsource, canal, collected_at)
    SELECT DISTINCT ON (codigo)
      'rd_station', codigo, codigo, codigo, 'rd_station', s.collected_at
    FROM (
      SELECT
        COALESCE(s.payload#>>'{last_conversion,content,identificador}', s.payload#>>'{last_conversion,content,utm_campaign}') AS codigo,
        s.collected_at
      FROM stg_rdstation s
      WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent'
    ) s
    WHERE codigo IS NOT NULL
    ON CONFLICT (source_system, source_id) DO NOTHING;

    INSERT INTO conversion_event (contact_id, campaign_ref_id, tipo, ativo_de_origem, source_system, source_event_id, occurred_at, date_traceable, collected_at)
    SELECT
      c.id, camp.id, 'conversao',
      COALESCE(s.payload#>>'{last_conversion,content,identificador}', s.payload#>>'{last_conversion,content,event_identifier}'),
      'rd_station',
      s.payload#>>'{last_conversion,content,__cdp__original_event,event_uuid}',
      NULLIF(s.payload#>>'{last_conversion,created_at}', '')::timestamptz,
      (s.payload#>>'{last_conversion,created_at}') IS NOT NULL,
      s.collected_at
    FROM stg_rdstation s
    JOIN contact c ON c.source_system = 'rd_station' AND c.source_id = s.payload->>'uuid'
    LEFT JOIN campaign camp ON camp.source_system = 'rd_station'
      AND camp.source_id = COALESCE(s.payload#>>'{last_conversion,content,identificador}', s.payload#>>'{last_conversion,content,utm_campaign}')
    WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent'
    ON CONFLICT (source_system, source_event_id, occurred_at) WHERE source_event_id IS NOT NULL DO UPDATE SET
      contact_id = EXCLUDED.contact_id, campaign_ref_id = EXCLUDED.campaign_ref_id, tipo = EXCLUDED.tipo,
      ativo_de_origem = EXCLUDED.ativo_de_origem,
      date_traceable = EXCLUDED.date_traceable, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;

    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status)
    VALUES ('rd_station', 'ConversionEvent', now(), now(), v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END);
    object_type := 'ConversionEvent'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  SELECT count(*) INTO v_pendente_nao_mapeado
  FROM (
    SELECT r.batch_id FROM stg_rdstation r WHERE r.batch_id = p_batch_id AND r.object_type <> 'ConversionEvent'
    UNION ALL
    SELECT a.batch_id FROM stg_ads a WHERE a.batch_id = p_batch_id
    UNION ALL
    SELECT sh.batch_id FROM stg_sheets sh WHERE sh.batch_id = p_batch_id
  ) pendentes;

  IF v_pendente_nao_mapeado > 0 THEN
    INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status, error_message)
    VALUES ('ads_sheets_ou_rdstation_outro_tipo', 'nao_mapeado', now(), now(), v_pendente_nao_mapeado, 0, 'failed',
      'Mapeamento staging→canônico ainda não implementado para este object_type — staging recebido mas NÃO processado, reportado como falha explícita.');
    object_type := 'nao_mapeado'; rows_source := v_pendente_nao_mapeado; rows_target := 0; status := 'failed';
    RETURN NEXT;
  END IF;

  RETURN;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_run_ingest_batch(text) IS
  'v4 (migration 026): acopla fn_classify_origin ao upsert de Lead (Salesforce) — classifica leads novos ou com sinal alterado, grava como nova versão em lead_origin_classification, respeitando I3 (first-touch) e I4 (append-only). RD Station ConversionEvent (v3/016) e Owner/Account/Opportunity (v1/012) inalterados.';
