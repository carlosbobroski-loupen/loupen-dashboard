-- db/migrations/036_view_lead_360.sql
-- Subtask 3.17. FR-2/AC-2.1/AC-2.2. Perfil do lead + classificação
-- corrente (com razão auditável) + oportunidades vinculadas EXCLUSIVAMENTE
-- por ConvertedAccountId (CON-4) — join por LeadSource é literalmente
-- impossível aqui porque a coluna nem aparece na condição de JOIN.
--
-- EC-2/P-UI-6: lead sem oportunidade tem opportunity_id NULL — distinguível
-- de "zero oportunidades" só pela ausência da linha à direita (LEFT JOIN),
-- nunca um zero fabricado.

CREATE OR REPLACE VIEW view_lead_360 AS
SELECT
  l.id AS lead_id,
  l.source_system,
  l.source_id,
  l.nome,
  l.empresa,
  l.email,
  l.telefone,
  l.status AS estagio_funil,
  l.converted_account_id,
  loc.segmento,
  loc.categoria,
  loc.detalhe,
  loc.sinal_id,
  loc.valor_bruto,
  loc.razao,
  a.id AS account_id,
  a.nome AS account_nome,
  o.id AS opportunity_id,
  o.stage_name,
  o.record_type_name,
  vr.mrr,
  vr.contrato_valor,
  vr.contrato_indisponivel_motivo
FROM lead l
LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
LEFT JOIN account a ON a.source_system = l.source_system AND a.source_id = l.converted_account_id
LEFT JOIN opportunity o ON o.account_id = a.id
LEFT JOIN view_receita vr ON vr.opportunity_id = o.id;

COMMENT ON VIEW view_lead_360 IS
  'FR-2: perfil + classificação + oportunidades. Join lead→account→opportunity é SEMPRE via converted_account_id (CON-4) — origem_bruta/LeadSource não participa da condição de JOIN. Lead sem conversão: account_id/opportunity_id NULL (EC-2), nunca omitido da view.';
