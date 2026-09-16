-- db/queries/verificacao/funil-status-do-lead.sql
--
-- VERIFICAÇÃO DAS MIGRATIONS 105 E 106.
--
-- REGRA DESTE ÉPICO: uma asserção só vale depois de eu PROVAR QUE ELA CONSEGUE
-- FALHAR. Foram SETE verdes vazios até aqui; o oitavo quase entrou ontem
-- (`has_function_privilege` devolve `true` para função com `proacl` NULL, ver
-- `leads-e-categoria-na-aba.sql` bloco H1b). Cada bloco abaixo tem duas metades:
-- o estado REAL, e a MESMA checagem escrita de forma incompleta — ou o banco num
-- estado quebrado de propósito, dentro de transação revertida — mostrando a
-- diferença.
--
-- ⚠️ ESTE ARQUIVO TEM UM PAPEL A MAIS QUE OS OUTROS, e já cobrou o preço dele.
-- A `status_ressalva` da função é PROSA DATADA com números dentro, e prosa não
-- se recalcula sozinha. O bloco C recalcula cada um ao vivo.
--
-- FOI ELE QUE DERRUBOU A PRÓPRIA MIGRATION 105, horas depois de aplicá-la: os
-- dois números que a 105 usava para provar "Rejeitado é automação" — amplitude
-- semanal de 0,0%–93,5% e "90,9% criados antes de 2026-08-17" — NÃO
-- DISCRIMINAM. `Aberto` varia 94,6 pontos nas mesmas semanas, e a taxa base da
-- coorte é 82,2%, o que deixa o lift em 1,11×. A conclusão continuava certa; a
-- prova, não. A migration 106 trocou a prova pela comparação com a CAMPANHA
-- CONSTANTE, que reproduz.
--
-- Por isso os blocos C3 e C4 continuam medindo os números REFUTADOS, com a
-- asserção invertida: eles têm de continuar NÃO discriminando. Apagar um teste
-- que derrubou uma afirmação é como a afirmação volta.
--
-- Rodar inteiro:
--   psql "$NEON_DATABASE_URL" -f db/queries/verificacao/funil-status-do-lead.sql
--
-- Nenhum bloco deixa efeito: todos os que escrevem terminam em ROLLBACK.

\set ON_ERROR_STOP on
\pset pager off

-- ═════════════════════════════════════════════════════════════════════════════
-- A. A PARTIÇÃO FECHA — INCLUINDO A LINHA `(sem status)`
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- A1. a soma dos status = total do recorte, e a linha sem status existe ---'
SELECT sum(qtd_leads)                                      AS soma_dos_status,
       max(total_do_recorte)                               AS total,
       sum(qtd_leads_que_viraram_oportunidade)             AS soma_virou,
       max(total_que_virou_oportunidade)                   AS total_virou,
       count(*) FILTER (WHERE status IS NULL)              AS linhas_sem_status,
       round(sum(pct_do_recorte))                          AS soma_dos_pcts,
       CASE WHEN sum(qtd_leads) = max(total_do_recorte)
             AND sum(qtd_leads_que_viraram_oportunidade) = max(total_que_virou_oportunidade)
             AND count(*) FILTER (WHERE status IS NULL) = 1
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- A2. TESTE NEGATIVO: a mesma soma IGNORANDO a linha `(sem status)`.'
\echo '---     Tem de ficar CURTA — são os 521 leads do RD Station. ---'
SELECT sum(qtd_leads)                                      AS soma_completa,
       sum(qtd_leads) FILTER (WHERE status IS NOT NULL)    AS soma_sem_a_linha_nula,
       max(total_do_recorte)                               AS total,
       sum(qtd_leads) FILTER (WHERE status IS NULL)        AS leads_que_sumiriam,
       CASE WHEN sum(qtd_leads) = max(total_do_recorte)
             AND sum(qtd_leads) FILTER (WHERE status IS NOT NULL) <> max(total_do_recorte)
            THEN 'OK — a checagem distingue somar e não somar a linha nula'
            ELSE 'FALHOU — ou não há linha nula, ou a checagem não a enxerga' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- A3. a função bate com a query direta, status a status (zero linhas = vale) ---'
