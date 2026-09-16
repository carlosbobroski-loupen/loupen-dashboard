// assets/js/formato-moeda.js — formatação de dinheiro numa org MULTI-MOEDA
// (BRL / USD / MXN — migration 090).
//
// EXTRAÍDO de views/lead-detalhe.js em 2026-09-16, sem alteração de
// comportamento, quando a aba Oportunidades passou a precisar exatamente das
// mesmas regras. Duplicar as três funções seria duplicar a chance de repetir
// o defeito que elas existem para não repetir — e a aba nova mostra valor de
// 8.073 oportunidades, não de 91 leads.
//
// O defeito original: a ficha imprimia `currency: 'BRL'` (e um "R$ " literal)
// em cima de `amount`/`contrato_valor`, que vêm NA MOEDA DO REGISTRO. Medido
// em 2026-09-16: 22 dos 91 leads com valor na `view_lead_360` estavam em USD
// ou MXN, ou seja, com o símbolo errado — um deles (MXN 3.299,99) aparecia
// como "R$ 3.299,99" quando o valor real é R$ 967,78. 3,4× para cima.
//
// As três regras, nesta ordem de precedência:
//   1. NUNCA formatar um número não-BRL como real. Símbolo errado é número
//      errado.
//   2. Quando há conversão, o CRU vai JUNTO do convertido, nunca no lugar:
//      "R$ 967,78 (MX$ 3.299,99)". O convertido é a grandeza comparável, o
//      cru é o dado que existe no Salesforce.
//   3. Quando NÃO há conversão, não se inventa taxa e não se some o valor:
//      ele aparece na moeda dele, com o motivo. Exclusão silenciosa e
//      substituição silenciosa são proibidas (contrato §1.6; a própria 090
//      recusa `amount × 1` para moeda desconhecida).

const MOEDA_ISO = /^[A-Z]{3}$/;

/**
 * Formata na moeda pedida, ou devolve null se a moeda não for utilizável —
 * null aqui significa "não sei rotular", e quem chama decide o que dizer.
 * Nunca cai em BRL por omissão: era exatamente esse fallback implícito que
 * produzia o número errado.
 * @param {*} valor
 * @param {?string} codigo ISO-4217
 * @returns {?string}
 */
export function emMoeda(valor, codigo) {
  const n = Number(valor);
  if (!Number.isFinite(n)) return null;
  if (!MOEDA_ISO.test(String(codigo ?? ''))) return null;
  try {
    // Duas casas SEMPRE, inclusive em moedas que o Intl trata como inteiras
    // (COP, JPY…): o valor na origem é `numeric(x,2)` e deixar o Intl arredondar
    // transformaria 3.299,99 em "COP 3.300" — arredondamento silencioso é da
    // mesma família do símbolo errado. Quem exibe formata; ninguém altera.
    return n.toLocaleString('pt-BR', {
      style: 'currency', currency: codigo,
      minimumFractionDigits: 2, maximumFractionDigits: 2,
    });
  } catch {
    // Código com forma de ISO-4217 mas não suportado pelo runtime.
    return null;
  }
}

/** Número sem símbolo, duas casas, separador pt-BR. @returns {?string} */
export function numeroSimples(valor) {
  const n = Number(valor);
  if (!Number.isFinite(n)) return null;
  return n.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/**
 * Valor monetário que tem par convertido na fonte (`amount`/`amount_brl`,
 * `contrato_valor`/`contrato_valor_brl`).
 * @param {*} brl valor já em real (pode ser string numérica — a API devolve
 *   `numeric` do Postgres como string)
 * @param {*} cru valor na moeda do registro
 * @param {?string} moeda ISO-4217 do registro
 * @param {?string} motivo por que a conversão não existe, quando não existe
 * @returns {?string} texto puro (quem exibe aplica escapeHtml), ou null se
 *   não há valor nenhum a mostrar
 */
export function fmtValor(brl, cru, moeda, motivo) {
  const temBrl = Number.isFinite(Number(brl)) && brl !== null && brl !== '';
  const temCru = Number.isFinite(Number(cru)) && cru !== null && cru !== '';
  if (!temBrl && !temCru) return null;

  if (temBrl) {
    const emReal = emMoeda(brl, 'BRL');
    // Em BRL o cru É o convertido; repetir o mesmo número entre parênteses
    // seria ruído, não transparência.
    if (!moeda || moeda === 'BRL') return emReal;
    const origem = temCru ? (emMoeda(cru, moeda) ?? `${numeroSimples(cru)} ${moeda}`) : null;
    return origem ? `${emReal} (${origem})` : `${emReal} (convertido de ${moeda})`;
  }

  // Sem conversão. O valor continua visível, na moeda em que ele realmente
  // está, e o motivo vai junto — não converter é uma informação, não um erro
  // a esconder.
  const emOrigem = emMoeda(cru, moeda);
  const texto = emOrigem ?? `${numeroSimples(cru)} em moeda não identificada`;
  const porque = motivo
    || (moeda ? `taxa de ${moeda} indisponível na fonte` : 'moeda do registro não informada');
  return `${texto} · sem conversão para real: ${porque}`;
}

/**
 * Agregado já convertido para real pela camada de dados (receita, pipeline,
 * ticket). Diferente de `fmtValor`: aqui NÃO existe "cru na moeda de origem"
 * — a soma é de grandezas convertidas, e o que fica de fora é contado à parte
 * (`qtd_ganhas_fora_do_valor`), nunca embutido no número.
 * @param {*} brl
 * @returns {?string}
 */
export function fmtBrl(brl) {
  return emMoeda(brl, 'BRL');
}

/**
 * MRR. Fica na MOEDA DE ORIGEM, rotulado, e NUNCA em real convertido.
 *
 * Por quê: a migration 090 converteu `Amount` e `contrato_valor`, não
 * `MRR__c` — não existe `mrr_brl` em `view_receita`/`view_lead_360`/
 * `view_oportunidade_analitica`. Converter no navegador seria reimplementar a
 * taxa na camada errada (a taxa vem de `currency_rate`, ingerida do
 * Salesforce, e mudá-la de lugar é como dois números divergentes nascem).
 * Omitir o MRR também não serve: é dado real da origem e sumiria da tela sem
 * aviso. Então ele aparece como está, com o símbolo da moeda em que está — e,
 * se a moeda for desconhecida, dizendo isso em vez de chutar real.
 * @returns {?string} texto puro, ou null quando não há MRR
 */
export function fmtMrr(valor, moeda) {
  if (valor === null || valor === undefined || valor === '') return null;
  if (!Number.isFinite(Number(valor))) return null;
  const emOrigem = emMoeda(valor, moeda);
  if (emOrigem) {
    return moeda === 'BRL' ? emOrigem : `${emOrigem} (sem equivalente em real na fonte)`;
  }
  return `${numeroSimples(valor)} em moeda não identificada`;
}
