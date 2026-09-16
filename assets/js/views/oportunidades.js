// assets/js/views/oportunidades.js — a aba Oportunidades sobre a BASE INTEIRA
// (migrations 097 / 098 / 100, endpoint GET /api/oportunidades).
//
// POR QUE ESTA ABA EXISTE (e a antiga não podia ser consertada no lugar)
//
// A aba anterior (`view-oportunidades`, lógica em views-legacy.js) lia uma
// planilha Google de 513 linhas. A base tem 8.073 oportunidades, e a planilha
// era subconjunto ESTRITO. Os defeitos medidos pela auditoria:
//
//   · 93% da receita ganha vinha de leads que a planilha não continha — por
//     isso a aba conseguia afirmar "100% atribuído a marketing".
//   · win rate 6,8%, porque dividia ganhas por TODAS as oportunidades,
//     inclusive as ainda não decididas. Sobre as decididas é 56,56%.
//   · 1.556 de 2.753 leads (56,5%) não apareciam em card nenhum.
//   · toda seta de tendência comparava contra ZERO: a planilha não tinha
//     período anterior.
//   · `isWon` era `valorNF > 0 && !isLost` — preencher Valor NF numa proposta
//     virava venda ganha.
//   · a receita somava BRL, USD e MXN no mesmo número.
//
// AS REGRAS DESTA TELA, e cada uma é um desses defeitos negado:
//
//  1. WIN RATE NUNCA SEM O DENOMINADOR. `56,56%` sai sempre acompanhado de
//     "987 de 1.745 decididas", visível, não em tooltip. E
//     `win_rate_sobre_todas_pct` NÃO vai para a tela: ele vem da API só como
//     contraste de auditoria, e é literalmente o número errado da aba antiga.
//  2. RECEITA NUNCA SOZINHA. Ao lado dela, sempre, quantas ganhas ficaram
//     FORA da soma e por quê (`qtd_ganhas_fora_do_valor` +
//     `ganhas_fora_do_valor_motivos`). Hoje são 147, por Amount vazio.
//  3. `soma_fecha === false` ⇒ OS NÚMEROS NÃO SÃO DESENHADOS. A partição por
//     desfecho tem de fechar com o total; se não fecha, a camada está errada,
//     e desenhar assim mesmo seria a tela fingindo que não viu.
//  4. O FUNIL É ESTOQUE, NÃO FLUXO. `qtd_da_coorte_agora` responde "das
//     criadas no período, quantas estão AGORA nesta fase". É PROIBIDO dividir
//     uma fase pela outra e chamar de conversão: as fases são estados
//     simultâneos, não etapas percorridas, e esta base só ingere o estágio
//     ATUAL (não há histórico). A aba antiga dividia "Qualificados" por "Em
//     cadência" — dois estados mutuamente exclusivos — e chamava o resultado
//     de taxa.
//  5. A LINHA `(fora de qualquer fase)` APARECE SEMPRE, mesmo valendo 4. Foi
//     omitir o resto que fez 56,5% dos leads sumirem da aba antiga.
//  6. SETA DE TENDÊNCIA SÓ COM `periodo_anterior_tem_dado === true`. Quando
//     for false, a seta some e o motivo aparece. Variação contra zero, nunca.
//  7. SEM CARD DE CICLO. `dias_ate_close_date_*` vem na API e NÃO vai para a
//     tela: `CloseDate` nesta org carrega o FIM DO CONTRATO, não o fecho da
//     venda (587 das 987 ganhas têm CloseDate anterior à criação). O que a
//     tela mostra é a RESSALVA, que é a informação honesta.
//  8. DINHEIRO É `*_brl`. Os valores vêm sem arredondar de propósito
//     (arredondar linha a linha acumula deriva); quem formata é a tela, via
//     ../formato-moeda.js — o mesmo módulo da ficha do lead, para que "R$ em
//     cima de MXN" não volte por um segundo caminho.
//  9. PERÍODO É DECISÃO EXPLÍCITA DO FRONT. A API não tem padrão: sem de/ate
//     ela devolve o universo e diz `periodo_aplicado: false`. Esta tela manda
//     os últimos 12 meses ao abrir e mostra, por escrito, qual recorte está
//     aplicado.
// 10. TODO NÚMERO QUE É CONJUNTO ABRE O CONJUNTO, E O TOTAL DO PAINEL É O
//     NÚMERO CLICADO. Mesmo modelo de interação do modal da aba antiga
//     (`abrirDetalheCard`), com a conferência painel × card escrita na tela.
//     Número que NÃO é conjunto (win rate, receita, ticket, pipeline) não vira
//     botão: abrir uma lista embaixo de uma razão ou de uma soma obrigaria o
//     painel a exibir um total que não é o número do card. Ver a seção
//     DRILL-DOWN mais abaixo.
//
// ⚠️ OS FILTROS NÃO CHEGAM TODOS EM TODA SEÇÃO — e isso é da camada de dados,
// não desta tela. Medido contra a API em 2026-09-16, linha a linha, depois da
// correção da borda:
//
//   cards     : de/ate, segmento, fase, desfecho, record_type, moeda, vínculo
//   funil     : de/ate, segmento,                 record_type, moeda, vínculo   (IGNORA fase e desfecho)
//   segmento  : de/ate,           fase, desfecho, record_type, moeda            (IGNORA segmento e vínculo)
//   categoria : de/ate, segmento, fase, desfecho, record_type, moeda, categoria (IGNORA vínculo)
//   lista     : tudo acima + busca + so_divergentes + so_sem_valor + so_nao_classificado + ordenar_por
//
// A tabela de CATEGORIA não é a de segmento com outro eixo: ela APLICA
// `segmento` (que a de segmento ignora) e IGNORA `lead_vinculo_regra` (que a de
// segmento também ignora). Copiar a herança de uma para a outra por simetria
// produziria painel que não bate com a linha — medido, não deduzido.
//
// HISTÓRICO DA BORDA, porque explica escolhas que sobraram no código: até
// 2026-09-16 o Code node "Montar filtros" do n8n tinha uma whitelist escrita
// antes das migrations 100 e 103/104, e DESCARTAVA EM SILÊNCIO `categoria`,
// `lead_source` e `so_nao_classificado` — a tela pedia um recorte e recebia o
// universo, com 200 e sem erro. Corrigido. Duas marcas ficaram:
//   · o painel de cobertura é expresso em `segmento=NaoClassificado,SemOrigem`
//     em vez de `so_nao_classificado=true`. Os dois predicados são idênticos no
//     SQL; o primeiro nasceu do contorno e continua porque é o que o teste
//     contra a API exercita hoje;
//   · há um teste vigiando a whitelist (oportunidades-drilldown-api), com par
//     negativo, para a regressão não voltar calada.
//
// `categoria` NÃO VIRA SELETOR NA BARRA DE FILTROS, e isso é medição, não
// esquecimento: ela estreita a LISTA e a tabela de categoria, mas NÃO os cards
// (com `categoria=Evento/Webinar` a lista vai a 33 e os cards continuam em
// 5.415). Publicar o seletor faria os doze cards do topo contradizerem a tabela.
// O caminho para "quais são essas 33" é o drill-down da linha.
//
// `so_divergentes` e `so_sem_valor` existem SÓ em `fn_search_oportunidades`:
// eles estreitam a LISTA e não tocam nos cards (conferido: com
// `so_sem_valor=true` a lista vai a 462 e os cards continuam em 5.415 no
// recorte de 12 meses). Cada seção declara na tela o que ela ignora — senão o
// usuário lê contradição e conclui que o dado está errado, quando o errado
// seria o silêncio.

import { obterOportunidades } from '../data-api.js';
import { fmtValor, fmtBrl, fmtMrr } from '../formato-moeda.js';
import { lerEstadoAtual, atualizarEstado } from '../url-state.js';

// ---------------------------------------------------------------------------
// utilidades
// ---------------------------------------------------------------------------
export function escapeHtml(str) {
  return String(str ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

const n = (v) => {
  const x = Number(v);
  return Number.isFinite(x) ? x : null;
};
const int = (v) => {
  const x = Number(v);
  return Number.isFinite(x) ? Math.round(x) : 0;
};
const br = (v) => int(v).toLocaleString('pt-BR');

// Percentual que a API já calculou (string numérica). NÃO recalculamos: o
// denominador certo é o do SQL, e refazer a conta aqui abriria a porta para a
// tela e o banco discordarem no arredondamento.
function pct(v) {
  const x = n(v);
  return x === null ? null : `${x.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}%`;
}

// INSTANTE (criada_em, gerado_em): renderizado no fuso local, que é o certo
// para "quando isso aconteceu".
function dataCurta(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

// BORDA DE PERÍODO (periodo_de / periodo_ate / as duas do período anterior):
// renderizada em UTC, e isto é correção de um defeito real visto em produção,
// não preciosismo. Essas bordas chegam como meia-noite UTC
// (`2025-09-16T00:00:00.000Z`); lidas no fuso de São Paulo (UTC-3) viram
// 21:00 do DIA ANTERIOR, e a barra passava a dizer "recorte de 15/09/2025"
// para um filtro que mandou `de=2025-09-16`. A tela contradizia o próprio
// parâmetro que enviou.
// `deslocaDias` existe porque `ate` é EXCLUSIVO na API: para escrever um
// intervalo que um humano lê, o último dia mostrado é `ate - 1`.
function dataDePeriodo(iso, deslocaDias = 0) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const alvo = new Date(d.getTime() + deslocaDias * 86400000);
  return alvo.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'UTC' });
}

/**
 * Seta de tendência. REGRA 6: sem período anterior não existe seta.
 *
 * Três saídas distintas, de propósito:
 *   · sem dado anterior  → texto do motivo, nenhuma seta;
 *   · anterior em zero   → "período anterior em zero", nenhuma seta (dividir
 *                          por zero é como a aba antiga produzia +100% em
 *                          tudo);
 *   · com base           → seta + variação.
 * @param {boolean} inverso true quando CRESCER é ruim (perdidas)
 */
export function tendencia(atual, anterior, temDado, motivo, inverso = false) {
  if (!temDado) {
    // Frase CURTA aqui, motivo completo UMA VEZ na barra de recorte. Repetir o
    // parágrafo inteiro em doze cards afogava os números que o card existe
    // para mostrar — e um aviso que ninguém lê por excesso é um aviso perdido.
    return `<div class="kpi-footer" style="color:var(--dim);line-height:1.4"
      title="${escapeHtml(motivo || '')}">sem base de comparação — ver o motivo no topo</div>`;
  }
  const a = n(atual);
  const b = n(anterior);
  if (a === null || b === null) {
    return '<div class="kpi-footer" style="color:var(--dim)">Período anterior sem este número.</div>';
  }
  if (b === 0) {
    return '<div class="kpi-footer" style="color:var(--dim)">Período anterior em zero — variação não é calculável.</div>';
  }
  const varPct = ((a - b) / Math.abs(b)) * 100;
  const subiu = varPct > 0;
  const bom = inverso ? !subiu : subiu;
  const cor = Math.abs(varPct) < 0.005 ? 'var(--muted)' : (bom ? 'var(--green)' : 'var(--red)');
  const icone = Math.abs(varPct) < 0.005 ? 'ti-minus' : (subiu ? 'ti-trending-up' : 'ti-trending-down');
  const sinal = subiu ? '+' : '';
  return `<div class="kpi-footer" style="color:${cor};display:flex;align-items:center;gap:4px">
    <i class="ti ${icone}"></i>${sinal}${varPct.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}% vs. período anterior
  </div>`;
}

// ---------------------------------------------------------------------------
// REGRA 3 — a partição por desfecho tem de fechar
// ---------------------------------------------------------------------------
// A partição TOTAL do desfecho, com o valor de filtro ao lado do campo de
// contagem. Os dois escritos à mão, de propósito: derivar um do outro por
// `replace('qtd_','')` funcionaria hoje e quebraria calado no dia em que a
// camada ganhasse um sétimo valor com plural irregular.
const DESFECHOS = [
  { campo: 'qtd_ganhas', valor: 'ganha', rotulo: 'Ganhas', cor: 'var(--green)' },
  { campo: 'qtd_perdidas', valor: 'perdida', rotulo: 'Perdidas', cor: 'var(--red)' },
  { campo: 'qtd_abertas', valor: 'aberta', rotulo: 'Abertas', cor: 'var(--blue)' },
  { campo: 'qtd_fora_de_fase', valor: 'fora_de_fase', rotulo: 'Fora de fase', cor: 'var(--amber)' },
  { campo: 'qtd_estagio_nao_declarado', valor: 'estagio_nao_declarado', rotulo: 'Estágio não declarado', cor: 'var(--purple)' },
  { campo: 'qtd_declaracao_incompleta', valor: 'declaracao_incompleta', rotulo: 'Declaração incompleta', cor: 'var(--purple)' },
];

/**
 * Tira da partição os seis valores + o total, e confere a soma NA TELA além de
 * ler `soma_fecha`. Conferir dos dois lados é de propósito: `soma_fecha` é a
 * afirmação da camada de dados, e esta é a verificação independente dela.
 */
export function conferirParticao(cards) {
  const total = int(cards.total_oportunidades);
  const partes = DESFECHOS.map((d) => ({ ...d, qtd: int(cards[d.campo]) }));
  const soma = partes.reduce((s, p) => s + p.qtd, 0);
  return {
    total,
    partes,
    soma,
    fechaNaTela: soma === total,
    fechaNaApi: cards.soma_fecha === true,
    diferencaApi: n(cards.soma_fecha_diferenca),
  };
}

export function renderIntegridade(cards) {
  const p = conferirParticao(cards);
  if (p.fechaNaApi && p.fechaNaTela) {
    const linhas = p.partes.map((x) => `<span style="display:inline-flex;align-items:center;gap:5px">
        <span style="width:7px;height:7px;border-radius:50%;background:${x.cor};display:inline-block"></span>
        ${escapeHtml(x.rotulo)} <strong style="font-variant-numeric:tabular-nums">${br(x.qtd)}</strong></span>`).join('<span style="color:var(--dim)">+</span>');
    return `<div class="card" style="padding:12px 16px;margin-bottom:16px">
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;font-size:12px;color:var(--muted)">
        <span class="badge lq"><i class="ti ti-check" style="margin-right:4px"></i>a partição fecha</span>
        ${linhas}
        <span style="color:var(--dim)">=</span>
        <span><strong style="font-variant-numeric:tabular-nums;color:var(--text)">${br(p.total)}</strong> oportunidades</span>
      </div>
      <div class="mono-sm" style="color:var(--dim);margin-top:6px;line-height:1.5">
        Os seis desfechos são mutuamente exclusivos e cobrem 100% do recorte — a autoridade é
        <code>IsWon</code>/<code>IsClosed</code> declarados pelo Salesforce, não o rótulo do estágio.
        Nenhuma oportunidade fica fora de card: foi omitir o resto que fez 56,5% dos leads sumirem da aba antiga.
      </div>
    </div>`;
  }

  // REGRA 3: aqui a tela PARA. Nada de KPI, nada de funil, nada de segmento.
  const dif = p.diferencaApi !== null ? p.diferencaApi : (p.soma - p.total);
  return `<div class="card" style="border-color:var(--red);margin-bottom:16px">
    <div class="section-row"><div class="section-title" style="color:var(--red)">
      <i class="ti ti-alert-octagon"></i>A partição por desfecho não fecha — os números não vão para a tela</div>
      <div class="section-badge" style="background:var(--red-dim);color:var(--red)">soma_fecha = false</div></div>
    <div style="font-size:13px;line-height:1.6">
      A camada de dados declara ${DESFECHOS.length} desfechos mutuamente exclusivos que deveriam somar o total do recorte.
      Neste momento eles somam <strong style="font-variant-numeric:tabular-nums">${br(p.soma)}</strong>
      contra um total de <strong style="font-variant-numeric:tabular-nums">${br(p.total)}</strong> —
      diferença de <strong style="color:var(--red);font-variant-numeric:tabular-nums">${br(Math.abs(dif))}</strong> oportunidade(s).
    </div>
    <div style="display:flex;gap:14px;flex-wrap:wrap;margin-top:12px;font-size:12px;color:var(--muted)">
      ${p.partes.map((x) => `<span>${escapeHtml(x.rotulo)}: <strong style="font-variant-numeric:tabular-nums;color:var(--text)">${br(x.qtd)}</strong></span>`).join('')}
    </div>
    <div class="tl-idade" style="margin-top:12px;line-height:1.55">
      ⚠️ Desenhar win rate, receita e funil em cima de uma partição que não fecha seria a tela fingindo que não viu.
      Enquanto isto aparecer, o defeito está na camada de dados (<code>fn_oportunidades_cards</code>, migrations 097/100)
      e não adianta reler a tela. Os únicos números acima são os da própria conferência.
    </div>
  </div>`;
}

