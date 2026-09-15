# Roteamento de borda e credenciais de ingestão

Registro das credenciais e conexões entre n8n e os sistemas de origem/destino
(FR-14/AC-14.1 — decisões registradas, não só na cabeça de quem configurou).

## n8n → Neon (subtask 2.15)

- **Credencial n8n:** "Neon CRM Ingest (crm_ingest, least-privilege)", id
  `HxzsjsD5aq9xddR2`, tipo `postgres`.
- **Endpoint:** `-pooler` (PgBouncer), `ssl=require` — nunca o endpoint direto (P-ING-6).
- **Usuário Postgres:** `crm_ingest`, role dedicada (NÃO o owner `neondb_owner`). INV-1
  (menor privilégio): `GRANT SELECT, INSERT, UPDATE ON ALL TABLES` + `EXECUTE ON
  FUNCTION fn_run_ingest_batch(text)`. Sem DDL, sem DROP, sem TRUNCATE — testado na
  prática (`DROP TABLE`/`TRUNCATE` com esta role retornam `permission denied`/`must be
  owner`, ver validation-log.md).
- **Verificação real (2026-09-07):** workflow de teste com nó Postgres (`SELECT 1,
  inet_server_addr() IS NOT NULL, current_user`) executado via webhook em produção no
  n8n real (`n8n.loupenapps.com.br`) — resultado `{ok: 1, conectado: true, usuario:
  "crm_ingest"}`. Workflow de teste removido após a prova (não fica no ar).

## API de leitura real — `/api/leads` (subtask 5.1, parcial)

**Workflow n8n:** "CRM API - /api/leads" (id `RNatAiKSjOuoWzjE`), ativo. Webhook GET
`https://n8n.loupenapps.com.br/webhook/api/leads`, `Authentication: Header Auth`
(credencial "CRM API Header Auth (X-CRM-Api-Key)", id `1zOWmZMVPMyV3J0e`, header
`X-CRM-Api-Key`). Nós: Webhook → Code (monta filtros jsonb a partir da query string) →
Postgres (chama `fn_search_leads`, credencial `crm_ingest` de 2.15) → Code (formata
`{leads: [...], total: N}`) → Respond to Webhook. **Nenhuma lógica de negócio no
workflow** — só chama a função SQL de 3.19 (CRIT-4 respeitado).

**Testado com HTTP real (curl), não só via ferramenta de teste do n8n:**
- Sem header → `403` (rejeitado).
- Header errado → `403` (rejeitado).
- Header correto + `?segmento=Marketing` → JSON real com leads/total corretos.

**Segurança real hoje:** o Header Auth já é uma proteção de verdade neste nível (sem ele,
403) — mas **NÃO substitui o gate do Cloudflare Access** da phase-4 (ainda não construído,
Cloudflare não configurado pelo usuário). Enquanto phase-4 não existir, este endpoint está
exposto na internet pública protegido SÓ pelo header secreto — aceitável para
desenvolvimento/teste, não para produção com dado real de cliente. Registrar isso
explicitamente antes de considerar este endpoint "pronto para produção".

## `/api/leads/{id}` (subtask 5.1, parcial)

**Workflow n8n:** "CRM API - /api/leads/:id" (id `6Rh3yYNX1gAwAIIh`), ativo. Webhook GET
com path dinâmico `api/leads/:id` — **achado real de n8n**: com segmento dinâmico (`:id`),
o `webhookId` do nó é PREPENDED à URL real (não documentado de forma óbvia na UI) — a URL
de produção correta é
`https://n8n.loupenapps.com.br/webhook/<webhookId>/api/leads/:id`, não
`.../webhook/api/leads/lead-51b` como seria natural assumir. `webhookId` deste workflow:
`855a5444-c212-4c84-b993-ef082e35f999`.

Nós: Webhook → Code (extrai `:id`) → dois ramos PARALELOS (`fn_lead_360` chamando
`view_lead_360`, `fn_jornada` chamando `view_jornada_unificada`, ambos filtrando por
`source_id`/`lead_id`) → Code (monta `{overview, activity, related}`) → Respond to Webhook.

**Dois bugs reais encontrados e corrigidos testando com HTTP de verdade:**
1. Os dois ramos paralelos alimentam o MESMO índice de entrada do Code final — `$input.all()`
   nesse caso mistura os itens dos DOIS ramos, não só o "mais próximo". Corrigido
   referenciando cada ramo pelo NOME do node (`$('fn_lead_360').all()` /
   `$('fn_jornada').all()`), nunca `$input` quando há mais de uma fonte.
2. Um Postgres node com ZERO linhas de resultado, por padrão, não dispara os nodes
   seguintes (o pipeline simplesmente para nesse ramo) — um lead inexistente devolvia
   corpo vazio em vez de um erro tratado. Corrigido com `alwaysOutputData: true` nos dois
   nós Postgres, e o Code final filtrando explicitamente por um campo que só existe em
   linha real (`r.lead_id !== undefined`) em vez de confiar no tamanho do array.

