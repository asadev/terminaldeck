import { Fragment } from 'react'
import { HoverNote } from '../../components/HoverNote'
import type { ControlId, ControlOption, ControlReading } from './catalog'
import { controlName, controlNote, displayValue, isCurrent, reachOf, sourceNote, unreadNote } from './catalog'
import { ControlToggle } from './ControlToggle'

interface Props {
  control: ControlId
  reading: ControlReading | undefined
  options: ControlOption[]
  busy: boolean
  /** True while a *different* control is being applied. */
  disabled: boolean
  /**
   * Why the control cannot be used, when that is known.
   *
   * It used to *replace* the options with itself, printed as a paragraph. It
   * does neither now: the rows stay, drawn and locked, and the reason is behind
   * the ⓘ beside the heading. See the note on the component.
   */
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
 * A control as a titled block of options, for the folded controls sheet.
 *
 * The same job `ControlPicker` does on the bar, drawn the other way round. On
 * the bar there is room for a value and a caret, so the options hide in a menu;
 * in the sheet there is room for the options, so nothing hides at all — one
 * click changes the setting instead of two.
 *
 * ## Every sentence this used to print is gone
 *
 * The sheet is what the toolbar becomes below about nine hundred pixels, which
 * is a normal window, and it was printing four blocks of prose: a description
 * under each heading, a repeated two-line refusal, and a two-line foot naming
 * where each value was read from and how far a change reaches. Asad, on
 * 2026-08-20, and he said it more times than he said anything else:
 *
 *   > *"don't put any single statement in anywhere. Everywhere you are putting a
 *   > lot of statements. We don't need to give the statements. We want
 *   > simplicity. Let the smart people use it. Smart people knows how it
 *   > works."*
 *
 * and, on where an explanation may live when one is genuinely needed:
 *
 *   > *"if somewhere it's very required, give the i icon like other ones,
 *   > information icon in the settings, same way."*
 *
 * So a section is now a heading, its rows, and nothing else. What was in those
 * four blocks went to one of three places, and none of them costs a line:
 *
 *  - **The refusal** and the *"nothing has been read yet"* note are the ⓘ beside
 *    the heading — the same `HoverNote` dot every Settings pane wears, which is
 *    the control he named. It appears only where there is something to say, so
 *    an ordinary working section carries no dot at all.
 *  - **The description** is behind that dot for one control and deleted for the
 *    rest; {@link controlNote} is where that is decided and argued.
 *  - **The provenance** — *"read from this session"*, *"from Claude settings"* —
 *    is the section's `title`, in exactly the words and the order the bar's own
 *    chip already uses for the same control, so the two cannot drift. `ub-cx`
 *    in `UsageBar.tsx` moved its unreadable lines to a `title` in the same pass
 *    and for the same reason.
 *
 * The reach — *"This session — and your default too, if the CLI says so when it
 * confirms"* — is not moved anywhere, and that matches what `ControlPicker`
 * already did when it deleted its own foot: the CLI states the arm it actually
 * took at the moment it confirms, and `applyControl` quotes it into the notice
 * under the bar. A warning before the press became a report after it.
 */
export function ControlSection({
  control,
  reading,
  options,
  busy,
  disabled,
  blocked,
  toggle = false,
  onPick,
}: Props) {
  const value = displayValue(reading, control)
  const unknown = !reading || reading.label === null
  const name = controlName(control)
  /*
   * What the ⓘ carries, or `null` for no dot.
   *
   * Ordered by urgency, which is also the order a reader would ask in: why can
   * I not use this, then why is nothing selected, then what does this do. Only
   * the first two are ever true of a working session, and the third is true of
   * exactly one control — so most sections, most of the time, draw a bare
   * heading, which is the whole point of the change.
   */
  const dotNote = blocked ?? (unknown ? unreadNote(control) : null) ?? controlNote(control)
  /*
   * The hover label, built the way `ControlPicker` builds the bar chip's: name,
   * value, and where the value came from. One expression in two components
   * rather than two spellings of one sentence, because the sheet and the bar
   * are two presentations of the same reading and a reader who checks both must
   * not be told two different things.
   */
  const sourced = unknown ? sourceNote(null) : sourceNote(reading.source)
  const provenance = blocked ?? `${name}: ${busy ? 'Working…' : value} — ${sourced}`
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
  /*
   * Locked, and the three reasons are not the same kind of thing.
   *
   * `disabled` is another control mid-change, `busy` is this one mid-change,
   * and `blocked` is a refusal that may outlast both. They are one expression
   * here because a row cannot be half-pressable, and because the *reason* is no
   * longer carried by the rows at all — it is on the dot, which is what let the
   * refusal stop deleting the control it refuses.
   */
  const locked = disabled || busy || blocked !== null

  return (
    <section className="ac-section" title={provenance}>
      {/*
        The heading and, only where there is something behind it, the dot.

        One line rather than a heading with a paragraph under it. The dot sits
        after the name and not at the end of the row on purpose: at the end it
        reads as belonging to the section's right edge — to a value, or to the
        rows — and what it is about is the control the name just gave.
      */}
      <div className="ac-section-head">
        <h4 className="ac-section-name">{name}</h4>
        {dotNote === null ? null : <HoverNote label={name}>{dotNote}</HoverNote>}
      </div>

      {/*
        A two-state control in a panel, and the two states it cannot draw as a
        switch.

        The switch itself is `ControlToggle`, without its name — the `<h4>` above
        is the name, and printing it again six pixels lower is the
        same-fact-twice this cluster has already been reported for.

        It is not drawn when the position was never read, because a knob is a
        claim about where something is; and it is not drawn when the control is
        refused, because a switch is a promise that pressing it changes
        something. Both fall through to the radiogroup below, which is the same
        set of rows either way — locked when refused, live when merely unread.

        The unread case used to be a sentence *instead of* the rows: on any
        session whose screen had not been parsed yet, the sheet's fast-mode
        section was a paragraph while model and effort above it were working
        lists. Both ids are sendable whatever has been read — `applyControl`
        types `/fast on` and reads the screen afterwards — so the rows were
        always the honest answer, and now they are the only one. The whole of
        the argument, and the matching repair on the bar, is in
        `ControlToggle.tsx`.
      */}
      {toggle && !unreadValue && blocked === null ? (
        <div className="ac-section-toggle">
          <ControlToggle
            control={control}
            name={null}
            reading={reading}
            options={options}
            /* Read here rather than taken as a prop, which is one fewer thing
               the sheet has to remember to pass. It reaches no pixel either way
               — the switch spends it in its hover label, which is where the
               reach lives now that no foot prints it. */
            reach={reachOf(control)}
            busy={busy}
            disabled={disabled}
            blocked={null}
            onPick={onPick}
          />
        </div>
      ) : (
        <div className="ac-options" role="radiogroup" aria-label={name} aria-disabled={blocked === null ? undefined : true}>
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
                  disabled={locked}
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
      )}

      {/*
        One word, for the second the command is in flight.

        All that is left of a foot that printed three lines under every section:
        `Now: …` (the same fact as the tick six rows above), the source note (now
        the section's `title`) and the reach (now the CLI's own confirmation,
        quoted into the notice). This is not a statement about anything — it is
        the state of a press, and without it a press on a locked-looking list
        reads as ignored until the reply lands.
      */}
      {busy ? (
        <p className="ac-reach">
          <span className="ac-reach-now">Working…</span>
        </p>
      ) : null}
    </section>
  )
}
