-- db/migrations/030_seed_identidade_tier2.sql
-- Subtask 3.11. Lead e contact com nomes PARECIDOS (não idênticos) e
-- mesmo domínio de e-mail corporativo, mas endereços de e-mail exatos
-- DIFERENTES — Tier 1 (igualdade exata) não liga os dois, só Tier 2
-- (similaridade) deveria. Mesmo padrão conceitual da fixture de EC-7 da
-- Etapa A (seed-prov-01/02), agora do lado do banco.

INSERT INTO lead (source_system, source_id, nome, email, collected_at)
VALUES ('seed_test', 'seed-t2-lead', 'Joao Pereira Lima', 'joao.lima@nortec-exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;

INSERT INTO contact (source_system, source_id, nome, email, collected_at)
VALUES ('rd_station', 'seed-t2-contact', 'João P. Lima', 'jp.lima@nortec-exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;
