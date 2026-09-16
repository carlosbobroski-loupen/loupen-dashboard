-- db/migrations/100_origem_propria_da_oportunidade.sql
--
-- A OPORTUNIDADE SEMPRE SOUBE DE ONDE VEIO. NÓS É QUE NÃO PERGUNTÁVAMOS.
--
-- A migration 097 entregou a camada da aba Oportunidades e relatou um teto
-- duro: só 520 das 8.073 oportunidades (6,4%) tinham lead identificável, então
-- o corte Marketing vs Comercial descrevia 6,4% da base e 93,6% caíam num balde
-- `SemLeadIdentificado`. A causa medida era a ausência de `LeadSource` no
-- payload ingerido de `Opportunity`.
--
-- O campo existe na origem e está preenchido. Medido na org em 2026-09-16:
--
--   SELECT COUNT(Id), COUNT(LeadSource) FROM Opportunity
--    WHERE SystemModstamp >= 2025-09-14T00:00:00Z
--   → 8.073 registros · 8.071 com LeadSource (99,98%) · 2 nulos
--
-- O SOQL do n8n já foi alterado (n8n/crm-ingest-salesforce.json e workflow ao
-- vivo). Esta migration abre o destino, mapeia o campo na ingestão, consome o
-- reset de watermark e reescreve a regra de atribuição da aba.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🔴 O CROSSWALK NÃO CONHECE 36 DOS 110 VALORES. MEDIDO ANTES DE ESCREVER.
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A migration 075 existe porque `leadsource_crosswalk` tinha sido construído
-- por AMOSTRA e desconhecia 50 dos 94 valores que a carga real trouxe. A mesma
-- armadilha estava montada aqui, e desta vez ela foi medida ANTES:
--
--   SELECT LeadSource, COUNT(Id) FROM Opportunity
--    WHERE SystemModstamp >= 2025-09-14T00:00:00Z GROUP BY LeadSource
--
--   valores distintos ............................  110 (+ NULL, 2 registros)
--   já no crosswalk ..............................   74  (67,3%)
--   DESCONHECIDOS ................................   36  (32,7%)
--   registros cobertos pelo crosswalk ............ 6.548 de 8.071 (81,13%)
--   registros em valor desconhecido .............. 1.523 (18,87%)
--
-- Os desconhecidos de maior volume, na ordem:
--
--   GoTo ............................... 898    Inbound ................. 20
--   Expansão ........................... 110    Evento .................. 14
--   Upgrade / Add-on em Renovação ......  94    WhatsApp ................ 13
--   Conta Ativa LMI ....................  89    Gerência 2.0 ............ 13
--   Loupen .............................  53    Base Freshworks .......... 7
--   Renovação ..........................  44    Eventos Loupen LATAM ..... 7
--   Prospecção ativa ...................  37    Cross Sale ............... 6
--   Solicitação direta do cliente ......  32    Email .................... 6
--   Indicação de colaborador ...........  22    (+ 20 valores com ≤ 6)
--
-- 🚫 NENHUM DELES É CLASSIFICADO AQUI POR PALPITE. `Expansão`, `Renovação`,
-- `Upgrade / Add-on em Renovação` e `Conta Ativa LMI` claramente falam de base
-- instalada, e `GoTo` é o nome de um produto/parceiro — mas "claramente" foi
-- exatamente o raciocínio que mapeou `Pending Sale` como venda fechada na 079 e
-- teria inventado 14 vendas (derrubado pela 092). Classificar 1.523
-- oportunidades por intuição num CASE dentro de uma view é reproduzir, com
-- outro nome, o "100% atribuído a marketing" que a aba antiga exibia.
--
-- A regra desta migration: valor que o crosswalk não conhece vira
-- `NaoClassificado`, categoria DECLARADA, visível na tela e listada em
-- `view_leadsource_nao_classificado` para que alguém decida REGRA POR REGRA,
-- na TABELA, com data e fonte de decisão — que é o contrato de
-- `leadsource_crosswalk` desde a 075. `NaoClassificado` nunca cai em
-- "Comercial", e também não cai em `NaoAtribuido`: este último é uma decisão
-- tomada ("base importada não se atribui a ninguém"), enquanto
-- `NaoClassificado` é a ausência de decisão. Colapsar os dois apagaria a
-- diferença entre "resolvemos que não" e "ninguém olhou".
--
-- `Otros` e `Outros` são VALORES DISTINTOS na origem (80 e 409 registros) e
-- continuam distintos aqui. O crosswalk conhece os dois separadamente. Se
-- algum dia tiverem de virar a mesma coisa, que seja por duas linhas na tabela
-- apontando para o mesmo segmento — nunca por um `lower(unaccent(...))` numa
-- view, que unificaria também o que ninguém pediu.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- A REGRA DE ATRIBUIÇÃO PASSA A TER TRÊS FORÇAS, NESTA ORDEM
-- ═════════════════════════════════════════════════════════════════════════════
--
--   (a) lead vinculado INDIVIDUALMENTE (lead.converted_opportunity_id)
--   (b) lead vinculado POR CONTA       (lead.converted_account_id)
--   (c) LeadSource da PRÓPRIA oportunidade, via leadsource_crosswalk
--
-- (a) e (b) vêm primeiro porque descrevem a jornada REAL daquela pessoa — o
-- RD Station sabe por qual conversão ela entrou. (c) descreve o que o vendedor
-- digitou no CRM. Quando os dois existem, o primeiro ganha; quando só o
-- segundo existe, ele é melhor do que nada, e `lead_vinculo_regra` diz na cara
-- qual dos três classificou cada linha. É essa coluna que impede a fusão
-- silenciosa: sem ela, "Marketing" pela jornada e "Marketing" porque alguém
-- escolheu na picklist viram o mesmo número sem aviso.
--
-- `lead_vinculo_regra` ganha SEIS valores, e a partição continua TOTAL:
--   oportunidade · conta · leadsource · leadsource_desconhecido ·
--   lead_sem_classificacao · sem_origem
--
-- O valor `sem_lead` da 097 VIRA `sem_origem` e deixa de significar "não tem
-- lead" para significar "não tem lead NEM LeadSource". Mantê-lo com o nome
-- antigo seria mentir: 99,98% das linhas passam a ter origem. Da mesma forma
-- `segmento_aba = 'SemLeadIdentificado'` vira `'SemOrigem'`. A aba ainda não
-- foi montada sobre a 097, então este é o momento barato de acertar o nome.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- SOBRE A WATERMARK: O RESET É DADO E CONSUMIDO, NÃO DEIXADO NO PISO
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A ingestão é incremental por `SystemModstamp`. Abrir a coluna não traz dado
-- nenhum: os 8.073 registros já estão gravados e não serão relidos enquanto a
-- watermark estiver em `now()`. O reset abaixo devolve a watermark ao piso de
-- 12 meses (2025-09-14), e a releitura é feita LOGO EM SEGUIDA reproduzindo o
-- n8n — mesma SOQL, mesma paginação, mesma guarda de truncamento, mesmo
-- staging, mesma chamada de `fn_run_ingest_batch`, que por sua vez reposiciona
-- a watermark via `fn_registrar_ingest`. Deixar o piso gravado faria a próxima
-- execução horária do n8n reler 12 meses sem que ninguém tivesse pedido.
--
-- O UPDATE é condicionado a `NOT EXISTS (... lead_source IS NOT NULL)`: depois
-- que a releitura acontece, reaplicar este arquivo é no-op. Um reset que se
-- repete a cada `psql -f` é uma armadilha para quem for reler o histórico.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- `fn_run_ingest_batch` PARTIU DO CORPO VIVO, E O DIFF É ADIÇÃO PURA
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Uma migration desta sessão reverteu outra por reemitir esta função a partir
-- de um ARQUIVO antigo em vez do corpo em produção. Aqui o corpo abaixo saiu de
-- `pg_get_functiondef('public.fn_run_ingest_batch'::regproc)` lido em
-- 2026-09-16, com exatamente três adições, conferidas por diff:
--
--   + `lead_source` na lista de colunas do INSERT
--   + `NULLIF(s.payload->>'LeadSource','')` na projeção, na mesma posição
--   + `lead_source = EXCLUDED.lead_source` no DO UPDATE
--
-- Nenhuma linha removida, nenhum bloco de outro objeto tocado. 915 linhas ->
-- 921 linhas.
--
-- 🔴 E ESTE ARQUIVO JÁ COMETEU O ERRO QUE DESCREVE. FICA REGISTRADO.
--
-- A primeira versão desta migration partiu de um `pg_get_functiondef` lido às
-- 13:24 UTC. As migrations 099 (13:20) e 101 (13:29), de outro agente, tocam a
-- MESMA função. O dump pegou a 099 pela metade e não pegou a 101, e ao aplicar
-- esta migration às ~13:35 o `CREATE OR REPLACE` levou embora o bloco de
-- enriquecimento do webhook do RD que a 101 acabara de repor — sem erro e sem
-- aviso, exatamente o modo de falha que a 090 cometeu e que a 099 e a 101
-- existem para desfazer.
--
-- Detectado por token, não por sorte: `custom_fields` (o marcador que a 101
-- registra como decisivo, porque `last_conversion` dá falso positivo — ele
-- aparece 9 vezes já na base da 073) estava em ZERO no corpo vivo depois da
-- aplicação. Reparado partindo do corpo da 101 (915 linhas, custom_fields=14,
-- identificador_rd=5) e reaplicando as MESMAS três adições. Resultado
-- conferido por token: custom_fields=14, identificador_rd=5, last_conversion=42,
-- `Campanha de Origem`=2, lead_source presente.
--
-- LIÇÃO, para quem vier depois: "parta do corpo vivo" não basta quando há outro
-- agente escrevendo na mesma função. Releia o corpo IMEDIATAMENTE antes de
-- aplicar, e confira os tokens das migrations vizinhas DEPOIS de aplicar.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE ESTA MIGRATION NÃO TOCA
-- ═════════════════════════════════════════════════════════════════════════════
-- `currency_rate`, `opportunity_stage`, `opportunity_stage_fase`,
-- `leadsource_crosswalk` (nenhuma regra nova é inventada aqui),
-- `view_receita`, `view_pessoa_jornada_desfecho`, `view_lead_360`,
-- permissões de role. Nenhuma linha de dado é apagada.
--
-- `fn_search_oportunidades` precisa de DROP (o tipo de retorno ganha colunas).
-- DROP descarta `plan_cache_mode` E o GRANT — os dois são reemitidos logo
-- abaixo, de propósito e não por idempotência. Esquecer o grant foi o modo de
-- falha real da 049, e aconteceu duas vezes nesta epic.

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. O DESTINO DO CAMPO
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE opportunity ADD COLUMN IF NOT EXISTS lead_source text;

