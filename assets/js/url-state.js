// assets/js/url-state.js — estado de view/filtro/ficha vive na URL, nunca em
// useState/variável de módulo perdida ao navegar (FR-1/AC-1.2, FR-6/AC-6.1).
//
// SEMPRE query string ou hash — NUNCA segmentos de caminho. Hospedagem
// estática (GitHub Pages, CON-12) sem rewrite não serve caminhos
// arbitrários: uma URL como /leads/123 daria 404 no carregamento direto e
// no refresh, quebrando justamente o "endereçável e retomável" que AC-6.1
// exige. Path routing só volta com o lado servidor da fase 2 (spec.md §3.8).
//
// Funções puras (serialize/parse) + um adaptador fino da History API.

/**
 * Serializa um objeto de estado em query string (sem o "?" inicial).
 * Valores array viram chaves repetidas (URLSearchParams nativo).
 * @param {Object<string, string|string[]>} estado
 * @returns {string}
 */
export function serialize(estado) {
  const params = new URLSearchParams();
  for (const [chave, valor] of Object.entries(estado)) {
    if (Array.isArray(valor)) {
      for (const v of valor) params.append(chave, v);
    } else if (valor !== undefined && valor !== null) {
      params.append(chave, valor);
    }
  }
  return params.toString();
}

/**
 * Desserializa uma query string de volta em objeto de estado. Chaves
 * repetidas viram array; chave única vira string escalar — espelha
 * exatamente o que serialize() produziu (round-trip).
 * @param {string} query
 * @returns {Object<string, string|string[]>}
 */
export function parse(query) {
  const params = new URLSearchParams(query);
  const estado = {};
  for (const chave of params.keys()) {
    if (estado[chave] !== undefined) continue; // já processada (chave repetida)
    const valores = params.getAll(chave);
    estado[chave] = valores.length > 1 ? valores : valores[0];
  }
  return estado;
}

/**
 * Normaliza um valor de parse() para array, sempre. Necessário porque um
 * array de UM item é indistinguível de um escalar depois de ir e voltar
 * pela query string (`segmento=marketing` não guarda "isso era array") —
 * limitação inerente de query string, não bug. Todo campo que É
 * conceitualmente multi-valor (ex.: segmento, canal) deve passar por aqui
 * no código que consome o estado, em vez de assumir que parse() devolve
 * array sozinho.
 * @param {string|string[]|undefined} valor
 * @returns {string[]}
 */
export function comoArray(valor) {
  if (valor === undefined || valor === null) return [];
  return Array.isArray(valor) ? valor : [valor];
}

/** Lê o estado atual da URL do navegador. Não usar fora de um contexto de DOM. */
export function lerEstadoAtual() {
  return parse(window.location.search.replace(/^\?/, ''));
}

/**
 * Atualiza a URL com o novo estado, via History API — nunca recarrega a
 * página. `substituir: true` usa replaceState (não cria entrada no
 * histórico); o default (pushState) permite o botão "voltar" do navegador
 * funcionar como navegação normal.
 * @param {Object} estado
 * @param {{substituir?: boolean}} [opcoes]
 */
export function atualizarEstado(estado, opcoes = {}) {
  const query = serialize(estado);
  const url = query ? `${window.location.pathname}?${query}` : window.location.pathname;
  if (opcoes.substituir) {
    window.history.replaceState(estado, '', url);
  } else {
    window.history.pushState(estado, '', url);
  }
}
