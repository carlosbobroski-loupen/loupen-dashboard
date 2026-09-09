-- db/migrations/035_view_cobertura_atribuicao.sql
-- Subtask 3.14. D14: a PRIMEIRA métrica a entregar, antes de qualquer
-- métrica de performance — pré-requisito de confiança das demais. Com
-- ~85% de não atribuição observado historicamente em canais sem sinal
-- forte, publicar CAC ou taxa de conversão antes desta view produz número
-- que parece preciso e não é.
--
-- ESCOPO REAL DECLARADO: AC-12.1/AC-12.2 originais são especificamente
-- sobre leads WhatsApp/SDR IA (FR-12), e FR-12 está DEFERRED (decisão do
-- usuário, 2026-09-04) — esta sessão não ingere WhatsApp. A view abaixo
-- generaliza o ESPÍRITO de AC-12.2 (cobertura exposta como métrica de
-- qualidade de dados) para TODOS os canais já classificados, sem
-- reativar o escopo WhatsApp que foi deliberadamente tirado.

CREATE OR REPLACE VIEW view_cobertura_atribuicao AS
SELECT
  COALESCE(loc.categoria, 'Sem categoria') AS canal,
  date_trunc('month', loc.classified_at) AS periodo,
  count(*) AS total,
  count(*) FILTER (WHERE loc.segmento <> 'NaoAtribuido') AS atribuidos,
  count(*) FILTER (WHERE loc.segmento = 'NaoAtribuido') AS nao_atribuidos,
  ROUND(100.0 * count(*) FILTER (WHERE loc.segmento <> 'NaoAtribuido') / NULLIF(count(*), 0), 1) AS pct_cobertura
FROM lead_origin_classification loc
WHERE loc.valid_to IS NULL
GROUP BY 1, 2;

COMMENT ON VIEW view_cobertura_atribuicao IS
  'D14/I5: cobertura de atribuição por canal (categoria) e período (mês), com pct_cobertura sempre exposto (nunca omitido) quando há base — trava de 5.14: nenhuma métrica de CAC por canal pode ser publicada fora desta mesma superfície.';
