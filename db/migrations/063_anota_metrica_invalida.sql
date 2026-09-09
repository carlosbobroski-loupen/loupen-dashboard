-- db/migrations/063_anota_metrica_invalida.sql
-- Subtask 8.20 — anota as 5 execuções cuja MÉTRICA foi computada com o bug
-- que a migration 062 corrigiu, sem reescrever número nem status.
--
-- ── O QUE NÃO FIZ, E POR QUÊ ──────────────────────────────────────────────
--
-- (a) NÃO recomputei os valores. `ingest_run` não guarda `batch_id`, então
--     não existe como ligar uma linha de execução ao lote de staging que a
--     originou. Recomputar exigiria adivinhar, e um número inventado num
--     registro de auditoria é pior que um número errado documentado.
--
-- (b) NÃO mudei o status para `partial` só para a asserção passar. Aqueles
--     lotes estavam CORRETOS — a deduplicação funcionou e nada foi perdido.
--     Rotulá-los de parciais seria mentir na direção oposta.
--
-- (c) NÃO deletei as linhas. São registro de auditoria; apagar o que
--     incomoda é o oposto do propósito da tabela.
--
-- ── O QUE FIZ ─────────────────────────────────────────────────────────────
-- Anotei cada uma com um marcador estável (`[METRICA-INVALIDA-PRE-062]`) e a
-- explicação, preservando os valores originais na própria mensagem. A
-- asserção AC-8.1 passa a EXCLUIR linhas com esse marcador — escopo
-- documentado em vez de história reescrita.
--
-- O marcador é uma string e não um id de corte de propósito: um `id <= 301`
-- seria um número mágico que ninguém entende em seis meses.
--
-- ── AS DUAS FORMAS DO MESMO BUG, VISÍVEIS NOS DADOS ───────────────────────
--   183, 186, 188  linhas de staging contra recém-inseridos: a deduplicação
--                  legítima (16→14, 136→120, 777→632) parecia perda.
--   291, 301       `rows_target = 0` numa reexecução idempotente CORRETA —
--                  o invariante AC-8.1 era incompatível com idempotência por
--                  construção, e essas duas linhas são a prova.

UPDATE ingest_run
   SET error_message = format(
         '[METRICA-INVALIDA-PRE-062] Valores originais: rows_source=%s, rows_target=%s. '
         || 'A metrica foi computada antes da migration 062: rows_source contava LINHAS DE STAGING '
         || '(fazendo a deduplicacao legitima do contrato 1.7 parecer perda de dado) e rows_target '
         || 'contava RECEM-INSERIDOS (dando 0 em reexecucao idempotente correta). O DADO destas '
         || 'execucoes esta correto; apenas a medicao estava errada. Nao recomputado porque '
         || 'ingest_run nao guarda batch_id e nao ha como ligar a execucao ao lote de origem.',
         rows_source, rows_target)
 WHERE source = 'rd_station'
   AND object = 'LeadConversion'
   AND status = 'ok'
   AND rows_source <> rows_target
   AND error_message IS NULL;

DO $$
DECLARE
  v_anotadas integer;
  v_restantes integer;
BEGIN
  SELECT count(*) INTO v_anotadas
  FROM ingest_run WHERE error_message LIKE '[METRICA-INVALIDA-PRE-062]%';

  -- Quantas execucoes AINDA violam o invariante sem estarem anotadas. Se
  -- isto for > 0 depois desta migration, existe uma violacao NOVA e real que
  -- a anotacao nao cobre — e o alerta tem de aparecer aqui.
  SELECT count(*) INTO v_restantes
  FROM ingest_run
  WHERE status = 'ok' AND rows_source <> rows_target
    AND coalesce(error_message, '') NOT LIKE '[METRICA-INVALIDA-PRE-062]%';

  RAISE NOTICE '% execucao(oes) anotada(s) como metrica invalida pre-062.', v_anotadas;
  IF v_restantes > 0 THEN
    RAISE EXCEPTION 'Restam % execucao(oes) com status=ok e rows_source<>rows_target NAO anotadas — violacao real de AC-8.1, investigar antes de seguir.', v_restantes;
  END IF;
  RAISE NOTICE 'OK: nenhuma violacao de AC-8.1 fora da janela anotada.';
END;
$$;