// ---------------------------------------------------------------------------
// KPIs — 12 cards, duas fileiras de 6
// ---------------------------------------------------------------------------
/**
 * Um card. `drill` é OPCIONAL e só existe para os cards cujo número é um
 * CONJUNTO: recebe `{ tipo, esperado }` e transforma o card em botão.
 *
 * `data-esperado` sai da MESMA expressão que pintou o número do card, e não de
 * uma segunda leitura do mesmo campo: é ele que o painel usa para conferir que
 * a lista aberta tem exatamente o tamanho do número clicado. Duas leituras
 * seriam duas chances de discordar.
 */
function kpi(cor, icone, rotulo, valor, rodape, titulo, tamanho, drill) {
  // CARD VALENDO ZERO NÃO ABRE. A mesma regra das tabelas de segmento e
  // categoria e da linha "(fora de qualquer fase)" do funil: um clique que só
  // pode dar lista vazia informa menos do que a frase que explica o zero.
  //
  // Não é caso de canto: no payload real de 12 meses (e na base inteira)
  // "Sem declaração da origem" e "Divergência origem × fase" valem 0, e o card
  // convidava, escrito, a "abrir as 0 oportunidades". É o estado PADRÃO da aba.
  const abre = Boolean(drill) && int(drill.esperado) > 0;
  const clicavel = abre
    ? ` role="button" tabindex="0" data-drill="${escapeHtml(drill.tipo)}" data-esperado="${int(drill.esperado)}"`
      + ` style="cursor:pointer" aria-label="${escapeHtml(`${rotulo}: abrir as ${br(drill.esperado)} oportunidades que compõem este número`)}"`
    : '';
  const dica = abre
    ? `<div class="kpi-footer" style="color:var(--dim);display:flex;align-items:center;gap:4px">
        <i class="ti ti-list-search"></i>abrir as ${br(drill.esperado)} oportunidades</div>`
    : (drill ? '<div class="kpi-footer" style="color:var(--dim);line-height:1.4">Sem lista: não há nenhuma para listar neste recorte.</div>' : '');
  return `<div class="kpi ${cor}"${clicavel}>
    <div class="kpi-label"${titulo ? ` title="${escapeHtml(titulo)}"` : ''}><i class="ti ${icone}"></i>${escapeHtml(rotulo)}</div>
    <div class="kpi-value"${tamanho ? ` style="font-size:${tamanho}"` : ''}>${valor}</div>
    ${rodape || ''}${dica}
  </div>`;
}

export function renderKpis(cards) {
  const temAnt = cards.periodo_anterior_tem_dado === true;
  const motivoAnt = cards.periodo_anterior_sem_dado_motivo;
  const total = int(cards.total_oportunidades);
  const ganhas = int(cards.qtd_ganhas);
  const decididas = int(cards.qtd_decididas);
  const foraDoValor = int(cards.qtd_ganhas_fora_do_valor);

  const parte = (q) => (total > 0 ? `${((q / total) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}% do recorte` : '—');

  // REGRA 1: o denominador é parte do indicador, não nota de rodapé opcional.
  const winRate = pct(cards.win_rate_decididas_pct) ?? '—';
  const winFooter = `<div class="kpi-footer" style="color:var(--text);font-weight:600;font-variant-numeric:tabular-nums">
      ${br(ganhas)} de ${br(decididas)} decididas</div>
    <div class="kpi-footer" style="line-height:1.4">Decididas = ganhas + perdidas. As ${br(int(cards.qtd_abertas) + int(cards.qtd_fora_de_fase))} não decididas ficam fora do denominador.</div>`;

  // REGRA 2: receita nunca sozinha.
  const motivos = cards.ganhas_fora_do_valor_motivos && typeof cards.ganhas_fora_do_valor_motivos === 'object'
    ? Object.entries(cards.ganhas_fora_do_valor_motivos) : [];
  const receitaFooter = foraDoValor > 0
    ? `<div class="kpi-footer" style="color:var(--amber);font-weight:600;font-variant-numeric:tabular-nums">
        ${br(foraDoValor)} ganha(s) fora da soma</div>
       <div class="kpi-footer" style="line-height:1.4">${motivos.map(([m, q]) => `${br(q)}× ${escapeHtml(m)}`).join(' · ') || 'motivo não informado pela origem'}</div>
       <div class="kpi-footer">base da soma: ${br(cards.qtd_ganhas_no_valor)} ganhas com valor convertido</div>`
    : `<div class="kpi-footer" style="color:var(--green)">todas as ${br(ganhas)} ganhas entraram na soma</div>`;

  // OS TRÊS CARDS SEM CLIQUE desta fileira são razão e soma, não conjunto: uma
  // lista embaixo deles teria um total que não é o número exibido. O motivo
  // fica escrito no card, porque "não clica" sem explicação vira suspeita de
  // bug.
  const semConjunto = (frase) => `<div class="kpi-footer" style="color:var(--dim);line-height:1.4">${frase}</div>`;

  const fileira1 = [
    kpi('blue', 'ti-briefcase', 'Oportunidades', br(total),
      `<div class="kpi-footer">criadas no recorte (campo <code>criada_em</code>)</div>${tendencia(total, cards.ant_total_oportunidades, temAnt, motivoAnt)}`,
      'Todas as oportunidades do Salesforce criadas dentro do recorte. Universo inteiro — não é o recorte de nenhuma planilha.',
      null, { tipo: 'total', esperado: total }),
    kpi('green', 'ti-trophy', 'Ganhas', br(ganhas),
      `<div class="kpi-footer">${parte(ganhas)}</div>${tendencia(ganhas, cards.ant_qtd_ganhas, temAnt, motivoAnt)}`,
      'A origem declara IsWon = true. Não é "tem valor preenchido" — era isso que a aba antiga usava.',
      null, { tipo: 'ganhas', esperado: ganhas }),
    kpi('red', 'ti-mood-sad', 'Perdidas', br(cards.qtd_perdidas),
      `<div class="kpi-footer">${parte(int(cards.qtd_perdidas))}</div>${tendencia(cards.qtd_perdidas, cards.ant_qtd_perdidas, temAnt, motivoAnt, true)}`,
      'A origem declara IsClosed = true e IsWon = false.',
      null, { tipo: 'perdidas', esperado: int(cards.qtd_perdidas) }),
    kpi('blue', 'ti-progress', 'Abertas', br(cards.qtd_abertas),
      `<div class="kpi-footer">${parte(int(cards.qtd_abertas))} · ainda não decididas</div>${tendencia(cards.qtd_abertas, cards.ant_qtd_abertas, temAnt, motivoAnt)}`,
      'IsClosed = false e o estágio está dentro do funil.',
      null, { tipo: 'abertas', esperado: int(cards.qtd_abertas) }),
    kpi('purple', 'ti-percentage', 'Win rate (decididas)', winRate,
      `${winFooter}${semConjunto('Sem lista: é uma razão entre dois conjuntos, não um conjunto. Os dois lados dela abrem pelos cards Ganhas e Perdidas.')}`,
      'ganhas ÷ (ganhas + perdidas). A aba antiga dividia por TODAS as oportunidades e chegava a 6,8%.'),
    kpi('green', 'ti-cash', 'Receita ganha', fmtBrl(cards.receita_ganha_brl) ?? '—',
      `${receitaFooter}${semConjunto('Sem lista: é uma soma em reais, e o total de qualquer lista seria uma contagem — outro número. As ganhas abrem pelo card ao lado; as que ficaram fora da soma, pela seção logo abaixo.')}`,
      'Soma de amount convertido para real. BRL/USD/MXN convertidos pela taxa de currency_rate; sem taxa, a linha NÃO entra na soma e é contada ao lado.', '17px'),
  ].join('');

  const naoClassificado = int(cards.qtd_nao_classificado);
  const semOrigem = int(cards.qtd_sem_origem);
  const divergencias = int(cards.qtd_divergencia_origem_vs_fase);
  const semDeclaracao = int(cards.qtd_estagio_nao_declarado) + int(cards.qtd_declaracao_incompleta);

  const fileira2 = [
    kpi('amber', 'ti-stack-2', 'Pipeline aberto', fmtBrl(cards.pipeline_aberto_brl) ?? '—',
      `<div class="kpi-footer">${br(cards.qtd_abertas_no_pipeline)} com valor · ${br(cards.qtd_abertas_fora_do_pipeline)} sem valor</div>
       <div class="kpi-footer" style="line-height:1.4">É ESTOQUE do que está aberto agora — jamais previsão de receita.</div>
       ${tendencia(cards.pipeline_aberto_brl, cards.ant_pipeline_aberto_brl, temAnt, motivoAnt)}
       ${semConjunto('Sem lista: é uma soma em reais. As não decididas abrem pelos cards Abertas e Fora de qualquer fase.')}`,
      'Soma do valor das não decididas (abertas + fora de fase). Não tem probabilidade aplicada e não é forecast.', '17px'),
    kpi('blue', 'ti-receipt', 'Ticket médio das ganhas', fmtBrl(cards.ticket_medio_ganhas_brl) ?? '—',
      `<div class="kpi-footer">base: ${br(cards.ticket_medio_n)} ganhas com valor</div>
       ${tendencia(cards.ticket_medio_ganhas_brl, cards.ant_ticket_medio_ganhas_brl, temAnt, motivoAnt)}
       ${semConjunto('Sem lista: é uma média. E a base dela (“ganhas COM valor”) não é um recorte que a API saiba devolver — só existe o complemento, “sem valor”, que abre na seção abaixo.')}`,
      'Média do amount convertido das ganhas que têm valor. As ganhas sem valor não entram — e por isso a base aparece escrita.', '17px'),
    kpi('amber', 'ti-circle-dashed', 'Fora de qualquer fase', br(cards.qtd_fora_de_fase),
      `<div class="kpi-footer" style="line-height:1.4">Abertas na origem, em estágio que o nosso mapa declara fora do funil de propósito.</div>
       <div class="kpi-footer">aparece mesmo valendo ${br(cards.qtd_fora_de_fase)} — some nunca</div>`,
      'Estágios como "Lista": IsClosed = false e fora do funil. Deixar este número invisível é como 56,5% dos leads sumiram da aba antiga.',
      null, { tipo: 'fora_de_fase', esperado: int(cards.qtd_fora_de_fase) }),
    kpi(semDeclaracao > 0 ? 'red' : 'purple', 'ti-help-octagon', 'Sem declaração da origem', br(semDeclaracao),
      `<div class="kpi-footer">${br(cards.qtd_estagio_nao_declarado)} estágio fora do catálogo · ${br(cards.qtd_declaracao_incompleta)} IsWon/IsClosed nulo</div>
       <div class="kpi-footer" style="line-height:1.4">A org tem 114 estágios e nós mapeamos 29 — este card é o alarme de estágio novo entrando calado.</div>`,
      'Oportunidades cujo estágio não existe em opportunity_stage, ou existe com IsWon/IsClosed nulo. Nós não chutamos o desfecho delas.',
      null, { tipo: 'sem_declaracao', esperado: semDeclaracao }),
    // O NÚMERO EXIBIDO É A COBERTURA; o conjunto que existe para abrir é o
    // COMPLEMENTO dela. O painel diz isso no título em vez de abrir uma lista
    // de 800 embaixo de um card que mostra 85,23%.
    kpi('purple', 'ti-route', 'Com origem classificada', pct(cards.pct_com_segmento) ?? '—',
      `<div class="kpi-footer">${br(cards.qtd_com_segmento)} de ${br(total)} oportunidades</div>
       <div class="kpi-footer" style="line-height:1.4">${br(naoClassificado)} com LeadSource que ninguém traduziu · ${br(semOrigem)} sem lead e sem LeadSource</div>`,
      'Cobertura da atribuição. Tem de aparecer junto de qualquer corte Marketing × Comercial — ler participação por segmento sem saber a cobertura é como a planilha chegou a "100% marketing".',
      null, { tipo: 'sem_origem_classificada', esperado: naoClassificado + semOrigem }),
    kpi(divergencias > 0 ? 'red' : 'green', 'ti-arrows-diff', 'Divergência origem × fase', br(divergencias),
      `<div class="kpi-footer" style="line-height:1.4">${divergencias > 0
        ? 'O Salesforce e o nosso mapa de fases discordam nestas linhas. Estão marcadas na lista.'
        : 'Nenhuma discordância entre IsWon/IsClosed da origem e a fase que nós traduzimos.'}</div>`,
      'Existe para o dia em que um estágio novo com IsWon = true entrar pela porta da frente sem ninguém notar.',
      null, { tipo: 'divergentes', esperado: divergencias }),
  ].join('');

  return `<div class="kpi-grid-6">${fileira1}</div><div class="kpi-grid-6">${fileira2}</div>`;
}

// ---------------------------------------------------------------------------
// REGRA 4 e 5 — funil de ESTOQUE
// ---------------------------------------------------------------------------
const COR_FASE = {
  contato: 'var(--blue)', qualificacao: 'var(--purple)', reuniao: 'var(--amber)',
  negociacao: 'var(--amber)', ganho: 'var(--green)', perdido: 'var(--red)',
};
const ROTULO_FASE = {
  contato: 'Contato', qualificacao: 'Qualificação', reuniao: 'Reunião',
  negociacao: 'Negociação', ganho: 'Ganho', perdido: 'Perdido',
};

export function renderFunil(funil, opcoes = {}) {
  const linhas = Array.isArray(funil) ? funil : [];
  if (linhas.length === 0) {
    return '<div class="empty-state"><div class="es-title">Sem oportunidades no recorte</div><div>Nenhuma fase a exibir.</div></div>';
  }
  // A linha "(fora de qualquer fase)" é OBRIGATÓRIA (regra 5) e a camada de
  // dados a emite sempre — se um dia ela sumir, a tela avisa em vez de calar.
  const temForaDeFase = linhas.some((f) => f.fase === null || f.fase === undefined);
  const totalCoorte = int(linhas[0]?.total_da_coorte);
  const somaQtd = linhas.reduce((s, f) => s + int(f.qtd_da_coorte_agora), 0);
  const maior = Math.max(1, ...linhas.map((f) => int(f.qtd_da_coorte_agora)));

  const corpo = linhas.map((f) => {
    const qtd = int(f.qtd_da_coorte_agora);
    const cor = f.fase ? (COR_FASE[f.fase] ?? 'var(--muted)') : 'var(--dim)';
    const rotulo = f.fase ? (ROTULO_FASE[f.fase] ?? f.fase) : (f.fase_rotulo ?? '(fora de qualquer fase)');
    const largura = (qtd / maior) * 100;
    const valor = fmtBrl(f.valor_brl);
    const semValor = int(f.qtd_sem_valor);
    // A LINHA "(fora de qualquer fase)" NÃO ABRE, e isto é limite da camada de
    // dados, não esquecimento. Ela é `fase IS NULL`, e `fn_filtro_casa` nunca
    // casa NULL com filtro presente (de propósito: filtrar por fase não deve
    // trazer quem não tem fase) — não existe valor de `fase` que devolva
    // exatamente estas linhas. Trocar por `desfecho=fora_de_fase` seria outro
    // conjunto: uma ganha cujo estágio esteja fora do funil cai nesta barra e
    // NÃO naquele desfecho. Hoje os dois números coincidem (4 e 4), e abrir a
    // lista por causa da coincidência seria acertar por sorte.
    const abre = Boolean(f.fase) && qtd > 0;
    const attrs = abre
      ? ` role="button" tabindex="0" data-drill="fase:${escapeHtml(f.fase)}" data-esperado="${qtd}" style="cursor:pointer"`
        + ` aria-label="${escapeHtml(`${rotulo}: abrir as ${br(qtd)} oportunidades desta fase`)}"`
      : ' style="cursor:default"';
    return `<div class="funil2-row"${attrs}>
      <div class="funil2-name"${f.fase ? '' : ' style="color:var(--muted);font-style:italic"'}>${escapeHtml(rotulo)}</div>
      <div class="funil2-track">
        <div class="funil2-fill" style="width:${largura.toFixed(2)}%;background:${cor}"></div>
      </div>
      <div class="funil2-val">${br(qtd)}<span class="mono-sm" style="display:block;font-weight:400;color:var(--muted);font-size:10.5px">${pct(f.pct_da_coorte) ?? '—'} da coorte</span></div>
    </div>
    <div class="mono-sm" style="color:var(--dim);padding:0 10px 8px 184px;line-height:1.45">
      ${valor ? `${escapeHtml(valor)} em valor convertido` : 'sem valor convertido'}${semValor > 0 ? ` · ${br(semValor)} sem valor na origem` : ''}${abre ? '' : (f.fase
        ? ' · <span style="color:var(--dim)">sem lista: nenhuma oportunidade nesta fase neste recorte</span>'
        : ' · <span style="color:var(--amber)">sem lista: esta linha é “fase nula”, e a API não aceita filtrar por ausência de fase</span>')}
    </div>`;
  }).join('');

  const avisoFiltro = opcoes.ignorando && opcoes.ignorando.length
    ? `<div class="tl-idade" style="margin-bottom:10px;line-height:1.5">⚠️ Esta seção IGNORA ${escapeHtml(opcoes.ignorando.join(' e '))} —
        <code>fn_oportunidades_funil</code> não aceita esses filtros, porque filtrar a coorte por fase a reduziria à própria fase escolhida.
        Os cards acima estão filtrados; este funil não. A diferença é real e está escrita aqui em vez de ser deixada para o leitor descobrir.</div>`
    : '';

  const conferencia = somaQtd === totalCoorte
    ? `<span style="color:var(--green)">as fases somam ${br(somaQtd)} = o total da coorte</span>`
    : `<span style="color:var(--red)">⚠️ as fases somam ${br(somaQtd)} mas a coorte tem ${br(totalCoorte)} — há ${br(Math.abs(somaQtd - totalCoorte))} oportunidade(s) fora de toda linha</span>`;

  return `${avisoFiltro}
    <div class="funil2">${corpo}</div>
    <div class="mono-sm" style="color:var(--dim);margin-top:10px;line-height:1.6;border-top:1px solid var(--border);padding-top:10px">
      <strong style="color:var(--amber)">Leia como estoque.</strong> Cada barra responde
      “das oportunidades CRIADAS no recorte, quantas estão AGORA nesta fase”. As fases são estados
      simultâneos no instante da leitura, não etapas que a mesma oportunidade percorre —
      esta base ingere só o estágio ATUAL, sem histórico.
      <strong style="color:var(--amber)">Dividir uma barra pela outra não produz taxa de conversão nenhuma.</strong>
      A aba antiga dividia “Qualificados” por “Em cadência”, que são mutuamente exclusivos, e chamava o resultado de conversão.
      <br>${conferencia}.
      ${temForaDeFase ? '' : ' <span style="color:var(--red)">⚠️ a linha “(fora de qualquer fase)” não veio da API — ela é obrigatória.</span>'}
    </div>`;
}

