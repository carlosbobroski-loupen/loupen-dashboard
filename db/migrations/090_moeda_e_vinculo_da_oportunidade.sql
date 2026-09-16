-- db/migrations/090_moeda_e_vinculo_da_oportunidade.sql
--
-- O BANCO ESTAVA SOMANDO DÓLAR COM REAL. Medido, não suspeitado.
--
-- A org do Salesforce é multi-moeda desde sempre e a ingestão nunca trouxe o
-- campo que diz qual moeda cada oportunidade usa. `Opportunity.Amount` entrou
-- aqui como um numérico sem unidade, e toda soma feita em cima dele — a aba
-- Leads, view_receita, view_pessoa_jornada_desfecho — somou grandezas
-- diferentes como se fossem a mesma.
--
-- Das 5.431 oportunidades da janela de 12 meses (CreatedDate >= 2025-09-14):
--   BRL 4.173 · USD 841 · MXN 417
-- Ou seja: 23% dos registros estavam na unidade errada. Não é caso de borda.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- A SEMÂNTICA DA TAXA, VERIFICADA POR QUATRO CAMINHOS INDEPENDENTES
--
-- `CurrencyType.ConversionRate` no Salesforce é CORPORATIVA -> ESTRANGEIRA.
-- A corporativa aqui é BRL, com taxa 1. Logo a conversão é uma DIVISÃO:
--
--     valor_brl = amount / conversion_rate
--
-- Lido na origem em 2026-09-16 (SELECT ... FROM CurrencyType):
--   BRL  1.00000  IsCorporate=true
--   MXN  3.40986  IsCorporate=false
--   USD  0.19604  IsCorporate=false
--
--   1) A própria definição do campo (corporativa=1, estrangeira≠1).
--   2) 1 / 0,19604 = 5,101000 — o câmbio USD/BRL plausível. A recíproca da
--      hipótese contrária (0,19604 BRL por dólar) seria absurda.
--   3) Uma auditoria anterior mediu por engenharia reversa, comparando 3
--      oportunidades ganhas contra a planilha exportada do Salesforce, e achou
--      razão exatamente 5,101 em duas linhas USD e 1,000 na linha BRL.
--   4) 🎯 RECONCILIAÇÃO AO CENTAVO, feita nesta migration:
--      O SOQL agregado devolve SUM(Amount) JÁ CONVERTIDO para a moeda
--      corporativa (comportamento documentado do Salesforce em orgs
--      multi-moeda). As somas das ganhas da janela vieram de lá assim:
--        BRL 701 -> 1.742.219,98 | USD 238 -> 1.871.669,00 | MXN 53 -> 229.425,81
--      Desfazendo a conversão (multiplicando de volta pela taxa) para chegar ao
--      valor CRU que este banco guarda:
--        1.742.219,98 + 1.871.669,00 × 0,19604 + 229.425,81 × 3,40986
--        = 2.891.451,86
--      E o banco, nas mesmas 992 linhas:
--        select sum(amount) from opportunity
--         where stage_name='Ganho' and created_at_source >= '2025-09-14'
--        = 2.891.451,86
--      Diferença: R$ 0,00. Mesma contagem (992 = 701+238+53), mesmo centavo.
--      Não sobra hipótese alternativa.
--
-- CONSEQUÊNCIA MEDIDA: as 992 ganhas da janela valem 3.843.314,79 convertidas,
-- e não 2.891.451,86. O banco estava subestimando a receita em R$ 951.862,93
-- (+32,9%), porque a maior parte do volume estrangeiro é USD, cujo valor cru é
-- ~5x menor que o equivalente em real.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠️ LIMITAÇÃO DECLARADA, NÃO CORRIGIDA: NÃO HÁ TAXA DATADA
--
-- `SELECT ... FROM DatedConversionRate` devolve ZERO linhas nesta org
-- (verificado em 2026-09-16). Não existe histórico de câmbio no Salesforce
-- aqui. A conversão usa sempre a taxa ATUAL.
--
-- Isso significa que a receita histórica SE MOVE quando o câmbio se move: a
-- mesma venda fechada em julho vale um número hoje e outro amanhã. Uma
-- auditoria anterior mediu 1,82% de variação em um único dia.
--
-- Isso NÃO é defeito desta migration — é propriedade da ORIGEM. A própria
-- planilha exportada do Salesforce sofre do mesmo. Inventar uma taxa datada
-- aqui seria fabricar dado que a fonte não tem, que é exatamente o erro que
-- este projeto passou 20 migrations desfazendo. Fica registrado no COMMENT da
-- view, para quem for ler o número saber o que ele é.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O SEGUNDO CAMPO PERDIDO: Lead.ConvertedOpportunityId
--
-- Hoje o banco só liga lead -> CONTA (`converted_account_id`). Uma conta com 3
-- oportunidades credita as 3 ao mesmo lead — a nota de grão que a 088 deixou
-- registrada em view_lead_360 ("um lead com 3 oportunidades devolve 3 linhas")
-- é sintoma disso.
--
-- `ConvertedOpportunityId` é o vínculo INDIVIDUAL. Cobertura medida na origem
-- em 2026-09-16: 320 de 325 leads convertidos da janela (98,5%) — melhor que
-- `ConvertedAccountId`, que cobre 319. Esta migration cria o DESTINO e o
-- ingere. Trocar o join das views por ele é trabalho separado e deliberado:
-- mudar o grão de view_lead_360 com tela publicada lendo ela é outro assunto.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PROIBIÇÃO EXPLÍCITA: NADA DE FALLBACK SILENCIOSO
--
-- Oportunidade cuja moeda não está em `currency_rate`, ou cujo
-- `currency_iso_code` é nulo, resulta em `amount_brl` NULL. NUNCA em
-- `amount × 1`. Tratar moeda desconhecida como real é fabricar um número —
-- e um número fabricado não se distingue de um número correto na tela.
--
-- E como NULL somado desaparece (sum() ignora NULL), exclusão silenciosa
-- também está proibida (contrato §1.6): as views expõem
-- `conversao_indisponivel_motivo` e `qtd_ganhas_sem_conversao` para que se
-- conte quantas ficaram de fora e POR QUÊ, no mesmo padrão do
-- `contrato_indisponivel_motivo` que a 088 criou.

