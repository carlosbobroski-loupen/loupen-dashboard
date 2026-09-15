# ADR-022: Credencial do RD Station sem escopo granular — aceitação de risco e regra de arquitetura no lugar de controle técnico

**Status:** Aceito · **Data:** 2026-09-14 · **Épico:** `epic-crm-lead-intelligence`

## Contexto

INV-1 do épico exige **menor privilégio** para toda credencial de ingestão: quem só lê não deve poder escrever. A subtask 2.21 mandava provar isso do jeito certo — não lendo código, mas tentando uma escrita deliberada e confirmando que a plataforma a **rejeita**.

Em 2026-09-08 o teste foi feito: `PATCH /platform/contacts/email:<endereço inventado>` com a credencial real "RD Station Marketing OAuth2 - Loupen" (id `vOAhOy0T4xmEAOvq`), a mesma já usada para ler contagens de segmentação.

**A escrita funcionou.** `status 200`. O endpoint tem semântica de upsert, então o e-mail inexistente virou **um contato novo de verdade em produção** (uuid `88edaf4b-c6f7-4ab1-a38d-d88576fcaeaf`, nome "Teste INV-1"). O contato foi deletado na hora (`DELETE .../uuid:...` → `204`, depois `404` ao rebuscar) e o workflow de teste apagado. Nenhum resíduo ficou.

O achado não é "um caminho de leitura fez escrita sem querer" — é que **a credencial tem poder que nenhum workflow usa, mas que existe e é real**.

A pergunta seguinte era se dava para reduzir o escopo. O usuário abriu a página "Permissões de acesso" do app na App Store do RD Station e mandou o print:

```
Gerenciar webhooks
Gerenciar contatos
Gerenciar campos customizados
Visualizar o link do código de monitoramento
Manipular os estágios de funil de seus contatos
Envio de eventos para os contatos
```

Todas marcadas, **nenhuma com opção de desmarcar**. É um pacote fixo. Isso é evidência direta da plataforma, não silêncio de documentação: **não existe caminho técnico** para uma credencial somente-leitura neste modelo de app.

## Decisão

**Aceitar formalmente o risco residual de escopo de escrita, e substituir o controle técnico impossível por uma regra de arquitetura verificável.**

> **Regra permanente:** nenhum workflow do n8n pode conectar a credencial `vOAhOy0T4xmEAOvq` a um nó de escrita da API do RD Station — `POST /platform/conversions`, `PATCH /platform/contacts/...`, `PUT .../funnels/...`, inscrição em workflow. **Somente `GET`.**

A subtask 2.21 permanece com `status: failed` no `implementation.yaml`, de propósito. O que fechou foi a **decisão** sobre o que fazer diante do achado, não o invariante — INV-1 genuinamente não se sustenta aqui. Marcar como `completed` seria inventar uma conformidade que não existe (Artigo IV da Constitution).

## O que a auditoria de 2026-09-14 mostrou, e por que ela muda o texto da regra

Os 28 workflows da instância foram lidos nó a nó, pelo JSON, não pelo nome. Três resultados:

**1. Nos workflows ATIVOS a regra vale.** Os 8 nós que usam `vOAhOy0T4xmEAOvq` em workflow ativo (`x1md8DzjX6psKXNR` — ingestão de leads do CRM; `By8hqnYjf6CSWZQY` — ads data API) são **todos GET**.

**2. Existem dois nós de escrita latentes com essa credencial.** Não estão rodando, mas estão armados:

| Workflow | Estado | Nó | Chamada |
|---|---|---|---|
| `4xTglLdVWuPTBNII` LinkedIn Lead Gen Forms → RD Station (OFICIAL) | inativo, **não arquivado** | Send to RD Station | `POST /platform/conversions` |
| `s39i4zl6U6Oos7CW` LinkedIn Lead Sync → RD Station | arquivado, **com Schedule Trigger de 15 min** | Enviar para RD Station | `POST /platform/conversions` |

O primeiro é o pior caso: o nome diz "aguardando aprovação do LinkedIn", ou seja, **existe a intenção declarada de ligá-lo**. No dia em que a aprovação sair, alguém aperta o botão e a regra é violada sem ninguém perceber que violou.

**3. Existe um segundo caminho de escrita — mas ele é público por projeto.** Quatro nós
fazem `POST /platform/conversions?api_key=c5c0947…` com a chave em texto puro na URL, dois
deles em workflows ativos (`1PF5oDDICnODOMH8` "automação leads" e `uYQP2xMSouJyMgot`
"Diagnóstico de Maturidade").

