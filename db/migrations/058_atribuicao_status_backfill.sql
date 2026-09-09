-- db/migrations/058_atribuicao_status_backfill.sql
-- Subtask 8.15 — permite que uma reingestao COMPLETE o atribuicao_status dos
-- eventos gravados antes da migration 057, sem reescrever dado de negocio.
--
-- O PROBLEMA QUE A 057 DEIXOU
-- A 057 criou a coluna e passou a preenche-la nos eventos NOVOS. Mas a dedup
-- usa `ON CONFLICT ... DO NOTHING`, entao os 766 eventos que ja estavam no
-- banco continuariam com status nulo para sempre — e a secao de atribuicao da
-- aba de qualidade ficaria sem informacao ate alguem apagar e reingerir tudo.
--
-- A SOLUCAO, E POR QUE ELA E SEGURA
-- O ON CONFLICT passa a `DO UPDATE`, mas com duas travas:
--   WHERE ... atribuicao_status IS NULL      (so completa o que falta)
--   COALESCE(atual, novo)                    (nunca sobrescreve valor definido)
-- e NENHUMA outra coluna entra no SET. A regra de negocio da dedup (mesmo
-- lead, mesma origem, mesmo instante E o mesmo evento) fica intacta.
--
-- ARMADILHA QUE ISSO CRIOU, E QUE EU QUASE DEIXEI PASSAR
-- O contador de eventos gravados usava `IF FOUND`. Com DO UPDATE condicional,
-- `FOUND` passa a ser true tambem quando o conflito apenas preencheu o status
-- de um evento pre-existente — o que inflaria `rows_target` e destruiria a
-- prova de idempotencia: reprocessar o mesmo lote passaria a reportar linhas
-- novas que nao existem. A v11 distingue os dois pelo `ingested_at` da linha
-- contra o inicio do lote, e reporta o preenchimento como um objeto separado
-- (`LeadConversion_StatusPreenchido`) em vez de somar.
--
-- E o mesmo tipo de erro da migration 042 (PERFORM descartando o retorno que
-- servia de contador): a metrica mente enquanto o dado esta certo. Metrica que
-- mente e pior que metrica ausente, porque ninguem desconfia dela.

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
  -- v9 (migration 048)
  v_lead_source_system text;
  v_lead_id_we bigint;
  r_lc RECORD;
  v_lead_id_lc bigint;
  v_conv_gravadas integer;
  v_conv_sem_lead integer;
  v_leads_escalados integer;
  v_lead_id_rd bigint;
  -- v11 (migration 058)
  v_conv_status_preenchido integer;
  v_inicio_lote timestamptz;
