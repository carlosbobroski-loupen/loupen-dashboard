-- db/migrations/080_corrige_receita_e_agregacao_sem_regra.sql
--
-- DOIS BUGS ATIVOS -- numeros errados exibidos na tela hoje, nao divida tecnica.
-- Encontrados na revisao de arquitetura de 2026-09-15.

-- ─────────────────────────────────────────────────────────────────────────────
-- BUG 1: view_receita calcula contrato sobre a coluna que a 073 declarou errada
--
-- A view fazia DUAS coisas erradas, e a segunda e pior que a primeira:
--   (a) `amount AS mrr` -- renomeia Amount para MRR na saida. A suposicao
--       errada virou NOME DE COLUNA, o que a propaga para todo consumidor.
--   (b) `contrato_valor = amount * duracao_meses_contrato`
--
-- A migration 073 provou ontem, com linha real da org (Amount = 708,00 e
-- MRR__c = 2367,05), que sao campos diferentes. Criou `opportunity.mrr`,
-- reescreveu o COMMENT de `amount` avisando -- e NAO tocou esta view.
-- `view_lead_360` expoe `vr.contrato_valor` para a ficha do lead. Ou seja:
-- todo valor de contrato exibido desde ontem esta calculado sobre a coluna
-- que a propria equipe marcou como errada.
--
-- A CORRECAO NAO ESCOLHE por voce. A decisao "qual coluna sustenta receita"
-- e de negocio e esta em aberto. Entao a view passa a expor AS DUAS, cada uma
-- com o nome do campo de origem, e a tela tem de rotular qual esta mostrando.
-- Escolher aqui seria repetir exatamente o erro que criou o problema.

-- CREATE OR REPLACE nao consegue renomear coluna de view. E os nomes PRECISAM
-- mudar: manter `amount AS mrr` seria preservar exatamente a mentira que esta
-- migration existe para corrigir. Entao DROP + CREATE em cadeia, com o
-- procedimento que a migration 066 estabeleceu: conferir pg_depend antes (feito:
-- o unico dependente e view_lead_360) e REFAZER OS GRANTS depois -- esquecer o
-- grant foi o modo de falha real da migration 049.

DROP VIEW IF EXISTS view_lead_360;
DROP VIEW IF EXISTS view_receita;

CREATE VIEW view_receita AS
SELECT
  o.id                       AS opportunity_id,
  o.source_system,
  o.source_id,
  o.stage_name,
  o.amount                   AS amount,   -- Opportunity.Amount cru. NAO e o MRR.
  o.mrr                      AS mrr,      -- Opportunity.MRR__c cru (migration 073).
  o.duracao_meses_contrato,
  CASE WHEN o.stage_name = 'Ganho' AND o.duracao_meses_contrato IS NOT NULL
       THEN o.amount * o.duracao_meses_contrato::numeric END AS contrato_valor_por_amount,
  CASE WHEN o.stage_name = 'Ganho' AND o.duracao_meses_contrato IS NOT NULL
       THEN o.mrr * o.duracao_meses_contrato::numeric    END AS contrato_valor_por_mrr,
  CASE
    WHEN o.stage_name IS DISTINCT FROM 'Ganho'
      THEN 'Oportunidade ainda não está Ganha — valor de contrato não se aplica'
    WHEN o.duracao_meses_contrato IS NULL
      THEN 'Ganha, mas duração de contrato desconhecida na origem — contrato indisponível, nunca um prazo presumido'
    WHEN o.mrr IS NULL
      THEN 'Ganha e com duração, mas MRR__c vazio na origem (cobertura ~10%) — só o cálculo por Amount está disponível'
  END AS contrato_indisponivel_motivo
FROM opportunity o;