**Correção do diagnóstico inicial (2026-09-14).** A auditoria classificou isso como
"segredo exposto". Não é. `c5c0947…` é a **API Key / token público** do RD Station: ela
serve *exclusivamente* para enviar evento de conversão, é o único endpoint que a
plataforma aceita receber do front-end, e é feita para ficar visível em código de cliente
— está, aliás, nos formulários do próprio site. Não lê contato, não lê segmentação, não
altera cadastro.

O risco residual real é **injeção de conversão falsa** (poluir a base com lead inventado),
não vazamento de dado. Isso é inerente ao mecanismo e não some com rotação — a chave
continuaria pública no site no dia seguinte.


## Consequências da auditoria sobre o desenho

**A regra precisa separar por PODER, não por lugar onde a chave mora.** Versão corrigida, que é a que vale:

> A credencial OAuth2 da ingestão analítica (`vOAhOy0T4xmEAOvq`), que lê contato,
> segmentação e evento, **nunca** pode ser anexada a uma chamada de escrita. Escrita de
> conversão é feita com a API Key pública, que não lê nada — e é justamente por não ler
> nada que ela pode ser pública.

**Escrita legítima existe e não está proibida.** As automações de negócio (`automação leads`, `Diagnóstico de Maturidade`) cadastram conversão no RD Station de propósito; isso é produto, não vazamento. O que a regra exige é **separação**: a credencial da ingestão analítica não é a credencial da automação de negócio, e nenhuma das duas herda o poder da outra por conveniência.

**A verificação é por auditoria de nó, não por confiança.** O n8n não impede tecnicamente nada: `vOAhOy0T4xmEAOvq` é do tipo genérico `oAuth2Api`, então qualquer nó HTTP Request pode anexá-la a qualquer URL. A regra é convencional por natureza, e por isso precisa de uma checagem repetível — não de uma promessa.

## Alternativas rejeitadas

**Criar uma credencial OAuth2 nova com escopo de leitura.** Era o plano original (INV-1 pede exatamente isso) e foi a primeira coisa tentada. Rejeitada por impossibilidade comprovada na plataforma, não por preferência: o print das permissões mostra um pacote sem toggles.

**Usar um app diferente do RD Station só para leitura.** Não resolve: o conjunto de permissões é o mesmo para o tipo de app, então um app novo nasceria com o mesmo pacote. Trocaria uma credencial poderosa por duas.

**Deixar como TODO até o RD Station lançar escopos granulares.** Rejeitada porque transforma um risco conhecido em espera indefinida, e porque a subtask ficaria `pending` para sempre mascarando que uma decisão já foi tomada de fato — a de continuar operando assim.

**Marcar 2.21 como `completed`.** Rejeitada: o invariante não se sustenta. O status `failed` com a decisão registrada é a descrição honesta do estado.

## Consequências

**Positivas:**
- O risco fica **nomeado, datado e localizável** em vez de viver dentro de um log narrativo de 100 KB.
- A auditoria transformou a regra de aspiração em fato medido: sabemos exatamente quais 2 nós latentes e quais 4 nós com chave embutida existem hoje.
- A separação "credencial de ingestão ≠ credencial de automação" fica explícita antes de a ingestão crescer.

**Negativas / limites aceitos:**
- **A credencial segue podendo escrever, criar e apagar contato em produção.** Isso não tem mitigação técnica; é o custo aceito.
- **A regra depende de disciplina humana.** Nada no n8n a impõe.
- **Os 2 nós latentes continuam existindo** até serem desconectados da credencial. Enquanto existirem, "a regra vale" é verdade apenas para o que está ligado.
- **Injeção de conversão falsa continua possível** por quem tiver a API Key pública — inerente ao mecanismo do RD Station, não corrigível por rotação (a chave é pública por projeto, inclusive nos formulários do site).

## Ver também

- `docs/stories/epic-crm-lead-intelligence/plan/validation-log.md` — o teste de escrita, o print das permissões e a auditoria completa nó a nó
- `docs/architecture/edge-routing.md` — o mapa de credenciais atualizado
- `implementation.yaml` subtask 2.21 (`status: failed`, com a decisão nas notas)
- ADR-018 (por que a Pages Function é allowlist e não proxy — mesma família de raciocínio: quem já está autenticado não deve herdar poder que não precisa)
