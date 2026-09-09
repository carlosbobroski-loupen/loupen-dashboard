-- db/queries/verificacao/integracao-ingestao.sql
-- Subtask 2.20, metade de DADO. Cobre os itens de §6.2 expressáveis em SQL:
--   AC-9.1  — todo registro COM source_system/fonte e collected_at
--             preenchidos (schema-provenance.sql verifica a forma; aqui é
--             o dado)
--   P-ING-1 — rodar a MESMA ingestão duas vezes não duplica nem corrompe
--             a contagem
--   P-ING-2 — watermark incremental existe e só avança em execução íntegra
--   EC-8 /
--   AC-9.2  — fonte indisponível registra a lacuna com fonte e horário, e
--             o último dado válido mantém sua idade real (NUNCA substituído
--             por zero)
--
-- P-ING-1 e P-ING-2 são testados por EXECUÇÃO REAL (insere, roda duas
-- vezes, compara, limpa) — não por leitura do código da função. O batch de
-- teste usa um source_system inédito (`__teste_ping__`) para nunca tocar
-- dado real.

-- ── Parte 1 — relatório humano. ──────────────────────────────────────────
SELECT source, object, last_run_at, rows_source, rows_target
FROM sync_state
ORDER BY source, object;

SELECT source, object, status, count(*) AS execucoes,
       max(started_at) AS mais_recente
FROM ingest_run
GROUP BY source, object, status
ORDER BY source, object, status;

-- ── Parte 2 — asserções. ─────────────────────────────────────────────────

-- (a) AC-9.1 no DADO: nenhuma linha de tabela ingerida com proveniência ou
-- collected_at nulos. Percorre dinamicamente as tabelas ingeridas que de
-- fato existem, para não precisar manter uma lista de SELECTs à mão.
DO $$
DECLARE
  v_ingeridas text[] := ARRAY[
    'account', 'ad_campaign', 'automation_workflow', 'campaign', 'contact',
    'conversion_event', 'lead', 'marketing_asset', 'opportunity', 'owner',
    'lead_touchpoint', 'lead_funnel_stage_event',
    'stg_ads', 'stg_rdstation', 'stg_salesforce', 'stg_sheets'
  ];
  r RECORD;
  v_col_prov text;
  v_nulos bigint;
  v_ofensoras text := '';
