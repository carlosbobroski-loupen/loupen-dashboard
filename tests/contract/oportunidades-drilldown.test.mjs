// tests/contract/oportunidades-drilldown.test.mjs — o painel que abre ao
// clicar num número da aba Oportunidades.
//
// A ÚNICA COISA QUE ESTE PAINEL PROMETE é que o total dele é o número clicado.
// Tudo aqui existe para provar isso sem navegador, em três frentes:
//
//   1. O NÚMERO PINTADO E O `data-esperado` SÃO O MESMO. Se o card mostrasse
//      987 e mandasse 840 para o painel, a conferência da tela passaria a
//      comparar o painel contra um número que ninguém viu.
//   2. O RECORTE DO PAINEL É O PREDICADO DA SEÇÃO. Cada seção da aba aplica um
//      conjunto diferente de filtros; herdar o que a seção ignora faz a lista
//      deixar de corresponder à linha que a abriu.
//   3. NÚMERO QUE NÃO É CONJUNTO NÃO VIRA BOTÃO. Win rate, receita, ticket e
//      pipeline não podem abrir lista nenhuma.
//
// A igualdade painel × card contra a API REAL está em
// `oportunidades-drilldown-api.test.mjs` — este arquivo é a parte pura.
//
// Rodar: node --test tests/contract/oportunidades-drilldown.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  PAINEIS, definicaoDoPainel, filtrosDoPainel, ignoradosDoPainel,
  renderKpis, renderFunil, renderSegmento, renderForaDoValor, renderCategoria,
  badgeDeCategoria, exemploQueProibeATaxa, escapeHtml, conferirVinculo,
  renderPainelSub, renderRodapePainel,
} from '../../assets/js/views/oportunidades.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(
  join(__dirname, '..', '..', 'assets', 'data', 'mock', 'oportunidades.json'), 'utf8'));
const PADRAO = fixture.padrao;

// Estado da aba sem filtro nenhum, do jeito que a view o mantém.
const LIMPO = {
  de: '2025-09-16', ate: '2026-09-17', segmento: '', fase: '', desfecho: '',
  moeda: '', lead_vinculo_regra: '', busca: '', ordenar_por: 'recentes',
  so_divergentes: false, so_sem_valor: false,
};

