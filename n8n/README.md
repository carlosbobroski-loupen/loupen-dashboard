# Definicoes de workflow do n8n

Os workflows da ingestao vivem na instancia (`n8n.loupenapps.com.br`) e ate 2026-09-14
NAO eram versionados em lugar nenhum -- uma alteracao errada nao tinha diff nem rollback.
Este diretorio guarda a definicao JSON, para que exista historico. A instancia continua
sendo a fonte de execucao; o arquivo e o registro.

## O que esta no ar (2026-09-16)

| Workflow | id | Gatilho | Frequencia | JSON versionado aqui? |
|---|---|---|---|---|
| CRM Ingest - Salesforce (delta por SystemModstamp) | `edD30vLzzjvSJXD1` | webhook `crm-sf-ingest` + cron | **de hora em hora** (`7 * * * *`) | sim |
| CRM Ingest - RD Station Leads (descoberta + conversoes) | `x1md8DzjX6psKXNR` | webhook + cron | **a cada 6h** (`23 */6 * * *`) | nao |
| CRM Ingest - RD Station Funil/Workflow | `3l8hobRXtjbzodZc` | cron | **diario 03:00** (`0 3 * * *`) | nao |
| CRM API - /api/pessoas | `2lvaPGYp86D0pi3o` | webhook | sob demanda (aba Leads) | nao |
| CRM API - /api/leads/:id | `6Rh3yYNX1gAwAIIh` | webhook | sob demanda (ficha do lead) | nao |
| **CRM API - /api/oportunidades** | `S0sCuNqNpSxJJz18` | webhook | sob demanda (aba Oportunidades) | nao |
| CRM API - /api/marketing-funil | `evyq9rB0ln6m5XwC` | webhook | sob demanda | nao |
| Leads RD Station (conversoes) | `O0CV1vx7N5Mc6Nig` | webhook que o RD empurra | tempo real | nao |
| Loupen Dashboard - Ads Data API | `By8hqnYjf6CSWZQY` | webhook | a cada carregamento | nao |

> **Lacuna conhecida.** So a ingestao do Salesforce tem JSON aqui. Os workflows de
> API vivem apenas na instancia, e nao ha chave de gestao do n8n no `.env` para
> exporta-los por script -- escrever o JSON a mao produziria um arquivo que ninguem
> consegue provar que bate com o que esta rodando, o que e pior que nao ter arquivo.
> Para fechar: gerar uma API key do n8n, guardar como `N8N_API_KEY` no `.env`, e
> exportar com `GET /api/v1/workflows/{id}`.

## O que mudou em 2026-09-16 (sessao de moeda e oportunidades)

**Ingestao do Salesforce** ganhou tres objetos e tres campos, todos testados com a
identidade estreita do n8n antes de entrar (ela ja recusou objeto que o conector
administrativo le):

| mudanca | por que |
|---|---|
| objeto `CurrencyType` | a org e multi-moeda (BRL corporativa, USD 0.19604, MXN 3.40986) e o banco somava dolar com real. Lido INTEIRO a cada execucao, sem watermark: sao 3 linhas e a taxa muda sozinha -- ler incremental congelaria um cambio antigo. |
| objeto `OpportunityStage` | a origem ja declara `IsWon`/`IsClosed`/`DefaultProbability` dos 114 estagios. Derrubou um palpite: `Pending Sale` parece venda fechada e e `IsWon=false`, prob 95%. Mapear pelo nome teria inventado 14 vendas. Tambem sem watermark: o Setup reclassifica estagio sem tocar em registro. |
| `Opportunity.LeadSource` | 100% de preenchimento. Sem ele, 93,6% das oportunidades nao tinham origem: `Opportunity` nao herda o `LeadSource` do lead e a maioria nao tem lead vinculado. |
| `Opportunity.CurrencyIsoCode` | sem isso `amount` nao tem unidade. |
| `Lead.ConvertedOpportunityId` | 320 de 325 convertidos. O vinculo INDIVIDUAL; por conta, 114 leads recebiam 345 linhas. |

**`/api/leads/:id`** teve a projecao do Code node alargada. O no Postgres sempre fez
`SELECT *`, mas o Code node projetava 6 campos e descartava o resto -- inclusive
`fase_comercial`, o que deixou o bloco de desfecho comercial **inerte na tela desde
que subiu**. Lição: `SELECT *` no SQL nao significa que o campo chega ao navegador.

**Armadilha de reescrita de funcao.** Uma migration desta sessao reescreveu
`fn_run_ingest_batch` a partir de um arquivo de migration antigo e **reverteu em
silencio** duas migrations posteriores. A ingestao continuou reportando `status: ok`,
porque `rows_target` conta linha inserida na tabela antiga, nao o enriquecimento que
sumiu. **O sintoma desse modo de falha e a ausencia de sintoma.** Regra registrada em
`db/README.md`: funcao se reescreve a partir do corpo VIVO (`pg_get_functiondef`), com
diff exigindo adicao pura.

## Armadilha real, custou uma execucao quebrada

A credencial OAuth2 generica do n8n (`fy93rAXAr6vJ3J7C`) manda `scope` no pedido de token.
O fluxo **client_credentials do Salesforce recusa** esse parametro:

```
invalid_request - scope parameter not supported
```

O campo `scope` da credencial tem de ficar **VAZIO**. Com `scope=api` o node devolve
`EAUTH` com uma mensagem generica de "parametro invalido" que nao nomeia o culpado --
foi preciso reproduzir os dois pedidos por `curl`, lado a lado, para achar.

## Testar antes de confiar

```
curl -H "X-CRM-Api-Key: <segredo>" https://n8n.loupenapps.com.br/webhook/crm-sf-ingest
curl -H "X-CRM-Api-Key: <segredo>" https://n8n.loupenapps.com.br/webhook/api/marketing-funil
```

A resposta da ingestao e a saida de `fn_run_ingest_batch`: uma linha por objeto com
`rows_source`, `rows_target` e `status`. Qualquer `status` diferente de `ok` significa
divergencia origem->destino e deve ser investigada.

## Multiplicacao de itens: a pegadinha do n8n

Um node Postgres roda UMA VEZ POR ITEM que entra nele. Em `/api/marketing-funil` isso
fez a consulta de leads rodar 9 vezes (uma por categoria que vinha do node anterior) e
devolver 2.745 linhas em vez de 305. Corrigido com `executeOnce: true` nos nodes que
devem rodar uma unica vez, independentemente de quantos itens chegam.
