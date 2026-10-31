import {
  Fragment,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { useOneMenu } from '../../shell/one-menu'
import { menuSide, type MenuSide } from './menu-side'
import type { ControlId, ControlOption, ControlReading } from './catalog'
import { displayValue, isCurrent, shortModelLabel, sourceNote, unreadNote } from './catalog'

interface Props {
  /** Which control this is. Decides what it says when it cannot read a value. */
  control: ControlId
  /** The short name on the button, e.g. "Model". */
  name: string
  reading: ControlReading | undefined
  options: ControlOption[]
  busy: boolean
  disabled: boolean
  /** Why the control cannot be used, when that is known. Shown instead of the menu. */
  blocked: string | null
  /**
   * Another control, drawn at the end of this one's menu under a rule.
   *
   * A `ReactNode` rather than a second set of control props, because this
   * component must not acquire an opinion about which control lives inside
   * which — that fact is `NESTED_CONTROLS` in `shell/SessionControls.tsx`, next
   * to the list that decides what is on the bar at all, which is where every
   * other placement decision in this cluster already lives. What is decided
   * *here* is only that a menu has an end and that the end is under a rule.
   *
   * It is drawn where the foot used to be, and it is not a replacement for it:
   * see the tombstone below the options.
   */
  nested?: ReactNode
  onPick: (optionId: string) => void
}

/*
 * `onOpen` used to be a prop here and it is gone, along with everything that
 * passed it.
 *
 * It was called the moment the menu opened, before it was drawn, and exactly one
 * caller used it: the model picker, to ask the session what models it actually
 * had. That meant typing `/model` into the live pty, reading the dialog the CLI
 * drew and pressing Esc — and cancelling makes the CLI print `Kept model as …`,
 * so every look left a line in somebody's conversation. The argument for it was
 * that a list read from the session is the *account's* list, which a table in
 * this repo can never guarantee.
 *
 * Asad, watching it: *"just to view it is running a command… At least when I
 * click on something then it should run."* Five `/model` blocks stacked in a
 * working conversation. The trade went the other way — the catalogue in
 * `catalog.ts` can be slightly stale, and staleness fails safely where writing
 * into somebody's work does not — and the whole of it is written out beside
 * `optionsForRow` in `shell/SessionControls.tsx`.
 *
 * The prop is removed rather than left unused because an optional hook on a menu
 * is an invitation: the next person with something to fetch would fill it in,
 * and the thing that made this wrong was never *what* it fetched. A menu opening
 * must not run anything.
 */

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
 * An unread control also gets to say *why* where there is a real reason.
 * Permission mode is the only one left that has one — a session nobody has
 * pressed shift+tab in, on a machine with no `permissions.defaultMode` written
 * anywhere, genuinely has nothing to report — see `unreadLabel` in
 * `catalog.ts`. Fast mode used to be in that sentence and is not any more: it
 * turned out to be readable at any moment from the `↯` the CLI leaves in its
 * status rule, so it resolves like its siblings.
 */
export function ControlPicker({
  control,
  name,
  reading,
  options,
  busy,
  disabled,
  blocked,
  nested,
  onPick,
}: Props) {
  const [open, setOpen] = useState(false)
  const [above, setAbove] = useState(true)
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
    if (!box) return
    setAbove(box.top > window.innerHeight - box.bottom)
    setSide(menuSide(box, window.innerWidth))
  }, [open])

  const value = displayValue(reading, control)
  /*
   * The chip prints the short name and the `title` prints the one that was read.
   *
   * Only the model has a long form worth shortening — `Opus 5 with 1M context`
   * against fourteen characters of chip — and only the model's menu shows every
   * name in full underneath, which is what makes the shortening safe. See
   * {@link shortModelLabel} for what it keeps and why `1M` is not optional.
   */
  const shown = control === 'model' ? shortModelLabel(value) : value
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
        // Opening this asks nobody anything, which is the whole of the note
        // above the `Props` interface.
        onClick={() => setOpen((was) => !was)}
      >
        <span className="ac-name">{name}</span>
        <span className={unknown ? 'ac-value ac-value-unknown' : 'ac-value'}>{busy ? 'Working…' : shown}</span>
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
          {blocked ? (
            <p className="ac-blocked">{blocked}</p>
          ) : (
            options.map((option) => {
              const current = isCurrent(reading, option)
              return (
                <Fragment key={option.id}>
                  {/* Only where the rows below make a weaker claim than the ones
                      above — see `ControlOption.group`. The model menu ends with
                      names the CLI's picker does not list and an account may not
                      be entitled to, and run together they read as one list. */}
                  {option.group ? (
                    <p className="ac-option-group" role="presentation">
                      {option.group}
                    </p>
                  ) : null}
                  <button
                    type="button"
                    role="menuitemradio"
                    aria-checked={current}
                    className={current ? 'ac-item ac-item-current' : 'ac-item'}
                    /*
                     * Locked while anything on this bar is mid-change, and that
                     * became load-bearing the day fast mode moved into this menu.
                     *
                     * It used to be unnecessary: picking a row shut the menu, and
                     * the chip that reopens it is disabled for as long as the
                     * command is settling, so there was no way to reach a second
                     * row. Nesting a switch at the foot of the list broke that —
                     * flipping fast mode deliberately leaves the menu open, so
                     * eleven live model rows sat over a `/fast` that was still in
                     * flight, and two slash commands racing into one pty is the
                     * thing every other surface in this cluster locks its rows to
                     * prevent. `ControlToggle`'s popover and `ControlSection`'s
                     * radiogroup both spell it exactly this way.
                     */
                    disabled={disabled || busy}
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
                </Fragment>
              )
            })
          )}
          {/*
            The foot of this menu is deleted, and the `reach` prop with it.

            It printed three lines under every list — `Now: Opus 5`, the source
            note, and *"This session — and your default too, if the CLI says so
            when it confirms"* — and Asad, looking at the model menu and the
            effort menu one after the other: *"I don't want this inside."* He is
            right about the first two thirds of it. `Now:` is the same fact as
            the tick six rows above and the same fact again as the value on the
            chip that opened the menu, which is three copies of one word; the
            source note is already the chip's hover label, in the same words.

            Two things went with it that were **not** duplicates, and they are
            written here rather than quietly lost:

             - The reach. Model and effort branch — the CLI decides at confirm
               time whether a change is this session only or also your default —
               and this menu was the only place in the app that said so before
               you pressed anything. It is still said *after*: `applyControl`
               quotes the arm the CLI actually printed, and that sentence lands
               in the notice under the bar. So the warning is now a report.
             - `Now:` was also the unread state's only line. With nothing read,
               `isCurrent` is false for every row, so an open menu carries no
               tick at all. The chip above it still says `Unknown` in the
               unread italic and still names the source in its hover label, so
               the fact is on screen — but it is on the trigger, not in the
               list.

            Neither is replaced with an invention. If either needs to be back on
            screen it should be back as the thing it is, not as a third line of
            grey text under every menu.
          */}
          {/* Outside the refusal above, deliberately. What is nested here is a
              *different control* with its own answer to whether it can act — a
              model the account cannot select says nothing about whether fast
              mode can be switched — and hiding a control that works because its
              neighbour is refused is the dead-control failure this cluster is
              audited for. Two refusals stack into two sentences, which is
              wordy and true; one refusal swallowing a working switch is neither. */}
          {nested}
        </div>
      ) : null}
    </div>
  )
}
