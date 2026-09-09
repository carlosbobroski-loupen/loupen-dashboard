## ⚠️ PERGUNTA PENDENTE PARA O USUÁRIO (3.11): limiar de similarity() = 0.6 tem lacuna real

Testando T2.1 (Tier 2 de identidade) com o par real "Joao Pereira Lima" vs "João P. Lima"
(mesmo par conceitual da fixture EC-7 da Etapa A) — `similarity()` retornou **0.36**, MUITO
abaixo do limiar de 0.6 que o plano especifica. Abreviação de nome do meio + acento é uma
variação real que o trigrama não pega nesse limiar — não é bug de código, é uma lacuna de
calibração do próprio limiar especificado. Testei um segundo par com variação MENOR (só
acentuação: "Patricia Gomes Andrade" vs "Patrícia Gomes Andrade") e esse sim bateu 0.77,
confirmando que o MECANISMO funciona — só o limiar de 0.6 é alto demais para variações de
abreviação de nome comuns no Brasil (nome do meio abreviado, sobrenome duplo abreviado).
**Não decidi um novo limiar sozinho** — fica para quando o usuário voltar: opções são (a)
baixar o limiar (risco: mais falsos positivos), (b) somar um segundo sinal mais barato
(ex.: primeira letra do sobrenome + mesmo domínio) para pares como este, ou (c) aceitar
que esse tipo de variação específica simplesmente não é pego por Tier 2 e cai sem
resolução de identidade (honesto, mas perde casos reais).

## 🔴 ACHADO CRÍTICO (2.21, 2026-09-08): credencial do RD Station tem escopo de ESCRITA

**Teste realizado:** workflow n8n temporário, `PATCH /platform/contacts/email:<e-mail
inventado, nunca usado>` usando a credencial real "RD Station Marketing OAuth2 - Loupen"
(id `vOAhOy0T4xmEAOvq`) — a MESMA credencial já em uso para leitura de segmentações no
workflow "Loupen Dashboard - Ads Data API".

**Resultado:** `status 200` — a escrita FUNCIONOU. A API do RD Station tem semântica de
upsert nesse endpoint: como o e-mail não existia, ela CRIOU um contato novo de verdade em
produção (uuid `88edaf4b-c6f7-4ab1-a38d-d88576fcaeaf`, nome "Teste INV-1"). Isso viola
INV-1 (menor privilégio) — a credencial usada para leitura tem escopo de escrita real, não
hipotético.

**Correção imediata (mitigação do dano, não do problema):** o contato de teste foi
DELETADO via `DELETE /platform/contacts/uuid:...` com a mesma credencial (confirmado
`204`, depois confirmado `404` ao tentar buscar de novo — contato realmente removido). O
workflow de teste foi apagado do n8n.

**Revisão nó a nó (a outra metade de 2.21):** todos os 5 nós RD Station do workflow
"Loupen Dashboard - Ads Data API" (RD Total/Leads/MQL/Clientes/Oportunidades) são `GET`
para `/platform/segmentations/{id}/contacts` — nenhuma chamada de escrita EXISTENTE hoje.
O workflow "Leads RD Station" só RECEBE webhook do RD Station, nunca chama a API de volta.
**O risco não é um caminho de leitura fazendo escrita sem querer — é que a CREDENCIAL em
si tem permissão de escrita que nenhum workflow atual usa, mas que existe e é real.**

**AÇÃO PENDENTE PARA O USUÁRIO (não fiz sozinho — é mudança de credencial de produção):**
criar uma credencial OAuth2 NOVA no RD Station com escopo só de leitura (se a plataforma
permitir granularidade de escopo na tela de autorização do app conectado), ou pelo menos
documentar formalmente que a credencial atual tem mais poder do que o usado e que qualquer
novo workflow precisa ser revisado manualmente antes de usar essa credencial para
qualquer operação de escrita não intencional.

## Subtask 1.2 (parcial) — Inventário de DNS ANTES de qualquer mudança (R3/PR-3)

**Comando real (2026-09-08):** `dig +short NS loupenapps.com.br` e `dig +short NS
loupen.com.br`.

**Resultado:** AMBOS os domínios já têm zona na Cloudflare — nameservers
`jakub.ns.cloudflare.com` / `sreeni.ns.cloudflare.com` nos dois. **Isso resolve a
pergunta central de 1.2 sem ambiguidade**: não é preciso criar conta nova nem migrar
nameserver (o risco de R3 não se aplica — a única incógnita que resta é encontrar quem
já tem acesso a essa conta Cloudflare existente, e se o Zero Trust está na MESMA conta).

**MX (`dig +short MX <dominio>`):**
- `loupenapps.com.br`: **nenhum registro MX** — não é usado para e-mail, zero risco de
  quebrar e-mail corporativo ao mexer na zona.
- `loupen.com.br`: MX real, Google Workspace (`aspmx.l.google.com` e variantes) — É o
  domínio de e-mail da empresa. Qualquer mudança aqui tem risco real.

**Conclusão prática (resolve OQ-15 com dado real, não preferência):** usar
`dashboard.loupenapps.com.br` como hostname do gate — confirmado como a escolha sem
risco de e-mail, exatamente a recomendação original do plano, agora com evidência.

**Pendente para fechar 1.2 por completo:** confirmar (só o usuário consegue, precisa
logar no painel) que essa conta Cloudflare que já gerencia a zona é a MESMA conta onde o
Zero Trust vai ser configurado — ou identificar quem tem acesso, se não for o usuário
diretamente.

## Fase 1b — Motor de atribuição (phase-3), iniciada em 2026-09-07

### ✅ V4 (OQ-12) — decisão do usuário sobre "Parceiro/Indicação"

**Pergunta apresentada:** onde "Parceiro/Indicação" se encaixa no nível 1 da taxonomia —
Comercial, Marketing ou quarto segmento próprio?
**Resposta literal do usuário:** "Quarto segmento próprio (Recomendado)".
**Consequência:** o domínio do nível 1 passa de 3 para 4 valores: `Marketing`,
`Comercial`, `NaoAtribuido`, `Parceiro`. Isso muda `channel_source.classificacao` e
`lead_origin_classification.segmento` (migration 017) e, later, a Etapa A do frontend
(que hoje só tem 3 badges/pills) — registrado como follow-up, não feito nesta sessão.
Novo sinal necessário para determinar este segmento: **S9** (vocabulário controlado de
parceria/indicação), análogo a S5 mas resultando em Parceiro em vez de Comercial.

### ✅ V3 (OQ-13) — levantamento real do vocabulário de LeadSource

**Fonte:** SOQL direto no Salesforce real via MCP (`SELECT LeadSource, COUNT(Id) FROM
Lead GROUP BY LeadSource ORDER BY COUNT(Id) DESC LIMIT 200`) — não inferido, medido.
200 valores distintos retornados (pode haver mais além do LIMIT 200, cauda muito longa
de valores com contagem baixa — 2 a 200). Achado real: o campo LeadSource nunca foi
governado — "Fornecedor" sozinho é o maior valor (10.054 leads), maior que qualquer
canal de marketing nomeado.
**Pergunta apresentada sobre "Fornecedor":** o que significa operacionalmente.
**Resposta literal do usuário:** "Prospecção/lista comprada de fornecedor de dados" →
classificado como Comercial (S5, mesmo tratamento de Lista Comprada/Lista Neoway).
**Metodologia de classificação adotada** (ver `db/migrations/018_leadsource_crosswalk.sql`
para a lista completa e citável): apenas valores com correspondência CONFIANTE entram no
crosswalk (Marketing: Busca Paga, Facebook Ads, Google Ads, todos os RD Station(...),
LandingPage, Website, eventos de marketing nomeados; Comercial: Outbound, ferramentas de
prospecção conhecidas — Apollo.Io, SNOV, Ramper, Fornecedor, listas compradas nomeadas,
listas de vendedor nomeadas; Parceiro: Parceiro/Indicação/Revenda). Valores SEM
correspondência confiante NÃO entram no crosswalk — por desenho, isso os deixa cair em
S6/Não atribuído (Direto/Desconhecido ou "Outro (requer nota)"), que é o comportamento
CORRETO e seguro do próprio modelo (nunca forçar uma classificação por adivinhação de
string). Isso NÃO é "inferir vocabulário pelos nomes" (o erro de DEF-3): é uma tabela de
referência estática, citável e corrigível por linha, olhada por match exato — nunca
heurística de runtime.