-- view_lead_360 recriada: consumia `vr.mrr` (que era Amount disfarcado) e
-- `vr.contrato_valor` (calculado sobre Amount). Passa a expor os dois valores,
-- com os nomes honestos, para a ficha do lead poder rotular qual esta mostrando.
--
-- NOTA DE GRAO, registrada mas NAO corrigida aqui: o nome diz "360 do lead" e o
-- grao e OPORTUNIDADE (LEFT JOIN opportunity). Um lead com 3 oportunidades
-- devolve 3 linhas. Renomear para view_lead_oportunidade e trabalho separado --
-- misturar renomeacao com correcao de bug num passo so e como o comentario
-- errado sobre MRR se propagou por 15 migrations.

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
    vr.contrato_valor_por_amount,
    vr.contrato_valor_por_mrr,
    vr.contrato_indisponivel_motivo
   FROM lead l
     LEFT JOIN lead_origin_classification loc ON loc.lead_id = l.id AND loc.valid_to IS NULL
     LEFT JOIN account a ON a.source_system = l.source_system AND a.source_id = l.converted_account_id
     LEFT JOIN opportunity o ON o.account_id = a.id
     LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
     LEFT JOIN view_receita vr ON vr.opportunity_id = o.id;

-- Grants refeitos -- DROP leva os privilegios junto.
GRANT SELECT ON view_receita  TO crm_ingest;
GRANT SELECT ON view_lead_360 TO crm_ingest;

COMMENT ON VIEW view_receita IS
  'Grao: UMA LINHA POR OPORTUNIDADE. Expoe amount e mrr CRUS, com os nomes dos campos de origem, e o valor de contrato calculado pelas DUAS bases -- porque qual delas sustenta receita e decisao de negocio em aberto desde a migration 073. Quem consome DEVE rotular qual esta exibindo. Ver migration 080.';

-- ─────────────────────────────────────────────────────────────────────────────
-- BUG 2: view_marketing_rd_sf agrega campo de negocio com min()
--
--   min(l.status) AS sf_status  -> devolve o status ALFABETICAMENTE menor entre
--                                  os leads Salesforce daquela pessoa. Nao o
--                                  mais recente, nao o mais avancado.
--   min(a.id)     AS account_id -> escolhe UMA conta arbitraria. O CTE de
--                                  oportunidades junta so por essa conta, entao
--                                  PESSOA COM DUAS CONTAS PERDE AS OPORTUNIDADES
--                                  DA SEGUNDA, em silencio.
--
-- Mesma classe de defeito que a migration 064 pegou (campanha contada em
-- dobro): agregacao sem regra de negocio declarada.
--
-- De quebra, esta versao LIGA a opportunity_stage_fase (migration 079), que
-- estava orfa -- nenhuma view a lia. Sao as colunas que respondem "houve
-- reuniao?" e "chegou a negociar?", que e metade da pergunta do usuario.

-- Mesmo motivo do bloco acima: acrescentar coluna no meio conta como renomear
-- coluna posicional, e CREATE OR REPLACE recusa. Sem dependentes em pg_depend
-- (fn_marketing_funil* tem corpo em string, nao cria dependencia), entao DROP
-- simples, sem CASCADE -- CASCADE aqui derrubaria as funcoes junto.
DROP VIEW IF EXISTS view_marketing_rd_sf;

