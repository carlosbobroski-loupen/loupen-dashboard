-- db/queries/verificacao/i5.sql
-- Subtask 3.4 (V5). I5: percentual de Não atribuído por canal e período,
-- com ALERTA (não bloqueio — é sinal de negócio, não integridade de
-- schema) acima de 15%. RAISE WARNING, não EXCEPTION — "alerta" no texto
-- do plano é deliberado: acima do limiar é indício de falha de
-- RASTREAMENTO, a ser investigado, não um estado inválido que deva parar
-- pipeline nenhum.

SELECT
  date_trunc('month', classified_at) AS periodo,
  count(*) FILTER (WHERE segmento = 'NaoAtribuido') AS nao_atribuidos,
  count(*) AS total,
  ROUND(100.0 * count(*) FILTER (WHERE segmento = 'NaoAtribuido') / NULLIF(count(*), 0), 1) AS pct_nao_atribuido
FROM lead_origin_classification
WHERE valid_to IS NULL
GROUP BY 1
ORDER BY 1;

DO $$
DECLARE
  pct numeric;
  total_geral integer;
BEGIN
  SELECT count(*) INTO total_geral FROM lead_origin_classification WHERE valid_to IS NULL;
  IF total_geral = 0 THEN
    RAISE NOTICE 'I5: nenhuma classificação corrente ainda — nada a alertar (base vazia, esperado antes de 2.16/ingestão real).';
    RETURN;
  END IF;

  SELECT 100.0 * count(*) FILTER (WHERE segmento = 'NaoAtribuido') / total_geral INTO pct
  FROM lead_origin_classification WHERE valid_to IS NULL;

  IF pct > 15 THEN
    RAISE WARNING 'I5: % %% de leads correntes estão Não atribuído (limiar de alerta: 15%%) — investigar como falha de RASTREAMENTO, não como resultado de negócio.', ROUND(pct, 1);
  ELSE
    RAISE NOTICE 'I5: % %% de Não atribuído — dentro do esperado (limiar de alerta: 15%%).', ROUND(pct, 1);
  END IF;
END $$;
