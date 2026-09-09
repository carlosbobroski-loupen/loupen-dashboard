-- db/migrations/049_grants_sequencias_crm_ingest.sql
-- Subtask 8.6 — corrige uma lacuna de privilégio ANTERIOR a esta etapa, que
-- só apareceu agora porque esta foi a primeira tabela nova com `bigserial`
-- criada depois que o papel `crm_ingest` passou a existir.
--
-- SINTOMA
-- A ingestão de leads do RD falhou no último nó com:
--   permission denied for sequence lead_conversion_event_id_seq
-- Tudo antes funcionou: 6 contatos descobertos, 16 eventos de conversão
-- coletados, 22 linhas gravadas em staging. Só o INSERT na tabela canônica
-- caiu, porque INSERT numa coluna bigserial precisa de USAGE na sequência.
--
-- CAUSA RAIZ (verificada em pg_default_acl, não suposta)
-- Existe ALTER DEFAULT PRIVILEGES de neondb_owner concedendo a crm_ingest
-- em TABELAS (defaclobjtype = 'r' → crm_ingest=arw), e NÃO existe o
-- equivalente para SEQUÊNCIAS (defaclobjtype = 'S'). Resultado: toda tabela
-- nova nasce com INSERT/SELECT/UPDATE automáticos para crm_ingest, e a
-- sequência que a acompanha nasce sem nada. Foi o que aconteceu com
-- lead_conversion_event (migration 045).
--
-- Isso não é específico desta tabela: é uma armadilha que ia disparar na
-- PRÓXIMA tabela com bigserial, quem quer que a criasse. Por isso esta
-- migration faz duas coisas, e a segunda é a que importa.
--
--   1. Concede USAGE, SELECT nas sequências que já existem.
--   2. Registra o DEFAULT PRIVILEGE para sequências futuras, fechando a
--      classe do problema em vez do caso.
--
-- Escopo do privilégio: USAGE e SELECT, nunca UPDATE. `crm_ingest` precisa
-- consumir nextval e ler currval; não precisa poder reposicionar sequência
-- (setval), que é operação de manutenção e fica com o owner.

-- ---------------------------------------------------------------------------
-- 1. Sequências existentes
-- ---------------------------------------------------------------------------
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO crm_ingest;

-- ---------------------------------------------------------------------------
-- 2. Sequências futuras — o conserto de verdade
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE neondb_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO crm_ingest;

-- ---------------------------------------------------------------------------
-- Verificação imediata, no próprio arquivo: se alguma sequência de tabela do
-- schema public ficar sem USAGE para crm_ingest, esta migration levanta
-- exceção e o apply.sh para. Melhor falhar aqui do que descobrir no meio de
-- uma ingestão de produção, que foi exatamente como isto apareceu.
--
-- ARMADILHA DE ORDEM DE AVALIAÇÃO, encontrada ao escrever isto:
-- pôr `relkind = 'S'` e `has_sequence_privilege(...)` no mesmo WHERE FALHA com
--   ERROR: "pg_toast_16618" is not a sequence
-- porque o planner pode avaliar a função antes do filtro de relkind, e então
-- ela recebe o OID de um objeto que não é sequência. O filtro tem de ser
-- forçado a acontecer primeiro — daí a CTE MATERIALIZED, que é uma barreira
-- de otimização. `OFFSET 0` numa subconsulta teria o mesmo efeito, mas é um
-- truque menos legível.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_faltantes text;
  v_total     integer;
  v_conferidas integer;
BEGIN
  WITH seqs AS MATERIALIZED (
    SELECT c.oid, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S'
      AND n.nspname = 'public'
      AND c.relname NOT LIKE 'pg\_%'
  )
  SELECT count(*) FILTER (WHERE NOT has_sequence_privilege('crm_ingest', s.oid, 'USAGE')),
         string_agg(s.relname, ', ' ORDER BY s.relname)
           FILTER (WHERE NOT has_sequence_privilege('crm_ingest', s.oid, 'USAGE')),
         count(*)
    INTO v_total, v_faltantes, v_conferidas
  FROM seqs s;

  IF v_total > 0 THEN
    RAISE EXCEPTION 'Ficaram % sequencia(s) sem USAGE para crm_ingest: %', v_total, v_faltantes;
  END IF;

  -- Conferir que a checagem realmente examinou algo. Se v_conferidas fosse 0,
  -- a asserção passaria por vacuidade — o mesmo tipo de falso OK que o
  -- antipadrão `SELECT 1/(subquery)` produz, e que este projeto proíbe.
  IF v_conferidas = 0 THEN
    RAISE EXCEPTION 'Nenhuma sequencia encontrada em public — a verificacao passaria por vacuidade, o que nao vale como prova.';
  END IF;

  RAISE NOTICE 'OK: as % sequencias de public tem USAGE para crm_ingest.', v_conferidas;
END;
$$;
