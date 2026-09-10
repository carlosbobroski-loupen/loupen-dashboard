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

## ✅ Fase 4 EXECUTADA em produção — dashboard no ar, protegido, chave só no servidor

**URL:** `https://loupen-dashboard.pages.dev/` — Cloudflare Pages + Access em conta nova, conforme ADR-018. Execução feita pelo usuário com um agente operando o navegador; resultado item a item abaixo.

### Resultado da verificação (4.12/4.15/4.16)

| Item | Resultado |
|---|---|
| Gate bloqueia visitante sem sessão | ✅ requisição sem cookies (`credentials:'omit'`, `redirect:'manual'`) recebe redirect, nunca o dashboard; com cookie de sessão, 200 + dashboard |
| Login `@loupen.com.br` | ✅ PIN por e-mail, login concluído, dashboard carrega |
| `/api/meta` retorna dado real | ✅ JSON real com `ad_campaign` (33 linhas) — **não** o 500 de secret ausente |
| Navegador não envia `X-CRM-Api-Key` | ✅ (por auditoria de código; ver ressalva de método) |
| Allowlist recusa o que deve | ✅ `/api/automacao-leads` → 404; `/api/leads/a%20b` → 404; `/api/leads` → 200; `/api/meta` → 200 |

**Ressalva de método, registrada em vez de escondida:** dois itens não foram verificados exatamente como especificado. (1) O bloqueio anônimo foi provado por requisição sem cookies em vez de janela anônima literal — equivalente e, na prática, mais preciso. (2) A ausência do header foi verificada por auditoria do código de produção (o caminho real faz `fetch('/${caminho}')` sem objeto `headers`, então não há como enviar a chave) em vez de leitura da aba Network, porque a ferramenta de automação não expõe headers brutos. As duas substituições são defensáveis, mas ficam declaradas: não é o mesmo que ter visto o DevTools.

### 🔍 Achado real do item 5, e a correção que ele motivou

O agente reportou **falha parcial**: a string `X-CRM-Api-Key` aparece 2x em `assets/js/data-api.js` (um comentário e o branch de teste local), o que não bate com "zero ocorrências".

**Duas conclusões honestas:**

1. **O critério estava mal redigido — culpa minha.** O texto dizia "zero ocorrências de *valor de chave*", mas mandava buscar também pelo *nome* do header. O critério real (nenhum **valor** de chave no bundle) **passou**: não há chave hardcoded em lugar nenhum, só o nome do header como string, associado a uma variável que nenhum arquivo commitado define.

2. **Mas havia um vetor menor que o relatório não mencionou, e ele foi corrigido.** Com `MODO_DADOS='real'`, o branch de teste local tinha **precedência** sobre o caminho same-origin. Quem conseguisse injetar script na página (XSS, extensão maliciosa) poderia forçar o dashboard a abandonar as chamadas seguras e bater direto no n8n. Não vaza a chave — quem injetasse precisaria já conhecer um valor válido — mas é uma degradação evitável.

**Correção aplicada:** `_modoTesteLocal()` agora exige host local (`localhost`, `127.0.0.1`, `[::1]`, `file://`). Em produção o branch é **inalcançável**, independentemente do que seja injetado em `window`. Testado nos dois sentidos: ativa em localhost/127.0.0.1/[::1]/file://, **inativa** em `loupen-dashboard.pages.dev` e em `github.io` mesmo com a variável injetada.

**Não quebra nada:** verificado que **nenhum** spec Playwright usa essa variável (o uso foi manual, uma vez, em 7.1) e que o servidor de teste roda em `localhost:8123`. Regressão: 39/39 `node --test` e 8/8 Playwright (2 skips conhecidos).

**Decisão de NÃO remover o branch:** ele preserva a capacidade de validar a integração real localmente sem depender de deploy, que é valor concreto. Travá-lo em host local custa ~zero e elimina o risco — remover custaria essa capacidade sem ganho adicional.

### Diferenças reais entre a UI da Cloudflare e o roteiro (para a próxima vez)

Registradas porque um roteiro que não bate com a tela faz a pessoa duvidar de si em vez de duvidar do roteiro:

- **"Connect to Git" ficou atrás de um link "Continue to Pages"** na tela unificada de criação de Workers & Pages.
- **A pegadinha do wildcard NÃO se materializou:** na criação do app self-hosted, os campos *Subdomain* e *Domain* já vêm **separados**, e o *Subdomain* veio **vazio** — não existe mais o campo único com `*` pré-preenchido que a documentação/comunidade descrevia. O alerta era baseado em material mais antigo; foi inofensivo, mas está corrigido aqui.
- **Ativar Zero Trust pela primeira vez exigiu tela de seleção de plano + checkout, mesmo no Free** — envolve dados de cobrança, então o usuário precisou concluir pessoalmente. Vale avisar de antemão: assusta, mas o plano Free segue sem custo.
- **"One-time PIN" não é um toggle em Settings:** está em *Integrations → Identity providers*, e precisou ser **adicionado explicitamente** como provedor.

### Restrições respeitadas

GitHub Pages **não** foi desativado (é 4.4, só depois desta verificação); nenhum outro domínio ou zona DNS da conta foi tocado; nenhum arquivo do repositório foi alterado pelo agente do navegador.

### ✅ Verificação independente do gate (feita pelo agente, sem depender do relatório do navegador)

Depois do relatório da execução, confirmei o gate por fora, com `curl` anônimo contra o hostname de produção. **Toda** a superfície responde `302` para o login do Access:

