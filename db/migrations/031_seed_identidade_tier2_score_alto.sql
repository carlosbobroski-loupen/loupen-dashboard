-- db/migrations/031_seed_identidade_tier2_score_alto.sql
-- Subtask 3.11. ACHADO REAL (registrado, não escondido): o par de teste de
-- 030 ("Joao Pereira Lima" vs "João P. Lima") tem similarity() = 0.36 —
-- ABAIXO do limiar de 0.6 do plano. Abreviação de nome do meio + acento é
-- uma variação real demais para trigrama pegar nesse limiar. Isso é uma
-- LACUNA DE CALIBRAÇÃO genuína do T2.1 como especificado, não um bug de
-- código — fica para revisão do usuário (ver validation-log.md).
--
-- Este par adicional tem uma variação MENOR (só acentuação) — similarity
-- esperada bem mais alta — para provar que o CAMINHO POSITIVO de T2.1
-- (quando o score realmente bate o limiar) funciona de verdade.

INSERT INTO lead (source_system, source_id, nome, email, collected_at)
VALUES ('seed_test', 'seed-t2b-lead', 'Patricia Gomes Andrade', 'patricia.andrade@vertice-exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;

INSERT INTO contact (source_system, source_id, nome, email, collected_at)
VALUES ('rd_station', 'seed-t2b-contact', 'Patrícia Gomes Andrade', 'p.andrade@vertice-exemplo.com', now())
ON CONFLICT (source_system, source_id) DO NOTHING;