WITH da_funcao AS (
  SELECT status AS st, qtd_leads, qtd_leads_que_viraram_oportunidade AS virou
  FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text))
),
direta AS (
  SELECT nullif(trim(l.status), '') AS st,
         count(*) AS n,
         count(*) FILTER (WHERE l.converted_opportunity_id IS NOT NULL
                             OR l.converted_account_id     IS NOT NULL) AS virou
  FROM lead l
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE NOT l.is_teste AND l.created_at_source >= now() - interval '12 months'
  GROUP BY 1
),
-- UNION + dois LEFT JOIN no lugar de FULL OUTER JOIN: a chave é `status`, que
-- é NULL na linha "(sem status)", e casar NULL com NULL exige
-- `IS NOT DISTINCT FROM` — que o PostgreSQL recusa como condição de FULL JOIN.
-- Com `=` a linha nula nunca casaria e apareceria como divergência FALSA.
chaves AS (SELECT st FROM da_funcao UNION SELECT st FROM direta)
SELECT coalesce(k.st, '(sem status)') AS status,
       f.qtd_leads AS funcao, d.n AS direta, f.virou AS funcao_virou, d.virou AS direta_virou,
       'FALHOU — a função e a query direta discordam' AS veredito
FROM chaves k
LEFT JOIN da_funcao f ON f.st IS NOT DISTINCT FROM k.st
LEFT JOIN direta    d ON d.st IS NOT DISTINCT FROM k.st
WHERE f.qtd_leads IS DISTINCT FROM d.n OR f.virou IS DISTINCT FROM d.virou;

\echo '--- A4. TESTE NEGATIVO COM ESCRITA (revertido): troco o status de 30 leads'
\echo '---     por string VAZIA. Eles TÊM de cair na linha `(sem status)`, não'
\echo '---     criar uma 15ª linha invisível. ---'
BEGIN;
  CREATE TEMP TABLE _a4 ON COMMIT DROP AS
    SELECT count(*) AS linhas, sum(qtd_leads) FILTER (WHERE status IS NULL) AS sem_status
    FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

  UPDATE lead SET status = '' WHERE id IN (
    SELECT l.id FROM lead l
    WHERE NOT l.is_teste AND l.status = 'Aberto'
      AND l.created_at_source >= now() - interval '12 months'
    ORDER BY l.id LIMIT 30);

  SELECT a.sem_status                                        AS sem_status_antes,
         sum(f.qtd_leads) FILTER (WHERE f.status IS NULL)    AS sem_status_depois,
         sum(f.qtd_leads) FILTER (WHERE f.status = '')       AS numa_linha_de_string_vazia,
         sum(f.qtd_leads) = max(f.total_do_recorte)          AS soma_ainda_fecha,
         CASE WHEN sum(f.qtd_leads) FILTER (WHERE f.status IS NULL) = a.sem_status + 30
               AND coalesce(sum(f.qtd_leads) FILTER (WHERE f.status = ''), 0) = 0
               AND sum(f.qtd_leads) = max(f.total_do_recorte)
              THEN 'OK — vazio e NULL caem na MESMA linha, e a soma fecha'
              ELSE 'FALHOU — string vazia criou balde separado' END AS veredito
  FROM _a4 a, fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text)) f
  GROUP BY a.sem_status;
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. O INNER JOIN COM A CLASSIFICAÇÃO NÃO DESCARTA NINGUÉM
-- ═════════════════════════════════════════════════════════════════════════════
-- A função junta `lead` com `lead_origin_classification` por INNER JOIN para
-- poder filtrar por segmento/categoria. Isso só é seguro enquanto TODO lead
-- tiver classificação vigente. Hoje tem — e este bloco é o que garante que o
-- dia em que deixar de ter apareça, em vez de a função encolher em silêncio.

\echo '--- B1. zero leads não-teste sem classificação vigente ---'
SELECT count(*) AS leads_nao_teste,
       count(*) FILTER (WHERE NOT EXISTS (
         SELECT 1 FROM lead_origin_classification c
         WHERE c.lead_id = l.id AND c.valid_to IS NULL)) AS sem_classificacao,
       CASE WHEN count(*) FILTER (WHERE NOT EXISTS (
              SELECT 1 FROM lead_origin_classification c
              WHERE c.lead_id = l.id AND c.valid_to IS NULL)) = 0
            THEN 'OK — o INNER JOIN da 105 não descarta ninguém'
            ELSE 'FALHOU — há lead sem classificação e a função o está perdendo' END AS veredito
