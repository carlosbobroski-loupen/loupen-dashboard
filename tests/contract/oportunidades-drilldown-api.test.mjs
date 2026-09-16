// tests/contract/oportunidades-drilldown-api.test.mjs — a igualdade que o
// painel de drill-down promete, medida contra a API REAL.
//
// PARA CADA NÚMERO CLICÁVEL DA ABA: o total que a API devolve sob o recorte que
// `filtrosDoPainel()` monta tem de ser EXATAMENTE o número que o card mostra
// (`def.esperado()` sobre a mesma resposta que pintou os cards).
//
// Por que contra a API real e não contra o fixture: o fixture não refiltra (ver
// data-api.js), então ele não consegue provar nada sobre recorte. E a metade
// interessante do risco está fora do nosso código — é o endpoint
// /api/oportunidades encaminhar (ou não) cada parâmetro. Dois já foram pegos
// assim: `so_nao_classificado` e `categoria` chegam ao n8n e MORREM lá, apesar
// de `fn_search_oportunidades` aceitar os dois. O painel de cobertura só existe
// porque a medição mostrou isso a tempo e o recorte foi reescrito em `segmento`.
//
// O CAMINHO EXERCITADO É O DE PRODUÇÃO INTEIRO: `obterOportunidades` de
// data-api.js, com a sua própria serialização de parâmetros. O único ponto
// substituído é o `fetch` global, que reescreve `/api/*` (same-origin, servido
// pela Pages Function) para o webhook do n8n com o header — porque em node não
// existe a borda que injeta a chave.
//
// Rodar: N8N_API_HEADER_SECRET=... node --test tests/contract/oportunidades-drilldown-api.test.mjs
// (ou `set -a; . .env; set +a` antes). Sem a chave, os testes de rede são
// PULADOS — e o primeiro teste do arquivo denuncia isso em vez de o arquivo
// passar em silêncio parecendo que verificou alguma coisa.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PAINEIS, definicaoDoPainel, filtrosDoPainel, ultimosMeses,
} from '../../assets/js/views/oportunidades.js';
import { obterOportunidades } from '../../assets/js/data-api.js';

const SEGREDO = process.env.N8N_API_HEADER_SECRET;
const API_BASE = 'https://n8n.loupenapps.com.br/webhook';
const semRede = !SEGREDO && 'sem N8N_API_HEADER_SECRET no ambiente — exporte a chave para medir contra a API real';

// A borda de produção (functions/api/[[path]].js) injeta o header do lado do
// servidor. Em node não há borda: este stub faz o mesmo papel, e só ele.
const fetchOriginal = globalThis.fetch;
globalThis.fetch = (url, opcoes = {}) => {
  const caminho = String(url);
  if (!caminho.startsWith('/api/')) return fetchOriginal(url, opcoes);
  return fetchOriginal(`${API_BASE}${caminho}`, {
    ...opcoes,
    headers: { ...(opcoes.headers ?? {}), 'X-CRM-Api-Key': SEGREDO },
  });
};

const JANELA = ultimosMeses(12);
const ESTADO_BASE = {
  ...JANELA, segmento: '', fase: '', desfecho: '', moeda: '',
  lead_vinculo_regra: '', busca: '', ordenar_por: 'recentes',
  so_divergentes: false, so_sem_valor: false,
};

/** A resposta que pinta a aba — a MESMA de onde sai todo número esperado. */
async function respostaDaAba(est) {
  return obterOportunidades({
    de: est.de, ate: est.ate,
    segmento: est.segmento || undefined,
    fase: est.fase || undefined,
    desfecho: est.desfecho || undefined,
    moeda: est.moeda || undefined,
    lead_vinculo_regra: est.lead_vinculo_regra || undefined,
    limit: 1,
  });
}

/** Todos os alvos clicáveis, inclusive os dinâmicos que a resposta revela. */
function todosOsAlvos(resp) {
  const tipos = Object.keys(PAINEIS);
  for (const f of resp.funil ?? []) if (f.fase) tipos.push(`fase:${f.fase}`);
  for (const s of resp.segmento ?? []) tipos.push(`segmento:${s.segmento_aba}`);
  // Linha de categoria só abre com oportunidade — as `so_lead` valem zero por
  // construção e a tabela declara isso em vez de oferecer um clique vazio.
  for (const c of resp.categoria ?? []) {
    if (Number(c.qtd_oportunidades) > 0) tipos.push(`categoria:${c.segmento_aba}:${c.categoria ?? ''}`);
  }
  return tipos;
}

/**
 * Mede UM painel. Devolve o que foi medido, sem assertar — quem asserta é o
 * teste, e assim a tabela de saída sai inteira mesmo quando uma linha falha.
 */
