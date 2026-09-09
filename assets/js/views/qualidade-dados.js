// assets/js/views/qualidade-dados.js — degradação explícita por fonte
// indisponível (5.15, P-UI-6, EC-8, AC-9.2) e, desde 2026-09-09, a auditoria
// que o contrato de dados prometia e não tinha:
//
//   §1.6  contagem de exclusão de dado de teste POR REGRA. A marcação já
//         existia no banco; a contagem não, e sem ela "exclusão nunca
//         silenciosa" era só intenção — o lead saía dos filtros e ninguém
//         via por quê.
//   §1.3  os valores que nenhuma regra classificou, para a tabela de regras
//         evoluir com evidência. Foi assim que se descobriu que a regra de
//         cargo `Outro` (match exato) não pegava `Outros` — 27 leads.
//
// Esta aba mostra os números desconfortáveis de propósito. Se ela ficar
// vazia e bonita, provavelmente está escondendo algo.

import { obterQualidadeDados } from '../data-api.js';

const FONTE_LABEL = { salesforce: 'Salesforce', rd_station: 'RD Station', ads: 'Mídia paga', seed_test: 'Seed de teste' };

const ROTULO_VALOR = {
  c_level: 'C-level', diretoria: 'Diretoria', gerencia: 'Gerência',
  coordenacao: 'Coordenação', analista: 'Analista', consultor: 'Consultor/Especialista',
  operacional: 'Operacional', outro_declarado: 'Outro (declarado)',
  area_declarada: 'Área declarada', outros: 'Sem regra',
  nao_informado: 'Não informado',
  pequena: 'Pequena (1–99)', media: 'Média (100–999)', grande: 'Grande (1.000+)',
};

