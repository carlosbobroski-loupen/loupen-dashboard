-- db/migrations/092_estagio_declarado_pela_origem.sql
--
-- O SALESFORCE JÁ DECLARA O QUE NÓS ESCREVEMOS À MÃO, E NUNCA LEMOS.
--
-- A migration 079 traduziu 24 estágios em 6 fases comerciais POR JULGAMENTO
-- HUMANO, e deixou 5 estágios (27 oportunidades) deliberadamente sem fase
-- porque "nenhum deles diz sozinho se a venda aconteceu". A frase estava certa
-- sobre o NOME do estágio e errada sobre a ORIGEM: o objeto `OpportunityStage`
-- do Salesforce declara, por estágio, `IsWon`, `IsClosed`,
-- `DefaultProbability`, `ForecastCategoryName`, `SortOrder` e `IsActive`.
-- São 114 estágios na org (48 ativos) contra 24 mapeados a mão.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O PALPITE QUE A ORIGEM DERRUBOU
--
-- `Pending Sale` parece venda fechada. Mapeá-lo como ganho era o caminho
-- óbvio. Lido na origem em 2026-09-16:
--
--   ApiName                  IsWon  IsClosed  Prob  ForecastCategory  IsActive
--   -----------------------  -----  --------  ----  ----------------  --------
--   Pending Sale             false  false       95  Pipeline          true
--   Processamento Interno    false  false       95  Pipeline          true
--   Pending Payment          false  false       95  Pipeline          true
--   Projeto para o Futuro    false  false       20  Pipeline          true
--   Lista                    false  false     NULL  Omitted           FALSE
--
-- Mapear `Pending Sale` e `Pending Payment` por intuição teria INVENTADO 14
-- vendas (11 + 3). A org marca `IsWon = true` em exatamente cinco estágios --
-- `Ganho`, `Fechadas`, `Closed Won`, `Sell Pending`, `Sale Pending` -- e só
-- `Ganho` existe na nossa base (2.553 oportunidades). Não há vitória escondida.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- 1. A DECLARAÇÃO DA ORIGEM VIRA TABELA
-- ═════════════════════════════════════════════════════════════════════════════
-- Cópia fiel, sem classificação nossa. `opportunity_stage_fase` continua sendo
-- o nosso julgamento; `opportunity_stage` é o que o CRM diz. Duas tabelas
-- porque são duas AUTORIDADES diferentes -- misturá-las numa só apagaria
-- exatamente a fronteira que esta migration existe para tornar auditável.
--
-- SEM CHECK INVENTADO: `currency_rate` ganhou `CHECK (conversion_rate > 0)`
-- porque taxa zero é divisão por zero esperando acontecer. Aqui nenhuma conta
-- depende destes campos, e um CHECK do tipo "IsWon implica IsClosed" seria uma
-- regra NOSSA colada numa tabela cujo valor é ser cópia. Se a org configurar
-- algo incoerente, queremos ver a incoerência, não recusá-la.

