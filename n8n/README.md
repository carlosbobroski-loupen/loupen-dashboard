# Definicoes de workflow do n8n

Os workflows da ingestao vivem na instancia (`n8n.loupenapps.com.br`) e ate 2026-09-14
NAO eram versionados em lugar nenhum -- uma alteracao errada nao tinha diff nem rollback.
Este diretorio guarda a definicao JSON, para que exista historico. A instancia continua
sendo a fonte de execucao; o arquivo e o registro.

## O que esta no ar (2026-09-15)

| Workflow | id | Gatilho | Frequencia |
|---|---|---|---|
| CRM Ingest - Salesforce (delta por SystemModstamp) | `edD30vLzzjvSJXD1` | webhook `crm-sf-ingest` + cron | **de hora em hora** (`7 * * * *`) |
| CRM Ingest - RD Station Leads (descoberta + conversoes) | `x1md8DzjX6psKXNR` | webhook + cron | **a cada 6h** (`23 */6 * * *`) |
| CRM Ingest - RD Station Funil/Workflow | `3l8hobRXtjbzodZc` | cron | **diario 03:00** (`0 3 * * *`) |
| CRM API - /api/marketing-funil | `evyq9rB0ln6m5XwC` | webhook | sob demanda (a aba chama) |
| Leads RD Station (conversoes) | `O0CV1vx7N5Mc6Nig` | webhook que o RD empurra | tempo real |
| Loupen Dashboard - Ads Data API | `By8hqnYjf6CSWZQY` | webhook | a cada carregamento do dashboard |

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
