-- db/migrations/097_camada_da_aba_oportunidades.sql
--
-- A ABA "OPORTUNIDADES" DESCREVIA UMA PLANILHA, NÃO O NEGÓCIO.
--
-- A tela é alimentada hoje por uma planilha Google de 513 linhas. A base real
-- tem 8.073 oportunidades do Salesforce. A planilha é SUBCONJUNTO ESTRITO, e
-- o que ela deixa de fora não é ruído:
--
--   · Origens inteiramente ausentes da planilha e 100% convertidas --
--     `Indicação Cliente` (32 leads), `Cliente da base` (13),
--     `Indicação Parceiro` (7), `Loupen_Chat` (8). Por isso a aba conseguia
--     dizer "100% atribuído a marketing": tudo que não é marketing tinha sido
--     removido da fonte antes de chegar na tela.
--   · Win rate com denominador errado: 3 ÷ 44 (TODAS as oportunidades) = 6,8%.
--     Sobre as DECIDIDAS (3 ganhas + 23 perdidas) = 11,5%. A meta de 20% era
--     cobrada contra uma taxa que CAI sozinha enquanto o pipeline cresce.
--   · 1.556 de 2.753 leads (56,5%) não apareciam em card nenhum.
--   · O "funil" somava estados MUTUAMENTE EXCLUSIVOS ("Em cadência" e
--     "Qualificados") como se fossem etapas sequenciais, e dividia um pelo
--     outro chamando o resultado de conversão.
--   · Toda seta de tendência comparava contra ZERO, porque a planilha não tem
--     período anterior.
--   · `isWon` no código era `valorNF > 0 && !isLost`: preencher Valor NF numa
--     proposta virava venda ganha.
--
-- Esta migration cria a camada que a tela vai consumir no lugar da planilha.
-- Ela NÃO cria número novo: ela declara o grão, declara o denominador, e
-- declara o que ficou de fora de cada soma.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🔴 A PREMISSA QUE NÃO SOBREVIVEU À MEDIÇÃO: `CloseDate` NÃO É DATA DE FECHO
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A definição nº 10 pedia "ciclo = mediana de created_at_source ->
-- closed_at_source das ganhas". Implementada ao pé da letra ela devolve 320
-- dias, e esse número NÃO é o ciclo de venda. Medido em 2026-09-16 sobre as
-- 2.551 ganhas:
--
--   · 641 delas (25%) têm closed_at_source ANTERIOR a created_at_source.
--     Mínimo: -258 dias. Duração negativa não é ciclo lento, é campo com
--     outra semântica.
--   · Excluindo as invertidas, a mediana sobe para 349 dias -- e a correlação
--     com `Termo_do_Contrato__c` é quase 1:1:
--
--       Termo     n      mediana created->close
--       -------  ----    ---------------------
--        6 meses   10       164 dias
--       12 meses 1391       351 dias
--       15 meses   16       425 dias
--       24 meses  124       668 dias
--
--   · 927 das 1.732 ganhas com termo declarado (54%) têm CloseDate a menos de
--     31 dias do FIM DO CONTRATO. Só 318 (18%) fecham em até 31 dias da
--     criação.
--
-- E A SEMÂNTICA MUDA ENTRE COORTES, o que é pior do que estar errada de um
-- jeito só. Na janela que a aba vai usar por padrão (criadas nos últimos 12
-- meses, 987 ganhas), o quadro se inverte:
--
--   Termo     n     invertidas   mediana created->close
--   -------  ----   ----------   ---------------------
--   12 meses  576      377            -1 dia
--   36 meses   66       33             0 dias
--   24 meses   47       22             0 dias
--   (sem)      78       77          -166 dias
--
-- 587 das 987 ganhas recentes (59%) têm CloseDate ANTERIOR à criação, e as
-- restantes têm mediana de 6,3 dias. Ou seja: na coorte antiga CloseDate é o
-- FIM do contrato; na coorte recente a oportunidade é registrada no CRM quando
-- o negócio JÁ está fechado, com CloseDate ancorado no passado. Nos dois casos
-- o intervalo não mede quanto tempo a venda levou.
--
-- CONCLUSÃO: nesta org, `Opportunity.CloseDate` NÃO é a data em que a venda
-- aconteceu. É um campo de data editável pelo usuário, não um timestamp de
-- sistema, e carrega significados diferentes em coortes diferentes.
--
-- O QUE ESTA MIGRATION FAZ COM ISSO: entrega o número, com o nome do que ele
-- é (`dias_entre_criacao_e_close_date`, nunca "ciclo de venda"), e entrega
-- JUNTO as duas contrapartidas medidas em tempo real --
-- `ciclo_qtd_close_antes_da_criacao` e `ciclo_qtd_close_no_fim_do_contrato` --
-- para que quem for exibir saiba que está olhando prazo de contrato, não
-- velocidade comercial. Inventar uma data de fecho que a origem não tem seria
-- repetir exatamente o erro do `isWon = valorNF > 0`.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- 🟡 A SEGUNDA PREMISSA QUE A MEDIÇÃO ENCOLHEU: SEGMENTO SOBRE A BASE INTEIRA
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A definição nº 8 pede Marketing vs Comercial "sobre a base inteira". A base
-- inteira existe; o segmento, não. Medido:
--
--   vínculo individual (lead.converted_opportunity_id) ......  321 oportunidades
--   vínculo por conta  (lead.converted_account_id) ..........  199 adicionais
--   ------------------------------------------------------------------------
--   com lead identificável ..................................  520  (6,4%)
--   SEM lead identificável .................................. 7.553 (93,6%)
--
-- Não há como melhorar isso aqui: `Opportunity` não traz `LeadSource` no
-- payload ingerido (chaves disponíveis hoje: AccountId, Amount, CloseDate,
-- CreatedDate, CurrencyIsoCode, Id, MRR__c, OwnerId, RecordType, StageName,
-- Termo_do_Contrato__c). A maioria das oportunidades desta org nasce direto,
-- sem conversão de Lead.
--
-- Por isso `SemLeadIdentificado` é uma categoria de PRIMEIRA CLASSE aqui, e a
-- definição nº 8 é honrada ao pé da letra: ela NÃO cai no balde "Comercial".
-- A tela precisa mostrar o 93,6% -- caso contrário repete, com outro sinal, o
-- mesmo "100% atribuído a marketing" que esta migration existe para desfazer.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- AS 11 DEFINIÇÕES, E ONDE CADA UMA MORA
-- ═════════════════════════════════════════════════════════════════════════════
--
--  1. Universo = todas as oportunidades `source_system='salesforce'`. Sem
--     recorte de planilha, sem `seed_test`. Filtro de período sobre
--     `created_at_source`.                        -> WHERE da view
--  2. Ganho/perdido vêm de `opportunity_stage.is_won`/`is_closed` (a
--     DECLARAÇÃO da origem), cruzados com a nossa `fase`. Divergência é
--     EXPOSTA, nunca resolvida em silêncio.       -> desfecho + divergencia_*
--  3. Win rate = ganhas ÷ (ganhas + perdidas). Denominador devolvido em
--     coluna própria.                             -> fn_oportunidades_cards
--  4. Receita = amount convertido para BRL, só de ganhas, COM a contagem e o
--     motivo das que ficaram de fora.             -> fn_oportunidades_cards
--  5. Pipeline = não decididas (is_closed=false). Rotulado pipeline, jamais
--     previsão.                                   -> fn_oportunidades_cards
--  6. Funil = ESTOQUE por fase. Sem taxa entre fases.  -> fn_oportunidades_funil
--  7. Nada invisível: a partição por `desfecho` é TOTAL (6 valores, nenhum
--     ELSE implícito) e a soma é conferida na própria saída. -> soma_fecha
--  8. Marketing vs Comercial pelo segmento do lead de origem, com
--     `SemLeadIdentificado` como categoria declarada. -> fn_oportunidades_por_segmento
--  9. Ticket médio só sobre ganhas COM valor, com o n.  -> ticket_medio_*
-- 10. "Ciclo" -- ver o bloco vermelho acima.           -> ciclo_* + ressalvas
-- 11. Período anterior COM marca de existência de dado. -> periodo_anterior_*
--
-- ═════════════════════════════════════════════════════════════════════════════
-- POR QUE O VÍNCULO LEAD->OPORTUNIDADE TEM DUAS FORÇAS, E POR QUE ELA APARECE
-- ═════════════════════════════════════════════════════════════════════════════
--
-- `lead.converted_opportunity_id` é INDIVIDUAL (migration 090).
-- `lead.converted_account_id` é POR CONTA, e uma conta com 3 oportunidades
-- credita as 3 ao mesmo lead. Fundir os dois em silêncio foi como a duplicação
-- nasceu em `view_lead_360`.
--
-- Aqui a preferência é declarada E VISÍVEL: `lead_vinculo_regra` diz, linha a
-- linha, se o vínculo veio de `'oportunidade'`, de `'conta'` ou se não há
-- (`'sem_lead'`). O grão da view é UMA LINHA POR OPORTUNIDADE nos três casos:
-- os dois lados do vínculo são agregados ANTES do join, então nenhuma
-- oportunidade se multiplica. Medido: 2 oportunidades têm 2 leads apontando
-- para elas pelo vínculo individual, e 15 contas têm mais de um lead -- sem a
-- agregação prévia, essas linhas dobrariam. `qtd_leads_candidatos` conta os
-- empates em vez de escondê-los; o desempate é `min(lead.id)`, declarado.
--
-- ═════════════════════════════════════════════════════════════════════════════
-- O QUE ESTA MIGRATION NÃO TOCA
-- ═════════════════════════════════════════════════════════════════════════════
-- `view_receita`, `view_pessoa_jornada_desfecho`, `view_lead_360`,
-- `view_fase_vs_origem`, `opportunity_stage`, `opportunity_stage_fase`,
-- `currency_rate`, permissões de role e `schema_migrations`. Nenhuma linha é
-- apagada. Tudo aqui é objeto NOVO.
--
-- `plan_cache_mode = 'force_custom_plan'` em TODAS as funções, pelo motivo
-- medido na migration 089: filtro opcional na forma `($n IS NULL OR col = $n)`
-- degradou `fn_search_pessoas` de 259 ms para 207 s (800x) por plano genérico
-- neste mesmo banco. As funções abaixo têm de 6 a 8 filtros opcionais cada --
-- a mesma forma, a mesma armadilha.

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A VIEW. GRÃO: UMA LINHA POR OPORTUNIDADE.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW view_oportunidade_analitica AS
WITH
-- ── vínculo FORTE: lead.converted_opportunity_id ─────────────────────────────
-- Agregado POR OPORTUNIDADE antes do join. Sem este group by, as 2
-- oportunidades que têm 2 leads virariam 4 linhas e a contagem do universo
-- passaria de 8.073 sem que ninguém percebesse.
vinculo_individual AS (
  SELECT
    o.id                             AS opportunity_id,
    (array_agg(l.id ORDER BY l.id))[1] AS lead_id,
    count(DISTINCT l.id)             AS qtd_leads_candidatos
  FROM opportunity o
  JOIN lead l ON l.converted_opportunity_id = o.source_id
  WHERE o.source_system = 'salesforce'
  GROUP BY o.id
),
-- ── vínculo FRACO: lead.converted_account_id, e SÓ onde o forte não existe ───
-- O NOT EXISTS é o que torna a queda declarada em vez de uma fusão silenciosa:
-- uma oportunidade nunca recebe os dois vínculos ao mesmo tempo.
vinculo_por_conta AS (
  SELECT
    o.id                             AS opportunity_id,
    (array_agg(l.id ORDER BY l.id))[1] AS lead_id,
    count(DISTINCT l.id)             AS qtd_leads_candidatos
  FROM opportunity o
  JOIN account a ON a.id = o.account_id AND a.source_system = 'salesforce'
  JOIN lead l    ON l.converted_account_id = a.source_id
  WHERE o.source_system = 'salesforce'
    AND NOT EXISTS (SELECT 1 FROM vinculo_individual vi WHERE vi.opportunity_id = o.id)
  GROUP BY o.id
)
SELECT
  o.id                                       AS opportunity_id,
  o.source_id,
  o.account_id                               AS conta_id,
  a.nome                                     AS conta_nome,
  o.record_type_name                         AS record_type,
  o.stage_name                               AS estagio,
  -- ── a nossa tradução (opportunity_stage_fase, migrations 079/092) ─────────
  f.fase,
  f.ordem                                    AS fase_ordem,
  -- ── a DECLARAÇÃO da origem (opportunity_stage, migration 092) ─────────────
  s.is_won                                   AS origem_is_won,
  s.is_closed                                AS origem_is_closed,
  s.default_probability                      AS origem_probabilidade,
  s.forecast_category                        AS origem_forecast,
  s.is_active                                AS origem_estagio_ativo,
  -- ── DESFECHO: partição TOTAL do universo, sem ELSE implícito ──────────────
  -- Autoridade é a ORIGEM (is_won/is_closed), não o rótulo do estágio nem a
  -- nossa fase. `Pending Sale` PARECE venda fechada e a origem declara
  -- IsWon=false; mapeá-lo por intuição teria inventado 14 vendas (migration
  -- 092). Os seis valores cobrem 100% das linhas por construção -- é o que
  -- permite conferir a soma na saída em vez de confiar nela.
  CASE
    WHEN s.api_name IS NULL                       THEN 'estagio_nao_declarado'
    WHEN s.is_won IS NULL OR s.is_closed IS NULL  THEN 'declaracao_incompleta'
    WHEN s.is_won                                 THEN 'ganha'
    WHEN s.is_closed                              THEN 'perdida'
    WHEN f.fase IS NULL                           THEN 'fora_de_fase'
    ELSE                                               'aberta'
  END                                        AS desfecho,
  CASE
    WHEN s.api_name IS NULL
      THEN format('Estágio "%s" não existe em opportunity_stage — a origem não declarou IsWon/IsClosed para ele, e nós não chutamos', coalesce(o.stage_name, '(nulo)'))
    WHEN s.is_won IS NULL OR s.is_closed IS NULL
      THEN format('Estágio "%s" existe no catálogo mas com IsWon/IsClosed nulo — declaração incompleta na origem', o.stage_name)
    WHEN s.is_won     THEN 'Origem declara IsWon = true'
    WHEN s.is_closed  THEN 'Origem declara IsClosed = true e IsWon = false'
    WHEN f.fase IS NULL
      THEN format('Aberta na origem (IsClosed = false), mas o estágio "%s" está fora do funil — opportunity_stage_fase declara fase NULL de propósito', o.stage_name)
    ELSE 'Aberta na origem (IsClosed = false)'
  END                                        AS desfecho_motivo,
  -- ── A DIVERGÊNCIA, EXPOSTA ────────────────────────────────────────────────
  -- Hoje o nosso julgamento e a declaração da origem concordam em 100% dos 29
  -- estágios em uso (medido em 2026-09-16). Esta coluna existe para o dia em
  -- que deixarem de concordar: a org tem 114 estágios, nós mapeamos 29, e um
  -- estágio novo com IsWon=true entraria calado pela porta da frente.
  CASE
    WHEN s.api_name IS NULL THEN NULL
    WHEN s.is_won IS NULL OR s.is_closed IS NULL THEN NULL
    WHEN s.is_won AND coalesce(f.fase, '') <> 'ganho'
      THEN format('Origem declara IsWon=true para "%s", nossa fase é "%s"', o.stage_name, coalesce(f.fase, '(nenhuma)'))
    WHEN NOT s.is_won AND f.fase = 'ganho'
      THEN format('Nossa fase diz ganho para "%s", origem declara IsWon=false', o.stage_name)
    WHEN s.is_closed AND coalesce(f.fase, '') NOT IN ('ganho', 'perdido')
      THEN format('Origem declara IsClosed=true para "%s", nossa fase é "%s" (não terminal)', o.stage_name, coalesce(f.fase, '(nenhuma)'))
    WHEN NOT s.is_closed AND f.fase IN ('ganho', 'perdido')
      THEN format('Nossa fase é terminal ("%s") para "%s", origem declara IsClosed=false', f.fase, o.stage_name)
  END                                        AS divergencia_origem_vs_fase,
  -- ── tempo ─────────────────────────────────────────────────────────────────
  o.created_at_source                        AS criada_em,
  -- NOME DELIBERADO. Não é `fechada_em`: ver o bloco vermelho do cabeçalho.
  o.closed_at_source                         AS close_date_origem,
  CASE
    WHEN o.created_at_source IS NOT NULL AND o.closed_at_source IS NOT NULL
      THEN round((extract(epoch FROM (o.closed_at_source - o.created_at_source)) / 86400)::numeric, 1)
  END                                        AS dias_entre_criacao_e_close_date,
  (o.closed_at_source < o.created_at_source) AS close_date_antes_da_criacao,
  -- A evidência de que CloseDate carrega o FIM DO CONTRATO, recalculada a cada
  -- leitura em vez de congelada num comentário: se a org mudar de prática, o
  -- número muda junto.
  CASE
    WHEN o.duracao_meses_contrato IS NULL OR o.duracao_meses_contrato <= 0
      OR o.created_at_source IS NULL OR o.closed_at_source IS NULL THEN NULL
    ELSE abs(extract(epoch FROM (o.closed_at_source - o.created_at_source)) / 86400
             - o.duracao_meses_contrato * 30.44) <= 31
  END                                        AS close_date_no_fim_do_contrato,
  -- ── dinheiro (migration 090: DIVISÃO, e jamais fallback para 1) ───────────
  o.amount,                                  -- CRU, em moeda local. O DADO.
  o.mrr,
  o.duracao_meses_contrato,
  o.currency_iso_code                        AS moeda,
  cr.conversion_rate                         AS taxa_conversao,
  CASE
    WHEN o.amount IS NOT NULL AND cr.conversion_rate IS NOT NULL
      THEN o.amount / cr.conversion_rate
  END                                        AS amount_brl,
  CASE
    WHEN o.amount IS NULL
      THEN 'Amount vazio na origem — não há valor para converter'
    WHEN o.currency_iso_code IS NULL
      THEN 'Moeda ausente no registro — ingerido antes da migration 090 e ainda não relido'
    WHEN cr.iso_code IS NULL
      THEN format('Moeda "%s" não está em currency_rate — taxa desconhecida, e valor NUNCA é assumido como real', o.currency_iso_code)
  END                                        AS conversao_indisponivel_motivo,
  -- ── origem do negócio ─────────────────────────────────────────────────────
  coalesce(vi.lead_id, vc.lead_id)           AS lead_id,
  l.source_id                                AS lead_source_id,
  l.nome                                     AS lead_nome,
  CASE
    WHEN vi.lead_id IS NOT NULL THEN 'oportunidade'
    WHEN vc.lead_id IS NOT NULL THEN 'conta'
    ELSE                             'sem_lead'
  END                                        AS lead_vinculo_regra,
  coalesce(vi.qtd_leads_candidatos, vc.qtd_leads_candidatos, 0) AS qtd_leads_candidatos,
  c.segmento,
  c.categoria,
  c.detalhe,
  -- O balde que a tela exibe. `SemLeadIdentificado` é 93,6% da base e NÃO é
  -- "Comercial": a definição nº 8 proíbe explicitamente essa fusão.
  coalesce(c.segmento, 'SemLeadIdentificado') AS segmento_aba
