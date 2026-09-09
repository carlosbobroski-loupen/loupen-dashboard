// assets/js/views/relacionamentos.js — subtask 5.11: navegação entre
// entidades relacionadas (campanha → leads → oportunidades).
//
// LIMITE CONHECIDO E DECLARADO (não é um bug escondido): o contrato atual
// (data-contract.md §1/§2) só expõe oportunidades ANINHADAS dentro de um
// lead — não existe endpoint de campanhas/oportunidades avulso. Isso torna
// AC-4.1 (campanha → leads → oportunidades) implementável como um PIVÔ de
// filtro sobre a mesma lista de leads (o que este arquivo faz), mas torna
// AC-4.2 na direção inversa — "de uma oportunidade sem lead convertido
// associado, navegar até a origem" — IRREPRESENTÁVEL com os dados de hoje,
// porque uma oportunidade nesse contrato só existe se já estiver pendurada
// em algum lead da lista. Reportado ao usuário como gap real da Etapa A,
// não escondido nem simulado com dado inventado (Constitution Artigo IV).

import { buscarLead } from '../data-api.js';

/**
 * Filtra `lista` (list items de listarLeads) para os que pertencem à
 * `campanhaId` informada. Exige buscar o detalhe de cada item da lista
 * porque `campanha_bruta`/`cadeia_campanha` só existem no bloco
 * `atribuicao` do detalhe (§2), não no list item (§1) — ver a mesma nota
 * em data-api.js sobre o limite de filtro por campanha na Etapa A.
 * @param {Array<object>} lista
 * @param {string|undefined} campanhaId
 */
export async function aplicarFiltroCampanha(lista, campanhaId) {
  if (!campanhaId) return lista;
  const detalhes = await Promise.all(lista.map((l) => buscarLead(l.id)));
  return lista.filter((l, i) => {
    const d = detalhes[i];
    if (!d) return false;
    const bruta = d.overview.atribuicao?.campanha_bruta;
    const cadeia = d.related?.cadeia_campanha ?? [];
    return bruta === campanhaId || cadeia.includes(campanhaId);
  });
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/**
 * Renderiza o breadcrumb "Campanha: X" acima da lista quando um filtro de
 * campanha está ativo, com caminho de volta preservado (AC-4.1: "sem sair
 * da superfície, com caminho de volta preservado").
 * @param {string|undefined} campanhaId
 * @param {() => void} aoLimpar
 */
export function renderBreadcrumbCampanha(campanhaId, aoLimpar) {
  let el = document.getElementById('crm-campanha-breadcrumb');
  if (!campanhaId) {
    if (el) el.remove();
    return;
  }
  if (!el) {
    el = document.createElement('div');
    el.id = 'crm-campanha-breadcrumb';
    el.style.cssText = 'display:flex;align-items:center;gap:8px;margin-bottom:12px;font-size:13px;color:var(--muted)';
    const grid = document.getElementById('crm-work-grid');
    grid.parentNode.insertBefore(el, grid);
  }
  el.innerHTML = `<i class="ti ti-speakerphone"></i> Filtrando por campanha: <b style="color:var(--text)">${escapeHtml(campanhaId)}</b> <button id="crm-campanha-voltar" style="background:none;border:1px solid var(--border2);color:var(--muted);padding:3px 9px;border-radius:6px;font-size:12px;cursor:pointer;margin-left:4px"><i class="ti ti-arrow-left"></i> Voltar para todos os leads</button>`;
  document.getElementById('crm-campanha-voltar').onclick = aoLimpar;
}
