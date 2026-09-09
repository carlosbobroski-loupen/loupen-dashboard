-- db/migrations/013_indexes_base.sql
-- Subtask 2.14. Índices ESTRUTURAIS apenas (join e chave de lookup usados
-- pelo próprio desenho do schema/fn_classify_origin, phase-3) — não
-- índices motivados por medição de performance (isso é 6.11, DEPOIS da
-- medição de 5.17; criar por antecipação sem medida gasta CU-hours/storage
-- do Neon Free contra um problema hipotético, R8).
--
-- Postgres não indexa FK automaticamente — cada FK usada em join aqui abaixo
-- ganha índice explícito. Índice em tabela particionada (conversion_event)
-- propaga automaticamente para cada partição (Postgres 11+).

-- Join lead→account (CON-4: via ConvertedAccountId, nunca via LeadSource).
CREATE INDEX IF NOT EXISTS idx_lead_converted_account_id ON lead (converted_account_id);
CREATE INDEX IF NOT EXISTS idx_lead_owner_id ON lead (owner_id);

-- Joins de opportunity/contact para account/owner.
CREATE INDEX IF NOT EXISTS idx_opportunity_account_id ON opportunity (account_id);
CREATE INDEX IF NOT EXISTS idx_opportunity_owner_id ON opportunity (owner_id);
CREATE INDEX IF NOT EXISTS idx_contact_account_id ON contact (account_id);

-- Jornada (DM-10) — lookup por lead e por data (partição já particiona por
-- data; este índice acelera o filtro dentro de cada partição/por lead).
CREATE INDEX IF NOT EXISTS idx_conversion_event_lead_id ON conversion_event (lead_id);
CREATE INDEX IF NOT EXISTS idx_conversion_event_contact_id ON conversion_event (contact_id);
CREATE INDEX IF NOT EXISTS idx_conversion_event_campaign_ref_id ON conversion_event (campaign_ref_id);

-- Influência (migration 006) — lookup por lead.
CREATE INDEX IF NOT EXISTS idx_lead_touchpoint_lead_id ON lead_touchpoint (lead_id);

-- Chaves de campanha — codigo_leadsource é o sinal principal de S3 (LeadSource
-- reconhecido como código de campanha); ad_id é o sinal de S1 (Ad ID presente).
CREATE INDEX IF NOT EXISTS idx_campaign_codigo_leadsource ON campaign (codigo_leadsource);
CREATE INDEX IF NOT EXISTS idx_ad_campaign_ad_id ON ad_campaign (ad_id);
CREATE INDEX IF NOT EXISTS idx_ad_campaign_campaign_ref_id ON ad_campaign (campaign_ref_id);

-- Histórico de classificação — lookup pela versão corrente já tem o índice
-- único parcial (migration 008); este cobre a leitura por lead sem filtro
-- de valid_to (auditoria do histórico completo).
CREATE INDEX IF NOT EXISTS idx_lead_origin_classification_lead_id ON lead_origin_classification (lead_id);
