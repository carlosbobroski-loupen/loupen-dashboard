-- db/migrations/044_sync_state_watermark.sql
-- Subtask 2.20 / P-ING-2. LACUNA REAL ENCONTRADA ao escrever as asserções de
-- 2.20: a tabela `sync_state` existe desde a migration 007 e é citada no
-- header de 012, mas NADA NUNCA ESCREVEU NELA — tabela vazia, zero
-- INSERT/UPDATE em qualquer migration. A nota de 012 revela a intenção
-- original ("o nó de workflow grava esse número separadamente em
-- sync_state"), mas nenhum workflow n8n faz isso. Resultado: P-ING-2
-- (watermark incremental) não estava implementado de forma nenhuma.
--
-- Corrigido aqui, e no lugar certo: em SQL, não no n8n. CRIT-4 põe a regra de
-- negócio no banco; e um watermark escrito pelo n8n poderia divergir do
-- ingest_run escrito pelo SQL (dois escritores, duas verdades).
--
-- MECANISMO: função auxiliar fn_registrar_ingest() que grava ingest_run E
-- faz o upsert de sync_state na MESMA chamada — os dois nunca podem
-- divergir, porque são escritos juntos ou não são escritos. Substitui os 8
-- INSERTs duplicados de ingest_run espalhados por fn_run_ingest_batch.
--
-- DECISÃO DE DESENHO (a parte que mais importa): o watermark SÓ AVANÇA em
-- status='ok'. Se avançasse numa execução 'partial'/'failed', a próxima
-- consulta de delta começaria depois de registros que nunca foram
-- ingeridos — perda silenciosa de dado, exatamente a classe de defeito
-- (EC-6, sincronização parcial se apresentando como completa) que este
-- épico existe para corrigir. Em execução parcial/falha o watermark fica
-- onde estava e a janela é retentada na próxima rodada.
--
-- `nao_mapeado` continua gravando só em ingest_run (via INSERT direto, não
-- pela função): é relatório de falha, não watermark de uma fonte/objeto
-- real — não faria sentido ter linha em sync_state.

CREATE OR REPLACE FUNCTION fn_registrar_ingest(
  p_source        text,
  p_object        text,
  p_rows_source   integer,
  p_rows_target   integer,
  p_status        text,
  p_error_message text DEFAULT NULL
) RETURNS void AS $fn$
BEGIN
  INSERT INTO ingest_run (source, object, started_at, finished_at, rows_source, rows_target, status, error_message)
  VALUES (p_source, p_object, now(), now(), p_rows_source, p_rows_target, p_status, p_error_message);

  -- Watermark avança SOMENTE em execução íntegra (ver header).
  IF p_status = 'ok' THEN
    INSERT INTO sync_state (source, object, last_run_at, rows_source, rows_target)
    VALUES (p_source, p_object, now(), p_rows_source, p_rows_target)
    ON CONFLICT (source, object) DO UPDATE SET
      last_run_at = EXCLUDED.last_run_at,
      rows_source = EXCLUDED.rows_source,
      rows_target = EXCLUDED.rows_target;
  END IF;
END;
$fn$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_registrar_ingest(text, text, integer, integer, text, text) IS
  'Grava ingest_run + upsert de sync_state numa única chamada, para que os dois nunca divirjam. O watermark (sync_state) só avança quando status=''ok'' — avançar em execução parcial causaria perda silenciosa de dado no delta seguinte (EC-6).';

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
  r_we RECORD;
  r_fs RECORD;
  v_lead_source_id text;
  v_lead_id_fs bigint;
  v_stage_ref_id bigint;
  v_ultimo_stage_ref_id bigint;
  v_touchpoints_gravados integer;
  v_touchpoints_sem_lead integer;
  v_estagios_gravados integer;
  v_estagios_sem_lead integer;
  v_touchpoint_id_novo bigint;
  v_pendente_ads integer;
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
    PERFORM fn_registrar_ingest('salesforce', 'Owner', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
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
    PERFORM fn_registrar_ingest('salesforce', 'Account', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
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
    PERFORM fn_registrar_ingest('salesforce', 'Lead', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
    object_type := 'Lead'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;

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
    PERFORM fn_registrar_ingest('salesforce', 'Opportunity', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
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

    PERFORM fn_registrar_ingest('rd_station', 'ConversionEvent', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
    object_type := 'ConversionEvent'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- ── WorkflowEvent (RD Station) — S7, segunda metade de P-ING-5. ────────
  -- Payload esperado (montado pelo workflow n8n a partir de
  -- workflow_leads_started_list/workflow_leads_exited_list):
  -- {contact_uuid, workflow_id, workflow_nome, tipo: 'workflow_entrada'|
  --  'workflow_saida', occurred_at}. Grava via fn_record_touchpoint (3.13),
  -- nunca direto em lead_touchpoint.
  SELECT count(*) INTO v_rows_source FROM stg_rdstation s WHERE s.batch_id = p_batch_id AND s.object_type = 'WorkflowEvent';
  IF v_rows_source > 0 THEN
    INSERT INTO automation_workflow (source_system, source_id, nome, collected_at)
    SELECT DISTINCT ON (s.payload->>'workflow_id')
      'rd_station', s.payload->>'workflow_id', s.payload->>'workflow_nome', s.collected_at
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'WorkflowEvent'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, collected_at = EXCLUDED.collected_at, ingested_at = now();

    v_touchpoints_gravados := 0;
    v_touchpoints_sem_lead := 0;
    FOR r_we IN
      SELECT s.payload AS payload, s.collected_at AS collected_at
      FROM stg_rdstation s
      WHERE s.batch_id = p_batch_id AND s.object_type = 'WorkflowEvent'
    LOOP
      SELECT l.source_id INTO v_lead_source_id
      FROM identity_edge rd
      JOIN identity_edge sf ON sf.person_id = rd.person_id AND sf.source_system = 'salesforce'
      JOIN lead l ON l.source_system = 'salesforce' AND l.source_id = sf.source_record_id
      WHERE rd.source_system = 'rd_station' AND rd.identifier_type = 'rdstation_uuid'
        AND rd.identifier_value = r_we.payload->>'contact_uuid'
      LIMIT 1;

      IF v_lead_source_id IS NULL THEN
        v_touchpoints_sem_lead := v_touchpoints_sem_lead + 1;
        CONTINUE;
      END IF;

      SELECT fn_record_touchpoint(
        'salesforce', v_lead_source_id,
        NULLIF(r_we.payload->>'occurred_at', '')::timestamptz::date,
        'rd_station', r_we.payload->>'tipo', NULL,
        'rd_station', r_we.payload->>'workflow_id',
        r_we.collected_at
      ) INTO v_touchpoint_id_novo;
      IF v_touchpoint_id_novo IS NOT NULL THEN
        v_touchpoints_gravados := v_touchpoints_gravados + 1;
      END IF;
    END LOOP;

    PERFORM fn_registrar_ingest('rd_station', 'WorkflowEvent', v_rows_source, v_touchpoints_gravados, CASE WHEN v_touchpoints_sem_lead = 0 THEN 'ok' ELSE 'partial' END, CASE WHEN v_touchpoints_sem_lead > 0
        THEN format('%s evento(s) de workflow sem lead vinculado via identity_edge (contato ainda não resolvido pela Tier 1 — rodar fn_identity_tier1_resolve antes deste pull).', v_touchpoints_sem_lead)
        ELSE NULL END);
    object_type := 'WorkflowEvent'; rows_source := v_rows_source; rows_target := v_touchpoints_gravados;
    status := CASE WHEN v_touchpoints_sem_lead = 0 THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- ── FunnelStage (RD Station) — DM-8 por lead, segunda metade de P-ING-5.
  -- Payload esperado (de contact_funnel_stage_get): {contact_uuid,
  -- lifecycle_stage}. Vocabulário upsertado dinamicamente (nunca um enum
  -- fixo adivinhado). Só grava quando o estágio DIFERE do último já
  -- registrado para aquele lead.
  SELECT count(*) INTO v_rows_source FROM stg_rdstation s WHERE s.batch_id = p_batch_id AND s.object_type = 'FunnelStage';
  IF v_rows_source > 0 THEN
    INSERT INTO funnel_stage (origem, nome)
    SELECT DISTINCT 'rd_station', s.payload->>'lifecycle_stage'
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'FunnelStage' AND s.payload->>'lifecycle_stage' IS NOT NULL
    ON CONFLICT (origem, nome) DO NOTHING;

    v_estagios_gravados := 0;
    v_estagios_sem_lead := 0;
    FOR r_fs IN
      SELECT s.payload AS payload, s.collected_at AS collected_at
      FROM stg_rdstation s
      WHERE s.batch_id = p_batch_id AND s.object_type = 'FunnelStage'
    LOOP
      SELECT l.id INTO v_lead_id_fs
      FROM identity_edge rd
      JOIN identity_edge sf ON sf.person_id = rd.person_id AND sf.source_system = 'salesforce'
      JOIN lead l ON l.source_system = 'salesforce' AND l.source_id = sf.source_record_id
      WHERE rd.source_system = 'rd_station' AND rd.identifier_type = 'rdstation_uuid'
        AND rd.identifier_value = r_fs.payload->>'contact_uuid'
      LIMIT 1;

      IF v_lead_id_fs IS NULL THEN
        v_estagios_sem_lead := v_estagios_sem_lead + 1;
        CONTINUE;
      END IF;

      SELECT fs.id INTO v_stage_ref_id FROM funnel_stage fs
      WHERE fs.origem = 'rd_station' AND fs.nome = r_fs.payload->>'lifecycle_stage';

      SELECT fse.funnel_stage_ref_id INTO v_ultimo_stage_ref_id
      FROM lead_funnel_stage_event fse
      WHERE fse.lead_id = v_lead_id_fs
      ORDER BY fse.occurred_on DESC, fse.id DESC
      LIMIT 1;

      IF v_ultimo_stage_ref_id IS NOT DISTINCT FROM v_stage_ref_id THEN
        CONTINUE;
      END IF;

      INSERT INTO lead_funnel_stage_event (lead_id, funnel_stage_ref_id, occurred_on, fonte, collected_at)
      VALUES (v_lead_id_fs, v_stage_ref_id, r_fs.collected_at::date, 'rd_station', r_fs.collected_at)
      ON CONFLICT (lead_id, funnel_stage_ref_id, occurred_on) DO NOTHING;
      v_estagios_gravados := v_estagios_gravados + 1;
    END LOOP;

    PERFORM fn_registrar_ingest('rd_station', 'FunnelStage', v_rows_source, v_estagios_gravados, CASE WHEN v_estagios_sem_lead = 0 THEN 'ok' ELSE 'partial' END, CASE WHEN v_estagios_sem_lead > 0
        THEN format('%s contato(s) sem lead vinculado via identity_edge (não resolvido pela Tier 1).', v_estagios_sem_lead)
        ELSE NULL END);
    object_type := 'FunnelStage'; rows_source := v_rows_source; rows_target := v_estagios_gravados;
    status := CASE WHEN v_estagios_sem_lead = 0 THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- ── ad_campaign (Meta/Google/LinkedIn Ads) — 2.18, ADAPT do workflow de ads
  -- existente. campaign_ref_id fica NULL por desenho (DM-6: nem toda ad_campaign
  -- tem uma campaign correspondente conhecida) — não força um match adivinhado.
  SELECT count(*) INTO v_rows_source FROM stg_ads s WHERE s.batch_id = p_batch_id AND s.object_type = 'campaign';
  IF v_rows_source > 0 THEN
    INSERT INTO ad_campaign (source_system, source_id, plataforma, campanha_id, metricas, collected_at)
    SELECT s.source_system, s.payload->>'source_id', s.payload->>'plataforma', s.payload->>'source_id', s.payload->'metricas', s.collected_at
    FROM stg_ads s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'campaign'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      plataforma = EXCLUDED.plataforma, metricas = EXCLUDED.metricas, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    PERFORM fn_registrar_ingest('ads', 'ad_campaign', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
    object_type := 'ad_campaign'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- Fontes ainda sem mapeamento (ads/sheets, e RD Station fora dos 3 tipos
  -- já cobertos): reportadas como falha explícita, nunca zero silencioso.
  SELECT count(*) INTO v_pendente_nao_mapeado
  FROM (
    SELECT r.batch_id FROM stg_rdstation r WHERE r.batch_id = p_batch_id AND r.object_type NOT IN ('ConversionEvent', 'WorkflowEvent', 'FunnelStage')
    UNION ALL
    SELECT a.batch_id FROM stg_ads a WHERE a.batch_id = p_batch_id AND a.object_type <> 'campaign'
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
  'v8 (migration 044): passa a gravar sync_state (P-ING-2, watermark incremental) via fn_registrar_ingest, que escreve ingest_run e sync_state juntos. Watermark só avança em status=ok. Mapeamentos de dado inalterados desde v7/043.';