FROM opportunity o
LEFT JOIN account a                 ON a.id = o.account_id
LEFT JOIN opportunity_stage_fase f  ON f.stage_name = o.stage_name
LEFT JOIN opportunity_stage s       ON s.api_name  = o.stage_name
-- LEFT, nunca INNER: moeda desconhecida vira NULL visível, não some da view.
LEFT JOIN currency_rate cr          ON cr.iso_code = o.currency_iso_code
LEFT JOIN vinculo_individual vi     ON vi.opportunity_id = o.id
LEFT JOIN vinculo_por_conta   vc    ON vc.opportunity_id = o.id
LEFT JOIN lead l                    ON l.id = coalesce(vi.lead_id, vc.lead_id)
LEFT JOIN lead_origin_classification c
       ON c.lead_id = coalesce(vi.lead_id, vc.lead_id) AND c.valid_to IS NULL
-- O UNIVERSO, declarado aqui e em lugar nenhum mais: todas as oportunidades do
-- Salesforce. `seed_test` (3 fixtures da migration 025, duas delas Ganhas com
-- R$ 3.000) fica de fora por este predicado, não por sorte.
WHERE o.source_system = 'salesforce';

COMMENT ON VIEW view_oportunidade_analitica IS
  'A CAMADA DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR OPORTUNIDADE (contrato §1.7) — os dois vínculos com lead são agregados antes do join, então nenhuma oportunidade se multiplica. UNIVERSO: todas as oportunidades source_system=salesforce (8.073 em 2026-09-16), nunca o recorte da planilha de 513 linhas. DESFECHO é partição TOTAL em 6 valores (ganha/perdida/aberta/fora_de_fase/estagio_nao_declarado/declaracao_incompleta) e a autoridade é opportunity_stage.is_won/is_closed da ORIGEM, não o rótulo do estágio. divergencia_origem_vs_fase expõe discordância entre a declaração e a nossa fase em vez de escolher em silêncio. amount_brl é amount/conversion_rate e é NULL quando a taxa é desconhecida — NUNCA amount×1 (migration 090); conversao_indisponivel_motivo diz por quê. ⚠️ close_date_origem é Opportunity.CloseDate e nesta org carrega predominantemente o FIM DO CONTRATO, não a data do fecho: 25% das ganhas têm CloseDate anterior à criação e 54% das que têm termo declarado caem a menos de 31 dias do fim do contrato. Use dias_entre_criacao_e_close_date como prazo de contrato, jamais como ciclo de venda. segmento_aba tem SemLeadIdentificado em 93,6% das linhas porque Opportunity não traz LeadSource no payload — isso é a medição, não um defeito da view. Migration 097.';

