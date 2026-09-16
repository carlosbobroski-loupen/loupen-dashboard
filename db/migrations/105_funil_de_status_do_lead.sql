-- db/migrations/105_funil_de_status_do_lead.sql
--
-- O FUNIL QUE JÁ EXISTIA NA BASE E NINGUÉM ESTAVA OLHANDO: `lead.status`.
--
-- A migration 103 entregou leads e oportunidades como DUAS POPULAÇÕES, lado a
-- lado, sem taxa entre elas — porque a razão entre dois conjuntos que não se
-- rastreiam não é conversão. O dado da própria 103 dá o argumento definitivo:
-- `Marketing / Inbound Web` tem 74 leads e 132 oportunidades na janela de 12
-- meses. Uma "taxa de conversão" ali marcaria 178%.
--
-- Mas existe uma afirmação SOBRE OS LEADS que a aba pode fazer com denominador
-- próprio, sem dividir populações: onde os leads param. É o que esta migration
-- entrega. GRÃO: UMA LINHA POR `lead.status`. A população contada é LEAD, do
-- começo ao fim, e o nome da função diz isso.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🔴 A PREMISSA QUE NÃO SOBREVIVEU: "93% DOS QUALIFICADOS VIRAM OPORTUNIDADE"
-- ═════════════════════════════════════════════════════════════════════════════
--
-- O pedido descrevia um funil com gargalo claro: 41% Rejeitado, 26% Aberto, e
-- `Qualificado` convertendo 93%. O 93% existe. Ele só não significa o que
-- parece.
--
-- Medido em 2026-09-16, TODOS os leads não-teste da janela de 12 meses,
-- agrupados por status, contando quantos têm `converted_opportunity_id` ou
-- `converted_account_id`:
--
--   status              leads   viraram oportunidade
--   -----------------   -----   --------------------
--   Aberto              3.130            0
--   Rejeitado           1.410            0
--   Descalificado         699            0
--   (sem status)          521            0
--   Qualificado           336          318
--   Contato dia 1         231            0
--   E-mail Invalido       145            0
--   ... (mais 13 status)              TODOS 0
--
-- **NENHUM outro status tem UMA ÚNICA conversão.** Não é "Qualificado converte
-- melhor": é que `Qualificado` É O CARIMBO DA CONVERSÃO nesta org. Converter um
-- Lead no Salesforce grava `Status = 'Qualificado'` junto com
-- `ConvertedOpportunityId`. A causalidade que o número sugere está invertida —
-- o lead não vira oportunidade porque foi qualificado; ele é marcado
-- Qualificado PORQUE foi convertido.
--
-- Prova direta: `SELECT status, count(*) FROM lead WHERE converted_* IS NOT
-- NULL GROUP BY status` devolve UMA linha — `Qualificado`, 330 (base inteira).
-- Zero linhas com qualquer outro status.
--
-- Logo os 93% NÃO são taxa de passagem de etapa. São a fração dos leads
-- carimbados `Qualificado` cujo `ConvertedOpportunityId` sobreviveu à
-- ingestão — os 8 de 114 que faltam em Marketing são carimbo sem id, não
-- qualificação que não converteu. Exibir isso como "conversão do funil" seria
-- exatamente a classe de erro que a 103 acabou de evitar: um número com cara de
-- taxa que mede o MECANISMO, não o negócio.
--
-- O QUE ESTA MIGRATION FAZ COM ISSO, e é a mesma decisão da 097 com `CloseDate`:
-- entrega o número, entrega o nome do que ele é, e entrega A RESSALVA JUNTO.
--   · `qtd_leads_que_viraram_oportunidade` é CONTAGEM. Não existe coluna de
--     percentual ao lado dela, de propósito — ver o bloco 🚫 abaixo.
--   · `status_e_carimbo_de_conversao` é `true` na linha `Qualificado` e diz,
--     em booleano que a tela pode testar, que aquela linha não é etapa.
--   · `status_ressalva` diz por extenso.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🚫 POR QUE NÃO HÁ `pct_virou_oportunidade`
-- ═════════════════════════════════════════════════════════════════════════════
-- `pct_do_recorte` (leads deste status ÷ leads do recorte) EXISTE e é legítimo:
-- mesma população, mesmo denominador, as participações somam 100%.
--
-- Já `viraram ÷ leads do status` seria 93% em UMA linha e 0% em DEZENOVE. Não é
-- distribuição de nada: é a marca do carimbo, publicada como se fosse desempenho
-- comercial. Quem quiser a razão que a calcule com as duas colunas à vista e com
-- `status_e_carimbo_de_conversao` na cara. Entregá-la pronta seria dar o número
-- sem a ressalva, que é o defeito que esta epic inteira existe para desfazer.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 ARMADILHA 1 (pedida): `Rejeitado` É EM BOA PARTE AUTOMAÇÃO
-- ═════════════════════════════════════════════════════════════════════════════
-- Medido em 2026-09-16, leads Salesforce não-teste da janela de 12 meses:
--
--   · 23 semanas de criação com 30+ leads. Taxa de rejeição por semana:
--     MÍNIMO 0,0%, MÁXIMO 93,5%. A semana de 2026-07-27 rejeitou 287 de 307
--     (93,5%); a seguinte com volume, 2026-08-17, rejeitou 22 de 593 (3,7%).
--     Vinte e cinco vezes de diferença entre coortes adjacentes.
--   · 1.282 dos 1.410 rejeitados (90,9%) foram CRIADOS antes de 2026-08-17 —
--     a fronteira de IDADE compatível com uma varredura de auto-rejeição por
--     inatividade aplicada em massa, não com avaliação individual.
--   · O mix de motivos é DISJUNTO entre as coortes (`Sem resposta` 45% antes,
--     1,9% depois).
--
-- E há um segundo balde que nenhum card de rejeição conta: `Descalificado`,
-- 699 leads na janela — dos quais **699 foram criados numa janela de TRÊS
-- SEMANAS** (2026-06-29 a 2026-07-19) e nenhum fora dela. Isso é lote, não
-- julgamento.
--
-- Sem ressalva, a tela diria "41% dos leads de marketing são ruins". O que o
-- dado sustenta é "41% carregam a marca de uma varredura automática".
--
-- ⚠️ Os números citados em `status_ressalva` são PROSA DATADA, no molde do
-- `ciclo_ressalva` da 097, e vão envelhecer. A contrapartida está em
-- `db/queries/verificacao/funil-status-do-lead.sql`, que RECALCULA cada um
-- deles ao vivo e acusa quando a prosa deixar de bater com o banco.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 ARMADILHA 2 (pedida): NÃO EXISTE ORDEM DE FUNIL PARA STATUS DE SALESFORCE
-- ═════════════════════════════════════════════════════════════════════════════
-- `funnel_stage` existe, tem coluna `ordem`, e o CHECK de `origem` aceita
-- 'salesforce'. Medido: **ZERO linhas com origem='salesforce'**. As 3 linhas que
-- existem são do RD Station (Lead 1, Qualified Lead 2, Client 3).
--
-- Os 21 status de `lead.status` desta base, portanto, NÃO TÊM ORDEM DECLARADA
-- POR NINGUÉM. `Contato dia 1` vem antes de `Contato dia 3`? Parece. E
-- `Reaquecer` vem antes ou depois de `Rejeitado`? `Cadência Ebook` é etapa ou
-- trilha paralela? Ordenar por julgamento aqui é inventar o funil, que é o
-- mesmo erro da aba antiga somando "Em cadência" com "Qualificados" como se
-- fossem sequenciais.
--
-- Então `status_ordem` vem de `funnel_stage` por LEFT JOIN e HOJE É NULL EM
-- TODAS AS LINHAS, com `ordem_declarada = false` ao lado e
-- `qtd_status_sem_ordem_declarada` contando quantos estão nessa situação. A
-- ordenação de saída é por VOLUME, não por etapa. É a mesma decisão da
-- migration 070.
--
-- Efeito colateral desejado: no dia em que alguém popular `funnel_stage` com
-- `origem='salesforce'`, a ordem aparece sozinha, sem migration nova. E um
-- status NOVO que a tabela não conhecer aparece visivelmente sem ordem, em vez
-- de cair num balde.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 OS 6,9% SEM STATUS NÃO SÃO FALHA DE DADO — SÃO OUTRA FONTE
-- ═════════════════════════════════════════════════════════════════════════════
-- A cobertura de `lead.status` medida em 2026-09-16 é 7.084 de 7.605 leads
-- não-teste = **93,15%** (confirma os 93,1% do pedido). Mas o buraco não está
-- espalhado:
--
--   source_system   leads   sem status
--   -------------   -----   ----------
--   salesforce      7.084            0
--   rd_station        521          521
--
-- É 0% e 100%, não 7% em média. `Status` é campo do Salesforce; o lead do RD
-- Station não o tem POR CONSTRUÇÃO, do mesmo jeito que ele não pode ter
-- `ConvertedOpportunityId`. A linha `(sem status)` é linha própria e declarada,
-- nunca somada a outra, e `status_ressalva` diz que ela é a população do RD
-- inteira — ausência estrutural, não ingestão incompleta.
--
-- Esta é, aliás, a mesma armadilha de denominador que já apareceu uma vez nesta
-- epic: misturar as duas fontes numa métrica que só uma delas pode ter.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- FILTROS
-- ═════════════════════════════════════════════════════════════════════════════
-- `de`, `ate`, `segmento` — os pedidos. Mais `categoria`, ACRESCENTADO ALÉM DO
-- PEDIDO e declarado aqui: ele vive na mesma `lead_origin_classification`, usa o
-- mesmo `fn_filtro_casa` já verificado na 103, e é o que torna respondível
-- "quantos leads de Evento/Webinar foram rejeitados" — a pergunta que motivou a
-- 103. Custo: um parâmetro. Se não for querido, some sem afetar as outras.
--
-- NÃO há filtro de `fase`, `desfecho`, `record_type`, `moeda` nem `lead_source`:
-- são atributos de `opportunity` e esta função não conta oportunidades. Não
-- existe, aqui, o problema de `leads_filtros_ignorados` da 103 — todo filtro
-- desta função vale para toda a população que ela conta.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE ESTA MIGRATION NÃO TOCA
-- ═════════════════════════════════════════════════════════════════════════════
-- `fn_run_ingest_batch` (regra do db/README.md), `view_oportunidade_analitica`,
-- `fn_oportunidades_cards`, `fn_oportunidades_funil`, `fn_search_oportunidades`,
-- `fn_classify_origin`, `fn_reclassificar_lead`, `leadsource_crosswalk`,
-- `funnel_stage`, permissões de role. Nenhuma linha de dado é lida para
-- escrita, criada ou apagada. Os únicos objetos alterados são os DOIS COMMENTs
-- das funções da 103 — mudança de documentação, não de comportamento, pedida
-- pelo PM para que a tabela de negócio não exiba métrica de qualidade de dado.

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. O FUNIL DE STATUS. GRÃO: UMA LINHA POR `lead.status`. POPULAÇÃO: LEAD.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_funil_status_do_lead(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  -- ── a chave ──────────────────────────────────────────────────────────────
  status                            text,
  status_rotulo                     text,
  -- ── a ordem que NINGUÉM declarou (ver armadilha 2) ───────────────────────
  status_ordem                      integer,
  ordem_declarada                   boolean,
  -- ── a distribuição: mesma população, mesmo denominador, soma 100% ────────
  qtd_leads                         bigint,
  pct_do_recorte                    numeric,
  -- ── o vínculo com oportunidade: CONTAGEM, nunca taxa (ver bloco 🚫) ──────
  qtd_leads_que_viraram_oportunidade bigint,
  status_e_carimbo_de_conversao     boolean,
  -- Quantos status DIFERENTES do recorte têm ao menos uma conversão. É 1 hoje,
  -- e esse 1 É a premissa inteira do bloco 🔴 do cabeçalho. Ele sai na saída em
  -- vez de ficar implícito para que, no dia em que virar 2, a mudança apareça
  -- na tela e na verificação em vez de o booleano acima simplesmente sumir.
  qtd_status_com_conversao          bigint,
  -- ── a ressalva, no molde do ciclo_ressalva da 097 ────────────────────────
  status_ressalva                   text,
  -- ── os totais, para a partição fechar na própria saída ───────────────────
  total_do_recorte                  bigint,
  total_que_virou_oportunidade      bigint,
  qtd_status_sem_ordem_declarada    bigint
)
LANGUAGE plpgsql
STABLE
-- Migration 089: filtro opcional na forma ($n IS NULL OR col = $n) já degradou
-- uma função deste banco de 259 ms para 207 s por plano genérico.
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de   timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate  timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_seg  jsonb := p_filtros->'segmento';
  v_cat  jsonb := p_filtros->'categoria';
