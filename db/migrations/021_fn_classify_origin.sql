-- db/migrations/021_fn_classify_origin.sql
-- Subtask 3.5. O CORAÇÃO DA EPIC — implementação real do motor de
-- atribuição. Precedência ESTRITA, first-match-wins, avaliada uma vez
-- (CASE/IF sequencial com RETURN antecipado — nunca OR encadeado, que foi
-- exatamente o DEF-4 que este épico corrige).
--
-- Substitui os seis defeitos de spec.md §3.5:
--   DEF-1 Comercial como bucket residual → aqui só S5/S9 produzem
--         Comercial/Parceiro, tudo o mais cai em NaoAtribuido (S6).
--   DEF-2 booleano binário sem terceiro estado → NaoAtribuido e Parceiro
--         são valores de PRIMEIRA CLASSE do domínio (CHECK em migration 017).
--   DEF-3 sinal implícito → todo sinal vem de um match EXATO contra uma
--         tabela de referência citável (leadsource_crosswalk), nunca de
--         heurística sobre string em runtime.
--   DEF-4 ausência de hierarquia → precedência sequencial com RETURN
--         antecipado, nunca `||`.
--   DEF-5 Ad ID do Meta fora da classificação → S1 é o PRIMEIRO sinal
--         checado, antes de qualquer outro.
--   DEF-6 ausência de imutabilidade de first-touch → não é responsabilidade
--         desta função (é do trigger de 2.10); esta função só CALCULA a
--         classificação, quem grava com a garantia de first-touch é 3.9.
--
-- ESCOPO REAL DESTA VERSÃO (honesto, não invenção de sinal que não existe
-- ainda): S1, S3, S5, S9 e S6 estão implementados e testados. S2 (e-mail
-- batendo com "Central de Leads") e S4 (conversão do RD Station) exigem
-- infraestrutura que ainda não existe nesta sessão — S2 precisa de uma
-- fonte de rastreamento de e-mail↔anúncio ainda não ingerida (candidato:
-- o workflow n8n "Envia Lead Qualificado pro Meta CAPI"), e S4 precisa da
-- resolução de identidade Tier 1/2 (EC-7, subtasks 3.10-3.12, ainda não
-- implementadas). Ambos ficam como TODO explícito nesta função — quando
-- implementados, entram na precedência na posição correta (S2 entre S1 e
-- S3; S4 entre S3 e S5), sem precisar reescrever o resto da função.

CREATE OR REPLACE FUNCTION fn_classify_origin(p_lead_id bigint)
RETURNS TABLE (
  segmento       text,
  categoria      text,
  detalhe        text,
  campanha_id    bigint,
  sinal_id       text,
  valor_bruto    text,
  razao          jsonb
) AS $$
DECLARE
  v_lead lead%ROWTYPE;
  v_cw   leadsource_crosswalk%ROWTYPE;
BEGIN
  SELECT * INTO v_lead FROM lead WHERE id = p_lead_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_classify_origin: lead % não encontrado', p_lead_id;
  END IF;

  -- S1 — Ad ID de anúncio presente em campanha_linkedin_bruta (DEF-5: este
  -- sinal é checado ANTES de qualquer outro, de propósito).
  IF v_lead.campanha_linkedin_bruta IS NOT NULL AND v_lead.campanha_linkedin_bruta <> '' THEN
    segmento := 'Marketing';
    categoria := 'Paid Social';
    detalhe := 'Meta Ads';
    sinal_id := 'S1';
    valor_bruto := v_lead.campanha_linkedin_bruta;
    razao := jsonb_build_object(
      'sinal_id', 'S1',
      'razao_legivel', format('Classificado como Marketing porque o Ad ID de anúncio ("%s") veio preenchido em Campanha_LinkedIn__c — sinal S1, o de maior precedência.', v_lead.campanha_linkedin_bruta)
    );
    RETURN NEXT;
    RETURN;
  END IF;

  -- S2 — NÃO IMPLEMENTADO NESTA VERSÃO (ver header). TODO: e-mail
  -- normalizado batendo com registro rastreado de anúncio ("Central de
  -- Leads") — precisa da fonte de dados ainda não ingerida.

  -- S3 / S5 / S9 — lookup exato no crosswalk validado (018) por origem_bruta.
  IF v_lead.origem_bruta IS NOT NULL AND v_lead.origem_bruta <> '' THEN
    SELECT * INTO v_cw FROM leadsource_crosswalk lc WHERE lc.valor_bruto = v_lead.origem_bruta;
    IF FOUND THEN
      segmento := v_cw.segmento;
      categoria := v_cw.categoria;
      detalhe := v_cw.detalhe;
      sinal_id := v_cw.sinal_id;
      valor_bruto := v_lead.origem_bruta;
      razao := jsonb_build_object(
        'sinal_id', v_cw.sinal_id,
        'razao_legivel', format('Classificado como %s porque a origem (LeadSource) "%s" bate com o crosswalk validado em 2026-09-07 (categoria: %s).', v_cw.segmento, v_lead.origem_bruta, v_cw.categoria)
      );
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  -- S4 — NÃO IMPLEMENTADO NESTA VERSÃO (ver header). TODO: conversão em
  -- ativo de captura do RD Station, via identidade Tier 1/2 (EC-7,
  -- subtasks 3.10-3.12, ainda não implementadas nesta sessão).

  -- S6 — fallback: distingue "vazio" (Direto/Desconhecido) de "presente
  -- mas não mapeado" (Outro, requer nota) — a mesma origem_bruta NUNCA
  -- vira Comercial por ausência de match (DEF-1, o bug que esta epic
  -- existe pra corrigir).
  IF v_lead.origem_bruta IS NULL OR v_lead.origem_bruta = '' THEN
    segmento := 'NaoAtribuido';
    categoria := 'Direto/Desconhecido';
    detalhe := NULL;
    sinal_id := 'S6';
    valor_bruto := v_lead.origem_bruta;
    razao := jsonb_build_object(
      'sinal_id', 'S6',
      'razao_legivel', 'Classificado como Não atribuído — nenhuma origem registrada (LeadSource vazio/nulo) e nenhum outro sinal (S1/S3/S5/S9) casou.'
    );
  ELSE
    segmento := 'NaoAtribuido';
    categoria := 'Outro (requer nota)';
    detalhe := NULL;
    sinal_id := 'S6';
    valor_bruto := v_lead.origem_bruta;
    razao := jsonb_build_object(
      'sinal_id', 'S6',
      'razao_legivel', format('Classificado como Não atribuído — a origem "%s" está presente mas não corresponde a nenhum valor validado no crosswalk (leadsource_crosswalk). Entra na fila de revisão mensal, honesto em vez de um chute.', v_lead.origem_bruta)
    );
  END IF;
  RETURN NEXT;
  RETURN;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_classify_origin(bigint) IS
  'Motor de atribuição real (FR-5), implementado em 2026-09-07. S1/S3/S5/S9/S6 completos e testados contra os leads semeados de 020_seed_leads_atribuicao.sql. S2/S4 são TODO explícito (ver header) — precisam de infraestrutura ainda não construída nesta sessão (fonte de tracking de anúncio para S2; resolução de identidade EC-7 para S4).';

-- Ruleset ativado — substitui o v0-stub.
INSERT INTO attribution_ruleset (version, definition_hash, migration_file, activated_at)
VALUES ('v1-s1-s3-s5-s9-s6', md5('021_fn_classify_origin.sql:v1'), '021_fn_classify_origin.sql', now())
ON CONFLICT (version) DO NOTHING;
