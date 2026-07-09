# Arquitetura — Loupen Dashboard v2 (`index-v2.html`)

**Autor:** Aria (AIOX Architect)
**Data:** 2026-07-08
**Arquivo-alvo:** `index-v2.html` (NOVO — nunca sobrescrever `index.html`)
**Insumos:** `index.html` (2222 linhas, lido integralmente), `docs/diagnostico-marketing-v2.md` (Fase 1 aprovada), revisão técnica prévia (6 achados).
**Filosofia aplicada:** Architect-First — "Arquitetura perfeita, execução pragmática, qualidade garantida por testes". Este documento é o blueprint; a implementação é da próxima fase (`aiox-dev`).

---

## 0. Regra de ouro (inegociável — preservar em TODA mudança)

> **CPL real = investimento ÷ leads reais da Central de Leads** (`leadsReaisPorCampanha` / `normCanal`), NUNCA o `results`/`conv`/`cpl` auto-reportado pela plataforma.

Todo cálculo novo de retorno/eficiência que envolva contagem de leads DEVE usar leads reais. Métricas de plataforma (`results`, `costPerResult`, `conv`, `cpa`) só podem aparecer como dado operacional **rotulado como métrica-plataforma**. Nenhuma capacidade analítica existente pode ser perdida (baseline: CPL real, bucket `campanha|||conjunto|||criativo`, cruzamento por e-mail, `standardizeCampanha`, badge "sem mapear", disclaimers de escopo).

---

## 1. Mapa da arquitetura atual (Map Before Modify)

### 1.1 Fontes de dados (todas client-side)

| Variável global | Origem | Forma | Datas por linha? |
|---|---|---|---|
| `_allLeads` | Google Sheets `Conversoes` (gviz) | array de linhas `{c:[...]}` | **Sim** (`c[26]` ou `c[0]`) |
| `_allSalesforce` | Google Sheets SF (gviz) | array de objetos já normalizados | **Sim** (`dataCriacao`/`dataConversao`/`dataFechamento`) |
| `_adsCacheStore[range]` | webhook n8n `ADS_API_URL?start&end` | `{googleAds, metaAds, linkedIn, ga4, rdStation}` | **Não** — totais agregados por range |
| `_leadEmailMap` | derivado de `_allLeads` | `{email → {canal, campanha}}` | — |
| `_metaData`, `_criativoData` | derivados em memória | — | — |

**Índices de coluna de `_allLeads` (`r.c[i].v`) — referência para o dev:**
`c[0]` data (fallback) · `c[1]` evento/campanha · `c[2]` email · `c[3]` nome · `c[5]` empresa · `c[6]` cargo · `c[7]` porte · `c[8]` UTM campaign (primário) · `c[10]` conv_source · `c[14]` conv_channel · `c[15]` utm_source · `c[16]` criativo · `c[19]` conjunto · `c[24]` status · `c[26]` data (primário).

**Campos de `_allSalesforce` (já parseados em `loadSalesforce`):**
`origem`, `origemCRM`, `dataConversao`, `nome`, `email`, `empresa`, `dataCriacao`, `status`, `motivoRejeicao`, `nomeOpp`, `produto`, `fase`, `motivoPerda`, `valorOpp`, `valorNF`, `dataFechamento`, `isOpportunity`, `isLost`, `isWon`, `isOpen`, `canal`, `isMarketing`.

### 1.2 Camadas lógicas (implícitas, não separadas hoje)

```
[CONFIG]  PROPS, SHEET, ADS_API_URL, CORES, VIEWS           (linhas 708-728)
[HELPERS] fmt, fmtR, pct, brl, rcl, pill, statusChip,       (760-799)
          mkChart, mkLeg, mkBars, period, prevPeriod
[NORM]    normCargo, normPorte, normCanal, normEvento,       (804-902)
          parseDataLead, ga4ToLeadBucket, standardizeCampanha,
          inferCanalOrigem, inferPlataformaLead
[FETCH]   loadLeads, loadSalesforce, fetchAdsData(ForRange), (978-1378)
          fetchAdsDataPrev, _adsCacheStore
[CALC]    leadsInRange, salesforceInRange,                   (dispersos)
          leadsReaisPorCampanha, buildCriativoData
[RENDER]  loadOverview, loadGA4, loadMeta, loadLinkedIn,     (1026-2188)
          loadGoogleAds, loadRDStation, renderLeads,
          renderOportunidades, renderCriativos
[ORCH]    carregarTudo, setInterval                          (2199-2219)
```

