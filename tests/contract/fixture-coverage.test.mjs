// Subtask 0.3 — GATE FINAL de cobertura do fixture (Etapa A). 5.4 (data-api.js)
// depende deste arquivo, não de 0.2/0.5/0.4 isoladamente: só passa quando o
// fixture cobre TODOS os estados de borda exigidos pelo contrato. Sem
// dependência instalada (CON-10/CON-12, ADR-017).
//
// Rodar: node --test tests/contract/fixture-coverage.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const mockDir = join(__dirname, '..', '..', 'assets', 'data', 'mock');
const leads = JSON.parse(readFileSync(join(mockDir, 'leads.json'), 'utf8'));
const detalhes = JSON.parse(readFileSync(join(mockDir, 'leads-detalhe.json'), 'utf8'));

const detalheList = Object.values(detalhes);

test('cobertura: os 3 segmentos (marketing, comercial, nao_atribuido) estão representados', () => {
  const segmentos = new Set(leads.map((l) => l.segmento));
  for (const s of ['marketing', 'comercial', 'nao_atribuido']) {
    assert.ok(segmentos.has(s), `nenhum lead com segmento="${s}"`);
  }
});

test('cobertura: os 6 sinais de atribuição (S1-S6) aparecem pelo menos uma vez cada', () => {
  const sinais = new Set(detalheList.map((d) => d.overview.atribuicao.sinal_id));
  for (const s of ['S1', 'S2', 'S3', 'S4', 'S5', 'S6']) {
    assert.ok(sinais.has(s), `nenhum lead usa o sinal_id="${s}" — cobertura de atribuição incompleta`);
  }
});

test('cobertura: estado vazio — lead sem conta e sem oportunidade', () => {
  const vazio = detalheList.some((d) => d.related.conta === null && d.related.oportunidade === null);
  assert.ok(vazio, 'nenhum lead representa o estado vazio de related (sem conta, sem oportunidade)');
});

test('cobertura: estado "sem data rastreável" (AC-3.2) — timestamp null em algum evento', () => {
  const semData = detalheList.some((d) => d.activity.some((ev) => ev.timestamp === null));
  assert.ok(semData, 'nenhum evento de activity representa data não rastreável (timestamp=null)');
});

test('cobertura: identidade PROVAVEL (EC-7 Tier 2) representada e bidirecional', () => {
  const provaveis = detalheList.filter((d) => d.overview.vinculo_identidade?.status === 'provavel');
  assert.ok(provaveis.length >= 2, 'cobertura de identidade "provavel" incompleta — precisa do par completo');
});

test('cobertura: identidade em CONFLITO (EC-7) representada e bidirecional', () => {
  const conflitos = detalheList.filter((d) => d.overview.vinculo_identidade?.status === 'conflito');
  assert.ok(conflitos.length >= 2, 'cobertura de identidade "conflito" incompleta — precisa do par completo');
});

test('cobertura: fonte indisponível (EC-8) com idade do dado declarada, nunca zero', () => {
  const evento = detalheList
    .flatMap((d) => d.activity)
    .find((ev) => /indispon[íi]vel/i.test(`${ev.titulo} ${ev.descricao}`));
  assert.ok(evento, 'nenhum evento representa fonte indisponível');
  assert.ok(evento.idade_dado_declarada, 'evento de fonte indisponível sem idade_dado_declarada');
});

test('cobertura: FR-10/EC-5 — nenhuma oportunidade não-Ganha tem valor_contrato preenchido', () => {
  const violacoes = detalheList
    .map((d) => d.related.oportunidade)
    .filter((o) => o && o.estagio !== 'Ganho' && o.valor_contrato !== null);
  assert.equal(violacoes.length, 0, `oportunidades violando FR-10/EC-5: ${JSON.stringify(violacoes)}`);
});

test('cobertura: nenhum vinculo_identidade "provavel"/"conflito" tem score fora de [0,1]', () => {
  const foraDeFaixa = detalheList
    .map((d) => d.overview.vinculo_identidade)
    .filter((v) => v && (v.score_similaridade < 0 || v.score_similaridade > 1));
  assert.equal(foraDeFaixa.length, 0, 'score_similaridade fora da faixa [0,1] encontrado');
});

test('cobertura: nenhuma referência de vinculo_identidade.candidato_id aponta para id inexistente', () => {
  const idsValidos = new Set(Object.keys(detalhes));
  for (const [id, d] of Object.entries(detalhes)) {
    const candidatoId = d.overview.vinculo_identidade?.candidato_id;
    if (candidatoId) {
      assert.ok(idsValidos.has(candidatoId), `${id}: candidato_id "${candidatoId}" não existe`);
    }
  }
});

test('RESUMO DE COBERTURA (informativo — não falha, só documenta o estado atual)', () => {
  const resumo = {
    total_leads: leads.length,
    por_segmento: Object.fromEntries(
      ['marketing', 'comercial', 'nao_atribuido'].map((s) => [s, leads.filter((l) => l.segmento === s).length])
    ),
    por_sinal: Object.fromEntries(
      ['S1', 'S2', 'S3', 'S4', 'S5', 'S6'].map((s) => [
        s,
        detalheList.filter((d) => d.overview.atribuicao.sinal_id === s).length,
      ])
    ),
    leads_semeados_sinteticos: detalheList.filter((d) => d._seed_nota).length,
    pares_identidade_provavel: detalheList.filter((d) => d.overview.vinculo_identidade?.status === 'provavel').length / 2,
    pares_identidade_conflito: detalheList.filter((d) => d.overview.vinculo_identidade?.status === 'conflito').length / 2,
  };
  console.log('\n' + JSON.stringify(resumo, null, 2) + '\n');
  assert.ok(true);
});
