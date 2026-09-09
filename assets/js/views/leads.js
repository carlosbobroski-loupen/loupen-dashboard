// assets/js/views/leads.js — aba de Leads com os filtros do contrato
// revisado (data-contract.md §1). Reescrita em 2026-09-09.
//
// O QUE MUDOU E POR QUÊ
//
// 1. As opções de cada filtro vêm de /api/meta (fn_opcoes_filtro), com a
//    contagem de leads ao lado. NÃO existe mais enum de valores embutido
//    aqui. A versão anterior tinha `SEGMENTOS_TODOS` hardcoded, e essa
//    mesma prática — a interface decidindo quais valores existem — é a raiz
//    do erro que produziu os 4 filtros inventados da v1 do contrato.
//
// 2. Todo filtro é resolvido no SERVIDOR. A versão anterior filtrava período
//    e campanha no cliente, sobre a página já retornada: com paginação isso
//    descartava linhas em vez de reconsultar, e o total exibido não
//    correspondia ao filtro aplicado.
//
// 3. Os KPIs saem da própria lista. A versão anterior buscava o DETALHE de
//    cada lead para calcular KPI (`_carregarDetalhesParaKpis`) — 1 chamada
//    por lead. O próprio comentário dela dizia que não era o padrão a
//    seguir em escala. Com 474 leads reais seriam 474 chamadas por render.
//    Removido.
//
// 4. Onde o grão é multiplicado (um lead em várias origens/tags), a
//    interface ROTULA. É obrigação do contrato §1.7: sem o rótulo alguém
//    soma a coluna e conclui que o número está errado.

import { listarLeads, obterOpcoesFiltro } from '../data-api.js';
import { renderBadge } from '../attribution.js';
import { lerEstadoAtual, atualizarEstado, comoArray } from '../url-state.js';
import { renderPainelLead, limparPainel } from './lead-detalhe.js';
import { aplicarFiltroCampanha, renderBreadcrumbCampanha } from './relacionamentos.js';

// Dimensões de filtro. `rotulo` é o que aparece na tela; `chave` é o nome no
// contrato, na URL e na query. A ordem aqui é a ordem na barra de filtros:
// as de maior cobertura medida primeiro, porque são as que valem usar.
const DIMENSOES = [
  { chave: 'trimestre',        rotulo: 'Trimestre',  icone: 'ti-calendar' },
  { chave: 'origem_conversao', rotulo: 'Origem de conversão', icone: 'ti-click', grao: 'multiplicado' },
  { chave: 'tags',             rotulo: 'Tags',       icone: 'ti-tags', grao: 'multiplicado' },
  { chave: 'cargo_grupo',      rotulo: 'Cargo',      icone: 'ti-briefcase' },
  { chave: 'atendido_por',     rotulo: 'Atendido por', icone: 'ti-headset' },
  { chave: 'tamanho_empresa',  rotulo: 'Tamanho',    icone: 'ti-building' },
  { chave: 'plataforma',       rotulo: 'Plataforma', icone: 'ti-speakerphone' },
  { chave: 'campanha_midia',   rotulo: 'Campanha paga', icone: 'ti-currency-dollar' },
  { chave: 'estagio_funil',    rotulo: 'Estágio',    icone: 'ti-filter' },
];

// Rótulos legíveis para valores que chegam em snake_case da API. Só tradução
// de apresentação — a chave real nunca muda, para que a URL siga estável.
const ROTULO_VALOR = {
  marketing: 'Marketing', comercial: 'Comercial', parceiro: 'Parceiro',
  nao_atribuido: 'Não atribuído', nao_informado: 'Não informado',
  c_level: 'C-level', diretoria: 'Diretoria', gerencia: 'Gerência',
  coordenacao: 'Coordenação', analista: 'Analista', consultor: 'Consultor',
  operacional: 'Operacional', outro_declarado: 'Outro (declarado)',
  outros: 'Sem regra de cargo',
  pequena: 'Pequena (1–99)', media: 'Média (100–999)', grande: 'Grande (1.000+)',
};
const rot = (v) => ROTULO_VALOR[v] ?? v;

let _opcoes = null;          // cache de /api/meta nesta sessão de view
let _opcoesErro = null;

