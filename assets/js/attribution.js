// assets/js/attribution.js — camada de EXIBIÇÃO APENAS (spec.md §5.1).
// Renderiza a classificação e a razão JÁ calculadas pelo backend (Etapa A:
// já pré-calculadas no fixture curado; Etapa B: função/view SQL de
// db/migrations/*.sql) e devolvidas prontas por data-api.js. Este arquivo
// NÃO recalcula, NÃO reordena sinais e NÃO aplica fallback no cliente —
// se a razão vier ausente, exibe a lacuna (P-UI-6), nunca deduz uma.

const SEGMENTO_LABEL = { marketing: 'Marketing', comercial: 'Comercial', nao_atribuido: 'Não atribuído' };
const SEGMENTO_CLASSE = { marketing: 'mkt', comercial: 'com', nao_atribuido: 'na' };

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/**
 * Renderiza o badge de segmento. Se `atribuicao` ou `atribuicao.segmento`
 * vier ausente, exibe explicitamente que a classificação não chegou —
 * NUNCA assume "não atribuído" nem "comercial" por conta própria (essa
 * dedução é exatamente o bug que este épico existe para corrigir).
 * @param {object|null|undefined} atribuicao
 */
export function renderBadge(atribuicao) {
  if (!atribuicao || !atribuicao.segmento) {
    return '<span class="badge na" title="Classificação não veio do backend nesta resposta"><span class="b-dot"></span>Sem classificação</span>';
  }
  const classe = SEGMENTO_CLASSE[atribuicao.segmento] ?? 'na';
  const label = SEGMENTO_LABEL[atribuicao.segmento] ?? atribuicao.segmento;
  return `<span class="badge ${classe}"><span class="b-dot"></span>${escapeHtml(label)}</span>`;
}

/**
 * Renderiza o bloco de razão auditável (NFR-7): sinal, confiança e o texto
 * pronto para leitura. Se `razao_legivel` vier ausente, isso é uma FALHA
 * de NFR-7 e deve aparecer como tal — nunca compor uma razão no cliente a
 * partir de outros campos.
 * @param {object|null|undefined} atribuicao
 */
export function renderRazao(atribuicao) {
  if (!atribuicao) {
    return '<div class="attr-reason">Nenhum dado de atribuição retornado para este lead.</div>';
  }
  if (!atribuicao.razao_legivel) {
    return '<div class="attr-reason">⚠️ Classificação presente, mas sem razão auditável (NFR-7 não satisfeito nesta resposta) — reportar como falha, não presumir o motivo.</div>';
  }
  const confSpan = atribuicao.confianca
    ? `<span class="mono-sm" style="font-family:var(--mono);font-size:11.5px;color:var(--muted)">${escapeHtml(atribuicao.sinal_id ?? '')} · confiança ${escapeHtml(atribuicao.confianca)}</span>`
    : '';
  return `
    <div class="attr-box-top">${renderBadge(atribuicao)}${confSpan}</div>
    <div class="attr-reason">${atribuicao.razao_legivel}</div>
  `;
  // Nota: razao_legivel já vem em HTML simples (<b>, <code>) do backend —
  // ver docs/architecture/data-contract.md §2.1. Não escapar aqui
  // apagaria a formatação que o próprio contrato define como parte do
  // conteúdo, não como entrada de usuário não confiável.
}

/**
 * Renderiza o aviso de vínculo de identidade "provável"/"conflito" (EC-7),
 * quando presente. Ausência (null) é o caso comum e não gera nenhum HTML.
 * @param {object|null|undefined} vinculo
 */
export function renderVinculoIdentidade(vinculo) {
  if (!vinculo) return '';
  const rotulo = vinculo.status === 'conflito' ? 'Conflito de identidade' : 'Vínculo de identidade provável';
  return `
    <div class="attr-vinculo">
      <span>⚠️</span>
      <span><b>${rotulo}</b> — ${escapeHtml(vinculo.explicacao)}</span>
    </div>
  `;
}
