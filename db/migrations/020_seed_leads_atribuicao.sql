-- db/migrations/020_seed_leads_atribuicao.sql
-- Subtask 3.4 (V5) precisa de leads com sinal CONHECIDO para testar
-- fn_classify_origin de forma determinística — nenhum dado real do
-- Salesforce está carregado ainda (2.16 bloqueada, ver TODO do usuário em
-- edge-routing.md). Mesmo padrão já usado na Etapa A (fixture seed-*):
-- dados SINTÉTICOS, marcados, nunca confundidos com dado real.
--
-- source_system='seed_test' — NUNCA aparece em relatório/métrica real
-- (nenhuma query de negócio deste épico filtra ou soma por 'seed_test',
-- mas o valor em si já é o marcador de "não é produção"). Substituído por
-- dados de leads reais assim que 2.16 for desbloqueada — este arquivo fica
-- então como fixture de teste permanente (papel equivalente ao
-- assets/data/mock/*.json da Etapa A, só que no lado do banco).

INSERT INTO lead (source_system, source_id, nome, empresa, origem_bruta, campanha_linkedin_bruta, converted_account_id, collected_at) VALUES
  ('seed_test', 'seed-s1-adid', 'Seed S1', 'Seed Empresa S1', NULL, '120255640138090492', NULL, now()),
  ('seed_test', 'seed-s3-campanha', 'Seed S3', 'Seed Empresa S3', 'Busca Paga | Google', NULL, NULL, now()),
  ('seed_test', 'seed-s5-outbound', 'Seed S5', 'Seed Empresa S5', 'Apollo.Io', NULL, NULL, now()),
  ('seed_test', 'seed-s9-parceiro', 'Seed S9', 'Seed Empresa S9', 'Parceiro', NULL, NULL, now()),
  ('seed_test', 'seed-s6-vazio', 'Seed S6 Vazio', 'Seed Empresa S6', NULL, NULL, NULL, now()),
  ('seed_test', 'seed-s6-naomapeado', 'Seed S6 Não Mapeado', 'Seed Empresa S6b', 'ValorMaisEstranhoNuncaVistoXYZ', NULL, NULL, now())
ON CONFLICT (source_system, source_id) DO NOTHING;