FROM lead l WHERE NOT l.is_teste;

\echo '--- B2. TESTE NEGATIVO COM ESCRITA (revertido): expiro a classificação de'
\echo '---     25 leads. A função TEM de encolher exatamente 25 — é a prova de'
\echo '---     que B1 não é decorativo. ---'
BEGIN;
  CREATE TEMP TABLE _b2 ON COMMIT DROP AS
    SELECT max(total_do_recorte) AS n FROM fn_funil_status_do_lead('{}'::jsonb);

  UPDATE lead_origin_classification SET valid_to = now()
   WHERE id IN (SELECT c.id FROM lead_origin_classification c
                 JOIN lead l ON l.id = c.lead_id
                WHERE c.valid_to IS NULL AND NOT l.is_teste
                ORDER BY c.id LIMIT 25);

  SELECT b.n AS antes, max(f.total_do_recorte) AS depois,
         b.n - max(f.total_do_recorte) AS perdidos,
         CASE WHEN b.n - max(f.total_do_recorte) = 25
              THEN 'OK — B1 tem dentes: sem classificação, o lead some mesmo'
              ELSE 'FALHOU — B1 não vigia nada' END AS veredito
  FROM _b2 b, fn_funil_status_do_lead('{}'::jsonb) f
  GROUP BY b.n;
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. A RESSALVA É PROSA DATADA — AQUI ELA É RECALCULADA, E AS PROVAS QUE
--    CAÍRAM CONTINUAM SENDO TESTADAS PARA QUE NINGUÉM AS REINTRODUZA
-- ═════════════════════════════════════════════════════════════════════════════
-- HISTÓRICO, e é o ponto deste bloco: a migration 105 sustentou "Rejeitado é
-- automação" com dois números que NÃO discriminam, e foi o teste negativo aqui
-- que derrubou os dois. A migration 106 corrigiu a prosa. Os números refutados
-- continuam medidos abaixo — agora com a asserção INVERTIDA: eles TÊM de
-- continuar não discriminando. Se um dia passarem a discriminar, isso é notícia
-- e o certo é reavaliar, não reintroduzi-los em silêncio.

\echo '--- C1. A PROVA QUE SUSTENTA: mesma campanha, meses diferentes ---'
SELECT origem_bruta, count(*) AS leads,
       count(*) FILTER (WHERE status = 'Rejeitado') AS rejeitados,
       round(100.0 * count(*) FILTER (WHERE status='Rejeitado') / count(*), 1) AS pct
FROM lead
WHERE NOT is_teste AND source_system = 'salesforce'
  AND origem_bruta ILIKE '%LOGMEIN%RESCUE%LICENCA%'
GROUP BY 1 ORDER BY 1;

\echo '--- C2. a asserção: com a CAMPANHA CONSTANTE, a rejeição despenca de'
\echo '---     jul/ago para setembro. É isto que a ressalva da 106 cita. ---'
WITH m AS (
  SELECT substring(origem_bruta from '(0[1-9]|1[0-2])') AS mes,
         count(*) AS n, count(*) FILTER (WHERE status='Rejeitado') AS r
  FROM lead
  WHERE NOT is_teste AND source_system='salesforce'
    AND origem_bruta ILIKE 'LOGMEIN_RESCUE-LICENCA-ECO%'
  GROUP BY 1
)
SELECT max(round(100.0*r/n,1)) FILTER (WHERE mes IN ('07','08')) AS pct_jul_ago,
       max(round(100.0*r/n,1)) FILTER (WHERE mes = '09')          AS pct_set,
       count(*)                                                   AS meses_medidos,
       CASE WHEN count(*) >= 3
             AND max(round(100.0*r/n,1)) FILTER (WHERE mes IN ('07','08'))
               > 3 * max(round(100.0*r/n,1)) FILTER (WHERE mes='09')
            THEN 'OK — campanha controlada, rejeição cai 10x+; a prova da 106 vale'
            ELSE 'FALHOU — a prova da ressalva não reproduz mais; reavaliar a 106' END AS veredito
