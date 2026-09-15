-- db/migrations/075_crosswalk_leadsource_pos_carga.sql
--
-- ⚠️ NAO APLICADA. Escrita em 2026-09-15, aguardando aprovacao do usuario.
--    `leadsource_crosswalk.fonte_decisao` diz "SOQL real + revisao manual" --
--    classificar origem de lead e decisao de negocio (CON-8), nao de agente.
--
-- POR QUE ESTA MIGRATION EXISTE
--
-- O crosswalk foi decidido em 2026-09-07 a partir de uma AMOSTRA SOQL, quando a
-- base tinha 500 leads do RD Station e nenhum do Salesforce. A carga de 12 meses
-- de 2026-09-14 trouxe 7.076 leads do Salesforce, e com eles valores de
-- LeadSource que o crosswalk nunca viu.
--
-- MEDIDO: a base tem 94 valores distintos de LeadSource. O crosswalk conhece 44.
-- Os outros 50 (53%) caem direto em 'NaoAtribuido' -- nao porque a origem seja
-- desconhecida, mas porque NINGUEM ENSINOU a regra.
--
-- POR QUE ISSO IMPORTA PARA O GATE 3.16: a matriz de transicao de 3.15 mostrou
-- 633 leads saindo de Marketing para NaoAtribuido. Eu li isso, na primeira
-- passada, como "o motor parou de inventar". Errado: parte desses 633 sao
-- CAMPANHA DE VERDADE -- `LOGMEIN_RESCUE-LICENCA-ECO_07-26`,
-- `Rescue-licenca-eco-meta`, `[CP07][LOGMEIN][FUNDO][LEAD]`. Quem estava certo
-- ali era a regra legada, por acidente: o match por substring pegava o codigo da
-- campanha que o crosswalk nao tinha.
--
-- Aprovar o gate 3.16 ANTES desta migration exibiria como "nao atribuido" um
-- conjunto de leads de midia paga -- exatamente o erro que o epico existe para
-- corrigir, so que na direcao oposta.
--
-- METODO: cada valor abaixo foi classificado pelo que o PROPRIO VALOR diz, com
-- a contagem de leads e a janela de datas na frente. Nada foi inferido de
-- comportamento do lead. Onde o valor nao decide sozinho, NAO classifiquei --
-- ver a secao de pendencias no fim.