```
/                          -> HTTP 302 -> ...cloudflareaccess.com/cdn-cgi/access/login/...
/assets/js/data-api.js     -> HTTP 302 -> (idem)
/api/meta                  -> HTTP 302 -> (idem)
/api/leads                 -> HTTP 302 -> (idem)
```

Três coisas que isso prova, e que são mais fortes do que o que havia sido testado:

1. **O gate cobre os ativos estáticos, não só o HTML.** Um visitante anônimo não consegue nem baixar os `.js`. Isso reduz ainda mais a relevância do achado do item 5 (a string `X-CRM-Api-Key` no bundle): além de não conter valor de chave e de o branch estar travado em host local, o arquivo **não é alcançável** sem sessão válida.
2. **O gate cobre `/api/*`**, que era o risco R5 (Access não cobrir a API). No desenho novo isso é estrutural — mesma origem, mesmo projeto — e agora está confirmado empiricamente, não só por raciocínio.
3. **A aplicação foi criada no hostname de PRODUÇÃO**, não só nos previews — que era o objetivo do passo do wildcard. O JWT do redirect trazia `"hostname":"loupen-dashboard.pages.dev"` e `"auth_status":"NONE"`, confirmando qual host o Access está protegendo.

**Efeito colateral útil de notar:** por causa disso, não é possível auditar o conteúdo do JS publicado sem autenticar. Uma tentativa de `grep` no arquivo servido devolve o HTML da tela de login — o que pode ser confundido com "o arquivo não tem o código esperado". Vale lembrar disso em auditorias futuras.

---

## 2026-09-09 — Etapa 8: inventário da fonte e revisão do contrato de filtros

### O erro de método que originou esta etapa

O usuário apontou, corretamente, que o pipeline de spec pesquisou arquitetura, custo e
integração mas **nunca enumerou os campos que a fonte entrega**. Os 4 filtros do contrato
(`segmento`, `canal`, `campanha`, `periodo`) saíram de suposição sobre o que o negócio queria,
não do que o RD Station tem.

Registrado como **regra permanente**: inventariar a fonte é a primeira tarefa de qualquer
trabalho de dados, antes de contrato, schema ou tela. Nenhum filtro entra no contrato sem uma
taxa de cobertura **medida** ao lado dele.

### Inventário executado (não revisão de documentação)

Chamadas reais à API de produção do RD Station:

- `contact_custom_fields_list` → **35 campos**, dos quais 3 com enum fechado.
- `campaigns_search`, `forms_search`, `landing_pages_search` → **todos vazios**. A conta não usa
  ativos nativos do RD; as conversões vêm de formulários externos. Isso invalidou a hipótese de
  tirar "tipo de conversão" de metadado de ativo — ele vem do evento.
- `segmentation_list` → **25 segmentações** (7 padrão de funil + 18 coortes reais de campanha).
- `get_contact_events` (event_type é enum `CONVERSION | OPPORTUNITY`) → shape real do payload.

### Achado que mudou a modelagem

`traffic_source` chega como `encoded_` + **base64 de um JSON** com `first_session` e
`current_session`. Decodificado localmente e confirmado: **o RD Station já entrega atribuição de
primeiro e último toque em todo evento de conversão**, sem instrumentação. Estava 100% sem uso.

Segundo achado, do mesmo payload: a firmografia é **por evento, não por lead**. No mesmo contato
real, `job_title` vai de `Diretor` para `CEO, Founder, Sócio` e `cf_tamanho_da_empresa` de
`1 a 19` para `20 a 99`. O cadastro guarda só o último valor. Gravar firmografia apenas em `lead`
perderia informação que a fonte tem — daí `lead_conversion_event` (migration 045).

### Medição de cobertura — 250 contatos reais, 0 erros

Fluxo de diagnóstico criado no n8n, executado por webhook e **removido no mesmo dia** (não ficou
resíduo). Credencial RD usada em modo GET apenas, conforme a regra permanente.

**Duas recomendações minhas foram derrubadas pelo dado:**

| Campo | Cobertura | Efeito |
|---|---|---|
| `cf_numero_de_funcionarios` | **0,0%** | eu havia recomendado como oficial "porque é lista fechada". Está vazio. |
| `cf_cargo_profissional` | **0,0%** | descartado |
| `cf_tamanho_da_empresa` | 36,4% | **vence** por medição |
| `job_title` | 90,0% | **vence** por medição |

**Três filtros que eu propus e o dado não sustenta** — retirados, não maquiados:
`city`/`state`/`country` (0,0%), `cf_nome_do_anuncio`/`cf_grupo_de_anuncio` (0,0% — o drill-down
de mídia tem 2 níveis, não os 4 que eu havia desenhado), `cf_atuacao_da_empresa` (0,4%, enum de
19 setores efetivamente vazio).

**Duas dimensões melhores que qualquer uma que eu havia proposto:** `tags` (**94,4%**, e é o único
campo nativamente multivalor) e `cf_falou_com` (**82,0%**, quem atendeu o lead).

**Descoberta de negócio, não de software:** UTM está preenchida em **7,6%** dos contatos e `gclid`
em 0,8%. O motivo pelo qual ROI por campanha era difícil de montar não é a ferramenta — é que
92% das conversões não chegam tagueadas.

### Decisões do usuário registradas

1. **Tamanho e cargo decididos por medição** (instrução dele), não por preferência de desenho.
2. **Exclusão de dado de teste:** critério livre para o agente. Escolhido: marcar com `is_teste`
   via tabela de regras auditável, **nunca deletar**, com contagem por regra visível na aba
   Qualidade de dados.
