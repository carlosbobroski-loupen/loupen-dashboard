-- db/migrations/076_reclassificar_quando_a_regra_muda.sql
--
-- CORRIGE UM DEFEITO QUE TORNAVA A RECLASSIFICACAO IMPOSSIVEL.
--
-- fn_reclassificar_lead desistia cedo com esta guarda:
--
--     IF v_versao_atual.valor_bruto IS NOT DISTINCT FROM v_result.valor_bruto
--       THEN RETURN false;
--
-- O comentario original explica a intencao, e ela e legitima: "Nada mudou: nao
-- versiona. Evita uma versao nova por execucao de pull."
--
-- MAS a guarda compara o SINAL BRUTO, e isso embute a suposicao de que a unica
-- coisa que pode mudar e o DADO. Quando a REGRA muda -- uma entrada nova em
-- leadsource_crosswalk -- o valor_bruto continua identico e a funcao retorna
-- false sem reavaliar nada. A classificacao guardada fica presa na regra antiga
-- para sempre.
--
-- COMO ISSO APARECEU (2026-09-15): a migration 075 acrescentou 54 regras ao
-- crosswalk, incluindo as 18 origens de conversao do RD Station. Conferido
-- chamando fn_classify_origin direto: `Webinar-GoTo-07-26` ja devolvia
-- Marketing / Evento-Webinar. Mas rodar fn_reclassificar_lead nos 7.551 leads
-- nao mudou UMA linha -- todos os 475 leads do RD seguiam 'NaoAtribuido'.
-- O motor sabia a resposta certa e a tabela guardava a errada.
--
-- Isso quebrava o objetivo central do epico: "leads do RD gerados por
-- marketing" continuaria sendo um conjunto vazio mesmo depois de a regra
-- existir.
--
-- A CORRECAO: comparar o RESULTADO, nao a entrada. Se a classificacao que sai
-- hoje e diferente da que esta guardada -- em segmento, categoria, detalhe,
-- sinal ou valor bruto -- versiona. Se for igual em tudo, nao versiona. A
-- intencao original (nao gerar versao por pull) fica preservada: pull que nao
-- muda nada continua nao gerando versao, porque o resultado continua igual.
--
-- E o motivo registrado passa a distinguir as duas causas, que e o que ADR-016
-- pede para ser auditavel: mudou o dado, ou mudou a regra?

CREATE OR REPLACE FUNCTION public.fn_reclassificar_lead(p_lead_id bigint)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  v_result             RECORD;
  v_versao_atual       lead_origin_classification%ROWTYPE;
  v_proxima_versao     integer;
  v_ja_teve_first_touch boolean;
  v_sinal_mudou        boolean;
  v_motivo             text;
BEGIN
  SELECT * INTO v_result FROM fn_classify_origin(p_lead_id);

  SELECT * INTO v_versao_atual FROM lead_origin_classification
  WHERE lead_id = p_lead_id AND valid_to IS NULL;

  -- Nada mudou NO RESULTADO: nao versiona. Preserva a intencao original (nao
  -- gerar uma versao por execucao de pull) sem cegar a funcao para mudanca de
  -- regra -- ver cabecalho da migration 076.
  IF v_versao_atual.id IS NOT NULL
     AND v_versao_atual.valor_bruto IS NOT DISTINCT FROM v_result.valor_bruto
     AND v_versao_atual.segmento    IS NOT DISTINCT FROM v_result.segmento
     AND v_versao_atual.categoria   IS NOT DISTINCT FROM v_result.categoria
     AND v_versao_atual.detalhe     IS NOT DISTINCT FROM v_result.detalhe
     AND v_versao_atual.sinal_id    IS NOT DISTINCT FROM v_result.sinal_id THEN
    RETURN false;
  END IF;

  v_sinal_mudou := v_versao_atual.id IS NOT NULL
                   AND v_versao_atual.valor_bruto IS DISTINCT FROM v_result.valor_bruto;

  SELECT EXISTS (
    SELECT 1 FROM lead_origin_classification WHERE lead_id = p_lead_id AND is_first_touch = true
  ) INTO v_ja_teve_first_touch;

  SELECT COALESCE(MAX(version), 0) + 1 INTO v_proxima_versao
  FROM lead_origin_classification WHERE lead_id = p_lead_id;

  IF v_versao_atual.id IS NOT NULL THEN
    UPDATE lead_origin_classification SET valid_to = now() WHERE id = v_versao_atual.id;
  END IF;

  -- Distingue as DUAS causas possiveis, que e o que torna a reclassificacao
  -- auditavel (ADR-016): o dado mudou, ou a regra mudou?
  v_motivo := CASE
    WHEN v_versao_atual.id IS NULL THEN NULL
    WHEN v_sinal_mudou THEN format(
      'Sinal bruto mudou de "%s" para "%s" entre execucoes de ingestao.',
      v_versao_atual.valor_bruto, v_result.valor_bruto)
    ELSE format(
      'Sinal bruto inalterado ("%s"); a REGRA mudou. Classificacao foi de %s/%s para %s/%s.',
      v_result.valor_bruto,
      v_versao_atual.segmento, coalesce(v_versao_atual.categoria,'-'),
      v_result.segmento, coalesce(v_result.categoria,'-'))
  END;

  INSERT INTO lead_origin_classification (
    lead_id, version, segmento, categoria, detalhe, campanha_id, sinal_id, valor_bruto, razao,
    is_first_touch, ruleset_version, classified_by, supersedes_id, reclass_reason, valid_from
  ) VALUES (
    p_lead_id, v_proxima_versao, v_result.segmento, v_result.categoria, v_result.detalhe,
    v_result.campanha_id, v_result.sinal_id, v_result.valor_bruto, v_result.razao,
    NOT v_ja_teve_first_touch,
    'v1-s1-s3-s5-s9-s6',
    CASE WHEN v_versao_atual.id IS NOT NULL THEN 'reclass:fn_reclassificar_lead' ELSE 'ingest:fn_reclassificar_lead' END,
    v_versao_atual.id,
    v_motivo,
    now()
  );
  RETURN true;
END;
$function$;

COMMENT ON FUNCTION fn_reclassificar_lead(bigint) IS
  'Reclassifica um lead e versiona SE o resultado mudou (nao apenas se o sinal bruto mudou) -- ver migration 076. reclass_reason distingue "o dado mudou" de "a regra mudou".';
