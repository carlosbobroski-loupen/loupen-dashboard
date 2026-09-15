-- db/queries/verificacao/receita-fr10.sql
-- Subtask 3.8. FR-10/EC-5: (a) oportunidade NÃO Ganha nunca expõe valor de
-- contrato; (b) Ganha sem Amount na origem nunca recebe um número presumido —
-- contrato fica indisponível, com o motivo explícito.
--
-- REESCRITA NA MIGRATION 088. A versão anterior checava "Ganha SEM DURAÇÃO
-- conhecida nunca recebe contrato". Essa cláusula MORREU junto com a fórmula:
-- desde que `Amount` passou a ser lido como o VALOR TOTAL da oportunidade,
-- `duracao_meses_contrato` não é mais insumo do cálculo, e desconhecer a
-- duração deixou de impedir qualquer coisa. Checar uma condição que não existe
-- mais daria verde por vacuidade — pior do que não checar.
-- A lacuna que restou é outra: Ganha com `Amount` vazio na origem (379 das
-- 2.554 Ganhas, medido em 2026-09-15).

-- Parte 1 — relatório humano.
SELECT opportunity_id, source_id, stage_name, amount, mrr, duracao_meses_contrato,
       contrato_valor, contrato_indisponivel_motivo
FROM view_receita
WHERE (stage_name IS DISTINCT FROM 'Ganho' AND contrato_valor IS NOT NULL)
   OR (stage_name = 'Ganho' AND amount IS NULL AND contrato_valor IS NOT NULL);

-- Parte 2 — asserção.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM view_receita
  WHERE (stage_name IS DISTINCT FROM 'Ganho' AND contrato_valor IS NOT NULL)
     OR (stage_name = 'Ganho' AND amount IS NULL AND contrato_valor IS NOT NULL);
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'FR-10/EC-5 violado: % linha(s) de view_receita expõem contrato_valor indevidamente (não-Ganha com contrato, ou Ganha sem Amount com contrato inventado).', ofensoras;
  END IF;
  RAISE NOTICE 'FR-10/EC-5 OK: nenhuma linha ofensora em view_receita.';
END $$;

-- Parte 3 — TESTE NEGATIVO da própria asserção.
-- Verde só vale se o vermelho for alcançável. Injeta uma linha ofensora
-- sintética (não-Ganha com contrato preenchido) sobre o MESMO predicado da
-- Parte 2 e exige que ele acuse. Se esta parte passar em silêncio, a Parte 2
-- estava dando verde por construção, não por mérito. Nada é escrito no banco.
DO $$
DECLARE pegou integer;
BEGIN
  SELECT count(*) INTO pegou
  FROM (VALUES ('Negociação'::text, NULL::numeric, 999.0::numeric)) AS falsa(stage_name, amount, contrato_valor)
  WHERE (falsa.stage_name IS DISTINCT FROM 'Ganho' AND falsa.contrato_valor IS NOT NULL)
     OR (falsa.stage_name = 'Ganho' AND falsa.amount IS NULL AND falsa.contrato_valor IS NOT NULL);
  IF pegou <> 1 THEN
    RAISE EXCEPTION 'TESTE NEGATIVO FALHOU: o predicado da Parte 2 não acusou uma linha comprovadamente ofensora. A asserção estava dando verde por vacuidade.';
  END IF;
  RAISE NOTICE 'Teste negativo OK: o predicado acusa ofensora quando existe uma.';
END $$;

-- Parte 4 — a lacuna real, medida e visível (nunca escondida).
SELECT
  count(*) FILTER (WHERE stage_name = 'Ganho')                       AS ganhas,
  count(*) FILTER (WHERE stage_name = 'Ganho' AND amount IS NULL)    AS ganhas_sem_amount,
  count(*) FILTER (WHERE stage_name = 'Ganho' AND amount = 0)        AS ganhas_amount_zero,
  count(*) FILTER (WHERE contrato_valor IS NOT NULL)                 AS com_contrato,
  sum(contrato_valor)                                                AS soma_contrato
FROM view_receita;