// ---------------------------------------------------------------------------
// KPIs — calculados sobre a lista já retornada, sem chamada extra
// ---------------------------------------------------------------------------
function _renderKpis(lista, totalFiltrado, totalGeral) {
  const txt = (id, v) => { const el = document.getElementById(id); if (el) el.textContent = v; };

  txt('crm-kpi-total', totalFiltrado.toLocaleString('pt-BR'));
  txt('crm-kpi-total-foot', totalFiltrado === totalGeral
    ? 'sem filtro aplicado'
    : `de ${totalGeral.toLocaleString('pt-BR')} no total`);

  // Somas sobre a PÁGINA carregada. Quando há mais linhas que a página, o
  // rodapé diz isso — um número parcial rotulado é honesto; um número
  // parcial apresentado como total, não.
  const conv = lista.reduce((s, l) => s + (l.qtd_conversoes || 0), 0);
  const multi = lista.filter((l) => (l.qtd_conversoes || 0) > 1).length;
  const paga = lista.filter((l) => l.campanha_midia || l.plataforma).length;
  const parcial = lista.length < totalFiltrado;
  const nota = parcial ? `nos ${lista.length} carregados` : `nos ${lista.length} leads`;

  txt('crm-kpi-conv', conv.toLocaleString('pt-BR'));
  txt('crm-kpi-conv-foot', lista.length
    ? `${(conv / lista.length).toFixed(1)} por lead · ${nota}`
    : '—');

  txt('crm-kpi-multi', multi.toLocaleString('pt-BR'));
  txt('crm-kpi-multi-foot', lista.length
    ? `${Math.round((multi / lista.length) * 100)}% ${nota}`
    : '—');

  txt('crm-kpi-paga', paga.toLocaleString('pt-BR'));
  txt('crm-kpi-paga-foot', lista.length
    ? `${Math.round((paga / lista.length) * 100)}% ${nota} · único eixo com ROI`
    : '—');
}

// ---------------------------------------------------------------------------
// Controles de filtro
// ---------------------------------------------------------------------------
function _pillsSegmento(estado) {
  const el = document.getElementById('crm-pills-segmento');
  if (!el) return;
  const opcoes = _opcoes?.segmento ?? [];
  if (opcoes.length === 0) {
    el.innerHTML = '<span class="mono-sm" style="color:var(--dim)">sem dado</span>';
    return;
  }
  const ativos = comoArray(estado.segmento);
  const classePor = { marketing: 'seg-mkt', comercial: 'seg-com', parceiro: 'seg-com', nao_atribuido: 'seg-na' };
  el.innerHTML = opcoes.map((o) => {
    const on = ativos.length === 0 || ativos.includes(o.valor);
    return `<button class="seg-pill ${classePor[o.valor] ?? 'seg-na'}" data-on="${on ? 1 : 0}" data-seg="${o.valor}">
      <span class="b-dot" style="width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block"></span>${rot(o.valor)}
      <span class="mono-sm" style="opacity:.65;margin-left:2px">${o.leads}</span>
    </button>`;
  }).join('');
  // As pills são renderizadas TODAS ACESAS quando não há filtro, porque
  // ausência de filtro significa "sem restrição". Então clicar numa pill tem
  // de DESLIGÁ-LA a partir desse baseline — não selecionar só ela. Semântica
  // diferente da dos checkboxes do dropdown, e de propósito: os dois
  // controles têm aparência diferente e a interação segue a aparência.
  const todos = opcoes.map((o) => String(o.valor));
  el.querySelectorAll('[data-seg]').forEach((btn) => {
    btn.onclick = () => {
      const seg = btn.dataset.seg;
      const atuais = comoArray(lerEstadoAtual().segmento);
      const baseline = atuais.length ? atuais : todos;
      let novos = baseline.includes(seg)
        ? baseline.filter((s) => s !== seg)
        : [...new Set([...baseline, seg])];
      // Desligar a última pill acesa não pode zerar a tela sem saída: volta a
      // "sem restrição", que é o mesmo estado visual de todas acesas.
      if (novos.length === 0 || novos.length === todos.length) novos = [];
      _aplicarFiltro({ segmento: novos.length ? novos : undefined });
    };
  });
}

