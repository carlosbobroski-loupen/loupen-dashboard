-- db/queries/verificacao/identidade-ec7.sql
-- Subtask 3.12. Três casos de EC-7, cada um ancorado num par semeado
-- (migrations 028/030/031/033) para ser um teste determinístico, não uma
-- leitura vaga do estado do banco.

-- (a) Tier 1 persistido com e-mail normalizado corretamente (lowercase,
-- sufixo +tag removido) — lead com "pessoa.tier1+promo@exemplo.com" tem
-- que ter gravado "pessoa.tier1@exemplo.com" em identity_edge.
DO $$
DECLARE v_valor text;
BEGIN
  SELECT ie.identifier_value INTO v_valor
  FROM identity_edge ie
  WHERE ie.source_system = 'seed_test' AND ie.source_record_id = 'seed-t1-lead' AND ie.identifier_type = 'email';

  IF v_valor IS DISTINCT FROM 'pessoa.tier1@exemplo.com' THEN
    RAISE EXCEPTION 'EC-7(a) violado: e-mail Tier 1 esperado "pessoa.tier1@exemplo.com", encontrado "%".', v_valor;
  END IF;
  RAISE NOTICE 'EC-7(a) OK: e-mail normalizado corretamente em Tier 1.';
END $$;

-- (b) Tier 2 gera candidato com confidence < 1, NUNCA vínculo direto — o
-- par "Patricia .../Patrícia ..." (score alto) tem que estar em
-- identity_candidate, e as duas persons têm que continuar SEPARADAS (sem
-- identity_edge ligando os dois source_record_id à MESMA person).
DO $$
DECLARE
  v_existe_candidato boolean;
  v_mesma_person boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM identity_candidate ic
    JOIN identity_edge iea ON iea.person_id = ic.person_a_id AND iea.source_record_id = 'seed-t2b-lead'
    JOIN identity_edge ieb ON ieb.person_id = ic.person_b_id AND ieb.source_record_id = 'seed-t2b-contact'
    WHERE ic.status = 'provavel' AND ic.confidence < 1
  ) INTO v_existe_candidato;

  IF NOT v_existe_candidato THEN
    RAISE EXCEPTION 'EC-7(b) violado: par Tier 2 de alta similaridade (seed-t2b-*) deveria ter gerado identity_candidate provavel com confidence<1.';
  END IF;

  SELECT (iea.person_id = ieb.person_id) INTO v_mesma_person
  FROM identity_edge iea, identity_edge ieb
  WHERE iea.source_record_id = 'seed-t2b-lead' AND ieb.source_record_id = 'seed-t2b-contact';

  IF v_mesma_person THEN
    RAISE EXCEPTION 'EC-7(b) violado: Tier 2 fundiu automaticamente as duas persons (mesma person_id) — NUNCA deveria mesclar sem confirmação humana.';
  END IF;
  RAISE NOTICE 'EC-7(b) OK: candidato Tier 2 criado com confidence<1, persons continuam separadas.';
END $$;

-- (c) Conflito vai para identity_candidate com status='conflito' — o par
-- seed-conflito-a/b (mesmo e-mail, nomes divergentes) tem que estar
-- marcado como conflito, com persons separadas.
DO $$
DECLARE
  v_status text;
  v_mesma_person boolean;
BEGIN
  SELECT ic.status INTO v_status
  FROM identity_candidate ic
  JOIN identity_edge iea ON iea.person_id = ic.person_a_id AND iea.source_record_id IN ('seed-conflito-a','seed-conflito-b')
  JOIN identity_edge ieb ON ieb.person_id = ic.person_b_id AND ieb.source_record_id IN ('seed-conflito-a','seed-conflito-b')
  LIMIT 1;

  IF v_status IS DISTINCT FROM 'conflito' THEN
    RAISE EXCEPTION 'EC-7(c) violado: par seed-conflito-a/b (mesmo e-mail, nomes divergentes) deveria estar marcado como conflito, encontrado status=%.', v_status;
  END IF;

  SELECT (iea.person_id = ieb.person_id) INTO v_mesma_person
  FROM identity_edge iea, identity_edge ieb
  WHERE iea.source_record_id = 'seed-conflito-a' AND ieb.source_record_id = 'seed-conflito-b';

  IF v_mesma_person THEN
    RAISE EXCEPTION 'EC-7(c) violado: conflito foi fundido na mesma person mesmo assim — nunca deveria mesclar automaticamente um conflito.';
  END IF;
  RAISE NOTICE 'EC-7(c) OK: conflito detectado e persons mantidas separadas.';
END $$;