BEGIN
  RETURN QUERY
  WITH recorte AS (
    SELECT
      -- `nullif(trim(...), '')` no lugar de `l.status` cru: string vazia e NULL
      -- são a MESMA ausência e têm de cair na MESMA linha. Duas linhas "sem
      -- status", uma delas invisível na tela, seria o balde escondido de novo.
      nullif(trim(l.status), '')                     AS status,
      l.source_system,
      l.created_at_source,
      (l.converted_opportunity_id IS NOT NULL
       OR l.converted_account_id  IS NOT NULL)       AS virou_opp
    FROM lead l
    -- INNER JOIN e não LEFT: medido em 2026-09-16, ZERO dos 7.605 leads
    -- não-teste estão sem classificação vigente, então o INNER não descarta
    -- ninguém HOJE. O bloco B do arquivo de verificação confere esse zero a
    -- cada execução — no dia em que deixar de valer, ele acusa em vez de a
    -- função encolher em silêncio.
    JOIN lead_origin_classification c
      ON c.lead_id = l.id AND c.valid_to IS NULL
    WHERE NOT l.is_teste
      AND (v_de  IS NULL OR l.created_at_source >= v_de)
      AND (v_ate IS NULL OR l.created_at_source <  v_ate)
      AND fn_filtro_casa(c.segmento,  v_seg)
      AND fn_filtro_casa(c.categoria, v_cat)
  ),
  tot AS (
    SELECT count(*) AS n, count(*) FILTER (WHERE virou_opp) AS virou FROM recorte
  ),
  agg AS (
    SELECT
      r.status                                        AS st,
      count(*)                                        AS n,
      count(*) FILTER (WHERE r.virou_opp)             AS virou,
      -- Serve à ressalva do `(sem status)`: quantos daquela linha são RD.
      count(*) FILTER (WHERE r.source_system = 'rd_station') AS n_rd,
      -- Serve à ressalva do `Rejeitado`: a fronteira de idade medida.
      count(*) FILTER (WHERE r.created_at_source < DATE '2026-08-17') AS n_antes_varredura
    FROM recorte r
    -- GROUP BY com NULL agrupa todos os NULL numa linha só — é exatamente o
    -- desejado: UMA linha "(sem status)", nunca uma por lead.
    GROUP BY r.status
  ),
  -- A ordem vem da TABELA, nunca de um CASE aqui dentro. Hoje o LEFT JOIN não
  -- casa com nada (0 linhas origem='salesforce') e todo status sai sem ordem.
  com_ordem AS (
    SELECT a.*, f.ordem
    FROM agg a
    LEFT JOIN funnel_stage f ON f.origem = 'salesforce' AND f.nome = a.st
  ),
  sem_ordem AS (SELECT count(*) AS n FROM com_ordem WHERE ordem IS NULL),
  -- A premissa do bloco 🔴, calculada em vez de assumida.
  conv AS (SELECT count(*) AS n_status FROM com_ordem WHERE virou > 0)
  SELECT
    o.st,
    coalesce(o.st, '(sem status — campo não existe no RD Station)'),
    o.ordem,
    o.ordem IS NOT NULL,
    o.n,
    round(100.0 * o.n / nullif(t.n, 0), 2),
    o.virou,
    -- Não é lista de status "bons" nem constante hardcoded: a linha só é
    -- marcada como carimbo se ELA tem conversões E se ela é a ÚNICA com
    -- conversões no recorte. Se um segundo status passar a converter, nenhuma
    -- linha recebe o booleano E `qtd_status_com_conversao` sai 2 — a premissa
    -- quebrada fica VISÍVEL em vez de o marcador sumir sem explicação.
    (o.virou > 0 AND cv.n_status = 1),
    cv.n_status,
    CASE
      WHEN o.st IS NULL THEN format(
        'AUSÊNCIA ESTRUTURAL, não falha de ingestão: `status` é campo do Salesforce e %s destes %s leads vêm do RD Station, onde o campo não existe — do mesmo jeito que um lead do RD não pode ter ConvertedOpportunityId. Medido em 2026-09-16: cobertura de status é 0%% no RD (0 de 521) e 100%% no Salesforce (7.084 de 7.084), nunca 93%% espalhados.',
        o.n_rd, o.n)
      WHEN o.virou > 0 AND cv.n_status = 1 THEN format(
        '🚫 ESTA LINHA NÃO É ETAPA DE FUNIL: é o CARIMBO DA CONVERSÃO. Converter um Lead no Salesforce grava este status junto com ConvertedOpportunityId, e neste recorte os %s leads convertidos estão TODOS aqui — os outros %s status somam ZERO conversões. Dividir %s por %s devolve a marca do carimbo, não desempenho comercial. Use a contagem; a razão não mede passagem de etapa.',
        t.virou, (SELECT count(*) - 1 FROM com_ordem), o.virou, o.n)
      WHEN o.virou > 0 AND cv.n_status > 1 THEN format(
        '⚠️ A PREMISSA DA MIGRATION 105 MUDOU: até 2026-09-16 `Qualificado` era o ÚNICO status com conversões (carimbo do Salesforce). Agora são %s status diferentes convertendo. Reavaliar o cabeçalho da 105 antes de ler qualquer razão desta coluna — o motivo pode ser status novo, mudança de configuração da conversão, ou dado de outra fonte entrando.',
        cv.n_status)
      WHEN o.st = 'Rejeitado' THEN format(
        '⚠️ EM BOA PARTE AUTOMAÇÃO, NÃO JULGAMENTO COMERCIAL. %s destes %s leads (%s%%) foram CRIADOS antes de 2026-08-17, a fronteira de idade de uma varredura de auto-rejeição em massa. Medido em 2026-09-16 sobre 23 semanas de criação com 30+ leads, a taxa de rejeição por semana vai de 0,0%% a 93,5%% — 2026-07-27 rejeitou 287 de 307 e 2026-08-17 rejeitou 22 de 593. A rejeição acompanha o CALENDÁRIO, não a campanha nem a qualidade do lead. Ler esta linha como "leads ruins" é atribuir a marketing o efeito de um job.',
        o.n_antes_varredura, o.n,
        round(100.0 * o.n_antes_varredura / nullif(o.n, 0), 1))
      WHEN o.st = 'Descalificado' THEN
        '⚠️ LOTE, NÃO JULGAMENTO — e balde que nenhum card de "rejeição" conta. Medido em 2026-09-16: 699 dos 700 leads com este status foram criados numa janela de TRÊS SEMANAS (2026-06-29 a 2026-07-19) e nenhum fora dela. A rejeição real desta base é maior do que qualquer número de `Rejeitado` exibido, porque está repartida entre dois status.'
    END,
    t.n,
    t.virou,
    s.n
  FROM com_ordem o
  CROSS JOIN tot t
  CROSS JOIN sem_ordem s
  CROSS JOIN conv cv
  -- ORDEM DE SAÍDA É POR VOLUME, e é assim de propósito: sem `funnel_stage`
  -- povoado para salesforce não existe ordem de etapa, e ordenar por
  -- `status_ordem` daria a impressão de uma sequência que ninguém declarou.
  -- Quando a tabela for povoada, trocar isto é uma linha — e aí passa a ser
  -- ordem declarada por alguém, não inferida aqui.
  ORDER BY o.n DESC, o.st NULLS LAST;
