import type { CSSProperties } from 'react';
import kick from '../../assets/keyboard-layouts/nuphy-kick75-io.json';
import air from '../../assets/keyboard-layouts/nuphy-air75-v3.json';
import { tint, type Signal } from './theme';
export const layouts = [kick, air];
type Key = (typeof kick.keys)[number];
const icons: Record<string, string> = {
  'rectangle.3.group': 'missioncontrol',
  magnifyingglass: 'search',
  mic: 'siri',
  'moon.zzz': 'macdnd',
  'backward.end': 'mediaKeys_keyIcon6',
  playpause: 'mediaKeys_keyIcon4',
  'forward.end': 'mediaKeys_keyIcon7',
  'speaker.slash': 'mediaKeys_keyIcon3',
  'speaker.wave.2': 'mediaKeys_keyIcon1',
  'speaker.wave.1': 'mediaKeys_keyIcon2',
};
export function KeyboardPreview({
  model,
  main,
  side,
  zone,
  onZone,
}: {
  model: string;
  main: Signal | null;
  side: Signal | null;
  zone: string;
  onZone: (zone: 'main' | 'side') => void;
}) {
  const layout = layouts.find((l) => l.id === model) ?? kick;
  const reference = layout.id === kick.id;
  const rect = (key: { x: number; y: number; w: number; h: number }): CSSProperties => ({
    left: `${(key.x / layout.width) * 100}%`,
    top: `${(key.y / layout.height) * 100}%`,
    width: `${(key.w / layout.width) * 100}%`,
    height: `${(key.h / layout.height) * 100}%`,
  });
  return (
    <div
      className={`keyboard ${reference ? 'reference' : 'example'}`}
      style={
        {
          aspectRatio: `${layout.width}/${layout.height}`,
          '--key-unit': `${100 / layout.width}cqw`,
        } as CSSProperties
      }
      aria-label={`${layout.name} 配色预览`}
    >
      {reference && <img className="housing" src="/reference/case.webp" alt="" draggable={false} />}
      {layout.keys.map((raw) => {
        const key = raw as Key;
        const symbol = key.symbol && icons[key.symbol];
        return (
          <button
            key={key.id}
            type="button"
            className={`key ${key.kind}`}
            style={rect(key)}
            aria-label={`${key.label || key.symbol || '旋钮'}，编辑主键区颜色`}
            onClick={() => onZone('main')}
          >
            {key.kind === 'knob' ? (
              reference ? (
                <img className="knob-image" src="/reference/knob.webp" alt="" />
              ) : (
                <span className="example-knob" />
              )
            ) : (
              <>
                <span className="key-tint" style={{ backgroundColor: tint(main) }} />
                {reference && (
                  <span className="key-wireframe">
                    <img src="/reference/key-left.svg" alt="" />
                    <img src="/reference/key-middle.svg" alt="" />
                    <img src="/reference/key-right.svg" alt="" />
                  </span>
                )}
                <span className="legend">
                  {reference && symbol ? (
                    <img src={`/reference/${symbol}.svg`} alt="" />
                  ) : (
                    key.label
                  )}
                </span>
              </>
            )}
          </button>
        );
      })}
      {layout.lights.map((light) => (
        <button
          key={light.id}
          type="button"
          className={`side-strip ${zone === 'side' ? 'selected' : ''}`}
          style={{
            ...rect(light),
            backgroundColor: side ? side.color : '#bec3c7',
            opacity: side ? 0.25 + (side.brightness / 100) * 0.75 : 0.35,
          }}
          onClick={() => onZone('side')}
          aria-label={`编辑${light.id === 'left' ? '左' : '右'}侧灯条颜色`}
        />
      ))}
    </div>
  );
}