COMMENT ON COLUMN opportunity.lead_source IS
  'Salesforce Opportunity.LeadSource. A origem declarada da PRÓPRIA oportunidade, independente de ter havido conversão de Lead. Cobertura medida na origem em 2026-09-16: 8.071 de 8.073 (99,98%). É o que levou a atribuição Marketing x Comercial de 6,4% para ~81% da base — 93,6% das oportunidades desta org nascem direto, sem Lead convertido. Valor CRU, exatamente como a origem grava: `Otros` e `Outros` são valores diferentes e continuam diferentes. A tradução para segmento mora em leadsource_crosswalk, nunca num CASE de view. NULL = registro ingerido antes da migration 100 e ainda não relido, ou LeadSource vazio na origem (2 casos). Migration 100.';

CREATE INDEX IF NOT EXISTS idx_opportunity_lead_source
  ON opportunity (lead_source) WHERE lead_source IS NOT NULL;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A INGESTÃO PASSA A TRAZER O CAMPO — CORPO VIVO + 3 ADIÇÕES
-- ═════════════════════════════════════════════════════════════════════════════

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
    INSERT INTO lead (source_system, source_id, nome, empresa, email, telefone, status, origem_bruta, campanha_linkedin_bruta, identificador_rd, converted_account_id, converted_opportunity_id, owner_id, created_at_source, collected_at)
    SELECT
      'salesforce', s.payload->>'Id', s.payload->>'Name', s.payload->>'Company', s.payload->>'Email', s.payload->>'Phone',
      s.payload->>'Status', s.payload->>'LeadSource', s.payload->>'Campanha_LinkedIn__c', NULLIF(s.payload->>'Identificador_RD__c',''), s.payload->>'ConvertedAccountId',
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
      -- identificador_rd so avanca: NULL da fonte nao apaga o que ja foi
      -- capturado. Regra original da 081, reposta pela 099.
      identificador_rd = COALESCE(EXCLUDED.identificador_rd, lead.identificador_rd),
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

  -- ── OpportunityStage (Salesforce) — migration 092 ───────────────────────
  -- ANTES de Opportunity pelo mesmo motivo de CurrencyType: a oportunidade só
  -- é classificável depois que a declaração do estágio está na tabela.
  --
  -- Lido INTEIRO a cada execução, sem watermark: são 114 linhas, e a
  -- classificação de um estágio muda no Setup sem tocar em registro nenhum --
  -- ler incremental congelaria a regra antiga.
  --
  -- Sem DISTINCT ON de propósito: ApiName é único na org (medido, 114 de 114).
  -- Se um dia chegar duplicado, o ON CONFLICT aborta o lote em voz alta, que é
  -- melhor do que escolher uma das duas declarações em silêncio.
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'OpportunityStage';
  IF v_rows_source > 0 THEN
    INSERT INTO opportunity_stage (api_name, master_label, is_active, is_won, is_closed, default_probability, forecast_category, sort_order, source_id, collected_at)
    SELECT
      s.payload->>'ApiName',
      s.payload->>'MasterLabel',
      NULLIF(s.payload->>'IsActive','')::boolean,
      NULLIF(s.payload->>'IsWon','')::boolean,
      NULLIF(s.payload->>'IsClosed','')::boolean,
      NULLIF(s.payload->>'DefaultProbability','')::numeric,
      NULLIF(s.payload->>'ForecastCategoryName',''),
      NULLIF(s.payload->>'SortOrder','')::integer,
      s.payload->>'Id',
      s.collected_at
    FROM stg_salesforce s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'OpportunityStage'
      AND s.payload->>'ApiName' IS NOT NULL
    ON CONFLICT (api_name) DO UPDATE SET
      master_label = EXCLUDED.master_label, is_active = EXCLUDED.is_active,
      is_won = EXCLUDED.is_won, is_closed = EXCLUDED.is_closed,
      default_probability = EXCLUDED.default_probability,
      forecast_category = EXCLUDED.forecast_category, sort_order = EXCLUDED.sort_order,
      source_id = EXCLUDED.source_id, collected_at = EXCLUDED.collected_at, ingested_at = now();
    GET DIAGNOSTICS v_rows_target = ROW_COUNT;
    PERFORM fn_registrar_ingest('salesforce', 'OpportunityStage', v_rows_source, v_rows_target, CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END, NULL);
    object_type := 'OpportunityStage'; rows_source := v_rows_source; rows_target := v_rows_target;
    status := CASE WHEN v_rows_source = v_rows_target THEN 'ok' ELSE 'partial' END;
    RETURN NEXT;
  END IF;
  -- Opportunity (Salesforce)
  SELECT count(*) INTO v_rows_source FROM stg_salesforce s WHERE s.batch_id = p_batch_id AND s.object_type = 'Opportunity';
  IF v_rows_source > 0 THEN
    INSERT INTO opportunity (source_system, source_id, account_id, record_type_name, stage_name, lead_source, amount, currency_iso_code, mrr, duracao_meses_contrato, owner_id, created_at_source, closed_at_source, collected_at)
    SELECT
      'salesforce', s.payload->>'Id', a.id, s.payload#>>'{RecordType,Name}', s.payload->>'StageName',
      -- migration 100: a ORIGEM da propria oportunidade. 93,6% das oportunidades
      -- nao tem lead convertido, entao sem este campo a atribuicao marketing x
      -- comercial cobria 6,4% da base. Cobertura de LeadSource na org: 8.071 de
      -- 8.073 (99,98%).
      NULLIF(s.payload->>'LeadSource',''),
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
      lead_source = EXCLUDED.lead_source,
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

    -- REPOSTO PELA MIGRATION 101 (2026-09-16): este bloco inteiro sumiu quando a
    -- 090 foi escrita sobre o corpo da 073. Texto identico ao da 078, reinserido
    -- sobre o corpo vivo -- ver cabecalho da 101.
    -- ── v12 (migration 078): o webhook passa a alimentar lead e
    -- lead_conversion_event, nao so contact e conversion_event.
    --
    -- ATE AQUI o caminho do webhook (tempo real) escrevia em `contact` e na
    -- tabela antiga `conversion_event`, que NAO TEM colunas de UTM. Todo o
    -- resto do payload -- utm_source, utm_medium, utm_campaign, utm_content,
    -- utm_term, utm_id (que e o ID do anuncio no Meta), Midia, Cargo, Tamanho
    -- da Empresa -- ficava parado no JSON de staging e nunca chegava na tela.
    --
    -- Quem enriquecia era so o caminho do PULL de descoberta (object_type
    -- 'LeadConversion'), que roda em lote. Resultado pratico: lead que chega
    -- AGORA aparece no dashboard como linha crua, so com a origem; lead que
    -- chegou no ultimo lote aparece completo. Dois caminhos, um so deles
    -- entregando o dado que o RD ja mandou.
    --
    -- O payload do webhook e ANINHADO e cru (formato da API do RD); o do pull
    -- vem achatado pelo coletor no n8n. Por isso o mapeamento abaixo nao pode
    -- ser copiado do ramo LeadConversion -- ele le os mesmos campos nos
    -- caminhos onde o RD de fato os coloca, com COALESCE entre
    -- custom_fields e last_conversion.content (a fonte popula os dois, nem
    -- sempre ambos).

    INSERT INTO lead (
      source_system, source_id, nome, empresa, email, telefone,
      origem_bruta, cargo, tamanho_empresa_bruto, tags,
      is_teste, teste_regra, lista_regra, created_at_source, collected_at
    )
    SELECT
      'rd_station', s.payload->>'uuid',
      COALESCE(s.payload#>>'{last_conversion,content,Nome}', s.payload->>'name'),
      COALESCE(s.payload#>>'{last_conversion,content,Empresa}', s.payload->>'company'),
      COALESCE(s.payload#>>'{last_conversion,content,email_lead}', s.payload->>'email'),
      COALESCE(s.payload#>>'{last_conversion,content,Telefone}', s.payload->>'personal_phone'),
      COALESCE(s.payload#>>'{first_conversion,content,conversion_identifier}',
               s.payload#>>'{last_conversion,content,identificador}'),
      COALESCE(s.payload#>>'{last_conversion,content,Cargo}', s.payload->>'job_title'),
      COALESCE(s.payload#>>'{custom_fields,Tamanho da Empresa}',
               s.payload#>>'{last_conversion,content,Tamanho da Empresa}'),
      CASE WHEN jsonb_typeof(s.payload->'tags') = 'array'
           THEN ARRAY(SELECT jsonb_array_elements_text(s.payload->'tags'))
           ELSE NULL END,
      fn_lead_e_teste(COALESCE(s.payload#>>'{last_conversion,content,email_lead}', s.payload->>'email')) IS NOT NULL,
      fn_lead_e_teste(COALESCE(s.payload#>>'{last_conversion,content,email_lead}', s.payload->>'email')),
      fn_lead_lista_regra(CASE WHEN jsonb_typeof(s.payload->'tags') = 'array'
                               THEN ARRAY(SELECT jsonb_array_elements_text(s.payload->'tags'))
                               ELSE NULL END),
      NULLIF(s.payload->>'created_at','')::timestamptz,
      s.collected_at
    FROM stg_rdstation s
    WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent'
      AND s.payload->>'uuid' IS NOT NULL
    ON CONFLICT (source_system, source_id) DO UPDATE SET
      nome                  = COALESCE(EXCLUDED.nome, lead.nome),
      empresa               = COALESCE(EXCLUDED.empresa, lead.empresa),
      email                 = COALESCE(EXCLUDED.email, lead.email),
      telefone              = COALESCE(EXCLUDED.telefone, lead.telefone),
      -- origem_bruta e o PRIMEIRO toque: nao sobrescreve quando ja existe.
      origem_bruta          = COALESCE(lead.origem_bruta, EXCLUDED.origem_bruta),
      cargo                 = COALESCE(EXCLUDED.cargo, lead.cargo),
      tamanho_empresa_bruto = COALESCE(EXCLUDED.tamanho_empresa_bruto, lead.tamanho_empresa_bruto),
      tags                  = COALESCE(EXCLUDED.tags, lead.tags),
      is_teste              = lead.is_teste OR EXCLUDED.is_teste,
      teste_regra           = COALESCE(lead.teste_regra, EXCLUDED.teste_regra),
      lista_regra           = fn_lead_lista_regra(COALESCE(EXCLUDED.tags, lead.tags)),
      collected_at          = EXCLUDED.collected_at,
      ingested_at           = now();

    INSERT INTO lead_conversion_event (
      lead_id, origem_conversao, event_type, occurred_at,
      empresa_bruta, cargo, tamanho_empresa_bruto, tamanho_empresa,
      primeiro_toque_bruto, ultimo_toque_bruto,
      utm_source, utm_medium, utm_campaign, utm_content, utm_term, utm_id,
      gclid, midia, campanha_de_origem, source_system, collected_at,
      atribuicao_status
    )
    SELECT
      l.id,
      COALESCE(s.payload#>>'{last_conversion,content,identificador}',
               s.payload#>>'{last_conversion,content,conversion_identifier}',
               s.payload#>>'{last_conversion,source}'),
      COALESCE(NULLIF(s.payload#>>'{last_conversion,content,event_type}',''), 'CONVERSION'),
      NULLIF(s.payload#>>'{last_conversion,created_at}','')::timestamptz,
      COALESCE(s.payload#>>'{last_conversion,content,Empresa}', s.payload->>'company'),
      COALESCE(s.payload#>>'{last_conversion,content,Cargo}', s.payload->>'job_title'),
      COALESCE(s.payload#>>'{custom_fields,Tamanho da Empresa}',
               s.payload#>>'{last_conversion,content,Tamanho da Empresa}'),
      fn_normalizar_tamanho_empresa(COALESCE(s.payload#>>'{custom_fields,Tamanho da Empresa}',
                                             s.payload#>>'{last_conversion,content,Tamanho da Empresa}')),
      NULLIF(s.payload#>>'{first_conversion,content,traffic_source}',''),
      NULLIF(s.payload#>>'{last_conversion,content,traffic_source}',''),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,utm_source}',''),  NULLIF(s.payload#>>'{last_conversion,content,utm_source}','')),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,utm_medium}',''),  NULLIF(s.payload#>>'{last_conversion,content,utm_medium}','')),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,utm_campaign}',''),NULLIF(s.payload#>>'{last_conversion,content,utm_campaign}','')),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,utm_content}',''), NULLIF(s.payload#>>'{last_conversion,content,utm_content}','')),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,utm_term}',''),    NULLIF(s.payload#>>'{last_conversion,content,utm_term}','')),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,utm_id}',''),      NULLIF(s.payload#>>'{last_conversion,content,utm_id}','')),
      NULLIF(s.payload#>>'{custom_fields,gclid}',''),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,Mídia}',''), NULLIF(s.payload#>>'{last_conversion,content,Mídia}','')),
      COALESCE(NULLIF(s.payload#>>'{custom_fields,Campanha de Origem}',''),
               NULLIF(s.payload#>>'{last_conversion,content,Campanha de Origem}','')),
      'rd_station',
      s.collected_at,
      -- Mesma regra do ramo do pull: 'ok' quando a fonte mandou sinal de
      -- sessao/trafego; NULL quando nao mandou. Nunca inventa.
      CASE WHEN NULLIF(s.payload#>>'{last_conversion,content,traffic_source}','') IS NOT NULL
                OR NULLIF(s.payload#>>'{custom_fields,utm_source}','') IS NOT NULL
           THEN 'ok' ELSE NULL END
    FROM stg_rdstation s
    JOIN lead l ON l.source_system = 'rd_station' AND l.source_id = s.payload->>'uuid'
    WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent'
      AND NULLIF(s.payload#>>'{last_conversion,created_at}','') IS NOT NULL
    ON CONFLICT DO NOTHING;

    -- Classifica o lead recem-chegado com as regras vigentes, para ele nao
    -- ficar 'NaoAtribuido' ate a proxima reclassificacao manual.
    PERFORM fn_reclassificar_lead(l.id)
    FROM stg_rdstation s
    JOIN lead l ON l.source_system = 'rd_station' AND l.source_id = s.payload->>'uuid'
    WHERE s.batch_id = p_batch_id AND s.object_type = 'ConversionEvent';

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
-- 3. O RESET DE WATERMARK — DADO AQUI, CONSUMIDO EM SEGUIDA
-- ═════════════════════════════════════════════════════════════════════════════
-- Consumido por uma releitura que reproduz o n8n fielmente (ver cabeçalho).
-- Condicionado para não se repetir: depois que a primeira oportunidade tiver
-- `lead_source`, este UPDATE afeta 0 linhas.

UPDATE sync_state
   SET last_run_at = timestamptz '2025-09-14T00:00:00Z'
 WHERE source = 'salesforce'
   AND object = 'Opportunity'
   AND NOT EXISTS (
     SELECT 1 FROM opportunity
      WHERE source_system = 'salesforce' AND lead_source IS NOT NULL
   );

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A VIEW: A ATRIBUIÇÃO GANHA A TERCEIRA FORÇA
-- ═════════════════════════════════════════════════════════════════════════════
-- Substitui a definição da migration 097. O grão NÃO muda: uma linha por
-- oportunidade. O que muda é de onde o segmento pode vir, e a coluna que conta
-- de onde veio.

-- DROP + CREATE, e não CREATE OR REPLACE: a 100 RENOMEIA `lead_source_id` para
-- `lead_salesforce_id` e acrescenta colunas no meio da lista, e CREATE OR
-- REPLACE VIEW recusa as duas coisas (só aceita acréscimo NO FIM, com o mesmo
-- nome e tipo para todas as anteriores). Procedimento da 088/090: conferir
-- pg_depend ANTES (feito em 2026-09-16: ZERO views dependentes — as quatro
-- funções leem a view mas função não entra em pg_depend) e REEMITIR O GRANT
-- depois. Esquecer o grant foi o modo de falha real da 049.
--
-- `view_leadsource_nao_classificado` cai junto porque depende desta view; ela é
-- recriada na seção 5, logo abaixo. Na primeira aplicação o IF EXISTS torna o
-- comando inócuo.
DROP VIEW IF EXISTS view_leadsource_nao_classificado;
DROP VIEW IF EXISTS view_oportunidade_analitica;

CREATE VIEW view_oportunidade_analitica AS
WITH
-- ── vínculo FORTE: lead.converted_opportunity_id ─────────────────────────────
-- Agregado POR OPORTUNIDADE antes do join. Sem este group by, as 2
-- oportunidades que têm 2 leads virariam 4 linhas e a contagem do universo
-- passaria de 8.073 sem que ninguém percebesse.
vinculo_individual AS (
  SELECT
    o.id                             AS opportunity_id,
    (array_agg(l.id ORDER BY l.id))[1] AS lead_id,
    count(DISTINCT l.id)             AS qtd_leads_candidatos
  FROM opportunity o
  JOIN lead l ON l.converted_opportunity_id = o.source_id
  WHERE o.source_system = 'salesforce'
  GROUP BY o.id
),
-- ── vínculo FRACO: lead.converted_account_id, e SÓ onde o forte não existe ───
vinculo_por_conta AS (
  SELECT
    o.id                             AS opportunity_id,
    (array_agg(l.id ORDER BY l.id))[1] AS lead_id,
    count(DISTINCT l.id)             AS qtd_leads_candidatos
  FROM opportunity o
  JOIN account a ON a.id = o.account_id AND a.source_system = 'salesforce'
  JOIN lead l    ON l.converted_account_id = a.source_id
  WHERE o.source_system = 'salesforce'
    AND NOT EXISTS (SELECT 1 FROM vinculo_individual vi WHERE vi.opportunity_id = o.id)
  GROUP BY o.id
)
SELECT
  o.id                                       AS opportunity_id,
  o.source_id,
  o.account_id                               AS conta_id,
  a.nome                                     AS conta_nome,
  o.record_type_name                         AS record_type,
  o.stage_name                               AS estagio,
  -- ── a nossa tradução (opportunity_stage_fase, migrations 079/092) ─────────
  f.fase,
  f.ordem                                    AS fase_ordem,
  -- ── a DECLARAÇÃO da origem (opportunity_stage, migration 092) ─────────────
  s.is_won                                   AS origem_is_won,
  s.is_closed                                AS origem_is_closed,
  s.default_probability                      AS origem_probabilidade,
  s.forecast_category                        AS origem_forecast,
  s.is_active                                AS origem_estagio_ativo,
  -- ── DESFECHO: partição TOTAL do universo, sem ELSE implícito ──────────────
  CASE
    WHEN s.api_name IS NULL                       THEN 'estagio_nao_declarado'
    WHEN s.is_won IS NULL OR s.is_closed IS NULL  THEN 'declaracao_incompleta'
    WHEN s.is_won                                 THEN 'ganha'
    WHEN s.is_closed                              THEN 'perdida'
    WHEN f.fase IS NULL                           THEN 'fora_de_fase'
    ELSE                                               'aberta'
  END                                        AS desfecho,
  CASE
    WHEN s.api_name IS NULL
      THEN format('Estágio "%s" não existe em opportunity_stage — a origem não declarou IsWon/IsClosed para ele, e nós não chutamos', coalesce(o.stage_name, '(nulo)'))
    WHEN s.is_won IS NULL OR s.is_closed IS NULL
      THEN format('Estágio "%s" existe no catálogo mas com IsWon/IsClosed nulo — declaração incompleta na origem', o.stage_name)
    WHEN s.is_won     THEN 'Origem declara IsWon = true'
    WHEN s.is_closed  THEN 'Origem declara IsClosed = true e IsWon = false'
    WHEN f.fase IS NULL
      THEN format('Aberta na origem (IsClosed = false), mas o estágio "%s" está fora do funil — opportunity_stage_fase declara fase NULL de propósito', o.stage_name)
    ELSE 'Aberta na origem (IsClosed = false)'
  END                                        AS desfecho_motivo,
  -- ── A DIVERGÊNCIA, EXPOSTA ────────────────────────────────────────────────
  CASE
    WHEN s.api_name IS NULL THEN NULL
    WHEN s.is_won IS NULL OR s.is_closed IS NULL THEN NULL
    WHEN s.is_won AND coalesce(f.fase, '') <> 'ganho'
      THEN format('Origem declara IsWon=true para "%s", nossa fase é "%s"', o.stage_name, coalesce(f.fase, '(nenhuma)'))
    WHEN NOT s.is_won AND f.fase = 'ganho'
      THEN format('Nossa fase diz ganho para "%s", origem declara IsWon=false', o.stage_name)
    WHEN s.is_closed AND coalesce(f.fase, '') NOT IN ('ganho', 'perdido')
      THEN format('Origem declara IsClosed=true para "%s", nossa fase é "%s" (não terminal)', o.stage_name, coalesce(f.fase, '(nenhuma)'))
    WHEN NOT s.is_closed AND f.fase IN ('ganho', 'perdido')
      THEN format('Nossa fase é terminal ("%s") para "%s", origem declara IsClosed=false', f.fase, o.stage_name)
  END                                        AS divergencia_origem_vs_fase,
  -- ── tempo ─────────────────────────────────────────────────────────────────
  o.created_at_source                        AS criada_em,
  -- NOME DELIBERADO. Não é `fechada_em`: CloseDate nesta org carrega o fim do
  -- contrato na coorte antiga e é retroativa na recente (migration 097).
  o.closed_at_source                         AS close_date_origem,
  CASE
    WHEN o.created_at_source IS NOT NULL AND o.closed_at_source IS NOT NULL
      THEN round((extract(epoch FROM (o.closed_at_source - o.created_at_source)) / 86400)::numeric, 1)
  END                                        AS dias_entre_criacao_e_close_date,
  (o.closed_at_source < o.created_at_source) AS close_date_antes_da_criacao,
  CASE
    WHEN o.duracao_meses_contrato IS NULL OR o.duracao_meses_contrato <= 0
      OR o.created_at_source IS NULL OR o.closed_at_source IS NULL THEN NULL
    ELSE abs(extract(epoch FROM (o.closed_at_source - o.created_at_source)) / 86400
             - o.duracao_meses_contrato * 30.44) <= 31
  END                                        AS close_date_no_fim_do_contrato,
  -- ── dinheiro (migration 090: DIVISÃO, e jamais fallback para 1) ───────────
  o.amount,                                  -- CRU, em moeda local. O DADO.
  o.mrr,
  o.duracao_meses_contrato,
  o.currency_iso_code                        AS moeda,
  cr.conversion_rate                         AS taxa_conversao,
  CASE
    WHEN o.amount IS NOT NULL AND cr.conversion_rate IS NOT NULL
      THEN o.amount / cr.conversion_rate
  END                                        AS amount_brl,
  CASE
    WHEN o.amount IS NULL
      THEN 'Amount vazio na origem — não há valor para converter'
    WHEN o.currency_iso_code IS NULL
      THEN 'Moeda ausente no registro — ingerido antes da migration 090 e ainda não relido'
    WHEN cr.iso_code IS NULL
      THEN format('Moeda "%s" não está em currency_rate — taxa desconhecida, e valor NUNCA é assumido como real', o.currency_iso_code)
  END                                        AS conversao_indisponivel_motivo,
  -- ── ORIGEM DO NEGÓCIO — TRÊS FORÇAS DECLARADAS (migration 100) ────────────
  coalesce(vi.lead_id, vc.lead_id)           AS lead_id,
  -- RENOMEADO na 100: era `lead_source_id` na 097 e passou a colidir de frente
  -- com `lead_source`, que é outra coisa inteiramente. Dois nomes quase iguais
  -- para o id do lead e para a picklist de origem é erro esperando acontecer.
  l.source_id                                AS lead_salesforce_id,
  l.nome                                     AS lead_nome,
  o.lead_source,                             -- CRU, exatamente como a origem grava
  -- QUAL REGRA CLASSIFICOU ESTA LINHA. Partição total em 6 valores. A ordem do
  -- CASE É a ordem de precedência declarada: jornada real antes de picklist.
  CASE
    WHEN c.segmento IS NOT NULL AND vi.lead_id IS NOT NULL THEN 'oportunidade'
    WHEN c.segmento IS NOT NULL AND vc.lead_id IS NOT NULL THEN 'conta'
    WHEN x.segmento IS NOT NULL                            THEN 'leadsource'
    WHEN o.lead_source IS NOT NULL                         THEN 'leadsource_desconhecido'
    WHEN coalesce(vi.lead_id, vc.lead_id) IS NOT NULL      THEN 'lead_sem_classificacao'
    ELSE                                                        'sem_origem'
  END                                        AS lead_vinculo_regra,
  coalesce(vi.qtd_leads_candidatos, vc.qtd_leads_candidatos, 0) AS qtd_leads_candidatos,
  coalesce(c.segmento,  x.segmento)          AS segmento,
  coalesce(c.categoria, x.categoria)         AS categoria,
  coalesce(c.detalhe,   x.detalhe)           AS detalhe,
  coalesce(c.sinal_id,  x.sinal_id)          AS origem_sinal_id,
  -- O balde que a tela exibe. Cinco destinos possíveis, e nenhum deles é um
  -- "outros" onde o desconhecido se esconde:
  --   Marketing / Comercial / Parceiro / NaoAtribuido  -> classificação feita
  --   NaoClassificado                                  -> ninguém decidiu ainda
  --   SemOrigem                                        -> a origem não tem o dado
  -- `NaoClassificado` NÃO é `NaoAtribuido`: o segundo é uma decisão tomada
  -- ("base importada não se atribui"), o primeiro é a ausência de decisão.
  CASE
    WHEN coalesce(c.segmento, x.segmento) IS NOT NULL THEN coalesce(c.segmento, x.segmento)
    WHEN o.lead_source IS NOT NULL                    THEN 'NaoClassificado'
    WHEN coalesce(vi.lead_id, vc.lead_id) IS NOT NULL THEN 'NaoClassificado'
    ELSE                                                   'SemOrigem'
  END                                        AS segmento_aba
FROM opportunity o
LEFT JOIN account a                 ON a.id = o.account_id
LEFT JOIN opportunity_stage_fase f  ON f.stage_name = o.stage_name
LEFT JOIN opportunity_stage s       ON s.api_name  = o.stage_name
LEFT JOIN currency_rate cr          ON cr.iso_code = o.currency_iso_code
LEFT JOIN vinculo_individual vi     ON vi.opportunity_id = o.id
LEFT JOIN vinculo_por_conta   vc    ON vc.opportunity_id = o.id
LEFT JOIN lead l                    ON l.id = coalesce(vi.lead_id, vc.lead_id)
LEFT JOIN lead_origin_classification c
       ON c.lead_id = coalesce(vi.lead_id, vc.lead_id) AND c.valid_to IS NULL
-- A TERCEIRA FORÇA. LEFT, nunca INNER: valor que o crosswalk não conhece tem de
-- virar `NaoClassificado` VISÍVEL, não sumir da view. Sumir é a exclusão
-- silenciosa que o contrato §1.6 proíbe, e foi assim que 1.523 oportunidades
-- teriam desaparecido da aba sem ninguém notar.
LEFT JOIN leadsource_crosswalk x    ON x.valor_bruto = o.lead_source
WHERE o.source_system = 'salesforce';

COMMENT ON VIEW view_oportunidade_analitica IS
  'A CAMADA DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR OPORTUNIDADE (contrato §1.7). UNIVERSO: todas as oportunidades source_system=salesforce (8.073 em 2026-09-16), nunca o recorte da planilha de 513 linhas. DESFECHO é partição TOTAL em 6 valores e a autoridade é opportunity_stage.is_won/is_closed da ORIGEM, não o rótulo do estágio; divergencia_origem_vs_fase expõe discordância em vez de escolher em silêncio. amount_brl é amount/conversion_rate e é NULL quando a taxa é desconhecida — NUNCA amount×1 (migration 090). ATRIBUIÇÃO (migration 100): três forças em ordem declarada — (a) lead por converted_opportunity_id, (b) lead por converted_account_id, (c) Opportunity.LeadSource via leadsource_crosswalk. lead_vinculo_regra diz qual das três classificou cada linha e é partição total em 6 valores. LeadSource que o crosswalk não conhece vira segmento_aba=NaoClassificado, JAMAIS Comercial e JAMAIS NaoAtribuido (este último é decisão tomada; NaoClassificado é ausência de decisão) — os valores pendentes estão em view_leadsource_nao_classificado. ⚠️ close_date_origem é Opportunity.CloseDate e NÃO é a data do fecho: na coorte antiga carrega o fim do contrato, na recente é retroativa. Use dias_entre_criacao_e_close_date como prazo, jamais como ciclo de venda. Migrations 097 + 100.';

COMMENT ON COLUMN view_oportunidade_analitica.lead_vinculo_regra IS
  'Qual das três forças classificou esta linha. Partição TOTAL: "oportunidade" = lead por converted_opportunity_id; "conta" = lead por converted_account_id; "leadsource" = Opportunity.LeadSource reconhecido por leadsource_crosswalk; "leadsource_desconhecido" = tem LeadSource mas o crosswalk não conhece o valor (vira NaoClassificado, nunca Comercial); "lead_sem_classificacao" = tem lead mas o lead não tem classificação vigente; "sem_origem" = não tem lead NEM LeadSource. Substituiu o valor "sem_lead" da migration 097, que passou a mentir quando 99,98% das linhas ganharam origem.';

COMMENT ON COLUMN view_oportunidade_analitica.lead_source IS
  'Opportunity.LeadSource CRU, como a origem grava. `Otros` (80 registros) e `Outros` (409) são valores DIFERENTES e continuam diferentes — unificar por normalização de texto numa view unificaria também o que ninguém pediu. Se tiverem de virar a mesma coisa, que seja por duas linhas em leadsource_crosswalk apontando para o mesmo segmento.';

COMMENT ON COLUMN view_oportunidade_analitica.segmento_aba IS
  'O balde da tela. Cinco destinos: Marketing/Comercial/Parceiro/NaoAtribuido (classificação feita, por lead ou por crosswalk), NaoClassificado (a origem declarou algo que ninguém traduziu ainda) e SemOrigem (a origem não tem o dado — 2 registros). Nenhum deles é um "outros" onde o desconhecido se esconde. Foi despejar o desconhecido num balde existente que produziu o "100% atribuído a marketing" da aba antiga.';

GRANT SELECT ON view_oportunidade_analitica TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A FILA DE TRABALHO: O QUE FALTA CLASSIFICAR, ORDENADO POR IMPACTO
-- ═════════════════════════════════════════════════════════════════════════════
-- Sem esta view, "NaoClassificado" seria um número na tela sem próximo passo.
-- Com ela, é uma lista de decisões pendentes ordenada pelo que elas custam —
-- e a receita ao lado responde "vale a pena classificar este valor?".

CREATE OR REPLACE VIEW view_leadsource_nao_classificado AS
SELECT
  v.lead_source                                            AS valor_bruto,
  count(*)                                                 AS oportunidades,
  count(*) FILTER (WHERE v.desfecho = 'ganha')             AS ganhas,
  sum(v.amount_brl) FILTER (WHERE v.desfecho = 'ganha')    AS receita_ganha_brl,
  min(v.criada_em)                                         AS primeira_em,
  max(v.criada_em)                                         AS ultima_em
FROM view_oportunidade_analitica v
WHERE v.lead_vinculo_regra = 'leadsource_desconhecido'
GROUP BY v.lead_source
ORDER BY count(*) DESC;

COMMENT ON VIEW view_leadsource_nao_classificado IS
  'GRÃO: UMA LINHA POR VALOR DE Opportunity.LeadSource que leadsource_crosswalk ainda não conhece. É a fila de decisões pendentes, ordenada por impacto, com a receita ganha ao lado para priorizar. Medido em 2026-09-16: 36 valores, 1.523 oportunidades (18,9% da base), lideradas por GoTo (898), Expansão (110) e Upgrade / Add-on em Renovação (94). A decisão de cada valor vira uma LINHA em leadsource_crosswalk, com decidido_em e fonte_decisao — nunca um CASE dentro de uma view. Migration 100.';

GRANT SELECT ON view_leadsource_nao_classificado TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. OS CARDS — GANHAM O FILTRO POR LeadSource E DOIS CONTADORES DE COBERTURA
-- ═════════════════════════════════════════════════════════════════════════════
-- `qtd_nao_classificado` e `qtd_sem_origem` entram na saída porque a cobertura
-- da atribuição é ela própria um número da tela. Sem eles, a aba mostraria
-- "Marketing 8%" sem dizer que 19% da base não foi classificada — que é o
-- mesmo tipo de silêncio que produziu "100% atribuído a marketing".
--
-- O tipo de retorno muda, então é DROP + CREATE. DROP descarta GRANT e
-- `plan_cache_mode`: os dois voltam abaixo, de propósito.

DROP FUNCTION IF EXISTS public.fn_oportunidades_cards(jsonb);

CREATE FUNCTION public.fn_oportunidades_cards(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  periodo_de                          timestamptz,
  periodo_ate                         timestamptz,
  periodo_anterior_de                 timestamptz,
  periodo_anterior_ate                timestamptz,
  periodo_anterior_tem_dado           boolean,
  periodo_anterior_sem_dado_motivo    text,
  total_oportunidades                 bigint,
  qtd_ganhas                          bigint,
  qtd_perdidas                        bigint,
  qtd_abertas                         bigint,
  qtd_fora_de_fase                    bigint,
  qtd_estagio_nao_declarado           bigint,
  qtd_declaracao_incompleta           bigint,
  soma_fecha                          boolean,
  soma_fecha_diferenca                bigint,
  qtd_decididas                       bigint,
  win_rate_decididas_pct              numeric,
  win_rate_sobre_todas_pct            numeric,
  receita_ganha_brl                   numeric,
  qtd_ganhas_no_valor                 bigint,
  qtd_ganhas_fora_do_valor            bigint,
  ganhas_fora_do_valor_motivos        jsonb,
  pipeline_aberto_brl                 numeric,
  qtd_abertas_no_pipeline             bigint,
  qtd_abertas_fora_do_pipeline        bigint,
  ticket_medio_ganhas_brl             numeric,
  ticket_medio_n                      bigint,
  dias_ate_close_date_mediana         numeric,
  dias_ate_close_date_n               bigint,
  ciclo_qtd_close_antes_da_criacao    bigint,
  ciclo_qtd_close_no_fim_do_contrato  bigint,
  ciclo_ressalva                      text,
  qtd_divergencia_origem_vs_fase      bigint,
  -- ── migration 100: a cobertura da atribuição, como número de primeira classe
  qtd_com_segmento                    bigint,
  qtd_nao_classificado                bigint,
  qtd_sem_origem                      bigint,
  pct_com_segmento                    numeric,
  -- ── período anterior ──
  ant_total_oportunidades             bigint,
  ant_qtd_ganhas                      bigint,
  ant_qtd_perdidas                    bigint,
  ant_qtd_abertas                     bigint,
  ant_qtd_decididas                   bigint,
  ant_win_rate_decididas_pct          numeric,
  ant_receita_ganha_brl               numeric,
  ant_qtd_ganhas_fora_do_valor        bigint,
  ant_pipeline_aberto_brl             numeric,
  ant_ticket_medio_ganhas_brl         numeric,
  ant_ticket_medio_n                  bigint
)
LANGUAGE plpgsql
STABLE
-- Migration 089: sem isto, os filtros opcionais na forma ($n IS NULL OR col=$n)
-- fazem o planejador multiplicar seletividades default, estimar rows=1 e
-- escolher nested loop. Mediu-se 800x de degradação neste banco.
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de        timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate       timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_ant_de    timestamptz;
  v_ant_ate   timestamptz;
  v_seg       jsonb := p_filtros->'segmento';
  v_fase      jsonb := p_filtros->'fase';
  v_desfecho  jsonb := p_filtros->'desfecho';
  v_rt        jsonb := p_filtros->'record_type';
  v_moeda     jsonb := p_filtros->'moeda';
  v_vinculo   jsonb := p_filtros->'lead_vinculo_regra';
  v_ls        jsonb := p_filtros->'lead_source';   -- migration 100
BEGIN
  IF v_de IS NOT NULL AND v_ate IS NOT NULL THEN
    v_ant_de  := v_de - (v_ate - v_de);
    v_ant_ate := v_de;
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT v.*,
           CASE
             WHEN (v_de  IS NULL OR v.criada_em >= v_de)
              AND (v_ate IS NULL OR v.criada_em <  v_ate)          THEN 'atual'
             WHEN v_ant_de IS NOT NULL
              AND v.criada_em >= v_ant_de AND v.criada_em < v_ant_ate THEN 'anterior'
           END AS janela
    FROM view_oportunidade_analitica v
    WHERE fn_filtro_casa(v.segmento_aba,       v_seg)
      AND fn_filtro_casa(v.fase,               v_fase)
      AND fn_filtro_casa(v.desfecho,           v_desfecho)
      AND fn_filtro_casa(v.record_type,        v_rt)
      AND fn_filtro_casa(v.moeda,              v_moeda)
      AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
      AND fn_filtro_casa(v.lead_source,        v_ls)
  ),
  recorte AS (SELECT * FROM base WHERE janela IS NOT NULL),
  agg AS (
    SELECT
      count(*)                       FILTER (WHERE janela='atual') AS total,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='ganha')                 AS ganhas,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='perdida')               AS perdidas,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='aberta')                AS abertas,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='fora_de_fase')          AS fora_fase,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='estagio_nao_declarado') AS nao_decl,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='declaracao_incompleta') AS decl_incompleta,
      sum(amount_brl)                FILTER (WHERE janela='atual' AND desfecho='ganha')                     AS receita,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='ganha' AND amount_brl IS NOT NULL) AS ganhas_com_valor,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='ganha' AND amount_brl IS NULL)     AS ganhas_sem_valor,
      avg(amount_brl)                FILTER (WHERE janela='atual' AND desfecho='ganha')                     AS ticket,
      -- PIPELINE = NÃO DECIDIDAS. `fora_de_fase` entra: a origem diz
      -- IsClosed=false para `Lista`, e omitir 4 linhas porque elas não têm fase
      -- seria a exclusão silenciosa que o contrato §1.6 proíbe.
      sum(amount_brl)                FILTER (WHERE janela='atual' AND desfecho IN ('aberta','fora_de_fase'))                            AS pipeline,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho IN ('aberta','fora_de_fase') AND amount_brl IS NOT NULL) AS abertas_com_valor,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho IN ('aberta','fora_de_fase') AND amount_brl IS NULL)     AS abertas_sem_valor,
      -- `::numeric` explícito: percentile_cont só tem variante float8/interval,
      -- então o numeric da view seria promovido a double precision e voltaria
      -- com ruído de ponto flutuante numa coluna de dias.
      (percentile_cont(0.5) WITHIN GROUP (ORDER BY dias_entre_criacao_e_close_date)
        FILTER (WHERE janela='atual' AND desfecho='ganha' AND dias_entre_criacao_e_close_date >= 0))::numeric AS ciclo_mediana,
      count(*) FILTER (WHERE janela='atual' AND desfecho='ganha' AND dias_entre_criacao_e_close_date >= 0) AS ciclo_n,
      count(*) FILTER (WHERE janela='atual' AND desfecho='ganha' AND close_date_antes_da_criacao)          AS ciclo_invertidas,
      count(*) FILTER (WHERE janela='atual' AND desfecho='ganha' AND close_date_no_fim_do_contrato)        AS ciclo_fim_contrato,
      count(*) FILTER (WHERE janela='atual' AND divergencia_origem_vs_fase IS NOT NULL)                    AS divergencias,
      -- ── migration 100: cobertura da atribuição ──
      count(*) FILTER (WHERE janela='atual' AND segmento_aba NOT IN ('NaoClassificado','SemOrigem')) AS com_segmento,
      count(*) FILTER (WHERE janela='atual' AND segmento_aba = 'NaoClassificado')                    AS nao_classificado,
      count(*) FILTER (WHERE janela='atual' AND segmento_aba = 'SemOrigem')                          AS sem_origem,
      -- ── período anterior ──
      count(*)        FILTER (WHERE janela='anterior')                        AS a_total,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='ganha')   AS a_ganhas,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='perdida') AS a_perdidas,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='aberta')  AS a_abertas,
      sum(amount_brl) FILTER (WHERE janela='anterior' AND desfecho='ganha')   AS a_receita,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='ganha' AND amount_brl IS NULL) AS a_ganhas_sem_valor,
      sum(amount_brl) FILTER (WHERE janela='anterior' AND desfecho IN ('aberta','fora_de_fase'))   AS a_pipeline,
      avg(amount_brl) FILTER (WHERE janela='anterior' AND desfecho='ganha')   AS a_ticket,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='ganha' AND amount_brl IS NOT NULL) AS a_ticket_n
    FROM recorte
  ),
  motivos AS (
    -- Não basta contar quantas ficaram de fora: POR QUE cada uma ficou é o que
    -- distingue "Amount vazio na origem" de "moeda sem taxa", e as duas exigem
    -- providências diferentes de quem opera o CRM.
    SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) AS j
    FROM (
      SELECT coalesce(conversao_indisponivel_motivo, '(motivo não classificado)') AS m,
             count(*) AS n
      FROM recorte
      WHERE janela = 'atual' AND desfecho = 'ganha' AND amount_brl IS NULL
      GROUP BY 1
    ) t
  )
  SELECT
    v_de, v_ate, v_ant_de, v_ant_ate,
    (v_ant_de IS NOT NULL AND agg.a_total > 0),
    CASE
      WHEN v_de IS NULL OR v_ate IS NULL
        THEN 'Sem período fechado no filtro (de/ate) — não há duração para deslocar, logo não existe período anterior. A tela deve esconder a seta, não desenhar variação contra zero.'
      WHEN agg.a_total = 0
        THEN format('Nenhuma oportunidade criada entre %s e %s sob os mesmos filtros — variação percentual contra zero é indefinida, não é +100%%.',
                    to_char(v_ant_de, 'YYYY-MM-DD'), to_char(v_ant_ate, 'YYYY-MM-DD'))
    END,
    agg.total, agg.ganhas, agg.perdidas, agg.abertas, agg.fora_fase, agg.nao_decl, agg.decl_incompleta,
    (agg.ganhas + agg.perdidas + agg.abertas + agg.fora_fase + agg.nao_decl + agg.decl_incompleta) = agg.total,
    agg.total - (agg.ganhas + agg.perdidas + agg.abertas + agg.fora_fase + agg.nao_decl + agg.decl_incompleta),
    (agg.ganhas + agg.perdidas),
    round(100.0 * agg.ganhas / nullif(agg.ganhas + agg.perdidas, 0), 2),
    round(100.0 * agg.ganhas / nullif(agg.total, 0), 2),
    agg.receita, agg.ganhas_com_valor, agg.ganhas_sem_valor, motivos.j,
    agg.pipeline, agg.abertas_com_valor, agg.abertas_sem_valor,
    round(agg.ticket, 2), agg.ganhas_com_valor,
    round(agg.ciclo_mediana, 1), agg.ciclo_n, agg.ciclo_invertidas, agg.ciclo_fim_contrato,
    CASE WHEN agg.ciclo_n > 0 OR agg.ciclo_invertidas > 0 THEN
      format('NÃO é ciclo de venda. Opportunity.CloseDate nesta org carrega predominantemente o FIM DO CONTRATO: %s das %s ganhas deste recorte têm CloseDate ANTERIOR à criação (excluídas da mediana e contadas aqui), e %s caem a menos de 31 dias do fim do Termo_do_Contrato__c. Leia como prazo de contrato.',
             agg.ciclo_invertidas, agg.ganhas, agg.ciclo_fim_contrato)
    END,
    agg.divergencias,
    agg.com_segmento, agg.nao_classificado, agg.sem_origem,
    round(100.0 * agg.com_segmento / nullif(agg.total, 0), 2),
    agg.a_total, agg.a_ganhas, agg.a_perdidas, agg.a_abertas,
    (agg.a_ganhas + agg.a_perdidas),
    round(100.0 * agg.a_ganhas / nullif(agg.a_ganhas + agg.a_perdidas, 0), 2),
    agg.a_receita, agg.a_ganhas_sem_valor, agg.a_pipeline,
    round(agg.a_ticket, 2), agg.a_ticket_n
  FROM agg, motivos;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_cards(jsonb) IS
  'CARDS DA ABA OPORTUNIDADES. GRÃO DA SAÍDA: UMA LINHA (o recorte inteiro). Filtros em p_filtros: de/ate (timestamptz sobre criada_em; `de` INCLUSIVO, `ate` EXCLUSIVO), segmento, fase, desfecho, record_type, moeda, lead_vinculo_regra, lead_source (cada um aceita string ou array, via fn_filtro_casa). CONTRATOS: win_rate_decididas_pct = ganhas/(ganhas+perdidas) e qtd_decididas vem ao lado para a tela exibir o denominador — win_rate_sobre_todas_pct é devolvido SÓ para contraste de auditoria, não é o indicador. receita_ganha_brl nunca vem sozinha: qtd_ganhas_fora_do_valor e ganhas_fora_do_valor_motivos dizem quantas ficaram de fora e por quê. pipeline_aberto_brl é ESTOQUE de não decididas, jamais previsão. soma_fecha confere que as 6 contagens de desfecho somam total_oportunidades — se vier false, a camada está errada e o número não deve ir para a tela. pct_com_segmento/qtd_nao_classificado/qtd_sem_origem são a COBERTURA da atribuição (migration 100) e devem aparecer junto de qualquer corte Marketing x Comercial. periodo_anterior_tem_dado=false significa ESCONDER a seta de tendência, não desenhar +100%. ⚠️ dias_ate_close_date_mediana NÃO é ciclo de venda. Migrations 097 + 100.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_cards(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. FUNIL E SEGMENTO — MESMO CONTRATO, MAIS UM FILTRO
-- ═════════════════════════════════════════════════════════════════════════════
-- O tipo de retorno não muda nos dois, então CREATE OR REPLACE preserva GRANT
-- e `plan_cache_mode` por construção. O SET é reemitido mesmo assim porque ele
-- faz parte da DEFINIÇÃO da função, não é um ALTER separado.

CREATE OR REPLACE FUNCTION public.fn_oportunidades_funil(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  fase                      text,
  fase_ordem                integer,
  fase_rotulo               text,
  qtd_da_coorte_agora       bigint,
  pct_da_coorte             numeric,
  valor_brl                 numeric,
  qtd_sem_valor             bigint,
  total_da_coorte           bigint
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de       timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate      timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_seg      jsonb := p_filtros->'segmento';
  v_rt       jsonb := p_filtros->'record_type';
  v_moeda    jsonb := p_filtros->'moeda';
  v_vinculo  jsonb := p_filtros->'lead_vinculo_regra';
  v_ls       jsonb := p_filtros->'lead_source';   -- migration 100
BEGIN
  RETURN QUERY
  WITH coorte AS (
    SELECT v.*
    FROM view_oportunidade_analitica v
    WHERE (v_de  IS NULL OR v.criada_em >= v_de)
      AND (v_ate IS NULL OR v.criada_em <  v_ate)
      AND fn_filtro_casa(v.segmento_aba,       v_seg)
      AND fn_filtro_casa(v.record_type,        v_rt)
      AND fn_filtro_casa(v.moeda,              v_moeda)
      AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
      AND fn_filtro_casa(v.lead_source,        v_ls)
  ),
  tot AS (SELECT count(*) AS n FROM coorte)
  SELECT
    c.fase,
    c.fase_ordem,
    -- A linha "fora de qualquer fase" é OBRIGATÓRIA (definição 7): hoje são as
    -- 4 de `Lista`, que a origem declara IsClosed=false e IsActive=false. Sem
    -- ela a soma do funil não bate com o total e ninguém percebe.
    coalesce(c.fase, '(fora de qualquer fase)') AS fase_rotulo,
    count(*)                                    AS qtd_da_coorte_agora,
    round(100.0 * count(*) / nullif(tot.n, 0), 2),
    sum(c.amount_brl),
    count(*) FILTER (WHERE c.amount_brl IS NULL),
    tot.n
  FROM coorte c, tot
  GROUP BY c.fase, c.fase_ordem, tot.n
  -- `ganho` e `perdido` compartilham ordem 5 (são os dois finais do funil);
  -- o desempate por nome mantém a saída estável entre chamadas.
  ORDER BY c.fase_ordem NULLS LAST, c.fase NULLS LAST;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_funil(jsonb) IS
  'FUNIL DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR FASE de opportunity_stage_fase, mais a linha "(fora de qualquer fase)" que é obrigatória. É ESTOQUE, não progressão: qtd_da_coorte_agora responde "das oportunidades CRIADAS no período filtrado, quantas estão AGORA nesta fase". 🚫 NÃO DIVIDA UMA LINHA PELA OUTRA. As fases são estados no instante da leitura, não etapas que a mesma oportunidade percorre de forma observável — esta base ingere só o estágio ATUAL, sem histórico. A aba antiga dividia "Qualificados" por "Em cadência" (estados mutuamente exclusivos) e chamava o resultado de conversão. pct_da_coorte é participação no total da coorte. Filtros: de/ate, segmento, record_type, moeda, lead_vinculo_regra, lead_source. Migrations 097 + 100.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_funil(jsonb) TO crm_ingest;

CREATE OR REPLACE FUNCTION public.fn_oportunidades_por_segmento(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  segmento_aba              text,
  qtd_oportunidades         bigint,
  pct_do_total              numeric,
  qtd_ganhas                bigint,
  qtd_perdidas              bigint,
  -- NOME DIFERENTE DO DOS CARDS DE PROPÓSITO: aqui o balde é "tudo que a
  -- origem ainda não decidiu", `fora_de_fase` incluída. Nos cards `qtd_abertas`
  -- e `qtd_fora_de_fase` são colunas separadas porque lá a soma das seis é
  -- conferida. Chamar as duas coisas de `qtd_abertas` faria dois números
  -- diferentes com o mesmo nome no mesmo endpoint.
  qtd_nao_decididas         bigint,
  qtd_decididas             bigint,
  win_rate_decididas_pct    numeric,
  receita_ganha_brl         numeric,
  pct_da_receita            numeric,
  qtd_ganhas_fora_do_valor  bigint,
  pipeline_aberto_brl       numeric,
  total_do_recorte          bigint,
  receita_total_do_recorte  numeric
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de       timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate      timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_fase     jsonb := p_filtros->'fase';
  v_desfecho jsonb := p_filtros->'desfecho';
  v_rt       jsonb := p_filtros->'record_type';
  v_moeda    jsonb := p_filtros->'moeda';
  v_ls       jsonb := p_filtros->'lead_source';   -- migration 100
BEGIN
  RETURN QUERY
  WITH recorte AS (
    SELECT v.*
    FROM view_oportunidade_analitica v
    WHERE (v_de  IS NULL OR v.criada_em >= v_de)
      AND (v_ate IS NULL OR v.criada_em <  v_ate)
      AND fn_filtro_casa(v.fase,        v_fase)
      AND fn_filtro_casa(v.desfecho,    v_desfecho)
      AND fn_filtro_casa(v.record_type, v_rt)
      AND fn_filtro_casa(v.moeda,       v_moeda)
      AND fn_filtro_casa(v.lead_source, v_ls)
  ),
  tot AS (
    SELECT count(*) AS n,
           sum(amount_brl) FILTER (WHERE desfecho = 'ganha') AS receita
    FROM recorte
  )
  SELECT
    r.segmento_aba,
    count(*),
    round(100.0 * count(*) / nullif(tot.n, 0), 2),
    count(*) FILTER (WHERE r.desfecho = 'ganha'),
    count(*) FILTER (WHERE r.desfecho = 'perdida'),
    count(*) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase')),
    count(*) FILTER (WHERE r.desfecho IN ('ganha','perdida')),
    round(100.0 * count(*) FILTER (WHERE r.desfecho = 'ganha')
          / nullif(count(*) FILTER (WHERE r.desfecho IN ('ganha','perdida')), 0), 2),
    sum(r.amount_brl) FILTER (WHERE r.desfecho = 'ganha'),
    round(100.0 * sum(r.amount_brl) FILTER (WHERE r.desfecho = 'ganha')
          / nullif(tot.receita, 0), 2),
    count(*) FILTER (WHERE r.desfecho = 'ganha' AND r.amount_brl IS NULL),
    sum(r.amount_brl) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase')),
    tot.n,
    tot.receita
  FROM recorte r, tot
  GROUP BY r.segmento_aba, tot.n, tot.receita
  ORDER BY count(*) DESC;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) IS
  'MARKETING vs COMERCIAL DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR segmento_aba. Seis valores possíveis: Marketing, Comercial, Parceiro, NaoAtribuido (classificação feita — por lead vinculado ou por leadsource_crosswalk), NaoClassificado (a origem declarou um LeadSource que ninguém traduziu ainda — 36 valores, 1.523 oportunidades em 2026-09-16, ver view_leadsource_nao_classificado) e SemOrigem (nem lead nem LeadSource — 2 registros). NaoClassificado NÃO é NaoAtribuido e NÃO é Comercial: despejá-lo num balde existente é como a aba antiga produziu "100% atribuído a marketing". Cada segmento vem com o SEU denominador (qtd_decididas) para que win rates de bases de tamanhos diferentes não sejam comparados como iguais. Filtros: de/ate, fase, desfecho, record_type, moeda, lead_source. Migrations 097 + 100.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. A LISTA — GANHA lead_source, origem_sinal_id E O RENOME DO ID DO LEAD
-- ═════════════════════════════════════════════════════════════════════════════
-- `lead_source_id` da 097 (o Id do Lead no Salesforce) vira `lead_salesforce_id`
-- porque `lead_source` passou a existir e dois nomes quase iguais para coisas
-- diferentes no mesmo payload é erro esperando acontecer no endpoint.
--
-- Tipo de retorno muda -> DROP + CREATE. DROP descarta GRANT e
-- `plan_cache_mode`; os dois voltam abaixo.

DROP FUNCTION IF EXISTS public.fn_search_oportunidades(jsonb, integer, integer);

CREATE FUNCTION public.fn_search_oportunidades(
  p_filtros jsonb    DEFAULT '{}'::jsonb,
  p_limit   integer  DEFAULT 50,
  p_offset  integer  DEFAULT 0
)
RETURNS TABLE (
  opportunity_id                  bigint,
  source_id                       text,
  conta_id                        bigint,
  conta_nome                      text,
  record_type                     text,
  estagio                         text,
  fase                            text,
  fase_ordem                      integer,
  desfecho                        text,
  desfecho_motivo                 text,
  divergencia_origem_vs_fase      text,
  criada_em                       timestamptz,
  close_date_origem               timestamptz,
  dias_entre_criacao_e_close_date numeric,
  close_date_antes_da_criacao     boolean,
  amount                          numeric,
  moeda                           text,
  amount_brl                      numeric,
  conversao_indisponivel_motivo   text,
  mrr                             numeric,
  duracao_meses_contrato          integer,
  lead_id                         bigint,
  lead_salesforce_id              text,
  lead_nome                       text,
  lead_source                     text,
  lead_vinculo_regra              text,
  qtd_leads_candidatos            bigint,
  segmento_aba                    text,
  categoria                       text,
  detalhe                         text,
  origem_sinal_id                 text,
  total_filtrado                  bigint
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de        timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate       timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_busca     text  := nullif(trim(p_filtros->>'busca'), '');
  v_seg       jsonb := p_filtros->'segmento';
  v_fase      jsonb := p_filtros->'fase';
  v_desfecho  jsonb := p_filtros->'desfecho';
  v_rt        jsonb := p_filtros->'record_type';
  v_moeda     jsonb := p_filtros->'moeda';
  v_vinculo   jsonb := p_filtros->'lead_vinculo_regra';
  v_ls        jsonb := p_filtros->'lead_source';   -- migration 100
  -- Interruptores de AUDITORIA, não de negócio. Existem para responder "me
  -- mostre as ganhas que não entraram na receita" e "quais são as que ninguém
  -- classificou" sem que alguém escreva SQL à mão e erre o predicado.
  v_so_divergentes boolean := coalesce((p_filtros->>'so_divergentes')::boolean, false);
  v_so_sem_valor   boolean := coalesce((p_filtros->>'so_sem_valor')::boolean, false);
  v_so_nao_class   boolean := coalesce((p_filtros->>'so_nao_classificado')::boolean, false);
  v_ordem     text  := coalesce(nullif(p_filtros->>'ordenar_por', ''), 'recentes');
  v_total     bigint;
BEGIN
  IF v_ordem NOT IN ('recentes', 'valor', 'fase') THEN
    RAISE EXCEPTION 'ordenar_por inválido: "%". Aceitos: recentes, valor, fase.', v_ordem
      USING HINT = 'Cair num ORDER BY padrão em silêncio faria a tela mostrar uma ordem que ninguém pediu.';
  END IF;

  SELECT count(*) INTO v_total
  FROM view_oportunidade_analitica v
  WHERE (v_de  IS NULL OR v.criada_em >= v_de)
    AND (v_ate IS NULL OR v.criada_em <  v_ate)
    AND fn_filtro_casa(v.segmento_aba,       v_seg)
    AND fn_filtro_casa(v.fase,               v_fase)
    AND fn_filtro_casa(v.desfecho,           v_desfecho)
    AND fn_filtro_casa(v.record_type,        v_rt)
    AND fn_filtro_casa(v.moeda,              v_moeda)
    AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
    AND fn_filtro_casa(v.lead_source,        v_ls)
    AND (NOT v_so_divergentes OR v.divergencia_origem_vs_fase IS NOT NULL)
    AND (NOT v_so_sem_valor   OR v.amount_brl IS NULL)
    AND (NOT v_so_nao_class   OR v.segmento_aba IN ('NaoClassificado','SemOrigem'))
    AND (v_busca IS NULL
         OR v.conta_nome  ILIKE '%' || v_busca || '%'
         OR v.lead_nome   ILIKE '%' || v_busca || '%'
         OR v.lead_source ILIKE '%' || v_busca || '%'
         OR v.source_id   =  v_busca);

  RETURN QUERY
  SELECT
    v.opportunity_id, v.source_id, v.conta_id, v.conta_nome, v.record_type,
    v.estagio, v.fase, v.fase_ordem,
    v.desfecho, v.desfecho_motivo, v.divergencia_origem_vs_fase,
    v.criada_em, v.close_date_origem, v.dias_entre_criacao_e_close_date,
    v.close_date_antes_da_criacao,
    v.amount, v.moeda, v.amount_brl, v.conversao_indisponivel_motivo,
    v.mrr, v.duracao_meses_contrato,
    v.lead_id, v.lead_salesforce_id, v.lead_nome,
    v.lead_source, v.lead_vinculo_regra, v.qtd_leads_candidatos,
    v.segmento_aba, v.categoria, v.detalhe, v.origem_sinal_id,
    v_total
  FROM view_oportunidade_analitica v
  WHERE (v_de  IS NULL OR v.criada_em >= v_de)
    AND (v_ate IS NULL OR v.criada_em <  v_ate)
    AND fn_filtro_casa(v.segmento_aba,       v_seg)
    AND fn_filtro_casa(v.fase,               v_fase)
    AND fn_filtro_casa(v.desfecho,           v_desfecho)
    AND fn_filtro_casa(v.record_type,        v_rt)
    AND fn_filtro_casa(v.moeda,              v_moeda)
    AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
    AND fn_filtro_casa(v.lead_source,        v_ls)
    AND (NOT v_so_divergentes OR v.divergencia_origem_vs_fase IS NOT NULL)
    AND (NOT v_so_sem_valor   OR v.amount_brl IS NULL)
    AND (NOT v_so_nao_class   OR v.segmento_aba IN ('NaoClassificado','SemOrigem'))
    AND (v_busca IS NULL
         OR v.conta_nome  ILIKE '%' || v_busca || '%'
         OR v.lead_nome   ILIKE '%' || v_busca || '%'
         OR v.lead_source ILIKE '%' || v_busca || '%'
         OR v.source_id   =  v_busca)
  ORDER BY
    -- NULLS LAST em TODAS as chaves: sem isto, ordenar por valor traria as 838
    -- sem `amount` na frente de todas as vendas, porque em PostgreSQL
    -- `ORDER BY x DESC` põe NULL PRIMEIRO.
    CASE WHEN v_ordem = 'valor'    THEN v.amount_brl END  DESC NULLS LAST,
    CASE WHEN v_ordem = 'fase'     THEN v.fase_ordem END  DESC NULLS LAST,
    CASE WHEN v_ordem = 'recentes' THEN v.criada_em  END  DESC NULLS LAST,
    v.criada_em DESC NULLS LAST,
    -- Desempate final determinístico: sem ele, duas chamadas com o mesmo
    -- OFFSET podem devolver a mesma linha duas vezes e pular outra.
    v.opportunity_id DESC
  LIMIT  greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$function$;

COMMENT ON FUNCTION public.fn_search_oportunidades(jsonb, integer, integer) IS
  'LISTA DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR OPORTUNIDADE (o mesmo de view_oportunidade_analitica). O predicado é IDÊNTICO ao de fn_oportunidades_cards para que a lista nunca contradiga o card acima dela; total_filtrado é recalculado sob o MESMO predicado (não é count do array paginado). Filtros: de/ate (`de` INCLUSIVO, `ate` EXCLUSIVO, sobre criada_em), busca (conta_nome, lead_nome, lead_source ou source_id exato), segmento, fase, desfecho, record_type, moeda, lead_vinculo_regra, lead_source, so_divergentes, so_sem_valor, so_nao_classificado, ordenar_por (recentes|valor|fase — valor inválido levanta exceção em vez de cair num padrão em silêncio). ATENÇÃO ao renome da migration 100: `lead_source_id` virou `lead_salesforce_id` (o Id do Lead), e `lead_source` agora é Opportunity.LeadSource — são coisas diferentes. Migrations 098 + 100.';

GRANT EXECUTE ON FUNCTION public.fn_search_oportunidades(jsonb, integer, integer) TO crm_ingest;

COMMIT;
