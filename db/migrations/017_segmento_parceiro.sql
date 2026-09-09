-- db/migrations/017_segmento_parceiro.sql
-- Subtask 3.2 (V4/OQ-12): decisão do usuário — "Parceiro/Indicação" é um
-- QUARTO SEGMENTO próprio no nível 1 da taxonomia, não um caso de
-- Marketing nem de Comercial (ver validation-log.md, resposta literal do
-- usuário em 2026-09-07). Domínio passa de 3 para 4 valores.
--
-- Forward-only: os CHECKs de channel_source.classificacao (migration 003)
-- e lead_origin_classification.segmento (migration 008) são recriados com
-- o valor adicional — não é uma reversão de decisão anterior, é a mesma
-- decisão de origem sendo completada com a resposta que faltava (OQ-12
-- estava deliberadamente não mapeado até agora).

ALTER TABLE channel_source DROP CONSTRAINT IF EXISTS channel_source_classificacao_check;
ALTER TABLE channel_source ADD CONSTRAINT channel_source_classificacao_check
  CHECK (classificacao IN ('Marketing', 'Comercial', 'NaoAtribuido', 'Parceiro'));

ALTER TABLE lead_origin_classification DROP CONSTRAINT IF EXISTS lead_origin_classification_segmento_check;
ALTER TABLE lead_origin_classification ADD CONSTRAINT lead_origin_classification_segmento_check
  CHECK (segmento IN ('Marketing', 'Comercial', 'NaoAtribuido', 'Parceiro'));

INSERT INTO channel_source (canal, classificacao, sinal_determinante, descricao) VALUES
  ('parceiro_indicacao', 'Parceiro', 'S9', 'Lead trazido por parceiro comercial, revenda ou indicação (cliente/funcionário) — quarto segmento próprio por decisão do usuário (OQ-12, 2026-09-07), nunca colapsado em Marketing ou Comercial')
ON CONFLICT (canal) DO NOTHING;

COMMENT ON CONSTRAINT lead_origin_classification_segmento_check ON lead_origin_classification IS
  'Domínio de 4 valores desde 2026-09-07 (OQ-12 resolvido: Parceiro é segmento próprio, decisão do usuário). S9 é o sinal que produz Parceiro — ver fn_classify_origin (migration 019).';
