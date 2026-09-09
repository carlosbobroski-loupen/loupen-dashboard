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
import { lerEstadoAtual } from '../url-state.js';

if (typeof window.showView === 'function') {
  const showViewAntesDoCrm = window.showView;
  window.showView = function (id, fromDrill) {
    showViewAntesDoCrm(id, fromDrill);
    if (id === 'leads-crm') renderViewLeadsCrm();
    if (id === 'qualidade-dados') renderViewQualidadeDados();
  };
}

const estadoInicial = lerEstadoAtual();
if (['leads-crm', 'qualidade-dados'].includes(estadoInicial.view) && typeof window.showView === 'function') {
  window.showView(estadoInicial.view);
}
