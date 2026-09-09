-- db/migrations/025_seed_opportunities_receita.sql
-- Subtask 3.8. Oportunidades sintéticas para testar view_receita nos três
-- casos exigidos por AC-10.1/AC-10.2: Ganha com duração conhecida, Ganha
-- sem duração, e não-Ganha com Amount preenchido.

INSERT INTO opportunity (source_system, source_id, stage_name, amount, duracao_meses_contrato, record_type_name, collected_at) VALUES
  ('seed_test', 'seed-opp-ganha-com-duracao', 'Ganho', 1000, 12, 'Serviço', now()),
  ('seed_test', 'seed-opp-ganha-sem-duracao', 'Ganho', 2000, NULL, 'Serviço', now()),
  ('seed_test', 'seed-opp-nao-ganha', 'Avaliação', 3000, 24, 'Produto', now())
ON CONFLICT (source_system, source_id) DO NOTHING;
