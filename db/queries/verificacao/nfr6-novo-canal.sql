-- db/queries/verificacao/nfr6-novo-canal.sql
-- Subtask 6.9. NFR-6: acrescentar um canal de anúncio NOVO não pode exigir
-- nenhuma coluna nova no schema central (lead/opportunity/campaign/contact/
-- account) nem em ad_campaign. Esta asserção PROVA isso executando de
-- verdade: tira uma impressão digital das colunas do schema central, insere
-- um canal inédito (`tiktok_ads`, que não existe em nenhum lugar do código),
-- reconfere a impressão digital, e só então limpa o dado de teste.
--
-- Não é revisão visual de schema: é prova por execução. Se acrescentar um
-- canal exigisse ALTER TABLE, este arquivo falharia (o insert quebraria por
-- coluna faltando) em vez de passar silenciosamente.
--
-- Evidência real que motivou a forma desta asserção: em 2026-09-09 (subtask
-- 2.18) três canais reais — Meta Ads, Google Ads e LinkedIn Ads — foram
-- ingeridos pela primeira vez através de `stg_ads` → `ad_campaign` sem uma
-- única mudança de schema. `metricas jsonb` é o que absorve a diferença de
-- forma entre plataformas (cada uma tem seu próprio conjunto de métricas),
-- e é exatamente por isso que a coluna existe como jsonb e não como colunas
-- fixas por métrica (ver COMMENT em ad_campaign.metricas, migration 003).

-- ── Parte 1 — relatório humano: canais já ingeridos e a impressão digital
-- atual do schema central. ────────────────────────────────────────────────
SELECT source_system, plataforma, count(*) AS campanhas
FROM ad_campaign
GROUP BY source_system, plataforma
ORDER BY source_system;

SELECT table_name, count(*) AS colunas
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('lead', 'opportunity', 'campaign', 'contact', 'account', 'ad_campaign')
GROUP BY table_name
ORDER BY table_name;

-- ── Parte 2 — asserção por execução real. ────────────────────────────────
DO $$
DECLARE
  v_fingerprint_antes  text;
  v_fingerprint_depois text;
  v_canal_novo         text := 'tiktok_ads';
  v_source_id          text := 'NFR6-CANAL-NOVO-TESTE';
  v_inseridas          integer;
  v_canais_antes       integer;
  v_canais_depois      integer;
BEGIN
  -- Guarda: o canal de teste tem de ser realmente inédito, senão a prova
  -- não prova nada (estaria só reinserindo algo que já passou por aqui).
  IF EXISTS (SELECT 1 FROM ad_campaign WHERE source_system = v_canal_novo) THEN
    RAISE EXCEPTION 'NFR-6 inconclusivo: o canal de teste "%" já existe em ad_campaign — escolher um canal genuinamente inédito ou limpar resíduo de execução anterior.', v_canal_novo;
  END IF;

  -- Impressão digital ANTES: nome+tipo de toda coluna do schema central.
  SELECT md5(string_agg(table_name || '.' || column_name || ':' || data_type, ',' ORDER BY table_name, column_name))
  INTO v_fingerprint_antes
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('lead', 'opportunity', 'campaign', 'contact', 'account', 'ad_campaign');

  SELECT count(DISTINCT source_system) INTO v_canais_antes FROM ad_campaign;

  -- Insere o canal NOVO pelo MESMO caminho dos canais reais (stg_ads →
  -- ad_campaign), com um conjunto de métricas de forma DIFERENTE das outras
  -- plataformas de propósito (video_views/saves não existem em nenhum dos 3
  -- canais reais) — é justamente isso que testaria a necessidade de coluna
  -- nova se o desenho fosse rígido.
  INSERT INTO stg_ads (batch_id, source_system, object_type, payload, collected_at)
  VALUES (
    v_source_id, v_canal_novo, 'campaign',
    jsonb_build_object(
      'source_system', v_canal_novo,
      'source_id', v_source_id,
      'plataforma', 'TikTok Ads',
      'nome', 'NFR-6 canal novo (teste, apagado ao fim deste script)',
      'metricas', jsonb_build_object(
        'id', v_source_id,
        'name', 'NFR-6 canal novo (teste)',
        'spend', 0,
        'video_views', 1234,
        'saves', 56
      )
    ),
    now()
  );

  PERFORM fn_run_ingest_batch(v_source_id);

  SELECT count(*) INTO v_inseridas FROM ad_campaign WHERE source_system = v_canal_novo;
  IF v_inseridas <> 1 THEN
    RAISE EXCEPTION 'NFR-6 violado: canal novo "%" não foi ingerido pelo caminho existente (esperado 1 linha em ad_campaign, obtido %) — acrescentar um canal exigiu mais do que dado.', v_canal_novo, v_inseridas;
  END IF;

  SELECT count(DISTINCT source_system) INTO v_canais_depois FROM ad_campaign;
  IF v_canais_depois <> v_canais_antes + 1 THEN
    RAISE EXCEPTION 'NFR-6 inconclusivo: contagem de canais distintos não subiu exatamente 1 (antes %, depois %).', v_canais_antes, v_canais_depois;
  END IF;

  -- Impressão digital DEPOIS.
  SELECT md5(string_agg(table_name || '.' || column_name || ':' || data_type, ',' ORDER BY table_name, column_name))
  INTO v_fingerprint_depois
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('lead', 'opportunity', 'campaign', 'contact', 'account', 'ad_campaign');

  IF v_fingerprint_antes IS DISTINCT FROM v_fingerprint_depois THEN
    RAISE EXCEPTION 'NFR-6 violado: o schema central MUDOU ao acrescentar o canal "%" (impressão digital antes % != depois %).', v_canal_novo, v_fingerprint_antes, v_fingerprint_depois;
  END IF;

  -- Limpeza do dado de teste — o canal inédito não fica na base.
  DELETE FROM ad_campaign WHERE source_system = v_canal_novo;
  DELETE FROM stg_ads WHERE batch_id = v_source_id;
  DELETE FROM ingest_run WHERE object = 'ad_campaign' AND rows_source = 1 AND started_at > now() - interval '1 minute';

  IF EXISTS (SELECT 1 FROM ad_campaign WHERE source_system = v_canal_novo) THEN
    RAISE EXCEPTION 'NFR-6: limpeza do dado de teste FALHOU — canal "%" ainda presente em ad_campaign.', v_canal_novo;
  END IF;

  RAISE NOTICE 'NFR-6 OK: canal novo "%" ingerido pelo caminho existente, schema central inalterado (% colunas, impressão digital %), dado de teste removido.',
    v_canal_novo,
    (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('lead','opportunity','campaign','contact','account','ad_campaign')),
    v_fingerprint_antes;
END $$;