## Fase 1 (spikes) — Etapa B, iniciada em 2026-09-07

### ✅ Spike 1.1 — `pg_trgm`/`fuzzystrmatch` no Neon Free (R4, premissa central de EC-7 Tier 2)

**Projeto Neon criado:** "Dashboard MKT Loupen", região **AWS South America East 1
(São Paulo, `aws-sa-east-1`)** — confirmado disponível no tier Free na própria tela
de criação (resolve a pendência residual de OQ-4/CON-15 registrada em spec.md §4.4).
Postgres 18. Neon Auth desligado (não usado nesta fase).

**Comando executado:**
```
psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/queries/verificacao/spike-00-extensions.sql
```

**Resultado:** `CREATE EXTENSION` para `pg_trgm` e `fuzzystrmatch` — ambos sem erro.
`similarity('Joao Pereira Lima', 'João P. Lima') = 0.3636...`,
`levenshtein('Joao Pereira Lima', 'João P. Lima') = 7`. Postgres 18.6.

**Veredito:** APROVADO. O Tier 2 de resolução de identidade (EC-7) pode seguir
como desenhado — não é preciso reabrir a escolha de banco (R4 mitigado).

### ✅ Spike 1.7 — Termos de Uso do Neon quanto a uso comercial/interno (R19)

**Fontes consultadas (2026-09-07):**
1. `https://neon.com/terms-of-service` — "Product Specific Schedule (Neon)", datado de
   05/08/2026. Aborda planos de autosserviço, preço, segurança e conformidade; **nenhuma
   cláusula restringe uso comercial/interno** por plano.
2. `https://neon.com/docs/introduction/plans` — o Free é descrito como recomendado para
   "Prototypes, side projects, and small teams", mas essa é uma **sugestão de uso**, não
   uma restrição de licença. Os únicos limites documentados são técnicos: 0,5 GB de
   storage/projeto, 100 CU-hours/projeto/mês, 10 branches/projeto, 5 GB de transferência —
   e o texto é explícito: "None of these limits delete your data" (suspende, não apaga).
3. `https://neon.com/platform-terms` — redirecionou para o mesmo Product Specific Schedule
   do item 1; não foi possível localizar um documento de "Platform Terms" canônico
   separado nesta consulta.

**Achado honesto (não uma cláusula única, mas ausência convergente):** nenhuma das três
fontes contém uma cláusula que proíba uso comercial/interno de empresa no plano Free —
mas também não encontrei o documento legal mestre ("Neon Platform Terms") citado no
rodapé do Product Specific Schedule para confirmar de forma canônica e definitiva.

**Veredito:** APROVADO PARA CONTINUAR A CONSTRUÇÃO, com ressalva registrada. R19 tem
impacto médio e a mitigação do próprio spec.md diz "ler o ToS **antes do deploy de
produção**" — não antes de continuar desenvolvendo. Recomendação: repetir esta leitura,
mirando especificamente o documento "Neon Platform Terms" completo (não só o Product
Specific Schedule), como parte do checklist pré-produção (`phase-7`, antes do cutover
real), não bloqueia phase-2/phase-3 agora.

### ⚠️ ACHADO: o padrão de asserção `1/(... HAVING count(*)=N)` não falha de verdade

Usado nas verificações oficiais de 2.3, 2.5, 2.6, 2.7, 2.8, 2.9, 2.11 e 2.14 no plano.
Testado empiricamente (2026-09-07): quando a condição do `HAVING` é falsa, a subquery
escalar retorna **zero linhas**, e uma subquery escalar sem linhas avalia como `NULL` —
`1/NULL` em Postgres é `NULL`, **não** um erro de divisão por zero. Resultado real: o
`psql` imprime uma célula vazia e sai com **exit code 0**, mesmo com a invariante violada.
Isso é exatamente o modo de falha silenciosa que esta epic existe para eliminar — a
ferramenta de verificação tinha o mesmo defeito.

**Correção adotada a partir daqui:** trocar por
`SELECT 1/CASE WHEN (subquery de contagem) = N THEN 1 ELSE 0 END;` — isso força uma
divisão por zero LITERAL (`1/0`) quando a condição é falsa, que o Postgres genuinamente
rejeita com erro e exit code != 0. Cada subtask de 2.4 em diante que reusa este padrão
registra nas suas notas que rodei a versão corrigida, não o comando literal do plano.

### ✅ Subtask 2.1 — Projeto Neon definitivo provisionado

**Região:** `aws-sa-east-1` (São Paulo), fixada e conferida na tela de criação (CON-15).
**Postgres major:** 18, fixado no provisionamento pelo mesmo motivo de irreversibilidade.
**Endpoint:** `-pooler` (connection pooling), `sslmode=require` — convenção documentada em
`db/README.md`.

**Comando executado:**
```
psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT current_setting('server_version'), inet_server_addr() IS NOT NULL AS conectado;"
```
**Resultado:** `18.6 (c5250a2)` / `conectado = t`. Conexão real confirmada contra o
projeto definitivo (mesmo projeto do spike 1.1 — não descartável).

### ✅ Subtask 1.11 (parcial) — Inventário da plataforma n8n

**n8n real conectado:** `n8n.loupenapps.com.br`, MCP v2.82.1 (versão do próprio n8n não
exposta pela API desde 1.119.0 — não é erro, é comportamento documentado). 22 workflows
inventariados. Achados relevantes registrados em `docs/architecture/edge-routing.md`:
nenhuma credencial de API de pull para Salesforce ou RD Station existe hoje — "Ponte SF"
é 100% manual (sem chamada de API), "Leads RD Station" só recebe webhook. Confirma R20 e
a origem real do gap 44/236 (EC-6): nunca houve ingestão automática de Salesforce.
Issue #31234 (SSL do nó Postgres) não reproduzida: o nó Postgres usado em 2.15 conectou
sem erro de SSL contra o Neon (que exige TLS) — evidência real a favor, ainda que não uma
checagem direta da issue em si.

**ACHADO REAL sobre CORS (contradiz uma suposição do plano):** inspecionei o node type
`n8n-nodes-base.webhook` (versão 2.1, 4 versões de histórico) via schema completo. Ele
expõe `authentication: headerAuth` (Header Auth por nó, CONFIRMADO disponível — a
recomendação de 1.11 de "Header auth" está correta). Porém a coleção `options` do nó
NÃO tem nenhuma opção de "Allowed Origins"/CORS por nó nesta versão — as opções
disponíveis são: Binary File, Ignore Bots, IP Allowlist, No Response Body, Only Run If,
Response Code/Content-Type/Data/Headers. Isso contradiz a nota original de 1.11
("configurar por nó, com UMA origem") — nesta versão, CORS parece ser controlado
GLOBALMENTE (`N8N_CORS_ALLOW_ORIGIN`), não por nó. A recomendação de NÃO alterar essa
env var global continua válida e ainda mais importante à luz deste achado (não há
alternativa por-nó nesta versão para mitigar o blast radius). Relevante principalmente
para phase-4 (gate de acesso), não bloqueia a ingestão CRM em si (webhooks recebendo de
Salesforce/RD Station não são chamados por navegador, CORS não se aplica a esse tráfego
server-to-server).
Versão exata do n8n permanece não confirmada (API não expõe desde 1.119.0) — inferida
como >= 1.119.0 pela própria mensagem da API, não medida diretamente.

### ✅ Subtask 2.15 — Credencial n8n → Neon (crm_ingest, least-privilege)

