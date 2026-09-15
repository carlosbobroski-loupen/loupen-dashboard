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
//
// 5. (2026-09-15) A LISTA PASSOU A SER POR PESSOA, não por registro de origem.
//    Antes, quem existia no RD e no Salesforce aparecia DUAS vezes — uma linha
//    completa e uma vazia — e nada na tela dizia qual era qual. Eram 430 casos.
//    A lista agora lê `/api/pessoas` (fn_search_pessoas, migration 084), que
//    entrega uma linha por pessoa com o ARRAY de conversões do RD e o DESFECHO
//    comercial do Salesforce. `listarLeads` continua servindo a ficha, onde o
//    grão de registro é o certo — é lá que se abre um registro específico.
//
// 6. Existe BUSCA. O produto inteiro não tinha nenhum campo de busca, e por
//    isso achar um lead específico exigia filtrar e varrer a tabela com o olho.

import { listarLeads, obterPessoas, obterOpcoesFiltro } from '../data-api.js';
import { renderBadge } from '../attribution.js';
import { lerEstadoAtual, atualizarEstado, comoArray } from '../url-state.js';
import { renderPainelLead, limparPainel } from './lead-detalhe.js';
import { renderBreadcrumbCampanha } from './relacionamentos.js';

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
function _renderKpis(env) {
  const txt = (id, v) => { const el = document.getElementById(id); if (el) el.textContent = v; };
  const n = (v) => Number(v ?? 0).toLocaleString('pt-BR');
  const pessoas = env.pessoas || [];
  const total = Number(env.total ?? 0);

  txt('crm-kpi-total', n(total));
  txt('crm-kpi-total-foot', env.ocultos_lista_importada
    ? `${n(env.ocultos_lista_importada)} de lista importada fora da conta`
    : 'pessoas, não registros de origem');

  // As três somas abaixo são sobre a PÁGINA carregada, e o rodapé diz isso.
  // Número parcial rotulado é honesto; número parcial apresentado como total,
  // não — foi assim que o dashboard antigo divergiu da lista embaixo dele.
  const carregados = pessoas.length;
  const parcial = carregados < total;
  const nota = parcial ? `nos ${n(carregados)} carregados` : `nas ${n(carregados)} pessoas`;

  const conv = pessoas.reduce((s, p) => s + Number(p.qtd_conversoes || 0), 0);
  txt('crm-kpi-conv', n(conv));
  txt('crm-kpi-conv-foot', carregados ? `${(conv / carregados).toFixed(1)} por pessoa · ${nota}` : '—');

  const comOpp = pessoas.filter((p) => Number(p.qtd_oportunidades || 0) > 0).length;
  txt('crm-kpi-multi', n(comOpp));
  txt('crm-kpi-multi-foot', carregados
    ? `${Math.round((comOpp / carregados) * 100)}% ${nota}` : '—');

  const paga = pessoas.filter((p) => p.utm_campaign || p.plataforma).length;
  txt('crm-kpi-paga', n(paga));
  txt('crm-kpi-paga-foot', carregados
    ? `${Math.round((paga / carregados) * 100)}% ${nota} · único eixo com ROI` : '—');
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
  // O estado da URL guarda arrays (multi-seleção). `fn_search_pessoas` aceita
  // um valor por dimensão — mandamos o primeiro e a barra de chips continua
  // mostrando o que está ativo. Multi-seleção por dimensão volta quando a
  // função aceitar array; mandar só o primeiro em silêncio seria pior, então
  // a tela avisa (ver _renderChipsAtivos).
  const um = (chave) => comoArray(estado[chave])[0];
  const f = {};
  const seg = um('segmento');
  if (seg) f.segmento = ROTULO_VALOR[seg] ?? seg;
  for (const [estadoChave, apiChave] of [
    ['trimestre', 'trimestre'], ['cargo_grupo', 'cargo_grupo'],
    ['atendido_por', 'atendido_por'], ['estagio_funil', 'estagio_funil'],
    ['tamanho_empresa', 'tamanho_empresa'], ['plataforma', 'plataforma'],
    ['origem_conversao', 'origem_conversao'], ['tags', 'tag'],
  ]) {
    const v = um(estadoChave);
    if (v) f[apiChave] = v;
  }
  // Pivo campanha->leads (AC-4.1). `campanha` e parametro de primeira classe
  // em fn_search_pessoas desde a migration 087. Mandar no `busca` -- como esta
  // linha fazia -- devolvia ZERO para qualquer campanha, porque `busca` so casa
  // contra nome, empresa e e-mail.
  if (estado.campanha) f.campanha = estado.campanha;
  if (estado.busca) f.busca = estado.busca;
  if (estado.incluir_lista) f.incluir_lista = true;
  if (estado.so_com_oportunidade) f.so_com_oportunidade = true;
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

// Quantas pessoas já foram carregadas nesta combinação de filtro. Zera quando
// o filtro muda — "carregar mais" acumula, trocar de filtro recomeça.
let _carregadas = [];
let _chaveFiltro = null;

const FASE_ROTULO = {
  contato: 'Contato', qualificacao: 'Qualificação', reuniao: 'Reunião',
  negociacao: 'Negociação', ganho: 'Ganho', perdido: 'Perdido',
};
const FASE_COR = {
  contato: 'var(--dim)', qualificacao: 'var(--blue)', reuniao: 'var(--purple)',
  negociacao: 'var(--amber)', ganho: 'var(--green)', perdido: 'var(--red)',
};

// A jornada como pontos: um por conversão, na ordem. Com 367 pessoas de uma
// conversão só a coluna fica calma, e quem tem várias SALTA — que é o sinal
// que interessa. O texto embaixo nomeia as origens.
function _jornada(p) {
  const n = Number(p.qtd_conversoes || 0);
  if (!n) return '<span class="t-sub">sem conversão no RD</span>';
  const pagas = Number(p.qtd_conversoes_pagas || 0);
  const pontos = Array.from({ length: Math.min(n, 10) }, (_, i) =>
    `<span style="width:6px;height:6px;border-radius:50%;display:inline-block;background:${
      i < pagas ? 'var(--green)' : 'var(--muted)'}"></span>`).join('');
  const origens = (p.origens_conversao || []);
  const txt = origens.slice(0, 2).join(' · ') + (origens.length > 2 ? ` +${origens.length - 2}` : '');
  return `<div style="display:flex;gap:3px;align-items:center;margin-bottom:3px">${pontos}${
    n > 10 ? `<span class="mono-sm" style="color:var(--dim);margin-left:4px">+${n - 10}</span>` : ''}</div>
    <div class="t-sub" title="${origens.join(' · ')}" style="max-width:190px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${txt}</div>`;
}

// O desfecho comercial como barra de 5 segmentos. Comunica "onde parou" num
// relance, sem obrigar a ler um dos 29 nomes de estágio do Salesforce.
function _desfecho(p) {
  if (!Number(p.qtd_oportunidades || 0)) {
    return p.existe_no_salesforce
      ? '<span class="t-sub">no CRM, sem oportunidade</span>'
      : '<span class="t-sub" style="color:var(--dim)">só no RD Station</span>';
  }
  const ordem = Number(p.fase_ordem || 0);
  const fase = p.fase_mais_avancada;
  const cor = FASE_COR[fase] || 'var(--muted)';
  const segs = [1, 2, 3, 4, 5].map((i) =>
    `<span style="flex:1;height:5px;border-radius:2px;background:${i <= ordem ? cor : 'var(--surface2)'}"></span>`).join('');
  const extra = [];
  if (Number(p.qtd_ganhas || 0))   extra.push(`${p.qtd_ganhas} ganha(s)`);
  if (Number(p.qtd_perdidas || 0)) extra.push(`${p.qtd_perdidas} perdida(s)`);
  return `<div style="display:flex;gap:2px;margin-bottom:4px;min-width:90px">${segs}</div>
    <div style="font-size:11.5px;color:${cor};font-weight:500">${FASE_ROTULO[fase] ?? p.estagio_mais_avancado ?? 'sem fase'}</div>
    ${extra.length ? `<div class="t-sub">${extra.join(' · ')}</div>` : ''}`;
}

async function _renderLista(estado, { acumular = false } = {}) {
  const tbody = document.getElementById('crm-lead-rows');
  const emptyEl = document.getElementById('crm-empty-state');
  const filtros = _filtrosDoEstado(estado);
  const chave = JSON.stringify(filtros);

  if (!acumular || chave !== _chaveFiltro) { _carregadas = []; _chaveFiltro = chave; }

  let env;
  try {
    env = await obterPessoas({ ...filtros, limit: 50, offset: _carregadas.length });
  } catch (e) {
    tbody.innerHTML = '';
    // INT-1: erro NÃO apaga o filtro aplicado.
    _renderEmptyState(`Falha ao carregar: ${e.message}. Os filtros continuam aplicados — tente novamente.`);
    document.getElementById('crm-mais').style.display = 'none';
    return;
  }

  _carregadas = acumular ? [..._carregadas, ...(env.pessoas || [])] : (env.pessoas || []);
  const total = Number(env.total ?? 0);

  document.getElementById('crm-row-count').textContent =
    _carregadas.length < total
      ? `${_carregadas.length} de ${total.toLocaleString('pt-BR')}`
      : total.toLocaleString('pt-BR');

  if (!_carregadas.length) {
    tbody.innerHTML = '';
    // INT-1: o estado vazio NOMEIA cada filtro ativo. Nunca "0" sem contexto --
    // e nunca um filtro omitido da explicação, senão o usuário não sabe o que
    // soltar para voltar a ver linha.
    const ativos = [];
    if (estado.busca) ativos.push(`Busca: "${estado.busca}"`);
    if (estado.campanha) ativos.push(`Campanha: ${estado.campanha}`);
    for (const chaveDim of ['segmento', ...DIMENSOES.map((d) => d.chave)]) {
      const v = comoArray(estado[chaveDim]);
      if (v.length) {
        const dim = DIMENSOES.find((d) => d.chave === chaveDim);
        ativos.push(`${dim?.rotulo ?? 'Segmento'}: ${v.map(rot).join(' ou ')}`);
      }
    }
    _renderEmptyState(ativos.length
      ? `Nenhuma pessoa satisfaz <strong>todos</strong> estes critérios ao mesmo tempo:<br>${ativos.join('<br>')}`
      : 'A base não tem pessoas para mostrar.');
    document.getElementById('crm-mais').style.display = 'none';
    _renderKpis({ pessoas: [], total: 0, ocultos_lista_importada: env.ocultos_lista_importada });
    return;
  }
  emptyEl.style.display = 'none';

  tbody.innerHTML = _carregadas.map((p) => {
    // A ficha abre por source_id (/api/leads/{id}), NAO pelo id interno.
    const alvo = p.source_id_ficha;
    const fontes = (p.fontes || []).map((f) => `<span class="mono-sm" style="background:var(--surface2);color:var(--muted);padding:1px 5px;border-radius:4px;margin-right:3px">${f === 'rd_station' ? 'RD' : 'SF'}</span>`).join('');
    const lista = p.de_lista_importada
      ? '<span class="mono-sm" style="background:var(--amber-dim);color:var(--amber);padding:1px 5px;border-radius:4px" title="Lead de lista importada — conta como lead, mas sai do denominador das taxas.">lista</span>'
      : '';
    const paga = p.utm_campaign
      ? `<div style="max-width:170px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${p.utm_campaign}">${p.plataforma ? `<strong>${p.plataforma}</strong> · ` : ''}${p.utm_campaign}</div>
         ${p.criativo ? `<div class="t-sub">${p.criativo}</div>` : ''}`
      : '<span class="t-sub" style="color:var(--dim)">sem tagueamento</span>';
    return `
    <tr data-lead-row="${alvo}" style="cursor:pointer" class="${estado.lead == alvo ? 'sel' : ''}">
      <td>
        <div style="font-weight:600">${p.nome ?? '—'}</div>
        <div class="t-sub">${p.empresa ?? '—'}</div>
        <div style="margin-top:3px">${fontes}${lista}</div>
      </td>
      <td>${_jornada(p)}</td>
      <td>${paga}</td>
      <td>${_desfecho(p)}</td>
      <td class="mono-sm" style="text-align:right;font-variant-numeric:tabular-nums">${p.qtd_conversoes ?? 0}</td>
    </tr>`;
  }).join('');

  tbody.querySelectorAll('[data-lead-row]').forEach((tr) => {
    tr.onclick = () => _aplicarFiltro({ lead: tr.dataset.leadRow });
  });

  // "Carregar mais": os 290 leads que a interface não alcançava antes.
  const maisEl = document.getElementById('crm-mais');
  const temMais = _carregadas.length < total;
  maisEl.style.display = temMais ? 'block' : 'none';
  document.getElementById('crm-mais-info').textContent =
    `${_carregadas.length} de ${total.toLocaleString('pt-BR')}`;

  _renderKpis({ ...env, pessoas: _carregadas });
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

// A busca vai para a URL (FR-6: endereçável e retomável), com debounce para
// não disparar uma consulta por tecla. O valor do campo é restaurado do estado
// a cada render, senão ele se apaga ao voltar da ficha.
let _debounceBusca = null;
function _ligarBusca(estado) {
  const el = document.getElementById('crm-busca');
  if (!el) return;
  if (document.activeElement !== el) el.value = estado.busca ?? '';
  if (el.dataset.ligado) return;
  el.dataset.ligado = '1';
  el.addEventListener('input', () => {
    clearTimeout(_debounceBusca);
    const termo = el.value.trim();
    _debounceBusca = setTimeout(() => {
      _aplicarFiltro({ busca: termo || undefined, lead: undefined });
      const campo = document.getElementById('crm-busca');
      if (campo) { campo.focus(); campo.setSelectionRange(campo.value.length, campo.value.length); }
    }, 350);
  });
}

function _ligarCarregarMais(estado) {
  const btn = document.getElementById('crm-btn-mais');
  if (!btn || btn.dataset.ligado) return;
  btn.dataset.ligado = '1';
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    btn.textContent = 'Carregando…';
    try {
      await _renderLista(lerEstadoAtual(), { acumular: true });
    } finally {
      btn.disabled = false;
      btn.textContent = 'Carregar mais';
    }
  });
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
  _ligarBusca(estado);
  _ligarCarregarMais(estado);
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
