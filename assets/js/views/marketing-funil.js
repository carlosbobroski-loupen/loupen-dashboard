// assets/js/views/marketing-funil.js — a aba que responde o objetivo central
// do épico, dito pelo usuário em 2026-09-15:
//
//   "pegar os leads que estão no RD Station, que foram gerados por marketing,
//    fazer análise desses mesmos leads dentro do Salesforce e trazer no
//    dashboard"
//
// Cada número aqui vem de /api/marketing-funil, que serve a view
// view_marketing_rd_sf (migration 077). Nada é calculado no cliente: somar no
// cliente foi exatamente como o dashboard antigo produzia total que não batia
// com a lista embaixo.
//
// GRÃO: uma linha por lead de marketing do RD. As oportunidades vêm agregadas
// em colunas — a lista NÃO multiplica por oportunidade.

import { obterMarketingFunil } from '../data-api.js';

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
const num = (v) => Number(v ?? 0).toLocaleString('pt-BR');
const set = (id, html) => { const el = document.getElementById(id); if (el) el.innerHTML = html; };
const txt = (id, t) => { const el = document.getElementById(id); if (el) el.textContent = t; };

function dataCurta(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleDateString('pt-BR');
}

// ── KPIs ───────────────────────────────────────────────────────────────────
function _renderKpis(k) {
  if (!k) return '';
  const pctSf = k.leads_marketing > 0
    ? ((100 * k.achados_no_sf) / k.leads_marketing).toFixed(0) : '0';
  return `
    <div class="kpi blue">
      <div class="kpi-label"><i class="ti ti-target-arrow"></i>Leads de marketing</div>
      <div class="kpi-value">${num(k.leads_marketing)}</div>
      <div class="kpi-footer">no RD Station, classificados pelo motor</div>
    </div>
    <div class="kpi purple">
      <div class="kpi-label"><i class="ti ti-brand-salesforce"></i>Achados no Salesforce</div>
      <div class="kpi-value">${num(k.achados_no_sf)}</div>
      <div class="kpi-footer">${pctSf}% — ligados por e-mail (Tier 1)</div>
    </div>
    <div class="kpi amber">
      <div class="kpi-label"><i class="ti ti-building"></i>Viraram conta</div>
      <div class="kpi-value">${num(k.viraram_conta)}</div>
      <div class="kpi-footer">lead convertido em Account</div>
    </div>
    <div class="kpi green">
      <div class="kpi-label"><i class="ti ti-briefcase"></i>Oportunidades</div>
      <div class="kpi-value">${num(k.oportunidades)}</div>
      <div class="kpi-footer">${num(k.ganhas)} ganha(s)</div>
    </div>
    <div class="kpi red">
      <div class="kpi-label"><i class="ti ti-list-check"></i>De lista importada</div>
      <div class="kpi-value">${num(k.de_lista)}</div>
      <div class="kpi-footer">fora do denominador de taxa</div>
    </div>`;
}

// ── Funil, com a queda visível ─────────────────────────────────────────────
function _renderFunil(k) {
  if (!k) return '';
  const etapas = [
    { nome: 'Leads de marketing (RD)', v: Number(k.leads_marketing || 0), cor: 'var(--blue)' },
    { nome: 'Achados no Salesforce', v: Number(k.achados_no_sf || 0), cor: 'var(--purple)' },
    { nome: 'Viraram conta', v: Number(k.viraram_conta || 0), cor: 'var(--amber)' },
    { nome: 'Com oportunidade', v: Number(k.oportunidades || 0), cor: 'var(--green)' },
    { nome: 'Ganhas', v: Number(k.ganhas || 0), cor: 'var(--green)' },
  ];
  const base = etapas[0].v || 1;
  return etapas.map((e, i) => {
    const pct = (100 * e.v) / base;
    const anterior = i > 0 ? etapas[i - 1].v : null;
    const conv = anterior ? (anterior > 0 ? ((100 * e.v) / anterior).toFixed(1).replace('.', ',') : '0') : null;
    return `
      <div class="funil2-row" style="animation-delay:${i * 60}ms;cursor:default">
        <div class="funil2-name">${esc(e.nome)}</div>
        <div class="funil2-track">
          <div class="funil2-fill" style="width:${Math.max(pct, 0.6)}%;background:${e.cor}"></div>
        </div>
        <div class="funil2-val mono">${num(e.v)}${conv !== null ? `<span style="color:var(--muted);font-size:11px"> · ${conv}%</span>` : ''}</div>
      </div>`;
  }).join('');
}