3. **Grão de contagem:** visão geral conta lead distinto; visão por campanha conta o lead em cada
   campanha em que converteu. **Consequência que a UI é obrigada a rotular:** a soma da coluna por
   campanha é legitimamente maior que o total geral.
4. **Dois eixos de campanha, nunca fundidos** (escolha dele entre 3 opções apresentadas):
   `origem_conversao` (eixo A, 100%, jamais recebe investimento) e `campanha_midia` (eixo B, 7,6%,
   único que recebe investimento/ROI). Fundi-los produziria ROI errado sem avisar.

### Estado que impediu o cutover imediato

O usuário autorizou `MODO_DADOS = 'real'`. Consulta ao Postgres de produção mostrou:
`lead` com **13 registros, todos `source_system = 'seed_test'`**; `lead_touchpoint` com 2;
`lead_funnel_stage_event` com 0; `ad_campaign` com 33 reais.

Causa: o fluxo `CRM Ingest - RD Station` (20 nós) parte de contatos **já vinculados** no Postgres.
**Não existe descoberta de leads** — nada nunca leu a base de contatos do RD para dentro do banco.
Virar a chave agora trocaria 13 leads falsos rotulados por 13 leads falsos não rotulados.

Ordem corrigida: ingestão primeiro, asserção depois, chave por último. A autorização segue válida.

### Verificado por execução

`db/queries/verificacao/normalizacao-perfil-lead.sql` — 5 asserções, todas OK:

```
ASSERCAO 1 OK: os 13 casos de tamanho_empresa batem
ASSERCAO 2 OK: distribuicao 72/12/7 confere com data-contract.md 1.4
ASSERCAO 3 OK: os 7 casos de cargo_grupo batem
ASSERCAO 4 OK: as 5 regras de cargo sao todas de valor observado
ASSERCAO 5 OK: as 3 regras de lead_teste_regra estao ativas
```

**Teste negativo da asserção 2**, porque asserção que nunca falha não vale nada: perturbando o
esperado de 72 para 73, ela devolveu `FALHOU corretamente (2 divergencia)`. A asserção detecta
divergência de verdade — não é o antipadrão `SELECT 1/(subquery HAVING count=N)`.

### Pendente desta etapa

Fluxo de descoberta de leads no n8n (a peça que nunca existiu), asserção de ingestão sobre dado
real, cutover, e os filtros na tela. `cargo_grupo_regra` tem só as 5 regras de valor **observado**;
as demais devem sair da lista de distintos da primeira ingestão cheia, nunca inventadas.

---

## 2026-09-09 (cont.) — Etapa 8: ingestão de leads do RD Station em produção

### Migrations aplicadas

`045` tabela `lead_conversion_event` + normalizações · `046` `fn_lead_e_teste` e
`fn_resolve_lead_por_rd_uuid` · `047` v8 com as seções RDLead/LeadConversion ·
`048` **correção de regressão** · `049` grants de sequência · `050` regras de cargo observadas.

### 🔴 Regressão que eu introduzi e como foi pega

Montei a `047` reaproveitando o corpo da `043` (v7) por substituição de texto. Mas a `044` já
era a v8 e havia trocado todos os `INSERT INTO ingest_run` por `PERFORM fn_registrar_ingest(...)`,
que grava `ingest_run` **e** `sync_state`. Reconstruir da v7 reverteu isso: o watermark
incremental (P-ING-2) pararia de avançar **em silêncio** — sem erro, sem log.

Pega antes de rodar qualquer coisa, ao verificar se alguma migration posterior à minha base
mexia nas mesmas linhas. Corrigida na `048`, reconstruindo a partir da `044` com verificação
por contagem antes de escrever o arquivo: 11 chamadas de `fn_registrar_ingest` no código e
1 único `INSERT` direto (o catch-all `nao_mapeado`, que é `failed` de propósito).

**Regra tirada disto:** reaproveitar corpo de função por substituição de texto exige conferir
contra a versão **mais recente**, nunca contra a que estava aberta.

### 🔴 Lacuna de privilégio anterior a esta etapa

A ingestão falhou no último nó com `permission denied for sequence lead_conversion_event_id_seq`.
Causa raiz verificada em `pg_default_acl` (não suposta): existia `ALTER DEFAULT PRIVILEGES` para
**tabelas** (`crm_ingest=arw`) e **nenhum para sequências**. Toda tabela nova nascia com
INSERT/SELECT/UPDATE automáticos e a sequência dela nascia sem nada.

Não era específico desta tabela — ia disparar na próxima `bigserial`, quem quer que a criasse.
A `049` concede nas 26 sequências existentes **e** registra o default privilege para as futuras,
fechando a classe do problema.

Armadilha encontrada ao escrever a verificação: `relkind='S'` e `has_sequence_privilege()` no
mesmo `WHERE` falha com `"pg_toast_16618" is not a sequence`, porque o planner pode avaliar a
função antes do filtro. Resolvido com CTE `MATERIALIZED` como barreira de otimização.

### Três asserções minhas que estavam erradas (o código estava certo)

Em `ingestao-rd-leads.sql`, três asserções falharam por expectativa minha equivocada, não por
defeito de código. Registradas porque o padrão do erro se repetiu:

1. Contei 1 relato de lote parcial quando o arquivo roda o lote **duas** vezes.
2. Esperei watermark para `LeadConversion`, mas `fn_registrar_ingest` **só avança em `ok`** e o
   lote ficou `partial` por causa do evento órfão. É o comportamento correto da `044` — se
   avançasse num lote parcial, os órfãos seriam pulados para sempre. Virou a **asserção 9**,
   que agora trava essa propriedade.
3. Contei 3 versionamentos de classificação como falha, quando são 3 leads com 1 versão cada.
   O que prova idempotência é nenhum lead ter `version > 1`, não a contagem total.

O arquivo tem 10 asserções, todas OK, e roda dentro de `BEGIN ... ROLLBACK` — o que elimina a
classe do erro que me custou o watermark de produção numa sessão anterior. A asserção 6 compara
o watermark de ads antes e depois justamente para provar o isolamento.

### ✅ Ingestão real executada

Fluxo `x1md8DzjX6psKXNR` — `CRM Ingest - RD Station Leads (descoberta + conversoes)`.

**Primeiro obstáculo:** `helpers.httpRequestWithAuthentication` **não é suportado no Code Node**
desta instância (roda em task-runner isolado). Reestruturado para nós HTTP.

**Segundo obstáculo, de desenho:** o endpoint de eventos do RD **não devolve o uuid do contato**,
e o nó HTTP divide array de resposta em vários items, destruindo o item-linking do n8n. Resolvido
com junção explícita por **e-mail** (identificador primário do contato no RD), que é
determinística e não depende de `pairedItem`.

**Resultado em produção:**

| | |
|---|---|
| Leads reais do RD ingeridos | **125** (antes: 0 — só 13 de `seed_test`) |
| Marcados como teste pelas regras | **26** (21% da base) |
| Eventos de conversão | **134** |
| Duplicatas de fonte colapsadas | **18** (136→120 num lote, 16→14 no outro) |
| Origens de conversão distintas (eixo A) | 7 |

A deduplicação da §1.7 **confirmou-se em dado real**: 18 eventos com mesmo lead, mesma origem e
mesmo `event_timestamp` ao segundo.

### Cobertura medida na ingestão real vs. na amostra de 250

| Campo | Amostra (250) | Ingestão real (99 não-teste) | Veredito |
|---|---|---|---|
| `tags` | 94,4% | **97,0%** | confirma |
| `cargo` | 90,0% | **85,9%** | confirma |
| `atendido_por` | 82,0% | **79,8%** | confirma |
| `tamanho_empresa` | 36,4% | **17,2%** | ⚠️ **divergiu** |

**A divergência de tamanho de empresa é material e precisa constar.** A amostra de 250 cobria a
base toda; esta fatia são os contatos mais **recentes** (corte 2026-04-01, ordenado por última
conversão). Contato recente tem menos enriquecimento firmográfico. Ou seja: no período que o
dashboard olha, `tamanho_empresa` fica em `nao_informado` para 82 de 99 leads. O filtro existe e
é honesto, mas vai ser pouco útil até a captação melhorar.

### Atribuição: correção da minha própria empolgação

Dos 134 eventos reais: **96 sem `traffic_source` decodificável**, 35 com `(none)`, 2 com UTM,
1 com URL de página. Ou seja ~28% dos eventos têm sessão de origem legível.

Eu havia apresentado a atribuição de primeiro/último toque como "de graça e nativa". É nativa,
mas **não é universal** — e no dado real ela cobre menos de um terço dos eventos. Falta
distinguir "campo ausente no payload" de "falha de decodificação": o decodificador atual devolve
`null` nos dois casos. Pendência registrada.

### `cargo_grupo` semeado por evidência (migration 050)

A ingestão produziu **31 valores distintos** de `job_title`. As 14 regras novas saem todas de
valor observado, com a contagem no comentário de cada uma. Resultado: **0 de 111 cargos
preenchidos seguem em `outros`**.

Duas distinções que o dado revelou:

- `Outro`/`outro` (10x) é a pessoa **tendo escolhido "Outro"** no formulário — resposta, não
  lacuna. Vai para `outro_declarado`, e `outros` volta a significar só "nenhuma regra casou",
  que é o sinal que a aba Qualidade de dados usa para pedir regra nova.
- `Fundador`/`Fundadora` é a forma portuguesa de Founder, e as regras da `045` só cobriam
  `Founder` — 5 sócios-fundadores estavam caindo em `outros`.

Distribuição real (99 leads não-teste): c_level 42 · nao_informado 14 · gerencia 11 ·
outro_declarado 10 · analista 8 · diretoria 7 · operacional 3 · consultor 2 · coordenacao 2.

### Pendente

View de perfil + `fn_search_leads` com os filtros novos; cutover de `MODO_DADOS`; filtros na
tela. E investigar por que 72% dos eventos não trazem `traffic_source` legível.

---

## 2026-09-09 (cont.) — Etapa 8: camada de leitura, cutover e filtros na tela

### Carga completa de Q2/Q3

| | |
|---|---|
| Leads reais do RD Station | **500** |
| Eventos de conversão | **766** |
| Duplicatas de fonte colapsadas | **145** só no último lote (777→632) |
| Origens de conversão distintas | **23** |
| Leads marcados como teste | 39 (26 por regra + 13 seeds meus) |
| Leads visíveis por padrão | **474** |

### Migrations 051–054

`051` `view_lead_perfil` + `view_campanha_lead` + `fn_search_leads` v2 · `052` tradução de
segmento e marcação dos seeds · `053` `fn_opcoes_filtro` · `054` **restauração de filtro que eu
removi por engano**.