-- TUDO EM UMA TRANSACAO SO. A migration faz DROP VIEW de view_receita,
-- view_lead_360 e view_pessoa_jornada_desfecho -- as tres estao sendo lidas por
-- uma API no ar. Sem BEGIN/COMMIT, cada comando do psql autocommita e existe
-- uma janela real em que a view simplesmente NAO EXISTE; e, se algum comando no
-- meio falhar, o banco fica com a view derrubada e nada no lugar. Aqui ou entra
-- tudo, ou nao entra nada.
BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A TAXA MORA EM TABELA, INGERIDA DA ORIGEM
-- ═════════════════════════════════════════════════════════════════════════════
-- Jamais um CASE WHEN moeda='USD' THEN 5.101 no meio de uma view. Câmbio muda
-- sozinho; constante escrita no código só é descoberta quando o número já saiu
-- errado na tela, e aí ninguém lembra de onde veio o 5,101.
--
-- O n8n lê CurrencyType INTEIRO a cada execução, sem watermark — são 3 linhas,
-- e filtrar por SystemModstamp congelaria um câmbio antigo.

CREATE TABLE IF NOT EXISTS currency_rate (
  iso_code        text PRIMARY KEY,
  conversion_rate numeric NOT NULL,
  is_corporate    boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true,
  decimal_places  integer,
  source_id       text,
  collected_at    timestamptz NOT NULL,
  ingested_at     timestamptz NOT NULL DEFAULT now(),
  -- Taxa zero ou negativa não é taxa: é divisão por zero esperando acontecer.
  -- O lote FALHA em voz alta em vez de gravar um denominador impossível.
  CONSTRAINT currency_rate_taxa_positiva CHECK (conversion_rate > 0)
);

COMMENT ON TABLE currency_rate IS
  'Salesforce CurrencyType. `conversion_rate` e CORPORATIVA->ESTRANGEIRA: a moeda corporativa (BRL, is_corporate=true) tem taxa 1 e as demais tem taxa != 1. Converter para BRL e DIVIDIR: valor_brl = amount / conversion_rate. Verificado por reconciliacao ao centavo contra o SOQL agregado (ver migration 090). NAO HA TAXA DATADA nesta org (DatedConversionRate = 0 linhas): a taxa e sempre a ATUAL, e a receita historica se move com o cambio. Propriedade da origem, nao desta tabela. Ingerida por fn_run_ingest_batch, nunca hardcoded. Migration 090.';

COMMENT ON COLUMN currency_rate.conversion_rate IS
  'Unidades da moeda estrangeira por 1 unidade da corporativa (BRL). USD=0,19604 significa 0,19604 dolar por real, logo 1 dolar = 1/0,19604 = 5,101 reais. Para converter valores em moeda estrangeira para BRL, DIVIDA por esta taxa.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. OS DOIS CAMPOS PERDIDOS GANHAM DESTINO
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE opportunity ADD COLUMN IF NOT EXISTS currency_iso_code text;

COMMENT ON COLUMN opportunity.currency_iso_code IS
  'Salesforce Opportunity.CurrencyIsoCode. A UNIDADE de `amount`. Sem ela `amount` e um numero sem grandeza e qualquer soma mistura moedas. NULL = registro ingerido antes da migration 090 (a ingestao e incremental por SystemModstamp: so volta a aparecer depois que a watermark foi zerada). Migration 090.';

ALTER TABLE lead ADD COLUMN IF NOT EXISTS converted_opportunity_id text;

COMMENT ON COLUMN lead.converted_opportunity_id IS
  'Salesforce Lead.ConvertedOpportunityId. O vinculo INDIVIDUAL lead->oportunidade, que `converted_account_id` nao da: uma conta com 3 oportunidades credita as 3 ao mesmo lead. Cobertura medida na origem em 2026-09-16: 320 de 325 leads convertidos da janela (98,5%), contra 319 do converted_account_id. Ingerido a partir da migration 090; as views ainda fazem o join por CONTA -- trocar o grao e trabalho separado.';

CREATE INDEX IF NOT EXISTS idx_lead_converted_opportunity_id
  ON lead (converted_opportunity_id) WHERE converted_opportunity_id IS NOT NULL;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A INGESTÃO PASSA A TRAZER OS TRÊS CAMPOS
-- ═════════════════════════════════════════════════════════════════════════════
-- Função reemitida inteira (mesmo procedimento da 081): CurrencyType tratado
-- ANTES do bloco Opportunity, `currency_iso_code` no INSERT e no DO UPDATE de
-- Opportunity, `converted_opportunity_id` no INSERT e no DO UPDATE de Lead.
-- O resto da definição é idêntico ao que estava em produção nesta data.
--
-- O SOQL do n8n (n8n/crm-ingest-salesforce.json) já foi alterado para pedir os
-- três campos. O payload em stg_salesforce é o registro cru do SOQL, então o
-- mapeamento lê `IsoCode`, `ConversionRate`, `CurrencyIsoCode` e
-- `ConvertedOpportunityId` direto do jsonb.

CREATE OR REPLACE FUNCTION public.fn_run_ingest_batch(p_batch_id text)
 RETURNS TABLE(object_type text, rows_source integer, rows_target integer, status text)
 LANGUAGE plpgsql
