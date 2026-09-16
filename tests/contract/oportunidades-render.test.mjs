// tests/contract/oportunidades-render.test.mjs — exercita o RENDER da aba
// Oportunidades nos quatro caminhos que a tela é obrigada a tratar e que a
// base real quase nunca produz ao mesmo tempo:
//
//   1. `soma_fecha: false`            → os números NÃO podem ser desenhados
//   2. `periodo_anterior_tem_dado:false` → a seta some e o motivo aparece
//   3. `qtd_ganhas_fora_do_valor > 0` → a receita nunca sai sozinha
//   4. linha em moeda não-BRL         → jamais "R$" em cima de MXN
//
// CADA ASSERÇÃO POSITIVA TEM UM PAR NEGATIVO. Não é zelo: neste épico seis
// verificações passaram em branco — asserções que não conseguiam falhar. Aqui,
// para cada "X aparece no caso A" existe um "X NÃO aparece no caso B", com o
// mesmo código, o que prova que a asserção discrimina.
//
// Rodar: node --test tests/contract/oportunidades-render.test.mjs
//
// As funções de render são PURAS (recebem dados, devolvem string HTML) — é o
// que permite exercitá-las sem DOM, sem navegador e sem dependência instalada
// (ADR-017: node --test é o único runner).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  renderIntegridade, renderKpis, renderFunil, renderSegmento,
  renderForaDoValor, renderRessalvaCiclo, renderLista, renderRecorte,
  renderRodapeLista, conferirParticao, tendencia, ultimosMeses,
  totalDaCoorte, coberturaDaTabela,
} from '../../assets/js/views/oportunidades.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(
  join(__dirname, '..', '..', 'assets', 'data', 'mock', 'oportunidades.json'), 'utf8'));

const PADRAO = fixture.padrao;
const SOMA_QUEBRADA = fixture.cenarios.soma_nao_fecha;
const SEM_ANTERIOR = fixture.cenarios.sem_periodo_anterior;

// ───────────────────────────────────────────────────────────────────────────
// o fixture em si
// ───────────────────────────────────────────────────────────────────────────
test('o fixture exercita os quatro casos difíceis — se parar de exercitar, o resto deste arquivo vira teatro', () => {
  assert.equal(PADRAO.cards.soma_fecha, true);
  assert.equal(SOMA_QUEBRADA.cards.soma_fecha, false, 'cenário soma_nao_fecha precisa ter soma_fecha=false');
  assert.equal(PADRAO.cards.periodo_anterior_tem_dado, true);
  assert.equal(SEM_ANTERIOR.cards.periodo_anterior_tem_dado, false);
  assert.ok(Number(PADRAO.cards.qtd_ganhas_fora_do_valor) > 0, 'padrão precisa ter ganhas fora do valor');
  const moedas = new Set(PADRAO.lista.oportunidades.map((o) => o.moeda));
  assert.ok(moedas.has('MXN'), 'padrão precisa ter pelo menos uma linha em MXN');
  assert.ok(moedas.has('USD'), 'padrão precisa ter pelo menos uma linha em USD');
  assert.ok(moedas.has('COP'), 'padrão precisa ter uma moeda SEM taxa (conversão indisponível)');
});

test('o fixture não carrega PII: nenhum lead_nome preenchido (repositório público)', () => {
  for (const o of PADRAO.lista.oportunidades) {
    assert.equal(o.lead_nome, null, `oportunidade ${o.opportunity_id} não pode trazer nome`);
  }
  const bruto = readFileSync(join(__dirname, '..', '..', 'assets', 'data', 'mock', 'oportunidades.json'), 'utf8');
  assert.ok(!/@[a-z0-9.-]+\.[a-z]{2,}/i.test(bruto), 'fixture não pode conter e-mail');
});