**Testado com HTTP real:** lead existente → JSON completo e correto (overview com
atribuição+razão, activity com os eventos reais na ordem certa incluindo o marco de
criação de oportunidade derivado, related com conta+oportunidades); lead inexistente →
`{"erro":"lead_nao_encontrado"}` (200, não 404 — REST-puro ficou para depois, não
bloqueante); sem header → 403.

## `/api/meta` (subtask 5.1, concluído)

**Workflow n8n:** "CRM API - /api/meta" (id `na8l0jvaHqUon0I0`), ativo. Webhook GET
`https://n8n.loupenapps.com.br/webhook/api/meta` (sem path dinâmico — sem o problema do
webhookId prefixado). Três nós Postgres em paralelo (`sync_state`, `ingest_run` últimos
20, `view_cobertura_atribuicao`), todos com `alwaysOutputData: true` (lição de
`/api/leads/{id}`), mesclados por nome de node (`$('fn_sync_state').all()` etc.) — nunca
`$input`. Retorna `{fontes, execucoes_recentes, cobertura}`.

**Testado com HTTP real:** vazio (estado real atual — nenhum dado de teste residual) e com
dado real inserido temporariamente (uma linha em cada tabela) — os três arrays populam
corretamente; sem header → 403.

## Resumo — subtask 5.1

Os três recursos descritos em 5.1 (`/api/leads`, `/api/leads/{id}`, `/api/meta`) estão
TODOS construídos, ativos e testados com HTTP real. O único item da subtask não satisfeito
é a autenticação via Cloudflare Access (dependência `4.12`) — os três endpoints têm Header
Auth real do n8n como única camada de proteção hoje, suficiente para desenvolvimento, não
para produção com dado de cliente real.

## Borda de produção — Cloudflare Pages + Access (ADR-018, 2026-09-09)

**Mudança de arquitetura.** O desenho original de phase-4 (Origin Rule + URL Rewrite +
Request Header Modification na zona de `loupenapps.com.br`) foi **substituído**: o usuário
confirmou que não conseguirá acesso à conta Cloudflare que administra esses domínios.
Decisão registrada em `adr-018-cloudflare-pages-em-vez-de-github-pages.md`, e é a aceitação
explícita do plano B previsto em OQ-16.

Desenho novo, em conta Cloudflare **nova**, sem DNS e sem domínio:

| Peça | O que faz | Onde vive |
|---|---|---|
| Cloudflare Pages | serve o site estático, deploy automático a cada commit enviado (sem build, CON-12) | projeto Pages, hostname grátis `*.pages.dev` |
| Cloudflare Access | gate "Emails ending in `@loupen.com.br`", grátis até 50 usuários | Zero Trust da conta nova, aplicação no hostname de produção (remover o wildcard no campo *Subdomain*) |
| Pages Function | atende `/api/*`, injeta `X-CRM-Api-Key` server-side, repassa ao n8n | `functions/api/[[path]].js` (versionado neste repo) |

Fluxo real de uma chamada em produção:

```
navegador  --GET /api/leads (same-origin, SEM chave)-->  Pages Function
                                                              |
                                    lê context.env.CRM_API_KEY (secret encriptado)
                                                              |
                     --GET .../webhook/api/leads + header X-CRM-Api-Key-->  n8n
```

O navegador **nunca** recebe a chave: não está no código-fonte, não está no DevTools.
Isso é o que torna o modo real publicável — não a obscuridade.

**A Function é allowlist, não proxy.** Só `GET`, e só três rotas:
`/api/meta`, `/api/leads`, `/api/leads/{id}` (com o `id` validado por regex). Qualquer
outro caminho recebe 404. Isso NÃO é redundante com o Access: quem chega na Function já é
usuário autenticado, mas um proxy genérico permitiria a essa pessoa chamar **qualquer**
webhook desta instância n8n — inclusive os de automação com efeito colateral real (escrita
em planilha, CAPI, cadastro no RD Station) — usando uma chave que ela nunca vê.

**A peculiaridade do `webhookId` fica encapsulada aqui.** A Function traduz
`/api/leads/{id}` para `.../webhook/855a5444-.../api/leads/{id}`; o cliente não precisa
saber que essa esquisitice existe.

**Configuração que depende do usuário** (não automatizável pelo agente): criar a conta,
criar o projeto Pages apontando para o repo, cadastrar o secret `CRM_API_KEY`
(mesmo valor de `N8N_API_HEADER_SECRET` no `.env`), criar a Access Application com a
política de e-mail, e **desativar o GitHub Pages** depois do corte (critério de R1/4.4 —
senão a URL `github.io` continua pública).

**Interruptor do corte:** `MODO_DADOS` em `assets/js/data-api.js` (`'mock'` → `'real'`).
Não virar antes do gate estar ativo e verificado.

## Credenciais de fonte — estado real (2026-09-14)

