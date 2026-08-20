import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import { menuSide, type MenuSide } from './menu-side'
import type { ControlId, ControlOption, ControlReading } from './catalog'
import { controlName, displayValue, isCurrent, sourceNote } from './catalog'

/**
 * A control with exactly two states, drawn as the one control it is.
 *
 * ## What this replaces, and why a menu was the wrong shape
 *
 * Fast mode was a `ControlPicker` over a two-row list — `Off`, `On` — and Asad
 * said what is wrong with that watching the bar:
 *
 *   > *"then here also now think we don't need, just one to select is enough."*
 *
 * A picker asks a question whose answer set has two members, one of which is
 * already in force. That is two clicks to do a one-click thing, and it spends
 * one of its two rows telling you what you are already doing. Every other
 * control in the cluster earns its menu — the model has eleven rows, effort has
 * seven, and neither has a natural "other one" to flip to. This one does.
 *
 * It is deliberately *not* the `Switch` in `settings/controls.tsx`. That is a
 * settings-row control: a `<label>` wrapping a checkbox, styled by
 * `SettingsWindow.css`, which the shell does not load, and sized for a form
 * rather than for a toolbar. What belongs on this bar is a chip — the same
 * `cc-chip` shape the model and effort chips beside it wear, so the row stays
 * one family — with the switch drawn inside it. Reusing the settings component
 * would have meant importing a second stylesheet into the chrome to get a
 * control of the wrong size.
 *
 * ## Three states, and only one of them is a switch
 *
 * The hard part of a toggle is not the on and the off. It is that this app reads
 * its values off somebody else's screen, so there is a third answer — *nothing
 * said* — and a switch has no position for it. Drawing the knob to the left when
 * the truth is "we have not been told" is exactly the confident-looking
 * falsehood this whole cluster was rebuilt to remove; `displayValue`'s own note
 * says it in as many words, *"a control showing a confident value it never read
 * is the failure mode this feature exists to avoid."*
 *
 * So:
 *
 *  - **A value was read.** `role="switch"`, `aria-checked` from the reading, and
 *    a press sends the other one. This is the ordinary case for fast mode: the
 *    CLI leaves a `↯` in the status rule for as long as it is on, so
 *    `readFastIndicator` answers off any frame — see `src/main/agent-controls.ts`.
 *  - **The control cannot act**, because there is no bridge, because the session
 *    runs a CLI this build has not been shown, because the account is barred, or
 *    because the session cannot be typed into this instant. Drawn back, announced
 *    disabled, and pressing it opens the reason — the same behaviour, the same
 *    markup and the same argument as `ControlPicker`'s blocked chip, which is
 *    written out beside `aria-disabled` in that file: a `disabled` attribute
 *    receives no pointer events, so the reason would be unreachable.
 *  - **Nothing has been read yet and nothing is wrong.** No *switch*: there is
 *    no position to draw, because a knob has to be somewhere and "somewhere"
 *    would be a claim about a session that has not spoken. But the control
 *    still **works**, and it is drawn as a control that works: full-strength
 *    ink, a caret, no `aria-disabled`, and a popover holding the sentence *and*
 *    the two rows — which is exactly what the `ControlPicker` this replaced put
 *    there, because a picker renders its options whenever `blocked === null`,
 *    whatever it has or has not read.
 *
 * ## The revision in the middle, and why it was worse than the bug it fixed
 *
 * The first version of this file computed one `sentence` from `blocked ?? (read
 * ? null : unreadNote)` and drew *both* of the last two states from it. That is
 * one branch for two states the paragraphs above spend a page keeping apart, and
 * the markup said so: the unread chip came out byte-identical to the refused one
 * — `aria-disabled="true"`, `data-blocked=""`, a popover with one sentence and
 * nothing to press. Two costs, and the second is the serious one.
 *
 * It **looked** refused. `.cc-chip[data-blocked]` in `AgentControls.css` is
 * documented as "a chip whose control cannot act right now, *and knows why*",
 * and it mutes the chip; `aria-disabled` says the same thing out loud to a
 * screen reader. Nothing was refused. The chip was drawn back and announced
 * broken because a reading had not landed yet.
 *
 * And it **was** refused, in fact if not in truth: with no switch and no rows
 * there was nothing to press, so on a fresh session — every fresh session, since
 * `blockedFor` in `SessionControls.tsx` returns null while `readings === null` —
 * fast mode could not be changed at all, while model and effort beside it could.
 * The sentence it showed instead said *"there is no setting here to change until
 * it does"*, and that sentence is false: the `fast` branch of `applyControl` in
 * `src/main/agent-controls.ts` types `/fast on` and *then* waits for the screen,
 * and `pick` in `useSessionControls.ts` never consults a reading either. The
 * keystroke was valid the whole time. This is the standing rule of this cluster
 * inverted — a control that *can* act, drawn absent, with a reason that is not
 * true — and it mattered here more than most, because fast mode was brought back
 * from deletion only on the terms *"if it is available then let's bring it here,
 * otherwise remove it completely"*. A chip that refuses on every session whose
 * screen has not been read yet is that deletion, arriving quietly.
 *
 * So the two states share a *shape* — a chip that opens a popover rather than
 * flipping — and nothing else. The refusal keeps every attribute it had. The
 * unread state keeps none of them, and the conditional that decides is the same
 * one `ControlPicker.tsx` writes and argues beside its own `aria-disabled`:
 * `blocked !== null`, not
 * "anything other than a clean reading".
 *
 * The third case used to be impossible to distinguish from "off", and that is
 * precisely why it is a case here rather than a default. It then spent one
 * revision impossible to distinguish from a refusal, which is worse: "off" at
 * least left you something to flip.
 */