**Duas views e não uma, de propósito.** O grão de contagem depende da visão (§1.7):
`view_lead_perfil` é um registro por lead; `view_campanha_lead` é um por (origem, lead). Separar
torna difícil somar a coluna errada — quem lê a segunda sabe que está num grão multiplicado,
porque o nome diz.

**`cargo_grupo` e `tamanho_empresa` NÃO são materializados.** São funções puras sobre tabela de
regra, e materializá-los ficaria obsoleto no instante em que uma regra nova entrasse — que é
exatamente o que a `050` acabou de fazer. Derivados na view, a próxima regra vale
retroativamente sem reprocessar ingestão.

### 🔴 O contrato estava errado sobre `segmento`

O contrato dizia 3 valores minúsculos (`marketing | comercial | nao_atribuido`). A view devolveu
`NaoAtribuido`. Investigado: `lead_origin_classification` tem CHECK constraint com **4** valores
em CamelCase, incluindo `Parceiro`.

**Quem estava errado era o contrato.** Colapsar `Parceiro` em um dos outros três para "caber"
destruiria informação de negócio. Resolvido com `fn_segmento_contrato()` — um único ponto de
tradução, com asserção que falha se a CHECK ganhar valor novo e a função não.

### 🔴 Regressão que eu introduzi e que os testes pegaram

Ao escrever `fn_search_leads` v2 eu listei as 13 dimensões novas e **não recoloquei o filtro
`campanha`** (match contra `valor_bruto` da atribuição), que sustenta o pivô campanha→leads
(AC-4.1). Pior: no cliente tratei `campanha` como **apelido** de `campanha_midia`, que é o eixo B
(UTM de mídia paga, 7,6% de cobertura). São conceitos diferentes — aliasá-los faria o pivô
devolver vazio quase sempre.

**Pego por 4 specs Playwright, todos os quatro sobre campanha.** Minha primeira leitura foi
"os specs quebraram por efeito esperado do cutover" — se eu tivesse aceitado isso, a regressão
teria passado. Corrigido na `054`, e agora os três conceitos convivem sem se misturar:

| Filtro | Significado | Recebe investimento? |
|---|---|---|
| `campanha` | `valor_bruto` do sinal de atribuição (o pivô) | não |
| `origem_conversao` | eixo A — ativo que converteu (100%) | **nunca** |
| `campanha_midia` | eixo B — veiculação paga (7,6%) | **sim, só ele** |

### 🔴 Bug no meu próprio mecanismo de teste

Para o cutover não desativar a suíte e2e (que roda em localhost sem chave de API), criei um
override `?dados=mock`, travado em host local. Os specs passaram a falhar num ponto novo:
`atualizarEstado()` reescreve a query string inteira ao limpar filtros e **apagava o
`dados=mock`** junto — a página caía em modo real no meio do teste.

Corrigido lendo o override **uma vez, na carga do módulo**. Também é o comportamento correto por
natureza: é chave de sessão de teste, não filtro, e não deve mudar durante a navegação.

### Uma asserção de teste que eu afrouxei, e por quê

Um spec exigia literalmente `'segmento: Comercial'` em minúscula no estado vazio. A reescrita
usa `Segmento:` para casar com os rótulos da barra de filtros. Tornei a asserção insensível a
caixa, com o motivo escrito no próprio teste: o que ela garante (INT-1 — o estado vazio NOMEIA os
filtros ativos em vez de mostrar "0" sem contexto) continua valendo; forçar minúscula deixaria a
tela inconsistente consigo mesma só para satisfazer a letra.

### Correções na interface que eram dívida real

1. **`fonte_dados` era `'salesforce'` FIXO** em `_adaptarItemLista`, com um TODO dizendo que
   deixaria de ser fixo "quando o RD Station entrar na busca". Entrou — e o valor fixo passaria a
   **mentir**, rotulando 500 leads do RD Station como Salesforce.
2. **KPIs faziam 1 chamada de detalhe POR LEAD** (`_carregarDetalhesParaKpis`). O próprio
   comentário dizia que não era padrão para escala. Com 474 leads seriam 474 chamadas por render.
   Removido — os KPIs saem da lista já retornada.
3. **Período era filtrado no CLIENTE** sobre a página retornada: com paginação isso descartava
   linhas em vez de reconsultar, e o total exibido não correspondia ao filtro. Agora é servidor.
4. **Inconsistência que eu mesmo criei:** as pills de segmento aparecem todas acesas (ausência de
   filtro = sem restrição), mas minha primeira lógica fazia clicar numa **selecionar só ela**.
   Corrigido para desligar a partir do baseline, seguindo o que o visual promete. Os checkboxes
   dos dropdowns mantêm semântica de marcar/desmarcar — controles com aparência diferente devem
   ter interação diferente.

### As opções de filtro vêm do dado, não de enum

`fn_opcoes_filtro()` devolve as opções de cada dimensão **com contagem de leads**, e a interface
monta os controles a partir disso. Dimensão sem dado **não é oferecida** — foi assim que
`cf_atuacao_da_empresa` (0,4%) quase entrou como filtro.

No modo mock as opções são derivadas do próprio fixture, não devolvidas como null: o princípio
("a opção vem do dado") vale nos dois modos, muda só qual dado.

### ✅ Cutover executado

`MODO_DADOS = 'real'`. Feito **depois** de a ingestão existir e ser verificada — não no momento
da autorização, quando `lead` tinha 13 registros de `seed_test` e virar a chave teria trocado
13 leads falsos rotulados por 13 leads falsos não rotulados.

### Verificação

