-- db/migrations/093_null_nao_vence_ganho.sql
--
-- A 085 VOLTOU PELA PORTA DO NULL.
--
-- A 085 consertou um caso concreto: uma pessoa com 4 oportunidades GANHAS
-- aparecia com `fase_mais_avancada = 'perdido'`, porque a 079 deu ordem 5 a
-- `ganho` e 6 a `perdido` e as views calculam a fase mais avançada com
-- `max(ordem)`. A correção foi empatar os dois terminais em 5 e desempatar
-- preferindo ganho:
--
--   ORDER BY (f.fase = 'ganho') DESC, f.ordem DESC NULLS LAST
--
-- POR QUE A 085 NÃO PEGOU ESTE CASO. Ela raciocinou sobre duas fases que
-- EXISTEM e brigam entre si. Não havia terceiro competidor. Só que o join com
-- `opportunity_stage_fase` é LEFT, e estágio que ninguém mapeou entra com
-- `f.fase IS NULL` — e aí `(f.fase = 'ganho')` não é `false`, é NULL. Em
-- `ORDER BY ... DESC` o padrão do Postgres é NULLS FIRST. O desconhecido passa
-- na frente de ganho, de perdido e de tudo.
--
-- O `NULLS LAST` que já estava escrito na SEGUNDA chave (`f.ordem`) mostra que
-- o problema era conhecido — só não foi aplicado na primeira, onde o NULL não
-- vem de uma coluna e sim da comparação.
--
-- MEDIDO, com o defeito REPRODUZIDO em transação revertida (2026-09-16):
-- basta uma oportunidade com estágio não mapeado na conta de `email:1316`,
-- pessoa com 2 vitórias, para a view devolver
--
--   fase_mais_avancada = NULL
--   estagio_mais_avancado = 'Estagio Novo Que Ninguem Mapeou Ainda'
--
-- A tela então renderiza o nome cru do estágio no lugar de "Ganho", com a
-- barra de fase zerada, para quem comprou. Antes da 092 isso não era hipótese:
-- 4 pessoas estavam assim na base real, DUAS delas com vitória (`email:573`
-- com 1 ganha e `solo:salesforce:00QV200000f7ztd` com 2), escondidas atrás de
-- `Pending Sale` e `Projeto para o Futuro`. A 092 mapeou os órfãos e zerou a
-- contagem — mas mapear os órfãos de hoje não é consertar o desempate.
-- `Lista` segue com fase NULL DE PROPÓSITO (092), e todo estágio novo que a
-- org criar no Setup nasce sem fase até alguém decidir.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- POR QUE `NULLS LAST` E NÃO `coalesce(f.fase, '')`
--
-- Um `coalesce` resolveria a ordenação e afirmaria algo que não sabemos.
-- `(f.fase = 'ganho')` devolver NULL não é um defeito da expressão: é a
-- resposta correta para "este estágio é uma venda ganha?" quando ninguém
-- classificou o estágio. É DESCONHECIDO, não `false`.
--
-- `coalesce(f.fase, '') = 'ganho'` transforma desconhecido em "definitivamente
-- não é ganho", que é uma afirmação mais forte do que temos. E ela ENVELHECE
-- MAL na direção errada: se a org criar um `Closed Won` novo, o coalesce o
-- classifica em silêncio como não-ganho e a venda some — o mesmo tipo de
-- colapso num balde residual que a 079 recusou, só que escondido num ORDER BY.
--
-- `NULLS LAST` diz outra coisa, mais modesta e verdadeira: DESCONHECIDO NÃO É
-- MELHOR QUE CONHECIDO. Não afirma o que o estágio é; só recusa deixá-lo
-- vencer de quem já foi classificado. `fase_mais_avancada` continua NULL para
-- quem só tem estágio sem fase (que é o fato), e `qtd_estagio_sem_fase` /
-- `estagio_mais_avancado` continuam mostrando qual estágio é.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- ONDE O PADRÃO APARECE — três ocorrências, duas views
--
-- Varrido no catálogo vivo (`pg_get_viewdef` de todas as views + todas as
-- funções), não nos arquivos de migration, que são histórico:
--
--   view_pessoa_jornada_desfecho   2x  (fase_mais_avancada, estagio_mais_avancado)
--   view_marketing_rd_sf           1x  (fase_mais_avancada)
--
-- ONDE NÃO APARECE, conferido:
--   view_receita e view_lead_360 — grão de OPORTUNIDADE, uma linha por
--     oportunidade. Não agregam nem desempatam; expõem `f.fase` direto.
--   fn_search_pessoas — LÊ `v.fase_mais_avancada` da view, não reimplementa o
--     desempate. Por isso NÃO é tocada aqui, e o `plan_cache_mode =
--     'force_custom_plan'` da 089 fica onde está: `DROP FUNCTION` o
--     descartaria, e não há motivo para dropar.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- COMO
--
-- `CREATE OR REPLACE VIEW`, não DROP + CREATE. A lista de colunas não muda
-- (nome, tipo e ordem idênticos), então o REPLACE é aceito, as dependências
-- não quebram e os GRANTs não são perdidos — foi perder privilégio no DROP que
-- obrigou a 090 a reemitir os grants. As definições abaixo são as que estavam
-- em produção nesta data, extraídas de `pg_get_viewdef`, com UMA alteração
-- cada: `NULLS LAST` na primeira chave do ORDER BY.

