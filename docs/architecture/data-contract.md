# Contrato de dados — CRM Lead Intelligence (fase 1)

> **Subtask:** 0.1 (Etapa A) · **ADR relacionada:** ADR-021 · **Épico:** `epic-crm-lead-intelligence`
> **Status:** Draft — a costura entre a Etapa A (fixture curado) e a Etapa B (backend real)
> **Regra de ouro:** `assets/js/data-api.js` é o único arquivo que sabe se está lendo o mock ou o backend real. Nada mais na interface pode saber a diferença.

Todo campo abaixo rastreia para `requirements.json.domainModel`, `research.json.attributionModelProposal` ou um AC de `spec.md`. Onde um campo existe só para viabilizar a Etapa B (ex.: `ruleset_version`), ele é `nullable` desde o mock — o cutover (subtask 7.1) não pode mudar a forma.

---

## 1. `GET /api/leads` — lista filtrável

**Fonte:** FR-1 (filtros combináveis), FR-9 (consolidação de fonte), `domainModel` DM-1 (Lead) + DM-7 (Channel/Source).

### Query params (filtros combináveis por interseção — AC-1.1)

> **Revisão de 2026-09-09 (subtask 8.1).** A versão anterior deste contrato definia 4 filtros
> derivados de suposição, sem que ninguém tivesse enumerado os campos que o RD Station entrega.
> Os filtros abaixo saem de **medição executada** (§1.1). Nenhum filtro pode ser adicionado a
> este contrato sem uma taxa de cobertura medida ao lado dele.

| Param | Tipo | Valores | Cobertura | Trace |
|---|---|---|---|---|
| `periodo_inicio`, `periodo_fim` | string (ISO 8601) | sobre `data_conversao` | 100% | INT-1 |
| `trimestre[]` | string[] | `2026-Q2` \| `2026-Q3` … | 100% | derivado de `data_conversao` |
| `origem_conversao[]` | string[] | livre — ex.: `Webinar-GoTo-07-26` | **100%** | eixo A (§1.2) |
| `tags[]` | string[] | livre, multivalor | **94,4%** | fonte `tags` (SET) |
| `cargo_grupo[]` | string[] | ver §1.3 | **90,0%** | fonte `job_title` |
| `atendido_por[]` | string[] | 12 valores fechados | **82,0%** | fonte `cf_falou_com` |
| `tamanho_empresa[]` | string[] | `pequena` \| `media` \| `grande` | **36,4%** | ver §1.4 |
| `campanha_midia` | string | ex.: `Rescue - Licença Eco 2026` | **7,6%** | eixo B (§1.2) |
| `plataforma[]` | string[] | ex.: `Instagram`, `Facebook` | **6,8%** | fonte `cf_midia` |
| `estagio_funil[]` | string[] | `lead` \| `qualificado` \| `oportunidade` \| `cliente` | coletado | DM-7 |
| `segmento[]` | string[] | `marketing` \| `comercial` \| `parceiro` \| `nao_atribuido` — ver §1.8 | derivado | DM-7, FR-5 |
| `atribuicao` | string | `primeiro_toque` \| `ultimo_toque` | 100% | `traffic_source` (§1.5) |
| `incluir_teste` | boolean | default `false` | — | §1.6 |

**Filtros recusados por ausência de dado** — medidos e descartados, não esquecidos:

| Campo candidato | Cobertura medida | Decisão |
|---|---|---|
| `city`, `state`, `country` | 0,0% | recusado — sem filtro geográfico |
| `cf_nome_do_anuncio`, `cf_grupo_de_anuncio` | 0,0% | recusado — o drill-down de mídia tem 2 níveis, não 4 |
| `cf_atuacao_da_empresa` (19 setores) | 0,4% | recusado — enum cheio, coluna vazia |
| `cf_departamento_da_empresa` | 0,0% | recusado |
| `cf_numero_de_funcionarios` | 0,0% | recusado em favor de `cf_tamanho_da_empresa` |
| `cf_cargo_profissional` | 0,0% | recusado em favor de `job_title` |