O que estava escrito aqui até 2026-09-09 ("PENDENTES", "nenhuma credencial de pull
existe", "obter um token do RD Station com escopo de leitura apenas") **ficou falso nos
dois casos**. Substituído pelo estado medido.

### RD Station — credencial única, com escopo de escrita irredutível

**Credencial:** "RD Station Marketing OAuth2 - Loupen", id `vOAhOy0T4xmEAOvq`, tipo
genérico `oAuth2Api`.

Ela **tem escopo de escrita real** e não existe forma de reduzi-lo: as permissões do app
são um pacote fixo na plataforma, sem toggle individual. Comprovado por escrita
deliberada (criou um contato de verdade, deletado em seguida) e por print da tela de
permissões. Decisão, alternativas rejeitadas e limites aceitos em **ADR-022**.

> **Regra de arquitetura permanente:** nenhum workflow pode executar chamada de
> **escrita** à API do RD Station usando credencial ou chave da ingestão analítica —
> esteja ela no gerenciador de credenciais, embutida na URL ou em header manual.
> Somente `GET`.

**Quem usa a credencial hoje** (auditoria nó a nó dos 28 workflows, 2026-09-14):

| Workflow | Estado | Nós | Veredito |
|---|---|---|---|
| `x1md8DzjX6psKXNR` CRM Ingest - RD Station Leads | ativo | 3 × GET (segmentação, contato, eventos) | conforme |
| `By8hqnYjf6CSWZQY` Loupen Dashboard - Ads Data API | ativo | 5 × GET (segmentações) | conforme |
| `3l8hobRXtjbzodZc` CRM Ingest - Funil/Workflow | inativo | 3 × GET | conforme |
| `i9lwcRFRddo3cAec` CRM Ingest - Estágio de Funil | inativo | 1 × GET | conforme |
| `aqXxZ5EpyyyZFnOk` [BACKFILL] retroativos LinkedIn | inativo | 1 × GET | conforme |
| `4xTglLdVWuPTBNII` LinkedIn Lead Gen Forms (OFICIAL) | inativo, **não arquivado** | `POST /platform/conversions` | ⚠️ **latente** |
| `s39i4zl6U6Oos7CW` LinkedIn Lead Sync | arquivado, Schedule 15 min | `POST /platform/conversions` | ⚠️ **latente** |

**Escrita de conversão usa a API Key pública, e isso está correto.** Quatro nós fazem
`POST /platform/conversions?api_key=c5c0947…` com a chave na URL —
`1PF5oDDICnODOMH8` "automação leads" e `uYQP2xMSouJyMgot` "Diagnóstico de Maturidade"
(ativos), mais `3iGqn4kYNh5kKEbe` e `aqXxZ5EpyyyZFnOk` (inativos).

Essa chave é o **token público** do RD Station: escreve conversão e **não lê nada** — é o
único endpoint que a plataforma aceita receber do front-end, e por isso é feita para ficar
exposta (está nos formulários do site). Não é segredo vazado, e rotacioná-la não reduz
risco nenhum. O risco residual é injeção de conversão falsa, inerente ao mecanismo.

**É exatamente essa separação que a regra protege:** quem escreve conversão usa a chave que
não lê; quem lê contato usa a credencial OAuth2, que nunca deve escrever.

Uma quinta credencial existe e está isolada: `cMCb7MTOzM7DrG1c` "RD Station Conversions
API" (`httpHeaderAuth`), usada só no workflow arquivado `ymDbU9lMkinHYn9Q`.

### Salesforce — client_credentials, sem handshake humano

**O bloqueio registrado no plano (consentimento OAuth interativo, subtask 2.16) não
existe.** O Connected App aceita `grant_type=client_credentials`:

```
POST https://loupen.my.salesforce.com/services/oauth2/token
grant_type=client_credentials & client_id=... & client_secret=...
→ 200, scope=api
```

Sem navegador, sem clique, sem sessão humana. Roda desatendido de um nó HTTP Request.

| | |
|---|---|
| Org | `00D15000000FnTfEAK`, API até v67.0 |
| Segredos | `SALESFORCE_LOGIN_URL` / `_CLIENT_ID` / `_CLIENT_SECRET` no `.env` (ignorado pelo git, não rastreado) |
| Bulk API 2.0 | verificado: job de query devolveu 4.585 oportunidades de 2026 em 772 ms (~788 KB CSV). Confirma R20 — tem de ser HTTP Request, o node nativo do n8n não expõe Bulk 2.0 |
| Limites | 105.200 requisições/dia · 10.000 jobs Bulk V2/dia |

**⚠️ Mesmo problema do RD Station, mas aqui com conserto.** O app roda como **TI Loupen
(`suporte.ti@loupen.com.br`), perfil "Administrador do sistema"**: o describe reporta
`createable`, `updateable` e **`deletable` = true** em Lead, Account e Opportunity — a
credencial de ingestão pode **apagar** registro de CRM em produção. Nenhuma escrita foi
testada; a permissão foi lida da metadata, justamente para não repetir o episódio do RD
Station.

Diferente do RD Station, o Salesforce **permite** corrigir: basta trocar o usuário "Run
As" do Connected App por um usuário de integração com perfil somente-leitura. Ação de
Setup, pendente no dono da org. Até lá, o risco é o mesmo de INV-1 — só que evitável.