async function medir(tipo, est, resp) {
  const def = definicaoDoPainel(tipo);
  const plano = filtrosDoPainel(def, est);
  const esperado = def.esperado(resp);
  if (plano.vazio) return { tipo, rotulo: def.rotulo, esperado, obtido: 0, vazio: true };
  const r = await obterOportunidades(plano.filtros);
  return { tipo, rotulo: def.rotulo, esperado, obtido: Number(r.lista?.total), vazio: false, filtros: plano.filtros };
}

function imprimir(titulo, linhas) {
  console.log(`\n── ${titulo} ──`);
  for (const l of linhas) {
    const ok = l.obtido === l.esperado ? 'OK  ' : 'ERRO';
    console.log(`  ${ok} ${String(l.tipo).padEnd(26)} painel=${String(l.obtido).padStart(6)}  card=${String(l.esperado).padStart(6)}${l.vazio ? '  (interseção vazia, sem chamada)' : ''}`);
  }
}

test('a suíte de rede está de fato rodando (e não passando por estar pulada)', (t) => {
  // Sem esta guarda, rodar o arquivo sem a chave produziria uma saída toda
  // verde que não mediu nada — o formato exato de verificação decorativa que
  // este projeto já teve seis vezes.
  //
  // `t.todo()` e não `assert.ok(true)`: um teste verde a menos, uma PENDÊNCIA
  // a mais. O runner passa a imprimir `todo 1` no resumo e a marcar a linha
  // com `TODO`, então quem roda o arquivo sem a chave vê, no resumo, que os
  // cinco testes que medem a borda não mediram nada. A versão anterior deste
  // guard escrevia um aviso no meio da saída e ainda assim contava como `pass`
  // — e no fluxo padrão (sem `. .env`) o vigia da borda estava, ele próprio,
  // calado.
  if (semRede) {
    t.todo(`os 5 testes que medem a API real NÃO rodaram: ${semRede}. `
      + 'Rode `set -a; . .env; set +a; node --test tests/contract/oportunidades-drilldown-api.test.mjs`.');
    return;
  }
  assert.ok(SEGREDO, 'com a chave presente este teste é uma asserção de verdade');
});

test('CADA número clicável da aba abre EXATAMENTE o conjunto que ele conta', { skip: semRede }, async () => {
  const resp = await respostaDaAba(ESTADO_BASE);
  const alvos = todosOsAlvos(resp);
  assert.ok(alvos.length >= 14, `esperava pelo menos 14 alvos, a resposta rendeu ${alvos.length}`);

  const linhas = [];
  for (const tipo of alvos) linhas.push(await medir(tipo, ESTADO_BASE, resp));
  imprimir(`recorte padrão da aba (${JANELA.de} → ${JANELA.ate})`, linhas);

  for (const l of linhas) {
    assert.equal(typeof l.esperado, 'number', `${l.tipo}: o número do card não veio da resposta`);
    assert.equal(l.obtido, l.esperado,
      `${l.tipo} ("${l.rotulo}"): o painel abriu ${l.obtido} e o card marca ${l.esperado}`);
  }

  // A soma dos desfechos abertos pelos cards tem de ser o universo: se um
  // painel estivesse medindo o conjunto errado mas por acaso batendo, esta
  // segunda igualdade (sobre outra decomposição) o pegaria.
  const porDesfecho = ['ganhas', 'perdidas', 'abertas', 'fora_de_fase', 'sem_declaracao']
    .map((t) => linhas.find((l) => l.tipo === t).obtido)
    .reduce((a, b) => a + b, 0);
  const total = linhas.find((l) => l.tipo === 'total').obtido;
  assert.equal(porDesfecho, total, 'os painéis de desfecho têm de particionar o painel total');
});