FROM m;

\echo '--- C3. REFUTADO (a): a amplitude semanal NÃO discrimina Rejeitado.'
\echo '---     `Aberto` varia MAIS nas mesmas semanas. A asserção é que isso'
\echo '---     CONTINUE assim — o número não pode voltar como prova. ---'
WITH sem AS (
  SELECT date_trunc('week', created_at_source)::date AS s, count(*) AS n,
         count(*) FILTER (WHERE status='Rejeitado')   AS r,
         count(*) FILTER (WHERE status='Aberto')      AS a
  FROM lead
  WHERE NOT is_teste AND source_system='salesforce'
    AND created_at_source >= now() - interval '12 months'
  GROUP BY 1 HAVING count(*) >= 30
)
SELECT max(round(100.0*r/n,1)) - min(round(100.0*r/n,1)) AS amplitude_rejeitado,
       max(round(100.0*a/n,1)) - min(round(100.0*a/n,1)) AS amplitude_aberto,
       CASE WHEN (max(round(100.0*a/n,1)) - min(round(100.0*a/n,1)))
                 >= (max(round(100.0*r/n,1)) - min(round(100.0*r/n,1)))
            THEN 'OK — segue sem discriminar (Aberto varia igual ou mais); prova refutada'
            ELSE 'ATENÇÃO — a amplitude passou a ser específica de Rejeitado; reavaliar a 106' END AS veredito
FROM sem;

\echo '--- C4. REFUTADO (b): a coorte de criação quase não discrimina.'
\echo '---     90,9% em Rejeitado contra 82,2% de TAXA BASE = lift 1,11x. ---'
WITH b AS (
  SELECT count(*) AS n_todos,
         count(*) FILTER (WHERE created_at_source < DATE '2026-08-17') AS antes_todos,
         count(*) FILTER (WHERE status='Rejeitado') AS n_rej,
         count(*) FILTER (WHERE status='Rejeitado' AND created_at_source < DATE '2026-08-17') AS antes_rej
  FROM lead
  WHERE NOT is_teste AND source_system='salesforce'
    AND created_at_source >= now() - interval '12 months'
)
SELECT round(100.0*antes_todos/n_todos,1) AS taxa_base_pct,
       round(100.0*antes_rej/n_rej,1)     AS rejeitado_pct,
       round((1.0*antes_rej/n_rej) / (1.0*antes_todos/n_todos), 2) AS lift,
       CASE WHEN (1.0*antes_rej/n_rej) / (1.0*antes_todos/n_todos) < 1.5
            THEN 'OK — lift baixo; segue sem ser prova, como a 106 declara'
            ELSE 'ATENÇÃO — a coorte passou a discriminar; reavaliar a 106' END AS veredito
FROM b;

\echo '--- C5. `Descalificado`: a concentração que DE FATO discrimina (lift 8,7x) ---'
WITH b AS (
  SELECT status, count(*) AS n,
         count(*) FILTER (WHERE created_at_source >= DATE '2026-06-29'
                            AND created_at_source <  DATE '2026-07-20') AS j3
  FROM lead WHERE NOT is_teste AND source_system='salesforce' GROUP BY 1 HAVING count(*) >= 60
)
SELECT max(round(100.0*j3/n,1)) FILTER (WHERE status='Descalificado')  AS pct_descalificado,
       max(round(100.0*j3/n,1)) FILTER (WHERE status <> 'Descalificado') AS pct_segundo_colocado,
       CASE WHEN max(round(100.0*j3/n,1)) FILTER (WHERE status='Descalificado')
                 > 4 * max(round(100.0*j3/n,1)) FILTER (WHERE status <> 'Descalificado')
            THEN 'OK — esta concentração discrimina, ao contrário das duas refutadas'
            ELSE 'FALHOU — perdeu o poder de discriminar; reavaliar a ressalva' END AS veredito
FROM b;