Role `crm_ingest` criada no Postgres com `GRANT SELECT, INSERT, UPDATE ON ALL TABLES` +
`EXECUTE ON FUNCTION fn_run_ingest_batch(text)` — sem DDL. Testado na prática com a
PRÓPRIA credencial: `DROP TABLE lead` → `ERROR: must be owner of table lead`;
`TRUNCATE lead` → `ERROR: permission denied for table lead`. `SELECT count(*) FROM
lead` e `SELECT * FROM fn_run_ingest_batch(...)` funcionam normalmente.

Credencial criada no n8n real (id `HxzsjsD5aq9xddR2`, endpoint `-pooler`, `ssl=require`).
Verificação MANUAL (per instruções da subtask): workflow de teste com nó Postgres
(`SELECT 1, inet_server_addr() IS NOT NULL, current_user`) executado via webhook em
produção — resultado real: `{ok: 1, conectado: true, usuario: "crm_ingest"}`. Workflow
de teste deletado depois da prova (não ficou no ar). Detalhes completos em
`docs/architecture/edge-routing.md`.

---

# Log de verificação manual — épico CRM Lead Intelligence

Registro de execução do checklist de §6.4 (spec.md) e de outros pontos de decisão
manual do plano. Cada entrada: o que foi checado, como, e o resultado real — nunca
presumido. Itens fora do escopo de uma subtask específica da Etapa A (gate de
acesso, NFR-2 medido em produção, NFR-6, reconciliação de views migradas) ficam
como pendentes, não como verificados por engano.

---

## Subtask 5.19 — checklist §6.4 aplicável à Etapa A (2026-09-07)

Escopo desta subtask (ver notes em `implementation.yaml`, dependências `5.15`/`0.5`):
apenas os três itens de §6.4 que já fazem sentido verificar num artefato estático
sem backend/gate real — INV-5, INV-4 e NFR-5. Os demais itens de §6.4 (política do
Access, timestamp de coleta por fonte em produção, NFR-2, NFR-6, reconciliação de
views migradas) dependem de infraestrutura da Etapa B ou de outras subtasks
(5.14/5.17/5.18, todas `stage: B`) e continuam **pendentes** abaixo, não marcados
como feitos.

### ✅ INV-5 — Nenhum segredo presente no JavaScript entregue ao navegador

**Comando executado** (o mesmo da verificação oficial da subtask, `type: command`):

```
grep -rniE '(api[_-]?key|secret|token|bearer)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_-]{12,}' assets/js/ index.html
```

**Resultado:** 0 ocorrências (`exit code 1` — grep sem match). Confirmado em
`assets/js/` (todos os arquivos: `app.js`, `data-api.js`, `url-state.js`,
`attribution.js`, `views-legacy.js`, `views/*.js`) e em `index.html`.

### ✅ INV-4 — Nenhum dado pessoal de lead presente no artefato estático

Três verificações, não apenas uma:

1. **`SRD_IA_LEADS` (o array do incidente de 2026-09-04, ver
   `project_pii_exposure_incident`)** — sobreviveu à extração verbatim de 5.3 para
   `assets/js/views-legacy.js`. Confirmado: todo campo `nome`/`tel` no array
   permanece `"[REDIGIDO]"`. A extração não reintroduziu PII.
2. **Padrão de e-mail real fora do fixture mock** — `grep -rnoE
   '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' assets/js/views-legacy.js
   index.html` (excluindo `exemplo`/`example.com`/`@loupen.com.br`/artefatos de
   CSS): **0 ocorrências**.
3. **Padrão de telefone brasileiro real** — `grep -rnoE '\+55[0-9 ()\-]{8,}'
   assets/js/views-legacy.js index.html assets/js/app.js` (excluindo
   `REDIGIDO`/`XXXX`): **0 ocorrências**.

O fixture novo (`assets/data/mock/*.json`) já tem cobertura própria e contínua via
`tests/contract/*.test.mjs` (heurística R23, 29/29 testes passando) — não repetido
aqui, apenas referenciado.

### ✅ NFR-5 — Componentes do design system reutilizados, nenhum equivalente mais simples introduzido em paralelo

Verificado por inspeção: `assets/js/views/leads.js`, `lead-detalhe.js` e
`qualidade-dados.js` reutilizam `kpi-grid-4`, `badge` (com as variantes
`.mkt`/`.com`/`.na` já definidas para o segmento), `mono-sm`, `t-sub`, `rel-card`,
`field-grid`, `crm-timeline`/`tl-*`, `empty-state` — todos definidos uma única vez
em `assets/css/design-system.css` (extraído em 5.2/5.3, estendido aditivamente em
5.6-5.15). Nenhuma classe paralela redundante (ex.: um "card" ou "badge" alternativo)
foi criada para as mesmas necessidades.

### ⏳ Pendente (fora do escopo desta subtask, aguarda Etapa B / outras subtasks)

- [ ] Política do Access verificada com e-mail externo — aguarda infraestrutura de
  gate (fora do escopo de qualquer subtask da Etapa A).
- [ ] Entrega do one-time PIN confirmada — idem.
- [ ] Timestamp de última coleta visível por fonte, em produção com dado real —
  a Etapa A tem uma versão honestamente aproximada disso em
  `qualidade-dados.js` (subtask 5.15, ver nota "LIMITE DECLARADO" no plano);
  a versão real com `ingest_run` é Etapa B.
- [ ] Divergência origem↔destino visível por fonte — depende de 5.13/5.14 (`stage: B`).
- [ ] Cobertura de atribuição na mesma superfície de qualquer CAC por canal —
  depende de 5.14 (`stage: B`).
- [ ] AC-6.2 (jornada longa, sem modal de rolagem confinada) — **já verificado
  na prática em 5.10** (ver nota dessa subtask no plano; não repetido aqui,
  apenas referenciado).
- [ ] Views ainda não migradas com banner de snapshot congelado — **já
  verificado em 5.8** (app.js, `_garantirBannerSnapshot`); confirmado de novo
  aqui que `leads-crm` e `qualidade-dados` corretamente NÃO mostram o banner
  (estão em `window.MIGRATED_VIEWS`, por serem views novas, nunca terem sido
  snapshot).
- [ ] Números de views migradas conferidos contra o snapshot congelado — depende
  de 5.18 (`stage: B`), que só faz sentido quando alguma view *existente*
  (não nova) for de fato migrada para dado ao vivo.
- [ ] NFR-2 medido (não presumido) — depende de 5.17 (`stage: B`, backend real).
- [ ] NFR-6 (schema estável ao adicionar canal) — depende de schema real em
  produção (Etapa B).

## 🔒 Fechamento (2.21): RD Station não tem escopo de permissão granular — risco aceito por governança

Confirmação visual real, direto da UI do RD Station App Store (print de tela do
usuário, 2026-09-08), na página "Permissões de acesso" do app cujo Connected
App/OAuth alimenta a credencial "RD Station Marketing OAuth2 - Loupen":

```
Gerenciar webhooks
Gerenciar contatos
Gerenciar campos customizados
Visualizar o link do código de monitoramento
Manipular os estágios de funil de seus contatos
Envio de eventos para os contatos
```

Todas marcadas, nenhuma opção de desmarcar individualmente — é um pacote fixo,
sem toggle por permissão. Isso confirma, com evidência direta da plataforma (não
só ausência de menção na doc oficial), que **não existe caminho técnico** para
reduzir esta credencial a somente-leitura dentro do modelo de app do RD Station.

**Decisão de fechamento:** aceitar formalmente o risco residual (escopo de escrita
real, achado crítico documentado acima nesta subtask). Mitigação permanente:
nenhum workflow n8n pode conectar esta credencial a um node de escrita — regra de
arquitetura, revisada a cada mudança em workflow que a referencie. Subtask 2.21
permanece com `status: failed` no implementation.yaml porque o invariante técnico
(INV-1, menor privilégio) genuinamente não se sustenta — o que fechou foi a
*decisão* sobre o que fazer diante disso, não o invariante em si (Artigo IV: não
inventar uma conformidade que não existe).

