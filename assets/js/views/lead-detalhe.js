// assets/js/views/lead-detalhe.js — subtask 5.10: ficha lead 360 em três
// blocos (Overview/Activity/Related) como superfície endereçável e
// retomável (?lead=<id>), sem modal de rolagem confinada — o painel vive
// na própria página, ao lado da lista (ver #crm-panel em index.html).

import { buscarLead } from '../data-api.js';
import { renderBadge, renderRazao, renderVinculoIdentidade } from '../attribution.js';
import { atualizarEstado, lerEstadoAtual } from '../url-state.js';

const FONTE_CLASSE = { salesforce: 'src-sf', rd_station: 'src-rd' };

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function _formatarDataHora(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  return d.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// Só o dia, para eventos de granularidade 'dia' (CON-3). Exibir hora neles
// daria falsa precisão: a fonte não sabe a hora.
function _formatarData(iso) {
  if (!iso) return null;
  return new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

const ROTULO_VALOR = {
  c_level: 'C-level', diretoria: 'Diretoria', gerencia: 'Gerência',
  coordenacao: 'Coordenação', analista: 'Analista', consultor: 'Consultor/Especialista',
  operacional: 'Operacional', outro_declarado: 'Outro (declarado)',
  area_declarada: 'Área declarada', outros: 'Sem regra de cargo',
  nao_informado: 'Não informado',
  pequena: 'Pequena (1–99)', media: 'Média (100–999)', grande: 'Grande (1.000+)',
};
const rot = (v) => (v == null ? '—' : (ROTULO_VALOR[v] ?? v));

function _tags(tags) {
  if (!tags || tags.length === 0) return '—';
  return tags.map((t) => `<span class="mono-sm" style="background:var(--surface2);color:var(--muted);padding:1px 6px;border-radius:4px;margin:0 3px 3px 0;display:inline-block">${escapeHtml(t)}</span>`).join('');
}

// Sessão de origem em forma legível. `(none)` significa acesso direto — a
// fonte diz isso explicitamente, e traduzir para "—" perderia a diferença
// entre "veio direto" e "não sabemos".
function _toque(valor) {
  if (!valor) return '—';
  if (valor === '(none)') return '<span title="A fonte informou explicitamente que não houve sessão de origem">direto, sem sessão</span>';
  if (valor.startsWith('http')) return `<span class="mono-sm" title="${escapeHtml(valor)}">${escapeHtml(valor.slice(0, 46))}${valor.length > 46 ? '…' : ''}</span>`;
  return `<span class="mono-sm" title="${escapeHtml(valor)}">${escapeHtml(valor.slice(0, 46))}${valor.length > 46 ? '…' : ''}</span>`;
}

function _renderOverview(detalhe) {
  const ov = detalhe.overview;
  const temEixoB = ov.campanha_midia || ov.plataforma;

  return `
    ${detalhe._seed_nota ? `<div class="attr-vinculo" style="margin-bottom:12px"><span>ℹ️</span><span>${escapeHtml(detalhe._seed_nota)}</span></div>` : ''}
    ${ov.is_teste ? `<div class="tl-idade" style="margin-bottom:12px">⚠️ Marcado como <strong>dado de teste</strong>${ov.teste_regra ? ` pela regra "${escapeHtml(ov.teste_regra)}"` : ''}. Fica fora dos filtros por padrão — não é deletado.</div>` : ''}
    <div class="attr-box">${renderRazao(ov.atribuicao)}</div>
    ${renderVinculoIdentidade(ov.vinculo_identidade)}

    <div class="field-grid" style="margin-top:14px">
      <div class="field"><div class="field-label">Empresa</div><div class="field-val">${ov.empresa ? escapeHtml(ov.empresa) : '—'}</div></div>
      <div class="field"><div class="field-label">Estágio do funil</div><div class="field-val">${ov.estagio_funil ? escapeHtml(ov.estagio_funil) : '—'}</div></div>
      <div class="field"><div class="field-label">Cargo</div><div class="field-val">${ov.cargo ? escapeHtml(ov.cargo) : '—'}${ov.cargo_grupo ? ` <span class="mono-sm" style="color:var(--muted)">· ${escapeHtml(rot(ov.cargo_grupo))}</span>` : ''}</div></div>
      <div class="field"><div class="field-label">Tamanho da empresa</div><div class="field-val">${rot(ov.tamanho_empresa)}${ov.tamanho_empresa_bruto ? ` <span class="mono-sm" style="color:var(--dim)" title="Valor cru como a fonte mandou">(${escapeHtml(ov.tamanho_empresa_bruto)})</span>` : ''}</div></div>
      <div class="field"><div class="field-label">Atendido por</div><div class="field-val">${ov.atendido_por ? escapeHtml(ov.atendido_por) : '—'}</div></div>
      <div class="field"><div class="field-label">E-mail</div><div class="field-val mono-sm">${ov.email ? escapeHtml(ov.email) : '—'}</div></div>
      <div class="field"><div class="field-label">Telefone</div><div class="field-val mono-sm">${ov.telefone ? escapeHtml(ov.telefone) : '—'}</div></div>
      <div class="field"><div class="field-label">Trimestre</div><div class="field-val">${ov.trimestre ? escapeHtml(ov.trimestre) : '—'}</div></div>
    </div>

    <div class="field" style="margin-top:12px"><div class="field-label">Tags</div><div class="field-val">${_tags(ov.tags)}</div></div>

    <!-- Os dois eixos, separados na tela porque são separados no contrato
         (§1.2). Só o eixo B pode receber investimento e ROI; misturá-los
         produziria ROI sobre campanha sem custo. -->
    <div style="margin-top:16px;padding:12px;border:1px solid var(--border2);border-left:3px solid var(--blue);border-radius:0 8px 8px 0;background:var(--surface2)">
      <div style="font-size:12px;font-weight:600;margin-bottom:8px">O que trouxe este lead <span class="mono-sm" style="font-weight:400;color:var(--dim)">nunca recebe investimento</span></div>
      <div class="field-grid">
        <div class="field"><div class="field-label">Conversões</div><div class="field-val" style="font-variant-numeric:tabular-nums">${ov.qtd_conversoes}${ov.qtd_origens > 1 ? ` <span class="mono-sm" style="color:var(--muted)">em ${ov.qtd_origens} origens</span>` : ''}</div></div>
        <div class="field"><div class="field-label">Primeira origem</div><div class="field-val">${ov.origem_primeira_conversao ? escapeHtml(ov.origem_primeira_conversao) : '—'}</div></div>
        <div class="field"><div class="field-label">Última origem</div><div class="field-val">${ov.origem_ultima_conversao ? escapeHtml(ov.origem_ultima_conversao) : '—'}</div></div>
      </div>
      ${ov.origens_conversao.length > 1 ? `<div class="mono-sm" style="color:var(--dim);margin-top:6px;line-height:1.5">Todas: ${ov.origens_conversao.map(escapeHtml).join(' · ')}</div>` : ''}
    </div>

    <div style="margin-top:10px;padding:12px;border:1px solid var(--border2);border-left:3px solid ${temEixoB ? 'var(--green)' : 'var(--border2)'};border-radius:0 8px 8px 0;background:var(--surface2)">
      <div style="font-size:12px;font-weight:600;margin-bottom:8px">Anúncio que pagou por este lead <span class="mono-sm" style="font-weight:400;color:var(--dim)">único eixo com ROI</span></div>
      ${temEixoB ? `
      <div class="field-grid">
        <div class="field"><div class="field-label">Campanha</div><div class="field-val">${ov.campanha_midia ? escapeHtml(ov.campanha_midia) : '—'}</div></div>
        <div class="field"><div class="field-label">Plataforma</div><div class="field-val">${ov.plataforma ? escapeHtml(ov.plataforma) : '—'}${ov.tem_gclid ? ' <span class="mono-sm" style="color:var(--green)" title="Presença de gclid prova clique pago no Google">· gclid</span>' : ''}</div></div>
      </div>
      ${(ov.campanha_midia_bruta && ov.campanha_midia_bruta !== ov.campanha_midia) || (ov.plataforma_bruta && ov.plataforma_bruta !== ov.plataforma)
        ? `<div class="mono-sm" style="color:var(--dim);margin-top:6px;line-height:1.5">Valor cru da fonte: ${escapeHtml(ov.campanha_midia_bruta ?? '—')} / ${escapeHtml((ov.plataforma_bruta ?? '—').slice(0, 50))}</div>`
        : ''}`
      : `<div class="mono-sm" style="color:var(--dim);line-height:1.5">Sem sinal de mídia paga neste lead. Não é falha da ferramenta: a conversão chegou sem tagueamento de UTM, o que acontece na maioria dos leads da base.</div>`}
    </div>

    <div class="field-grid" style="margin-top:12px">
      <div class="field"><div class="field-label">Primeiro toque</div><div class="field-val">${_toque(ov.primeiro_toque)}</div></div>
      <div class="field"><div class="field-label">Último toque</div><div class="field-val">${_toque(ov.ultimo_toque)}</div></div>
    </div>
  `;
}

function _renderJornada(detalhe) {
  const atividades = detalhe.activity ?? [];
  if (atividades.length === 0) {
    return '<div class="empty-state"><div class="es-title">Sem eventos registrados</div><div>Nenhuma atividade encontrada para este lead nas fontes conectadas.</div></div>';
  }

  const conversoes = atividades.filter((a) => a.tipo === 'conversao').length;
  const temGranularidadeDia = atividades.some((a) => a.granularidade === 'dia');

  // Cargo e tamanho de empresa do evento ANTERIOR, para detectar mudança.
  // É o achado que justifica a firmografia ser gravada por evento: no dado
  // real o mesmo lead aparece como `Diretor` numa conversão e
  // `CEO, Founder, Sócio` noutra. Mostrar só o valor atual esconderia isso.
  let cargoAnterior = null;
  let tamanhoAnterior = null;

  const itens = atividades
    .map((a) => {
      const dotClasse = a.idade_dado_declarada ? 'src-indisponivel' : (FONTE_CLASSE[a.fonte] ?? '');

      // CON-3/EC-10: granularidade 'dia' significa que a fonte só atualiza
      // uma vez ao dia. A ordem entre dois eventos 'dia' no mesmo dia NÃO é
      // significativa, e a tela precisa dizer isso em vez de exibir uma hora
      // que dá falsa precisão.
      const rotuloData = !a.timestamp
        ? `<span class="tl-time" style="color:var(--amber)" title="Data não rastreável">data não rastreável</span>`
        : a.granularidade === 'dia'
          ? `<span class="tl-time" title="A fonte só informa o dia — a hora não é significativa">${_formatarData(a.timestamp)} <span class="mono-sm" style="opacity:.6">(dia)</span></span>`
          : `<span class="tl-time">${_formatarDataHora(a.timestamp)}</span>`;

      // Contexto só existe em conversão; nos outros ramos vem null.
      const ctx = [];
      if (a.campanha_midia) ctx.push(`<span title="Campanha de mídia paga"><i class="ti ti-currency-dollar" style="font-size:11px"></i> ${escapeHtml(a.campanha_midia)}</span>`);
      if (a.plataforma) ctx.push(`<span title="Plataforma de origem"><i class="ti ti-speakerphone" style="font-size:11px"></i> ${escapeHtml(a.plataforma)}</span>`);
      // O anúncio que pagou por esta conversão (migration 086). É o que liga a
      // pessoa ao criativo na aba de Criativos — sem ele, "veio do Facebook" é
      // tudo o que se sabe.
      if (a.criativo) ctx.push(`<span title="Criativo do anúncio"><i class="ti ti-photo" style="font-size:11px"></i> ${escapeHtml(a.criativo)}</span>`);
      if (a.publico) ctx.push(`<span title="Público/segmentação do anúncio"><i class="ti ti-users" style="font-size:11px"></i> ${escapeHtml(a.publico)}</span>`);
      if (a.id_anuncio) ctx.push(`<span title="ID do anúncio na plataforma — clique para copiar" data-copiar="${escapeHtml(a.id_anuncio)}" style="cursor:pointer;border-bottom:1px dotted var(--dim)"><i class="ti ti-hash" style="font-size:11px"></i> ${escapeHtml(a.id_anuncio)}</span>`);
      if (a.cargo_no_evento) {
        const mudou = cargoAnterior !== null && cargoAnterior !== a.cargo_no_evento;
        ctx.push(`<span${mudou ? ' style="color:var(--amber);font-weight:600" title="O cargo informado MUDOU em relação à conversão anterior — a firmografia é gravada por evento justamente para mostrar isso"' : ' title="Cargo informado nesta conversão"'}><i class="ti ti-briefcase" style="font-size:11px"></i> ${escapeHtml(a.cargo_no_evento)}${mudou ? ' ⟵ mudou' : ''}</span>`);
      }
      if (a.tamanho_no_evento && a.tamanho_no_evento !== 'nao_informado') {
        const mudou = tamanhoAnterior !== null && tamanhoAnterior !== a.tamanho_no_evento;
        ctx.push(`<span${mudou ? ' style="color:var(--amber);font-weight:600" title="O tamanho de empresa informado MUDOU em relação à conversão anterior"' : ''}><i class="ti ti-building" style="font-size:11px"></i> ${escapeHtml(rot(a.tamanho_no_evento))}${mudou ? ' ⟵ mudou' : ''}</span>`);
      }
      if (a.atribuicao_status === 'ilegivel') {
        ctx.push(`<span style="color:var(--red)" title="A fonte mandou traffic_source num formato que o coletor não sabe ler. É defeito nosso, não da fonte."><i class="ti ti-alert-triangle" style="font-size:11px"></i> atribuição ilegível</span>`);
      }

      if (a.cargo_no_evento) cargoAnterior = a.cargo_no_evento;
      if (a.tamanho_no_evento && a.tamanho_no_evento !== 'nao_informado') tamanhoAnterior = a.tamanho_no_evento;

      return `
        <div class="tl-item">
          <div class="tl-dot ${dotClasse}"></div>
          ${rotuloData}
          <div class="tl-title">${escapeHtml(a.titulo)}</div>
          <div class="tl-desc">${escapeHtml(a.descricao)}</div>
          ${ctx.length ? `<div class="mono-sm" style="display:flex;flex-wrap:wrap;gap:10px;margin-top:5px;color:var(--muted);line-height:1.5">${ctx.join('')}</div>` : ''}
          <span class="tl-src">${escapeHtml(a.fonte)}</span>
          ${a.idade_dado_declarada ? `<div class="tl-idade">⚠️ ${escapeHtml(a.idade_dado_declarada)}</div>` : ''}
        </div>`;
    })
    .join('');

  const resumo = `<div class="mono-sm" style="color:var(--dim);margin-bottom:10px;line-height:1.5">
    ${atividades.length} evento(s) · ${conversoes} conversão(ões)${temGranularidadeDia ? ' · eventos marcados <strong>(dia)</strong> não têm ordem intradiária significativa: a fonte só atualiza uma vez ao dia' : ''}
  </div>`;

  return resumo + `<div class="crm-timeline">${itens}</div>`;
}

// Desfecho comercial no TOPO da ficha. Antes vivia dentro da terceira aba, e
// mostrava apenas `oportunidades[0]` com o stage_name cru — um dos 29 valores
// literais do Salesforce. Metade do modelo mental do usuário estava a dois
// cliques de distância.
const FASE_ROTULO_F = {
  contato: 'Contato', qualificacao: 'Qualificação', reuniao: 'Reunião',
  negociacao: 'Negociação', ganho: 'Ganho', perdido: 'Perdido',
};
const FASE_COR_F = {
  contato: 'var(--dim)', qualificacao: 'var(--blue)', reuniao: 'var(--purple)',
  negociacao: 'var(--amber)', ganho: 'var(--green)', perdido: 'var(--red)',
};
const FASE_ORDEM_F = { contato: 1, qualificacao: 2, reuniao: 3, negociacao: 4, ganho: 5, perdido: 5 };

function _renderDesfecho(detalhe) {
  const opps = detalhe.related?.oportunidades ?? [];
  const conta = detalhe.related?.conta;

  if (!opps.length) {
    return `<div style="background:var(--surface2);border-radius:9px;padding:12px 14px">
      <div class="mono-sm" style="color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-size:10.5px;margin-bottom:5px">Desfecho comercial</div>
      <div style="font-size:13px;color:var(--muted)">${conta
        ? `Virou a conta <strong style="color:var(--text)">${escapeHtml(conta.nome ?? '—')}</strong>, ainda sem oportunidade registrada.`
        : 'Ainda não virou conta nem oportunidade no Salesforce.'}</div>
    </div>`;
  }

  // TODAS as oportunidades, não `oportunidades[0]`. Uma pessoa com 7
  // oportunidades tinha 6 invisíveis.
  const comFase = opps.map((o) => ({ ...o, fase: o.fase_comercial ?? null }));
  const maisAvancada = comFase.reduce((melhor, o) => {
    const ord = FASE_ORDEM_F[o.fase] ?? 0;
    const ganhou = o.fase === 'ganho';
    if (!melhor) return { ...o, _ord: ord, _ganhou: ganhou };
    if (ganhou && !melhor._ganhou) return { ...o, _ord: ord, _ganhou: ganhou };
    if (!melhor._ganhou && ord > melhor._ord) return { ...o, _ord: ord, _ganhou: ganhou };
    return melhor;
  }, null);

  const cor = FASE_COR_F[maisAvancada?.fase] ?? 'var(--muted)';
  const ord = FASE_ORDEM_F[maisAvancada?.fase] ?? 0;
  const barra = [1, 2, 3, 4, 5]
    .map((i) => `<span style="flex:1;height:6px;border-radius:2px;background:${i <= ord ? cor : 'var(--surface)'}"></span>`)
    .join('');

  const ganhas = comFase.filter((o) => o.fase === 'ganho').length;
  const perdidas = comFase.filter((o) => o.fase === 'perdido').length;

  const linhas = comFase.map((o) => {
    const c = FASE_COR_F[o.fase] ?? 'var(--muted)';
    // Valor de contrato: as DUAS bases, rotuladas. Qual sustenta receita é
    // decisão de negócio em aberto (migrations 073/080) — a tela não escolhe.
    const vals = [];
    if (o.mrr != null) vals.push(`MRR ${Number(o.mrr).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })}`);
    if (o.amount != null) vals.push(`Amount ${Number(o.amount).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })}`);
    return `<div style="display:flex;gap:8px;align-items:baseline;padding:5px 0;border-top:1px solid var(--border)">
      <span style="width:6px;height:6px;border-radius:50%;background:${c};flex:none"></span>
      <div style="flex:1;min-width:0">
        <div style="font-size:12.5px">${escapeHtml(o.stage_name ?? '—')}
          ${o.record_type_name ? `<span class="mono-sm" style="color:var(--dim)"> · ${escapeHtml(o.record_type_name)}</span>` : ''}</div>
        ${vals.length ? `<div class="mono-sm" style="color:var(--muted)">${vals.join(' · ')}</div>` : ''}
      </div>
    </div>`;
  }).join('');

  return `<div style="background:var(--surface2);border-radius:9px;padding:12px 14px">
    <div class="mono-sm" style="color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-size:10.5px;margin-bottom:7px">Desfecho comercial</div>
    <div style="display:flex;gap:3px;margin-bottom:6px">${barra}</div>
    <div style="display:flex;align-items:baseline;gap:8px;margin-bottom:4px">
      <strong style="color:${cor};font-size:14px">${FASE_ROTULO_F[maisAvancada?.fase] ?? 'sem fase mapeada'}</strong>
      <span class="mono-sm" style="color:var(--muted)">${opps.length} oportunidade(s)${
        ganhas ? ` · ${ganhas} ganha(s)` : ''}${perdidas ? ` · ${perdidas} perdida(s)` : ''}</span>
    </div>
    ${conta ? `<div class="mono-sm" style="color:var(--muted);margin-bottom:4px"><i class="ti ti-building" style="font-size:11px"></i> ${escapeHtml(conta.nome ?? '')}</div>` : ''}
    ${linhas}
  </div>`;
}

function _renderRelated(detalhe, estado) {
  const rel = detalhe.related;
  const blocos = [];

  if (rel.conta) {
    blocos.push(`
      <div class="rel-card" style="cursor:default">
        <div><div class="rel-title"><i class="ti ti-building"></i> ${escapeHtml(rel.conta.nome)}</div><div class="rel-sub">Conta Salesforce · ${escapeHtml(rel.conta.id)}</div></div>
      </div>`);
  } else {
    blocos.push(`
      <div class="rel-card" style="cursor:default;opacity:.75">
        <div><div class="rel-title"><i class="ti ti-building-off"></i> Sem conta associada</div><div class="rel-sub">Lead ainda não convertido — nenhuma conta Salesforce vinculada.</div></div>
      </div>`);
  }

  if (rel.oportunidade) {
    const o = rel.oportunidade;
    blocos.push(`
      <div class="rel-card" style="cursor:default">
        <div><div class="rel-title"><i class="ti ti-arrow-up-right"></i> ${escapeHtml(o.estagio)}</div><div class="rel-sub">Oportunidade · ${escapeHtml(o.id)}</div></div>
        <div class="rel-val">R$ ${Number(o.mrr).toLocaleString('pt-BR')}${o.valor_contrato !== null ? ` <span class="mono-sm" style="font-weight:400;color:var(--muted)">(contrato: R$ ${Number(o.valor_contrato).toLocaleString('pt-BR')})</span>` : ''}</div>
      </div>`);
  } else {
    blocos.push(`
      <div class="rel-card" style="cursor:default;opacity:.75">
        <div><div class="rel-title"><i class="ti ti-arrow-up-right"></i> Sem oportunidade</div><div class="rel-sub">Nenhuma oportunidade gerada por este lead até o momento.</div></div>
      </div>`);
  }

  const campanha = rel.cadeia_campanha ? rel.cadeia_campanha.at(-1) : detalhe.overview.atribuicao?.campanha_bruta;
  if (campanha) {
    blocos.push(`
      <div class="rel-card" data-ir-campanha="${escapeHtml(campanha)}">
        <div><div class="rel-title"><i class="ti ti-speakerphone"></i> Ver leads desta campanha</div><div class="rel-sub">${escapeHtml(campanha)}</div></div>
        <i class="ti ti-arrow-right"></i>
      </div>
      ${rel.cadeia_campanha ? `<div class="chain">${rel.cadeia_campanha.map((c) => `<b>${escapeHtml(c)}</b>`).join(' › ')}</div>` : ''}`);
  } else {
    blocos.push(`
      <div class="rel-card" style="cursor:default;opacity:.75">
        <div><div class="rel-title"><i class="ti ti-speakerphone-off"></i> Sem campanha rastreável</div><div class="rel-sub">Motivo: nenhum sinal de origem suficiente para associar este lead a uma campanha (ver Visão geral).</div></div>
      </div>`);
  }

  return blocos.join('');
}

// As abas do painel foram removidas em 2026-09-15 (ver index.html). O seletor
// abaixo não encontra nada e o forEach não itera — mantido explicitamente, com
// esta nota, porque apagar sem explicar faria a próxima pessoa procurar por
// onde as abas sumiram.
document.querySelectorAll('#crm-panel-tabs .meta-tab').forEach((btn) => {
  btn.onclick = () => {};
});

// Copiar o ID do anúncio com um clique: é o valor que se cola na plataforma de
// mídia para achar o criativo. Sem isso, o caminho é selecionar 18 dígitos com
// o mouse.
document.addEventListener('click', (ev) => {
  const alvo = ev.target.closest('[data-copiar]');
  if (!alvo) return;
  navigator.clipboard?.writeText(alvo.dataset.copiar).then(() => {
    const antes = alvo.innerHTML;
    alvo.innerHTML = '<i class="ti ti-check" style="font-size:11px"></i> copiado';
    setTimeout(() => { alvo.innerHTML = antes; }, 1200);
  }).catch(() => {});
});

/**
 * Renderiza a ficha completa do lead no painel lateral. Endereçável via
 * ?lead=<id>: chamado tanto por clique na lista (leads.js) quanto por
 * carregamento direto da URL (renderViewLeadsCrm no bootstrap).
 */
export async function renderPainelLead(leadId, estado) {
  const detalhe = await buscarLead(leadId);
  if (!detalhe) {
    document.getElementById('crm-p-nome').textContent = 'Lead não encontrado';
    document.getElementById('crm-p-url').textContent = `/leads/${leadId}`;
    document.getElementById('crm-view-overview').innerHTML = `<div class="empty-state"><div class="es-title">Não encontrado</div><div>Nenhum lead com id "${escapeHtml(leadId)}" no fixture atual.</div></div>`;
    document.getElementById('crm-view-desfecho').innerHTML = '';
    document.getElementById('crm-view-jornada').innerHTML = '';
    document.getElementById('crm-view-related').innerHTML = '';
    return;
  }

  document.getElementById('crm-p-nome').innerHTML = `${escapeHtml(detalhe.overview.nome)} ${renderBadge(detalhe.overview.atribuicao)}`;
  document.getElementById('crm-p-url').textContent = `/leads/${leadId}`;
  document.getElementById('crm-view-desfecho').innerHTML = _renderDesfecho(detalhe);
  document.getElementById('crm-view-overview').innerHTML = _renderOverview(detalhe);
  document.getElementById('crm-view-jornada').innerHTML = _renderJornada(detalhe);
  document.getElementById('crm-view-related').innerHTML = _renderRelated(detalhe, estado);

  document.querySelectorAll('#crm-view-related [data-ir-campanha]').forEach((btn) => {
    btn.onclick = () => {
      const estadoAtual = lerEstadoAtual();
      const novo = { ...estadoAtual, view: 'leads-crm', campanha: btn.dataset.irCampanha };
      delete novo.lead;
      atualizarEstado(novo);
      import('./leads.js').then((m) => m.renderViewLeadsCrm());
    };
  });
}

/** Reseta o painel para o estado placeholder (nenhum lead selecionado). */
export function limparPainel() {
  document.getElementById('crm-p-nome').textContent = 'Selecione um lead';
  document.getElementById('crm-p-url').textContent = '/leads';
  const d = document.getElementById('crm-view-desfecho');
  if (d) d.innerHTML = '';
  document.getElementById('crm-view-overview').innerHTML = '';
  document.getElementById('crm-view-jornada').innerHTML = '';
  document.getElementById('crm-view-related').innerHTML = '';
}
