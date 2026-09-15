// tests/e2e/atribuicao-e-ficha.spec.js — subtask 5.16.
// Cobre "Feature: Ficha do lead e jornada (FR-2, FR-3, FR-6)" de spec.md §6.3.
// NÃO cobre "Feature: Atribuição de origem auditável" — essa regra mora no
// banco (Etapa B) e é testada por asserção SQL (3.4/3.6), não pela UI.

const { test, expect } = require('@playwright/test');

test.describe('Ficha do lead e jornada', () => {
  test('Ficha de lead convertido: exibe oportunidade vinculada e a razão da classificação', async ({ page }) => {
    // real-mkt-01 tem related.oportunidade preenchido no fixture (Etapa A).
    await page.goto('/?view=leads-crm&lead=real-mkt-01&dados=mock');
    await expect(page.locator('#crm-p-nome')).toContainText('Camila R.');
    await expect(page.locator('#crm-view-overview')).toContainText('Classificado como Marketing');

    // 2026-09-15: o painel do lead deixou de ter abas — #crm-panel-tabs saiu de
    // index.html e #crm-view-related agora renderiza empilhado, sempre visível.
    // O clique na aba virou ruído, não um passo do cenário. As asserções
    // abaixo seguem INTACTAS: é delas que vem a garantia do AC.
    await expect(page.locator('#crm-view-related')).not.toContainText('Sem oportunidade');
    await expect(page.locator('#crm-view-related')).toContainText('Avaliação');
  });

  test('Lead não convertido: estado vazio explícito, sem tentativa de join por LeadSource', async ({ page }) => {
    // real-mkt-03 tem related.conta=null e related.oportunidade=null no fixture.
    await page.goto('/?view=leads-crm&lead=real-mkt-03&dados=mock');
    // 2026-09-15: o painel do lead deixou de ter abas — #crm-panel-tabs saiu de
    // index.html e #crm-view-related agora renderiza empilhado, sempre visível.
    // O clique na aba virou ruído, não um passo do cenário. As asserções
    // abaixo seguem INTACTAS: é delas que vem a garantia do AC.
    await expect(page.locator('#crm-view-related')).toContainText('Sem conta associada');
    await expect(page.locator('#crm-view-related')).toContainText('Lead ainda não convertido');
  });

  test('Detalhe endereçável e retomável: filtros A e B continuam aplicados ao voltar', async ({ page }) => {
    await page.goto('/?view=leads-crm&segmento=marketing&segmento=comercial&dados=mock');
    const linhasAntes = await page.locator('#crm-lead-rows tr').count();
    await page.click('tr[data-lead-row="real-mkt-01"]');
    await expect(page).toHaveURL(/lead=real-mkt-01/);

    await page.goBack();
    await expect(page).toHaveURL(/segmento=marketing/);
    await expect(page).toHaveURL(/segmento=comercial/);
    expect(await page.locator('#crm-lead-rows tr').count()).toBe(linhasAntes);
  });

  test('Jornada com fonte indisponível: lacuna declarada, nunca ausência silenciosa', async ({ page }) => {
    // seed-src-01 tem um evento com idade_dado_declarada preenchida (EC-8).
    await page.goto('/?view=leads-crm&lead=seed-src-01&dados=mock');
    // 2026-09-15: sem abas no painel — #crm-view-jornada já vem renderizado.
    // Só o clique saiu; toda a asserção de EC-8 abaixo permanece intacta.
    const jornada = page.locator('#crm-view-jornada');
    await expect(jornada).toContainText('Conversão em Landing Page');
    await expect(jornada).toContainText('Fonte indisponível na última tentativa de coleta');
    await expect(jornada).toContainText('dias atrás');
    await expect(jornada).not.toContainText(/\b0 dias\b/);
  });
});
