-- db/migrations/070_ordem_do_funil_rd.sql
-- Fecha a pendencia deixada aberta de proposito pela migration 039.
--
-- CONTEXTO: o vocabulario de funnel_stage vem da FONTE (upsert dinamico a
-- partir do que a API do RD Station devolve), nunca de um enum adivinhado.
-- Por isso `ordem` nasceu NULL: o nome de um estagio e dado, mas a ORDEM
-- entre eles e decisao de negocio -- a API nao a expoe.
--
-- DECISAO (2026-09-14): Lead (1) -> Qualified Lead (2) -> Client (3). E o
-- funil padrao do RD Station, e os tres valores observados na base sao
-- exatamente esses tres. Nao ha etapa intermediaria nos dados.
--
-- POR QUE NAO UM CHECK OU NOT NULL: estagio novo que apareca na fonte amanha
-- deve continuar entrando com ordem NULL, visivel e sem ordem, em vez de ser
-- recusado na ingestao ou receber uma ordem inventada. A regra do epico e a
-- mesma de sempre: o desconhecido aparece feio, nao some.

UPDATE funnel_stage SET ordem = 1 WHERE origem = 'rd_station' AND nome = 'Lead';
UPDATE funnel_stage SET ordem = 2 WHERE origem = 'rd_station' AND nome = 'Qualified Lead';
UPDATE funnel_stage SET ordem = 3 WHERE origem = 'rd_station' AND nome = 'Client';

COMMENT ON COLUMN funnel_stage.ordem IS
  'Ordem de negocio do estagio no funil. NULL = estagio veio da fonte e ainda nao foi ordenado por decisao humana -- estado valido e visivel, nunca preenchido por suposicao. Definida para o funil do RD Station na migration 070.';

DO $$
DECLARE v_sem_ordem int;
BEGIN
  SELECT count(*) INTO v_sem_ordem
  FROM funnel_stage WHERE origem = 'rd_station' AND ordem IS NULL;
  IF v_sem_ordem > 0 THEN
    RAISE NOTICE 'ATENCAO: % estagio(s) do RD Station seguem sem ordem -- apareceram depois desta migration e precisam de decisao.', v_sem_ordem;
  END IF;
END $$;
