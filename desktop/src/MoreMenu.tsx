import { useEffect, useId, useRef, useState } from 'react';

export function MoreMenu({
  actions,
  disabled,
}: {
  actions: { id: string; label: string; onSelect: () => void }[];
  disabled: boolean;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const firstFocus = useRef(0);
  const id = useId();
  useEffect(() => {
    const dismiss = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', dismiss);
    return () => document.removeEventListener('pointerdown', dismiss);
  }, []);
  useEffect(() => {
    if (open)
      menu.current
        ?.querySelectorAll<HTMLButtonElement>('[role=menuitem]')
        [firstFocus.current]?.focus();
  }, [open]);
  return (
    <div className="more-menu" ref={root}>
      <button
        type="button"
        className="more-trigger"
        ref={trigger}
        aria-label="更多操作"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        disabled={disabled}
        onClick={() => {
          firstFocus.current = 0;
          setOpen(!open);
        }}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            firstFocus.current = event.key === 'ArrowUp' ? actions.length - 1 : 0;
            if (open)
              menu.current
                ?.querySelectorAll<HTMLButtonElement>('[role=menuitem]')
                [firstFocus.current]?.focus();
            else setOpen(true);
          } else if (event.key === 'Escape') setOpen(false);
        }}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="5" cy="12" r="1.5" />
          <circle cx="12" cy="12" r="1.5" />
          <circle cx="19" cy="12" r="1.5" />
        </svg>
      </button>
      {open && (
        <div
          className="more-options"
          id={id}
          role="menu"
          aria-label="扩展操作"
          ref={menu}
          onKeyDown={(event) => {
            const items = [
              ...(menu.current?.querySelectorAll<HTMLButtonElement>('[role=menuitem]') ?? []),
            ];
            const index = items.indexOf(document.activeElement as HTMLButtonElement);
            if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
              event.preventDefault();
              const next =
                event.key === 'Home'
                  ? 0
                  : event.key === 'End'
                    ? items.length - 1
                    : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
              items[next]?.focus();
            } else if (event.key === 'Escape') {
              event.preventDefault();
              setOpen(false);
              trigger.current?.focus();
            } else if (event.key === 'Tab') setOpen(false);
          }}
        >
          {actions.map((action) => (
            <button
              key={action.id}
              type="button"
              role="menuitem"
              tabIndex={-1}
              onClick={() => {
                setOpen(false);
                trigger.current?.focus();
                action.onSelect();
              }}
            >
              {action.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
