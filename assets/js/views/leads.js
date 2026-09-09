// assets/js/views/leads.js — subtask 5.9: view /leads-crm com filtros
// combináveis por interseção (AC-1.1), resumo dos filtros ativos e estado
// vazio explícito (INT-1). Importa lead-detalhe.js (5.10) e
// relacionamentos.js (5.11) diretamente como ES modules — sem namespace
// global, cada módulo expõe só o que os outros dois precisam chamar.

import { listarLeads } from '../data-api.js';
import { renderBadge } from '../attribution.js';
import { lerEstadoAtual, atualizarEstado, comoArray } from '../url-state.js';
import { renderPainelLead, limparPainel } from './lead-detalhe.js';
import { aplicarFiltroCampanha, renderBreadcrumbCampanha } from './relacionamentos.js';

const SEGMENTOS_TODOS = ['marketing', 'comercial', 'nao_atribuido'];
const SEGMENTO_LABEL = { marketing: 'Marketing', comercial: 'Comercial', nao_atribuido: 'Não atribuído' };

async function _carregarDetalhesParaKpis(listaAtual) {
  // Nota de honestidade (Etapa A): calcular KPIs exige o bloco `atribuicao`,
  // que só vem no detalhe (§2), não na lista (§1) — o contrato não expõe um
  // endpoint de agregado (data-contract.md §4). Buscar o detalhe de cada
  // lead da lista funciona no fixture (13 registros); NÃO é o padrão que a
  // Etapa B deve seguir em escala — lá isso é uma query agregada no banco,
  // não N chamadas de detalhe. Registrado aqui como limite conhecido da
  // Etapa A, não como arquitetura a copiar.
  const { buscarLead } = await import('../data-api.js');
  const detalhes = await Promise.all(listaAtual.map((l) => buscarLead(l.id)));
  return detalhes.filter(Boolean);
}

function _renderKpis(listaFiltrada, detalhes) {
  document.getElementById('crm-kpi-total').textContent = listaFiltrada.length;

  const semSeed = detalhes.filter((d) => !d._seed_nota);
  const comSinal = semSeed.filter((d) => d.overview.atribuicao?.sinal_id && d.overview.atribuicao.sinal_id !== 'S6');
  const cobertura = semSeed.length ? Math.round((comSinal.length / semSeed.length) * 100) : 0;
  document.getElementById('crm-kpi-cobertura').textContent = semSeed.length ? `${cobertura}%` : '—';

  const comOport = detalhes.filter((d) => d.related.oportunidade !== null).length;
  document.getElementById('crm-kpi-oport').textContent = comOport;

  const vinculos = detalhes.filter((d) => d.overview.vinculo_identidade).length;
  document.getElementById('crm-kpi-vinculos').textContent = Math.round(vinculos / 2); // pares
}

function _renderChipsAtivos(estado) {
  const el = document.getElementById('crm-active-chips');
  const segmentosAtivos = comoArray(estado.segmento);
  const chips = [];
  if (segmentosAtivos.length > 0 && segmentosAtivos.length < SEGMENTOS_TODOS.length) {
    for (const s of segmentosAtivos) {
      chips.push(`<span class="active-chip" data-remove-seg="${s}" style="display:inline-flex;align-items:center;gap:6px;font-size:11px;background:var(--blue-dim);color:var(--blue);padding:4px 10px;border-radius:6px;font-weight:500;cursor:pointer">Segmento: ${SEGMENTO_LABEL[s]} <i class="ti ti-x"></i></span>`);
    }
  }
  el.innerHTML = chips.join('');
  el.querySelectorAll('[data-remove-seg]').forEach((chip) => {
    chip.onclick = () => {
      const seg = chip.dataset.removeSeg;
      const atuais = comoArray(lerEstadoAtual().segmento);
      const novos = atuais.length > 0 ? atuais.filter((s) => s !== seg) : SEGMENTOS_TODOS.filter((s) => s !== seg);
      _aplicarFiltro({ segmento: novos.length === SEGMENTOS_TODOS.length ? undefined : novos });
    };
  });
}

function _renderEmptyState(motivoResumo) {
  document.getElementById('crm-empty-state').style.display = 'block';
  document.getElementById('crm-empty-state').innerHTML = `
    <div class="empty-state">
      <div class="es-title">Nenhum lead encontrado</div>
      <div>${motivoResumo}</div>
      <button onclick="document.getElementById('crm-filter-clear').click()" style="margin-top:10px;background:var(--surface2);border:1px solid var(--border2);color:var(--text);padding:6px 12px;border-radius:7px;font-size:12px;cursor:pointer">Limpar filtros</button>
    </div>`;
}