// ---------------------------------------------------------------------------
// Marketing × Comercial (segmento)
// ---------------------------------------------------------------------------
const ROTULO_SEG = {
  Marketing: 'Marketing', Comercial: 'Comercial', Parceiro: 'Parceiro',
  NaoAtribuido: 'Não atribuído', NaoClassificado: 'Não classificado', SemOrigem: 'Sem origem',
};
const NOTA_SEG = {
  Marketing: 'Lead com sinal de mídia paga rastreado, ou LeadSource reconhecido como código de campanha.',
  Comercial: 'Lead cadastrado direto no CRM, sem sinal de mídia paga.',
  Parceiro: 'Indicação de parceiro.',
  NaoAtribuido: 'Tem origem identificada, mas nenhuma regra a classificou em marketing/comercial/parceiro.',
  NaoClassificado: 'A origem declarou um LeadSource que o crosswalk ainda não traduz. NÃO é "comercial" — despejar o desconhecido num balde existente foi como a aba antiga chegou a "100% marketing".',
  SemOrigem: 'Não tem lead vinculado NEM LeadSource. A origem simplesmente não tem o dado.',
};
const CLASSE_SEG = { Marketing: 'mkt', Comercial: 'com', Parceiro: 'lq', NaoAtribuido: 'na', NaoClassificado: 'na', SemOrigem: 'lead' };

export function renderSegmento(segmento, opcoes = {}) {
  const linhas = Array.isArray(segmento) ? segmento : [];
  if (linhas.length === 0) {
    return '<div class="empty-state"><div class="es-title">Sem oportunidades no recorte</div><div>Nenhum segmento a exibir.</div></div>';
  }
  const totalRecorte = int(linhas[0]?.total_do_recorte);
  const somaQtd = linhas.reduce((s, x) => s + int(x.qtd_oportunidades), 0);

  const corpo = linhas.map((s) => {
    const nome = s.segmento_aba;
    const dec = int(s.qtd_decididas);
    const wr = pct(s.win_rate_decididas_pct);
    const qtd = int(s.qtd_oportunidades);
    const leads = int(s.qtd_leads_gerados);
    const notaJoin = PRESENTE_EM[s.segmento_presente_em] ?? null;
    // MESMA REGRA DA TABELA DE CATEGORIA: só abre se houver o que listar.
    // A migration 103 transformou esta função em FULL OUTER JOIN com o lado do
    // lead, e com isso passaram a existir linhas de ZERO oportunidade (com
    // `desfecho=fora_de_fase`, Marketing e Não atribuído vêm a 0 e `so_lead`).
    // Antes desta guarda elas abriam painel vazio sem explicação nenhuma.
    const abre = qtd > 0;
    const attrs = abre
      ? ` role="button" tabindex="0" data-drill="segmento:${escapeHtml(nome)}" data-esperado="${qtd}" style="cursor:pointer"`
        + ` aria-label="${escapeHtml(`${ROTULO_SEG[nome] ?? nome}: abrir as ${br(qtd)} oportunidades deste segmento`)}"`
      : '';
    return `<tr${attrs}>
      <td>
        <div class="t-name" style="max-width:none">
          <span class="badge ${CLASSE_SEG[nome] ?? 'lead'}"><span class="b-dot"></span>${escapeHtml(ROTULO_SEG[nome] ?? nome)}</span>
        </div>
        <div class="t-sub" style="line-height:1.45;white-space:normal;max-width:52ch">${escapeHtml(NOTA_SEG[nome] ?? 'Balde não descrito nesta tela — aparece cru de propósito.')}</div>
        ${notaJoin ? `<div class="t-sub" style="line-height:1.45;white-space:normal;max-width:52ch">${escapeHtml(notaJoin)}</div>` : ''}
        ${abre ? '' : motivoSemLista(s.segmento_presente_em, leads)}
      </td>
      <td style="font-variant-numeric:tabular-nums">${br(s.qtd_oportunidades)}<div class="t-sub">${pct(s.pct_do_total) ?? '—'}</div></td>
      <td style="font-variant-numeric:tabular-nums;padding-right:14px">
        ${br(leads)}
        <div class="t-sub">${leads > 0 ? `${br(s.qtd_leads_com_oportunidade)} viraram oportunidade` : 'nenhum lead neste segmento'}</div>
        ${int(s.qtd_leads_fora_por_data_ausente) > 0 ? `<div class="t-sub" style="color:var(--amber)">${br(s.qtd_leads_fora_por_data_ausente)} fora do recorte por data ausente</div>` : ''}
      </td>
      <td style="font-variant-numeric:tabular-nums;color:var(--green)">${br(s.qtd_ganhas)}</td>
      <td style="font-variant-numeric:tabular-nums;color:var(--red)">${br(s.qtd_perdidas)}</td>
      <td style="font-variant-numeric:tabular-nums;color:var(--muted)">${br(s.qtd_nao_decididas)}</td>
      <td style="font-variant-numeric:tabular-nums">
        ${dec > 0 ? `<strong>${wr ?? '—'}</strong><div class="t-sub">${br(s.qtd_ganhas)} de ${br(dec)} decididas</div>`
                  : '<span style="color:var(--dim)">—</span><div class="t-sub">nenhuma decidida</div>'}
      </td>
      <td style="font-variant-numeric:tabular-nums">${escapeHtml(fmtBrl(s.receita_ganha_brl) ?? '—')}
        <div class="t-sub">${pct(s.pct_da_receita) ?? '—'} da receita${int(s.qtd_ganhas_fora_do_valor) > 0 ? ` · ${br(s.qtd_ganhas_fora_do_valor)} fora da soma` : ''}</div>
      </td>
      <td style="font-variant-numeric:tabular-nums;color:var(--muted)">${escapeHtml(fmtBrl(s.pipeline_aberto_brl) ?? '—')}</td>
    </tr>`;
  }).join('');

  const avisoFiltro = opcoes.ignorando && opcoes.ignorando.length
    ? `<div class="tl-idade" style="margin-bottom:10px;line-height:1.5">⚠️ Esta seção IGNORA ${escapeHtml(opcoes.ignorando.join(' e '))} —
        <code>fn_oportunidades_por_segmento</code> não aceita esses filtros, porque filtrar por segmento reduziria a tabela a uma linha só.
        Os cards acima estão filtrados; esta tabela não.</div>`
    : '';

  const conferencia = somaQtd === totalRecorte
    ? `<span style="color:var(--green)">os baldes somam ${br(somaQtd)} = o total do recorte</span>`
    : `<span style="color:var(--red)">⚠️ os baldes somam ${br(somaQtd)} mas o recorte tem ${br(totalRecorte)}</span>`;

  // O LADO DO LEAD, que a migration 103 acrescentou e esta tabela não lia. É
  // onde o dono do produto procura "quantos leads viram oportunidade" primeiro,
  // e a coluna fica ADJACENTE à de oportunidades porque na ponta da tabela ela
  // cai fora da área visível — medido na entrega anterior.
  const totalLeads = int(linhas[0]?.total_leads_do_recorte);
  const somaLeads = linhas.reduce((acc, x) => acc + int(x.qtd_leads_gerados), 0);
  const confLead = somaLeads === totalLeads
    ? `<span style="color:var(--green)">e ${br(somaLeads)} = o total de leads do recorte</span>`
    : `<span style="color:var(--red)">⚠️ e somam ${br(somaLeads)} leads contra ${br(totalLeads)} do recorte</span>`;
  const ignoradosNoLead = linhas.find((x) => x.leads_filtros_ignorados)?.leads_filtros_ignorados ?? null;
  const avisoLead = ignoradosNoLead
    ? `<div class="tl-idade" style="margin-bottom:10px;line-height:1.5">⚠️ A coluna de LEADS não honra ${escapeHtml(String(ignoradosNoLead))}:
        esses campos existem na oportunidade e não em <code>lead</code>. As contagens de oportunidade desta tabela estão filtradas por eles; as de lead, não —
        quem declara isso é a própria camada, no campo <code>leads_filtros_ignorados</code>.</div>`
    : '';
  const vinculo = conferirVinculo(linhas, (x) => ROTULO_SEG[x.segmento_aba] ?? x.segmento_aba);
  const exemplo = exemploQueProibeATaxa(linhas.map((x) => ({ ...x, categoria_rotulo: ROTULO_SEG[x.segmento_aba] ?? x.segmento_aba })));

  // Os extremos saem DO DADO. A versão anterior deste rodapé trazia dois
  // números de exemplo escritos à mão ("80 decididas e 1.374") que, na primeira
  // carga real, não correspondiam a nenhuma linha da tabela logo acima —
  // ilustração congelada é a forma barata de a tela mentir.
  const dens = linhas.map((x) => int(x.qtd_decididas)).filter((x) => x > 0);
  const denominadores = dens.length >= 2
    ? `, e neste recorte eles vão de ${br(Math.min(...dens))} a ${br(Math.max(...dens))} decididas`
    : '';

  return `${avisoFiltro}${avisoLead}${vinculo}
    <div style="overflow-x:auto">
      <table class="tbl">
        <thead><tr>
          <th>Segmento</th><th>Oportunidades</th><th style="padding-right:14px">Leads gerados</th><th>Ganhas</th><th>Perdidas</th>
          <th>Não decididas</th><th>Win rate (decididas)</th><th>Receita ganha</th><th>Pipeline aberto</th>
        </tr></thead>
        <tbody>${corpo}</tbody>
      </table>
    </div>
    <div class="mono-sm" style="color:var(--dim);margin-top:10px;line-height:1.6">
      Cada segmento traz o SEU denominador${denominadores}.
      Win rates apoiados em bases de tamanhos tão diferentes não são o mesmo tipo de afirmação,
      e a tela não deixa comparar às cegas.
      <br><strong style="color:var(--amber)">As duas contagens ficam lado a lado e nenhuma divide a outra.</strong>
      A oportunidade é atribuída pela origem DELA (<code>Opportunity.LeadSource</code>), não herdada do lead${exemplo ? `, e neste recorte ${escapeHtml(exemplo)}` : ''}.
      <br>${conferencia}, ${confLead}.
    </div>`;
}

// ---------------------------------------------------------------------------
// Categoria de origem (Evento/Webinar, Paid Social, Inbound Web, ...)
// ---------------------------------------------------------------------------
// A CATEGORIA JÁ EXISTIA NA CAMADA e não aparecia na tela: `view_oportunidade_
// analitica` projeta `categoria` desde a migration 100, e a lista sempre a
// mostrou linha a linha. O que faltava era o AGREGADO — e ele chegou com
// `fn_oportunidades_por_categoria` (migration 103), no array `categoria[]` da
// resposta.
//
// O GRÃO É O PAR (segmento_aba, categoria), não a categoria sozinha. Hoje
// nenhuma categoria aparece sob dois segmentos, mas a chave é o par para que
// uma regra futura não funda duas linhas em silêncio — e o drill-down manda os
// dois filtros, pelo mesmo motivo.
//
// ⚠️ AS DUAS CONTAGENS DE LEAD FICAM AO LADO E NENHUMA DIVIDE A OUTRA. Medido
// em 2026-09-16: `Inbound Web` tem 75 leads e 133 oportunidades, `Sem origem`
// tem 166 leads e 489 oportunidades. Uma "taxa lead → oportunidade" ali marcaria
// 177% e 295%. Não é erro de dado: a oportunidade é atribuída pela origem DELA
// (Opportunity.LeadSource), não herdada de um lead — são duas populações
// atribuídas por caminhos diferentes, e dividir uma pela outra é o mesmo erro
// de "Qualificados ÷ Em cadência" da aba antiga, com outra roupa. A frase na
// tela sai DO DADO do recorte, nunca escrita à mão: ilustração congelada já
// mentiu duas vezes neste arquivo.
//
// ⚠️ ZERO ESTRUTURAL ≠ ZERO MEDIDO, e `categoria_presente_em` é quem separa os
// dois. `Conteúdo/Ebook` tem 460 leads e ZERO oportunidades porque a categoria
// só existe do lado do lead (`so_lead`) — some da tabela se alguém filtrar por
// "tem oportunidade", e é exatamente o dado interessante. Já `Suporte` é
// `ambos` com zero leads: aí o zero foi MEDIDO. A tela diz qual é qual.
//
// NÃO HÁ FILTRO DE CATEGORIA NA BARRA, de propósito: medido contra a API,
// `categoria` estreita a LISTA e a própria tabela de categoria, mas NÃO os
// cards (com `categoria=Evento/Webinar` a lista vai a 33 e os cards continuam
// em 5.415). Publicar o seletor faria os doze cards do topo contradizerem a
// tabela. O caminho para "quais são essas 33" é o drill-down da linha, que
// abre uma lista e confere o total contra o número da linha.

// De qual lado do FULL OUTER JOIN a linha veio. Vale para os dois agregados
// (`segmento_presente_em` e `categoria_presente_em`), com o mesmo significado.
//
// ⚠️ É MEDIDO NO RECORTE, NÃO É PROPRIEDADE ESTRUTURAL — e a versão anterior
// deste bloco afirmava o contrário ("o zero é estrutural, não medido"). Medido
// contra a API em 2026-09-16: `Comercial/Suporte` é `ambos` nos 12 meses e vira
// `so_lead` assim que o filtro `desfecho=fora_de_fase` zera as oportunidades
// dele. Chamar isso de estrutural era a tela prometendo uma garantia que o dado
// não dá.
//
// Nas 105 linhas observadas em cinco recortes diferentes, `so_lead` sempre veio
// com zero oportunidade e `ambos` sempre com pelo menos uma — mas quem decide o
// texto aqui é a CONTAGEM, não o rótulo, para que um dia em que isso deixe de
// valer a tela não passe a mentir por dedução.
const PRESENTE_EM = {
  ambos: null,
  so_oportunidade: 'Neste recorte o lado do LEAD não trouxe nenhuma linha para este balde: a linha existe porque o lado da oportunidade trouxe. Outro recorte pode devolvê-la nos dois lados.',
  so_lead: 'Neste recorte o lado da OPORTUNIDADE não trouxe nenhuma linha para este balde: a linha existe porque o lado do lead trouxe. Outro recorte pode devolvê-la nos dois lados.',
};

/**
 * Por que uma linha de zero oportunidades não abre lista. Compartilhado por
 * segmento e categoria: a regra é a mesma nas duas tabelas, e tê-la escrita em
 * dois lugares foi como a de segmento ficou sem ela por uma entrega inteira.
 */
function motivoSemLista(presenteEm, leads) {
  const base = 'sem lista: nenhuma oportunidade neste recorte';
  const cor = presenteEm === 'so_lead' ? 'var(--amber)' : 'var(--dim)';
  const extra = int(leads) > 0
    ? ` — a linha continua na tabela porque o lado do lead trouxe ${br(leads)}`
    : '';
  return `<div class="t-sub" style="color:${cor};white-space:normal">${base}${extra}</div>`;
}