- Playwright: **8 passam**, 2 skipped (já bloqueados antes, por limitação de contrato em 5.11).
- Contrato (node): **11 passam**.
- `fn_search_leads` verificado contra dado real: 42 c_level; **10** ao cruzar com `pequena`
  (interseção, menor); **60** no multi-select de 3 cargos (OR interno, maior); `campanha`
  restaurada devolve 17; campanha inexistente devolve 0.

### Pendente

- **Deploy**: exige commit + push (push é @devops-exclusivo, Artigo II — o usuário empurra).
- Aba Qualidade de dados ainda não mostra a contagem de exclusão POR REGRA, que o contrato §1.6
  promete. As regras e o `teste_regra` por lead já existem no banco; falta a tela.
- 72% dos eventos sem `traffic_source` legível — falta distinguir "campo ausente" de "falha de
  decodificação".
- Aba de oportunidades (cruzamento com Salesforce) segue bloqueada no consentimento OAuth.

---

## 2026-09-09 (cont.) — Etapa 8: aba de qualidade e atribuição mensurável

Trabalho autônomo depois do push de `f75d3d4`. Nada aqui exigiu decisão do usuário.

### Migrations 055–059

`055` `fn_qualidade_dados` · `056` 2ª rodada de regras de cargo e tamanho ·
`057` coluna `atribuicao_status` + v10 · `058` backfill do status + v11 ·
`059` `fn_qualidade_dados` usando a coluna nova.

### 🔴 A aba de qualidade encontrou um bug meu em 5 minutos

`fn_qualidade_dados` lista os cargos que nenhuma regra classificou. Primeira execução:
**`Outros` com 27 leads** no topo. Minha regra da `050` era `'Outro'` em **match exato** — o valor
real na base é `Outros`, plural. 27 leads caíam em "sem regra" por uma letra.

Mais dois do mesmo tipo, também revelados pela lista:

- `%Gerente%` não pega `Gestor De Marketing`. Funcionava para `Gestor/Gerente` (que contém
  "Gerente"), e isso me deu falsa confiança de que "Gestor" estava coberto.
- `%Head de%` não pega `Head` sozinho — regra escrita a partir de UM valor observado, estreita
  demais.

**Efeito das correções:** cargos em `outros` caíram de **92 para 10** de 439 preenchidos.

### Uma dimensão que o campo escondia

`TI / Tecnologia` (17 leads), `Comercial / Vendas` (8), `Marketing`, `Comunicação`: não são
respostas de senioridade, são **áreas**. O formulário mistura duas perguntas no mesmo campo
`job_title`. Colapsá-las em algum nível de cargo inventaria senioridade que a pessoa não informou,
então foram para `area_declarada` — 27 leads que antes poluiriam qualquer filtro de nível.

O que fica em `outros` de propósito: a cauda de cargos livres com n=1 (`Apresentadora`,
`Psicóloga`, `Engenheiro de plataforma`…). Escrever regra a partir de um único caso seria
construir taxonomia por palpite. `outros` com 10 de 439 é estado saudável, e a aba mostra quais são.

### Tamanho de empresa: respostas por palavra

A função só extraía números, então devolvia `nao_informado` para `Grande`,
`Sou autônomo / Profissional independente` e `ste` — misturando "não informou" com "informou e
não entendemos". Agora há um ramo por palavra: ilegíveis caíram de 3 para 1 (só o `ste`, que é
lixo mesmo).

### 🔴 Duas asserções latentes desde as migrations 050 e 052

Ao rodar `normalizacao-perfil-lead.sql` depois da `056`, duas asserções falharam — e as duas
estavam quebradas **desde antes**, porque eu acrescentei regras e não reexecutei a asserção que
cobria aquele comportamento:

1. Travava `Analista de TI -> outros`, verdade quando o arquivo nasceu (5 regras) e obsoleta
   desde a `050`, que acrescentou `%Analista%`.
2. Exigia **exatamente 3** regras de teste ativas; a `052` acrescentou uma quarta legitimamente.

**Lição concreta:** acrescentar regra é mudar comportamento coberto por asserção, e a asserção tem
de rodar no mesmo passo. A asserção 5 foi reescrita para verificar o **invariante** do contrato
§1.6 (toda regra ativa tem campo, padrão e motivo — exclusão auditável) em vez de uma quantidade.
Foi o **quarto** erro do mesmo tipo neste projeto: travar valor absoluto em vez do invariante.

### Atribuição: separando limitação da fonte de bug nosso

O coletor devolvia `null` tanto quando `traffic_source` vinha **ausente** do payload quanto quando
a **decodificação falhava**. Somados, viravam um número só ("332 eventos sem sessão decodificável"),
escondendo a única distinção acionável.

`atribuicao_status` (057) tem 4 estados: `ok`, `ausente` (limitação da fonte, sem ação nossa),
`ilegivel` (**bug nosso, tem correção** — é o número a vigiar) e `NULL` (evento anterior à coluna).

O `NULL` **não foi retroagido**: sem reingerir não há como saber qual caso era, e um palpite
apagaria a lacuna. A `058` permite que uma reingestão complete o status **sem tocar nenhum outro
campo** (`COALESCE` + `WHERE ... IS NULL`, nenhuma outra coluna no `SET`).

### 🔴 Armadilha que a 058 criou e que eu quase deixei passar

O contador de eventos gravados usava `IF FOUND`. Com `DO UPDATE` condicional, `FOUND` passa a ser
true também quando o conflito apenas **preencheu o status** de um evento pré-existente — o que
inflaria `rows_target` e **destruiria a prova de idempotência**: reprocessar o mesmo lote passaria
a reportar linhas novas que não existem.

