// Subtask 5.6 — testes de assets/js/url-state.js. Runner nativo do Node
// (ADR-017), zero dependência instalada, zero build step (CON-12).
//
// Rodar: node --test tests/js/url-state.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { serialize, parse, comoArray } from '../../assets/js/url-state.js';

test('serialize produz query string sem "?" inicial', () => {
  assert.equal(serialize({ view: 'leads' }), 'view=leads');
});

test('round-trip: parse(serialize(x)) === x para valores escalares', () => {
  const estado = { view: 'leads', seg: 'Marketing' };
  assert.deepEqual(parse(serialize(estado)), estado);
});

test('round-trip: array vira chaves repetidas e volta como array', () => {
  const estado = { view: 'leads', segmento: ['marketing', 'comercial'] };
  const serializado = serialize(estado);
  assert.equal(serializado, 'view=leads&segmento=marketing&segmento=comercial');
  assert.deepEqual(parse(serializado), estado);
});

test('parse de query string vazia retorna objeto vazio', () => {
  assert.deepEqual(parse(''), {});
});

test('serialize ignora valores undefined e null', () => {
  const serializado = serialize({ view: 'leads', campanha: undefined, lead: null });
  assert.equal(serializado, 'view=leads');
});

test('AC-1.2 (preservação de filtro ao navegar para a ficha e voltar): estado com view+filtro(2 segmentos)+lead round-trips completo', () => {
  const estado = { view: 'leads', segmento: ['marketing', 'nao_atribuido'], canal: 'meta_ads', lead: 'real-mkt-01' };
  assert.deepEqual(parse(serialize(estado)), estado);
});

test('LIMITAÇÃO CONHECIDA E DOCUMENTADA: array de 1 item vira escalar no round-trip (query string não guarda "era array")', () => {
  const estado = { segmento: ['marketing'] };
  const resultado = parse(serialize(estado));
  assert.equal(resultado.segmento, 'marketing', 'query string não distingue array-de-1 de escalar — isso é esperado, não um bug');
  // Por isso todo consumidor de um campo multi-valor usa comoArray():
  assert.deepEqual(comoArray(resultado.segmento), ['marketing']);
});

test('comoArray() normaliza escalar, array e ausência de valor de forma consistente', () => {
  assert.deepEqual(comoArray('marketing'), ['marketing']);
  assert.deepEqual(comoArray(['marketing', 'comercial']), ['marketing', 'comercial']);
  assert.deepEqual(comoArray(undefined), []);
  assert.deepEqual(comoArray(null), []);
});

test('parse não quebra com query string começando por "?"', () => {
  // lerEstadoAtual() já remove o "?" antes de chamar parse, mas parse
  // sozinho também precisa ser tolerante — URLSearchParams aceita ambos.
  assert.deepEqual(parse('?view=leads'), parse('view=leads'));
});

test('chave repetida em query string malformada não perde valores', () => {
  const r = parse('segmento=marketing&segmento=comercial&segmento=nao_atribuido');
  assert.deepEqual(r.segmento, ['marketing', 'comercial', 'nao_atribuido']);
});
