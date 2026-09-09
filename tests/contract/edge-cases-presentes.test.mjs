// Subtask 0.4 — confirma que os casos difíceis semeados deliberadamente
// (EC-7 Tier 2: provável e conflito; EC-8: fonte indisponível) existem e
// estão consistentes entre si. Sem dependência instalada (CON-10/CON-12).
//
// Rodar: node --test tests/contract/edge-cases-presentes.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const mockDir = join(__dirname, '..', '..', 'assets', 'data', 'mock');
const detalhes = JSON.parse(readFileSync(join(mockDir, 'leads-detalhe.json'), 'utf8'));

test('existe pelo menos um par de identidade PROVAVEL, e as duas pontas se referenciam', () => {
  const provaveis = Object.entries(detalhes).filter(
    ([, d]) => d.overview.vinculo_identidade?.status === 'provavel'
  );
  assert.ok(provaveis.length >= 2, 'precisa de pelo menos 2 leads com vinculo_identidade.status="provavel" (as duas pontas do par)');

  for (const [id, d] of provaveis) {
    const candidatoId = d.overview.vinculo_identidade.candidato_id;
    assert.ok(candidatoId && detalhes[candidatoId], `${id}: candidato_id "${candidatoId}" não existe no fixture`);
    const candidato = detalhes[candidatoId].overview.vinculo_identidade;
    assert.equal(candidato?.status, 'provavel', `${id} <-> ${candidatoId}: os dois lados devem ter status="provavel"`);
    assert.equal(candidato.candidato_id, id, `${id} <-> ${candidatoId}: a referência deve ser bidirecional`);
  }
});

test('existe pelo menos um par de identidade em CONFLITO, e as duas pontas se referenciam', () => {
  const conflitos = Object.entries(detalhes).filter(
    ([, d]) => d.overview.vinculo_identidade?.status === 'conflito'
  );
  assert.ok(conflitos.length >= 2, 'precisa de pelo menos 2 leads com vinculo_identidade.status="conflito"');

  for (const [id, d] of conflitos) {
    const candidatoId = d.overview.vinculo_identidade.candidato_id;
    assert.ok(candidatoId && detalhes[candidatoId], `${id}: candidato_id "${candidatoId}" não existe no fixture`);
    const candidato = detalhes[candidatoId].overview.vinculo_identidade;
    assert.equal(candidato?.status, 'conflito', `${id} <-> ${candidatoId}: os dois lados devem ter status="conflito"`);
  }
});

test('NENHUM vinculo_identidade "provavel" ou "conflito" é tratado como identidade confirmada (nunca há merge automático)', () => {
  // Invariante: se existisse um campo "confirmado" ou similar sem revisão, seria bug de desenho.
  for (const [id, d] of Object.entries(detalhes)) {
    const v = d.overview.vinculo_identidade;
    if (v) {
      assert.notEqual(v.status, 'confirmado', `${id}: vinculo_identidade não deveria nunca ser "confirmado" automaticamente pelo fixture — isso exigiria revisão humana real, não simulação`);
    }
  }
});

test('existe pelo menos um lead sem conta E sem oportunidade (lead não convertido)', () => {
  const semNada = Object.entries(detalhes).filter(
    ([, d]) => d.related.conta === null && d.related.oportunidade === null
  );
  assert.ok(semNada.length >= 1, 'precisa de pelo menos um lead com related.conta=null e related.oportunidade=null');
});

test('existe pelo menos um evento de jornada com timestamp=null (AC-3.2, data não rastreável)', () => {
  const comTimestampNull = Object.values(detalhes).some((d) =>
    d.activity.some((ev) => ev.timestamp === null)
  );
  assert.ok(comTimestampNull, 'nenhum evento de activity tem timestamp=null em todo o fixture — AC-3.2 não está representado');
});

test('existe pelo menos um evento representando fonte indisponível (EC-8), com idade do dado declarada e sem "0"/"zero"', () => {
  const evento = Object.values(detalhes)
    .flatMap((d) => d.activity)
    .find((ev) => /indispon[íi]vel/i.test(ev.titulo || '') || /indispon[íi]vel/i.test(ev.descricao || ''));

  assert.ok(evento, 'nenhum evento de activity menciona fonte indisponível — EC-8 não está representado no fixture');
  assert.ok(evento.idade_dado_declarada, `${JSON.stringify(evento)}: evento de fonte indisponível precisa declarar idade_dado_declarada`);
  assert.doesNotMatch(
    evento.idade_dado_declarada.toLowerCase(),
    /^(0|zero)\b/,
    'idade_dado_declarada não pode começar com "0" ou "zero" — EC-8 proíbe substituir lacuna por zero'
  );
});

test('todo lead com _seed_nota está claramente marcado como sintético (não é dado real)', () => {
  const seeds = Object.entries(detalhes).filter(([, d]) => d._seed_nota);
  assert.ok(seeds.length >= 5, `esperava pelo menos 5 leads semeados (0.4), encontrado ${seeds.length}`);
  for (const [id, d] of seeds) {
    assert.match(d._seed_nota, /SEMEADO/, `${id}: _seed_nota deveria conter a palavra "SEMEADO" para ficar inequívoco`);
  }
});