### 1.1 Cobertura medida na fonte (evidência)

Medição executada em 2026-09-09 contra a API de produção do RD Station: **amostra de 250 contatos
da segmentação `19631903` ("Todos os contatos da base de Leads"), 0 erros de coleta.** Fluxo de
diagnóstico criado, executado e removido no mesmo dia (não permanece no n8n).

Reexecutar antes de qualquer nova revisão deste contrato. Uma cobertura que muda invalida um filtro.

### 1.2 Os dois eixos de campanha — nunca se misturam

Decisão do usuário em 2026-09-09. `conversion_identifier` cobre 100% dos eventos; UTM cobre 7,6%.
Fundi-los criaria "campanha sem investimento" e qualquer ROI calculado sobre a coluna misturada
estaria errado sem avisar.

| Eixo | Param | Significado | Investimento |
|---|---|---|---|
| **A — Origem de conversão** | `origem_conversao[]` | qual ativo/oferta converteu o lead | **nunca** |
| **B — Campanha de mídia paga** | `campanha_midia` | qual veiculação paga trouxe o lead | sim, via `ad_campaign` |

**Regra dura:** valor de investimento e ROI só podem ser calculados sobre o eixo B. A interface
não pode somar, comparar ou agregar os dois eixos na mesma coluna.

### 1.3 `cargo_grupo` — agrupamento derivado

`job_title` é texto livre a 90% de preenchimento: alto valor, formato inutilizável como filtro
direto. Vira `cargo_grupo` por uma **tabela de mapeamento em banco** (`cargo_grupo_regra`), não
por regex embutida em query.

A tabela é semeada a partir da lista real de valores distintos produzida pela primeira ingestão
completa — **não a partir de faixas inventadas agora**. Todo valor sem regra cai em `outros`, e a
aba Qualidade de dados mostra os `outros` mais frequentes para que a tabela evolua com evidência.

### 1.4 `tamanho_empresa` — 3 faixas, e por quê só 3

`cf_tamanho_da_empresa` é texto livre e os 91 preenchimentos medidos usam **escalas incompatíveis**:
`1 a 19` / `20 a 99` de um lado; `1 a 9` / `10 a 49` / `50 a 99` / `100 a 249` / `250 a 499` /
`500 a 999` / `1.000+` do outro, mais `mais de 1000 funcionários` como variante.

As únicas fronteiras comuns às duas escalas são **99/100** e **999/1.000**. Logo:

| Faixa canônica | Valores de origem | n medido |
|---|---|---|
| `pequena` | `1 a 9`, `1 a 19`, `10 a 49`, `20 a 99`, `50 a 99` | 72 |
| `media` | `100 a 249`, `250 a 499`, `500 a 999` | 12 |
| `grande` | `1.000+`, `mais de 1000 funcionários` | 7 |

Uma quarta faixa exigiria decidir em que lado do corte cai `10 a 49` — invenção, proibida pelo
Artigo IV. Se a origem passar a usar uma escala só, a granularidade pode aumentar.

### 1.5 Atribuição — primeiro e último toque

`traffic_source` chega como `encoded_` + base64 de um JSON com `first_session` e `current_session`.
Decodificado na ingestão, dá atribuição de primeiro e último toque por evento, sem instrumentação
adicional. Quando não há UTM, `value` traz a URL crua da sessão (permite atribuição por página em
tráfego direto) ou `(none)`.

**Correção de 2026-09-09 sobre a magnitude disto.** Esta seção foi escrita descrevendo a
atribuição como se fosse universal. Medido em 766 eventos reais: **434 (57%) têm sessão de origem
legível**, não todos. É nativa, não é universal — e a diferença importa porque um dashboard de ROI
construído sobre a premissa errada superestima a cobertura da própria conta.

**`atribuicao_status`** (migration 057) separa os estados que antes eram um `null` só:

