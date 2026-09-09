// Subtask 0.2 (Etapa A) — valida a FORMA do fixture contra o contrato de
// docs/architecture/data-contract.md, sem nenhuma dependência instalada
// (CON-10/CON-12, ADR-017: node --test é o único runner).
//
// PROIBIDO adicionar ajv/zod/qualquer validador de schema via npm aqui —
// isso introduziria package.json. As asserções abaixo são deliberadamente
// escritas à mão, cobrindo só o que o contrato exige.
//
// Rodar: node --test tests/contract/fixture-shape.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const mockDir = join(__dirname, '..', '..', 'assets', 'data', 'mock');

const leads = JSON.parse(readFileSync(join(mockDir, 'leads.json'), 'utf8'));
const detalhes = JSON.parse(readFileSync(join(mockDir, 'leads-detalhe.json'), 'utf8'));

const SEGMENTOS = ['marketing', 'comercial', 'nao_atribuido'];
const SINAIS = ['S1', 'S2', 'S3', 'S4', 'S5', 'S6'];
const CONFIANCAS = ['alta', 'media-alta', 'media', 'n/a'];
const FONTES = ['salesforce', 'rd_station'];
const TIPOS_ATIVIDADE = ['conversao', 'mudanca_estagio', 'criacao_oportunidade', 'participacao_workflow'];

test('leads.json é um array não vazio', () => {
  assert.ok(Array.isArray(leads), 'leads.json deve ser um array');
  assert.ok(leads.length > 0, 'leads.json não pode estar vazio');
});

test('todo item de leads.json tem os campos obrigatórios do contrato §1', () => {
  for (const item of leads) {
    assert.ok(item.id, `item sem id: ${JSON.stringify(item)}`);
    assert.ok(item.nome, `${item.id}: sem nome`);
    assert.ok(SEGMENTOS.includes(item.segmento), `${item.id}: segmento inválido "${item.segmento}"`);
    assert.ok(item.estagio_funil, `${item.id}: sem estagio_funil`);
    assert.ok(item.data_criacao, `${item.id}: sem data_criacao`);
    assert.ok(FONTES.includes(item.fonte_dados), `${item.id}: fonte_dados inválido "${item.fonte_dados}"`);
  }
});

test('todo id de leads.json tem um par em leads-detalhe.json (e vice-versa)', () => {
  const listIds = new Set(leads.map((l) => l.id));
  const detailIds = new Set(Object.keys(detalhes));
  for (const id of listIds) {
    assert.ok(detailIds.has(id), `leads.json tem "${id}" mas leads-detalhe.json não`);
  }
  for (const id of detailIds) {
    assert.ok(listIds.has(id), `leads-detalhe.json tem "${id}" mas leads.json não`);
  }
});

test('todo detalhe tem os três blocos exigidos pelo contrato §2', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    assert.ok(detalhe.overview, `${id}: sem bloco overview`);
    assert.ok(Array.isArray(detalhe.activity), `${id}: activity deve ser array (mesmo que vazio)`);
    assert.ok(detalhe.related, `${id}: sem bloco related`);
  }
});

test('overview.atribuicao respeita o contrato §2.1', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    const a = detalhe.overview.atribuicao;
    assert.ok(a, `${id}: sem overview.atribuicao`);
    assert.ok(SEGMENTOS.includes(a.segmento), `${id}: atribuicao.segmento inválido`);
    assert.ok(a.categoria, `${id}: atribuicao.categoria ausente`);
    assert.ok(SINAIS.includes(a.sinal_id), `${id}: atribuicao.sinal_id inválido "${a.sinal_id}"`);
    assert.ok(CONFIANCAS.includes(a.confianca), `${id}: atribuicao.confianca inválida`);
    assert.ok(
      typeof a.razao_legivel === 'string' && a.razao_legivel.length >= 10,
      `${id}: razao_legivel ausente ou curta demais (NFR-7 exige razão auditável)`
    );
  }
});

test('INVARIANTE I1 (spec.md §3.5): segmento=comercial exige sinal_id=S5', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    const a = detalhe.overview.atribuicao;
    if (a.segmento === 'comercial') {
      assert.equal(a.sinal_id, 'S5', `${id}: segmento=comercial mas sinal_id="${a.sinal_id}" (deveria ser S5 — Comercial nunca é resíduo)`);
    }
  }
});

test('INVARIANTE: segmento=nao_atribuido exige sinal_id=S6', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    const a = detalhe.overview.atribuicao;
    if (a.segmento === 'nao_atribuido') {
      assert.equal(a.sinal_id, 'S6', `${id}: segmento=nao_atribuido mas sinal_id="${a.sinal_id}"`);
    }
  }
});

test('activity: timestamp é ISO válido ou null explícito (AC-3.2), nunca string vazia', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    for (const ev of detalhe.activity) {
      assert.ok(TIPOS_ATIVIDADE.includes(ev.tipo), `${id}: tipo de evento inválido "${ev.tipo}"`);
      assert.ok(FONTES.includes(ev.fonte), `${id}: evento com fonte inválida "${ev.fonte}"`);
      assert.notEqual(ev.timestamp, '', `${id}: timestamp vazio ("") não é permitido — use null explícito`);
      if (ev.timestamp !== null) {
        assert.ok(!Number.isNaN(Date.parse(ev.timestamp)), `${id}: timestamp "${ev.timestamp}" não é ISO 8601 válido`);
      }
    }
  }
});

test('INVARIANTE FR-10/EC-5: valor_contrato só quando oportunidade.estagio="Ganho"', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    const opp = detalhe.related.oportunidade;
    if (opp && opp.estagio !== 'Ganho') {
      assert.equal(opp.valor_contrato, null, `${id}: estagio="${opp.estagio}" (não Ganho) mas valor_contrato="${opp.valor_contrato}" — nunca assumir duração default`);
    }
  }
});

test('related.conta null é aceito explicitamente (lead não convertido, AC-2.2)', () => {
  for (const [id, detalhe] of Object.entries(detalhes)) {
    assert.ok(
      detalhe.related.conta === null || (detalhe.related.conta && detalhe.related.conta.id && detalhe.related.conta.nome),
      `${id}: related.conta malformado — deve ser null ou {id, nome} completo`
    );
  }
});

test('nenhum campo de e-mail/telefone parece dado real não anonimizado (heurística R23)', () => {
  // Checagem só heurística — não substitui revisão humana antes de publicar (subtask 0.5/0.19).
  const suspeitos = [];
  for (const [id, detalhe] of Object.entries(detalhes)) {
    const email = detalhe.overview.email || '';
    const tel = detalhe.overview.telefone || '';
    if (email && !/(exemplo|ficticio|fake|test)/i.test(email)) {
      suspeitos.push(`${id}: e-mail "${email}" não contém marcador de exemplo — confirme que foi anonimizado`);
    }
    if (tel && !/X/i.test(tel)) {
      suspeitos.push(`${id}: telefone "${tel}" não tem dígitos mascarados (X) — confirme que foi anonimizado`);
    }
  }
  assert.equal(suspeitos.length, 0, suspeitos.join('\n'));
});