\echo '--- C6. a prosa da função CITA as provas refutadas como refutadas ---'
SELECT count(*) FILTER (WHERE status_ressalva LIKE '%O QUE SUSTENTA%')            AS diz_o_que_sustenta,
       count(*) FILTER (WHERE status_ressalva LIKE '%O QUE FOI TESTADO E NÃO SUSTENTA%') AS diz_o_que_caiu,
       count(*) FILTER (WHERE status_ressalva LIKE '%LOGMEIN%')                   AS cita_a_campanha_controlada,
       CASE WHEN count(*) FILTER (WHERE status_ressalva LIKE '%O QUE SUSTENTA%') = 1
             AND count(*) FILTER (WHERE status_ressalva LIKE '%O QUE FOI TESTADO E NÃO SUSTENTA%') = 1
             AND count(*) FILTER (WHERE status_ressalva LIKE '%LOGMEIN%') = 1
            THEN 'OK — a 106 entrou: a ressalva separa prova de prova refutada'
            ELSE 'FALHOU — a prosa da 105 ainda está no ar' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- C7. TESTE NEGATIVO de C6: a mesma busca NÃO acha a prosa antiga da 105 ---'
SELECT count(*) FILTER (WHERE status_ressalva LIKE '%fronteira de idade%')  AS prosa_105_ainda_no_ar,
       CASE WHEN count(*) FILTER (WHERE status_ressalva LIKE '%fronteira de idade%') = 0
            THEN 'OK — C6 discrimina: a frase antiga sumiu de verdade'
            ELSE 'FALHOU — a 106 não substituiu o corpo' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- C8. a ressalva é SELETIVA: 4 linhas de 20. Ressalva em tudo é ressalva em nada. ---'
SELECT count(*)                                            AS status_no_recorte,
       count(*) FILTER (WHERE status_ressalva IS NOT NULL) AS com_ressalva,
       CASE WHEN count(*) FILTER (WHERE status_ressalva IS NOT NULL) BETWEEN 1 AND 4
             AND count(*) FILTER (WHERE status_ressalva IS NULL) > count(*) FILTER (WHERE status_ressalva IS NOT NULL)
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

-- ═════════════════════════════════════════════════════════════════════════════
-- D. `Qualificado` É CARIMBO DE CONVERSÃO — A PREMISSA CENTRAL DA 105
-- ═════════════════════════════════════════════════════════════════════════════
-- Este é o bloco que derruba "93% dos qualificados viram oportunidade" como
-- medida de funil. Se algum dia D1 falhar, o cabeçalho inteiro da 105 precisa
-- ser reescrito — e é para isso que ele está aqui.

\echo '--- D1. TODO lead convertido tem status `Qualificado`, e NENHUM outro converte ---'
SELECT count(DISTINCT status)                                     AS status_distintos_entre_convertidos,
       string_agg(DISTINCT status, ', ')                          AS quais,
       count(*)                                                   AS leads_convertidos,
       CASE WHEN count(DISTINCT status) = 1
            THEN 'OK — a conversão carimba UM status só; a premissa da 105 vale'
            ELSE 'FALHOU — a premissa mudou, reescrever o cabeçalho da 105' END AS veredito
FROM lead
WHERE NOT is_teste
  AND (converted_opportunity_id IS NOT NULL OR converted_account_id IS NOT NULL);

\echo '--- D2. a função reflete isso: exatamente UMA linha marcada como carimbo ---'
SELECT count(*) FILTER (WHERE status_e_carimbo_de_conversao)       AS linhas_marcadas,
       max(qtd_status_com_conversao)                               AS status_com_conversao,
       string_agg(status, ', ') FILTER (WHERE status_e_carimbo_de_conversao) AS qual,
       CASE WHEN count(*) FILTER (WHERE status_e_carimbo_de_conversao) = 1
             AND max(qtd_status_com_conversao) = 1
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- D3. TESTE NEGATIVO COM ESCRITA (revertido): faço 5 leads `Aberto`'
\echo '---     apontarem para uma oportunidade. Agora DOIS status convertem: o'
\echo '---     marcador TEM de sumir de todas as linhas e qtd_status_com_conversao'
\echo '---     TEM de virar 2, com a ressalva avisando que a premissa mudou. ---'
BEGIN;
  UPDATE lead SET converted_opportunity_id = (
      SELECT source_id FROM opportunity WHERE source_system='salesforce' ORDER BY id LIMIT 1)
   WHERE id IN (SELECT l.id FROM lead l
                 WHERE NOT l.is_teste AND l.status = 'Aberto'
                   AND l.converted_opportunity_id IS NULL
                   AND l.created_at_source >= now() - interval '12 months'
                 ORDER BY l.id LIMIT 5);

  SELECT count(*) FILTER (WHERE status_e_carimbo_de_conversao) AS linhas_marcadas,
         max(qtd_status_com_conversao)                          AS status_com_conversao,
         count(*) FILTER (WHERE status_ressalva LIKE '%A PREMISSA DA MIGRATION 105 MUDOU%') AS avisos,
         CASE WHEN count(*) FILTER (WHERE status_e_carimbo_de_conversao) = 0
               AND max(qtd_status_com_conversao) = 2
               AND count(*) FILTER (WHERE status_ressalva LIKE '%A PREMISSA DA MIGRATION 105 MUDOU%') = 2
              THEN 'OK — a quebra da premissa é VISÍVEL, não some junto com o marcador'
              ELSE 'FALHOU — a premissa quebrou em silêncio' END AS veredito
  FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));