| Valor | Significado | Ação possível |
|---|---|---|
| `ok` | `encoded_<base64>` decodificado, com sessão | — |
| `ok_plano` | forma plana de mídia paga (ver §1.5.1) | — |
| `ausente` | a fonte **não** mandou `traffic_source` | nenhuma do nosso lado |
| `ilegivel` | veio num formato que não sabemos ler | **defeito nosso, tem correção** |
| `NULL` | evento anterior à migration 057 | reingerir preenche |

`ilegivel` é o único número acionável, e por isso é o que a aba Qualidade de dados destaca.
Somá-lo com `ausente` — como a versão anterior fazia — escondia a única distinção que permite agir.

### 1.5.1 `traffic_source` tem DUAS formas — e a segunda estava sendo descartada

Descoberto em 2026-09-09 **porque** `atribuicao_status` existia: a primeira medição acusou 61
eventos `ilegivel`, e ao inspecioná-los eles eram os **melhor atribuídos** da base (47 com
`utm_campaign`, 45 com `midia`). Isso não fazia sentido como "falha de leitura", e a consulta à
API revelou o motivo.

| Forma | Conteúdo | Origem típica |
|---|---|---|
| **A** `encoded_<base64>` | JSON com `first_session` / `current_session` | conversão de site |
| **B** string simples (`facebook`) | acompanhada de `traffic_medium`, `traffic_campaign`, `traffic_value` | Facebook Lead Ads |

O coletor tentava decodificar B como base64, falhava, e marcava `ilegivel` — **descartando a
atribuição de mídia paga**, que é justamente a que sustenta cálculo de ROI. Dos 61, **14 ficaram
sem nenhuma atribuição capturada**.

Corrigido na migration 060. Resultado medido: `ilegivel` foi de **61 para 0**, e os 61 eventos
passaram a ter plataforma identificada (era 45) e 50 com campanha (era 47).

**Consequência para o eixo B:** a cobertura de 7,6% que este contrato reportou foi medida sobre os
campos `cf_utm_*` do cadastro. A forma plana é uma fonte **adicional** de atribuição paga, e a
cobertura real do eixo B é maior do que a registrada em §1.1.

A forma B **não tem histórico de sessão**, então primeiro e último toque continuam nulos nesses
eventos — não se reconstrói uma sessão a partir dela. Os campos planos alimentam
`utm_source`/`utm_medium`/`utm_campaign`/`utm_term`/`midia` como **fallback**, com os `cf_utm_*`
dedicados sempre vencendo quando existem.

**Precedência de atribuição, em uma linha:** `cf_utm_*` dedicado → sessão decodificada → campos
planos.

### 1.5.2 O nome errado ensina mais que o bug

A migration 057 corrigiu um erro (misturar "campo ausente" com "falha de decodificação" num `null`
só) e, na mesma correção, criou uma versão menor dele: passei a chamar `ilegivel` tanto uma falha
real quanto um formato que eu simplesmente não conhecia.

`ilegivel` **afirma que o dado está errado**, quando o que estava errado era o leitor. Um estado de
erro deve nomear o que se sabe, não acusar a fonte. Por isso a aba Qualidade de dados descreve
`ilegivel` como "formato que o nosso coletor não sabe ler", e não como "dado inválido".

O `NULL` **não foi retroagido de propósito**: sem reingerir não há como saber qual dos dois casos
era, e preencher um palpite apagaria a lacuna em vez de mostrá-la (Artigo IV). A migration 058
permite que uma reingestão complete o status **sem tocar nenhum outro campo** — e o contador de
ingestão distingue "evento novo" de "status preenchido" para não inflar a métrica nem destruir a
prova de idempotência.

### 1.6 Dados de teste — marcados, nunca deletados

A base de produção do RD contém dados de teste. Regra: o lead **entra** no banco com `is_teste`,
e os filtros o excluem por padrão (`incluir_teste=false`). Regras ficam em tabela auditável
(`lead_teste_regra`), nunca em query solta, e a aba Qualidade de dados mostra quantos leads cada
regra excluiu. Exclusão silenciosa é proibida.

