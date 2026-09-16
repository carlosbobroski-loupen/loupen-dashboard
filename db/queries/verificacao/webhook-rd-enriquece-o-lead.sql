-- db/queries/verificacao/webhook-rd-enriquece-o-lead.sql
--
-- Asserção de COMPORTAMENTO para a migration 101: um evento que chega pelo
-- WEBHOOK do RD Station (stg_rdstation, object_type='ConversionEvent') com UTM
-- em `custom_fields` tem de virar linha em `lead` E evento em
-- `lead_conversion_event` com os UTM preenchidos.
--
-- Por que não basta procurar string no corpo da função: `last_conversion` aparece
-- 9 vezes no corpo MESMO SEM a 078 -- 9 é a base da 073. Procurar por ele dá
-- falso positivo e foi exatamente o erro que atrasou este conserto. Aqui a
-- ingestão acontece de verdade, pelo caminho real, e o teste olha as colunas.
--
-- ESTE ARQUIVO SABE FALHAR: rodado contra o corpo anterior à 101 (o que a 090
-- deixou), ele aborta com "o webhook não criou linha em `lead`" -- porque sem o
-- bloco da 078 o caminho do webhook escreve só em `contact`/`conversion_event`,
-- que não têm coluna de UTM.
--
-- NÃO ESCREVE NADA: tudo dentro de BEGIN/ROLLBACK, com a limpeza conferida no
-- fim (inclusive `ingest_run`), fora da transação.

BEGIN;

INSERT INTO stg_rdstation (batch_id, object_type, payload, collected_at)
VALUES ('teste-101-webhook-utm', 'ConversionEvent', jsonb_build_object(
  'uuid',           '00000000-0101-4101-8101-000000000101',
  'name',           'Lead de Teste 101',
  'company',        'Loupen (teste automatizado)',
  'email',          'teste101@exemplo.invalido',
  'personal_phone', '+55 11 90000-0101',
  'job_title',      'Analista de Teste',
  'created_at',     to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
  'tags',           jsonb_build_array('teste-101'),
  'custom_fields',  jsonb_build_object(
      'utm_source',         'facebook-teste-101',
      'utm_medium',         'paid-teste-101',
      'utm_campaign',       'campanha-teste-101',
      'utm_content',        'criativo-teste-101',
      'utm_term',           'termo-teste-101',
      'utm_id',             'AD-TESTE-101',
      'Mídia',              'Meta Ads (teste)',
      'Campanha de Origem', 'Campanha de Origem Teste 101',
      'Tamanho da Empresa', 'de 11 a 50'
  ),
  'first_conversion', jsonb_build_object('content', jsonb_build_object(
      'conversion_identifier', 'primeiro-toque-teste-101',
      'traffic_source',        'facebook-teste-101'
  )),
  'last_conversion', jsonb_build_object(
      'created_at', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
      'source',     'facebook-teste-101',
      'content',    jsonb_build_object(
          'Nome',           'Lead de Teste 101',
          'Empresa',        'Loupen (teste automatizado)',
          'email_lead',     'teste101@exemplo.invalido',
          'Telefone',       '+55 11 90000-0101',
          'Cargo',          'Analista de Teste',
          'identificador',  'ultimo-toque-teste-101',
          'event_type',     'CONVERSION',
          'traffic_source', 'facebook-teste-101'
      )
  )
), now());

-- Relatório humano: o que a ingestão reportou...
SELECT * FROM fn_run_ingest_batch('teste-101-webhook-utm');

-- ...o lead que deveria ter nascido...
SELECT source_id, nome, cargo, tamanho_empresa_bruto, origem_bruta
FROM lead
WHERE source_system = 'rd_station' AND source_id = '00000000-0101-4101-8101-000000000101';

-- ...e a atribuição de mídia paga, que é o motivo de tudo isto existir.
SELECT e.utm_source, e.utm_medium, e.utm_campaign, e.utm_content, e.utm_term, e.utm_id,
       e.midia, e.campanha_de_origem, e.atribuicao_status
