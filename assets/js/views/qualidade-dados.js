// assets/js/views/qualidade-dados.js — subtask 5.15: degradação explícita
// por fonte indisponível — lacuna declarada com fonte e horário, jamais
// zero (P-UI-6, EC-8, AC-9.2). Etapa A: deriva tudo do fixture já
// carregado via data-api.js/obterQualidadeDados (ver header desse arquivo
// — não existe endpoint formal de status neste contrato, data-contract.md
// §4).

import { obterQualidadeDados } from '../data-api.js';

const FONTE_LABEL = { salesforce: 'Salesforce', rd_station: 'RD Station' };

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function _formatarData(iso) {
  const [ano, mes, dia] = iso.slice(0, 10).split('-');
  return `${dia}/${mes}/${ano}`;
}

function _renderFontes(porFonte) {
  return porFonte
    .map(
      (f) => `
    <div class="rel-card" style="cursor:default">
      <div><div class="rel-title"><i class="ti ti-database"></i> ${FONTE_LABEL[f.fonte] ?? escapeHtml(f.fonte)}</div><div class="rel-sub">${f.totalLeads} lead${f.totalLeads === 1 ? '' : 's'} nesta fonte</div></div>
      <div class="rel-val mono-sm" style="font-weight:400;color:var(--muted)">último visto ${_formatarData(f.ultimaAtividadeObservada)}</div>
    </div>`
    )
    .join('');
}

function _renderLacunas(lacunas) {
  if (lacunas.length === 0) {
    return '<div class="empty-state"><div class="es-title">Nenhuma lacuna declarada no momento</div><div>Nenhum evento do fixture atual está marcado com fonte indisponível.</div></div>';
  }
  return lacunas
    .map(
      (l) => `
    <div class="rel-card" style="cursor:default;align-items:flex-start">
      <div>
        <div class="rel-title"><i class="ti ti-alert-triangle" style="color:var(--amber)"></i> ${FONTE_LABEL[l.fonte] ?? escapeHtml(l.fonte)} indisponível</div>
        <div class="rel-sub">Lead: ${escapeHtml(l.leadNome)} — ${escapeHtml(l.titulo)}</div>
        <div class="tl-idade" style="margin-top:4px">⚠️ ${escapeHtml(l.idade_dado_declarada)}</div>
        ${l.ultimoEventoValidoTitulo ? `<div class="mono-sm" style="color:var(--muted);margin-top:4px">Último dado válido: ${escapeHtml(l.ultimoEventoValidoTitulo)}${l.ultimoEventoValidoTimestamp ? ` (${_formatarData(l.ultimoEventoValidoTimestamp)})` : ''}</div>` : ''}
      </div>
    </div>`
    )
    .join('');
}

/** Ponto de entrada — chamado quando a view é exibida (ver bootstrap). */
export async function renderViewQualidadeDados() {
  const { porFonte, lacunas } = await obterQualidadeDados();
  document.getElementById('qd-fontes-count').textContent = porFonte.length;
  document.getElementById('qd-fontes-grid').innerHTML = _renderFontes(porFonte);
  document.getElementById('qd-lacunas-count').textContent = lacunas.length;
  document.getElementById('qd-lacunas-list').innerHTML = _renderLacunas(lacunas);
}