test('com filtro ativo na aba, os painéis continuam batendo — cada um com a herança da SUA seção', { skip: semRede }, async () => {
  // O CENÁRIO PRECISA TER ATIVOS, AO MESMO TEMPO, OS QUATRO FILTROS QUE AS
  // SEÇÕES TRATAM DE FORMA DIFERENTE — senão ele não consegue distinguir uma
  // herança certa de uma errada. Uma versão anterior deste teste usava
  // `moeda=USD` + `fase=ganho` e passava mesmo com o painel do funil herdando
  // `desfecho`: não havia filtro de desfecho ativo para vazar. Medido: a
  // mutação passou verde, e por isso o cenário é este.
  //
  //   moeda              → as três seções aplicam; todo painel herda
  //   desfecho, fase     → funil IGNORA; painel de funil não pode herdar
  //   segmento, vínculo  → tabela de segmento IGNORA; painel dela não pode herdar
  const est = { ...ESTADO_BASE, moeda: 'USD', desfecho: 'ganha', fase: 'ganho', lead_vinculo_regra: 'oportunidade' };
  const resp = await respostaDaAba(est);
  const alvos = [
    'total', 'ganhas', 'perdidas', 'sem_origem_classificada', 'ganhas_sem_valor',
    ...(resp.funil ?? []).filter((f) => f.fase).map((f) => `fase:${f.fase}`),
    ...(resp.segmento ?? []).map((s) => `segmento:${s.segmento_aba}`),
    ...(resp.categoria ?? []).filter((c) => Number(c.qtd_oportunidades) > 0)
      .map((c) => `categoria:${c.segmento_aba}:${c.categoria ?? ''}`),
  ];
  const linhas = [];
  for (const tipo of alvos) linhas.push(await medir(tipo, est, resp));
  imprimir('com moeda=USD, desfecho=ganha, fase=ganho e vínculo=oportunidade ativos', linhas);

  for (const l of linhas) {
    assert.equal(l.obtido, l.esperado,
      `${l.tipo} ("${l.rotulo}"): o painel abriu ${l.obtido} e o número na tela marca ${l.esperado}`);
  }

  // AS TRÊS CONDIÇÕES QUE FAZEM O CENÁRIO DISCRIMINAR. Sem elas, tudo acima
  // poderia estar batendo por os filtros não separarem nada.
  const foraDoFunil = linhas.filter((l) => l.tipo.startsWith('fase:') && !l.tipo.endsWith(':ganho'));
  assert.ok(foraDoFunil.some((l) => l.obtido > 0),
    'precisa haver painel de funil NÃO-ganho com linhas: é ele que fica vazio se o painel herdar o desfecho');
  const seg = linhas.filter((l) => l.tipo.startsWith('segmento:'));
  assert.ok(seg.reduce((s, l) => s + l.obtido, 0) > linhas.find((l) => l.tipo === 'total').obtido,
    'a tabela de segmento tem de estar descrevendo um recorte MAIOR que os cards (ela ignora vínculo) — se não estiver, herdar ou não herdar daria o mesmo');
  assert.ok(linhas.find((l) => l.tipo === 'total').obtido > 0, 'o recorte filtrado não pode estar vazio, ou o teste não discrimina');
});

test('INTERSEÇÃO VAZIA contra a API: o card marca 0 e o painel não inventa linhas', { skip: semRede }, async () => {
  // Com `desfecho=perdida` na barra, o card "Ganhas" marca 0. Um painel que
  // trocasse o filtro em vez de intersectar abriria ~1.000 linhas.
  const est = { ...ESTADO_BASE, desfecho: 'perdida' };
  const resp = await respostaDaAba(est);
  assert.equal(Number(resp.cards.qtd_ganhas), 0, 'os cards precisam marcar 0 ganhas sob desfecho=perdida');

  const l = await medir('ganhas', est, resp);
  imprimir('com desfecho=perdida ativo (interseção vazia)', [l]);
  assert.equal(l.vazio, true, 'o plano tem de reconhecer a exclusão mútua');
  assert.equal(l.obtido, 0);
  assert.equal(l.esperado, 0);

  // PROVA DE QUE A ASSERÇÃO ACIMA DISCRIMINA: o recorte que o painel teria
  // aberto se trocasse o filtro em vez de intersectar devolve MUITA linha.
  const trocando = await obterOportunidades({ de: est.de, ate: est.ate, desfecho: 'ganha', limit: 1 });
  console.log(`  (se trocasse o filtro em vez de intersectar, abriria ${trocando.lista.total} linhas embaixo de um card que marca 0)`);
  assert.ok(Number(trocando.lista.total) > 100, 'sem isto, "vazio" seria vazio por acaso e o teste não provaria nada');
});

test('as DUAS linhas de categoria nula, na base inteira, abrem cada uma a SUA — não a soma', { skip: semRede }, async () => {
  // Este é o caso que a janela de 12 meses esconde. Nela só existe UMA linha de
  // categoria nula (NaoClassificado), e `so_nao_classificado=true` acerta o
  // número por coincidência. Na base inteira existem DUAS (NaoClassificado e
  // SemOrigem) e aquele interruptor devolve a SOMA das duas — que não é
  // nenhuma das duas linhas. Por isso o recorte da linha nula é o SEGMENTO.
  const est = { ...ESTADO_BASE, de: null, ate: null };
  const resp = await obterOportunidades({ limit: 1 });
  const nulas = (resp.categoria ?? []).filter((c) => c.categoria === null);
  const somaDasDuas = await obterOportunidades({ limit: 1, so_nao_classificado: true });
  console.log('\n── linhas de categoria nula, base inteira ──');
  console.log(`  so_nao_classificado=true (o atalho errado) -> ${somaDasDuas.lista.total}`);

  assert.equal(nulas.length, 2, 'a base inteira precisa ter as duas linhas nulas, ou este teste não prova nada');
  const linhas = [];
  for (const c of nulas) linhas.push(await medir(`categoria:${c.segmento_aba}:`, est, resp));
  imprimir('linha de categoria nula, uma a uma', linhas);
  for (const l of linhas) assert.equal(l.obtido, l.esperado, `${l.tipo}: painel ${l.obtido} vs linha ${l.esperado}`);

  // A PROVA DE QUE O ATALHO ESTARIA ERRADO: o interruptor devolve a soma, e a
  // soma não é igual a nenhuma das duas linhas.
  const soma = linhas.reduce((s, l) => s + l.esperado, 0);
  assert.equal(Number(somaDasDuas.lista.total), soma, 'so_nao_classificado devolve a soma das duas linhas');
  for (const l of linhas) {
    assert.notEqual(l.esperado, soma,
      `se a linha ${l.tipo} fosse igual à soma, este teste não distinguiria o recorte certo do atalho`);
  }
});