A v11 distingue pelo `ingested_at` da linha contra o início do lote, e reporta o preenchimento
como objeto separado (`LeadConversion_StatusPreenchido`) em vez de somar. Verificado: execução 2
do mesmo lote segue reportando `LeadConversion 5 → 0`.

É o mesmo tipo de erro da `042` (PERFORM descartando o retorno que servia de contador): **a
métrica mente enquanto o dado está certo**. Métrica que mente é pior que métrica ausente, porque
ninguém desconfia dela.

### Aba Qualidade de dados — quatro seções novas

Cumpre o que o contrato prometia e não tinha:

- **Cobertura dos campos de filtro** — barra por dimensão com semáforo (<40% vermelho, 40–79%
  âmbar, 80%+ verde). Existe para ninguém usar um filtro sem saber de quantos leads ele fala.
- **Dados de teste excluídos, por regra** (§1.6) — cada regra com o que pegou, o padrão e **o
  motivo pelo qual existe**. Regra com 0 leads também aparece: ou o padrão está errado, ou o
  problema parou de ocorrer.
- **Valores sem regra de classificação** (§1.3) — os cargos e tamanhos que ninguém classificou.
- **Atribuição de origem** — os 4 estados, com destaque no `ilegivel`.

Também corrigidos dois bugs de exibição que só apareceriam em modo real: `_formatarData(null)`
chamava `.slice()` em null e derrubava a aba inteira (o watermark É null quando a fonte nunca
completou execução íntegra), e `leadNome` null era renderizado como a string "null".

### Fluxo de estágio de funil — a razão de `estagio_funil` estar vazio

O ramo de funil do fluxo agendado nunca rodou: a query `Contatos Vinculados` exigia vínculo
`identity_edge` → lead do **Salesforce**, e sem Salesforce ela devolve zero linhas. Correto quando
foi escrita; obsoleto desde que existem leads nativos do RD.

Ampliada com a mesma precedência de `fn_resolve_lead_por_rd_uuid` (Salesforce canônico, RD nativo
como fallback), leads de teste fora, e **batching adicionado** (não havia: 500 chamadas de uma vez
tomariam 429).

**Não ativei o fluxo agendado do usuário.** Ativá-lo para rodar um webhook ativaria também o
`Schedule Trigger`, que foi deixado inativo de propósito aguardando revisão. Criei um fluxo
dedicado de carga sob demanda (`i9lwcRFRddo3cAec`) e deixei o agendado intocado, exceto pelas duas
melhorias acima, que são corretas de qualquer forma.

### 🔴 O achado que justifica a instrumentação inteira

A coluna `atribuicao_status` foi criada para separar "a fonte não mandou" de "não conseguimos
ler". Na primeira medição real: 434 `ok`, 270 `ausente` e **61 `ilegivel`**.

Fui olhar os 61 e eles eram os **melhor atribuídos da base**: 47 com `utm_campaign`, 45 com
`midia`. Isso não fazia sentido como falha de leitura. Consultando a API para um deles, a causa:

**O RD Station usa DUAS formas para `traffic_source`, e o coletor conhecia só uma.**

| Forma | Conteúdo | Origem |
|---|---|---|
| A | `encoded_<base64>` com `first_session`/`current_session` | conversão de site |
| B | string simples (`"facebook"`) + `traffic_medium`/`traffic_campaign`/`traffic_value` | Facebook Lead Ads |

Eu tentava decodificar B como base64, falhava, e marcava `ilegivel` — **jogando fora a atribuição
de mídia paga**, que é exatamente a que sustenta ROI. Dos 61, **14 ficaram sem nenhuma atribuição
capturada**.

**Resultado da correção (migrations 060/061 + coletor):**

| | Antes | Depois |
|---|---|---|
| `ilegivel` | 61 | **0** |
| Eventos com plataforma | 45 | **61** |
| Eventos com campanha (nos 61) | 47 | **50** |

**Consequência que corrige um número que eu reportei:** os 7,6% de cobertura do eixo B foram
medidos sobre `cf_utm_*` do cadastro. A forma plana é fonte **adicional** de atribuição paga, então
a cobertura real do eixo B é maior do que eu disse.

**A lição está no nome, não no bug.** A `057` corrigiu misturar "ausente" com "falha" e, na mesma
correção, criou uma versão menor do mesmo erro: chamei `ilegivel` tanto uma falha real quanto um
formato que eu não conhecia. `ilegivel` **afirma que o dado está errado** quando o errado era o
leitor. Estado de erro deve nomear o que se sabe, não acusar a fonte.

### Enumerar valores no código, terceira ocorrência

A `059` contava atribuição com um `FILTER (WHERE status = 'ok')` por valor conhecido. Bastou a
`060` criar `ok_plano` para a aba **deixar de contá-lo** — o valor existia no banco e não aparecia
na tela. A `061` passou a **agrupar** por status dinamicamente, e a interface mostra status
desconhecido com o valor cru: visível e feio é melhor que invisível.

É a mesma família dos 4 filtros inventados do contrato: código decidindo quais valores existem em
vez de perguntar ao dado.

### ✅ Estágio de funil preenchido

Fluxo dedicado `i9lwcRFRddo3cAec`, executado: **475 contatos consultados, 475 gravados, status ok**.

