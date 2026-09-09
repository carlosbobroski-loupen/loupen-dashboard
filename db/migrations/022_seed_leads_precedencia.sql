-- db/migrations/022_seed_leads_precedencia.sql
-- Subtask 3.6. Lead sintético adicional (mesmo padrão de 020) onde DOIS
-- sinais casam simultaneamente — S1 (Ad ID presente) e S5 (LeadSource no
-- vocabulário outbound) — para provar que a precedência estrita (S1 antes
-- de S5) é respeitada de verdade, não coincidência de dado real.

INSERT INTO lead (source_system, source_id, nome, origem_bruta, campanha_linkedin_bruta, collected_at)
VALUES ('seed_test', 'seed-precedencia-s1-vs-s5', 'Seed Precedencia', 'Apollo.Io', '120255640138090492', now())
ON CONFLICT (source_system, source_id) DO NOTHING;