BEGIN
  FOR r IN
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
      AND t.table_name = ANY(v_ingeridas)
    ORDER BY t.table_name
  LOOP
    SELECT c.column_name INTO v_col_prov
    FROM information_schema.columns c
    WHERE c.table_schema = 'public' AND c.table_name = r.table_name
      AND c.column_name IN ('source_system', 'fonte')
    ORDER BY c.column_name
    LIMIT 1;

    EXECUTE format(
      'SELECT count(*) FROM %I WHERE %I IS NULL OR %I = '''' OR collected_at IS NULL',
      r.table_name, v_col_prov, v_col_prov
    ) INTO v_nulos;

    IF v_nulos > 0 THEN
      v_ofensoras := v_ofensoras || format('%s(%s linhas) ', r.table_name, v_nulos);
    END IF;
  END LOOP;

  IF v_ofensoras <> '' THEN
    RAISE EXCEPTION 'AC-9.1 violado (dado): linha(s) sem proveniência ou sem collected_at em: %', v_ofensoras;
  END IF;
  RAISE NOTICE 'AC-9.1 OK (dado): nenhuma linha sem proveniência/collected_at nas tabelas ingeridas.';
END $$;

-- (b) P-ING-1 — reexecução idempotente, testada de verdade.
--
-- CUIDADO NÃO ÓBVIO (bug real cometido e corrigido ao escrever isto):
-- fn_run_ingest_batch registra o watermark sob os literais FIXOS
-- 'ads'/'ad_campaign', independente do source_system do payload. Então
-- qualquer batch de teste que passe pela função SOBRESCREVE o watermark
-- REAL de ads/ad_campaign. A primeira versão desta asserção fez exatamente
-- isso (trocou 33/33 por 1/1) e depois apagou a linha na limpeza,
-- destruindo o watermark de produção. Por isso o bloco abaixo SALVA e
-- RESTAURA a linha real de sync_state em volta do teste.
DO $$
DECLARE
  v_batch text := '__teste_ping1__';
  v_ss    text := '__teste_ping__';
  v_apos_1 bigint;
  v_apos_2 bigint;
  v_ingest_runs integer;
  v_wm_existia boolean;
  v_wm_last_run timestamptz;
  v_wm_rows_source integer;
  v_wm_rows_target integer;
BEGIN
  -- SALVA o watermark real que a função vai sobrescrever.
  SELECT true, last_run_at, rows_source, rows_target
  INTO v_wm_existia, v_wm_last_run, v_wm_rows_source, v_wm_rows_target
  FROM sync_state WHERE source = 'ads' AND object = 'ad_campaign';
  v_wm_existia := COALESCE(v_wm_existia, false);

  -- Limpa resíduo de execução anterior interrompida.
  DELETE FROM ad_campaign WHERE source_system = v_ss;
  DELETE FROM stg_ads WHERE batch_id = v_batch;

  INSERT INTO stg_ads (batch_id, source_system, object_type, payload, collected_at)
  VALUES (v_batch, v_ss, 'campaign',
    jsonb_build_object(
      'source_system', v_ss, 'source_id', 'PING1-A', 'plataforma', 'Teste P-ING-1',
      'nome', 'teste idempotencia', 'metricas', jsonb_build_object('spend', 10)),
    now());

  PERFORM fn_run_ingest_batch(v_batch);
  SELECT count(*) INTO v_apos_1 FROM ad_campaign WHERE source_system = v_ss;

  -- MESMO batch_id, segunda vez.
  PERFORM fn_run_ingest_batch(v_batch);
  SELECT count(*) INTO v_apos_2 FROM ad_campaign WHERE source_system = v_ss;

  IF v_apos_1 <> 1 THEN
    RAISE EXCEPTION 'P-ING-1 inconclusivo: primeira execução deveria gravar 1 linha, gravou %.', v_apos_1;
  END IF;
  IF v_apos_2 <> v_apos_1 THEN
    RAISE EXCEPTION 'P-ING-1 violado: reexecutar o MESMO batch duplicou dado (% linhas depois da 1a, % depois da 2a).', v_apos_1, v_apos_2;
  END IF;

  -- A contagem reportada não pode ter sido corrompida: as duas execuções
  -- devem ter reportado rows_source = rows_target (status ok).
  SELECT count(*) INTO v_ingest_runs
  FROM ingest_run
  WHERE object = 'ad_campaign' AND started_at > now() - interval '2 minutes'
    AND rows_source = 1 AND rows_target = 1 AND status = 'ok';
  IF v_ingest_runs < 2 THEN
    RAISE EXCEPTION 'P-ING-1 violado: esperadas 2 execuções reportando 1/1 ok, encontradas %.', v_ingest_runs;
  END IF;

  -- Limpeza.
  DELETE FROM ad_campaign WHERE source_system = v_ss;
  DELETE FROM stg_ads WHERE batch_id = v_batch;
  DELETE FROM ingest_run WHERE object = 'ad_campaign' AND rows_source = 1 AND rows_target = 1
    AND started_at > now() - interval '2 minutes';

  -- RESTAURA o watermark real ao estado exato de antes do teste.
  IF v_wm_existia THEN
    INSERT INTO sync_state (source, object, last_run_at, rows_source, rows_target)
    VALUES ('ads', 'ad_campaign', v_wm_last_run, v_wm_rows_source, v_wm_rows_target)
    ON CONFLICT (source, object) DO UPDATE SET
      last_run_at = EXCLUDED.last_run_at,
      rows_source = EXCLUDED.rows_source,
      rows_target = EXCLUDED.rows_target;
  ELSE
    -- Não existia antes do teste: o próprio teste criou. Remove, para não
    -- deixar um watermark falso de 1/1 no lugar de nenhum.
    DELETE FROM sync_state WHERE source = 'ads' AND object = 'ad_campaign';
  END IF;

  IF EXISTS (SELECT 1 FROM ad_campaign WHERE source_system = v_ss) THEN
    RAISE EXCEPTION 'P-ING-1: limpeza do dado de teste FALHOU.';
  END IF;
  RAISE NOTICE 'P-ING-1 OK: reexecutar o mesmo batch não duplicou (1 linha nas duas vezes) e as duas execuções reportaram 1/1 ok. Dado de teste removido; watermark real restaurado (existia antes do teste: %).', v_wm_existia;
END $$;

-- (c) P-ING-2 — watermark existe e SÓ avança em execução íntegra.
DO $$
DECLARE
  v_src text := '__teste_ping2__';
  v_obj text := 'watermark';
  v_t_ok    timestamptz;
  v_t_depois timestamptz;
BEGIN
  DELETE FROM sync_state WHERE source = v_src;
  DELETE FROM ingest_run WHERE source = v_src;

  -- Execução íntegra: o watermark tem de ser criado.
  PERFORM fn_registrar_ingest(v_src, v_obj, 10, 10, 'ok', NULL);
  SELECT last_run_at INTO v_t_ok FROM sync_state WHERE source = v_src AND object = v_obj;
  IF v_t_ok IS NULL THEN
    RAISE EXCEPTION 'P-ING-2 violado: execução ok NÃO criou watermark em sync_state.';
  END IF;

  PERFORM pg_sleep(0.05);

  -- Execução PARCIAL: o watermark NÃO pode avançar. Se avançasse, a próxima
  -- consulta de delta começaria depois de registros nunca ingeridos — perda
  -- silenciosa de dado (EC-6, o defeito que originou esta epic).
  PERFORM fn_registrar_ingest(v_src, v_obj, 99, 5, 'partial', 'teste P-ING-2');
  SELECT last_run_at INTO v_t_depois FROM sync_state WHERE source = v_src AND object = v_obj;
  IF v_t_depois IS DISTINCT FROM v_t_ok THEN
    RAISE EXCEPTION 'P-ING-2 violado: watermark AVANÇOU numa execução parcial (de % para %) — o delta seguinte pularia registros nunca ingeridos.', v_t_ok, v_t_depois;
  END IF;

  -- Mas a execução parcial TEM de estar registrada em ingest_run.
  IF NOT EXISTS (SELECT 1 FROM ingest_run WHERE source = v_src AND status = 'partial') THEN
    RAISE EXCEPTION 'P-ING-2/INV-2 violado: execução parcial não foi registrada em ingest_run — falha silenciosa.';
  END IF;

  DELETE FROM sync_state WHERE source = v_src;
  DELETE FROM ingest_run WHERE source = v_src;
  RAISE NOTICE 'P-ING-2 OK: watermark criado em execução ok e NÃO avançado em execução parcial (parcial registrada em ingest_run). Dado de teste removido.';
END $$;

-- (d) EC-8 / AC-9.2 — fonte indisponível registra a lacuna com fonte e
-- horário, e o último dado válido mantém sua idade real.
DO $$
DECLARE
  v_src text := '__teste_ec8__';
  v_obj text := 'fonte_indisponivel';
  v_t_valido timestamptz;
  v_t_apos   timestamptz;
  v_rows_valido integer;
  v_rows_apos   integer;
BEGIN
  DELETE FROM sync_state WHERE source = v_src;
  DELETE FROM ingest_run WHERE source = v_src;

  -- Último dado válido.
  PERFORM fn_registrar_ingest(v_src, v_obj, 500, 500, 'ok', NULL);
  SELECT last_run_at, rows_target INTO v_t_valido, v_rows_valido
  FROM sync_state WHERE source = v_src AND object = v_obj;

  PERFORM pg_sleep(0.05);

  -- Fonte cai: registra falha com fonte e horário.
  PERFORM fn_registrar_ingest(v_src, v_obj, 0, 0, 'failed', 'EC-8 teste: fonte indisponível');

  -- A lacuna tem de estar registrada COM fonte e horário.
  IF NOT EXISTS (
    SELECT 1 FROM ingest_run
    WHERE source = v_src AND status = 'failed'
      AND error_message IS NOT NULL AND started_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'EC-8/AC-9.2 violado: fonte indisponível não registrou a lacuna com fonte, horário e motivo.';
  END IF;

  -- E o último dado válido tem de manter sua IDADE REAL — nem apagado, nem
  -- zerado, nem com timestamp renovado (que faria dado velho parecer novo).
  SELECT last_run_at, rows_target INTO v_t_apos, v_rows_apos
  FROM sync_state WHERE source = v_src AND object = v_obj;

  IF v_t_apos IS NULL THEN
    RAISE EXCEPTION 'EC-8/AC-9.2 violado: o último dado válido foi APAGADO quando a fonte caiu.';
  END IF;
  IF v_t_apos IS DISTINCT FROM v_t_valido THEN
    RAISE EXCEPTION 'EC-8/AC-9.2 violado: o timestamp do último dado válido foi RENOVADO (% -> %) — dado velho passaria por novo.', v_t_valido, v_t_apos;
  END IF;
  IF v_rows_apos IS DISTINCT FROM v_rows_valido THEN
    RAISE EXCEPTION 'EC-8/AC-9.2 violado: a contagem do último dado válido foi substituída (% -> %) — provavelmente por zero.', v_rows_valido, v_rows_apos;
  END IF;

  DELETE FROM sync_state WHERE source = v_src;
  DELETE FROM ingest_run WHERE source = v_src;
  RAISE NOTICE 'EC-8/AC-9.2 OK: fonte indisponível registrou a lacuna (fonte+horário+motivo) e o último dado válido manteve idade e contagem reais (% linhas, %). Dado de teste removido.', v_rows_valido, v_t_valido;
END $$;
