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
//
// ── CUTOVER EM 2026-09-09 (subtask 7.1) ───────────────────────────────────
// Trocado de 'mock' para 'real'. Autorizado pelo usuário (gate CON-8), mas
// deliberadamente NÃO no momento em que a autorização veio: naquele instante
// `lead` tinha 13 registros, todos `source_system = 'seed_test'`, porque
// nenhum fluxo jamais havia lido a base de leads do RD Station. Virar a chave
// ali teria trocado 13 leads falsos ROTULADOS como mock por 13 leads falsos
// NÃO rotulados — estritamente pior.
//
// A chave virou depois de a ingestão existir e ser verificada em produção:
// 500 leads reais do RD Station, 766 eventos de conversão, 39 leads marcados
// como teste (e portanto fora dos filtros por padrão).
//
// Para voltar: trocar por 'mock'. É uma linha, e o fixture segue no repo.
const MODO_DADOS = 'real';

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
// TRAVADO EM HOST LOCAL (endurecido em 2026-09-09, após auditoria da borda
// em produção). Antes bastava a variável existir, em qualquer host. O risco
// não era vazamento — a chave nunca esteve no bundle, e quem injetasse a
// variável precisaria já conhecer um valor válido para conseguir algo. O
// problema era outro: com MODO_DADOS='real', este caminho tem PRECEDÊNCIA
// sobre o caminho seguro, então quem conseguisse injetar script na página
// (XSS, extensão maliciosa) poderia forçar o dashboard a abandonar as
// chamadas same-origin e passar a bater direto no n8n. Degradação evitável,
// custo de evitar ~zero: em produção este branch agora é inalcançável.
// Não quebra nada: os specs Playwright rodam em localhost:8123 e nenhum
// deles usa esta variável (o uso foi manual, uma vez, na subtask 7.1).
function _modoTesteLocal() {
  if (typeof window === 'undefined' || !window.__CRM_API_KEY__) return false;
  const host = window.location.hostname;
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1' || host === '';
}

// Fixar o modo mock por query string, SÓ em host local. Existe porque o
// cutover para 'real' quebraria os specs Playwright: eles rodam em
// localhost:8123, não têm chave de API, e passariam a bater em `/api/*`
// same-origin — que num servidor estático local não existe. Sem isto, virar
// a chave desativaria silenciosamente a suíte e2e, o que é pior do que a
// suíte falhar: uma suíte que não exercita nada continua verde.
//
// Travado no mesmo host-guard de _modoTesteLocal, e por isso INALCANÇÁVEL em
// produção. Forçar mock em produção seria inofensivo em termos de dados (o
// fixture não tem PII), mas mostraria número falso sem rótulo — exatamente o
// problema que o cutover corrigiu.
// Avaliado UMA VEZ, na carga do módulo, e não a cada chamada. O motivo é um
// bug real encontrado pelos specs: `atualizarEstado()` reescreve a query
// string inteira ao aplicar/limpar filtros, e isso APAGAVA o `dados=mock`
// junto — a página caía em modo real no meio do teste e passava a buscar
// `/api/*` num servidor estático local, que não tem esses caminhos.
//
// Ler uma vez também é o comportamento correto por natureza: isto é uma
// chave de sessão de teste, não um filtro. Não deve mudar durante a
// navegação.
const _MOCK_FORCADO_LOCAL = (() => {
  if (typeof window === 'undefined') return false;
  const host = window.location.hostname;
  const local = host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1' || host === '';
  if (!local) return false;
  try {
    return new URLSearchParams(window.location.search).get('dados') === 'mock';
  } catch (e) {
    return false;
  }
})();