/**
 * A conferência de `soma_vinculo_fecha`, que a camada emite em toda linha das
 * duas funções e que a tela NÃO lia. A migration 103 escreveu essa partição com
 * quatro FILTER explícitos porque "uma checagem que só consegue passar não é
 * checagem" — e uma checagem que ninguém lê é ainda menos. Hoje é `true` em
 * todas as linhas medidas; é justamente por isso que ela precisa de saída: um
 * `lead_vinculo_regra` novo entraria sem alarme, que é o cenário que ela existe
 * para pegar.
 */
export function conferirVinculo(linhas, rotuloDaLinha) {
  const quebradas = (Array.isArray(linhas) ? linhas : []).filter((x) => x.soma_vinculo_fecha !== true);
  if (quebradas.length === 0) return '';
  const nomes = quebradas.map((x) => {
    const partes = int(x.qtd_opps_rastreadas_ate_lead) + int(x.qtd_opps_so_por_leadsource)
      + int(x.qtd_opps_lead_sem_classificacao) + int(x.qtd_opps_sem_origem);
    return `${rotuloDaLinha(x)} (as quatro regras de vínculo somam ${br(partes)} contra ${br(x.qtd_oportunidades)} oportunidades)`;
  });
  return `<div class="card" style="border-color:var(--red);margin-bottom:10px;padding:10px 14px">
    <div style="font-size:12.5px;line-height:1.6;color:var(--text)">
      <strong style="color:var(--red)">⚠️ A partição por regra de vínculo não fecha em ${br(quebradas.length)} linha(s):</strong>
      ${escapeHtml(nomes.join('; '))}.
      <div class="mono-sm" style="color:var(--dim);margin-top:6px;line-height:1.55">
        As quatro regras (<code>rastreada até o lead</code>, <code>só por LeadSource</code>, <code>lead sem classificação</code>, <code>sem origem</code>)
        são partição TOTAL dos valores de <code>lead_vinculo_regra</code> e deveriam somar as oportunidades da linha.
        Não somarem significa que a origem ganhou um valor de vínculo que a camada ainda não conhece — os números da linha continuam certos,
        mas a atribuição dela deixou de ser explicável. O alarme é da camada (<code>soma_vinculo_fecha</code>), não desta tela.
      </div>
    </div>
  </div>`;
}

/**
 * A frase que proíbe a divisão, com o pior caso DO RECORTE ATUAL.
 * Sai do dado porque números de exemplo escritos à mão já apareceram duas vezes
 * neste arquivo citando um recorte que não estava na tela.
 */
export function exemploQueProibeATaxa(linhas) {
  const candidatas = linhas
    .filter((r) => int(r.qtd_leads_gerados) > 0 && int(r.qtd_oportunidades) > int(r.qtd_leads_gerados))
    .map((r) => ({ r, razao: int(r.qtd_oportunidades) / int(r.qtd_leads_gerados) }))
    .sort((a, b) => b.razao - a.razao);
  if (candidatas.length === 0) return null;
  const { r, razao } = candidatas[0];
  // SEM "neste recorte" aqui: quem põe a moldura é a frase que a consome, e
  // tê-la nos dois lugares produzia "e neste recorte X tem 75 leads e 322
  // oportunidades neste recorte" — visto na primeira carga contra a API real.
  return `${r.categoria_rotulo ?? r.categoria} tem ${br(r.qtd_leads_gerados)} leads e ${br(r.qtd_oportunidades)} oportunidades — uma taxa ali marcaria ${(razao * 100).toLocaleString('pt-BR', { maximumFractionDigits: 0 })}%`;
}

export function renderCategoria(categoria, opcoes = {}) {
  const linhas = Array.isArray(categoria) ? categoria : [];
  if (linhas.length === 0) {
    return '<div class="empty-state"><div class="es-title">Sem categorias no recorte</div><div>Nenhuma linha a exibir.</div></div>';
  }
  const totalRecorte = int(linhas[0]?.total_do_recorte);
  const totalLeads = int(linhas[0]?.total_leads_do_recorte);
  const somaOpp = linhas.reduce((s, x) => s + int(x.qtd_oportunidades), 0);
  const somaLeads = linhas.reduce((s, x) => s + int(x.qtd_leads_gerados), 0);

  const corpo = linhas.map((c) => {
    const qtd = int(c.qtd_oportunidades);
    const dec = int(c.qtd_decididas);
    const leads = int(c.qtd_leads_gerados);
    const rotulo = c.categoria_rotulo ?? c.categoria ?? '(sem categoria)';
    const nota = PRESENTE_EM[c.categoria_presente_em] ?? null;
    // A LINHA SÓ ABRE SE HOUVER O QUE LISTAR. Zero oportunidades é um clique
    // que só pode dar lista vazia — dizer o motivo informa mais do que abrir um
    // painel em branco. E os dois zeros não são a mesma coisa (ver acima).
    const separavel = typeof c.categoria === 'string' && c.categoria.includes(',');
    const abre = qtd > 0 && !separavel;
    const alvo = `categoria:${c.segmento_aba}:${c.categoria ?? ''}`;
    const attrs = abre
      ? ` role="button" tabindex="0" data-drill="${escapeHtml(alvo)}" data-esperado="${qtd}" style="cursor:pointer"`
        + ` aria-label="${escapeHtml(`${rotulo}: abrir as ${br(qtd)} oportunidades desta categoria`)}"`
      : '';
    const motivoSemClique = abre ? ''
      : (separavel
        ? '<div class="t-sub" style="color:var(--amber);white-space:normal">sem lista: o nome desta categoria tem vírgula, e o filtro viaja em lista separada por vírgula — o painel traria a união de dois recortes, não este</div>'
        : motivoSemLista(c.categoria_presente_em, leads));
    return `<tr${attrs}>
      <td>
        <div class="t-name" style="max-width:none">
          <span class="badge ${CLASSE_SEG[c.segmento_aba] ?? 'lead'}"><span class="b-dot"></span>${escapeHtml(ROTULO_SEG[c.segmento_aba] ?? c.segmento_aba)}</span>
          <span style="margin-left:6px">${escapeHtml(rotulo)}</span>
        </div>
        ${nota ? `<div class="t-sub" style="line-height:1.45;white-space:normal;max-width:52ch">${escapeHtml(nota)}</div>` : ''}
        ${motivoSemClique}
      </td>
      <td style="font-variant-numeric:tabular-nums">${br(qtd)}<div class="t-sub">${pct(c.pct_do_total) ?? '—'}</div></td>
      <td style="font-variant-numeric:tabular-nums;padding-right:14px">
        ${br(leads)}
        <div class="t-sub">${leads > 0 ? `${br(c.qtd_leads_com_oportunidade)} viraram oportunidade` : 'nenhum lead nesta categoria'}</div>
        ${int(c.qtd_leads_fora_por_data_ausente) > 0 ? `<div class="t-sub" style="color:var(--amber)">${br(c.qtd_leads_fora_por_data_ausente)} fora do recorte por data ausente</div>` : ''}
      </td>
      <td style="font-variant-numeric:tabular-nums;color:var(--green)">${br(c.qtd_ganhas)}</td>
      <td style="font-variant-numeric:tabular-nums;color:var(--red)">${br(c.qtd_perdidas)}</td>
      <td style="font-variant-numeric:tabular-nums;color:var(--muted)">${br(c.qtd_nao_decididas)}</td>
      <td style="font-variant-numeric:tabular-nums">
        ${dec > 0 ? `<strong>${pct(c.win_rate_decididas_pct) ?? '—'}</strong><div class="t-sub">${br(c.qtd_ganhas)} de ${br(dec)} decididas</div>`
                  : '<span style="color:var(--dim)">—</span><div class="t-sub">nenhuma decidida</div>'}
      </td>
      <td style="font-variant-numeric:tabular-nums">${escapeHtml(fmtBrl(c.receita_ganha_brl) ?? '—')}
        <div class="t-sub">${pct(c.pct_da_receita) ?? '—'} da receita${int(c.qtd_ganhas_fora_do_valor) > 0 ? ` · ${br(c.qtd_ganhas_fora_do_valor)} fora da soma` : ''}</div>
      </td>
      <td style="font-variant-numeric:tabular-nums;color:var(--muted)">${escapeHtml(fmtBrl(c.pipeline_aberto_brl) ?? '—')}</td>
    </tr>`;
  }).join('');

  // DOIS AVISOS DIFERENTES, e colapsá-los num só apagaria a distinção:
  //  · `ignorando` — filtros que a SEÇÃO INTEIRA não aplica (medido por nós);
  //  · `leads_filtros_ignorados` — filtros que a camada aplicou à oportunidade
  //    e NÃO conseguiu aplicar ao lead, porque o campo não existe em `lead`.
  //    Este vem declarado pela própria API, como string.
  const avisoSecao = opcoes.ignorando && opcoes.ignorando.length
    ? `<div class="tl-idade" style="margin-bottom:10px;line-height:1.5">⚠️ Esta seção IGNORA ${escapeHtml(opcoes.ignorando.join(' e '))} —
        <code>fn_oportunidades_por_categoria</code> não aceita esse filtro. Os cards acima estão filtrados; esta tabela não.</div>`
    : '';
  const ignoradosNoLead = linhas.find((x) => x.leads_filtros_ignorados)?.leads_filtros_ignorados ?? null;
  const avisoLead = ignoradosNoLead
    ? `<div class="tl-idade" style="margin-bottom:10px;line-height:1.5">⚠️ A coluna de LEADS não honra ${escapeHtml(String(ignoradosNoLead))}:
        esses campos existem na oportunidade e não em <code>lead</code>. As contagens de oportunidade desta tabela estão filtradas por eles; as de lead, não —
        quem declara isso é a própria camada, no campo <code>leads_filtros_ignorados</code>.</div>`
    : '';

  const confOpp = somaOpp === totalRecorte
    ? `<span style="color:var(--green)">as categorias somam ${br(somaOpp)} = o total de oportunidades do recorte</span>`
    : `<span style="color:var(--red)">⚠️ as categorias somam ${br(somaOpp)} mas o recorte tem ${br(totalRecorte)} oportunidades</span>`;
  const confLead = somaLeads === totalLeads
    ? `<span style="color:var(--green)">e ${br(somaLeads)} = o total de leads do recorte</span>`
    : `<span style="color:var(--red)">⚠️ e somam ${br(somaLeads)} leads contra ${br(totalLeads)} do recorte</span>`;

  const exemplo = exemploQueProibeATaxa(linhas);
  const soLead = linhas.filter((x) => x.categoria_presente_em === 'so_lead');
  const vinculo = conferirVinculo(linhas, (x) => x.categoria_rotulo ?? x.categoria ?? '(sem categoria)');

  return `${avisoSecao}${avisoLead}${vinculo}
    <div style="overflow-x:auto">
      <table class="tbl">
        <thead><tr>
          <th>Segmento / categoria</th><th>Oportunidades</th><th style="padding-right:14px">Leads gerados</th><th>Ganhas</th><th>Perdidas</th>
          <th>Não decididas</th><th>Win rate (decididas)</th><th>Receita ganha</th><th>Pipeline aberto</th>
        </tr></thead>
        <tbody>${corpo}</tbody>
      </table>
    </div>
    <div class="mono-sm" style="color:var(--dim);margin-top:10px;line-height:1.6">
      <strong style="color:var(--amber)">As duas contagens ficam lado a lado e nenhuma divide a outra.</strong>
      A oportunidade é atribuída pela origem DELA (<code>Opportunity.LeadSource</code>), não herdada do lead — são duas populações
      atribuídas por caminhos diferentes${exemplo ? `, e neste recorte ${escapeHtml(exemplo)}` : ''}.
      Dividir uma pela outra é “Qualificados ÷ Em cadência” com outra roupa.
      ${soLead.length ? `<br>${br(soLead.length)} categoria(s) aparecem só do lado do lead (${soLead.map((x) => escapeHtml(x.categoria_rotulo ?? x.categoria)).join(', ')}):
        neste recorte nenhuma oportunidade caiu nelas, e elas continuam na tabela de propósito — sumir com elas esconderia justamente o dado interessante.` : ''}
      <br>${confOpp}, ${confLead}.
    </div>`;
}

// ---------------------------------------------------------------------------
// REGRA 2 (detalhe) e REGRA 7
// ---------------------------------------------------------------------------
export function renderForaDoValor(cards) {
  const fora = int(cards.qtd_ganhas_fora_do_valor);
  const motivos = cards.ganhas_fora_do_valor_motivos && typeof cards.ganhas_fora_do_valor_motivos === 'object'
    ? Object.entries(cards.ganhas_fora_do_valor_motivos) : [];
  if (fora === 0) {
    return `<div class="empty-state"><div class="es-title">Nenhuma ganha fora da soma</div>
      <div>As ${br(cards.qtd_ganhas)} oportunidades ganhas do recorte entraram inteiras na receita.</div></div>`;
  }
  const somaMotivos = motivos.reduce((s, [, q]) => s + int(q), 0);
  // O MOTIVO NÃO É FILTRO na camada (`conversao_indisponivel_motivo` não entra
  // em fn_search_oportunidades), então a lista abre pelo CONJUNTO INTEIRO e não
  // linha a linha. Abrir "só as sem taxa" exigiria filtrar no cliente sobre uma
  // página de 50, o que é fingir que a página é o conjunto.
  const abrirTodas = `<div style="margin-top:12px">
      <button type="button" class="filter-clear" data-drill="ganhas_sem_valor" data-esperado="${fora}"
        style="cursor:pointer;display:inline-flex;align-items:center;gap:6px"
        aria-label="Abrir as ${escapeHtml(br(fora))} ganhas que ficaram fora da receita">
        <i class="ti ti-list-search"></i>Ver as ${br(fora)} ganhas fora da soma
      </button>
      <span class="mono-sm" style="color:var(--dim);margin-left:8px">o motivo não é filtro na camada — a lista abre o conjunto inteiro, não um motivo</span>
    </div>`;
  return `<div style="overflow-x:auto">
      <table class="tbl">
        <thead><tr><th>Motivo declarado pela camada de dados</th><th>Ganhas</th></tr></thead>
        <tbody>${motivos.map(([m, q]) => `<tr>
          <td><div style="white-space:normal;line-height:1.45;max-width:46ch">${escapeHtml(m)}</div></td>
          <td style="font-variant-numeric:tabular-nums;font-weight:600">${br(q)}</td></tr>`).join('')}</tbody>
      </table>
    </div>
    <div class="mono-sm" style="color:var(--dim);margin-top:10px;line-height:1.6">
      ${br(fora)} de ${br(cards.qtd_ganhas)} ganhas ficaram fora da receita exibida. Elas <strong>não somem</strong>:
      continuam contadas como ganhas, no win rate e no funil — o que falta é o valor delas, e o motivo está acima.
      A soma dos motivos é ${br(somaMotivos)}${somaMotivos === fora ? '' : ` <span style="color:var(--red)">⚠️ e deveria ser ${br(fora)}</span>`}.
      <br>Converter mesmo assim (<code>amount × 1</code>) seria inventar receita; deixá-las de fora sem contar seria esconder a falta.
    </div>${abrirTodas}`;
}

export function renderRessalvaCiclo(cards) {
  const ressalva = cards.ciclo_ressalva;
  return `<div style="font-size:12.5px;line-height:1.6">
      Esta aba <strong>não tem card de ciclo de venda</strong>, e isso é uma decisão, não uma lacuna.
    </div>
    ${ressalva ? `<div class="tl-idade" style="margin-top:10px;line-height:1.55;white-space:normal">⚠️ ${escapeHtml(ressalva)}</div>` : ''}
    <div class="mono-sm" style="color:var(--dim);margin-top:10px;line-height:1.6">
      <code>Opportunity.CloseDate</code> nesta org é um campo de data editável que carrega predominantemente
      o <strong>fim do contrato</strong>: ${br(cards.ciclo_qtd_close_antes_da_criacao)} ganhas do recorte têm CloseDate
      ANTERIOR à data de criação, e ${br(cards.ciclo_qtd_close_no_fim_do_contrato)} caem a menos de 31 dias do fim do
      Termo do Contrato. A API devolve <code>dias_ate_close_date_mediana</code>
      (${escapeHtml(String(cards.dias_ate_close_date_mediana ?? '—'))} dias sobre ${br(cards.dias_ate_close_date_n)} casos)
      e a tela deliberadamente não a promove a indicador: chamar isso de ciclo de venda seria fabricar um número.
    </div>`;
}