**Diagnóstico estrutural:** hoje CALC e RENDER estão fundidos (cada `load*/render*` calcula E pinta no mesmo escopo). A v2 deve **extrair as funções de cálculo puras** (input → número, sem tocar o DOM) para viabilizar testes e reuso — sem reescrever os renders inteiros. Este é o único movimento estrutural relevante; o resto é adição incremental.

### 1.3 Infra reutilizável já existente (NÃO reinventar)

- **Trend período-a-período:** `trendHTML(cur, prev, invert)` + `prevPeriod()` + `setKpi(prefix, value, trendInner)` (1011-1024). Hoje só o Overview usa. É a base para o item Média #9.
- **Recorte por período:** `leadsInRange`, `salesforceInRange`, `period()`.
- **Erro de canal:** `showChannelError(prefix, channelData)` (1183) — banner por `status:"error"`. Só GA4/Meta/LinkedIn/GoogleAds chamam; falta o padrão em `fetchAdsDataPrev`.
- **Cache por range:** `_adsCacheStore` (1352) — evita refetch do mesmo range, mas não evita o reload periódico completo.

---

## 2. Bloco de configuração novo — `METAS` e benchmarks (itens 5, 12)

**Decisão de arquitetura (Config > Hardcoding):** criar um único objeto de configuração no topo do `<script>`, logo após `CORES`/`VIEWS`. Sem backend, sem build — editável direto no arquivo. Este objeto centraliza (a) metas de negócio configuráveis e (b) os benchmarks que hoje estão espalhados em `title=` de tooltips (CTR>2%, bounce<40%, CTR Search>3%, QS>=7).

```js
// ── METAS & BENCHMARKS (editável — sem backend) ──────────────
const METAS = {
  // Metas de negócio (null = sem meta definida, indicador não aparece)
  cplBlended:     { alvo: 150,  invert: true  }, // R$ — menor é melhor
  taxaQualif:     { alvo: 25,   invert: false }, // %
  roasBlended:    { alvo: 3.0,  invert: false }, // x
  winRate:        { alvo: 20,   invert: false }, // %
  lpConversion:   { alvo: 5,    invert: false }, // %
  ga4Conversion:  { alvo: 3,    invert: false }, // %
  cacPorGanho:    { alvo: 2000, invert: true  }, // R$
  // Benchmarks de referência (semáforo — não são metas de negócio)
  bench: {
    ctrMeta: 2, ctrSearch: 3, bounceOk: 40, bounceBad: 65, qualityScore: 7
  }
};
```

**Renderização visual da meta (proposta mínima):** helper `metaHTML(valorAtual, chaveMeta)` que devolve um selo colorido no `kpi-footer` (verde se atingiu, âmbar perto, vermelho abaixo — respeitando `invert`), no mesmo espaço onde hoje mora o `trendHTML`. Quando a meta e o trend coexistem no mesmo KPI, empilhar (trend em cima, meta embaixo) ou alternar por prioridade da view. Não requer nova biblioteca de gráfico.

**Trade-off:** objeto em JS (vs. arquivo YAML externo) — como o dashboard é single-file sem build/servidor, YAML externo exigiria fetch adicional e falharia em `file://`. Objeto JS inline é a forma mais simples que preserva a natureza single-file. Documentar no README "como ajustar metas".

---

## 3. Camada de cálculo nova — funções puras (item 1)

**Princípio:** cada função abaixo é **pura** (recebe dados + período, devolve número/objeto; não toca o DOM). Colocá-las num bloco `// ── CALC (v2) ──` logo após o bloco NORM (após linha ~902) e antes dos `load*`. Isso permite teste unitário isolado (ver §9) e reuso entre views.

### 3.1 Financeiro — ROAS / Receita / CAC (Alta #1)

```
financeSummary(sfRows, spendPorCanal) → {
  receitaGanhaTotal,        // Σ valorNF onde isWon (todos)
  receitaGanhaMkt,          // Σ valorNF onde isWon && isMarketing
  roasRealizado,            // receitaGanhaMkt / spendTotal   (ver nota de atribuição)
  roasProjetado,            // (pipeAberto + receitaGanhaMkt) / spendTotal
  cacPorOpp,                // spendTotal / nº oportunidades
  cacPorGanho,              // spendTotal / nº ganhos
  winRate                   // nº ganhos / nº oportunidades * 100
}
```

