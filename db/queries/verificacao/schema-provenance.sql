-- db/queries/verificacao/schema-provenance.sql
-- Subtask 2.20, metade de SCHEMA de AC-9.1: todo registro tem de ter
-- `source_system` (ou `fonte`) e um timestamp de coleta. Este arquivo
-- verifica a FORMA (as colunas existem?); integracao-ingestao.sql verifica
-- o DADO (estão preenchidas?).
--
-- DESENHO DELIBERADO — MUNDO FECHADO: as tabelas são particionadas em duas
-- listas explícitas (ingeridas x isentas). Uma tabela que não esteja em
-- NENHUMA das duas faz a asserção FALHAR. Isso é o ponto: acrescentar uma
-- tabela nova ao schema força uma DECISÃO consciente ("isso é dado ingerido
-- de fonte externa, ou é derivado/catálogo/infra?"), em vez de escapar por
-- omissão. Uma verificação de mundo aberto (só "as ingeridas têm as
-- colunas?") passaria silenciosamente ao alguém criar amanhã uma tabela
-- ingerida sem proveniência — que é exatamente o modo de falha que AC-9.1
-- existe para impedir.

-- ── Parte 1 — relatório humano: quem tem o que. ──────────────────────────
SELECT
  t.table_name,
  bool_or(c.column_name = 'source_system') AS tem_source_system,
  bool_or(c.column_name = 'fonte')         AS tem_fonte,
  bool_or(c.column_name = 'collected_at')  AS tem_collected_at
FROM information_schema.tables t
JOIN information_schema.columns c
  ON c.table_schema = t.table_schema AND c.table_name = t.table_name
WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
GROUP BY t.table_name
ORDER BY t.table_name;

-- ── Parte 2 — asserção. ──────────────────────────────────────────────────
DO $$
DECLARE
  -- Tabelas que guardam dado COPIADO de fonte externa. Estas TÊM de ter
  -- proveniência + timestamp de coleta.
  v_ingeridas text[] := ARRAY[
    'account', 'ad_campaign', 'automation_workflow', 'campaign', 'contact',
    'conversion_event', 'lead', 'marketing_asset', 'opportunity', 'owner',
    'lead_touchpoint', 'lead_funnel_stage_event',
    'stg_ads', 'stg_rdstation', 'stg_salesforce', 'stg_sheets'
  ];
  -- Tabelas ISENTAS, cada uma por um motivo real (não por conveniência):
  --   catálogo/vocabulário .. attribution_ruleset, channel_source,
  --                           funnel_stage, leadsource_crosswalk
  --   derivada no próprio banco (proveniência é do registro de origem, não
  --   desta linha) .......... identity_candidate, identity_edge, person,
  --                           lead_origin_classification
  --   infra de ingestão (é o próprio registro de proveniência) ...........
  --                           ingest_run, sync_state, schema_migrations
  v_isentas text[] := ARRAY[
    'attribution_ruleset', 'channel_source', 'funnel_stage', 'leadsource_crosswalk',
    'identity_candidate', 'identity_edge', 'person', 'lead_origin_classification',
    'ingest_run', 'sync_state', 'schema_migrations'
  ];
  v_sem_proveniencia text;
  v_sem_coleta       text;
  v_nao_classificada text;
  v_usam_fonte       text;
BEGIN
  -- (a) Toda tabela ingerida tem proveniência (source_system OU fonte).
  SELECT string_agg(t.table_name, ', ' ORDER BY t.table_name) INTO v_sem_proveniencia
  FROM information_schema.tables t
  WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
    AND t.table_name = ANY(v_ingeridas)
    AND NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.table_name = t.table_name
        AND c.column_name IN ('source_system', 'fonte')
    );
  IF v_sem_proveniencia IS NOT NULL THEN
    RAISE EXCEPTION 'AC-9.1 violado (schema): tabela(s) ingerida(s) SEM coluna de proveniência (source_system/fonte): %', v_sem_proveniencia;
  END IF;

  -- (b) Toda tabela ingerida tem timestamp de coleta.
  SELECT string_agg(t.table_name, ', ' ORDER BY t.table_name) INTO v_sem_coleta
  FROM information_schema.tables t
  WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
    AND t.table_name = ANY(v_ingeridas)
    AND NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.table_name = t.table_name
        AND c.column_name = 'collected_at'
    );
  IF v_sem_coleta IS NOT NULL THEN
    RAISE EXCEPTION 'AC-9.1 violado (schema): tabela(s) ingerida(s) SEM collected_at: %', v_sem_coleta;
  END IF;

  -- (c) MUNDO FECHADO: nenhuma tabela fora das duas listas. Partições de
  -- conversion_event (conversion_event_*) herdam a classificação da mãe.
  SELECT string_agg(t.table_name, ', ' ORDER BY t.table_name) INTO v_nao_classificada
  FROM information_schema.tables t
  WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
    AND NOT (t.table_name = ANY(v_ingeridas))
    AND NOT (t.table_name = ANY(v_isentas))
    AND t.table_name NOT LIKE 'conversion\_event\_%';
  IF v_nao_classificada IS NOT NULL THEN
    RAISE EXCEPTION 'AC-9.1 indeterminado: tabela(s) nova(s) não classificada(s) como ingerida NEM isenta: %. Decidir explicitamente e acrescentar a uma das duas listas deste arquivo — não deixar escapar por omissão.', v_nao_classificada;
  END IF;

  -- (d) Inconsistência de nomenclatura REAL, reportada e não escondida:
  -- duas tabelas usam `fonte` (português) para a mesma semântica de
  -- `source_system`. Não falha (as duas são proveniência válida), mas fica
  -- visível — se ficasse silencioso, uma consulta que filtra por
  -- source_system esqueceria essas duas tabelas sem ninguém notar.
  SELECT string_agg(DISTINCT c.table_name, ', ' ORDER BY c.table_name) INTO v_usam_fonte
  FROM information_schema.columns c
  WHERE c.table_schema = 'public' AND c.column_name = 'fonte'
    AND c.table_name = ANY(v_ingeridas);
  IF v_usam_fonte IS NOT NULL THEN
    RAISE NOTICE 'AC-9.1 ATENÇÃO (não é falha): tabela(s) % usam `fonte` em vez de `source_system` para a mesma semântica. Consultas que filtram por source_system NÃO cobrem essas tabelas.', v_usam_fonte;
  END IF;

  RAISE NOTICE 'AC-9.1 OK (schema): % tabela(s) ingerida(s) com proveniência e collected_at; % isenta(s) por motivo documentado; nenhuma tabela não classificada.',
    (SELECT count(*) FROM information_schema.tables t WHERE t.table_schema='public' AND t.table_type='BASE TABLE' AND t.table_name = ANY(v_ingeridas)),
    (SELECT count(*) FROM information_schema.tables t WHERE t.table_schema='public' AND t.table_type='BASE TABLE' AND t.table_name = ANY(v_isentas));
END $$;
