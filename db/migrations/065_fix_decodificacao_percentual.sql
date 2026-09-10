-- db/migrations/065_fix_decodificacao_percentual.sql
-- Subtask 8.22 — corrige `fn_decodificar_utm`, que eu escrevi errado na 064.
--
-- ── O QUE ESTAVA ERRADO ───────────────────────────────────────────────────
-- Usei `convert_from(decode(replace(v, '%', '\x'), 'escape'), 'UTF8')`.
-- `decode(..., 'escape')` NÃO entende `\xHH` — o formato escape do Postgres
-- representa bytes como `\nnn` OCTAL. Então a conversão falhava sempre, e o
-- meu próprio bloco `EXCEPTION WHEN others THEN NULL` engolia a falha em
-- silêncio: a função devolvia a string com o `+` corrigido e os `%XX`
-- intactos, e o teste mostrou `%5BSB%5D CAMPANHA_WEBINAR` e `LinkedIn%20Ads`
-- passando batido.
--
-- Só apareceu porque eu testei a função contra os valores REAIS em vez de
-- confiar que ela funcionava. Um `EXCEPTION WHEN others THEN NULL` que
-- silencia a única coisa que a função precisa fazer é armadilha — a versão
-- nova só captura falha depois de tentar do jeito certo, e não mascara o
-- caminho principal.
--
-- ── A IMPLEMENTAÇÃO CORRETA, E POR QUE ELA É ASSIM ────────────────────────
-- Não dá para trocar `%XX` por `chr(x)` um a um: em UTF-8, um caractere
-- acentuado é DOIS bytes (`ú` = `%C3%BA`), e `chr()` por byte produziria
-- mojibake. A montagem tem de ser em nível de BYTE.
--
-- Então: tokeniza a string em "um `%XX`" ou "um caractere qualquer", converte
-- cada token para os seus bytes em hexadecimal, concatena tudo num `bytea` e
-- só então interpreta o conjunto como UTF-8. Assim sequências multibyte se
-- remontam corretamente.
--
-- `+` continua sendo trocado por espaço ANTES (x-www-form-urlencoded), para
-- que um `%2B` (mais literal) sobreviva.
--
-- Um `%` solto (não seguido de dois hexa) cai no ramo "caractere qualquer" e
-- é preservado — sem exceção, sem perda.

CREATE OR REPLACE FUNCTION fn_decodificar_utm(p_valor text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_valor IS NULL OR btrim(p_valor) = '' THEN NULL
    ELSE btrim(
      convert_from(
        CAST('\x' || COALESCE(string_agg(
          CASE
            -- Token `%XX`: os dois hexa JÁ são a representação do byte.
            WHEN t.tok ~ '^%[0-9a-fA-F]{2}$' THEN lower(substring(t.tok from 2 for 2))
            -- Qualquer outro caractere: pega os bytes UTF-8 dele.
            ELSE encode(convert_to(t.tok, 'UTF8'), 'hex')
          END, '' ORDER BY t.ord), '') AS bytea),
        'UTF8')
    )
  END
  FROM regexp_matches(replace(p_valor, '+', ' '), '%[0-9a-fA-F]{2}|.', 'g')
       WITH ORDINALITY AS m(arr, ord),
       LATERAL (SELECT m.arr[1] AS tok, m.ord AS ord) t;
$$;

COMMENT ON FUNCTION fn_decodificar_utm(text) IS
  'Decodifica valor de query string: `+` vira espaço (x-www-form-urlencoded) e `%XX` é resolvido em nível de BYTE, para que sequências UTF-8 multibyte (ex.: %C3%BA) se remontem corretamente — trocar %XX por chr() um a um produziria mojibake. Reescrita na migration 065: a versão da 064 usava decode(...,''escape''), que não entende %XX, e um EXCEPTION WHEN others silenciava a falha.';

-- ---------------------------------------------------------------------------
-- Verificação no próprio arquivo, contra os valores REAIS da base.
-- Falha aqui interrompe o apply — é o que faltou na 064.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
  v_falhas text := '';
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- bruto observado                                     esperado
      ('[SB]+CAMPANHA_WEBINAR',                              '[SB] CAMPANHA_WEBINAR'),
      ('%5BSB%5D+CAMPANHA_WEBINAR',                          '[SB] CAMPANHA_WEBINAR'),
      ('[SB] CAMPANHA_WEBINAR',                              '[SB] CAMPANHA_WEBINAR'),
      ('LinkedIn%20Ads',                                     'LinkedIn Ads'),
      ('Facebook%20Ads',                                     'Facebook Ads'),
      ('RD+Station',                                         'RD Station'),
      ('LOGMEIN_RESCUE-LICENCA-ECO_09_26_',                  'LOGMEIN_RESCUE-LICENCA-ECO_09_26_'),
      -- multibyte: a razao de a montagem ser em nivel de byte
      ('conte%C3%BAdo',                                      'conteúdo'),
      -- mais literal codificado tem de sobreviver ao tratamento do `+`
      ('a%2Bb',                                              'a+b'),
      -- porcento solto: preservado, sem excecao
      ('100%',                                               '100%'),
      ('desconto+de+50%25',                                  'desconto de 50%')
    ) AS t(bruto, esperado)
  LOOP
    IF fn_decodificar_utm(r.bruto) IS DISTINCT FROM r.esperado THEN
      v_falhas := v_falhas || format(E'\n  %L -> %L (esperado %L)',
                    r.bruto, fn_decodificar_utm(r.bruto), r.esperado);
    END IF;
  END LOOP;

  IF v_falhas <> '' THEN
    RAISE EXCEPTION 'fn_decodificar_utm falhou nos casos:%', v_falhas;
  END IF;
  RAISE NOTICE 'OK: os 11 casos de fn_decodificar_utm batem (inclui multibyte, %%2B e %% solto).';
END;
$$;
