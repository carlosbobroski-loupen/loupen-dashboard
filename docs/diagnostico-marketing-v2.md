# Diagnóstico de Marketing Analytics — Loupen Dashboard (v2)

**Autor:** Atlas (AIOX Analyst)
**Data:** 2026-07-08
**Escopo:** camada de métricas e indicadores. NÃO cobre código, arquitetura, performance, segurança ou UI/UX (fases posteriores).
**Fonte:** leitura integral de `index.html` (2222 linhas). As recomendações citam funções/campos reais do código para rastreabilidade.

---

## Sumário executivo

O dashboard está **maduro na camada de aquisição e atribuição** (a disciplina do CPL real via `leadsReaisPorCampanha()`, a padronização de campanha por substring e o cruzamento por e-mail Central de Leads ↔ Salesforce são acertos analíticos sérios e devem ser preservados). O que falta é quase todo do lado do **retorno**: o dashboard mostra com precisão *quanto se gasta e quantos leads entram*, mas quase nunca *quanto volta*. Não existe ROAS/ROI, receita ganha realizada não é KPI de destaque em lugar nenhum, e o custo por oportunidade/negócio ganho (CAC real) nunca é calculado — apesar de todos os ingredientes (spend por canal + valor ganho por canal) já estarem carregados na memória.

Os três maiores ganhos de decisão, em ordem:
1. **Fechar o loop financeiro** (ROAS, receita ganha, CAC por canal) — os dados já existem, só não são cruzados.
2. **Consistência do "resultado" no Overview** — a tabela de canais pagos ainda mistura o `results` inflado do Meta com `conv` do Google/LinkedIn, contrariando a própria regra de ouro do projeto na tela mais vista.
3. **Taxas de conversão e velocidade de funil** — hoje quase tudo é contagem absoluta (snapshot); faltam denominadores (taxa sessão→conversão, LP conversion rate, win rate) e tempo (ciclo de venda), que são o que um time de growth usa para priorizar.

---

## Overview (Visão geral)

### Preservar como está
- **Trend período-a-período** (`trendHTML`/`prevPeriod`) nos 6 KPIs — é a única view com comparação temporal e está bem feita (inclusive com `invert` para métricas onde "menos é melhor", ex: CPL e rejeição). Excelente, deve virar padrão nas outras views.
- **CPL blended** usando leads reais (`spend/curLeads.length`, linha 1044) — coerente com a regra de ouro.
- **Funil de aquisição** Sessões→Leads→Qualificados com % de conversão entre etapas — TOFU/MOFU limpo.
- **Sessões × Leads por canal** com o tratamento de "sem rastreio" (bucket com leads e 0 sessões marcado em âmbar, linha 1145) — isso é honestidade analítica rara e valiosa; mantenha.

### Faltando (alto valor)
- **ROAS / retorno no Overview.** O KPI "Investimento total" aparece isolado, sem contrapartida de retorno. Um executivo olha essa tela e não consegue responder "o marketing está dando lucro?". Falta pelo menos um KPI de **Receita ganha no período** e um **ROAS blended** (receita ganha ÷ investimento). Os dados existem: `_allSalesforce` traz `valorNF`/`isWon` e o `spend` já é somado em `loadOverview`. Hoje o `loadOverview` sequer carrega Salesforce — é o único lugar onde o loop financeiro precisa ser fechado.
- **Custo por oportunidade / por negócio ganho (CAC blended).** Spend total já está calculado; nº de oportunidades e ganhos por período estão em `renderOportunidades`. Dividir um pelo outro dá o indicador que conecta marketing a receita.

