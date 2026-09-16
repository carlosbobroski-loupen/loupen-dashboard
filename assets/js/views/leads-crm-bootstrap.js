// assets/js/views/leads-crm-bootstrap.js — liga a view leads-crm (5.9-5.11)
// ao showView() legado (Strangler Fig): dispara o render ao trocar de view
// e, no carregamento direto da página com ?view=leads-crm na URL (FR-6,
// endereçável/retomável), abre a view certa sem exigir clique manual.
//
// Módulo ES, executado após a análise do documento (defer implícito de
// type=module) — quando roda, window.showView já é a função real definida
// em views-legacy.js (script clássico, executado antes durante o parsing).

import { renderViewLeadsCrm } from './leads.js';
import { renderViewQualidadeDados } from './qualidade-dados.js';
import { renderViewMarketingFunil } from './marketing-funil.js';
import { renderViewOportunidades } from './oportunidades.js';
import { lerEstadoAtual } from '../url-state.js';

// Títulos das views novas. `showView()` legado lê de um mapa `VIEWS` que vive
// dentro de views-legacy.js e cai em `||id` para o que não conhece — sem isto,
// a aba nova estamparia "oportunidades-crm" no topo da página. Escrito aqui, e
// não lá, porque views-legacy.js (3.828 linhas) não é tocado por decisão.
const TITULO_VIEW = { 'oportunidades-crm': 'Oportunidades' };

// Views novas que trazem o PRÓPRIO seletor de período. O de cima (#date-range-wrap)
// pertence ao carregamento legado e não recorta nenhuma delas — deixá-lo visível
// e inerte faria o usuário mexer na data, nada mudar, e passar a duvidar do dado
// em vez de duvidar do controle. É a mesma regra que views-legacy.js já aplica a
// marketing-funil e qualidade-dados; aqui ela só é estendida sem editar aquele arquivo.
const SEM_PERIODO_GLOBAL = ['oportunidades-crm'];

if (typeof window.showView === 'function') {
  const showViewAntesDoCrm = window.showView;
  window.showView = function (id, fromDrill) {
    showViewAntesDoCrm(id, fromDrill);
    if (TITULO_VIEW[id]) {
      const t = document.getElementById('page-title');
      if (t) t.textContent = TITULO_VIEW[id];
    }
    if (SEM_PERIODO_GLOBAL.includes(id)) {
      const drw = document.getElementById('date-range-wrap');
      if (drw) drw.style.display = 'none';
    }
    if (id === 'leads-crm') renderViewLeadsCrm();
    if (id === 'qualidade-dados') renderViewQualidadeDados();
    if (id === 'marketing-funil') renderViewMarketingFunil();
    if (id === 'oportunidades-crm') renderViewOportunidades();
  };
}

const estadoInicial = lerEstadoAtual();
if (['leads-crm', 'qualidade-dados', 'marketing-funil', 'oportunidades-crm'].includes(estadoInicial.view) && typeof window.showView === 'function') {
  window.showView(estadoInicial.view);
}
