-- db/queries/verificacao/ingestao-rd-leads.sql
-- Prova por EXECUÇÃO as seções RDLead e LeadConversion de fn_run_ingest_batch
-- v9 (migrations 045/046/047/048).
--
-- Uso:
--   set -a; source .env; set +a
--   psql "$NEON_DATABASE_URL" -f db/queries/verificacao/ingestao-rd-leads.sql
--
-- ── POR QUE ESTE ARQUIVO RODA DENTRO DE BEGIN ... ROLLBACK ────────────────
-- Numa sessão anterior deste projeto eu DESTRUÍ o watermark de produção com
-- uma asserção minha: `fn_run_ingest_batch` registra em sync_state por
-- (source, object), e um lote "de nome único" sobrescreveu o registro real de
-- ads (33/33 → 1/1); a limpeza manual depois o apagou de vez. Só descobri
-- porque fui olhar o estado do banco DEPOIS da limpeza em vez de confiar no
-- "OK" que a query imprimiu.
--
-- ROLLBACK elimina a classe inteira desse erro: nada do que este arquivo faz
-- sobrevive, inclusive as escritas em sync_state e ingest_run. Não existe
-- passo de limpeza que possa dar errado, porque não existe limpeza.
--
-- A asserção final compara o watermark de ads antes e depois justamente para
-- provar que o isolamento funcionou.
--
-- Dados abaixo são SINTÉTICOS. Este repositório é público e já teve incidente
-- real de vazamento de PII — nenhum nome, e-mail ou telefone de lead real
-- pode entrar aqui.
--
-- CUIDADO ESPECÍFICO COM O E-MAIL DE TESTE: a regra de dado de teste casa
-- contra `^(ana|joao|maria|carla|pedro)[0-9]{3}@gmail\.com$`, então exercitá-la
-- exige um endereço nessa forma.
--
-- A primeira versão deste arquivo usava um endereço nessa forma que eu havia
-- copiado da listagem de contatos da API — ou seja, um endereço REALMENTE
-- PRESENTE na base de produção. Parece sintético (alguém testou formulário em
-- rajada), mas está lá, e portanto é endereço de alguém dentro do nosso
-- sistema. Não pode ir para repositório público, e não vou repeti-lo nem aqui
-- no comentário.
--
-- `ana000@gmail.com` abaixo é fabricado, com dígitos escolhidos justamente
-- por NÃO corresponderem a nenhum dos endereços observados na base. Serve só
-- para exercitar a forma da regex.
--
-- Regra geral que fica: valor de teste tem de ser INVENTADO, nunca copiado de
-- uma resposta de API — mesmo quando o valor copiado parece falso.

\pset pager off
\set ON_ERROR_STOP on

BEGIN;

-- Watermarks ANTES, para as asserções 6 e 9.
--
-- Snapshot em vez de valor absoluto porque a primeira versão da asserção 9
-- checava `count(*) = 0` para rd_station/LeadConversion — o que passou
-- enquanto a ingestão real não existia e passou a FALHAR depois, quando as
-- cargas de produção criaram o watermark legitimamente. A asserção estava
-- medindo estado global em vez do efeito DESTE teste. É o terceiro erro do
-- mesmo tipo neste arquivo, e o padrão agora está claro: asserção tem de
-- comparar o antes com o depois, nunca presumir um valor absoluto do banco.
CREATE TEMP TABLE _ads_antes AS
SELECT rows_source, rows_target FROM sync_state WHERE source = 'ads' AND object = 'ad_campaign';

CREATE TEMP TABLE _lc_antes AS
SELECT rows_source, rows_target, last_run_at
FROM sync_state WHERE source = 'rd_station' AND object = 'LeadConversion';

-- ---------------------------------------------------------------------------
-- Cenário. Três leads que cobrem os três caminhos que importam:
--   L1  legítimo, com tags/cargo/tamanho preenchidos
--   L2  e-mail sintético → deve ser marcado por regra de e-mail
--   L3  legítimo no cadastro, mas com UTM de teste no EVENTO → deve ser
--       escalado a is_teste pela seção LeadConversion
-- ---------------------------------------------------------------------------
INSERT INTO stg_rdstation (batch_id, object_type, payload, collected_at) VALUES
('verif-rd-001', 'RDLead', '{
   "uuid": "verif-uuid-L1", "name": "Lead Um Sintetico", "email": "l1@exemplo-sintetico.test",
   "empresa": "Empresa Um", "job_title": "Diretor Comercial",
   "cf_tamanho_da_empresa": "100 a 249 funcionários", "cf_falou_com": "Monica",
   "tags": ["webinar", "quente"], "created_at": "2026-06-01T10:00:00-03:00",
   "origem_primeira_conversao": "Webinar-Sintetico-01"
 }'::jsonb, now()),
