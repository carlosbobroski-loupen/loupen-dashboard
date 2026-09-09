-- db/queries/verificacao/recordtype-fr11.sql
-- Subtask 3.8. FR-11/AC-11.1/EC-11: a chave de agrupamento por
-- Produto/Serviço é RecordType.Name (opportunity.record_type_name),
-- JAMAIS LeadSource/origem_bruta. Varre TODAS as views e funções do
-- schema public e falha se alguma agrupar (GROUP BY) por origem_bruta —
-- é verificação de DEFINIÇÃO (o texto da view/função), não só de dado.

-- Parte 1 — relatório humano: views/funções cujo texto contém um GROUP BY
-- envolvendo origem_bruta.
SELECT n.nspname AS schema, p.proname AS nome, 'function' AS tipo
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
  AND pg_get_functiondef(p.oid) ~* 'group\s+by[^;]*origem_bruta'
UNION ALL
SELECT schemaname, viewname, 'view'
FROM pg_views
WHERE schemaname = 'public'
  AND definition ~* 'group\s+by[^;]*origem_bruta';

-- Parte 2 — asserção.
DO $$
DECLARE ofensoras integer;
BEGIN
  SELECT count(*) INTO ofensoras FROM (
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
      AND pg_get_functiondef(p.oid) ~* 'group\s+by[^;]*origem_bruta'
    UNION ALL
    SELECT viewname::regclass::oid FROM pg_views
    WHERE schemaname = 'public' AND definition ~* 'group\s+by[^;]*origem_bruta'
  ) x;
  IF ofensoras > 0 THEN
    RAISE EXCEPTION 'FR-11/AC-11.1 violado: % view(s)/função(ões) agrupam por origem_bruta — Produto/Serviço TEM de ser agrupado por record_type_name, nunca por LeadSource.', ofensoras;
  END IF;
  RAISE NOTICE 'FR-11 OK: nenhuma view/função agrupa por origem_bruta.';
END $$;