function _modoReal() {
  if (_MOCK_FORCADO_LOCAL) return false;
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
    // Corrigido em 2026-09-09: era `'salesforce'` FIXO, com um TODO dizendo
    // que deixaria de ser fixo "quando o RD Station entrar na busca". Entrou
    // (fn_search_leads v2 lê view_lead_perfil, que cobre as duas fontes), e
    // o valor fixo passaria a MENTIR — rotularia 125 leads do RD Station como
    // Salesforce. Agora vem do dado.
    fonte_dados: real.fonte_dados ?? real.source_system ?? null,

    // Dimensões novas (data-contract.md §1, todas com cobertura medida).
    data_conversao: real.data_conversao ?? null,
    trimestre: real.trimestre ?? null,
    // Eixo A — origem de conversão. NUNCA portadora de investimento (§1.2).
    origem_conversao: real.origem_conversao ?? null,
    origem_ultima_conversao: real.origem_ultima_conversao ?? null,
    qtd_conversoes: Number(real.qtd_conversoes ?? 0),
    tags: Array.isArray(real.tags) ? real.tags : [],
    cargo: real.cargo ?? null,
    cargo_grupo: real.cargo_grupo ?? 'nao_informado',
    tamanho_empresa: real.tamanho_empresa ?? 'nao_informado',
    atendido_por: real.atendido_por ?? null,
    // Eixo B — campanha de mídia paga. Único eixo que pode receber
    // investimento e ROI (§1.2). Esparso de propósito: 7,6% medido.
    campanha_midia: real.campanha_midia ?? null,
    plataforma: real.plataforma ?? null,
    is_teste: real.is_teste === true,
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
// Dimensões multivalor do contrato §1. Repetidas na query string
// (?tag=a&tag=b); o backend combina por OR dentro da dimensão e por AND
// entre dimensões (AC-1.1: interseção real, nunca substituição).
const DIMENSOES_MULTI = [
  'segmento', 'estagio_funil', 'cargo_grupo', 'tamanho_empresa',
  'atendido_por', 'plataforma', 'trimestre', 'origem_conversao', 'tags',
];

export async function listarLeads(filtros = {}) {
  const {
    segmento, campanha, campanha_midia, periodo_inicio, periodo_fim,
    incluir_teste, limit, offset,
  } = filtros;

  if (_modoReal()) {
    const params = new URLSearchParams();

    for (const dim of DIMENSOES_MULTI) {
      const v = filtros[dim];
      if (v === undefined || v === null || v === '') continue;
      for (const item of (Array.isArray(v) ? v : [v])) {
        if (item !== '' && item !== null && item !== undefined) params.append(dim, item);
      }
    }

    // TRÊS conceitos distintos, e a primeira versão desta função os
    // confundiu (tratava `campanha` como apelido de `campanha_midia`, o que
    // quebrou o pivô campanha→leads e foi pego por 4 specs Playwright):
    //
    //   campanha         valor_bruto do sinal de atribuição — o pivô (AC-4.1)
    //   origem_conversao eixo A, ativo que converteu (cobertura 100%)
    //   campanha_midia   eixo B, veiculação paga (7,6%) — ÚNICO com ROI
    //
    // São independentes e combináveis. Nunca aliasar um no outro.
    if (campanha) params.set('campanha', campanha);
    if (campanha_midia) params.set('campanha_midia', campanha_midia);

    // Período agora é resolvido no SERVIDOR, sobre data_conversao. Antes era
    // filtrado no cliente sobre a página já retornada — o que significava
    // que um período combinado com paginação descartava linhas da página em
    // vez de reconsultar, e o total exibido não correspondia ao filtro.
    if (periodo_inicio) params.set('periodo_inicio', periodo_inicio);
    if (periodo_fim) params.set('periodo_fim', periodo_fim);

    // Dado de teste fica FORA por padrão: 21% da base real é teste, e
    // incluí-lo por omissão inflaria toda contagem. A aba Qualidade de dados
    // é quem pede explicitamente.
    if (incluir_teste) params.set('incluir_teste', 'true');

    if (limit) params.set('limit', String(limit));
    if (offset) params.set('offset', String(offset));

    const res = await _fetchReal(`api/leads?${params.toString()}`);
    if (!res.ok) throw new Error(`data-api (real): falha ao listar leads (HTTP ${res.status})`);
    const body = await res.json();
    const lista = body.leads.map(_adaptarItemLista);
    // O total vem do servidor (window function em fn_search_leads), então
    // reflete o filtro inteiro e não só a página. Anexado sem quebrar quem
    // trata o retorno como array.
    lista.total = Number(body.total ?? lista.length);
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
 * Opções disponíveis de cada filtro, com contagem de leads — vindas do DADO
 * (`fn_opcoes_filtro`), nunca de enum embutido no código.
 *
 * É a correção estrutural do erro que produziu os 4 filtros inventados da v1
 * do contrato: a interface não decide mais quais valores existem. Se um campo
 * está vazio na fonte, ele não aparece como opção; se um cargo novo surgir,
 * aparece sem alterar código.
 *
 * A contagem por opção não é enfeite: é o que permite nunca oferecer uma
 * opção que devolve zero, e mostrar onde vale filtrar.
 *
 * @returns {Promise<object|null>} null quando o backend não expõe (mock).
 */
export async function obterOpcoesFiltro() {
  if (_modoReal()) {
    const res = await _fetchReal(`api/meta`);
    if (!res.ok) throw new Error(`data-api (real): falha ao obter opções de filtro (HTTP ${res.status})`);
    const body = await res.json();
    return body.opcoes_filtro ?? null;
  }

  // Modo mock: as opções são derivadas do PRÓPRIO fixture, não devolvidas
  // como null nem inventadas. O princípio ("a opção vem do dado") vale nos
  // dois modos — o que muda é qual dado.
  //
  // O fixture da Etapa A só tem `segmento` e `estagio_funil`; as dimensões
  // firmográficas e de atribuição chegaram depois, com a revisão do
  // contrato. Então aqui elas vêm vazias — e dimensão vazia não é oferecida
  // como filtro, que é exatamente o comportamento certo.
  const leads = await _loadList();
  const contar = (campo) => {
    const m = new Map();
    for (const l of leads) {
      const v = l[campo];
      if (v === null || v === undefined || v === '') continue;
      m.set(v, (m.get(v) ?? 0) + 1);
    }
    return [...m.entries()]
      .map(([valor, n]) => ({ valor, leads: n }))
      .sort((a, b) => b.leads - a.leads || String(a.valor).localeCompare(String(b.valor)));
  };

  return {
    segmento: contar('segmento'),
    estagio_funil: contar('estagio_funil'),
    cargo_grupo: [], tamanho_empresa: [], atendido_por: [],
    plataforma: [], trimestre: [], campanha_midia: [],
    tags: [], origem_conversao: [],
    totais: { leads: leads.length, leads_teste: 0, eventos_conversao: 0,
              origens_distintas: 0, leads_sem_conversao: leads.length },
    grao: {},
    _fonte: 'fixture-mock',
  };
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
      // Pode ser null quando a fonte nunca completou uma execução íntegra
      // (o watermark só avança em status=ok). A view trata null; antes ela
      // chamava .slice() direto e quebrava a aba inteira.
      ultimaAtividadeObservada: f.last_run_at ?? null,
      objeto: f.object ?? null,
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
    // Bloco novo: contagem de exclusão POR REGRA (contrato §1.6 — exclusão
    // silenciosa é proibida) e os cargos que nenhuma regra classificou (§1.3,
    // para a tabela de regras evoluir com evidência). Vem de
    // fn_qualidade_dados; null quando o ramo de /api/meta não respondeu.
    return { porFonte, lacunas, qualidade: body.qualidade ?? null };
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

  // `qualidade: null` no mock, de propósito: o fixture não tem regra de dado
  // de teste nem cargo livre para classificar, e fabricar números aqui faria
  // a aba mostrar uma auditoria que não existe. A view trata null mostrando
  // que a seção depende do backend real.
  return { porFonte: Object.values(porFonte), lacunas, qualidade: null };
}

/** Limpa o cache em memória — só usado por testes. */
export function _resetCacheParaTestes() {
  _listCache = null;
  _detailCache = null;
}
