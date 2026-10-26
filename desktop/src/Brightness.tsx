import { useEffect, useId, useState, type CSSProperties } from 'react';

export function Brightness({
  value,
  disabled,
  onBegin,
  onChange,
}: {
  value: number;
  disabled: boolean;
  onBegin: () => void;
  onChange: (value: number) => void;
}) {
  const [dragging, setDragging] = useState(false);
  const [focused, setFocused] = useState(false);
  const id = useId();
  useEffect(() => {
    if (!dragging) return;
    const stop = () => setDragging(false);
    window.addEventListener('pointerup', stop);
    window.addEventListener('pointercancel', stop);
    window.addEventListener('blur', stop);
    return () => {
      window.removeEventListener('pointerup', stop);
      window.removeEventListener('pointercancel', stop);
      window.removeEventListener('blur', stop);
    };
  }, [dragging]);
  return (
    <div
      className={`brightness ${dragging ? 'dragging' : ''} ${focused ? 'focused' : ''} ${disabled ? 'disabled' : ''}`}
      style={{ '--brightness': `${value}%`, '--brightness-ratio': value / 100 } as CSSProperties}
    >
      <label htmlFor={id} className="brightness-label">
        <svg width="15" height="15" viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="12" cy="12" r="3.5" />
          <path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" />
        </svg>
        亮度
      </label>
      <div className="brightness-rail">
        <input
          id={id}
          aria-label="亮度"
          type="range"
          min="0"
          max="100"
          step="1"
          value={value}
          disabled={disabled}
          aria-valuetext={`${value}%`}
          onFocus={(event) => {
            setFocused(event.currentTarget.matches(':focus-visible'));
            onBegin();
          }}
          onBlur={() => setFocused(false)}
          onKeyDown={() => setFocused(true)}
          onPointerDown={() => {
            setFocused(false);
            setDragging(true);
            onBegin();
          }}
          onChange={(event) => onChange(Number(event.target.value))}
        />
        {!disabled && (dragging || focused) && (
          <span className="brightness-tooltip" aria-hidden="true">
            {value}%
          </span>
        )}
      </div>
      <output htmlFor={id}>
        {value}
        <span>%</span>
      </output>
    </div>
  );
}