function escapeHtml(str) {
  return String(str ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Trata null explicitamente. A versão anterior chamava .slice() direto e
// quebrava a aba inteira quando `sync_state.last_run_at` era null — o que
// acontece de verdade, porque o watermark só avança em execução íntegra.
function _formatarData(iso) {
  if (!iso || typeof iso !== 'string') return 'nunca';
  const [ano, mes, dia] = iso.slice(0, 10).split('-');
  if (!ano || !mes || !dia) return 'nunca';
  return `${dia}/${mes}/${ano}`;
}

const pct = (parte, total) => (total > 0 ? Math.round((parte / total) * 100) : 0);

// Barra de cobertura. Cor é semântica e separada do acento da interface:
// abaixo de 40% é problema, 40–79% é parcial, 80%+ é utilizável.
function _barra(rotulo, parte, total, nota) {
  const p = pct(parte, total);
  const cor = p >= 80 ? 'var(--green)' : p >= 40 ? 'var(--amber)' : 'var(--red)';
  return `
    <div style="margin-bottom:12px">
      <div style="display:flex;justify-content:space-between;align-items:baseline;gap:10px;margin-bottom:4px">
        <span style="font-size:13px;font-weight:500">${escapeHtml(rotulo)}</span>
        <span class="mono-sm" style="color:var(--muted);font-variant-numeric:tabular-nums">${parte.toLocaleString('pt-BR')} de ${total.toLocaleString('pt-BR')} · ${p}%</span>
      </div>
      <div style="height:6px;background:var(--surface2);border-radius:3px;overflow:hidden">
        <div style="height:100%;width:${p}%;background:${cor};border-radius:3px"></div>
      </div>
      ${nota ? `<div class="mono-sm" style="color:var(--dim);margin-top:4px;line-height:1.45">${escapeHtml(nota)}</div>` : ''}
    </div>`;
}

function _semBackend(oque) {
  return `<div class="mono-sm" style="color:var(--dim);line-height:1.5">${escapeHtml(oque)} depende do backend real. No modo mock esta seção fica vazia de propósito — fabricar números aqui mostraria uma auditoria que não existe.</div>`;
}

// ---------------------------------------------------------------------------
function _renderFontes(porFonte) {
  if (porFonte.length === 0) {
    return '<div class="mono-sm" style="color:var(--dim)">Nenhuma fonte com execução registrada.</div>';
  }
  return porFonte.map((f) => `
    <div class="rel-card" style="cursor:default">
      <div>
        <div class="rel-title"><i class="ti ti-database"></i> ${FONTE_LABEL[f.fonte] ?? escapeHtml(f.fonte)}${f.objeto ? ` <span class="mono-sm" style="color:var(--dim);font-weight:400">${escapeHtml(f.objeto)}</span>` : ''}</div>
        <div class="rel-sub">${Number(f.totalLeads ?? 0).toLocaleString('pt-BR')} registro${Number(f.totalLeads) === 1 ? '' : 's'} na última execução íntegra</div>
      </div>
      <div class="rel-val mono-sm" style="font-weight:400;color:var(--muted)">${_formatarData(f.ultimaAtividadeObservada)}</div>
    </div>`).join('');
}

function _renderLacunas(lacunas) {
  if (lacunas.length === 0) {
    return '<div class="empty-state"><div class="es-title">Nenhuma lacuna declarada</div><div>Nenhuma execução de ingestão recente terminou com status parcial ou falho.</div></div>';
  }
  return lacunas.map((l) => `
    <div class="rel-card" style="cursor:default;align-items:flex-start">
      <div>
        <div class="rel-title"><i class="ti ti-alert-triangle" style="color:var(--amber)"></i> ${FONTE_LABEL[l.fonte] ?? escapeHtml(l.fonte)}</div>
        <div class="rel-sub">${escapeHtml(l.titulo)}${l.leadNome ? ` — lead: ${escapeHtml(l.leadNome)}` : ''}</div>
        <div class="tl-idade" style="margin-top:4px">⚠️ ${escapeHtml(l.idade_dado_declarada)}</div>
        <div class="mono-sm" style="color:var(--muted);margin-top:4px">Execução de ${_formatarData(l.ultimoEventoValidoTimestamp)}</div>
      </div>
    </div>`).join('');
}

function _renderCobertura(q) {
  if (!q?.cobertura) return _semBackend('A cobertura dos campos de filtro');
  const c = q.cobertura;
  const base = Number(c.leads_visiveis ?? 0);
  return `
    <div style="max-width:640px">
      ${_barra('Tags', Number(c.com_tags ?? 0), base, 'Único campo multivalor da fonte — a dimensão de maior cobertura da base.')}
      ${_barra('Cargo', Number(c.com_cargo ?? 0), base, 'Texto livre, agrupado por tabela de regra em cargo_grupo.')}
      ${_barra('Atendido por', Number(c.com_atendente ?? 0), base, 'Lista fechada de 12 pessoas — recorte por SDR/consultor.')}
      ${_barra('Tamanho de empresa', Number(c.com_tamanho ?? 0), base, 'Texto livre com escalas conflitantes; colapsado em 3 faixas. Cobertura baixa: o filtro existe, mas fala de uma minoria dos leads.')}
    </div>
    <div class="mono-sm" style="color:var(--dim);margin-top:6px;line-height:1.5">
      Base: ${base.toLocaleString('pt-BR')} leads visíveis (de ${Number(c.leads_total ?? 0).toLocaleString('pt-BR')} no banco;
      ${Number(c.leads_marcados_teste ?? 0).toLocaleString('pt-BR')} marcados como teste e excluídos por padrão).
    </div>`;
}

function _renderTeste(q) {
  if (!q?.regras_teste) return _semBackend('A auditoria de exclusão de dado de teste');
  const regras = q.regras_teste;
  const total = regras.reduce((s, r) => s + Number(r.leads ?? 0), 0);

  const linhas = regras.map((r) => `
    <tr>
      <td>
        <div style="font-weight:600">${escapeHtml(r.regra)}${r.ativa ? '' : ' <span class="mono-sm" style="color:var(--dim)">(inativa)</span>'}</div>
        <div class="t-sub" style="line-height:1.45">${escapeHtml(r.motivo)}</div>
      </td>
      <td class="mono-sm">${escapeHtml(r.campo)}</td>
      <td class="mono-sm" style="max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${escapeHtml(r.padrao)}">${escapeHtml(r.padrao)}</td>
      <td class="mono-sm" style="text-align:right;font-variant-numeric:tabular-nums;font-weight:600">${Number(r.leads ?? 0).toLocaleString('pt-BR')}</td>
    </tr>`).join('');

  const orfaos = Number(q.marcados_sem_regra ?? 0);

  return `
    <div style="overflow-x:auto">
      <table class="tbl">
        <thead><tr><th>Regra</th><th>Campo</th><th>Padrão</th><th style="text-align:right">Leads</th></tr></thead>
        <tbody>${linhas}</tbody>
      </table>
    </div>
    <div class="mono-sm" style="color:var(--dim);margin-top:10px;line-height:1.5">
      ${total.toLocaleString('pt-BR')} lead(s) marcados como teste. Eles <strong>não são deletados</strong> — ficam no banco
      com a regra que os pegou e saem dos filtros por padrão. Regra com 0 leads também é informação:
      ou o padrão está errado, ou o problema que ela cobre parou de ocorrer.
    </div>
    ${orfaos > 0
      ? `<div class="tl-idade" style="margin-top:8px">⚠️ ${orfaos} lead(s) marcados como teste <strong>sem regra registrada</strong>. Isso não deveria acontecer pelo caminho normal de ingestão — indica marcação feita à mão.</div>`
      : ''}`;
}

function _renderSemRegra(q) {
  if (!q) return _semBackend('A lista de valores sem regra');
  const cargos = q.cargos_sem_regra ?? [];
  const tamanhos = q.tamanhos_nao_lidos ?? [];

  if (cargos.length === 0 && tamanhos.length === 0) {
    return '<div class="empty-state"><div class="es-title">Todos os valores preenchidos estão classificados</div><div>Nenhum cargo caiu em "sem regra" e nenhum tamanho de empresa ficou ilegível.</div></div>';
  }

  const bloco = (titulo, itens, campoValor, nota) => itens.length === 0 ? '' : `
    <div style="margin-bottom:16px">
      <div style="font-size:13px;font-weight:600;margin-bottom:2px">${escapeHtml(titulo)}</div>
      <div class="mono-sm" style="color:var(--dim);margin-bottom:8px;line-height:1.45">${escapeHtml(nota)}</div>
      <div style="display:flex;flex-wrap:wrap;gap:6px">
        ${itens.map((i) => `<span class="mono-sm" style="display:inline-flex;align-items:center;gap:6px;background:var(--surface2);border:1px solid var(--border2);padding:3px 8px;border-radius:5px">
          <span style="max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${escapeHtml(i[campoValor])}">${escapeHtml(i[campoValor])}</span>
          <span style="color:var(--dim);font-variant-numeric:tabular-nums">${Number(i.leads ?? 0)}</span>
        </span>`).join('')}
      </div>
    </div>`;

  return `
    ${bloco('Cargos sem regra de agrupamento', cargos, 'cargo',
      'Cada um destes vai para o grupo "Sem regra" no filtro de cargo. A cauda com 1 lead cada fica assim de propósito: escrever regra a partir de um único caso seria inventar taxonomia. Valor que aparecer com volume merece regra nova.')}
    ${bloco('Tamanhos de empresa preenchidos e ilegíveis', tamanhos, 'valor',
      'O lead informou algo que a normalização não consegue mapear nas 3 faixas. Distinto de "não informou" — aqui o dado existe e a falha de leitura é nossa.')}`;
}

// Rótulos dos estados de atribuição que conhecemos. A LISTA DE ESTADOS vem do
// backend (`atribuicao.estados`, agrupado dinamicamente) — este mapa só
// traduz. Status desconhecido é mostrado com o valor cru: visível e feio é
// melhor que invisível, e foi justamente uma enumeração no código que fez
// `ok_plano` sumir da tela quando ele nasceu.
const ROTULO_ATRIB = {
  ok:         { rotulo: 'Sessão decodificada', cor: 'var(--green)',
    nota: 'A fonte mandou traffic_source no formato de sessão (base64) e lemos primeiro e último toque.' },
  ok_plano:   { rotulo: 'Mídia paga (formato plano)', cor: 'var(--blue)',
    nota: 'traffic_source veio como string simples (ex.: "facebook") com traffic_medium/campaign ao lado — conversões de Lead Ads. Não tem histórico de sessão, mas tem a atribuição paga, que é a que sustenta ROI.' },
  ausente:    { rotulo: 'Ausente na fonte', cor: 'var(--muted)',
    nota: 'O RD Station não enviou traffic_source neste evento. Limitação da origem — não há correção do nosso lado.' },
  ilegivel:   { rotulo: 'Ilegível', cor: 'var(--red)',
    nota: 'Veio num formato que o nosso coletor não sabe ler. É defeito NOSSO e tem correção — este é o número a vigiar.' },
  nao_medido: { rotulo: 'Não medido', cor: 'var(--amber)',
    nota: 'Evento ingerido antes de a distinção existir. Uma reingestão preenche, sem alterar nenhum outro campo.' },
};

function _renderAtribuicao(q) {
  if (!q?.atribuicao) return _semBackend('A cobertura de atribuição de origem');
  const a = q.atribuicao;
  const total = Number(a.eventos_total ?? 0);
  const estados = Array.isArray(a.estados) ? a.estados : [];

  const barras = estados.map((e) => {
    const n = Number(e.eventos ?? 0);
    if (n === 0) return '';
    const meta = ROTULO_ATRIB[e.status] ?? {
      rotulo: `Status "${e.status}"`, cor: 'var(--purple, var(--muted))',
      nota: 'Status que esta tela ainda não conhece. Aparece cru de propósito — é assim que se descobre que o backend ganhou um estado novo.',
    };
    const p = pct(n, total);
    return `
      <div style="margin-bottom:12px">
        <div style="display:flex;justify-content:space-between;align-items:baseline;gap:10px;margin-bottom:4px">
          <span style="font-size:13px;font-weight:500;display:inline-flex;align-items:center;gap:7px">
            <span style="width:8px;height:8px;border-radius:50%;background:${meta.cor};display:inline-block"></span>${escapeHtml(meta.rotulo)}
          </span>
          <span class="mono-sm" style="color:var(--muted);font-variant-numeric:tabular-nums">${n.toLocaleString('pt-BR')} · ${p}%</span>
        </div>
        <div style="height:6px;background:var(--surface2);border-radius:3px;overflow:hidden">
          <div style="height:100%;width:${p}%;background:${meta.cor};border-radius:3px"></div>
        </div>
        <div class="mono-sm" style="color:var(--dim);margin-top:4px;line-height:1.45">${escapeHtml(meta.nota)}</div>
      </div>`;
  }).join('');

  const ilegivel = Number((estados.find((e) => e.status === 'ilegivel') || {}).eventos ?? 0);
  const semSinal = Number(a.sem_nenhum_sinal ?? 0);

  return `
    <div style="max-width:640px">
      ${barras || '<div class="mono-sm" style="color:var(--dim)">Nenhum evento de conversão ingerido ainda.</div>'}
      <div style="height:1px;background:var(--border2);margin:16px 0"></div>
      ${_barra('Eventos com sinal de campanha (UTM)', Number(a.com_utm ?? 0), total,
        'Único eixo que pode receber investimento e cálculo de ROI. Cobertura baixa não é falha da ferramenta: é conversão chegando sem tagueamento.')}
      ${_barra('Eventos com plataforma identificada', Number(a.com_midia ?? 0), total,
        'De onde o lead veio (Instagram, Facebook…). Vem do formato plano ou de cf_midia.')}
    </div>
    <div class="mono-sm" style="color:var(--dim);margin-top:6px;line-height:1.6">
      ${total.toLocaleString('pt-BR')} eventos de conversão ·
      ${Number(a.sessao_direta ?? 0).toLocaleString('pt-BR')} com sessão direta <code>(none)</code> ·
      ${Number(a.com_gclid ?? 0).toLocaleString('pt-BR')} com <code>gclid</code> (clique pago no Google) ·
      <strong>${semSinal.toLocaleString('pt-BR')} sem nenhum sinal de origem</strong> (nem sessão, nem UTM, nem plataforma).
    </div>
    ${ilegivel > 0
      ? `<div class="tl-idade" style="margin-top:10px">⚠️ ${ilegivel.toLocaleString('pt-BR')} evento(s) num formato que o coletor não sabe ler. É defeito nosso, não da fonte — foi assim que se descobriu que o RD Station usa dois formatos de <code>traffic_source</code>, e o segundo (Lead Ads) estava sendo descartado.</div>`
      : ''}`;
}

/** Ponto de entrada — chamado quando a view é exibida (ver bootstrap). */
export async function renderViewQualidadeDados() {
  const set = (id, html) => { const el = document.getElementById(id); if (el) el.innerHTML = html; };
  const txt = (id, v) => { const el = document.getElementById(id); if (el) el.textContent = v; };

  let dados;
  try {
    dados = await obterQualidadeDados();
  } catch (e) {
    // Esta aba é justamente onde se olha quando algo está quebrado, então ela
    // não pode falhar em silêncio nem sumir.
    set('qd-fontes-grid', `<div class="tl-idade">⚠️ Falha ao carregar o status: ${escapeHtml(e.message)}</div>`);
    txt('qd-fontes-count', '—');
    return;
  }

  const { porFonte = [], lacunas = [], qualidade = null } = dados;

  txt('qd-fontes-count', porFonte.length);
  set('qd-fontes-grid', _renderFontes(porFonte));

  txt('qd-lacunas-count', lacunas.length);
  set('qd-lacunas-list', _renderLacunas(lacunas));

  const cob = qualidade?.cobertura;
  txt('qd-cob-badge', cob ? `${Number(cob.leads_visiveis ?? 0).toLocaleString('pt-BR')} leads` : '—');
  set('qd-cobertura', _renderCobertura(qualidade));

  const nTeste = (qualidade?.regras_teste ?? []).reduce((s, r) => s + Number(r.leads ?? 0), 0);
  txt('qd-teste-badge', qualidade?.regras_teste ? `${nTeste} excluídos` : '—');
  set('qd-teste', _renderTeste(qualidade));

  const nSemRegra = (qualidade?.cargos_sem_regra ?? []).length + (qualidade?.tamanhos_nao_lidos ?? []).length;
  txt('qd-semregra-badge', qualidade ? `${nSemRegra} valor(es)` : '—');
  set('qd-semregra', _renderSemRegra(qualidade));

  const at = qualidade?.atribuicao;
  txt('qd-atrib-badge', at ? `${Number(at.eventos_total ?? 0).toLocaleString('pt-BR')} eventos` : '—');
  set('qd-atribuicao', _renderAtribuicao(qualidade));
}
