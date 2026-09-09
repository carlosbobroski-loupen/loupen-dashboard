-- db/migrations/015_conversion_event_source_id.sql
-- BUG REAL encontrado testando 2.17 end-to-end: reprocessar o mesmo
-- batch_id duplicava linhas em conversion_event, porque o INSERT não tinha
-- ON CONFLICT — não havia coluna alguma que identificasse o evento de
-- origem de forma única (violação de P-ING-1: reingestão idempotente).
--
-- Fix: conversion_event ganha source_event_id (o identificador único do
-- evento na origem — no RD Station, o event_uuid dentro de
-- __cdp__original_event, presente no payload real do webhook). Índice
-- único PARCIAL (WHERE source_event_id IS NOT NULL): eventos sem
-- identificador de origem rastreável continuam podendo existir (não é um
-- erro), só não participam da dedup automática — honesto em vez de
-- inventar uma chave sintética para forçar unicidade onde a origem não dá.

ALTER TABLE conversion_event ADD COLUMN IF NOT EXISTS source_event_id text;

-- Tabela particionada por RANGE(occurred_at): todo índice único PRECISA
-- incluir a coluna de partição (regra do Postgres). occurred_at entra no
-- índice por essa exigência técnica, não porque faça parte do conceito de
-- unicidade em si — dois eventos com o mesmo source_event_id mas
-- occurred_at NULL (data não rastreável) não seriam pegos por este índice
-- (NULL nunca é "igual" a outro NULL numa constraint de unicidade); é um
-- limite residual honesto, não escondido, do caso raro "evento com id mas
-- sem data".
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversion_event_source_unique
  ON conversion_event (source_system, source_event_id, occurred_at)
  WHERE source_event_id IS NOT NULL;

COMMENT ON COLUMN conversion_event.source_event_id IS
  'Identificador único do evento NA ORIGEM (ex.: event_uuid do RD Station) — chave real de idempotência (P-ING-1). NULL é aceito (evento sem identificador rastreável na origem), mas então a reingestão pode duplicar esse evento específico — limite conhecido, documentado, não escondido.';