### Redundante / mal posicionado / confuso
- **Tabela "Comparação de canais pagos" — coluna "Resultados" e "Custo/result." misturam definições.** Linhas 1082-1084: Google usa `gA.conv`, Meta usa `mA.results` (o resultado **inflado** que a regra de ouro proíbe usar para CPL), LinkedIn usa `lA.conv`. Três definições diferentes na mesma coluna, sendo uma delas justamente a que o projeto decidiu ser errada. Isso permite ao usuário comparar CPL entre canais de forma enganosa, na tela mais vista do dashboard. **Recomendação (alta):** trocar por **Leads reais por canal** (usar `normCanal()` para bucketizar `_allLeads` no período, como já é feito em `leadsByBucket`) e recalcular "Custo/result." como spend do canal ÷ leads reais do canal. Isso alinha o Overview à disciplina que já vale no Criativos e no Meta.
- **Três funis em três telas, sem jornada única.** Overview (Sessões→Leads→Qualif), RD Station (Total→Leads→MQL→Opp→Clientes) e Oportunidades (Leads→Qualif→Opp→Ganhas) coexistem sem um funil ponta-a-ponta. Falta uma leitura Sessão→Lead→MQL→Opp→Ganho→Receita num só lugar (ver Média #9).

---

## Leads RD Station (Central de Leads)

### Preservar
- Segmentações por **canal, cargo, porte e evento** (`renderLeads`) com ordenação de porte por faixa (`ordemPorte`) — a leitura de ICP (cargo CEO/Diretor, porte de empresa) é exatamente o que um time B2B precisa para julgar qualidade de lead, não só volume.
- Normalizações (`normCargo`, `normPorte`, `normEvento`, `normCanal`) — consolidam ruído de origem em buckets acionáveis. Preservar.

### Faltando
- **Taxa de qualificação por segmento.** Hoje mostra volume por canal/cargo/porte, mas não *qual canal/porte gera lead mais qualificado*. Um % de qualificados dentro de cada barra (ou uma coluna) transforma a view de "de onde vêm os leads" para "de onde vêm os **bons** leads" — decisão de alocação de verba muito mais forte.
- **Trend período-a-período** (como no Overview) — hoje o volume de leads não tem contexto de crescimento/queda.
- **Evolução temporal (série no tempo).** Todos os campos de data existem (`c[26]`/`c[0]`, `parseDataLead`), mas não há nenhuma linha de leads por dia/semana. Growth usa a curva, não só o total, para detectar momentum e efeito de campanha.

### Redundante / mal posicionado
- **KPI "Eventos" (`l-camps`, contagem de eventos distintos)** é fraco como KPI de destaque — é a cardinalidade de uma dimensão, não um resultado de negócio. Rebaixar (virar rótulo do gráfico "Por evento") e promover no lugar algo como **taxa de qualificação** ou **CPL médio do período**.

---

## RD Station Marketing

### Preservar
- Funil de base completa (Total→Leads→MQL→Opp→Clientes) e as taxas Lead→MQL, MQL→Opp, Opp→Cliente (`loadRDStation`) — dá a saúde macro da base.
- **Disclaimer de que NÃO é filtrado por período** (linha 335) — essencial, evita leitura errada. Manter bem visível.
- Honestidade sobre limitações da API (automações, LP, e-mail indisponíveis) — não inventa dado. Manter.

### Faltando / confuso
- **Confusão entre dois funis e duas "taxas de qualificação".** Esta view dá MQL/Opp da base inteira (não-temporal), e a view Oportunidades dá Opp por período+atribuição. O usuário vê "Oportunidades" nas duas com números diferentes e não sabe qual é a verdade. **Recomendação:** rotular explicitamente cada funil quanto a escopo (base total vs período atribuído) — já existe o disclaimer, mas o KPI "Oportunidades" repetido entre views merece um rótulo diferenciador (ex: "Oportunidades (base RD)" vs "Oportunidades (período/CRM)").
- Não há nada a "corrigir" nas seções de automação/LP/e-mail — a limitação é da API, já documentada. Deixar como está.

---

## Google Analytics (GA4)

### Preservar
- KPIs Sessões/Usuários/Conversões/Rejeição e detalhamento por canal com semáforo de rejeição (`rcl`, cores <40%/<65%). Bom baseline.
- Filtro por domínio e por canal (`mudarDominio`, `mudarCanal`).

### Faltando (alto valor)
- **Taxa de conversão (Sessões→Conversões).** A view tem Sessões e Conversões lado a lado mas nunca divide. Conversion rate por canal é *a* métrica de eficiência de topo de funil — hoje o usuário faz a conta de cabeça. Adicionar coluna.
- **Métricas de engajamento nativas do GA4.** Bounce rate é a métrica antiga; o GA4 prioriza **engagement rate** e **average engagement time**. Se o backend n8n conseguir expô-las, são leituras de qualidade de tráfego muito superiores a bounce. *(Confiança média — depende de o backend GA4 trazer esses campos; hoje `ga4.channels` só traz sessions/users/conversions/bounceRate.)*

### Redundante
- Nada relevante. A view é enxuta e correta para o que se propõe.

---

## Campanhas UTM

### Preservar
- Cruzamento de campanha com Source/Medium e rejeição.

### Faltando (alto valor)
- **Taxa de conversão por campanha UTM** (Conversões ÷ Sessões) — mesmo gap do GA4; é o principal julgamento de eficácia de campanha orgânica/UTM.
- **Custo e CPL por campanha UTM.** Esta é a ponte que falta entre UTM (GA4) e investimento (Ads). Como o `standardizeCampanha()` já resolve nome-mestre, seria possível aproximar spend de Ads à campanha UTM e mostrar CPL/CPA por campanha aqui. *(Confiança média — o match UTM↔campanha de Ads é imperfeito, especialmente Google, cujo UTM Content é placeholder genérico, limitação já conhecida.)*

---

## Landing Pages

### Preservar
- Página / Sessões / Conversões / Rejeição do GA4.

### Faltando (alto valor)
- **Taxa de conversão da LP (Conversões ÷ Sessões).** Esta é literalmente a métrica-fim de uma landing page e ela **não existe** na view — só volumes absolutos. Uma LP com 2.000 sessões e 20 conversões (1%) parece "melhor" que uma com 200 sessões e 20 conversões (10%) na ordenação atual por volume, quando é o oposto. **Alto valor, correção de leitura, dado 100% disponível.**

---

## Oportunidades (CRM Comercial)

### Preservar
- Segmentação **Marketing vs Comercial** via `buildLeadEmailMap()` (lead rastreado por e-mail vs cadastrado direto) — distinção poderosa, permite isolar o que o marketing realmente influenciou. Preservar.
- Funil comercial, motivo de perda, motivo de rejeição, por canal, por origem — cobertura rica de BOFU.
- Fallback de canal por texto (`inferCanalOrigem`) para leads antigos sem match.

### Faltando (alto valor)
- **Receita ganha realizada não é KPI.** Existem "Valor em pipeline" (`valorOpp` de abertas) e "Ticket médio", mas **o valor efetivamente ganho** (`valorNF`/`isWon`, já calculado como `ganhas`) não vira KPI de destaque. É o número mais importante da operação e está escondido. **Adicionar KPI "Receita ganha".**
- **Win rate (Opp→Ganha).** O funil mostra "Ganhas" mas não há % de conversão oportunidade→ganho como KPI. Win rate é o termômetro da qualidade da oportunidade e da execução comercial.
- **Custo por oportunidade e por negócio ganho (CAC por canal).** A tabela "Por canal de origem" tem Leads/Opp/Perdidas/Valor — falta cruzar com o `spend` do canal (já disponível no `fetchAdsData`) para dar **CAC real por canal**. Sem isso, "Meta gera mais oportunidades" não responde se gera oportunidades *mais baratas*.
- **Tempo de ciclo / velocidade de funil.** Os campos `dataCriacao`, `dataConversao`, `dataFechamento` existem em `_allSalesforce` mas nunca são usados para medir tempo. Tempo médio lead→oportunidade e oportunidade→ganho são essenciais para forecast e para detectar gargalo de estágio.

### Confuso / a esclarecer
- **"Ticket médio" (`ticketMedio`)** usa `valorOpp` de *oportunidades* (linha 1758), não de negócios *ganhos*. Isso mistura ticket de pipeline com ticket realizado. Rotular claramente ("Ticket médio de oportunidade") ou dividir em ticket de pipeline vs ticket ganho.
- **"Qualificados" no funil soma `qualificados + oportunidades`** (linha 1780) — correto conceitualmente (quem virou opp já foi qualificado antes), mas o KPI "Qualificados" isolado (linha 1750) conta só status atual "qualificado". Dois números de "qualificados" na mesma tela podem confundir; vale uma nota/rótulo.

---

## Criativos

### Preservar
- **Toda a espinha dorsal de atribuição:** CPL real (`spend ÷ leads reais`), bucket `campanha|||conjunto|||criativo`, fallback para plataformas sem detalhamento de criativo (Google/LinkedIn), cruzamento com Salesforce por e-mail para Opp/Pipe/Ganho. É a view analiticamente mais sofisticada e correta do dashboard. Preservar integralmente.
- Badge "leads sem criativo mapeado" (`semMapear`) — transparência sobre cobertura de atribuição. Manter.

### Faltando (alto valor — dados já presentes)
- **ROAS por campanha/criativo.** A tabela "Por campanha" já traz `spend`, `pipe` e `ganho` lado a lado — falta a razão **Ganho ÷ Investimento (ROAS realizado)** e **(Pipe+Ganho) ÷ Investimento (ROAS projetado)**. Isso transforma a view de "qual criativo tem CPL menor" para "qual criativo dá mais retorno" — que é o que decide corte/escala de verba. Custo praticamente zero, dados já na tela.
- **Custo por oportunidade.** Tem `oportunidades` e `spend` por campanha — dividir dá cost-per-opp, mais próximo de receita que o CPL.

### Confuso
- KPI "Pipe + Ganho" mistura pipeline (incerto) com ganho (realizado). Para decisão de verba, separar os dois é mais honesto (pipe é probabilístico). Sugerir dois KPIs ou rótulo explícito.

---

## Meta ADS

### Preservar
- **CPL real no KPI** (`cplGeral` via `leadsReaisPorCampanha`, com footer mostrando "X leads reais, Meta reportou Y") — implementação exemplar da regra de ouro; o contraste explícito educa o usuário. Preservar.
- Tabs Campanha/Conjunto/Anúncio com Resultados, Alcance, Freq, CPC, CTR — dados operacionais completos para gestão de mídia.

### Faltando
- **CPM (custo por mil impressões).** Tem spend e impressões, não mostra CPM — métrica padrão de eficiência de compra de mídia e de leitura de leilão/saturação.
- **Frequência no nível de totais.** Freq aparece por campanha mas não como KPI agregado; frequência alta é sinal precoce de fadiga de criativo.

### Confuso
- **Gráfico "Resultados por campanha"** (donut, linha 1345) usa `c.results` (o resultado inflado do Meta). Coerente com a decisão do projeto, isso deveria ser **leads reais por campanha** (via `leadsPorCampanha` já calculado no mesmo `loadMeta`). Hoje o número-título (KPI) usa leads reais mas o gráfico logo abaixo usa results — inconsistência dentro da mesma tela.
- Nas tabelas por campanha/conjunto/anúncio, "Custo/Result." usa `costPerResult` da plataforma. Aceitável como dado operacional de mídia (é o que o gestor vê no Ads Manager), mas vale um rótulo deixando claro que é métrica-plataforma, não o CPL real.

---

## LinkedIn ADS

### Preservar
- KPIs e tabela de campanha (é o teto de granularidade da API — sem conjunto/criativo, limitação conhecida). Correto para o que a fonte permite.

### Faltando / a esclarecer
- **CPL aqui usa `conv` da plataforma** (`t.cpl`), não leads reais da Central de Leads, diferente do Meta. Para LinkedIn o desvio é menor (a conversão do LinkedIn é mais confiável que o `results` misto do Meta), mas gera **inconsistência de definição de CPL entre abas de anúncio**. Recomenda-se ao menos rotular ("CPL plataforma") para o usuário não comparar diretamente com o "CPL real" do Meta.
- **CPM** ausente (mesmo caso do Meta).

---

## Google ADS

### Preservar
- Tabs Campanha/Grupo/Palavra-chave/Anúncio com **Quality Score** por keyword (semáforo `qsColor`) — leitura de eficiência de Search valiosa. Uso de keyword como proxy de "criativo" (limitação de macro do Google, conhecida) é a decisão certa.
- CPA no KPI.

### Faltando
- **CPL real vs CPA da plataforma.** Diferente do Meta, o Google mostra só CPA da plataforma (`t.cpa`), não o CPL real da Central de Leads. Para consistência com a regra de ouro, o Google deveria também expor um "CPL real" (spend Google ÷ leads reais de canal Google, obtíveis via `normCanal`). Hoje só o Meta recebeu esse tratamento — o Google fica com métrica-plataforma isolada.
- **CPM** e **conversion value / ROAS** (se o backend trouxer valor de conversão do Google Ads). *(Confiança média — depende de campo do backend.)*
- **Search Impression Share / Lost IS** — indicador central de Google Ads (quanto do leilão você está perdendo por orçamento/rank). *(Confiança média — depende de a API/n8n expor.)*

---

## Lacunas transversais (afetam várias views)

1. **Loop financeiro ausente (ROAS/ROI/CAC/LTV:CAC).** Maior gap do dashboard. Spend está em todo lugar; receita ganha (`valorNF`/`isWon`) existe mas quase nunca é cruzada com spend. Sem isso o dashboard responde "quanto gastei e quantos leads" mas não "valeu a pena".
2. **Ausência de séries temporais.** Quase tudo é total agregado do período. Faltam curvas (leads/dia, spend/dia, opp/semana) para leitura de momentum. *(Confiança média para dados de Ads — os totais vêm agregados por range do n8n; leads e Salesforce têm data por linha e permitem série imediata.)*
3. **Trend período-a-período só no Overview.** `trendHTML`/`prevPeriod` já existem e poderiam ser reaproveitados em Leads, Oportunidades, Criativos e nas abas de anúncio.
4. **Taxas de conversão faltando onde há numerador e denominador** (GA4, UTM, LP, win rate no CRM). Padrão recorrente: mostram-se dois volumes, nunca a razão.
5. **Sem metas/benchmarks visuais.** Há bons benchmarks embutidos em tooltips (CTR Meta >2%, bounce <40%, CTR Search >3%, QS >=7), mas nenhuma **meta configurável** nem linha de alvo nos KPIs. Growth precisa de "estou acima/abaixo da meta", não só do valor absoluto.
6. **Inconsistência de definição de CPL entre abas** (Meta = real; LinkedIn/Google = plataforma). Padronizar a definição ou rotular explicitamente a origem de cada CPL.

---

## Resumo de prioridades

### Alta (decisão crítica, dados majoritariamente já disponíveis)
1. **ROAS / Receita ganha / CAC** — fechar o loop financeiro no Overview, Oportunidades e Criativos. Receita ganha (`valorNF`/`isWon`) + spend já carregados; só falta cruzar. *Por quê:* é a pergunta central "o marketing dá lucro?", hoje sem resposta.
2. **Corrigir a "Comparação de canais pagos" do Overview** para usar **leads reais / CPL real por canal** em vez do `results`/`cpl` misto (Meta inflado). *Por quê:* a tela mais vista contraria a regra de ouro e permite comparação enganosa entre canais.
3. **Taxa de conversão de Landing Page** (Conversões ÷ Sessões). *Por quê:* é a métrica-fim da LP, ausente; a ordenação por volume atual esconde as LPs mais eficientes.
4. **Win rate + Receita ganha como KPI no CRM.** *Por quê:* qualidade da oportunidade e resultado realizado são o output do funil e hoje estão escondidos atrás de pipeline/ticket.
5. **Taxa de conversão em GA4 e UTM** (Sessões→Conversões). *Por quê:* eficiência de topo/meio de funil, dado 100% disponível, hoje calculado de cabeça.
6. **ROAS por campanha/criativo na aba Criativos** (Ganho÷Spend). *Por quê:* decide corte/escala de verba; spend+ganho já estão na mesma linha.

### Média
7. **Séries temporais** (leads/spend/oportunidades ao longo do período) — começar por leads/CRM, que têm data por linha.
8. **Tempo de ciclo / velocidade de funil** no CRM (usar `dataCriacao`/`dataConversao`/`dataFechamento`). *Por quê:* forecast e detecção de gargalo por estágio.
9. **Estender trend período-a-período** (Leads, Oportunidades, Criativos, abas de anúncio) — infra `trendHTML` já existe.
10. **Funil unificado ponta-a-ponta** (Sessão→Lead→MQL→Opp→Ganho→Receita) e desambiguar os três funis/duas "qualificações" atuais com rótulos de escopo.
11. **Taxa de qualificação por segmento** na view Leads (canal/porte/cargo que geram lead mais qualificado).
12. **Metas/benchmarks visuais** nos KPIs (transformar os benchmarks de tooltip em linhas de alvo).
13. **Padronizar/rotular definição de CPL** entre Meta (real), LinkedIn e Google (plataforma); idealmente dar CPL real também a Google e LinkedIn via `normCanal`.
14. **Métricas de engajamento GA4** (engagement rate, avg engagement time) — depende de o backend expor.

### Baixa
15. **Rebaixar KPI "Eventos"** na view Leads (é cardinalidade de dimensão, não resultado) e promover taxa de qualificação/CPL no lugar.
16. **Gráfico "Resultados por campanha" (Meta)** passar a usar leads reais em vez de `results` inflado, alinhando com o KPI da mesma tela.
17. **CPM e frequência agregada** em Meta/LinkedIn/Google — eficiência de compra e fadiga de criativo.
18. **Separar/rotular "Pipe + Ganho" (Criativos) e "Ticket médio" (CRM)** — não misturar valor probabilístico (pipeline) com realizado (ganho).

---

## Notas de confiança e dependências de dados

- **Alta confiança / dados já em memória:** ROAS, receita ganha, CAC, win rate, taxas de conversão (GA4/UTM/LP), ROAS por criativo, tempo de ciclo — todos derivam de `_allLeads`, `_allSalesforce` e `fetchAdsData` já carregados.
- **Confiança média / dependem de campo do backend n8n:** engagement metrics GA4, conversion value/ROAS do Google Ads, Search Impression Share, séries temporais de Ads (totais chegam agregados por range).
- **Fora de escopo (limitações de fonte já validadas, não são gaps):** criativo/conjunto no LinkedIn, nome de anúncio no Google, macros de Lead Ads nativo do Meta, métricas de e-mail/automação/LP do RD Station via API. Não recomendo tentar "resolver" nenhuma delas no dashboard.