function _dropdowns(estado) {
  const el = document.getElementById('crm-filter-bar-2');
  if (!el) return;

  if (_opcoesErro) {
    el.innerHTML = `<span class="mono-sm" style="color:var(--red)">Filtros indisponíveis: ${_opcoesErro}</span>`;
    return;
  }

  const blocos = DIMENSOES.map((d) => {
    const opcoes = _opcoes?.[d.chave] ?? [];
    // Regra de ouro: dimensão sem dado NÃO é oferecida. Melhor ausente do que
    // presente e sempre vazia — foi assim que `cf_atuacao_da_empresa` (0,4%)
    // quase entrou como filtro.
    if (opcoes.length === 0) return '';

    const ativos = comoArray(estado[d.chave]);
    const n = ativos.length;
    const marcado = n > 0;
    const itens = opcoes.map((o) => `
      <label style="display:flex;align-items:center;gap:8px;padding:5px 9px;font-size:12px;cursor:pointer;border-radius:5px" onmouseover="this.style.background='var(--surface2)'" onmouseout="this.style.background='none'">
        <input type="checkbox" data-dim="${d.chave}" value="${String(o.valor).replace(/"/g, '&quot;')}" ${ativos.includes(String(o.valor)) ? 'checked' : ''}>
        <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${String(o.valor).replace(/"/g, '&quot;')}">${rot(o.valor)}</span>
        <span class="mono-sm" style="color:var(--dim)">${o.leads}</span>
      </label>`).join('');

    return `
      <details class="crm-dd" style="position:relative">
        <summary style="list-style:none;cursor:pointer;display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:6px 10px;border-radius:7px;border:1px solid ${marcado ? 'var(--blue)' : 'var(--border2)'};background:${marcado ? 'var(--blue-dim)' : 'none'};color:${marcado ? 'var(--blue)' : 'var(--muted)'}">
          <i class="ti ${d.icone}"></i>${d.rotulo}${marcado ? ` · ${n}` : ''}
          <i class="ti ti-chevron-down" style="font-size:11px;opacity:.7"></i>
        </summary>
        <div style="position:absolute;z-index:40;top:calc(100% + 4px);left:0;min-width:236px;max-width:320px;max-height:288px;overflow-y:auto;background:var(--surface);border:1px solid var(--border2);border-radius:9px;padding:6px;box-shadow:0 8px 28px -12px rgba(0,0,0,.45)">
          ${d.grao === 'multiplicado' ? `<div class="mono-sm" style="color:var(--dim);padding:4px 9px 6px;line-height:1.4;border-bottom:1px solid var(--border2);margin-bottom:4px">Um lead pode estar em mais de um valor — a soma passa do total.</div>` : ''}
          ${itens}
        </div>
      </details>`;
  }).join('');

  el.innerHTML = blocos || '<span class="mono-sm" style="color:var(--dim)">Nenhuma dimensão com dado disponível.</span>';

  el.querySelectorAll('input[data-dim]').forEach((cb) => {
    cb.onchange = () => _alternarValor(cb.dataset.dim, cb.value);
  });
  // Fecha os outros dropdowns ao abrir um — sem isso a tela vira uma pilha
  // de painéis sobrepostos.
  el.querySelectorAll('details.crm-dd').forEach((dd) => {
    dd.addEventListener('toggle', () => {
      if (!dd.open) return;
      el.querySelectorAll('details.crm-dd').forEach((o) => { if (o !== dd) o.open = false; });
    });
  });
}

function _renderChipsAtivos(estado) {
  const el = document.getElementById('crm-active-chips');
  if (!el) return;
  const chips = [];

  const addChips = (chave, rotuloDim) => {
    for (const v of comoArray(estado[chave])) {
      chips.push(`<span class="active-chip" data-dim="${chave}" data-val="${String(v).replace(/"/g, '&quot;')}" style="display:inline-flex;align-items:center;gap:6px;font-size:11px;background:var(--blue-dim);color:var(--blue);padding:4px 10px;border-radius:6px;font-weight:500;cursor:pointer">${rotuloDim}: ${rot(v)} <i class="ti ti-x"></i></span>`);
    }
  };
  addChips('segmento', 'Segmento');
  for (const d of DIMENSOES) addChips(d.chave, d.rotulo);

  if (estado.periodo_inicio || estado.periodo_fim) {
    chips.push(`<span class="active-chip" data-dim="periodo" style="display:inline-flex;align-items:center;gap:6px;font-size:11px;background:var(--blue-dim);color:var(--blue);padding:4px 10px;border-radius:6px;font-weight:500;cursor:pointer">Período: ${estado.periodo_inicio ?? '…'} → ${estado.periodo_fim ?? '…'} <i class="ti ti-x"></i></span>`);
  }
  if (estado.incluir_teste) {
    chips.push(`<span class="active-chip" data-dim="incluir_teste" style="display:inline-flex;align-items:center;gap:6px;font-size:11px;background:var(--amber-dim,var(--surface2));color:var(--amber,var(--muted));padding:4px 10px;border-radius:6px;font-weight:500;cursor:pointer">Incluindo dados de teste <i class="ti ti-x"></i></span>`);
  }

  el.innerHTML = chips.join('');
  el.querySelectorAll('[data-dim]').forEach((chip) => {
    chip.onclick = () => {
      const dim = chip.dataset.dim;
      if (dim === 'periodo') return _aplicarFiltro({ periodo_inicio: undefined, periodo_fim: undefined });
      if (dim === 'incluir_teste') return _aplicarFiltro({ incluir_teste: undefined });
      _alternarValor(dim, chip.dataset.val);
    };
  });
}