## ✅ 2.16 parcialmente desbloqueada: credencial Salesforce criada no n8n

Usuário forneceu Consumer Key/Secret do Connected App do Salesforce (criado por
ele mesmo no Setup → App Manager, via fluxo "Manage Consumer Details" com
verificação por e-mail — o mesmo fluxo humano-obrigatório documentado em
`feedback_salesforce_connector_no_admin_actions`).

Credencial criada via `n8n_manage_credentials` (tipo `salesforceOAuth2Api`,
não o OAuth2 genérico — n8n tem um tipo dedicado para Salesforce):
- Nome: "Salesforce OAuth2 (Connected App - CRM epic)"
- ID: `DPIrUz4vnDr8TDd7`
- `environment: production`, `serverUrl: https://login.salesforce.com`
- Consumer Key/Secret armazenados criptografados dentro do n8n; não foram
  ecoados em nenhum arquivo do projeto, commit ou memória.

Achado de schema (não documentado, só via `getSchema` + tentativa/erro): o
schema retornado por `getSchema` referencia `useDynamicClientRegistration` e
`grantType` dentro de blocos `if/then` condicionais, mas esses dois campos NÃO
estão na lista de `properties` de nível superior — e o schema tem
`additionalProperties: false`. Resultado: é impossível enviá-los (a API rejeita
como "additional property"), mas omiti-los também dispara os ramos `then` que
exigem `serverUrl` e (`sendAdditionalBodyProperties` + `additionalBodyProperties`)
por padrão. Contorno: enviar esses três campos (que SÃO propriedades de nível
superior válidas) mesmo sem tocar nos dois campos problemáticos.

**Falta ainda (bloqueado em ação humana):** o handshake OAuth2 interativo — abrir
esta credencial na UI do n8n e clicar "Sign in with Salesforce" para autorizar via
navegador (login + consentimento). Nenhuma ferramenta de agente completa isso.
Depois disso: construir o workflow de chamada à Bulk API 2.0 (HTTP Request manual,
o nó nativo Salesforce do n8n não expõe Bulk API 2.0) e testar o delta por
SystemModstamp.

## ✅ 2.17 (segunda metade): camada de banco para estágio de funil + workflow do RD Station construída e testada

**Achado real ao investigar antes de construir:** `funnel_stage` (migration 003, catálogo DM-8) nunca teve nenhuma tabela de fato por lead — nenhuma migration posterior criou esse vínculo. `fn_record_touchpoint` (migration 034, S7) já existia como mecanismo de escrita, mas nunca tinha sido chamada por uma ingestão real (o próprio header da 034 dizia isso).

**Construído (migrations 039-042):**
- `lead_funnel_stage_event` (nova tabela) — DM-8 por lead. Vocabulário de estágio (`funnel_stage.nome`) NUNCA pré-semeado com uma lista adivinhada — upsert dinâmico pelo valor real que a API devolver. Testado ao vivo via `contact_funnel_stage_get` real (RD Station) para 5 contatos reais (e-mails REDIGIDOS deste log — ver nota de PII no fim do arquivo): um lead pessoal da campanha `LOGMEIN_RESCUE-LICENCA-ECO_07-26` e as 2 leads mais recentes da base → `"Qualified Lead"`; o contato da conta **DCP Soluções** (uma das 3 contas Ganhas do "Farol Comercial") → `"Client"`. Confirma que é um campo real, em inglês, DIFERENTE do `lead_stage` em português visto no payload do webhook de conversão ("Lead Qualificado") — dois vocabulários reais da mesma plataforma, nunca colapsados.
- `fn_run_ingest_batch` (v6, migration 042) ganhou 2 seções novas: `WorkflowEvent` (chama `fn_record_touchpoint`, nunca insere direto em `lead_touchpoint`) e `FunnelStage` (só grava quando o estágio difere do último registrado — não é heartbeat diário). Ambas resolvem o lead vinculado via `identity_edge` (mesmo join de 027/032: rd_station rdstation_uuid → person → salesforce source_record_id → lead); contato sem lead vinculado é CONTADO e reportado em `ingest_run.error_message`, nunca descartado silenciosamente.

**Testado de verdade com um lead/contato de teste isolado** (criado e apagado depois — não havia como testar com um lead/contato real porque a ingestão Salesforce, 2.16, ainda está bloqueada, então o Postgres não tem o lead real correspondente a nenhum contato real do RD Station ainda), mas usando um WORKFLOW real (`🟢 Rescue - Oferta [06.26]`, id `7c232f92-b7c1-47fa-973b-7a29086f35be`) e os 2 valores de estágio REAIS confirmados acima:
1. Lote 1: `workflow_entrada` + estágio `"Qualified Lead"` → gravado corretamente (`{rows_target:1, status:ok}` nos dois).
2. Reprocessar o MESMO lote 1 → `{rows_target:0}` nos dois — idempotência real confirmada (sem duplicata em `lead_touchpoint` nem `lead_funnel_stage_event`).
3. Lote 2: `workflow_saida` + mudança real de estágio (`"Qualified Lead"` → `"Client"`) → gravado corretamente, 2 touchpoints e 2 eventos de estágio no total.

**2 bugs reais encontrados e corrigidos no processo** (nenhum hipotético — os dois só apareceram rodando de verdade):
1. `ON CONFLICT ON CONSTRAINT` não funciona sobre um índice único PARCIAL (`CREATE UNIQUE INDEX ... WHERE ...`) — Postgres não permite constraint parcial via `ADD CONSTRAINT`. Erro real: `constraint "uq_lead_touchpoint_workflow_evento" for table "lead_touchpoint" does not exist`. Corrigido (migration 041) usando a mesma forma já usada em `conversion_event`: `ON CONFLICT (colunas) WHERE <condição>`.
2. O contador de `WorkflowEvent` gravado usava `PERFORM` (descarta o retorno da função) — reprocessar o mesmo lote reportava `rows_target:1` de novo mesmo sem gravar nada (o dado em si estava protegido pelo `ON CONFLICT DO NOTHING`, só a MÉTRICA reportada estava errada). `FunnelStage` não tinha esse bug (já checava mudança antes de inserir). Corrigido (migration 042): `SELECT ... INTO` + só conta quando o retorno não é `NULL`.

**Limpeza confirmada:** lead/contact/identity_edge/stg_rdstation/ingest_run de teste todos apagados. Mantido permanentemente (dado real, não teste): a linha de `automation_workflow` do workflow real, e as 2 linhas de `funnel_stage` (vocabulário real observado).

**Falta para fechar 2.17 de vez:** o workflow n8n que de fato chama a API do RD Station numa agenda (Cron) e empurra pra `stg_rdstation`. Endpoint REST cru confirmado só para `workflow_leads_started` (`https://api.rd.services/platform/workflows/{id}/leads/started`, visto no `links.href` da própria resposta do conector MCP). Faltam confirmar o endpoint cru de `contact_funnel_stage_get` e de `workflow_leads_exited` (que tem rate limit severo por plano — Light/Basic 1/hora) antes de escrever os nós HTTP Request no n8n, já que o conector MCP do Claude usado nesta sessão não é chamável a partir do n8n.

## ✅ 2.17: workflow n8n construído e testado ao vivo (ainda inativo, aguardando revisão do usuário)

**Workflow real:** "CRM Ingest - RD Station Funil/Workflow (pull agendado)", id `3l8hobRXtjbzodZc`, 20 nós, Cron diário 03:00 America/Sao_Paulo. Estrutura: 3 cadeias independentes a partir do Cron (Funil de estágio; Workflow entrada; Workflow saída), cada uma terminando com sua própria chamada a `fn_run_ingest_batch` — sem nó de merge (evitado deliberadamente: idempotência do banco garante que chamar a função múltiplas vezes com o mesmo `$execution.id` como batch_id é seguro, então 3 chamadas independentes é mais simples e robusto que sincronizar 3 branches paralelas).

