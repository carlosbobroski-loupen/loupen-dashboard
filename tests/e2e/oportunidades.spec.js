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

  test('a aba não expõe PESSOA: nem coluna de identificação, nem e-mail ou telefone no conteúdo', async ({ page }) => {
    // A VERSÃO ANTERIOR PROIBIA A PALAVRA "lead" EM QUALQUER CABEÇALHO, e isso
    // deixou de servir quando a seção de categoria trouxe a coluna "Leads
    // gerados" — que é uma CONTAGEM agregada, não identificação de ninguém. A
    // regra foi reescrita para dizer o que ela sempre quis dizer, e ficou mais
    // rígida, não mais frouxa:
    //
    //   1. nenhum cabeçalho pode identificar uma PESSOA (nome, e-mail, telefone,
    //      ou uma coluna "Lead"/"Contato" no singular, que é o que carregaria
    //      um indivíduo);
    //   2. e agora o CONTEÚDO inteiro da aba é varrido atrás de e-mail e
    //      telefone — que é o dado do incidente, e que o teste antigo nunca
    //      olhou porque só lia cabeçalho.
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await expect(page.locator('#opc-lista-foot')).toContainText('não exibe nome de lead');

    const cols = await page.locator('#view-oportunidades-crm thead th').allInnerTexts();
    const juntos = cols.join('|');
    expect(juntos).not.toMatch(/nome|e-?mail|telefone|celular|cpf/i);
    // "Lead"/"Contato" no singular identificaria um indivíduo; "Leads gerados"
    // é contagem. A distinção é o plural seguido de qualificador agregado.
    for (const col of cols) {
      expect(col.trim()).not.toMatch(/^(lead|contato|pessoa)$/i);
    }
    expect(cols.some((c) => /^leads gerados$/i.test(c.trim()))).toBe(true);

    // O conteúdo, e não só os títulos. Vale para a tabela de baixo e para o painel.
    const varrer = async () => {
      const texto = await page.locator('#view-oportunidades-crm').innerText();
      expect(texto).not.toMatch(/[\w.+-]+@[\w-]+\.[a-z]{2,}/i);
      expect(texto).not.toMatch(/\(?\d{2}\)?\s?9?\d{4}-?\d{4}/);
    };
    await varrer();
    await page.click('#opc-kpis .kpi[data-drill="ganhas"]');
    await page.waitForSelector('#opc-det-rows tr');
    await varrer();
  });

  test('sem recorte de período a tela diz isso por escrito, em vez de deixar o leitor supor', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&cenario=sem_periodo');
    await expect(page.locator('#opc-recorte-info')).toContainText('sem recorte de período');
  });

  // ── DRILL-DOWN: o painel que abre ao clicar num número ────────────────────
  // Em modo mock o fixture NÃO refiltra (ver data-api.js), então aqui não dá
  // para verificar a igualdade painel × card — ela é medida contra a API real
  // em tests/contract/oportunidades-drilldown-api.test.mjs. O que estes specs
  // pegam é a FIAÇÃO: abrir, fechar, teclado, URL, paginação, e quais números
  // podem ou não virar botão.

  test('clicar num card abre o painel, com o recorte escrito no título', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    await expect(page.locator('#opc-detalhe')).toBeHidden();

    await page.click('#opc-kpis .kpi[data-drill="ganhas"]');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
    await expect(page.locator('#opc-det-titulo')).toContainText('Ganhas');
    await expect(page.locator('#opc-det-titulo')).toContainText('oportunidades');
    // o recorte, por extenso, e não "detalhe"
    await expect(page.locator('#opc-det-sub')).toContainText('Recorte:');
    await expect(page.locator('#opc-det-sub')).toContainText('desfecho = Ganhas');
    await expect(page.locator('#opc-det-rows tr')).toHaveCount(50);
    // e o estado do painel vai para a URL (F5 e link compartilhado)
    await expect(page).toHaveURL(/odet=ganhas/);
  });

  test('o painel fecha no X, no overlay e no Esc — e some da URL', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');

    // O overlay é fechado por CLIQUE NA MARGEM VISÍVEL, não no centro: o
    // diálogo fica por cima do meio da tela (é a mesma geometria do modal
    // legado). `page.click` miraria o centro do overlay, que está coberto — o
    // usuário clica no canto, e é isso que o teste faz.
    const fecharPor = {
      'botão X': () => page.click('#opc-det-fechar'),
      'clique fora (canto superior esquerdo)': () => page.mouse.click(8, 8),
      'tecla Esc': () => page.keyboard.press('Escape'),
    };
    for (const [, acao] of Object.entries(fecharPor)) {
      await page.click('#opc-kpis .kpi[data-drill="perdidas"]');
      await expect(page.locator('#opc-detalhe')).toBeVisible();
      await expect(page).toHaveURL(/odet=perdidas/);
      await acao();
      await expect(page.locator('#opc-detalhe')).toBeHidden();
      await expect(page).not.toHaveURL(/odet=/);
    }
  });

  test('o painel sobrevive ao F5 — ele vive na URL como o resto da aba', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&odet=segmento:Marketing');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
    await expect(page.locator('#opc-det-titulo')).toContainText('Marketing');
    await expect(page.locator('#opc-det-rows tr')).toHaveCount(50);
    // a chave de sessão de teste não pode ser apagada pela reescrita da URL
    await expect(page).toHaveURL(/dados=mock/);
    await expect(page).toHaveURL(/odet=segmento/);
  });

  test('`odet` adulterado não abre painel nenhum nem derruba a aba', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&odet=xpto');
    await expect(page.locator('#opc-kpis .kpi')).toHaveCount(12);
    await expect(page.locator('#opc-detalhe')).toBeHidden();
    // par positivo: o mesmo caminho com um tipo válido ABRE
    await page.goto('/?view=oportunidades-crm&dados=mock&odet=abertas');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
  });

  test('o painel abre pelo teclado (role=button precisa responder a Enter)', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    await page.locator('#opc-kpis .kpi[data-drill="total"]').focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
    await expect(page.locator('#opc-det-titulo')).toContainText('Todas as oportunidades');
  });

  test('a paginação do painel obedece `tem_mais`, e não mexe na lista de baixo', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-lista-rows tr');
    const listaAntes = await page.locator('#opc-lista-rows tr').count();

    await page.click('#opc-kpis .kpi[data-drill="total"]');
    await expect(page.locator('#opc-det-rows tr')).toHaveCount(50);
    await expect(page.locator('#opc-det-mais')).toBeVisible();
    const primeira = await page.locator('#opc-det-rows tr').first().innerText();

    await page.click('#opc-det-btn-mais');
    await expect(page.locator('#opc-det-rows tr')).toHaveCount(60);
    // `tem_mais` da camada, nunca `acumulado.length < total` (bloqueador 2 do QA)
    await expect(page.locator('#opc-det-mais')).toBeHidden();
    expect(await page.locator('#opc-det-rows tr').first().innerText()).toBe(primeira);
    // os dois offsets são independentes: a lista de baixo não se mexeu
    expect(await page.locator('#opc-lista-rows tr').count()).toBe(listaAntes);
  });

  test('mexer num filtro fecha o painel — o recorte que ele herdou mudou', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    await page.click('#opc-kpis .kpi[data-drill="ganhas"]');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
    await page.selectOption('#opc-moeda', 'USD');
    await expect(page.locator('#opc-detalhe')).toBeHidden();
    await expect(page).not.toHaveURL(/odet=/);
  });

  test('número que não é conjunto não vira botão: win rate, receita, ticket e pipeline', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    // 12 cards, 8 clicáveis — os 4 de razão/soma ficam de fora, com o motivo escrito
    await expect(page.locator('#opc-kpis .kpi')).toHaveCount(12);
    // 8 dos 12 definem conjunto; "Sem declaração da origem" vale 0 no fixture
    // (e na base real), e card de zero não abre — ver o teste dedicado.
    await expect(page.locator('#opc-kpis .kpi[data-drill]')).toHaveCount(7);
    for (const rotulo of ['Win rate', 'Receita ganha', 'Ticket médio', 'Pipeline aberto']) {
      const card = page.locator('#opc-kpis .kpi', { hasText: rotulo });
      await expect(card).toHaveCount(1);
      await expect(card).not.toHaveAttribute('data-drill', /.*/);
      await expect(card).toContainText('Sem lista:');
    }
  });

  test('a linha "(fora de qualquer fase)" do funil não abre, e diz por quê', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-funil .funil2-row');
    const semFase = page.locator('#opc-funil .funil2-row', { hasText: '(fora de qualquer fase)' });
    await expect(semFase).toHaveCount(1);
    await expect(semFase).not.toHaveAttribute('data-drill', /.*/);
    await expect(page.locator('#opc-funil')).toContainText('a API não aceita filtrar por ausência de fase');
    // par positivo: as linhas com fase abrem
    await expect(page.locator('#opc-funil .funil2-row[data-drill]')).toHaveCount(6);
    await page.click('#opc-funil .funil2-row[data-drill="fase:reuniao"]');
    await expect(page.locator('#opc-det-titulo')).toContainText('Reunião');
  });

  test('clicar numa LINHA da tabela de segmento abre o painel daquele balde', async ({ page }) => {
    // O alvo aqui é um <tr>, não um card: o clique chega num <td> e a delegação
    // tem de subir até a linha. Caminho diferente do card e do funil, e o único
    // que nenhum outro spec exercita por clique.
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-segmento-tbl tbody tr');
    await expect(page.locator('#opc-segmento-tbl tbody tr[data-drill]')).toHaveCount(6);
    await page.click('#opc-segmento-tbl tbody tr[data-drill="segmento:Comercial"] td:first-child');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
    await expect(page.locator('#opc-det-titulo')).toContainText('Segmento: Comercial');
    await expect(page).toHaveURL(/odet=segmento%3AComercial|odet=segmento:Comercial/);
  });

  test('o painel não expõe nome de lead (mesma regra da lista de baixo)', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock&odet=ganhas');
    await expect(page.locator('#opc-det-rows tr').first()).toBeVisible();
    await expect(page.locator('#opc-det-foot')).toContainText('não exibe nome de lead');
    const cols = await page.locator('#opc-detalhe thead th').allInnerTexts();
    expect(cols.join('|')).not.toMatch(/lead|nome|e-mail|telefone/i);
  });

  test('em modo mock o painel SUSPENDE a conferência por escrito, em vez de fingir', async ({ page }) => {
    // O fixture não refiltra: comparar o total dele com o número do card
    // levantaria um alarme vermelho que não é sobre o produto.
    await page.goto('/?view=oportunidades-crm&dados=mock&odet=ganhas');
    await expect(page.locator('#opc-det-sub')).toContainText('o mock não refiltra');
    await expect(page.locator('#opc-det-sub')).not.toContainText('se contradizendo');
  });

  // ── CATEGORIA DE ORIGEM ───────────────────────────────────────────────────

  test('a seção de categoria aparece, com o lado do lead ao lado e sem nenhuma taxa', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-categoria-tbl tbody tr');
    await expect(page.locator('#opc-categoria-tbl tbody tr')).toHaveCount(16);
    await expect(page.locator('#opc-categoria-badge')).toHaveText('16 categorias · 3 só do lado do lead');
    // as duas colunas convivem e nenhuma divide a outra
    const cols = await page.locator('#opc-categoria-tbl thead th').allInnerTexts();
    const nomes = cols.map((c) => c.trim().toLowerCase());
    expect(nomes).toContain('leads gerados');
    expect(nomes).toContain('oportunidades');
    expect(cols.join('|')).not.toMatch(/taxa|convers/i);
    await expect(page.locator('#opc-categoria-tbl')).toContainText('nenhuma divide a outra');
    await expect(page.locator('#opc-categoria-tbl')).toContainText('uma taxa ali marcaria 167%');
    // as duas conferências
    await expect(page.locator('#opc-categoria-tbl')).toContainText('as categorias somam 420');
    await expect(page.locator('#opc-categoria-tbl')).toContainText('748 = o total de leads do recorte');
  });

  test('categoria que só existe do lado do lead fica na tabela e não vira botão', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-categoria-tbl tbody tr');
    const ebook = page.locator('#opc-categoria-tbl tbody tr', { hasText: 'Conteúdo/Ebook' });
    await expect(ebook).toHaveCount(1);
    await expect(ebook).toContainText('55'); // os leads continuam visíveis
    await expect(ebook).not.toHaveAttribute('data-drill', /.*/);
    await expect(ebook).toContainText('sem lista: nenhuma oportunidade neste recorte');
    await expect(ebook).toContainText('o lado do lead trouxe 55');
    // par: uma linha com oportunidade É botão
    const inbound = page.locator('#opc-categoria-tbl tbody tr', { hasText: 'Inbound Web' });
    await expect(inbound).toHaveAttribute('data-drill', 'categoria:Marketing:Inbound Web');
  });

  test('clicar numa categoria abre o painel do PAR segmento × categoria', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-categoria-tbl tbody tr');
    await page.click('#opc-categoria-tbl tbody tr[data-drill="categoria:Marketing:Evento/Webinar"] td:first-child');
    await expect(page.locator('#opc-detalhe')).toBeVisible();
    await expect(page.locator('#opc-det-titulo')).toContainText('Marketing · Evento/Webinar');
    await expect(page.locator('#opc-det-sub')).toContainText('segmento = Marketing');
    await expect(page.locator('#opc-det-sub')).toContainText('categoria = Evento/Webinar');
    // a barra do nome sobrevive ao round-trip pela URL
    await expect(page).toHaveURL(/odet=categoria%3AMarketing%3AEvento%2FWebinar/);
    await page.reload();
    await expect(page.locator('#opc-det-titulo')).toContainText('Marketing · Evento/Webinar');
  });

  test('a linha de categoria NULA abre pelo segmento, com a ressalva na cara', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-categoria-tbl tbody tr');
    // duas linhas nulas no fixture (NaoClassificado e SemOrigem), como na base inteira
    await expect(page.locator('#opc-categoria-tbl tbody tr', { hasText: 'sem categoria — origem não classificada' })).toHaveCount(2);
    await page.click('#opc-categoria-tbl tbody tr[data-drill="categoria:NaoClassificado:"] td:first-child');
    await expect(page.locator('#opc-det-titulo')).toContainText('Sem categoria — segmento Não classificado');
    await expect(page.locator('#opc-det-sub')).toContainText('Não existe filtro de “categoria nula”');
    await expect(page.locator('#opc-det-sub')).toContainText('segmento = Não classificado');
  });

  // ── correções do QA ───────────────────────────────────────────────────────

  test('sair da aba com o painel aberto: Esc NÃO sequestra a URL de outra view', async ({ page }) => {
    // Defeito reproduzido: `_painel.tipo` não zerava na troca de view, o
    // listener de Esc do document seguia vivo, e `fecharPainel()` chamava
    // `persistirNaUrl()`, que crava `view`. A tela mostrava Leads e a URL dizia
    // `view=oportunidades-crm` — F5 abria a aba errada.
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    await page.click('#opc-kpis .kpi[data-drill="ganhas"]');
    await expect(page.locator('#opc-detalhe')).toBeVisible();

    // O MENU FICA COBERTO pelo overlay enquanto o painel está aberto (medido:
    // `elementFromPoint` sobre o item "Leads" devolve o overlay), e com a
    // armadilha de foco o Tab também não chega lá. Sobra o caminho
    // PROGRAMÁTICO — que existe de verdade: o card "Receita ganha" da Visão
    // geral chama `showView('oportunidades-crm')`, e o botão "voltar" faz o
    // inverso. É esse caminho que este teste exercita.
    await page.evaluate(() => window.showView('leads-crm'));
    // sair da aba fecha o painel: senão a trava de rolagem vazaria para a view seguinte
    await expect(page.locator('#opc-detalhe')).toBeHidden();
    expect(await page.evaluate(() => getComputedStyle(document.body).overflow)).toBe('visible');

    const urlAntes = page.url();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
    await expect(page.locator('.view.active')).toHaveId('view-leads-crm');
    // A GARANTIA É ESTA: fora da aba, esta view não escreve mais a URL. Antes,
    // o Esc chamava `persistirNaUrl()`, que crava `view=oportunidades-crm` e
    // apagava `odet` — com `view-leads-crm` na tela.
    expect(page.url()).toBe(urlAntes);
    // (A URL já estava desatualizada ANTES do Esc: `showView` legado não a
    // reescreve nesta chamada programática. Isso é de views-legacy.js, que este
    // módulo não edita — o defeito corrigido aqui é esta aba PIORAR a URL de
    // outra view, não a troca de view em si.)
  });

  test('o painel prende o foco e trava a rolagem — `aria-modal` com o comportamento que promete', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    expect(await page.evaluate(() => getComputedStyle(document.body).overflow)).toBe('visible');

    await page.click('#opc-kpis .kpi[data-drill="ganhas"]');
    await page.waitForSelector('#opc-det-rows tr');
    expect(await page.evaluate(() => getComputedStyle(document.body).overflow)).toBe('hidden');

    // Medido antes da correção: de 40 Tabs, 38 paradas caíam fora do diálogo
    // (a segunda já era o BODY). Agora nenhuma pode cair.
    let fora = 0;
    for (let i = 0; i < 40; i++) {
      await page.keyboard.press('Tab');
      const dentro = await page.evaluate(() => {
        const a = document.activeElement;
        return !!(a && a.closest && a.closest('#opc-detalhe'));
      });
      if (!dentro) fora++;
    }
    expect(fora).toBe(0);

    // Shift+Tab também, que é o outro sentido da armadilha
    for (let i = 0; i < 10; i++) {
      await page.keyboard.press('Shift+Tab');
      const dentro = await page.evaluate(() => {
        const a = document.activeElement;
        return !!(a && a.closest && a.closest('#opc-detalhe'));
      });
      if (!dentro) fora++;
    }
    expect(fora).toBe(0);

    // e fechar devolve a rolagem
    await page.keyboard.press('Escape');
    expect(await page.evaluate(() => getComputedStyle(document.body).overflow)).toBe('visible');
  });

  test('card valendo ZERO não convida a abrir lista vazia', async ({ page }) => {
    // Com o payload real de 12 meses, "Sem declaração da origem" e "Divergência
    // origem × fase" valem 0 e o rodapé imprimia "abrir as 0 oportunidades".
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-kpis .kpi');
    await expect(page.locator('#opc-kpis')).not.toContainText('abrir as 0 oportunidades');
    const zerado = page.locator('#opc-kpis .kpi', { hasText: 'Sem declaração da origem' });
    await expect(zerado).not.toHaveAttribute('data-drill', /.*/);
    await expect(zerado).toContainText('não há nenhuma para listar');
    // par positivo: um card com conteúdo continua abrindo
    await expect(page.locator('#opc-kpis .kpi[data-drill="ganhas"]')).toHaveCount(1);
  });

  test('a tabela de segmento mostra o lado do lead, adjacente às oportunidades', async ({ page }) => {
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-segmento-tbl tbody tr');
    const cols = (await page.locator('#opc-segmento-tbl thead th').allInnerTexts()).map((c) => c.trim().toLowerCase());
    expect(cols.slice(0, 3)).toEqual(['segmento', 'oportunidades', 'leads gerados']);
    await expect(page.locator('#opc-segmento-tbl')).toContainText('viraram oportunidade');
    await expect(page.locator('#opc-segmento-tbl')).toContainText('nenhuma divide a outra');
    await expect(page.locator('#opc-segmento-tbl')).toContainText('748 = o total de leads do recorte');
  });

  test('CENÁRIO vínculo não fecha: o alarme da camada aparece nas duas tabelas', async ({ page }) => {
    // `soma_vinculo_fecha` é true em 100% das linhas reais; sem este cenário o
    // aviso seria mais uma guarda que só consegue passar.
    await page.goto('/?view=oportunidades-crm&dados=mock&cenario=vinculo_nao_fecha');
    await page.waitForSelector('#opc-segmento-tbl tbody tr');
    await expect(page.locator('#opc-segmento-tbl')).toContainText('A partição por regra de vínculo não fecha');
    await expect(page.locator('#opc-categoria-tbl')).toContainText('A partição por regra de vínculo não fecha');
    // par negativo: no cenário saudável o alarme não existe
    await page.goto('/?view=oportunidades-crm&dados=mock');
    await page.waitForSelector('#opc-segmento-tbl tbody tr');
    await expect(page.locator('#opc-segmento-tbl')).not.toContainText('não fecha');
    await expect(page.locator('#opc-categoria-tbl')).not.toContainText('não fecha');
  });
});
