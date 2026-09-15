-- db/migrations/088_amount_e_o_valor_total.sql
--
-- DECISÃO DE NEGÓCIO TOMADA (2026-09-15, pelo dono do produto):
-- `Opportunity.Amount` é o VALOR TOTAL da oportunidade. Não é MRR, não é mensal.
--
-- Consequência direta: a fórmula que a migration 080 deixou em pé estava
-- multiplicando um total por um prazo.
--
--   contrato_valor_por_amount = amount * duracao_meses_contrato  -> R$ 214.452.878,39
--   contrato_valor            = amount                           -> R$  14.924.947,76
--
-- 14x de inflação, exibida na ficha do lead desde ontem. Medido antes e depois
-- neste banco (2.554 oportunidades Ganhas).
--
-- A 080 se recusou, de propósito, a escolher entre `amount` e `mrr`, e expôs as
-- DUAS bases de cálculo com a justificativa de que a decisão era de negócio e
-- estava em aberto. A decisão foi tomada. Manter as duas colunas agora não é
-- mais prudência: é indecisão fossilizada na view. Então só sobra uma.
--
-- O QUE FICA E O QUE SAI:
--   SAI   contrato_valor_por_amount, contrato_valor_por_mrr  (a indecisão)
--   ENTRA contrato_valor                                      (a decisão)
--   FICA  amount, mrr crus, com os nomes dos campos de origem — eles são o
--         DADO. A conclusão muda; o dado não. Quem discordar da decisão
--         recalcula a partir daqui sem precisar de outra migration.
--
-- `duracao_meses_contrato` continua projetada, mas NÃO ENTRA MAIS NO CÁLCULO.
-- Por isso o motivo "duração desconhecida" deixa de existir em
-- `contrato_indisponivel_motivo`: se a duração não é insumo, desconhecê-la não
-- impede nada. Sobram duas razões reais — "não está Ganha" e "Ganha mas Amount
-- vazio na origem" (379 das 2.554 Ganhas, medido).

-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠️ DIVERGÊNCIA MEDIDA, REGISTRADA AQUI EM VEZ DE SUMIR
--
-- A decisão do dono do produto vale e está implementada abaixo. Mas o dado da
-- própria base a contradiz, e esconder isso seria repetir exatamente o erro que
-- a 073 e a 080 passaram duas migrations corrigindo.
--
-- Entre as 253 oportunidades Ganhas que têm Amount E MRR__c preenchidos:
--   184 (73%) têm amount/mrr dentro de ±10% de 1  -> Amount se comporta como MENSAL
--     6 ( 2%) têm amount/mrr ≈ duracao_meses      -> Amount se comporta como TOTAL
--    63 (25%) não batem com nenhuma das duas hipóteses
--
-- A razão mediana amount/mrr é ≈1,0 em TODOS os RecordTypes com volume (Canais
-- 1,045 · New Brasil 1,021 · Renew 1,012 · Global 1,000 · LATAM 1,112). Ou
-- seja: se Amount fosse o total de um contrato de 12 meses, MRR__c teria de ser
-- ~1/12 dele, e não é — os dois campos carregam praticamente o mesmo número.
--
-- A hipótese "New Freshworks guarda o total anual" não sobreviveu à medição:
-- é UMA linha (amount 248,83 = mrr 20,74 × 12) entre 27, e a mediana daquele
-- RecordType é 0,299, com outlier de 34,9. New Freshworks não é "total": é
-- inconsistente.
--
-- Isto NÃO altera o que esta migration faz. Fica registrado, e a query
-- `db/queries/verificacao/amount-semantica-por-recordtype.sql` reproduz a
-- medição a qualquer momento, para quando alguém quiser reabrir a decisão.
-- ─────────────────────────────────────────────────────────────────────────────

-- CREATE OR REPLACE VIEW não remove nem renomeia coluna, e aqui removemos duas.
-- Então DROP + CREATE em cadeia, com o procedimento da 080/066: conferir
-- pg_depend antes (feito — o único dependente de view_receita é view_lead_360)
-- e REFAZER OS GRANTS depois. Esquecer o grant foi o modo de falha real da 049.

DROP VIEW IF EXISTS view_lead_360;
DROP VIEW IF EXISTS view_receita;