COMMENT ON COLUMN view_oportunidade_analitica.desfecho IS
  'Partição TOTAL do universo em 6 valores mutuamente exclusivos. Precedência: estágio fora do catálogo -> declaração incompleta -> IsWon -> IsClosed -> fase NULL -> aberta. Não existe ELSE implícito: a soma das seis contagens É o total, e fn_oportunidades_cards.soma_fecha confere isso a cada chamada.';

COMMENT ON COLUMN view_oportunidade_analitica.lead_vinculo_regra IS
  'Qual regra ligou esta oportunidade a um lead: "oportunidade" = lead.converted_opportunity_id (vínculo individual, 321 linhas); "conta" = lead.converted_account_id, usado SÓ onde o individual não existe (199 linhas); "sem_lead" = nenhum dos dois (7.553 linhas, 93,6%). Fundir os dois em silêncio foi como a duplicação de view_lead_360 nasceu.';

COMMENT ON COLUMN view_oportunidade_analitica.close_date_origem IS
  'Opportunity.CloseDate. NÃO É a data em que a venda foi fechada nesta org: é um campo de data editável, e a medição de 2026-09-16 mostra correlação quase 1:1 com Termo_do_Contrato__c (12 meses -> mediana 351 dias; 24 meses -> 668 dias). 641 das 2.551 ganhas têm CloseDate ANTERIOR ao CreatedDate. Chamar isso de ciclo de venda é fabricar um indicador.';