// ── Quebra por categoria de origem ─────────────────────────────────────────
function _renderCategorias(cats) {
  if (!cats?.length) return '<div style="padding:16px;color:var(--muted);font-size:13px">Nenhuma categoria.</div>';
  return `<table class="tbl">
    <thead><tr>
      <th>Origem</th><th>Leads</th><th>No Salesforce</th><th>Contas</th><th>Oportunidades</th>
    </tr></thead>
    <tbody>${cats.map((c) => `
      <tr>
        <td><div class="t-name">${esc(c.categoria)}</div><div class="t-sub">${esc(c.detalhe)}</div></td>
        <td class="mono">${num(c.leads)}</td>
        <td class="mono">${num(c.achados_no_sf)}</td>
        <td class="mono">${num(c.viraram_conta)}</td>
        <td class="mono">${num(c.oportunidades)}</td>
      </tr>`).join('')}</tbody></table>`;
}

// ── Lista de leads ─────────────────────────────────────────────────────────
function _renderLeads(leads) {
  if (!leads?.length) return '<div style="padding:16px;color:var(--muted);font-size:13px">Nenhum lead.</div>';
  return `<table class="tbl">
    <thead><tr>
      <th>Lead</th><th>Origem</th><th>Criado</th><th>Salesforce</th><th>Conta</th><th>Opp.</th>
    </tr></thead>
    <tbody>${leads.map((l) => {
      const sf = l.virou_conta
        ? '<span class="badge" style="background:var(--green-dim);color:var(--green)">virou conta</span>'
        : l.achado_no_salesforce
          ? '<span class="badge lead">no CRM</span>'
          : '<span class="badge" style="background:var(--surface2);color:var(--muted)">não achado</span>';
      const lista = l.de_lista_importada
        ? '<span class="badge" style="background:var(--amber-dim);color:var(--amber);margin-left:6px">lista</span>' : '';
      return `<tr>
        <td><div class="t-name">${esc(l.nome || '—')}${lista}</div>
            <div class="t-sub">${esc(l.empresa || '—')}</div></td>
        <td style="text-align:left"><div class="t-name" style="font-weight:400">${esc(l.detalhe || l.categoria || '—')}</div>
            <div class="t-sub">${esc(l.origem_conversao || '')}</div></td>
        <td class="mono">${dataCurta(l.criado_em)}</td>
        <td>${sf}</td>
        <td><div class="t-name" style="font-weight:400">${esc(l.conta_nome || '—')}</div></td>
        <td class="mono">${num(l.qtd_oportunidades)}</td>
      </tr>`;
    }).join('')}</tbody></table>`;
}

export async function renderViewMarketingFunil() {
  set('mf-kpis', '<div style="grid-column:1/-1;padding:16px;color:var(--muted);font-size:13px">Carregando…</div>');

  let dados;
  try {
    dados = await obterMarketingFunil();
  } catch (e) {
    // Degradação explícita (P-UI-6): a aba diz o que falhou em vez de ficar
    // vazia e parecer que não há dado.
    set('mf-kpis', `<div style="grid-column:1/-1;padding:16px;color:var(--red);font-size:13px">
      <i class="ti ti-alert-triangle"></i> Falha ao carregar o funil: ${esc(e.message)}</div>`);
    set('mf-funil', '');
    set('mf-categorias', '');
    set('mf-leads', '');
    return;
  }

  const k = dados?.kpis || null;
  set('mf-kpis', _renderKpis(k));
  set('mf-funil', _renderFunil(k));
  txt('mf-cat-badge', `${(dados?.categorias ?? []).length} origem(ns)`);
  set('mf-categorias', _renderCategorias(dados?.categorias));
  txt('mf-leads-badge', `${num((dados?.leads ?? []).length)} leads`);
  set('mf-leads', _renderLeads(dados?.leads));
  txt('mf-gerado', dados?.gerado_em ? `atualizado ${new Date(dados.gerado_em).toLocaleString('pt-BR')}` : '');
}
