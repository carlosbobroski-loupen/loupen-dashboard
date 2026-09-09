# Contrato de dados — CRM Lead Intelligence (fase 1)

> **Subtask:** 0.1 (Etapa A) · **ADR relacionada:** ADR-021 · **Épico:** `epic-crm-lead-intelligence`
> **Status:** Draft — a costura entre a Etapa A (fixture curado) e a Etapa B (backend real)
> **Regra de ouro:** `assets/js/data-api.js` é o único arquivo que sabe se está lendo o mock ou o backend real. Nada mais na interface pode saber a diferença.

Todo campo abaixo rastreia para `requirements.json.domainModel`, `research.json.attributionModelProposal` ou um AC de `spec.md`. Onde um campo existe só para viabilizar a Etapa B (ex.: `ruleset_version`), ele é `nullable` desde o mock — o cutover (subtask 7.1) não pode mudar a forma.

---

## 1. `GET /api/leads` — lista filtrável

**Fonte:** FR-1 (filtros combináveis), FR-9 (consolidação de fonte), `domainModel` DM-1 (Lead) + DM-7 (Channel/Source).

### Query params (filtros combináveis por interseção — AC-1.1)

| Param | Tipo | Valores | Trace |
|---|---|---|---|
| `segmento[]` | string[] | `marketing` \| `comercial` \| `nao_atribuido` | DM-7, FR-5 |
| `canal[]` | string[] | livre (ex.: `meta_ads`, `google_ads`, `linkedin_ads`, `rd_station`) | DM-6 |
| `campanha` | string | id ou código bruto da campanha | DM-5 |
| `periodo_inicio`, `periodo_fim` | string (ISO 8601) | — | INT-1 |

### Resposta — item da lista

```json
{
  "id": "string (opaco, usado em /api/leads/{id})",
  "nome": "string",
  "empresa": "string | null",
  "segmento": "marketing | comercial | nao_atribuido",
  "estagio_funil": "string",
  "data_criacao": "string (ISO 8601)",
  "fonte_dados": "salesforce | rd_station"
}
```

| Campo | Trace |
|---|---|
| `id` | opaco de propósito — não é `LeadSource` nem PII; é a chave que `/api/leads/{id}` espera |
| `segmento` | DM-7.classificacao — **sempre um dos 3 valores, nunca omitido** (AC-5.2: ausência de sinal → `nao_atribuido`, jamais fallback para `comercial`) |
| `fonte_dados` | AC-9.1 — toda linha carrega identificação de fonte |

**Estados da interação (INT-1):** `loading` (lista+KPIs em carregamento), `error` (falha não apaga o filtro aplicado), `empty` (combinação sem resultado mostra resumo dos filtros ativos + ação de limpar — nunca "0" sem contexto).

---

## 2. `GET /api/leads/{id}` — ficha em três blocos (FR-2, FR-6, AC-6.1)

### 2.1 Bloco `overview`

```json
{
  "overview": {
    "nome": "string",
    "empresa": "string | null",
    "email": "string | null",
    "telefone": "string | null",
    "responsavel": "string | null",
    "estagio_funil": "string",
    "atribuicao": {
      "segmento": "marketing | comercial | nao_atribuido",
      "categoria": "string (nível 2 da taxonomia — ex.: 'Paid Social', 'Outbound SDR/Vendas')",
      "detalhe": "string | null (nível 3 — ex.: nome do ativo, 'canal a resolver')",
      "campanha_bruta": "string | null (nível 4 — identificador cru, ex.: 'GOTO_GERAL_LEADS_2601')",
      "sinal_id": "S1 | S2 | S3 | S4 | S5 | S6",
      "sinal_nome": "string (ex.: 'Ad ID de plataforma presente')",
      "confianca": "alta | media-alta | media | n/a",
      "razao_legivel": "string (frase pronta para exibir — NFR-7)",
      "campo_origem_bruto": "string | null (o valor de LeadSource/Campanha_LinkedIn__c antes de qualquer normalização — P6)",
      "ruleset_version": "string | null — NULLABLE na Etapa A; a Etapa B preenche com a versão do motor SQL que classificou"
    }
  }
}
```

| Campo | Trace |
|---|---|
| `atribuicao.*` | `research.json.attributionModelProposal.taxonomy` + `.signals` — os 6 sinais (S1-S6), a taxonomia de 4 níveis, e NFR-7 (100% dos leads expõem o sinal que os classificou) |
| `atribuicao.segmento = nao_atribuido` sem `sinal_id` de Comercial | **invariante I1** (spec.md §3.5): nenhum caminho retorna `comercial` sem que S5 tenha casado |
| `ruleset_version` | antecipa a Etapa B sem mudar a forma (D21) — é o único campo desta seção que só a Etapa B preenche de verdade |

