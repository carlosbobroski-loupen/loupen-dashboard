-- db/migrations/091_busca_por_pessoa_em_moeda_unica.sql
--
-- A BUSCA POR PESSOA AINDA ENTREGAVA UM NÚMERO SEM UNIDADE. Este é o item que
-- a migration 090 deixou declarado em aberto, e é só isso que esta migration faz.
--
-- A 090 consertou a VIEW. `view_pessoa_jornada_desfecho` ganhou
-- `amount_ganho_brl`, `contrato_valor_brl`, `moedas_ganho`,
-- `qtd_ganhas_sem_conversao` e `conversao_indisponivel_motivo`. Mas
-- `fn_search_pessoas` (084, reescrita pela 087) projeta as colunas
-- NOMINALMENTE: colunas novas na view não entram na função sozinhas. A API que
-- alimenta a aba Leads continuou recebendo `amount_ganho` e `mrr_ganho` CRUS.
--
-- POR QUE NO GRÃO DE PESSOA É PIOR QUE NO GRÃO DE OPORTUNIDADE. Uma
-- oportunidade tem UMA moeda: `amount` cru tem unidade, basta olhar
-- `currency_iso_code` ao lado. Uma PESSOA agrega N oportunidades, e a org é
-- multi-moeda (BRL/USD/MXN). `sum(o.amount)` por pessoa soma grandezas
-- diferentes e devolve um número que não é reais, não é dólares, e não é pesos.
-- Não é um número impreciso: é um número sem unidade.
--
-- MEDIDO HOJE (2026-09-16), 6.844 pessoas na view, 77 com oportunidade Ganha:
--
--   pessoa                       moedas     amount_ganho    amount_ganho_brl
--   ---------------------------  ---------  --------------  ----------------
--   email:2490                   BRL+USD        96.020,10        192.394,01
--   email:2439                   BRL+USD        29.197,26         87.420,22
--   email:1572                   BRL+USD         4.742,00         17.980,03
--   email:1316                   BRL+USD         6.785,95         16.940,64
--   email:607                    BRL+USD         3.974,00         14.214,20
--   solo:salesforce:00QV200000g4 BRL+USD         3.902,00         13.695,19
--   email:848                    BRL+USD         2.570,00          6.900,66
--   email:1664                   BRL+USD         2.269,00          5.516,99
--   solo:salesforce:00QV200000fC BRL+USD         2.508,00          4.673,33
--   solo:salesforce:00QV200000bz MXN+USD        12.121,00          3.554,69
--   email:1363                   BRL+USD         2.243,00          2.243,00
--
-- São 11 pessoas. O erro NÃO tem sinal fixo: a primeira aparecia com metade do
-- valor (96.020,10 onde são 192.394,01), e a de MXN+USD aparecia com 3,4x o
-- valor (12.121,00 onde são 3.554,69). Não dá para corrigir na tela com um
-- fator, porque não existe um fator.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- O QUE SAI, E POR QUÊ — O PRECEDENTE DA 088
--
-- `amount_ganho` CRU SAI DO RETORNO DA FUNÇÃO.
--
-- A 088 já decidiu este caso: quando a decisão está tomada, manter as duas
-- versões "por prudência" não é prudência, é indecisão fossilizada no contrato.
-- Lá saíram `contrato_valor_por_amount` e `contrato_valor_por_mrr`; aqui sai a
-- soma cruzada de moedas.
--
-- A regra que a 088 fixou e que continua valendo: O DADO CRU FICA ONDE TEM
-- UNIDADE. `opportunity.amount`, `view_receita.amount` e `view_lead_360.amount`
-- são grão de OPORTUNIDADE e trazem `moeda` ao lado — continuam intocados, e é
-- de lá que se recalcula qualquer coisa. `view_pessoa_jornada_desfecho.amount_ganho`
-- também FICA (a 090 o manteve de propósito, como campo de origem somado e
-- contraprova). O que sai é só a projeção dele no CONTRATO DA BUSCA, que é o
-- que a tela consome — porque no grão de pessoa aquela soma não é "dado
-- imperfeito", é um erro de aritmética, e um erro de aritmética não é
-- contraprova de nada.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- E `mrr_ganho`? SAI TAMBÉM. DECISÃO EXPLÍCITA, COM O MOTIVO.
--
-- A tentação era manter `mrr_ganho` cru com `moedas_ganho` ao lado, "porque
-- agora dá para ver que moedas ele mistura". Três medições derrubam isso:
--
-- 1. ELE JÁ MISTURA, HOJE. Das 39 pessoas com `mrr_ganho` preenchido, 3 somam
--    moedas diferentes — inclusive a de MXN+USD, cujo `mrr_ganho` = 12.121,00
--    é literalmente MXN + USD somados. É o MESMO defeito de `amount_ganho`, na
--    mesma linha, na mesma tela.
--
-- 2. NÃO EXISTE SUBSTITUTO CONVERTIDO. `grep` no catálogo: as únicas colunas
--    de MRR no banco são `opportunity.mrr`, `view_receita.mrr`,
--    `view_lead_360.mrr` e `view_pessoa_jornada_desfecho.mrr_ganho` — todas
--    CRUAS. NÃO HÁ `mrr_brl` em lugar nenhum. A 090 converteu `amount`, não
--    converteu MRR. Então, diferente de `amount_ganho`, não dá para pôr o
--    número certo ao lado do errado: só existe o errado.
--
--    Isso muda o que `moedas_ganho` significa nos dois casos. Ao lado de
--    `amount_ganho_brl`, `moedas_ganho` é uma NOTA DE RODAPÉ ("a soma crua
--    misturava BRL e USD; o número que você está vendo já está resolvido").
--    Ao lado de `mrr_ganho` cru, seria um AVISO SEM SAÍDA ("este número está
--    errado e não há outro"). A única ação correta do consumidor passaria a ser
--    "não exiba" — e uma coluna cuja única leitura correta é não lê-la não
--    pertence a um contrato de API.
--
-- 3. NEM AS PESSOAS DE MOEDA ÚNICA SALVAM A COLUNA. Distribuição das 77
--    pessoas com Ganha, e a soma de `mrr_ganho` em cada grupo:
--
--      BRL      54 pessoas   32 com mrr    soma 21.515,00 (reais)
--      BRL+USD  10 pessoas    2 com mrr    soma  2.792,00 (misturado)
--      MXN       8 pessoas    4 com mrr    soma 36.655,00 (pesos)
--      USD       4 pessoas    0 com mrr             —
--      MXN+USD   1 pessoa     1 com mrr    soma 12.121,00 (misturado)
--
--    Mesmo que cada LINHA tivesse unidade, a COLUNA não tem: qualquer total de
--    rodapé sobre a lista soma 21.515 reais com 36.655 pesos. O defeito
--    reaparece um nível acima, na agregação que a tela faz — e aí sem nenhum
--    `moedas_ganho` por perto para avisar.
--
-- POR QUE NÃO CONVERTER MRR AQUI MESMO. Seria reimplementar a divisão por
-- `currency_rate` dentro da função de busca, com a regra já implementada em
-- `view_receita`. Duas implementações da mesma regra divergem — foi assim que o
-- ramo do webhook divergiu do ramo do pull por 33 migrations (registrado na
-- 090). MRR convertido é trabalho de VIEW: entra `mrr_brl` em `view_receita`,
-- daí `mrr_ganho_brl` em `view_pessoa_jornada_desfecho`, e só então
-- `mrr_ganho_brl` entra nesta função — pela porta da frente, com unidade.
-- Mexer em view está fora do escopo desta migration, de propósito.
--
-- O QUE SE PERDE: o grão de pessoa fica SEM NENHUMA coluna de MRR até essa
-- view existir. É perda real e está sendo declarada aqui, não escondida. A
-- alternativa era manter um número errado em produção para não parecer que se
-- perdeu capacidade — que é exatamente a troca que este projeto se recusou a
-- fazer na 073, na 080 e na 088.
--
-- ⚠️ CONTRATO DA API MUDA. `assets/js/data-api.js` tem UMA linha que cita
-- `amount_ganho` e `mrr_ganho` (medido com `grep -c`; não abri o arquivo, outro
-- agente está trabalhando em `assets/` agora). Depois desta migration as duas
-- chaves somem do payload de `/api/pessoas` e quem ler `row.amount_ganho`
-- receberá `undefined`. A substituição é `amount_ganho_brl`. Para MRR não há
-- substituição — o campo tem de sair da tela, não ser trocado por outro.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- TRÊS ARMADILHAS DE EXECUÇÃO, TODAS JÁ DOCUMENTADAS COMO FALHA REAL
--
-- 1. DROP FUNCTION É OBRIGATÓRIO. Mudar o `RETURNS TABLE` muda o tipo de
--    retorno, e `CREATE OR REPLACE FUNCTION` recusa ("cannot change return type
--    of existing function"). A 084 já documenta isso. Diferente da 084, agora
--    HÁ consumidor em produção — mas o workflow chama por nome, não por
--    assinatura, e a janela entre DROP e CREATE é a mesma transação.
--
-- 2. O `GRANT` MORRE COM O DROP. Reemitido no fim.
--
--    ⚠️ MAS A PREMISSA CORRENTE SOBRE ESTE GRANT ESTÁ ERRADA, E MEDIR DERRUBOU.
--    A regra que se repete neste épico — "esquecer o grant é o modo de falha da
--    049, o n8n leva permission denied" — NÃO se aplica a FUNÇÃO. Em PostgreSQL,
--    `CREATE FUNCTION` já concede EXECUTE a PUBLIC por padrão. Provado aqui em
--    2026-09-16 com uma função-sonda criada SEM nenhum grant:
--
--      create function fn_probe_grant_091() returns int language sql
--        stable as $x$ select 42 $x$;
--      -- pg_proc.proacl = NULL  (default: PUBLIC tem EXECUTE)
--      -- conectando pelo pooler COMO crm_ingest: select fn_probe_grant_091()
--      --   -> 42.  NÃO deu permission denied.
--
--    Ou seja: executar a função como `crm_ingest` NÃO é teste do GRANT. Esse
--    teste passa com o grant e passa sem ele — é um verde falso.
--
--    A 049 era sobre SEQUÊNCIA, e lá PUBLIC não tem nada por padrão: o teste de
--    executar como crm_ingest de fato falhava. A lição não atravessa para
--    função. A 090 concedeu SELECT em VIEW, onde PUBLIC também não tem default,
--    e lá o teste valia.
--
--    O QUE DE FATO DISTINGUE grant presente de ausente, para função, é o
--    catálogo — e a asserção sabe falhar (conferida contra a sonda acima):
--      SELECT proacl::text[] @> ARRAY['crm_ingest=X/neondb_owner']
--        FROM pg_proc WHERE proname = 'fn_search_pessoas';   -- t
--      (mesma asserção na sonda sem grant: f)
--
--    O GRANT continua sendo reemitido, e por dois motivos que continuam de pé:
--    torna o privilégio EXPLÍCITO no contrato em vez de herdado de um default
--    do PostgreSQL, e sobrevive ao dia em que alguém fizer
--    `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC` — que, aliás, é o
--    endurecimento que este banco ainda NÃO tem: hoje QUALQUER role do banco
--    executa `fn_search_pessoas`. Fica registrado como achado; fechar isso é
--    trabalho de outra migration, deliberado, porque mexe em superfície de
--    permissão de todas as funções e não só desta.
--
-- 3. O `ALTER FUNCTION ... SET plan_cache_mode` MORRE COM O DROP TAMBÉM, e este
--    é o mais fácil de esquecer porque não dá erro: dá LENTIDÃO. A 089 mediu
--    `force_custom_plan` = 259 ms contra `force_generic_plan` = 207.096 ms
--    (3m27s) NA MESMA CHAMADA — 800x, causado pelos filtros opcionais
--    `($n IS NULL OR coluna = $n)`. Recriar a função sem reemitir o ALTER
--    devolve a aba Leads ao incidente de ontem. Reemitido no fim, e conferido
--    em `pg_proc.proconfig` depois de aplicar.
--
-- Nada além disso muda: mesmos parâmetros, mesmos 16 filtros, mesmo predicado
-- nos três lugares (CTE `filtrado`, bloco de ocultos, RETURN QUERY), mesma
-- ordenação, mesma paginação. O corpo abaixo é o da 087 com a lista de
-- projeção trocada.
-- ─────────────────────────────────────────────────────────────────────────────

BEGIN;

DROP FUNCTION IF EXISTS fn_search_pessoas(jsonb, integer, integer);

CREATE FUNCTION fn_search_pessoas(
  p_filtros jsonb   DEFAULT '{}'::jsonb,
  p_limit   integer DEFAULT 50,
  p_offset  integer DEFAULT 0
)
RETURNS TABLE(
  pessoa_chave           text,
  nome                   text,
  empresa                text,
  fontes                 text[],
  rd_lead_id             bigint,
  sf_lead_id             bigint,
  source_id_ficha        text,
  segmento               text,
  categoria              text,
  detalhe                text,
  de_lista_importada     boolean,
  qtd_conversoes         bigint,
  origens_conversao      text[],
  primeira_conversao_em  timestamptz,
  ultima_conversao_em    timestamptz,
  plataforma             text,
  utm_campaign           text,
  id_anuncio             text,
  criativo               text,
  cargo                  text,
  tamanho_empresa        text,
  existe_no_salesforce   boolean,
  status_no_salesforce   text,
  qtd_oportunidades      bigint,
  teve_reuniao           boolean,
  chegou_a_negociar      boolean,
  qtd_ganhas             bigint,
  qtd_perdidas           bigint,
  fase_mais_avancada     text,
  fase_ordem             integer,
  estagio_mais_avancado  text,
  -- ── migration 091: receita em UMA unidade, e o rastro do que ficou fora ──
  -- Saíram daqui `mrr_ganho` e `amount_ganho` CRUS (ver cabeçalho). Continuam
  -- existindo na view e nas views de grão de oportunidade, onde têm unidade.
  amount_ganho_brl              numeric,
  contrato_valor_brl            numeric,
  -- sum() ignora NULL: uma Ganha que não converteu sumiria da soma sem deixar
  -- rastro, que é a exclusão silenciosa proibida pelo contrato §1.6. Estas três
  -- colunas são o rastro — quantas ficaram fora, por quê, e que moedas a soma
  -- crua misturava. Vêm prontas da view (090), não recalculadas aqui.
  qtd_ganhas_sem_conversao      bigint,
  conversao_indisponivel_motivo text,
  moedas_ganho                  text[],
  trimestre              text,
  cargo_grupo            text,
  atendido_por           text,
  estagio_funil          text,
  tags                   text[],
  total_filtrado         bigint,
  total_ocultos_lista    bigint
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_busca      text    := nullif(trim(p_filtros->>'busca'), '');
  v_segmento   text    := nullif(p_filtros->>'segmento', '');
  v_categoria  text    := nullif(p_filtros->>'categoria', '');
  v_fase       text    := nullif(p_filtros->>'fase', '');
  v_plataforma text    := nullif(p_filtros->>'plataforma', '');
  v_incluir_lista boolean := coalesce((p_filtros->>'incluir_lista')::boolean, false);
  v_so_com_opp boolean := coalesce((p_filtros->>'so_com_oportunidade')::boolean, false);
  -- Dimensoes que a barra de filtros da aba Leads ja oferecia. Trocar a lista
  -- pela versao por pessoa SEM elas seria perder capacidade em silencio.
  v_trimestre  text    := nullif(p_filtros->>'trimestre', '');
  v_cargo      text    := nullif(p_filtros->>'cargo_grupo', '');
  v_atendido   text    := nullif(p_filtros->>'atendido_por', '');
  v_estagio    text    := nullif(p_filtros->>'estagio_funil', '');
  v_tag        text    := nullif(p_filtros->>'tag', '');
  v_tamanho    text    := nullif(p_filtros->>'tamanho_empresa', '');
  v_origem     text    := nullif(p_filtros->>'origem_conversao', '');
  -- Filtro de PIVO (migration 087). Distinto de v_origem e de v_plataforma:
  -- atravessa os dois eixos porque o nome de campanha aparece nos dois.
  v_campanha   text    := nullif(p_filtros->>'campanha', '');
  v_total      bigint;
  v_ocultos    bigint;
BEGIN
  WITH filtrado AS (
    SELECT v.*
    FROM view_pessoa_jornada_desfecho v
    WHERE (v_busca IS NULL
           OR v.nome    ILIKE '%' || v_busca || '%'
           OR v.empresa ILIKE '%' || v_busca || '%'
           OR EXISTS (SELECT 1 FROM lead l
                      WHERE l.id IN (v.rd_lead_id, v.sf_lead_id)
                        AND l.email ILIKE '%' || v_busca || '%'))
      AND (v_segmento   IS NULL OR v.segmento   = v_segmento)
      AND (v_categoria  IS NULL OR v.categoria  = v_categoria)
      AND (v_plataforma IS NULL OR v.plataforma = v_plataforma)
      AND (v_fase       IS NULL OR v.fase_mais_avancada = v_fase)
      AND (NOT v_so_com_opp OR v.qtd_oportunidades > 0)
      AND (v_trimestre  IS NULL OR v.trimestre       = v_trimestre)
      AND (v_cargo      IS NULL OR v.cargo_grupo     = v_cargo)
      AND (v_atendido   IS NULL OR v.atendido_por    = v_atendido)
      AND (v_estagio    IS NULL OR v.estagio_funil   = v_estagio)
      AND (v_tamanho    IS NULL OR v.tamanho_empresa = v_tamanho)
      AND (v_tag        IS NULL OR v.tags @> ARRAY[v_tag])
      AND (v_origem     IS NULL OR v.origens_conversao @> ARRAY[v_origem])
      AND (v_campanha   IS NULL
           OR v.origens_conversao @> ARRAY[v_campanha]
           OR v.utm_campaign = v_campanha)
      AND (v_incluir_lista OR NOT v.de_lista_importada)
  )
  SELECT count(*) INTO v_total FROM filtrado;

  -- Quantos a regra de lista importada tirou de cena, sob o MESMO filtro.
  IF v_incluir_lista THEN
    v_ocultos := 0;
  ELSE
    SELECT count(*) INTO v_ocultos
    FROM view_pessoa_jornada_desfecho v
    WHERE v.de_lista_importada
      AND (v_busca IS NULL
           OR v.nome ILIKE '%' || v_busca || '%'
           OR v.empresa ILIKE '%' || v_busca || '%')
      AND (v_segmento  IS NULL OR v.segmento  = v_segmento)
      AND (v_categoria IS NULL OR v.categoria = v_categoria)
      AND (v_campanha  IS NULL
           OR v.origens_conversao @> ARRAY[v_campanha]
           OR v.utm_campaign = v_campanha);
  END IF;

  RETURN QUERY
  SELECT
    v.pessoa_chave, v.nome, v.empresa, v.fontes, v.rd_lead_id, v.sf_lead_id, v.source_id_ficha,
    v.segmento, v.categoria, v.detalhe, v.de_lista_importada,
    v.qtd_conversoes, v.origens_conversao, v.primeira_conversao_em, v.ultima_conversao_em,
    v.plataforma, v.utm_campaign, v.id_anuncio, v.criativo,
    v.cargo, v.tamanho_empresa,
    v.existe_no_salesforce, v.status_no_salesforce, v.qtd_oportunidades,
    v.teve_reuniao, v.chegou_a_negociar, v.qtd_ganhas, v.qtd_perdidas,
    v.fase_mais_avancada, v.fase_ordem, v.estagio_mais_avancado,
    -- migration 091: o valor comparável, e o rastro do que a soma deixou fora.
    -- `v.amount_ganho` e `v.mrr_ganho` NÃO são projetados de propósito.
    v.amount_ganho_brl, v.contrato_valor_brl,
    v.qtd_ganhas_sem_conversao, v.conversao_indisponivel_motivo, v.moedas_ganho,
    v.trimestre, v.cargo_grupo, v.atendido_por, v.estagio_funil, v.tags,
    v_total, v_ocultos
  FROM view_pessoa_jornada_desfecho v
  WHERE (v_busca IS NULL
         OR v.nome    ILIKE '%' || v_busca || '%'
         OR v.empresa ILIKE '%' || v_busca || '%'
         OR EXISTS (SELECT 1 FROM lead l
                    WHERE l.id IN (v.rd_lead_id, v.sf_lead_id)
                      AND l.email ILIKE '%' || v_busca || '%'))
    AND (v_segmento   IS NULL OR v.segmento   = v_segmento)
    AND (v_categoria  IS NULL OR v.categoria  = v_categoria)
    AND (v_plataforma IS NULL OR v.plataforma = v_plataforma)
    AND (v_fase       IS NULL OR v.fase_mais_avancada = v_fase)
    AND (NOT v_so_com_opp OR v.qtd_oportunidades > 0)
    AND (v_trimestre  IS NULL OR v.trimestre       = v_trimestre)
    AND (v_cargo      IS NULL OR v.cargo_grupo     = v_cargo)
    AND (v_atendido   IS NULL OR v.atendido_por    = v_atendido)
    AND (v_estagio    IS NULL OR v.estagio_funil   = v_estagio)
    AND (v_tamanho    IS NULL OR v.tamanho_empresa = v_tamanho)
    AND (v_tag        IS NULL OR v.tags @> ARRAY[v_tag])
    AND (v_origem     IS NULL OR v.origens_conversao @> ARRAY[v_origem])
    AND (v_campanha   IS NULL
         OR v.origens_conversao @> ARRAY[v_campanha]
         OR v.utm_campaign = v_campanha)
    AND (v_incluir_lista OR NOT v.de_lista_importada)
  -- Ordem: quem foi mais longe no funil primeiro, depois quem tem jornada mais
  -- rica, depois o mais recente. O lead que virou negócio é o que se procura.
  ORDER BY v.fase_ordem DESC NULLS LAST,
           v.qtd_oportunidades DESC,
           v.qtd_conversoes DESC,
           v.ultima_conversao_em DESC NULLS LAST,
           v.primeiro_registro_em DESC NULLS LAST
  LIMIT greatest(p_limit, 1) OFFSET greatest(p_offset, 0);
END $$;

COMMENT ON FUNCTION fn_search_pessoas(jsonb, integer, integer) IS
  'Busca por PESSOA (view_pessoa_jornada_desfecho) com busca textual em nome/empresa/e-mail, filtros e paginacao real. Devolve `total_filtrado` na MESMA chamada, sobre o mesmo predicado -- total calculado a parte foi como o dashboard antigo produzia numero que nao batia com a lista. `total_ocultos_lista` diz quantos a regra de lista importada tirou de cena, porque exclusao silenciosa e proibida (contrato §1.6). v2 (migration 087): filtro `campanha` de primeira classe, que casa contra origens_conversao OU utm_campaign -- e o que sustenta o pivo campanha->leads (AC-4.1). NAO e apelido de `origem_conversao` nem de `plataforma`, que seguem independentes (mesmo erro que a migration 054 corrigiu). v3 (migration 091): RECEITA EM MOEDA UNICA. Projeta `amount_ganho_brl` e `contrato_valor_brl` (convertidos em view_receita via currency_rate, migration 090) mais o rastro do que ficou fora da soma: `qtd_ganhas_sem_conversao`, `conversao_indisponivel_motivo` e `moedas_ganho`. SAIRAM `amount_ganho` e `mrr_ganho` CRUS -- a org e multi-moeda (BRL/USD/MXN) e no grao de PESSOA somar campo cru mistura moedas: 11 pessoas medidas, uma delas exibindo 96.020,10 onde o valor e 192.394,01 e outra 12.121,00 onde e 3.554,69. Os campos crus seguem existindo na view e nas views de grao de OPORTUNIDADE, onde tem unidade ao lado. MRR saiu SEM substituto: nao existe mrr_brl no banco, e converte-lo aqui duplicaria a regra de view_receita -- o grao de pessoa fica sem MRR ate a view expor mrr_brl. ATENCAO: nao ha taxa datada na origem; a conversao usa a taxa ATUAL e a receita historica se move com o cambio. Ver migrations 084, 087, 088, 090 e 091.';

-- ⚠️ O DROP ACIMA LEVOU O GRANT E O plan_cache_mode JUNTO. Os dois blocos
-- abaixo NÃO são redundância: sem eles a função fica sem permissão para o n8n
-- e volta ao plano genérico (3m27s medidos na 089). Ver armadilhas 2 e 3 no
-- cabeçalho.

ALTER FUNCTION fn_search_pessoas(jsonb, integer, integer)
  SET plan_cache_mode = 'force_custom_plan';

GRANT EXECUTE ON FUNCTION fn_search_pessoas(jsonb, integer, integer) TO crm_ingest;

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICAÇÃO (queries completas em db/queries/verificacao/moeda-por-pessoa.sql)
--
--   -- assinatura nova
--   SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = 'fn_search_pessoas';
--   -- o plan_cache_mode sobreviveu ao DROP
--   SELECT proconfig FROM pg_proc WHERE proname = 'fn_search_pessoas';
--   -- o grant EXPLÍCITO existe (o único teste que sabe falhar — ver armadilha 2)
--   SELECT proacl::text[] @> ARRAY['crm_ingest=X/neondb_owner']
--     FROM pg_proc WHERE proname = 'fn_search_pessoas';
--   -- e, separadamente, a função é ALCANÇÁVEL ponta a ponta: conectar pelo
--   -- pooler COMO crm_ingest e chamá-la. Isso prova alcance (role, pooler,
--   -- search_path, assinatura), NÃO prova o grant — ver armadilha 2.
--
-- ROLLBACK
--   Não há "reverter o ALTER": esta migration muda o tipo de retorno, então
--   voltar é reaplicar o corpo da 087 INTEIRO (DROP FUNCTION + o CREATE da 087
--   + ALTER plan_cache_mode + GRANT). Reverter devolve o número sem unidade às
--   11 pessoas acima. Só faça isso com uma medição nova na mão.
-- ─────────────────────────────────────────────────────────────────────────────
