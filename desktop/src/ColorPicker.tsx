import { useEffect, useState, type PointerEvent } from 'react';
import { fromHSV, hex, rgb, toHSV } from './color';
const presets = [
  '#FF6B16',
  '#FFE600',
  '#00D7A0',
  '#009DFF',
  '#8270F2',
  '#F22991',
  '#FF2638',
  '#FFC000',
  '#00D5EB',
  '#20DF38',
  '#3523F9',
  '#E525ED',
];
function readRecent(): string[] {
  try {
    return JSON.parse(localStorage.getItem('keyflux.recent-colors.v1') ?? '[]')
      .filter((s: unknown) => typeof s === 'string' && /^#[\dA-F]{6}$/.test(s))
      .slice(0, 8);
  } catch {
    return [];
  }
}
export function ColorPicker({
  value,
  disabled,
  onChange,
  onBegin,
}: {
  value: string;
  disabled: boolean;
  onChange: (color: string) => void;
  onBegin: () => void;
}) {
  const hsv = toHSV(value),
    channels = rgb(value);
  const [hue, setHue] = useState(hsv.h);
  const [recent, setRecent] = useState<string[]>(readRecent);
  useEffect(() => {
    if (hsv.s > 0) setHue(hsv.h);
  }, [hsv.h, hsv.s]);
  const remember = (color: string) => {
    const next = [color, ...readRecent().filter((c) => c !== color)].slice(0, 8);
    setRecent(next);
    try {
      localStorage.setItem('keyflux.recent-colors.v1', JSON.stringify(next));
    } catch {}
  };
  const move = (event: PointerEvent<HTMLDivElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    onChange(
      fromHSV({
        h: hue,
        s: Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)),
        v: Math.max(0, Math.min(1, 1 - (event.clientY - box.top) / box.height)),
      }),
    );
  };
  return (
    <fieldset className="color-picker" disabled={disabled} onFocusCapture={onBegin}>
      <div className="color-spectrum">
        <div
          className="sv-plane"
          role="slider"
          tabIndex={disabled ? -1 : 0}
          aria-label="饱和度与明度"
          aria-disabled={disabled}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={Math.round(hsv.v * 100)}
          aria-valuetext={`饱和度 ${Math.round(hsv.s * 100)}%，明度 ${Math.round(hsv.v * 100)}%`}
          style={{ backgroundColor: fromHSV({ h: hue, s: 1, v: 1 }) }}
          onPointerDown={(event) => {
            if (disabled) return;
            onBegin();
            event.currentTarget.focus();
            event.currentTarget.setPointerCapture(event.pointerId);
            move(event);
          }}
          onPointerMove={(event) => {
            if (!disabled && event.currentTarget.hasPointerCapture(event.pointerId)) move(event);
          }}
          onPointerUp={(event) => {
            if (!disabled && event.currentTarget.hasPointerCapture(event.pointerId)) {
              event.currentTarget.releasePointerCapture(event.pointerId);
              remember(value);
            }
          }}
          onKeyDown={(event) => {
            if (
              disabled ||
              !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)
            )
              return;
            event.preventDefault();
            onBegin();
            const step = event.shiftKey ? 0.1 : 0.01;
            onChange(
              fromHSV({
                h: hue,
                s: Math.max(
                  0,
                  Math.min(
                    1,
                    hsv.s +
                      (event.key === 'ArrowRight' ? step : event.key === 'ArrowLeft' ? -step : 0),
                  ),
                ),
                v: Math.max(
                  0,
                  Math.min(
                    1,
                    hsv.v +
                      (event.key === 'ArrowUp' ? step : event.key === 'ArrowDown' ? -step : 0),
                  ),
                ),
              }),
            );
          }}
        >
          <i
            className="sv-thumb"
            style={{ left: `${hsv.s * 100}%`, top: `${(1 - hsv.v) * 100}%` }}
          />
        </div>
        <input
          className="hue-rail"
          aria-label="色相"
          type="range"
          min="0"
          max="359"
          value={hue}
          onChange={(event) => {
            const h = Number(event.target.value);
            setHue(h);
            onChange(fromHSV({ ...hsv, h }));
          }}
          onPointerUp={() => remember(value)}
        />
      </div>
      <div className="color-options">
        <div className="color-presets" aria-label="颜色预设">
          {presets.map((color, index) => (
            <button
              type="button"
              key={color}
              aria-label={`预设颜色 ${index + 1}`}
              aria-pressed={color === value}
              style={{ backgroundColor: color }}
              onClick={() => {
                onChange(color);
                remember(color);
              }}
            />
          ))}
        </div>
        <div className="rgb-inputs">
          <span className="current-swatch" style={{ backgroundColor: value }} aria-hidden="true" />
          {channels.map((channel, index) => (
            <label key={index}>
              {['R', 'G', 'B'][index]}
              <input
                type="number"
                min="0"
                max="255"
                aria-label={['红色通道', '绿色通道', '蓝色通道'][index]}
                value={channel}
                onChange={(event) => {
                  if (Number.isFinite(event.target.valueAsNumber)) {
                    const next = [...channels];
                    next[index] = event.target.valueAsNumber;
                    onChange(hex(next));
                  }
                }}
                onBlur={() => remember(value)}
              />
            </label>
          ))}
        </div>
        <div className="recent-colors">
          <span>最近</span>
          {recent.length ? (
            recent.map((color) => (
              <button
                key={color}
                type="button"
                aria-label={`最近颜色 RGB ${rgb(color).join(' ')}`}
                style={{ backgroundColor: color }}
                onClick={() => onChange(color)}
              />
            ))
          ) : (
            <span className="empty-recent">暂无</span>
          )}
        </div>
      </div>
    </fieldset>
  );
}
