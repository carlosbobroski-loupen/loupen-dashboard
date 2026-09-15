-- db/migrations/082_view_pessoa.sql
--
-- A camada de PESSOA. Uma linha por ser humano, não por registro de origem.
--
-- O PROBLEMA QUE ELA RESOLVE: `lead` tem UNIQUE (source_system, source_id), e
-- isso está CERTO -- é tabela de registros de origem, e é essa propriedade que
-- permitiu reingerir 7.076 leads em 2,2 s quando o campo inventado apareceu.
-- Mas a consequência é que a mesma pessoa vira DUAS linhas quando existe no RD
-- e no Salesforce (430 casos medidos). A tela mostra as duas: uma completa e
-- uma vazia. Foi exatamente isso que o usuário viu no caso AMP Consultoria.
--
-- POR QUE NÃO USA `person_id` DIRETO, que existe desde a migration 004:
-- `person` HOJE NÃO É UMA PESSOA. `fn_identity_tier1_resolve` tem três laços --
-- converted_account_id, email, rdstation_uuid -- e cada um procura person
-- existente APENAS dentro do próprio identifier_type. Não há união de clusters.
-- Um lead do Salesforce convertido ganha uma `person` pela conta E OUTRA pelo
-- e-mail. Por isso há 8.704 arestas para ~7.500 registros: o número de `person`
-- está na ordem das arestas, não das pessoas.
--
-- Corrigir `fn_identity_tier1_resolve` com union-find é o caminho certo, e é
-- trabalho separado -- mudar o significado de `person_id` com telas publicadas
-- lendo ele é trocar a chave debaixo de quem está em cima.
--
-- 🔴 A CHAVE QUE EU IA USAR NÃO SERVE, E MEDIR ANTES EVITOU PIORAR A TELA.
--
-- Eu ia usar `Identificador_RD__c` como chave canônica -- está registrado na
-- memória do projeto desde 2026-09-14 como "a chave canônica RD<->SF, melhor
-- que casar por e-mail", a partir de uma medição de COBERTURA (423 preenchidos)
-- que nunca olhou o CONTEÚDO.
--
-- Medido em 2026-09-15, antes de aplicar: os 308 valores da janela de 12 meses
-- são **todos iguais a `1160539`**. Sete dígitos, o mesmo número para todo
-- lead. Não bate com nenhum uuid do RD na base (0 de 308), nem com o `id`
-- numérico que o RD manda no webhook (0 de 308). Não é identificador de LEAD --
-- é identificador da conta ou da integração.
--
-- E o estrago que teria causado é pior que não usar: o Alexandre Mendes Pereira
-- e o gêmeo dele no Salesforce JÁ ESTAVAM ligados pelo cluster de e-mail
-- (person 6975). A "chave canônica" daria `rd:<uuid>` para um e `rd:1160539`
-- para o outro, e SEPARARIA um par que já funcionava. Cobertura de campo não é
-- o mesmo que utilidade de campo.
--
-- A CHAVE DESTA VIEW, então:
--   1. cluster de e-mail (`identity_edge` tipo 'email') -- Tier 1. É o que
--      temos, e funde 615 pares de registros em pessoas.
--   2. o próprio registro -- lead sem e-mail é uma pessoa de um registro só.
--      Declarado, não escondido.
--
-- `identificador_rd` continua ingerido e exposto como ATRIBUTO, para o dia em
-- que alguém do RD explicar o que ele significa. Como chave, não entra.
--
-- A regra que resolveu cada pessoa fica GRAVADA em `chave_origem`. Sem isso,
-- ninguém consegue auditar por que dois registros viraram um -- e fundir pessoa
-- errada é pior que deixar duplicado.

CREATE OR REPLACE VIEW view_pessoa AS
WITH base AS (
  SELECT
    l.id                AS lead_id,
    l.source_system,
    l.source_id,
    l.nome,
    l.empresa,
    l.email,
    l.created_at_source,
    -- O uuid do RD fica como ATRIBUTO da pessoa, nunca como chave -- ver
    -- cabeçalho. Só o lead do RD tem um de verdade.
    CASE WHEN l.source_system = 'rd_station' THEN l.source_id END AS rd_uuid,
    ie.person_id AS email_person
  FROM lead l
  LEFT JOIN identity_edge ie
    ON ie.source_system = l.source_system
   AND ie.source_record_id = l.source_id
   AND ie.identifier_type = 'email'
  WHERE NOT l.is_teste
),
-- Propaga o uuid do RD pelo cluster de e-mail, para a pessoa carregar o uuid
-- mesmo quando a linha do Salesforce é que foi lida. ATRIBUTO, não chave.
cluster AS (
  SELECT email_person, min(rd_uuid) AS rd_uuid_do_cluster
  FROM base
  WHERE email_person IS NOT NULL AND rd_uuid IS NOT NULL
  GROUP BY email_person
),
chaveado AS (
  SELECT
    b.*,
    coalesce(b.rd_uuid, c.rd_uuid_do_cluster) AS rd_uuid_efetivo,
    CASE
      WHEN b.email_person IS NOT NULL THEN 'email:' || b.email_person
      ELSE 'solo:' || b.source_system || ':' || b.source_id
    END AS pessoa_chave,
    CASE
      WHEN b.email_person IS NOT NULL THEN 'email'
      ELSE 'sem chave — registro isolado (sem e-mail na origem)'
    END AS chave_origem
  FROM base b
  LEFT JOIN cluster c ON c.email_person = b.email_person
)
SELECT
  k.pessoa_chave,
  min(k.chave_origem)                                                    AS chave_origem,
  max(k.rd_uuid_efetivo)                                                 AS rd_uuid,
  -- Nome e empresa: o Salesforce vence, porque é lá que o comercial corrige.
  -- Regra declarada, não coalesce arbitrário.
  coalesce(
    max(k.nome)    FILTER (WHERE k.source_system = 'salesforce'),
    max(k.nome)    FILTER (WHERE k.source_system = 'rd_station'),
    max(k.nome))                                                         AS nome,
  coalesce(
    max(k.empresa) FILTER (WHERE k.source_system = 'salesforce'),
    max(k.empresa) FILTER (WHERE k.source_system = 'rd_station'),
    max(k.empresa))                                                      AS empresa,
  min(k.email)                                                           AS email,
  min(k.created_at_source)                                               AS primeiro_registro_em,
  max(k.lead_id) FILTER (WHERE k.source_system = 'rd_station')           AS rd_lead_id,
  max(k.lead_id) FILTER (WHERE k.source_system = 'salesforce')           AS sf_lead_id,
  count(*) FILTER (WHERE k.source_system = 'rd_station')                 AS n_registros_rd,
  count(*) FILTER (WHERE k.source_system = 'salesforce')                 AS n_registros_sf,
  count(*)                                                               AS n_registros,
  array_agg(DISTINCT k.source_system ORDER BY k.source_system)           AS fontes
FROM chaveado k
GROUP BY k.pessoa_chave;

COMMENT ON VIEW view_pessoa IS
  'GRÃO: UMA LINHA POR PESSOA. Chave = cluster de e-mail (identity_edge tipo email, Tier 1); lead sem e-mail vira pessoa de um registro só. `Identificador_RD__c` NÃO é chave: medido em 2026-09-15, os 308 valores são todos iguais (1160539) -- identifica a conta, não o lead. NÃO usa `person_id` porque ele não é unificado entre identifier_types (ver fn_identity_tier1_resolve). A regra que resolveu cada pessoa fica em `chave_origem`. Migration 082.';

GRANT SELECT ON view_pessoa TO crm_ingest;