ROLLBACK;

\echo '--- D4. a função NÃO expõe percentual de conversão por status (bloco 🚫) ---'
SELECT count(*) FILTER (WHERE a.nome ~* '^pct.*(virou|convers)|^.*(virou|convers).*pct$') AS colunas_de_taxa,
       string_agg(a.nome, ', ') FILTER (WHERE a.nome ~* 'pct') AS colunas_pct_existentes,
       CASE WHEN count(*) FILTER (WHERE a.nome ~* '^pct.*(virou|convers)|^.*(virou|convers).*pct$') = 0
            THEN 'OK — só pct_do_recorte, que é distribuição da MESMA população'
            ELSE 'FALHOU — alguém publicou a razão sem a ressalva' END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL unnest(p.proargnames) AS a(nome)
WHERE n.nspname = 'public' AND p.proname = 'fn_funil_status_do_lead';

\echo '--- D5. TESTE NEGATIVO de D4: a regex acha o nome proibido quando ele existe ---'
SELECT 'pct_virou_oportunidade' ~* '^pct.*(virou|convers)|^.*(virou|convers).*pct$' AS acha_o_proibido,
       'pct_do_recorte'         ~* '^pct.*(virou|convers)|^.*(virou|convers).*pct$' AS acha_o_permitido,
       CASE WHEN ('pct_virou_oportunidade' ~* '^pct.*(virou|convers)|^.*(virou|convers).*pct$')
             AND NOT ('pct_do_recorte' ~* '^pct.*(virou|convers)|^.*(virou|convers).*pct$')
            THEN 'OK — a regex de D4 discrimina, logo D4 não é sempre verde'
            ELSE 'FALHOU — a regex de D4 não vale nada' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. A COBERTURA DE `status` É 0%/100% POR FONTE, NÃO 93% ESPALHADOS
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- E1. a cobertura agregada (93,1%) esconde duas populações homogêneas ---'
SELECT source_system,
       count(*) AS leads,
       count(*) FILTER (WHERE nullif(trim(status),'') IS NOT NULL) AS com_status,
       round(100.0 * count(*) FILTER (WHERE nullif(trim(status),'') IS NOT NULL) / count(*), 2) AS pct
FROM lead WHERE NOT is_teste GROUP BY 1 ORDER BY 2 DESC;

\echo '--- E2. a asserção: 100% no Salesforce, 0% no RD, e o agregado ~93% ---'
SELECT round(100.0*count(*) FILTER (WHERE nullif(trim(status),'') IS NOT NULL)/count(*),2) AS pct_agregado,
       bool_and(CASE WHEN source_system='salesforce' THEN nullif(trim(status),'') IS NOT NULL ELSE true END) AS salesforce_100,
       bool_and(CASE WHEN source_system='rd_station' THEN nullif(trim(status),'') IS NULL   ELSE true END) AS rd_zero,
       CASE WHEN bool_and(CASE WHEN source_system='salesforce' THEN nullif(trim(status),'') IS NOT NULL ELSE true END)
             AND bool_and(CASE WHEN source_system='rd_station' THEN nullif(trim(status),'') IS NULL ELSE true END)
            THEN 'OK — ausência ESTRUTURAL por fonte, não buraco de ingestão'
            ELSE 'FALHOU — a separação limpa por fonte acabou; reavaliar a ressalva da 105' END AS veredito
