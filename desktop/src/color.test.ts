import { expect, it } from 'vitest';
import { fromHSV, hex, rgb, toHSV } from './color';
it('RGB and HSV round trips preserve primary, grayscale and arbitrary colors', () => {
  for (const color of [
    '#FF0000',
    '#00FF00',
    '#0000FF',
    '#000000',
    '#FFFFFF',
    '#808080',
    '#3B82F6',
    '#123456',
    '#00D7A0',
  ])
    expect(fromHSV(toHSV(color))).toBe(color);
});
it('RGB fields clamp to byte boundaries', () => {
  expect(hex([-1, 256, 45.6])).toBe('#00FF2E');
  expect(rgb('#123456')).toEqual([18, 52, 86]);
});