`estagio_funil` saiu de vazio para: **434 `Lead`, 41 `Qualified Lead`**. O vocabulário veio da
fonte (`Client`, `Lead`, `Qualified Lead` upsertados dinamicamente), nunca de enum adivinhado —
`ordem` segue NULL até o usuário decidir uma ordenação real.

Cruzamento já possível: dos 41 qualificados, **19 são C-level**.

### 🔒 Exposição que eu criei e fechei

Os webhooks de ingestão que eu criei estavam **sem autenticação**. Quem descobrisse o caminho
dispararia centenas de chamadas à API do RD Station e escritas no banco. Não é vazamento de dado
(são endpoints de escrita interna), mas é abuso de quota e de recurso.

Ambos passaram a exigir o header `X-CRM-Api-Key`, com a credencial que já existia. Verificado por
`curl` anônimo: `/crm-rd-leads-ingest` → **403**; `/crm-rd-funil-carga` → **404** (inativo).

O fluxo de funil ficou **desativado** de propósito: é carga sob demanda, não precisa de webhook
aberto permanentemente.

### O fluxo agendado do usuário segue intocado

Não ativei `3l8hobRXtjbzodZc`. Ativá-lo para rodar um webhook ativaria também o `Schedule
Trigger`, deixado inativo aguardando revisão. Recebeu só duas melhorias corretas de qualquer
forma: a query de contatos ampliada (antes exigia vínculo com Salesforce e devolvia zero linhas) e
batching no nó HTTP (não havia — 500 chamadas de uma vez tomariam 429).

---

## 2026-09-10 — Etapa 8: ficha completa do lead

### 🔴 A jornada do lead não mostrava nenhuma conversão

`view_jornada_unificada` (migration 037) une 4 fontes: `conversion_event`
(direto e via identidade), `lead_touchpoint` e criação de oportunidade. Foi escrita **antes** de
`lead_conversion_event` (045) e `lead_funnel_stage_event` (039) terem dado.

Resultado: a ficha do lead exibia tudo **menos** as conversões — **767 eventos** e **475** mudanças
de estágio invisíveis, com o banco tendo a história inteira. O lead aparecia com jornada vazia.

Migration 068 acrescentou as duas fontes. Estado agora:

| tipo | granularidade | eventos |
|---|---|---|
| `conversao` | timestamp | **767** |
| `mudanca_estagio` | dia | **475** |
| `workflow_entrada`/`saida` | dia | 2 |

### Firmografia por evento, visível na tela

As colunas novas da view (`cargo_no_evento`, `tamanho_no_evento`, `campanha_midia`, `plataforma`,
`primeiro_toque`, `ultimo_toque`, `atribuicao_status`) existem porque a firmografia é gravada por
evento — e a ficha agora **destaca em âmbar quando o valor mudou** em relação à conversão anterior.

Exemplo real na base: o mesmo lead aparece como `Diretor` em 22/06 e `CEO, Founder, Sócio` em
30/06. Mostrar só o valor atual do cadastro esconderia a evolução, que é o que conta a história.

Nos ramos que não têm o dado as colunas vêm **NULL de propósito**: um touchpoint de workflow não
tem cargo, e preencher com o valor do cadastro atribuiria ao evento uma informação que ele não
carrega.

### Granularidade respeitada na interface

Evento de granularidade `dia` passa a exibir **só a data**, com o marcador `(dia)`, e o resumo da
jornada avisa que a ordem intradiária entre eles não é significativa (CON-3/EC-10). Exibir hora
neles daria falsa precisão: a API do RD só expõe o estado atual, então a data real é "quando o
pull rodou".

### 🔴 Regressão que eu introduzi e os specs pegaram

A ficha ganhou os campos novos e passou a fazer `ov.origens_conversao.length`. No modo real esses
campos vêm do adaptador; no modo mock o fixture era devolvido **cru**, sem eles — e
`undefined.length` derrubou a ficha inteira, deixando os três blocos em branco. **Três specs
Playwright** acusaram.

Corrigido com `_garantirFormaDetalhe()`, aplicada nos **dois** ramos. A lição é sobre
responsabilidade: `data-api.js` é a costura única (ADR-021), então garantir a FORMA é trabalho
dele. Uma view que precisa checar se cada campo existe já perdeu a garantia.

Detalhe de implementação que também é armadilha: os defaults têm de vir **depois** do spread de
`ov`. Antes, seriam código morto — e um `null` vindo do fixture reintroduziria o bug.

### Endpoint `/api/leads/:id`

Ganhou um terceiro ramo (`fn_perfil` → `view_lead_perfil`), separado de `view_lead_360` de
propósito: aquela é o eixo Salesforce/receita, esta é o eixo firmografia/atribuição do RD. Fundi-las
exigiria um JOIN que duplica linha por oportunidade.

Também corrigido: o endpoint tratava ausência em `view_lead_360` como **`lead_nao_encontrado`**.
Isso esconderia os 475 leads nativos do RD, que não têm registro no Salesforce. Agora a ficha é
válida quando existe em **qualquer** dos dois eixos.

### Os dois eixos, separados na tela

A ficha mostra eixo A (origem de conversão) e eixo B (mídia paga) em blocos distintos, cada um com
o rótulo do que pode receber investimento. Quando o eixo B está vazio, o texto explica que **não é
falha da ferramenta** — é conversão sem tagueamento de UTM, o que acontece na maioria dos leads.

### Verificado

19/19 SQL · 11/11 node --test · 8/8 Playwright. Queries do endpoint executadas contra um lead real
(3 conversões em 2 origens + 1 mudança de estágio).
