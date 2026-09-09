-- db/migrations/056_cargo_e_tamanho_segunda_rodada.sql
-- Subtask 8.13 — segunda rodada de regras, guiada pelo que `fn_qualidade_dados`
-- (migration 055) expôs sobre os 500 leads reais.
--
-- Isto é o ciclo que o contrato §1.3 desenhou funcionando: a tabela de regras
-- evolui a partir dos valores que sobraram em `outros`, não de uma taxonomia
-- inventada de antemão. A migration 050 semeou com os 31 valores do primeiro
-- lote; a carga completa trouxe valores novos, e são eles que justificam esta.
--
-- ── TRÊS BUGS NAS MINHAS PRÓPRIAS REGRAS, ENCONTRADOS PELO DADO ───────────
--
--   1. `Outro` estava como match EXATO. O valor real na base é `Outros`
--      (plural) — 27 leads, o maior grupo sem classificação, caindo em
--      `outros` por uma letra. Era o meu maior erro de regra e só apareceu
--      porque a aba de qualidade lista os não classificados.
--
--   2. `%Gerente%` não pega `Gestor De Marketing`. Ela funcionava para
--      `Gestor/Gerente` (que contém "Gerente"), o que me deu falsa confiança
--      de que "Gestor" estava coberto. Não estava.
--
--   3. `%Head de%` não pega `Head` sozinho. Regra escrita a partir de UM
--      valor observado (`Head de Operações...`), estreita demais.
--
-- ── UMA DIMENSÃO QUE O CAMPO ESCONDE ──────────────────────────────────────
-- `TI / Tecnologia` (17 leads), `Comercial / Vendas` (8), `Marketing`,
-- `Comunicação`: estas NÃO são respostas de senioridade, são ÁREAS. O
-- formulário mistura duas perguntas no mesmo campo `job_title`.
--
-- Colapsá-las em algum nível de cargo seria inventar senioridade que a pessoa
-- não informou. Vão para `area_declarada` — um grupo que diz exatamente o que
-- aconteceu: a pessoa respondeu com a área, não com o cargo. Assim quem
-- filtrar por `c_level` não recebe 25 leads de senioridade desconhecida.
--
-- ── O QUE FICA EM `outros` DE PROPÓSITO ───────────────────────────────────
-- A cauda de cargos livres com n=1 (`Apresentadora`, `Psicóloga`,
-- `Professor do ensino fundamental`, `Engenheiro de plataforma`,
-- `Atendente de Suporte...`, e afins). São legítimos e idiossincráticos.
-- Escrever regra para cada um seria construir taxonomia a partir de n=1 —
-- exatamente o tipo de invenção que o Artigo IV proíbe. `outros` com ~12 de
-- 439 cargos preenchidos é um estado saudável, e a aba de qualidade continua
-- mostrando quais são.
--
-- `Executiva` também fica: sozinha, em português comercial brasileiro, pode
-- ser tanto C-level quanto executiva de contas. Ambíguo é ambíguo.

-- ---------------------------------------------------------------------------
-- 1. Correção dos três bugs + área declarada
-- ---------------------------------------------------------------------------

-- `Outro` era match exato e não pegava `Outros`. Trocado por prefixo, que
-- cobre as duas formas. Continua no fim da fila (prioridade 90) para não
-- capturar cargo que contenha a palavra por acidente.
UPDATE cargo_grupo_regra
   SET padrao = 'Outro%'
 WHERE padrao = 'Outro' AND grupo = 'outro_declarado';

INSERT INTO cargo_grupo_regra (padrao, grupo, prioridade, observado) VALUES
  -- c_level (10) — 1x `Partner` (sócio, em inglês)
  ('%Partner%',      'c_level',         10, true),

  -- diretoria (20) — 1x `Head` sozinho. A regra `%Head de%` da 050 continua
  -- existindo e é redundante com esta, mas não a removo: remover regra que
  -- funciona para trocar por uma mais ampla é risco sem retorno, e a
  -- prioridade igual faz as duas darem o mesmo resultado.
  ('%Head%',         'diretoria',       20, true),

  -- gerencia (30) — 1x `Gestor De Marketing`
  ('%Gestor%',       'gerencia',        30, true),

  -- consultor (50) — 1x `Especialista Pedagogico Pearson Latam`. O grupo
  -- cobre contribuidor individual sênior: consultor e especialista.
  ('%Especialista%', 'consultor',       50, true),

  -- area_declarada (80) — a pessoa respondeu ÁREA, não cargo. Prioridade 80:
  -- depois de todos os níveis de senioridade (para que `Gestor De Marketing`
  -- caia em gerencia, não aqui) e antes de outro_declarado.
  ('TI / Tecnologia',      'area_declarada', 80, true),
  ('Comercial / Vendas',   'area_declarada', 80, true),
  ('Marketing',            'area_declarada', 80, true),
  ('Comunicação',          'area_declarada', 80, true)
