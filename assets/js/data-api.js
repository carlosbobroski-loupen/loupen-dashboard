// assets/js/data-api.js — a camada ÚNICA de acesso a dados (spec.md §5.1,
// P-UI-5, ADR-021). Nenhum outro arquivo pode saber se está lendo o fixture
// mock (Etapa A) ou o backend real (Etapa B) — só este arquivo.
//
// TRÊS MODOS, e a diferença entre eles é de SEGURANÇA, não de conveniência:
//
//  MOCK (padrão, `MODO_DADOS = 'mock'`) — lê o fixture curado da Etapa A.
//    É o que o site publicado faz hoje, byte a byte. Nenhum dado real,
//    nenhuma PII, nenhum segredo.
//
//  TESTE LOCAL (`window.__CRM_API_KEY__` injetada à mão) — chama o n8n
//    direto com o header. A variável NUNCA é definida neste arquivo nem em
//    qualquer arquivo commitado: só existe se alguém a injeta no console ou
//    um script de teste a injeta antes da página carregar (Playwright
//    `addInitScript`). Serve para validar a integração real sem depender de
//    deploy, e sem publicar segredo nenhum.
//
//  PRODUÇÃO (`MODO_DADOS = 'real'`) — chama `/api/*` SAME-ORIGIN, sem chave
//    nenhuma no cliente. Quem injeta o header `X-CRM-Api-Key` é a Pages
//    Function (`functions/api/[[path]].js`), que roda no servidor. Este é o
//    único caminho seguro para o público: um site estático não tem como
//    esconder segredo do navegador (D11/P-ING-6 proíbem segredo de API no
//    front-end), e a Function resolve isso movendo o segredo para fora do
//    navegador — não confiando na obscuridade.
//
// O cutover (7.1/7.4) é literalmente trocar `MODO_DADOS` para 'real'. Nada
// mais neste arquivo, e nada em nenhum outro arquivo, precisa mudar — é o
// que ADR-021 previu. NÃO trocar antes do gate de acesso estar ativo
// (ADR-018): em modo real este dashboard serve PII de lead, e o que impede
// acesso anônimo é o Cloudflare Access, não este arquivo.

const LEADS_LIST_URL = 'assets/data/mock/leads.json';
const LEADS_DETAIL_URL = 'assets/data/mock/leads-detalhe.json';

// MODO_DADOS é o ÚNICO interruptor do corte de produção (7.1/7.4). Enquanto
// for 'mock', o site publicado se comporta exatamente como hoje. Virar para
// 'real' é a "troca de uma constante de origem" que ADR-021 previu como
// sendo todo o cutover — nenhuma outra linha de nenhum outro arquivo muda.
// NÃO virar sem o gate de acesso ativo (ADR-018): em modo real o dashboard
// serve dado de lead com PII, e o que impede acesso anônimo é o Cloudflare
// Access, não este arquivo.
const MODO_DADOS = 'mock';

// Achado real (subtask 5.1): webhook com path dinâmico (:id) é servido com
// o webhookId do nó PREPENDED à URL — não documentado de forma óbvia na UI
// do n8n. Ver docs/architecture/edge-routing.md.
// Usado SÓ no modo de teste local (chave injetada à mão); em produção quem
// conhece essa peculiaridade é a Pages Function, não o cliente.
const API_BASE = 'https://n8n.loupenapps.com.br/webhook';
const API_DETAIL_WEBHOOK_ID = '855a5444-c212-4c84-b993-ef082e35f999';

