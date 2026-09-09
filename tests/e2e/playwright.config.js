// tests/e2e/playwright.config.js — subtask 5.16, Faixa 2 de ADR-017.
//
// Executado via `npx --yes playwright test --config tests/e2e/playwright.config.js`
// (CON-12: nada entra em package.json da aplicação — o download do browser
// é ação de máquina de dev, não passo de build do artefato entregue).
//
// DESVIO DECLARADO em relação à nota original desta subtask no plano: o
// texto do plano assume `https://<hostname-oq15>/` com sessão do Cloudflare
// Access via storageState/CF_Authorization — isso descreve o alvo real da
// Etapa B (hostname protegido, backend real). Etapa A ainda não tem esse
// hostname: o artefato é servido estático localmente e não existe gate
// Cloudflare Access na frente de um `python3 -m http.server` local. Este
// config sobe/derruba esse servidor automaticamente via `webServer` e roda
// contra localhost — sem storageState, porque não há Access para autenticar
// contra. Quando a Etapa B estiver no ar, `baseURL` e o bloco `webServer`
// abaixo são o que muda; os specs em si (que testam comportamento de UI,
// não infraestrutura de acesso) não precisam mudar.

const path = require('node:path');

// Nota técnica (achado real ao rodar `npx --yes playwright test`): este
// config NÃO importa `defineConfig` de '@playwright/test' de propósito.
// Quando instalado via npx, `@playwright/test` vive só dentro do cache
// isolado do npx (~/.npm/_npx/<hash>/node_modules) — a resolução padrão de
// `require()` do Node parte do diretório DESTE arquivo (tests/e2e/) e nunca
// enxerga esse cache, então `require('@playwright/test')` aqui sempre falha
// com MODULE_NOT_FOUND antes mesmo dos testes rodarem. `defineConfig` é só
// açúcar de tipagem (TypeScript) — um objeto simples é um config válido em
// runtime. Os specs em si continuam usando `require('@playwright/test')`
// normalmente: o test runner do Playwright carrega arquivos de teste com
// seu próprio resolvedor interno, que enxerga o pacote onde quer que o
// npx o tenha instalado — só o carregamento do ARQUIVO DE CONFIG usa
// `require()` puro do Node, por isso só ele precisava deste contorno.
module.exports = ({
  testDir: '.',
  timeout: 15000,
  fullyParallel: false,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:8123',
    headless: true,
    screenshot: 'only-on-failure',
  },
  webServer: {
    command: 'python3 -m http.server 8123',
    cwd: path.resolve(__dirname, '../..'),
    url: 'http://localhost:8123',
    reuseExistingServer: !process.env.CI,
    timeout: 10000,
  },
});