FROM lead WHERE NOT is_teste;

\echo '--- E3. TESTE NEGATIVO COM ESCRITA (revertido): apago o status de 10 leads'
\echo '---     do Salesforce. E2 TEM de acusar — se não acusar, ele não vigia nada. ---'
BEGIN;
  UPDATE lead SET status = NULL WHERE id IN (
    SELECT id FROM lead WHERE NOT is_teste AND source_system='salesforce'
      AND status IS NOT NULL ORDER BY id LIMIT 10);

  SELECT bool_and(CASE WHEN source_system='salesforce' THEN nullif(trim(status),'') IS NOT NULL ELSE true END) AS salesforce_100,
         CASE WHEN NOT bool_and(CASE WHEN source_system='salesforce' THEN nullif(trim(status),'') IS NOT NULL ELSE true END)
              THEN 'OK — E2 acusou o estado forçado'
              ELSE 'FALHOU — E2 é verde vazio' END AS veredito
  FROM lead WHERE NOT is_teste;
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. A ORDEM DO FUNIL NÃO FOI INVENTADA
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- F1. `funnel_stage` não tem linha nenhuma para salesforce ---'
SELECT origem, count(*) AS linhas, string_agg(nome || '=' || coalesce(ordem::text,'-'), ', ' ORDER BY ordem) AS conteudo
FROM funnel_stage GROUP BY 1 ORDER BY 1;

\echo '--- F2. logo TODA linha da função sai sem ordem declarada, e diz isso ---'
SELECT count(*)                                                AS status_no_recorte,
       count(*) FILTER (WHERE status_ordem IS NOT NULL)        AS com_ordem,
       count(*) FILTER (WHERE ordem_declarada)                 AS marcadas_como_declaradas,
       max(qtd_status_sem_ordem_declarada)                     AS contador_da_funcao,
       CASE WHEN count(*) FILTER (WHERE ordem_declarada) = 0
             AND max(qtd_status_sem_ordem_declarada) = count(*)
            THEN 'OK — nenhuma ordem inventada, e a ausência está contada'
            ELSE 'FALHOU' END AS veredito
FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));

\echo '--- F3. TESTE NEGATIVO COM ESCRITA (revertido): declaro a ordem de 2 status'
\echo '---     em `funnel_stage`. A função TEM de passar a devolvê-la sozinha,'
\echo '---     sem migration — se não passar, o LEFT JOIN é decorativo. ---'
BEGIN;
  INSERT INTO funnel_stage (origem, nome, ordem) VALUES
    ('salesforce', 'Aberto', 1), ('salesforce', 'Qualificado', 9);

  SELECT count(*) FILTER (WHERE ordem_declarada)          AS agora_com_ordem,
         max(qtd_status_sem_ordem_declarada)              AS ainda_sem_ordem,
         string_agg(status || '=' || status_ordem, ', ') FILTER (WHERE ordem_declarada) AS quais,
         CASE WHEN count(*) FILTER (WHERE ordem_declarada) = 2
              THEN 'OK — a ordem vem da TABELA; povoar funnel_stage é o caminho'
              ELSE 'FALHOU — o LEFT JOIN com funnel_stage não está ligado' END AS veredito
  FROM fn_funil_status_do_lead(jsonb_build_object('de', (now() - interval '12 months')::text));
ROLLBACK;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. OS FILTROS ALCANÇAM A POPULAÇÃO INTEIRA (não há filtro "ignorado" aqui)
-- ═════════════════════════════════════════════════════════════════════════════