END;
$function$;

COMMENT ON FUNCTION public.fn_funil_status_do_lead(jsonb) IS
  'ONDE OS LEADS PARAM. GRÃO: UMA LINHA POR lead.status. A POPULAÇÃO CONTADA É LEAD, NUNCA OPORTUNIDADE — é essa distinção que impede de voltar a dividir um lado pelo outro (contrato §1.7). pct_do_recorte é participação no total de LEADS do recorte e as participações somam 100%. 🚫 NÃO EXISTE pct_virou_oportunidade, de propósito: medido em 2026-09-16, TODOS os leads convertidos desta base têm status=Qualificado e NENHUM outro status tem uma única conversão — Qualificado é o CARIMBO da conversão no Salesforce, não uma etapa que converte 93%. status_e_carimbo_de_conversao marca essa linha em booleano e status_ressalva explica. ⚠️ Rejeitado é em boa parte AUTOMAÇÃO: 90,9% dos rejeitados foram criados antes de 2026-08-17 e a taxa semanal de rejeição varia de 0,0% a 93,5% entre coortes adjacentes — acompanha o calendário, não a campanha. Descalificado é um segundo balde de rejeição (699 de 700 criados em 3 semanas) que nenhum card conta. ⚠️ status_ordem vem de funnel_stage e HOJE É NULL EM TODAS AS LINHAS porque a tabela tem ZERO linhas com origem=salesforce; a saída é ordenada por VOLUME e ordem_declarada=false diz isso linha a linha — inventar a sequência aqui seria refazer o "Em cadência → Qualificados" da aba antiga. ⚠️ a linha (sem status) é 100% RD Station: status é campo do Salesforce e a cobertura é 0% no RD e 100% no Salesforce, nunca 93% espalhados. Filtros: de, ate, segmento, categoria — todos valem para a população inteira que a função conta. Migration 105.';

