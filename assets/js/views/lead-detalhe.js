// assets/js/views/lead-detalhe.js — subtask 5.10: ficha lead 360 em três
// blocos (Overview/Activity/Related) como superfície endereçável e
// retomável (?lead=<id>), sem modal de rolagem confinada — o painel vive
// na própria página, ao lado da lista (ver #crm-panel em index.html).

import { buscarLead } from '../data-api.js';
import { renderBadge, renderRazao, renderVinculoIdentidade } from '../attribution.js';
import { atualizarEstado, lerEstadoAtual } from '../url-state.js';

const FONTE_CLASSE = { salesforce: 'src-sf', rd_station: 'src-rd' };

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function _formatarDataHora(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  return d.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function _renderOverview(detalhe) {
  const ov = detalhe.overview;
  return `
    ${detalhe._seed_nota ? `<div class="attr-vinculo" style="margin-bottom:12px"><span>ℹ️</span><span>${escapeHtml(detalhe._seed_nota)}</span></div>` : ''}
    <div class="attr-box">${renderRazao(ov.atribuicao)}</div>
    ${renderVinculoIdentidade(ov.vinculo_identidade)}
    <div class="field-grid" style="margin-top:14px">
      <div class="field"><div class="field-label">Empresa</div><div class="field-val">${ov.empresa ? escapeHtml(ov.empresa) : '—'}</div></div>
      <div class="field"><div class="field-label">Estágio do funil</div><div class="field-val">${escapeHtml(ov.estagio_funil)}</div></div>
      <div class="field"><div class="field-label">E-mail</div><div class="field-val mono-sm">${ov.email ? escapeHtml(ov.email) : '—'}</div></div>
      <div class="field"><div class="field-label">Telefone</div><div class="field-val mono-sm">${ov.telefone ? escapeHtml(ov.telefone) : '—'}</div></div>
      <div class="field"><div class="field-label">Responsável</div><div class="field-val">${ov.responsavel ? escapeHtml(ov.responsavel) : '—'}</div></div>
      <div class="field"><div class="field-label">Categoria de origem</div><div class="field-val">${ov.atribuicao?.categoria ? escapeHtml(ov.atribuicao.categoria) : '—'}</div></div>
    </div>
  `;
}

function _renderJornada(detalhe) {
  const atividades = detalhe.activity ?? [];
  if (atividades.length === 0) {
    return '<div class="empty-state"><div class="es-title">Sem eventos registrados</div><div>Nenhuma atividade encontrada para este lead nas fontes conectadas.</div></div>';
  }
  // AC-3.2/EC-8: quando timestamp vem null, exibir a lacuna com a idade
  // declarada — NUNCA inventar uma data nem ordenar como se fosse "agora".
  const itens = atividades
    .map((a) => {
      // EC-8/AC-3.2: timestamp null nunca vira "agora" nem some da linha do
      // tempo — mostra a lacuna explicitamente e usa o dot tracejado.
      const dotClasse = a.idade_dado_declarada ? 'src-indisponivel' : (FONTE_CLASSE[a.fonte] ?? '');
      const rotuloData = a.timestamp
        ? `<span class="tl-time">${_formatarDataHora(a.timestamp)}</span>`
        : `<span class="tl-time" style="color:var(--amber)" title="Data não rastreável">data não rastreável</span>`;
      return `
        <div class="tl-item">
          <div class="tl-dot ${dotClasse}"></div>
          ${rotuloData}
          <div class="tl-title">${escapeHtml(a.titulo)}</div>
          <div class="tl-desc">${escapeHtml(a.descricao)}</div>
          <span class="tl-src">${escapeHtml(a.fonte)}</span>
          ${a.idade_dado_declarada ? `<div class="tl-idade">⚠️ ${escapeHtml(a.idade_dado_declarada)}</div>` : ''}
        </div>`;
    })
    .join('');
  return `<div class="crm-timeline">${itens}</div>`;
}

function _renderRelated(detalhe, estado) {
  const rel = detalhe.related;
  const blocos = [];

  if (rel.conta) {
    blocos.push(`
      <div class="rel-card" style="cursor:default">
        <div><div class="rel-title"><i class="ti ti-building"></i> ${escapeHtml(rel.conta.nome)}</div><div class="rel-sub">Conta Salesforce · ${escapeHtml(rel.conta.id)}</div></div>
      </div>`);
  } else {
    blocos.push(`
      <div class="rel-card" style="cursor:default;opacity:.75">
        <div><div class="rel-title"><i class="ti ti-building-off"></i> Sem conta associada</div><div class="rel-sub">Lead ainda não convertido — nenhuma conta Salesforce vinculada.</div></div>
      </div>`);
  }

  if (rel.oportunidade) {
    const o = rel.oportunidade;
    blocos.push(`
      <div class="rel-card" style="cursor:default">
        <div><div class="rel-title"><i class="ti ti-arrow-up-right"></i> ${escapeHtml(o.estagio)}</div><div class="rel-sub">Oportunidade · ${escapeHtml(o.id)}</div></div>
        <div class="rel-val">R$ ${Number(o.mrr).toLocaleString('pt-BR')}${o.valor_contrato !== null ? ` <span class="mono-sm" style="font-weight:400;color:var(--muted)">(contrato: R$ ${Number(o.valor_contrato).toLocaleString('pt-BR')})</span>` : ''}</div>
      </div>`);
  } else {
    blocos.push(`
      <div class="rel-card" style="cursor:default;opacity:.75">
        <div><div class="rel-title"><i class="ti ti-arrow-up-right"></i> Sem oportunidade</div><div class="rel-sub">Nenhuma oportunidade gerada por este lead até o momento.</div></div>
      </div>`);
  }

  const campanha = rel.cadeia_campanha ? rel.cadeia_campanha.at(-1) : detalhe.overview.atribuicao?.campanha_bruta;
  if (campanha) {
    blocos.push(`
      <div class="rel-card" data-ir-campanha="${escapeHtml(campanha)}">
        <div><div class="rel-title"><i class="ti ti-speakerphone"></i> Ver leads desta campanha</div><div class="rel-sub">${escapeHtml(campanha)}</div></div>
        <i class="ti ti-arrow-right"></i>
      </div>
      ${rel.cadeia_campanha ? `<div class="chain">${rel.cadeia_campanha.map((c) => `<b>${escapeHtml(c)}</b>`).join(' › ')}</div>` : ''}`);
  } else {
    blocos.push(`
      <div class="rel-card" style="cursor:default;opacity:.75">
        <div><div class="rel-title"><i class="ti ti-speakerphone-off"></i> Sem campanha rastreável</div><div class="rel-sub">Motivo: nenhum sinal de origem suficiente para associar este lead a uma campanha (ver Visão geral).</div></div>
      </div>`);
  }

  return blocos.join('');
}

function _ativarAba(tabId) {
  document.querySelectorAll('#crm-panel-tabs .meta-tab').forEach((btn) => btn.classList.toggle('active', btn.dataset.tab === tabId));
  document.querySelectorAll('.crm-panel-body .crm-p-view').forEach((el) => el.classList.toggle('active', el.dataset.view === tabId));
}

document.querySelectorAll('#crm-panel-tabs .meta-tab').forEach((btn) => {
  btn.onclick = () => _ativarAba(btn.dataset.tab);
});

/**
 * Renderiza a ficha completa do lead no painel lateral. Endereçável via
 * ?lead=<id>: chamado tanto por clique na lista (leads.js) quanto por
 * carregamento direto da URL (renderViewLeadsCrm no bootstrap).
 */
export async function renderPainelLead(leadId, estado) {
  const detalhe = await buscarLead(leadId);
  if (!detalhe) {
    document.getElementById('crm-p-nome').textContent = 'Lead não encontrado';
    document.getElementById('crm-p-url').textContent = `/leads/${leadId}`;
    document.getElementById('crm-view-overview').innerHTML = `<div class="empty-state"><div class="es-title">Não encontrado</div><div>Nenhum lead com id "${escapeHtml(leadId)}" no fixture atual.</div></div>`;
    document.getElementById('crm-view-jornada').innerHTML = '';
    document.getElementById('crm-view-related').innerHTML = '';
    return;
  }

  document.getElementById('crm-p-nome').innerHTML = `${escapeHtml(detalhe.overview.nome)} ${renderBadge(detalhe.overview.atribuicao)}`;
  document.getElementById('crm-p-url').textContent = `/leads/${leadId}`;
  document.getElementById('crm-view-overview').innerHTML = _renderOverview(detalhe);
  document.getElementById('crm-view-jornada').innerHTML = _renderJornada(detalhe);
  document.getElementById('crm-view-related').innerHTML = _renderRelated(detalhe, estado);

  document.querySelectorAll('#crm-view-related [data-ir-campanha]').forEach((btn) => {
    btn.onclick = () => {
      const estadoAtual = lerEstadoAtual();
      const novo = { ...estadoAtual, view: 'leads-crm', campanha: btn.dataset.irCampanha };
      delete novo.lead;
      atualizarEstado(novo);
      import('./leads.js').then((m) => m.renderViewLeadsCrm());
    };
  });
}

/** Reseta o painel para o estado placeholder (nenhum lead selecionado). */
export function limparPainel() {
  document.getElementById('crm-p-nome').textContent = 'Selecione um lead';
  document.getElementById('crm-p-url').textContent = '/leads';
  document.getElementById('crm-view-overview').innerHTML = '';
  document.getElementById('crm-view-jornada').innerHTML = '';
  document.getElementById('crm-view-related').innerHTML = '';
  _ativarAba('overview');
}
