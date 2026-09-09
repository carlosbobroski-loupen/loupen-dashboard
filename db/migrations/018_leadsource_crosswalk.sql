-- db/migrations/018_leadsource_crosswalk.sql
-- Subtask 3.1 (V3/OQ-13). Crosswalk explícito valor→segmento/sinal para o
-- campo LeadSource real do Salesforce, levantado por SOQL direto
-- (SELECT LeadSource, COUNT(Id) FROM Lead GROUP BY LeadSource, 200 valores
-- distintos retornados, 2026-09-07 — ver validation-log.md para a
-- metodologia completa e a citação da fonte).
--
-- ESTA É UMA TABELA DE REFERÊNCIA ESTÁTICA, olhada por MATCH EXATO em
-- fn_classify_origin (migration 019) — nunca heurística de runtime sobre
-- string (isso seria repetir DEF-3, sinal implícito). Só valores com
-- correspondência CONFIANTE entram aqui. Valores ausentes desta tabela
-- caem em S6 (Não atribuído) pelo desenho da própria função — "não
-- mapeado" é um estado seguro e esperado, não uma lacuna a esconder.
--
-- PENDENTE DE REVISÃO DO USUÁRIO (não classificado nesta versão, fica
-- honestamente como Não atribuído/"Outro (requer nota)" até decisão):
--   'Espelhamento SF LMI' (3793 leads) — parece artefato de sincronização
--     entre orgs Salesforce, não um canal real.
--   'Lead Freshdesk' (5135 leads) — origem de ticket de suporte, natureza
--     ambígua (marketing vs orgânico vs outro).
--   'Base de Leads - Canales' (2860 leads) — pode ser Parceiro (canal) ou
--     Comercial (lista); ambíguo demais pro volume envolvido pra eu
--     decidir sozinho.
--   'Evento' (1622 leads) — genérico demais; pode sobrepor com
--     Feira/Webinar/Summit já mapeados individualmente.
--   'Redrive' (34), 'Projeto Lost New' (9), 'ACS' (50), tickets 'T-0215...'
--     (2 cada) — nomes internos sem significado claro pra mim.

CREATE TABLE IF NOT EXISTS leadsource_crosswalk (
  valor_bruto      text PRIMARY KEY,
  segmento         text NOT NULL CHECK (segmento IN ('Marketing', 'Comercial', 'NaoAtribuido', 'Parceiro')),
  categoria        text NOT NULL,
  detalhe          text,
  sinal_id         text NOT NULL,
  decidido_em      date NOT NULL DEFAULT '2026-09-07',
  fonte_decisao    text NOT NULL DEFAULT 'V3/OQ-13 — SOQL real + revisão manual, ver validation-log.md'
);
COMMENT ON TABLE leadsource_crosswalk IS
  'Referência estática valor→segmento para LeadSource do Salesforce. Citável, corrigível por linha (UPDATE, nunca heurística). Ausência de uma linha É uma decisão válida (cai em S6).';