test('a chave `source_id_ficha`-style: o mock emite TODAS as chaves que o real emite', () => {
  // O defeito que esta asserção existe para não repetir: `source_id_ficha`
  // ausente no mock virou `data-lead-row="undefined"` na aba Leads. A lista de
  // chaves abaixo é a projeção real de /api/oportunidades, medida em 2026-09-16.
  const CHAVES_REAIS = [
    'amount', 'amount_brl', 'categoria', 'close_date_antes_da_criacao', 'close_date_origem',
    'conta_id', 'conta_nome', 'conversao_indisponivel_motivo', 'criada_em', 'desfecho',
    'desfecho_motivo', 'detalhe', 'dias_entre_criacao_e_close_date', 'divergencia_origem_vs_fase',
    'duracao_meses_contrato', 'estagio', 'fase', 'fase_ordem', 'lead_id', 'lead_nome',
    'lead_salesforce_id', 'lead_source', 'lead_vinculo_regra', 'moeda', 'mrr', 'opportunity_id',
    'origem_sinal_id', 'qtd_leads_candidatos', 'record_type', 'segmento_aba', 'source_id',
  ];
  for (const o of PADRAO.lista.oportunidades) {
    for (const k of CHAVES_REAIS) {
      assert.ok(k in o, `oportunidade ${o.opportunity_id} não emite a chave "${k}"`);
    }
  }
});

// ───────────────────────────────────────────────────────────────────────────
// CASO 1 — soma_fecha: false
// ───────────────────────────────────────────────────────────────────────────
test('CASO 1 — partição que fecha: a tela desenha os números', () => {
  const p = conferirParticao(PADRAO.cards);
  assert.equal(p.fechaNaApi, true);
  assert.equal(p.fechaNaTela, true, `soma ${p.soma} vs total ${p.total}`);
  const html = renderIntegridade(PADRAO.cards);
  assert.match(html, /a partição fecha/);
  assert.doesNotMatch(html, /não fecha/);
});

test('CASO 1 (par negativo) — partição quebrada: o alerta aparece e o render dos números é suprimido', () => {
  const p = conferirParticao(SOMA_QUEBRADA.cards);
  assert.equal(p.fechaNaApi, false);
  assert.equal(p.fechaNaTela, false, 'o cenário precisa quebrar também na conferência independente da tela');
  const html = renderIntegridade(SOMA_QUEBRADA.cards);
  assert.match(html, /não fecha/);
  assert.match(html, /soma_fecha = false/);
  assert.match(html, /diferença de/i);
  assert.doesNotMatch(html, /a partição fecha</);

  // A supressão é decidida por esta condição — a mesma que a view usa.
  const desenha = SOMA_QUEBRADA.cards.soma_fecha === true && p.fechaNaTela;
  assert.equal(desenha, false);
  const desenhaPadrao = PADRAO.cards.soma_fecha === true && conferirParticao(PADRAO.cards).fechaNaTela;
  assert.equal(desenhaPadrao, true, 'a mesma condição precisa dar true no caso saudável, senão ela não discrimina');
});

test('CASO 1 — a diferença declarada pela API aparece escrita, não arredondada para "alguns"', () => {
  const html = renderIntegridade(SOMA_QUEBRADA.cards);
  assert.match(html, />7<\/strong> oportunidade/);
});

// ───────────────────────────────────────────────────────────────────────────
// CASO 2 — periodo_anterior_tem_dado: false
// ───────────────────────────────────────────────────────────────────────────
test('CASO 2 — com período anterior: a seta é desenhada', () => {
  const html = tendencia(420, 361, true, null);
  assert.match(html, /ti-trending-up|ti-trending-down|ti-minus/);
  assert.match(html, /vs\. período anterior/);
});

test('CASO 2 (par negativo) — sem período anterior: nenhuma seta, e o motivo no lugar dela', () => {
  const motivo = SEM_ANTERIOR.cards.periodo_anterior_sem_dado_motivo;
  const html = tendencia(420, null, false, motivo);
  assert.doesNotMatch(html, /ti-trending-up|ti-trending-down|ti-minus/, 'seta não pode aparecer sem período anterior');
  assert.doesNotMatch(html, /vs\. período anterior/);
  assert.match(html, /sem base de comparação/);
  // O motivo COMPLETO da API tem de estar na tela — na barra de recorte, uma
  // vez, e não repetido em doze cards. Se ele sumir dos dois lugares, o
  // usuário fica sem saber por que a seta não está lá.
  const barra = renderRecorte(SEM_ANTERIOR);
  assert.match(barra, /Sem período anterior comparável/);
  assert.ok(barra.includes(motivo.slice(0, 60)), 'o motivo declarado pela API tem de aparecer na barra de recorte');
  assert.doesNotMatch(renderRecorte(PADRAO), /Sem período anterior comparável/);
});

