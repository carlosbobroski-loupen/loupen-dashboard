-- db/migrations/024_view_receita.sql
-- Subtask 3.7. Regras de receita como view SQL versionada (FR-10/EC-5,
-- mesmo domicílio da atribuição pela resolução de CRIT-4). Amount é MRR,
-- NUNCA valor de contrato — contrato só é calculável quando Ganho E com
-- duração conhecida (nunca duração default/presumida).
--
-- AC-10.1: oportunidade não Ganha NÃO expõe valor de contrato — a view
-- retorna NULL, nunca zero e nunca Amount reaproveitado como se fosse
-- contrato.
-- AC-10.2: Ganha sem duração conhecida → contrato_valor NULL +
-- contrato_indisponivel_motivo explicando por quê — nunca duração default.

CREATE OR REPLACE VIEW view_receita AS
SELECT
  o.id AS opportunity_id,
  o.source_system,
  o.source_id,
  o.stage_name,
  o.amount AS mrr,
  o.duracao_meses_contrato,
  CASE
    WHEN o.stage_name = 'Ganho' AND o.duracao_meses_contrato IS NOT NULL
      THEN o.amount * o.duracao_meses_contrato
    ELSE NULL
  END AS contrato_valor,
  CASE
    WHEN o.stage_name IS DISTINCT FROM 'Ganho'
      THEN 'Oportunidade ainda não está Ganha — valor de contrato não se aplica'
    WHEN o.duracao_meses_contrato IS NULL
      THEN 'Ganha, mas duração de contrato desconhecida na origem — contrato indisponível, nunca um prazo presumido'
    ELSE NULL
  END AS contrato_indisponivel_motivo
FROM opportunity o;

COMMENT ON VIEW view_receita IS
  'FR-10/EC-5/CON-4: mrr é sempre Amount bruto; contrato_valor só é não-nulo quando Ganho E duracao_meses_contrato conhecida; contrato_indisponivel_motivo explica a lacuna (P-UI-6) — nunca um número inventado no lugar de NULL.';
