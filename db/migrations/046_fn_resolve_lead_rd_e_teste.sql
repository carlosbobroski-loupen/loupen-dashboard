-- db/migrations/046_fn_resolve_lead_rd_e_teste.sql
-- Subtask 8.3 — funções auxiliares que a ingestão de leads do RD Station
-- (migration 047) precisa. Separadas de propósito: cada uma é testável
-- isoladamente antes de entrar na função de ingestão, que é grande.
--
-- ── 1. CORREÇÃO DE FORMA DAS REGRAS DE TESTE ──────────────────────────────
-- A migration 045 semeou lead_teste_regra com padrões de formas
-- inconsistentes: 'TEST_%' é sintaxe de ILIKE, mas
-- 'fonte|midia|nome|termo|...' é sintaxe de regex alternada. Um único
-- operador de casamento não serve os dois. Padronizo tudo em REGEX (~*),
-- porque a regra de UTM é genuinamente uma alternância e reescrevê-la como
-- 3 regras de ILIKE separadas esconderia que é uma regra só.
--
-- ── 2. RESOLUÇÃO DE LEAD A PARTIR DE UUID DO RD ───────────────────────────
-- As seções WorkflowEvent e FunnelStage (migrations 040/042/043) resolvem
-- lead SÓ via identity_edge → lead do Salesforce. Isso era correto quando
-- o único caminho de entrada de lead era o Salesforce. A partir da ingestão
-- de descoberta do RD (047) passam a existir leads NATIVOS do RD, e aquelas
-- seções deixariam de encontrá-los — funil e workflow ficariam órfãos.
--
-- Esta função centraliza a resolução com precedência explícita:
--   Tier 1  identity_edge → lead do Salesforce (lead unificado, preferido)
--   Tier 2  lead nativo do RD Station por uuid
-- A ordem importa: quando o mesmo humano existe nas duas fontes, o lead do
-- Salesforce é o canônico (é o que carrega oportunidade e receita). Só se
-- não houver vínculo é que o lead do RD responde por si.

-- ---------------------------------------------------------------------------
-- 1. Padroniza os padrões em regex
-- ---------------------------------------------------------------------------
UPDATE lead_teste_regra
   SET padrao = '^TEST_'
 WHERE nome = 'gclid literal de teste' AND padrao = 'TEST_%';

UPDATE lead_teste_regra
   SET padrao = '^(fonte|midia|mídia|nome|termo|conteudo|conteúdo|campanha)$'
 WHERE nome = 'utm com nome do proprio campo';

COMMENT ON COLUMN lead_teste_regra.padrao IS
  'Expressão REGULAR (operador ~*, case-insensitive), nunca padrão de ILIKE. Padronizado na migration 046 porque a regra de UTM é uma alternância e não caberia em ILIKE sem virar 3 regras artificiais.';

-- ---------------------------------------------------------------------------
-- 2. fn_lead_e_teste — devolve o NOME da regra que casou, ou NULL
--
-- Devolve o nome da regra (não um booleano) de propósito: a aba Qualidade de
-- dados tem de mostrar quantos leads cada regra pegou, e isso é impossível se
-- a função só disser "sim/não". Exclusão silenciosa é proibida
-- (data-contract.md §1.6).
--
-- p_utms é um array porque um evento traz até 6 UTMs e basta UMA casar para
-- o lead ser de teste.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_lead_e_teste(
  p_email  text,
  p_gclid  text  DEFAULT NULL,
  p_utms   text[] DEFAULT NULL,
  p_origem text  DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  r_regra RECORD;
  v_utm   text;
BEGIN
  FOR r_regra IN
    SELECT nome, campo, padrao FROM lead_teste_regra WHERE ativo ORDER BY id
  LOOP
    IF r_regra.campo = 'email' AND p_email IS NOT NULL AND p_email ~* r_regra.padrao THEN
      RETURN r_regra.nome;
    ELSIF r_regra.campo = 'gclid' AND p_gclid IS NOT NULL AND p_gclid ~* r_regra.padrao THEN
      RETURN r_regra.nome;
    ELSIF r_regra.campo = 'origem_conversao' AND p_origem IS NOT NULL AND p_origem ~* r_regra.padrao THEN
      RETURN r_regra.nome;
    ELSIF r_regra.campo = 'utm' AND p_utms IS NOT NULL THEN
      FOREACH v_utm IN ARRAY p_utms LOOP
        IF v_utm IS NOT NULL AND btrim(v_utm) <> '' AND v_utm ~* r_regra.padrao THEN
          RETURN r_regra.nome;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;
COMMENT ON FUNCTION fn_lead_e_teste(text, text, text[], text) IS
  'data-contract.md §1.6 — devolve o NOME da regra de lead_teste_regra que casou, ou NULL. Devolve o nome e não um booleano porque a contagem por regra tem de aparecer na aba Qualidade de dados: exclusão silenciosa é proibida.';

-- ---------------------------------------------------------------------------
-- 3. fn_resolve_lead_por_rd_uuid — Tier 1 (Salesforce) antes de Tier 2 (RD)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_resolve_lead_por_rd_uuid(p_contact_uuid text)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_lead_id bigint;
BEGIN
  IF p_contact_uuid IS NULL OR btrim(p_contact_uuid) = '' THEN
    RETURN NULL;
  END IF;

  -- Tier 1: o humano já está unificado e tem lead no Salesforce.
  SELECT l.id INTO v_lead_id
  FROM identity_edge rd
  JOIN identity_edge sf ON sf.person_id = rd.person_id AND sf.source_system = 'salesforce'
  JOIN lead l ON l.source_system = 'salesforce' AND l.source_id = sf.source_record_id
  WHERE rd.source_system = 'rd_station'
    AND rd.identifier_type = 'rdstation_uuid'
    AND rd.identifier_value = p_contact_uuid
  LIMIT 1;

  IF v_lead_id IS NOT NULL THEN
    RETURN v_lead_id;
  END IF;

  -- Tier 2: lead nativo do RD Station.
  SELECT l.id INTO v_lead_id
  FROM lead l
  WHERE l.source_system = 'rd_station' AND l.source_id = p_contact_uuid
  LIMIT 1;

  RETURN v_lead_id;
END;
$$;
COMMENT ON FUNCTION fn_resolve_lead_por_rd_uuid(text) IS
  'Resolve lead.id a partir do uuid de contato do RD Station, com precedência: identity_edge→lead do Salesforce (canônico, carrega oportunidade/receita) e só depois lead nativo do RD. Criada na migration 046 porque as seções WorkflowEvent/FunnelStage resolviam apenas via Salesforce e deixariam órfãos os leads nativos do RD introduzidos pela ingestão de descoberta (047).';
