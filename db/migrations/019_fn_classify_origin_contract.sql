-- db/migrations/019_fn_classify_origin_contract.sql
-- Subtask 3.3. Contrato de fn_classify_origin ANTES da implementação
-- (V5/3.4 precisa de algo contra o que compilar). Assinatura fixada aqui;
-- corpo é um stub que RAISE — estado vermelho legítimo e verificável, não
-- "não implementado" silencioso.
--
-- P1: o segmento é PROJEÇÃO do nível 1 de uma taxonomia de 4 níveis
-- (segmento/categoria/detalhe/campanha), NUNCA um campo escrito
-- diretamente — por isso a função retorna todos os níveis + o sinal + a
-- razão auditável (NFR-7), nunca só o segmento.

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
BEGIN
  RAISE EXCEPTION 'fn_classify_origin: not implemented (contrato de 3.3, implementação real em 3.5/migration 021)';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_classify_origin(bigint) IS
  'Motor de atribuição (FR-5, o coração da epic). Contrato fixado em 3.3; implementação real em 3.5 (migration 021), só depois de V3 (018_leadsource_crosswalk) e V4 (017_segmento_parceiro) resolvidos.';

-- Linha inicial em attribution_ruleset (migration 008) — toda classificação
-- referencia a versão da regra que a produziu.
INSERT INTO attribution_ruleset (version, definition_hash, migration_file, activated_at)
VALUES ('v0-stub', 'n/a-stub-nao-implementado', '019_fn_classify_origin_contract.sql', now())
ON CONFLICT (version) DO NOTHING;
