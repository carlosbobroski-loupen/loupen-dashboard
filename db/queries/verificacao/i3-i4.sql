-- db/queries/verificacao/i3-i4.sql
-- Subtask 3.4 (V5). I3/I4 testam a estrutura de versionamento de 2.10
-- (triggers já provados na prática nessa subtask) — aqui a asserção é
-- sobre os DADOS, não o DDL: nenhum lead com mais de um first-touch,
-- nenhum lead com mais de uma versão corrente.
--
-- I3: first-touch gravado uma vez por lead, nunca sobrescrito por reingestão.
-- I4: reclassificação é versionada (nova linha), nunca mutação do histórico.

-- Parte 1 — relatório humano de I3.
SELECT lead_id, count(*) AS linhas_first_touch
FROM lead_origin_classification
WHERE is_first_touch = true
GROUP BY lead_id
HAVING count(*) > 1;

-- Parte 2 — asserção de I3.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM (
    SELECT lead_id FROM lead_origin_classification
    WHERE is_first_touch = true GROUP BY lead_id HAVING count(*) > 1
  ) x;
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'I3 violado: % lead(s) com mais de uma linha is_first_touch=true — first-touch foi sobrescrito por reingestão.', ofensoras;
  END IF;
END $$;

-- Parte 1 — relatório humano de I4 (mais de uma versão corrente por lead —
-- o índice único parcial de 2.10 já impede isso na escrita; esta é a
-- checagem de defesa em profundidade sobre os dados existentes).
SELECT lead_id, count(*) AS versoes_correntes
FROM lead_origin_classification
WHERE valid_to IS NULL
GROUP BY lead_id
HAVING count(*) > 1;

-- Parte 2 — asserção de I4.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM (
    SELECT lead_id FROM lead_origin_classification
    WHERE valid_to IS NULL GROUP BY lead_id HAVING count(*) > 1
  ) x;
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'I4 violado: % lead(s) com mais de uma versão corrente (valid_to IS NULL) — o índice único parcial de 2.10 deveria ter impedido isso.', ofensoras;
  END IF;
END $$;