CREATE TABLE IF NOT EXISTS opportunity_stage (
  api_name            text PRIMARY KEY,
  master_label        text,
  is_active           boolean,
  is_won              boolean,
  is_closed           boolean,
  default_probability numeric,
  forecast_category   text,
  sort_order          integer,
  source_id           text,
  collected_at        timestamptz NOT NULL,
  ingested_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE opportunity_stage IS
  'Salesforce OpportunityStage, copia FIEL da declaracao da origem -- nenhuma classificacao nossa mora aqui. O julgamento humano mora em opportunity_stage_fase, e view_fase_vs_origem cruza os dois. Lida INTEIRA a cada execucao do n8n, sem watermark (114 linhas, e a classificacao de um estagio muda no Setup sem tocar em registro nenhum: ler incremental por SystemModstamp congelaria a regra antiga). Migration 092.';

COMMENT ON COLUMN opportunity_stage.is_won IS
  'Declaracao da ORIGEM de que o estagio e uma venda ganha. Em 2026-09-16 apenas Ganho, Fechadas, Closed Won, Sell Pending e Sale Pending trazem true, e so Ganho existe na nossa base. E este campo, nao o rotulo, que decide se uma oportunidade conta como venda: Pending Sale traz is_won=false com probabilidade 95.';

COMMENT ON COLUMN opportunity_stage.default_probability IS
  'Probabilidade padrao declarada pela org, 0 a 100. NULL em estagio inativo. E a regua contra a qual view_fase_vs_origem confere a nossa `ordem`: fase mais avancada com probabilidade menor que uma fase anterior e uma INVERSAO -- exposta, nunca corrigida sozinha.';

COMMENT ON COLUMN opportunity_stage.sort_order IS
  'Ordem de exibicao da org, unica entre os 48 ativos (1..48). NAO e a ordem de um funil: os 114 estagios pertencem a processos de venda diferentes, e SortOrder 26..48 mistura retencao, GTM SPIN e renovacao. NAO usar como sequencia de pipeline -- por isso a checagem de inversao usa default_probability, e nao este campo.';

COMMENT ON COLUMN opportunity_stage.forecast_category IS
  'ForecastCategoryName da origem: Pipeline, Best Case, Commit, Closed, Omitted. Atencao -- nesta org ela DISCORDA de default_probability em alguns estagios (Pending Sale traz prob 95 e categoria Pipeline, abaixo do Commit de Em Negociacao/Acordo Verbal, que trazem 85 e 90). A discordancia e da origem; esta tabela nao a resolve.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. OS 5 ÓRFÃOS, DERIVADOS DA DECLARAÇÃO E NÃO DO RÓTULO
-- ═════════════════════════════════════════════════════════════════════════════
--
-- ─── Os três de 95% -> `negociacao` (ordem 4), NÃO uma fase nova ────────────
--
-- `Pending Sale`, `Pending Payment` e `Processamento Interno` trazem
-- `DefaultProbability = 95` e `ForecastCategoryName = 'Pipeline'`.
--
-- O que a declaração FECHA: `IsClosed = false` elimina desfecho (nem ganho nem
-- perdido -- é o que impediu as 14 vendas inventadas). E 95 é maior que a
-- probabilidade de TODOS os estágios que já estão em `negociacao`
-- (Aprovado Verbalmente 70, Avaliando Proposta 75, Proposta Enviada 85,
-- Em Negociação 85, Acordo Verbal 90), o que elimina qualquer fase anterior.
--
-- O que a declaração NÃO fecha, e é por isso que NÃO abrimos fase nova:
-- os dois campos da origem DISCORDAM entre si. A probabilidade (95) diz
-- "acima de negociação"; a categoria de forecast diz `Pipeline`, ABAIXO do
-- `Commit` que a mesma org dá a `Em Negociação` (85) e `Acordo Verbal` (90).
-- Criar uma fase nova seria resolver uma contradição da ORIGEM com julgamento
-- NOSSO -- exatamente o que esta migration existe para parar de fazer.
-- `negociacao` é a única colocação que nenhum dos dois sinais contradiz.
--
-- E um motivo operacional que fecha a questão: a barra de desfecho da tela é
-- desenhada com `[1,2,3,4,5]` literal (assets/js/views/leads.js), e a regra da
-- 085 fixou `ganho` e `perdido` empatados em 5. Uma 6a ordem exigiria mexer na
-- tela, que está fora do escopo desta migration.
--
-- ─── `Projeto para o Futuro` -> `qualificacao` (ordem 2) ────────────────────
--
-- Prob 20, `Pipeline`, ativo. 20 é a MESMA probabilidade de `Avaliação` (20),
-- que já está em `qualificacao`, e está abaixo de `Coleta de Cenário` (30),
-- também em `qualificacao`. Cai dentro da faixa da fase, 0..50. O rótulo
-- ("projeto para o futuro" soa a geladeira, não a qualificação) não foi usado.
--
-- ─── `Lista` -> CONTINUA SEM FASE, e agora DECLARADO ────────────────────────
--
-- `IsActive = false`, `DefaultProbability = NULL`, `ForecastCategoryName =
-- 'Omitted'`. Um estágio inativo e sem probabilidade não é etapa de funil: a
-- própria org o omite da previsão. Entrar em qualquer fase o colocaria no
-- DENOMINADOR de taxa de conversão -- 4 oportunidades de valor 0,00, todas
-- criadas no mesmo 2026-08-04, que é assinatura de carga de lista, não de
-- pipeline.
--
-- A diferença em relação à 079: lá ele ficava fora por OMISSÃO, e omissão é
-- indistinguível de esquecimento. Aqui ele entra na tabela com `fase NULL` e
-- `motivo` escrito. O comportamento em todas as views é IDÊNTICO (todas fazem
-- LEFT JOIN e já tratam fase NULL), mas a pergunta "quem está fora de
-- propósito?" passa a ter resposta em SQL, e um estágio NOVO e desconhecido
-- continua aparecendo como ausente da tabela -- alto e visível, como na 079.

ALTER TABLE opportunity_stage_fase ALTER COLUMN fase DROP NOT NULL;

-- Um estágio sem fase não pode ter ordem: se tivesse, entraria em max(ordem) e
-- viraria "fase mais avançada" sendo justamente o que decidimos não ser fase.
ALTER TABLE opportunity_stage_fase
  DROP CONSTRAINT IF EXISTS opportunity_stage_fase_sem_fase_sem_ordem;
ALTER TABLE opportunity_stage_fase
  ADD CONSTRAINT opportunity_stage_fase_sem_fase_sem_ordem
  CHECK (fase IS NOT NULL OR ordem IS NULL);

COMMENT ON COLUMN opportunity_stage_fase.fase IS
  'Fase comercial atribuida por JULGAMENTO HUMANO. NULL = estagio deliberadamente fora do funil, com o porque em `motivo` (migration 092). Estagio AUSENTE desta tabela = desconhecido, ninguem decidiu ainda -- e continua aparecendo no aviso da 079. As duas coisas renderizam igual na tela; so esta tabela distingue decisao de esquecimento.';

INSERT INTO opportunity_stage_fase (stage_name, fase, ordem, motivo) VALUES
  ('Pending Sale',          'negociacao',  4, 'origem declara IsWon=false, IsClosed=false, prob 95, forecast Pipeline. Nao e desfecho (IsClosed=false) e 95 supera os 90 de Acordo Verbal, o teto de negociacao. Fase nova foi recusada porque prob e forecast da origem discordam entre si -- ver migration 092'),
  ('Pending Payment',       'negociacao',  4, 'origem declara IsWon=false, IsClosed=false, prob 95, forecast Pipeline. Mesmo criterio de Pending Sale: pagamento pendente nao e venda declarada pela origem -- ver migration 092'),
  ('Processamento Interno', 'negociacao',  4, 'origem declara IsWon=false, IsClosed=false, prob 95, forecast Pipeline. Mesmo criterio de Pending Sale -- ver migration 092'),
  ('Projeto para o Futuro', 'qualificacao',2, 'origem declara prob 20, forecast Pipeline, ativo. 20 e a mesma probabilidade de Avaliacao e abaixo de Coleta de Cenario (30), ambas ja em qualificacao -- ver migration 092'),
  ('Lista',                 NULL,       NULL, 'FORA DO FUNIL DE PROPOSITO: origem declara IsActive=false, DefaultProbability=NULL, forecast Omitted. Estagio inativo e sem probabilidade nao e etapa de funil e nao deve entrar em denominador de taxa. As 4 oportunidades tem amount 0,00 e a mesma data de criacao (2026-08-04), assinatura de carga de lista -- ver migration 092')
ON CONFLICT (stage_name) DO NOTHING;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A INGESTÃO PASSA A TRAZER A DECLARAÇÃO
-- ═════════════════════════════════════════════════════════════════════════════
-- Função reemitida INTEIRA (mesmo procedimento das 081 e 090), a partir da
-- definição que estava em produção nesta data, com um único bloco novo:
-- `OpportunityStage`, ANTES de `Opportunity`.
--
-- O SOQL do n8n (n8n/crm-ingest-salesforce.json) já pede o objeto novo. O
-- payload em stg_salesforce é o registro cru, então o mapeamento lê `ApiName`,
-- `MasterLabel`, `IsWon`, `IsClosed`, `DefaultProbability`,
-- `ForecastCategoryName`, `SortOrder` e `IsActive` direto do jsonb.
--
-- SEM ZERAR WATERMARK: `OpportunityStage` não tem filtro por SystemModstamp,
-- então a próxima execução do n8n traz os 114 estágios sozinha. As watermarks
-- de Lead e Opportunity ficam onde estão.
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

GRANT SELECT ON opportunity_stage TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A CHECAGEM: O NOSSO JULGAMENTO CONTRA A DECLARAÇÃO DA ORIGEM
-- ═════════════════════════════════════════════════════════════════════════════
-- Este é o ponto da migration. Ter as duas tabelas lado a lado não serve de
-- nada se ninguém as cruzar; a fronteira entre "o que o CRM diz" e "o que nós
-- decidimos" só é útil quando a DISCORDÂNCIA é visível.
--
-- A view NÃO CORRIGE NADA. Julgamento humano pode legitimamente discordar da
-- probabilidade da origem -- `No-Show` traz prob 15 e está na nossa fase
-- `reuniao` porque um no-show É uma reunião que foi marcada, e essa é uma
-- decisão de produto defensável. O que não pode é a discordância ser invisível.
--
-- UMA LINHA POR ESTÁGIO MAPEADO, sempre, com um `diagnostico`. De propósito:
-- uma view que só devolvesse os problemas voltaria vazia tanto quando está
-- tudo certo quanto quando `opportunity_stage` está VAZIA -- e "vazio" viraria
-- falso verde. Aqui, tabela vazia produz 25 linhas de
-- 'estagio ausente da origem', que é impossível confundir com "sem problemas".
--
-- POR QUE A COMPARAÇÃO EXCLUI `is_closed`: a probabilidade de um desfecho não
-- é previsão, é fato -- `Ganho` traz 100 e `Perdido` traz 0. Comparar o 0 de
-- `Perdido` (ordem 5) com o 90 de `Acordo Verbal` (ordem 4) acusaria uma
-- inversão que não existe. O critério do corte vem da origem (`IsClosed`), não
-- do nosso rótulo de fase.
--
-- POR QUE `default_probability` E NÃO `sort_order`: SortOrder é ordem de
-- EXIBIÇÃO e os 114 estágios pertencem a processos de venda diferentes --
-- `Pending Payment` tem SortOrder 33, DEPOIS de `Ganho` (24), e isso não
-- significa nada sobre funil. A probabilidade é a única grandeza da origem
-- comparável entre processos.

CREATE OR REPLACE VIEW view_fase_vs_origem AS
WITH decl AS (
  SELECT
    f.stage_name,
    f.fase,
    f.ordem,
    f.motivo,
    os.api_name IS NOT NULL AS declarado_na_origem,
    os.is_active,
    os.is_won,
    os.is_closed,
    os.default_probability,
    os.forecast_category,
    os.sort_order
  FROM opportunity_stage_fase f
  LEFT JOIN opportunity_stage os ON os.api_name = f.stage_name
),
-- Para cada estágio, o estágio de uma fase ANTERIOR com a MAIOR probabilidade
-- que ainda assim supera a dele. LATERAL sem LEFT: linha só existe quando há
-- inversão de fato.
inversao AS (
  SELECT
    d.stage_name,
    e.stage_name          AS estagio_anterior,
    e.fase                AS fase_anterior,
    e.ordem               AS ordem_anterior,
    e.default_probability AS prob_anterior
  FROM decl d
  CROSS JOIN LATERAL (
    SELECT d2.stage_name, d2.fase, d2.ordem, d2.default_probability
    FROM decl d2
    WHERE d2.ordem IS NOT NULL
      AND d2.ordem < d.ordem
      AND d2.default_probability IS NOT NULL
      AND NOT coalesce(d2.is_closed, false)
      AND d2.default_probability > d.default_probability
    ORDER BY d2.default_probability DESC, d2.stage_name
    LIMIT 1
  ) e
  WHERE d.ordem IS NOT NULL
    AND d.default_probability IS NOT NULL
    AND NOT coalesce(d.is_closed, false)
)
SELECT
  d.stage_name,
  d.fase,
  d.ordem,
  d.default_probability,
  d.forecast_category,
  d.is_won,
  d.is_closed,
  d.is_active,
  d.sort_order,
  i.estagio_anterior,
  i.fase_anterior,
  i.prob_anterior,
  i.prob_anterior - d.default_probability AS inversao_pontos,
  CASE
    -- O mais grave: a nossa fase afirma um desfecho que a origem nega, ou nega
    -- um que ela afirma. É o erro que teria inventado 14 vendas.
    WHEN d.declarado_na_origem
     AND (coalesce(d.fase, '') = 'ganho') IS DISTINCT FROM coalesce(d.is_won, false)
      THEN 'desfecho divergente: nossa fase ganho vs origem is_won'
    WHEN d.declarado_na_origem
     AND (coalesce(d.fase, '') IN ('ganho', 'perdido')) IS DISTINCT FROM coalesce(d.is_closed, false)
      THEN 'desfecho divergente: nossa fase terminal vs origem is_closed'
    WHEN i.stage_name IS NOT NULL
      THEN 'inversao de probabilidade'
    WHEN NOT d.declarado_na_origem
      THEN 'estagio ausente da origem'
    WHEN d.fase IS NULL
      THEN 'fora do funil por decisao declarada'
    WHEN d.default_probability IS NULL
      THEN 'sem probabilidade declarada na origem'
    ELSE 'ok'
  END AS diagnostico,
  d.motivo
FROM decl d
LEFT JOIN inversao i ON i.stage_name = d.stage_name;

COMMENT ON VIEW view_fase_vs_origem IS
  'UMA LINHA POR ESTAGIO de opportunity_stage_fase, cruzando o NOSSO julgamento (fase, ordem) com a DECLARACAO da origem (opportunity_stage: is_won, is_closed, default_probability, forecast_category). NAO CORRIGE NADA -- expoe. `diagnostico` = desfecho divergente (o mais grave: nossa fase afirma ganho onde a origem diz is_won=false, ou o contrario) | inversao de probabilidade (fase mais avancada com probabilidade menor que a maior de uma fase anterior) | estagio ausente da origem | fora do funil por decisao declarada | sem probabilidade declarada na origem | ok. Devolve TODAS as linhas de proposito: uma view que so mostrasse problemas voltaria vazia tanto com tudo certo quanto com opportunity_stage VAZIA, e vazio viraria falso verde. Desfechos (is_closed=true) sao excluidos da comparacao de probabilidade porque 100 e 0 sao fato, nao previsao. Migration 092.';

GRANT SELECT ON view_fase_vs_origem TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. AVISO — agora com três categorias, não duas
-- ═════════════════════════════════════════════════════════════════════════════
-- A 079 avisava sobre estágio ausente da tabela. Depois da 092 há uma terceira
-- categoria: estágio PRESENTE e deliberadamente sem fase. As duas renderizam
-- igual na tela; só aqui dá para distinguir decisão de esquecimento.
DO $$
DECLARE v_desconhecidos text; v_declarados text;
BEGIN
  SELECT string_agg(DISTINCT o.stage_name, ', ') INTO v_desconhecidos
  FROM opportunity o
  LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  WHERE o.source_system = 'salesforce' AND f.stage_name IS NULL AND o.stage_name IS NOT NULL;

  SELECT string_agg(DISTINCT f.stage_name, ', ') INTO v_declarados
  FROM opportunity o
  JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  WHERE o.source_system = 'salesforce' AND f.fase IS NULL;

  IF v_desconhecidos IS NOT NULL THEN
    RAISE NOTICE 'Estagios DESCONHECIDOS (ninguem decidiu ainda, aparecem como "sem fase" na tela): %', v_desconhecidos;
  ELSE
    RAISE NOTICE 'Nenhum estagio desconhecido na base.';
  END IF;

  IF v_declarados IS NOT NULL THEN
    RAISE NOTICE 'Estagios FORA DO FUNIL POR DECISAO DECLARADA (motivo em opportunity_stage_fase.motivo): %', v_declarados;
  END IF;
END $$;
