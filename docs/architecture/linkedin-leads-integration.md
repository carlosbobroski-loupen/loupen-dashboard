# Arquitetura — Integração de Leads Nativos do LinkedIn Ads

**Autor:** Aria (@architect) · **Data:** 2026-07-13 · **Status:** Proposta (design-only, nada implementado)
**Escopo:** Replicar, com paridade funcional, a automação de leads nativos do Meta Ads para o **LinkedIn Lead Sync API**, dentro do n8n (instância `n8n.loupenapps.com.br`), alimentando o mesmo hub (RD Station) → planilha "Central de Leads" → dashboard (`index.html`).

---

## 0. Princípio arquitetural (não-negociável)

> **RD Station é o hub. Ninguém escreve na planilha direto — todos os canais convergem no RD Station via Conversions API, e o pipeline RD Station → Sheet já existente é genérico e reaproveitável sem modificação.**

Consequência de projeto: o **único** trabalho novo é um workflow n8n que traduz o evento do LinkedIn para **exatamente o mesmo envelope de conversão RD Station** que o Meta já produz. Se os nomes de campo (`cf_*`, `traffic_*`) forem idênticos aos do Meta, o workflow "Leads RD Station" (id `O0CV1vx7N5Mc6Nig`) faz o append na planilha nas mesmas colunas, e o dashboard lê sem nenhuma alteração.

### Achado crítico: o dashboard JÁ está pronto para LinkedIn

Auditei o `index.html` atual. O frontend **não precisa de nenhuma mudança** — ele já foi preparado para leads de LinkedIn:

| Evidência no código | Linha | Implicação |
|---|---|---|
| `normCanal`: `if (s.includes('linkedin')) return 'LinkedIn ADS'` | 1298 | Basta o `cf_utm_source` conter `"linkedin"` para o lead cair no canal certo. |
| `normEvento`: remove sufixo `-{formId}` (`.replace(/-\d{6,}$/,'')`) com comentário citando LinkedIn | 1309-1311 | Defesa já existente caso o Evento venha com Form ID anexado. |
| `CAMPANHA_RULES`: `(s.includes('goto') || s.includes('linkedin'))` para Saúde/Institucional | 1029-1030 | `standardizeCampanha` já resolve campanhas LinkedIn. |
| Tabela de gasto/criativos: `plataforma:'LinkedIn ADS', conjunto:'—', criativo:'—'` | 3180, 3197 | **O dashboard já renderiza conjunto/criativo do LinkedIn como "—".** A ausência de nome de ad set/criativo NÃO é um problema de paridade. |

Isso muda o custo/risco do projeto: **toda a entrega é backend (n8n) + setup no Developer Portal. Zero risco de frontend.**

---

## 1. Visão geral do fluxo

```
                 ┌─────────────── LinkedIn ───────────────┐
  Usuário        │  Preenche Lead Gen Form no anúncio      │
  preenche  ───► │  LinkedIn gera leadFormResponse (URN)   │
                 └───────────────────┬─────────────────────┘
                                     │  push webhook (LEAD_ACTION, enxuto — só URNs)
                                     ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │  n8n — NOVO workflow "automação leads - LinkedIn"                      │
   │                                                                        │
   │  [GET  /webhook/linkedin-leads] ── handshake HMAC (challengeCode)      │
   │                                                                        │
   │  [POST /webhook/linkedin-leads]                                        │
   │      → responde 200 imediato                                           │
   │      → valida X-LI-Signature (HMAC do corpo bruto)                     │
   │      → filtra leadAction=CREATED, testLead=false                       │
   │      → dedupe por (leadGenFormResponse + occurredAt)                   │
   │      → GET /rest/leadFormResponses/{URN}   (dados completos do lead)   │
   │      → schema lookup: questionId → campo  (cache; fetch se formId novo)│
   │      → transform: monta objeto de campos + standardizeCampanha()       │
   │      → monta payload RD Station (MESMOS cf_* do Meta)                  │
   │      → POST api.rd.services/platform/conversions                       │
   │      → (on error em qualquer HTTP) → append linha ERRO na planilha     │
   └───────────────────────────────┬──────────────────────────────────────┘
                                    │  CONVERSION (CDP)
                                    ▼
                        ┌────────────────────────┐
                        │  RD Station (hub)       │
                        └───────────┬────────────┘
                                    │  webhook de conversão (já existe)
                                    ▼
              workflow "Leads RD Station" (O0CV1vx7N5Mc6Nig) → Append row
                                    ▼
                   Planilha "Central de Leads" / aba Conversoes
                                    ▼
                        index.html (dashboard) — SEM mudança
```

