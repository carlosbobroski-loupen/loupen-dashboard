-- db/migrations/003_marketing_entities.sql
-- Subtask 2.5. Entidades de marketing (DM-5 campaign, DM-6 ad_campaign,
-- DM-7 channel_source, DM-8 funnel_stage, DM-9 automation_workflow,
-- DM-12 marketing_asset). Campos e relacionamentos derivados literalmente
-- de requirements.json.domainModel — nenhum campo inventado fora dali.

-- DM-5: campanha de marketing (RD Station e/ou código em LeadSource).
CREATE TABLE IF NOT EXISTS campaign (
  id                   bigserial PRIMARY KEY,
  source_system        text NOT NULL,
  source_id            text NOT NULL,
  nome                 text,
  codigo_leadsource    text,
  canal                text,
  collected_at         timestamptz NOT NULL,
  ingested_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);
COMMENT ON COLUMN campaign.codigo_leadsource IS
  'Código/identificador da campanha como aparece em LeadSource — sinal principal usado hoje para classificar Marketing (DM-5). Preservado bruto (P6).';

-- DM-6: campanha de anúncio pago (Meta/Google/LinkedIn), hierarquia
-- campanha → conjunto → anúncio.
CREATE TABLE IF NOT EXISTS ad_campaign (
  id                bigserial PRIMARY KEY,
  source_system     text NOT NULL,
  source_id         text NOT NULL,
  plataforma        text,
  campanha_id       text,
  conjunto_id       text,
  ad_id             text,
  campaign_ref_id   bigint REFERENCES campaign(id),
  metricas          jsonb,
  collected_at      timestamptz NOT NULL,
  ingested_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);
COMMENT ON COLUMN ad_campaign.campaign_ref_id IS
  'FK para campaign quando mapeável (DM-6: "belongs_to Campaign quando mapeável"). NULL é um estado válido, não uma falha — nem toda ad_campaign tem uma campaign correspondente conhecida.';
COMMENT ON COLUMN ad_campaign.metricas IS
  'Métricas de mídia (impressões, cliques, spend etc.) preservadas como jsonb bruto da origem — schema de métricas não fixado nesta migration, evita coluna nova por métrica.';

-- DM-7: canal/origem do lead — a dimensão de atribuição. NaoAtribuido é
-- valor de PRIMEIRA CLASSE aqui, não ausência/NULL — é a causa raiz do bug
-- de FR-5 que esta epic existe para corrigir.
CREATE TABLE IF NOT EXISTS channel_source (
  id                  bigserial PRIMARY KEY,
  canal               text NOT NULL UNIQUE,
  classificacao       text NOT NULL CHECK (classificacao IN ('Marketing', 'Comercial', 'NaoAtribuido')),
  sinal_determinante  text,
  descricao           text
);
COMMENT ON TABLE channel_source IS
  'Dimensão de canais conhecidos e sua classificação PADRÃO (DM-7). A classificação REAL por lead é calculada por fn_classify_origin (phase-3) e versionada em lead_origin_classification — esta tabela é catálogo de referência, não a fonte de verdade por lead.';

INSERT INTO channel_source (canal, classificacao, sinal_determinante, descricao) VALUES
  ('ads',              'Marketing',   'S1/S2/S3', 'Anúncio pago (Meta/Google/LinkedIn), com ou sem Ad ID individual'),
  ('formulario',       'Marketing',   'S4',       'Conversão em formulário próprio (RD Station)'),
  ('landing_page',     'Marketing',   'S4',       'Conversão em landing page própria'),
  ('pop_up',           'Marketing',   'S4',       'Conversão em pop-up próprio'),
  ('whatsapp_sdr_ia',  'Marketing',   'S1',       'Lead WhatsApp com Ad ID identificável via Campanha_LinkedIn__c'),
  ('outbound',         'Comercial',   'S5',       'Prospecção ativa por lista — vocabulário controlado, único caminho para Comercial'),
  ('nao_atribuido',    'NaoAtribuido','S6',       'Nenhum sinal suficiente — estado explícito de primeira classe, nunca reclassificado como Comercial por padrão')
ON CONFLICT (canal) DO NOTHING;

-- DM-8: estágio de funil — DUAS SEMÂNTICAS DISTINTAS, mantidas separadas
-- pela coluna `origem`, nunca colapsadas na mesma linha/campo.
CREATE TABLE IF NOT EXISTS funnel_stage (
  id      bigserial PRIMARY KEY,
  origem  text NOT NULL CHECK (origem IN ('rd_station', 'salesforce')),
  nome    text NOT NULL,
  ordem   integer,
  UNIQUE (origem, nome)
);
COMMENT ON TABLE funnel_stage IS
  'DM-8: estágio de funil do RD Station (marketing) e StageName da opportunity (comercial) são semânticas DISTINTAS, distinguidas por `origem` — nunca comparadas ou somadas como se fossem a mesma escala.';

-- DM-9: workflow de automação do RD Station.
CREATE TABLE IF NOT EXISTS automation_workflow (
  id                        bigserial PRIMARY KEY,
  source_system             text NOT NULL,
  source_id                 text NOT NULL,
  nome                      text,
  etapas                    jsonb,
  data_atualizacao_origem   timestamptz,
  collected_at              timestamptz NOT NULL,
  ingested_at               timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);
COMMENT ON COLUMN automation_workflow.data_atualizacao_origem IS
  'Dados de workflow no RD Station são atualizados 1x/dia na origem (DM-9) — granularidade diária, coerente com CON-3/NFR-4/EC-10. Nunca comparar como se fosse granularidade intradiária.';

-- DM-12: ativos de captura (landing pages, formulários, pop-ups, e-mails).
CREATE TABLE IF NOT EXISTS marketing_asset (
  id                    bigserial PRIMARY KEY,
  source_system         text NOT NULL,
  source_id             text NOT NULL,
  tipo                  text CHECK (tipo IN ('landing_page', 'formulario', 'pop_up', 'email')),
  nome                  text,
  campaign_ref_id       bigint REFERENCES campaign(id),
  metricas_conversao    jsonb,
  collected_at          timestamptz NOT NULL,
  ingested_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, source_id)
);
