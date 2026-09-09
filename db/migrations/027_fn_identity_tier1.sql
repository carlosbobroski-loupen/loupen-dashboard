-- db/migrations/027_fn_identity_tier1.sql
-- Subtask 3.10. Resolução de identidade Tier 1 — DETERMINÍSTICA apenas.
-- T1.1 e-mail normalizado (lowercase, trim, sufixo +tag removido);
-- T1.3 ConvertedAccountId; T1.4 UUID do contato do RD Station (já é
-- contact.source_id, por desenho — migration 003/016). T1.2 (telefone
-- E.164) fica coberto pela MESMA lógica de match por identifier_value,
-- assumindo que a normalização E.164 já rodou no n8n antes do insert
-- (resíduo aceito, ver §3.3 e migration 004).
--
-- Igualdade EXATA apenas — nada de similarity()/levenshtein() aqui (isso
-- é Tier 2, 3.11, e só roda quando Tier 1 não encontra nada). confidence=1
-- sempre. R18: registro de origem NUNCA é destruído — este processo só
-- ACRESCENTA person/identity_edge, nunca faz UPDATE/DELETE em
-- lead/contact/account/opportunity.
--
-- Função de PROCESSAMENTO EM LOTE, idempotente: processa todo lead/contact
-- ainda sem identity_edge correspondente. Chamada explícita (não
-- automática em todo INSERT) porque resolução de identidade é uma
-- operação de reconciliação periódica, não uma trigger por linha.

CREATE OR REPLACE FUNCTION fn_normalizar_email(p_email text)
RETURNS text AS $$
  SELECT NULLIF(regexp_replace(lower(trim(p_email)), '\+[^@]*@', '@'), '');
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION fn_normalizar_email(text) IS
  'T1.1: lowercase + trim + remove sufixo +tag antes do @ (ex.: user+promo@x.com -> user@x.com). Usado só para MATCH de identidade, nunca sobrescreve o e-mail original armazenado.';

CREATE OR REPLACE FUNCTION fn_identity_tier1_resolve()
RETURNS TABLE (identifier_type text, edges_criados integer) AS $$
DECLARE
  v_count integer;
BEGIN
  -- ConvertedAccountId (lead → identidade, quando convertido). Loop
  -- explícito por linha (mais simples e correto do que tentar casar CTEs
  -- com row_number para atribuir uma person nova por linha em lote).
  v_count := 0;
  DECLARE
    r RECORD;
    v_person_id bigint;
  BEGIN
    FOR r IN
      SELECT l.id AS lead_id, l.source_system, l.source_id, l.converted_account_id AS valor
      FROM lead l
      WHERE l.converted_account_id IS NOT NULL AND l.converted_account_id <> ''
        AND NOT EXISTS (
          SELECT 1 FROM identity_edge ie
          WHERE ie.source_system = l.source_system AND ie.source_record_id = l.source_id
            AND ie.identifier_type = 'converted_account_id'
        )
    LOOP
      -- Já existe pessoa com este ConvertedAccountId (de outro lead do mesmo Account)?
      SELECT ie.person_id INTO v_person_id FROM identity_edge ie
      WHERE ie.identifier_type = 'converted_account_id' AND ie.identifier_value = r.valor
      LIMIT 1;

      IF v_person_id IS NULL THEN
        INSERT INTO person (nome_canonico) VALUES (NULL) RETURNING id INTO v_person_id;
      END IF;

      INSERT INTO identity_edge (person_id, identifier_type, identifier_value, source_system, source_record_id, confidence)
      VALUES (v_person_id, 'converted_account_id', r.valor, r.source_system, r.source_id, 1)
      ON CONFLICT ON CONSTRAINT identity_edge_source_system_source_record_id_identifier_typ_key DO NOTHING;
      v_count := v_count + 1;
    END LOOP;
  END;
  identifier_type := 'converted_account_id'; edges_criados := v_count; RETURN NEXT;

  -- E-mail normalizado (lead E contact — o mesmo e-mail normalizado em
  -- fontes diferentes aponta para a mesma person).
  v_count := 0;
  DECLARE
    r RECORD;
    v_person_id bigint;
    v_email_norm text;
  BEGIN
    FOR r IN
      SELECT l.id, l.source_system, l.source_id, l.email
      FROM lead l WHERE l.email IS NOT NULL AND l.email <> ''
        AND NOT EXISTS (SELECT 1 FROM identity_edge ie WHERE ie.source_system=l.source_system AND ie.source_record_id=l.source_id AND ie.identifier_type='email')
      UNION ALL
      SELECT c.id, c.source_system, c.source_id, c.email
      FROM contact c WHERE c.email IS NOT NULL AND c.email <> ''
        AND NOT EXISTS (SELECT 1 FROM identity_edge ie WHERE ie.source_system=c.source_system AND ie.source_record_id=c.source_id AND ie.identifier_type='email')
    LOOP
      v_email_norm := fn_normalizar_email(r.email);
      CONTINUE WHEN v_email_norm IS NULL;

      SELECT ie.person_id INTO v_person_id FROM identity_edge ie
      WHERE ie.identifier_type = 'email' AND ie.identifier_value = v_email_norm
      LIMIT 1;

      IF v_person_id IS NULL THEN
        INSERT INTO person (nome_canonico) VALUES (NULL) RETURNING id INTO v_person_id;
      END IF;

      INSERT INTO identity_edge (person_id, identifier_type, identifier_value, source_system, source_record_id, confidence)
      VALUES (v_person_id, 'email', v_email_norm, r.source_system, r.source_id, 1)
      ON CONFLICT ON CONSTRAINT identity_edge_source_system_source_record_id_identifier_typ_key DO NOTHING;
      v_count := v_count + 1;
    END LOOP;
  END;
  identifier_type := 'email'; edges_criados := v_count; RETURN NEXT;

  -- UUID do contato do RD Station (contact.source_id JÁ é o UUID, por
  -- desenho — não precisa de normalização adicional).
  v_count := 0;
  DECLARE
    r RECORD;
    v_person_id bigint;
  BEGIN
    FOR r IN
      SELECT c.id, c.source_system, c.source_id
      FROM contact c
      WHERE c.source_system = 'rd_station'
        AND NOT EXISTS (SELECT 1 FROM identity_edge ie WHERE ie.source_system=c.source_system AND ie.source_record_id=c.source_id AND ie.identifier_type='rdstation_uuid')
    LOOP
      SELECT ie.person_id INTO v_person_id FROM identity_edge ie
      WHERE ie.identifier_type = 'rdstation_uuid' AND ie.identifier_value = r.source_id
      LIMIT 1;

      IF v_person_id IS NULL THEN
        INSERT INTO person (nome_canonico) VALUES (NULL) RETURNING id INTO v_person_id;
      END IF;

      INSERT INTO identity_edge (person_id, identifier_type, identifier_value, source_system, source_record_id, confidence)
      VALUES (v_person_id, 'rdstation_uuid', r.source_id, r.source_system, r.source_id, 1)
      ON CONFLICT ON CONSTRAINT identity_edge_source_system_source_record_id_identifier_typ_key DO NOTHING;
      v_count := v_count + 1;
    END LOOP;
  END;
  identifier_type := 'rdstation_uuid'; edges_criados := v_count; RETURN NEXT;

  RETURN;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_identity_tier1_resolve() IS
  'EC-7 Tier 1 (determinístico): processa lead/contact em lote, cria person+identity_edge para ConvertedAccountId/email normalizado/UUID RD Station. confidence=1 sempre. Idempotente (NOT EXISTS guarda). Chamar periodicamente após ingestão, não é trigger por linha.';