// ---------------------------------------------------------------------------
// Lista
// ---------------------------------------------------------------------------
function _filtrosDoEstado(estado) {
  const f = {};
  for (const chave of ['segmento', ...DIMENSOES.map((d) => d.chave)]) {
    const v = comoArray(estado[chave]);
    if (v.length) f[chave] = v;
  }
  if (estado.periodo_inicio) f.periodo_inicio = estado.periodo_inicio;
  if (estado.periodo_fim) f.periodo_fim = estado.periodo_fim;
  if (estado.incluir_teste) f.incluir_teste = true;
  // `campanha` é o pivô campanha→leads (AC-4.1): casa contra valor_bruto da
  // atribuição. NÃO é `campanha_midia` (eixo B) — confundir os dois foi um
  // erro real desta reescrita, pego pelos specs.
  if (estado.campanha) f.campanha = estado.campanha;
  f.limit = 200;
  return f;
}

function _renderEmptyState(resumo) {
  const el = document.getElementById('crm-empty-state');
  el.style.display = 'block';
  el.innerHTML = `
    <div class="empty-state">
      <div class="es-title">Nenhum lead encontrado</div>
      <div>${resumo}</div>
      <button onclick="document.getElementById('crm-filter-clear').click()" style="margin-top:10px;background:var(--surface2);border:1px solid var(--border2);color:var(--text);padding:6px 12px;border-radius:7px;font-size:12px;cursor:pointer">Limpar filtros</button>
    </div>`;
}

