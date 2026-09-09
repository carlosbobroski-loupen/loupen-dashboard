# Fixture curado — Etapa A (mock)

Este diretório é o substituto temporário do backend real enquanto a Etapa A constrói a interface. Ele é lido por `assets/js/data-api.js` e some de vez quando o cutover (subtask 7.1) acontecer — nada na interface deveria saber que estes arquivos existem.

## O que fazer aqui (subtask 0.5 — curadoria humana, não é tarefa de código)

1. Abra `leads.json` e `leads-detalhe.json`. Cada um tem **3 entradas de exemplo** (`exemplo-mkt-01`, `exemplo-com-01`, `exemplo-na-01`) — uma por segmento (Marketing, Comercial, Não atribuído).
2. **Substitua** essas entradas por ~6-10 leads reais das suas planilhas (Central de Leads e equivalentes), mantendo exatamente o mesmo formato.
3. Para cada lead, você precisa saber e registrar **qual sinal (S1 a S6)** o classifica — não só o rótulo final. Consulte a tabela abaixo se tiver dúvida.
4. **Anonimize antes de salvar.** Nome, e-mail, telefone **e empresa** precisam ser fictícios na versão final do arquivo — isso vai para o mesmo repositório público que já teve um vazamento de dados reais corrigido (ver `[[project_pii_exposure_incident]]` na memória do projeto). Nome de empresa real, combinado com segmento/estágio/valor, pode revelar quem são os clientes/prospects da Loupen — trate como dado sensível também, não só nome de pessoa. Pode manter reais: segmento/sinal calculado, estágio do funil, valores de MRR, `RecordType.Name`, e o **código/nome bruto da campanha** (é taxonomia interna da Loupen, não identifica o cliente).
5. Cubra os três segmentos. Se puder, inclua pelo menos um lead sem oportunidade e um sem conta (estados vazios que a interface precisa saber mostrar).

## Tabela de sinais (para você anotar o `sinal_id` certo)

| ID | Quando usar | `segmento` resultante |
|---|---|---|
| S1 | Tem Ad ID de anúncio (Meta/Google/LinkedIn) na origem | `marketing` |
| S2 | E-mail bate com um registro de campanha já conhecido | `marketing` |
| S3 | O campo de origem (`LeadSource`) tem um código de campanha reconhecível, mesmo sem saber o canal exato | `marketing` |
| S4 | Converteu numa landing page / formulário / pop-up | `marketing` |
| S5 | Foi prospectado ativamente (prospecção, cold call, lista) — **único caminho pra Comercial** | `comercial` |
| S6 | Nenhum dos sinais acima bateu | `nao_atribuido` |

**Regra que não pode quebrar:** `comercial` só existe com `sinal_id: "S6"` — nunca use Comercial como "não sei o que é". Se não souber, é `nao_atribuido` com `S6`.

## Depois de preencher

Rode a validação (subtask 0.3, ainda a ser escrita depois que você preencher isto):
```bash
node --test tests/contract/fixture-shape.test.mjs
```
Ela confere que o formato bate com `docs/architecture/data-contract.md` e `docs/architecture/schemas/lead.schema.json` — não que os dados "fazem sentido de negócio". Isso é com você.