-- ── Marketing: paid ads / paid search ──────────────────────────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id) VALUES
  ('Busca Paga | Google', 'Marketing', 'Paid Search', 'Google Ads', 'S3'),
  ('Busca Paga |Google', 'Marketing', 'Paid Search', 'Google Ads', 'S3'),
  ('Busca Paga', 'Marketing', 'Paid Search', 'Google Ads', 'S3'),
  ('Busca Orgânica | Google', 'Marketing', 'Busca Orgânica', 'Google', 'S3'),
  ('Facebook Ads', 'Marketing', 'Paid Social', 'Meta Ads', 'S3'),
  ('Campanha Facebook GoTo', 'Marketing', 'Paid Social', 'Meta Ads', 'S3'),
  ('Google Ads - Jive Empresarial', 'Marketing', 'Paid Search', 'Google Ads', 'S3'),
  ('Google AdWords', 'Marketing', 'Paid Search', 'Google Ads', 'S3'),
  ('LinkedIn', 'Marketing', 'Paid Social', 'LinkedIn Ads', 'S3'),
  ('Anúncios', 'Marketing', 'Paid (canal a resolver)', NULL, 'S3'),
  ('Social | Instagram', 'Marketing', 'Paid Social', 'Instagram', 'S3'),
  ('Social | Facebook', 'Marketing', 'Paid Social', 'Facebook', 'S3'),
  ('Social | YouTube', 'Marketing', 'Paid Social', 'YouTube', 'S3')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ── Marketing: inbound web (site, formulário, chat, referral) ──────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id) VALUES
  ('LandingPage', 'Marketing', 'Inbound Web', 'Landing Page', 'S3'),
  ('Landing Page', 'Marketing', 'Inbound Web', 'Landing Page', 'S3'),
  ('Loupen - Landing Page', 'Marketing', 'Inbound Web', 'Landing Page', 'S3'),
  ('Website', 'Marketing', 'Inbound Web', 'Site institucional', 'S3'),
  ('Site Loupen', 'Marketing', 'Inbound Web', 'Site institucional', 'S3'),
  ('Site LogmeInBrasil', 'Marketing', 'Inbound Web', 'Site institucional', 'S3'),
  ('Site Jive empresarial', 'Marketing', 'Inbound Web', 'Site institucional', 'S3'),
  ('Formulário | Site (loupenbrasil)', 'Marketing', 'Inbound Web', 'Formulário de contato', 'S3'),
  ('Formulário Serviços', 'Marketing', 'Inbound Web', 'Formulário de contato', 'S3'),
  ('Formulario de Servicios', 'Marketing', 'Inbound Web', 'Formulário de contato', 'S3'),
  ('Página de Contato (loupenbrasil)', 'Marketing', 'Inbound Web', 'Formulário de contato', 'S3'),
  ('Freshchat', 'Marketing', 'Inbound Web', 'Chat do site', 'S3'),
  ('Loupen_Chat', 'Marketing', 'Inbound Web', 'Chat do site', 'S3'),
  ('Referência | loupenlatam.com', 'Marketing', 'Inbound Web', 'Referral do site', 'S3'),
  ('Referência   loupenlatam.com', 'Marketing', 'Inbound Web', 'Referral do site', 'S3'),
  ('Referência | rdstation.com.br', 'Marketing', 'Inbound Web', 'Referral do site', 'S3'),
  ('Referência | loupenbrasil.com.br', 'Marketing', 'Inbound Web', 'Referral do site', 'S3'),
  ('comprar-pro', 'Marketing', 'Inbound Web', 'Página de compra', 'S3'),
  ('LogMeIn Brasil (COMPRAR-CENTRAL)', 'Marketing', 'Inbound Web', 'Página de compra', 'S3'),
  ('LogMeIn Brasil (COMPRAR-RESCUE)', 'Marketing', 'Inbound Web', 'Página de compra', 'S3'),
  ('LogMeIn Brasil (COMPRAR-GTM)', 'Marketing', 'Inbound Web', 'Página de compra', 'S3'),
  ('Trial', 'Marketing', 'Inbound Web', 'Trial self-service', 'S3'),
  ('Trial GoTo', 'Marketing', 'Inbound Web', 'Trial self-service', 'S3'),
  ('Trial Site Attemics', 'Marketing', 'Inbound Web', 'Trial self-service', 'S3')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ── Marketing: RD Station (todas as variantes observadas) ──────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id)
SELECT v, 'Marketing', 'Inbound Web', 'RD Station', 'S3'
FROM (VALUES
  ('RD Station (logmeinbrasil)'), ('RD Station (lmibrazil-central)'), ('RD Station (logmein-latam)'),
  ('RD Station ([LATAM] Clientes)'), ('RD Station ([ACTIVE] Importação)'),
  ('RD Station (tudo-sobre-webinar-ebook-gui'), ('RD Station (logmein-rescue-assist)'),
  ('RD Station (solicitar-contato-rodape-sit'), ('RD Station (20904-2095)'), ('RD Station (jive)'),
  ('RD Station (tsw-taticas-para-criar-webin'), ('RD Station (jive-pabx-na-nuvem)'),
  ('RD Station (logmein-precos)'), ('RD Station ([LATAM] LastPass - clientes)'),
  ('RD Station (rescue-trial-latam)'), ('RD Station (tsw-os-erros-mais-comuns-em-'),
  ('RD Station (formulario-contato-loupenbra'), ('RD Station (comece-agora-rescue)'),
  ('RD Station (freshchat-jive-empresarial)'), ('RD Station (jive-contact-center-loupen-c'),
  ('RD Station (jive-pabx-loupen-com-br)'), ('RD Station ([GOTO] GoTo Connect - Agendar Demonstração)'),
  ('RD Station (jive-call-center-pro)'), ('RD Station (gotoconnect-latam)'),
  ('RD Station (tsw-guia-do-engajamento-perf'), ('RD Station (tsw-guia-completo-potenciali'),
  ('RD Station (tsw-pesquisa-dados-e-fatos-p'), ('RD Station (lastpass-latam)'),
  ('RD Station (central-trial-latam)'), ('RD Station ()'),
  ('lmibrazil-central'), ('lmibrazil-Rescue Assist'), ('logmeinbrasil'), ('logmein-latam'), ('logmein-precos')
) AS t(v)
ON CONFLICT (valor_bruto) DO NOTHING;