test('o endpoint encaminha `categoria` e `so_nao_classificado` — e um valor inexistente NÃO passa batido', { skip: semRede }, async () => {
  // HISTÓRICO, porque a asserção inverteu de sinal e isso precisa ficar legível:
  // até 2026-09-16 este teste afirmava o CONTRÁRIO. O Code node "Montar
  // filtros" do n8n tinha uma whitelist escrita antes das migrations 100 e
  // 103/104, e descartava `categoria`, `lead_source` e `so_nao_classificado`
  // EM SILÊNCIO — a tela pedia um recorte e recebia o universo, com 200 e sem
  // erro nenhum. A whitelist foi corrigida; este teste passou a vigiar o lado
  // de cá do interruptor.
  //
  // O QUE ELE PEGA AGORA é a regressão: se a whitelist voltar a ficar atrás de
  // uma migration, o filtro para de estreitar e as três primeiras asserções
  // caem. O par negativo (categoria inexistente → 0) é o que separa "filtrou"
  // de "devolveu tudo": sem ele, um filtro quebrado que devolvesse o universo
  // passaria em qualquer comparação de desigualdade.
  const base = await obterOportunidades({ de: JANELA.de, ate: JANELA.ate, limit: 1 });
  const comCategoria = await obterOportunidades({ de: JANELA.de, ate: JANELA.ate, limit: 1, categoria: 'Evento/Webinar' });
  const comNaoClass = await obterOportunidades({ de: JANELA.de, ate: JANELA.ate, limit: 1, so_nao_classificado: true });
  const comLeadSource = await obterOportunidades({ de: JANELA.de, ate: JANELA.ate, limit: 1, lead_source: 'GoTo' });
  const inexistente = await obterOportunidades({ de: JANELA.de, ate: JANELA.ate, limit: 1, categoria: 'NaoExisteEssaCategoria' });
  console.log('\n── parâmetros que o endpoint encaminha (whitelist do n8n) ──');
  console.log(`  sem filtro                        lista=${base.lista.total}`);
  console.log(`  categoria=Evento/Webinar          lista=${comCategoria.lista.total}`);
  console.log(`  lead_source=GoTo                  lista=${comLeadSource.lista.total}`);
  console.log(`  so_nao_classificado=true          lista=${comNaoClass.lista.total}`);
  console.log(`  categoria=NaoExisteEssaCategoria  lista=${inexistente.lista.total}   ← teste negativo`);

  const totalBase = Number(base.lista.total);
  assert.ok(Number(comCategoria.lista.total) > 0 && Number(comCategoria.lista.total) < totalBase,
    '`categoria` tem de ESTREITAR; se voltar a valer o total inteiro, a whitelist do n8n regrediu');
  assert.ok(Number(comLeadSource.lista.total) > 0 && Number(comLeadSource.lista.total) < totalBase,
    '`lead_source` está em fn_search_oportunidades desde a migration 100');
  assert.ok(Number(comNaoClass.lista.total) > 0 && Number(comNaoClass.lista.total) < totalBase,
    '`so_nao_classificado` tem de estreitar');
  assert.equal(Number(inexistente.lista.total), 0,
    'categoria inexistente tem de devolver ZERO — se devolver o universo, o parâmetro está sendo descartado de novo');

  // E o agregado, que é o que a seção de categoria desenha.
  assert.ok(Array.isArray(base.categoria) && base.categoria.length > 0, 'a resposta tem de trazer `categoria[]`');
  const soma = base.categoria.reduce((s, c) => s + Number(c.qtd_oportunidades), 0);
  assert.equal(soma, Number(base.categoria[0].total_do_recorte), 'as categorias têm de particionar o recorte');
  assert.equal(soma, totalBase, 'e fechar com o total da lista');
});
