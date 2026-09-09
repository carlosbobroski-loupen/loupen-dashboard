-- db/migrations/039_lead_funnel_stage_event.sql
-- Subtask 2.17, segunda metade (P-ING-5 parte 2): estágio de funil do RD
-- Station. funnel_stage (migration 003, DM-8) existia como catálogo mas
-- SEM nenhuma tabela de fato por lead/contato — esta migration fecha essa
-- lacuna real, encontrada ao construir a ingestão de verdade.
--
-- Vocabulário de estágio NÃO é pré-semeado aqui: testado ao vivo nesta
-- sessão via contact_funnel_stage_get (RD Station), o campo real é
-- `lifecycle_stage` (ex.: "Qualified Lead") — em inglês, diferente do
-- `lead_stage` em português visto no payload do webhook de conversão
-- ("Lead Qualificado"). São dois campos/vocabulários REAIS mas DISTINTOS
-- da mesma plataforma; nenhum enum completo foi observado, então
-- funnel_stage.nome é upsertado dinamicamente pelo valor real que a API
-- devolver (mesmo padrão já usado para `campaign` por código), nunca uma
-- lista fixa adivinhada. `ordem` fica NULL até o usuário decidir uma
-- ordenação real (Artigo IV: não inventar).
--
-- occurred_on é DATE (não timestamptz), mesmo motivo de lead_touchpoint
-- (migration 006): a API do RD Station para estágio de funil não expõe
-- histórico timestamped, só o estado atual no momento da consulta —
-- granularidade real é "por execução do pull", não intradiária.
--
-- Detecção de MUDANÇA (não heartbeat diário): fica a cargo da função de
-- ingestão (fn_run_ingest_batch, migration seguinte) só inserir uma linha
-- nova quando o estágio difere do último registrado para aquele lead —
-- esta tabela por si só permite duplicatas por dia se a função não filtrar,
-- de propósito (a tabela não impõe a regra de negócio, a função impõe).

CREATE TABLE IF NOT EXISTS lead_funnel_stage_event (
  id                    bigserial PRIMARY KEY,
  lead_id               bigint NOT NULL REFERENCES lead(id),
  funnel_stage_ref_id   bigint NOT NULL REFERENCES funnel_stage(id),
  occurred_on           date NOT NULL,
  fonte                 text NOT NULL DEFAULT 'rd_station',
  collected_at          timestamptz NOT NULL,
  ingested_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lead_id, funnel_stage_ref_id, occurred_on)
);
COMMENT ON TABLE lead_funnel_stage_event IS
  'DM-8 por lead: histórico de mudança de lifecycle_stage do RD Station, distinto de StageName da Opportunity (Salesforce) — nunca comparados/somados (mesma regra de funnel_stage, migration 003). UNIQUE em (lead_id, funnel_stage_ref_id, occurred_on) é só uma trava de idempotência técnica contra reprocessar o mesmo lote; a regra de negócio real (só gravar quando o estágio MUDA) vive na função de ingestão.';

-- Idempotência real para lead_touchpoint (S7): a tabela original (migration
-- 006) não tinha nenhuma UNIQUE — reexecutar o mesmo lote de eventos de
-- workflow duplicaria touchpoints indefinidamente. workflow_ref_id pode ser
-- NULL (touchpoint sem workflow mapeado) — o índice parcial só cobre o caso
-- com workflow, que é o único que a ingestão de 2.17 vai gravar.
CREATE UNIQUE INDEX IF NOT EXISTS uq_lead_touchpoint_workflow_evento
  ON lead_touchpoint (lead_id, workflow_ref_id, tipo, occurred_on)
  WHERE workflow_ref_id IS NOT NULL;