-- ── Marketing: eventos e campanhas nomeadas ─────────────────────────────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id) VALUES
  ('Startup Summit 2026', 'Marketing', 'Evento/Webinar', 'Startup Summit', 'S3'),
  ('Startup Summit 2025', 'Marketing', 'Evento/Webinar', 'Startup Summit', 'S3'),
  ('Startup Summit', 'Marketing', 'Evento/Webinar', 'Startup Summit', 'S3'),
  ('RD Summit 2019', 'Marketing', 'Evento/Webinar', 'RD Summit', 'S3'),
  ('Webinar', 'Marketing', 'Evento/Webinar', NULL, 'S3'),
  ('Trilhas de Conteúdo', 'Marketing', 'Evento/Webinar', NULL, 'S3'),
  ('Ebook', 'Marketing', 'Conteúdo/Ebook', NULL, 'S3'),
  ('Ebook GoToConnect', 'Marketing', 'Conteúdo/Ebook', NULL, 'S3'),
  ('Attemics - Ebook 2023', 'Marketing', 'Conteúdo/Ebook', NULL, 'S3'),
  ('Campanha Ebook MSP', 'Marketing', 'Conteúdo/Ebook', NULL, 'S3'),
  ('Digital Event', 'Marketing', 'Evento/Webinar', NULL, 'S3'),
  ('Feira', 'Marketing', 'Evento/Webinar', 'Feira', 'S3'),
  ('Leads Gerados por Marketing', 'Marketing', 'Campanha (canal a resolver)', NULL, 'S3'),
  ('Leads FRESH Generados por Marketing', 'Marketing', 'Campanha (canal a resolver)', NULL, 'S3'),
  ('Campanhas Marketing', 'Marketing', 'Campanha (canal a resolver)', NULL, 'S3'),
  ('Marketing Email', 'Marketing', 'E-mail Marketing', NULL, 'S3'),
  ('Campanha de E-mail RD Station', 'Marketing', 'E-mail Marketing', 'RD Station', 'S3'),
  ('Campanha de E-mail RD Station - Jive Empresarial', 'Marketing', 'E-mail Marketing', 'RD Station', 'S3'),
  ('[G2MWT] [Contact Sales Form][BR][PT]', 'Marketing', 'Inbound Web', 'Formulário de contato', 'S3')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ── Comercial: outbound explícito, ferramentas de prospecção, listas ───
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id) VALUES
  ('Outbound', 'Comercial', 'Outbound SDR/Vendas', 'Prospecção ativa', 'S5'),
  ('Outbound ERP Summit', 'Comercial', 'Outbound SDR/Vendas', 'Prospecção ativa em evento', 'S5'),
  ('Fornecedor', 'Comercial', 'Outbound SDR/Vendas', 'Lista/fornecedor de dados (confirmado pelo usuário 2026-09-07)', 'S5'),
  ('Fornecedor (Edymiller)', 'Comercial', 'Outbound SDR/Vendas', 'Lista/fornecedor de dados', 'S5'),
  ('SNOV', 'Comercial', 'Outbound SDR/Vendas', 'Snov.io', 'S5'),
  ('SNOV| Diretores/Gerentes Comerciais', 'Comercial', 'Outbound SDR/Vendas', 'Snov.io', 'S5'),
  ('Apollo.Io', 'Comercial', 'Outbound SDR/Vendas', 'Apollo.io', 'S5'),
  ('Ramper', 'Comercial', 'Outbound SDR/Vendas', 'Ramper', 'S5'),
  ('Ramper | Diretores/Gestores de TI', 'Comercial', 'Outbound SDR/Vendas', 'Ramper', 'S5'),
  ('Ramper | Diretores/Gerentes Comerciais', 'Comercial', 'Outbound SDR/Vendas', 'Ramper', 'S5'),
  ('Lista Comprada', 'Comercial', 'Outbound SDR/Vendas', 'Lista comprada', 'S5'),
  ('Lista Neoway', 'Comercial', 'Outbound SDR/Vendas', 'Lista Neoway', 'S5'),
  ('Lista DataPar Py', 'Comercial', 'Outbound SDR/Vendas', 'Lista DataPar', 'S5'),
  ('Lista Take Over', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção', 'S5'),
  ('Lista Jorge', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Base en Frio', 'Comercial', 'Outbound SDR/Vendas', 'Base fria de prospecção', 'S5'),
  ('Prospecção', 'Comercial', 'Outbound SDR/Vendas', NULL, 'S5'),
  ('Prospecção de Gerente de Canais Loupen', 'Comercial', 'Outbound SDR/Vendas', 'Prospecção por gerente de canais', 'S5'),
  ('LATAM - Recuperação Opps Jorge LMI', 'Comercial', 'Outbound SDR/Vendas', 'Reativação de oportunidade', 'S5'),
  ('Leads Tony 09-03-2020', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Tony 13-12-2019', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Tony 05-02-2020', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Tony 16-01-2020', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Felipe LMI 03-10-2019', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Felipe LMI 18-09-2019', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Gabriel Listek 06-05', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Gabriel Listek 24-05', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Gabriel Listek 30-05', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5'),
  ('Leads Gabriel Listek 13-05', 'Comercial', 'Outbound SDR/Vendas', 'Lista de prospecção nominal', 'S5')
ON CONFLICT (valor_bruto) DO NOTHING;

-- ── Parceiro (S9, segmento próprio — OQ-12/V4, decisão do usuário) ──────
INSERT INTO leadsource_crosswalk (valor_bruto, segmento, categoria, detalhe, sinal_id) VALUES
  ('Parceiro', 'Parceiro', 'Parceiro/Indicação', NULL, 'S9'),
  ('Lead de Parceiro', 'Parceiro', 'Parceiro/Indicação', NULL, 'S9'),
  ('Indicação Parceiro', 'Parceiro', 'Parceiro/Indicação', NULL, 'S9'),
  ('Indicação de Parceiro / Revenda', 'Parceiro', 'Parceiro/Indicação', 'Revenda', 'S9'),
  ('Partner indicador Diumex - Distribuidora Universal Mexicana', 'Parceiro', 'Parceiro/Indicação', 'Revenda', 'S9'),
  ('Indicação', 'Parceiro', 'Parceiro/Indicação', NULL, 'S9'),
  ('Indicação Cliente', 'Parceiro', 'Parceiro/Indicação', 'Indicação de cliente', 'S9'),
  ('Indicação de Cliente', 'Parceiro', 'Parceiro/Indicação', 'Indicação de cliente', 'S9'),
  ('Indicação de Funcionário', 'Parceiro', 'Parceiro/Indicação', 'Indicação de funcionário', 'S9'),
  ('Indicação Interna', 'Parceiro', 'Parceiro/Indicação', 'Indicação de funcionário', 'S9'),
  ('Indicação Interna Loupen', 'Parceiro', 'Parceiro/Indicação', 'Indicação de funcionário', 'S9'),
  ('Indicação de Revenda Loupen', 'Parceiro', 'Parceiro/Indicação', 'Revenda', 'S9'),
  ('LMI Partner Exchange', 'Parceiro', 'Parceiro/Indicação', 'Revenda', 'S9'),
  ('Leads Indicación LastPass (email/monday)', 'Parceiro', 'Parceiro/Indicação', NULL, 'S9'),
  ('Leads Indicación GoTo (email)', 'Parceiro', 'Parceiro/Indicação', NULL, 'S9'),
  ('Leads IndicaciÃ³n LastPass (email/monday)', 'Parceiro', 'Parceiro/Indicação', 'variante com encoding quebrado do mesmo valor acima', 'S9')
ON CONFLICT (valor_bruto) DO NOTHING;