-- ─────────────────────────────────────────────────────────────────────────────
-- MARKETING — codigo de campanha explicito (midia paga)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id, decidido_em, fonte_decisao) VALUES
  -- Canal NAO nomeado pelo valor. O usuario confirmou em 2026-09-15 que todos
  -- pertencem a campanha Rescue Licenca Eco, mas "mesma campanha" nao e "mesmo
  -- canal" -- uma campanha roda em mais de uma veiculacao. Fica
  -- 'Campanha (canal a resolver)', que e a categoria que existe exatamente para
  -- isto, em vez de herdar o canal do vizinho.
  ('LOGMEIN_RESCUE-LICENCA-ECO_07-26',           'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco', 'S3', '2026-09-15', 'V4 — campanha confirmada pelo usuario 2026-09-15; canal nao nomeado pelo valor'),
  ('LOGMEIN_RESCUE-LICENCA-ECO_08-26',           'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco', 'S3', '2026-09-15', 'V4 — mesma familia de codigo, mes diferente'),
  ('LOGMEIN_RESCUE-LICENCA-ECO_09_26_',          'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco', 'S3', '2026-09-15', 'V4 — mesma familia de codigo, mes diferente'),
  ('Campanha Rescue Eco',                        'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco', 'S3', '2026-09-15', 'V4 — o valor diz "Campanha"; canal nao nomeado'),
  ('Rescue - Licença Eco 2026',                  'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco', 'S3', '2026-09-15', 'V4 — canal nao nomeado pelo valor'),
  ('Rescue-licenca-eco',                         'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco', 'S3', '2026-09-15', 'V4 — canal nao nomeado pelo valor'),
  ('Rescue-licenca-eco-fb',                      'Marketing', 'Paid Social', 'Meta Ads', 'S3', '2026-09-15', 'V4 — campanha Rescue Licença Eco (usuario, 2026-09-15); canal nomeado pelo sufixo -fb'),
  ('Rescue-licenca-eco-fb (v2)',                 'Marketing', 'Paid Social', 'Meta Ads', 'S3', '2026-09-15', 'V4 — campanha Rescue Licença Eco; canal nomeado pelo sufixo -fb'),
  ('Rescue-licenca-eco-fb -planilha',            'Marketing', 'Paid Social', 'Meta Ads', 'S3', '2026-09-15', 'V4 — campanha Rescue Licença Eco (usuario, 2026-09-15); canal nomeado pelo sufixo -fb'),
  ('Rescue-licenca-eco-fb+insta',                'Marketing', 'Paid Social', 'Meta Ads', 'S3', '2026-09-15', 'V4 — campanha Rescue Licença Eco; fb+insta nomeia Meta'),
  ('Rescue-licenca-eco-fb+insta (v1)',           'Marketing', 'Paid Social', 'Meta Ads', 'S3', '2026-09-15', 'V4 — campanha Rescue Licença Eco; fb+insta nomeia Meta'),
  ('Rescue-licenca-eco-meta',                    'Marketing', 'Paid Social', 'Meta Ads', 'S3', '2026-09-15', 'V4 — campanha Rescue Licença Eco (usuario, 2026-09-15); o valor diz "meta"'),
  ('GOTO_INSTITUCIONAL_07-26',                   'Marketing', 'Campanha (canal a resolver)', 'GoTo Institucional', 'S3', '2026-09-15', 'V4 — codigo de campanha no proprio valor'),
  ('GOTO_INSTITUCIONAL_09/26',                   'Marketing', 'Campanha (canal a resolver)', 'GoTo Institucional', 'S3', '2026-09-15', 'V4 — codigo de campanha no proprio valor'),
  ('GOTO_INSTITUCIONAL_07-26-1018790131',        'Marketing', 'Campanha (canal a resolver)', 'GoTo Institucional', 'S3', '2026-09-15', 'V4 — codigo de campanha no proprio valor'),
  ('GOTO_GERAL_LEADS_2601',                      'Marketing', 'Campanha (canal a resolver)', 'GoTo Geral',        'S3', '2026-09-15', 'V4 — codigo de campanha no proprio valor'),
  ('Campanha TV Vitalicio',                      'Marketing', 'Campanha (canal a resolver)', 'TV Vitalicio',      'S3', '2026-09-15', 'V4 — o valor diz "Campanha"'),
  ('[CP07][LOGMEIN][FUNDO][LEAD]',               'Marketing', 'Campanha (canal a resolver)', 'Rescue Licença Eco','S3', '2026-09-15', 'V4 — campanha confirmada pelo usuario 2026-09-15 (era "CP07 LogMeIn fundo" por leitura do codigo)'),
  ('[CP06][GOTO][FUNDO][SAUDE]',                 'Marketing', 'Campanha (canal a resolver)', 'CP06 GoTo Saude',   'S3', '2026-09-15', 'V4 — nomenclatura de campanha em colchetes'),
  ('[FORM][LINKEDIN][GOTO][WEBINAR]-1018890105', 'Marketing', 'Paid Social', 'LinkedIn Ads',                'S3', '2026-09-15', 'V4 — o valor nomeia LINKEDIN e WEBINAR')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- MARKETING — formulario / inbound web
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id, decidido_em, fonte_decisao) VALUES
  ('GoTo_INSCRIÇÃO',            'Marketing', 'Inbound Web', 'Formulario de inscricao', 'S3', '2026-09-15', 'V4 — formulario de inscricao'),
  ('GOTO_SAUDE_FORM',           'Marketing', 'Inbound Web', 'Formulario GoTo Saude',   'S3', '2026-09-15', 'V4 — sufixo _FORM'),
  ('Novo formulário',           'Marketing', 'Inbound Web', 'Formulário de contato',   'S3', '2026-09-15', 'V4 — formulario de site'),
  ('Contact-Form',              'Marketing', 'Inbound Web', 'Formulário de contato',   'S3', '2026-09-15', 'V4 — formulario de site'),
  ('Contatos_RD_Station',       'Marketing', 'Inbound Web', 'RD Station',              'S3', '2026-09-15', 'V4 — origem RD Station'),
  ('LogMeIn Brasil(Central)',   'Marketing', 'Inbound Web', 'LogMeIn Brasil',          'S3', '2026-09-15', 'V4 — mesma familia de "LogMeIn Brasil (COMPRAR-*)" ja no crosswalk'),
  ('LogMeIn Brasil(Rescue)',    'Marketing', 'Inbound Web', 'LogMeIn Brasil',          'S3', '2026-09-15', 'V4 — mesma familia de "LogMeIn Brasil (COMPRAR-*)" ja no crosswalk'),
  ('LogMeIn Brasil(Pro)',       'Marketing', 'Inbound Web', 'LogMeIn Brasil',          'S3', '2026-09-15', 'V4 — mesma familia de "LogMeIn Brasil (COMPRAR-*)" ja no crosswalk'),
  ('LogMeIn_2.0 (v1)',          'Marketing', 'Inbound Web', 'LogMeIn Brasil',          'S3', '2026-09-15', 'V4 — mesma familia')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- NAO E MARKETING — base importada, cadastro interno, suporte
