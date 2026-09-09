-- db/migrations/008_attribution_classification_versioned.sql
-- Subtask 2.10. [AUTO-DECISION — ADR-016, a formalizar em phase-6]
-- carryForwardToPlan pedia "o DDL da estrutura de versionamento de
-- reclassificação exigida por I4". Efetivo-datado, append-only: responde
-- às três perguntas de I4 simultaneamente (quem, quando, de-para) e ainda
-- permite ler o estado corrente em uma query barata pelo índice parcial.
-- Trade-off aceito: escrita mais cara e todo SELECT de estado atual precisa
-- filtrar valid_to IS NULL — mitigado pela ordem de centenas/milhares de
-- leads (NFR-2, não é volume de big data).

CREATE TABLE IF NOT EXISTS attribution_ruleset (
  version           text PRIMARY KEY,
  definition_hash   text NOT NULL,
  migration_file    text NOT NULL,
  activated_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE attribution_ruleset IS
  'Liga cada linha de lead_origin_classification à versão da regra (função fn_classify_origin, phase-3) que a produziu — sem isso a matriz de transição de V1 não é reproduzível.';

CREATE TABLE IF NOT EXISTS lead_origin_classification (
  id                 bigserial PRIMARY KEY,
  lead_id            bigint NOT NULL REFERENCES lead(id),
  version            integer NOT NULL,
  segmento           text NOT NULL CHECK (segmento IN ('Marketing', 'Comercial', 'NaoAtribuido')),
  categoria          text,
  detalhe            text,
  campanha_id        bigint REFERENCES campaign(id),
  sinal_id           text,
  valor_bruto        text,
  razao              jsonb NOT NULL,
  is_first_touch     boolean NOT NULL DEFAULT false,
  ruleset_version    text REFERENCES attribution_ruleset(version),
  classified_at      timestamptz NOT NULL DEFAULT now(),
  classified_by      text NOT NULL,
  supersedes_id      bigint REFERENCES lead_origin_classification(id),
  reclass_reason     text,
  valid_from         timestamptz NOT NULL DEFAULT now(),
  valid_to           timestamptz,
  CHECK (classified_by NOT LIKE 'reclass:%' OR reclass_reason IS NOT NULL),
  UNIQUE (lead_id, version)
);

COMMENT ON TABLE lead_origin_classification IS
  'Histórico append-only, efetivo-datado, da classificação de origem por lead (I3/I4). NUNCA fazer UPDATE de uma linha do histórico exceto valid_to (fechar uma versão) — enforçado por trigger em 009, não só por convenção.';
COMMENT ON COLUMN lead_origin_classification.razao IS
  'NOT NULL: razão auditável (NFR-7) é obrigatória em toda classificação, nunca opcional.';
COMMENT ON COLUMN lead_origin_classification.is_first_touch IS
  'I3: gravado uma única vez por lead e nunca sobrescrito por reingestão — enforçado por trigger em 009 (segunda linha com is_first_touch=true para o mesmo lead é rejeitada).';
COMMENT ON COLUMN lead_origin_classification.reclass_reason IS
  'CHECK garante: se classified_by começa com "reclass:", reclass_reason é obrigatório — reclassificação sem razão é impossível de gravar.';

-- Índice único PARCIAL: no máximo UMA versão "corrente" (valid_to IS NULL)
-- por lead — é o que torna ler o estado atual uma query barata em vez de
-- precisar agregar o histórico inteiro a cada leitura.
CREATE UNIQUE INDEX IF NOT EXISTS idx_lead_origin_classification_current
  ON lead_origin_classification (lead_id)
  WHERE valid_to IS NULL;