// Dois caminhos reais, deliberadamente distintos:
//
//  (1) TESTE LOCAL — `window.__CRM_API_KEY__` injetada à mão (console ou
//      Playwright addInitScript, NUNCA um arquivo commitado). Chama o n8n
//      direto, com o header. Serve para validar a integração sem depender
//      de deploy.
//  (2) PRODUÇÃO — `MODO_DADOS === 'real'`. Chama `/api/*` SAME-ORIGIN, sem
//      chave nenhuma: quem injeta o header é a Pages Function
//      (`functions/api/[[path]].js`), do lado do servidor. É o único
//      caminho seguro para o público, porque um site estático não tem como
//      esconder segredo do navegador.
//
// (1) tem precedência sobre (2) para que um teste local continue possível
// mesmo depois do cutover.
function _modoTesteLocal() {
  return typeof window !== 'undefined' && !!window.__CRM_API_KEY__;
}

function _modoReal() {
  return MODO_DADOS === 'real' || _modoTesteLocal();
}

// `caminho` é lógico: 'api/meta', 'api/leads?x=y', 'api/leads/<id>'.
function _fetchReal(caminho) {
  if (_modoTesteLocal()) {
    // Reproduz a peculiaridade do webhookId só neste caminho.
    const url = caminho.startsWith('api/leads/')
      ? `${API_BASE}/${API_DETAIL_WEBHOOK_ID}/${caminho}`
      : `${API_BASE}/${caminho}`;
    return fetch(url, { headers: { 'X-CRM-Api-Key': window.__CRM_API_KEY__ } });
  }
  // Produção: same-origin, sem header. A borda resolve o resto.
  return fetch(`/${caminho}`);
}

let _listCache = null;
let _detailCache = null;

async function _loadList() {
  if (_listCache) return _listCache;
  const res = await fetch(LEADS_LIST_URL, { credentials: 'same-origin' });
  if (!res.ok) throw new Error(`data-api: falha ao carregar lista de leads (HTTP ${res.status})`);
  _listCache = await res.json();
  return _listCache;
}

async function _loadDetail() {
  if (_detailCache) return _detailCache;
  const res = await fetch(LEADS_DETAIL_URL, { credentials: 'same-origin' });
  if (!res.ok) throw new Error(`data-api: falha ao carregar detalhe de leads (HTTP ${res.status})`);
  _detailCache = await res.json();
  return _detailCache;
}

// Adapta um item de /api/leads (fn_search_leads) para a forma que o
// restante da Etapa A já espera (mesmo contrato de data-contract.md §1).
function _adaptarItemLista(real) {
  return {
    id: real.source_id,
    nome: real.nome,
    empresa: real.empresa,
    segmento: real.segmento,
    estagio_funil: real.estagio_funil,
    data_criacao: real.created_at_source,
    // TODO conhecido: fn_search_leads só lê a tabela `lead` (Salesforce) —
    // quando contact/RD Station entrar na busca combinada, isto deixa de
    // ser um valor fixo.
    fonte_dados: 'salesforce',
  };
}

const ROTULO_TIPO_EVENTO = {
  conversao: 'Conversão registrada',
  criacao_oportunidade: 'Oportunidade criada',
};