COMMENT ON COLUMN view_oportunidade_analitica.segmento_aba IS
  'segmento do lead de origem (Marketing/Comercial/Parceiro/NaoAtribuido) ou SemLeadIdentificado quando não há lead. SemLeadIdentificado é categoria de PRIMEIRA CLASSE e NÃO deve ser somada a Comercial — despejá-la num balde existente é como a planilha chegou a "100% atribuído a marketing".';

GRANT SELECT ON view_oportunidade_analitica TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. OS CARDS. UMA LINHA, COM O PERÍODO ATUAL E O ANTERIOR LADO A LADO.
-- ═════════════════════════════════════════════════════════════════════════════
-- Uma chamada, uma varredura: o período atual e o anterior entram no MESMO
-- scan, marcados por `janela`, e as agregações se separam por FILTER. Duas
-- chamadas separadas dobrariam o custo e abririam a porta para os dois números
-- serem calculados com filtros diferentes sem ninguém notar.
--
-- TODO número vem acompanhado do seu denominador ou do que ficou de fora. Esse
-- é o defeito que esta migration existe para não repetir: a aba antiga exibia
-- "6,8% de win rate" sem dizer que o denominador eram 44 oportunidades, das
-- quais 18 nem tinham sido decididas.

CREATE OR REPLACE FUNCTION public.fn_oportunidades_cards(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  -- ── o recorte, devolvido para a tela poder rotular o que está mostrando ──
  periodo_de                          timestamptz,
  periodo_ate                         timestamptz,
  periodo_anterior_de                 timestamptz,
  periodo_anterior_ate                timestamptz,
  periodo_anterior_tem_dado           boolean,
  periodo_anterior_sem_dado_motivo    text,
  -- ── definição 7: a partição total, e a conferência dela ──────────────────
  total_oportunidades                 bigint,
  qtd_ganhas                          bigint,
  qtd_perdidas                        bigint,
  qtd_abertas                         bigint,
  qtd_fora_de_fase                    bigint,
  qtd_estagio_nao_declarado           bigint,
  qtd_declaracao_incompleta           bigint,
  soma_fecha                          boolean,
  soma_fecha_diferenca                bigint,
  -- ── definição 3: win rate, com o denominador ao lado ─────────────────────
  qtd_decididas                       bigint,
  win_rate_decididas_pct              numeric,
  win_rate_sobre_todas_pct            numeric,
  -- ── definição 4: receita, e o que não entrou nela ────────────────────────
  receita_ganha_brl                   numeric,
  qtd_ganhas_no_valor                 bigint,
  qtd_ganhas_fora_do_valor            bigint,
  ganhas_fora_do_valor_motivos        jsonb,
  -- ── definição 5: pipeline, e o que não entrou nele ───────────────────────
  pipeline_aberto_brl                 numeric,
  qtd_abertas_no_pipeline             bigint,
  qtd_abertas_fora_do_pipeline        bigint,
  -- ── definição 9: ticket médio, com o n ───────────────────────────────────
  ticket_medio_ganhas_brl             numeric,
  ticket_medio_n                      bigint,
  -- ── definição 10: o prazo, com as duas ressalvas medidas ─────────────────
  dias_ate_close_date_mediana         numeric,
  dias_ate_close_date_n               bigint,
  ciclo_qtd_close_antes_da_criacao    bigint,
  ciclo_qtd_close_no_fim_do_contrato  bigint,
  ciclo_ressalva                      text,
  -- ── definição 2: a divergência, contada ──────────────────────────────────
  qtd_divergencia_origem_vs_fase      bigint,
  -- ── definição 11: o período anterior ─────────────────────────────────────
  ant_total_oportunidades             bigint,
  ant_qtd_ganhas                      bigint,
  ant_qtd_perdidas                    bigint,
  ant_qtd_abertas                     bigint,
  ant_qtd_decididas                   bigint,
  ant_win_rate_decididas_pct          numeric,
  ant_receita_ganha_brl               numeric,
  ant_qtd_ganhas_fora_do_valor        bigint,
  ant_pipeline_aberto_brl             numeric,
  ant_ticket_medio_ganhas_brl         numeric,
  ant_ticket_medio_n                  bigint
)
LANGUAGE plpgsql
STABLE
-- Migration 089: sem isto, 6 filtros opcionais na forma ($n IS NULL OR col=$n)
-- fazem o planejador multiplicar seletividades default, estimar rows=1 e
-- escolher nested loop. Mediu-se 800x de degradação neste banco.
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de        timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate       timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_ant_de    timestamptz;
  v_ant_ate   timestamptz;
  v_seg       jsonb := p_filtros->'segmento';
  v_fase      jsonb := p_filtros->'fase';
  v_desfecho  jsonb := p_filtros->'desfecho';
  v_rt        jsonb := p_filtros->'record_type';
  v_moeda     jsonb := p_filtros->'moeda';
  v_vinculo   jsonb := p_filtros->'lead_vinculo_regra';
  v_ant_n     bigint;