// ---------------------------------------------------------------------------
// Lista
// ---------------------------------------------------------------------------
const BADGE_DESFECHO = {
  ganha: ['lq', 'Ganha'], perdida: ['na', 'Perdida'], aberta: ['lead', 'Aberta'],
  fora_de_fase: ['na', 'Fora de fase'], estagio_nao_declarado: ['na', 'Não declarado'],
  declaracao_incompleta: ['na', 'Declaração incompleta'],
};
const ROTULO_VINCULO = {
  oportunidade: 'lead por oportunidade', conta: 'lead por conta', leadsource: 'LeadSource traduzido',
  leadsource_desconhecido: 'LeadSource sem tradução', lead_sem_classificacao: 'lead sem classificação',
  sem_origem: 'sem lead e sem LeadSource',
};

/**
 * A lista NÃO exibe nome de lead. `lead_nome` chega na resposta e fica onde
 * está: este repositório é PÚBLICO e já teve incidente de vazamento de PII, e
 * a unidade desta aba é o NEGÓCIO (conta, valor, fase), não a pessoa. Quem
 * precisa da pessoa abre a aba Leads, que é onde esse dado tem razão de
 * aparecer.
 */
export function renderLista(lista) {
  const linhas = lista?.oportunidades ?? [];
  if (linhas.length === 0) {
    // DOIS vazios diferentes, e colapsá-los num texto só foi um defeito real:
    // a tela dizia "não há divergência escondida aqui" com o badge ao lado
    // marcando 420. Página vazia sobre total > 0 NÃO é recorte vazio — é a
    // lista pedindo uma fatia que não existe, e a tela tem de dizer isso.
    const total = int(lista?.total);
    if (total > 0) {
      return `<tr><td colspan="7"><div class="empty-state">
        <div class="es-title">A página pedida veio vazia, mas o recorte tem ${br(total)} oportunidades</div>
        <div>Isto é divergência entre a lista e o total, não um recorte vazio. Recarregue a aba para voltar à primeira página.</div>
      </div></td></tr>`;
    }
    return `<tr><td colspan="7"><div class="empty-state">
      <div class="es-title">Nenhuma oportunidade neste recorte</div>
      <div>Os filtros ativos não deixaram nenhuma linha, e o total ao lado também é zero — lista e contagem saem do mesmo predicado.</div>
    </div></td></tr>`;
  }
  return linhas.map((o) => {
    const [classe, rotuloDesfecho] = BADGE_DESFECHO[o.desfecho] ?? ['na', o.desfecho ?? '—'];
    // REGRA 8: valor convertido + valor cru na moeda de origem, nunca R$ em
    // cima de USD/MXN. Mesmo módulo da ficha do lead.
    const valor = fmtValor(o.amount_brl, o.amount, o.moeda, o.conversao_indisponivel_motivo);
    const fase = o.fase ? (ROTULO_FASE[o.fase] ?? o.fase) : '(fora de qualquer fase)';
    const origem = [o.categoria, o.detalhe].filter(Boolean).join(' · ');
    return `<tr>
      <td style="padding-right:12px">
        <div class="t-name" style="max-width:none" title="${escapeHtml(o.conta_nome ?? '')}">${escapeHtml(o.conta_nome ?? '(conta sem nome na origem)')}</div>
        <div class="t-sub" style="white-space:normal">${escapeHtml(o.record_type ?? 'sem record type')} · criada em ${escapeHtml(dataCurta(o.criada_em) ?? '—')}</div>
      </td>
      <td style="text-align:left;padding-right:12px">
        <div style="overflow-wrap:anywhere">${escapeHtml(o.estagio ?? '—')}</div>
        <div class="t-sub">fase: ${escapeHtml(fase)}</div>
      </td>
      <td style="text-align:left;padding-right:12px">
        <span class="badge ${classe}">${escapeHtml(rotuloDesfecho)}</span>
        <div class="t-sub" style="white-space:normal;line-height:1.4">${escapeHtml(o.desfecho_motivo ?? '')}</div>
        ${o.divergencia_origem_vs_fase ? `<div class="tl-idade" style="white-space:normal">⚠️ ${escapeHtml(o.divergencia_origem_vs_fase)}</div>` : ''}
      </td>
      <td style="text-align:left;padding-right:12px">
        <span class="badge ${CLASSE_SEG[o.segmento_aba] ?? 'lead'}"><span class="b-dot"></span>${escapeHtml(ROTULO_SEG[o.segmento_aba] ?? o.segmento_aba ?? '—')}</span>
        ${origem ? `<div class="t-sub" style="white-space:normal">${escapeHtml(origem)}</div>` : ''}
      </td>
      <td style="text-align:left;padding-right:12px">
        <div class="mono-sm" style="color:var(--muted);white-space:normal">${escapeHtml(ROTULO_VINCULO[o.lead_vinculo_regra] ?? o.lead_vinculo_regra ?? '—')}</div>
        ${o.lead_source ? `<div class="t-sub" style="white-space:normal;overflow-wrap:anywhere">LeadSource: ${escapeHtml(o.lead_source)}</div>` : ''}
      </td>
      <td style="font-variant-numeric:tabular-nums;padding-right:12px">
        ${valor ? `<div style="white-space:normal;max-width:none;line-height:1.45">${escapeHtml(valor)}</div>`
                : '<span style="color:var(--dim)">sem valor na origem</span>'}
        ${fmtMrr(o.mrr, o.moeda) ? `<div class="t-sub" style="white-space:normal;max-width:none">MRR ${escapeHtml(fmtMrr(o.mrr, o.moeda))}</div>` : ''}
      </td>
      <td class="mono-sm" style="color:var(--muted);font-variant-numeric:tabular-nums">${escapeHtml(o.moeda ?? '—')}</td>
    </tr>`;
  }).join('');
}

// ---------------------------------------------------------------------------
// estado da tela
// ---------------------------------------------------------------------------
const PAGINA = 50;

// REGRA 9: o recorte padrão é decisão DESTA tela, escrita aqui e visível na
// barra de cima. A API não tem padrão — sem de/ate ela devolve o universo.
export function ultimosMeses(meses, hoje = new Date()) {
  const ate = new Date(Date.UTC(hoje.getUTCFullYear(), hoje.getUTCMonth(), hoje.getUTCDate()));
  // `setUTCMonth(mes - N)` SOZINHO estoura quando o dia não existe no mês de
  // destino: rodando em 31/03, o preset de 1 mês pedia 31/02 e o Date
  // "corrigia" para 03/03 — um recorte de 28 dias rotulado como 30d, e o
  // usuário não tem como perceber. O dia é preso ao último do mês alvo antes
  // de ser aplicado.
  const ano = ate.getUTCFullYear();
  const mesAlvo = ate.getUTCMonth() - meses;
  // Date.UTC(ano, mes + 1, 0) devolve o último dia do mês `mes` (dia 0 do
  // seguinte), e aceita mês negativo, rolando o ano sozinho.
  const ultimoDiaDoAlvo = new Date(Date.UTC(ano, mesAlvo + 1, 0)).getUTCDate();
  const de = new Date(Date.UTC(ano, mesAlvo, Math.min(ate.getUTCDate(), ultimoDiaDoAlvo)));
  const iso = (d) => d.toISOString().slice(0, 10);
  // `ate` é EXCLUSIVO na API. Mandar a data de hoje em `ate` excluiria as
  // oportunidades criadas HOJE — e "últimos 12 meses" que esconde o dia
  // corrente é um recorte que mente pela borda. Por isso `ate` = amanhã.
  const ateExclusivo = new Date(ate.getTime() + 86400000);
  return { de: iso(de), ate: iso(ateExclusivo) };
}

const PRESETS = [
  { id: '30d', rotulo: '30d', meses: 1 },
  { id: '90d', rotulo: '90d', meses: 3 },
  { id: '12m', rotulo: '12 meses', meses: 12 },
  { id: '24m', rotulo: '24 meses', meses: 24 },
  { id: 'tudo', rotulo: 'Tudo', meses: null },
];

// ESTADO NA URL (FR-6: endereçável e retomável). O objeto abaixo é cache de
// leitura; a FONTE DA VERDADE é a query string, e é dela que `hidratarDaUrl()`
// preenche este objeto a cada entrada na aba. Sem isto a aba era a única view
// nova em que F5 perdia o recorte e um link não podia ser compartilhado.
//
// AS CHAVES SÃO PREFIXADAS com `o`. Não é estilo: `segmento` JÁ É usado pela
// aba Leads na mesma query string, e com outro vocabulário — lá é `marketing`
// minúsculo, aqui é `Marketing` como a API exige. Sem prefixo, sair de
// leads-crm filtrado e entrar aqui herdaria `segmento=marketing`, que a API
// não conhece, e a aba abriria vazia sem explicação.
//
// `offset` NÃO entra na URL de propósito: abrir um link com offset=100
// mostraria a lista começando na linha 101 sem as 100 anteriores. Paginação é
// posição de leitura, não recorte.
const CHAVES_URL = {
  opreset: 'preset', ode: 'de', oate: 'ate',
  oseg: 'segmento', ofase: 'fase', odesf: 'desfecho', omoeda: 'moeda',
  ovinc: 'lead_vinculo_regra', oord: 'ordenar_por', obusca: 'busca',
};
const CHAVES_URL_BOOL = { odiv: 'so_divergentes', osv: 'so_sem_valor' };

const PADROES = {
  preset: '12m', de: null, ate: null, segmento: '', fase: '', desfecho: '',
  moeda: '', lead_vinculo_regra: '', ordenar_por: 'recentes', busca: '',
  so_divergentes: false, so_sem_valor: false,
};

const estado = { ...PADROES, offset: 0 };

// ---------------------------------------------------------------------------
// DRILL-DOWN — abrir o conjunto que está por trás de um número
// ---------------------------------------------------------------------------
// MESMO MODELO DE INTERAÇÃO da aba antiga (`abrirDetalheCard`,
// views-legacy.js:1966): clica no número, abre um painel modal com as linhas
// que o compõem, fecha no X, no overlay ou no Esc. O que muda aqui é a
// PROMESSA que o painel faz:
//
//  · O TOTAL DO PAINEL É O NÚMERO CLICADO. Não "parecido", não "a primeira
//    página": o painel recebe o número que estava no card, pergunta o total à
//    API sob o recorte que ele mesmo montou, e ESCREVE a conferência na tela.
//    Divergiu, ele denuncia — é literalmente o defeito que esta aba existe
//    para não ter.
//
//  · UM NÚMERO QUE NÃO DEFINE CONJUNTO NÃO VIRA BOTÃO. Win rate é razão;
//    receita, ticket médio e pipeline são somas. Abrir uma lista embaixo de um
//    deles obrigaria o painel a exibir um total que não é o número do card —
//    e "lista que não corresponde ao número" é a forma mais barata de a tela
//    mentir. Eles ficam sem clique, com o motivo escrito no próprio card.
//
//  · O PAINEL REPRODUZ O PREDICADO DA SEÇÃO, não o da barra de filtros. As
//    seções desta aba aplicam conjuntos DIFERENTES de filtros (medido contra a
//    API em 2026-09-16 e reconferido nesta entrega: o funil devolve as mesmas
//    sete linhas com `desfecho=ganha`; a tabela de segmento devolve as mesmas
//    cinco com `lead_vinculo_regra=conta`). Herdar o que a seção ignora faria
//    o total do painel discordar da linha que o abriu.
//
// `busca`, `so_divergentes` e `so_sem_valor` NÃO entram em herança nenhuma:
// eles estreitam só a LISTA (medido: com `busca=LOGMEIN` a lista vai a 40 e os
// cards continuam em 5.415). O painel declara, por escrito, o que deixou de
// fora e por quê.
const HERANCA_DO_PAINEL = {
  cards: ['de', 'ate', 'segmento', 'fase', 'desfecho', 'moeda', 'lead_vinculo_regra'],
  funil: ['de', 'ate', 'segmento', 'moeda', 'lead_vinculo_regra'],
  segmento: ['de', 'ate', 'fase', 'desfecho', 'moeda'],
  // `fn_oportunidades_por_categoria` APLICA segmento (ao contrário da tabela de
  // segmento, que o ignora) e IGNORA lead_vinculo_regra — medido contra a API
  // em 2026-09-16, linha a linha: com `lead_vinculo_regra=conta` as 16 linhas
  // voltam idênticas; com `segmento=Marketing` a tabela cai para 6.
  categoria: ['de', 'ate', 'segmento', 'fase', 'desfecho', 'moeda'],
};

const ROTULO_CAMPO = {
  segmento: 'segmento', fase: 'fase', desfecho: 'desfecho',
  moeda: 'moeda', lead_vinculo_regra: 'vínculo', categoria: 'categoria',
};

const ROTULO_DESFECHO = Object.fromEntries(DESFECHOS.map((d) => [d.valor, d.rotulo]));

function rotuloDeValor(campo, valor) {
  if (campo === 'segmento') return ROTULO_SEG[valor] ?? valor;
  if (campo === 'fase') return ROTULO_FASE[valor] ?? valor;
  if (campo === 'desfecho') return ROTULO_DESFECHO[valor] ?? valor;
  if (campo === 'lead_vinculo_regra') return ROTULO_VINCULO[valor] ?? valor;
  return valor;
}

// Os dois baldes que a camada considera SEM origem classificada. A lista é
// LITERALMENTE o predicado de `so_nao_classificado` em fn_search_oportunidades
// (`segmento_aba IN ('NaoClassificado','SemOrigem')`).
//
// CORREÇÃO de um comentário que ficou velho dentro da mesma sessão: a versão
// anterior deste bloco dizia, como medição datada, que o endpoint NÃO
// encaminhava `so_nao_classificado`. Isso era verdade quando foi escrito e
// deixou de ser quando a whitelist do n8n foi corrigida — hoje o parâmetro
// devolve 795 no recorte de 12 meses, e o teste de contrato afirma isso. Num
// arquivo onde comentário é prova, um comentário vencido é pior que nenhum.
//
// Mantemos `segmento` (e não o interruptor) por um motivo que continua válido:
// ele é o mesmo parâmetro que a linha de categoria nula precisa usar, e um
// caminho só é um caminho só para testar. Os dois predicados são idênticos.
const SEM_CLASSIFICACAO = ['NaoClassificado', 'SemOrigem'];

/**
 * Os painéis de recorte fixo. Cada um declara:
 *   `secao`    — de qual seção o número veio (define o que é herdado);
 *   `extra`    — os filtros que ESTE recorte acrescenta;
 *   `esperado` — de onde sai o número que o painel tem de bater, lido da MESMA
 *                resposta que pintou o card. É esta função que o teste contra
 *                a API real usa como fonte do esperado: mexer no recorte sem
 *                mexer no esperado (ou vice-versa) deixa o teste vermelho.
 */
export const PAINEIS = {
  total: {
    rotulo: 'Todas as oportunidades do recorte',
    secao: 'cards',
    extra: () => ({}),
    esperado: (r) => int(r?.cards?.total_oportunidades),
  },
  ganhas: {
    rotulo: 'Ganhas',
    secao: 'cards',
    extra: () => ({ desfecho: ['ganha'] }),
    esperado: (r) => int(r?.cards?.qtd_ganhas),
  },
  perdidas: {
    rotulo: 'Perdidas',
    secao: 'cards',
    extra: () => ({ desfecho: ['perdida'] }),
    esperado: (r) => int(r?.cards?.qtd_perdidas),
  },
  abertas: {
    rotulo: 'Abertas',
    secao: 'cards',
    extra: () => ({ desfecho: ['aberta'] }),
    esperado: (r) => int(r?.cards?.qtd_abertas),
  },
  fora_de_fase: {
    rotulo: 'Fora de qualquer fase',
    secao: 'cards',
    extra: () => ({ desfecho: ['fora_de_fase'] }),
    esperado: (r) => int(r?.cards?.qtd_fora_de_fase),
  },
  sem_declaracao: {
    rotulo: 'Sem declaração da origem',
    secao: 'cards',
    extra: () => ({ desfecho: ['estagio_nao_declarado', 'declaracao_incompleta'] }),
    esperado: (r) => int(r?.cards?.qtd_estagio_nao_declarado) + int(r?.cards?.qtd_declaracao_incompleta),
  },
  divergentes: {
    rotulo: 'Divergência origem × fase',
    secao: 'cards',
    extra: () => ({ so_divergentes: true }),
    esperado: (r) => int(r?.cards?.qtd_divergencia_origem_vs_fase),
  },
  sem_origem_classificada: {
    // O card mostra a COBERTURA (um percentual); o conjunto que dá para abrir é
    // o COMPLEMENTO dela, e o título diz isso com todas as letras em vez de
    // abrir uma lista que não corresponde ao número exibido.
    rotulo: 'Sem origem classificada (o complemento da cobertura)',
    secao: 'cards',
    extra: () => ({ segmento: [...SEM_CLASSIFICACAO] }),
    esperado: (r) => int(r?.cards?.qtd_nao_classificado) + int(r?.cards?.qtd_sem_origem),
  },
  ganhas_sem_valor: {
    rotulo: 'Ganhas que ficaram fora da receita',
    secao: 'cards',
    extra: () => ({ desfecho: ['ganha'], so_sem_valor: true }),
    esperado: (r) => int(r?.cards?.qtd_ganhas_fora_do_valor),
  },
};

