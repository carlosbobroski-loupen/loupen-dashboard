-- db/migrations/071_lista_importada.sql
-- Marca leads vindos de LISTA IMPORTADA, para que eles nao distorcam TAXA sem
-- sumir da CONTAGEM.
--
-- O PROBLEMA MEDIDO (2026-09-14): 318 dos 475 leads visiveis -- 67% da base --
-- carregam a tag `leads_statup_summit_lista`. Todos criados entre 26/08 e
-- 01/09/2026, todos com essa unica tag, de duas origens ("Cadastro Sorteio
-- Loupen x GoTo" 161, "Leads_RD_Station" 157), e TODOS parados no estagio
-- `Lead` -- nenhum chegou a `Qualified Lead`.
--
-- O efeito no numero: 475 leads / 41 qualificados = 8,6%. Sem a lista:
-- 157 / 41 = 26%. A diferenca nao e cosmetica -- e a diferenca entre "o
-- marketing esta ruim" e "o marketing esta bom".
--
-- POR QUE NAO REUSAR is_teste: lead de sorteio nao e lead de teste. Ele
-- EXISTE, a pessoa se cadastrou, e ele conta como lead. O que ele nao deve
-- fazer e entrar no denominador de taxa de conversao junto com lead de
-- demanda. Semantica diferente, coluna diferente.
--
-- POR QUE GUARDA O NOME DA REGRA E NAO UM BOOLEANO: mesma razao do
-- `teste_regra` (data-contract.md §1.6) -- a contagem por regra tem de poder
-- aparecer na aba Qualidade de dados. Exclusao silenciosa e proibida: se um
-- numero exclui linhas, a tela tem de dizer quantas e por qual regra.
--
-- POR QUE REGRA E NAO LISTA DE IDs: uma lista de 318 ids congelada em SQL
-- envelhece no dia seguinte. A regra casa contra a TAG, que e o dado que a
-- fonte entrega -- e pega sozinha a proxima lista importada que chegar.

CREATE TABLE IF NOT EXISTS lead_lista_regra (
  id        bigserial PRIMARY KEY,
  nome      text NOT NULL UNIQUE,
  campo     text NOT NULL,
  padrao    text NOT NULL,
  ativo     boolean NOT NULL DEFAULT true,
  motivo    text NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE lead_lista_regra IS
  'Regras que identificam lead vindo de lista importada (evento, sorteio, base comprada). Espelha lead_teste_regra na forma, mas a semantica e outra: lead de lista CONTA como lead e so sai do denominador de TAXA. Ver migration 071.';

ALTER TABLE lead ADD COLUMN IF NOT EXISTS lista_regra text;

COMMENT ON COLUMN lead.lista_regra IS
  'Nome da regra de lead_lista_regra que casou, ou NULL. Nome e nao booleano para que a aba Qualidade de dados consiga contar por regra -- exclusao silenciosa e proibida.';

INSERT INTO lead_lista_regra (nome, campo, padrao, motivo) VALUES
  ('lista Startup Summit (sorteio)', 'tags', '^leads_statup_summit_lista$',
   'Lista de cadastro de sorteio captada no Startup Summit (26/08 a 01/09/2026). 318 leads, nenhum avancou de estagio. Entra na contagem de leads, sai do denominador de taxa.')
ON CONFLICT (nome) DO NOTHING;

CREATE OR REPLACE FUNCTION fn_lead_lista_regra(p_tags text[])
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT r.nome
  FROM lead_lista_regra r
  WHERE r.ativo
    AND r.campo = 'tags'
    AND p_tags IS NOT NULL
    AND EXISTS (SELECT 1 FROM unnest(p_tags) t WHERE t ~ r.padrao)
  ORDER BY r.id
  LIMIT 1;
$$;

COMMENT ON FUNCTION fn_lead_lista_regra(text[]) IS
  'Devolve o NOME da regra de lead_lista_regra que casou com as tags do lead, ou NULL. Ver migration 071.';

-- Backfill do que ja esta na base.
UPDATE lead
   SET lista_regra = fn_lead_lista_regra(tags)
 WHERE lista_regra IS DISTINCT FROM fn_lead_lista_regra(tags);