BEGIN
  -- O período anterior é a janela de MESMA DURAÇÃO imediatamente anterior.
  -- Sem os dois limites não existe duração, logo não existe período anterior:
  -- devolver zeros aqui seria desenhar a seta contra o zero de novo, que é
  -- exatamente o defeito da aba antiga.
  IF v_de IS NOT NULL AND v_ate IS NOT NULL THEN
    v_ant_de  := v_de - (v_ate - v_de);
    v_ant_ate := v_de;
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT v.*,
           CASE
             WHEN (v_de  IS NULL OR v.criada_em >= v_de)
              AND (v_ate IS NULL OR v.criada_em <  v_ate)          THEN 'atual'
             WHEN v_ant_de IS NOT NULL
              AND v.criada_em >= v_ant_de AND v.criada_em < v_ant_ate THEN 'anterior'
           END AS janela
    FROM view_oportunidade_analitica v
    WHERE fn_filtro_casa(v.segmento_aba,       v_seg)
      AND fn_filtro_casa(v.fase,               v_fase)
      AND fn_filtro_casa(v.desfecho,           v_desfecho)
      AND fn_filtro_casa(v.record_type,        v_rt)
      AND fn_filtro_casa(v.moeda,              v_moeda)
      AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
  ),
  recorte AS (SELECT * FROM base WHERE janela IS NOT NULL),
  agg AS (
    SELECT
      count(*)                       FILTER (WHERE janela='atual') AS total,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='ganha')                 AS ganhas,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='perdida')               AS perdidas,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='aberta')                AS abertas,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='fora_de_fase')          AS fora_fase,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='estagio_nao_declarado') AS nao_decl,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='declaracao_incompleta') AS decl_incompleta,
      sum(amount_brl)                FILTER (WHERE janela='atual' AND desfecho='ganha')                     AS receita,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='ganha' AND amount_brl IS NOT NULL) AS ganhas_com_valor,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho='ganha' AND amount_brl IS NULL)     AS ganhas_sem_valor,
      avg(amount_brl)                FILTER (WHERE janela='atual' AND desfecho='ganha')                     AS ticket,
      -- PIPELINE = NÃO DECIDIDAS. `fora_de_fase` entra: a origem diz
      -- IsClosed=false para `Lista`, e omitir 4 linhas porque elas não têm fase
      -- seria a exclusão silenciosa que o contrato §1.6 proíbe.
      sum(amount_brl)                FILTER (WHERE janela='atual' AND desfecho IN ('aberta','fora_de_fase'))                            AS pipeline,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho IN ('aberta','fora_de_fase') AND amount_brl IS NOT NULL) AS abertas_com_valor,
      count(*)                       FILTER (WHERE janela='atual' AND desfecho IN ('aberta','fora_de_fase') AND amount_brl IS NULL)     AS abertas_sem_valor,
      -- Mediana só sobre duração NÃO NEGATIVA. As invertidas não somem: elas
      -- viram `ciclo_qtd_close_antes_da_criacao`, ao lado do número.
      -- `::numeric` explícito: percentile_cont só tem variante float8/interval,
      -- então o numeric da view seria promovido a double precision e voltaria
      -- com ruído de ponto flutuante numa coluna de dias.
      (percentile_cont(0.5) WITHIN GROUP (ORDER BY dias_entre_criacao_e_close_date)
        FILTER (WHERE janela='atual' AND desfecho='ganha' AND dias_entre_criacao_e_close_date >= 0))::numeric AS ciclo_mediana,
      count(*) FILTER (WHERE janela='atual' AND desfecho='ganha' AND dias_entre_criacao_e_close_date >= 0) AS ciclo_n,
      count(*) FILTER (WHERE janela='atual' AND desfecho='ganha' AND close_date_antes_da_criacao)          AS ciclo_invertidas,
      count(*) FILTER (WHERE janela='atual' AND desfecho='ganha' AND close_date_no_fim_do_contrato)        AS ciclo_fim_contrato,
      count(*) FILTER (WHERE janela='atual' AND divergencia_origem_vs_fase IS NOT NULL)                    AS divergencias,
      -- ── período anterior ──
      count(*)        FILTER (WHERE janela='anterior')                        AS a_total,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='ganha')   AS a_ganhas,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='perdida') AS a_perdidas,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='aberta')  AS a_abertas,
      sum(amount_brl) FILTER (WHERE janela='anterior' AND desfecho='ganha')   AS a_receita,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='ganha' AND amount_brl IS NULL) AS a_ganhas_sem_valor,
      sum(amount_brl) FILTER (WHERE janela='anterior' AND desfecho IN ('aberta','fora_de_fase'))   AS a_pipeline,
      avg(amount_brl) FILTER (WHERE janela='anterior' AND desfecho='ganha')   AS a_ticket,
      count(*)        FILTER (WHERE janela='anterior' AND desfecho='ganha' AND amount_brl IS NOT NULL) AS a_ticket_n
    FROM recorte
  ),
  motivos AS (
    -- Não basta contar quantas ficaram de fora: POR QUE cada uma ficou é o que
    -- distingue "Amount vazio na origem" de "moeda sem taxa", e as duas exigem
    -- providências diferentes de quem opera o CRM.
    SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) AS j
    FROM (
      SELECT coalesce(conversao_indisponivel_motivo, '(motivo não classificado)') AS m,
             count(*) AS n
      FROM recorte
      WHERE janela = 'atual' AND desfecho = 'ganha' AND amount_brl IS NULL
      GROUP BY 1
    ) t
  )
  SELECT
    v_de, v_ate, v_ant_de, v_ant_ate,
    (v_ant_de IS NOT NULL AND agg.a_total > 0),
    CASE
      WHEN v_de IS NULL OR v_ate IS NULL
        THEN 'Sem período fechado no filtro (de/ate) — não há duração para deslocar, logo não existe período anterior. A tela deve esconder a seta, não desenhar variação contra zero.'
      WHEN agg.a_total = 0
        THEN format('Nenhuma oportunidade criada entre %s e %s sob os mesmos filtros — variação percentual contra zero é indefinida, não é +100%%.',
                    to_char(v_ant_de, 'YYYY-MM-DD'), to_char(v_ant_ate, 'YYYY-MM-DD'))
    END,
    agg.total, agg.ganhas, agg.perdidas, agg.abertas, agg.fora_fase, agg.nao_decl, agg.decl_incompleta,
    (agg.ganhas + agg.perdidas + agg.abertas + agg.fora_fase + agg.nao_decl + agg.decl_incompleta) = agg.total,
    agg.total - (agg.ganhas + agg.perdidas + agg.abertas + agg.fora_fase + agg.nao_decl + agg.decl_incompleta),
    (agg.ganhas + agg.perdidas),
    round(100.0 * agg.ganhas / nullif(agg.ganhas + agg.perdidas, 0), 2),
    round(100.0 * agg.ganhas / nullif(agg.total, 0), 2),
    agg.receita, agg.ganhas_com_valor, agg.ganhas_sem_valor, motivos.j,
    agg.pipeline, agg.abertas_com_valor, agg.abertas_sem_valor,
    round(agg.ticket, 2), agg.ganhas_com_valor,
    round(agg.ciclo_mediana, 1), agg.ciclo_n, agg.ciclo_invertidas, agg.ciclo_fim_contrato,
    CASE WHEN agg.ciclo_n > 0 OR agg.ciclo_invertidas > 0 THEN
      format('NÃO é ciclo de venda. Opportunity.CloseDate nesta org carrega predominantemente o FIM DO CONTRATO: %s das %s ganhas deste recorte têm CloseDate ANTERIOR à criação (excluídas da mediana e contadas aqui), e %s caem a menos de 31 dias do fim do Termo_do_Contrato__c. Leia como prazo de contrato.',
             agg.ciclo_invertidas, agg.ganhas, agg.ciclo_fim_contrato)
    END,
    agg.divergencias,
    agg.a_total, agg.a_ganhas, agg.a_perdidas, agg.a_abertas,
    (agg.a_ganhas + agg.a_perdidas),
    round(100.0 * agg.a_ganhas / nullif(agg.a_ganhas + agg.a_perdidas, 0), 2),
    agg.a_receita, agg.a_ganhas_sem_valor, agg.a_pipeline,
    round(agg.a_ticket, 2), agg.a_ticket_n
  FROM agg, motivos;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_cards(jsonb) IS
  'CARDS DA ABA OPORTUNIDADES. GRÃO DA SAÍDA: UMA LINHA (o recorte inteiro). Filtros em p_filtros: de/ate (timestamptz sobre criada_em; `de` INCLUSIVO, `ate` EXCLUSIVO), segmento, fase, desfecho, record_type, moeda, lead_vinculo_regra (cada um aceita string ou array, via fn_filtro_casa). CONTRATOS: win_rate_decididas_pct = ganhas/(ganhas+perdidas) e qtd_decididas vem ao lado para a tela exibir o denominador — win_rate_sobre_todas_pct é devolvido SÓ para contraste de auditoria, não é o indicador. receita_ganha_brl nunca vem sozinha: qtd_ganhas_fora_do_valor e ganhas_fora_do_valor_motivos dizem quantas ficaram de fora e por quê. pipeline_aberto_brl é ESTOQUE de não decididas, jamais previsão. soma_fecha confere que as 6 contagens de desfecho somam total_oportunidades — se vier false, a camada está errada e o número não deve ir para a tela. periodo_anterior_tem_dado=false significa ESCONDER a seta de tendência, não desenhar +100%. ⚠️ dias_ate_close_date_mediana NÃO é ciclo de venda: ver ciclo_ressalva e o COMMENT de view_oportunidade_analitica.close_date_origem. Migration 097.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_cards(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. O FUNIL. ESTOQUE POR FASE — E NENHUMA TAXA ENTRE FASES.