/**
 * Resolve o tipo do painel, inclusive os dinâmicos (`fase:<v>`, `segmento:<v>`).
 * Devolve `null` para tipo desconhecido — a URL é entrada não confiável e
 * `?odet=xpto` não pode abrir painel nenhum nem derrubar a aba.
 */
export function definicaoDoPainel(tipo) {
  if (typeof tipo !== 'string' || tipo === '') return null;
  if (Object.prototype.hasOwnProperty.call(PAINEIS, tipo)) return { tipo, ...PAINEIS[tipo] };

  // `categoria:<segmento_aba>:<categoria>` — precisa de parser próprio porque o
  // GRÃO É O PAR e o nome da categoria não é um identificador: ele contém
  // barras (Evento/Webinar, Outbound SDR/Vendas) e pode conter dois-pontos. Quem
  // delimita é o PRIMEIRO dois-pontos depois do prefixo — `segmento_aba` é enum
  // fechado, sem separador nenhum. Sufixo VAZIO é a linha de categoria NULA.
  if (tipo.startsWith('categoria:')) {
    const resto = tipo.slice('categoria:'.length);
    const corteSeg = resto.indexOf(':');
    if (corteSeg < 1) return null;
    const seg = resto.slice(0, corteSeg);
    const cru = resto.slice(corteSeg + 1);
    const cat = cru === '' ? null : cru;
    // VÍRGULA NO NOME DA CATEGORIA TORNA O RECORTE INEXPRIMÍVEL, e a tela
    // recusa em vez de abrir a lista errada. `data-api.js` serializa lista de
    // filtro com vírgula (`v.join(',')`), e a borda separa de volta pela
    // vírgula: "Evento, Webinar" chegaria ao SQL como DOIS valores e o painel
    // traria a UNIÃO dos dois, embaixo de uma linha que conta um só.
    // Nenhuma das 15 categorias de hoje tem vírgula — mas elas vêm de
    // `leadsource_crosswalk`, que é texto livre, então a guarda é de quando e
    // não de se.
    if (cat !== null && cat.includes(',')) return null;
    const achaLinha = (r) => (r?.categoria ?? []).find(
      (x) => x.segmento_aba === seg && (x.categoria ?? null) === cat);
    if (cat === null) {
      // NÃO EXISTE FILTRO DE "CATEGORIA NULA". `fn_filtro_casa` trata
      // `categoria: null` como AUSÊNCIA de filtro, e mandar isso devolveria o
      // recorte inteiro embaixo de uma linha de 795. O recorte possível é o
      // SEGMENTO, e ele coincide com a linha porque só NaoClassificado e
      // SemOrigem têm categoria nula — conferido nos dois recortes, inclusive
      // na base inteira, onde as duas linhas existem (1.380 e 2) e
      // `so_nao_classificado` sozinho devolveria a soma, 1.382, que não é
      // nenhuma das duas. Se um dia um desses segmentos ganhar categoria, a
      // conferência painel × linha fica VERMELHA em vez de o painel mentir.
      return {
        tipo,
        arg: seg,
        rotulo: `Sem categoria — segmento ${ROTULO_SEG[seg] ?? seg}`,
        secao: 'categoria',
        ressalva: 'Não existe filtro de “categoria nula” na camada: este recorte é o segmento inteiro, e ele coincide com a linha porque só os segmentos sem classificação têm categoria nula. A conferência acima é o que prova a coincidência a cada abertura.',
        extra: () => ({ segmento: [seg] }),
        esperado: (r) => { const l = achaLinha(r); return l ? int(l.qtd_oportunidades) : null; },
      };
    }
    return {
      tipo,
      arg: cat,
      rotulo: `${ROTULO_SEG[seg] ?? seg} · ${cat}`,
      secao: 'categoria',
      // OS DOIS FILTROS, porque a linha é o PAR. Hoje nenhuma categoria aparece
      // sob dois segmentos e `categoria` sozinha bastaria; mandar o par é o que
      // mantém o painel correto no dia em que uma regra nova fundir isso.
      extra: () => ({ segmento: [seg], categoria: [cat] }),
      esperado: (r) => { const l = achaLinha(r); return l ? int(l.qtd_oportunidades) : null; },
    };
  }

  const corte = tipo.indexOf(':');
  if (corte < 1) return null;
  const prefixo = tipo.slice(0, corte);
  const arg = tipo.slice(corte + 1);
  if (!arg) return null;
  if (prefixo === 'fase') {
    return {
      tipo,
      arg,
      rotulo: `Fase: ${ROTULO_FASE[arg] ?? arg}`,
      secao: 'funil',
      extra: () => ({ fase: [arg] }),
      esperado: (r) => {
        const linha = (r?.funil ?? []).find((f) => f.fase === arg);
        return linha ? int(linha.qtd_da_coorte_agora) : null;
      },
    };
  }
  if (prefixo === 'segmento') {
    return {
      tipo,
      arg,
      rotulo: `Segmento: ${ROTULO_SEG[arg] ?? arg}`,
      secao: 'segmento',
      extra: () => ({ segmento: [arg] }),
      esperado: (r) => {
        const linha = (r?.segmento ?? []).find((s) => s.segmento_aba === arg);
        return linha ? int(linha.qtd_oportunidades) : null;
      },
    };
  }
  return null;
}

/** O que a aba está filtrando e o painel DELIBERADAMENTE não herdou. */
export function ignoradosDoPainel(def, est) {
  const herda = HERANCA_DO_PAINEL[def.secao] ?? [];
  const fora = [];
  for (const campo of ['segmento', 'fase', 'desfecho', 'lead_vinculo_regra']) {
    if (est[campo] && !herda.includes(campo)) {
      fora.push(`o filtro de ${ROTULO_CAMPO[campo]} (${rotuloDeValor(campo, est[campo])}), que esta seção não aplica ao próprio número`);
    }
  }
  if (est.busca) fora.push(`a busca “${est.busca}”, que estreita só a lista do rodapé e não o número clicado`);
  const extra = def.extra();
  if (est.so_divergentes && extra.so_divergentes !== true) fora.push('o interruptor “só divergentes”, que é de auditoria e estreita só a lista');
  if (est.so_sem_valor && extra.so_sem_valor !== true) fora.push('o interruptor “só sem valor”, que é de auditoria e estreita só a lista');
  return fora;
}

/**
 * Monta o recorte do painel a partir do estado da aba.
 *
 * A parte que não é óbvia é a INTERSEÇÃO. Com `desfecho=perdida` na barra de
 * filtros, o card "Ganhas" marca 0 — porque os cards já aplicam o filtro.
 * Trocar `desfecho` por `ganha` abriria 987 linhas embaixo de um card que diz
 * zero. O recorte certo é a interseção dos dois, que nesse caso é o conjunto
 * VAZIO: a API não tem como expressar "nada", então o painel nem chama — ele
 * declara a exclusão mútua e confere contra o zero do card.
 */
export function filtrosDoPainel(def, est = estado) {
  if (!def) return null;
  const filtros = { limit: PAGINA };
  for (const campo of HERANCA_DO_PAINEL[def.secao] ?? []) {
    const v = est[campo];
    if (v !== null && v !== undefined && v !== '') filtros[campo] = v;
  }
  if (est.ordenar_por) filtros.ordenar_por = est.ordenar_por;

  let vazio = false;
  let motivoVazio = null;
  for (const [campo, alvo] of Object.entries(def.extra())) {
    if (typeof alvo === 'boolean') { filtros[campo] = alvo; continue; }
    const herdado = filtros[campo];
    if (!herdado) { filtros[campo] = alvo; continue; }
    if (alvo.includes(herdado)) { filtros[campo] = [herdado]; continue; }
    vazio = true;
    motivoVazio = `o filtro de ${ROTULO_CAMPO[campo] ?? campo} ativo na aba (${rotuloDeValor(campo, herdado)}) e este recorte (${alvo.map((v) => rotuloDeValor(campo, v)).join(' ou ')}) são mutuamente exclusivos — a interseção é vazia, e é por isso que o número clicado é zero`;
  }
  return { filtros, vazio, motivoVazio, ignorados: ignoradosDoPainel(def, est) };
}

/** O recorte, por extenso, para o subtítulo do painel. */
function recortePorExtenso(plano, est) {
  const pedacos = [];
  const de = plano.filtros.de ? dataDePeriodo(`${plano.filtros.de}T00:00:00.000Z`) : null;
  const ate = plano.filtros.ate ? dataDePeriodo(`${plano.filtros.ate}T00:00:00.000Z`, -1) : null;
  pedacos.push(de && ate ? `criadas entre ${de} e ${ate}, inclusive` : 'sem recorte de período — a base inteira');
  for (const campo of ['segmento', 'categoria', 'fase', 'desfecho', 'moeda', 'lead_vinculo_regra']) {
    const v = plano.filtros[campo];
    if (v === undefined) continue;
    const lista = Array.isArray(v) ? v : [v];
    pedacos.push(`${ROTULO_CAMPO[campo]} = ${lista.map((x) => rotuloDeValor(campo, x)).join(' ou ')}`);
  }
  if (plano.filtros.so_sem_valor) pedacos.push('sem valor convertido para real');
  if (plano.filtros.so_divergentes) pedacos.push('com divergência entre a declaração da origem e a nossa fase');
  return pedacos.join(' · ');
}

/**
 * O cabeçalho do painel: o recorte exato, o total, e a CONFERÊNCIA contra o
 * número clicado. A conferência é a razão de este painel existir — sem ela,
 * ele é só mais uma lista, e listas que não batem com o card acima delas foram
 * o defeito que matou a aba antiga.
 */
export function renderPainelSub({ def, plano, total, esperado, mock = false, est = estado }) {
  const t = int(total);
  const e = (esperado === null || esperado === undefined) ? null : int(esperado);

  let confere;
  if (mock) {
    confere = `<span style="color:var(--amber)">fixture de desenvolvimento: o mock não refiltra, então o total abaixo é o do fixture inteiro e a conferência contra o número clicado não se aplica aqui</span>`;
  } else if (e === null) {
    confere = '<span style="color:var(--amber)">⚠️ o número de origem não veio na última resposta — sem conferência possível, e isso já é um defeito</span>';
  } else if (t === e) {
    confere = `<span style="color:var(--green)"><i class="ti ti-check" style="margin-right:4px"></i>confere: <strong style="font-variant-numeric:tabular-nums">${br(t)}</strong> no painel = <strong style="font-variant-numeric:tabular-nums">${br(e)}</strong> no número clicado</span>`;
  } else {
    confere = `<span style="color:var(--red)">⚠️ o painel trouxe <strong style="font-variant-numeric:tabular-nums">${br(t)}</strong> e o número clicado marca <strong style="font-variant-numeric:tabular-nums">${br(e)}</strong>. A tela está se contradizendo: uma das duas contagens está errada, e nenhuma linha abaixo deve ser lida como “o conjunto do card” enquanto isto aparecer.</span>`;
  }

  const vazio = plano.vazio
    ? `<div class="tl-idade" style="margin-top:8px;line-height:1.5">⚠️ ${escapeHtml(plano.motivoVazio ?? '')}. Nenhuma chamada foi feita à API: não existe recorte que devolva o conjunto vazio, e inventar um devolveria linhas que não pertencem a este número.</div>`
    : '';

  const ignorados = plano.ignorados.length
    ? `<div class="tl-idade" style="margin-top:8px;line-height:1.5">⚠️ Este painel NÃO herdou ${plano.ignorados.map((x) => escapeHtml(x)).join('; ')}. Herdar faria a lista deixar de corresponder ao número que a abriu.</div>`
    : '';

  // Ressalva do próprio recorte: hoje só a linha de categoria nula tem uma, e
  // ela existe porque a camada não sabe filtrar por ausência de categoria.
  const ressalva = def.ressalva
    ? `<div class="tl-idade" style="margin-top:8px;line-height:1.5">⚠️ ${escapeHtml(def.ressalva)}</div>`
    : '';

  return `<div class="mono-sm" style="color:var(--muted);line-height:1.6">
      <strong style="color:var(--text)">Recorte:</strong> ${escapeHtml(recortePorExtenso(plano, est))}.
      <br>${confere}
    </div>${vazio}${ressalva}${ignorados}`;
}

function hidratarDaUrl() {
  const url = typeof window === 'undefined' ? {} : lerEstadoAtual();
  Object.assign(estado, PADROES);
  estado.offset = 0;
  for (const [naUrl, interno] of Object.entries(CHAVES_URL)) {
    // `parse()` devolve array quando a chave se repete; aqui todo campo é
    // escalar, então o primeiro valor é o que vale.
    const v = Array.isArray(url[naUrl]) ? url[naUrl][0] : url[naUrl];
    if (v !== undefined && v !== '') estado[interno] = v;
  }
  for (const [naUrl, interno] of Object.entries(CHAVES_URL_BOOL)) {
    estado[interno] = url[naUrl] === '1';
  }
  // A URL é entrada NÃO CONFIÁVEL: ela pode ter sido editada à mão ou ter
  // envelhecido depois de um preset ser renomeado. Dois campos precisam de
  // validação, por motivos diferentes:
  //
  //  `ordenar_por` — `fn_search_oportunidades` faz RAISE EXCEPTION em valor
  //    desconhecido (de propósito: cair num ORDER BY padrão em silêncio faria
  //    a tela mostrar uma ordem que ninguém pediu). Sem esta guarda,
  //    `?oord=xpto` derruba a aba inteira com erro de API.
  //  `preset` — um valor desconhecido faria `aplicarPreset` não mexer em
  //    de/ate, e a aba abriria sobre o UNIVERSO parecendo estar nos 12 meses.
  //    Silenciosamente mostrar 8.073 no lugar de 5.413 é pior que ignorar o
  //    parâmetro.
  if (!['recentes', 'valor', 'fase'].includes(estado.ordenar_por)) {
    estado.ordenar_por = PADROES.ordenar_por;
  }
  const presetConhecido = estado.preset === 'custom' || PRESETS.some((x) => x.id === estado.preset);
  if (!presetConhecido) estado.preset = PADROES.preset;

  // `odet` — o painel aberto (FR-6: endereçável e retomável, como o resto da
  // aba). Também entrada NÃO CONFIÁVEL: `definicaoDoPainel` devolve null para
  // tipo desconhecido, e aí o painel simplesmente não abre em vez de a aba
  // tentar montar um recorte que não existe. Só é ABERTO depois da primeira
  // carga, porque o número esperado sai da resposta que pinta os cards.
  const det = Array.isArray(url.odet) ? url.odet[0] : url.odet;
  _painelPendenteDaUrl = definicaoDoPainel(det) ? det : null;

  // Preset e datas têm de ser coerentes: preset nomeado manda nas datas; só
  // `custom` preserva o que veio escrito na URL.
  if (estado.preset !== 'custom') aplicarPreset(estado.preset);
}

/**
 * Esta aba está visível? A pergunta existe por um defeito real: o listener de
 * Esc vive no `document` e continuava vivo depois de o usuário trocar de aba
 * com o painel aberto. Abrir "Ganhas" → ir para Leads → Esc fazia
 * `fecharPainel()` chamar `persistirNaUrl()`, que crava `view` — e a URL
 * passava a dizer `view=oportunidades-crm` com `view-leads-crm` na tela. F5 ou
 * link compartilhado abria a aba errada.
 */
function abaAtiva() {
  if (typeof document === 'undefined') return false;
  const raiz = document.getElementById('view-oportunidades-crm');
  return Boolean(raiz && raiz.classList.contains('active'));
}

