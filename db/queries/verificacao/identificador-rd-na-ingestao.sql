-- db/queries/verificacao/identificador-rd-na-ingestao.sql
--
-- Asserção de COMPORTAMENTO para a migration 099: um lead do Salesforce que
-- chega no staging com `Identificador_RD__c` tem de sair de `fn_run_ingest_batch`
-- com `lead.identificador_rd` PREENCHIDO.
--
-- Por que não basta procurar a string no corpo da função: um comentário com a
-- palavra `identificador_rd` satisfaria essa checagem sem que uma única linha
-- fosse gravada. A asserção aqui ingere de verdade, pelo caminho real
-- (stg_salesforce -> fn_run_ingest_batch), e olha a coluna.
--
-- ESTE ARQUIVO SABE FALHAR: rodado contra o corpo anterior à 099 (o da 092, que
-- perdeu o campo quando a 090 foi escrita sobre o arquivo da 073), ele aborta com
-- `identificador_rd veio NULL`. Foi assim que a regressão foi reproduzida antes
-- de ser corrigida.
--
-- NÃO ESCREVE NADA: tudo roda dentro de BEGIN/ROLLBACK, e a limpeza é conferida
-- no fim, fora da transação.

BEGIN;

INSERT INTO stg_salesforce (batch_id, object_type, payload, collected_at)
VALUES ('teste-099-identificador-rd', 'Lead', jsonb_build_object(
  'Id',                  '00Q0000000TESTE099',
  'Name',                'Lead de Teste 099',
  'Company',             'Loupen (teste automatizado)',
  'Email',               'teste099@exemplo.invalido',
  'Status',              'Novo',
  'LeadSource',          'SITE_Contato_Fale conosco',
  'Identificador_RD__c', 'TESTE-ID-RD-099',
  'CreatedDate',         to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF')
), now());

-- Relatório humano: o que a ingestão reportou...
SELECT * FROM fn_run_ingest_batch('teste-099-identificador-rd');

-- ...e o que de fato ficou gravado na coluna.
SELECT source_id, identificador_rd, (identificador_rd IS NULL) AS veio_null
FROM lead
WHERE source_system = 'salesforce' AND source_id = '00Q0000000TESTE099';

-- Asserção.
DO $$
DECLARE v_valor text; v_existe boolean;
BEGIN
  SELECT (count(*) > 0), max(identificador_rd) INTO v_existe, v_valor
  FROM lead WHERE source_system = 'salesforce' AND source_id = '00Q0000000TESTE099';

  IF NOT v_existe THEN
    RAISE EXCEPTION 'migration 099: o lead de teste nem chegou na tabela `lead` -- a ingestao do objeto Lead falhou antes da coluna';
  END IF;

  IF v_valor IS DISTINCT FROM 'TESTE-ID-RD-099' THEN
    RAISE EXCEPTION 'migration 099 VIOLADA: lead.identificador_rd = % (esperado TESTE-ID-RD-099). O payload trazia Identificador_RD__c e fn_run_ingest_batch nao gravou -- e a regressao da 090 de volta.',
      coalesce(v_valor, 'NULL');
  END IF;

  RAISE NOTICE 'OK migration 099: Identificador_RD__c do staging chegou em lead.identificador_rd como %', v_valor;
END $$;

ROLLBACK;

-- A limpeza é o próprio ROLLBACK, mas não se declara limpeza sem conferir:
-- as duas contagens abaixo TÊM de ser zero.
SELECT
  (SELECT count(*) FROM lead           WHERE source_id = '00Q0000000TESTE099')            AS lead_residual,
  (SELECT count(*) FROM stg_salesforce WHERE batch_id  = 'teste-099-identificador-rd')    AS staging_residual;

DO $$
DECLARE v_lead int; v_stg int;
BEGIN
  SELECT count(*) INTO v_lead FROM lead           WHERE source_id = '00Q0000000TESTE099';
  SELECT count(*) INTO v_stg  FROM stg_salesforce WHERE batch_id  = 'teste-099-identificador-rd';
  IF v_lead <> 0 OR v_stg <> 0 THEN
    RAISE EXCEPTION 'assercao 099 deixou residuo: % linha(s) em lead, % em stg_salesforce', v_lead, v_stg;
  END IF;
  RAISE NOTICE 'OK limpeza: nenhum residuo do teste 099 no banco';
END $$;