interface Props {
  /** Which control this is. Decides the name and the unread wording. */
  control: ControlId
  /**
   * The short name on the chip, e.g. "Fast mode" — or null where something
   * above it has already said so.
   *
   * Null is how this control is drawn inside a `ControlSection`, whose `<h4>`
   * is the name. Printing it twice, six pixels apart, is the duplication this
   * cluster has already been reported for at a larger scale: *"options is
   * having all of the things that we already have here and there."*
   */
  name: string | null
  reading: ControlReading | undefined
  /**
   * The two states, as `[off, on]`.
   *
   * Passed in rather than hard-coded so that the ids typed at the session and
   * the words drawn on the chip are one fact, held in `catalog.ts` with
   * everything else the CLI's grammar decides. A list that is not exactly two
   * long is refused below rather than rendered as half a switch.
   */
  options: ControlOption[]
  /** How far a change reaches, or null where this app has no grounds to say. */
  reach: string | null
  busy: boolean
  disabled: boolean
  /** Why the control cannot act, when that is known. Shown instead of a switch. */
  blocked: string | null
  onPick: (optionId: string) => void
}

/**
 * What a two-state control says when it has read neither of them.
 *
 * A sentence rather than a shrug, because the reader's next two questions are
 * always "why not" and "what do I do" and both have real answers: nothing has
 * been read, and the reading comes off the session's own screen, so it arrives
 * as soon as the session draws anything.
 *
 * ## The clause that had to go
 *
 * This used to end *"— so there is no setting here to change until it does."*
 * That was false, and false in the expensive direction: it told the reader a
 * control was unavailable while the keystroke behind it was perfectly good.
 * Nothing anywhere requires a prior reading in order to send one of these two
 * ids — see the `fast` branch of `applyControl` in `src/main/agent-controls.ts`,
 * which types the command first and reads the screen afterwards. A sentence that
 * talks a person out of an action that would have worked is worse than no
 * sentence, and it is the same failure as a greyed control with no explanation,
 * wearing an explanation as its alibi.
 *
 * What is left is the narrower thing that is actually true: there is no
 * *position* to show. A switch is a claim about where something currently is,
 * and that is the one claim this app has not got. The setting is still sendable
 * and the sentence now says so, which is also what the popover under it now
 * offers.
 *
 * Exported because `ControlSection` needs the same sentence and must not draw
 * it the same way. On the bar there is room for a chip and the sentence hides
 * behind it; in the panel there is room for the sentence itself, and a popover
 * hanging out of a panel that scrolls would be clipped by the panel. One
 * sentence, two presentations — which is the split `ControlSection`'s own note
 * already describes for the pickers.
 */