FROM lead_conversion_event e
JOIN lead l ON l.id = e.lead_id
WHERE l.source_system = 'rd_station' AND l.source_id = '00000000-0101-4101-8101-000000000101';

-- Asserção.
DO $$
DECLARE v_lead_id bigint; v_utm text; v_utm_id text; v_camp text; v_n int;
BEGIN
  SELECT id INTO v_lead_id FROM lead
  WHERE source_system = 'rd_station' AND source_id = '00000000-0101-4101-8101-000000000101';

  IF v_lead_id IS NULL THEN
    RAISE EXCEPTION 'migration 101 VIOLADA: o webhook nao criou linha em `lead`. Sem o bloco da 078 ele escreve so em contact/conversion_event, que nao tem UTM -- e a regressao da 090 de volta.';
  END IF;

  SELECT count(*) INTO v_n FROM lead_conversion_event WHERE lead_id = v_lead_id;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'migration 101 VIOLADA: lead % existe mas nao gerou nenhum lead_conversion_event -- a atribuicao do webhook nao foi gravada', v_lead_id;
  END IF;

  SELECT utm_source, utm_id, campanha_de_origem INTO v_utm, v_utm_id, v_camp
  FROM lead_conversion_event WHERE lead_id = v_lead_id ORDER BY id DESC LIMIT 1;

  IF v_utm IS DISTINCT FROM 'facebook-teste-101'
     OR v_utm_id IS DISTINCT FROM 'AD-TESTE-101'
     OR v_camp IS DISTINCT FROM 'Campanha de Origem Teste 101' THEN
    RAISE EXCEPTION 'migration 101 VIOLADA: UTM do webhook nao chegou completo -- utm_source=%, utm_id=%, campanha_de_origem=% (esperado facebook-teste-101 / AD-TESTE-101 / Campanha de Origem Teste 101)',
      coalesce(v_utm,'NULL'), coalesce(v_utm_id,'NULL'), coalesce(v_camp,'NULL');
  END IF;

  RAISE NOTICE 'OK migration 101: webhook virou lead % com utm_source=%, utm_id=% (o ID do anuncio) e campanha_de_origem=%', v_lead_id, v_utm, v_utm_id, v_camp;
END $$;

ROLLBACK;

-- A limpeza é o próprio ROLLBACK, mas não se declara limpeza sem conferir.
SELECT
  (SELECT count(*) FROM lead          WHERE source_id = '00000000-0101-4101-8101-000000000101') AS lead_residual,
  (SELECT count(*) FROM stg_rdstation WHERE batch_id  = 'teste-101-webhook-utm')                AS staging_residual,
  (SELECT count(*) FROM contact       WHERE source_id = '00000000-0101-4101-8101-000000000101') AS contact_residual,
  (SELECT count(*) FROM ingest_run    WHERE started_at > now() - interval '2 minutes')          AS ingest_run_residual;

DO $$
DECLARE v_lead int; v_stg int; v_contact int; v_run int;
BEGIN
  SELECT count(*) INTO v_lead    FROM lead          WHERE source_id = '00000000-0101-4101-8101-000000000101';
  SELECT count(*) INTO v_stg     FROM stg_rdstation WHERE batch_id  = 'teste-101-webhook-utm';
  SELECT count(*) INTO v_contact FROM contact       WHERE source_id = '00000000-0101-4101-8101-000000000101';
  SELECT count(*) INTO v_run     FROM ingest_run    WHERE started_at > now() - interval '2 minutes';
  IF v_lead <> 0 OR v_stg <> 0 OR v_contact <> 0 OR v_run <> 0 THEN
    RAISE EXCEPTION 'assercao 101 deixou residuo: lead=%, stg_rdstation=%, contact=%, ingest_run=%', v_lead, v_stg, v_contact, v_run;
  END IF;
  RAISE NOTICE 'OK limpeza: nenhum residuo do teste 101 no banco (lead, staging, contact, ingest_run)';
END $$;