**Paralelo direto com o Meta** (workflow `1PF5oDDICnODOMH8`):

| Etapa Meta | Etapa LinkedIn equivalente | Diferença-chave |
|---|---|---|
| Webhook GET ecoa `hub.challenge` | Webhook GET responde HMAC de `challengeCode` | LinkedIn exige **assinatura**, não eco simples (resp. em ≤3s, `application/json`). |
| Webhook1 POST recebe `leadgen_id` | Webhook POST recebe URN `leadGenFormResponse` | Ambos enxutos (só ID). LinkedIn adiciona `X-LI-Signature` a validar. |
| GET Graph API `{leadgen_id}?fields=field_data,campaign_name,...` | GET `/rest/leadFormResponses/{URN}` | Meta devolve nome do campo E nome de campanha/adset/ad juntos. LinkedIn devolve `questionId` numérico (sem nome) + nome de campanha, **sem** nome de criativo/adset. |
| Code node: `field_data[]` → objeto | Code node: `answers[]` + schema → objeto | LinkedIn precisa de **1 lookup extra de schema** (`/rest/leadForms/{formId}`) para traduzir `questionId` → campo. |
| POST RD Station Conversions | POST RD Station Conversions | **Idêntico** (mesmo envelope, mesmos `cf_*`). |
| Log erro `ERRO_INTEGRACAO_META` | Log erro `ERRO_INTEGRACAO_LINKEDIN` | Mesma aba de log, mesmo formato. |

---

## 2. Workflow n8n node a node — "automação leads - LinkedIn"

Nomenclatura sugerida entre colchetes. Reaproveite ao máximo o Code node de transform e o de log de erro do workflow do Meta (copiar-adaptar).

### 2A. Ramo de handshake (validação do endpoint)

**Node 1 — `[Webhook LI Challenge]`** (Webhook, method **GET**, path `linkedin-leads`, responseMode `responseNode`)
- LinkedIn faz `GET .../linkedin-leads?challengeCode={uuid}` na criação da subscription e revalida a cada ~2h.

**Node 2 — `[Compute Challenge HMAC]`** (Code)
```js
// clientSecret = MESMO client secret do app OAuth2 do LinkedIn já usado hoje
const crypto = require('crypto');
const code = $json.query.challengeCode;
const secret = $env.LINKEDIN_CLIENT_SECRET; // externalizar — NUNCA hardcode
const challengeResponse = crypto.createHmac('sha256', secret).update(code).digest('hex');
return [{ json: { challengeCode: code, challengeResponse } }];
```

**Node 3 — `[Respond Challenge]`** (Respond to Webhook)
- Status 200, header `Content-Type: application/json`, body = `{{ $json }}` (`{challengeCode, challengeResponse}`).
- **Restrição dura:** resposta em ≤3s, senão falha; 3 falhas seguidas = endpoint **Blocked** no portal (reativação manual).

### 2B. Ramo de notificação real (o lead de fato)

**Node 4 — `[Webhook LI Notification]`** (Webhook, method **POST**, path `linkedin-leads`, opção **Raw Body = ON**, responseMode `onReceived` → 200 imediato)
- Duas webhooks no mesmo path, uma GET e uma POST — **exatamente o padrão que o Meta já usa** (`/formulario`).
- Raw Body é obrigatório: a assinatura é calculada sobre o corpo **exatamente como recebido** (re-serializar quebra o HMAC).

**Node 5 — `[Verify X-LI-Signature]`** (Code) — *gate de segurança*
```js
const crypto = require('crypto');
const secret = $env.LINKEDIN_CLIENT_SECRET;
const raw = $binary ? $binary.data.toString() : $json.rawBody; // corpo bruto
const expected = crypto.createHmac('sha256', secret)
  .update('hmacsha256=' + raw).digest('hex');
const received = $node['[Webhook LI Notification]'].json.headers['x-li-signature'];
if (expected !== received) {
  // assinatura inválida → NÃO processar. Retornar vazio interrompe o ramo.
  return [];
}
return [{ json: JSON.parse(raw) }];
```
> Assinatura inválida = descartar silenciosamente (já respondemos 200 no Node 4). Opcionalmente logar como evento de segurança.

**Node 6 — `[Filter CREATED / not test]`** (Filter/IF)
- Segue só se `leadAction === 'CREATED'` **e** (o `testLead` verificado depois no fetch, ou já aqui se disponível). Descarta `DELETED`.