BEGIN
  v_inicio_lote := clock_timestamp();
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

  -- ── RDLead (RD Station) — DESCOBERTA de lead, subtask 8.4. ─────────────
  -- Payload esperado (montado pelo n8n a partir de
  -- segmentations/{id}/contacts + contacts/{uuid}):
  --   {uuid, name, email, empresa, job_title, cf_tamanho_da_empresa,
  --    cf_falou_com, tags[], created_at, origem_primeira_conversao}
  --
  -- Precede as demais seções de RD de propósito: contato e lead têm de
  -- existir antes de ConversionEvent/WorkflowEvent/FunnelStage tentarem
  -- resolvê-los.
  SELECT count(*) INTO v_rows_source FROM stg_rdstation s WHERE s.batch_id = p_batch_id AND s.object_type = 'RDLead';
  IF v_rows_source > 0 THEN
    INSERT INTO contact (source_system, source_id, nome, email, collected_at)
    SELECT 'rd_station', s.payload->>'uuid', NULLIF(s.payload->>'name',''), NULLIF(s.payload->>'email',''), s.collected_at
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'RDLead'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, email = EXCLUDED.email,
      collected_at = EXCLUDED.collected_at, ingested_at = now();

    INSERT INTO lead (
      source_system, source_id, nome, empresa, email, origem_bruta,
      cargo, tamanho_empresa_bruto, atendido_por, tags,
      is_teste, teste_regra, created_at_source, collected_at
    )
    SELECT
      'rd_station', s.payload->>'uuid',
      NULLIF(s.payload->>'name',''),
      NULLIF(s.payload->>'empresa',''),
      NULLIF(s.payload->>'email',''),
      NULLIF(s.payload->>'origem_primeira_conversao',''),
      NULLIF(s.payload->>'job_title',''),
      NULLIF(s.payload->>'cf_tamanho_da_empresa',''),
      NULLIF(s.payload->>'cf_falou_com',''),
      CASE WHEN jsonb_typeof(s.payload->'tags') = 'array'
           THEN ARRAY(SELECT jsonb_array_elements_text(s.payload->'tags'))
           ELSE NULL END,
      fn_lead_e_teste(NULLIF(s.payload->>'email','')) IS NOT NULL,
      fn_lead_e_teste(NULLIF(s.payload->>'email','')),
      NULLIF(s.payload->>'created_at','')::timestamptz,
      s.collected_at
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'RDLead'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome                  = EXCLUDED.nome,
      empresa               = COALESCE(EXCLUDED.empresa, lead.empresa),
      email                 = EXCLUDED.email,
      origem_bruta          = COALESCE(lead.origem_bruta, EXCLUDED.origem_bruta),
      cargo                 = EXCLUDED.cargo,
      tamanho_empresa_bruto = EXCLUDED.tamanho_empresa_bruto,
      atendido_por          = EXCLUDED.atendido_por,
      tags                  = EXCLUDED.tags,
      -- is_teste é MONOTÔNICO: uma execução nova nunca "des-marca" um lead.
      is_teste              = lead.is_teste OR EXCLUDED.is_teste,
      teste_regra           = COALESCE(lead.teste_regra, EXCLUDED.teste_regra),
      collected_at          = EXCLUDED.collected_at,
      ingested_at           = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;

    PERFORM fn_registrar_ingest('rd_station', 'RDLead', v_rows_source, v_rows_target,
      CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
    object_type := 'RDLead'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;

    -- Classificação de origem dos leads nativos do RD. Sem isto, `segmento`
    -- ficaria nulo para 100% dos leads do RD e o contrato (que exige sempre
    -- um dos 3 valores) seria violado na primeira consulta.
    v_leads_classificados := 0;
    FOR v_lead_id_rd IN
      SELECT l.id FROM lead l
      JOIN stg_rdstation s ON s.batch_id = p_batch_id AND s.object_type = 'RDLead'
                          AND s.payload->>'uuid' = l.source_id
      WHERE l.source_system = 'rd_station'
    LOOP
      IF fn_reclassificar_lead(v_lead_id_rd) THEN
        v_leads_classificados := v_leads_classificados + 1;
      END IF;
    END LOOP;

    IF v_leads_classificados > 0 THEN
      object_type := 'RDLead_Atribuicao'; rows_source := v_leads_classificados;
      rows_target := v_leads_classificados; status := 'ok';
      RETURN NEXT;
    END IF;
  END IF;

  -- ── LeadConversion (RD Station) — evento de conversão com firmografia e
  -- atribuição DO INSTANTE, subtask 8.4. Grava em lead_conversion_event
  -- (migration 045).
  --
  -- Payload esperado (do endpoint de eventos, event_type CONVERSION):
  --   {contact_uuid, origem_conversao, event_type, occurred_at,
  --    empresa_bruta, cargo, tamanho_empresa_bruto,
  --    primeiro_toque_bruto, ultimo_toque_bruto,
  --    utm_source, utm_medium, utm_campaign, utm_content, utm_term, utm_id,
  --    gclid, midia, campanha_de_origem}
  --
  -- primeiro_toque_bruto/ultimo_toque_bruto vêm da decodificação base64 de
  -- `traffic_source` feita no n8n (JS tem base64 nativo; SQL precisaria de
  -- decode+convert_from e ficaria ilegível). O valor CRU de cada sessão é
  -- preservado porque quando não há UTM a fonte manda a URL da sessão ou o
  -- literal `(none)` — e os dois são informação, não ausência dela.
  SELECT count(*) INTO v_rows_source FROM stg_rdstation s WHERE s.batch_id = p_batch_id AND s.object_type = 'LeadConversion';
  IF v_rows_source > 0 THEN
    v_conv_gravadas := 0;
    v_conv_sem_lead := 0;
    v_conv_status_preenchido := 0;
    FOR r_lc IN
      SELECT s.payload AS payload, s.collected_at AS collected_at
      FROM stg_rdstation s
      WHERE s.batch_id = p_batch_id AND s.object_type = 'LeadConversion'
    LOOP
      v_lead_id_lc := fn_resolve_lead_por_rd_uuid(r_lc.payload->>'contact_uuid');

      IF v_lead_id_lc IS NULL THEN
        v_conv_sem_lead := v_conv_sem_lead + 1;
        CONTINUE;
      END IF;

      INSERT INTO lead_conversion_event (
        lead_id, origem_conversao, event_type, occurred_at,
        empresa_bruta, cargo, tamanho_empresa_bruto, tamanho_empresa,
        primeiro_toque_bruto, ultimo_toque_bruto,
        utm_source, utm_medium, utm_campaign, utm_content, utm_term, utm_id,
        gclid, midia, campanha_de_origem, source_system, collected_at,
        atribuicao_status
      ) VALUES (
        v_lead_id_lc,
        r_lc.payload->>'origem_conversao',
        COALESCE(NULLIF(r_lc.payload->>'event_type',''), 'CONVERSION'),
        NULLIF(r_lc.payload->>'occurred_at','')::timestamptz,
        NULLIF(r_lc.payload->>'empresa_bruta',''),
        NULLIF(r_lc.payload->>'cargo',''),
        NULLIF(r_lc.payload->>'tamanho_empresa_bruto',''),
        fn_normalizar_tamanho_empresa(NULLIF(r_lc.payload->>'tamanho_empresa_bruto','')),
        NULLIF(r_lc.payload->>'primeiro_toque_bruto',''),
        NULLIF(r_lc.payload->>'ultimo_toque_bruto',''),
        NULLIF(r_lc.payload->>'utm_source',''),
        NULLIF(r_lc.payload->>'utm_medium',''),
        NULLIF(r_lc.payload->>'utm_campaign',''),
        NULLIF(r_lc.payload->>'utm_content',''),
        NULLIF(r_lc.payload->>'utm_term',''),
        NULLIF(r_lc.payload->>'utm_id',''),
        NULLIF(r_lc.payload->>'gclid',''),
        NULLIF(r_lc.payload->>'midia',''),
        NULLIF(r_lc.payload->>'campanha_de_origem',''),
        'rd_station',
        r_lc.collected_at,
        -- v10: separa "a fonte nao mandou" de "mandou e nao conseguimos ler".
        -- O coletor no n8n envia o marcador; se vier ausente do payload,
        -- infere-se pelo que chegou, sem inventar: sessao presente => ok.
        COALESCE(
          NULLIF(r_lc.payload->>'atribuicao_status', ''),
          CASE WHEN NULLIF(r_lc.payload->>'primeiro_toque_bruto','') IS NOT NULL
                 OR NULLIF(r_lc.payload->>'ultimo_toque_bruto','') IS NOT NULL
               THEN 'ok' ELSE NULL END
        )
      )
      -- Dedup por regra de negócio (data-contract.md §1.7): mesmo lead,
      -- mesma origem, mesmo instante É o mesmo evento. Duplicata real
      -- observada na fonte, diferindo só na codificação de um acento.
      -- v11: a dedup continua sendo regra de negocio (mesmo lead, mesma
      -- origem, mesmo instante E o mesmo evento), mas passa a PREENCHER
      -- atribuicao_status quando ele ainda esta nulo. Isso permite que uma
      -- reingestao complete os eventos gravados antes da migration 057 sem
      -- reescrever NENHUM dado de negocio: o COALESCE nunca sobrescreve um
      -- status ja definido, e nenhuma outra coluna e tocada.
      ON CONFLICT (lead_id, origem_conversao, occurred_at) DO UPDATE
        SET atribuicao_status = COALESCE(lead_conversion_event.atribuicao_status,
                                         EXCLUDED.atribuicao_status)
        WHERE lead_conversion_event.atribuicao_status IS NULL
          AND EXCLUDED.atribuicao_status IS NOT NULL;

      -- ARMADILHA DA v11: com DO UPDATE condicional, `FOUND` passa a ser
      -- true tambem quando o conflito apenas PREENCHEU o status de um evento
      -- que ja existia. Contar isso como "gravado" inflaria a metrica e
      -- destruiria a prova de idempotencia (reprocessar o mesmo lote
      -- passaria a reportar linhas novas). Distingo pelo xmin: linha recem
      -- inserida tem xmin igual a transacao corrente.
      IF FOUND THEN
        IF EXISTS (
          SELECT 1 FROM lead_conversion_event e
          WHERE e.lead_id = v_lead_id_lc
            AND e.origem_conversao = r_lc.payload->>'origem_conversao'
            AND e.occurred_at = NULLIF(r_lc.payload->>'occurred_at','')::timestamptz
            AND e.ingested_at >= v_inicio_lote
        ) THEN
          v_conv_gravadas := v_conv_gravadas + 1;
        ELSE
          v_conv_status_preenchido := v_conv_status_preenchido + 1;
        END IF;
      END IF;
    END LOOP;

    PERFORM fn_registrar_ingest('rd_station', 'LeadConversion', v_rows_source, v_conv_gravadas,
      CASE WHEN v_conv_sem_lead = 0 THEN 'ok' ELSE 'partial' END,
      CASE WHEN v_conv_sem_lead > 0
        THEN format('%s evento(s) de conversão sem lead resolvido — o contato não veio no mesmo lote de RDLead nem existe vínculo em identity_edge. Eventos NÃO foram descartados do staging: reprocessar o lote depois de ingerir os contatos.', v_conv_sem_lead)
        ELSE NULL END);
    object_type := 'LeadConversion'; rows_source := v_rows_source; rows_target := v_conv_gravadas;
    status := CASE WHEN v_conv_sem_lead = 0 THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;

    -- Reportado separado de propósito: preencher status em evento antigo NAO
    -- e ingestao de dado novo, e somar os dois esconderia que a ingestao foi
    -- idempotente.
    IF v_conv_status_preenchido > 0 THEN
      PERFORM fn_registrar_ingest('rd_station', 'LeadConversion_StatusPreenchido',
        v_conv_status_preenchido, v_conv_status_preenchido, 'ok',
        format('%s evento(s) pre-existentes tiveram atribuicao_status preenchido (migration 057/058). Nenhum outro campo foi alterado.', v_conv_status_preenchido));
      object_type := 'LeadConversion_StatusPreenchido';
      rows_source := v_conv_status_preenchido; rows_target := v_conv_status_preenchido;
      status := 'ok';
      RETURN NEXT;
    END IF;

    -- Escalonamento de is_teste. As regras de gclid e de utm só podem ser
    -- avaliadas no EVENTO — o cadastro não tem esses campos. Um lead que
    -- passa pela regra de e-mail pode ainda assim ter eventos com utm de
    -- teste, e nesse caso quem manda é o evento.
    UPDATE lead l
       SET is_teste = true,
           teste_regra = COALESCE(l.teste_regra, s.regra),
           ingested_at = now()
      FROM (
        SELECT DISTINCT e.lead_id, fn_lead_e_teste(
                 NULL, e.gclid,
                 ARRAY[e.utm_source, e.utm_medium, e.utm_campaign, e.utm_content, e.utm_term, e.utm_id],
                 e.origem_conversao) AS regra
        FROM lead_conversion_event e
        JOIN lead l2 ON l2.id = e.lead_id AND NOT l2.is_teste
      ) s
     WHERE l.id = s.lead_id AND s.regra IS NOT NULL;
    GET DIAGNOSTICS v_leads_escalados = ROW_COUNT;

    IF v_leads_escalados > 0 THEN
      PERFORM fn_registrar_ingest('rd_station', 'LeadConversion_MarcacaoTeste', v_leads_escalados, v_leads_escalados, 'ok',
        format('%s lead(s) marcados como teste por regra de gclid/utm no evento — visível na aba Qualidade de dados, nunca deletados (data-contract.md §1.6).', v_leads_escalados));
      object_type := 'LeadConversion_MarcacaoTeste'; rows_source := v_leads_escalados;
      rows_target := v_leads_escalados; status := 'ok';
      RETURN NEXT;
    END IF;
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
      -- v9: resolve via fn_resolve_lead_por_rd_uuid (Tier1 Salesforce, senao
      -- lead nativo do RD). Antes daqui a resolucao era SO Salesforce, e os
      -- leads nativos do RD ficariam orfaos de funil/workflow.
      v_lead_id_we := fn_resolve_lead_por_rd_uuid(r_we.payload->>'contact_uuid');
      v_lead_source_system := NULL;
      v_lead_source_id := NULL;
      IF v_lead_id_we IS NOT NULL THEN
        SELECT l.source_system, l.source_id
          INTO v_lead_source_system, v_lead_source_id
        FROM lead l WHERE l.id = v_lead_id_we;
      END IF;

      IF v_lead_source_id IS NULL THEN
        v_touchpoints_sem_lead := v_touchpoints_sem_lead + 1;
        CONTINUE;
      END IF;

      SELECT fn_record_touchpoint(
        v_lead_source_system, v_lead_source_id,
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
      -- v9: idem WorkflowEvent.
      v_lead_id_fs := fn_resolve_lead_por_rd_uuid(r_fs.payload->>'contact_uuid');

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
    SELECT r.batch_id FROM stg_rdstation r WHERE r.batch_id = p_batch_id AND r.object_type NOT IN ('ConversionEvent', 'WorkflowEvent', 'FunnelStage', 'RDLead', 'LeadConversion')
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
  'v11 (migration 058): o ON CONFLICT de lead_conversion_event passa a preencher atribuicao_status quando nulo (COALESCE + WHERE IS NULL, nenhuma outra coluna tocada), permitindo que uma reingestao complete os eventos anteriores a 057. O contador distingue insercao de preenchimento para nao inflar rows_target nem destruir a prova de idempotencia, e reporta o preenchimento como LeadConversion_StatusPreenchido. Resto herdado da v10/057.';