GRANT EXECUTE ON FUNCTION public.fn_funil_status_do_lead(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. AS COLUNAS DE VÍNCULO SÃO QUALIDADE DE DADO, NÃO NÚMERO DE NEGÓCIO
-- ═════════════════════════════════════════════════════════════════════════════
-- Parecer do PM aceito: `qtd_opps_rastreadas_ate_lead` e irmãs respondem "quanto
-- da nossa atribuição é rastreável", não "como o negócio foi". O lugar delas é a
-- aba Qualidade de dados. Elas FICAM na saída — a partição e o
-- `soma_vinculo_fecha` dependem delas — mas o COMMENT passa a dizer onde
-- pertencem, porque o COMMENT é o que o próximo agente lê.
--
-- Só os COMMENTs mudam. Nenhum corpo de função é tocado aqui: reescrever o
-- corpo para mudar documentação é como duas reversões silenciosas já
-- aconteceram nesta epic.

COMMENT ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) IS
  'MARKETING vs COMERCIAL DA ABA OPORTUNIDADES, COM O LADO DO LEAD AO LADO. GRÃO: UMA LINHA POR SEGMENTO, vindo de um FULL OUTER JOIN entre o segmento_aba da oportunidade (6 valores) e o segmento do lead (4 valores — o CHECK de lead_origin_classification não tem NaoClassificado nem SemOrigem). segmento_presente_em diz se a linha existe nos dois lados; um zero com segmento_presente_em=so_oportunidade é ESTRUTURAL, não medido. 🚫 NÃO DIVIDA qtd_oportunidades POR qtd_leads_gerados: são duas populações atribuídas por caminhos diferentes e a razão não mede conversão. A prova mais curta está no dado da própria função — Marketing/Inbound Web tem 74 leads e 132 oportunidades na janela de 12 meses, o que daria 178%. Para "onde os leads param", que é uma afirmação sobre LEADS com denominador próprio, use fn_funil_status_do_lead (migration 105). 📊 qtd_opps_rastreadas_ate_lead, qtd_opps_so_por_leadsource, qtd_opps_lead_sem_classificacao, qtd_opps_sem_origem e soma_vinculo_fecha são MÉTRICA DE QUALIDADE DE DADO, não número de negócio: elas respondem "quanto da nossa atribuição é rastreável até um lead", e o lugar delas na tela é a aba Qualidade de dados, NÃO a tabela de negócio (parecer do PM, 2026-09-16). Continuam na saída porque são a partição total dos 6 valores de lead_vinculo_regra e soma_vinculo_fecha confere isso a cada chamada. ⚠️ As contagens de lead honram SOMENTE de/ate: fase, desfecho, record_type, moeda e lead_source não existem em lead, e leads_filtros_ignorados lista, em texto, os que foram pedidos e não puderam ser aplicados. Universo do lead: NOT is_teste, período sobre created_at_source. Migrations 097 + 100 + 103 + 105.';

