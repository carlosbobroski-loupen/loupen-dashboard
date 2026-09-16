-- db/queries/verificacao/auditoria-aba-oportunidades.sql
--
-- AUDITORIA DA ABA "OPORTUNIDADES" — reconciliação planilha (gviz) x Neon.
-- Data da execução original: 2026-09-15. Período auditado: 2026-06-01 a 2026-09-15.
-- Executar com:  psql "$NEON_DATABASE_URL" -f db/queries/verificacao/auditoria-aba-oportunidades.sql
--
-- NÃO cria nem altera nada permanente. Só TEMP TABLE + SELECT.
--
-- CONTEXTO
-- A aba lê a planilha 1xSC6e91_uHYRPkzD0idX3jJcb-GmhL-BCY4BMsZQuYc (gid=0), que é uma
-- exportação MANUAL de um relatório de Lead do Salesforce, cruzada por e-mail com a
-- "Central de Leads" (12xck94yAtE94Z6XK-aZJW13q55mt9YQRNzFPsCDi2Og / aba Conversoes).
-- O Neon é alimentado por outro caminho: Salesforce -> n8n (hora em hora) -> Neon.
-- Ninguém reconcilia os dois. Este arquivo reconcilia.
--
-- PRÉ-REQUISITO PARA AS SEÇÕES 4+ (join linha a linha)
-- Gerar o TSV da planilha e carregá-lo em sheet_sf. O TSV tem 8 colunas, sem cabeçalho:
--   email \t status \t fase \t tem_opp(0|1) \t valor_opp \t valor_nf \t mkt(0|1) \t origem
-- A geração replica a lógica de assets/js/views-legacy.js (loadSalesforce + salesforceInRange).
-- Sem o TSV, as seções 1 a 3 rodam sozinhas.

\set PERIODO_INI '2026-06-01'
\set PERIODO_FIM '2026-09-16'   -- exclusivo

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. POPULAÇÃO: quantos leads o Neon tem no período
--    Tela: "Leads recebidos 513". Neon: 2.753. A planilha NÃO é o CRM.
-- ═══════════════════════════════════════════════════════════════════════════
select count(*) as sf_leads_no_periodo
from lead
where source_system = 'salesforce'
  and created_at_source >= :'PERIODO_INI' and created_at_source < :'PERIODO_FIM';

-- Distribuição por status. Serve para o item 2 (cobertura dos cards).
select status, count(*)
from lead
where source_system = 'salesforce'
  and created_at_source >= :'PERIODO_INI' and created_at_source < :'PERIODO_FIM'
group by 1 order by 2 desc;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. COBERTURA DOS CARDS
--    O frontend só reconhece 3 recortes de status: 'contato dia%' (Em cadência),
--    'qualificado' (Qualificados) e 'rejeitado' (Rejeitados). Tudo o mais é invisível.
--    Resultado 2026-09-15: 1.556 de 2.753 leads (56,5%) não aparecem em card nenhum,
--    incluindo 699 'Descalificado' — que é uma rejeição que o card "Rejeitados" não conta.
-- ═══════════════════════════════════════════════════════════════════════════
with base as (
  select status, count(*) n from lead
  where source_system = 'salesforce'
    and created_at_source >= :'PERIODO_INI' and created_at_source < :'PERIODO_FIM'
  group by 1)
select case
    when lower(status) like 'contato dia%' then 'card Em cadencia'
    when lower(status) = 'qualificado'     then 'card Qualificados'
    when lower(status) = 'rejeitado'       then 'card Rejeitados'
    else 'NENHUM CARD' end as card,
  sum(n) as leads,
  string_agg(status || ' (' || n || ')', ', ' order by n desc) as status_incluidos
from base group by 1 order by 2 desc;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. REJEIÇÃO: humana ou automação?
--    Teste: se rejeição fosse juízo comercial sobre o lead, a mesma família de
--    campanha em meses diferentes rejeitaria em taxa parecida. Não é o que acontece.
--    Resultado 2026-09-15: LOGMEIN_RESCUE-..._07-26 = 87%, _08-26 = 82%, _09_26_ = 5,7%.
--    A rejeição acompanha o CALENDÁRIO, não a campanha. Asserção "é juízo humano" FALSIFICADA.
-- ═══════════════════════════════════════════════════════════════════════════
select coalesce(origem_bruta, '(sem origem)') as leadsource,
       count(*) as total,
       count(*) filter (where status = 'Rejeitado') as rejeitados,
       round(100.0 * count(*) filter (where status = 'Rejeitado') / count(*), 1) as pct_rejeicao
from lead
where source_system = 'salesforce'
  and created_at_source >= :'PERIODO_INI' and created_at_source < :'PERIODO_FIM'
  and origem_bruta not in ('Apollo.Io', 'Startup Summit 2026')   -- listas de prospecção, outra mecânica
