import type { CSSProperties } from 'react';
import kick from '../../assets/keyboard-layouts/nuphy-kick75-io.json';
import type { Signal, Action } from './theme';
// Only actual supported device layouts belong in the runtime catalog.
export const layouts = [kick];
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
  strip,
  action,
}: {
  model: string;
  main: Signal | null;
  strip: Signal | null;
  action?: Action;
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
      className={`keyboard ${reference ? 'reference' : 'example'} effect-${main ? (action?.effect ?? 'solid') : 'solid'}`}
      role="img"
      aria-label={`${layout.name} 灯光预览`}
      onDragStart={(event) => event.preventDefault()}
      style={
        {
          '--effect-duration': `${6 - (action?.speed ?? 3)}s`,
          '--board-ratio': layout.width / layout.height,
          '--key-unit': `${100 / layout.width}cqw`,
          '--light-color': main && main.brightness > 0 ? main.color : '#55575a',
          '--light-opacity': main ? 0.35 + (0.65 * main.brightness) / 100 : 1,
        } as CSSProperties
      }
    >
      {reference && <img className="housing" src="/reference/case.webp" alt="" draggable={false} />}
      {layout.keys.map((raw) => {
        const key = raw as Key;
        const symbol = key.symbol && icons[key.symbol];
        return (
          <div
            className={`key ${key.kind}`}
            key={key.id}
            style={
              {
                ...rect(key),
                '--key-x': key.x / layout.width,
                '--key-y': key.y / layout.height,
                '--key-angle':
                  (Math.atan2(
                    (key.y + key.h / 2) / layout.height - 0.5,
                    (key.x + key.w / 2) / layout.width - 0.5,
                  ) +
                    Math.PI) /
                  (2 * Math.PI),
              } as CSSProperties
            }
            aria-hidden="true"
          >
            {key.kind === 'knob' ? (
              reference ? (
                <img className="knob-image" draggable={false} src="/reference/knob.webp" alt="" />
              ) : (
                <span className="example-knob" />
              )
            ) : (
              <>
                {reference && (
                  <span className="key-wireframe">
                    {['left', 'middle', 'right'].map((part) => (
                      <i
                        key={part}
                        style={{
                          maskImage: `url(/reference/key-${part}.svg)`,
                          WebkitMaskImage: `url(/reference/key-${part}.svg)`,
                        }}
                      />
                    ))}
                  </span>
                )}
                <span className="legend">
                  {reference && symbol ? (
                    <img draggable={false} src={`/reference/${symbol}.svg`} alt="" />
                  ) : (
                    key.label
                  )}
                </span>
              </>
            )}
          </div>
        );
      })}
      {strip &&
        strip.brightness > 0 &&
        layout.lights.map((light) => (
          <span
            key={light.id}
            className="strip-aperture"
            style={{
              ...rect(light),
              backgroundColor: strip.color,
              opacity: strip.brightness / 100,
            }}
          />
        ))}
    </div>
  );
}