function persistirNaUrl(opcoes = {}) {
  if (typeof window === 'undefined') return;
  // Só esta aba escreve a URL desta aba.
  //
  // ⚠️ GUARDA QUE A SUÍTE NÃO DISCRIMINA, e isto está escrito para não parecer
  // coberta: com o observador de saída de aba (ver `ligarEventos`) fechando o
  // painel antes, nenhum caminho chama esta função com a aba inativa — mutar
  // esta linha não deixa teste nenhum vermelho. Ela fica porque escreve estado
  // GLOBAL (a query string, compartilhada com todas as views) e porque foi
  // assim que a URL de Leads foi sequestrada: um caller futuro que rode fora do
  // ciclo da aba erraria de novo, calado.
  if (!abaAtiva()) return;
  // Parte do que JÁ está na URL para não apagar `dados=mock` / `cenario=`, que
  // são chaves de sessão de teste e vivem no mesmo lugar. `atualizarEstado`
  // reescreve a query string INTEIRA — foi exatamente assim que `dados=mock`
  // sumiu no meio de um spec antes (ver data-api.js).
  const novo = { ...lerEstadoAtual(), view: 'oportunidades-crm' };
  for (const [naUrl, interno] of Object.entries(CHAVES_URL)) {
    const v = estado[interno];
    if (v === null || v === undefined || v === '' || v === PADROES[interno]) delete novo[naUrl];
    else novo[naUrl] = String(v);
  }
  for (const [naUrl, interno] of Object.entries(CHAVES_URL_BOOL)) {
    if (estado[interno]) novo[naUrl] = '1'; else delete novo[naUrl];
  }
  // `custom` precisa das datas na URL mesmo quando o preset é o default.
  if (estado.preset === 'custom') {
    if (estado.de) novo.ode = estado.de;
    if (estado.ate) novo.oate = estado.ate;
    novo.opreset = 'custom';
  }
  // O painel aberto vive na URL junto com o recorte: sem isto, F5 sobre um
  // painel aberto voltava para a aba sem ele, e o link compartilhado mostrava
  // a aba em vez do conjunto que motivou o compartilhamento.
  // `_painelPendenteDaUrl` entra no OR porque, na entrada da aba, a URL é
  // reescrita ANTES de o painel de `?odet=` abrir (ele espera a primeira
  // carga): sem ele, esta reescrita apagaria o próprio parâmetro que a
  // hidratação acabou de ler.
  const det = _painel.tipo || _painelPendenteDaUrl;
  if (det) novo.odet = det; else delete novo.odet;
  atualizarEstado(novo, opcoes);
}
// Lido de `odet` na hidratação e consumido depois da primeira carga — o número
// que o painel tem de bater sai da mesma resposta que pinta os cards, e ela só
// existe depois de `carregar()`.
let _painelPendenteDaUrl = null;
let _acumulado = [];
let _ultimaResposta = null;
let _ligado = false;
// Contador de requisição. Trocar dois filtros em sequência rápida dispara duas
// leituras, e a rede não garante a ordem de chegada: sem isto, a resposta do
// filtro ANTIGO pode aterrissar depois e repintar a tela com números que não
// correspondem aos controles. Visto ao vivo em 2026-09-16 — a tabela de
// segmento ficou sem o aviso de filtro ignorado porque quem venceu a corrida
// foi o render anterior. Resposta atrasada é descartada, não desenhada.
let _seq = 0;

function filtrosDaApi() {
  const f = {
    segmento: estado.segmento || undefined,
    fase: estado.fase || undefined,
    desfecho: estado.desfecho || undefined,
    moeda: estado.moeda || undefined,
    lead_vinculo_regra: estado.lead_vinculo_regra || undefined,
    busca: estado.busca || undefined,
    ordenar_por: estado.ordenar_por || undefined,
    so_divergentes: estado.so_divergentes || undefined,
    so_sem_valor: estado.so_sem_valor || undefined,
    limit: PAGINA,
    offset: estado.offset || undefined,
  };
  if (estado.de) f.de = estado.de;
  if (estado.ate) f.ate = estado.ate;
  return f;
}

function aplicarPreset(id) {
  estado.preset = id;
  const p = PRESETS.find((x) => x.id === id);
  if (!p || p.meses === null) { estado.de = null; estado.ate = null; return; }
  const { de, ate } = ultimosMeses(p.meses);
  estado.de = de; estado.ate = ate;
}

const el = (id) => document.getElementById(id);
const set = (id, html) => { const x = el(id); if (x) x.innerHTML = html; };
const txt = (id, v) => { const x = el(id); if (x) x.textContent = v; };

// Opções de segmento e fase vêm do DADO (com contagem), nunca de enum
// embutido — foi assim que `ok_plano` sumiu da aba de qualidade quando nasceu.
// O valor selecionado é reinjetado quando o recorte o zera, senão o filtro
// ativo desaparece do próprio seletor.
function preencherSelect(id, valorAtual, rotuloVazio, itens) {
  const sel = el(id);
  if (!sel) return;
  const temAtual = !valorAtual || itens.some((i) => i.valor === valorAtual);
  const lista = temAtual ? itens : [...itens, { valor: valorAtual, rotulo: `${valorAtual} (sem linha no recorte)`, qtd: null }];
  sel.innerHTML = `<option value="">${escapeHtml(rotuloVazio)}</option>` + lista.map((i) => `
    <option value="${escapeHtml(i.valor)}"${i.valor === valorAtual ? ' selected' : ''}>${escapeHtml(i.rotulo)}${i.qtd === null || i.qtd === undefined ? '' : ` (${br(i.qtd)})`}</option>`).join('');
}

function renderBarra(resp) {
  // presets
  document.querySelectorAll('#opc-presets .preset-btn').forEach((b) => {
    b.classList.toggle('active', b.getAttribute('data-preset') === estado.preset);
  });
  const de = el('opc-de'); if (de) de.value = estado.de ?? '';
  const ate = el('opc-ate'); if (ate) ate.value = estado.ate ?? '';

  if (resp) {
    preencherSelect('opc-segmento', estado.segmento, 'Todos os segmentos',
      (resp.segmento ?? []).map((s) => ({ valor: s.segmento_aba, rotulo: ROTULO_SEG[s.segmento_aba] ?? s.segmento_aba, qtd: int(s.qtd_oportunidades) })));
    preencherSelect('opc-fase', estado.fase, 'Todas as fases',
      (resp.funil ?? []).filter((f) => f.fase).map((f) => ({ valor: f.fase, rotulo: ROTULO_FASE[f.fase] ?? f.fase, qtd: int(f.qtd_da_coorte_agora) })));
    const c = resp.cards ?? {};
    // CONTAGEM DE DESFECHO SÓ QUANDO NÃO HÁ FILTRO DE DESFECHO.
    // `cards` já aplica o próprio filtro: com "Ganhas" selecionado, o dropdown
    // passava a oferecer "Perdidas (0)" e "Abertas (0)" quando são 758 e
    // 3.664. Numa aba cuja tese é "contagem nunca mente", um zero falso no
    // seletor é o pior lugar possível.
    // `fase` e `segmento` não têm o problema porque o funil e a tabela de
    // segmento ignoram justamente esses dois filtros — as contagens de lá
    // continuam sendo do recorte inteiro.
    const filtrandoDesfecho = Boolean(estado.desfecho);
    preencherSelect('opc-desfecho', estado.desfecho,
      filtrandoDesfecho ? 'Todos os desfechos (limpe para ver as contagens)' : 'Todos os desfechos',
      DESFECHOS.map((d) => ({
        valor: d.valor, rotulo: d.rotulo,
        // `null` = "não sei contar sob este filtro", e `preencherSelect` omite
        // o número. Omitir é honesto; imprimir o zero do recorte filtrado não.
        qtd: filtrandoDesfecho && d.valor !== estado.desfecho ? null : int(c[d.campo]),
      })));
  }
}

export function renderRecorte(resp) {
  const c = resp.cards ?? {};
  const aplicado = resp.periodo_aplicado === true;
  const pedaco = aplicado
    ? `no recorte de <strong>${escapeHtml(dataDePeriodo(c.periodo_de) ?? estado.de)}</strong> a <strong>${escapeHtml(dataDePeriodo(c.periodo_ate, -1) ?? estado.ate)}</strong>, inclusive, sobre a data de criação da oportunidade
       <span style="color:var(--dim)">(a API recebe <code>de=${escapeHtml(dataDePeriodo(c.periodo_de) ?? '')}</code> inclusivo e <code>ate=${escapeHtml(dataDePeriodo(c.periodo_ate) ?? '')}</code> exclusivo)</span>`
    : '<strong>sem recorte de período</strong> — a base inteira, do primeiro registro ao último';
  // "N oportunidades no sem recorte de período" foi o que a frase produzia
  // quando o preset Tudo estava ativo. A preposição pertence ao pedaço, não à
  // moldura.
  const anterior = c.periodo_anterior_tem_dado === true
    ? `Comparação: ${escapeHtml(dataDePeriodo(c.periodo_anterior_de) ?? '—')} a ${escapeHtml(dataDePeriodo(c.periodo_anterior_ate, -1) ?? '—')}, uma janela de mesma duração deslocada para trás.`
    : `<span style="color:var(--amber)">Sem período anterior comparável — as setas de tendência estão escondidas. ${escapeHtml(c.periodo_anterior_sem_dado_motivo ?? '')}</span>`;
  const mock = resp.mock === true
    ? `<div class="tl-idade" style="margin-top:6px;line-height:1.5">⚠️ Fixture de desenvolvimento (<code>assets/data/mock/oportunidades.json</code>), não a base.
        Os filtros não estão aplicados aos números — o mock não refiltra, porque reproduzir os predicados do SQL aqui criaria um segundo motor de números que discordaria do primeiro.
        O fixture carrega ${br(resp.lista?.linhas_no_fixture ?? 0)} linhas de exemplo sobre um total declarado de ${br(resp.lista?.total)}: por isso a lista termina antes do total, e isso é o mock, não paginação quebrada.</div>`
    : '';
  return `<div class="mono-sm" style="color:var(--muted);line-height:1.6">
      ${br(c.total_oportunidades)} oportunidades ${pedaco}.
      <br>${anterior}
      <br><span style="color:var(--dim)">Gerado em ${escapeHtml(dataCurta(resp.gerado_em) ?? '—')} · a camada lê todas as oportunidades do Salesforce, não o recorte de nenhuma planilha.</span>
    </div>${mock}`;
}

/** Total da coorte que o FUNIL descreve — dele, não dos cards. */
export function totalDaCoorte(funil) {
  const linhas = Array.isArray(funil) ? funil : [];
  if (linhas.length === 0) return 0;
  return int(linhas[0].total_da_coorte);
}

/**
 * Cobertura de atribuição da TABELA DE SEGMENTO, calculada dos próprios
 * baldes. `cards.pct_com_segmento` não serve aqui: a tabela ignora os filtros
 * de segmento e de vínculo, então os dois falam de recortes diferentes assim
 * que um desses filtros é usado.
 */
export function coberturaDaTabela(segmento) {
  const linhas = Array.isArray(segmento) ? segmento : [];
  if (linhas.length === 0) return '—';
  const total = linhas.reduce((acc, x) => acc + int(x.qtd_oportunidades), 0);
  if (total === 0) return '—';
  const semClasse = linhas
    .filter((x) => x.segmento_aba === 'NaoClassificado' || x.segmento_aba === 'SemOrigem')
    .reduce((acc, x) => acc + int(x.qtd_oportunidades), 0);
  const p = ((total - semClasse) / total) * 100;
  return `${p.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}% com origem classificada`;
}

/**
 * Badge da seção de categoria. Conta as linhas e destaca quantas existem só do
 * lado do lead — que é a informação que o badge tem para dar e que nenhum outro
 * lugar da tela dá. Sai do dado da PRÓPRIA seção, nunca de `cards`: a tabela
 * ignora o filtro de vínculo, e os dois falariam de recortes diferentes.
 */
export function badgeDeCategoria(categoria) {
  const linhas = Array.isArray(categoria) ? categoria : [];
  if (linhas.length === 0) return '—';
  const soLead = linhas.filter((x) => x.categoria_presente_em === 'so_lead').length;
  const base = `${br(linhas.length)} categoria${linhas.length === 1 ? '' : 's'}`;
  return soLead > 0 ? `${base} · ${br(soLead)} só do lado do lead` : base;
}

function ignoradosFunil() {
  const x = [];
  if (estado.fase) x.push('o filtro de fase');
  if (estado.desfecho) x.push('o filtro de desfecho');
  return x;
}
function ignoradosSegmento() {
  const x = [];
  if (estado.segmento) x.push('o filtro de segmento');
  if (estado.lead_vinculo_regra) x.push('o filtro de vínculo');
  return x;
}
// A tabela de categoria aplica `segmento` (a de segmento não) e ignora
// `lead_vinculo_regra` — medido, não deduzido por simetria.
function ignoradosCategoria() {
  const x = [];
  if (estado.lead_vinculo_regra) x.push('o filtro de vínculo');
  return x;
}

export function renderRodapeLista(resp, mostrando) {
  const l = resp.lista ?? {};
  const total = int(l.total);
  const soLista = [];
  if (resp.__so_divergentes) soLista.push('só divergentes');
  if (resp.__so_sem_valor) soLista.push('só sem valor');
  // A EVIDÊNCIA VEM DO RECORTE QUE ESTÁ NA TELA. A versão anterior trazia
  // "a lista cai para 836 e os cards continuam em 8.073", medido uma vez no
  // preset "Tudo" e escrito à mão: no padrão de 12 meses o real é 461 contra
  // 5.413, e a nota passava a citar números que não estavam em lugar nenhum
  // da página. É a mesma ilustração congelada já removida do rodapé do
  // segmento, reaparecendo 350 linhas abaixo.
  const nota = soLista.length
    ? `<div class="tl-idade" style="margin-top:6px;line-height:1.5">⚠️ ${escapeHtml(soLista.join(' e '))}: estes dois interruptores são de AUDITORIA e existem só em
        <code>fn_search_oportunidades</code>. Eles estreitam <strong>a lista</strong> e <strong>não</strong> os cards, o funil ou a tabela de segmento —
        neste recorte, a lista está em <strong>${br(total)}</strong> e os cards continuam em <strong>${br(resp.cards?.total_oportunidades)}</strong>.</div>`
    : '';
  return `<div class="mono-sm" style="color:var(--dim);line-height:1.6">
      Mostrando ${br(mostrando)} de ${br(total)} oportunidades do mesmo predicado dos cards
      (o total vem do SQL, não de <code>length</code> do array recebido — total vindo de outro lugar foi como a aba antiga produziu número que não batia com a lista embaixo dele).
      <br>A lista não exibe nome de lead: a unidade desta aba é o negócio, e este repositório é público.
    </div>${nota}`;
}

async function carregar(acumular = false) {
  const alvoErro = 'opc-recorte-info';
  const meu = ++_seq;
  try {
    const resp = await obterOportunidades(filtrosDaApi());
    if (meu !== _seq) return; // chegou tarde: já existe leitura mais nova
    _ultimaResposta = resp;
    const novas = resp.lista?.oportunidades ?? [];
    _acumulado = acumular ? _acumulado.concat(novas) : novas;

    set(alvoErro, renderRecorte(resp));
    renderBarra(resp);

    const cards = resp.cards ?? {};
    set('opc-integridade', renderIntegridade(cards));

    const particaoOk = cards.soma_fecha === true && conferirParticao(cards).fechaNaTela;
    // REGRA 3: partição quebrada ⇒ nenhum número agregado é desenhado. A lista
    // continua, porque ela é o dado bruto — é justamente nela que se investiga.
    set('opc-kpis', particaoOk ? renderKpis(cards) : '');
    set('opc-funil', particaoOk ? renderFunil(resp.funil, { ignorando: ignoradosFunil() })
      : '<div class="empty-state"><div class="es-title">Seção suprimida</div><div>A partição por desfecho não fecha — ver o alerta no topo.</div></div>');
    set('opc-segmento-tbl', particaoOk ? renderSegmento(resp.segmento, { ignorando: ignoradosSegmento() })
      : '<div class="empty-state"><div class="es-title">Seção suprimida</div><div>A partição por desfecho não fecha — ver o alerta no topo.</div></div>');
    set('opc-categoria-tbl', particaoOk ? renderCategoria(resp.categoria, { ignorando: ignoradosCategoria() })
      : '<div class="empty-state"><div class="es-title">Seção suprimida</div><div>A partição por desfecho não fecha — ver o alerta no topo.</div></div>');
    set('opc-fora-valor', particaoOk ? renderForaDoValor(cards)
      : '<div class="empty-state"><div class="es-title">Seção suprimida</div><div>A partição por desfecho não fecha — ver o alerta no topo.</div></div>');
    set('opc-ciclo', renderRessalvaCiclo(cards));

    // BADGE DE CADA SEÇÃO VEM DO TOTAL DA PRÓPRIA SEÇÃO, nunca de `cards`.
    // Com `desfecho=ganha`, `cards.total_oportunidades` é 987 e o funil segue
    // falando de 5.413 (ele ignora `desfecho`): o badge dizia "987 na coorte"
    // 400px acima de um rodapé dizendo "as fases somam 5.413". O mesmo com
    // `pct_com_segmento`, que ia a 100% sobre uma tabela inalterada.
    txt('opc-funil-badge', `${br(totalDaCoorte(resp.funil))} na coorte`);
    txt('opc-segmento-badge', coberturaDaTabela(resp.segmento));
    txt('opc-categoria-badge', badgeDeCategoria(resp.categoria));
    txt('opc-lista-badge', `${br(resp.lista?.total)} no recorte`);
    txt('opc-fora-badge', `${br(cards.qtd_ganhas_fora_do_valor)} ganha(s)`);

    set('opc-lista-rows', renderLista({ oportunidades: _acumulado, total: resp.lista?.total }));
    set('opc-lista-foot', renderRodapeLista(
      { ...resp, __so_divergentes: estado.so_divergentes, __so_sem_valor: estado.so_sem_valor },
      _acumulado.length));

    const mais = el('opc-mais');
    // `tem_mais` vem da camada de dados, que sabe quantas linhas ela tem.
    // Comparar `_acumulado.length` com `lista.total` era errado sempre que os
    // dois falam de coisas diferentes: no fixture, `total` é 420 (o recorte
    // que os cards descrevem) sobre um array de 10, e o botão ficava visível
    // para sempre sem nada para carregar.
    if (mais) mais.style.display = resp.lista?.tem_mais === true ? '' : 'none';
  } catch (e) {
    if (meu !== _seq) return; // erro de leitura obsoleta não apaga a tela atual
    set(alvoErro, `<div class="tl-idade" style="line-height:1.55">⚠️ Falha ao carregar a aba: ${escapeHtml(e.message)}.
      Nenhum número é exibido em cima de uma leitura que falhou — a tela prefere ficar vazia a mostrar o recorte anterior como se fosse o atual.</div>`);
    set('opc-kpis', ''); set('opc-integridade', ''); set('opc-funil', '');
    set('opc-segmento-tbl', ''); set('opc-categoria-tbl', '');
    set('opc-fora-valor', ''); set('opc-ciclo', '');
    set('opc-lista-rows', ''); set('opc-lista-foot', '');
  }
}