### 1.7 Grão de contagem — depende da visão

Decisão do usuário em 2026-09-09.

| Visão | Grão | Consequência |
|---|---|---|
| Geral / KPI de topo | lead **distinto** | um lead conta uma vez |
| Por campanha / por origem | lead distinto **por campanha** | um lead conta em cada campanha em que converteu |

**A soma da coluna "leads" por campanha é legitimamente maior que o total geral.** A interface é
obrigada a rotular isso onde a coluna aparece — sem o rótulo, o número parece um erro de soma.

Conversões com `event_timestamp` idêntico ao segundo para o mesmo lead e mesma origem são
**duplicata de fonte** (verificado nos dados reais) e colapsam para uma.

### 1.8 `segmento` — correção do contrato em 2026-09-09

Este contrato dizia que `segmento` tem **três** valores minúsculos
(`marketing | comercial | nao_atribuido`). Ao consultar a view com dado real, o valor devolvido
era `NaoAtribuido`. Investigado: `lead_origin_classification` tem uma CHECK constraint com
**quatro** valores em CamelCase — `Marketing`, `Comercial`, `NaoAtribuido`, `Parceiro`.

**Quem estava errado era o contrato, não o banco.** `Parceiro` é uma classificação real,
prevista na constraint desde a criação da tabela. Colapsá-la em um dos outros três para "caber"
no que o contrato dizia destruiria informação de negócio — parceiro não é marketing nem
comercial.

Resolução: a API expõe snake_case (convenção deste contrato para valor de query param) e o banco
mantém o CamelCase interno. A tradução vive em `fn_segmento_contrato()` — **um** ponto de
tradução, com asserção na migration 052 que falha se a CHECK ganhar um valor novo e a função
não. Valor desconhecido cai em `nao_atribuido` e aparece na aba Qualidade de dados, em vez de
vazar cru para a interface.

`nao_atribuido` continua sendo o destino de ausência de sinal (AC-5.2) — **jamais** `comercial`.

### Resposta — item da lista

```json
{
  "id": "string (opaco, usado em /api/leads/{id})",
  "nome": "string",
  "empresa": "string | null",
  "segmento": "marketing | comercial | nao_atribuido",
  "estagio_funil": "string",
  "data_criacao": "string (ISO 8601)",
  "data_conversao": "string (ISO 8601) | null",
  "fonte_dados": "salesforce | rd_station",

  "origem_conversao": "string | null",
  "qtd_conversoes": "integer",
  "tags": "string[]",
  "cargo": "string | null",
  "cargo_grupo": "string",
  "tamanho_empresa": "pequena | media | grande | nao_informado",
  "atendido_por": "string | null",
  "campanha_midia": "string | null",
  "plataforma": "string | null",
  "is_teste": "boolean"
}
```

| Campo | Trace |
|---|---|
| `id` | opaco de propósito — não é `LeadSource` nem PII; é a chave que `/api/leads/{id}` espera |
| `segmento` | DM-7.classificacao — **sempre um dos 3 valores, nunca omitido** (AC-5.2: ausência de sinal → `nao_atribuido`, jamais fallback para `comercial`) |
| `fonte_dados` | AC-9.1 — toda linha carrega identificação de fonte |
| `origem_conversao` | eixo A (§1.2) — **nunca** portador de investimento |
| `campanha_midia` | eixo B (§1.2) — único eixo que pode receber investimento/ROI |
| `qtd_conversoes` | separa curioso de engajado; já deduplicado por §1.7 |
| `cargo_grupo` | derivado de `cargo` por `cargo_grupo_regra` (§1.3); `outros` quando sem regra |
| `tamanho_empresa` | normalizado em 3 faixas (§1.4); `nao_informado` nos 63,6% sem dado |
| `is_teste` | §1.6 — sempre presente para que a exclusão seja visível, nunca silenciosa |

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