async function _renderLista(estado) {
  const tbody = document.getElementById('crm-lead-rows');
  const emptyEl = document.getElementById('crm-empty-state');
  const filtros = _filtrosDoEstado(estado);

  let lista;
  try {
    lista = await listarLeads(filtros);
    // Pivô campanha→leads no modo MOCK: o fixture não tem `valor_bruto` na
    // lista (só no detalhe), então o recorte por campanha continua sendo
    // feito no cliente, como na Etapa A. No modo real o servidor já filtrou
    // (fn_search_leads v3), e esta chamada é um no-op — ela devolve a lista
    // inteira quando não encontra o que recortar.
    if (estado.campanha) {
      const recortada = await aplicarFiltroCampanha(lista, estado.campanha);
      if (recortada.length !== lista.length) {
        const total = lista.total;
        lista = recortada;
        lista.total = Math.min(Number(total ?? recortada.length), recortada.length);
      }
    }
  } catch (e) {
    tbody.innerHTML = '';
    // INT-1: erro NÃO apaga o filtro aplicado.
    _renderEmptyState(`Falha ao carregar: ${e.message}. Os filtros continuam aplicados — tente novamente.`);
    return;
  }

  const totalFiltrado = Number(lista.total ?? lista.length);
  const totalGeral = _opcoes?.totais?.leads ?? totalFiltrado;

  document.getElementById('crm-row-count').textContent =
    lista.length < totalFiltrado
      ? `${lista.length} de ${totalFiltrado.toLocaleString('pt-BR')}`
      : `${totalFiltrado.toLocaleString('pt-BR')}`;

  if (lista.length === 0) {
    tbody.innerHTML = '';
    // INT-1: nunca "0" sem contexto — o resumo diz QUAL combinação vazia.
    const ativos = [];
    for (const chave of ['segmento', ...DIMENSOES.map((d) => d.chave)]) {
      const v = comoArray(estado[chave]);
      if (v.length) {
        const dim = DIMENSOES.find((d) => d.chave === chave);
        ativos.push(`${dim?.rotulo ?? 'Segmento'}: ${v.map(rot).join(' ou ')}`);
      }
    }
    if (estado.campanha) ativos.push(`Campanha: ${estado.campanha}`);
    _renderEmptyState(ativos.length
      ? `Nenhum lead satisfaz <strong>todos</strong> estes critérios ao mesmo tempo:<br>${ativos.join('<br>')}`
      : 'A base não tem leads para mostrar.');
    _renderKpis([], 0, totalGeral);
    return;
  }
  emptyEl.style.display = 'none';

  tbody.innerHTML = lista.map((l) => {
    const tags = (l.tags || []).slice(0, 2)
      .map((t) => `<span class="mono-sm" style="background:var(--surface2);color:var(--muted);padding:1px 5px;border-radius:4px;margin-right:3px">${t}</span>`).join('');
    const maisTags = (l.tags || []).length > 2 ? `<span class="mono-sm" style="color:var(--dim)">+${l.tags.length - 2}</span>` : '';
    const origem = l.origem_conversao ?? '—';
    return `
    <tr data-lead-row="${l.id}" style="cursor:pointer" class="${estado.lead === l.id ? 'sel' : ''}">
      <td>
        <div style="font-weight:600">${l.nome ?? '—'}${l.is_teste ? ' <span class="mono-sm" style="color:var(--amber,var(--dim))" title="Marcado como dado de teste — visível porque você pediu explicitamente.">(teste)</span>' : ''}</div>
        <div class="t-sub">${l.empresa ?? '—'}</div>
        <div style="margin-top:3px">${tags}${maisTags}</div>
      </td>
      <td>
        <div style="max-width:210px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${origem}">${origem}</div>
        <div class="t-sub">${renderBadge({ segmento: l.segmento })}</div>
      </td>
      <td><div>${rot(l.cargo_grupo)}</div><div class="t-sub" title="${l.cargo ?? ''}">${l.cargo ?? '—'}</div></td>
      <td>${rot(l.tamanho_empresa)}</td>
      <td class="mono-sm" style="text-align:right;font-variant-numeric:tabular-nums">${l.qtd_conversoes ?? 0}</td>
      <td class="mono-sm">${(l.data_conversao ?? l.data_criacao ?? '').slice(0, 10) || '—'}</td>
    </tr>`;
  }).join('');

  tbody.querySelectorAll('[data-lead-row]').forEach((tr) => {
    tr.onclick = () => _aplicarFiltro({ lead: tr.dataset.leadRow });
  });

  _renderKpis(lista, totalFiltrado, totalGeral);
}

// ---------------------------------------------------------------------------
// Estado
// ---------------------------------------------------------------------------
function _aplicarFiltro(patch) {
  const novo = { ...lerEstadoAtual(), view: 'leads-crm', ...patch };
  Object.keys(novo).forEach((k) => (novo[k] === undefined || novo[k] === '') && delete novo[k]);
  atualizarEstado(novo);
  renderViewLeadsCrm();
}

// Alterna um valor dentro de uma dimensão. Ausência da dimensão significa
// "sem restrição" — nunca "nenhum selecionado". Por isso desmarcar o último
// valor LIMPA a dimensão em vez de produzir uma lista vazia que não traria
// nada.
function _alternarValor(dimensao, valor) {
  const atuais = comoArray(lerEstadoAtual()[dimensao]);
  const novos = atuais.includes(valor)
    ? atuais.filter((v) => v !== valor)
    : [...atuais, valor];
  _aplicarFiltro({ [dimensao]: novos.length ? novos : undefined });
}

const btnLimpar = document.getElementById('crm-filter-clear');
if (btnLimpar) {
  btnLimpar.onclick = () => {
    atualizarEstado({ view: 'leads-crm' });
    renderViewLeadsCrm();
  };
}

/** Ponto de entrada — chamado quando a view é exibida (ver app.js). */
export async function renderViewLeadsCrm() {
  const estado = lerEstadoAtual();

  if (_opcoes === null && _opcoesErro === null) {
    try {
      // Vem de /api/meta no modo real e do próprio fixture no modo mock —
      // nos dois casos DO DADO, nunca de enum embutido aqui.
      _opcoes = await obterOpcoesFiltro();
      if (_opcoes === null) _opcoesErro = 'backend não devolveu as opções de filtro';
    } catch (e) {
      _opcoesErro = e.message;
    }
  }

  _pillsSegmento(estado);
  _dropdowns(estado);
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
