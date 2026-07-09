# Especificação de UX/UI — Loupen Dashboard v2 (`index-v2.html`)

**Autora:** Uma (AIOX UX Design Expert)
**Data:** 2026-07-08
**Insumos:** `index.html` (design system atual, lido), `docs/diagnostico-marketing-v2.md` (Fase 1), `docs/arquitetura-v2.md` (Fase 2, aprovada).
**Destinatário:** `aiox-dev` (Fase 4 — implementação).
**Filosofia:** estender o design system existente, nunca reinventá-lo. Toda decisão abaixo reusa tokens, classes e helpers que já existem. Onde há classe/CSS nova, ela é aditiva e nomeada no mesmo padrão do arquivo.

> **Regra de ouro herdada (inegociável):** "CPL real" e "Leads reais" sempre vêm de `leadsReaisPorCanal`/`leadsReaisPorCampanha`. Métricas de plataforma (`results`/`conv`/`cpa`/`cpl`) só aparecem **rotuladas como plataforma**. A UX abaixo materializa essa distinção com selos visuais — a desambiguação é responsabilidade de design, não só de cálculo.

---

## 0. Princípios de design da v2 (contrato visual)

1. **Aditivo, não disruptivo.** O usuário atual não pode se sentir perdido. KPIs novos entram no mesmo molde `.kpi`; colunas novas entram nas `.tbl` existentes; séries novas usam `mkChart`. Nenhum layout é reconstruído.
2. **Cor = semântica, já estabelecida.** Mantém-se o vocabulário atual: `blue` = volume/tráfego, `green` = qualidade/receita positiva, `amber` = custo/atenção, `red` = risco/rejeição, `purple` = investimento/mídia. Métricas novas herdam essa gramática (ver §1).
3. **Número comparável ≠ número de plataforma.** Sempre que dois números de mesma natureza coexistem (CPL real vs plataforma, ROAS realizado vs projetado), o número "verdade do projeto" é o de **destaque** (`.kpi-value` / primeira coluna) e o de plataforma é **secundário** (footer / coluna rotulada / `.t-sub`).
4. **Honestidade sobre vazio.** `—` para divisão por zero ou dado indisponível, nunca `NaN`/`0` enganoso (padrão já existente — preservar).
5. **Tudo que dá drill-down é operável por teclado.** Requisito de UX, não opcional (ver §6).

---

## 1. Sistema visual das métricas novas (mapa cor × componente)

Cada métrica nova recebe cor, componente-host e ícone Tabler (a família de ícones já usada, prefixo `ti ti-`). Nada aqui exige biblioteca nova.

| Métrica nova | Cor (`.kpi.<cor>`) | Componente | Ícone Tabler | Racional da cor |
|---|---|---|---|---|
| Receita ganha | `green` | KPI + footer "% atribuído a mkt" | `ti-cash` | Receita realizada = resultado positivo |
| ROAS blended | `purple` | KPI | `ti-trending-up` | Retorno sobre investimento (mídia = roxo) |
| ROAS realizado / projetado (criativo) | `purple` | 2 colunas na `.tbl` | — | Mesmo domínio de mídia |
| CAC por opp / por ganho | `amber` | KPI + colunas na tabela por canal | `ti-target-arrow` | Custo = atenção |
| Win rate | `green` | KPI | `ti-trophy` | Eficácia comercial = qualidade |
| Taxa conv. (LP/GA4/UTM) | herda a cor da view | coluna na `.tbl` + KPI/footer | `ti-percentage` | Não muda a identidade da view |
| Tempo de ciclo (lead→opp, opp→ganho) | `blue` | 2 KPIs | `ti-clock` | Métrica de fluxo/tempo, neutra |
| Taxa de qualificação por segmento | `green` | sufixo `%` na `.bar-row` | — | Qualidade dentro do volume |
| Meta vs realizado | selo dinâmico (verde/âmbar/vermelho) | `metaHTML()` no `.kpi-footer` | `ti-flag` | Semáforo — cor calculada |
| Série temporal (leads/dia, opp/semana) | `blue` (leads), `green`+`purple` (opp/ganho) | card com `mkChart` line | `ti-chart-line` | Consistente com nav "Google Analytics" (line) |
| CPL real vs plataforma | `green` (real) / `muted` (plataforma) | KPI + footer / 2 colunas | — | Real = verdade; plataforma = operacional |

### 1.1 Classes CSS novas (aditivas — colocar no fim do `<style>`)

