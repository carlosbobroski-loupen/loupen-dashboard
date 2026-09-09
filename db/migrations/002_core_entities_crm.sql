-- db/migrations/002_core_entities_crm.sql
-- Subtask 2.4. Entidades canônicas de CRM (DM-1 lead, DM-2 contact,
-- DM-3 account, DM-4 opportunity, DM-11 owner).
--
-- CON-4 (normativo): record_type_name é o sinal de Produto/Serviço de
-- opportunity, NUNCA derivado de origem_bruta/LeadSource. amount é MRR,
-- nunca valor de contrato (ver feedback_mrr_vs_contrato_rule — valor de
-- contrato só é calculável quando stage_name='Ganho' E duracao_meses_contrato
-- é conhecida; esse CÁLCULO mora em função/view SQL de phase-3, não aqui).
-- account_id em opportunity é a chave de join lead→opportunity via
-- ConvertedAccountId — join NUNCA por LeadSource/origem_bruta.
--
-- AC-9.1: UNIQUE (source_system, source_id) em toda tabela de origem
-- externa — é o alvo do ON CONFLICT de P-ING-1 (upsert idempotente).
-- P6/§3.5: campos brutos preservados como vieram da origem (origem_bruta,
-- campanha_linkedin_bruta) — nenhuma transformação de atribuição acontece
-- aqui, isso é phase-3.
-- NFR-6: nenhuma coluna específica de canal de anúncio (ex.: "meta_ad_id")
-- nestas tabelas — campanha_linkedin_bruta é o nome real do campo de origem
-- (Salesforce Campanha_LinkedIn__c), preservado como veio, não reinterpretado.

CREATE TABLE IF NOT EXISTS owner (
  id            bigserial PRIMARY KEY,
  source_system text NOT NULL,
  source_id     text NOT NULL,
  nome          text,
  email         text,
  collected_at  timestamptz NOT NULL,
  ingested_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);

CREATE TABLE IF NOT EXISTS account (
  id            bigserial PRIMARY KEY,
  source_system text NOT NULL,
  source_id     text NOT NULL,
  nome          text,
  collected_at  timestamptz NOT NULL,
  ingested_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);

CREATE TABLE IF NOT EXISTS lead (
  id                       bigserial PRIMARY KEY,
  source_system            text NOT NULL,
  source_id                text NOT NULL,
  nome                     text,
  empresa                  text,
  email                    text,
  telefone                 text,
  status                   text,
  origem_bruta             text,
  campanha_linkedin_bruta  text,
  converted_account_id     text,
  owner_id                 bigint REFERENCES owner(id),
  created_at_source        timestamptz,
  collected_at             timestamptz NOT NULL,
  ingested_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);

COMMENT ON COLUMN lead.origem_bruta IS
  'Valor bruto do LeadSource (ou equivalente) preservado sem transformação — P6/§3.5. A classificação de origem (Marketing/Comercial/Não atribuído) NÃO é derivada aqui: é calculada por fn_classify_origin (phase-3) e versionada em lead_origin_classification (migration 008).';
COMMENT ON COLUMN lead.campanha_linkedin_bruta IS
  'Campo bruto Campanha_LinkedIn__c do Salesforce — apesar do nome, historicamente carrega o Ad ID do Meta em parte da amostra. Preservado como veio (P6); NFR-6: nenhuma coluna de canal específico é criada a partir dele.';
COMMENT ON COLUMN lead.converted_account_id IS
  'Chave de join lead→account/opportunity quando o lead foi convertido. Único caminho de join aceito (CON-4/AC-2.2) — NUNCA via origem_bruta/LeadSource.';

CREATE TABLE IF NOT EXISTS contact (
  id            bigserial PRIMARY KEY,
  source_system text NOT NULL,
  source_id     text NOT NULL,
  account_id    bigint REFERENCES account(id),
  nome          text,
  email         text,
  telefone      text,
  collected_at  timestamptz NOT NULL,
  ingested_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);

CREATE TABLE IF NOT EXISTS opportunity (
  id                        bigserial PRIMARY KEY,
  source_system             text NOT NULL,
  source_id                 text NOT NULL,
  account_id                bigint REFERENCES account(id),
  record_type_name          text,
  stage_name                text,
  amount                    numeric,
  duracao_meses_contrato    integer,
  owner_id                  bigint REFERENCES owner(id),
  created_at_source         timestamptz,
  closed_at_source          timestamptz,
  collected_at              timestamptz NOT NULL,
  ingested_at               timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);

COMMENT ON COLUMN opportunity.record_type_name IS
  'RecordType.Name do Salesforce — o sinal CONFIÁVEL de Produto/Serviço (CON-4/project_salesforce_integration). NUNCA usar origem_bruta/LeadSource para isso.';
COMMENT ON COLUMN opportunity.amount IS
  'Amount do Salesforce = MRR (receita mensal recorrente), NUNCA valor de contrato total. Valor de contrato = amount * duracao_meses_contrato, e só é significativo quando stage_name = ''Ganho'' e duracao_meses_contrato é conhecida (FR-10/EC-5) — esse cálculo mora em função/view de phase-3, não é uma coluna armazenada aqui.';
COMMENT ON COLUMN opportunity.duracao_meses_contrato IS
  'Duração do contrato em meses, quando conhecida na origem. NULL não vira 0 nem é assumido — a ausência é uma lacuna real (FR-10/EC-5), nunca um valor default inventado.';
