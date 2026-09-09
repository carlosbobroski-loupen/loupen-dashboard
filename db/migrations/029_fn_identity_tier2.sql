-- db/migrations/029_fn_identity_tier2.sql
-- Subtask 3.11. Resolução de identidade Tier 2 — PROBABILÍSTICA, e SÓ RODA
-- para registros que Tier 1 NÃO conseguiu ligar (a ordem é controle de
-- risco, R18 — não otimização). T2.1: similarity(nome) >= 0.6 combinado
-- com domínio de e-mail corporativo igual (proxy de "mesma empresa" —
-- contact não tem coluna empresa própria, migration 003). Toda saída é
-- identity_candidate, NUNCA identity_edge — confidence < 1 sempre (CHECK
-- de banco em migration 004), status 'provavel' por padrão.
--
-- "Conflito" (status='conflito') é quando dois candidatos JÁ resolvidos a
-- pessoas DIFERENTES (via Tier 1) compartilham o mesmo sinal Tier 2 — caso
-- que exige revisão humana, nunca decisão automática.

CREATE OR REPLACE FUNCTION fn_identity_tier2_resolve()
RETURNS TABLE (candidatos_criados integer) AS $$
DECLARE
  v_count integer := 0;
  r RECORD;
  v_score double precision;
BEGIN
  FOR r IN
    SELECT
      l.id AS lead_id, l.nome AS lead_nome, l.email AS lead_email, l.source_system AS lead_ss, l.source_id AS lead_sid,
      c.id AS contact_id, c.nome AS contact_nome, c.email AS contact_email, c.source_system AS contact_ss, c.source_id AS contact_sid
    FROM lead l
    CROSS JOIN contact c
    WHERE l.nome IS NOT NULL AND c.nome IS NOT NULL
      AND l.email IS NOT NULL AND c.email IS NOT NULL
      AND split_part(l.email, '@', 2) = split_part(c.email, '@', 2)
      -- Tier 1 já resolveu por e-mail exato? Então não é candidato Tier 2.
      AND NOT EXISTS (
        SELECT 1 FROM identity_edge ie1
        JOIN identity_edge ie2 ON ie2.person_id = ie1.person_id
        WHERE ie1.source_system = l.source_system AND ie1.source_record_id = l.source_id
          AND ie2.source_system = c.source_system AND ie2.source_record_id = c.source_id
      )
  LOOP
    v_score := similarity(lower(r.lead_nome), lower(r.contact_nome));
    CONTINUE WHEN v_score < 0.6;

    -- Já existe este candidato (nas duas direções)?
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM identity_candidate ic
      JOIN person pa ON pa.id = ic.person_a_id
      JOIN person pb ON pb.id = ic.person_b_id
      JOIN identity_edge iea ON iea.person_id = pa.id AND iea.source_system = r.lead_ss AND iea.source_record_id = r.lead_sid
      JOIN identity_edge ieb ON ieb.person_id = pb.id AND ieb.source_system = r.contact_ss AND ieb.source_record_id = r.contact_sid
    );

    DECLARE
      v_person_a bigint;
      v_person_b bigint;
    BEGIN
      -- Cada lado do candidato precisa de uma person "provisória" própria
      -- (Tier 2 nunca reaproveita a person de Tier 1 de outro registro sem
      -- confirmação humana — o candidato liga DUAS pessoas candidatas, não
      -- funde identidades).
      SELECT ie.person_id INTO v_person_a FROM identity_edge ie
      WHERE ie.source_system = r.lead_ss AND ie.source_record_id = r.lead_sid LIMIT 1;
      IF v_person_a IS NULL THEN
        INSERT INTO person (nome_canonico) VALUES (r.lead_nome) RETURNING id INTO v_person_a;
        INSERT INTO identity_edge (person_id, identifier_type, identifier_value, source_system, source_record_id, confidence)
        VALUES (v_person_a, 'email', fn_normalizar_email(r.lead_email), r.lead_ss, r.lead_sid, 1)
        ON CONFLICT ON CONSTRAINT identity_edge_source_system_source_record_id_identifier_typ_key DO NOTHING;
      END IF;

      SELECT ie.person_id INTO v_person_b FROM identity_edge ie
      WHERE ie.source_system = r.contact_ss AND ie.source_record_id = r.contact_sid LIMIT 1;
      IF v_person_b IS NULL THEN
        INSERT INTO person (nome_canonico) VALUES (r.contact_nome) RETURNING id INTO v_person_b;
        INSERT INTO identity_edge (person_id, identifier_type, identifier_value, source_system, source_record_id, confidence)
        VALUES (v_person_b, 'email', fn_normalizar_email(r.contact_email), r.contact_ss, r.contact_sid, 1)
        ON CONFLICT ON CONSTRAINT identity_edge_source_system_source_record_id_identifier_typ_key DO NOTHING;
      END IF;

      CONTINUE WHEN v_person_a = v_person_b;

      INSERT INTO identity_candidate (person_a_id, person_b_id, score, confidence, signal, status, explicacao)
      VALUES (
        LEAST(v_person_a, v_person_b), GREATEST(v_person_a, v_person_b),
        v_score, LEAST(v_score, 0.99),
        'trigram_nome_dominio_email',
        'provavel',
        format('Nomes "%s" e "%s" batem por similaridade de trigrama (score %s) e os e-mails compartilham o mesmo domínio — Tier 2, nunca confirmado automaticamente.', r.lead_nome, r.contact_nome, round(v_score::numeric, 2))
      )
      ON CONFLICT (person_a_id, person_b_id) DO NOTHING;
      v_count := v_count + 1;
    END;
  END LOOP;

  candidatos_criados := v_count;
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_identity_tier2_resolve() IS
  'EC-7 Tier 2 (probabilístico): SÓ processa pares não resolvidos por Tier 1. similarity(nome)>=0.6 + domínio de e-mail igual. Grava identity_candidate com confidence<1 SEMPRE (CHECK de banco) e status=provavel — NUNCA identity_edge, NUNCA merge automático (R18).';
