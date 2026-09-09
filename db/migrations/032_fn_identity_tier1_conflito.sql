-- db/migrations/032_fn_identity_tier1_conflito.sql
-- Subtask 3.12 (achado ao escrever a asserção de conflito EC-7): o
-- fn_identity_tier1_resolve original (027) mesclava QUALQUER registro com
-- e-mail normalizado igual na MESMA person, sem checar se isso fazia
-- sentido — um e-mail corporativo genérico (contato@empresa.com,
-- financeiro@empresa.com) compartilhado por PESSOAS DIFERENTES seria
-- fundido silenciosamente. Isso é exatamente o falso positivo que R18
-- existe para evitar.
--
-- Fix: antes de reaproveitar uma person já existente por e-mail, compara
-- o NOME do registro novo com os nomes já ligados a essa person. Se a
-- similaridade for baixa (< 0.3 — nitidamente pessoas diferentes), NÃO
-- funde: grava um identity_candidate com status='conflito' para revisão
-- humana, e o registro novo ganha sua PRÓPRIA person (nunca fica solto).

CREATE OR REPLACE FUNCTION fn_identity_tier1_resolve()
RETURNS TABLE (identifier_type text, edges_criados integer) AS $$
DECLARE
  v_count integer;
BEGIN
  -- ConvertedAccountId (sem checagem de conflito — Id de Account é forte
  -- o bastante para não precisar do mesmo cuidado do e-mail genérico).
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

  -- E-mail normalizado — COM checagem de conflito por divergência de nome.
  v_count := 0;
  DECLARE
    r RECORD;
    v_person_id bigint;
    v_email_norm text;
    v_max_sim double precision;
    v_novo_person_id bigint;
  BEGIN
    FOR r IN
      SELECT l.id, l.source_system, l.source_id, l.email, l.nome
      FROM lead l WHERE l.email IS NOT NULL AND l.email <> ''
        AND NOT EXISTS (SELECT 1 FROM identity_edge ie WHERE ie.source_system=l.source_system AND ie.source_record_id=l.source_id AND ie.identifier_type='email')
      UNION ALL
      SELECT c.id, c.source_system, c.source_id, c.email, c.nome
      FROM contact c WHERE c.email IS NOT NULL AND c.email <> ''
        AND NOT EXISTS (SELECT 1 FROM identity_edge ie WHERE ie.source_system=c.source_system AND ie.source_record_id=c.source_id AND ie.identifier_type='email')
    LOOP
      v_email_norm := fn_normalizar_email(r.email);
      CONTINUE WHEN v_email_norm IS NULL;

      SELECT ie.person_id INTO v_person_id FROM identity_edge ie
      WHERE ie.identifier_type = 'email' AND ie.identifier_value = v_email_norm
      LIMIT 1;

      IF v_person_id IS NOT NULL AND r.nome IS NOT NULL THEN
        -- Compara com os nomes JÁ ligados a esta person (via lead OU contact).
        SELECT max(similarity(lower(r.nome), lower(nomes.nome))) INTO v_max_sim
        FROM (
          SELECT l2.nome FROM identity_edge ie2 JOIN lead l2 ON l2.source_system=ie2.source_system AND l2.source_id=ie2.source_record_id
          WHERE ie2.person_id = v_person_id AND l2.nome IS NOT NULL
          UNION ALL
          SELECT c2.nome FROM identity_edge ie2 JOIN contact c2 ON c2.source_system=ie2.source_system AND c2.source_id=ie2.source_record_id
          WHERE ie2.person_id = v_person_id AND c2.nome IS NOT NULL
        ) nomes;

        IF v_max_sim IS NOT NULL AND v_max_sim < 0.3 THEN
          -- CONFLITO: e-mail bate, mas o nome diverge demais para presumir
          -- que é a mesma pessoa (ex.: e-mail corporativo genérico
          -- compartilhado). NÃO funde — cria person própria + candidate.
          INSERT INTO person (nome_canonico) VALUES (r.nome) RETURNING id INTO v_novo_person_id;
          INSERT INTO identity_candidate (person_a_id, person_b_id, score, confidence, signal, status, explicacao)
          VALUES (
            LEAST(v_person_id, v_novo_person_id), GREATEST(v_person_id, v_novo_person_id),
            v_max_sim, LEAST(GREATEST(v_max_sim, 0.01), 0.99),
            'email_identico_nome_divergente', 'conflito',
            format('E-mail "%s" idêntico, mas nome "%s" diverge demais (similaridade %s) dos nomes já ligados a este e-mail — NÃO fundido automaticamente, requer revisão humana (R18).', v_email_norm, r.nome, round(v_max_sim::numeric, 2))
          )
          ON CONFLICT (person_a_id, person_b_id) DO NOTHING;
          v_person_id := v_novo_person_id;
        END IF;
      END IF;

      IF v_person_id IS NULL THEN
        INSERT INTO person (nome_canonico) VALUES (r.nome) RETURNING id INTO v_person_id;
      END IF;

      INSERT INTO identity_edge (person_id, identifier_type, identifier_value, source_system, source_record_id, confidence)
      VALUES (v_person_id, 'email', v_email_norm, r.source_system, r.source_id, 1)
      ON CONFLICT ON CONSTRAINT identity_edge_source_system_source_record_id_identifier_typ_key DO NOTHING;
      v_count := v_count + 1;
    END LOOP;
  END;
  identifier_type := 'email'; edges_criados := v_count; RETURN NEXT;

  -- UUID do contato do RD Station (inalterado).
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
  'v2 (migration 032): igual a 027, mas o match por e-mail agora detecta CONFLITO (nome divergente demais) antes de fundir — protege contra e-mail corporativo genérico compartilhado por pessoas diferentes (R18). ConvertedAccountId e rdstation_uuid inalterados.';
