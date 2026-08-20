import { Fragment } from 'react'
import type { ControlId, ControlOption, ControlReading } from './catalog'
import { controlName, describeControl, displayValue, isCurrent, sourceNote, unreadNote } from './catalog'
import { ControlToggle, toggleUnreadNote } from './ControlToggle'

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
  /**
   * Draw the two options as one switch instead of as a radiogroup.
   *
   * True for fast mode and for nothing else, because fast mode is the only
   * control here whose answer set has two members — *"then here also now think
   * we don't need, just one to select is enough."* The whole argument is in
   * `ControlToggle.tsx`; what is decided *here* is only which of the two
   * presentations the panel uses, and it is a prop rather than a lookup on
   * `control` so that this component does not grow a second opinion about which
   * controls are two-state. `SessionControls` already knows, because it is the
   * thing that chose a toggle over a picker on the row.
   */
  toggle?: boolean
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
export function ControlSection({
  control,
  reading,
  options,
  reach,
  busy,
  disabled,
  blocked,
  toggle = false,
  onPick,
}: Props) {
  const value = displayValue(reading, control)
  const unknown = !reading || reading.label === null
  const note = unknown ? (unreadNote(control) ?? sourceNote(null)) : sourceNote(reading.source)
  const name = controlName(control)
  /*
   * Whether a *switch* has a position to draw, which is a narrower question
   * than `unknown` above.
   *
   * `unknown` asks whether there is a label to print. This asks whether the
   * value that came back is one of the two this control offers — because a
   * switch flipped to "the other one" needs to know which one it is on now, and
   * a reading of, say, `off` from a control whose options are `plan`/`auto`
   * would put the knob somewhere neither option means. It costs nothing and it
   * cannot be got wrong later by somebody widening what `unknown` covers.
   */
  const unreadValue = !options.some((option) => option.id === reading?.value)

  return (
    <section className="ac-section">
      <h4 className="ac-section-name">{name}</h4>
      <p className="ac-section-desc">{describeControl(control)}</p>

      {blocked ? (
        <p className="ac-blocked">{blocked}</p>
      ) : /*
           A two-state control in a panel, and the one state it cannot draw as a
           switch.

           The switch itself is `ControlToggle`, without its name — the `<h4>`
           above is the name, and printing it again six pixels lower is the
           same-fact-twice this cluster has already been reported for.

           The *unread* state is drawn here rather than delegated, and that is
           the one place these two surfaces deliberately differ. On the bar the
           sentence hides behind the chip in a popover; this panel scrolls
           (`.sc-sheet` wears `scroll-fade`), so an absolutely-positioned popover
           opened from inside it would be clipped by the very thing it is drawn
           in. A panel has room for the sentence, which is the whole reason this
           component exists instead of a second row of pickers — so it prints it.

           What it prints *under* the sentence is the ordinary radiogroup, and
           that is a repair. This branch used to be the sentence alone: a
           heading, a description, a paragraph saying nothing had been read, and
           nothing at all to press — so on any session whose screen had not been
           read yet, the panel's fast-mode section was a wall of prose while
           model and effort above it were fully working lists. Nothing justified
           that. The two ids are sendable whatever has been read (`applyControl`
           types `/fast on` and reads the screen afterwards; `pick` in
           `useSessionControls.ts` never looks at a reading at all), and the
           rows below are the same rows this component already knows how to
           draw. The whole of the argument, and the matching repair on the bar,
           is in `ControlToggle.tsx`.

           So the sentence explains why there is no *switch*, and the rows are
           what there is instead — which is exactly the shape a `ControlPicker`
           had here before the switch replaced it.
         */
      toggle && !unreadValue ? (
        <div className="ac-section-toggle">
          <ControlToggle
            control={control}
            name={null}
            reading={reading}
            options={options}
            reach={reach}
            busy={busy}
            disabled={disabled}
            blocked={null}
            onPick={onPick}
          />
        </div>
      ) : (
        <>
          {toggle ? <p className="ac-unread-note">{toggleUnreadNote(control)}</p> : null}
          <div className="ac-options" role="radiogroup" aria-label={name}>
            {options.map((option) => {
              const current = isCurrent(reading, option)
              return (
                <Fragment key={option.id}>
                  {/* A caption only where the rows below it are a different kind
                      of claim from the rows above — see `ControlOption.group`.
                      It sits inside the radiogroup as a presentational row rather
                      than outside it, because splitting the group into two would
                      mean two sets of arrow-key navigation for one control. */}
                  {option.group ? (
                    <p className="ac-option-group" role="presentation">
                      {option.group}
                    </p>
                  ) : null}
                  <button
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
                </Fragment>
              )
            })}
          </div>
        </>
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
