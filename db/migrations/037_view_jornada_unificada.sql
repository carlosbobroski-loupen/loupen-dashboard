-- db/migrations/037_view_jornada_unificada.sql
-- Subtask 3.18. FR-3/AC-3.1/AC-3.2: jornada em ORDEM CRONOLÓGICA ÚNICA
-- sobre as fontes disponíveis nesta sessão — conversion_event (direto por
-- lead_id OU indireto via contact→identidade→lead), lead_touchpoint
-- (influência, granularidade diária declarada) e criação de oportunidade
-- (marco derivado do próprio dado já ingerido, não staging bruto).
--
-- CON-3/EC-10: granularidade DECLARADA por linha — 'timestamp' quando a
-- fonte dá hora exata, 'dia' quando só dá o dia (workflow do RD Station,
-- 1x/dia na origem). A UI nunca deve comparar dois eventos de
-- granularidade 'dia' como se a ORDEM entre eles no mesmo dia fosse
-- significativa.
--
-- AC-3.2: evento sem data rastreável (date_traceable=false) entra
-- MARCADO — nunca omitido, nunca com data arbitrária (já garantido pelo
-- CHECK de conversion_event + a asserção evento-sem-data-fr3.sql de 3.12).

CREATE OR REPLACE VIEW view_jornada_unificada AS
-- 1) Eventos de conversão já ligados diretamente a um lead.
SELECT
  ce.lead_id,
  ce.occurred_at,
  ce.date_traceable,
  ce.source_system,
  ce.tipo,
  ce.ativo_de_origem AS detalhe,
  'timestamp' AS granularidade
FROM conversion_event ce
WHERE ce.lead_id IS NOT NULL

UNION ALL

-- 2) Eventos de conversão de contact (RD Station) resolvidos a um lead
-- (Salesforce) via identidade (EC-7) — só entram na jornada do lead
-- quando a identidade já foi resolvida (Tier 1 ou Tier 2 confirmado
-- manualmente; Tier 2 'provavel'/'conflito' NÃO conta como resolvido —
-- ver CTE abaixo, que exige que os dois lados apontem para a MESMA
-- person via identity_edge, nunca via identity_candidate).
SELECT
  l.id AS lead_id,
  ce.occurred_at,
  ce.date_traceable,
  ce.source_system,
  ce.tipo,
  ce.ativo_de_origem AS detalhe,
  'timestamp' AS granularidade
FROM conversion_event ce
JOIN contact c ON c.id = ce.contact_id
JOIN identity_edge ie_contact ON ie_contact.source_system = c.source_system AND ie_contact.source_record_id = c.source_id
JOIN identity_edge ie_lead ON ie_lead.person_id = ie_contact.person_id AND ie_lead.source_system <> c.source_system
JOIN lead l ON l.source_system = ie_lead.source_system AND l.source_id = ie_lead.source_record_id
WHERE ce.contact_id IS NOT NULL AND ce.lead_id IS NULL

UNION ALL

-- 3) Touchpoints de influência (S7) — granularidade SEMPRE 'dia' (CON-3),
-- nunca timestamp, porque a origem (workflow do RD Station) só atualiza
-- 1x/dia.
SELECT
  lt.lead_id,
  lt.occurred_on::timestamptz,
  true AS date_traceable,
  lt.fonte AS source_system,
  lt.tipo,
  lt.campanha AS detalhe,
  'dia' AS granularidade
FROM lead_touchpoint lt

UNION ALL

-- 4) Criação de oportunidade — marco derivado do dado já canônico
-- (opportunity), vinculado ao lead via ConvertedAccountId (CON-4).
SELECT
  l.id AS lead_id,
  o.created_at_source,
  o.created_at_source IS NOT NULL,
  o.source_system,
  'criacao_oportunidade',
  o.stage_name,
  'timestamp'
FROM opportunity o
JOIN account a ON a.id = o.account_id
JOIN lead l ON l.source_system = a.source_system AND l.converted_account_id = a.source_id;

COMMENT ON VIEW view_jornada_unificada IS
  'FR-3: jornada cronológica única (ORDER BY occurred_at fica a cargo de quem consome — a view não ordena para não impor um ORDER BY implícito sobre uma UNION ALL grande). granularidade declara timestamp vs dia (CON-3/EC-10) — nunca comparar dois eventos "dia" como se a ordem intradiária importasse.';