export function toggleUnreadNote(control: ControlId): string {
  return `${noPosition(control)} ${STILL_SENDABLE}`
}

/**
 * The first clause on its own, for a container that is already showing the rows.
 *
 * Two lengths of one sentence, built from the same two strings, so they cannot
 * come to disagree — the short one is literally a prefix of the long one, which
 * is the only version of "keep these in sync" that needs no discipline.
 *
 * The clause that is dropped is *"either setting can still be sent, and the
 * switch appears the moment the session says which one it is in"*, and it is
 * dropped exactly where it stops being news: inside an open menu the two
 * settings are on screen, three rows down, pressable. The long form exists for
 * the chip and the panel, where the reader is looking at a sentence with nothing
 * beside it and has to be told there is something to press at all.
 *
 * This matters more than a saved line. Under a list of eleven models, on a
 * session whose first frame has not been parsed — which is every session for its
 * first second — the full sentence is five lines of grey prose at the foot of
 * the menu Asad has just asked to be made clean: *"we need this clean and
 * visual."* A menu that answers a question nobody asked, at the length this one
 * did, is the same complaint arriving in a different control.
 */
export function toggleUnreadBrief(control: ControlId): string {
  return noPosition(control)
}

/** Why there is no switch. */
function noPosition(control: ControlId): string {
  return `${controlName(control)} is read from this session’s own screen, and it has not drawn one yet — so there is no position to show.`
}

/** And what can be done anyway, for the surfaces that are not already showing it. */
const STILL_SENDABLE =
  'Either setting can still be sent, and the switch appears the moment the session says which one it is in.'

