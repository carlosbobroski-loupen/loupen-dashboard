# ADR-021: Contrato de dados congelado como costura entre Etapa A e Etapa B

**Status:** Aceito · **Data:** 2026-09-07 · **Épico:** `epic-crm-lead-intelligence`

## Contexto

ADR-020 decidiu inverter o sequenciamento (superfície antes do backend). Isso só é seguro se existir uma fronteira estável entre "o que a interface consome" e "de onde o dado vem" — senão a Etapa A produz uma interface que precisa ser reescrita quando o backend real chegar, o que anularia o ganho da inversão.

`spec.md` §5.1 já previa `assets/js/data-api.js` como "a camada ÚNICA de acesso a dados" — essa decisão não foi criada por esta ADR, foi **antecipada** por ela (D21 não inventa a costura, formaliza-a mais cedo do que o plano original previa).

## Decisão

O contrato de dados (`docs/architecture/data-contract.md` + `docs/architecture/schemas/lead.schema.json`) é escrito e **congelado** antes de qualquer subtask de superfície começar. Ele define:

1. A forma de `GET /api/leads` (lista, filtros combináveis) e `GET /api/leads/{id}` (ficha em três blocos: overview/activity/related).
2. Os campos que só a Etapa B preenche (ex.: `ruleset_version`) entram **nullable** desde o mock — o cutover (7.1) nunca pode exigir mudança de forma, só de fonte.
3. As invariantes de negócio (I1: `comercial` exige `sinal_id=S5`; FR-10/EC-5: `valor_contrato` só quando `estagio=Ganho`) são verificadas por teste automatizado tanto no mock (0.2/0.3) quanto no backend real (7.2), com a **mesma suíte**.

`assets/js/data-api.js` é o único arquivo autorizado a saber se está lendo `assets/data/mock/*.json` ou `/api/*` real. Nenhum outro arquivo da interface pode ramificar nesse "if".

## Consequências

**Positivas:**
- O cutover (7.1) é, por desenho, uma troca de uma constante de origem — não uma reescrita de UI.
- A mesma suíte de teste (`tests/contract/*.test.mjs`) valida mock e real, dando confiança real de paridade, não só "a tela não quebrou".
- Nenhum campo foi inventado sem lastro: cada um do contrato rastreia para `requirements.json.domainModel`, `research.json.attributionModelProposal` ou um AC de `spec.md` (Artigo IV).

**Negativas / limites aceitos:**
- Se o backend real precisar produzir um campo que o contrato não previu, o contrato — não só o código — precisa ser revisado, e a mudança se propaga para o schema, o fixture e o validador. Isso é o preço de ter uma costura formal em vez de um acoplamento implícito.
- O contrato não cobre agregados/KPIs (ver `data-contract.md` §4) — fica para quando a agregação real (phase-2/3) definir a forma, para não inventar um formato sem lastro em dado real.

## Ver também

- ADR-020 (a decisão de inversão que esta ADR viabiliza)
- `docs/architecture/data-contract.md`
- `docs/architecture/schemas/lead.schema.json`
- `tests/contract/fixture-shape.test.mjs`