('verif-rd-001', 'RDLead', '{
   "uuid": "verif-uuid-L2", "name": "Lead Dois Sintetico", "email": "ana000@gmail.com",
   "job_title": "Gerente", "cf_tamanho_da_empresa": "1 a 19 funcionários",
   "tags": ["importado"], "created_at": "2026-09-04T22:00:00-03:00",
   "origem_primeira_conversao": "Webinar-Sintetico-01"
 }'::jsonb, now()),
('verif-rd-001', 'RDLead', '{
   "uuid": "verif-uuid-L3", "name": "Lead Tres Sintetico", "email": "l3@exemplo-sintetico.test",
   "job_title": "CEO, Founder, Socio", "cf_tamanho_da_empresa": "1.000+ funcionários",
   "tags": ["formulario"], "created_at": "2026-07-15T08:00:00-03:00",
   "origem_primeira_conversao": "Rescue-Sintetico-02"
 }'::jsonb, now());

-- Eventos de conversão. Note o par L1 com occurred_at IDÊNTICO: é a duplicata
-- de fonte real observada (mesmo lead, mesma origem, mesmo instante ao
-- segundo, diferindo só na codificação de um acento na URL). Tem de colapsar
-- para UMA linha — data-contract.md §1.7.
INSERT INTO stg_rdstation (batch_id, object_type, payload, collected_at) VALUES
('verif-rd-001', 'LeadConversion', '{
   "contact_uuid": "verif-uuid-L1", "origem_conversao": "Webinar-Sintetico-01",
   "event_type": "CONVERSION", "occurred_at": "2026-06-01T10:00:00-03:00",
   "empresa_bruta": "Empresa Um", "cargo": "Gerente",
   "tamanho_empresa_bruto": "50 a 99 funcionários",
   "primeiro_toque_bruto": "(none)",
   "ultimo_toque_bruto": "utm_source=instagram&utm_medium=cpc",
   "utm_source": "instagram", "utm_medium": "cpc", "utm_campaign": "Campanha Sintetica A",
   "midia": "Instagram"
 }'::jsonb, now()),
('verif-rd-001', 'LeadConversion', '{
   "contact_uuid": "verif-uuid-L1", "origem_conversao": "Webinar-Sintetico-01",
   "event_type": "CONVERSION", "occurred_at": "2026-06-01T10:00:00-03:00",
   "empresa_bruta": "Empresa Um", "cargo": "Gerente",
   "tamanho_empresa_bruto": "50 a 99 funcionários",
   "primeiro_toque_bruto": "(none)",
   "ultimo_toque_bruto": "utm_source=instagram&utm_medium=cpc&utm_content=conte%C3%BAdo",
   "utm_source": "instagram", "utm_medium": "cpc", "utm_campaign": "Campanha Sintetica A",
   "midia": "Instagram"
 }'::jsonb, now()),
-- Segunda conversão de L1, instante diferente: NÃO é duplicata, tem de entrar.
('verif-rd-001', 'LeadConversion', '{
   "contact_uuid": "verif-uuid-L1", "origem_conversao": "Rescue-Sintetico-02",
   "event_type": "CONVERSION", "occurred_at": "2026-08-10T14:30:00-03:00",
   "cargo": "Diretor Comercial", "tamanho_empresa_bruto": "100 a 249 funcionários",
   "primeiro_toque_bruto": "utm_source=instagram&utm_medium=cpc",
   "ultimo_toque_bruto": "(none)"
 }'::jsonb, now()),
-- L3: UTM literalmente com o nome do campo → regra de teste no evento.
('verif-rd-001', 'LeadConversion', '{
   "contact_uuid": "verif-uuid-L3", "origem_conversao": "Rescue-Sintetico-02",
   "event_type": "CONVERSION", "occurred_at": "2026-07-15T08:00:00-03:00",
   "primeiro_toque_bruto": "(none)", "ultimo_toque_bruto": "utm_source=fonte",
   "utm_source": "fonte", "utm_medium": "midia", "utm_campaign": "nome"
 }'::jsonb, now()),
-- Evento de contato que NÃO veio no lote de RDLead: tem de ser reportado como
-- `partial`, nunca descartado em silêncio.
('verif-rd-001', 'LeadConversion', '{
   "contact_uuid": "verif-uuid-ORFAO", "origem_conversao": "Webinar-Sintetico-01",
   "event_type": "CONVERSION", "occurred_at": "2026-06-05T09:00:00-03:00"
 }'::jsonb, now());

-- ---------------------------------------------------------------------------
-- Primeira execução
-- ---------------------------------------------------------------------------
SELECT '=== execucao 1 ===' AS bloco;
SELECT * FROM fn_run_ingest_batch('verif-rd-001');

