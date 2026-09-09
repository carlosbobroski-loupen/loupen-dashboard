// tests/e2e/filtros-e-navegacao.spec.js — subtask 5.16.
// Cobre "Feature: Filtragem combinável e navegação de relacionamentos"
// (FR-1, FR-4) de spec.md §6.3.

const { test, expect } = require('@playwright/test');

test.describe('Filtragem combinável', () => {
  test('Filtros combinados produzem a interseção, não a substituição', async ({ page }) => {
    await page.goto('/?view=leads-crm');
    await page.click('.seg-pill[data-seg="comercial"]');
    await page.click('.seg-pill[data-seg="nao_atribuido"]'); // só marketing fica ativo
    const totalMarketing = await page.locator('#crm-lead-rows tr').count();
    expect(totalMarketing).toBeGreaterThan(0);

    await page.click('tr[data-lead-row="real-mkt-03"]');
    await page.click('.meta-tab[data-tab="related"]');
    await page.click('#crm-view-related [data-ir-campanha]'); // filtro B: campanha

    await expect(page).toHaveURL(/segmento=marketing/);
    await expect(page).toHaveURL(/campanha=/);
    await expect(page.locator('#crm-active-chips')).toContainText('Marketing');
    await expect(page.locator('#crm-campanha-breadcrumb')).toBeVisible();
    const totalCombinado = await page.locator('#crm-lead-rows tr').count();
    expect(totalCombinado).toBeLessThan(totalMarketing); // interseção reduz, nunca substitui
  });

  test('Combinação de filtros sem resultado: estado vazio explícito com ação de limpar', async ({ page }) => {
    await page.goto('/?view=leads-crm&segmento=marketing&campanha=LOGMEIN_RESCUE-LICENCA-ECO_09_26_');
    // troca para comercial mantendo a campanha (nenhum lead comercial tem essa campanha)
    await page.click('.seg-pill[data-seg="comercial"]');
    await page.click('.seg-pill[data-seg="marketing"]');

    await expect(page.locator('#crm-lead-rows tr')).toHaveCount(0);
    const vazio = page.locator('#crm-empty-state');
    await expect(vazio).toBeVisible();
    await expect(vazio).toContainText('segmento: Comercial');
    await expect(vazio).toContainText('campanha:');

    await vazio.locator('button').click();
    await expect(page.locator('#crm-lead-rows tr').first()).toBeVisible();
  });

  test('Navegar de uma campanha para seus leads, com caminho de volta preservado', async ({ page }) => {
    await page.goto('/?view=leads-crm&lead=real-mkt-05'); // mesma campanha de real-mkt-03
    await page.click('.meta-tab[data-tab="related"]');
    await page.click('#crm-view-related [data-ir-campanha]');

    const linhas = await page.locator('#crm-lead-rows tr').allTextContents();
    expect(linhas.some((t) => t.includes('Diego S.'))).toBe(true);
    expect(linhas.some((t) => t.includes('Vitor L.'))).toBe(true);

    await page.click('#crm-campanha-voltar');
    await expect(page.locator('#crm-campanha-breadcrumb')).toHaveCount(0);
  });

  test('Campanha sem leads atribuídos: estado vazio explícito, sem contador zerado sem contexto', async ({ page }) => {
    await page.goto('/?view=leads-crm&campanha=campanha-inexistente-no-fixture');
    await expect(page.locator('#crm-empty-state')).toBeVisible();
    await expect(page.locator('#crm-empty-state')).toContainText('campanha-inexistente-no-fixture');
  });

  // GAP DECLARADO (ver implementation.yaml, subtask 5.11, nota "GAP DECLARADO"):
  // o contrato atual (data-contract.md §1/§2) só expõe oportunidades ANINHADAS
  // dentro de um lead — não existe endpoint de oportunidades avulso. Os dois
  // cenários abaixo do Gherkin de §6.3 são IRREPRESENTÁVEIS com os dados de
  // hoje: não há como construir uma "oportunidade sem lead convertido
  // associado" sem inventar um objeto que a Etapa A não tem de onde vir
  // (Constitution Artigo IV — No Invention). Marcados `skip`, não omitidos
  // silenciosamente, com o motivo explícito no próprio teste.
  test.skip('Voltar da oportunidade ao lead de origem — BLOQUEADO: contrato atual não expõe oportunidades como entidade independente (ver 5.11)', () => {});
  test.skip('Oportunidade sem origem rastreável — BLOQUEADO: mesma limitação de contrato acima; Etapa B precisa de um endpoint de oportunidades de primeira classe', () => {});
});
