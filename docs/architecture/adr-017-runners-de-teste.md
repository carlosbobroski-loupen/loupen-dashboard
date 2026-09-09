# ADR-017: Estratégia de runners de teste sem toolchain no artefato servido

**Status:** Aceito · **Data:** 2026-09-07 (atualizado 2026-09-09) · **Épico:** `epic-crm-lead-intelligence`

## Contexto

`critique-2.json.carryForwardToPlan` deixou aberta a estratégia de runner de testes. A dificuldade é uma restrição que parece proibir testes automatizados por completo:

- **CON-12:** sem build step. O que é servido é HTML/CSS/JS estático, direto do repositório, no GitHub Pages.
- **CON-10:** custo zero, sem toolchain nova.

Um `package.json` na raiz seria o começo do fim dessas duas: introduz `node_modules`, introduz "instalar antes de rodar", e abre a porta para um passo de build entrar por tabela.

Mas três camadas distintas precisam de verificação, e elas têm naturezas diferentes:

1. **Lógica SQL** (atribuição, receita, identidade) — a mais crítica (R14).
2. **JS puro** (estado de filtro na URL, adaptadores de dados) — lógica sem DOM.
3. **Comportamento no navegador** (§6.3) — filtros combinados, navegação, ficha do lead.

## Decisão

**Um runner por camada, escolhido pela natureza da camada — nenhum deles no artefato servido.**

| Camada | Runner | Dependência instalada |
|---|---|---|
| SQL | `psql -v ON_ERROR_STOP=1` | nenhuma (já existe para migrations) |
| JS puro | `node --test` (nativo desde Node 18) | **nenhuma** |
| Navegador | Playwright, isolado em `tests/e2e/` | sim, mas **fora** do artefato |

**SQL:** `psql` com `ON_ERROR_STOP=1` **é** o runner. Exit code 0 = passou; ≠ 0 = falhou. Cada asserção tem um `SELECT` de relatório humano + um bloco `DO $$ ... RAISE EXCEPTION`. Convenção completa em `db/README.md`.

**JS puro:** `node --test tests/js/*.test.mjs` e `node --test tests/contract/*.test.mjs`. Runner nativo do Node, zero instalação. Consequência deliberada e importante: **proibido `ajv`/`zod`/qualquer validador de schema via npm** — o validador de contrato (`tests/contract/fixture-shape.test.mjs`) é escrito à mão contra o JSON Schema. Mais verboso, e é o preço de não ter `package.json` na raiz.

**Navegador:** Playwright, com `package.json` **privado** em `tests/e2e/` (`"private": true`, só `devDependencies`), `node_modules` já coberto pela regra global do `.gitignore`. A fronteira que faz isso ser aceitável sob CON-12: **nada em `index.html`/`assets/js` referencia esse diretório**; o artefato servido não sabe que ele existe. É ferramenta de desenvolvimento no repositório, não dependência do produto.

## Alternativas rejeitadas

**Jest ou Vitest.** Rejeitados: exigem `package.json` + `node_modules` para testar JS que roda sem nenhum dos dois, e trazem transform/config próprios — o começo de um build step. `node --test` cobre o que se precisa (`test`, `describe`, `assert`) sem nada disso.

**Harness caseiro numa página HTML** (uma `tests.html` que roda asserções no navegador e pinta verde/vermelho). Rejeitado: sem exit code, logo inautomatizável em CI; exige um humano abrindo a página e olhando; e reimplementaria mal um *test runner* que o Node já tem de graça. Foi tentador exatamente porque respeitaria CON-12 ao extremo — mas trocaria verificação automatizável por ritual manual.

**Um único runner para tudo.** Rejeitado: forçaria ou instalar toolchain para testar SQL, ou testar navegador sem navegador. As três camadas têm naturezas diferentes; forçar uniformidade custaria mais do que a diversidade custa.

## Consequências

**Positivas:**
- O artefato servido continua sendo HTML/CSS/JS estático — CON-12 intacto, verificável por `grep` (5.19 faz isso).
- SQL e JS puro rodam sem instalar nada: `psql` e `node --test`, e pronto.
- A lógica mais crítica (SQL) tem a rede de segurança mais barata de manter.

**Negativas / limites aceitos:**
- Validação de schema à mão em vez de `ajv` — mais linhas, e um schema complexo ficaria desconfortável. Aceito enquanto o contrato é do tamanho que é.
- Três formas de rodar teste em vez de uma; `db/README.md` e as notas do plano precisam dizer qual é qual, senão vira conhecimento tácito.
- Playwright **precisa** de `npm install` dentro de `tests/e2e/` antes do primeiro uso. É um passo manual documentado, não automático.

## Atualização de 2026-09-09 (armadilha real encontrada)

O comando de verificação que o plano original trazia para os testes de navegador — `npx --yes playwright test` — **não funciona**, e o motivo não é óbvio: o `npx` instala `playwright`/`@playwright/test` num diretório de cache isolado, e um `require()` de dentro de `tests/e2e/*.js` nunca resolve para lá. Reproduzido duas vezes, com nomes de pacote diferentes, sempre `MODULE_NOT_FOUND`.

Foi essa falha que **motivou** o `tests/e2e/package.json` privado desta ADR. O comando que funciona de verdade:

```bash
cd tests/e2e && npm install && npm test
```

Vale registrar porque a tentação natural é concluir que "Playwright não dá sob CON-12" — dá, desde que a dependência viva no diretório de teste e não na raiz.

**Segunda armadilha, no `node --test`:** passar um **diretório** falha nesta versão do Node (v26.4.0) — `node --test tests/contract/` tenta carregar o diretório como módulo e morre com `MODULE_NOT_FOUND`. Usar sempre a forma com glob de arquivos:

```bash
node --test tests/js/*.test.mjs tests/contract/*.test.mjs    # 39/39 passando
```

O erro é enganoso: a saída termina com `✖ tests/contract` e `fail 1`, que parece um teste quebrado, quando na verdade é o runner não tendo encontrado nada para rodar. Os mesmos arquivos passam individualmente.

## Ver também

- `db/README.md` — convenção de asserção SQL e como rodar a suíte inteira
- `tests/e2e/package.json` — a fronteira privada, com o motivo no próprio `description`
- `tests/contract/fixture-shape.test.mjs` — validação de schema à mão, consequência de não ter `ajv`
- ADR-021 (o contrato de dados que esses testes validam, com a mesma suíte para mock e real)