**Node 7 — `[Dedupe]`** (ver §3.1 para escolha do mecanismo)
- Chave composta: `leadGenFormResponse + '|' + occurredAt`. Se já visto → interromper.
- **Motivo:** LinkedIn reentrega notificações, e a MESMA URN pode repetir para o mesmo form+pessoa em ações distintas (registro/cancelamento/re-registro). ID sozinho não basta.

**Node 8 — `[Fetch Lead Response]`** (HTTP Request)
- `GET https://api.linkedin.com/rest/leadFormResponses/{URN-encoded}`
- Headers: `LinkedIn-Version: 202606`, `X-Restli-Protocol-Version: 2.0.0`; auth via credencial OAuth2 **já existente** `LinkedIn Ads OAuth2 (Generic) - Loupen` (id `9QpAc6ggkbD9Gc7u`).
- Retorna: `formResponse.answers[]` (`{questionId, answerDetails}`), `leadMetadataInfo.sponsoredLeadMetadataInfo.campaign.{name,id,type}`, `associatedEntity.associatedCreative` (URN), `leadGenForm` (URN → formId), `submittedAt`, `testLead`.
- **`On Error: Continue (error output)`** → conecta ao ramo de log de erro (Node 14).

**Node 9 — `[Schema Cache Lookup]`** (ver §3.2)
- Extrai `formId` da URN `leadGenForm`. Busca no cache o mapa `questionId → {name, predefinedField}`.
- **Cache hit** → segue para Node 12. **Cache miss** (formId novo) → Node 10.

**Node 10 — `[Fetch Form Schema]`** (HTTP Request) — *só em cache miss*
- `GET https://api.linkedin.com/rest/leadForms/{formId}` (mesmos headers/credencial do Node 8).
- Lê `content.questions[].{questionId, name, predefinedField}`.

**Node 11 — `[Persist Schema Cache]`** — grava o mapa do form no cache (uma vez por form).

**Node 12 — `[Transform Lead]`** (Code) — *núcleo, adaptado do Code node do Meta*
- Aplica o schema: para cada `answer`, resolve `questionId → predefinedField/name` → objeto `campos`.
- `predefinedField`: `FIRST_NAME`+`LAST_NAME`→`name`; `EMAIL`→`email`; `JOB_TITLE`→`job_title`; `COMPANY_NAME`→`company_name`; telefone→`personal_phone`.
- Campos customizados (ex: "tamanho da empresa") sem `predefinedField`: casar por `name`/texto da pergunta → `cf_tamanho_da_empresa`.
- **Reusar a MESMA `standardizeCampanha()`** que o Meta e o dashboard usam, com as regras LinkedIn já presentes (`goto|linkedin` → GOTO_*; `webinar` → GOTO_WEBINAR_07-26). Fonte da verdade das regras: `index.html` linhas 1024-1031 — considerar externalizar num JSON compartilhado no futuro (ver §7, decisão D4).
- `Evento` = `standardizeCampanha(campaign.name)`.

**Node 13 — `[Post RD Station]`** (HTTP Request) — *idêntico ao Meta*
- `POST https://api.rd.services/platform/conversions?api_key=...`
- Body: `{ event_type:"CONVERSION", event_family:"CDP", payload: { ...campos + cf_* } }` (payload detalhado em §4).
- **`On Error: Continue`** → ramo de log de erro.

**Node 14 — `[Prepare Error Log Row]`** (Code) + **Node 15 — `[Log Error to Sheet]`** (Google Sheets Append)
- Cópia adaptada do par de nodes do Meta. Mesma planilha "Central Leads | RD Station", mesma aba de log.
- Diferença única: `Evento: 'ERRO_INTEGRACAO_LINKEDIN'`. Incluir `leadGenFormResponse`, `formId`, mensagem de erro, timestamp.

---

## 3. Decisões de infraestrutura interna (com recomendação)

### 3.1 Mecanismo de deduplicação

| Opção | Prós | Contras | Latência |
|---|---|---|---|
| **A. n8n static data** (`getWorkflowStaticData`) | Nativo, zero setup, rápido | Não auditável fora do n8n; cresce sem TTL (precisa poda) | ~0ms |
| **B. Google Sheet (aba dedupe)** | Auditável, visível ao time | +1 read/write por lead; risco de corrida em rajada | ~300-800ms |
| **C. n8n Data Table** | Estruturado, nativo, consultável na UI | Depende da versão do n8n ter o recurso | ~baixa |
| **RECOMENDAÇÃO** | **C** se a versão do n8n suportar Data Table; senão **A** com poda por janela de tempo (guardar só últimas 48-72h). B só se auditoria de dedupe for requisito explícito. | | |