test('CASO 2 — período anterior em ZERO não vira +100% (o defeito da aba antiga)', () => {
  const html = tendencia(420, 0, true, null);
  assert.doesNotMatch(html, /ti-trending-up/);
  assert.match(html, /Período anterior em zero/);
  // E o par: com base diferente de zero, o mesmo código produz seta.
  assert.match(tendencia(420, 1, true, null), /ti-trending-up/);
});

test('CASO 2 — os KPIs inteiros mudam de comportamento entre os dois cenários', () => {
  const comAnt = renderKpis(PADRAO.cards);
  const semAnt = renderKpis(SEM_ANTERIOR.cards);
  const setas = (h) => (h.match(/ti-trending-(up|down)/g) ?? []).length;
  assert.ok(setas(comAnt) > 0, 'com período anterior tem de haver seta');
  assert.equal(setas(semAnt), 0, 'sem período anterior não pode haver nenhuma seta');
  assert.match(semAnt, /sem base de comparação/);
  assert.doesNotMatch(comAnt, /sem base de comparação/);
});

// ───────────────────────────────────────────────────────────────────────────
// CASO 3 — qtd_ganhas_fora_do_valor > 0
// ───────────────────────────────────────────────────────────────────────────
test('CASO 3 — receita nunca sai sozinha: quantidade fora da soma e motivo no mesmo card', () => {
  const html = renderKpis(PADRAO.cards);
  assert.match(html, /Receita ganha/);
  assert.match(html, /12 ganha\(s\) fora da soma/);
  assert.match(html, /Amount vazio na origem/);
  assert.match(html, /base da soma: 84 ganhas com valor convertido/);
});

test('CASO 3 (par negativo) — sem ganhas fora do valor, o aviso some e o texto vira o oposto', () => {
  const cards = { ...PADRAO.cards, qtd_ganhas_fora_do_valor: '0', ganhas_fora_do_valor_motivos: {} };
  const html = renderKpis(cards);
  assert.doesNotMatch(html, /ganha\(s\) fora da soma/);
  assert.match(html, /todas as 96 ganhas entraram na soma/);
});

test('CASO 3 — a seção dedicada lista motivo a motivo e confere a soma dos motivos', () => {
  const html = renderForaDoValor(PADRAO.cards);
  assert.match(html, /Amount vazio na origem/);
  assert.match(html, /não está em currency_rate/);
  assert.match(html, /A soma dos motivos é 12(?!.*deveria ser)/s);
  // Par negativo: motivos que não somam o total precisam ser denunciados.
  const mentiroso = { ...PADRAO.cards, ganhas_fora_do_valor_motivos: { 'Amount vazio na origem — não há valor para converter': 9 } };
  assert.match(renderForaDoValor(mentiroso), /deveria ser 12/);
});

test('CASO 3 — win_rate_sobre_todas_pct NUNCA vai para a tela (é o número errado da aba antiga)', () => {
  // A VERSÃO ANTERIOR DESTA ASSERÇÃO ERA VACUOSA:
  //   assert.ok(!html.includes('22,86%') || !html.includes('win_rate_sobre_todas'))
  // `renderKpis` nunca emite a string `win_rate_sobre_todas` (é nome de campo,
  // não rótulo), então o segundo operando era SEMPRE true e a disjunção passava
  // mesmo com 22,86% carimbado no lugar do win rate. Medido: substituindo
  // 56,47% por 22,86% no HTML, a asserção antiga continuava verde.
  //
  // A versão nova testa O CAMPO, com sentinelas que não podem sair de mais
  // lugar nenhum — e traz o par positivo, que é o que prova que ela discrimina.
  const cards = {
    ...PADRAO.cards,
    win_rate_decididas_pct: '11.11',
    win_rate_sobre_todas_pct: '99.99',
  };
  const html = renderKpis(cards);
  assert.match(html, /11,11%/, 'win_rate_decididas_pct É o indicador e tem de sair na tela');
  assert.doesNotMatch(html, /99,99%/, 'win_rate_sobre_todas_pct é só auditoria e não pode ser exibido');
  assert.match(html, /96 de 170 decididas/, 'o denominador é obrigatório e visível');
});