Só três acréscimos são necessários; o resto reusa o que existe.

```css
/* Selo de meta — reusa as cores do design system, semáforo calculado por metaHTML() */
.meta-pill{display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;
  padding:2px 7px;border-radius:5px;font-family:var(--mono);letter-spacing:.02em}
.meta-pill i{font-size:11px}
.meta-hit  {background:var(--green-dim);color:var(--green)}   /* atingiu / superou a meta */
.meta-near {background:var(--amber-dim);color:var(--amber)}   /* dentro de ~15% da meta */
.meta-miss {background:var(--red-dim);color:var(--red)}       /* abaixo (ou acima, se invert) */
.meta-none {background:var(--surface2);color:var(--muted)}    /* sem meta definida em METAS */

/* Selo de escopo de rótulo (CPL real vs plataforma, escopo de funil) */
.scope-tag{display:inline-flex;align-items:center;font-size:9px;font-weight:600;
  padding:1px 6px;border-radius:4px;text-transform:uppercase;letter-spacing:.05em;
  vertical-align:middle;cursor:help}
.scope-real {background:var(--green-dim);color:var(--green)}  /* "REAL" — leads/CPL reais */
.scope-plat {background:var(--surface2);color:var(--muted)}   /* "PLATAFORMA" — auto-reportado */
.scope-base {background:var(--blue-dim);color:var(--blue)}    /* "BASE RD" — não-temporal */
.scope-period{background:var(--purple-dim);color:var(--purple)} /* "PERÍODO / CRM" */

/* KPI footer com trend + meta empilhados (quando coexistem) */
.kpi-footer .meta-pill{margin-top:4px}
```

> **Por que `--mono` no `.meta-pill`?** O arquivo já usa `--mono` para todo número (`.kpi-value`, `.bar-val`, colunas numéricas). O selo de meta carrega um número (o alvo), então segue a mesma regra tipográfica — mantém coesão visual.

---

## 2. Hierarquia de informação — view a view

Regra de grid: o CSS já tem `kpi-grid` (5), `kpi-grid-4`, `kpi-grid-6`. A v2 introduz **`kpi-grid-8`** (aditiva) só onde estritamente necessário. Em telas ≤ 1300px (o `.main` tem `max-width:1300px`), 8 KPIs numa linha ficam com ~150px cada — ainda legível para o `.kpi-value` de 24px. Acima disso, quebra em 2 linhas de 4 é aceitável.

```css
.kpi-grid-8{display:grid;grid-template-columns:repeat(8,1fr);gap:10px;margin-bottom:24px}
@media(max-width:1100px){.kpi-grid-8{grid-template-columns:repeat(4,1fr)}}
```

### 2.1 Overview (`view-overview`) — a tela mais vista, prioridade máxima

**Grid de KPIs: de 6 → 8.** Ordem da esquerda para a direita seguindo a leitura "gasto → volume → eficiência → qualidade → **retorno**":

| # | KPI | Estado | Cor | Notas |
|---|---|---|---|---|
| 1 | Investimento total | existe | purple | mantém |
| 2 | Leads | existe | blue | mantém |
| 3 | **Receita ganha** | **NOVO** | green | footer: "X% atribuído a marketing" |
| 4 | **ROAS blended** | **NOVO** | purple | footer: `metaHTML(roas, 'roasBlended')` |
| 5 | CPL blended | existe | amber | footer: trend **+** `metaHTML(cpl, 'cplBlended')` |
| 6 | Taxa de qualificação | existe | green | footer: trend + `metaHTML(taxa, 'taxaQualif')` |
| 7 | Sessões | existe | green | mantém |
| 8 | Rejeição | existe | red | mantém |

> **Decisão de layout `[AUTO-DECISION]`:** expandir para `kpi-grid-8` em vez de remover KPIs existentes → razão: nenhum dos 6 atuais é redundante no Overview (diagnóstico não pede corte), e "receita/ROAS" são o gap #1 — merecem estar acima da dobra, não escondidos. O trade-off (cards mais estreitos) é aceitável porque `.kpi-value` mono a 24px cabe em ~150px.

**Colocação de Receita+ROAS lado a lado (posições 3-4):** intencional — o olho lê "Investimento (1) … Receita (3) / ROAS (4)" e fecha o loop financeiro visualmente. Não separá-los.