export function ControlToggle({
  control,
  name,
  reading,
  options,
  reach,
  busy,
  disabled,
  blocked,
  onPick,
}: Props) {
  const [open, setOpen] = useState(false)
  const [above, setAbove] = useState(false)
  /*
   * Which edge the menu hangs from. `'left'` unless this chip is near the
   * window's right-hand edge, where a left-anchored 304px panel runs off the
   * glass — see `menu-side.ts`, which holds the measurement and the reasoning.
   */
  const [side, setSide] = useState<MenuSide>('left')
  const rootRef = useRef<HTMLDivElement>(null)
  const menuId = useId()
  const close = useCallback(() => setOpen(false), [])

  /*
   * The same one-menu-at-a-time rule its neighbours obey. Without this a chip
   * pressed while one of the pickers' menus or the cluster's own panel is open
   * would lay a second surface across it — see `one-menu.ts`, which exists for
   * exactly that overlap.
   */
  useOneMenu(open, close)

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

  // Which way the popover hangs. The same measurement `ControlPicker` takes,
  // and it has to be taken rather than assumed: this control lives on a bar at
  // the top of a pane, where up is another pane's terminal, and in the composer's
  // own row, where down is the bottom of the window.
  useEffect(() => {
    if (!open) return
    const box = rootRef.current?.getBoundingClientRect()
    if (!box) return
    setAbove(box.top > window.innerHeight - box.bottom)
    setSide(menuSide(box, window.innerWidth))
  }, [open])

  const off = options[0]
  const on = options[1]
  /*
   * A malformed pair draws nothing at all.
   *
   * Not a fallback to a hard-coded `on`/`off`, and the difference matters: the
   * ids here are typed into somebody's terminal after a slash command, so a
   * guess at what the second one is called is a guess at what gets typed. An
   * absent control with the reason in the source beats a switch that sends a
   * word nobody chose. `catalog.test.ts` pins that fast mode is exactly two.
   */
  if (!off || !on) return null

  const value = displayValue(reading, control)
  const read = reading?.value === on.id || reading?.value === off.id
  const isOn = reading?.value === on.id
  const note = read ? sourceNote(reading?.source ?? null) : sourceNote(null)
  /*
   * Refused, which is a fact about the control, and not merely unread, which is
   * a fact about what has been seen so far.
   *
   * Spelled `blocked !== null` rather than folded into whatever else is missing,
   * because the version that folded them is the bug this file's long note above
   * is written about. `ControlPicker.tsx` writes the same test on the same two
   * props and argues it there; one argument, obeyed in two files, and now the
   * same expression in both so they cannot drift apart again.
   */
  const refused = blocked !== null

  if (refused || !read) {
    return (
      <div className="ac-picker ac-toggle" ref={rootRef}>
        <button
          type="button"
          className="cc-chip ac-toggle-chip"
          aria-haspopup="menu"
          aria-expanded={open}
          aria-controls={open ? menuId : undefined}
          /* Announced disabled and drawn back **only when something is actually
             refusing** — never merely because a reading has not landed. Not
             `disabled`, for the reason written out beside `aria-disabled` in
             `ControlPicker.tsx`: a disabled button receives no pointer events,
             so the reason would be unreachable by hover and by press. It is one
             argument and it is not restated here. */
          aria-disabled={refused ? true : undefined}
          data-blocked={refused ? '' : undefined}
          /*
           * Named, then valued, then sourced — the same three facts in the same
           * order as every other chip on this row, and the same order
           * `ControlPicker` builds its title in. A chip whose hover label is a
           * paragraph while its neighbours' are `Effort: Ultracode — from Claude
           * settings` makes a person learn a second convention for one control.
           *
           * A *refusal* is the exception, and it is the picker's exception too:
           * when the CLI has said why this cannot act, that sentence is the
           * whole of what there is to say and prefixing it with a value nobody
           * can change reads as an argument with the reason underneath it. The
           * unread case is not a refusal — the value simply has not arrived — so
           * it keeps the ordinary label and puts its sentence in the popover,
           * which is the one place there is room for it.
           */
          title={blocked ?? `${controlName(control)}: ${value} — ${note}`}
          onClick={() => setOpen((was) => !was)}
        >
          {name === null ? null : <span className="ac-name">{name}</span>}
          {/*
            Muted italic means *we could not find out*, and not *you cannot
            change this*. A refused control usually has a perfectly good reading
            behind it — the CLI answers `Fast mode unavailable: …` and the `↯` in
            its status rule still says which way the switch is — so drawing that
            `Off` in the unread style would be a second, false claim stacked on
            top of a true refusal. `.cc-chip[data-blocked]` is what draws a
            refused chip back; the value keeps saying what kind of value it is.
            Same predicate and same pair of classes as `ControlPicker`, so the
            two cannot come to disagree about what italics mean.
          */}
          <span className={reading?.label == null ? 'ac-value ac-value-unknown' : 'ac-value'}>
            {busy ? 'Working…' : value}
          </span>
          {/*
            The caret is on the two states that open and off the one that flips.

            It is the mark that says *this opens something*, and that is a claim
            about the chip as drawn rather than about the control's identity: the
            switch below opens nothing, so a caret there would be a false
            affordance, and these two do open, so its absence was one. On the
            unread chip it is the whole visible difference between "press me,
            there are two rows behind this" and the dead grey thing this state
            used to be. `ControlPicker` keeps its caret when it is blocked for
            the same reason — the refusal is still behind it.
          */}
          <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
            <path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
        </button>
        {open ? (
          <div
          className={`ac-menu${above ? ' ac-menu-above' : ''}${side === 'right' ? ' ac-menu-right' : ''}`}
          id={menuId}
          role="menu"
        >
            {refused ? (
              /* The reason, and nothing else. Options under a refusal would be
                 rows that argue with the CLI on every press. */
              <p className="ac-blocked">{blocked}</p>
            ) : (
              <>
                {/* Why there is no switch, above the two things there are to
                    press. The sentence first because it is the answer to the
                    question the missing switch just asked. A different class
                    from `.ac-blocked` deliberately: these two sentences mean
                    different things and the markup should not have to be read
                    twice to tell which one is on screen. */}
                <p className="ac-unread-note">{toggleUnreadNote(control)}</p>
                {options.map((option) => (
                  <button
                    key={option.id}
                    type="button"
                    role="menuitemradio"
                    /* `isCurrent` rather than a hand-rolled comparison, so this
                       menu cannot form a second opinion about what "in force"
                       means. In this state it answers false for both, which is
                       the honest answer: a tick is a claim and nothing has been
                       read. */
                    aria-checked={isCurrent(reading, option)}
                    className="ac-item"
                    /* The chip stays pressable while a change is in flight and
                       these rows do not, which is the opposite way round from
                       `ControlPicker` and is deliberate. Pressing the chip sends
                       nothing — it only opens — so disabling it would hide the
                       explanation and prevent nothing. Pressing a row *does*
                       send, and two `/fast` commands racing into one pty is a
                       real thing to prevent: the popover shuts on pick, but the
                       chip can be reopened while the first one is still
                       settling. `ControlSection`'s radiogroup locks its rows on
                       the same terms. */
                    disabled={disabled || busy}
                    onClick={() => {
                      setOpen(false)
                      onPick(option.id)
                    }}
                  >
                    <span className="ac-tick" aria-hidden="true"></span>
                    <span className="ac-item-text">
                      <span className="ac-item-label">{option.label}</span>
                      {option.hint ? <span className="ac-item-hint">{option.hint}</span> : null}
                    </span>
                  </button>
                ))}
                {/* How far it reaches, and no `Now:` line. The picker's foot
                    prints the current value too; here it would say `Now:
                    Unknown` directly under a sentence that has just spent a line
                    saying so. What is worth the room is the reach — this is the
                    one state in which somebody sends a value without knowing
                    what it is replacing, and *"stays on until you turn it off —
                    new sessions too"* is exactly what they would want to have
                    been told first. */}
                {reach ? (
                  <p className="ac-reach">
                    <span className="ac-reach-scope">{reach}</span>
                  </p>
                ) : null}
              </>
            )}
          </div>
        ) : null}
      </div>
    )
  }

  const next = isOn ? off : on
  return (
    <div className="ac-picker ac-toggle" ref={rootRef}>
      <button
        type="button"
        role="switch"
        aria-checked={isOn}
        className="cc-chip ac-toggle-chip"
        disabled={disabled || busy}
        /* Name, state and where the state came from — the same three facts the
           picker's tooltip carries, in the same order, because a person who has
           hovered one chip on this row should not have to learn a second
           sentence for the next one. */
        title={`${controlName(control)}: ${busy ? 'Working…' : value} — ${note}${reach ? ` · ${reach}` : ''}`}
        onClick={() => onPick(next.id)}
      >
        {name === null ? null : <span className="ac-name">{name}</span>}
        {/*
          The track is the value, so the word beside it is the value's name and
          not a second copy of it.

          An earlier sketch drew the switch *and* printed `On` next to it, which
          is the same fact twice a centimetre apart — the duplication this
          cluster has already been reported for twice. What survives in text is
          `Working…`, because a switch mid-flight has no honest position: it is
          neither where it was nor where it is going, and animating it to the new
          state before the session confirms would be this app asserting a change
          it has not been told happened.
        */}
        {busy ? (
          <span className="ac-value ac-value-unknown">Working…</span>
        ) : (
          <span className="ac-toggle-track" data-on={isOn || undefined} aria-hidden="true">
            <span className="ac-toggle-knob" />
          </span>
        )}
      </button>
    </div>
  )
}