### 3.2 Cache do schema do form (questionId → campo)

O schema muda raramente (só quando editam o form). Não deve ser buscado a cada lead.

| Opção | Prós | Contras |
|---|---|---|
| **A. Aba Google Sheet `LI_Form_Schema_Cache`** | Auditável **e editável à mão** — dá pra corrigir mapeamento de campo custom sem mexer no código | +1 read por lead (mitigável com cache em memória do workflow) |
| **B. n8n Data Table** | Nativo, rápido | Menos "à mão" para o time editar |
| **C. n8n static data** | Zero latência | Invisível; refazer schema exige rodar workflow |
| **RECOMENDAÇÃO** | **A (Sheet)** — o ganho de poder editar manualmente o mapeamento de perguntas customizadas (que não têm `predefinedField`) supera o custo de latência. Refresh sob demanda: só busca `/rest/leadForms/{formId}` quando aparece um `formId` ausente no cache. | |

> Estratégia de refresh: **lazy/on-miss**. Nada de polling. Form novo → 1 fetch → grava no cache → nunca mais busca. Se editarem um form existente e mudarem `questionId`, basta apagar a linha do cache (ou o mapeamento cai no fallback por `name`).

---

## 4. Tabela de mapeamento de campos — LinkedIn → RD Station (`cf_*`)

> **Regra de ouro:** usar **exatamente** os mesmos nomes de campo que o Meta já envia, para que o workflow RD Station → Sheet caia nas **mesmas colunas** e o dashboard leia sem mudança. Onde o Meta usa `cf_facebook_lead_id`, o LinkedIn usa `cf_linkedin_lead_id` (novo campo, aditivo — não conflita).

| Campo RD Station (payload) | Origem no LinkedIn | Coluna no dashboard (efeito) | Paridade c/ Meta |
|---|---|---|---|
| `name` | `FIRST_NAME` + `LAST_NAME` (predefinedField) | c[3] Nome | ✅ igual |
| `email` | `EMAIL` (predefinedField) | c[2] e-mail (chave de cruzamento) | ✅ igual |
| `job_title` | `JOB_TITLE` (predefinedField) | c[6] Cargo (`normCargo`) | ✅ igual |
| `company_name` | `COMPANY_NAME` (predefinedField) | c[5] Empresa | ✅ igual |
| `personal_phone` | pergunta de telefone (predefinedField `PHONE_NUMBER`) | — | ✅ igual |
| `cf_tamanho_da_empresa` | pergunta custom "tamanho da empresa" (por `name`) | c[7] Porte (`normPorte`) | ⚠️ custom, sem predefinedField — casar por texto |
| **`cf_utm_source` = `"linkedin"`** | **constante** (não vem do lead) | c[15] → `normCanal` → **"LinkedIn ADS"** | ⚠️ Meta usa `fb/ig`; aqui fixamos `linkedin`. **Obrigatório** p/ canal correto |
| `cf_utm_medium` = `"paid_social"` (ou `cpc`) | constante | c[14] (`normCanal` fallback) | ⚠️ análogo ao Meta |
| `cf_utm_campaign` | `sponsoredLeadMetadataInfo.campaign.name` | — (rastreio) | ✅ campaign.name vem de graça |
| `traffic_source` / `traffic_campaign` | idem campanha | usado por `normCanal`/atribuição | ✅ |
| `Evento` (conversion_identifier) | `standardizeCampanha(campaign.name)` | c[1] Evento (campanha padronizada) | ✅ mesma função |
| `cf_utm_content` | `associatedEntity.associatedCreative` (**URN cru, sem nome**) | — | ❌ **lacuna**: só URN, sem nome legível |
| `cf_utm_term` | `leadGenForm` URN / form name | — | ⚠️ análogo fraco |
| **`cf_linkedin_lead_id`** | `leadGenFormResponse` (URN) | — (idempotência/rastreio) | ➕ novo (equivale a `cf_facebook_lead_id`) |
| `cf_linkedin_campaign_id` | `campaign.id` | — | ➕ opcional |

### Lacunas de paridade com o Meta (explícitas)

