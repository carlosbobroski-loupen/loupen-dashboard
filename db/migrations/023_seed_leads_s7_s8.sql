-- db/migrations/023_seed_leads_s7_s8.sql
-- Subtask 3.6. Lead sintético com origem Marketing (S3) que TAMBÉM tem
-- participação em workflow (S7, via lead_touchpoint) e dono no time
-- Comercial (S8, via owner) — para provar que nenhum dos dois muda o
-- segmento calculado por fn_classify_origin (INV-6: S7/S8 nunca
-- classificam origem).

INSERT INTO owner (source_system, source_id, nome, email, collected_at)
VALUES ('seed_test', 'seed-owner-comercial', 'Seed Owner Time Comercial', 'seed-comercial@exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;

INSERT INTO lead (source_system, source_id, nome, origem_bruta, owner_id, collected_at)
SELECT 'seed_test', 'seed-s7-s8-nao-classificam', 'Seed S7/S8', 'Busca Paga | Google', o.id, now()
FROM owner o WHERE o.source_system = 'seed_test' AND o.source_id = 'seed-owner-comercial'
ON CONFLICT (source_system, source_id) DO NOTHING;

INSERT INTO lead_touchpoint (lead_id, occurred_on, fonte, tipo, collected_at)
SELECT l.id, current_date, 'rd_station', 'workflow_entrada', now()
FROM lead l WHERE l.source_system = 'seed_test' AND l.source_id = 'seed-s7-s8-nao-classificam'
ON CONFLICT DO NOTHING;
