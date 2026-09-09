-- db/queries/verificacao/normalizacao-perfil-lead.sql
-- Prova por EXECUÇÃO as normalizações da migration 045:
--   fn_normalizar_tamanho_empresa  (data-contract.md §1.4)
--   fn_cargo_grupo                 (data-contract.md §1.3)
--
-- Uso:
--   set -a; source .env; set +a
--   psql "$NEON_DATABASE_URL" -f db/queries/verificacao/normalizacao-perfil-lead.sql
--
-- Convenção de asserção deste projeto (db/README.md): a query devolve uma
-- linha por caso com veredito legível E uma linha-resumo que só diz OK
-- quando ZERO divergências existem. Nunca usar o antipadrão
-- `SELECT 1/(subquery HAVING count=N)` — ele NÃO falha quando a condição é
-- falsa (NULL/x = NULL, não divisão por zero), então dá falso OK.
--
-- Os 10 valores de tamanho abaixo NÃO são inventados: são os valores reais
-- observados, com suas frequências, na medição de 250 contatos da API de
-- produção do RD Station em 2026-09-09 (data-contract.md §1.1). Se a origem
-- passar a mandar uma escala nova, este arquivo é o lugar de descobrir.

\pset pager off

-- ---------------------------------------------------------------------------
-- Caso a caso: tamanho de empresa
-- ---------------------------------------------------------------------------
WITH reais(bruto, n_observado, esperado) AS (VALUES
  ('1 a 19 funcionários',        38, 'pequena'),
  ('1 a 9 funcionários',         19, 'pequena'),
  ('10 a 49 funcionários',        9, 'pequena'),
  ('100 a 249 funcionários',      6, 'media'),
  ('1.000+ funcionários',         6, 'grande'),
  ('500 a 999 funcionários',      5, 'media'),
  ('50 a 99 funcionários',        4, 'pequena'),
  ('20 a 99 funcionários',        2, 'pequena'),
  ('mais de 1000 funcionários',   1, 'grande'),
  ('250 a 499 funcionários',      1, 'media'),
  (NULL,                          0, 'nao_informado'),
  ('',                            0, 'nao_informado'),
  ('não sei',                     0, 'nao_informado')
)
SELECT bruto, n_observado, esperado,
       fn_normalizar_tamanho_empresa(bruto) AS obtido,
       CASE WHEN fn_normalizar_tamanho_empresa(bruto) IS NOT DISTINCT FROM esperado
            THEN 'ok' ELSE '*** FALHA ***' END AS veredito
FROM reais
ORDER BY n_observado DESC, bruto NULLS LAST;

-- ---------------------------------------------------------------------------
-- ASSERÇÃO 1 — nenhuma divergência de tamanho
-- ---------------------------------------------------------------------------
SELECT CASE WHEN count(*) = 0
            THEN 'ASSERCAO 1 OK: os 13 casos de tamanho_empresa batem'
            ELSE '*** ASSERCAO 1 FALHOU: ' || count(*) || ' divergencia(s) ***'
       END AS resultado
FROM (VALUES
  ('1 a 19 funcionários','pequena'),('1 a 9 funcionários','pequena'),
  ('10 a 49 funcionários','pequena'),('100 a 249 funcionários','media'),
  ('1.000+ funcionários','grande'),('500 a 999 funcionários','media'),
  ('50 a 99 funcionários','pequena'),('20 a 99 funcionários','pequena'),
  ('mais de 1000 funcionários','grande'),('250 a 499 funcionários','media'),
  (NULL,'nao_informado'),('','nao_informado'),('não sei','nao_informado')
) AS t(bruto, esperado)
WHERE fn_normalizar_tamanho_empresa(bruto) IS DISTINCT FROM esperado;