/** Extrai os pares (tipo, esperado) que o HTML oferece para clique. */
function drills(html) {
  const out = [];
  const re = /data-drill="([^"]+)"[^>]*data-esperado="([^"]*)"/g;
  let m;
  while ((m = re.exec(html)) !== null) out.push({ tipo: m[1], esperado: Number(m[2]) });
  return out;
}

const HTML_KPIS = renderKpis(PADRAO.cards);
const HTML_FUNIL = renderFunil(PADRAO.funil);
const HTML_SEGMENTO = renderSegmento(PADRAO.segmento);
const HTML_FORA = renderForaDoValor(PADRAO.cards);
const TODOS = [...drills(HTML_KPIS), ...drills(HTML_FUNIL), ...drills(HTML_SEGMENTO), ...drills(HTML_FORA)];

// ───────────────────────────────────────────────────────────────────────────
// 1 — o número pintado e o número mandado ao painel são o mesmo
// ───────────────────────────────────────────────────────────────────────────
test('todo elemento clicável resolve para um painel conhecido', () => {
  assert.ok(TODOS.length >= 14, `esperava pelo menos 14 alvos de clique, achei ${TODOS.length}`);
  for (const d of TODOS) {
    assert.ok(definicaoDoPainel(d.tipo), `tipo "${d.tipo}" está no HTML e não resolve para painel nenhum`);
  }
});

test('o `data-esperado` de cada alvo é EXATAMENTE o que a mesma resposta declara', () => {
  // As duas fontes do número esperado (o atributo no DOM, para quem clica; e
  // `def.esperado(resposta)`, para quem reabre pela URL) têm de concordar —
  // senão um link compartilhado confere contra um número diferente do que o
  // clique conferiria, e a tela passaria a ter duas verdades.
  for (const d of TODOS) {
    const def = definicaoDoPainel(d.tipo);
    assert.equal(d.esperado, def.esperado(PADRAO),
      `"${d.tipo}": o HTML manda ${d.esperado} e def.esperado() devolve ${def.esperado(PADRAO)}`);
  }
});

test('o número que o card MOSTRA é o número que ele MANDA — conferido card a card', () => {
  // Par com o teste acima, e é este que pega o carimbo errado: aqui o valor sai
  // do texto visível do card, não de nenhuma função.
  const casos = [
    ['total', PADRAO.cards.total_oportunidades],
    ['ganhas', PADRAO.cards.qtd_ganhas],
    ['perdidas', PADRAO.cards.qtd_perdidas],
    ['abertas', PADRAO.cards.qtd_abertas],
    ['fora_de_fase', PADRAO.cards.qtd_fora_de_fase],
  ];
  for (const [tipo, valorCru] of casos) {
    const alvo = TODOS.find((d) => d.tipo === tipo);
    assert.ok(alvo, `o card "${tipo}" precisa ser clicável`);
    assert.equal(alvo.esperado, Number(valorCru));
    const pintado = Number(valorCru).toLocaleString('pt-BR');
    assert.ok(HTML_KPIS.includes(`>${pintado}<`),
      `o valor ${pintado} do card "${tipo}" precisa estar visível na tela`);
  }
});

test('a cobertura abre o COMPLEMENTO dela, e o título diz isso', () => {
  // O card mostra 85,24% (cobertura). O conjunto que existe para abrir são as
  // NÃO classificadas — abrir 60+2 embaixo de um card que diz 85,24% sem
  // avisar seria a lista não correspondendo ao número.
  const alvo = TODOS.find((d) => d.tipo === 'sem_origem_classificada');
  assert.ok(alvo);
  assert.equal(alvo.esperado, Number(PADRAO.cards.qtd_nao_classificado) + Number(PADRAO.cards.qtd_sem_origem));
  assert.notEqual(alvo.esperado, Number(PADRAO.cards.qtd_com_segmento), 'não é a cobertura, é o complemento dela');
  assert.match(definicaoDoPainel('sem_origem_classificada').rotulo, /complemento da cobertura/);
});

// ───────────────────────────────────────────────────────────────────────────
// 2 — número que não é conjunto não vira botão
// ───────────────────────────────────────────────────────────────────────────
test('win rate, receita, ticket médio e pipeline NÃO abrem lista — e dizem por quê', () => {
  // A conta não é um número mágico: dos 12 cards, 8 definem conjunto, e desses
  // só abrem os que têm o que listar. Derivar do fixture é o que impede o teste
  // de precisar de manutenção a cada mudança de dado — e continua pegando
  // "alguém tornou a receita clicável", que é o que ele existe para pegar.
  const comConjunto = ['total', 'ganhas', 'perdidas', 'abertas', 'fora_de_fase',
    'sem_declaracao', 'divergentes', 'sem_origem_classificada'];
  const esperados = comConjunto.filter((t) => definicaoDoPainel(t).esperado(PADRAO) > 0);
  assert.equal(drills(HTML_KPIS).length, esperados.length,
    `os KPIs clicáveis têm de ser exatamente os ${esperados.length} com conjunto não vazio`);
  assert.ok(esperados.length >= 6 && esperados.length < 8, 'o fixture precisa ter card de conjunto vazio E cards cheios, ou o teste não discrimina');
  const semClique = ['Win rate', 'Receita ganha', 'Ticket médio', 'Pipeline aberto'];
  for (const rotulo of semClique) {
    // pega o pedaço do card e confere que ele não carrega data-drill
    const i = HTML_KPIS.indexOf(rotulo);
    assert.ok(i > 0, `${rotulo} tem de estar na tela`);
    const inicio = HTML_KPIS.lastIndexOf('<div class="kpi ', i);
    const fim = HTML_KPIS.indexOf('<div class="kpi ', i);
    const card = HTML_KPIS.slice(inicio, fim === -1 ? undefined : fim);
    assert.doesNotMatch(card, /data-drill=/, `${rotulo} não pode abrir lista: não é um conjunto`);
    assert.match(card, /Sem lista:/, `${rotulo} tem de dizer por que não abre`);
  }
  // par negativo: um card que É conjunto carrega o atributo e não a desculpa
  const i = HTML_KPIS.indexOf('Ganhas<');
  const card = HTML_KPIS.slice(HTML_KPIS.lastIndexOf('<div class="kpi ', i), i + 400);
  assert.match(card, /data-drill="ganhas"/);
  assert.doesNotMatch(card, /Sem lista:/);
});

test('a linha "(fora de qualquer fase)" do funil NÃO abre — a API não filtra por fase nula', () => {
  // `fn_filtro_casa` nunca casa NULL com filtro presente, então não existe
  // valor de `fase` que devolva estas linhas. Trocar por `desfecho=fora_de_fase`
  // seria outro conjunto (uma ganha em estágio fora do funil cai nesta barra e
  // não naquele desfecho) — hoje os dois números coincidem, e abrir por causa
  // da coincidência seria acertar por sorte.
  const doFunil = drills(HTML_FUNIL);
  const fases = PADRAO.funil.filter((f) => f.fase).map((f) => `fase:${f.fase}`);
  assert.deepEqual(doFunil.map((d) => d.tipo), fases);
  assert.ok(PADRAO.funil.some((f) => f.fase === null), 'o fixture precisa ter a linha de fase nula');
  assert.doesNotMatch(HTML_FUNIL, /data-drill="fase:null"|data-drill="fase:"/);
  assert.match(HTML_FUNIL, /sem lista: esta linha é “fase nula”/);
  // par: as linhas COM fase não carregam esse aviso
  assert.equal((HTML_FUNIL.match(/sem lista: esta linha/g) ?? []).length, 1);
});

test('toda linha da tabela de segmento abre, com o número da própria linha', () => {
  const doSeg = drills(HTML_SEGMENTO);
  assert.equal(doSeg.length, PADRAO.segmento.length);
  for (const linha of PADRAO.segmento) {
    const alvo = doSeg.find((d) => d.tipo === `segmento:${linha.segmento_aba}`);
    assert.ok(alvo, `o segmento ${linha.segmento_aba} precisa abrir`);
    assert.equal(alvo.esperado, Number(linha.qtd_oportunidades));
  }
});

test('as ganhas fora da receita abrem pelo conjunto inteiro, nunca por motivo', () => {
  const alvo = drills(HTML_FORA);
  assert.equal(alvo.length, 1, 'um alvo só: o motivo não é filtro na camada');
  assert.equal(alvo[0].tipo, 'ganhas_sem_valor');
  assert.equal(alvo[0].esperado, Number(PADRAO.cards.qtd_ganhas_fora_do_valor));
  assert.match(HTML_FORA, /o motivo não é filtro na camada/);
  // par negativo: sem ganhas fora da soma, não há o que abrir
  const zerado = { ...PADRAO.cards, qtd_ganhas_fora_do_valor: '0', ganhas_fora_do_valor_motivos: {} };
  assert.equal(drills(renderForaDoValor(zerado)).length, 0);
});

// ───────────────────────────────────────────────────────────────────────────
// 3 — o recorte do painel é o predicado DA SEÇÃO
// ───────────────────────────────────────────────────────────────────────────
test('tipo desconhecido não abre painel nenhum (a URL é entrada não confiável)', () => {
  for (const lixo of ['xpto', '', null, undefined, 'fase:', ':contato', 'segmento', 'constructor', '__proto__']) {
    assert.equal(definicaoDoPainel(lixo), null, `"${lixo}" não pode resolver para painel`);
  }
  // par: os conhecidos resolvem
  for (const tipo of Object.keys(PAINEIS)) assert.ok(definicaoDoPainel(tipo));
  assert.ok(definicaoDoPainel('fase:contato'));
  assert.ok(definicaoDoPainel('segmento:Marketing'));
});

test('o painel de CARD herda todos os filtros que os cards aplicam', () => {
  const est = { ...LIMPO, segmento: 'Marketing', moeda: 'USD', lead_vinculo_regra: 'conta' };
  const { filtros, vazio } = filtrosDoPainel(definicaoDoPainel('ganhas'), est);
  assert.equal(vazio, false);
  assert.equal(filtros.segmento, 'Marketing');
  assert.equal(filtros.moeda, 'USD');
  assert.equal(filtros.lead_vinculo_regra, 'conta');
  assert.deepEqual(filtros.desfecho, ['ganha']);
  assert.equal(filtros.de, '2025-09-16');
  assert.equal(filtros.ate, '2026-09-17');
});

test('o painel do FUNIL não herda fase nem desfecho — a seção também não os aplica', () => {
  // Medido contra a API: com `desfecho=ganha` o funil devolve as mesmas sete
  // linhas. Herdar o desfecho faria o painel de "Contato" trazer só as ganhas
  // e contradizer a barra que marca 170.
  const est = { ...LIMPO, fase: 'reuniao', desfecho: 'ganha', segmento: 'Marketing' };
  const { filtros } = filtrosDoPainel(definicaoDoPainel('fase:contato'), est);
  assert.deepEqual(filtros.fase, ['contato'], 'a fase do painel é a da linha clicada, não a do filtro');
  assert.equal(filtros.desfecho, undefined, 'o funil ignora desfecho — o painel também tem de ignorar');
  assert.equal(filtros.segmento, 'Marketing', 'segmento o funil APLICA, então o painel herda');
  // par negativo: no painel de card, os mesmos dois campos SÃO herdados
  const doCard = filtrosDoPainel(definicaoDoPainel('total'), est).filtros;
  assert.equal(doCard.desfecho, 'ganha');
  assert.equal(doCard.fase, 'reuniao');
});

test('o painel de SEGMENTO não herda segmento nem vínculo — a tabela também não os aplica', () => {
  const est = { ...LIMPO, segmento: 'Comercial', lead_vinculo_regra: 'conta', fase: 'reuniao' };
  const { filtros } = filtrosDoPainel(definicaoDoPainel('segmento:Marketing'), est);
  assert.deepEqual(filtros.segmento, ['Marketing'], 'o segmento do painel é o da linha clicada');
  assert.equal(filtros.lead_vinculo_regra, undefined, 'a tabela ignora vínculo — o painel também');
  assert.equal(filtros.fase, 'reuniao', 'fase a tabela APLICA, então o painel herda');
});

test('busca e os dois interruptores de auditoria NUNCA são herdados', () => {
  // Medido contra a API: `busca=LOGMEIN` leva a lista a 40 e deixa os cards em
  // 5.415. Herdar a busca faria o painel de "Ganhas" trazer 6 linhas embaixo de
  // um card marcando 987.
  const est = { ...LIMPO, busca: 'LOGMEIN', so_divergentes: true, so_sem_valor: true };
  const { filtros, ignorados } = filtrosDoPainel(definicaoDoPainel('ganhas'), est);
  assert.equal(filtros.busca, undefined);
  assert.equal(filtros.so_divergentes, undefined);
  assert.equal(filtros.so_sem_valor, undefined);
  assert.equal(ignorados.length, 3, 'os três têm de aparecer escritos no painel');
  assert.ok(ignorados.some((x) => x.includes('LOGMEIN')));
  // par: o painel que É de divergentes manda o interruptor de propósito
  const div = filtrosDoPainel(definicaoDoPainel('divergentes'), est);
  assert.equal(div.filtros.so_divergentes, true);
  assert.equal(div.ignorados.length, 2, '“só divergentes” deixa de ser ignorado quando é o próprio recorte');
  const semV = filtrosDoPainel(definicaoDoPainel('ganhas_sem_valor'), est);
  assert.equal(semV.filtros.so_sem_valor, true);
  assert.deepEqual(semV.filtros.desfecho, ['ganha']);
});

test('INTERSEÇÃO: com "Perdidas" filtrado, o card "Ganhas" marca 0 e o painel abre vazio', () => {
  // Trocar o filtro em vez de intersectar abriria 987 linhas embaixo de um card
  // que mostra zero — o defeito exato que este painel existe para não ter.
  const est = { ...LIMPO, desfecho: 'perdida' };
  const plano = filtrosDoPainel(definicaoDoPainel('ganhas'), est);
  assert.equal(plano.vazio, true);
  assert.match(plano.motivoVazio, /mutuamente exclusivos/);
  assert.match(plano.motivoVazio, /Perdidas/);
  assert.match(plano.motivoVazio, /Ganhas/);
  // par positivo: o MESMO código com o filtro coincidente não esvazia nada
  const coincide = filtrosDoPainel(definicaoDoPainel('ganhas'), { ...LIMPO, desfecho: 'ganha' });
  assert.equal(coincide.vazio, false);
  assert.deepEqual(coincide.filtros.desfecho, ['ganha']);
  // e o painel de união intersecta para o elemento que sobrou
  const uniao = filtrosDoPainel(definicaoDoPainel('sem_declaracao'), { ...LIMPO, desfecho: 'declaracao_incompleta' });
  assert.equal(uniao.vazio, false);
  assert.deepEqual(uniao.filtros.desfecho, ['declaracao_incompleta']);
});

test('INTERSEÇÃO de segmento: filtrar Marketing zera o painel de "sem origem classificada"', () => {
  const plano = filtrosDoPainel(definicaoDoPainel('sem_origem_classificada'), { ...LIMPO, segmento: 'Marketing' });
  assert.equal(plano.vazio, true);
  // par: filtrando por um dos dois baldes, o painel é aquele balde
  const nc = filtrosDoPainel(definicaoDoPainel('sem_origem_classificada'), { ...LIMPO, segmento: 'NaoClassificado' });
  assert.equal(nc.vazio, false);
  assert.deepEqual(nc.filtros.segmento, ['NaoClassificado']);
});

test('o painel pede a MESMA página que a lista de baixo (50), nunca a base inteira', () => {
  const { filtros } = filtrosDoPainel(definicaoDoPainel('total'), LIMPO);
  assert.equal(filtros.limit, 50);
  assert.equal(filtros.offset, undefined, 'o offset é do carregamento, não do recorte');
});

// ───────────────────────────────────────────────────────────────────────────
// a conferência na tela
// ───────────────────────────────────────────────────────────────────────────
const PLANO_LIMPO = filtrosDoPainel(definicaoDoPainel('ganhas'), LIMPO);

test('conferência VERDE quando o painel bate com o número clicado', () => {
  const html = renderPainelSub({ def: definicaoDoPainel('ganhas'), plano: PLANO_LIMPO, total: 96, esperado: 96, est: LIMPO });
  assert.match(html, /confere: <strong[^>]*>96<\/strong> no painel = <strong[^>]*>96<\/strong>/);
  assert.doesNotMatch(html, /se contradizendo/);
});

test('conferência VERMELHA quando NÃO bate — e é ela que denuncia a tela mentindo', () => {
  const html = renderPainelSub({ def: definicaoDoPainel('ganhas'), plano: PLANO_LIMPO, total: 987, esperado: 96, est: LIMPO });
  assert.match(html, /o painel trouxe <strong[^>]*>987<\/strong>/);
  assert.match(html, /marca <strong[^>]*>96<\/strong>/);
  assert.match(html, /se contradizendo/);
  assert.doesNotMatch(html, /confere:/);
});

test('o título do painel diz o RECORTE EXATO, não "detalhe"', () => {
  const est = { ...LIMPO, moeda: 'USD', lead_vinculo_regra: 'conta' };
  const plano = filtrosDoPainel(definicaoDoPainel('ganhas'), est);
  const html = renderPainelSub({ def: definicaoDoPainel('ganhas'), plano, total: 12, esperado: 12, est });
  assert.match(html, /criadas entre 16\/09\/2025 e 16\/09\/2026, inclusive/);
  assert.match(html, /desfecho = Ganhas/);
  assert.match(html, /moeda = USD/);
  assert.match(html, /vínculo = lead por conta/);
});

test('o painel escreve o que NÃO herdou, em vez de deixar o leitor descobrir', () => {
  const est = { ...LIMPO, desfecho: 'ganha', busca: 'acme' };
  const plano = filtrosDoPainel(definicaoDoPainel('fase:contato'), est);
  const html = renderPainelSub({ def: definicaoDoPainel('fase:contato'), plano, total: 170, esperado: 170, est });
  assert.match(html, /NÃO herdou/);
  assert.match(html, /filtro de desfecho \(Ganhas\)/);
  assert.match(html, /busca “acme”/);
  // par: sem nada para ignorar, o aviso não aparece
  const limpo = renderPainelSub({ def: definicaoDoPainel('fase:contato'), plano: filtrosDoPainel(definicaoDoPainel('fase:contato'), LIMPO), total: 170, esperado: 170, est: LIMPO });
  assert.doesNotMatch(limpo, /NÃO herdou/);
});

test('interseção vazia é declarada, e sem chamada à API', () => {
  const est = { ...LIMPO, desfecho: 'perdida' };
  const plano = filtrosDoPainel(definicaoDoPainel('ganhas'), est);
  const html = renderPainelSub({ def: definicaoDoPainel('ganhas'), plano, total: 0, esperado: 0, est });
  assert.match(html, /Nenhuma chamada foi feita à API/);
  assert.match(html, /confere: <strong[^>]*>0<\/strong> no painel = <strong[^>]*>0<\/strong>/);
});

test('em modo mock a conferência é SUSPENSA por escrito, não fingida', () => {
  // O fixture não refiltra (ver data-api.js): comparar o total dele com o
  // número do card produziria um alarme vermelho que não é sobre o produto.
  const html = renderPainelSub({ def: definicaoDoPainel('ganhas'), plano: PLANO_LIMPO, total: 420, esperado: 96, mock: true, est: LIMPO });
  assert.match(html, /o mock não refiltra/);
  assert.doesNotMatch(html, /se contradizendo/);
  assert.doesNotMatch(html, /confere:/);
  // par: sem mock, o MESMO par de números dispara o alarme
  assert.match(renderPainelSub({ def: definicaoDoPainel('ganhas'), plano: PLANO_LIMPO, total: 420, esperado: 96, est: LIMPO }), /se contradizendo/);
});

test('o rodapé do painel usa o total do SQL e repete a regra de PII', () => {
  const html = renderRodapePainel(50, 987);
  assert.match(html, /Mostrando 50 de 987/);
  assert.match(html, /não exibe nome de lead/);
});

test('ignoradosDoPainel é puro: não vê nada além do estado que recebe', () => {
  assert.deepEqual(ignoradosDoPainel(definicaoDoPainel('ganhas'), LIMPO), []);
  assert.equal(ignoradosDoPainel(definicaoDoPainel('segmento:Marketing'), { ...LIMPO, lead_vinculo_regra: 'conta' }).length, 1);
});

// ───────────────────────────────────────────────────────────────────────────
// CATEGORIA DE ORIGEM — a seção que chegou quando a borda parou de descartar
// o parâmetro. O que ela tem de garantir, além do drill-down:
//   · as duas contagens de lead ao lado, e NENHUMA dividindo a outra;
//   · zero estrutural (`so_lead`) dito com outra frase que zero medido;
//   · a linha de categoria NULA em pé, sozinha, nunca somada a outra.
// ───────────────────────────────────────────────────────────────────────────
const HTML_CATEGORIA = renderCategoria(PADRAO.categoria);
const DRILLS_CATEGORIA = drills(HTML_CATEGORIA);

test('toda linha COM oportunidade abre; as de zero não abrem, e dizem qual zero é', () => {
  const comOpp = PADRAO.categoria.filter((c) => Number(c.qtd_oportunidades) > 0);
  const semOpp = PADRAO.categoria.filter((c) => Number(c.qtd_oportunidades) === 0);
  assert.ok(comOpp.length >= 10 && semOpp.length >= 2, 'o fixture precisa ter os dois casos');
  assert.equal(DRILLS_CATEGORIA.length, comOpp.length);

  for (const c of comOpp) {
    const alvo = DRILLS_CATEGORIA.find((d) => d.tipo === `categoria:${c.segmento_aba}:${c.categoria ?? ''}`);
    assert.ok(alvo, `${c.segmento_aba}/${c.categoria} precisa abrir`);
    assert.equal(alvo.esperado, Number(c.qtd_oportunidades));
    assert.equal(alvo.esperado, definicaoDoPainel(alvo.tipo).esperado(PADRAO));
  }
  // O ZERO É EXPLICADO, e sem prometer que é estrutural — `presente_em` é
  // medido no recorte (Comercial/Suporte é `ambos` nos 12 meses e vira
  // `so_lead` sob desfecho=fora_de_fase, medido contra a API).
  assert.match(HTML_CATEGORIA, /sem lista: nenhuma oportunidade neste recorte/);
  assert.doesNotMatch(HTML_CATEGORIA, /por construção, não por medição/,
    'a tela não pode chamar de estrutural um zero que depende do recorte');
  assert.doesNotMatch(HTML_CATEGORIA, /zero de oportunidades é estrutural/);
  // e quando o outro lado do join sustenta a linha, isso é dito
  assert.match(HTML_CATEGORIA, /a linha continua na tabela porque o lado do lead trouxe/);
});

test('o fixture só emite formas de `presente_em` que a API sabe emitir', () => {
  // Medido em 105 linhas, cinco recortes: `ambos` nunca vem com zero
  // oportunidade e `so_lead` nunca vem com oportunidade. A versão anterior
  // deste fixture tinha `Comercial/Suporte` com 0 oportunidades e `ambos` —
  // uma forma impossível. Fixture que emite forma impossível testa um contrato
  // que não existe.
  const todas = [
    ...PADRAO.categoria.map((c) => ({ p: c.categoria_presente_em, o: Number(c.qtd_oportunidades), l: Number(c.qtd_leads_gerados), q: `categoria ${c.categoria}` })),
    ...PADRAO.segmento.map((s) => ({ p: s.segmento_presente_em, o: Number(s.qtd_oportunidades), l: Number(s.qtd_leads_gerados), q: `segmento ${s.segmento_aba}` })),
  ];
  for (const x of todas) {
    if (x.p === 'ambos') assert.ok(x.o > 0, `${x.q}: "ambos" com zero oportunidade não existe na API`);
    if (x.p === 'so_lead') assert.equal(x.o, 0, `${x.q}: "so_lead" com oportunidade não existe na API`);
    if (x.p === 'so_oportunidade') assert.equal(x.l, 0, `${x.q}: "so_oportunidade" com lead não existe na API`);
  }
  // e o fixture exercita as três formas, senão a varredura acima é vazia
  const formas = new Set(todas.map((x) => x.p));
  for (const f of ['ambos', 'so_lead', 'so_oportunidade']) assert.ok(formas.has(f), `falta exercitar "${f}"`);
  // inclusive os dois casos raros observados de verdade
  assert.ok(PADRAO.categoria.some((c) => c.categoria_presente_em === 'ambos' && Number(c.qtd_leads_gerados) === 0),
    'falta o caso `ambos` com zero LEADS (Comercial/Suporte nos 12 meses reais)');
  assert.ok(PADRAO.categoria.some((c) => c.categoria_presente_em === 'so_lead' && Number(c.qtd_leads_gerados) === 0),
    'falta o caso `so_lead` com zero dos DOIS lados (observado sob desfecho=fora_de_fase)');
});

test('categoria que só existe do lado do lead NÃO some da tabela — é o dado interessante', () => {
  const soLead = PADRAO.categoria.filter((c) => c.categoria_presente_em === 'so_lead');
  assert.ok(soLead.length >= 2, 'o fixture precisa ter categorias só do lado do lead');
  for (const c of soLead) {
    assert.equal(Number(c.qtd_oportunidades), 0);
    assert.ok(HTML_CATEGORIA.includes(escapeHtml(c.categoria)), `${c.categoria} tem de continuar na tabela`);
  }
  assert.ok(soLead.some((c) => Number(c.qtd_leads_gerados) > 0),
    'pelo menos uma precisa ter leads, senão a linha não prova que o outro lado a sustenta');
  assert.match(HTML_CATEGORIA, /lado da OPORTUNIDADE não trouxe nenhuma linha/);
  assert.match(HTML_CATEGORIA, /neste recorte nenhuma oportunidade caiu nelas/);
  // par negativo: uma tabela sem linhas so_lead não publica o aviso
  const semSoLead = PADRAO.categoria.filter((c) => c.categoria_presente_em !== 'so_lead');
  assert.doesNotMatch(renderCategoria(semSoLead), /só do lado do lead \(/);
});

test('NENHUMA taxa lead → oportunidade, e o exemplo que a proíbe sai DO DADO', () => {
  // `Inbound Web` no fixture: 18 leads e 30 oportunidades — 167%. É a maior
  // razão do recorte, e é ela que a tela cita.
  assert.match(HTML_CATEGORIA, /nenhuma divide a outra/);
  assert.equal(exemploQueProibeATaxa(PADRAO.categoria),
    'Inbound Web tem 18 leads e 30 oportunidades — uma taxa ali marcaria 167%');
  assert.match(HTML_CATEGORIA, /uma taxa ali marcaria 167%/);
  // a moldura “neste recorte” é da frase que consome, e não pode aparecer duas
  // vezes — apareceu, na primeira carga contra a API real.
  assert.doesNotMatch(HTML_CATEGORIA, /oportunidades neste recorte/);
  assert.match(HTML_CATEGORIA, /e neste recorte Inbound Web tem/);

  // PAR NEGATIVO, que é o que prova que a frase vem do dado e não está escrita
  // à mão: com outro recorte ela cita outra linha e outro número.
  const outro = PADRAO.categoria.filter((c) => c.categoria !== 'Inbound Web');
  const frase = exemploQueProibeATaxa(outro);
  assert.notEqual(frase, exemploQueProibeATaxa(PADRAO.categoria));
  assert.match(renderCategoria(outro), new RegExp(frase.match(/marcaria (\d+)%/)[0]));
  // e sem nenhuma linha com mais oportunidades que leads, não há exemplo nenhum
  const semCaso = PADRAO.categoria.filter((c) => Number(c.qtd_oportunidades) <= Number(c.qtd_leads_gerados));
  assert.equal(exemploQueProibeATaxa(semCaso), null);
  assert.doesNotMatch(renderCategoria(semCaso), /uma taxa ali marcaria/);
});

test('as métricas de vínculo NÃO vão para esta tabela — o lugar delas é Qualidade de dados', () => {
  // `qtd_opps_rastreadas_ate_lead` e irmãs vêm no payload e são métrica de
  // QUALIDADE DE DADO. Publicá-las aqui misturaria as duas conversas.
  assert.ok('qtd_opps_rastreadas_ate_lead' in PADRAO.categoria[0], 'o payload traz o campo');
  for (const campo of ['rastreadas_ate_lead', 'so_por_leadsource', 'lead_sem_classificacao', 'soma_vinculo_fecha']) {
    assert.doesNotMatch(HTML_CATEGORIA, new RegExp(campo), `${campo} não pode aparecer na tabela de negócio`);
  }
  // par: um campo que É de negócio aparece
  assert.ok(HTML_CATEGORIA.includes('viraram oportunidade'));
});

test('a tabela confere as DUAS somas: oportunidades e leads', () => {
  assert.match(HTML_CATEGORIA, /as categorias somam 420 = o total de oportunidades do recorte/);
  assert.match(HTML_CATEGORIA, /e 748 = o total de leads do recorte/);
  // par negativo: mutilar a tabela tem de ser denunciado nas duas somas
  const mutilada = PADRAO.categoria.slice(0, 3);
  const html = renderCategoria(mutilada);
  assert.match(html, /⚠️ as categorias somam \d+ mas o recorte tem 420/);
  assert.match(html, /⚠️ e somam \d+ leads contra 748/);
});

test('os dois avisos de filtro são DIFERENTES e não se colapsam num só', () => {
  // (1) o que a SEÇÃO INTEIRA ignora — medido por nós;
  // (2) o que a camada não conseguiu aplicar ao LADO DO LEAD — declarado por ela.
  const comLead = PADRAO.categoria.map((c) => ({ ...c, leads_filtros_ignorados: 'fase, moeda' }));
  const html = renderCategoria(comLead, { ignorando: ['o filtro de vínculo'] });
  assert.match(html, /Esta seção IGNORA o filtro de vínculo/);
  assert.match(html, /A coluna de LEADS não honra fase, moeda/);
  assert.match(html, /leads_filtros_ignorados/);
  // par negativo: sem nenhum dos dois, nenhum aviso
  assert.doesNotMatch(HTML_CATEGORIA, /Esta seção IGNORA/);
  assert.doesNotMatch(HTML_CATEGORIA, /A coluna de LEADS não honra/);
});

test('leads fora do recorte por data ausente aparecem quando existem', () => {
  assert.match(HTML_CATEGORIA, /3 fora do recorte por data ausente/);
  const zerado = PADRAO.categoria.map((c) => ({ ...c, qtd_leads_fora_por_data_ausente: '0' }));
  assert.doesNotMatch(renderCategoria(zerado), /fora do recorte por data ausente/);
});

test('o badge da seção conta as linhas e destaca as que só existem do lado do lead', () => {
  assert.equal(badgeDeCategoria(PADRAO.categoria), '16 categorias · 3 só do lado do lead');
  const semSoLead = PADRAO.categoria.filter((c) => c.categoria_presente_em !== 'so_lead');
  assert.equal(badgeDeCategoria(semSoLead), '13 categorias');
  assert.equal(badgeDeCategoria([]), '—');
});

// ── o drill-down da categoria ───────────────────────────────────────────────
test('o tipo do painel carrega o PAR, e sobrevive a barra e dois-pontos no nome', () => {
  // `Evento/Webinar`, `Outbound SDR/Vendas`, `Parceiro/Indicação` têm barra; o
  // delimitador é o PRIMEIRO dois-pontos, porque `segmento_aba` é enum fechado.
  const d = definicaoDoPainel('categoria:Marketing:Evento/Webinar');
  assert.ok(d);
  assert.equal(d.arg, 'Evento/Webinar');
  assert.deepEqual(d.extra(), { segmento: ['Marketing'], categoria: ['Evento/Webinar'] });
  assert.equal(definicaoDoPainel('categoria:Comercial:Outbound SDR/Vendas').arg, 'Outbound SDR/Vendas');
  // um nome com dois-pontos continua inteiro
  assert.equal(definicaoDoPainel('categoria:Marketing:Webinar: série 2026').arg, 'Webinar: série 2026');
  // lixo não resolve
  for (const x of ['categoria:', 'categoria::', 'categoria::x', 'categoria:Marketing']) {
    assert.equal(definicaoDoPainel(x), null, `"${x}" não pode virar painel`);
  }
});

test('a linha de categoria NULA abre pelo SEGMENTO, com a ressalva escrita', () => {
  // Não existe filtro de "categoria nula": `fn_filtro_casa` lê `categoria:null`
  // como ausência de filtro e devolveria o recorte inteiro.
  const d = definicaoDoPainel('categoria:NaoClassificado:');
  assert.ok(d);
  assert.deepEqual(d.extra(), { segmento: ['NaoClassificado'] });
  assert.equal(d.extra().categoria, undefined, 'mandar categoria:null traria o universo');
  assert.match(d.ressalva, /Não existe filtro de “categoria nula”/);
  assert.equal(d.esperado(PADRAO), 60);

  // AS DUAS LINHAS NULAS SÃO DISTINTAS, e é por isso que o recorte é o segmento
  // e não `so_nao_classificado`: este último devolveria a SOMA das duas.
  const outra = definicaoDoPainel('categoria:SemOrigem:');
  assert.equal(outra.esperado(PADRAO), 2);
  assert.notEqual(d.esperado(PADRAO), outra.esperado(PADRAO));
  assert.notEqual(d.esperado(PADRAO), d.esperado(PADRAO) + outra.esperado(PADRAO));
  // e a ressalva sai no painel
  const plano = filtrosDoPainel(d, LIMPO);
  assert.match(renderPainelSub({ def: d, plano, total: 60, esperado: 60, est: LIMPO }), /categoria nula/);
});

test('o painel de categoria herda segmento (a seção aplica) e NÃO herda vínculo (a seção ignora)', () => {
  // Medido contra a API: com `lead_vinculo_regra=conta` as 16 linhas voltam
  // idênticas; com `segmento=Marketing` a tabela cai para 6. A tabela de
  // SEGMENTO faz o contrário — por isso a herança não pode ser copiada dela.
  const est = { ...LIMPO, lead_vinculo_regra: 'conta', fase: 'reuniao', segmento: 'Marketing' };
  const { filtros, ignorados } = filtrosDoPainel(definicaoDoPainel('categoria:Marketing:Inbound Web'), est);
  assert.equal(filtros.lead_vinculo_regra, undefined, 'a seção ignora vínculo — o painel também');
  assert.deepEqual(filtros.segmento, ['Marketing'], 'segmento a seção APLICA, e o par exige o valor da linha');
  assert.deepEqual(filtros.categoria, ['Inbound Web']);
  assert.equal(filtros.fase, 'reuniao', 'fase a seção aplica');
  assert.ok(ignorados.some((x) => x.includes('vínculo')));
  // par negativo: o painel de SEGMENTO herda o oposto
  const doSeg = filtrosDoPainel(definicaoDoPainel('segmento:Marketing'), est).filtros;
  assert.equal(doSeg.lead_vinculo_regra, undefined);
  assert.deepEqual(doSeg.segmento, ['Marketing']);
});

test('INTERSEÇÃO de segmento no painel de categoria: filtro incompatível esvazia', () => {
  const plano = filtrosDoPainel(definicaoDoPainel('categoria:Marketing:Inbound Web'), { ...LIMPO, segmento: 'Comercial' });
  assert.equal(plano.vazio, true);
  assert.match(plano.motivoVazio, /mutuamente exclusivos/);
  // par: com o segmento coincidente, abre normalmente
  assert.equal(filtrosDoPainel(definicaoDoPainel('categoria:Marketing:Inbound Web'), { ...LIMPO, segmento: 'Marketing' }).vazio, false);
});

test('o título do painel de categoria diz o segmento E a categoria', () => {
  const d = definicaoDoPainel('categoria:Marketing:Evento/Webinar');
  assert.equal(d.rotulo, 'Marketing · Evento/Webinar');
  const plano = filtrosDoPainel(d, LIMPO);
  const html = renderPainelSub({ def: d, plano, total: 12, esperado: 12, est: LIMPO });
  assert.match(html, /segmento = Marketing/);
  assert.match(html, /categoria = Evento\/Webinar/);
});

// ───────────────────────────────────────────────────────────────────────────
// O LADO DO LEAD NA TABELA DE SEGMENTO (migration 103)
// ───────────────────────────────────────────────────────────────────────────
// A 103 acrescentou 11 colunas a `fn_oportunidades_por_segmento` e a tabela não
// consumia NENHUMA — enquanto a de categoria consumia. E é na de segmento que o
// dono do produto procura primeiro "são gerados os leads onde alguns apenas são
// transformados em oportunidades".
const DRILLS_SEGMENTO = drills(HTML_SEGMENTO);

test('a tabela de segmento traz o lado do lead, ADJACENTE às oportunidades', () => {
  // Extrator tolerante a atributos: a coluna de leads tem `style` (espaçamento),
  // e um regex preso a `<th>` puro passaria a não achar nada e a comparar
  // `[] com []` — teste que some em silêncio é pior que teste vermelho.
  const cabecalhos = [...HTML_SEGMENTO.matchAll(/<th[^>]*>([^<]+)<\/th>/g)].map((m) => m[1]);
  assert.ok(cabecalhos.length >= 9, `o extrator precisa achar os cabeçalhos, achou ${cabecalhos.length}`);
  assert.deepEqual(cabecalhos.slice(0, 3), ['Segmento', 'Oportunidades', 'Leads gerados'],
    'a coluna de leads fica ao lado da de oportunidades — na ponta ela cai fora da área visível');
  for (const s of PADRAO.segmento) {
    assert.ok(HTML_SEGMENTO.includes(`>${Number(s.qtd_leads_gerados).toLocaleString('pt-BR')}\n`)
      || HTML_SEGMENTO.includes(Number(s.qtd_leads_gerados).toLocaleString('pt-BR')),
      `os leads de ${s.segmento_aba} têm de aparecer`);
  }
  assert.match(HTML_SEGMENTO, /viraram oportunidade/);
  // as duas somas conferidas, como na de categoria
  assert.match(HTML_SEGMENTO, /os baldes somam 420 = o total do recorte/);
  assert.match(HTML_SEGMENTO, /e 748 = o total de leads do recorte/);
});

test('a tabela de segmento também NÃO divide uma contagem pela outra', () => {
  assert.match(HTML_SEGMENTO, /nenhuma divide a outra/);
  // Parceiro no fixture: 12 leads e 16 oportunidades = 133%, o pior caso daqui
  assert.match(HTML_SEGMENTO, /Parceiro tem 12 leads e 16 oportunidades — uma taxa ali marcaria 133%/);
  // par negativo: sem linha com mais oportunidades que leads, não há exemplo
  const semCaso = PADRAO.segmento.filter((s) => Number(s.qtd_oportunidades) <= Number(s.qtd_leads_gerados));
  assert.doesNotMatch(renderSegmento(semCaso), /uma taxa ali marcaria/);
});

test('as métricas de vínculo NÃO vão para a tabela de segmento (qualidade de dado)', () => {
  assert.ok('qtd_opps_rastreadas_ate_lead' in PADRAO.segmento[0], 'o payload traz o campo');
  for (const campo of ['rastreadas_ate_lead', 'so_por_leadsource', 'lead_sem_classificacao']) {
    assert.doesNotMatch(HTML_SEGMENTO, new RegExp(campo), `${campo} é qualidade de dado, não vai para a tabela de negócio`);
  }
});

test('linha de segmento com ZERO oportunidade não abre — a 103 passou a produzi-las', () => {
  // Reproduzido contra a API com `desfecho=fora_de_fase`: Marketing e Não
  // atribuído voltam com 0 oportunidades e `so_lead`, e antes desta guarda
  // abriam painel vazio sem explicação nenhuma.
  const comZero = PADRAO.segmento.map((s) => (s.segmento_aba === 'Marketing'
    ? { ...s, qtd_oportunidades: '0', qtd_ganhas: '0', qtd_perdidas: '0', qtd_nao_decididas: '0', qtd_decididas: '0', segmento_presente_em: 'so_lead' }
    : s));
  const html = renderSegmento(comZero);
  const alvos = drills(html).map((d) => d.tipo);
  assert.ok(!alvos.includes('segmento:Marketing'), 'linha de zero não pode abrir');
  assert.ok(alvos.includes('segmento:Comercial'), 'as outras continuam abrindo');
  assert.match(html, /sem lista: nenhuma oportunidade neste recorte/);
  assert.match(html, /a linha continua na tabela porque o lado do lead trouxe 266/);
  // par negativo: no fixture saudável todas abrem e não há a frase
  assert.equal(DRILLS_SEGMENTO.length, PADRAO.segmento.length);
  assert.doesNotMatch(HTML_SEGMENTO, /sem lista: nenhuma oportunidade/);
});

// ───────────────────────────────────────────────────────────────────────────
// `soma_vinculo_fecha` — a guarda da camada que a tela não lia
// ───────────────────────────────────────────────────────────────────────────
test('a partição por regra de vínculo é CONFERIDA, nas duas tabelas', () => {
  // Hoje é `true` em 100% das linhas reais. Uma guarda que ninguém lê é pior
  // que uma que só consegue passar: um `lead_vinculo_regra` novo entraria sem
  // alarme, que é exatamente o que a migration 103 diz prevenir.
  assert.doesNotMatch(HTML_SEGMENTO, /não fecha em/, 'o caso saudável não pode disparar o alarme');
  assert.doesNotMatch(HTML_CATEGORIA, /não fecha em/);

  const quebrado = PADRAO.segmento.map((s, i) => (i === 0
    ? { ...s, soma_vinculo_fecha: false, qtd_opps_so_por_leadsource: String(Number(s.qtd_opps_so_por_leadsource) - 7) }
    : s));
  const html = renderSegmento(quebrado);
  assert.match(html, /A partição por regra de vínculo não fecha em 1 linha\(s\)/);
  assert.match(html, /as quatro regras de vínculo somam 161 contra 168 oportunidades/);
  assert.match(html, /a atribuição dela deixou de ser explicável/);

  // e o mesmo na tabela de categoria, com o rótulo da categoria
  const catQuebrada = PADRAO.categoria.map((c, i) => (i === 0
    ? { ...c, soma_vinculo_fecha: false, qtd_opps_so_por_leadsource: String(Number(c.qtd_opps_so_por_leadsource) - 7) }
    : c));
  assert.match(renderCategoria(catQuebrada), /Outbound SDR\/Vendas \(as quatro regras de vínculo somam 132 contra 139/);
});

test('conferirVinculo é puro e conta TODAS as linhas quebradas, não só a primeira', () => {
  const duas = PADRAO.segmento.map((s, i) => (i < 2 ? { ...s, soma_vinculo_fecha: false } : s));
  assert.match(conferirVinculo(duas, (x) => x.segmento_aba), /não fecha em 2 linha\(s\)/);
  assert.equal(conferirVinculo(PADRAO.segmento, (x) => x.segmento_aba), '');
  assert.equal(conferirVinculo([], (x) => x), '');
});

// ───────────────────────────────────────────────────────────────────────────
// vírgula no nome da categoria
// ───────────────────────────────────────────────────────────────────────────
test('categoria com vírgula não abre painel — o filtro viaja em lista separada por vírgula', () => {
  // `data-api.js` serializa lista de filtro com `v.join(',')` e a borda separa
  // de volta pela vírgula: "Evento, Webinar" chegaria como DOIS valores e o
  // painel traria a união. Nenhuma das 16 categorias de hoje tem vírgula, mas
  // elas vêm de `leadsource_crosswalk`, que é texto livre.
  assert.equal(definicaoDoPainel('categoria:Marketing:Evento, Webinar'), null);
  assert.ok(definicaoDoPainel('categoria:Marketing:Evento/Webinar'), 'barra continua valendo');

  const comVirgula = PADRAO.categoria.map((c) => (c.categoria === 'Inbound Web'
    ? { ...c, categoria: 'Inbound, Web', categoria_rotulo: 'Inbound, Web' } : c));
  const html = renderCategoria(comVirgula);
  assert.doesNotMatch(html, /data-drill="categoria:Marketing:Inbound, Web"/);
  assert.match(html, /o nome desta categoria tem vírgula/);
  // par negativo: sem vírgula, a mesma linha abre
  assert.match(HTML_CATEGORIA, /data-drill="categoria:Marketing:Inbound Web"/);
  assert.doesNotMatch(HTML_CATEGORIA, /tem vírgula/);
});
