import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import type { ControlId, ControlOption, ControlReading } from './catalog'
import { displayValue, isCurrent, sourceNote, unreadNote } from './catalog'

interface Props {
  /** Which control this is. Decides what it says when it cannot read a value. */
  control: ControlId
  /** The short name on the button, e.g. "Model". */
  name: string
  reading: ControlReading | undefined
  options: ControlOption[]
  /** Printed at the foot of the menu: how far a change reaches, or null when
   *  that is not something this app has any grounds to state. */
  reach: string | null
  busy: boolean
  disabled: boolean
  /** Why the control cannot be used, when that is known. Shown instead of the menu. */
  blocked: string | null
  onPick: (optionId: string) => void
}

/**
 * One control on the composer: a button showing the value that was actually
 * read, and a menu.
 *
 * The button never shows a value this app has not read from somewhere real —
 * `displayValue` says so instead — and the caption underneath names the source,
 * so "Opus 5" read from the last reply and "Opus 5" assumed from a settings
 * file are never confused for each other.
 *
 * It wears `cc-chip`, the shape every labelled control inside the chat box
 * wears — the plus, the model, the permission mode and the "More" button are
 * all one family, because they sit on one row and a family of one-offs is what
 * made that row look like a control panel.
 *
 * An unread control also gets to say *why* where there is a real reason. Fast
 * mode is the only one that has one, and it is permanent rather than a hiccup —
 * see `unreadLabel` in `catalog.ts`. Printing "Unknown" beside three siblings
 * that always resolve made a working control look broken.
 */
export function ControlPicker({ control, name, reading, options, reach, busy, disabled, blocked, onPick }: Props) {
  const [open, setOpen] = useState(false)
  const [above, setAbove] = useState(true)
  const rootRef = useRef<HTMLDivElement>(null)
  const menuId = useId()
  const close = useCallback(() => setOpen(false), [])

  /*
   * Opening this shuts every other menu in the window, and this is the picker
   * that made the rule necessary. It sits *inside* `.agent-controls`, which is
   * the element the Options panel measures its own outside-clicks against — so
   * pressing Model or Permission with that panel open was a click inside the
   * panel, the panel stayed, and this menu opened over the top of it. That is
   * the overlap in the recording. See `one-menu.ts`.
   */
  useOneMenu(open, close)

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

  const value = displayValue(reading, control)
  const unknown = !reading || reading.label === null
  const note = unknown ? (unreadNote(control) ?? sourceNote(null)) : sourceNote(reading.source)

  return (
    <div className="ac-picker" ref={rootRef}>
      <button
        type="button"
        className="cc-chip"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        disabled={disabled || busy}
        /*
         * Unavailable, but still hoverable and still pressable.
         *
         * `disabled` is the wrong attribute for a control that has a *reason*,
         * and the reason is a hard fact about the platform rather than a
         * preference: a disabled button receives no pointer events, so the
         * window's own tooltip layer — which listens on the document and is
         * what draws every hover label in this app (see `Tooltips.tsx`) —
         * never hears about it, and the sentence explaining why the control
         * cannot act is unreachable. A greyed chip that explains nothing when
         * you hover it and does nothing when you press it is the dead control
         * this repository is audited for, wearing a disabled attribute as an
         * alibi.
         *
         * So a blocked chip is announced disabled to assistive technology,
         * drawn back by `[data-blocked]`, and still opens — onto the reason,
         * in place of the options, which is the only thing there is to say.
         * `disabled` is kept for the states with nothing to explain: a
         * different control mid-change, and this one mid-change.
         */
        aria-disabled={blocked !== null ? true : undefined}
        data-blocked={blocked !== null ? '' : undefined}
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
            {reach ? <span className="ac-reach-scope">{reach}</span> : null}
          </p>
        </div>
      ) : null}
    </div>
  )
}
