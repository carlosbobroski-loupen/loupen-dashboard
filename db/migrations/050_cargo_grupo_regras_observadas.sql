-- db/migrations/050_cargo_grupo_regras_observadas.sql
-- Subtask 8.7 — semeia cargo_grupo_regra a partir dos valores REAIS.
--
-- O contrato (§1.3) diz que estas regras têm de sair da lista de valores
-- distintos da primeira ingestão cheia, "não a partir de faixas inventadas".
-- Essa ingestão aconteceu: 125 leads reais do RD Station, e `job_title`
-- preenchido em 85,9% deles produziu 31 valores distintos. Toda regra abaixo
-- casa com pelo menos um valor observado, e a contagem está no comentário.
--
-- DUAS DISTINÇÕES QUE IMPORTAM E QUE O DADO REVELOU
--
-- 1. `Outro` / `outro` (10 ocorrências) NÃO é o mesmo que "não temos regra".
--    É a pessoa tendo escolhido literalmente "Outro" no formulário — uma
--    resposta, não uma lacuna. Vai para `outro_declarado`, e o `outros`
--    continua significando exclusivamente "nenhuma regra casou", que é o
--    sinal que a aba Qualidade de dados usa para pedir regra nova.
--
-- 2. `Fundador`/`Fundadora` são a forma portuguesa de Founder, e as regras
--    originais (semeadas na 045 com o pouco que eu tinha observado) só
--    cobriam `Founder`. Sem esta migration, 5 sócios-fundadores caíam em
--    `outros`.
--
-- PRIORIDADE: menor vence. Herda a escala já usada na 045 (c_level 10,
-- diretoria 20, gerencia 30) e estende para baixo. `Fundador e CEO` casa com
-- duas regras de c_level — mesmo destino, então a ordem entre elas é
-- irrelevante; a prioridade só existe para separar níveis diferentes.

INSERT INTO cargo_grupo_regra (padrao, grupo, prioridade, observado) VALUES
  -- c_level (10) — 25x "CEO, Founder, Sócio", 10x minúsculo, 9x "Sócio",
  -- 8x "C-level/Presidente", 4x "Fundador", 3x "CEO / Sócio", 2x "Founder",
  -- 1x cada: CFO, CMO, CTO, Ceo, "Fundador e CEO", Fundadora
  ('%C-level%',      'c_level',        10, true),
  ('%Presidente%',   'c_level',        10, true),
  ('%Fundador%',     'c_level',        10, true),   -- pega Fundador e Fundadora
  ('%CFO%',          'c_level',        10, true),
  ('%CMO%',          'c_level',        10, true),
  ('%CTO%',          'c_level',        10, true),

  -- diretoria (20) — 1x "Head de Operações, Desenvolvimento de Negócios e
  -- Comunicação". Head de área é liderança de departamento; agrupado com
  -- diretoria. n=1, então é a regra mais frágil deste arquivo — se aparecer
  -- volume de "Head de" em nível mais júnior, revisar.
  ('%Head de%',      'diretoria',      20, true),

  -- coordenacao (40) — 1x "Coordenadora Comercial", 1x "coordenador/supervisor"
  ('%Coordenador%',  'coordenacao',    40, true),   -- pega Coordenadora
  ('%Supervisor%',   'coordenacao',    40, true),

  -- consultor (50) — 1x "Consultor Inovação & TI", 1x "Consultora de vendas"
  ('%Consultor%',    'consultor',      50, true),   -- pega Consultora

  -- analista (60) — 5x "Analista", 1x "Analista Financeiro",
  -- 1x "Analista Inovação Sr.", 1x minúsculo
  ('%Analista%',     'analista',       60, true),

  -- operacional (70) — 2x "Estagiário", 1x "Assistente"
  ('%Estagi%',       'operacional',    70, true),   -- pega Estagiário/Estagiária
  ('%Assistente%',   'operacional',    70, true),

  -- outro_declarado (90) — 8x "Outro", 2x "outro". Resposta explícita da
  -- pessoa, distinta de ausência de regra. Prioridade alta (última) para não
  -- capturar cargos que contenham a palavra por acidente.
  ('Outro',          'outro_declarado', 90, true)
ON CONFLICT (padrao) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verificação no próprio arquivo: quantos leads reais continuam em `outros`
-- depois destas regras. Não é uma asserção de falha — `outros` é um estado
-- legítimo e esperado para valores futuros. É um NOTICE para que a evolução
-- da tabela seja guiada por número, não por impressão.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_outros   integer;
  v_total    integer;
  v_exemplos text;
BEGIN
  SELECT count(*) FILTER (WHERE fn_cargo_grupo(cargo) = 'outros'),
         count(*) FILTER (WHERE cargo IS NOT NULL)
    INTO v_outros, v_total
  FROM lead WHERE source_system = 'rd_station';

  SELECT string_agg(DISTINCT cargo, ' | ') INTO v_exemplos
  FROM lead
  WHERE source_system = 'rd_station' AND cargo IS NOT NULL
    AND fn_cargo_grupo(cargo) = 'outros';

  RAISE NOTICE 'cargo_grupo: % de % cargos preenchidos seguem em "outros".', v_outros, v_total;
  IF v_outros > 0 THEN
    RAISE NOTICE 'Valores sem regra: %', v_exemplos;
  END IF;
END;
$$;
