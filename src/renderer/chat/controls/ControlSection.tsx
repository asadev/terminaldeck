import type { ControlId, ControlOption, ControlReading } from './catalog'
import { controlName, describeControl, displayValue, isCurrent, sourceNote, unreadNote } from './catalog'

interface Props {
  control: ControlId
  reading: ControlReading | undefined
  options: ControlOption[]
  /** How far a change reaches, or null where this app has no grounds to say. */
  reach: string | null
  busy: boolean
  /** True while a *different* control is being applied. */
  disabled: boolean
  /** Why the control cannot be used, when that is known. Replaces the options. */
  blocked: string | null
  onPick: (optionId: string) => void
}

/**
 * A control as a titled block of options, for the panel behind "More".
 *
 * The same job `ControlPicker` does on the composer itself, drawn the other way
 * round. On the composer there is room for a value and a caret, so the options
 * hide in a menu; in the panel there is room for the options, so nothing hides
 * at all — one click changes the setting instead of two.
 *
 * Title bright, description dim, air around both: the treatment the settings
 * window uses for the same kind of thing, so a person who has read one screen
 * of this app can read this one. The foot repeats the value and names where it
 * was read from, because a list of options with a tick on one of them says
 * *what* is in force and not *how we know* — and those two have been confused
 * here before, which is why `sourceNote` exists at all.
 */
export function ControlSection({ control, reading, options, reach, busy, disabled, blocked, onPick }: Props) {
  const value = displayValue(reading, control)
  const unknown = !reading || reading.label === null
  const note = unknown ? (unreadNote(control) ?? sourceNote(null)) : sourceNote(reading.source)
  const name = controlName(control)

  return (
    <section className="ac-section">
      <h4 className="ac-section-name">{name}</h4>
      <p className="ac-section-desc">{describeControl(control)}</p>

      {blocked ? (
        <p className="ac-blocked">{blocked}</p>
      ) : (
        <div className="ac-options" role="radiogroup" aria-label={name}>
          {options.map((option) => {
            const current = isCurrent(reading, option)
            return (
              <button
                key={option.id}
                type="button"
                role="radio"
                aria-checked={current}
                className={current ? 'ac-option ac-option-current' : 'ac-option'}
                disabled={disabled || busy}
                onClick={() => onPick(option.id)}
              >
                <span className="ac-tick" aria-hidden="true">
                  {current ? '✓' : ''}
                </span>
                <span className="ac-option-text">
                  <span className="ac-option-label">{option.label}</span>
                  {option.hint ? <span className="ac-option-hint">{option.hint}</span> : null}
                </span>
              </button>
            )
          })}
        </div>
      )}

      <p className="ac-reach">
        {/* The value gets a line of its own only when no option carries the
            tick. With a tick on screen, "Now: Extra high" directly under it is
            the same fact twice — and three lines of foot under every section
            was most of what made this panel long enough to need scrolling. */}
        {busy ? (
          <span className="ac-reach-now">Working…</span>
        ) : unknown ? (
          <span className="ac-reach-now">Now: {value}</span>
        ) : null}
        <span className="ac-reach-source">{note}</span>
        {reach ? <span className="ac-reach-scope">{reach}</span> : null}
      </p>
    </section>
  )
}