### 2.1.1 Campo adicional: `vinculo_identidade` (acrescentado na subtask 0.4, EC-7)

```json
{
  "vinculo_identidade": {
    "status": "provavel | conflito",
    "candidato_id": "string | null",
    "score_similaridade": "number (0-1) | null",
    "explicacao": "string"
  } || null
}
```

`null` para a maioria dos leads — a identidade já foi resolvida deterministicamente (Tier 1: e-mail, `ConvertedAccountId`, UUID do RD Station). Só populado quando existe um candidato Tier 2 (probabilístico, `pg_trgm`/`fuzzystrmatch`) — **nunca confirma um merge automático** (`research.json.proposedIdentityResolutionDesign`, invariante "vínculo Tier 2 grava confidence < 1 e status 'provável'; a UI exibe como provável, não confirmado").

### 2.2 Bloco `activity` (jornada — FR-3)

```json
{
  "activity": [
    {
      "tipo": "conversao | mudanca_estagio | criacao_oportunidade | participacao_workflow",
      "timestamp": "string (ISO 8601) | null — null explícito quando a data não é rastreável (AC-3.2), NUNCA data arbitrária",
      "fonte": "rd_station | salesforce",
      "titulo": "string",
      "descricao": "string",
      "idade_dado_declarada": "string (ex.: 'atualizado 1x/dia na origem') | null"
    }
  ]
}
```

Ordenado cronologicamente (AC-3.1). Array vazio é estado válido (lead sem interação capturada), não erro.

### 2.3 Bloco `related` (FR-4, INT-4)

```json
{
  "related": {
    "conta": { "id": "string", "nome": "string" } || null,
    "oportunidade": {
      "id": "string",
      "mrr": "number",
      "estagio": "string",
      "valor_contrato": "number | null — SÓ preenchido quando estagio = 'Ganho' e duração conhecida (FR-10, EC-5)"
    } || null,
    "cadeia_campanha": ["string campanha", "string conjunto", "string anuncio"] || null
  }
}
```

| Regra | Trace |
|---|---|
| `conta: null` | lead ainda não convertido — nunca inferir por `LeadSource` (AC-2.2, CON-4: join só por `ConvertedAccountId`) |
| `valor_contrato: null` quando `estagio != 'Ganho'` | FR-10/EC-5 — **invariante**, nunca duração default |

---

## 3. Estados transversais (aplicam a qualquer endpoint)

| Estado | Regra |
|---|---|
| Fonte indisponível | nunca omite o registro; marca a lacuna com fonte + horário (EC-8, AC-9.2) |
| Vínculo de identidade "provável" (Tier 2) | exposto com um campo `confianca_vinculo: "provavel"` explícito — nunca apresentado como confirmado (EC-7) |
| Cobertura de atribuição | métrica separada, não incluída neste contrato de lead individual — pertence ao endpoint de KPIs (fora do escopo de 0.1, ver spec.md §3.7 D14) |

---

## 4. O que este contrato NÃO cobre (de propósito)

- Endpoint de KPIs agregados (`/api/kpis` ou similar) — fica para quando phase-2/3 definirem a agregação real; a Etapa A pode mockar os 4 números do `kpi-grid` diretamente no fixture sem um endpoint formal, já que não há filtro combinável sobre eles ainda.
- Escrita (`POST`/`PUT`) — NG1 (spec.md): este épico é somente leitura.
- Autenticação/perfil por usuário — NG4/§3.8: adiado para fase 2.

---

## 5. Arquivos que implementam este contrato

| Arquivo | Papel |
|---|---|
| `docs/architecture/schemas/lead.schema.json` | JSON Schema formal dos três blocos acima |
| `assets/data/mock/leads.json` | Fixture da lista (§1) — Etapa A |
| `assets/data/mock/leads-detalhe.json` | Fixture do detalhe (§2), chaveado por `id` — Etapa A |
| `tests/contract/fixture-coverage.test.mjs` | Valida que o fixture cobre cada estado de borda de §3 (subtask 0.3) |
| `assets/js/data-api.js` | Lê deste contrato — mock na Etapa A, `/api/*` real na Etapa B (subtask 7.1) |
