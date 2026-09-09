# ADR-018: Cloudflare Pages + Access em conta nova, no lugar de GitHub Pages + regras de borda no domínio existente

**Status:** Aceito · **Data:** 2026-09-09 · **Épico:** `epic-crm-lead-intelligence`

## Contexto

O desenho de phase-4 assumia acesso administrativo à zona Cloudflare de `loupenapps.com.br` / `loupen.com.br`. Reconhecimento por `dig` (subtask 1.2) confirmou que **os dois domínios já estão em nameservers da Cloudflare** — o que na época pareceu excelente notícia (eliminava o risco R3 de migração de nameserver).

Em 2026-09-09 o usuário informou que **não vai conseguir acesso à conta que administra esses domínios**. Isso invalida, de uma vez, cinco subtasks de phase-4 que dependiam de configurar coisas *naquela* zona:

- Access Application cobrindo o hostname (4.5/4.6/4.7)
- Origin Rule roteando `/api/*` para o n8n (4.9)
- URL Rewrite convertendo `/api/<recurso>` no caminho real do webhook (4.10)
- Request Header Modification injetando o segredo na borda (4.11)
- Custom domain no GitHub Pages (4.3)

O problema de fundo **não** mudou, e é o que importa preservar: um site estático no GitHub Pages não tem como (a) restringir quem vê nem (b) esconder do navegador o segredo que a API exige. Sem resolver os dois, publicar o modo real expõe PII de lead a qualquer visitante — a mesma classe do incidente já ocorrido neste repositório.

O plano já previa esta bifurcação: **OQ-16 era exatamente "aceitar o plano B"**, descrito como "melhor postura de segurança do leque, ao custo de sair do GitHub Pages e introduzir passo de deploy". O gatilho do plano B ocorreu.

## Decisão

**Cloudflare Pages + Cloudflare Access, numa conta Cloudflare NOVA (do usuário), no hostname gratuito `*.pages.dev`.**

Três peças:

1. **Hospedagem:** Cloudflare Pages, com integração git no repositório existente. O site já é estático (CON-12, sem build step), então o Pages só serve os arquivos — deploy automático a cada `git push`, sem pipeline.
2. **Gate de acesso:** Cloudflare Access no hostname de produção `*.pages.dev`, política única "Emails ending in `@loupen.com.br`". Grátis até 50 usuários, indefinidamente, sem cartão.
3. **Injeção do segredo:** uma **Pages Function** (`functions/api/[[path]].js`) atende `/api/*`, lê `CRM_API_KEY` de `context.env` (secret encriptado do projeto) e repassa ao n8n com o header. O navegador chama `/api/*` **same-origin, sem chave nenhuma**.

Consequência direta em `assets/js/data-api.js`: o cutover passa a ser trocar **uma constante** (`MODO_DADOS = 'mock'` → `'real'`), exatamente como ADR-021 previu. O caminho de teste local (`window.__CRM_API_KEY__`, chamando o n8n direto) foi **preservado** — continua útil para validar a integração sem depender de deploy.

### Por que isto não exige DNS nem domínio

`*.pages.dev` é servido pela Cloudflare sem nenhum registro DNS de terceiro. O Access consegue proteger o hostname de produção `*.pages.dev` (removendo o wildcard no campo *Subdomain* da aplicação). Verificado na documentação e na comunidade da Cloudflare antes de decidir, não assumido.

### Por que a Pages Function é melhor que o desenho original

O desenho original precisava de **duas** regras de borda coordenadas (Origin Rule roteando + Request Header Modification injetando) mais uma URL Rewrite para esconder a peculiaridade do `webhookId` do n8n. A Function faz as três coisas em **um** arquivo versionado, revisável e testável — e a peculiaridade do webhookId fica encapsulada onde deveria estar, não no cliente.

### Allowlist, não proxy aberto

A Function **lista explicitamente** as três rotas de leitura (`/api/meta`, `/api/leads`, `/api/leads/{id}`) e recusa tudo o mais, além de aceitar somente `GET`.