1. **Sem nome de ad set.** O LinkedIn não tem "ad set" com nome como o Meta. Hierarquia = Campaign Group > Campaign > Creative. **Impacto: nenhum** — o dashboard já mostra `conjunto: '—'` para LinkedIn (linhas 3180/3197).
2. **Sem nome de criativo pronto.** Só vem o URN `associatedCreative`. Para ter nome legível seria preciso 1 chamada extra a um endpoint de creative/ad. **Impacto: nenhum hoje** — o dashboard já mostra `criativo: '—'` para LinkedIn. Recomendo **não** resolver (custo/benefício ruim) até que o dashboard passe a exibir criativo de LinkedIn. Ver decisão D3.
3. **`questionId` sem nome de campo.** Resolvido pelo lookup de schema (§3.2) — não é lacuna de dados, é 1 passo extra de tradução.
4. **`cf_utm_source` é constante, não dinâmico.** No Meta o `site_source_name` distingue fb/ig; no LinkedIn tudo é "linkedin". Aceitável e alinhado ao `normCanal` atual.

---

## 5. Checklist de setup one-time (fora do n8n)

> Este é o **caminho crítico do cronograma** — não o código. Executar **em ordem**.

- [ ] **1. Solicitar produto "Lead Sync API"** no LinkedIn Developer Portal, no **mesmo app já existente** (o que já tem "Advertising API" e a credencial OAuth2 `9QpAc6ggkbD9Gc7u`). Portal → app → aba **Products** → "Additional available products" → **Lead Sync API** → *Request Access*. Concede a permissão `r_marketing_leadgen_automation`.
- [ ] **2. Pré-requisito — verificação da Company Page:** associar o app à LinkedIn Page da Loupen; um **super admin da página** precisa validar o app.
- [ ] **3. Pré-requisito — e-mail corporativo verificado** no app (não pessoal) + descrição do caso de uso.
- [ ] **4. Role de Company Page para o usuário responsável:** para leads `SPONSORED`, o usuário autenticado precisa de role na Company Page (`ADMINISTRATOR`, `LEAD_GEN_FORMS_MANAGER`, `CURATOR`, `CONTENT_ADMINISTRATOR` ou `ANALYST`). Além da role de ad account que já têm. **Pode exigir alinhamento com quem administra a página da empresa.**
- [ ] **5. Aguardar aprovação da LinkedIn** (self-service com revisão; prazo **não** documentado — assumir dias a semanas). **Gargalo fora do nosso controle.**
- [ ] **6. Confirmar `LINKEDIN_CLIENT_SECRET`** disponível como env/credencial no n8n (é o client secret do MESMO app OAuth2 — usado no HMAC do handshake e da assinatura).
- [ ] **7. Publicar o endpoint n8n** (workflow ativo, ramos GET+POST no ar) **ANTES** de criar a subscription — o `POST /leadNotifications` dispara imediatamente o handshake `challengeCode`, e o endpoint precisa responder o HMAC corretamente ou a subscription não é aceita.
- [ ] **8. Criar a subscription** (uma vez): `POST https://api.linkedin.com/rest/leadNotifications` com
  `{ webhook: "https://n8n.loupenapps.com.br/webhook/linkedin-leads", owner: { sponsoredAccount: "urn:li:sponsoredAccount:533600351" }, leadType: "SPONSORED" }`.
  Nível **por owner** (não por form/creative) — pega todos os forms da conta.
- [ ] **9. Teste com `testLead`:** submeter um lead de teste no LinkedIn; confirmar que `testLead=true` é filtrado (ou roteado para não sujar produção) e que um lead real percorre o fluxo até a planilha.
- [ ] **10. Monitorar revalidação:** o endpoint é revalidado a cada ~2h; 3 falhas seguidas o marcam **Blocked** (reativação manual no portal). Garantir que o ramo GET/HMAC fique sempre no ar.

---

## 6. Riscos e decisões em aberto (só o usuário decide)

| ID | Decisão | Opções | Recomendação da arquitetura |
|---|---|---|---|
| **D1** | Mecanismo de dedupe | A) static data · B) Sheet · C) Data Table | **C** (ou A com poda) — ver §3.1 |
| **D2** | Local do cache de schema | A) Sheet editável · B) Data Table · C) static | **A** — editável à mão p/ campos custom (§3.2) |
| **D3** | Resolver nome de criativo? | A) deixar URN · B) chamada extra p/ nome | **A (deixar URN)** — dashboard já mostra "—"; sem ROI hoje |
| **D4** | `standardizeCampanha` duplicada em 3 lugares (dashboard, Code node Meta, futuro Code node LinkedIn) | A) manter duplicado · B) externalizar regras p/ JSON único versionado | **B** no médio prazo — hoje há **risco real de drift** (as regras já vivem em 2 cópias). Não bloqueia o MVP. |
| **D5** | Usar `hiddenFields` no form p/ tracking extra | A) não usar · B) configurar no form | **A** — campaign.name/id já vem de graça; hiddenFields é "nice to have", não necessário p/ atribuição |
| **D6** | Filtro de `testLead` | descartar vs. rotear p/ aba de teste | Decidir se testes devem aparecer em algum lugar (recomendo descartar em produção) |
| **D7** | Envelope de conversão RD Station | reusar 100% o do Meta | **Reusar** — qualquer divergência de nome de campo quebra o mapeamento p/ coluna |