// Adapta a resposta de /api/leads/{id} (view_lead_360 + view_jornada_unificada)
// para a forma de três blocos que a Etapa A já espera (data-contract.md §2).
function _adaptarDetalheReal(real) {
  if (!real || real.erro === 'lead_nao_encontrado') return null;
  const ov = real.overview;
  const oportunidades = real.related?.oportunidades ?? [];

  return {
    overview: {
      nome: ov.nome,
      empresa: ov.empresa,
      email: ov.email,
      telefone: ov.telefone,
      // TODO conhecido: /api/leads/{id} ainda não expõe o responsável
      // (owner) do lead — view_lead_360 não inclui esse campo hoje.
      responsavel: null,
      estagio_funil: ov.estagio_funil,
      atribuicao: ov.atribuicao ? {
        segmento: ov.atribuicao.segmento,
        categoria: ov.atribuicao.categoria,
        detalhe: ov.atribuicao.detalhe,
        campanha_bruta: ov.atribuicao.valor_bruto,
        sinal_id: ov.atribuicao.sinal_id,
        // TODO conhecido: fn_classify_origin não calcula um "nome de sinal"
        // textual nem um nível de confiança separado — só razao_legivel.
        sinal_nome: null,
        confianca: null,
        razao_legivel: ov.atribuicao.razao?.razao_legivel ?? null,
        campo_origem_bruto: ov.atribuicao.valor_bruto,
        ruleset_version: null,
      } : null,
      // TODO conhecido: /api/leads/{id} ainda não expõe identity_candidate
      // (EC-7) — quando expuser, mapear aqui em vez de null fixo.
      vinculo_identidade: null,
    },
    activity: (real.activity ?? []).map((a) => ({
      tipo: a.tipo,
      timestamp: a.date_traceable ? a.occurred_at : null,
      fonte: a.source_system,
      titulo: ROTULO_TIPO_EVENTO[a.tipo] ?? a.tipo,
      descricao: a.detalhe ?? '',
      // TODO conhecido: o backend real ainda só grava um booleano
      // (date_traceable), não uma idade textual do último dado válido
      // (EC-8) — a Etapa A tinha essa string pronta a partir do fixture
      // curado a mão; a Etapa B precisa de uma migration extra para
      // calcular isso a partir de sync_state, ainda não construída.
      idade_dado_declarada: a.date_traceable
        ? null
        : 'Data não rastreável nesta fonte (idade exata do último dado válido ainda não calculada pelo backend real — TODO conhecido).',
    })),
    related: {
      conta: real.related?.conta ?? null,
      // Contrato de data-contract.md §2.3 usa `estagio`/`valor_contrato` —
      // a API real (fn_search_leads/view_receita) usa `stage_name`/
      // `contrato_valor`. Mapear os nomes aqui, não espalhar esse
      // conhecimento pelo resto da UI.
      oportunidade: oportunidades[0] ? {
        id: oportunidades[0].id,
        mrr: oportunidades[0].mrr,
        estagio: oportunidades[0].stage_name,
        valor_contrato: oportunidades[0].contrato_valor,
      } : null,
      // TODO conhecido: ad_campaign/cadeia de campanha ainda não está
      // ligada à API real.
      cadeia_campanha: null,
    },
  };
}

/**
 * Lista leads filtrados por interseção (AC-1.1). Todo filtro é combinável:
 * um lead só aparece se satisfizer TODOS os critérios informados.
 * @param {{segmento?: string[], canal?: string[], campanha?: string, periodo_inicio?: string, periodo_fim?: string}} filtros
 */
export async function listarLeads(filtros = {}) {
  const { segmento, campanha, periodo_inicio, periodo_fim } = filtros;

  if (_modoReal()) {
    const params = new URLSearchParams();
    if (segmento && segmento.length > 0) segmento.forEach((s) => params.append('segmento', s));
    if (campanha) params.set('campanha', campanha);
    const res = await _fetchReal(`api/leads?${params.toString()}`);
    if (!res.ok) throw new Error(`data-api (real): falha ao listar leads (HTTP ${res.status})`);
    const body = await res.json();
    let lista = body.leads.map(_adaptarItemLista);
    // periodo_inicio/periodo_fim: fn_search_leads ainda não recebe esse
    // filtro (não fazia parte do contrato original de fn_search_leads,
    // 3.19) — filtrado aqui, no cliente, sobre a página já retornada. Como
    // a Etapa A já fazia o mesmo filtro no cliente, isso NÃO é uma
    // regressão de comportamento, só de onde a linha roda.
    if (periodo_inicio) lista = lista.filter((l) => l.data_criacao >= periodo_inicio);
    if (periodo_fim) lista = lista.filter((l) => l.data_criacao <= periodo_fim);
    return lista;
  }

  const leads = await _loadList();
  return leads.filter((lead) => {
    if (segmento && segmento.length > 0 && !segmento.includes(lead.segmento)) return false;
    if (periodo_inicio && lead.data_criacao < periodo_inicio) return false;
    if (periodo_fim && lead.data_criacao > periodo_fim) return false;
    return true;
    // canal/campanha exigem o bloco atribuicao (só existe no detalhe) — a
    // Etapa B resolve isso via query no banco (fn_search_leads JÁ suporta
    // campanha, ver ramo _modoReal acima); a Etapa A filtra por
    // segmento/período na lista e deixa canal/campanha para quando o
    // detalhe é aberto. Registrado como limite conhecido da Etapa A, não
    // como bug — ver docs/architecture/data-contract.md §1.
  });
}