-- ---------------------------------------------------------------------------
-- ASSERÇÃO 2 — a distribuição reproduz a tabela do contrato §1.4
-- (pequena 72 · media 12 · grande 7, sobre os 91 preenchimentos medidos)
-- ---------------------------------------------------------------------------
WITH dist AS (
  SELECT fn_normalizar_tamanho_empresa(bruto) AS faixa, sum(n) AS leads
  FROM (VALUES
    ('1 a 19 funcionários',38),('1 a 9 funcionários',19),('10 a 49 funcionários',9),
    ('100 a 249 funcionários',6),('1.000+ funcionários',6),('500 a 999 funcionários',5),
    ('50 a 99 funcionários',4),('20 a 99 funcionários',2),
    ('mais de 1000 funcionários',1),('250 a 499 funcionários',1)
  ) AS t(bruto, n)
  GROUP BY 1
), esperado(faixa, leads) AS (VALUES ('pequena',72::numeric),('media',12),('grande',7))
SELECT CASE WHEN count(*) = 0
            THEN 'ASSERCAO 2 OK: distribuicao 72/12/7 confere com data-contract.md 1.4'
            ELSE '*** ASSERCAO 2 FALHOU: distribuicao divergiu do contrato ***'
       END AS resultado
FROM (
  SELECT faixa FROM dist FULL OUTER JOIN esperado USING (faixa, leads)
  WHERE dist.faixa IS NULL OR esperado.faixa IS NULL
) AS divergencias;

-- ---------------------------------------------------------------------------
-- Caso a caso: cargo. `outros` (regra não casou) e `nao_informado` (campo
-- vazio) são estados DISTINTOS de propósito — a aba Qualidade de dados
-- precisa diferenciar "não sabemos" de "não sabemos classificar".
-- ---------------------------------------------------------------------------
-- ATUALIZADO em 2026-09-09 (2ª vez). Este bloco travava
-- `Analista de TI -> outros`, o que era verdade quando o arquivo nasceu (com
-- a migration 045, que tinha só 5 regras). A migration 050 acrescentou
-- `%Analista%` e a expectativa ficou OBSOLETA — e eu só descobri agora,
-- porque depois da 050 eu conferi a distribuição de cargos mas NÃO reexecutei
-- este arquivo. Lição concreta: acrescentar regra é mudar comportamento
-- coberto por asserção, e a asserção tem de rodar no mesmo passo.
--
-- O caso de `outros` agora usa um valor REAL da base que segue sem regra de
-- propósito (`Psicóloga`, n=1) — a cauda de cargos livres idiossincráticos
-- que o contrato §1.3 decidiu não classificar a partir de n=1.
WITH casos(cargo, esperado) AS (VALUES
  ('Diretor',             'diretoria'),
  ('Diretor Comercial',   'diretoria'),
  ('CEO, Founder, Sócio', 'c_level'),
  ('Partner',             'c_level'),
  ('Gerente',             'gerencia'),
  ('Gestor De Marketing', 'gerencia'),
  ('Head',                'diretoria'),
  ('Analista de TI',      'analista'),
  ('TI / Tecnologia',     'area_declarada'),
  ('Outros',              'outro_declarado'),
  ('Psicóloga',           'outros'),
  ('',                    'nao_informado'),
  (NULL,                  'nao_informado')
)
SELECT cargo, esperado, fn_cargo_grupo(cargo) AS obtido,
       CASE WHEN fn_cargo_grupo(cargo) IS NOT DISTINCT FROM esperado
            THEN 'ok' ELSE '*** FALHA ***' END AS veredito
FROM casos;

-- ---------------------------------------------------------------------------
-- ASSERÇÃO 3 — nenhuma divergência de cargo
-- ---------------------------------------------------------------------------
SELECT CASE WHEN count(*) = 0
            THEN 'ASSERCAO 3 OK: os 13 casos de cargo_grupo batem'
            ELSE '*** ASSERCAO 3 FALHOU: ' || count(*) || ' divergencia(s) ***'
       END AS resultado
FROM (VALUES
  ('Diretor','diretoria'),('Diretor Comercial','diretoria'),
  ('CEO, Founder, Sócio','c_level'),('Partner','c_level'),
  ('Gerente','gerencia'),('Gestor De Marketing','gerencia'),
  ('Head','diretoria'),('Analista de TI','analista'),
  ('TI / Tecnologia','area_declarada'),('Outros','outro_declarado'),
  ('Psicóloga','outros'),('','nao_informado'),(NULL,'nao_informado')
) AS t(cargo, esperado)
WHERE fn_cargo_grupo(cargo) IS DISTINCT FROM esperado;