- **Consome:** `_allSalesforce` (via `salesforceInRange`), `spend` dos totais de `fetchAdsData()` (`googleAds/metaAds/linkedIn .totals.spend`).
- **NOTA DE ATRIBUIÇÃO (crítica — regra de ouro aplicada ao retorno):** ROAS blended deve usar **receita ganha marketing-atribuída** (`isMarketing`), não a receita total. Creditar receita de leads *comerciais* (cadastrados direto, sem rastreio de mídia) ao spend de ads infla o ROAS e repete o pecado do `results` do Meta, só que do lado do retorno. → **`roasBlended = receitaGanhaMkt ÷ spend`**. O KPI "Receita ganha" pode mostrar o total (com footer "X% atribuído a marketing"), mas o ROAS usa o atribuído.
- **Onde entra:** `loadOverview` (que hoje NÃO carrega Salesforce — precisará chamar `salesforceInRange` após garantir `_allSalesforce`) e `renderOportunidades`.

```
cacPorCanal(sfRows, spendPorCanalMap) → { [canal]: {leads, opp, ganhos, receita, spend, cacOpp, cacGanho, roas} }
```

- **Consome:** o mesmo `byCanal` já montado em `renderOportunidades` (1803-1810), estendido com `ganho` (Σ `valorNF` isWon por canal) e cruzado com `spendPorCanalMap` (Google ADS→`googleAds.totals.spend`, Meta ADS→`metaAds.totals.spend`, LinkedIn ADS→`linkedIn.totals.spend`).
- **Nota:** só os 3 canais pagos têm spend; canais "Orgânico/Direto/Base RD" ficam com spend 0 → CAC/ROAS "—" (não dividir por zero).

### 3.2 Leads reais por canal — corrige Overview (Alta #2)

```
leadsReaisPorCanal(leads, period) → { [canalNormalizado]: count }
```

- **Consome:** `_allLeads` filtrado por período (`leadsInRange`), agrupado por `normCanal(c[15], c[14], c[10])` — exatamente o `leadsByBucket` que já existe em `loadOverview` (1122-1123). **Extrair essa lógica para função nomeada** e reusar tanto no cruzamento Sessões×Leads quanto na tabela "Comparação de canais pagos".
- **Uso:** substituir na tabela do Overview a coluna "Resultados" (hoje `gA.conv`/`mA.results`/`lA.conv` — três definições) por **leads reais do canal**, e "Custo/result." por **spend do canal ÷ leads reais do canal** = CPL real por canal. Ver §4.1.

### 3.3 Taxas de conversão (Alta #3, #5, #6)

```
convRate(numerador, denominador) → number|null   // null se denom<=0 (mostra "—")
```

