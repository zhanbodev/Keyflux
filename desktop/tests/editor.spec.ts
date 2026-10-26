import { test, expect } from '@playwright/test';
test('main/side editing, follow mode, model switching and persistence bridge', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/?fixture=1');
  await expect(page.getByText('浏览器样例')).toBeVisible();
  await expect(page.locator('.key')).toHaveCount(81);
  await page.waitForFunction(() =>
    [...document.images].every((image) => image.complete && image.naturalWidth > 0),
  );
  await page.screenshot({ path: 'test-results/main-preview.png', fullPage: true });
  await page.getByLabel('HEX 颜色').fill('#FF2244');
  await page.getByRole('button', { name: '保存配色' }).click();
  await expect(page.locator('.save-bar [role=status]')).toHaveText('配色已保存');
  await expect(page.locator('.key-tint').first()).toHaveCSS(
    'background-color',
    'rgba(255, 34, 68, 0.294)',
  );
  await page.getByRole('button', { name: '侧边灯条', exact: true }).click();
  await expect(page.getByLabel('HEX 颜色')).toBeDisabled();
  await page.getByLabel('启用侧灯预览').check();
  await page.getByLabel('侧灯配色模式').selectOption('independent');
  await page.getByLabel('HEX 颜色').fill('#22FF66');
  await expect(page.locator('.side-strip').first()).toHaveCSS(
    'background-color',
    'rgb(34, 255, 102)',
  );
  await expect(page.locator('.key-tint').first()).toHaveCSS(
    'background-color',
    'rgba(255, 34, 68, 0.294)',
  );
  await page.screenshot({ path: 'test-results/side-preview.png', fullPage: true });
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  await expect(page.getByLabel('启用侧灯预览')).not.toBeChecked();
  await page.getByLabel('键盘型号预览').selectOption('nuphy-air75-v3');
  await expect(page.getByLabel('Air75 V3 配色预览')).toBeVisible();
  await page.getByLabel('跟随核心状态').check();
  await expect(page.locator('.preview-footer')).toContainText('Thinking');
  expect(errors).toEqual([]);
});
test('a plain browser cannot silently pose as the core', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.save-bar [role=status]')).toContainText('请通过 Tauri 启动应用');
  await expect(page.getByRole('button', { name: '保存配色' })).toBeDisabled();
});

test('invalid drafts stay rejected across status refreshes', async ({ page }) => {
  await page.clock.install();
  await page.goto('/?fixture=1');
  await page.getByLabel('完成色保持秒数').fill('0');
  await page.getByRole('button', { name: '保存配色' }).click();
  const message = page.locator('.save-bar [role=status]');
  await expect(message).toContainText('配色名称、保持时间或颜色无效');
  await page.clock.fastForward(1800);
  await expect(message).toContainText('配色名称、保持时间或颜色无效');
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  await expect(page.getByLabel('完成色保持秒数')).toHaveValue('5');
});