COMMENT ON FUNCTION public.fn_oportunidades_por_categoria(jsonb) IS
  'CATEGORIA DA ABA OPORTUNIDADES (Evento/Webinar, Paid Social, Inbound Web, Outbound SDR/Vendas, ...). GRÃO: UMA LINHA POR PAR (segmento_aba, categoria) — medido em 2026-09-16 nenhuma categoria aparece sob dois segmentos, mas a chave é o par para que uma regra futura não funda duas linhas em silêncio. CATEGORIA NULL É LINHA PRÓPRIA E DECLARADA (categoria_rotulo = "(sem categoria — origem não classificada)"): são as oportunidades cujo segmento_aba é NaoClassificado ou SemOrigem, 792 na janela de 12 meses. Somá-las a uma categoria existente é o mecanismo exato que produziu o "100% atribuído a marketing" da aba antiga. Traz o lado do LEAD ao lado (qtd_leads_gerados / qtd_leads_com_oportunidade) e 🚫 NÃO oferece taxa lead→oportunidade: Inbound Web tem 74 leads e 132 oportunidades na janela, o que daria 178%. Para "onde os leads param" use fn_funil_status_do_lead (migration 105). 📊 as quatro contagens qtd_opps_* e soma_vinculo_fecha são MÉTRICA DE QUALIDADE DE DADO e pertencem à aba Qualidade de dados, não à tabela de negócio (parecer do PM, 2026-09-16). Filtros: de, ate, segmento, categoria, fase, desfecho, record_type, moeda, lead_source. segmento e categoria valem para os dois lados; os outros cinco só para a oportunidade e aparecem em leads_filtros_ignorados. ⚠️ filtrar por categoria remove a linha de categoria ausente (fn_filtro_casa não casa NULL com filtro presente) e total_do_recorte encolhe junto — por isso ele vem na saída. Migrations 103 + 105.';

COMMIT;
