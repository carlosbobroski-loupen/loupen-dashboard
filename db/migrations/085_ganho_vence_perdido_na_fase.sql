-- db/migrations/085_ganho_vence_perdido_na_fase.sql
--
-- BUG achado ao olhar a saida, nao o codigo: uma pessoa com 7 oportunidades e
-- 4 GANHAS aparecia com `fase_mais_avancada = 'perdido'`.
--
-- CAUSA: a migration 079 deu ordem 5 a 'ganho' e 6 a 'perdido', e as views
-- calculam a fase mais avancada com max(ordem). Perder passou a ser "mais
-- avancado" que ganhar.
--
-- O ERRO DE MODELO por tras: `ordem` estava tentando ser DUAS coisas -- a
-- sequencia do pipeline (contato -> qualificacao -> reuniao -> negociacao) e o
-- desfecho (ganho/perdido). Sao eixos diferentes. Ganho e perdido sao ambos
-- TERMINAIS; nenhum vem "depois" do outro.
--
-- CORRECAO: os dois terminais passam a dividir a mesma ordem (5), e as views
-- desempatam preferindo GANHO explicitamente. Uma pessoa que ganhou uma e
-- perdeu outra teve, como desfecho mais avancado, o ganho -- e as duas
-- contagens continuam visiveis em qtd_ganhas e qtd_perdidas, que e onde a
-- informacao completa mora.

UPDATE opportunity_stage_fase SET ordem = 5 WHERE fase = 'perdido';

COMMENT ON COLUMN opportunity_stage_fase.ordem IS
  'Sequencia do pipeline. `ganho` e `perdido` compartilham a ordem 5 porque sao ambos TERMINAIS -- nenhum vem depois do outro. Quem calcula "fase mais avancada" deve desempatar preferindo ganho (ver migration 085).';