AS $function$
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
  -- v13 (migration 062)
  v_conv_distintas integer;
  v_conv_presentes integer;
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
    INSERT INTO lead (source_system, source_id, nome, empresa, email, telefone, status, origem_bruta, campanha_linkedin_bruta, converted_account_id, converted_opportunity_id, owner_id, created_at_source, collected_at)
    SELECT
      'salesforce', s.payload->>'Id', s.payload->>'Name', s.payload->>'Company', s.payload->>'Email', s.payload->>'Phone',
      s.payload->>'Status', s.payload->>'LeadSource', s.payload->>'Campanha_LinkedIn__c', s.payload->>'ConvertedAccountId',
      -- migration 090: o vinculo INDIVIDUAL lead->oportunidade. Ate aqui so havia
      -- ConvertedAccountId, e uma conta com 3 oportunidades creditava as 3 ao
      -- mesmo lead. Cobertura medida na origem: 320 de 325 convertidos (98,5%).
      NULLIF(s.payload->>'ConvertedOpportunityId',''),
      o.id, NULLIF(s.payload->>'CreatedDate','')::timestamptz, s.collected_at
    FROM stg_salesforce s
    LEFT JOIN owner o ON o.source_system = 'salesforce' AND o.source_id = s.payload->>'OwnerId'
    WHERE s.batch_id = p_batch_id AND s.object_type = 'Lead'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome = EXCLUDED.nome, empresa = EXCLUDED.empresa, email = EXCLUDED.email, telefone = EXCLUDED.telefone,
      status = EXCLUDED.status, origem_bruta = EXCLUDED.origem_bruta, campanha_linkedin_bruta = EXCLUDED.campanha_linkedin_bruta,
      converted_account_id = EXCLUDED.converted_account_id,
      converted_opportunity_id = EXCLUDED.converted_opportunity_id, owner_id = EXCLUDED.owner_id,
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

  -- ── CurrencyType (Salesforce) — migration 090 ───────────────────────────
  -- ANTES de Opportunity de proposito: a oportunidade so tem valor comparavel
  -- depois que a taxa esta na tabela. Se a ordem fosse invertida, o primeiro
  -- lote de um lote novo converteria contra uma taxa velha.
  --
  -- A taxa e DADO DE ORIGEM, ingerido como qualquer outro objeto. Nunca CASE
  -- com numero escrito no codigo: taxa de cambio muda sozinha, e regra
  -- hardcoded so e descoberta quando o numero ja saiu errado na tela.
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'CurrencyType';
  IF v_rows_source > 0 THEN
    INSERT INTO currency_rate (iso_code, conversion_rate, is_corporate, is_active, decimal_places, source_id, collected_at)
    SELECT
      s.payload->>'IsoCode',
      NULLIF(s.payload->>'ConversionRate','')::numeric,
      COALESCE(NULLIF(s.payload->>'IsCorporate','')::boolean, false),
      COALESCE(NULLIF(s.payload->>'IsActive','')::boolean, true),
      NULLIF(s.payload->>'DecimalPlaces','')::integer,
      s.payload->>'Id',
      s.collected_at
    FROM stg_salesforce s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'CurrencyType'
      AND s.payload->>'IsoCode' IS NOT NULL
    ON CONFLICT (iso_code) DO UPDATE SET
      conversion_rate = EXCLUDED.conversion_rate, is_corporate = EXCLUDED.is_corporate,
      is_active = EXCLUDED.is_active, decimal_places = EXCLUDED.decimal_places,
      source_id = EXCLUDED.source_id, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    PERFORM fn_registrar_ingest('salesforce', 'CurrencyType', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
    object_type := 'CurrencyType'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;

  -- Opportunity (Salesforce)
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'Opportunity';
  IF v_rows_source > 0 THEN
    INSERT INTO opportunity (source_system, source_id, account_id, record_type_name, stage_name, amount, currency_iso_code, mrr, duracao_meses_contrato, owner_id, created_at_source, closed_at_source, collected_at)
    SELECT
      'salesforce', s.payload->>'Id', a.id, s.payload#>>'{RecordType,Name}', s.payload->>'StageName',
      NULLIF(s.payload->>'Amount','')::numeric,
      -- migration 090: a org e MULTI-MOEDA. Sem este campo, `amount` e um numero
      -- sem unidade e a soma mistura dolar com real.
      NULLIF(s.payload->>'CurrencyIsoCode',''),
      NULLIF(s.payload->>'MRR__c','')::numeric,
      round(NULLIF(s.payload->>'Termo_do_Contrato__c','')::numeric)::integer,
      o.id, NULLIF(s.payload->>'CreatedDate','')::timestamptz, NULLIF(s.payload->>'CloseDate','')::timestamptz, s.collected_at
    FROM stg_salesforce s
    LEFT JOIN account a ON a.source_system = 'salesforce' AND a.source_id = s.payload->>'AccountId'
    LEFT JOIN owner o ON o.source_system = 'salesforce' AND o.source_id = s.payload->>'OwnerId'
    WHERE s.batch_id = p_batch_id AND s.object_type = 'Opportunity'
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      account_id = EXCLUDED.account_id, record_type_name = EXCLUDED.record_type_name, stage_name = EXCLUDED.stage_name,
      amount = EXCLUDED.amount, currency_iso_code = EXCLUDED.currency_iso_code,
      mrr = EXCLUDED.mrr, duracao_meses_contrato = EXCLUDED.duracao_meses_contrato, owner_id = EXCLUDED.owner_id,
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
      is_teste, teste_regra, lista_regra, created_at_source, collected_at
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
      fn_lead_lista_regra(CASE WHEN jsonb_typeof(s.payload->'tags') = 'array'
           THEN ARRAY(SELECT jsonb_array_elements_text(s.payload->'tags'))
           ELSE NULL END),
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
      -- lista_regra NAO e monotonica, ao contrario de is_teste: a tag e o dado
      -- da fonte, e se a fonte tirar a tag o lead deixa de ser de lista. Fixar
      -- seria decidir contra o dado.
      lista_regra           = fn_lead_lista_regra(EXCLUDED.tags),
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
  -- v13: `rows_source` conta EVENTOS DISTINTOS do lote, nao linhas de
  -- staging. Ver o cabecalho desta migration: contar linhas de staging fazia
  -- a deduplicacao legitima (145 duplicatas de fonte num lote real) parecer
  -- perda de dado, e a assercao AC-8.1 acusava "sincronizacao parcial
  -- disfarcada de completa" num lote que estava perfeito.
  SELECT count(*) INTO v_rows_source
  FROM (
    SELECT DISTINCT s.payload->>'contact_uuid', s.payload->>'origem_conversao',
                    NULLIF(s.payload->>'occurred_at','')::timestamptz
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'LeadConversion'
  ) d;
  IF v_rows_source > 0 THEN
    v_conv_gravadas := 0;
    v_conv_sem_lead := 0;
    v_conv_status_preenchido := 0;
    v_conv_presentes := 0;
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
      -- v12: duas regras, e ambas sao conservadoras.
      --
      -- 1. PREENCHER LACUNA. Colunas de atribuicao recebem valor novo apenas
      --    quando estao NULL. COALESCE garante que valor ja gravado nunca e
      --    sobrescrito. Nenhuma coluna de identidade, firmografia ou data
      --    entra no SET.
      --
      -- 2. CORRIGIR FALHA AUTODECLARADA. `ilegivel` significa "nos falhamos
      --    ao ler" — nao e um fato sobre o lead, e um registro de defeito
      --    nosso. Quando o coletor melhora e passa a ler, manter o
      --    `ilegivel` seria preservar a memoria de um bug ja corrigido.
      --    Entao `ilegivel` PODE ser substituido; qualquer outro status, nao.
      --
      -- Isto nao afrouxa a dedup: a regra de negocio (mesmo lead, mesma
      -- origem, mesmo instante E o mesmo evento) continua intacta, e nenhum
      -- dado de negocio e reescrito.
      ON CONFLICT (lead_id, origem_conversao, occurred_at) DO UPDATE
        SET atribuicao_status =
              CASE WHEN lead_conversion_event.atribuicao_status IS NULL
                     OR lead_conversion_event.atribuicao_status = 'ilegivel'
                   THEN COALESCE(EXCLUDED.atribuicao_status, lead_conversion_event.atribuicao_status)
                   ELSE lead_conversion_event.atribuicao_status END,
            utm_source   = COALESCE(lead_conversion_event.utm_source,   EXCLUDED.utm_source),
            utm_medium   = COALESCE(lead_conversion_event.utm_medium,   EXCLUDED.utm_medium),
            utm_campaign = COALESCE(lead_conversion_event.utm_campaign, EXCLUDED.utm_campaign),
            utm_term     = COALESCE(lead_conversion_event.utm_term,     EXCLUDED.utm_term),
            midia        = COALESCE(lead_conversion_event.midia,        EXCLUDED.midia)
        WHERE lead_conversion_event.atribuicao_status IS NULL
           OR lead_conversion_event.atribuicao_status = 'ilegivel'
           OR lead_conversion_event.utm_source   IS NULL
           OR lead_conversion_event.utm_medium   IS NULL
           OR lead_conversion_event.utm_campaign IS NULL
           OR lead_conversion_event.utm_term     IS NULL
           OR lead_conversion_event.midia        IS NULL;

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

    -- v13: `rows_target` conta os eventos do lote PRESENTES no destino
    -- depois desta execucao — nao os recem-inseridos.
    --
    -- Sem isso, o invariante AC-8.1 (ok => source == target) seria
    -- incompativel com idempotencia: numa reexecucao correta nada e inserido,
    -- `rows_target` daria 0, e o lote perfeito seria acusado de perda total.
    -- "Quantos eventos do lote estao no destino" e a pergunta de
    -- reconciliacao; "quantos entraram agora" e uma metrica de operacao, e
    -- continua reportada separado.
    SELECT count(*) INTO v_conv_presentes
    FROM (
      SELECT DISTINCT s.payload->>'contact_uuid' AS uuid,
                      s.payload->>'origem_conversao' AS origem,
                      NULLIF(s.payload->>'occurred_at','')::timestamptz AS quando
      FROM stg_rdstation s
      WHERE s.batch_id = p_batch_id AND s.object_type = 'LeadConversion'
    ) d
    WHERE EXISTS (
      SELECT 1 FROM lead_conversion_event e
      WHERE e.lead_id = fn_resolve_lead_por_rd_uuid(d.uuid)
        AND e.origem_conversao = d.origem
        AND e.occurred_at = d.quando
    );

    PERFORM fn_registrar_ingest('rd_station', 'LeadConversion', v_rows_source, v_conv_presentes,
      CASE WHEN v_conv_sem_lead = 0 THEN 'ok' ELSE 'partial' END,
      CASE WHEN v_conv_sem_lead > 0
        THEN format('%s evento(s) de conversão sem lead resolvido — o contato não veio no mesmo lote de RDLead nem existe vínculo em identity_edge. Eventos NÃO foram descartados do staging: reprocessar o lote depois de ingerir os contatos.', v_conv_sem_lead)
        ELSE NULL END);
    object_type := 'LeadConversion'; rows_source := v_rows_source; rows_target := v_conv_presentes;
    status := CASE WHEN v_conv_sem_lead = 0 THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;

    -- Reportado separado de propósito: preencher status em evento antigo NAO
    -- e ingestao de dado novo, e somar os dois esconderia que a ingestao foi
    -- idempotente.
    -- Metrica de operacao, separada da de reconciliacao.
    IF v_conv_gravadas > 0 THEN
      object_type := 'LeadConversion_Novos'; rows_source := v_conv_gravadas;
      rows_target := v_conv_gravadas; status := 'ok';
      RETURN NEXT;
    END IF;

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
$function$;



-- ═════════════════════════════════════════════════════════════════════════════
-- 4. O VALOR CONVERTIDO APARECE — E O QUE NÃO CONVERTEU TAMBÉM
-- ═════════════════════════════════════════════════════════════════════════════
-- CREATE OR REPLACE VIEW só acrescenta coluna NO FIM e não muda tipo; aqui a
-- mudança é grande o bastante para não valer a aposta. DROP + CREATE em cadeia,
-- com o procedimento que a 088 e a 080 registraram: conferir pg_depend antes
-- (feito: o único dependente de view_receita é view_lead_360 — view_jornada_
-- unificada e view_marketing_rd_sf leem `opportunity` direto, não esta view) e
-- REEMITIR OS GRANTS depois. Esquecer o grant foi o modo de falha real da 049,
-- e aconteceu duas vezes nesta epic.
--
-- `amount` e `mrr` CRUS ficam, com os nomes dos campos de origem, pelo mesmo
-- motivo da 088: eles são o DADO, em moeda local. A conclusão (`amount_brl`) é
-- derivada e pode mudar quando o câmbio mudar; o dado, não.
--
-- SEM ARREDONDAR de propósito: arredondar linha a linha e depois somar acumula
-- centavo de deriva ao longo de 992 linhas, e esta view existe justamente para
-- que a soma feche com a origem. Formatação é trabalho de quem exibe.

DROP VIEW IF EXISTS view_lead_360;
DROP VIEW IF EXISTS view_receita;

CREATE VIEW view_receita AS
SELECT
  o.id                       AS opportunity_id,
  o.source_system,
  o.source_id,
  o.stage_name,
  o.amount                   AS amount,   -- Opportunity.Amount cru, EM MOEDA LOCAL. O DADO.
  o.mrr                      AS mrr,      -- Opportunity.MRR__c cru, idem (migration 073). O DADO.
  o.duracao_meses_contrato,               -- Projetada, mas NÃO entra no cálculo (088).
  -- A DECISÃO DA 088: Amount já é o valor total. Não se multiplica por prazo.
  CASE WHEN o.stage_name = 'Ganho' THEN o.amount END AS contrato_valor,
  CASE
    WHEN o.stage_name IS DISTINCT FROM 'Ganho'
      THEN 'Oportunidade ainda não está Ganha — valor de contrato não se aplica'
    WHEN o.amount IS NULL
      THEN 'Ganha, mas Amount vazio na origem — valor de contrato indisponível, nunca um número presumido'
  END AS contrato_indisponivel_motivo,
  -- ── migration 090: a unidade, a taxa, e o valor comparável ────────────────
  o.currency_iso_code        AS moeda,
  cr.conversion_rate         AS taxa_conversao,
  -- DIVISÃO, não multiplicação: a taxa é corporativa->estrangeira e BRL é a
  -- corporativa. Ver a reconciliação ao centavo no cabeçalho desta migration.
  CASE
    WHEN o.amount IS NOT NULL AND cr.conversion_rate IS NOT NULL
      THEN o.amount / cr.conversion_rate
  END AS amount_brl,
  CASE
    WHEN o.stage_name = 'Ganho' AND o.amount IS NOT NULL AND cr.conversion_rate IS NOT NULL
      THEN o.amount / cr.conversion_rate
  END AS contrato_valor_brl,
  -- POR QUE amount_brl ficou NULL. Sem esta coluna, "não converteu" seria
  -- indistinguível de "não existe", e a exclusão viraria silenciosa.
  -- Precedência declarada: Amount ausente vem primeiro porque sem valor não há
  -- conversão possível, seja qual for a moeda.
  CASE
    WHEN o.amount IS NULL
      THEN 'Amount vazio na origem — não há valor para converter'
    WHEN o.currency_iso_code IS NULL
      THEN 'Moeda ausente no registro — ingerido antes da migration 090 e ainda não relido (a ingestão é incremental por SystemModstamp)'
    WHEN cr.iso_code IS NULL
      THEN format('Moeda "%s" não está em currency_rate — taxa desconhecida, e valor NUNCA é assumido como real', o.currency_iso_code)
  END AS conversao_indisponivel_motivo
FROM opportunity o
-- LEFT, e não INNER: moeda desconhecida tem de virar NULL visível, não sumir
-- da view. Sumir é a exclusão silenciosa que o contrato §1.6 proíbe.
LEFT JOIN currency_rate cr ON cr.iso_code = o.currency_iso_code;

-- view_lead_360 recriada só porque depende de view_receita, mais as quatro
-- colunas novas. A nota de grão da 080/088 continua valendo e continua NÃO
-- corrigida aqui: o nome diz "360 do lead" e o grão é OPORTUNIDADE (LEFT JOIN
-- opportunity). Um lead com 3 oportunidades devolve 3 linhas. O campo que
-- permite corrigir isso (`lead.converted_opportunity_id`) passa a existir nesta
-- migration, mas trocar o join é trabalho separado e deliberado.

CREATE VIEW view_lead_360 AS
SELECT l.id AS lead_id,
    l.source_system,
    l.source_id,
    l.nome,
    l.empresa,
    l.email,
    l.telefone,
    l.status AS estagio_funil,
    l.converted_account_id,
    l.converted_opportunity_id,
    loc.segmento,
    loc.categoria,
    loc.detalhe,
    loc.sinal_id,
    loc.valor_bruto,
    loc.razao,
    a.id AS account_id,
    a.nome AS account_nome,
    o.id AS opportunity_id,
    o.stage_name,
    f.fase AS fase_comercial,
    o.record_type_name,
    vr.amount,
    vr.mrr,
    vr.contrato_valor,
    vr.contrato_indisponivel_motivo,
    vr.moeda,
    vr.taxa_conversao,
    vr.amount_brl,
    vr.contrato_valor_brl,
    vr.conversao_indisponivel_motivo
   FROM lead l
     LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
     LEFT JOIN account a ON a.source_system = l.source_system AND a.source_id = l.converted_account_id
     LEFT JOIN opportunity o ON o.account_id = a.id
     LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
     LEFT JOIN view_receita vr ON vr.opportunity_id = o.id;

-- Grants refeitos — DROP leva os privilégios junto.
GRANT SELECT ON view_receita  TO crm_ingest;
GRANT SELECT ON view_lead_360 TO crm_ingest;
GRANT SELECT ON currency_rate TO crm_ingest;

COMMENT ON VIEW view_receita IS
  'Grao: UMA LINHA POR OPORTUNIDADE. `amount` e `mrr` sao os campos de origem CRUS, EM MOEDA LOCAL -- a org e multi-moeda (BRL/USD/MXN) e somar `amount` direto mistura grandezas. `amount_brl` e `contrato_valor_brl` sao o valor em real: amount / conversion_rate, taxa lida de currency_rate (tabela ingerida do Salesforce, nunca constante no codigo). Moeda desconhecida ou ausente resulta em NULL, NUNCA em amount x 1, e o porque fica em `conversao_indisponivel_motivo`. NAO ARREDONDA: formatacao e de quem exibe. ATENCAO -- NAO HA TAXA DATADA nesta org (DatedConversionRate = 0 linhas): a conversao usa sempre a taxa ATUAL, entao a receita historica SE MOVE quando o cambio se move (1,82% medido em um unico dia). A planilha exportada do Salesforce sofre do mesmo; e propriedade da origem. `contrato_valor` = Amount quando Ganha, sem multiplicar por prazo (decisao de 2026-09-15, migration 088). Ver migrations 080, 088 e 090.';

COMMENT ON VIEW view_lead_360 IS
  'Grao: OPORTUNIDADE, apesar do nome (um lead com 3 oportunidades devolve 3 linhas) -- o join e por CONTA, via converted_account_id. `converted_opportunity_id` passa a ser exposto na migration 090 e e o vinculo individual que permitiria corrigir o grao; trocar o join e trabalho separado. Valores em real vem de view_receita (amount_brl, contrato_valor_brl). Ver migrations 080, 088 e 090.';

-- ─────────────────────────────────────────────────────────────────────────────
-- view_pessoa_jornada_desfecho: a soma por pessoa também misturava moedas.
--
-- `amount_ganho` (a soma crua) FICA, e de propósito: é o campo de origem
-- somado, e serve de contraprova. Ao lado dele entram `amount_ganho_brl` e
-- `contrato_valor_brl`.
--
-- O PROBLEMA DO sum() COM NULL: sum() ignora NULL, então uma oportunidade que
-- não converteu simplesmente sumiria da soma sem deixar rastro — a exclusão
-- silenciosa que o contrato §1.6 proíbe. Por isso entram também
-- `qtd_ganhas_sem_conversao`, `conversao_indisponivel_motivo` e `moedas_ganho`:
-- dá para contar quantas ficaram fora, saber por quê, e ver que moedas a soma
-- crua estava misturando.
--
-- A conversão vem de view_receita, não reimplementada aqui. Duas
-- implementações da mesma regra divergem — foi assim que o ramo do webhook
-- divergiu do ramo do pull por 33 migrations.
--
-- Nenhuma view depende desta (conferido em pg_depend). `fn_search_pessoas`
-- (084/087/089) referencia esta view mas projeta colunas NOMINALMENTE, então
-- colunas novas não a quebram — e ela continua devolvendo `amount_ganho` CRU.
-- Isso está declarado no relatório desta migration como item em aberto:
-- mudar a assinatura da função muda o que a API entrega à tela, e a tela está
-- fora do escopo desta migration.

DROP VIEW IF EXISTS view_pessoa_jornada_desfecho;
CREATE VIEW view_pessoa_jornada_desfecho AS
WITH
-- ── ESQUERDA: o array de conversões do RD ────────────────────────────────────
conv AS (
  SELECT
    p.pessoa_chave,
    count(*)                                                    AS qtd_conversoes,
    min(e.occurred_at)                                          AS primeira_conversao_em,
    max(e.occurred_at)                                          AS ultima_conversao_em,
    array_agg(DISTINCT e.origem_conversao)
      FILTER (WHERE e.origem_conversao IS NOT NULL)             AS origens_conversao,
    -- Atribuição de mídia paga. O valor do ÚLTIMO evento que trouxe cada sinal,
    -- não um min() arbitrário -- a última conversão é a que atribui.
    (array_agg(e.utm_campaign ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_campaign IS NOT NULL))[1]            AS utm_campaign,
    (array_agg(e.midia ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.midia IS NOT NULL))[1]                   AS plataforma,
    (array_agg(e.utm_id ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_id IS NOT NULL))[1]                  AS id_anuncio,
    (array_agg(e.utm_content ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_content IS NOT NULL))[1]             AS criativo,
    (array_agg(e.utm_term ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_term IS NOT NULL))[1]                AS publico,
    count(*) FILTER (WHERE e.utm_campaign IS NOT NULL)          AS qtd_conversoes_pagas,
    (array_agg(e.cargo ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.cargo IS NOT NULL))[1]                   AS cargo,
    (array_agg(e.tamanho_empresa ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.tamanho_empresa IS NOT NULL))[1]         AS tamanho_empresa
  FROM view_pessoa p
  JOIN lead_conversion_event e ON e.lead_id = p.rd_lead_id
  GROUP BY p.pessoa_chave
),
-- ── DIREITA: contas da pessoa. TODAS, sem colapsar ───────────────────────────
contas AS (
  SELECT DISTINCT p.pessoa_chave, a.id AS account_id, a.nome AS conta_nome
  FROM view_pessoa p
  JOIN lead l  ON l.id = p.sf_lead_id
  JOIN account a ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
),
-- ── DIREITA: o desfecho comercial, agregado ──────────────────────────────────
desfecho AS (
  SELECT
    ct.pessoa_chave,
    count(DISTINCT ct.account_id)                                     AS qtd_contas,
    count(DISTINCT o.id)                                              AS qtd_oportunidades,
    bool_or(f.fase = 'reuniao')                                       AS teve_reuniao,
    bool_or(f.fase = 'negociacao')                                    AS chegou_a_negociar,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'ganho')              AS qtd_ganhas,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'perdido')            AS qtd_perdidas,
    count(DISTINCT o.id) FILTER (WHERE f.fase IS NULL)                AS qtd_estagio_sem_fase,
    -- Desempate explicito: ganho vence perdido (migration 085).
    (array_agg(f.fase ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS fase_mais_avancada,
    max(f.ordem)                                                      AS fase_ordem,
    (array_agg(o.stage_name ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS estagio_mais_avancado,
    max(o.record_type_name)                                           AS record_type,
    max(o.closed_at_source)                                           AS ultima_movimentacao_em,
    -- CRU, em moeda local e possivelmente MISTURADA -- fica de propósito, como
    -- campo de origem somado e como contraprova do número convertido.
    sum(o.amount) FILTER (WHERE f.fase = 'ganho')                     AS amount_ganho,
    sum(o.mrr)    FILTER (WHERE f.fase = 'ganho')                     AS mrr_ganho,
    -- Amount JÁ É o total da oportunidade (migration 088). Sem prazo no meio.
    sum(o.amount) FILTER (WHERE f.fase = 'ganho')                     AS contrato_valor,
    -- ── migration 090: a mesma soma, em uma unidade só ────────────────────
    sum(vr.amount_brl) FILTER (WHERE f.fase = 'ganho')                AS amount_ganho_brl,
    sum(vr.amount_brl) FILTER (WHERE f.fase = 'ganho')                AS contrato_valor_brl,
    -- sum() ignora NULL, então uma ganha que não converteu sumiria da soma sem
    -- deixar rastro. Estas três colunas são o rastro: quantas, por quê, e que
    -- moedas a soma CRUA estava misturando.
    count(*) FILTER (WHERE f.fase = 'ganho'
                       AND o.amount IS NOT NULL
                       AND vr.amount_brl IS NULL)                     AS qtd_ganhas_sem_conversao,
    string_agg(DISTINCT vr.conversao_indisponivel_motivo, ' · ')
      FILTER (WHERE f.fase = 'ganho'
                AND o.amount IS NOT NULL
                AND vr.amount_brl IS NULL)                            AS conversao_indisponivel_motivo,
    array_agg(DISTINCT o.currency_iso_code)
      FILTER (WHERE f.fase = 'ganho'
                AND o.currency_iso_code IS NOT NULL)                  AS moedas_ganho,
    string_agg(DISTINCT ct.conta_nome, ' · ')                         AS conta_nome
  FROM contas ct
  JOIN opportunity o ON o.account_id = ct.account_id
  LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  -- A conversão vem de view_receita (migration 090), NÃO reimplementada aqui:
  -- duas implementações da mesma regra divergem, e foi assim que o ramo do
  -- webhook divergiu do ramo do pull por 33 migrations.
  LEFT JOIN view_receita vr ON vr.opportunity_id = o.id
  GROUP BY ct.pessoa_chave
),
-- Classificação de origem: a do registro do RD quando existe, senão a do SF.
-- O RD tem o sinal de conversão; o SF tem o LeadSource. Regra declarada.
classif AS (
  SELECT
    p.pessoa_chave,
    coalesce(crd.segmento,  csf.segmento)  AS segmento,
    coalesce(crd.categoria, csf.categoria) AS categoria,
    coalesce(crd.detalhe,   csf.detalhe)   AS detalhe,
    CASE WHEN crd.segmento IS NOT NULL THEN 'rd_station' ELSE 'salesforce' END AS classificado_por
  FROM view_pessoa p
  LEFT JOIN lead_origin_classification crd ON crd.lead_id = p.rd_lead_id AND crd.valid_to IS NULL
  LEFT JOIN lead_origin_classification csf ON csf.lead_id = p.sf_lead_id AND csf.valid_to IS NULL
)
SELECT
  p.pessoa_chave,
  p.nome,
  p.empresa,
  p.chave_origem,
  p.fontes,
  p.rd_lead_id,
  p.sf_lead_id,
  p.primeiro_registro_em,
  -- ── atribuição ──
  cl.segmento,
  cl.categoria,
  cl.detalhe,
  cl.classificado_por,
  lrd.lista_regra,
  (lrd.lista_regra IS NOT NULL)                       AS de_lista_importada,
  -- ── esquerda: a jornada ──
  coalesce(cv.qtd_conversoes, 0)                      AS qtd_conversoes,
  cv.origens_conversao,
  cv.primeira_conversao_em,
  cv.ultima_conversao_em,
  cv.utm_campaign,
  cv.plataforma,
  cv.id_anuncio,
  cv.criativo,
  cv.publico,
  coalesce(cv.qtd_conversoes_pagas, 0)                AS qtd_conversoes_pagas,
  coalesce(cv.cargo, lrd.cargo, lsf.cargo)            AS cargo,
  cv.tamanho_empresa,
  -- ── direita: o desfecho ──
  (p.sf_lead_id IS NOT NULL)                          AS existe_no_salesforce,
  lsf.status                                          AS status_no_salesforce,
  coalesce(d.qtd_contas, 0)                           AS qtd_contas,
  d.conta_nome,
  coalesce(d.qtd_oportunidades, 0)                    AS qtd_oportunidades,
  coalesce(d.teve_reuniao, false)                     AS teve_reuniao,
  coalesce(d.chegou_a_negociar, false)                AS chegou_a_negociar,
  coalesce(d.qtd_ganhas, 0)                           AS qtd_ganhas,
  coalesce(d.qtd_perdidas, 0)                         AS qtd_perdidas,
  coalesce(d.qtd_estagio_sem_fase, 0)                 AS qtd_estagio_sem_fase,
  d.fase_mais_avancada,
  d.fase_ordem,
  d.estagio_mais_avancado,
  d.record_type,
  d.ultima_movimentacao_em,
  d.amount_ganho,
  d.mrr_ganho,
  d.contrato_valor,
  -- ── migration 090 ──
  d.amount_ganho_brl,
  d.contrato_valor_brl,
  coalesce(d.qtd_ganhas_sem_conversao, 0)             AS qtd_ganhas_sem_conversao,
  d.conversao_indisponivel_motivo,
  d.moedas_ganho,
  -- ── dimensoes de filtro (ver JOIN com view_lead_perfil abaixo) ──
  coalesce(prd.trimestre,      psf.trimestre)      AS trimestre,
  coalesce(prd.cargo_grupo,    psf.cargo_grupo)    AS cargo_grupo,
  coalesce(prd.atendido_por,   psf.atendido_por)   AS atendido_por,
  coalesce(prd.estagio_funil,  psf.estagio_funil)  AS estagio_funil,
  coalesce(prd.tags,           psf.tags)           AS tags,
  coalesce(prd.fonte_dados,    psf.fonte_dados)    AS fonte_dados,
  -- O id que a FICHA usa para abrir (/api/leads/{id} busca por source_id, nao
  -- pelo id interno). Preferencia pelo registro do RD, que tem a jornada de
  -- conversao; Salesforce como reserva. Sem esta coluna a lista passaria o id
  -- interno e a ficha abriria vazia -- defeito que so aparece no clique.
  coalesce(lrd.source_id, lsf.source_id)              AS source_id_ficha
FROM view_pessoa p
LEFT JOIN lead lrd      ON lrd.id = p.rd_lead_id
LEFT JOIN lead lsf      ON lsf.id = p.sf_lead_id
-- Dimensoes que a barra de filtros da aba Leads ja usa. Vem de view_lead_perfil
-- para NAO reimplementar as regras de normalizacao (cargo_grupo, tamanho,
-- trimestre) numa segunda view -- duas implementacoes da mesma regra divergem,
-- e foi assim que o ramo do webhook divergiu do ramo do pull por 33 migrations.
-- Preferencia pelo registro do RD (tem a firmografia); Salesforce como reserva.
LEFT JOIN view_lead_perfil prd ON prd.lead_id = p.rd_lead_id
LEFT JOIN view_lead_perfil psf ON psf.lead_id = p.sf_lead_id
LEFT JOIN conv cv       ON cv.pessoa_chave = p.pessoa_chave
LEFT JOIN desfecho d    ON d.pessoa_chave  = p.pessoa_chave
LEFT JOIN classif cl    ON cl.pessoa_chave = p.pessoa_chave;

COMMENT ON VIEW view_pessoa_jornada_desfecho IS
  'A PERGUNTA CENTRAL DO EPICO. GRAO: UMA LINHA POR PESSOA. Esquerda = array de conversoes do RD (origens_conversao) + atribuicao de midia paga (id_anuncio, criativo, publico). Direita = desfecho comercial do Salesforce em colunas (teve_reuniao, chegou_a_negociar, fase_mais_avancada, ganhas, perdidas), traduzido por opportunity_stage_fase. NAO multiplica por oportunidade. RECEITA: `amount_ganho` e `contrato_valor` sao a soma CRUA, EM MOEDA LOCAL e possivelmente MISTURADA (a org e multi-moeda: BRL/USD/MXN) -- ficam como campo de origem e contraprova. O numero comparavel e `amount_ganho_brl` / `contrato_valor_brl`, convertido via currency_rate (migration 090). Oportunidade ganha que nao converteu NAO entra na soma e NAO some: conte em `qtd_ganhas_sem_conversao`, leia o motivo em `conversao_indisponivel_motivo`, e veja em `moedas_ganho` que moedas a soma crua misturava. Amount e o valor total da oportunidade, sem prazo (decisao de 2026-09-15, migration 088). ATENCAO: nao ha taxa datada na origem -- a conversao usa a taxa ATUAL e a receita historica se move com o cambio. Ver migrations 083, 088 e 090.';

GRANT SELECT ON view_pessoa_jornada_desfecho TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- ROLLBACK (forward-only: isto é documentação, não script a rodar)
-- ═════════════════════════════════════════════════════════════════════════════
-- Esta migration é aditiva em tabela e coluna. Desfazer, se for preciso:
--   1. Reaplicar db/migrations/088_amount_e_o_valor_total.sql a partir do
--      `DROP VIEW IF EXISTS view_lead_360;` — ela recria view_receita,
--      view_lead_360 e view_pessoa_jornada_desfecho sem as colunas novas, e
--      reemite os grants.
--   2. Reaplicar a definição de fn_run_ingest_batch da migration 081.
--   3. As colunas `opportunity.currency_iso_code`,
--      `lead.converted_opportunity_id` e a tabela `currency_rate` podem FICAR:
--      são dado, não regra, e removê-las custaria outra releitura completa do
--      Salesforce para recuperá-las.

COMMIT;