**Endpoint de estágio de funil descoberto SEM chutar:** um GET simples em `/platform/contacts/email:{email}` devolve um array `links` com a URL real: `CONTACT.FUNNEL: /platform/contacts/{uuid}/funnels/{funnel_name}`. Testado com `funnel_name=default` → 200, dado idêntico ao do conector MCP (`lifecycle_stage`). Testado com 5 contatos reais diferentes (e-mails REDIGIDOS deste log — ver nota de PII no fim do arquivo): 4 vieram `"Qualified Lead"`, 1 (o contato da conta **DCP Soluções**, uma das 3 contas Ganhas do Farol Comercial) veio `"Client"` — confirma o campo é real e reflete o funil de vendas de verdade, não um valor estático.

**Testado de ponta a ponta com um lead/contato de teste isolado** contra o workflow real "🟢 Rescue - Oferta [06.26]": entrada de workflow gravada, mudança de estágio Qualified→Client gravada, reprocessamento do mesmo lote confirmado idempotente (ver entrada anterior deste log). Todos os dados de teste apagados depois.

**2 achados reais de API, só visíveis testando de verdade (nenhum hipotético):**
1. `page_size=200` era rejeitado pela API real (`400 TOO_HIGH`, máximo real é 125) — descoberto só ao executar, não documentado antecipadamente em lugar nenhum que eu tinha acesso. Corrigido para 100.
2. Rate limit de BURST real: 3 chamadas próximas no tempo disparam `429 "Try spacing your requests out"` mesmo dentro do limite de 120/min documentado — API tem um limite de concorrência/burst não documentado explicitamente. Corrigido com `batching` (espaçamento de 15-20s entre chamadas) nos 2 nós HTTP que iteram sobre os 3 workflows.

**Não resolvido (real, fora do meu controle):** o endpoint `/leads/exited` devolveu `500 Internal Server Error` (página de erro real do próprio RD Station) em múltiplas tentativas nesta sessão — pode ser instabilidade real da plataforma nesse endpoint específico, ou efeito do volume de teste. A ROBUSTEZ do workflow a essa falha já está comprovada: com `onError: continueRegularOutput`, o item vira um erro tratado, o nó de mapeamento seguinte lida com isso (`|| []`), e o resto do workflow completa com status `success` mesmo assim — não trava, não corrompe dado, só não traz o dado daquele dia (comportamento aceitável para um pull agendado que roda de novo amanhã).

**Deixado INATIVO deliberadamente** — é uma automação recorrente escrevendo em produção; ativação é decisão do usuário, não tomada unilateralmente pelo agente.

## ✅ 2.18: ads (Meta/Google/LinkedIn) ligado ao Postgres via ADAPT do workflow existente — testado com dado real de produção

**Resolve, de fato, a pergunta original do usuário** ("automação mensal de investimento Google/LinkedIn Ads, sem depender do Windsor.ai"): o workflow n8n "Loupen Dashboard - Ads Data API" já chamava as APIs reais do Google Ads/LinkedIn Ads/Meta diretamente (credenciais OAuth próprias, sem Windsor.ai) para servir o dashboard ao vivo — só faltava um destino Postgres. Adaptado, não recriado (3 mudanças aditivas, testadas ao vivo antes/depois para confirmar zero regressão no consumidor atual):
1. Google Ads: GAQL ganhou `campaign.id` no SELECT (LinkedIn/Meta já traziam `id` real, só não estava sendo extraído).
2. `Combine Response` (Code node) passou a extrair esse `id` nos 3 arrays de campanha.
3. Ramo novo e paralelo (Build Ads Staging Rows → Insert stg_ads → Run Ingest Batch), sem alterar o ramo que responde o webhook.

`fn_run_ingest_batch` ganhou seção para `stg_ads.object_type='campaign'` → `ad_campaign` (migration 043), `campaign_ref_id` NULL por desenho (sem forçar match).

**Testado disparando o webhook REAL de produção** (mesmo endpoint que o dashboard já usa hoje) duas vezes — antes da mudança (confirma resposta idêntica ao consumidor atual) e depois (confirma `id` real presente nos 3 canais: Google Ads ex. `"20481588907"`, LinkedIn ex. `804900303`, Meta ex. `"120256183649680492"`). `ingest_run` confirma: 33 campanhas reais gravadas (13 Google Ads + 7 LinkedIn + 13 Meta Ads), `rows_source=rows_target=33`, `status=ok`. Spend real batendo com o que já foi levantado manualmente para o Farol Comercial (ex.: `LOGMEIN_RESCUE-LICENCA-ECO_08-26` = R$2.318,46 nos dois lugares).

**Sem cleanup necessário** — é dado real de produção, não teste sintético; fica no banco de propósito.

## ✅ 1.12: planilhas Google Sheets NÃO servem como carga histórica (ASM-5) — inspecionadas de verdade

**SHEET_SF** (`1xSC6e91_uHYRPkzD0idX3jJcb-GmhL-BCY4BMsZQuYc`, gid=0), 528 linhas: `Data de criação` 100% preenchida mas cobre só **14/06 a 08/09/2026** (~3 meses, não 6-12). Pior: os campos de nível-Oportunidade (`Valor da oportunidade`, `Produto`, `Oportunidade: Conta`) só estão preenchidos em **38 de 528 linhas (7%)** — a esmagadora maioria das linhas são só lead, sem oportunidade vinculada.

**Ponte_SF_RD_Station** (aba dentro de `12xck94yAtE94Z6XK-aZJW13q55mt9YQRNzFPsCDi2Og`), 44 linhas — confirma o gap já conhecido (memória: "known gaps 44/236 rows"). Tem os campos certos (`sf_record_type` 40/44, `sf_valor` 36/44, `sf_account_id` 44/44 preenchidos — equivalentes reais de RecordType.Name/Amount/ConvertedAccountId de CON-4), mas `sf_data_criacao_opp` varia de 2016 a 2026 numa amostra de só 44 linhas — denso o suficiente em lugar nenhum para servir de carga histórica real de 6-12 meses.

**Conclusão explícita (conforme a instrução de verificação pede): NÃO SERVE.** Nenhuma das duas planilhas, como existem hoje, sustenta ASM-5 para a janela de 6-12 meses decidida em OQ-9 — a carga histórica real (2.22) vai depender das janelas de retenção das APIs de origem (Salesforce Bulk API, ainda bloqueada em 2.16; RD Station), não destas planilhas manuais.

## ✅ 1.10: RD Station — MCP vs REST comparado de verdade (consolidação do que já foi descoberto construindo 2.17)

Comparação campo a campo, feita ao vivo nesta sessão construindo o pull agendado (2.17): `contact_funnel_stage_get` (MCP) devolveu exatamente o mesmo corpo que `GET /platform/contacts/{uuid}/funnels/default` (REST cru) — sem divergência. `workflow_leads_started_list` (MCP) bate com `GET /platform/workflows/{id}/leads/started` (mesma forma `leads[]` com contact/contact_id/started).

**Rate limit real:** 120 req/min documentado (`x-ratelimit-limit-quotas-minute`), MAS existe também um limite de BURST não documentado — 3 chamadas próximas no tempo disparam `429` mesmo dentro do budget de 120/min. `workflow_leads_exited` tem limite adicional por plano (visto: `x-ratelimit-limit-quotas-hour: 5`).
**Paginação:** `page_size` máximo real é **125** (rejeitado com `400 TOO_HIGH` acima disso) para os endpoints de workflow — não documentado em lugar nenhum que eu tinha acesso, só descoberto testando.
**Versão/edição da API:** `x-api-version: 2.0` (header real, confirmado em toda resposta).
**Janela de retenção:** NÃO verificada nesta sessão (exigiria dado histórico anterior ao que já temos) — fica como lacuna aberta, não inventada.

## ✅ 1.11: n8n — versão e capacidades inventariadas