group by 1 having count(*) >= 5 order by 2 desc;

-- Coorte semanal de criação x taxa de rejeição, escopo Marketing.
-- Resultado: 78–98% para todas as coortes criadas ATÉ 2026-08-17; 18% e 5% para as
-- criadas a partir de 2026-08-24. A quebra é uma FRONTEIRA DE IDADE do lead no momento
-- da varredura de 01/09/2026 — assinatura de regra automática de auto-rejeição por
-- inatividade aplicada em massa, não de avaliação individual.
select date_trunc('week', l.created_at_source)::date as semana,
       count(*) as total,
       count(*) filter (where l.status = 'Rejeitado') as rejeitados,
       round(100.0 * count(*) filter (where l.status = 'Rejeitado') / count(*), 1) as pct
from lead l
  join lead_origin_classification c on c.lead_id = l.id and c.valid_to is null
where l.source_system = 'salesforce'
  and l.created_at_source >= :'PERIODO_INI' and l.created_at_source < :'PERIODO_FIM'
  and c.segmento = 'Marketing'
group by 1 order by 1;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. CARGA DA PLANILHA (necessário para as seções 5 a 8)
-- ═══════════════════════════════════════════════════════════════════════════
create temp table sheet_sf(
  email text, status text, fase text, tem_opp text,
  valor_opp numeric, valor_nf numeric, mkt text, origem text);
-- \copy sheet_sf from '/caminho/para/sheet.tsv' with (format text, delimiter E'\t')

-- Uma linha por e-mail da planilha, casada com o lead mais recente do Neon.
create temp table m as
select distinct on (s.email)
       s.*, l.id as lead_id, l.status as neon_status, l.origem_bruta,
       l.created_at_source, l.converted_account_id, c.segmento
from sheet_sf s
  join lead l on l.source_system = 'salesforce' and lower(l.email) = s.email
  left join lead_origin_classification c on c.lead_id = l.id and c.valid_to is null
order by s.email, l.created_at_source desc nulls last;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. A PLANILHA É SUBCONJUNTO DO NEON
--    Resultado 2026-09-15: 513/513 da planilha existem no Neon (0 órfãos).
--    O Neon tem 2.216 leads no período que a planilha não tem.
-- ═══════════════════════════════════════════════════════════════════════════
select count(*) as total_neon_periodo,
  count(*) filter (where     exists (select 1 from sheet_sf s where s.email = lower(l.email))) as na_planilha,
  count(*) filter (where not exists (select 1 from sheet_sf s where s.email = lower(l.email))) as fora_da_planilha
from lead l
where l.source_system = 'salesforce'
  and l.created_at_source >= :'PERIODO_INI' and l.created_at_source < :'PERIODO_FIM';

-- O que exatamente ficou de fora, por origem. Repare nas origens comerciais/indicação:
-- Indicação Cliente 32/32 convertidas, Cliente da base 13/13, Indicação Parceiro 7/7,
-- Loupen_Chat 8/8, Outbound 16/18 — justamente as que mais viram negócio.
select coalesce(l.origem_bruta, '(sem origem)') as origem,
       count(*) as ausentes_da_planilha,
       count(*) filter (where l.converted_account_id is not null) as desses_convertidos
from lead l
where l.source_system = 'salesforce'
  and l.created_at_source >= :'PERIODO_INI' and l.created_at_source < :'PERIODO_FIM'
  and not exists (select 1 from sheet_sf s where s.email = lower(l.email))
group by 1 order by 2 desc;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. STATUS E SEGMENTO: planilha x Neon, linha a linha
--    Status: 498/508 iguais (a coluna de status da planilha está fresca).
--    Segmento: 240 leads que a planilha chama de "Comercial" o Neon classifica como
--    "Marketing" — 228 deles são "Startup Summit 2026" (Evento/Webinar). O split
--    "266 Marketing · 247 Comercial" da tela está essencialmente invertido.
-- ═══════════════════════════════════════════════════════════════════════════
select count(*) filter (where status = neon_status)             as status_igual,
       count(*) filter (where status is distinct from neon_status) as status_diferente
from m;

select status as planilha, neon_status as neon, count(*)
from m where status is distinct from neon_status group by 1,2 order by 3 desc;

select case when mkt = '1' then 'Marketing' else 'Comercial' end as planilha_seg,
       segmento as neon_seg, count(*)
from m group by 1,2 order by 3 desc;