/**
 * The same two-state control, drawn as the last item *inside* another control's
 * menu instead of as a chip of its own.
 *
 * ## Why fast mode stopped having a chip
 *
 * Asad, looking at the bar: *"move fast mode toggle inside the models
 * dropdown at the end."* The chip was correct and it was also a whole slot of a
 * bar spent on a switch that, by its own account in `catalog.ts`, spends most of
 * its life off — and it sat beside the one menu it is actually coupled to.
 * Fast mode belongs to the model: the CLI's own model picker says so under its
 * rows, *"Switching to other models turns off fast mode"*, which is a sentence
 * about the rows immediately above this item. Putting the switch anywhere else
 * is putting the consequence and the cause on opposite ends of a toolbar.
 *
 * ## The three states survive the move, because they are the control
 *
 * Everything the long note at the top of this file argues is still true here and
 * is implemented the same way, on the same predicate. What changes is only the
 * container, and the container is a help rather than a constraint: a menu is
 * already open when this is read, so the two states that need a *sentence* can
 * print it in place instead of behind a popover. There is no nested popover
 * anywhere in this component, which is the one thing a menu genuinely cannot do.
 *
 *  - **Read.** One row, `aria-checked`, and a press sends the other id.
 *  - **Refused.** The name and the CLI's own reason, in place. It is announced
 *    to assistive technology as a group with nothing pressable in it rather than
 *    as a disabled button, because there is no button — a refusal in an open
 *    menu has room to simply say so, which is what the chip needed a popover
 *    for.
 *  - **Nothing read yet.** The sentence, and under it the two ids as rows.
 *    `/fast on` is a valid keystroke whatever has been read — `applyControl` in
 *    `src/main/agent-controls.ts` types the command and reads the screen
 *    afterwards — so this state is pressable, and the regression this file
 *    already documents (an unread fast mode drawn as a refused one, leaving a
 *    fresh session with no way to change it at all) cannot come back through the
 *    new container.
 *
 * ## How it reads as a different kind of choice from the rows above it
 *
 * The model rows are a radiogroup: one of eleven names, a tick column down the
 * left, and picking one closes the menu because the question is answered. This
 * is not a twelfth model, and four separate things say so.
 *
 *  - A rule and a gap above it (`.ac-menu-nested`), which is the first
 *    separation this stylesheet reaches for after space alone.
 *  - No tick column. The row leads with the control's *name*, where every row
 *    above leads with an empty or ticked gutter, so the two columns of text do
 *    not line up — deliberately, for once.
 *  - A track and a knob on the trailing edge: a position, not a selection. It is
 *    the same 26×14 track the chip wore, so a person who used the old bar
 *    recognises it.
 *  - `role="menuitemcheckbox"`, not `menuitemradio`. A screen reader is told the
 *    difference in as many words, which is the half of this that a rule and a
 *    knob cannot carry.
 *
 * And it does not close the menu when it is pressed, where a model row does.
 * That is the same distinction again in behaviour: picking a model answers the
 * menu's question, so the menu goes; flipping a switch does not, and the switch
 * you just flipped is the thing you want to see move. The rows are locked while
 * the change is in flight for the reason the chip's popover locks its own — two
 * `/fast` commands racing into one pty is a real thing to prevent.
 */