ON CONFLICT (padrao) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Tamanho de empresa: valores por PALAVRA, não por número
--
-- `fn_qualidade_dados` mostrou 3 valores preenchidos que a normalização não
-- conseguiu ler, porque ela só extraía números:
--   `Grande`                                    -> palavra, sem dígito
--   `Sou autônomo / Profissional independente`  -> 1 pessoa, sem dígito
--   `ste`                                       -> lixo, continua nao_informado
--
-- A versão anterior devolvia `nao_informado` para os três, misturando "não
-- informou" com "informou e não entendemos". São coisas diferentes: a
-- primeira é ausência de dado, a segunda é falha nossa de leitura.
--
-- As 13 asserções de normalizacao-perfil-lead.sql continuam valendo: nenhum
-- dos valores numéricos contém as palavras tratadas aqui, e o ramo de
-- palavras roda ANTES da extração de número só para os casos sem dígito.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_normalizar_tamanho_empresa(p_bruto text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_limpo  text;
  v_maior  bigint;
BEGIN
  IF p_bruto IS NULL OR btrim(p_bruto) = '' THEN
    RETURN 'nao_informado';
  END IF;

  -- Remove separador de milhar para que `1.000+` vire `1000+`, não 1 e 000.
  v_limpo := replace(replace(p_bruto, '.', ''), ',', '');

  SELECT max(n::bigint) INTO v_maior
  FROM regexp_matches(v_limpo, '(\d+)', 'g') AS m(arr),
       LATERAL unnest(m.arr) AS n;

  -- Caminho numérico (o caso normal, e o único que existia antes).
  IF v_maior IS NOT NULL THEN
    IF    v_maior >= 1000 THEN RETURN 'grande';
    ELSIF v_maior >= 100  THEN RETURN 'media';
    ELSE                       RETURN 'pequena';
    END IF;
  END IF;

  -- Sem dígito nenhum: tenta as respostas por palavra observadas na base.
  -- Autônomo/independente é 1 pessoa, logo `pequena` (faixa 1–99).
  IF p_bruto ~* '(autônomo|autonomo|independente|freelanc|MEI\M|micro)' THEN
    RETURN 'pequena';
  ELSIF p_bruto ~* '\m(pequena|pequeno)\M' THEN
    RETURN 'pequena';
  ELSIF p_bruto ~* '\m(média|media|medio|médio)\M' THEN
    RETURN 'media';
  ELSIF p_bruto ~* '\m(grande|corporaç|corporac|enterprise)' THEN
    RETURN 'grande';
  END IF;

  -- Informou algo que não sabemos ler. Distinto de não ter informado, mas o
  -- contrato §1.4 só define 3 faixas + nao_informado, então não invento um
  -- quarto valor aqui — quem expõe a diferença é fn_qualidade_dados, que
  -- lista justamente os valores preenchidos que caíram em nao_informado.
  RETURN 'nao_informado';
END;
$$;

COMMENT ON FUNCTION fn_normalizar_tamanho_empresa(text) IS
  'Colapsa cf_tamanho_da_empresa (texto livre, escalas conflitantes) nas 3 faixas do data-contract.md §1.4. Caminho numérico primeiro (limite superior); sem dígito, tenta as respostas por PALAVRA observadas na base (autônomo, grande, média...). Valor preenchido e ilegível volta nao_informado, e fn_qualidade_dados o lista — a diferença entre "não informou" e "não sabemos ler" fica visível na aba, não escondida na função.';

-- ---------------------------------------------------------------------------
-- Efeito imediato, medido no próprio arquivo
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_outros        integer;
  v_com_cargo     integer;
  v_nao_lidos     integer;
BEGIN
  SELECT count(*) FILTER (WHERE fn_cargo_grupo(cargo) = 'outros'),
         count(*) FILTER (WHERE cargo IS NOT NULL)
    INTO v_outros, v_com_cargo
  FROM lead WHERE NOT is_teste;

  SELECT count(*) INTO v_nao_lidos
  FROM lead
  WHERE NOT is_teste AND tamanho_empresa_bruto IS NOT NULL
    AND btrim(tamanho_empresa_bruto) <> ''
    AND fn_normalizar_tamanho_empresa(tamanho_empresa_bruto) = 'nao_informado';

  RAISE NOTICE 'cargo: % de % preenchidos seguem em "outros" (era 92 antes desta migration).', v_outros, v_com_cargo;
  RAISE NOTICE 'tamanho: % valor(es) preenchido(s) ainda ilegivel(is).', v_nao_lidos;
END;
$$;
