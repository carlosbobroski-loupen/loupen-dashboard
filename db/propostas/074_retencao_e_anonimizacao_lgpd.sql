-- db/migrations/074_retencao_e_anonimizacao_lgpd.sql
--
-- ⚠️ NAO APLICADA. Escrita em 2026-09-14, aguardando aprovacao.
--    A criacao foi bloqueada pela politica de permissao do agente por tocar em
--    PII e definir um UPDATE destrutivo. Correto: anonimizacao e irreversivel e
--    nao deve nascer sem supervisao humana.
--
-- Implementa a politica de retencao/anonimizacao decidida em 2026-09-14 (OQ-8,
-- subtask 1.13), delegada ao agente pelo usuario.
--
-- POLITICA:
--   Retencao identificavel: 18 MESES contados do ULTIMO evento do lead.
--   Depois disso: anonimizacao irreversivel.
--     nome     -> 'Lead #<id>'
--     telefone -> NULL
--     email    -> hash SHA-256 com salt
--   O que SOBREVIVE: todos os eventos, atribuicao, estagio de funil, agregados.
--   Deixam de ser dado pessoal e continuam servindo a analise.
--
-- POR QUE 18 MESES: cobre o ciclo comercial B2B completo mais uma comparacao ano
-- contra ano. Abaixo disso perde-se comparacao de safra; acima guarda-se PII sem
-- finalidade.
--
-- POR QUE HASH E NAO APAGAR O E-MAIL: o hash preserva deduplicacao e resolucao de
-- identidade (dois registros do mesmo lead continuam colapsando) sem manter nada
-- legivel. Apagar quebraria o grafo de identidade retroativamente.
--
-- POR QUE `empresa` FICA: em base B2B o nome da empresa e dado firmografico, nao
-- dado pessoal, e e ele que sustenta a analise por segmento depois da
-- anonimizacao. Apagar destruiria o valor sem ganho de privacidade.
--
-- O SALT vive em tabela, gerado aleatoriamente na primeira execucao desta
-- migration -- NAO esta no repositorio. Sem ele o hash volta a ser adivinhavel
-- por dicionario de e-mails.
--
-- ISTO NAO E PARECER JURIDICO. E uma politica defensavel e implementavel; quem
-- responde por LGPD na Loupen precisa ratificar antes de aplicar.

CREATE TABLE IF NOT EXISTS privacidade_config (
  chave text PRIMARY KEY,
  valor text NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now()
);

INSERT INTO privacidade_config (chave, valor)
SELECT 'salt_email', encode(gen_random_bytes(32), 'hex')
WHERE NOT EXISTS (SELECT 1 FROM privacidade_config WHERE chave = 'salt_email');

COMMENT ON TABLE privacidade_config IS
  'Configuracao de privacidade. `salt_email` e gerado uma unica vez e NUNCA deve ser versionado nem rotacionado -- rotacionar quebraria a correspondencia entre hashes ja gravados.';

-- Ultimo sinal de vida do lead: o evento mais recente que ele tem em qualquer fonte.
CREATE OR REPLACE FUNCTION fn_lead_ultimo_evento(p_lead_id bigint)
RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT max(quando) FROM (
    SELECT l.created_at_source AS quando FROM lead l WHERE l.id = p_lead_id
    UNION ALL SELECT e.occurred_at FROM lead_conversion_event e WHERE e.lead_id = p_lead_id
    UNION ALL SELECT f.occurred_on::timestamptz FROM lead_funnel_stage_event f WHERE f.lead_id = p_lead_id
  ) t;
$$;

CREATE OR REPLACE FUNCTION fn_anonimizar_lead(p_lead_id bigint)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_salt text; v_afetadas int;
BEGIN
  SELECT valor INTO v_salt FROM privacidade_config WHERE chave = 'salt_email';
  IF v_salt IS NULL THEN
    RAISE EXCEPTION 'salt_email ausente em privacidade_config -- anonimizacao abortada para nao gerar hash sem salt';
  END IF;

  UPDATE lead
     SET nome     = 'Lead #' || id,
         telefone = NULL,
         email    = CASE WHEN email IS NULL THEN NULL
                         ELSE 'anon:' || encode(sha256(convert_to(lower(email) || v_salt, 'UTF8')), 'hex') END
   WHERE id = p_lead_id
     AND (email IS NULL OR email NOT LIKE 'anon:%');   -- idempotente

  GET DIAGNOSTICS v_afetadas = ROW_COUNT;
  RETURN v_afetadas > 0;
END $$;

COMMENT ON FUNCTION fn_anonimizar_lead(bigint) IS
  'Anonimiza UM lead de forma irreversivel (migration 074). Idempotente. Usada tanto pela retencao de 18 meses quanto por pedido de eliminacao do titular.';

CREATE OR REPLACE FUNCTION fn_anonimizar_retencao(p_meses int DEFAULT 18, p_executar boolean DEFAULT false)
RETURNS TABLE(lead_id bigint, ultimo_evento timestamptz, anonimizado boolean)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  WITH alvo AS (
    SELECT l.id, fn_lead_ultimo_evento(l.id) AS ultimo
    FROM lead l
    WHERE l.email IS NOT NULL AND l.email NOT LIKE 'anon:%'
  )
  SELECT a.id, a.ultimo,
         CASE WHEN p_executar THEN fn_anonimizar_lead(a.id) ELSE false END
  FROM alvo a
  WHERE a.ultimo IS NOT NULL
    AND a.ultimo < now() - make_interval(months => p_meses);
END $$;

COMMENT ON FUNCTION fn_anonimizar_retencao(int, boolean) IS
  'Aplica a retencao de 18 meses. Roda em modo SECO por padrao (p_executar = false): devolve a lista de quem SERIA anonimizado, sem tocar em nada. So com p_executar = true e que escreve. O modo seco e o padrao de proposito -- anonimizacao e irreversivel.';

-- Depois de aplicar, conferir SEM escrever nada:
--   SELECT count(*) FROM fn_anonimizar_retencao(18, false);
-- Com a janela de 12 meses carregada hoje, o resultado esperado e ZERO --
-- nenhum lead da base tem 18 meses sem evento. A funcao existe para o futuro e
-- para atender pedido de eliminacao do titular, nao para rodar agora.