Aplicações (todas com dados 100% disponíveis):
- **LP (Alta #3):** `conversions ÷ sessions` por linha de `ga.landingPages` → nova coluna "Taxa conv." na tabela `lp-body`.
- **GA4 (Alta #5):** `conversions ÷ sessions` por canal (`ga-body`) e total (novo KPI ou footer).
- **UTM (Alta #5):** `conversions ÷ sessions` por campanha (`utm-body`).
- **ROAS criativo (Alta #6):** ver §3.4.

### 3.4 ROAS por campanha/criativo (Alta #6)

Estender o retorno de `buildCriativoData` (já calcula `spend`, `pipe`, `ganho`, `oportunidades` por campanha e por criativo, linhas 2034-2046). Adicionar por linha:

```
roasRealizado = ganho / spend            // realizado
roasProjetado = (pipe + ganho) / spend   // projetado
custoPorOpp   = spend / oportunidades
```

- **Consome:** dados JÁ presentes em `campanhaRows`/`criativoRows`. Custo praticamente zero.
- **Onde entra:** novas colunas nas tabelas `cr-campanha-body` (1124-1143) e KPIs da view Criativos.

### 3.5 Tempo de ciclo / velocidade de funil (Média #8)

```
tempoDeCiclo(sfRows) → {
  leadToOpp:   { mediaDias, medianaDias, n },   // dataCriacao → dataConversao (quando isOpportunity)
  oppToGanho:  { mediaDias, medianaDias, n }     // dataConversao → dataFechamento (quando isWon)
}
```

- **Consome:** `dataCriacao`, `dataConversao`, `dataFechamento` de `_allSalesforce` (hoje parseados mas **nunca usados** para duração). Diferença em dias = `(dataB - dataA)/86400000`. Ignorar linhas com data faltante ou negativa (dado sujo). Preferir **mediana** como destaque (robusta a outliers), média como secundária.
- **Onde entra:** dois KPIs novos na view Oportunidades.

### 3.6 Séries temporais (Média #7)

```
agruparPorPeriodo(rows, dateAccessor, granularidade) → [{ bucket:'YYYY-MM-DD', valor:n }]
```

- `granularidade` = `'dia'` (padrão) ou `'semana'`; escolher automaticamente: `dia` se período ≤ 31 dias, `semana` se maior (evita gráfico ilegível em 90d).
- **Consome:** `_allLeads` (via `parseDataLead(c[26]||c[0])`) e `_allSalesforce` (via `dataConversao||dataCriacao`) — ambos têm data por linha.
- **LIMITAÇÃO EXTERNA (ver §7):** dados de Ads (spend/dia) NÃO têm série client-side — o n8n devolve totais agregados por range. Série de ads = dependência de webhook, fora do escopo de código v2.

### 3.7 Taxa de qualificação por segmento (Média #11)

```
qualifPorSegmento(leads, dimensao) → [{ label, total, qualificados, taxa }]
```

- `dimensao` = função de bucket (`normCanal`, `normPorte`, `normCargo`).
- **Consome:** `_allLeads` (status qualificado = `c[24]` inclui "qualificado", padrão já usado em `renderLeads`).
- **Onde entra:** view Leads — adicionar % dentro/ao lado de cada barra em "Por canal"/"Por porte".

### 3.8 Padronização de CPL entre canais (Média #13)

```
cplRealPorCanal(canal, leads, spendPorCanalMap) → number|null
```

- Reusa `leadsReaisPorCanal` (§3.2) ÷ spend do canal. Dá **CPL real** também a Google e LinkedIn (hoje só Meta tem), via `normCanal`.
- **Decisão:** manter o CPL de plataforma (`t.cpa` Google, `t.cpl` LinkedIn) visível, mas **rotulado "CPL plataforma"**, e adicionar "CPL real" ao lado. Não remover o de plataforma (é o que o gestor vê no Ads Manager — capacidade preservada), mas o número de destaque/comparável passa a ser o real. Ver §4.

---

## 4. Onde cada métrica aparece (mapa view-a-view)

### 4.1 Overview (`view-overview`)
- **+ KPI "Receita ganha"** (verde) e **+ KPI "ROAS blended"** (roxo) — expandir grid de 6 p/ 8, ou trocar dois KPIs de menor prioridade. `loadOverview` passa a garantir `_allSalesforce` e chamar `financeSummary`.
- **Corrigir tabela "Comparação de canais pagos"** (1080-1103): coluna "Resultados" → **Leads reais** (`leadsReaisPorCanal`); "Custo/result." → **CPL real** (spend canal ÷ leads reais canal). Manter Investimento/Impressões/Cliques/CTR/% (dados de plataforma legítimos). Renomear cabeçalho "Resultados"→"Leads reais" e "Custo/result."→"CPL real".
- **+ Indicador de meta** no CPL blended e Taxa de qualificação (via `metaHTML`).

### 4.2 Leads (`view-leads`)
- **+ Taxa de qualificação por segmento** (§3.7) em "Por canal" e "Por porte".
- **+ Trend período-a-período** nos KPIs Total/Qualif (reusar `trendHTML` + `leadsInRange(prevPeriod)`).
- **+ Série temporal de leads/dia** (card novo com Chart.js line).
- Item Média #15 (rebaixar KPI "Eventos") está FORA DE ESCOPO (Baixa) — não mexer.

### 4.3 GA4 (`view-ga4`)
- **+ Coluna "Taxa conv."** (`conversions÷sessions`) em `ga-body` e **+ KPI/footer** de conversion rate total.
- **+ Indicador de meta** `ga4Conversion`.

### 4.4 UTM (`view-utm`)
- **+ Coluna "Taxa conv."** por campanha em `utm-body`.

### 4.5 Landing Pages (`view-lp`)
- **+ Coluna "Taxa conv."** (`conversions÷sessions`) em `lp-body`. Alterar ordenação padrão para respeitar eficiência (hoje ordem vem do backend por volume) — ou ao menos exibir a taxa para o usuário reordenar mentalmente. **Alta prioridade, dado 100% disponível.**
- **+ Indicador de meta** `lpConversion`.

### 4.6 Oportunidades (`view-oportunidades`)
- **+ KPI "Receita ganha"** (destaque) e **+ KPI "Win rate"** (Opp→Ganha).
- **+ KPIs "Tempo lead→opp" e "Tempo opp→ganho"** (mediana, §3.5).
- **Tabela "Por canal de origem"** (1811-1822): **+ colunas Ganho (R$), CAC/opp, CAC/ganho, ROAS** (§3.1 `cacPorCanal`).
- **Rótulo de escopo** no KPI "Qualificados" e no funil (desambiguar vs RD Station — Média #10): sufixo "(período/CRM)".
- Rotular "Ticket médio" → "Ticket médio de oportunidade" (confusão apontada no diagnóstico, baixo custo).

### 4.7 Criativos (`view-criativos`)
- **Tabela "Por campanha"** (1124-1143): **+ colunas ROAS realizado (Ganho÷Spend) e ROAS projetado ((Pipe+Ganho)÷Spend)** e **Custo/opp** (§3.4).
- **+ KPI ROAS** no grid da view.
- Preservar integralmente CPL real, bucket, fallback, badge "sem mapear".

### 4.8 Meta / LinkedIn / Google ADS
- **LinkedIn:** rotular KPI CPL como **"CPL plataforma"** e **+ "CPL real"** (§3.8). Média #13.
- **Google:** **+ "CPL real"** ao lado do CPA de plataforma (§3.8). Média #13.
- **Meta:** já tem CPL real — nada a mudar aqui (item Baixa do donut está fora de escopo).
- **+ Trend período-a-período** opcional nos KPIs de gasto (Média #9) — reusar `fetchAdsDataPrev`.

---

## 5. Resolução das inconsistências de definição (item 3)

| Inconsistência | Hoje | v2 | Garantia da regra de ouro |
|---|---|---|---|
| **Canais do Overview** | `gA.conv` + `mA.results`(inflado) + `lA.conv` na mesma coluna | Coluna única "Leads reais" via `leadsReaisPorCanal` (`normCanal`) + "CPL real" = spend÷leads reais | Mesma disciplina do Criativos/Meta, agora na tela mais vista |
| **CPL Meta vs LinkedIn vs Google** | Meta=real, LinkedIn=`conv`, Google=`cpa` | "CPL real" (spend canal ÷ leads reais canal) em todos; CPL de plataforma mantido mas rotulado "plataforma" | CPL real vira o número comparável; plataforma = operacional |

**Princípio unificador:** existe UMA função-fonte de leads por canal (`leadsReaisPorCanal`) e UMA de CPL real por canal (`cplRealPorCanal`). Toda tela que fala "leads" ou "CPL" comparável entre canais consome essas duas. Métricas de plataforma nunca mais aparecem sob o rótulo genérico "Resultados"/"CPL" sem qualificação.

---

## 6. Séries temporais e trend estendido (item 4)

### 6.1 Séries temporais — decisão
- **Client-side viável AGORA:** leads/dia e oportunidades|ganhos/semana (dados têm data por linha). Implementar em Leads e Oportunidades via `agruparPorPeriodo` + Chart.js line (biblioteca já carregada).
- **NÃO viável client-side:** spend/dia, impressões/dia de Ads — o n8n entrega totais agregados por range (`_adsCacheStore` guarda o agregado, não a série). Registrado como **dependência externa** (§7). Não inventar dado: se o dev quiser série de ads, é mudança de contrato do webhook, fora do escopo v2.

### 6.2 Trend período-a-período estendido (Média #9)
Reusar a tríade existente `prevPeriod()` + `trendHTML()` + `setKpi()`:
- **Leads/Oportunidades:** dados do período anterior via `leadsInRange(pp)` / `salesforceInRange(pp)` — client-side puro.
- **Criativos/Ads:** `fetchAdsDataPrev()` já existe e já é cacheado.
- Padrão: cada KPI candidato ganha um `<div class="kpi-footer" id="...-trend">` e uma chamada `setKpi`.

---

## 7. Dependências externas / limitações (não inventar dado)

| Item | Status | Ação no v2 |
|---|---|---|
| Séries temporais de Ads (spend/dia) | Backend entrega agregado por range | Documentar como limitação; NÃO implementar client-side |
| Engagement metrics GA4 (engagement rate, avg time) — Média #14 | `ga4.channels` hoje só traz sessions/users/conversions/bounceRate | **Verificar com o dono do n8n se o campo existe.** Se não: manter bounce rate, adicionar nota "engagement indisponível na resposta atual do backend". Fallback proposto: exibir bounce com selo de benchmark e um TODO comentado no código apontando o campo esperado (`engagementRate`, `averageEngagementTime`) para quando o webhook expuser. |
| Conversion value / ROAS nativo Google Ads | Depende de campo do backend | Fora do escopo v2 (usar ROAS real via cruzamento SF, que não depende do backend) |

**Regra:** nenhuma métrica que dependa de campo inexistente pode ser "preenchida" com placeholder que pareça dado real. Ou o campo existe (confirmar), ou vira nota honesta de indisponibilidade (padrão já usado no RD Station).

---

## 8. Plano de correção dos 6 achados técnicos (integrados ao v2)

### 8.1 XSS armazenado (CRÍTICO — prioridade máxima)
**Desenhar `esc()` para aplicação sistemática:**

```js
// Escapa TODO campo vindo de Sheets/CRM/webhook antes de interpolar em template string.
// Cobre contexto de texto E de atributo (double/single quote) numa única função.
function esc(v){
  if (v == null) return '';
  return String(v)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
```

**Como aplicar sistematicamente (não pontual):**
1. **Regra de ouro de escaping:** qualquer `${...}` cujo conteúdo venha de `_allLeads`, `_allSalesforce`, `fetchAdsData` (nomes de campanha/criativo/conjunto/anúncio/keyword), ou de `norm*`/`standardizeCampanha` que repassem strings de origem, DEVE ser `${esc(...)}`.
2. **Inventário de pontos a corrigir** (o dev deve varrer, não confiar nesta lista como exaustiva):
   - `renderLeads` `l-all` (~974): `c[3]` nome, `c[5]` empresa, status `c[24]`.
   - `loadOverview` `ovx-leads-body` (~1165): nome, empresa.
   - `renderOportunidades` `o-all` (~1856): nome, empresa, origem, motivo, status; e os `onclick="filtrar...('${...}')"` em `o-canal-body`/`o-origem-body` (~1814, ~1835).
   - `renderCriativos` (~1131, ~2179): nome, empresa, campanha, conjunto, criativo, e `title="${...}"`.
   - `loadMeta`/`loadLinkedIn`/`loadGoogleAds`: `c.name`, `a.name`, `r.text` de campanha/conjunto/anúncio/keyword (~1298, ~1312, ~1325, ~1396, ~1437, ~1468, ~1482).
   - Preenchimento de `<option>` em selects (`f-evento`, `o-origem`, `cr-campanha` etc.) — `value="${esc(v)}"` e label.
3. **Atenção ao contexto `onclick`:** o `.replace(/'/g,"\\'")` atual NÃO é escaping de HTML — só evita quebra de string JS. Manter esse escape para a sintaxe JS **E** envolver o valor visível em `esc()`. Melhor ainda (recomendação): migrar drill-downs de `onclick` inline para `data-*` + listener delegado (resolve XSS de atributo E acessibilidade — ver 8.4). Trade-off: mais mudança agora, mas elimina a classe inteira de bug.
4. **Teste de fumaça obrigatório:** injetar um lead/opp de teste com nome `<img src=x onerror=alert(1)>` e `"><script>` e confirmar que renderiza como texto literal em todas as tabelas.

### 8.2 Falhas silenciosas
- `fetchAdsDataPrev().catch(()=>null)` (~1030): trocar por `.catch(e=>{console.warn('prev period ads falhou:',e); return null;})` — nunca engolir sem log.
- Estender `showChannelError` a qualquer canal com `status:"error"` (Meta/LinkedIn/Google já chamam; auditar que todos chamam sempre, inclusive no path do Overview). Padrão único de banner de erro por canal (mesma UX do `ga4-error-banner`).
- `carregarTudo` já usa `Promise.allSettled` e mostra "Parcial" — preservar; adicionar `console.error` detalhado por fonte (já existe parcialmente).

### 8.3 Refresh ineficiente
**Decisão (trade-off explícito):**
- **Opção A (mínima):** manter `carregarTudo` completo no botão "Atualizar" e no primeiro load; mas o `setInterval` passa a recarregar **apenas a view ativa** + fontes baratas. Requer um mapa `LOADERS = { overview:loadOverview, leads:loadLeads, ... }` e uma variável `viewAtiva`.
- **Opção B (lazy load):** carregar cada view só quando ativada (on-demand), com cache por range. Reduz o load inicial de 8 fontes para 1-2.
- **Recomendação: A + cache já existente.** B é mais eficiente mas muda o comportamento de "tudo pronto ao abrir" e tem mais risco de regressão nos cruzamentos (Criativos depende de Leads+SF+Ads). A entrega 80% do ganho (elimina o reload periódico completo) com risco baixo. Documentar B como evolução futura.
- Preservar `_adsCacheStore`; considerar TTL (ex: invalidar cache do range após X min) para o refresh periódico realmente buscar dado novo — hoje o cache serviria dado velho indefinidamente para o mesmo range. **Ponto de atenção:** definir se o auto-refresh deve furar o cache (senão o "Atualizar" automático não atualiza nada). Sugestão: botão manual e auto-refresh invalidam o range atual antes de buscar; navegação entre views usa cache.

### 8.4 Acessibilidade
- Drill-downs em `<tr data-nav onclick>`, barras (`mkBars`) e fatias de gráfico são mouse-only.
- **Solução sistemática:** onde houver `onclick` de navegação, adicionar `tabindex="0"` `role="button"` e um handler de teclado (Enter/Space). Melhor implementar via **delegação de eventos** (um listener no container que lê `data-nav`/`data-action`), o que também ajuda o item 8.1 (tira JS de dentro do HTML). 
- `mkBars`: adicionar `tabindex`/`role`/`onkeydown` quando `onClickLabel` existir.
- Gráficos Chart.js: manter `role="img"`+`aria-label` (já existem); drill por clique no gráfico é um extra — garantir que a mesma ação exista via tabela acessível (a tabela é o caminho a11y).

### 8.5 Duplicação de código — ver §9 (decisão dedicada).

### 8.6 Código morto
- Remover `const RD_TOKEN = ''` (718) e o comentário 715-717 pode ser condensado (o histórico do incidente já está no git). Confirmar via busca que `RD_TOKEN` não é referenciado em nenhum outro ponto antes de remover.

---

## 9. Decisão sobre duplicação de código (item 7)

**Contexto:** `m-camps-body`, `m-adsets-body`, `m-ads-body`, `li-camps-body`, `ga-camps-body`, `ga-groups-body`, `ga-keywords-body`, `ga-ads-body` usam template literals quase idênticos (status chip + colunas numéricas + semáforo de CTR).

**Decisão: introdução PARCIAL de helper, NÃO refactor big-bang.**

- **Criar agora** um helper leve de célula/linha que já embuta `esc()`, e aplicá-lo **apenas** (a) ao código NOVO e (b) às tabelas que já serão tocadas por outros itens deste escopo (Overview canais, LP, GA4, UTM, Criativos, tabelas de CAC/ROAS). Isso mata dois coelhos: reduz duplicação onde já vamos mexer E garante `esc()` embutido no caminho de render novo.
- **NÃO migrar** as 8 tabelas de ads que não têm mudança funcional nesta v2. Motivo (Architect-First / risk mitigation "premature generalization" e "rule of 3"): reescrever tabelas estáveis sem cobertura de teste é risco de regressão puro, sem ganho funcional. A dedução total é um **refactor separado**, com seu próprio escopo e teste.
- **Forma sugerida do helper** (sem overengineering — descrição de contrato, não implementação):
  ```
  renderRows(tbodyEl, rows, colFns, emptyMsg, rowAttrs?)
    // colFns: array de (row)=>htmlCell; helper aplica esc() nas strings de texto;
    // rowAttrs: (row)=>string opcional p/ data-nav/tabindex (drill acessível)
  ```
- **Trade-off documentado:** dedup total agora = menos linhas mas mais superfície de regressão e escopo estourado; dedup parcial = convive duplicação temporária nas tabelas de ads, porém entrega segurança (esc) e menos duplicação no que muda. Escolho parcial. Registrar TODO no código: "refactor: migrar tabelas de ads restantes para renderRows (fora do escopo v2)".

---

## 10. Ordem de implementação recomendada (dependências)

**Fase 0 — Setup do arquivo (base para tudo):**
1. Copiar `index.html` → `index-v2.html`.
2. Remover código morto `RD_TOKEN` (8.6).
3. Adicionar `esc()` + `metaHTML()` + objeto `METAS` + helper `renderRows` (blocos novos).
4. Extrair `leadsReaisPorCanal` da lógica inline do Overview (base do §3.2 e §5).

**Fase 1 — Segurança (BLOQUEANTE, antes de qualquer deploy):**
5. Aplicar `esc()` sistematicamente em todos os pontos do inventário 8.1 + teste de fumaça XSS. *(Prioridade máxima — não avança sem isso.)*
6. Corrigir falhas silenciosas (8.2): log no `.catch` e `showChannelError` universal.

**Fase 2 — Ganhos de Alta prioridade (dados já disponíveis, baixo risco):**
7. Funções puras financeiras `financeSummary` + `cacPorCanal` (§3.1).
8. Overview: KPIs Receita/ROAS + correção da tabela de canais (Alta #1, #2) — depende de 4 e 7.
9. Oportunidades: Receita ganha + Win rate + CAC por canal (Alta #4) — depende de 7.
10. Criativos: ROAS por campanha/criativo (Alta #6) — depende de estender `buildCriativoData`.
11. Taxas de conversão GA4/UTM/LP (Alta #3, #5) — `convRate`, independente do resto.

**Fase 3 — Média prioridade:**
12. Padronização de CPL (Meta/LinkedIn/Google) via `cplRealPorCanal` (Média #13) — depende de 4.
13. Trend estendido (Média #9) — reusa infra existente.
14. Tempo de ciclo (Média #8) + rótulos de desambiguação de funil (Média #10).
15. Taxa de qualificação por segmento (Média #11).
16. Séries temporais leads/CRM (Média #7) — client-side.
17. Metas/benchmarks visuais (Média #12) — depende do objeto `METAS` (fase 0) e das métricas já existirem (fases 2-3).

**Fase 4 — Estrutural (maior risco, por último):**
18. Refresh eficiente (8.3) — refatora `carregarTudo`/`setInterval`; fazer por último para não desestabilizar as fases anteriores.
19. Acessibilidade via delegação de eventos (8.4) — idealmente junto de 18 (ambos mexem no wiring de eventos).

**Racional da ordem:** segurança primeiro (não-negociável); depois valor de negócio com dado pronto e risco baixo; deixar por último o que mexe no orquestrador/eventos (maior superfície de regressão). Metas (17) vêm depois das métricas existirem. Engagement GA4 (Média #14) entra só se o backend confirmar o campo (§7) — caso contrário, vira nota.

---

## 11. Plano de testes / validação (escape hatch de qualidade)

Como não há framework de teste no single-file, a rede de segurança é **funções puras testáveis + verificação observacional**:

1. **Unit (funções puras da §3):** extrair para um `<script>` de teste temporário ou console — alimentar `financeSummary`, `convRate`, `tempoDeCiclo`, `leadsReaisPorCanal` com fixtures pequenas e conferir números à mão. São puras justamente para isso.
2. **XSS smoke test (obrigatório):** payloads `<img src=x onerror=...>`, `"><script>`, `';alert(1);'` em nome/empresa/campanha; confirmar render literal em todas as tabelas e nos `title=`/`onclick`.
3. **Regressão de paridade:** abrir `index.html` e `index-v2.html` lado a lado no mesmo período; os números que NÃO mudaram de definição devem bater (CPL real Meta, funis, contagens). Divergência só é esperada onde a definição mudou de propósito (canais do Overview, CPL Google/LinkedIn).
4. **Divisão por zero:** períodos sem leads/opp/spend → todos os novos indicadores mostram "—", nunca `NaN`/`Infinity`.
5. **Erro de fonte:** simular `status:"error"` de um canal e período vazio → banners aparecem, dashboard não quebra (`Promise.allSettled` preservado).
6. **A11y:** navegar drill-downs só por teclado (Tab + Enter).

---

## 12. Registro de decisões autônomas (AUTO-DECISION)

- `[AUTO-DECISION]` Metas em objeto JS inline vs YAML externo → **objeto JS inline (`METAS`)** (razão: single-file sem build/servidor; YAML exigiria fetch e quebraria em `file://`).
- `[AUTO-DECISION]` ROAS blended usa receita total ou atribuída a marketing → **receita marketing-atribuída (`isMarketing`)** (razão: creditar receita comercial não-rastreada ao spend infla ROAS e viola o espírito da regra de ouro no lado do retorno).
- `[AUTO-DECISION]` Dedup de tabelas: big-bang vs parcial → **parcial (só código novo + tabelas já tocadas)** (razão: risk mitigation — reescrever tabelas estáveis sem teste é regressão sem ganho funcional).
- `[AUTO-DECISION]` Refresh: lazy-load total vs refresh só da view ativa → **refresh só da view ativa (Opção A)** (razão: 80% do ganho com risco baixo; lazy-load muda comportamento e arrisca os cruzamentos).
- `[AUTO-DECISION]` CPL Google/LinkedIn: substituir plataforma ou adicionar real → **adicionar CPL real + rotular o de plataforma** (razão: preservar capacidade — o CPL de plataforma é o que o gestor vê no Ads Manager; não remover, apenas desambiguar).
- `[AUTO-DECISION]` Séries temporais de Ads → **fora do escopo client-side** (razão: backend entrega agregado por range; implementar exigiria mudança de contrato do webhook — não inventar dado).
- `[AUTO-DECISION]` Drill-down XSS + a11y → **recomendar migração para delegação de eventos + `data-*`** (razão: resolve XSS de atributo e acessibilidade de uma vez; trade-off de mais mudança registrado).

---

## 13. Flags de segurança e compatibilidade

- **Segurança:** o XSS armazenado (8.1) é a maior exposição — campos de formulário público chegam via Sheets sem sanitização. É bloqueante para deploy. Segredos já foram removidos do client (histórico em 715-717) — manter assim; nenhum token novo pode voltar ao arquivo (regra pós-incidente 2026-07-02).
- **Backward-compat:** `index-v2.html` é arquivo novo; `index.html` permanece intocado como rollback imediato. Todos os IDs de elemento e nomes de função preservados exceto onde há adição — reduz risco de quebrar integrações externas que dependam do DOM.
- **Capacidade preservada (gold standard):** nenhuma métrica/segmentação existente é removida; a v2 é aditiva (exceto a redefinição consciente de "Resultados/CPL" dos canais, que é correção de erro apontada e aprovada no diagnóstico).
```