// ---------------------------------------------------------------------------
// o painel, em movimento
// ---------------------------------------------------------------------------
// Estado PRÓPRIO, separado do da lista de baixo. Os dois paginam, e misturar
// os offsets faria "Carregar mais" do painel avançar a lista do rodapé.
const _painel = {
  tipo: null, def: null, plano: null, esperado: null,
  acumulado: [], total: 0, temMais: false, seq: 0, origem: null,
};

function painelAberto() {
  return _painel.tipo !== null;
}

// Os focáveis DENTRO do diálogo, na ordem do documento. Recalculado a cada Tab
// de propósito: a lista de linhas é repintada a cada página carregada, e uma
// lista memorizada apontaria para nós que saíram do DOM.
function focaveisDoPainel() {
  const modal = el('opc-detalhe');
  if (!modal) return [];
  return [...modal.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')]
    .filter((x) => !x.hasAttribute('disabled') && x.offsetParent !== null);
}

/**
 * Mantém o Tab dentro do diálogo enquanto ele estiver aberto — o
 * comportamento que `aria-modal="true"` PROMETE e que o markup sozinho não
 * entrega. A alternativa seria remover o atributo; ela foi descartada porque o
 * painel é modal de verdade (overlay opaco, Esc fecha, fundo inerte aos olhos),
 * e tirar a declaração só esconderia do leitor de tela o que os olhos já veem.
 */
function prenderFoco(ev) {
  const focaveis = focaveisDoPainel();
  if (focaveis.length === 0) return;
  const primeiro = focaveis[0];
  const ultimo = focaveis[focaveis.length - 1];
  const atual = document.activeElement;
  const modal = el('opc-detalhe');
  // Foco fora do diálogo (aconteceu antes desta guarda, ou veio do fundo):
  // devolve para dentro em vez de deixar seguir.
  if (!modal || !modal.contains(atual)) {
    ev.preventDefault();
    primeiro.focus();
    return;
  }
  if (ev.shiftKey && atual === primeiro) { ev.preventDefault(); ultimo.focus(); return; }
  if (!ev.shiftKey && atual === ultimo) { ev.preventDefault(); primeiro.focus(); }
}

// Trava a rolagem do fundo enquanto o painel está aberto. Sem isto, rolar com o
// painel na frente movia a página atrás dele — a mesma promessa quebrada do
// `aria-modal`, na versão do mouse.
function travarRolagem(travar) {
  if (typeof document === 'undefined' || !document.body) return;
  document.body.style.overflow = travar ? 'hidden' : '';
}

/**
 * O número que o painel tem de bater. Vem, nesta ordem:
 *   1. do `data-esperado` do elemento clicado — o número que o usuário viu;
 *   2. de `def.esperado(_ultimaResposta)`, quando o painel é reaberto pela URL
 *      (F5 ou link compartilhado) e não houve clique nenhum.
 * Os dois saem da MESMA resposta; o teste unitário confere que concordam para
 * todos os painéis, senão a fonte 2 poderia envelhecer sem ninguém notar.
 */
function esperadoDoPainel(def, doClique) {
  if (doClique !== null && doClique !== undefined && doClique !== '') {
    const x = Number(doClique);
    if (Number.isFinite(x)) return x;
  }
  return def.esperado(_ultimaResposta);
}

async function carregarPainel(acumular = false) {
  const def = _painel.def;
  if (!def) return;
  const meu = ++_painel.seq;
  const plano = filtrosDoPainel(def);
  _painel.plano = plano;

  const pintar = (resp, linhas) => {
    _painel.acumulado = linhas;
    _painel.total = int(resp?.lista?.total);
    _painel.temMais = resp?.lista?.tem_mais === true;
    const t = el('opc-det-titulo');
    if (t) t.textContent = `${def.rotulo} — ${br(_painel.total)} oportunidade${_painel.total === 1 ? '' : 's'}`;
    set('opc-det-sub', renderPainelSub({
      def, plano, total: _painel.total, esperado: _painel.esperado, mock: resp?.mock === true,
    }));
    set('opc-det-rows', renderLista({ oportunidades: linhas, total: _painel.total }));
    set('opc-det-foot', renderRodapePainel(linhas.length, _painel.total));
    const mais = el('opc-det-mais');
    // `tem_mais` da camada, nunca `acumulado.length < total`: os dois falam de
    // coisas diferentes assim que o total é o do recorte e o array é o da
    // página (foi o bloqueador 2 do QA na lista de baixo).
    if (mais) mais.style.display = _painel.temMais ? '' : 'none';
  };

  // INTERSEÇÃO VAZIA: nenhuma chamada. Não existe recorte que devolva "nada", e
  // mandar o recorte sem a parte que o esvazia traria linhas que não pertencem
  // ao número clicado.
  if (plano.vazio) {
    pintar({ lista: { total: 0, tem_mais: false } }, []);
    return;
  }

  try {
    const offset = acumular ? _painel.acumulado.length : 0;
    const resp = await obterOportunidades({ ...plano.filtros, offset: offset || undefined });
    if (meu !== _painel.seq || !painelAberto()) return;
    const novas = resp.lista?.oportunidades ?? [];
    pintar(resp, acumular ? _painel.acumulado.concat(novas) : novas);
  } catch (e) {
    if (meu !== _painel.seq || !painelAberto()) return;
    set('opc-det-sub', `<div class="tl-idade" style="line-height:1.55">⚠️ Falha ao abrir o painel: ${escapeHtml(e.message)}.
      Nenhuma linha é exibida sobre uma leitura que falhou.</div>`);
    set('opc-det-rows', '');
    set('opc-det-foot', '');
    const mais = el('opc-det-mais');
    if (mais) mais.style.display = 'none';
  }
}

export function renderRodapePainel(mostrando, total) {
  return `<div class="mono-sm" style="color:var(--dim);line-height:1.6">
      Mostrando ${br(mostrando)} de ${br(total)} oportunidades deste recorte — o total vem do SQL, não de <code>length</code> do array recebido.
      <br>O painel não exibe nome de lead: a unidade desta aba é o negócio, e este repositório é público. Quem precisa da pessoa abre a aba Leads.
    </div>`;
}

function abrirPainel(tipo, esperadoDoClique, origem) {
  const def = definicaoDoPainel(tipo);
  if (!def) return;
  _painel.tipo = tipo;
  _painel.def = def;
  _painel.esperado = esperadoDoPainel(def, esperadoDoClique);
  _painel.acumulado = [];
  _painel.total = 0;
  _painel.temMais = false;
  _painel.origem = origem ?? null;

  const modal = el('opc-detalhe');
  if (modal) modal.style.display = 'flex';
  travarRolagem(true);
  set('opc-det-rows', '');
  set('opc-det-foot', '');
  set('opc-det-sub', '<div class="mono-sm" style="color:var(--dim)">carregando o recorte…</div>');
  const t = el('opc-det-titulo');
  if (t) t.textContent = def.rotulo;
  const fechar = el('opc-det-fechar');
  if (fechar) fechar.focus();
  persistirNaUrl({ substituir: true });
  carregarPainel(false);
}

function fecharPainel({ persistir = true } = {}) {
  if (!painelAberto()) return;
  _painel.seq++; // descarta resposta em voo: ela não pode repintar um painel fechado
  _painel.tipo = null;
  _painel.def = null;
  _painel.plano = null;
  _painel.acumulado = [];
  const modal = el('opc-detalhe');
  if (modal) modal.style.display = 'none';
  travarRolagem(false);
  const origem = _painel.origem;
  _painel.origem = null;
  if (persistir) persistirNaUrl({ substituir: true });
  if (origem && typeof origem.focus === 'function' && origem.isConnected) origem.focus();
}

function recarregarDoZero() {
  estado.offset = 0;
  _acumulado = [];
  // Mexer num filtro muda o recorte que o painel herdou: mantê-lo aberto o
  // deixaria descrevendo um número que não está mais na tela.
  fecharPainel({ persistir: false });
  // `substituir: true`: mexer num filtro não é navegação, e empilhar uma
  // entrada de histórico por tecla digitada na busca tornaria o botão
  // "voltar" inutilizável.
  persistirNaUrl({ substituir: true });
  carregar(false);
}

function ligarEventos() {
  if (_ligado) return;
  _ligado = true;

  const raiz = el('view-oportunidades-crm');
  if (!raiz) return;

  // Fechar com Esc. Documento inteiro de propósito: o foco pode estar no botão
  // de fechar, numa linha da tabela ou em lugar nenhum, e o Esc tem de valer
  // nos três casos. Só age com o painel aberto, então não rouba o Esc de mais
  // ninguém na página.
  // SAIR DA ABA FECHA O PAINEL. Não é zelo: o painel trava a rolagem do corpo
  // (`travarRolagem`), e sair da aba com ele aberto deixaria a página SEGUINTE
  // sem rolagem, por um estado que não é mais dela. A guarda de `abaAtiva()`
  // sozinha não resolveria isso — ela impede a URL de ser sequestrada, não o
  // `overflow:hidden` de vazar.
  //
  // Observador em vez de hook no `showView`: a troca de view é de
  // views-legacy.js, e este módulo não o edita por decisão. A classe `active`
  // no próprio nó é o sinal público dessa troca.
  if (typeof MutationObserver !== 'undefined') {
    new MutationObserver(() => {
      if (painelAberto() && !abaAtiva()) fecharPainel({ persistir: false });
    }).observe(raiz, { attributes: true, attributeFilter: ['class'] });
  }

  document.addEventListener('keydown', (ev) => {
    if (!painelAberto() || !abaAtiva()) return;
    if (ev.key === 'Escape') { ev.stopPropagation(); fecharPainel(); return; }
    // ARMADILHA DE FOCO. Declarar `aria-modal="true"` e deixar o Tab passear
    // pelo fundo é pior do que não declarar: leitor de tela e teclado passam a
    // operar numa página que o overlay esconde. Medido antes desta guarda: de
    // 40 Tabs, 38 paradas caíam fora do diálogo, e a segunda já era o BODY.
    if (ev.key === 'Tab') prenderFoco(ev);
  });

  raiz.addEventListener('click', (ev) => {
    if (ev.target.closest('[data-drill-fechar]')) { fecharPainel(); return; }
    // ANTES dos filtros: o painel também vive dentro da raiz, e um clique nele
    // não pode ser lido como clique num controle da aba.
    const drill = ev.target.closest('[data-drill]');
    if (drill) {
      abrirPainel(drill.getAttribute('data-drill'), drill.getAttribute('data-esperado'), drill);
      return;
    }
    if (ev.target.closest('#opc-det-btn-mais')) { carregarPainel(true); return; }
    const btn = ev.target.closest('[data-preset]');
    if (btn) { aplicarPreset(btn.getAttribute('data-preset')); recarregarDoZero(); return; }
    if (ev.target.closest('#opc-limpar')) {
      estado.segmento = ''; estado.fase = ''; estado.desfecho = ''; estado.moeda = '';
      estado.lead_vinculo_regra = ''; estado.busca = ''; estado.ordenar_por = 'recentes';
      estado.so_divergentes = false; estado.so_sem_valor = false;
      aplicarPreset('12m');
      const b = el('opc-busca'); if (b) b.value = '';
      ['opc-moeda', 'opc-vinculo', 'opc-ordem'].forEach((id) => { const s = el(id); if (s) s.value = id === 'opc-ordem' ? 'recentes' : ''; });
      ['opc-so-divergentes', 'opc-so-sem-valor'].forEach((id) => { const c = el(id); if (c) c.checked = false; });
      recarregarDoZero();
      return;
    }
    if (ev.target.closest('#opc-btn-mais')) {
      estado.offset = _acumulado.length;
      carregar(true);
    }
  });

  // Teclado: `role="button"` obriga a responder a Enter e Espaço. Sem isto os
  // cards e as linhas seriam alcançáveis pelo Tab e não fariam nada — pior que
  // não serem alcançáveis.
  raiz.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Enter' && ev.key !== ' ') return;
    const drill = ev.target.closest('[data-drill]');
    if (!drill) return;
    ev.preventDefault();
    abrirPainel(drill.getAttribute('data-drill'), drill.getAttribute('data-esperado'), drill);
  });

  raiz.addEventListener('change', (ev) => {
    const id = ev.target.id;
    const mapa = {
      'opc-segmento': 'segmento', 'opc-fase': 'fase', 'opc-desfecho': 'desfecho',
      'opc-moeda': 'moeda', 'opc-vinculo': 'lead_vinculo_regra', 'opc-ordem': 'ordenar_por',
    };
    if (mapa[id]) { estado[mapa[id]] = ev.target.value; recarregarDoZero(); return; }
    if (id === 'opc-so-divergentes') { estado.so_divergentes = ev.target.checked; recarregarDoZero(); return; }
    if (id === 'opc-so-sem-valor') { estado.so_sem_valor = ev.target.checked; recarregarDoZero(); return; }
    if (id === 'opc-de' || id === 'opc-ate') {
      estado.preset = 'custom';
      estado.de = el('opc-de')?.value || null;
      estado.ate = el('opc-ate')?.value || null;
      recarregarDoZero();
    }
  });

  let timer = null;
  raiz.addEventListener('input', (ev) => {
    if (ev.target.id !== 'opc-busca') return;
    clearTimeout(timer);
    const v = ev.target.value;
    timer = setTimeout(() => { estado.busca = v.trim(); recarregarDoZero(); }, 350);
  });
}

/**
 * Ponto de entrada — chamado quando a view é exibida (ver bootstrap).
 *
 * Reidrata da URL e recomeça do offset ZERO. A versão anterior chamava
 * `carregar(false)` direto, e só `recarregarDoZero()` zerava o offset: quem
 * clicasse em "Carregar mais", saísse da aba e voltasse, voltava com
 * `offset=10` sobre uma lista recém-esvaziada — em mock a lista ia de 10 para
 * o estado vazio dizendo "Mostrando 0 de 420"; em produção voltava começando
 * na linha 101, com o "Carregar mais" seguinte concatenando fora de ordem.
 */
export async function renderViewOportunidades() {
  ligarEventos();
  fecharPainel({ persistir: false }); // entrar na aba de novo não reabre painel antigo
  hidratarDaUrl();
  sincronizarControles();
  renderBarra(_ultimaResposta);
  estado.offset = 0;
  _acumulado = [];
  persistirNaUrl({ substituir: true });
  await carregar(false);
  // O painel de `?odet=` só abre AGORA, depois de `carregar()`: o número que
  // ele tem de bater sai da resposta que acabou de pintar os cards. Abrir antes
  // seria conferir contra `undefined` e mostrar o aviso de "sem conferência
  // possível" em toda abertura por link.
  if (_painelPendenteDaUrl) {
    const pendente = _painelPendenteDaUrl;
    _painelPendenteDaUrl = null;
    abrirPainel(pendente, null, null);
  }
}

/** Põe os controles do DOM no valor do `estado` (que veio da URL). */
function sincronizarControles() {
  const v = (id, valor) => { const x = el(id); if (x) x.value = valor ?? ''; };
  v('opc-busca', estado.busca);
  v('opc-moeda', estado.moeda);
  v('opc-vinculo', estado.lead_vinculo_regra);
  v('opc-ordem', estado.ordenar_por);
  const c1 = el('opc-so-divergentes'); if (c1) c1.checked = estado.so_divergentes;
  const c2 = el('opc-so-sem-valor'); if (c2) c2.checked = estado.so_sem_valor;
  // segmento/fase/desfecho são repovoados por `renderBarra` a partir do dado.
}

/** Só para teste: devolve o estado interno sem expor a referência viva. */
export function _estadoParaTestes() {
  return { ...estado, ultimaResposta: _ultimaResposta };
}
