# Guia de Setup — Ponte LinkedIn Lead Gen Forms → RD Station via Make.com

**Status:** Fase 1 (ponte de curto prazo), decidida em 2026-07-13. Não depende da aprovação
da LinkedIn Lead Sync API (Make já é parceiro certificado). Migração futura para o workflow
custom no n8n está desenhada em `docs/architecture/linkedin-leads-integration.md` e só
acontece se/quando valer a pena (após a aprovação do Lead Sync API, já em análise).

## Princípio (igual ao caminho custom)

RD Station é o hub. O único requisito duro é que os campos enviados ao RD Station tenham
**exatamente os mesmos nomes** que a automação do Meta já usa (workflow n8n `automação leads`,
Code node "Code in JavaScript1") — senão o lead cai em colunas diferentes na planilha "Central
de Leads" e o dashboard (`index.html`) não reconhece o canal/campanha corretamente.

## 1. Cenário no Make.com

**Módulo 1 — Trigger:** app "LinkedIn Lead Gen Forms" → "Watch Responses" (ou "New Lead Gen
Form Response"). Conecta com uma conta LinkedIn que tenha role de admin na conta de anúncios
(`533600351`, a mesma já usada no dashboard) e na Company Page da Loupen. Essa conexão é
**própria do Make** — não reaproveita o app/credencial OAuth2 do n8n (`LinkedIn Ads OAuth2
(Generic) - Loupen`), é uma autenticação separada.

**Módulo 2 — Ação:** app "RD Station Marketing" → módulo de conversão/evento (equivalente ao
`POST /platform/conversions` que o n8n já usa). Mapear os campos conforme a tabela abaixo.

## 2. Mapeamento de campos (replicar o que o Meta já envia)

| Campo RD Station | Valor / origem no Make | Observação |
|---|---|---|
| `name` | `{{1.firstName}} {{1.lastName}}` | concatenar nome+sobrenome do lead |
| `email` | `{{1.email}}` | chave de cruzamento com o resto do pipeline |
| `job_title` | `{{1.jobTitle}}` | |
| `company_name` | `{{1.companyName}}` | |
| `personal_phone` | `{{1.phoneNumber}}` | |
| `cf_tamanho_da_empresa` | resposta da pergunta customizada "tamanho da empresa" | nome exato do campo depende de como o form do LinkedIn foi criado — conferir no preview do módulo 1 |
| **`cf_utm_source`** | constante **`linkedin`** | **obrigatório** — é o gatilho exato que `normCanal` (index.html:1298) usa pra classificar o canal como "LinkedIn ADS" |
| `cf_utm_medium` | constante `paid_social` | mesmo padrão do Meta |
| `traffic_source` | constante `linkedin` | |
| `traffic_medium` | constante `paid_social` | |
| `traffic_campaign` | `{{1.campaignName}}` | nome cru da campanha, como veio do LinkedIn |
| `cf_utm_campaign` | `{{1.campaignName}}` | idem |
| `cf_utm_id` | `{{1.campaignId}}` | |
| `cf_midia` | constante `LinkedIn` | |
| `cf_linkedin_lead_id` | `{{1.leadId}}` (ou ID único do módulo 1) | equivalente ao `cf_facebook_lead_id` do Meta — usar para idempotência/rastreio |
| `tags` | `["linkedin-lead-ads"]` | |
| **`conversion_identifier`** (aparece como **Evento**/c[1] na planilha) | ver fórmula de padronização abaixo | **crítico** — precisa reproduzir a mesma padronização de campanha do dashboard |

## 3. Replicar `standardizeCampanha()` dentro do Make

O dashboard e o n8n do Meta usam esta função (fonte da verdade: `index.html` linhas 1024-1031):

```js
rescue/logmein  → LOGMEIN_RESCUE-LICENCA-ECO_07-26
webinar         → GOTO_WEBINAR_07-26
(goto|linkedin) + saude → GOTO_SAUDE_06-26
goto|linkedin   → GOTO_INSTITUCIONAL_07-26
```

Make não roda JS livre no plano básico, mas o mesmo resultado sai com `if()`/`contains()`
aninhados no campo de mapeamento do `conversion_identifier` (e reaproveitado em
`cf_utm_campaign`/`Evento` se quiser já gravar padronizado):

```
{{ if(
     or(contains(lower(1.campaignName); "rescue"); contains(lower(1.campaignName); "logmein"));
     "LOGMEIN_RESCUE-LICENCA-ECO_07-26";
     if(
       contains(lower(1.campaignName); "webinar");
       "GOTO_WEBINAR_07-26";
       if(
         and(
           contains(lower(1.campaignName); "saude");
           or(contains(lower(1.campaignName); "goto"); contains(lower(1.campaignName); "linkedin"))
         );
         "GOTO_SAUDE_06-26";
         if(
           or(contains(lower(1.campaignName); "goto"); contains(lower(1.campaignName); "linkedin"));
           "GOTO_INSTITUCIONAL_07-26";
           1.campaignName
         )
       )
     )
   ) }}
```

A ordem das condições importa (mesma ordem do `CAMPANHA_RULES` no dashboard: rescue/logmein
primeiro, depois webinar, depois goto+saude, depois goto sozinho). Se uma campanha nova for
criada, esta fórmula **e** `CAMPANHA_RULES` (index.html) **e** o Code node do Meta no n8n
precisam ser atualizados juntos — são 3 cópias da mesma regra (risco de drift já sinalizado
no documento de arquitetura, decisão D4).

## 4. Lacunas de paridade com o Meta (mesmas do caminho custom)

- Sem nome de ad set (LinkedIn não tem esse conceito) — sem impacto, o dashboard já mostra "—".
- Sem nome de criativo pronto, só ID — sem impacto, o dashboard já mostra "—" para LinkedIn.
- Sem dedupe explícito da nossa parte — o Make trata isso internamente no trigger "Watch"
  (não deve reprocessar o mesmo lead a cada execução do cenário), mas vale testar com 1 lead
  de teste antes de confiar 100%.

## 5. Teste antes de ligar em produção

1. Gerar um lead de teste no Lead Gen Form do LinkedIn (Campaign Manager → form → "Send test
   lead").
2. Rodar o cenário manualmente no Make e conferir no RD Station se o lead chegou com os
   campos certos.
3. Conferir na planilha "Central de Leads" se a linha apareceu com `Evento` padronizado e
   `Conversao Channel`/canal = LinkedIn ADS.
4. Abrir o dashboard, aba Campanhas, e confirmar que o lead de teste aparece sob a campanha
   certa antes de ativar o cenário em modo automático/produção.

## 6. Quando migrar para o caminho custom (n8n)

Migrar só faz sentido quando **todas** as condições abaixo forem verdadeiras:
- Lead Sync API aprovada pela LinkedIn (já em análise, ver `linkedin-leads-integration.md` §5).
- Volume de leads do LinkedIn justificar eliminar o custo mensal do Make.
- Time disponível para o ~1 dia de implementação do workflow n8n (arquitetura já pronta).

Até lá, o Make é a fonte de leads nativos do LinkedIn e não precisa ser desligado apressadamente.
