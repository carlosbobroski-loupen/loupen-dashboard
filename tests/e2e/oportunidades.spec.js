// tests/e2e/oportunidades.spec.js — a aba Oportunidades no navegador, em modo
// mock (`?dados=mock`), incluindo os CENÁRIOS degradados que a base real quase
// nunca produz (`?cenario=...`, só em host local, ver data-api.js).
//
// O que estes specs existem para pegar, e que o teste de render puro não pega:
// a fiação. Markup com id trocado, view que não entra em MIGRATED_VIEWS (e
// ganha banner de "snapshot congelado" mentindo que o dado é estático), título
// da página caindo no id cru, seletor de período global visível e inerte.

const { test, expect } = require('@playwright/test');

test.describe('Aba Oportunidades (CRM ao vivo)', () => {
  test('abre pelo menu, com título próprio e sem banner de snapshot congelado', async ({ page }) => {
    await page.goto('/?dados=mock');
    await page.click('.nav-item:has-text("Oportunidades")');
    await expect(page.locator('#view-oportunidades-crm')).toHaveClass(/active/);
    await expect(page.locator('#page-title')).toHaveText('Oportunidades');
    // MIGRATED_VIEWS: sem isto a view ganharia o banner dizendo que lê arquivo
    // estático — o oposto do que ela faz.
    await expect(page.locator('#view-oportunidades-crm .snapshot-banner')).toHaveCount(0);
    // O seletor de período do topo é do carregamento legado e não recorta esta
    // aba: ela traz o próprio. Controle visível e inerte mente sobre o número.
    await expect(page.locator('#date-range-wrap')).toBeHidden();
  });

  test('o drill "Receita ganha" da Visão geral leva à aba nova, não à da planilha', async ({ page }) => {
    // Antes levava a showView('oportunidades'): uma SEGUNDA página com o mesmo
    // título, sem marcação no menu, publicando o card "Tempo mediano da
    // oportunidade virar ganho" — a métrica que esta aba recusa por ser fim de
    // contrato.
    await page.goto('/?dados=mock');
    await page.click('#view-overview .kpi-nav:has-text("Receita ganha")');
    await expect(page.locator('#view-oportunidades-crm')).toHaveClass(/active/);
    await expect(page.locator('#page-title')).toHaveText('Oportunidades');
    // o menu passa a marcar onde o usuário está (antes: 0 itens ativos)
    await expect(page.locator('.nav-item.active')).toHaveCount(1);
    // e o destino não publica a métrica de ciclo
    await expect(page.locator('.view.active [title*="Tempo mediano da oportunidade virar ganho"]')).toHaveCount(0);
    // o card avisa que o detalhe muda de fonte
    await expect(page.locator('#view-overview .kpi-nav:has-text("Receita ganha")')).toContainText('o detalhe abre sobre dado ao vivo');
  });

  test('paginação: "Carregar mais" concatena em ordem e some quando acaba', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-lista-rows tr');
    const linhas = page.locator('#opc-lista-rows tr');
    await expect(linhas).toHaveCount(50);
    await expect(page.locator('#opc-mais')).toBeVisible();
    const primeiraAntes = await linhas.first().innerText();

    await page.click('#opc-btn-mais');
    await expect(linhas).toHaveCount(60);
    // o botão obedece `tem_mais` da camada, não `_acumulado.length < total`:
    // com `total` 420 sobre um fixture de 60, a comparação antiga deixava o
    // botão visível para sempre sem nada para carregar.
    await expect(page.locator('#opc-mais')).toBeHidden();
    // concatenou, não substituiu nem reordenou
    expect(await linhas.first().innerText()).toBe(primeiraAntes);
  });

  test('sair e voltar à aba recomeça da primeira página, não do offset antigo', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-lista-rows tr');
    const primeira = await page.locator('#opc-lista-rows tr').first().innerText();
    await page.click('#opc-btn-mais');
    await expect(page.locator('#opc-lista-rows tr')).toHaveCount(60);

    await page.evaluate(() => window.showView('leads-crm'));
    await page.evaluate(() => window.showView('oportunidades-crm'));

    // Antes: 1 linha (estado vazio) dizendo "Mostrando 0 de 420", porque
    // `renderViewOportunidades` chamava carregar(false) sem zerar o offset.
    await expect(page.locator('#opc-lista-rows tr')).toHaveCount(50);
    expect(await page.locator('#opc-lista-rows tr').first().innerText()).toBe(primeira);
    await expect(page.locator('#opc-lista-foot')).toContainText('Mostrando 50 de 420');
  });

  test('o recorte vive na URL e sobrevive ao F5', async ({ page }) => {
    await page.goto('/?dados=mock');
    await page.click('.nav-item:has-text("Oportunidades")');
    await page.waitForSelector('#opc-kpis .kpi');
    await expect(page).toHaveURL(/view=oportunidades-crm/);

    await page.selectOption('#opc-vinculo', 'conta');
    await page.selectOption('#opc-ordem', 'valor');
    await expect(page).toHaveURL(/ovinc=conta/);
    await expect(page).toHaveURL(/oord=valor/);
    // a chave de sessão de teste NÃO pode ser apagada pela reescrita da query
    await expect(page).toHaveURL(/dados=mock/);

    await page.reload();
    await page.waitForSelector('#opc-kpis .kpi');
    await expect(page.locator('#view-oportunidades-crm')).toHaveClass(/active/);
    await expect(page.locator('#opc-vinculo')).toHaveValue('conta');
    await expect(page.locator('#opc-ordem')).toHaveValue('valor');
  });

  test('URL adulterada é saneada em vez de derrubar a aba', async ({ page }) => {
    // `ordenar_por` inválido faz RAISE EXCEPTION no SQL; preset inválido
    // abriria o universo parecendo estar nos 12 meses.
    await page.goto('/?view=oportunidades-crm&dados=mock&oord=xpto&opreset=inexistente');
    await expect(page.locator('#opc-kpis .kpi')).toHaveCount(12);
    await expect(page.locator('#opc-ordem')).toHaveValue('recentes');
    await expect(page.locator('#opc-presets .preset-btn.active')).toHaveText('12m');
  });

  test('o seletor de desfecho não publica zero falso quando o filtro está ativo', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    const opcoes = () => page.locator('#opc-desfecho option').allInnerTexts();
    expect((await opcoes()).join('|')).toMatch(/Perdidas \(74\)/);

    await page.selectOption('#opc-desfecho', 'ganha');
    await page.waitForTimeout(400);
    const depois = (await opcoes()).join('|');
    // `cards` já aplica o filtro de desfecho: as outras contagens virariam 0.
    expect(depois).not.toMatch(/Perdidas \(0\)/);
    expect(depois).not.toMatch(/Abertas \(0\)/);
    expect(depois).toMatch(/limpe para ver as contagens/);
  });

  test('os dois botões antigos de Oportunidades saíram do menu', async ({ page }) => {
    await page.goto('/?dados=mock');
    await expect(page.locator('.nav-item[onclick*="showView(\'oportunidades\')"]')).toHaveCount(0);
    await expect(page.locator('.nav-item[onclick*="oportunidades_v2"]')).toHaveCount(0);
    // e o markup antigo continua na página, dormente (reversão é devolver o botão)
    await expect(page.locator('#view-oportunidades')).toHaveCount(1);
  });

  test('win rate aparece SEMPRE com o denominador visível, não em tooltip', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    const card = page.locator('#view-oportunidades-crm .kpi', { hasText: 'Win rate (decididas)' });
    await expect(card).toContainText('56,47%');
    await expect(card).toContainText('96 de 170 decididas');
  });

  test('receita nunca sai sozinha: quantidade fora da soma e motivo no mesmo card', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    // Escopo obrigatório em #view-oportunidades-crm: o markup das abas antigas
            // continua na página (dormente) e também tem um KPI "Receita ganha" —
            // com o número da PLANILHA. Um seletor global casaria os dois.
    const card = page.locator('#view-oportunidades-crm .kpi', { hasText: 'Receita ganha' });
    await expect(card).toContainText('R$ 1.284.530,56');
    await expect(card).toContainText('12 ganha(s) fora da soma');
    await expect(card).toContainText('Amount vazio na origem');
  });

  test('o funil é rotulado como estoque e proíbe dividir uma fase pela outra', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await expect(page.locator('#opc-funil')).toContainText('Leia como estoque');
    await expect(page.locator('#opc-funil')).toContainText('não produz taxa de conversão');
    // regra 5: a linha "(fora de qualquer fase)" aparece mesmo valendo 3
    await expect(page.locator('#opc-funil')).toContainText('(fora de qualquer fase)');
  });

  test('CENÁRIO soma_fecha=false: alerta no topo e NENHUM KPI desenhado', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&cenario=soma_nao_fecha');
    await expect(page.locator('#opc-integridade')).toContainText('não fecha');
    await expect(page.locator('#opc-integridade')).toContainText('diferença de');
    await expect(page.locator('#opc-kpis .kpi')).toHaveCount(0);
    await expect(page.locator('#opc-funil')).toContainText('Seção suprimida');
    // par negativo: no cenário saudável os KPIs existem
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await expect(page.locator('#opc-kpis .kpi')).toHaveCount(12);
  });

  test('CENÁRIO sem período anterior: nenhuma seta de tendência na tela', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&cenario=sem_periodo_anterior');
    await expect(page.locator('#opc-kpis .ti-trending-up, #opc-kpis .ti-trending-down')).toHaveCount(0);
    await expect(page.locator('#opc-recorte-info')).toContainText('Sem período anterior comparável');
    // par negativo: no cenário saudável há setas
    await page.goto('/?view=oportunidades-crm&dados=mock');
    expect(await page.locator('#opc-kpis .ti-trending-up, #opc-kpis .ti-trending-down').count()).toBeGreaterThan(0);
  });

  test('moeda estrangeira na lista: convertido E cru, nunca R$ em cima do peso', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    const linha = page.locator('#opc-lista-rows tr', { hasText: 'Cloud Andina' });
    await expect(linha).toContainText('R$ 175.960,30');
    await expect(linha).toContainText('MX$ 600.000,00');
    await expect(linha).not.toContainText('R$ 600.000,00');
  });

  test('a lista não expõe nome de lead (repositório público, aba é sobre o negócio)', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await expect(page.locator('#opc-lista-foot')).toContainText('não exibe nome de lead');
    const cols = await page.locator('#view-oportunidades-crm thead th').allInnerTexts();
    expect(cols.join('|')).not.toMatch(/lead|nome|e-mail|telefone/i);
  });

  test('sem recorte de período a tela diz isso por escrito, em vez de deixar o leitor supor', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&cenario=sem_periodo');
    await expect(page.locator('#opc-recorte-info')).toContainText('sem recorte de período');
  });
});