test('CASO 3 (prova de que a asserção acima discrimina) — trocar os dois campos de lugar quebra', () => {
  // Se a implementação lesse o campo errado, este é o HTML que ela produziria.
  // O teste acima falharia nos dois `match`; aqui só confirmamos que os dois
  // valores são distinguíveis, isto é, que a sentinela não colide com nada.
  const html = renderKpis({ ...PADRAO.cards, win_rate_decididas_pct: '99.99' });
  assert.match(html, /99,99%/, 'a sentinela sai na tela quando vem pelo campo certo — logo o doesNotMatch acima tem conteúdo');
});

// ───────────────────────────────────────────────────────────────────────────
// CASO 4 — moeda não-BRL
// ───────────────────────────────────────────────────────────────────────────
test('CASO 4 — linha em MXN: o convertido em real E o cru em peso, nunca R$ em cima do peso', () => {
  const mxn = PADRAO.lista.oportunidades.find((o) => o.moeda === 'MXN' && o.amount_brl);
  assert.ok(mxn, 'o fixture precisa ter uma linha MXN com conversão');
  const html = renderLista({ oportunidades: [mxn] });
  assert.match(html, /R\$&nbsp;175\.960,30|R\$\s175\.960,30/, 'o valor convertido em real tem de aparecer');
  assert.match(html, /MX\$/, 'o valor cru na moeda de origem tem de aparecer ao lado');
  // A prova de que não houve carimbo: 600.000 é o número em PESO e ele não
  // pode aparecer precedido de R$.
  assert.doesNotMatch(html, /R\$(&nbsp;|\s)600\.000,00/, 'R$ jamais pode ser carimbado sobre o valor em MXN');
});