-- ---------------------------------------------------------------------------
-- Estado resultante
-- ---------------------------------------------------------------------------
SELECT '=== leads criados ===' AS bloco;
SELECT l.source_id, l.nome, l.cargo, fn_cargo_grupo(l.cargo) AS cargo_grupo,
       l.tamanho_empresa_bruto, fn_normalizar_tamanho_empresa(l.tamanho_empresa_bruto) AS faixa,
       l.atendido_por, l.tags, l.is_teste, l.teste_regra
FROM lead l WHERE l.source_system = 'rd_station' AND l.source_id LIKE 'verif-uuid-%'
ORDER BY l.source_id;

SELECT '=== eventos de conversao ===' AS bloco;
SELECT l.source_id, e.origem_conversao, e.occurred_at, e.cargo,
       e.tamanho_empresa_bruto, e.tamanho_empresa, e.utm_campaign, e.midia
FROM lead_conversion_event e JOIN lead l ON l.id = e.lead_id
WHERE l.source_id LIKE 'verif-uuid-%'
ORDER BY l.source_id, e.occurred_at;

-- ---------------------------------------------------------------------------
-- Segunda execução do MESMO lote: idempotência
-- ---------------------------------------------------------------------------
SELECT '=== execucao 2 (mesmo lote) ===' AS bloco;
SELECT * FROM fn_run_ingest_batch('verif-rd-001');

-- ---------------------------------------------------------------------------
-- ASSERÇÕES
-- ---------------------------------------------------------------------------
SELECT '=== assercoes ===' AS bloco;

-- 1. Os 3 leads entraram.
SELECT CASE WHEN count(*) = 3 THEN 'ASSERCAO 1 OK: 3 leads do RD criados'
            ELSE '*** ASSERCAO 1 FALHOU: ' || count(*) || ' lead(s), esperado 3 ***' END AS r
FROM lead WHERE source_system = 'rd_station' AND source_id LIKE 'verif-uuid-%';

-- 2. Dedup: L1 tem 2 eventos (não 3) — o par de mesmo instante colapsou.
SELECT CASE WHEN count(*) = 2
            THEN 'ASSERCAO 2 OK: duplicata de mesmo instante colapsou (2 eventos, nao 3)'
            ELSE '*** ASSERCAO 2 FALHOU: L1 tem ' || count(*) || ' eventos, esperado 2 ***' END AS r
FROM lead_conversion_event e JOIN lead l ON l.id = e.lead_id
WHERE l.source_id = 'verif-uuid-L1';

-- 3. L2 marcado por regra de e-mail; L1 permanece legítimo.
SELECT CASE WHEN (SELECT is_teste FROM lead WHERE source_id = 'verif-uuid-L2')
             AND (SELECT teste_regra FROM lead WHERE source_id = 'verif-uuid-L2') = 'email sintetico sequencial'
             AND NOT (SELECT is_teste FROM lead WHERE source_id = 'verif-uuid-L1')
            THEN 'ASSERCAO 3 OK: L2 marcado por e-mail, L1 intacto'
            ELSE '*** ASSERCAO 3 FALHOU: marcacao por e-mail incorreta ***' END AS r;

-- 4. L3 escalado a teste pela UTM do EVENTO, não pelo cadastro.
SELECT CASE WHEN (SELECT is_teste FROM lead WHERE source_id = 'verif-uuid-L3')
             AND (SELECT teste_regra FROM lead WHERE source_id = 'verif-uuid-L3') = 'utm com nome do proprio campo'
            THEN 'ASSERCAO 4 OK: L3 escalado a teste pela utm do evento'
            ELSE '*** ASSERCAO 4 FALHOU: escalonamento por utm do evento nao ocorreu ***' END AS r;

-- 5. Evento órfão reportado como partial, com mensagem — nunca zero silencioso.
--    São 2 linhas porque este arquivo roda o lote DUAS vezes (teste de
--    idempotência), e cada execução reporta o próprio parcial. A primeira
--    versão desta asserção exigia exatamente 1 e falhou — o erro era da
--    asserção, não do código.
SELECT CASE WHEN count(*) = 2
            THEN 'ASSERCAO 5 OK: evento orfao reportado como partial com mensagem nas 2 execucoes'
            ELSE '*** ASSERCAO 5 FALHOU: esperado 2 relatos de parcial, encontrado ' || count(*) || ' ***' END AS r
FROM ingest_run
WHERE object = 'LeadConversion' AND status = 'partial'
  AND error_message LIKE '%sem lead resolvido%';