**Tabela "Comparação de canais pagos" (correção crítica):**
- Cabeçalho: `Resultados` → **`Leads reais`** com `<span class="scope-tag scope-real" title="...">REAL</span>` ao lado; `Custo/result.` → **`CPL real`** com o mesmo selo.
- Dados: coluna Leads reais = `leadsReaisPorCanal(...)[canal]`; coluna CPL real = `spend ÷ leadsReais` (ou `—` se leads=0).
- Colunas Investimento/Impressões/Cliques/CTR/% ficam **iguais** (dados de plataforma legítimos, sem selo — são operacionais de mídia, não competem com "leads/CPL").
- A `.section-badge` da tabela ganha texto adicional: `clique numa linha para ver detalhes · leads reais da Central de Leads`.

Exemplo do cabeçalho (ilustrativo):
```html
<th>Leads reais <span class="scope-tag scope-real"
   title="Leads efetivamente recebidos na Central de Leads e atribuídos a este canal (normCanal). NÃO é o 'results'/'conv' auto-reportado pela plataforma de anúncios.">REAL</span></th>
<th>CPL real <span class="scope-tag scope-real"
   title="Investimento do canal ÷ leads reais do canal. É o custo por lead comparável entre canais — a métrica que o projeto trata como verdade.">REAL</span></th>
```

### 2.2 Leads (`view-leads`)
- KPIs: mantém `kpi-grid-4`. Adicionar **trend** no Total e no Qualif (via `setKpi` + `leadsInRange(prevPeriod)`) — os cards já têm espaço de `.kpi-footer` (hoje vazio); adicionar `<div class="kpi-footer" id="l-total-trend">` e `id="l-taxa-trend"`.
- **Taxa de qualificação por segmento:** nas barras de "Por canal" e "Por tamanho de empresa", anexar o `%` de qualificados ao `.bar-val` OU como sufixo cinza. Especificação: manter o volume como número principal e adicionar um segundo span cinza. Ver §2.9 (padrão de barra com taxa).
- **Card novo de série temporal "Leads por dia"** — inserir logo após o `kpi-grid-4`, antes das barras (é a leitura de momentum, alto na hierarquia). Ver §3.

### 2.3 GA4 (`view-ga4`)
- Tabela `ga-body`: **+ coluna "Taxa conv."** (`conversions÷sessions`), à direita das Conversões, com semáforo reusando a lógica de `rcl` invertida (aqui mais alto = melhor, então cor verde acima da meta). Simplicidade: usar cor verde se ≥ `METAS.ga4Conversion.alvo`, âmbar se perto, muted caso contrário.
- KPI de Rejeição (`ga-bounce`): adicionar `metaHTML` opcional não; em vez disso adicionar um **KPI/footer de conversion rate total**. Decisão: acrescentar `.kpi-footer` ao KPI "Conversões" (`ga-conv`) com "Taxa: X% · `metaHTML`", evitando um 5º card que quebraria o `kpi-grid-4`.

### 2.4 UTM (`view-utm`)
- Tabela `utm-body`: **+ coluna "Taxa conv."** por campanha. Mesmo tratamento visual da GA4. Sem novo KPI.

### 2.5 Landing Pages (`view-lp`)
- Tabela `lp-body`: **+ coluna "Taxa conv."** (`conversions÷sessions`). Esta é a métrica-fim — deve ser a **coluna de destaque visual**: renderizar o valor em `font-family:var(--mono);font-weight:600` e aplicar o semáforo de meta (`lpConversion`). Adicionar `.chart-click-hint` abaixo da tabela: "Ordenado por volume de sessões. A LP mais eficiente é a de maior taxa de conversão, não a de mais sessões." (resolve o viés de ordenação apontado no diagnóstico sem reordenar o backend).

### 2.6 Oportunidades (`view-oportunidades`)
- KPIs: adicionar **Receita ganha** (green, destaque), **Win rate** (green), **Tempo lead→opp** (blue) e **Tempo opp→ganho** (blue). Se o grid atual for `kpi-grid` (5) ou `kpi-grid-4`, migrar para **`kpi-grid-8`** ou duas linhas de 4. Recomendação: duas linhas de `kpi-grid-4` (financeiro em cima, tempo/qualidade embaixo) — mais legível que 8-em-linha para esta view densa.
  - Linha 1 (resultado): Receita ganha · Win rate · Valor em pipeline (existe) · Ticket médio de oportunidade (renomear).
  - Linha 2 (velocidade/qualidade): Qualificados `(período/CRM)` · Tempo lead→opp · Tempo opp→ganho · (KPI existente restante).