CREATE OR REPLACE VIEW view_pessoa_jornada_desfecho AS
 WITH conv AS (
         SELECT p_1.pessoa_chave,
            count(*) AS qtd_conversoes,
            min(e.occurred_at) AS primeira_conversao_em,
            max(e.occurred_at) AS ultima_conversao_em,
            array_agg(DISTINCT e.origem_conversao) FILTER (WHERE e.origem_conversao IS NOT NULL) AS origens_conversao,
            (array_agg(e.utm_campaign ORDER BY e.occurred_at DESC) FILTER (WHERE e.utm_campaign IS NOT NULL))[1] AS utm_campaign,
            (array_agg(e.midia ORDER BY e.occurred_at DESC) FILTER (WHERE e.midia IS NOT NULL))[1] AS plataforma,
            (array_agg(e.utm_id ORDER BY e.occurred_at DESC) FILTER (WHERE e.utm_id IS NOT NULL))[1] AS id_anuncio,
            (array_agg(e.utm_content ORDER BY e.occurred_at DESC) FILTER (WHERE e.utm_content IS NOT NULL))[1] AS criativo,
            (array_agg(e.utm_term ORDER BY e.occurred_at DESC) FILTER (WHERE e.utm_term IS NOT NULL))[1] AS publico,
            count(*) FILTER (WHERE e.utm_campaign IS NOT NULL) AS qtd_conversoes_pagas,
            (array_agg(e.cargo ORDER BY e.occurred_at DESC) FILTER (WHERE e.cargo IS NOT NULL))[1] AS cargo,
            (array_agg(e.tamanho_empresa ORDER BY e.occurred_at DESC) FILTER (WHERE e.tamanho_empresa IS NOT NULL))[1] AS tamanho_empresa
           FROM view_pessoa p_1
             JOIN lead_conversion_event e ON e.lead_id = p_1.rd_lead_id
          GROUP BY p_1.pessoa_chave
        ), contas AS (
         SELECT DISTINCT p_1.pessoa_chave,
            a.id AS account_id,
            a.nome AS conta_nome
           FROM view_pessoa p_1
             JOIN lead l ON l.id = p_1.sf_lead_id
             JOIN account a ON a.source_system = 'salesforce'::text AND a.source_id = l.converted_account_id
        ), desfecho AS (
         SELECT ct.pessoa_chave,
            count(DISTINCT ct.account_id) AS qtd_contas,
            count(DISTINCT o.id) AS qtd_oportunidades,
            bool_or(f.fase = 'reuniao'::text) AS teve_reuniao,
            bool_or(f.fase = 'negociacao'::text) AS chegou_a_negociar,
            count(DISTINCT o.id) FILTER (WHERE f.fase = 'ganho'::text) AS qtd_ganhas,
            count(DISTINCT o.id) FILTER (WHERE f.fase = 'perdido'::text) AS qtd_perdidas,
            count(DISTINCT o.id) FILTER (WHERE f.fase IS NULL) AS qtd_estagio_sem_fase,
            (array_agg(f.fase ORDER BY (f.fase = 'ganho'::text) DESC NULLS LAST, f.ordem DESC NULLS LAST))[1] AS fase_mais_avancada,
            max(f.ordem) AS fase_ordem,
            (array_agg(o.stage_name ORDER BY (f.fase = 'ganho'::text) DESC NULLS LAST, f.ordem DESC NULLS LAST))[1] AS estagio_mais_avancado,
            max(o.record_type_name) AS record_type,
            max(o.closed_at_source) AS ultima_movimentacao_em,
            sum(o.amount) FILTER (WHERE f.fase = 'ganho'::text) AS amount_ganho,
            sum(o.mrr) FILTER (WHERE f.fase = 'ganho'::text) AS mrr_ganho,
            sum(o.amount) FILTER (WHERE f.fase = 'ganho'::text) AS contrato_valor,
            sum(vr.amount_brl) FILTER (WHERE f.fase = 'ganho'::text) AS amount_ganho_brl,
            sum(vr.amount_brl) FILTER (WHERE f.fase = 'ganho'::text) AS contrato_valor_brl,
            count(*) FILTER (WHERE f.fase = 'ganho'::text AND o.amount IS NOT NULL AND vr.amount_brl IS NULL) AS qtd_ganhas_sem_conversao,
            string_agg(DISTINCT vr.conversao_indisponivel_motivo, ' · '::text) FILTER (WHERE f.fase = 'ganho'::text AND o.amount IS NOT NULL AND vr.amount_brl IS NULL) AS conversao_indisponivel_motivo,
            array_agg(DISTINCT o.currency_iso_code) FILTER (WHERE f.fase = 'ganho'::text AND o.currency_iso_code IS NOT NULL) AS moedas_ganho,
            string_agg(DISTINCT ct.conta_nome, ' · '::text) AS conta_nome
           FROM contas ct
             JOIN opportunity o ON o.account_id = ct.account_id
             LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
             LEFT JOIN view_receita vr ON vr.opportunity_id = o.id
          GROUP BY ct.pessoa_chave
        ), classif AS (
         SELECT p_1.pessoa_chave,
            COALESCE(crd.segmento, csf.segmento) AS segmento,
            COALESCE(crd.categoria, csf.categoria) AS categoria,
            COALESCE(crd.detalhe, csf.detalhe) AS detalhe,
                CASE
                    WHEN crd.segmento IS NOT NULL THEN 'rd_station'::text
                    ELSE 'salesforce'::text
                END AS classificado_por
           FROM view_pessoa p_1
             LEFT JOIN lead_origin_classification crd ON crd.lead_id = p_1.rd_lead_id AND crd.valid_to IS NULL
             LEFT JOIN lead_origin_classification csf ON csf.lead_id = p_1.sf_lead_id AND csf.valid_to IS NULL
        )
 SELECT p.pessoa_chave,
    p.nome,
    p.empresa,
    p.chave_origem,
    p.fontes,
    p.rd_lead_id,
    p.sf_lead_id,
    p.primeiro_registro_em,
    cl.segmento,
    cl.categoria,
    cl.detalhe,
    cl.classificado_por,
    lrd.lista_regra,
    lrd.lista_regra IS NOT NULL AS de_lista_importada,
    COALESCE(cv.qtd_conversoes, 0::bigint) AS qtd_conversoes,
    cv.origens_conversao,
    cv.primeira_conversao_em,
    cv.ultima_conversao_em,
    cv.utm_campaign,
    cv.plataforma,
    cv.id_anuncio,
    cv.criativo,
    cv.publico,
    COALESCE(cv.qtd_conversoes_pagas, 0::bigint) AS qtd_conversoes_pagas,
    COALESCE(cv.cargo, lrd.cargo, lsf.cargo) AS cargo,
    cv.tamanho_empresa,
    p.sf_lead_id IS NOT NULL AS existe_no_salesforce,
    lsf.status AS status_no_salesforce,
    COALESCE(d.qtd_contas, 0::bigint) AS qtd_contas,
    d.conta_nome,
    COALESCE(d.qtd_oportunidades, 0::bigint) AS qtd_oportunidades,
    COALESCE(d.teve_reuniao, false) AS teve_reuniao,
    COALESCE(d.chegou_a_negociar, false) AS chegou_a_negociar,
    COALESCE(d.qtd_ganhas, 0::bigint) AS qtd_ganhas,
    COALESCE(d.qtd_perdidas, 0::bigint) AS qtd_perdidas,
    COALESCE(d.qtd_estagio_sem_fase, 0::bigint) AS qtd_estagio_sem_fase,
    d.fase_mais_avancada,
    d.fase_ordem,
    d.estagio_mais_avancado,
    d.record_type,
    d.ultima_movimentacao_em,
    d.amount_ganho,
    d.mrr_ganho,
    d.contrato_valor,
    d.amount_ganho_brl,
    d.contrato_valor_brl,
    COALESCE(d.qtd_ganhas_sem_conversao, 0::bigint) AS qtd_ganhas_sem_conversao,
    d.conversao_indisponivel_motivo,
    d.moedas_ganho,
    COALESCE(prd.trimestre, psf.trimestre) AS trimestre,
    COALESCE(prd.cargo_grupo, psf.cargo_grupo) AS cargo_grupo,
    COALESCE(prd.atendido_por, psf.atendido_por) AS atendido_por,
    COALESCE(prd.estagio_funil, psf.estagio_funil) AS estagio_funil,
    COALESCE(prd.tags, psf.tags) AS tags,
    COALESCE(prd.fonte_dados, psf.fonte_dados) AS fonte_dados,
    COALESCE(lrd.source_id, lsf.source_id) AS source_id_ficha
   FROM view_pessoa p
     LEFT JOIN lead lrd ON lrd.id = p.rd_lead_id
     LEFT JOIN lead lsf ON lsf.id = p.sf_lead_id
     LEFT JOIN view_lead_perfil prd ON prd.lead_id = p.rd_lead_id
     LEFT JOIN view_lead_perfil psf ON psf.lead_id = p.sf_lead_id
     LEFT JOIN conv cv ON cv.pessoa_chave = p.pessoa_chave
     LEFT JOIN desfecho d ON d.pessoa_chave = p.pessoa_chave
     LEFT JOIN classif cl ON cl.pessoa_chave = p.pessoa_chave;

