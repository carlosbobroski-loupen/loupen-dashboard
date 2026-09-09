-- db/migrations/028_seed_identidade_tier1.sql
-- Subtask 3.10. Lead (Salesforce) e contact (RD Station) sintéticos com o
-- MESMO e-mail normalizado (um com sufixo +tag, o outro sem) — prova que
-- fn_identity_tier1_resolve() liga os dois à MESMA person via T1.1.

INSERT INTO lead (source_system, source_id, nome, email, converted_account_id, collected_at)
VALUES ('seed_test', 'seed-t1-lead', 'Seed Tier1 Lead', 'pessoa.tier1+promo@exemplo.com', 'seed-t1-account', now())
ON CONFLICT (source_system, source_id) DO NOTHING;

INSERT INTO contact (source_system, source_id, nome, email, collected_at)
VALUES ('rd_station', 'seed-t1-rdstation-uuid', 'Seed Tier1 Contact', 'pessoa.tier1@exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;