-- 6. O watermark real de ads NÃO foi tocado (o erro que já cometi).
SELECT CASE WHEN (SELECT rows_target FROM sync_state WHERE source='ads' AND object='ad_campaign')
                 = (SELECT rows_target FROM _ads_antes)
            THEN 'ASSERCAO 6 OK: watermark de ads intacto ('
                 || (SELECT rows_target FROM _ads_antes) || ')'
            ELSE '*** ASSERCAO 6 FALHOU: watermark de ads foi alterado pelo teste ***' END AS r;

-- 7. A firmografia do EVENTO difere da do cadastro — é o achado que justifica
--    a tabela existir. L1 tem cargo `Diretor Comercial` no cadastro e
--    `Gerente` no primeiro evento.
SELECT CASE WHEN (SELECT l.cargo FROM lead l WHERE l.source_id = 'verif-uuid-L1')
                 IS DISTINCT FROM
                 (SELECT e.cargo FROM lead_conversion_event e JOIN lead l ON l.id = e.lead_id
                  WHERE l.source_id = 'verif-uuid-L1' ORDER BY e.occurred_at LIMIT 1)
            THEN 'ASSERCAO 7 OK: firmografia do evento e do cadastro sao independentes'
            ELSE '*** ASSERCAO 7 FALHOU: evento e cadastro colapsaram no mesmo valor ***' END AS r;

-- 8. Watermark de RDLead criado — prova que fn_registrar_ingest está ativo e
--    que a regressão da 047 (que gravava só ingest_run) está corrigida.
SELECT CASE WHEN count(*) = 1
            THEN 'ASSERCAO 8 OK: sync_state gravado para RDLead (fn_registrar_ingest ativo, regressao da 047 corrigida)'
            ELSE '*** ASSERCAO 8 FALHOU: sync_state de RDLead nao gravado — a regressao da 047 voltou ***' END AS r
FROM sync_state WHERE source = 'rd_station' AND object = 'RDLead';

-- 9. E o watermark de LeadConversion NÃO avança, porque o lote ficou parcial.
--    Esta é a propriedade que mais importa travar: se o watermark avançasse
--    num lote parcial, os eventos órfãos seriam pulados para sempre na
--    próxima execução incremental e a perda seria silenciosa. A regra vem da
--    migration 044 ("watermark avança SOMENTE em execução íntegra") e esta
--    asserção é o que impede alguém de "consertar" isso sem perceber.
WITH depois AS (
  SELECT rows_source, rows_target, last_run_at
  FROM sync_state WHERE source = 'rd_station' AND object = 'LeadConversion'
)
SELECT CASE
  WHEN (SELECT count(*) FROM depois) = (SELECT count(*) FROM _lc_antes)
   AND NOT EXISTS (
     SELECT 1 FROM depois d FULL OUTER JOIN _lc_antes a
       USING (rows_source, rows_target, last_run_at)
     WHERE d.rows_source IS NULL OR a.rows_source IS NULL
   )
  THEN 'ASSERCAO 9 OK: lote parcial NAO mexeu no watermark de LeadConversion (regra da 044 intacta)'
  ELSE '*** ASSERCAO 9 FALHOU: o lote parcial alterou o watermark — eventos orfaos seriam pulados para sempre ***'
END AS r;

-- 10. Reclassificação de origem é idempotente. Os 3 leads recebem UMA versão
--     cada na execução 1; a execução 2 não cria versão nova porque o sinal
--     bruto não mudou (fn_reclassificar_lead retorna false e sai antes de
--     gravar). O que prova a idempotência é NENHUM lead ter version > 1 —
--     não a contagem total de linhas, que é 3 por haver 3 leads. A primeira
--     versão desta asserção contava o total e falhou por isso: o erro era da
--     asserção, e é o segundo do mesmo tipo neste arquivo.
SELECT CASE WHEN count(*) FILTER (WHERE loc.version > 1) = 0 AND count(*) = 3
            THEN 'ASSERCAO 10 OK: 3 leads com 1 versao cada — reexecucao nao reversiona'
            ELSE '*** ASSERCAO 10 FALHOU: ' || count(*) || ' linha(s), '
                 || count(*) FILTER (WHERE loc.version > 1)
                 || ' com version>1 — historico sendo inflado por execucao ***' END AS r
FROM lead_origin_classification loc
JOIN lead l ON l.id = loc.lead_id
WHERE l.source_id LIKE 'verif-uuid-%';

ROLLBACK;

-- Confirmação pós-rollback: nada sobreviveu.
SELECT CASE WHEN count(*) = 0
            THEN 'POS-ROLLBACK OK: nenhum lead sintetico sobreviveu'
            ELSE '*** POS-ROLLBACK FALHOU: ' || count(*) || ' lead(s) vazaram para o banco ***' END AS r
FROM lead WHERE source_id LIKE 'verif-uuid-%';

SELECT source, object, rows_source, rows_target FROM sync_state ORDER BY source, object;