CREATE VIEW view_marketing_rd_sf AS
WITH rd AS (
  SELECT
    l.id AS rd_lead_id, l.source_id AS rd_uuid, l.nome, l.empresa,
    l.created_at_source AS criado_em, l.lista_regra,
    ie.person_id, c.categoria, c.detalhe, c.valor_bruto AS origem_conversao
  FROM lead l
  JOIN identity_edge ie
    ON ie.source_system = l.source_system AND ie.source_record_id = l.source_id
   AND ie.identifier_type = 'email'
  JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
  WHERE l.source_system = 'rd_station' AND NOT l.is_teste AND c.segmento = 'Marketing'
),
-- Status: o MAIS RECENTE, por data de criacao do lead. Regra declarada, nao min().
sf AS (
  SELECT DISTINCT ON (ie.person_id)
    ie.person_id, l.id AS sf_lead_id, l.status AS sf_status
  FROM lead l
  JOIN identity_edge ie
    ON ie.source_system = l.source_system AND ie.source_record_id = l.source_id
   AND ie.identifier_type = 'email'
  WHERE l.source_system = 'salesforce'
  ORDER BY ie.person_id, l.created_at_source DESC NULLS LAST, l.id DESC
),
-- TODAS as contas da pessoa. Nao colapsa -- era aqui que as oportunidades sumiam.
contas AS (
  SELECT DISTINCT ie.person_id, a.id AS account_id, a.nome AS conta_nome
  FROM lead l
  JOIN identity_edge ie
    ON ie.source_system = l.source_system AND ie.source_record_id = l.source_id
   AND ie.identifier_type = 'email'
  JOIN account a ON a.source_system = 'salesforce' AND a.source_id = l.converted_account_id
  WHERE l.source_system = 'salesforce'
),
opp AS (
  SELECT
    ct.person_id,
    count(DISTINCT o.id)                                       AS qtd_oportunidades,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'ganho')        AS qtd_ganhas,
    count(DISTINCT o.id) FILTER (WHERE f.fase = 'perdido')      AS qtd_perdidas,
    -- As colunas que a pergunta do usuario pede, vindas da 079:
    bool_or(f.fase = 'reuniao')                                 AS teve_reuniao,
    bool_or(f.fase = 'negociacao')                              AS chegou_a_negociar,
    max(f.ordem)                                                AS fase_ordem_max,
    (array_agg(f.fase ORDER BY (f.fase='ganho') DESC, f.ordem DESC NULLS LAST))[1] AS fase_mais_avancada,
    count(DISTINCT o.id) FILTER (WHERE f.fase IS NULL)          AS qtd_estagio_sem_fase,
    sum(o.amount) FILTER (WHERE f.fase = 'ganho')               AS amount_ganho,
    sum(o.mrr)    FILTER (WHERE f.fase = 'ganho')               AS mrr_ganho,
    max(o.record_type_name)                                     AS record_type
  FROM contas ct
  JOIN opportunity o ON o.account_id = ct.account_id
  LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  GROUP BY ct.person_id
),
conta_nomes AS (
  SELECT person_id, string_agg(DISTINCT conta_nome, ' · ') AS conta_nome,
         count(*) AS qtd_contas
  FROM contas GROUP BY person_id
)
SELECT
  rd.rd_lead_id, rd.rd_uuid, rd.nome, rd.empresa, rd.criado_em,
  rd.categoria, rd.detalhe, rd.origem_conversao,
  (rd.lista_regra IS NOT NULL)          AS de_lista_importada,
  rd.lista_regra,
  (sf.sf_lead_id IS NOT NULL)           AS achado_no_salesforce,
  sf.sf_status                          AS status_no_salesforce,
  (cn.person_id IS NOT NULL)            AS virou_conta,
  cn.conta_nome,
  coalesce(cn.qtd_contas, 0)            AS qtd_contas,
  coalesce(opp.qtd_oportunidades, 0)    AS qtd_oportunidades,
  coalesce(opp.qtd_ganhas, 0)           AS qtd_ganhas,
  coalesce(opp.qtd_perdidas, 0)         AS qtd_perdidas,
  coalesce(opp.teve_reuniao, false)     AS teve_reuniao,
  coalesce(opp.chegou_a_negociar, false) AS chegou_a_negociar,
  opp.fase_mais_avancada,
  opp.fase_ordem_max,
  coalesce(opp.qtd_estagio_sem_fase, 0) AS qtd_estagio_sem_fase,
  opp.amount_ganho,
  opp.mrr_ganho,
  opp.record_type
FROM rd
LEFT JOIN sf          ON sf.person_id  = rd.person_id
LEFT JOIN opp         ON opp.person_id = rd.person_id
LEFT JOIN conta_nomes cn ON cn.person_id = rd.person_id;

COMMENT ON VIEW view_marketing_rd_sf IS
  'UMA LINHA POR LEAD DE MARKETING DO RD STATION, com o desfecho dele no Salesforce. Status = o MAIS RECENTE (regra declarada); oportunidades contam TODAS as contas da pessoa -- a versao anterior usava min() e perdia as da segunda conta em silencio (corrigido na migration 080). Fase comercial vem de opportunity_stage_fase (079). Ver migrations 077 e 080.';

GRANT SELECT ON view_marketing_rd_sf TO crm_ingest;