n8n para de expor a versão via API a partir de 1.119.0 (confirmado pela própria ferramenta de diagnóstico) — a versão exata em produção não é obtível via API; precisa ser conferida em Settings → About na UI. **Header Auth por nó**: confirmado disponível no node Webhook (`authentication: headerAuth` é uma opção real do schema do node) — já em uso nos workflows CRM API. **CORS por nó**: confirmado AUSENTE — o schema do node Webhook não tem nenhuma propriedade de CORS/Allowed Origins entre suas 15 propriedades (achado original desta sessão, agora formalizado com a busca no schema do node). **Agendamento (Cron)**: confirmado funcional — o node Schedule Trigger foi criado e usado com sucesso no workflow real de 2.17. Issues #18528/#31234 não puderam ser confirmadas como aplicáveis ou não sem a versão exata — dependem do usuário checar em Settings → About.

## ✅ 6.9: NFR-6 provado por EXECUÇÃO (não por revisão visual de schema)

`db/queries/verificacao/nfr6-novo-canal.sql` prova NFR-6 rodando de verdade: tira uma impressão digital md5 de todas as colunas do schema central (lead/opportunity/campaign/contact/account/ad_campaign — **70 colunas**, fingerprint `a829b6c8fd4edc0a09cbb22e558d270e`), ingere um canal **inédito** (`tiktok_ads`, com métricas de forma deliberadamente diferente dos 3 canais reais — `video_views`/`saves`, que nenhum deles tem) pelo MESMO caminho `stg_ads` → `fn_run_ingest_batch` → `ad_campaign`, reconfere a impressão digital, e limpa o dado de teste.

Resultado: **NFR-6 OK** — canal novo ingerido sem uma única mudança de coluna. Limpeza verificada (0 resíduo em `ad_campaign` e `stg_ads`; as 33 campanhas reais de 2.18 intactas: 13 Google Ads + 7 LinkedIn + 13 Meta).

Se acrescentar um canal exigisse `ALTER TABLE`, este arquivo **falharia** (o insert quebraria por coluna faltando) em vez de passar silenciosamente — é prova por execução, não inspeção. A razão de fundo pela qual funciona: `ad_campaign.metricas` é `jsonb`, então a diferença de forma entre plataformas é absorvida em dado, não em DDL. Evidência independente e anterior a esta asserção: os 3 canais reais de 2.18 foram ingeridos pela primeira vez sem nenhuma migration de schema.

## ✅ 1.8: spike EC-7 — chave canônica e regra de conflito OK; achado real e inesperado sobre o índice GIN

`db/queries/verificacao/spike-ec7-identidade.sql` cobre os 3 itens que a subtask nomeia.

**(1) Chave canônica — OK.** `person.canonical_id` (uuid) é a chave; o vínculo com origem é `(source_system, source_record_id, identifier_type)` em `identity_edge`. Verificado no DADO (não relendo o DDL): 0 persons sem `canonical_id`, e 0 combinações apontando para mais de uma person (identidade ambígua na raiz).

**(2) Regra de conflito — OK.** 2 candidatos existentes (1 `provavel` score 0.769, 1 `conflito`), nenhum com `confidence >= 1`, nenhum par em conflito com `person_a = person_b` (que seria exatamente a fusão que R18 existe para impedir).

**(3) Custo real do Tier 2 com índice GIN — ACHADO INESPERADO E IMPORTANTE.** Medido sobre amostra sintética de **20.000 leads × 5.000 contatos** (a base real tem 13 leads e 6 contatos hoje — pequena demais para o planner sequer considerar um índice, então medir exigia volume; nomes sintéticos servem só para gerar trigramas realistas, nenhum número de negócio sai deles, e as tabelas são TEMP):

| # | Forma | Pares | Tempo |
|---|---|---|---|
| A | set-based, filtro de domínio + `similarity()` como predicado | 57.500 | **393 ms** |
| B | operador `%` (GIN utilizável), SEM filtro de domínio | 1.437.500 | 131 ms |
| C | loop row-by-row PL/pgSQL (**comportamento ATUAL da função**) | 57.500 | **488 ms** |
| D | operador `%` + filtro de domínio (equivalente a A) | 57.500 | **353 ms** |

**O índice GIN `idx_lead_nome_trgm` (criado na migration 004 explicitamente "para tornar similarity() sobre nome executável em escala") NÃO é usado pelo desenho atual do Tier 2.** Provado por `EXPLAIN (ANALYZE)`: com o filtro de igualdade de domínio de e-mail presente, o planner escolhe `Merge Join` pelo domínio e aplica `l.nome % c.nome` como **Join Filter** pós-join — o `Bitmap Index Scan` sobre o índice trigram só aparece no caso B, que tem semântica completamente diferente (1,4M pares vs 57,5k). A e D dão o mesmo resultado com custo praticamente igual (393 vs 353 ms), confirmando que o índice não está contribuindo.

Motivo: o filtro de domínio já é altamente seletivo e faz a poda pesada antes; o trigram não tem o que acrescentar. **O índice é peso morto para este caso de uso** — não é um bug (não quebra nada, só ocupa espaço e custo de escrita).

**Não virou asserção de falha, de propósito:** nenhum requisito define alvo de performance para o Tier 2 (NFR-2 é sobre a API de leitura, não sobre este job de reconciliação periódica). 488 ms para 20k × 5k é perfeitamente aceitável para um job periódico. A medição fica registrada para embasar uma decisão futura (dropar o índice, ou reescrever a função em forma set-based para ganhar ~20%) — **nenhuma das duas foi feita agora**, porque nenhuma é necessária e mexer nisso sem necessidade é otimização prematura.

## 🔴→✅ 2.20: LACUNA REAL — `sync_state` nunca foi escrito por ninguém (P-ING-2 não existia). Corrigido.

**Achado ao escrever as asserções** (não por leitura de código — por consultar a tabela): `sync_state` existe desde a migration 007, é citada no header da 012, e estava **vazia com zero writers** — nenhum `INSERT`/`UPDATE` contra ela em nenhuma das 43 migrations. A nota da 012 revela a intenção original ("o nó de workflow grava esse número separadamente em sync_state"), mas **nenhum workflow n8n fazia isso**. Ou seja: **P-ING-2 (watermark incremental) não estava implementado de forma nenhuma** — a tabela era decoração.

**Corrigido na migration 044**, e no lugar certo (SQL, não n8n — CRIT-4 põe regra de negócio no banco, e dois escritores independentes para `ingest_run` e `sync_state` poderiam divergir). Mecanismo: função `fn_registrar_ingest()` que grava `ingest_run` **e** faz upsert de `sync_state` na mesma chamada — os dois nunca podem divergir porque são escritos juntos. Substituiu os 8 `INSERT INTO ingest_run` duplicados dentro de `fn_run_ingest_batch` (`nao_mapeado` segue como INSERT direto: é relatório de falha, não watermark de fonte real).

**Decisão de desenho que mais importa: o watermark SÓ avança em `status='ok'`.** Se avançasse numa execução `partial`/`failed`, a próxima consulta de delta começaria *depois* de registros que nunca foram ingeridos — perda silenciosa de dado, exatamente a classe de defeito (EC-6, sincronização parcial se apresentando como completa) que este épico existe para corrigir. Em execução parcial o watermark fica onde estava e a janela é retentada. **Testado de verdade:** `fn_registrar_ingest('ads','ad_campaign', 99, 5, 'partial')` → `ingest_run` registrou a parcial, `sync_state.last_run_at` ficou **idêntico**.

### As duas asserções de 2.20

**`schema-provenance.sql`** — verifica a FORMA (AC-9.1). Desenho deliberado de **mundo fechado**: as tabelas são particionadas em duas listas explícitas (16 ingeridas × 11 isentas), e uma tabela que não esteja em nenhuma das duas faz a asserção **falhar**. O ponto: criar uma tabela nova força uma decisão consciente ("é dado ingerido ou é derivado/catálogo/infra?") em vez de escapar por omissão — uma verificação de mundo aberto passaria silenciosamente se alguém criasse amanhã uma tabela ingerida sem proveniência, que é o modo de falha que AC-9.1 existe para impedir. Cada isenção tem motivo real registrado no próprio arquivo (catálogo / derivada no banco / infra de ingestão).