test('CASO 4 (par negativo) — linha em BRL não repete o valor entre parênteses', () => {
  const brl = PADRAO.lista.oportunidades.find((o) => o.moeda === 'BRL' && o.amount_brl);
  const html = renderLista({ oportunidades: [brl] });
  assert.doesNotMatch(html, /MX\$|US\$/);
  assert.doesNotMatch(html, /\(R\$/, 'em BRL o cru É o convertido — repetir seria ruído');
});

test('CASO 4 — moeda SEM taxa: o valor sai na moeda dele, com o motivo, e fora da soma', () => {
  const cop = PADRAO.lista.oportunidades.find((o) => o.moeda === 'COP');
  assert.ok(cop && cop.amount && cop.amount_brl === null);
  const html = renderLista({ oportunidades: [cop] });
  assert.match(html, /sem conversão para real/);
  assert.match(html, /não está em currency_rate/);
  assert.doesNotMatch(html, /R\$/, 'sem taxa conhecida, nada pode virar real');
});

test('MRR fica na moeda de ORIGEM e nunca é convertido (não existe mrr_brl na camada)', () => {
  const brl = PADRAO.lista.oportunidades.find((o) => o.mrr && o.moeda === 'BRL');
  assert.match(renderLista({ oportunidades: [brl] }), /MRR R\$(&nbsp;|\s)1\.533,33/);
  const mxn = PADRAO.lista.oportunidades.find((o) => o.mrr && o.moeda === 'MXN');
  const html = renderLista({ oportunidades: [mxn] });
  assert.match(html, /MRR MX\$/);
  assert.match(html, /sem equivalente em real na fonte/);
  assert.doesNotMatch(html, /MRR R\$/, 'MRR em MXN jamais pode sair com símbolo de real');
});

test('CASO 4 — a coluna de moeda mostra a moeda de origem de cada linha', () => {
  const html = renderLista(PADRAO.lista);
  for (const m of ['BRL', 'USD', 'MXN', 'COP']) assert.match(html, new RegExp(`>${m}<`));
});

// ───────────────────────────────────────────────────────────────────────────
// funil: estoque, nunca fluxo
// ───────────────────────────────────────────────────────────────────────────
test('o funil declara que é estoque, proíbe a divisão entre fases e confere a soma', () => {
  const html = renderFunil(PADRAO.funil);
  assert.match(html, /Leia como estoque/);
  assert.match(html, /não produz taxa de conversão/);
  assert.match(html, /as fases somam 420 = o total da coorte/);
  assert.doesNotMatch(html, /taxa de conversão de|conversão entre fases/);
});

test('a linha "(fora de qualquer fase)" aparece mesmo valendo 3 — e a ausência dela é denunciada', () => {
  const html = renderFunil(PADRAO.funil);
  assert.match(html, /\(fora de qualquer fase\)/);
  const semLinha = PADRAO.funil.filter((f) => f.fase !== null);
  const html2 = renderFunil(semLinha);
  assert.match(html2, /não veio da API — ela é obrigatória/);
  assert.doesNotMatch(html, /não veio da API/, 'o caso saudável não pode disparar o alarme');
});

test('o funil avisa quando IGNORA filtros que os cards aplicaram', () => {
  const semAviso = renderFunil(PADRAO.funil, { ignorando: [] });
  const comAviso = renderFunil(PADRAO.funil, { ignorando: ['o filtro de fase'] });
  assert.doesNotMatch(semAviso, /IGNORA/);
  assert.match(comAviso, /IGNORA o filtro de fase/);
});

// ───────────────────────────────────────────────────────────────────────────
// segmento
// ───────────────────────────────────────────────────────────────────────────
test('cada segmento sai com o SEU denominador ao lado do win rate', () => {
  const html = renderSegmento(PADRAO.segmento);
  assert.match(html, /de 69 decididas/); // Comercial: 38 ganhas + 31 perdidas
  assert.match(html, /os baldes somam 420 = o total do recorte/);
  assert.match(html, /Não classificado/);
  assert.match(html, /NÃO é &quot;comercial&quot;|NÃO é "comercial"/);
});

test('segmento denuncia quando os baldes não somam o recorte', () => {
  const mutilado = PADRAO.segmento.slice(0, 2);
  assert.match(renderSegmento(mutilado), /⚠️ os baldes somam/);
  assert.doesNotMatch(renderSegmento(PADRAO.segmento), /⚠️ os baldes somam/);
});

// ───────────────────────────────────────────────────────────────────────────
// ciclo: a ressalva vai para a tela, o número não
// ───────────────────────────────────────────────────────────────────────────
test('não existe card de ciclo; existe a ressalva, com o texto completo da camada', () => {
  const kpis = renderKpis(PADRAO.cards);
  assert.doesNotMatch(kpis, /[Cc]iclo de venda/, 'ciclo não pode virar KPI');
  assert.doesNotMatch(kpis, /dias/, 'nenhum KPI pode ser expresso em dias');
  const ressalva = renderRessalvaCiclo(PADRAO.cards);
  assert.match(ressalva, /não tem card de ciclo de venda/);
  assert.match(ressalva, /NÃO é ciclo de venda/);
  assert.match(ressalva, /fim do contrato/);
});

// ───────────────────────────────────────────────────────────────────────────
// recorte padrão (regra 9)
// ───────────────────────────────────────────────────────────────────────────
test('o recorte padrão são 12 meses, com fim EXCLUSIVO um dia à frente para incluir hoje', () => {
  const { de, ate } = ultimosMeses(12, new Date('2026-09-16T10:00:00Z'));
  assert.equal(de, '2025-09-16');
  assert.equal(ate, '2026-09-17', 'ate é exclusivo: mandar 2026-09-16 esconderia o que foi criado hoje');
  const trinta = ultimosMeses(1, new Date('2026-09-16T10:00:00Z'));
  assert.equal(trinta.de, '2026-08-16');
});

test('preset rodando em dia 31 não estoura para o mês seguinte', () => {
  // `setUTCMonth(mes - 1)` sozinho pedia 31/02 e o Date "corrigia" para 03/03:
  // um recorte de 28 dias rotulado como 30d, sem nada na tela denunciando.
  assert.equal(ultimosMeses(1, new Date('2026-03-31T10:00:00Z')).de, '2026-02-28');
  assert.equal(ultimosMeses(3, new Date('2026-05-31T10:00:00Z')).de, '2026-02-28');
  // ano bissexto e virada de ano continuam certos
  assert.equal(ultimosMeses(12, new Date('2024-02-29T10:00:00Z')).de, '2023-02-28');
  assert.equal(ultimosMeses(1, new Date('2026-01-31T10:00:00Z')).de, '2025-12-31');
  // e um dia que existe nos dois meses não é mexido
  assert.equal(ultimosMeses(1, new Date('2026-03-15T10:00:00Z')).de, '2026-02-15');
});

// ───────────────────────────────────────────────────────────────────────────
// PII: a lista não pode vazar nome de lead nem com o dado presente
// ───────────────────────────────────────────────────────────────────────────
test('mesmo com lead_nome preenchido na resposta, o render NÃO o coloca na tela', () => {
  const linha = { ...PADRAO.lista.oportunidades[0], lead_nome: 'Fulano de Tal Sobrenome' };
  const html = renderLista({ oportunidades: [linha] });
  assert.doesNotMatch(html, /Fulano de Tal Sobrenome/);
  // Par: o nome da CONTA (dado de negócio) aparece, o que prova que o render
  // está de fato imprimindo campos desta linha.
  assert.match(html, new RegExp(linha.conta_nome.replace(/[().]/g, '\\$&')));
});

// ───────────────────────────────────────────────────────────────────────────
// bordas de período: meia-noite UTC não pode virar o dia anterior
// ───────────────────────────────────────────────────────────────────────────
test('a barra de recorte mostra a data que foi PEDIDA, não o dia anterior por fuso', () => {
  // Defeito real visto na primeira carga contra a API: `periodo_de` chega como
  // 2025-09-16T00:00:00.000Z e, lido em UTC-3, virava 15/09/2025 — a tela
  // contradizia o parâmetro que ela mesma enviou.
  const html = renderRecorte(PADRAO);
  assert.match(html, /no recorte de <strong>16\/09\/2025<\/strong>/,
    'periodo_de = 2025-09-16T00:00Z tem de sair como 16/09/2025, não 15/09');
  assert.doesNotMatch(html, /no recorte de <strong>15\/09\/2025<\/strong>/,
    'a borda inicial não pode escorregar para o dia anterior por fuso');
  // O 15/09/2025 que SOBRA na tela é o fim (exclusivo -1) do período ANTERIOR,
  // e esse sim tem de estar lá — a asserção acima é sobre a borda inicial.
  assert.match(html, /Comparação: 16\/09\/2024 a 15\/09\/2025/);
  // fim EXCLUSIVO (2026-09-16T00:00Z) apresentado como último dia INCLUSIVO
  assert.match(html, /a <strong>15\/09\/2026<\/strong>, inclusive/);
  // e o valor cru enviado à API continua visível, sem fingir que não é exclusivo
  assert.match(html, /ate=16\/09\/2026<\/code> exclusivo/);
});

test('o rodapé de segmento usa os denominadores DESTE recorte, não um exemplo congelado', () => {
  const html = renderSegmento(PADRAO.segmento);
  // menor e maior qtd_decididas do fixture: SemOrigem tem 1, Comercial tem 69
  assert.match(html, /vão de 1 a 69 decididas/);
  // par negativo: com um recorte diferente, os números mudam junto
  const outro = PADRAO.segmento.filter((s) => ['Marketing', 'Comercial'].includes(s.segmento_aba));
  assert.match(renderSegmento(outro), /vão de 26 a 69 decididas/);
});

test('sem recorte, a frase continua sendo português (defeito "oportunidades no sem recorte")', () => {
  const html = renderRecorte(fixture.cenarios.sem_periodo);
  assert.match(html, /oportunidades <strong>sem recorte de período<\/strong>/);
  assert.doesNotMatch(html, /no <strong>sem recorte/);
  assert.match(renderRecorte(PADRAO), /oportunidades no recorte de/);
});

// ───────────────────────────────────────────────────────────────────────────
// CORREÇÕES DO QA (CONCERNS de 2026-09-16)
// ───────────────────────────────────────────────────────────────────────────

test('BLOQUEADOR 2 — página vazia sobre total > 0 é DIVERGÊNCIA, não recorte vazio', () => {
  // O texto anterior era um só para os dois casos, e afirmava "não há
  // divergência escondida aqui" enquanto o badge ao lado marcava 420.
  const divergente = renderLista({ oportunidades: [], total: 420 });
  assert.match(divergente, /A página pedida veio vazia, mas o recorte tem 420/);
  assert.match(divergente, /Isto é divergência entre a lista e o total/);
  assert.doesNotMatch(divergente, /não há divergência escondida/);

  const vazioDeVerdade = renderLista({ oportunidades: [], total: 0 });
  assert.match(vazioDeVerdade, /Nenhuma oportunidade neste recorte/);
  assert.match(vazioDeVerdade, /o total ao lado também é zero/);
  assert.doesNotMatch(vazioDeVerdade, /divergência entre a lista e o total/);
});

test('MÉDIO 3 — o badge do funil vem do total da COORTE, não dos cards', () => {
  // `funil[].total_da_coorte` é 420 mesmo quando os cards estão em 96.
  assert.equal(totalDaCoorte(PADRAO.funil), 420);
  const cardsFiltrados = { ...PADRAO.cards, total_oportunidades: '96' };
  assert.notEqual(totalDaCoorte(PADRAO.funil), Number(cardsFiltrados.total_oportunidades),
    'se os dois fossem iguais este teste não provaria nada');
  assert.equal(totalDaCoorte([]), 0);
});

test('MÉDIO 3 — a cobertura do badge de segmento vem dos baldes da própria tabela', () => {
  // 420 no total, 60 NaoClassificado + 2 SemOrigem => 358/420 = 85,24%
  assert.match(coberturaDaTabela(PADRAO.segmento), /^85,24% com origem classificada$/);
  // e NÃO é `cards.pct_com_segmento`: com o filtro de segmento ativo aquele
  // campo ia a 100% sobre esta mesma tabela inalterada.
  const soMarketing = { ...PADRAO.cards, pct_com_segmento: '100.00' };
  assert.notEqual(coberturaDaTabela(PADRAO.segmento), `${soMarketing.pct_com_segmento}% com origem classificada`);
  // par: uma tabela sem baldes desclassificados dá 100%, então a função reage
  const limpa = PADRAO.segmento.filter((x) => !['NaoClassificado', 'SemOrigem'].includes(x.segmento_aba));
  assert.match(coberturaDaTabela(limpa), /^100,00% com origem classificada$/);
  assert.equal(coberturaDaTabela([]), '—');
});

test('MÉDIO 4 — a nota dos interruptores de auditoria cita o recorte NA TELA, não um número congelado', () => {
  const resp = { ...PADRAO, __so_sem_valor: true, lista: { ...PADRAO.lista, total: 461 },
    cards: { ...PADRAO.cards, total_oportunidades: '5413' } };
  const html = renderRodapeLista(resp, 50);
  assert.match(html, /a lista está em <strong>461<\/strong>/);
  assert.match(html, /os cards continuam em <strong>5\.413<\/strong>/);
  assert.doesNotMatch(html, /836/, 'o número medido uma vez no preset "Tudo" não pode ficar escrito na tela');
  assert.doesNotMatch(html, /8\.073/);

  // par: com outro recorte, a nota muda junto — é o que prova que vem do dado
  const outro = { ...resp, lista: { ...resp.lista, total: 836 }, cards: { ...resp.cards, total_oportunidades: '8073' } };
  assert.match(renderRodapeLista(outro, 50), /a lista está em <strong>836<\/strong>/);
  assert.match(renderRodapeLista(outro, 50), /os cards continuam em <strong>8\.073<\/strong>/);
});

test('MÉDIO 4 — sem interruptor de auditoria não há nota nenhuma', () => {
  const html = renderRodapeLista({ ...PADRAO }, 10);
  assert.doesNotMatch(html, /interruptores são de AUDITORIA/);
  assert.match(html, /Mostrando 10 de 420/);
});