-- Estes NAO viram "Comercial" por serem o resto. Cada um tem categoria propria,
-- porque "Comercial como complemento de Marketing" e o defeito EC-1.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id, decidido_em, fonte_decisao) VALUES
  ('Base Loupen 2019',        'NaoAtribuido', 'Base importada',     'Importacao de base de 2019', 'S3', '2026-09-15', 'V4 — base legada importada, nao prospeccao nem campanha'),
  ('Cliente da base',         'NaoAtribuido', 'Base importada',     'Cliente ja existente',       'S3', '2026-09-15', 'V4 — cliente existente, nao aquisicao'),
  ('Espelhamento SF LMI',     'NaoAtribuido', 'Base importada',     'Migracao de CRM',            'S3', '2026-09-15', 'V4 — espelhamento tecnico entre orgs'),
  ('Desconhecido',            'NaoAtribuido', 'Sem origem',         NULL,                         'S3', '2026-09-15', 'V4 — o proprio CRM declara desconhecido'),
  ('Outros',                  'NaoAtribuido', 'Sem origem',         NULL,                         'S3', '2026-09-15', 'V4 — balde residual do CRM'),
  ('Otros',                   'NaoAtribuido', 'Sem origem',         NULL,                         'S3', '2026-09-15', 'V4 — balde residual do CRM (grafia LATAM)'),
  ('insercao-manual',         'NaoAtribuido', 'Cadastro manual',    NULL,                         'S3', '2026-09-15', 'V4 — cadastro manual, origem real desconhecida'),
  ('T-021530195',             'NaoAtribuido', 'Sem origem',         'Identificador tecnico',      'S3', '2026-09-15', 'V4 — id tecnico, nao origem'),
  ('Lead Rejeitado LMI',      'NaoAtribuido', 'Sem origem',         'Estado, nao origem',         'S3', '2026-09-15', 'V4 — descreve estado do lead, nao de onde veio'),
  ('Lead Freshdesk',          'Comercial',    'Suporte',            'Ticket de suporte',          'S3', '2026-09-15', 'V4 — originado em atendimento, nao em campanha'),
  ('Loupen Telefone',         'Comercial',    'Prospeccao ativa',   'Telefone',                   'S3', '2026-09-15', 'V4 — contato telefonico ativo'),
  ('Contato',                 'Comercial',    'Prospeccao ativa',   NULL,                         'S3', '2026-09-15', 'V4 — contato direto'),
  ('Projeto Lost New',        'Comercial',    'Prospeccao ativa',   'Recuperacao de perdidos',    'S3', '2026-09-15', 'V4 — acao comercial sobre base perdida'),
  ('Projeto Thomson Reuters', 'Comercial',    'Prospeccao ativa',   'Projeto nomeado',            'S3', '2026-09-15', 'V4 — acao comercial nomeada'),
  ('Indicação de Novos Clientes', 'Parceiro', 'Parceiro/Indicação', NULL,                         'S3', '2026-09-15', 'V4 — indicacao')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- ⛔ NAO CLASSIFICADOS DE PROPOSITO — o valor nao decide sozinho.