CREATE VIEW view_receita AS
SELECT
  o.id                       AS opportunity_id,
  o.source_system,
  o.source_id,
  o.stage_name,
  o.amount                   AS amount,   -- Opportunity.Amount cru. O DADO.
  o.mrr                      AS mrr,      -- Opportunity.MRR__c cru (migration 073). O DADO.
  o.duracao_meses_contrato,               -- Projetada, mas NÃO entra no cálculo.
  -- A DECISÃO: Amount já é o valor total. Não se multiplica por prazo.
  CASE WHEN o.stage_name = 'Ganho' THEN o.amount END AS contrato_valor,
  CASE
    WHEN o.stage_name IS DISTINCT FROM 'Ganho'
      THEN 'Oportunidade ainda não está Ganha — valor de contrato não se aplica'
    WHEN o.amount IS NULL
      THEN 'Ganha, mas Amount vazio na origem — valor de contrato indisponível, nunca um número presumido'
  END AS contrato_indisponivel_motivo
FROM opportunity o;

-- view_lead_360 recriada só para trocar as duas colunas por uma. O resto da
-- definição é idêntico ao da migration 080, inclusive a nota de grão abaixo.
--
-- NOTA DE GRÃO, ainda registrada e ainda NÃO corrigida aqui: o nome diz "360 do
-- lead" e o grão é OPORTUNIDADE (LEFT JOIN opportunity). Um lead com 3
-- oportunidades devolve 3 linhas. Renomear continua sendo trabalho separado.

CREATE VIEW view_lead_360 AS
SELECT l.id AS lead_id,
    l.source_system,
    l.source_id,
    l.nome,
    l.empresa,
    l.email,
    l.telefone,
    l.status AS estagio_funil,
    l.converted_account_id,
    loc.segmento,
    loc.categoria,
    loc.detalhe,
    loc.sinal_id,
    loc.valor_bruto,
    loc.razao,
    a.id AS account_id,
    a.nome AS account_nome,
    o.id AS opportunity_id,
    o.stage_name,
    f.fase AS fase_comercial,
    o.record_type_name,
    vr.amount,
    vr.mrr,
    vr.contrato_valor,
    vr.contrato_indisponivel_motivo
   FROM lead l
     LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
     LEFT JOIN account a ON a.source_system = l.source_system AND a.source_id = l.converted_account_id
     LEFT JOIN opportunity o ON o.account_id = a.id
     LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
     LEFT JOIN view_receita vr ON vr.opportunity_id = o.id;

-- Grants refeitos — DROP leva os privilégios junto.
GRANT SELECT ON view_receita  TO crm_ingest;
GRANT SELECT ON view_lead_360 TO crm_ingest;

COMMENT ON VIEW view_receita IS
  'Grao: UMA LINHA POR OPORTUNIDADE. `amount` e `mrr` sao os campos de origem CRUS. `contrato_valor` = Amount quando Ganha, sem multiplicar por prazo, porque Amount E o valor total da oportunidade (decisao de negocio de 2026-09-15). `duracao_meses_contrato` segue projetada mas NAO entra no calculo. Medicao que contradiz parcialmente a decisao esta registrada na migration 088 e em db/queries/verificacao/amount-semantica-por-recordtype.sql. Ver migrations 080 e 088.';

-- ─────────────────────────────────────────────────────────────────────────────
-- view_pessoa_jornada_desfecho (migration 083) tem o mesmo defeito, agregado:
--   sum(o.amount * o.duracao_meses_contrato) AS contrato_por_amount
--   sum(o.mrr    * o.duracao_meses_contrato) AS contrato_por_mrr
--
-- Vira uma coluna só: `contrato_valor` = soma do Amount das oportunidades
-- ganhas. Ela é, por construção, IGUAL a `amount_ganho` — e essa igualdade é
-- justamente a prova de que a multiplicação era toda a distorção. As duas
-- colunas coexistem de propósito: `amount_ganho` é o campo de origem somado,
-- `contrato_valor` é o conceito de negócio. Se a regra mudar de novo, só uma
-- delas muda.
--
-- Nenhuma view depende desta (conferido em pg_depend). `fn_search_pessoas`
-- (migrations 084/087) projeta colunas nominalmente e usa apenas amount_ganho e
-- mrr_ganho — não referencia contrato_por_*, então não precisa ser recriada.
-- CREATE OR REPLACE também não serve aqui: duas colunas saem, uma entra.

DROP VIEW IF EXISTS view_pessoa_jornada_desfecho;