export function ControlToggleItem({
  control,
  reading,
  options,
  reach,
  busy,
  disabled,
  blocked,
  onPick,
}: Omit<Props, 'name'>) {
  const off = options[0]
  const on = options[1]
  // A malformed pair draws nothing, on exactly the argument written beside the
  // same guard in `ControlToggle` above: the ids here are typed into somebody's
  // terminal, so a guess at the second one's name is a guess at what gets typed.
  if (!off || !on) return null

  const name = controlName(control)
  const value = displayValue(reading, control)
  const read = reading?.value === on.id || reading?.value === off.id
  const isOn = reading?.value === on.id
  const note = read ? sourceNote(reading?.source ?? null) : sourceNote(null)
  // Refused, which is a fact about the control, and not merely unread, which is
  // a fact about what has been seen. One expression, spelled the same way in all
  // three components, so they cannot come to disagree about which state is which.
  const refused = blocked !== null

  return (
    <div className="ac-menu-nested" role="group" aria-label={name}>
      {refused ? (
        <>
          <p className="ac-option-group" role="presentation">
            {name}
          </p>
          {/* The reason and nothing else — no switch, and no rows to argue with
              the CLI on every press. It is the same `.ac-blocked` box the chip
              opened onto, printed in place because the menu is already open. */}
          <p className="ac-blocked">{blocked}</p>
        </>
      ) : read ? (
        <button
          type="button"
          role="menuitemcheckbox"
          aria-checked={isOn}
          className="ac-item ac-item-switch"
          disabled={disabled || busy}
          /* Name, state, source and reach — the four facts the chip's own hover
             label carried, in that order, so nothing was lost by moving the
             control into a menu. The reach is the one that only lives here now:
             *"stays on until you turn it off — new sessions too"* is a real
             surprise to leave switched on by accident, and the menu itself has no
             room for a second line of grey text under a switch that already
             carries a hint. */
          title={`${name}: ${busy ? 'Working…' : value} — ${note}${reach ? ` · ${reach}` : ''}`}
          onClick={() => onPick(isOn ? off.id : on.id)}
        >
          <span className="ac-item-text">
            <span className="ac-item-label">{name}</span>
            {/*
              A tag, where a three-line description used to be.

              What was here was `describeControl(control)` in full — *"The same
              model, answering faster. Switching to another model turns it off."*
              — which wrapped to three lines of grey prose at the foot of the
              model menu, under a switch, in a panel Asad had already asked to be
              made clean. *"I don't want any kind of long descriptions
              anywhere."*

              It is not simply deleted, because half of it is a fact about the
              rows *directly above this one*: turn fast mode on, pick another
              model, and you have silently turned it off again, with nothing on
              screen changing to say so. That half is the only moment it can be
              read in time, and it fits in four words. The other half — what fast
              mode is — is the ⓘ in the folded sheet and is not news to anybody
              who found this row.

              Written to the same rule as every other hint in this cluster: a
              fact about what pressing the row *does*, not a description of the
              feature. See {@link ControlOption.hint}.
            */}
            {control === 'fast' ? <span className="ac-item-hint">off if you switch model</span> : null}
          </span>
          {busy ? (
            /* A switch mid-flight has no honest position: it is neither where it
               was nor where it is going, and animating it to the new state
               before the session confirms would be this app asserting a change
               it has not been told happened. */
            <span className="ac-value ac-value-unknown">Working…</span>
          ) : (
            <span className="ac-toggle-track" data-on={isOn || undefined} aria-hidden="true">
              <span className="ac-toggle-knob" />
            </span>
          )}
        </button>
      ) : (
        <>
          <p className="ac-option-group" role="presentation">
            {name}
          </p>
          {/* Why there is no switch, above the two things there are to press —
              and only that half of it. The clause about the setting still being
              sendable is the chip's and the panel's, where the sentence stands
              alone; here the two rows are directly underneath and say it better
              than a sentence can. See {@link toggleUnreadBrief}. */}
          <p className="ac-unread-note">{toggleUnreadBrief(control)}</p>
          {options.map((option) => (
            <button
              key={option.id}
              type="button"
              role="menuitemradio"
              /* `isCurrent` rather than a hand-rolled comparison, so this menu
                 cannot form a second opinion about what "in force" means. In
                 this state it answers false for both, which is the honest
                 answer: a tick is a claim and nothing has been read. */
              aria-checked={isCurrent(reading, option)}
              className="ac-item"
              disabled={disabled || busy}
              onClick={() => onPick(option.id)}
            >
              <span className="ac-tick" aria-hidden="true"></span>
              <span className="ac-item-text">
                <span className="ac-item-label">{option.label}</span>
                {option.hint ? <span className="ac-item-hint">{option.hint}</span> : null}
              </span>
            </button>
          ))}
        </>
      )}
    </div>
  )
}