**Riscos operacionais:**
- **R1 — Aprovação LinkedIn (ALTO, fora de controle):** prazo indeterminado. É o provável maior gargalo. Iniciar o passo 1 do §5 **imediatamente**, em paralelo ao desenvolvimento.
- **R2 — Endpoint "Blocked" por falha de handshake (MÉDIO):** HMAC errado, secret errado, ou resposta >3s bloqueia. Mitigar com teste do ramo GET isolado antes de criar a subscription.
- **R3 — Drift da `standardizeCampanha` (MÉDIO):** já são 2 cópias; a 3ª aumenta o risco de regra divergente entre canais. Ver D4.
- **R4 — Campo custom "tamanho da empresa" sem `predefinedField` (BAIXO):** casamento por texto da pergunta é frágil se editarem o label do form. Cache editável (D2/A) mitiga.
- **R5 — Corrida de dedupe em rajada de leads (BAIXO):** mitigado por static data/Data Table (D1).

---

## 7. Estimativa de esforço

| Frente | Esforço | Observação |
|---|---|---|
| **Workflow n8n (código)** | **~1 dia** (0,5 dia se cache/dedupe forem simples) | ~12-15 nodes, mas transform, payload RD, `standardizeCampanha` e log de erro são **copy-adapt do Meta**. O genuinamente novo: HMAC handshake, verificação de assinatura, lookup de schema, dedupe por par URN+timestamp. |
| **Dashboard (`index.html`)** | **0h** | Já é LinkedIn-ready (§0). Nenhuma mudança. |
| **RD Station → Sheet** | **0h** | Pipeline genérico já existe; reusado sem tocar. |
| **Setup Developer Portal + subscription** | horas de trabalho ativo | Mas **bloqueado pela aprovação da LinkedIn** (dias a semanas). |

**Comparação com o esforço aparente do Meta:** o workflow do Meta tem ~6 nodes e um Code node de transform robusto. O do LinkedIn é **maior em nº de nodes** (~2x), porém a maior parte do incremento é boilerplate de segurança (HMAC ×2) e o lookup de schema — nenhum deles algoritmicamente difícil. **O código não é o risco.**

> **Observação honesta de cronograma:** o gargalo real **não é a implementação** (que cabe em ~1 dia de n8n), e sim a **aprovação da LinkedIn para o produto "Lead Sync API"**, cujo prazo não controlamos e não está documentado. **Recomendação: iniciar hoje o pedido de acesso (§5, passo 1) e desenvolver o workflow em paralelo**, usando `testLead` para validar ponta a ponta assim que o acesso sair. Assim o código estará pronto e testável no minuto em que a LinkedIn liberar.

---

## 8. Anexo — Decisões automáticas de projeto (registro)

- `[AUTO-DECISION]` Duas Webhook nodes no mesmo path (GET+POST) → **adotado**, espelha o padrão validado do Meta (`/formulario`) e é a forma nativa do n8n lidar com métodos distintos por handler.
- `[AUTO-DECISION]` Resposta 200 imediata no POST + validação de assinatura interna → **adotado**, evita estourar timeout e não vaza resultado de validação ao emissor.
- `[AUTO-DECISION]` Refresh de schema **lazy/on-miss** (sem polling) → **adotado**, schema muda raramente; polling seria desperdício.
- `[AUTO-DECISION]` `cf_utm_source="linkedin"` como **constante** → **adotado**, é o gatilho exato que `normCanal` (linha 1298) espera para classificar o canal.
- Itens que **exigem decisão do usuário** (D1-D7, §6) foram deixados em aberto, com recomendação — não auto-decididos, conforme o pedido.

---

*Design-only. Nada implementado no n8n nem no dashboard. Este documento é a recomendação de arquitetura para aprovação antes da construção.*