Isto é deliberado e não é redundante com o Access: quem chega na Function já é um usuário autenticado `@loupen.com.br`, mas um proxy genérico permitiria a essa pessoa chamar **qualquer** webhook daquela instância n8n — inclusive os de automação com efeito colateral real (os que escrevem em planilha, disparam CAPI, cadastram lead no RD Station) — usando uma chave que ela nunca vê. O `id` também é validado por regex antes de compor a URL upstream, para que um id malformado não vire *path traversal*.

## Alternativas rejeitadas

**n8n servindo o dashboard com Basic Auth.** Atraente por não exigir nada novo (a instância já existe e funciona) e por deixar a API same-origin de graça. Rejeitada por dois motivos concretos: (1) Basic Auth é **senha compartilhada**, não identidade — perde-se a restrição por domínio de e-mail e o rastro de quem entrou, que é metade do valor do gate; (2) servir CSS/JS de múltiplos arquivos por webhooks do n8n exigiria ou uma rota por arquivo ou inline de tudo num HTML único, e colocaria tráfego de dashboard na mesma instância que roda as automações de produção.

**Domínio novo (~R$40–60/ano) em conta Cloudflare nova.** Mesma arquitetura desta ADR, só com URL apresentável. Não rejeitada por mérito técnico — apenas não escolhida agora, porque `*.pages.dev` resolve o problema com custo zero, e trocar para um domínio próprio depois é uma mudança aditiva (acrescentar custom domain ao mesmo projeto Pages + uma Access Application a mais). Fica registrada como caminho de evolução, não como decisão descartada.

**Migrar os nameservers de `loupenapps.com.br` para a conta nova.** Rejeitada: `n8n.loupenapps.com.br` é infraestrutura de produção viva naquele domínio. Migrar nameserver exigiria recriar todos os registros DNS corretamente, e um erro derruba o n8n — que é a espinha dorsal de toda a ingestão. Risco enorme para benefício nenhum, já que `*.pages.dev` dispensa DNS.

**Gate por senha no cliente (JS).** Rejeitada sem discussão: qualquer pessoa lê o código-fonte. Teatro de segurança, e com PII envolvida.

## Consequências

**Positivas:**
- Resolve o bloqueio sem depender de acesso que não existe, e sem custo.
- Postura de segurança **melhor** que o plano original: o segredo vive em um lugar server-side versionado, e a superfície exposta é uma allowlist de 3 rotas `GET`, não um roteamento genérico.
- O cutover fica sendo uma constante — testável, revisável, reversível por um commit.

**Negativas / limites aceitos:**
- **Sai do GitHub Pages**, revertendo a decisão travada nº 5 do épico. É a aceitação explícita de OQ-16.
- **O GitHub Pages tem de ser DESATIVADO** depois do corte. Se ficar ligado, a URL `github.io` continua servindo o conteúdo em aberto — e o critério de aceite de R1 (4.4) é exatamente "a URL `github.io` não serve mais o conteúdo". Enquanto o modo for `mock` isso não expõe dado real, mas com `MODO_DADOS = 'real'` a Function não é alcançável pelo GitHub Pages, então a versão `github.io` simplesmente quebraria — o risco é ficar uma URL pública quebrada e confusa, não um vazamento.
- **O repositório continua público.** O que ele contém é código e o fixture anonimizado; o dado real chega só via API, que está atrás do gate. Aceito, mas é uma decisão a revisitar se algum dia um dado sensível precisar ir para o repo.
- **`*.pages.dev` não é uma URL bonita** para uso executivo. Aceito por ora (ver alternativa do domínio próprio).
- Uma peça a mais para manter (a Function). Mitigado por ser pequena, versionada e com a lógica de rota testável isoladamente.

## Ver também

- `functions/api/[[path]].js` — a Function, com o raciocínio de segurança nos comentários
- `assets/js/data-api.js` — `MODO_DADOS`, o único interruptor do cutover
- `docs/architecture/edge-routing.md` — o mapa de borda atualizado
- ADR-021 (previu que o cutover seria a troca de uma constante de origem)
- ADR-017 (por que não há build step — o que torna o Pages uma troca barata)
