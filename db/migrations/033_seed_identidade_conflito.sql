-- db/migrations/033_seed_identidade_conflito.sql
-- Subtask 3.12. Dois leads com o MESMO e-mail (corporativo genérico) mas
-- nomes claramente DIFERENTES — o caso real de conflito de EC-7 (mesmo
-- padrão conceitual de seed-conf-01/02 da fixture da Etapa A).

INSERT INTO lead (source_system, source_id, nome, email, collected_at)
VALUES ('seed_test', 'seed-conflito-a', 'Marcos Vinicius Tavares', 'contato@grupoalfa-exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;

INSERT INTO lead (source_system, source_id, nome, email, collected_at)
VALUES ('seed_test', 'seed-conflito-b', 'Ana Paula Ferreira', 'contato@grupoalfa-exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;
