// assets/js/app.js — bootstrap e infraestrutura compartilhada.
// Extraido de index.html (subtask 5.3) sem alteracao de logica.
// Novas views (leads.js, lead-detalhe.js, relacionamentos.js) e a
// camada de dados (data-api.js/url-state.js/attribution.js) sao
// carregadas separadamente e comecam a viver aqui conforme a
// Etapa A avanca; a logica das 15 views existentes permanece em
// views-legacy.js, intocada.

// Aplica o estado salvo da sidebar e do tema o quanto antes (shell já está no DOM) para reduzir
// flash visual — o tema em especial, pra não piscar escuro→claro (ou vice-versa) no primeiro paint.
(function(){
  try {
    if (localStorage.getItem('sidebarCollapsed') === '1') {
      document.querySelector('.shell').classList.add('sidebar-collapsed');
      const icon = document.getElementById('sidebar-toggle-icon');
      const label = document.querySelector('#sidebar-toggle .sidebar-toggle-label');
      const btn = document.getElementById('sidebar-toggle');
      if (icon) icon.className = 'ti ti-layout-sidebar-left-expand';
      if (label) label.textContent = 'Expandir menu';
      if (btn) btn.setAttribute('aria-label', 'Expandir menu lateral');
    }
  } catch(e){}
  try {
    // Padrão continua escuro (ux atual) — tema claro é opt-in, só aplicado se já foi escolhido antes.
    if (localStorage.getItem('theme') === 'light') {
      document.documentElement.setAttribute('data-theme', 'light');
      const icon = document.getElementById('theme-toggle-icon');
      const label = document.getElementById('theme-toggle-label');
      const btn = document.getElementById('theme-toggle');
      if (icon) icon.className = 'ti ti-moon';
      if (label) label.textContent = 'Tema escuro';
      if (btn) btn.setAttribute('aria-label', 'Mudar para tema escuro');
    }
  } catch(e){}
})();

// ── Subtask 5.8: banner de "snapshot congelado" nas views ainda não
// migradas (Strangler Fig, spec.md §3.7 Passo 0/EC-12). Monkey-patch de
// showView() em vez de editar views-legacy.js — mantém a extração de 5.3
// verbatim e intocada. IDs em MIGRATED_VIEWS saem desta lista conforme
// cada view é migrada de verdade (ver subtask 5.9 em diante).
window.SNAPSHOT_DATA_ISO = '2026-08-21'; // data do último snapshot congelado conhecido (commit d86260a)
// 'leads-crm'/'qualidade-dados' nunca foram snapshot: são views novas
// (5.9-5.11, 5.15), leem o fixture curado via data-api.js desde o
// primeiro commit — não entram no banner.
window.MIGRATED_VIEWS = ['leads-crm', 'qualidade-dados', 'marketing-funil'];

function _formatarDataBanner(iso) {
  const [ano, mes, dia] = iso.split('-');
  return `${dia}/${mes}/${ano}`;
}

function _garantirBannerSnapshot(viewId) {
  const container = document.getElementById('view-' + viewId);
  if (!container) return;
  const jaMigrada = window.MIGRATED_VIEWS.includes(viewId);
  let banner = container.querySelector(':scope > .snapshot-banner');

  if (jaMigrada) {
    if (banner) banner.remove();
    return;
  }
  if (!banner) {
    banner = document.createElement('div');
    banner.className = 'snapshot-banner';
    banner.innerHTML = `<i class="ti ti-clock-pause"></i><span>Snapshot congelado em ${_formatarDataBanner(window.SNAPSHOT_DATA_ISO)} — esta view ainda lê dados estáticos do arquivo, não a base ao vivo.</span>`;
    container.insertBefore(banner, container.firstChild);
  }
}

window.addEventListener('load', function () {
  if (typeof window.showView !== 'function') return; // views-legacy.js não carregou (ambiente de teste isolado)
  const showViewOriginal = window.showView;
  window.showView = function (id, fromDrill) {
    showViewOriginal(id, fromDrill);
    _garantirBannerSnapshot(id);
  };
  // Aplica no view ativo no primeiro paint (overview, antes de qualquer clique).
  _garantirBannerSnapshot(window.viewAtiva || 'overview');
});
