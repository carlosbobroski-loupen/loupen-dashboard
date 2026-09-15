// functions/api/[[path]].js — Cloudflare Pages Function que serve /api/* .
//
// É AQUI, E SOMENTE AQUI, que o segredo da API vive do lado do servidor.
// Substitui o par "Origin Rule + Request Header Modification" do desenho
// original de phase-4 (que dependia de acesso à conta Cloudflare que
// administra os domínios — acesso que não existe, ver ADR-018).
//
// POR QUE ISTO RESOLVE O PROBLEMA QUE UM SITE ESTÁTICO NÃO RESOLVE:
// esta função roda no edge da Cloudflare, não no navegador. `context.env.
// CRM_API_KEY` é um secret encriptado do projeto Pages — não é servido para
// o cliente, não aparece em "ver código-fonte", não aparece no DevTools.
// O navegador chama `/api/leads` (same-origin) sem chave nenhuma; quem
// acrescenta o header `X-CRM-Api-Key` é este código. D11/P-ING-6 (proibido
// segredo de API no front-end) fica satisfeito de verdade, não por convenção.
//
// ALLOWLIST, NÃO PROXY ABERTO — decisão de segurança deliberada:
// esta função fica atrás do Cloudflare Access, então quem chega aqui já é
// um usuário autenticado @loupen.com.br. Isso NÃO é suficiente para deixar
// a rota aberta: um proxy genérico permitiria a qualquer pessoa autenticada
// chamar QUALQUER webhook do n8n (inclusive os de automação com efeito
// colateral real, como os que escrevem em planilha ou disparam CAPI),
// usando a chave que ela mesma nunca vê. As três rotas de leitura são
// listadas explicitamente e nada mais passa.
//
// SOMENTE GET, também deliberado: a camada é read-only por decisão travada
// do épico (Salesforce e RD Station seguem os únicos sistemas de registro).
// Um POST/PUT/DELETE aqui não tem caso de uso legítimo hoje.

// Achado real de 5.1 encapsulado aqui: um webhook do n8n com path dinâmico
// (`:id`) é servido com o webhookId PREPENDED na URL, o que não é óbvio na
// UI do n8n. O cliente não deveria precisar saber disso — esta função
// traduz `/api/leads/{id}` para a forma real. Ver docs/architecture/
// edge-routing.md.
const N8N_BASE = 'https://n8n.loupenapps.com.br/webhook';
const N8N_DETAIL_WEBHOOK_ID = '855a5444-c212-4c84-b993-ef082e35f999';

export async function onRequest(context) {
  const { request, env, params } = context;

  if (request.method !== 'GET') {
    return json({ error: 'Método não permitido: esta camada é somente leitura.' }, 405);
  }

  if (!env.CRM_API_KEY) {
    // Falha explícita e imediata. Sem isto, um deploy sem o secret
    // configurado chamaria o n8n sem header e receberia 403 — erro
    // confuso, longe da causa real.
    return json({ error: 'CRM_API_KEY não configurada no projeto Pages.' }, 500);
  }

  // `params.path` é o catch-all: /api/leads/abc -> ['leads','abc']
  const segments = Array.isArray(params.path) ? params.path : [params.path].filter(Boolean);
  const url = new URL(request.url);
  const upstream = resolverRota(segments, url.search);

  if (!upstream) {
    return json({ error: `Rota não permitida: /api/${segments.join('/')}` }, 404);
  }

  const res = await fetch(upstream, {
    method: 'GET',
    headers: { 'X-CRM-Api-Key': env.CRM_API_KEY },
  });

  // Repassa corpo e status do n8n, mas com cabeçalhos próprios — não
  // vazar header de upstream que possa identificar a infra por trás.
  return new Response(res.body, {
    status: res.status,
    headers: {
      'content-type': res.headers.get('content-type') || 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

// Allowlist. Devolve a URL upstream ou null.
function resolverRota(segments, search) {
  // GET /api/meta
  if (segments.length === 1 && segments[0] === 'meta') {
    return `${N8N_BASE}/api/meta`;
  }

  // GET /api/leads?<filtros>
  if (segments.length === 1 && segments[0] === 'leads') {
    return `${N8N_BASE}/api/leads${search || ''}`;
  }

  // GET /api/marketing-funil
  // Leads de marketing do RD Station cruzados com o desfecho deles no
  // Salesforce (migration 077). Sem query string: o recorte é a própria
  // definição da view, não um filtro do cliente.
  if (segments.length === 1 && segments[0] === 'marketing-funil') {
    return `${N8N_BASE}/api/marketing-funil`;
  }

  // GET /api/leads/{id}
  if (segments.length === 2 && segments[0] === 'leads') {
    const id = segments[1];
    // Id do Salesforce/interno: alfanumérico simples. Recusar qualquer
    // outra coisa evita que um id malformado vire path traversal na URL
    // do upstream.
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return null;
    return `${N8N_BASE}/${N8N_DETAIL_WEBHOOK_ID}/api/leads/${encodeURIComponent(id)}`;
  }

  return null;
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}