-- ═════════════════════════════════════════════════════════════════════════════
-- A aba antiga dividia "Qualificados" por "Em cadência" e chamava o resultado
-- de taxa de conversão. Os dois são estados MUTUAMENTE EXCLUSIVOS no momento da
-- leitura: uma oportunidade está num ou noutro, nunca passa de um para o outro
-- de forma observável nesta base. A razão entre eles não significa nada.
--
-- O que esta função devolve é uma COORTE: das oportunidades CRIADAS no período
-- filtrado, onde cada uma está AGORA. Por isso a coluna se chama
-- `qtd_da_coorte_agora` e não `qtd_que_chegou_na_fase` -- o nome é a única
-- defesa contra alguém dividir uma linha pela outra de novo.
--
-- Acompanhar a mesma coorte AO LONGO DO TEMPO exigiria histórico de estágio por
-- oportunidade, que esta base não tem (só o estágio ATUAL é ingerido). Inventar
-- a progressão a partir do estoque é o que esta função recusa a fazer.

CREATE OR REPLACE FUNCTION public.fn_oportunidades_funil(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  fase                      text,
  fase_ordem                integer,
  fase_rotulo               text,
  qtd_da_coorte_agora       bigint,
  pct_da_coorte             numeric,
  valor_brl                 numeric,
  qtd_sem_valor             bigint,
  total_da_coorte           bigint
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de       timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate      timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_seg      jsonb := p_filtros->'segmento';
  v_rt       jsonb := p_filtros->'record_type';
  v_moeda    jsonb := p_filtros->'moeda';
  v_vinculo  jsonb := p_filtros->'lead_vinculo_regra';
BEGIN
  RETURN QUERY
  WITH coorte AS (
    SELECT v.*
    FROM view_oportunidade_analitica v
    WHERE (v_de  IS NULL OR v.criada_em >= v_de)
      AND (v_ate IS NULL OR v.criada_em <  v_ate)
      AND fn_filtro_casa(v.segmento_aba,       v_seg)
      AND fn_filtro_casa(v.record_type,        v_rt)
      AND fn_filtro_casa(v.moeda,              v_moeda)
      AND fn_filtro_casa(v.lead_vinculo_regra, v_vinculo)
  ),
  tot AS (SELECT count(*) AS n FROM coorte)
  SELECT
    c.fase,
    c.fase_ordem,
    -- A linha "fora de qualquer fase" é OBRIGATÓRIA (definição 7): hoje são as
    -- 4 de `Lista`, que a origem declara IsClosed=false e IsActive=false. Sem
    -- ela a soma do funil não bate com o total e ninguém percebe.
    coalesce(c.fase, '(fora de qualquer fase)') AS fase_rotulo,
    count(*)                                    AS qtd_da_coorte_agora,
    round(100.0 * count(*) / nullif(tot.n, 0), 2),
    sum(c.amount_brl),
    count(*) FILTER (WHERE c.amount_brl IS NULL),
    tot.n
  FROM coorte c, tot
  GROUP BY c.fase, c.fase_ordem, tot.n
  -- `ganho` e `perdido` compartilham ordem 5 (são os dois finais do funil);
  -- o desempate por nome mantém a saída estável entre chamadas.
  ORDER BY c.fase_ordem NULLS LAST, c.fase NULLS LAST;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_funil(jsonb) IS
  'FUNIL DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR FASE de opportunity_stage_fase, mais a linha "(fora de qualquer fase)" que é obrigatória. É ESTOQUE, não progressão: qtd_da_coorte_agora responde "das oportunidades CRIADAS no período filtrado, quantas estão AGORA nesta fase". 🚫 NÃO DIVIDA UMA LINHA PELA OUTRA. As fases são estados no instante da leitura, não etapas que a mesma oportunidade percorre de forma observável — esta base ingere só o estágio ATUAL, sem histórico. A aba antiga dividia "Qualificados" por "Em cadência" (estados mutuamente exclusivos) e chamava o resultado de conversão. pct_da_coorte é participação no total da coorte, e as participações somam 100%. Filtros: de/ate, segmento, record_type, moeda, lead_vinculo_regra. Migration 097.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_funil(jsonb) TO crm_ingest;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. MARKETING vs COMERCIAL — COM O 93,6% NA CARA
-- ═════════════════════════════════════════════════════════════════════════════
-- A definição nº 8 exige que oportunidade sem lead identificável seja categoria
-- PRÓPRIA e não some no balde "comercial". Esta função existe para que essa
-- regra seja impossível de burlar acidentalmente: `SemLeadIdentificado` é uma
-- linha do resultado, com o mesmo peso visual das outras.
--
-- Devolve win rate e receita POR SEGMENTO, cada um com o seu denominador --
-- caso contrário a tela compararia 38 ganhas de Marketing com 2.398 de
-- SemLeadIdentificado como se fossem a mesma base.

CREATE OR REPLACE FUNCTION public.fn_oportunidades_por_segmento(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  segmento_aba              text,
  qtd_oportunidades         bigint,
  pct_do_total              numeric,
  qtd_ganhas                bigint,
  qtd_perdidas              bigint,
  -- NOME DIFERENTE DO DOS CARDS DE PROPÓSITO: aqui o balde é "tudo que a
  -- origem ainda não decidiu", `fora_de_fase` incluída. Nos cards `qtd_abertas`
  -- e `qtd_fora_de_fase` são colunas separadas porque lá a soma das seis é
  -- conferida. Chamar as duas coisas de `qtd_abertas` faria dois números
  -- diferentes com o mesmo nome no mesmo endpoint.
  qtd_nao_decididas         bigint,
  qtd_decididas             bigint,
  win_rate_decididas_pct    numeric,
  receita_ganha_brl         numeric,
  pct_da_receita            numeric,
  qtd_ganhas_fora_do_valor  bigint,
  pipeline_aberto_brl       numeric,
  total_do_recorte          bigint,
  receita_total_do_recorte  numeric
)
LANGUAGE plpgsql
STABLE
SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_de       timestamptz := (nullif(p_filtros->>'de',  ''))::timestamptz;
  v_ate      timestamptz := (nullif(p_filtros->>'ate', ''))::timestamptz;
  v_fase     jsonb := p_filtros->'fase';
  v_desfecho jsonb := p_filtros->'desfecho';
  v_rt       jsonb := p_filtros->'record_type';
  v_moeda    jsonb := p_filtros->'moeda';
BEGIN
  RETURN QUERY
  WITH recorte AS (
    SELECT v.*
    FROM view_oportunidade_analitica v
    WHERE (v_de  IS NULL OR v.criada_em >= v_de)
      AND (v_ate IS NULL OR v.criada_em <  v_ate)
      AND fn_filtro_casa(v.fase,        v_fase)
      AND fn_filtro_casa(v.desfecho,    v_desfecho)
      AND fn_filtro_casa(v.record_type, v_rt)
      AND fn_filtro_casa(v.moeda,       v_moeda)
  ),
  tot AS (
    SELECT count(*) AS n,
           sum(amount_brl) FILTER (WHERE desfecho = 'ganha') AS receita
    FROM recorte
  )
  SELECT
    r.segmento_aba,
    count(*),
    round(100.0 * count(*) / nullif(tot.n, 0), 2),
    count(*) FILTER (WHERE r.desfecho = 'ganha'),
    count(*) FILTER (WHERE r.desfecho = 'perdida'),
    count(*) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase')),
    count(*) FILTER (WHERE r.desfecho IN ('ganha','perdida')),
    round(100.0 * count(*) FILTER (WHERE r.desfecho = 'ganha')
          / nullif(count(*) FILTER (WHERE r.desfecho IN ('ganha','perdida')), 0), 2),
    sum(r.amount_brl) FILTER (WHERE r.desfecho = 'ganha'),
    round(100.0 * sum(r.amount_brl) FILTER (WHERE r.desfecho = 'ganha')
          / nullif(tot.receita, 0), 2),
    count(*) FILTER (WHERE r.desfecho = 'ganha' AND r.amount_brl IS NULL),
    sum(r.amount_brl) FILTER (WHERE r.desfecho IN ('aberta','fora_de_fase')),
    tot.n,
    tot.receita
  FROM recorte r, tot
  GROUP BY r.segmento_aba, tot.n, tot.receita
  ORDER BY count(*) DESC;
END;
$function$;

COMMENT ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) IS
  'MARKETING vs COMERCIAL DA ABA OPORTUNIDADES. GRÃO: UMA LINHA POR segmento_aba (Marketing, Comercial, Parceiro, NaoAtribuido, SemLeadIdentificado). SemLeadIdentificado é ~93,6% da base e é categoria de PRIMEIRA CLASSE por exigência do dono do produto — jamais somar a Comercial. A causa está medida: Opportunity não traz LeadSource no payload ingerido, e só 520 das 8.073 têm lead identificável (321 pelo vínculo individual, 199 pelo vínculo por conta). Cada segmento vem com o SEU denominador (qtd_decididas) para que win rates de bases de tamanhos diferentes não sejam comparados como iguais. Filtros: de/ate, fase, desfecho, record_type, moeda. Migration 097.';

GRANT EXECUTE ON FUNCTION public.fn_oportunidades_por_segmento(jsonb) TO crm_ingest;

COMMIT;