CREATE VIEW view_pessoa_jornada_desfecho AS
WITH
-- ── ESQUERDA: o array de conversões do RD ────────────────────────────────────
conv AS (
  SELECT
    p.pessoa_chave,
    count(*)                                                    AS qtd_conversoes,
    min(e.occurred_at)                                          AS primeira_conversao_em,
    max(e.occurred_at)                                          AS ultima_conversao_em,
    array_agg(DISTINCT e.origem_conversao)
      FILTER (WHERE e.origem_conversao IS NOT NULL)             AS origens_conversao,
    -- Atribuição de mídia paga. O valor do ÚLTIMO evento que trouxe cada sinal,
    -- não um min() arbitrário -- a última conversão é a que atribui.
    (array_agg(e.utm_campaign ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_campaign IS NOT NULL))[1]            AS utm_campaign,
    (array_agg(e.midia ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.midia IS NOT NULL))[1]                   AS plataforma,
    (array_agg(e.utm_id ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_id IS NOT NULL))[1]                  AS id_anuncio,
    (array_agg(e.utm_content ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_content IS NOT NULL))[1]             AS criativo,
    (array_agg(e.utm_term ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.utm_term IS NOT NULL))[1]                AS publico,
    count(*) FILTER (WHERE e.utm_campaign IS NOT NULL)          AS qtd_conversoes_pagas,
    (array_agg(e.cargo ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.cargo IS NOT NULL))[1]                   AS cargo,
    (array_agg(e.tamanho_empresa ORDER BY e.occurred_at DESC)
       FILTER (WHERE e.tamanho_empresa IS NOT NULL))[1]         AS tamanho_empresa
  FROM view_pessoa p
  JOIN lead_conversion_event e ON e.lead_id = p.rd_lead_id
  GROUP BY p.pessoa_chave
),
-- ── DIREITA: contas da pessoa. TODAS, sem colapsar ───────────────────────────
contas AS (
  SELECT DISTINCT p.pessoa_chave, a.id AS account_id, a.nome AS conta_nome
  FROM view_pessoa p
  JOIN lead l  ON l.id = p.sf_lead_id
  JOIN account a ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
),
-- ── DIREITA: o desfecho comercial, agregado ──────────────────────────────────
desfecho AS (
  SELECT
    ct.pessoa_chave,
    count(DISTINCT ct.account_id)                                     AS qtd_contas,
    count(DISTINCT o.id)                                              AS qtd_oportunidades,
    bool_or(f.fase = 'reuniao')                                       AS teve_reuniao,
    bool_or(f.fase = 'negociacao')                                    AS chegou_a_negociar,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'ganho')              AS qtd_ganhas,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'perdido')            AS qtd_perdidas,
    count(DISTINCT o.id) FILTER (WHERE f.fase IS NULL)                AS qtd_estagio_sem_fase,
    -- Desempate explicito: ganho vence perdido (migration 085).
    (array_agg(f.fase ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS fase_mais_avancada,
    max(f.ordem)                                                      AS fase_ordem,
    (array_agg(o.stage_name ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS estagio_mais_avancado,
    max(o.record_type_name)                                           AS record_type,
    max(o.closed_at_source)                                           AS ultima_movimentacao_em,
    sum(o.amount) FILTER (WHERE f.fase = 'ganho')                     AS amount_ganho,
    sum(o.mrr)    FILTER (WHERE f.fase = 'ganho')                     AS mrr_ganho,
    -- Amount JÁ É o total da oportunidade (migration 088). Sem prazo no meio.
    sum(o.amount) FILTER (WHERE f.fase = 'ganho')                     AS contrato_valor,
    string_agg(DISTINCT ct.conta_nome, ' · ')                         AS conta_nome
  FROM contas ct
  JOIN opportunity o ON o.account_id = ct.account_id
  LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  GROUP BY ct.pessoa_chave
),
-- Classificação de origem: a do registro do RD quando existe, senão a do SF.
-- O RD tem o sinal de conversão; o SF tem o LeadSource. Regra declarada.
classif AS (
  SELECT
    p.pessoa_chave,
    coalesce(crd.segmento,  csf.segmento)  AS segmento,
    coalesce(crd.categoria, csf.categoria) AS categoria,
    coalesce(crd.detalhe,   csf.detalhe)   AS detalhe,
    CASE WHEN crd.segmento IS NOT NULL THEN 'rd_station' ELSE 'salesforce' END AS classificado_por
  FROM view_pessoa p
  LEFT JOIN lead_origin_classification crd ON crd.lead_id = p.rd_lead_id AND crd.valid_to IS NULL
  LEFT JOIN lead_origin_classification csf ON csf.lead_id = p.sf_lead_id AND csf.valid_to IS NULL
)
SELECT
  p.pessoa_chave,
  p.nome,
  p.empresa,
  p.chave_origem,
  p.fontes,
  p.rd_lead_id,
  p.sf_lead_id,
  p.primeiro_registro_em,
  -- ── atribuição ──
  cl.segmento,
  cl.categoria,
  cl.detalhe,
  cl.classificado_por,
  lrd.lista_regra,
  (lrd.lista_regra IS NOT NULL)                       AS de_lista_importada,
  -- ── esquerda: a jornada ──
  coalesce(cv.qtd_conversoes, 0)                      AS qtd_conversoes,
  cv.origens_conversao,
  cv.primeira_conversao_em,
  cv.ultima_conversao_em,
  cv.utm_campaign,
  cv.plataforma,
  cv.id_anuncio,
  cv.criativo,
  cv.publico,
  coalesce(cv.qtd_conversoes_pagas, 0)                AS qtd_conversoes_pagas,
  coalesce(cv.cargo, lrd.cargo, lsf.cargo)            AS cargo,
  cv.tamanho_empresa,
  -- ── direita: o desfecho ──
  (p.sf_lead_id IS NOT NULL)                          AS existe_no_salesforce,
  lsf.status                                          AS status_no_salesforce,
  coalesce(d.qtd_contas, 0)                           AS qtd_contas,
  d.conta_nome,
  coalesce(d.qtd_oportunidades, 0)                    AS qtd_oportunidades,
  coalesce(d.teve_reuniao, false)                     AS teve_reuniao,
  coalesce(d.chegou_a_negociar, false)                AS chegou_a_negociar,
  coalesce(d.qtd_ganhas, 0)                           AS qtd_ganhas,
  coalesce(d.qtd_perdidas, 0)                         AS qtd_perdidas,
  coalesce(d.qtd_estagio_sem_fase, 0)                 AS qtd_estagio_sem_fase,
  d.fase_mais_avancada,
  d.fase_ordem,
  d.estagio_mais_avancado,
  d.record_type,
  d.ultima_movimentacao_em,
  d.amount_ganho,
  d.mrr_ganho,
  d.contrato_valor,
  -- ── dimensoes de filtro (ver JOIN com view_lead_perfil abaixo) ──
  coalesce(prd.trimestre,      psf.trimestre)      AS trimestre,
  coalesce(prd.cargo_grupo,    psf.cargo_grupo)    AS cargo_grupo,
  coalesce(prd.atendido_por,   psf.atendido_por)   AS atendido_por,
  coalesce(prd.estagio_funil,  psf.estagio_funil)  AS estagio_funil,
  coalesce(prd.tags,           psf.tags)           AS tags,
  coalesce(prd.fonte_dados,    psf.fonte_dados)    AS fonte_dados,
  -- O id que a FICHA usa para abrir (/api/leads/{id} busca por source_id, nao
  -- pelo id interno). Preferencia pelo registro do RD, que tem a jornada de
  -- conversao; Salesforce como reserva. Sem esta coluna a lista passaria o id
  -- interno e a ficha abriria vazia -- defeito que so aparece no clique.
  coalesce(lrd.source_id, lsf.source_id)              AS source_id_ficha
FROM view_pessoa p
LEFT JOIN lead lrd      ON lrd.id = p.rd_lead_id
LEFT JOIN lead lsf      ON lsf.id = p.sf_lead_id
-- Dimensoes que a barra de filtros da aba Leads ja usa. Vem de view_lead_perfil
-- para NAO reimplementar as regras de normalizacao (cargo_grupo, tamanho,
-- trimestre) numa segunda view -- duas implementacoes da mesma regra divergem,
-- e foi assim que o ramo do webhook divergiu do ramo do pull por 33 migrations.
-- Preferencia pelo registro do RD (tem a firmografia); Salesforce como reserva.
LEFT JOIN view_lead_perfil prd ON prd.lead_id = p.rd_lead_id
LEFT JOIN view_lead_perfil psf ON psf.lead_id = p.sf_lead_id
LEFT JOIN conv cv       ON cv.pessoa_chave = p.pessoa_chave
LEFT JOIN desfecho d    ON d.pessoa_chave  = p.pessoa_chave
LEFT JOIN classif cl    ON cl.pessoa_chave = p.pessoa_chave;

COMMENT ON VIEW view_pessoa_jornada_desfecho IS
  'A PERGUNTA CENTRAL DO EPICO. GRAO: UMA LINHA POR PESSOA. Esquerda = array de conversoes do RD (origens_conversao) + atribuicao de midia paga (id_anuncio, criativo, publico). Direita = desfecho comercial do Salesforce em colunas (teve_reuniao, chegou_a_negociar, fase_mais_avancada, ganhas, perdidas), traduzido por opportunity_stage_fase. NAO multiplica por oportunidade. RECEITA: `contrato_valor` = soma do Amount das ganhas, SEM prazo -- Amount e o valor total da oportunidade (decisao de 2026-09-15, migration 088). Igual a `amount_ganho` por construcao: a diferenca entre as duas colunas e que uma e o campo de origem e a outra e o conceito de negocio. Ver migrations 083 e 088.';

GRANT SELECT ON view_pessoa_jornada_desfecho TO crm_ingest;
