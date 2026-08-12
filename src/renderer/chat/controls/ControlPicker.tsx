import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import type { ControlOption, ControlReading } from './catalog'
import { isCurrent, sourceNote } from './catalog'

interface Props {
  /** The short name on the button, e.g. "Model". */
  name: string
  reading: ControlReading | undefined
  options: ControlOption[]
  /** Printed at the foot of the menu: how far a change reaches. */
  reach: string
  busy: boolean
  disabled: boolean
  /** Why the control cannot be used, when that is known. Shown instead of the menu. */
  blocked: string | null
  onPick: (optionId: string) => void
}

/**
 * One control: a button showing the value that was actually read, and a menu.
 *
 * The button never shows a value this app has not read from somewhere real —
 * `displayValue` returns "Unknown" instead — and the caption underneath names
 * the source, so "Opus 5" read from the last reply and "Opus 5" assumed from a
 * settings file are never confused for each other.
 */
export function ControlPicker({ name, reading, options, reach, busy, disabled, blocked, onPick }: Props) {
  const [open, setOpen] = useState(false)
  const [above, setAbove] = useState(true)
  const rootRef = useRef<HTMLDivElement>(null)
  const menuId = useId()

  // Close on an outside click or Escape. Both are needed: a popover that only
  // closes on Escape traps the pointer, and one that only closes on click
  // ignores the keyboard.
  useEffect(() => {
    if (!open) return
    const onDown = (event: MouseEvent): void => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  // The row sits at the bottom of the pane, so the menu opens upward — unless
  // there is no room above, which happens in a short pane.
  useLayoutEffect(() => {
    if (!open) return
    const box = rootRef.current?.getBoundingClientRect()
    if (box) setAbove(box.top > window.innerHeight - box.bottom)
  }, [open])

  const value = reading && reading.label !== null ? reading.label : 'Unknown'
  const unknown = !reading || reading.label === null
  const note = sourceNote(reading?.source ?? null)

  return (
    <div className="ac-picker" ref={rootRef}>
      <button
        type="button"
        className="ac-button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        disabled={disabled || busy}
        title={blocked ?? `${name}: ${value} — ${note}`}
        onClick={() => setOpen((was) => !was)}
      >
        <span className="ac-name">{name}</span>
        <span className={unknown ? 'ac-value ac-value-unknown' : 'ac-value'}>{busy ? 'Working…' : value}</span>
        <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
          <path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </svg>
      </button>

      {open ? (
        <div className={above ? 'ac-menu ac-menu-above' : 'ac-menu'} id={menuId} role="menu">
          {blocked ? (
            <p className="ac-blocked">{blocked}</p>
          ) : (
            options.map((option) => {
              const current = isCurrent(reading, option)
              return (
                <button
                  key={option.id}
                  type="button"
                  role="menuitemradio"
                  aria-checked={current}
                  className={current ? 'ac-item ac-item-current' : 'ac-item'}
                  onClick={() => {
                    setOpen(false)
                    onPick(option.id)
                  }}
                >
                  <span className="ac-tick" aria-hidden="true">
                    {current ? '✓' : ''}
                  </span>
                  <span className="ac-item-text">
                    <span className="ac-item-label">{option.label}</span>
                    {option.hint ? <span className="ac-item-hint">{option.hint}</span> : null}
                  </span>
                </button>
              )
            })
          )}
          <p className="ac-reach">
            <span className="ac-reach-now">Now: {value}</span>
            <span className="ac-reach-source">{note}</span>
            <span className="ac-reach-scope">{reach}</span>
          </p>
        </div>
      ) : null}
    </div>
  )
}
