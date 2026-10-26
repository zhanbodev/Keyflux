import { test, expect } from '@playwright/test';
test('compact console, custom menus and independent channel colors', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/?fixture=1');
  await expect(page.getByText('界面测试', { exact: true })).toBeVisible();
  await page.waitForFunction(() =>
    [...document.images].every((image) => image.complete && image.naturalWidth > 0),
  );
  await expect(page.locator('.key')).toHaveCount(81);
  await expect(page.locator('select')).toHaveCount(0);
  await expect(page.locator('.keyboard button,.side-strip,.key-tint')).toHaveCount(0);
  await expect(page.locator('.keyboard')).toHaveCSS('user-select', 'none');
  await expect(page.locator('h1')).toHaveCount(0);
  expect(
    await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight),
  ).toBeTruthy();
  await page.screenshot({ path: 'test-results/console-main.png' });
  await page.getByLabel('红色通道').fill('255');
  await page.getByLabel('绿色通道').fill('34');
  await page.getByLabel('蓝色通道').fill('68');
  await page.getByRole('button', { name: '保存', exact: true }).click();
  await expect(page.locator('.feedback')).toHaveText('配色已保存');
  await expect(page.locator('.keyboard')).toHaveCSS('--light-color', '#FF2244');
  await page.getByRole('button', { name: '条形灯', exact: true }).click();
  await page.getByLabel('启用条形灯').check();
  await page.getByLabel('条形灯配色模式').click();
  await page.getByRole('option', { name: '独立配色', exact: true }).click();
  await page.getByRole('button', { name: '预设颜色 3', exact: true }).click();
  await expect(page.locator('.strip-aperture')).toHaveCSS('background-color', 'rgb(0, 215, 160)');
  await expect(page.locator('.keyboard')).toHaveCSS('--light-color', '#FF2244');
  await page.screenshot({ path: 'test-results/console-strip.png' });
  await page.getByRole('button', { name: '撤销', exact: true }).click();
  await expect(page.getByLabel('启用条形灯')).not.toBeChecked();
  await expect(page.locator('.strip-aperture')).toHaveCount(0);
  await page.getByRole('button', { name: '键盘型号', exact: true }).click();
  await expect(page.getByRole('listbox', { name: '键盘型号' })).toBeVisible();
  await page.getByRole('option', { name: 'Air75 V3 · 布局样例', exact: true }).click();
  await expect(page.getByRole('img', { name: 'Air75 V3 灯光预览' })).toBeVisible();
  await page.getByRole('button', { name: '键盘型号', exact: true }).click();
  await page.getByRole('button', { name: '键盘型号', exact: true }).press('Home');
  await page.getByRole('button', { name: '键盘型号', exact: true }).press('Enter');
  await expect(page.getByRole('img', { name: 'Kick75 IO 灯光预览' })).toBeVisible();
  await page.getByRole('button', { name: '主键区', exact: true }).click();
  await page.getByLabel('跟随状态').check();
  await expect(page.locator('.panel-heading h2')).toHaveText('Thinking');
  await page.getByLabel('红色通道').focus();
  await expect(page.getByLabel('跟随状态')).not.toBeChecked();
  expect(errors).toEqual([]);
});
test('explicit connection, apply and restore UI', async ({ page }) => {
  await page.goto('/?fixture=1');
  await expect(page.getByRole('button', { name: '应用到键盘', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: '连接键盘', exact: true }).click();
  await expect(page.getByRole('button', { name: '断开', exact: true })).toBeEnabled();
  await page.getByRole('button', { name: '应用到键盘', exact: true }).click();
  await expect(page.locator('.feedback')).toHaveText('主灯已应用，回读确认');
  await page.getByRole('button', { name: '恢复灯效', exact: true }).click();
  await expect(page.locator('.feedback')).toHaveText('原灯效已恢复并回读确认');
  await page.getByRole('button', { name: '断开', exact: true }).click();
  await expect(page.getByRole('button', { name: '应用到键盘', exact: true })).toBeDisabled();
});
test('small supported windows keep every control on screen', async ({ page }) => {
  await page.goto('/?fixture=1');
  for (const [width, height] of [
    [900, 650],
    [1120, 750],
    [1280, 850],
  ]) {
    await page.setViewportSize({ width, height });
    await expect(page.getByRole('button', { name: '保存', exact: true })).toBeInViewport();
    await expect(page.getByLabel('亮度', { exact: true })).toBeInViewport();
    await expect(page.getByLabel('完成色保持秒数')).toBeInViewport();
    expect(
      await page.evaluate(
        () =>
          document.documentElement.scrollHeight <= innerHeight &&
          document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBeTruthy();
  }
});
test('plain browser cannot pretend to be connected', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.feedback')).toContainText('请通过 Tauri 启动应用');
  await expect(page.getByRole('button', { name: '连接键盘', exact: true })).toBeDisabled();
});
test('invalid drafts remain rejected across polling', async ({ page }) => {
  await page.clock.install();
  await page.goto('/?fixture=1');
  await page.getByLabel('完成色保持秒数').fill('0');
  await page.getByRole('button', { name: '保存', exact: true }).click();
  await expect(page.locator('.feedback')).toContainText('配色名称、保持时间或颜色无效');
  await page.clock.fastForward(1800);
  await expect(page.locator('.feedback')).toContainText('配色名称、保持时间或颜色无效');
});

test('extension menu keyboard navigation and precise brightness dragging', async ({ page }) => {
  await page.goto('/?fixture=1');
  const more = page.getByRole('button', { name: '更多操作', exact: true });
  await expect(more).toBeEnabled();
  await more.focus();
  await more.press('ArrowDown');
  await expect(page.getByRole('menuitem', { name: '导入配色' })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('menuitem', { name: '导出配色' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(more).toBeFocused();
  await more.click();
  await page.screenshot({ path: 'test-results/extension-menu.png' });
  await page.locator('.panel-heading h2').click();
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(page.locator('.zone-nav')).not.toContainText('导入配色');

  const slider = page.getByRole('slider', { name: '亮度', exact: true });
  const bounds = await slider.boundingBox();
  if (!bounds) throw new Error('Brightness control missing');
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  await page.mouse.down();
  await page.mouse.move(bounds.x + bounds.width * 0.8, bounds.y + bounds.height / 2, { steps: 12 });
  const dragged = Number(await slider.inputValue());
  expect(dragged).toBeGreaterThan(75);
  expect(dragged).toBeLessThan(85);
  await expect(page.locator('.brightness-tooltip')).toHaveText(`${dragged}%`);
  await page.screenshot({ path: 'test-results/brightness-drag.png' });
  await page.mouse.up();
  await expect(page.locator('.brightness-tooltip')).toHaveCount(0);
  await slider.press('Home');
  await expect(slider).toHaveValue('0');
  await slider.press('End');
  await expect(slider).toHaveValue('100');
  await slider.press('ArrowLeft');
  await expect(slider).toHaveValue('99');
  await slider.blur();
  await expect(page.locator('.brightness-tooltip')).toHaveCount(0);
});