\echo '--- G1. filtrar por segmento reduz; filtrar por categoria reduz mais ---'
SELECT (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{}'::jsonb)) AS sem_filtro,
       (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{"segmento":["Marketing"]}'::jsonb)) AS so_marketing,
       (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{"segmento":["Marketing"],"categoria":["Evento/Webinar"]}'::jsonb)) AS so_evento,
       CASE WHEN (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{"segmento":["Marketing"],"categoria":["Evento/Webinar"]}'::jsonb))
                 < (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{"segmento":["Marketing"]}'::jsonb))
             AND (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{"segmento":["Marketing"]}'::jsonb))
                 < (SELECT max(total_do_recorte) FROM fn_funil_status_do_lead('{}'::jsonb))
            THEN 'OK — os dois filtros alcançam a população contada'
            ELSE 'FALHOU — algum filtro está sendo ignorado' END AS veredito;

\echo '--- G2. o mesmo recorte na 103 e na 105 conta o MESMO total de leads ---'
\echo '---     (se divergir, uma das duas está filtrando escondido) ---'
SELECT (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_segmento(jsonb_build_object('de',(now()-interval '12 months')::text))) AS pela_103,
       (SELECT max(total_do_recorte)       FROM fn_funil_status_do_lead(jsonb_build_object('de',(now()-interval '12 months')::text)))       AS pela_105,
       CASE WHEN (SELECT max(total_leads_do_recorte) FROM fn_oportunidades_por_segmento(jsonb_build_object('de',(now()-interval '12 months')::text)))
               = (SELECT max(total_do_recorte)       FROM fn_funil_status_do_lead(jsonb_build_object('de',(now()-interval '12 months')::text)))
            THEN 'OK' ELSE 'FALHOU — 103 e 105 discordam sobre a população de lead' END AS veredito;

\echo '--- G3. e o "viraram oportunidade" também concorda entre as duas ---'
SELECT (SELECT sum(qtd_leads_com_oportunidade) FROM fn_oportunidades_por_segmento(jsonb_build_object('de',(now()-interval '12 months')::text))) AS pela_103,
       (SELECT max(total_que_virou_oportunidade) FROM fn_funil_status_do_lead(jsonb_build_object('de',(now()-interval '12 months')::text)))     AS pela_105,
       CASE WHEN (SELECT sum(qtd_leads_com_oportunidade) FROM fn_oportunidades_por_segmento(jsonb_build_object('de',(now()-interval '12 months')::text)))
               = (SELECT max(total_que_virou_oportunidade) FROM fn_funil_status_do_lead(jsonb_build_object('de',(now()-interval '12 months')::text)))
            THEN 'OK' ELSE 'FALHOU' END AS veredito;

-- ═════════════════════════════════════════════════════════════════════════════
-- H. PERMISSÃO, PLANO E LEDGER — PELO CATÁLOGO
-- ═════════════════════════════════════════════════════════════════════════════
-- `has_function_privilege` NÃO serve: toda função nasce com EXECUTE para PUBLIC
-- e ela devolve `true` mesmo sem GRANT nenhum (demonstrado em
-- `leads-e-categoria-na-aba.sql`, bloco H1b). A prova é a entrada nominal no ACL.

\echo '--- H1. GRANT nominal e plan_cache_mode na função da 105 ---'
SELECT p.proname,
       (p.proacl::text[] && ARRAY['crm_ingest=X/neondb_owner']) AS grant_nominal_no_acl,
       p.proconfig,
       CASE WHEN (p.proacl::text[] && ARRAY['crm_ingest=X/neondb_owner'])
             AND 'plan_cache_mode=force_custom_plan' = ANY (coalesce(p.proconfig, ARRAY[]::text[]))
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'fn_funil_status_do_lead';

\echo '--- H2. os COMMENTs da 103 passaram a apontar a 105 e a marcar as colunas 📊 ---'
SELECT p.proname,
       obj_description(p.oid,'pg_proc') LIKE '%fn_funil_status_do_lead%'        AS aponta_a_105,
       obj_description(p.oid,'pg_proc') LIKE '%MÉTRICA DE QUALIDADE DE DADO%'   AS marca_qualidade_de_dado,
       CASE WHEN obj_description(p.oid,'pg_proc') LIKE '%fn_funil_status_do_lead%'
             AND obj_description(p.oid,'pg_proc') LIKE '%MÉTRICA DE QUALIDADE DE DADO%'
            THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('fn_oportunidades_por_segmento','fn_oportunidades_por_categoria')
ORDER BY 1;

\echo '--- H3. as migrations 105 e 106 estão no ledger com checksum de 64 hex ---'
SELECT name, left(checksum, 16) AS checksum_16, applied_at,
       CASE WHEN checksum IS NOT NULL AND length(checksum) = 64 THEN 'OK' ELSE 'FALHOU' END AS veredito
FROM schema_migrations WHERE name ~ '^10[56]_' ORDER BY name;
