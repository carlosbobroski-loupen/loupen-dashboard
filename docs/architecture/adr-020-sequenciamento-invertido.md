# ADR-020: Sequenciamento invertido — superfície contra fixture curado antes do backend real

**Status:** Aceito · **Data:** 2026-09-07 · **Épico:** `epic-crm-lead-intelligence`

## Contexto

O plano original (Fase 6, `implementation.yaml` v1) seguia a ordem padrão de dependência do próprio processo AIOX: banco → backend → frontend → integração. Essa ordem tinha lastro técnico direto em `research.json` (perspectiva de marketing/RevOps): *"Customer 360 é a SAÍDA da resolução de identidade, não uma tela"* — ou seja, FR-2/FR-3 (ficha 360, jornada) não seriam **produzíveis em escala** antes de EC-7 (resolução de identidade cross-fonte) estar resolvido.

O usuário pediu, em 2026-09-07, para inverter essa ordem: construir toda a superfície (filtros, ficha, jornada, relacionados) primeiro, contra dados curados manualmente das planilhas que já alimentam o dashboard hoje, liberando a construção do backend real depois.

## Decisão

**D20 — Inverter o sequenciamento.** A Etapa A constrói a superfície inteira contra um fixture curado à mão (`assets/data/mock/*.json`), validando **experiência** (FR-1, FR-2, FR-3, FR-4, FR-6, NFR-5). A Etapa B constrói o backend real (banco, ingestão, motor de atribuição, gate) e faz o cutover, validando **integridade** (FR-7, FR-8, FR-9, NFR-1, EC-7 em escala).

A inversão **refina, não refuta**, o achado de research.json: ele torna impossível *produzir* a ficha em escala sem EC-7; não torna impossível *renderizar a forma* da saída para uma amostra costurada à mão. São duas coisas diferentes que o plano original tratava como uma.

## Consequências

**Positivas:**
- Progresso visual rápido, validação de UX antes de investir em infraestrutura.
- `phase-2` a `phase-4` (banco/ingestão/gate) passam a rodar com a superfície já validada, sem risco de retrabalho de UI por causa de decisão de backend.
- Fixture curado vira substrato determinístico permanente para os testes Playwright (5.16/7.3) — evita testes flaky contra base viva.
- Força respostas antecipadas a OQ-12 (Parceiro/Indicação) e OQ-13 (vocabulário de outbound), porque a curadoria (0.5) exige registrar o `sinal_id` de cada lead.

**Negativas (aceitas conscientemente):**
- **Não reduz o esforço total** — reorganiza e cresce ligeiramente (~15-22 dias contra 12-18 do plano original), por causa da formalização do contrato, da dupla validação (mock e real) e de ~1,5-2,5 dias de curadoria humana.
- **Não valida o defeito que originou a epic.** FR-8/NFR-1 (sincronização parcial, totais hardcoded) só se corrigem com ingestão real — um fixture curado é, por definição, um snapshot feito à mão.
- **R22 (novo): ancoragem de expectativa de performance.** Um JSON estático é instantâneo; o backend real (navegador → Cloudflare → n8n → Neon) pode não ser. Mitigado por medição de latência real antes do cutover (5.17) e pela decisão de que qualquer estouro do alvo de NFR-2 é decisão de escopo/arquitetura, não ajuste de expectativa.
- **R23 (novo): risco de reintroduzir PII em repositório público.** O fixture curado à mão, se descuidado, pode repetir o incidente já corrigido (ver `project_pii_exposure_incident`). Mitigado por: instruções explícitas de anonimização em `assets/data/mock/README.md`, e um teste automatizado (`fixture-shape.test.mjs`) com heurística que sinaliza e-mail/telefone que não parecem anonimizados.

## Ver também

- ADR-021 (o contrato de dados que viabiliza esta inversão)
- `docs/architecture/data-contract.md`
- `implementation.yaml`, cabeçalho "REVISÃO 2" (rationale completo do @architect)