Achado colateral, reportado como `NOTICE` e **não escondido**: `lead_touchpoint` e `lead_funnel_stage_event` usam `fonte` (português) em vez de `source_system` para a mesma semântica. Não é falha (as duas são proveniência válida), mas fica visível — uma consulta que filtra por `source_system` **não cobre essas duas tabelas** e ninguém notaria.

**`integracao-ingestao.sql`** — verifica o DADO, com execução real (insere, roda, compara, limpa):
- **AC-9.1** (dado): percorre dinamicamente as 16 tabelas ingeridas e falha se qualquer linha tiver proveniência ou `collected_at` nulos. **OK.**
- **P-ING-1** (idempotência): insere 1 campanha de teste, roda `fn_run_ingest_batch` **duas vezes** com o mesmo `batch_id`, verifica 1 linha nas duas vezes e que as duas execuções reportaram 1/1 `ok`. **OK.**
- **P-ING-2** (watermark): verifica que execução `ok` cria o watermark e que execução `partial` **não** o avança, e que a parcial fica registrada em `ingest_run`. **OK.**
- **EC-8/AC-9.2** (fonte indisponível): verifica que a lacuna é registrada com fonte+horário+motivo, e que o último dado válido **mantém idade e contagem reais** — nem apagado, nem zerado, nem com timestamp renovado (que faria dado velho passar por novo). **OK.**

### 🔴 Bug destrutivo que eu mesmo introduzi e corrigi (vale registrar como armadilha)

A primeira versão de `integracao-ingestao.sql` **destruiu o watermark real de produção**. Causa: `fn_run_ingest_batch` registra o watermark sob os literais **fixos** `'ads'`/`'ad_campaign'`, independente do `source_system` do payload — então o batch de teste (que usava `source_system='__teste_ping__'`, achando que estava isolado) sobrescreveu o watermark real de 33/33 para 1/1, e a linha de limpeza (`DELETE ... WHERE rows_source = 1`) então o apagou.

Descoberto porque conferi o estado do banco depois da limpeza em vez de confiar no "OK" da asserção. Corrigido com **save/restore explícito** da linha real de `sync_state` em volta do teste, e o cuidado está documentado em comentário no próprio arquivo. Verificado depois: watermark real intacto (33/33, mesmo timestamp antes e depois).

**Regressão completa:** as 17 asserções de `db/queries/verificacao/` passam juntas; dado real intacto (33 ad_campaign, 13 lead, 6 contact, 1 sync_state), zero resíduo de teste.

## ✅ 6.8: `db/README.md` finalizado — e o comando documentado foi testado, não só escrito

De 59 para ~185 linhas, cobrindo os 4 itens que a verificação de 6.8 exige (aplicar migrations, executar asserções, convenção de asserção, ausência de rollback) + o item de CON-12 que a nota pedia (rodar sem tooling).

**Testado de verdade em vez de assumido:** copiei o loop de "rodar todas as asserções" do próprio README e executei — as 17 passam. Rodei também o `bash db/apply.sh --dry-run` documentado (exit 0, lista as 45 migrations já aplicadas). Um README com comando que não funciona é pior que nenhum README.

Documentadas as regras que **não são óbvias** e que só se aprende errando:
- **Nunca editar migration já aplicada** — o checksum recusa reaplicar, então o runner falha. Para corrigir, migration nova (é o que 041/042 fazem sobre 039/040).
- **Ausência total de rollback** (seção própria): forward-only significa sem `down`, sem `--revert`. Cada arquivo roda em transação (protege contra falha *no meio*, não contra arrependimento *depois*). Desfazer exige migration inversa nova. Mudança destrutiva testa em **branch do Neon** primeiro — é o mecanismo de segurança disponível no lugar do rollback que não existe. E a role `crm_ingest` não tem DDL/`DROP`/`TRUNCATE` de propósito (INV-1): nenhum workflow de ingestão pode causar dano estrutural.
- **A armadilha do `SELECT 1/(subquery HAVING count=N)`** como forma de falhar — padrão que estava no plano original e **não falha** quando a condição é falsa (`NULL/x` = `NULL`, não divisão por zero). Registrado como proibido, com a alternativa correta.
- **Fallback de `PSQL_BIN`** para `/opt/homebrew/opt/libpq/bin/psql` — real: `psql` não está no `PATH` desta máquina, e sem isso o `apply.sh` não roda.

## ✅ 6.6: ADRs 015/016/017 escritos, com as alternativas rejeitadas e o que a implementação real revelou

Os 3 arquivos existem e a verificação (`test -f` x3) passa. Formato igual aos ADRs 020/021 já existentes.

Cada um traz as **alternativas rejeitadas com o motivo**, como a nota da subtask exigia — não só a escolha:
- **ADR-015** (invocação SQL pelo n8n): rejeitados chamada por linha em loop (N *round trips*, quebra P-ING-3, sem fronteira transacional do lote) e transformação em nó Code (devolveria a regra de negócio para fora do controle de versão, reabrindo R14).
- **ADR-016** (versionamento de reclassificação): rejeitados coluna de versão simples (perde o *de-para*, que é exatamente a pergunta que originou o épico) e tabela de log lateral (pode divergir da canônica porque nada no banco força os dois a andarem juntos — e log em que não se confia é pior que nenhum, porque dá falsa segurança).
- **ADR-017** (runners de teste): rejeitados Jest/Vitest (exigiriam `package.json` na raiz para testar JS que roda sem ele, e trazem transform/config — o começo de um build step) e harness caseiro em página HTML (sem exit code, logo inautomatizável; exigiria humano olhando a tela). Também rejeitado "um runner só para tudo".

**ADR-015 e ADR-017 ganharam seção "Atualização de 2026-09-09"** em vez de fingir que a decisão original previu tudo:
- Em **015**: a própria exceção que a ADR original abria — *"o nó de workflow grava esse número separadamente em `sync_state`"* — **era o furo**. Ninguém gravava. Corrigido movendo a escrita para dentro do SQL (migration 044), o que *fortalece* a decisão original de manter a regra no banco.
- Em **017**: duas armadilhas reais de invocação. (1) `npx --yes playwright test` **não funciona** — o npx instala em cache isolado e o `require()` de dentro de `tests/e2e/` nunca resolve; foi essa falha que motivou o `package.json` privado. (2) `node --test <diretório>` falha no Node v26.4.0 com `MODULE_NOT_FOUND`, e a saída (`✖ tests/contract`, `fail 1`) *parece* teste quebrado quando é o runner não achando nada — a forma correta é glob de arquivos. Verificado: `node --test tests/js/*.test.mjs tests/contract/*.test.mjs` → **39/39 passando**.

## 🚧 5.12: bloqueio real que não estava no grafo de dependências

5.7 e 5.9 (as dependências declaradas) estão `completed`, então 5.12 *parecia* disponível. Não está.

A subtask substitui a regra legada "pela classificação vinda do motor SQL". Hoje o dashboard **publicado** calcula `isMarketing` no cliente a partir das planilhas (`views-legacy.js:1733-1734`, dado de `SHEET_SF`/`Ponte_SF_RD_Station` via gviz). Trocar pela classificação real exige **chamar a API** — e um site estático no GitHub Pages não pode carregar a chave sem expô-la a qualquer visitante (mesma classe do incidente de PII já ocorrido neste repo). Logo 5.12 depende de fato de **phase-4** (Cloudflare Access injetando o segredo na borda), como 5.1 e 7.1. Dependência real a acrescentar: `4.12`. Status mudado para `blocked`.

**Nenhum meio-caminho foi feito de propósito:** mudar rótulo/filtro sem trocar a FONTE só maquiaria o defeito de EC-1 com números igualmente não auditáveis; e fabricar a classificação no cliente é o próprio bug que o épico existe para corrigir.