-- Quais origens produzem a divergência de segmento.
select m.origem_bruta, c.categoria, count(*)
from m join lead_origin_classification c on c.lead_id = m.lead_id and c.valid_to is null
where m.mkt = '0' and m.segmento = 'Marketing'
group by 1,2 order by 3 desc;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. RECEITA: onde ela realmente está
--    Resultado 2026-09-15:
--      leads NA planilha   ->  58 opps,  4 ganhas, amount 6.728,05
--      leads FORA da planilha -> 180 opps, 54 ganhas, amount 171.609,03 + mrr 25.858,00
--    96% da receita ganha do período vem de leads que a planilha não contém. Por isso o
--    card mostra "100% atribuído a marketing": a receita comercial é invisível por
--    construção do recorte, não por ausência de vendas comerciais.
--
--    ATENÇÃO — LIMITAÇÃO DESTA JUNÇÃO: no Neon o vínculo lead->oportunidade só existe
--    via Lead.ConvertedAccountId, ou seja, no nível da CONTA. Toda oportunidade da conta
--    entra. O filtro `o.created_at_source >= l.created_at_source` reduz o arrasto de
--    histórico mas não elimina o leque (uma conta com 3 opps credita 3 ao mesmo lead).
--    A SOQL de ingestão não traz ConvertedOpportunityId nem OpportunityContactRole.
-- ═══════════════════════════════════════════════════════════════════════════
with L as (
  select l.id, l.created_at_source as dt, l.converted_account_id as cid, l.origem_bruta,
         exists (select 1 from sheet_sf s where s.email = lower(l.email)) as na_planilha
  from lead l
  where l.source_system = 'salesforce'
    and l.created_at_source >= :'PERIODO_INI' and l.created_at_source < :'PERIODO_FIM'
    and l.converted_account_id is not null),
O as (
  select distinct o.id, o.stage_name, o.amount, o.mrr, L.na_planilha
  from L join account a on a.source_system = 'salesforce' and a.source_id = L.cid
         join opportunity o on o.account_id = a.id and o.created_at_source >= L.dt)
select na_planilha,
       count(*) as opps,
       count(*) filter (where stage_name = 'Ganho')   as ganhas,
       round(sum(coalesce(amount,0)) filter (where stage_name = 'Ganho'), 2) as amount_ganho,
       round(sum(coalesce(mrr,0))    filter (where stage_name = 'Ganho'), 2) as mrr_ganho,
       count(*) filter (where stage_name = 'Perdido') as perdidas
from O group by 1 order by 1;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. MOEDA — O DEFEITO MAIS GRAVE DOS DOIS LADOS
--    A planilha usa "Valor da oportunidade (CONVERTIDO)" e "Valor Nota Fiscal
--    (CONVERTIDO)": o Salesforce converte para BRL na hora da leitura. O Neon ingere
--    `Amount` CRU, e a SOQL (n8n/crm-ingest-salesforce.json) NÃO traz CurrencyIsoCode
--    nem ConvertedAmount. Logo o Neon soma USD com BRL como se fosse a mesma unidade.
--
--    Prova nas 3 oportunidades ganhas que aparecem nos DOIS lados (taxa medida = 5,101):
--      DCP SOLUCOES  planilha 2.784,00  | Neon amount 2.784,00   -> BRL, bate
--      VIDA DIGITAL  planilha 12.373,24 | Neon amount 2.425,65   -> 2.425,65 x 5,101
--      FIXIT         planilha 11.091,61 | Neon amount 2.174,40   -> 2.174,40 x 5,101
--    Soma planilha 26.248,85 BRL   vs   soma Neon 7.384,05 "unidades" -> erro de 3,55x.
--    15 das 32 oportunidades com valor visíveis nos dois lados são USD (47%).
-- ═══════════════════════════════════════════════════════════════════════════
select a.nome as conta, o.stage_name, o.amount, o.mrr, o.record_type_name,
       o.created_at_source::date as criada, o.closed_at_source::date as fechada
from opportunity o join account a on a.id = o.account_id
where a.nome ilike '%FIXIT%' or a.nome ilike '%VIDA DIGITAL%' or a.nome ilike '%DCP SOLUCOES%'
order by a.nome, o.created_at_source desc;

-- Confirmação de que não existe campo de moeda ingerido (deve retornar 0 linhas).
select distinct k
from stg_salesforce, lateral jsonb_object_keys(payload) k
where object_type = 'Opportunity' and k ilike '%curren%';

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. ESTÁGIO SEM MAPEAMENTO DE FASE
--    "Projeto para o Futuro" existe na planilha e no Neon, mas não está em
--    opportunity_stage_fase -> fase NULL -> some de toda agregação por fase.
-- ═══════════════════════════════════════════════════════════════════════════
select o.stage_name, count(*) as opps
from opportunity o
  left join opportunity_stage_fase f on f.stage_name = o.stage_name
where f.stage_name is null
group by 1 order by 2 desc;

-- ═══════════════════════════════════════════════════════════════════════════
-- LIMPEZA
-- ═══════════════════════════════════════════════════════════════════════════
drop table if exists m;
drop table if exists sheet_sf;