- **Selo de escopo (Média #10):** no KPI "Qualificados" adicionar `<span class="scope-tag scope-period" title="...">PERÍODO / CRM</span>` — desambigua do "MQL" da view RD Station. Ver §4.
- **Tabela "Por canal de origem":** + colunas `Ganho (R$)`, `CAC/opp`, `CAC/ganho`, `ROAS`. Canais sem spend (Orgânico/Direto/Base RD) mostram `—` nas colunas de CAC/ROAS.
- Rótulo: "Ticket médio" → "Ticket médio de oportunidade" (com `title` explicando que é `valorOpp` de oportunidades, não de ganhos).
- **Card novo "Oportunidades e ganhos por semana"** (série temporal, §3) — abaixo do funil.

### 2.7 Criativos (`view-criativos`)
- KPI grid: **+ KPI ROAS** (purple). 
- Tabela "Por campanha" (`cr-campanha-body`): + colunas `ROAS realizado` (Ganho÷Spend) e `ROAS projetado` ((Pipe+Ganho)÷Spend) e `Custo/opp`. 
  - **Desambiguação realizado vs projetado:** ROAS realizado em `--green` (dinheiro no bolso), ROAS projetado em `--purple` com o `scope-tag` "PROJ." (`title`: "Inclui pipeline em aberto — valor probabilístico, ainda não fechado"). Isso separa visualmente o certo do provável, como o diagnóstico pede para "Pipe + Ganho".
- Preservar integralmente CPL real, bucket, badge "sem mapear".

### 2.8 Meta / LinkedIn / Google ADS — o selo "CPL real" vs "CPL plataforma"
- **Meta:** já tem CPL real. Adicionar o `scope-tag scope-real` "REAL" ao lado do `.kpi-label` do CPL, para consistência com Google/LinkedIn (educação visual — o usuário aprende o selo aqui, onde a prática já é correta).
- **LinkedIn:** KPI CPL atual usa `t.cpl` (plataforma). Renomear label para "CPL" + `scope-tag scope-plat` "PLATAFORMA"; **adicionar footer** com "CPL real: R$ X" (`cplRealPorCanal('LinkedIn ADS', ...)`) em `--green`. O número de destaque no card continua sendo o de plataforma (é o que o gestor vê no Ads Manager), mas o real aparece no footer rotulado — sem quebrar a expectativa de quem já usa a tela.
- **Google:** idem LinkedIn — CPA de plataforma no destaque com selo "PLATAFORMA", "CPL real: R$ X" no footer.
- **Trend período-a-período** opcional nos KPIs de gasto (reusa `fetchAdsDataPrev`) — `.kpi-footer` + `setKpi`.

> **Decisão `[AUTO-DECISION]`:** no Meta o selo é "REAL" no destaque; no Google/LinkedIn o destaque continua "PLATAFORMA" e o real vai pro footer. Razão: no Meta o CPL já é o real (não há o que rebaixar); no Google/LinkedIn substituir o número de destaque quebraria a paridade com o Ads Manager que o gestor confere — preservar capacidade (regra de ouro da arquitetura §5) e apenas desambiguar.

### 2.9 Padrão de barra com taxa de qualificação (`.bar-row`)
Sem nova classe. Reusa `.bar-row`; o `.bar-val` continua sendo o volume; adiciona-se um span cinza de taxa. Ilustrativo:
```html
<div class="bar-row">
  <div class="bar-label">Meta ADS</div>
  <div class="bar-track"><div class="bar-fill" style="width:72%;background:var(--blue)"></div></div>
  <div class="bar-val">128 <span style="color:var(--green);font-size:11px">· 34%</span></div>
</div>
```
O `· 34%` em `--green` = "34% desses leads são qualificados". A cor verde reforça "qualidade". A largura da barra continua representando volume (não muda a semântica atual). `title` no `.bar-row`: "128 leads, 34% qualificados".

---

## 3. Visualização de série temporal (novidade da v2)

**Tipo escolhido: gráfico de LINHA com área preenchida suave (`fill: 'origin'` com gradiente de baixa opacidade).** Racional:
- **Linha** (não barra) porque série temporal comunica *tendência/momentum*, que é a leitura que o diagnóstico pede ("Growth usa a curva").
- **Área leve** (fill com ~12% de opacidade, mesma proporção dos tokens `-dim`) diferencia visualmente das barras de distribuição existentes e dos donuts — deixa claro "isto é evolução no tempo", não "composição".
- Usa `mkChart(id, 'line', ...)` — já suportado, Chart.js 4.4.1 carregado. Sem lib nova.

### 3.1 Especificação dos dois gráficos

**Leads por dia (view Leads):**
- Eixo X: buckets de `agruparPorPeriodo(leads, 'dia'|'semana')` — `dia` se período ≤ 31 dias, `semana` acima (decisão da arquitetura §3.6). Rótulos X curtos: `DD/MM`.
- Eixo Y: contagem de leads, começando em 0.
- 1 dataset, cor `--blue` (`#3b82f6`), `borderWidth:2`, `pointRadius:0` (limpo; `pointRadius:3` no hover), `tension:0.3` (curva suave), `fill:true` com backgroundColor `rgba(59,130,246,0.12)`.
- `scales: scOpts()` (já existe — grid discreto, ticks `#7a7f8a`).

**Oportunidades e ganhos por semana (view Oportunidades):**
- 2 datasets sobrepostos: "Oportunidades" (`--purple` `#a78bfa`) e "Ganhos" (`--green` `#22c55e`).
- Mesmo estilo de linha; `fill:false` aqui (duas séries sobrepostas com área poluiriam) — só linhas + legenda.
- Legenda: usar o padrão `.legend`/`.leg`/`.leg-dot` já existente (não a legend nativa do Chart.js, que está `display:false` em `mkChart`). Montar via `mkLeg` adaptado ou HTML manual com as 2 cores.

### 3.2 Sinalização de "novidade v2" (sem poluir)
- `.section-badge` do card de série recebe o texto **"série temporal"** + ícone `ti-sparkles` no `.section-title` — o mesmo mecanismo de badge já usado nas outras seções, então não é um enfeite estranho; apenas comunica que é uma leitura nova.
- **NÃO** usar banner "NOVO" piscando nem cor fora da paleta. A distinção do tipo (linha com área vs donut/barra) já é o sinal visual primário; o badge textual é o reforço.
- `.chart-click-hint` abaixo: "Evolução no período selecionado. Granularidade automática: diária até 31 dias, semanal acima." (honestidade sobre a agregação).

> **Limitação a exibir (arquitetura §7):** NÃO há série de spend/dia de Ads (backend entrega agregado por range). Não criar gráfico de gasto no tempo. Se algum card sugerir isso, adicionar `.chart-click-hint`: "Série de investimento por dia não disponível — o backend entrega totais por período." Não inventar dado.

---

## 4. Desambiguação dos 3 funis (rótulos/badges de escopo)

Três funis coexistem com números de "Oportunidades"/"Qualificados" diferentes. Solução visual: **um selo de escopo fixo por funil**, sempre visível no cabeçalho do funil e coloc­ado junto de cada KPI ambíguo. Usa `.scope-tag` (§1.1). O `title` de cada selo dá a definição exata.

| Funil / view | Selo | Classe | `title` exato sugerido |
|---|---|---|---|
| RD Station Marketing (Total→Leads→MQL→Opp→Clientes) | **BASE RD** | `scope-base` | "Estado atual de TODA a base do RD Station Marketing. NÃO é filtrado pelo período do topo — a API de segmentações não aceita data." |
| Overview (Sessões→Leads→Qualif) e Leads | **PERÍODO** | `scope-period` (usar variante azul se preferir distinguir de CRM) | "Leads recebidos DENTRO do período selecionado no topo, via Central de Leads (RD Station)." |
| Oportunidades (Leads→Qualif→Opp→Ganha) | **PERÍODO / CRM** | `scope-period` | "Oportunidades do CRM comercial (Salesforce) no período, atribuídas por cruzamento de e-mail. Difere do 'Opp' da view RD Station, que é a base inteira." |

**Onde ancorar:**
- No cabeçalho de cada funil, ao lado do `.section-title`: `<span class="scope-tag scope-base">BASE RD</span>` (posição igual à `.section-badge`, mas com significado de escopo).
- No KPI "Oportunidades" do RD Station: adicionar o selo ao `.kpi-label`. No KPI "Qualificados"/"Oportunidades" da view Oportunidades: selo "PERÍODO / CRM".
- O disclaimer textual do RD Station (linha 335) **permanece** — o selo é o reforço rápido, o disclaimer é o detalhe. Não remover um pelo outro.

**Regra:** o selo de escopo é sempre `cursor:help` com `title` — segue o padrão de tooltip do arquivo. Nunca abre modal.

---

## 5. Indicador de meta vs. realizado — o que `metaHTML()` gera

`metaHTML(valorAtual, chaveMeta)` lê `METAS[chaveMeta]` (`{alvo, invert}`) e devolve um `.meta-pill`. Renderiza **dentro do `.kpi-footer`**, no mesmo espaço do `trendHTML`. Quando ambos existem, empilham (trend em cima, meta embaixo — o `.kpi-footer .meta-pill{margin-top:4px}` cuida disso).

### 5.1 Lógica de cor (semáforo)
Seja `alvo` a meta e `v` o valor atual. Definir `ratio`:
- Se `invert:false` (mais é melhor, ex: ROAS, win rate, taxa conv.): `ratio = v / alvo`.
- Se `invert:true` (menos é melhor, ex: CPL, CAC): `ratio = alvo / v`.

Depois:
| Condição | Classe | Selo | Ícone |
|---|---|---|---|
| `ratio >= 1` | `meta-hit` (verde) | "✓ meta R$150" (mostra o alvo formatado) | `ti-flag-check` |
| `0.85 <= ratio < 1` | `meta-near` (âmbar) | "≈ meta R$150" | `ti-flag` |
| `ratio < 0.85` | `meta-miss` (vermelho) | "✗ meta R$150" | `ti-flag-off` |
| `METAS[chave] == null` ou sem dado | `meta-none` (muted) | "sem meta" | `ti-flag` |

- O selo **sempre mostra o valor-alvo** (não só o status), para o usuário saber contra o que está sendo medido sem abrir tooltip. Formatação do alvo respeita o tipo: `R$` para custo/CAC, `%` para taxas, `x` para ROAS (o dev passa um formatador ou o tipo vem de `METAS`).
- Threshold de 0.85 (≈15%) é a "zona âmbar" — ajustável; documentar no README junto de `METAS`.
- `title` do selo: "Meta: {alvo}. Atual: {v}. {'Acima'|'Dentro de 15%'|'Abaixo'} da meta." — dá o detalhe completo no hover.

Exemplo de saída (ilustrativo, CPL blended abaixo da meta, invert):
```html
<span class="meta-pill meta-miss" title="Meta: R$ 150,00. Atual: R$ 212,00. Abaixo da meta.">
  <i class="ti ti-flag-off"></i>✗ meta R$150
</span>
```

### 5.2 Onde `metaHTML` é chamado (chaves de `METAS`)
`cplBlended`, `taxaQualif` (Overview) · `roasBlended` (Overview) · `winRate` (Oportunidades) · `lpConversion` (LP) · `ga4Conversion` (GA4) · `cacPorGanho` (Oportunidades). Só aparece onde `METAS[chave].alvo != null` — se o gestor não definiu meta, o selo não polui (mostra `meta-none` discreto ou é omitido; recomendação: **omitir** quando `null`, para não sujar).

---

## 6. Acessibilidade de teclado — padrão de drill-down (requisito de UX)

**Problema atual:** drill-downs são `onclick` inline em `<tr>`, barras (`mkBars`) e fatias de gráfico — mouse-only. 6 `aria-*`, 6 `role=`, zero `tabindex`/handler de teclado.

**Padrão-alvo (delegação de eventos + `data-*`):** todo elemento navegável recebe `tabindex="0"`, `role="button"`, `data-nav` (e `data-nav-arg` quando há argumento) e um `aria-label` descritivo. Um único listener no container captura click **e** keydown (Enter/Space). Isso resolve simultaneamente a11y e o XSS de atributo (arquitetura §8.1/8.4).

### 6.1 Contrato de marcação (o dev implementa assim)

**Linha de tabela navegável** — substituir `onclick="showView('meta', true)"` por:
```html
<tr data-nav="meta" data-nav-drill="true" tabindex="0" role="button"
    aria-label="Abrir detalhes de Meta ADS">
```
CSS de foco (aditivo — hoje só há `:hover`):
```css
.tbl tr[data-nav]:focus-visible,
.bar-row[data-nav]:focus-visible,
.kpi-nav:focus-visible{
  outline:2px solid var(--blue);
  outline-offset:-2px;
  border-radius:6px;
  background:var(--surface2);
}
```
> Usar `:focus-visible` (não `:focus`) para não mostrar o anel ao clicar com mouse — só na navegação por teclado. O feedback visual de foco reusa `--blue` (a cor de "ativo/interativo" já estabelecida em `.nav-item.active`, `.kpi-nav:hover`).

**Barras (`mkBars` com `onClickLabel`):** quando `onClickLabel` é função, cada `.bar-row` recebe `data-nav-label`, `tabindex="0"`, `role="button"`, `aria-label="Filtrar por {label}"`. O listener delegado lê `data-nav-label`. Remove-se o `onclick="(fn)('${safeLabel}')"` inline (que hoje só escapa aspas de JS, não HTML).

**Gráficos Chart.js:** mantêm `role="img"` + `aria-label` (já existem). O clique no gráfico é um **extra**, não o caminho a11y — a **tabela equivalente é o caminho acessível** (toda distribuição em gráfico tem tabela/lista correspondente na mesma view). Adicionar ao `.chart-click-hint`: nada muda visualmente, mas garantir que a ação do clique no gráfico também exista via tabela navegável por teclado.

### 6.2 Ordem de tab e feedback
- **Ordem de tab:** segue a ordem do DOM (topbar → filtros → KPIs → cards/tabelas). Não usar `tabindex` positivo (>0) — só `0`. A ordem natural do DOM já corresponde à hierarquia visual.
- **Feedback de ativação:** ao acionar via teclado, a mesma transição visual do clique (ex: `scrollToCard` já pisca a borda azul por 900ms — reusar). Para drill que troca de view, o foco deve ir para o `.page-title` da nova view (`tabindex="-1"` + `.focus()`) para o leitor de tela anunciar a mudança de contexto.
- **Enter e Space** ambos ativam (padrão `role="button"`); `Space` deve `preventDefault` para não rolar a página.
- **Breadcrumb de volta** (`#drill-breadcrumb`): já é clicável; adicionar `tabindex="0"` `role="button"` `aria-label="Voltar à Visão geral"`.

### 6.3 Aria em elementos de estado
- KPIs com trend/meta: o `.kpi-value` deve ter o número; o selo de meta deve ter `title` (já vira `aria-label` acessível ao hover, mas para leitor de tela adicionar `aria-label` no `.meta-pill` repetindo "Meta {alvo}, {status}").
- Chips de escopo (`.scope-tag`): `title` + o texto visível já bastam (texto "REAL"/"PLATAFORMA" é lido).

---

## 7. Onboarding dos selos novos — tooltips `title=` (texto exato)

O arquivo já usa `title=""` como mecanismo de explicação (dezenas de `.kpi-label title="..."`, `cursor:help`). Os selos novos seguem o **mesmo padrão** — sem tour, sem modal, sem legenda fixa que ocupe espaço. O usuário passa o mouse e entende. Abaixo o texto exato sugerido para cada selo/rótulo principal (o dev deve envolver campos dinâmicos com `esc()` conforme arquitetura §8.1, mas estes são textos estáticos):

| Elemento | `title=` exato |
|---|---|
| CPL real (Overview / Meta) | "CPL real = investimento do canal ÷ leads efetivamente recebidos na Central de Leads (RD Station). É o custo por lead comparável entre canais — a métrica que este dashboard trata como verdade." |
| CPL plataforma (LinkedIn / Google) | "CPL plataforma = custo por conversão auto-reportado pela própria plataforma de anúncios (Ads Manager). Útil para conferência operacional, mas NÃO é comparável entre canais — use o 'CPL real' para comparar." |
| Leads reais (Overview) | "Leads reais = leads recebidos na Central de Leads e atribuídos a este canal pela normalização de origem. NÃO é o 'results'/'conv' inflado que a plataforma reporta." |
| ROAS blended | "ROAS blended = receita ganha atribuída a marketing ÷ investimento total em mídia paga no período. Acima de 1x significa que o marketing devolveu mais do que custou. Usa só a receita rastreada até a mídia, não a receita comercial direta." |
| ROAS realizado (criativo) | "ROAS realizado = receita já GANHA (fechada) desta campanha ÷ investimento. Dinheiro no caixa." |
| ROAS projetado (criativo) | "ROAS projetado = (pipeline em aberto + receita ganha) ÷ investimento. Inclui negócios ainda não fechados — é uma projeção, não um resultado." |
| Receita ganha | "Receita ganha = soma do valor de notas fiscais de oportunidades fechadas como ganhas no período. O footer mostra quanto disso é atribuível a marketing (lead rastreado por e-mail)." |
| Win rate | "Win rate = oportunidades ganhas ÷ total de oportunidades. Termômetro da qualidade da oportunidade e da execução comercial." |
| CAC por opp / por ganho | "CAC por oportunidade = investimento total ÷ nº de oportunidades. CAC por ganho = investimento ÷ nº de negócios ganhos. Quanto custou, em mídia, cada oportunidade/negócio." |
| Tempo lead→opp / opp→ganho | "Mediana de dias entre a criação do lead e a virada em oportunidade (e entre oportunidade e fechamento como ganho). Mediana é usada por ser robusta a outliers." |
| Taxa conv. (LP/GA4/UTM) | "Taxa de conversão = conversões ÷ sessões. Para landing pages, é a métrica-fim: uma LP com poucas sessões e alta taxa converte melhor que uma com muitas sessões e taxa baixa." |
| Selo BASE RD | (ver tabela §4) |
| Selo PERÍODO / CRM | (ver tabela §4) |
| Selo de meta (`meta-pill`) | "Meta: {alvo}. Atual: {valor}. {status}. Ajuste as metas no objeto METAS no topo do arquivo (ver README)." |

> **Anti-poluição:** nenhum selo carrega mais de ~2 palavras visíveis ("REAL", "PLATAFORMA", "✓ meta R$150"). Todo o resto vive no `title`. A tela fica limpa; a explicação está a um hover de distância — exatamente o contrato de UX que o arquivo já adota.

---

## 8. Checklist de acessibilidade (WCAG) — validação para o dev

| Critério WCAG | Como atende na v2 |
|---|---|
| 2.1.1 Keyboard | Todo drill-down (`tr[data-nav]`, `.bar-row`, `.kpi-nav`, breadcrumb) tem `tabindex="0"` + handler Enter/Space (§6). |
| 2.4.7 Focus Visible | `:focus-visible` com anel `--blue` de 2px (§6.1). |
| 4.1.2 Name/Role/Value | `role="button"` + `aria-label` descritivo em cada elemento navegável (§6.1). |
| 1.4.3 Contraste | Selos usam pares token/`-dim` já validados no design atual (green/amber/red sobre dim ≥ 4.5:1 no dark theme). Manter — não introduzir cor nova. |
| 1.4.1 Uso de cor | Cor nunca é o único sinal: selos de meta têm ícone (`ti-flag-check`/`ti-flag-off`) + texto ("✓/✗ meta"); escopo tem texto ("REAL"/"PLATAFORMA"). |
| 1.3.1 Info & Relationships | Toda distribuição em gráfico tem tabela/lista equivalente navegável — o gráfico é `role="img"`, a tabela é o caminho de dados (§6.1). |
| 2.4.3 Focus Order | Ordem = DOM = hierarquia visual; sem `tabindex` positivo (§6.2). Ao trocar de view, foco vai ao `.page-title` (§6.2). |

---

## 9. Resumo de entregáveis visuais para o `aiox-dev`

1. **3 classes CSS novas** (`.meta-pill`, `.scope-tag`, `.kpi-grid-8`) + regras de `:focus-visible` — todas aditivas no fim do `<style>` (§1.1, §2, §6.1).
2. **Overview:** grid 6→8, KPIs Receita+ROAS (posições 3-4), correção da tabela de canais com selos "REAL" (§2.1).
3. **`metaHTML()`** renderizando `.meta-pill` no `.kpi-footer` com semáforo invert-aware (§5).
4. **2 gráficos de linha** (leads/dia, opp+ganho/semana) via `mkChart('...','line',...)` com área leve e badge "série temporal" (§3).
5. **Selos de escopo** em 3 funis (BASE RD / PERÍODO / PERÍODO-CRM) via `.scope-tag` + `title` (§4).
6. **Selos CPL real/plataforma** e ROAS realizado/projetado (§2.7, §2.8).
7. **Colunas de taxa de conversão** em GA4/UTM/LP; taxa de qualificação nas barras de Leads (§2.3-2.5, §2.9).
8. **Padrão de drill-down acessível** (delegação `data-nav` + `tabindex`/`role`/`aria-label` + `:focus-visible`), substituindo `onclick` inline (§6).
9. **Textos exatos de `title=`** para todos os selos (§7).

**Nada acima requer biblioteca nova, cor fora da paleta, ou reconstrução de layout.** É uma extensão fiel do design system existente. O grosso da implementação (funções puras de cálculo, `esc()`, delegação de eventos) segue o blueprint da arquitetura; esta spec define o *como se parece e como se opera*.