Estado atual do defeito, medido por grep: `!row.isMarketing` como definição de Comercial sobrevive em **1** lugar servido (`views-legacy.js:1860`); a outra ocorrência (`:2501`) é comentário, não regra. A verificação por grep de 5.12 portanto **ainda falha — corretamente**.

## 🔀 Fase 4 redesenhada — Cloudflare Pages + Access em conta nova (ADR-018)

**Gatilho real (2026-09-09):** o usuário confirmou que **não conseguirá acesso à conta Cloudflare** que administra `loupenapps.com.br`/`loupen.com.br`. Isso invalidou de uma vez cinco subtasks de phase-4 que dependiam de configurar coisas *naquela* zona.

O plano já previa esta bifurcação: **OQ-16 era exatamente "aceitar o plano B"** ("melhor postura de segurança do leque, ao custo de sair do GitHub Pages e introduzir passo de deploy"). O gatilho ocorreu, e o usuário aceitou o plano B.

### Fatos verificados ANTES de decidir (não assumidos)

- **Cloudflare Access consegue proteger `*.pages.dev`** — mas com um detalhe não óbvio: é preciso **remover o wildcard do campo *Subdomain*** da Access Application. A opção "Enable access policy" das configurações do projeto Pages protege **só os preview deployments**, não o hostname de produção. Cair nessa confusão deixaria o dashboard aberto acreditando estar protegido.
- **Zero Trust free = até 50 usuários, indefinidamente, sem cartão.**
- **Pages Functions têm secrets encriptados** acessíveis só server-side via `context.env` — invisíveis no painel depois de salvos, e nunca servidos ao cliente.
- **Secret tem de ser cadastrado ANTES do deploy que o usa** (explícito na doc da Cloudflare); cadastrar depois exige redeploy.

### O que foi construído (código, testado, sem depender da conta)

**`functions/api/[[path]].js`** — a Pages Function que atende `/api/*`, lê `context.env.CRM_API_KEY` e repassa ao n8n com o header. O navegador chama same-origin **sem chave nenhuma**.

Três decisões de segurança dentro dela, todas deliberadas:
1. **Allowlist, não proxy.** Só `GET`, e só `/api/meta`, `/api/leads`, `/api/leads/{id}`. **Não é redundante com o Access:** quem chega ali já é usuário autenticado `@loupen.com.br`, mas um proxy genérico permitiria a essa pessoa chamar **qualquer** webhook desta instância n8n — inclusive os de automação com efeito colateral real (escrita em planilha, Meta CAPI, cadastro no RD Station) — usando uma chave que ela nunca vê.
2. **`id` validado por regex** antes de compor a URL upstream, para que id malformado não vire *path traversal*.
3. **Resposta reconstruída com cabeçalhos próprios** — nenhum header de upstream é repassado, então o segredo não pode vazar por resposta.

**Testado isolando a função de rota:** as 3 rotas legítimas resolvem para a URL correta (incluindo a tradução do `webhookId` prependado que 5.1 descobriu); `/api/leads/../../evil`, id com espaço, `automacao-leads`, segmentos extra e caminho vazio são todos **bloqueados**.

**`assets/js/data-api.js`** — passou a ter três modos explícitos (mock / teste local / produção). O cutover agora é literalmente trocar `MODO_DADOS = 'mock'` → `'real'`: **uma constante**, exatamente como ADR-021 previu. O caminho de teste local (`window.__CRM_API_KEY__` chamando o n8n direto) foi **preservado** e tem precedência, para continuar possível validar integração sem depender de deploy.

**Verificado que nada quebrou:** 39/39 testes `node --test` e 8/8 Playwright (2 skipped, a limitação de contrato já conhecida) — o comportamento publicado segue idêntico, porque o padrão continua `mock`.

### Reestruturação do plano (nenhum id renumerado ou apagado)

Seguindo a mesma convenção da inversão de sequenciamento, o histórico da decisão fica auditável. Introduzido o status **`superseded`** para o que não deve mais ser feito:

| Subtask | Antes | Agora | Por quê |
|---|---|---|---|
| 4.1 zona + CNAME | pending | **superseded** | `*.pages.dev` dispensa zona/DNS/domínio |
| 4.2 SSL/TLS Full | pending | **superseded** | TLS de `*.pages.dev` é gerenciado; não há origin GitHub atrás do proxy |
| 4.3 Custom domain no GitHub Pages | pending | **superseded** | sai do GitHub Pages (objetivo migrou para 4.4) |
| 4.9 Origin Rule | pending | **superseded** | *propósito D9 preservado por construção* — `/api/*` é servido pelo mesmo projeto Pages, logo same-origin por definição |
| 4.10 URL Rewrite | pending | **completed** | resolvida pela `optionB` que **a própria nota já previa** ("o Worker passa a ser o único lugar do mapeamento") |
| 4.11 injeção do segredo | pending | **partial** | código pronto e testado; falta só cadastrar o secret (4.15) |
| 4.4, 4.5 | dep. de 4.3 | deps corrigidas | 4.4 → dep. 4.12 (desativar o antigo só depois de verificar o novo); 4.5 → dep. 4.14 |

**Acrescentadas 4.14 / 4.15 / 4.16** (criar conta+projeto Pages; cadastrar o secret e provar que `/api/meta` responde real; confirmar em produção que a allowlist recusa o que deve recusar).

**Conexão que vale registrar:** duas subtasks (4.10 e 4.11) **já sancionavam explicitamente** o Worker como alternativa — 4.10 dizia "esta subtask e 4.11 são substituídas por optionB (Worker de ~15 linhas)" e a verificação de 4.11 já aceitava "ou em Worker Secret". O gatilho previsto era outro (Transform Rules não estarem no Free), mas a saída projetada era esta. Não foi improviso.

### Postura de segurança: melhor, não pior

O desenho original precisava de **três** regras de borda coordenadas (Origin Rule + URL Rewrite + Request Header Modification) num painel que ninguém do time acessa. O novo tem **um arquivo versionado, revisável e com a lógica de rota testável isoladamente**, e a superfície exposta é uma allowlist de 3 rotas `GET` em vez de roteamento genérico.

**O que o gate continua NÃO cobrindo** (registrado para não criar falsa sensação de cobertura): o repositório segue público (contém código e o fixture anonimizado, não dado real); não é NFR-3 (permissão por perfil) — é um portão "não-é-estranho"; e não protege contra vazamento por acesso legítimo.

---

## 🔒 Nota de PII deste arquivo

**Regra para quem escrever aqui:** este arquivo vive num repositório **público**, e este repositório já teve um incidente real de vazamento de PII (391 nomes e 365 telefones, purgados em 2026-09-04 — ver `project_pii_exposure_incident`). Logo:

- **Nunca registrar e-mail, telefone ou nome de pessoa física** de lead/contato real, nem em exemplo, nem em log de teste, nem "só para lembrar qual registro foi usado".
- Para identificar um caso testado, usar o que **não** é PII: a campanha, o `source_id` do Salesforce, o estágio, a conta (pessoa jurídica), o resultado. Isso preserva a rastreabilidade sem expor a pessoa.
- Nome de **empresa** em contexto B2B (ex.: "DCP Soluções") é aceitável e foi mantido — já aparece como conta ganha nos relatórios executivos.

**Redação aplicada em 2026-09-09:** dois e-mails reais de lead que eu havia escrito nas entradas de 2.17 (um Gmail pessoal e um contato corporativo) foram substituídos pela descrição do caso. Encontrados por varredura de PII feita **antes** do primeiro envio ao repositório remoto — nunca chegaram ao GitHub.

**Pendência para o usuário decidir:** `docs/stories/epic-crm-lead-intelligence/spec/research-amendment-2.json` (linha 71) contém **3 e-mails reais** de leads, escritos numa fase anterior de pesquisa. Não foram alterados aqui porque são insumo de um artefato de pesquisa já revisado e a decisão de reescrever histórico de spec é do usuário — mas **devem ser redigidos antes desse arquivo ir para o repositório público**.