-- ---------------------------------------------------------------------------
-- ASSERÇÃO 4 — as regras semeadas são só as OBSERVADAS (Artigo IV).
-- Se alguém semear uma taxonomia inventada de cargos sem marcar
-- observado=false, esta asserção denuncia.
-- ---------------------------------------------------------------------------
SELECT CASE WHEN count(*) FILTER (WHERE NOT observado) = 0
            THEN 'ASSERCAO 4 OK: as ' || count(*) || ' regras de cargo sao todas de valor observado'
            ELSE 'ATENCAO: ' || count(*) FILTER (WHERE NOT observado)
                 || ' regra(s) de cargo nao vieram de valor observado — confirmar a origem'
       END AS resultado
FROM cargo_grupo_regra;

-- ---------------------------------------------------------------------------
-- ASSERÇÃO 5 — o INVARIANTE das regras de teste, não a quantidade delas.
--
-- A primeira versão exigia exatamente 3 regras ativas. A migration 052
-- acrescentou uma quarta (seed_test) legitimamente, e a asserção passou a
-- falhar por um número que nunca foi a propriedade que importava. Foi o
-- QUARTO erro do mesmo tipo neste projeto: travar valor absoluto em vez do
-- invariante.
--
-- O invariante real do §1.6 é: toda regra ativa tem de ser AUDITÁVEL — nome,
-- campo, padrão e MOTIVO preenchidos. Uma regra sem motivo é exclusão
-- silenciosa com etapa extra, que é justamente o que o contrato proíbe. E o
-- número de regras pode e deve crescer conforme a base revela dado de teste
-- novo.
-- ---------------------------------------------------------------------------
SELECT CASE
  WHEN count(*) = 0 THEN '*** ASSERCAO 5 FALHOU: nenhuma regra de teste ativa — a exclusao de dado de teste esta desligada ***'
  WHEN count(*) FILTER (WHERE btrim(COALESCE(motivo,'')) = '') > 0
       THEN '*** ASSERCAO 5 FALHOU: ' || count(*) FILTER (WHERE btrim(COALESCE(motivo,'')) = '')
            || ' regra(s) ativa(s) sem motivo — exclusao nao auditavel, proibida pelo contrato 1.6 ***'
  WHEN count(*) FILTER (WHERE btrim(COALESCE(padrao,'')) = '') > 0
       THEN '*** ASSERCAO 5 FALHOU: regra ativa sem padrao ***'
  ELSE 'ASSERCAO 5 OK: as ' || count(*) || ' regras de teste ativas tem campo, padrao e motivo'
END AS resultado
FROM lead_teste_regra WHERE ativo;

-- ---------------------------------------------------------------------------
-- ASSERÇÃO 6 — tamanho por PALAVRA (migration 056). Valores reais que a
-- versão numérica da função não conseguia ler.
-- ---------------------------------------------------------------------------
SELECT CASE WHEN count(*) = 0
            THEN 'ASSERCAO 6 OK: os 5 casos de tamanho por palavra batem'
            ELSE '*** ASSERCAO 6 FALHOU: ' || count(*) || ' divergencia(s) ***'
       END AS resultado
FROM (VALUES
  ('Grande',                                   'grande'),
  ('Sou autônomo / Profissional independente', 'pequena'),
  ('Média',                                    'media'),
  ('Pequena',                                  'pequena'),
  -- Lixo real observado na base: informou algo ilegível. Continua
  -- nao_informado, e fn_qualidade_dados é quem expõe a diferença entre
  -- "não informou" e "não sabemos ler".
  ('ste',                                      'nao_informado')
) AS t(bruto, esperado)
WHERE fn_normalizar_tamanho_empresa(bruto) IS DISTINCT FROM esperado;