--    Ficam em NaoAtribuido ate alguem que conhece a operacao decidir.
--    Classificar por palpite aqui seria o mesmo erro do bucket residual.
-- ─────────────────────────────────────────────────────────────────────────────
--
--   'GoTo'            325 leads, 2021-09 a 2026-09  <-- O MAIOR DA LISTA
--        "GoTo" e o nome do PRODUTO, nao de uma campanha. Um lead com essa
--        origem pode ter vindo de campanha do GoTo ou de prospeccao ativa na
--        linha GoTo. Cinco anos de historico com o mesmo rotulo sugere que virou
--        padrao de digitacao, nao uma origem. 325 leads dependem desta decisao.
--
--   'Evento'           12 leads, 2022-09 a 2026-09
--        Qual evento? Patrocinado (Marketing) ou visita comercial a feira?
--
--   'Inbound'          12 leads, 2025-08 a 2026-09
--        Inbound de quê? Sem o canal, nomear como Marketing e adivinhar.
--
--   'WhatsApp'          4 leads
--        Canal, nao origem. O lead chegou no WhatsApp vindo de onde?
--        (mesma lacuna de CON-5, os ~15% de Ad ID no WhatsApp)
--
--   'LastPass'          2 leads
--        Nome de produto, mesma ambiguidade de 'GoTo'.
--
--   'Tráfego Direto'    1 lead
--        Trafego direto e literalmente a ausencia de atribuicao. Marketing
--        ou NaoAtribuido e uma escolha de politica, nao de dado.
--
-- Depois de decidir, acrescentar aqui e REEXECUTAR a matriz de 3.15 antes de
-- levar o gate 3.16 ao usuario.

-- ─────────────────────────────────────────────────────────────────────────────
-- ORIGENS DE CONVERSAO DO RD STATION (acrescentado 2026-09-15)
--
-- Descoberta ao investigar por que os 475 leads do RD estavam TODOS em
-- 'NaoAtribuido': o crosswalk so conhecia valores de LeadSource do SALESFORCE.
-- Nenhuma das 18 origens de conversao do RD estava nele, entao todas caiam em
-- S6 'Outro (requer nota)'.
--
-- Isso quebrava o objetivo central do epico: "leads do RD gerados por
-- marketing" era um conjunto VAZIO, por construcao.
--
-- Oito das 18 ja estao classificadas acima -- sao as MESMAS campanhas que
-- aparecem no LeadSource do Salesforce. O crosswalk e chaveado por valor_bruto,
-- nao por fonte, entao uma entrada serve as duas pontas. As 10 restantes:
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id, decidido_em, fonte_decisao) VALUES
  ('Cadastro Sorteio Loupen x GoTo',               'Marketing',    'Evento/Webinar', 'Startup Summit',        'S3', '2026-09-15', 'V4 — captacao de sorteio em evento; e acao de marketing. Sai das TAXAS pela marcacao de lista importada (migration 071), nao pela classificacao'),
  ('Webinar-GoTo-07-26',                           'Marketing',    'Evento/Webinar', 'Webinar GoTo',          'S3', '2026-09-15', 'V4 — o valor nomeia webinar e o mes'),
  ('META_LEADS_FORM_2605_GOTO_SORTEIO',            'Marketing',    'Paid Social',    'Meta Ads',              'S3', '2026-09-15', 'V4 — formulario de lead do Meta, nomeado no proprio valor'),
  ('SITE_Contato_Fale conosco',                    'Marketing',    'Inbound Web',    'Formulário de contato', 'S3', '2026-09-15', 'V4 — formulario do site'),
  ('Leads_RD_Station',                             'NaoAtribuido', 'Sem origem',     NULL,                    'S3', '2026-09-15', 'V4 — "leads do RD Station" nomeia a FERRAMENTA, nao a origem. Nao diz de onde o lead veio'),
  ('Contatos_Contas_Loupen_tratado_nome_completo', 'NaoAtribuido', 'Base importada', NULL,                    'S3', '2026-09-15', 'V4 — base tratada e importada'),
  ('Base_leads_Cliente_logMeIn',                   'NaoAtribuido', 'Base importada', NULL,                    'S3', '2026-09-15', 'V4 — base de clientes importada'),
  ('Contas base Fresh',                            'NaoAtribuido', 'Base importada', NULL,                    'S3', '2026-09-15', 'V4 — base importada'),
  ('computer',                                     'NaoAtribuido', 'Sem origem',     'Campo de dispositivo',  'S3', '2026-09-15', 'V4 — e o DISPOSITIVO vazando no campo de origem, nao uma origem'),
  ('mobile',                                       'NaoAtribuido', 'Sem origem',     'Campo de dispositivo',  'S3', '2026-09-15', 'V4 — idem: dispositivo, nao origem')
ON CONFLICT (valor_bruto) DO NOTHING;