CREATE OR REPLACE VIEW view_marketing_rd_sf AS
 WITH rd AS (
         SELECT l.id AS rd_lead_id,
            l.source_id AS rd_uuid,
            l.nome,
            l.empresa,
            l.created_at_source AS criado_em,
            l.lista_regra,
            ie.person_id,
            c.categoria,
            c.detalhe,
            c.valor_bruto AS origem_conversao
           FROM lead l
             JOIN identity_edge ie ON ie.source_system = l.source_system AND ie.source_record_id = l.source_id AND ie.identifier_type = 'email'::text
             JOIN lead_origin_classification c ON c.lead_id = l.id AND c.valid_to IS NULL
          WHERE l.source_system = 'rd_station'::text AND NOT l.is_teste AND c.segmento = 'Marketing'::text
        ), sf AS (
         SELECT DISTINCT ON (ie.person_id) ie.person_id,
            l.id AS sf_lead_id,
            l.status AS sf_status
           FROM lead l
             JOIN identity_edge ie ON ie.source_system = l.source_system AND ie.source_record_id = l.source_id AND ie.identifier_type = 'email'::text
          WHERE l.source_system = 'salesforce'::text
          ORDER BY ie.person_id, l.created_at_source DESC NULLS LAST, l.id DESC
        ), contas AS (
         SELECT DISTINCT ie.person_id,
            a.id AS account_id,
            a.nome AS conta_nome
           FROM lead l
             JOIN identity_edge ie ON ie.source_system = l.source_system AND ie.source_record_id = l.source_id AND ie.identifier_type = 'email'::text
             JOIN account a ON a.source_system = 'salesforce'::text AND a.source_id = l.converted_account_id
          WHERE l.source_system = 'salesforce'::text
        ), opp AS (
         SELECT ct.person_id,
            count(DISTINCT o.id) AS qtd_oportunidades,
            count(DISTINCT o.id) FILTER (WHERE f.fase = 'ganho'::text) AS qtd_ganhas,
            count(DISTINCT o.id) FILTER (WHERE f.fase = 'perdido'::text) AS qtd_perdidas,
            bool_or(f.fase = 'reuniao'::text) AS teve_reuniao,
            bool_or(f.fase = 'negociacao'::text) AS chegou_a_negociar,
            max(f.ordem) AS fase_ordem_max,
            (array_agg(f.fase ORDER BY (f.fase = 'ganho'::text) DESC NULLS LAST, f.ordem DESC NULLS LAST))[1] AS fase_mais_avancada,
            count(DISTINCT o.id) FILTER (WHERE f.fase IS NULL) AS qtd_estagio_sem_fase,
            sum(o.amount) FILTER (WHERE f.fase = 'ganho'::text) AS amount_ganho,
            sum(o.mrr) FILTER (WHERE f.fase = 'ganho'::text) AS mrr_ganho,
            max(o.record_type_name) AS record_type
           FROM contas ct
             JOIN opportunity o ON o.account_id = ct.account_id
             LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
          GROUP BY ct.person_id
        ), conta_nomes AS (
         SELECT contas.person_id,
            string_agg(DISTINCT contas.conta_nome, ' · '::text) AS conta_nome,
            count(*) AS qtd_contas
           FROM contas
          GROUP BY contas.person_id
        )
 SELECT rd.rd_lead_id,
    rd.rd_uuid,
    rd.nome,
    rd.empresa,
    rd.criado_em,
    rd.categoria,
    rd.detalhe,
    rd.origem_conversao,
    rd.lista_regra IS NOT NULL AS de_lista_importada,
    rd.lista_regra,
    sf.sf_lead_id IS NOT NULL AS achado_no_salesforce,
    sf.sf_status AS status_no_salesforce,
    cn.person_id IS NOT NULL AS virou_conta,
    cn.conta_nome,
    COALESCE(cn.qtd_contas, 0::bigint) AS qtd_contas,
    COALESCE(opp.qtd_oportunidades, 0::bigint) AS qtd_oportunidades,
    COALESCE(opp.qtd_ganhas, 0::bigint) AS qtd_ganhas,
    COALESCE(opp.qtd_perdidas, 0::bigint) AS qtd_perdidas,
    COALESCE(opp.teve_reuniao, false) AS teve_reuniao,
    COALESCE(opp.chegou_a_negociar, false) AS chegou_a_negociar,
    opp.fase_mais_avancada,
    opp.fase_ordem_max,
    COALESCE(opp.qtd_estagio_sem_fase, 0::bigint) AS qtd_estagio_sem_fase,
    opp.amount_ganho,
    opp.mrr_ganho,
    opp.record_type
   FROM rd
     LEFT JOIN sf ON sf.person_id = rd.person_id
     LEFT JOIN opp ON opp.person_id = rd.person_id
     LEFT JOIN conta_nomes cn ON cn.person_id = rd.person_id;

-- ═════════════════════════════════════════════════════════════════════════════
-- AVISO — quantas pessoas ainda dependem de um estágio sem fase
-- ═════════════════════════════════════════════════════════════════════════════
-- Depois desta migration, ter estágio sem fase deixa de ESCONDER o desfecho.
-- Continua valendo saber quantas pessoas têm um, porque é o sinal de que a
-- org criou estágio novo e ninguém decidiu ainda.
DO $$
DECLARE v_pessoas integer; v_com_ganho integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE qtd_ganhas > 0)
    INTO v_pessoas, v_com_ganho
  FROM view_pessoa_jornada_desfecho
  WHERE qtd_estagio_sem_fase > 0;
  RAISE NOTICE 'Pessoas com alguma oportunidade em estagio SEM FASE: % (dessas, % com vitoria). Antes da 093 o desfecho delas aparecia como NULL.', v_pessoas, v_com_ganho;
END $$;
