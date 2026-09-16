-- db/queries/verificacao/null-nao-vence-ganho.sql
--
-- Verificação da migration 093 — NULL não vence ganho no desempate de fase.
--
-- Rodar:
--   set -a; . ./.env; set +a
--   /opt/homebrew/opt/libpq/bin/psql "$NEON_DATABASE_URL" -f db/queries/verificacao/null-nao-vence-ganho.sql
--
-- O PROBLEMA DESTE TESTE, E POR QUE ELE TEM DUAS PARTES. Na base real o
-- defeito mede ZERO casos (a 092 mapeou os órfãos). Rodar "conte quantas
-- pessoas com vitória aparecem como NULL" devolveria 0 antes e depois da
-- correção: verde vazio, que não prova nada. Por isso a query 1 CRIA a
-- condição (estágio novo, não mapeado, na conta de quem ganhou) e a query 2
-- isola a semântica do ORDER BY contra um controle com o bug.

\echo '=== 1. REGRESSAO PONTA A PONTA — o defeito, recriado na view real ======='
-- `email:1316` tem 2 oportunidades Ganhas. Recebe, dentro de transação
-- revertida, uma oportunidade num estágio que ninguém mapeou -- exatamente o
-- que acontece quando a org cria estágio novo no Setup. Antes da 093 isso
-- devolvia fase NULL e o nome cru do estágio no lugar de "Ganho".
BEGIN;
  INSERT INTO opportunity (source_system, source_id, account_id, stage_name, amount, collected_at)
  VALUES ('probe_093', 'probe-093-estagio-novo', 19368, 'Estagio Novo Que Ninguem Mapeou Ainda', 0, now());

  SELECT pessoa_chave, qtd_ganhas, qtd_estagio_sem_fase, fase_mais_avancada, estagio_mais_avancado,
         CASE WHEN fase_mais_avancada = 'ganho' AND estagio_mais_avancado = 'Ganho'
              THEN 'OK — estagio desconhecido nao esconde mais a vitoria'
              ELSE 'FALHA — o desempate voltou a deixar NULL vencer' END AS veredito
  FROM view_pessoa_jornada_desfecho WHERE pessoa_chave = 'email:1316';
ROLLBACK;

\echo ''
\echo '=== 2. CONTROLE NEGATIVO — a assercao consegue falhar? ================='
-- A mesma expressão, com e sem a correção, sobre o caso mínimo: uma pessoa com
-- `ganho` (ordem 5) e um estágio sem fase. `com_o_bug` TEM de devolver NULL.
-- Se devolvesse 'ganho', a query 1 estaria passando por acaso e não pela
-- correção.
WITH t(fase, ordem) AS (VALUES ('ganho', 5), (NULL, NULL))
SELECT
  (array_agg(fase ORDER BY (fase = 'ganho') DESC,            ordem DESC NULLS LAST))[1] AS com_o_bug,
  (array_agg(fase ORDER BY (fase = 'ganho') DESC NULLS LAST, ordem DESC NULLS LAST))[1] AS corrigido,
  CASE WHEN (array_agg(fase ORDER BY (fase = 'ganho') DESC, ordem DESC NULLS LAST))[1] IS NULL
        AND (array_agg(fase ORDER BY (fase = 'ganho') DESC NULLS LAST, ordem DESC NULLS LAST))[1] = 'ganho'
       THEN 'OK — o controle com o bug falha, o corrigido passa'
       ELSE 'FALHA — o teste nao distingue as duas versoes' END AS veredito
FROM t;

\echo ''
\echo '=== 3. VARREDURA — sobrou algum desempate sem NULLS LAST? =============='
-- No catálogo VIVO (views e funções), não nos arquivos de migration. Conta
-- OBJETOS que contêm o padrão, não ocorrências: 2 views, 3 ocorrências.
SELECT count(*) FILTER (WHERE d ~ 'ganho''::text\) DESC,')            AS objetos_com_bug,
       count(*) FILTER (WHERE d ~ 'ganho''::text\) DESC NULLS LAST')  AS objetos_corrigidos,
       CASE WHEN count(*) FILTER (WHERE d ~ 'ganho''::text\) DESC,') = 0
            THEN 'OK' ELSE 'FALHA: ainda ha desempate com NULLS FIRST implicito' END AS veredito
FROM (
  SELECT pg_get_viewdef(c.oid, true) AS d FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('v','m')
  UNION ALL
  SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
) x;

\echo ''
\echo '=== 4. NADA MAIS MUDOU — distribuicao de fase na base real ============='
-- Esperado idêntico ao de antes da 093: perdido 164, ganho 77, negociacao 24,
-- qualificacao 15, contato 12, reuniao 11, e NENHUM NULL.
SELECT coalesce(fase_mais_avancada, '(sem fase)') AS fase, count(*)
FROM view_pessoa_jornada_desfecho WHERE qtd_oportunidades > 0
GROUP BY 1 ORDER BY 2 DESC;

\echo ''
\echo '=== 5. fn_search_pessoas INTACTA — force_custom_plan preservado ========'
-- A 093 não toca na função (ela LÊ a view, não reimplementa o desempate).
-- Conferido no catálogo porque `DROP FUNCTION` descartaria o ajuste da 089.
SELECT proname, proconfig,
       CASE WHEN proconfig @> ARRAY['plan_cache_mode=force_custom_plan'] THEN 'OK' ELSE 'FALHA' END AS veredito
FROM pg_proc WHERE proname IN ('fn_search_pessoas', 'fn_search_leads') ORDER BY 1;
