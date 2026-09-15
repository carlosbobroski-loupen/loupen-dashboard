-- db/migrations/079_fase_comercial_do_estagio.sql
--
-- Agrupa os 29 valores de `stage_name` do Salesforce nas fases que o negocio
-- pergunta: houve reuniao? chegou a negociar? ganhou? perdeu?
--
-- POR QUE TABELA E NAO CASE NO CODIGO: o vocabulario de estagio vem da
-- operacao e muda quando o time comercial muda o processo. Um CASE em SQL ou
-- em JS envelhece calado -- estagio novo cai no ELSE e some do funil sem
-- ninguem perceber. Numa tabela, o estagio novo aparece com fase NULL, feio e
-- visivel, que e a regra deste projeto desde a migration 050.
--
-- O QUE FICOU DE FORA DE PROPOSITO (fase NULL, 21 oportunidades): 'Pending
-- Sale', 'Pending Payment', 'Processamento Interno', 'Projeto para o Futuro'
-- e 'Lista'. Nenhum deles diz sozinho se a venda aconteceu -- 'Pending Sale'
-- tanto pode ser ganho aguardando faturamento quanto negociacao travada.
-- Chutar aqui contaminaria a taxa de ganho, que e o numero que decide
-- investimento.

CREATE TABLE IF NOT EXISTS opportunity_stage_fase (
  stage_name  text PRIMARY KEY,
  fase        text NOT NULL,
  ordem       integer,
  motivo      text NOT NULL,
  decidido_em date NOT NULL DEFAULT current_date
);

COMMENT ON TABLE opportunity_stage_fase IS
  'stage_name do Salesforce -> fase comercial. Estagio ausente desta tabela aparece com fase NULL na tela, nunca colapsado num balde residual. Ver migration 079.';

INSERT INTO opportunity_stage_fase (stage_name, fase, ordem, motivo) VALUES
  -- contato: o comercial tocou, ainda nao qualificou
  ('Novo',                  'contato',     1, 'oportunidade recem-criada'),
  ('Iniciar Contato',       'contato',     1, 'fila de primeiro contato'),
  ('Primeiro Contato',      'contato',     1, 'primeiro contato feito'),
  ('Tentando Contato',      'contato',     1, 'tentativa sem resposta'),
  ('Buscando Contato',      'contato',     1, 'tentativa sem resposta'),
  ('Abordagem',             'contato',     1, 'abordagem inicial'),
  ('Contato',               'contato',     1, 'contato generico'),
  ('1° Contato Renovação',  'contato',     1, 'primeiro contato do ciclo de renovacao'),
  -- qualificacao: entendendo o cenario
  ('Mapeamento de Cenário', 'qualificacao',2, 'levantamento de cenario'),
  ('Coleta de Cenário',     'qualificacao',2, 'levantamento de cenario'),
  ('Avaliação',             'qualificacao',2, 'avaliacao tecnica'),
  ('Avaliando',             'qualificacao',2, 'avaliacao tecnica'),
  ('POC da Solução',        'qualificacao',2, 'prova de conceito'),
  -- reuniao: houve (ou estava marcada) uma conversa com o cliente
  ('Demonstração',          'reuniao',     3, 'demonstracao realizada'),
  ('GTM Demonstração SPIN', 'reuniao',     3, 'demonstracao no metodo SPIN'),
  ('No-Show',               'reuniao',     3, 'reuniao MARCADA em que o cliente nao compareceu -- conta como reuniao agendada, nao como perda'),
  -- negociacao: proposta na mesa
  ('Proposta Enviada',      'negociacao',  4, 'proposta enviada'),
  ('Enviar Proposta',       'negociacao',  4, 'proposta em preparo'),
  ('Avaliando Proposta',    'negociacao',  4, 'cliente avaliando proposta'),
  ('Em Negociação',         'negociacao',  4, 'negociacao em andamento'),
  ('Acordo Verbal',         'negociacao',  4, 'acordo verbal, sem fechamento formal'),
  ('Aprovado Verbalmente',  'negociacao',  4, 'aprovacao verbal, sem fechamento formal'),
  -- desfecho
  ('Ganho',                 'ganho',       5, 'venda fechada'),
  ('Perdido',               'perdido',     6, 'oportunidade perdida')
ON CONFLICT (stage_name) DO NOTHING;

-- Aviso em vez de silencio: estagio da base que esta tabela nao conhece.
DO $$
DECLARE v_txt text;
BEGIN
  SELECT string_agg(DISTINCT o.stage_name, ', ') INTO v_txt
  FROM opportunity o
  LEFT JOIN opportunity_stage_fase f ON f.stage_name = o.stage_name
  WHERE o.source_system = 'salesforce' AND f.stage_name IS NULL AND o.stage_name IS NOT NULL;
  IF v_txt IS NOT NULL THEN
    RAISE NOTICE 'Estagios SEM fase (aparecem como "sem fase" na tela, de proposito): %', v_txt;
  END IF;
END $$;