/**
 * Busca a ficha completa (Overview + Activity + Related) de um lead.
 * @param {string} id
 * @returns {Promise<object|null>} null se o id não existir (AC-6.1: a UI
 *   decide como tratar "não encontrado", este módulo só informa a ausência).
 */
export async function buscarLead(id) {
  if (_modoReal()) {
    const res = await _fetchReal(`api/leads/${encodeURIComponent(id)}`);
    if (!res.ok) throw new Error(`data-api (real): falha ao buscar lead ${id} (HTTP ${res.status})`);
    return _adaptarDetalheReal(await res.json());
  }

  const detalhes = await _loadDetail();
  return detalhes[id] ?? null;
}

/**
 * Deriva a qualidade de dados por fonte (subtask 5.15, EC-8/AC-9.2).
 */
export async function obterQualidadeDados() {
  if (_modoReal()) {
    const res = await _fetchReal(`api/meta`);
    if (!res.ok) throw new Error(`data-api (real): falha ao obter qualidade de dados (HTTP ${res.status})`);
    const body = await res.json();
    const porFonte = (body.fontes ?? []).map((f) => ({
      fonte: f.source,
      totalLeads: f.rows_target,
      ultimaAtividadeObservada: f.last_run_at,
    }));
    // TODO conhecido: /api/meta reporta falha por EXECUÇÃO de ingestão
    // (granularidade de lote), não por EVENTO individual como o fixture
    // curado da Etapa A — é um nível de detalhe mais grosso, honesto para
    // o que o backend real calcula hoje.
    const lacunas = (body.execucoes_recentes ?? [])
      .filter((e) => e.status === 'failed' || e.status === 'partial')
      .map((e) => ({
        leadId: null,
        leadNome: null,
        fonte: e.source,
        titulo: `Execução de ingestão (${e.object}) com status "${e.status}"`,
        idade_dado_declarada: e.error_message ?? `rows_source=${e.rows_source}, rows_target=${e.rows_target}`,
        ultimoEventoValidoTitulo: null,
        ultimoEventoValidoTimestamp: e.started_at,
      }));
    return { porFonte, lacunas };
  }

  const lista = await _loadList();
  const detalhes = await _loadDetail();

  const porFonte = {};
  for (const l of lista) {
    const f = l.fonte_dados;
    if (!porFonte[f]) porFonte[f] = { fonte: f, totalLeads: 0, ultimaAtividadeObservada: null };
    porFonte[f].totalLeads += 1;
    if (!porFonte[f].ultimaAtividadeObservada || l.data_criacao > porFonte[f].ultimaAtividadeObservada) {
      porFonte[f].ultimaAtividadeObservada = l.data_criacao;
    }
  }

  const lacunas = [];
  for (const [id, d] of Object.entries(detalhes)) {
    for (const a of d.activity ?? []) {
      if (a.idade_dado_declarada) {
        lacunas.push({
          leadId: id,
          leadNome: d.overview.nome,
          fonte: a.fonte,
          titulo: a.titulo,
          idade_dado_declarada: a.idade_dado_declarada,
          ultimoEventoValidoTitulo: a.descricao,
          ultimoEventoValidoTimestamp: a.timestamp,
        });
      }
    }
  }

  return { porFonte: Object.values(porFonte), lacunas };
}

/** Limpa o cache em memória — só usado por testes. */
export function _resetCacheParaTestes() {
  _listCache = null;
  _detailCache = null;
}