async function _renderLista(estado) {
  const filtros = {
    segmento: comoArray(estado.segmento).length ? comoArray(estado.segmento) : undefined,
  };
  let lista = await listarLeads(filtros);

  // Pivô campanha → leads (5.11/AC-4.1): filtra a MESMA lista pela campanha
  // ativa, sem precisar de uma view de campanhas separada — ver
  // relacionamentos.js para a justificativa desta escolha de escopo.
  lista = await aplicarFiltroCampanha(lista, estado.campanha);

  const tbody = document.getElementById('crm-lead-rows');
  const emptyEl = document.getElementById('crm-empty-state');
  const totalGeral = (await listarLeads({})).length;
  document.getElementById('crm-row-count').textContent = `${lista.length} de ${totalGeral}`;

  if (lista.length === 0) {
    tbody.innerHTML = '';
    const filtrosAtivos = [];
    if (comoArray(estado.segmento).length) filtrosAtivos.push(`segmento: ${comoArray(estado.segmento).map((s) => SEGMENTO_LABEL[s]).join(', ')}`);
    if (estado.campanha) filtrosAtivos.push(`campanha: ${estado.campanha}`);
    _renderEmptyState(filtrosAtivos.length ? `Nenhum lead bate com ${filtrosAtivos.join(' + ')}.` : 'A combinação de filtros não retornou nenhum lead.');
    _renderKpis([], []);
    return;
  }
  emptyEl.style.display = 'none';

  tbody.innerHTML = lista
    .map(
      (l) => `
    <tr data-lead-row="${l.id}" style="cursor:pointer" class="${estado.lead === l.id ? 'sel' : ''}">
      <td><div style="font-weight:600">${l.nome}${l._seed_nota ? ' <span class="mono-sm" style="color:var(--dim)" title="'+l._seed_nota+'">(exemplo)</span>' : ''}</div><div class="t-sub">${l.empresa ?? '—'}</div></td>
      <td>${renderBadge({ segmento: l.segmento })}</td>
      <td>${l.estagio_funil ?? '—'}</td>
      <td class="mono-sm">${l.data_criacao ? l.data_criacao.slice(0, 10) : '—'}</td>
    </tr>`
    )
    .join('');

  tbody.querySelectorAll('[data-lead-row]').forEach((tr) => {
    tr.onclick = () => _aplicarFiltro({ lead: tr.dataset.leadRow });
  });

  const detalhesParaKpi = await _carregarDetalhesParaKpis(lista);
  _renderKpis(lista, detalhesParaKpi);
}

function _aplicarFiltro(patch) {
  const estadoAtual = lerEstadoAtual();
  const novoEstado = { ...estadoAtual, view: 'leads-crm', ...patch };
  Object.keys(novoEstado).forEach((k) => novoEstado[k] === undefined && delete novoEstado[k]);
  atualizarEstado(novoEstado);
  renderViewLeadsCrm();
}

document.querySelectorAll('#crm-filter-bar .seg-pill').forEach((btn) => {
  btn.onclick = () => {
    const seg = btn.dataset.seg;
    const atuais = comoArray(lerEstadoAtual().segmento);
    const baseline = atuais.length ? atuais : SEGMENTOS_TODOS;
    const novos = baseline.includes(seg) && baseline.length > 1 ? baseline.filter((s) => s !== seg) : [...new Set([...baseline, seg])];
    _aplicarFiltro({ segmento: novos.length === SEGMENTOS_TODOS.length ? undefined : novos });
  };
});
document.getElementById('crm-filter-clear').onclick = () => {
  const estado = lerEstadoAtual();
  atualizarEstado({ view: 'leads-crm' });
  renderViewLeadsCrm();
};

/** Ponto de entrada — chamado quando a view é exibida (ver app.js). */
export async function renderViewLeadsCrm() {
  const estado = lerEstadoAtual();
  document.querySelectorAll('#crm-filter-bar .seg-pill').forEach((btn) => {
    const ativos = comoArray(estado.segmento).length ? comoArray(estado.segmento) : SEGMENTOS_TODOS;
    btn.dataset.on = ativos.includes(btn.dataset.seg) ? '1' : '0';
  });
  _renderChipsAtivos(estado);
  renderBreadcrumbCampanha(estado.campanha, () => _aplicarFiltro({ campanha: undefined }));
  await _renderLista(estado);

  if (estado.lead) {
    await renderPainelLead(estado.lead, estado);
  } else {
    limparPainel();
  }
}

window.addEventListener('popstate', () => {
  if (lerEstadoAtual().view === 'leads-crm' || window.viewAtiva === 'leads-crm') renderViewLeadsCrm();
});
