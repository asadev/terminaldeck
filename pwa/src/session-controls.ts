/**
 * The session's control cluster — model, effort, fast mode, permission — on a
 * phone.
 *
 * ## Nothing new is on the wire, and that is the finding, again
 *
 * `CAPABILITY.controls` has shipped since 0.5.0. `host-core.ts` wires the
 * controls courier into the same fanout that serves this client, so a desktop
 * is *already* answering `controls.read` and `controls.apply` for whoever asks
 * — the desktop's own remote window does (see `readControls` / `setControl` in
 * `src/main/remote/machines/guest.ts`). This browser never sent one of those
 * frames, so a phone could watch a session and not once change what it runs at.
 * This module is a client, not a feature, exactly as `session-bar.ts` is for
 * `usage` and `account`.
 *
 * ## The vocabulary is imported, not copied
 *
 * Every option this cluster offers — the model rows, the seven efforts, the
 * five permission modes, the two positions of fast mode — comes from
 * `src/renderer/chat/controls/catalog.ts`, which is the one file the desktop's
 * own cluster reads. That file is plain TypeScript with a single import
 * (`shared/model-catalog.ts`, which has none), so the browser can bundle it,
 * and importing it is what "the same identical options" costs nothing to keep
 * true: a second list here would be right on the day it was written and would
 * drift from the first release onwards.
 *
 * ## What is drawn, and what is deliberately not
 *
 * Nothing at all until a `controls.reading` lands, and nothing ever over a
 * machine that does not advertise `controls` — the same rule the bar above
 * follows, so an older desktop gets a pane that is exactly what it was rather
 * than a row explaining what it is missing. Nothing over a plain shell either:
 * the reading says whether an agent is drawing that session's screen
 * (`agent.running`), and model chips over `/bin/zsh` are the defect the
 * desktop's own cluster withdraws itself for.
 *
 * ## A blocked chip opens onto its rows, with the reason above them
 *
 * The rule this file used to state, in these very words, was the opposite: a
 * barred control *"keeps its chip, and the chip opens onto the far end's own
 * sentence instead of onto rows."* Asad opened the session's Controls on his
 * phone, tapped **Model**, and got a paragraph about unsent text where the list
 * of models should have been:
 *
 *   > *"they are also not control they are just descriptions which i dont want
 *   > always"*
 *
 * He is right, and the old rule was solving the wrong half of the problem. It
 * was written against a dead menu — a menu that looks live and is not, measured
 * on this very bar once (the account sheet, 2026-08-20) — and prose in place of
 * the menu is not the cure for that. It is a second way of being it. A sheet
 * called **Controls** whose rows open onto descriptions is not a control panel.
 *
 * So the rows are drawn whether or not the control is blocked — he opened Model
 * to see models, and the ticked row is worth reading even in a moment he cannot
 * change it — and the reason rides above them as one short line. Blocked rows
 * are drawn and not pressable: a press that could only be answered with a
 * refusal is the dead click this app is repeatedly audited for.
 *
 * Two things at the far end had to become true for that to be honest rather
 * than merely tidier, and both now are (`src/main/agent-controls.ts`):
 *
 *  - **Most blocks are no longer blocks.** `readControls` asks `readCarry`
 *    rather than `refuseToType`, so a draft at the far prompt no longer closes
 *    the gate at all: `carryDraft` lifts the line out of the way, runs the
 *    command, and types the line back unsent. The commonest reason a chip ever
 *    greyed out — the exact one in his screenshot — does not arrive any more.
 *  - **What is left is short.** The four states the app genuinely cannot clear
 *    for him — a turn in flight, a dialog holding the keyboard, a prompt that
 *    is not on screen to be read, a draft spanning more rows than can be lifted
 *    — each travel as one line rather than a paragraph, because they are drawn
 *    beside a live control instead of in place of one. A desktop that has not
 *    been updated yet still sends its old paragraph and this draws it: the
 *    length is the far end's to fix, and the rows are here either way.
 *
 * ## Honest in-flight and failed states
 *
 * A press sends the frame and says "Working…" until the machine answers. The
 * ticked row is never the row that was pressed — it is whatever the far end
 * *re-read* off the session after the change settled, which is what makes a
 * failed apply revert by construction: nothing optimistic was ever written. A
 * failure keeps its sentence on screen until dismissed; a confirmation clears
 * itself. And a machine that never answers gets the one sentence that does not
 * guess: the command is typed into the far pty before anything is sent back, so
 * "it failed" would be a claim in the direction that makes somebody press
 * again — a second `/model` block in a conversation that already moved.
 */

import {
  CAPABILITY,
  type ClientMessage,
  type ControlName,
  type ControlReadingWire,
  type ControlsReadingWire,
  type ServerMessage,
} from '../../src/main/remote/protocol'
import {
  controlName,
  displayValue,
  EFFORT_OPTIONS,
  FAST_OPTIONS,
  isCurrent,
  modelOptions,
  PERMISSION_OPTIONS,
  previousModelOptions,
  shortModelLabel,
  type ControlOption,
  type ControlReading,
} from '../../src/renderer/chat/controls/catalog'

/* ---------------------------------------------------------------- reading -- */

/**
 * A wire reading in the catalogue's shape, so the desktop's own functions can
 * read it.
 *
 * The one field that does not carry over is `source`: the wire spells it as an
 * open string because a build older or newer than this one may name a source
 * this build has no word for, and narrowing it here would turn "a source this
 * client cannot name" into "no source". Nothing on a phone prints source notes
 * — the desktop's `sourceNote` is hover text, and there is no hover — so the
 * honest translation is to drop it rather than to guess at it.
 */
export function asCatalogReading(wire: ControlReadingWire | undefined): ControlReading | undefined {
  if (wire === undefined) return undefined
  return {
    value: wire.value,
    label: wire.label,
    source: null,
    ...(wire.unavailableReason === undefined ? {} : { unavailableReason: wire.unavailableReason }),
  }
}

/**
 * Whether there is a cluster to draw at all.
 *
 * Three answers fold to false and each is a different honesty: no reading has
 * landed (nothing real to show yet), the far end had no such session
 * (`live: false` — a corpse gets no menus), and the session is a plain shell
 * (`agent.running: false` — the same rule that withdraws the desktop's cluster
 * over `/bin/zsh`, because a model menu over a shell is a control acting on
 * nothing). Absent, not greyed: a phone row explaining why it is empty is the
 * wall of words this client's bar was told four times not to print.
 */
export function clusterShown(reading: ControlsReadingWire | null): boolean {
  return reading !== null && reading.live && reading.agent.running
}

/**
 * Why nothing can be changed at this instant, for one control, or null.
 *
 * The same two questions `blockedFor` in `SessionControls.tsx` asks, in the
 * same order, minus the two a remote client cannot ask locally — whether the
 * bridge is wired and whether the CLI is foreign, both of which the far machine
 * already answers by writing `unavailableReason` onto the reading itself (see
 * `readControls` in `src/main/agent-controls.ts`). Every sentence returned here
 * is the far end's own; the one fallback is for a gate that closed without
 * giving a reason, and it claims only what is known: nothing was sent.
 *
 * ## What the answer is used for, which is not what it used to be
 *
 * It used to pick between two whole drawings: the rows, or this sentence in
 * their place. It no longer does. The rows are always drawn, and this is one
 * short line above them plus the decision not to accept a press — see the note
 * at the top of this file for why that swapped round, in his words. The
 * function is unchanged because the question it asks was never the wrong one;
 * only what the drawing did with the answer was.
 *
 * The two sources are also no longer the same *kind* of thing, and which is
 * which now matters, because the far end clears one of them by itself.
 * `unavailableReason` is that machine saying it will not accept this at all — a
 * shell with no agent in it, a CLI whose model command was never established,
 * an account without the credits for fast mode. `gate` is a state that flips on
 * the session's next flush of output: mid-turn, a dialog on screen, a prompt
 * that cannot be read, a draft too big to lift. A draft that *can* be lifted is
 * no longer either of them — `carryDraft` takes it, runs the command and types
 * it back unsent — and this answers null throughout.
 */
export function blockedFor(control: ControlName, reading: ControlsReadingWire): string | null {
  const barred = reading[control].unavailableReason
  if (barred !== undefined && barred !== '') return barred
  if (!reading.gate.canType) {
    return reading.gate.reason ?? 'This session cannot be typed into right now, so nothing was sent.'
  }
  return null
}

/**
 * What a chip prints: the value alone, never the control's name beside it.
 *
 * *"no need to tell that Model Opus 5 — just Opus 5 with drop down is good
 * enough"* — the name lives in the accessible label and the sheet. The model is
 * shortened the way the desktop's chip shortens it, so the phone and the Mac
 * print the same word for the same session; everything else fits as read.
 * `displayValue` owns the unread words — `Unknown` for a read that should have
 * worked, `Not reported` for a permission nothing has ever said.
 */
export function chipText(control: ControlName, reading: ControlsReadingWire): string {
  const value = displayValue(asCatalogReading(reading[control]), control)
  return control === 'model' ? shortModelLabel(value) : value
}

/** The rows of one chip's sheet. Fast mode is a switch, not a sheet — see the model sheet. */
export function rowsFor(control: 'model' | 'effort' | 'permission'): ControlOption[] {
  if (control === 'model') return [...modelOptions(), ...previousModelOptions()]
  if (control === 'effort') return EFFORT_OPTIONS
  return PERMISSION_OPTIONS
}

/** See `isCurrent` in the catalogue, which owns what "in force" means. */
export function chosen(reading: ControlReadingWire, option: ControlOption): boolean {
  return isCurrent(asCatalogReading(reading), option)
}

/** Everything one open sheet is: a line, rows, and whether the rows take a press. */
export interface SheetPlan {
  /** The one short line above the rows, or null when nothing is in the way. */
  reason: string | null
  /** The rows. Always the whole list — a blocked sheet is not an empty one. */
  rows: ControlOption[]
  /** False when a press would only be answered with a refusal, so it is refused here. */
  usable: boolean
}

/**
 * What an open chip's sheet contains — decided here rather than inside
 * `render()`, so it is a rule something can ask a question of.
 *
 * The whole of T9 is that `reason` and `rows` are now two fields instead of two
 * branches. There is no arrangement of these three values that draws prose where
 * a list of models belongs: `rows` is `rowsFor(control)` unconditionally, and a
 * block spends itself on a line above them and on `usable`.
 */
export function sheetPlan(control: 'model' | 'effort' | 'permission', reading: ControlsReadingWire): SheetPlan {
  const reason = blockedFor(control, reading)
  return { reason, rows: rowsFor(control), usable: reason === null }
}

/**
 * The value to send when the fast-mode switch is pressed.
 *
 * Computed from the *reading*, never from what the switch looks like: a switch
 * drawn from a stale frame that flipped its picture rather than the fact would
 * send "on" to a session that is already on.
 */
export function fastFlip(reading: ControlReadingWire): 'on' | 'off' {
  return reading.value === 'on' ? 'off' : 'on'
}

/** Fast mode's corner of the model sheet: a line, a shape, and whether it takes a press. */
export interface FastPlan {
  /** The line to print above it, or null — see `alreadySaid` below. */
  reason: string | null
  /** A switch once the position has been read; the two rows while nothing has said which. */
  shape: 'switch' | 'rows'
  /** Where the switch stands. Only meaningful when `shape` is `switch`. */
  on: boolean
  /** False when a press would only be answered with a refusal. */
  usable: boolean
}

/**
 * What fast mode draws at the end of the model sheet.
 *
 * Asked against the *nested* control — `blockedFor('fast')`, never the model's
 * answer — so an account barred from fast mode gets that line while the model
 * rows above it stay live, and a shut typing gate closes both.
 *
 * `alreadySaid` is the model sheet's own reason, and it is passed in for one
 * case: the session's typing gate blocks all four controls at once, so without
 * it a mid-turn model sheet would print *"This session is mid-turn."* twice, a
 * few rows apart, about the same session. Once is information; twice reads as
 * the app repeating itself at somebody who came to pick a model. The refusal
 * that belongs to fast mode alone — *"Fast mode requires usage credits"* — is
 * never the same string as the model's, so it still gets its line. The line is
 * all that is suppressed: `usable` still answers for fast mode itself, so a
 * switch under a suppressed line is still not pressable.
 */
export function fastPlan(reading: ControlsReadingWire, alreadySaid: string | null): FastPlan {
  const barred = blockedFor('fast', reading)
  const value = reading.fast.value
  const read = value === 'on' || value === 'off'
  return {
    reason: barred !== null && barred !== alreadySaid ? barred : null,
    shape: read ? 'switch' : 'rows',
    on: value === 'on',
    usable: barred === null,
  }
}

/**
 * One control's reading replaced by the one an apply's answer carried.
 *
 * The answer's reading is what the far machine re-read off the session after
 * the change settled — never the value that was pressed — so writing it is what
 * makes a refused apply revert on screen: the row that ticks is the row the
 * session is actually on. The same rule, spelled the same way, as
 * `useSessionControls` on the desktop.
 */
export function appliedTo(
  reading: ControlsReadingWire | null,
  control: ControlName,
  answer: ControlReadingWire,
): ControlsReadingWire | null {
  if (reading === null) return null
  return { ...reading, [control]: answer }
}

/**
 * The sentence for an apply nobody answered, word for word the guest's
 * (`setControl` in `src/main/remote/machines/guest.ts`).
 *
 * It does not say "failed" on purpose: the far end types the command into the
 * pty before it sends anything back, so a channel that died in between leaves a
 * session that may well have changed. Claiming failure would send somebody
 * pressing again at a session that already moved.
 */
export const NO_ANSWER = 'That machine did not answer, so it is not known whether the change was made.'

/** And the one for a press while the socket is down — nothing was sent, and it says only that. */
export const NOT_CONNECTED = 'Not connected right now, so nothing was sent.'

/* ------------------------------------------------------------------ time -- */

/**
 * The waits are the guest's (`CONTROLS_READ_TIMEOUT_MS` /
 * `CONTROLS_APPLY_TIMEOUT_MS` in `guest.ts`), because they measure the same
 * journey — a relay hop and a far pty — and two clients waiting different
 * lengths for one answer would give one machine two reputations. The settle and
 * the confirmation are this client's own: the settle is the bar's above
 * (`session-bar.ts`, a round trip rides a relay here), the confirmation the
 * desktop cluster's (`CONFIRM_MS` in `useSessionControls.ts` — a confirmation
 * expires, a failure does not).
 */
export const READ_TIMEOUT_MS = 20_000
export const APPLY_TIMEOUT_MS = 60_000
const SETTLE_MS = 1200
const CONFIRM_MS = 4000

/* ----------------------------------------------------------------- state -- */

interface Pending {
  kind: 'read' | 'apply'
  /** Which control an apply was for; reads carry none. */
  control?: ControlName
  /** The session asked about, checked against the answer — see `receive`. */
  id: string
  timer: ReturnType<typeof setTimeout>
}

export interface SessionControlsDeps {
  /** True from the socket, false while it is down. */
  send: (message: ClientMessage) => boolean
  /** What the machine advertised. Nothing is asked without `controls` in it. */
  capabilities: () => readonly string[]
  /** The session this cluster is about, or null when nothing is attached. */
  sessionId: () => string | null
}

/** A request id nothing else will mint. Same scheme as the bar's, its own prefix. */
let counter = 0
function rid(): string {
  counter += 1
  return `ctl-${counter}-${Math.random().toString(36).slice(2, 8)}`
}

export class SessionControls {
  readonly element = document.createElement('div')

  private reading: ControlsReadingWire | null = null
  private busy: ControlName | null = null
  private notice: { ok: boolean; text: string } | null = null
  /** Which chip's sheet is open. `fast` never is — its switch lives in the model sheet. */
  private open: 'model' | 'effort' | 'permission' | null = null
  private readonly pending = new Map<string, Pending>()
  private quiet: ReturnType<typeof setTimeout> | null = null
  private confirm: ReturnType<typeof setTimeout> | null = null

  constructor(private readonly deps: SessionControlsDeps) {
    this.element.className = 'sctl'
    this.render()
  }

  /** Ask for the reading. Called once, after the attach is on the wire. */
  start(): void {
    this.ask()
  }

  /**
   * The session produced output and has now gone quiet — the same event the
   * bar above rides, because everything on these chips changes only when the
   * far pty writes: the model line, the effort confirmation, the footer the
   * permission mode is read from, and the composer state behind the gate.
   */
  noteOutput(): void {
    if (this.quiet !== null) clearTimeout(this.quiet)
    this.quiet = setTimeout(() => {
      this.quiet = null
      this.ask()
    }, SETTLE_MS)
  }

  destroy(): void {
    if (this.quiet !== null) clearTimeout(this.quiet)
    this.quiet = null
    if (this.confirm !== null) clearTimeout(this.confirm)
    this.confirm = null
    for (const entry of this.pending.values()) clearTimeout(entry.timer)
    this.pending.clear()
    this.reading = null
    this.busy = null
    this.notice = null
    this.open = null
    this.element.remove()
  }

  /** Frames this cluster asked for. True when it was one, so the router can stop. */
  receive(message: ServerMessage): boolean {
    if (message.t === 'controls.reading') {
      const asked = this.pending.get(message.rid)
      if (asked === undefined || asked.kind !== 'read') return false
      this.settle(message.rid, asked)
      /*
       * The session is checked as well as the `rid`, exactly as the guest
       * checks it: an id only proves this is the answer to *a* question this
       * end asked, and one comparison makes "another session's model on this
       * session's chip" impossible rather than unlikely.
       */
      if (message.id !== asked.id || message.id !== this.deps.sessionId()) return true
      this.reading = message.reading
      this.render()
      return true
    }
    if (message.t === 'controls.applied') {
      const asked = this.pending.get(message.rid)
      if (asked === undefined || asked.kind !== 'apply' || asked.control === undefined) return false
      this.settle(message.rid, asked)
      if (message.id !== asked.id || message.id !== this.deps.sessionId()) return true
      this.busy = null
      // The far end's own words, verbatim — "Model is now Sonnet 5…", "Fast
      // mode requires usage credits…" — never a sentence composed here.
      this.say({ ok: message.ok, text: message.message })
      this.reading = appliedTo(this.reading, asked.control, message.reading)
      // And a fresh read of the whole cluster, the desktop's `finally`: an
      // apply can move more than its own chip (picking a model turns fast mode
      // off), and the answer carried only one reading.
      this.ask()
      this.render()
      return true
    }
    return false
  }

  /* ------------------------------------------------------------- asking -- */

  private settle(key: string, entry: Pending): void {
    clearTimeout(entry.timer)
    this.pending.delete(key)
  }

  private ask(): void {
    const id = this.deps.sessionId()
    if (id === null || !this.deps.capabilities().includes(CAPABILITY.controls)) return
    const key = rid()
    if (!this.deps.send({ t: 'controls.read', rid: key, id })) return
    const timer = setTimeout(() => {
      // A read nobody answered keeps the previous values: they are still the
      // last thing genuinely read, and blanking them would be a regression in
      // honesty rather than an improvement. (Before the first answer there is
      // nothing on screen to blank, which is its own honest state.)
      this.pending.delete(key)
    }, READ_TIMEOUT_MS)
    this.pending.set(key, { kind: 'read', id, timer })
  }

  private apply(control: ControlName, value: string): void {
    const id = this.deps.sessionId()
    if (id === null || this.busy !== null) return
    const key = rid()
    this.open = null
    if (!this.deps.send({ t: 'controls.apply', rid: key, id, control, value })) {
      this.say({ ok: false, text: NOT_CONNECTED })
      this.render()
      return
    }
    const timer = setTimeout(() => {
      if (!this.pending.delete(key)) return
      this.busy = null
      this.say({ ok: false, text: NO_ANSWER })
      // Asked rather than assumed, because the change may well have landed —
      // see NO_ANSWER — and a fresh reading is the only honest tiebreak.
      this.ask()
      this.render()
    }, APPLY_TIMEOUT_MS)
    this.pending.set(key, { kind: 'apply', control, id, timer })
    this.busy = control
    this.say(null)
    this.render()
  }

  /** One place owns the notice's clock: a confirmation expires, a failure stays. */
  private say(notice: { ok: boolean; text: string } | null): void {
    if (this.confirm !== null) clearTimeout(this.confirm)
    this.confirm = null
    this.notice = notice
    if (notice !== null && notice.ok) {
      this.confirm = setTimeout(() => {
        this.confirm = null
        this.notice = null
        this.render()
      }, CONFIRM_MS)
    }
  }

  /* ------------------------------------------------------------ drawing -- */

  private render(): void {
    const reading = this.reading
    if (!clusterShown(reading) || reading === null) {
      /*
       * `hidden` on a flex container needs its own CSS rule — the escape hatch
       * `.sbar` and every hidden flex block in this stylesheet carry, which
       * `tests/layout.test.ts` makes each new one answer for. Hidden rather
       * than emptied because an empty row is still a 1px rule across the top of
       * a terminal, which reads as a rendering fault rather than a decision.
       */
      this.element.hidden = true
      this.element.replaceChildren()
      return
    }
    this.element.hidden = false
    const parts: HTMLElement[] = [
      this.chip('model', reading),
      this.chip('effort', reading),
      this.chip('permission', reading),
    ]
    if (this.notice !== null) parts.push(this.noticeRow(this.notice))
    if (this.open !== null) parts.push(this.sheet(this.open, reading))
    this.element.replaceChildren(...parts)
  }

  /**
   * One chip: the value and a caret, the control's name in the accessible
   * label only.
   *
   * A blocked chip opens like any other — onto its rows, with the reason as a
   * line above them. What the block costs the chip is its colour and its
   * announcement, so the state is known before the tap and again after it; what
   * it does not cost is the list, which is what he came for.
   *
   * The one state where the chip itself refuses to open is another control
   * mid-change: that is a queue rather than a block, there is nothing to read
   * about it, and two commands must never race into one pty.
   */
  private chip(control: 'model' | 'effort' | 'permission', reading: ControlsReadingWire): HTMLElement {
    const button = document.createElement('button')
    button.className = 'sctl__chip'
    button.type = 'button'
    const name = controlName(control)
    // The model chip is also where fast mode lives, so its work shows there.
    const working = this.busy === control || (control === 'model' && this.busy === 'fast')
    const text = working ? 'Working…' : chipText(control, reading)
    const blocked = blockedFor(control, reading)
    // The value first and the reason after it, because the value is what the
    // chip is for: a reader who wants only the state should not have to sit
    // through a sentence to reach it. The reason no longer *replaces* the value
    // here for the same reason it no longer replaces the rows below.
    const spoken = blocked === null ? `${name}: ${text}` : `${name}: ${text}. ${blocked}`
    button.title = spoken
    button.setAttribute('aria-label', spoken)
    button.setAttribute('aria-haspopup', 'menu')
    button.setAttribute('aria-expanded', this.open === control ? 'true' : 'false')
    if (blocked !== null) {
      button.setAttribute('aria-disabled', 'true')
      button.dataset.blocked = 'yes'
    }
    if (working) button.dataset.busy = 'yes'
    // While one control is mid-change the others wait their turn — two
    // commands must never race into one pty — and unlike a blocked chip this
    // really is disabled: there is nothing to read about a queue, and the rows
    // a blocked chip opens onto are worth reading.
    if (this.busy !== null && !working) button.disabled = true
    const value = document.createElement('span')
    value.textContent = text
    button.append(value, caret())
    button.addEventListener('click', () => {
      this.open = this.open === control ? null : control
      this.render()
    })
    return button
  }

  /**
   * An open chip's sheet: the reason as a line when there is one, and the rows
   * — always the rows — and, at the end of the model sheet, fast mode, which is
   * where the desktop keeps it (*"move fast mode toggle inside the models
   * dropdown at the end"*) because the CLI couples them: switching model turns
   * fast mode off.
   *
   * The sheet's own reason is handed on to fast mode so the session's typing
   * gate cannot print one sentence twice in one sheet. See `fastPlan`.
   */
  private sheet(control: 'model' | 'effort' | 'permission', reading: ControlsReadingWire): HTMLElement {
    const list = document.createElement('div')
    list.className = 'sctl__sheet'
    list.setAttribute('role', 'menu')
    list.setAttribute('aria-label', controlName(control))
    const plan = sheetPlan(control, reading)
    if (plan.reason !== null) list.append(reasonLine(plan.reason))
    for (const option of plan.rows) {
      if (option.group !== undefined) list.append(caption(option.group))
      list.append(this.row(control, option, chosen(reading[control], option), plan.usable))
    }
    if (control === 'model') this.fastSection(list, reading, plan.reason)
    return list
  }

  /**
   * One option row. `usable` false draws it and refuses the press: the row is
   * still worth reading — it is where the tick is — and a press answered only
   * by a refusal is the dead click this app keeps being audited for.
   */
  private row(control: ControlName, option: ControlOption, current: boolean, usable: boolean): HTMLElement {
    const button = document.createElement('button')
    button.className = 'sctl__row'
    button.type = 'button'
    button.setAttribute('role', 'menuitemradio')
    button.setAttribute('aria-checked', current ? 'true' : 'false')
    if (current) button.dataset.chosen = 'yes'
    if (!usable) markBlocked(button)
    const tick = document.createElement('i')
    tick.className = 'sctl__tick'
    tick.setAttribute('aria-hidden', 'true')
    tick.textContent = current ? '✓' : ''
    const text = document.createElement('span')
    text.className = 'sctl__text'
    const label = document.createElement('span')
    label.textContent = option.label
    text.append(label)
    if (option.hint !== undefined) {
      const hint = document.createElement('span')
      hint.className = 'sctl__hint'
      hint.textContent = option.hint
      text.append(hint)
    }
    button.append(tick, text)
    // Pressed rather than short-circuited even on the current row, which is
    // what the desktop does: the CLI answers "Kept model as …", and that
    // sentence in the notice is a better receipt than a menu that silently
    // closed.
    button.addEventListener('click', () => this.apply(control, option.id))
    return button
  }

  /**
   * Fast mode, at the end of the model sheet: a switch once its position has
   * been read, and the two rows under a caption while nothing has said which it
   * is — never a switch drawn at a position nobody established.
   *
   * A block used to replace all of that with the far end's sentence, which is
   * the same fault the chips above had and is fixed the same way: the reason
   * goes above the control, the control stays on screen showing what is in
   * force, and it does not take a press. *"Fast mode requires usage credits"* is
   * worth reading beside a switch that says Off; it is not worth reading instead
   * of one.
   */
  private fastSection(list: HTMLElement, reading: ControlsReadingWire, alreadySaid: string | null): void {
    const fast = reading.fast
    const plan = fastPlan(reading, alreadySaid)
    list.append(caption(controlName('fast')))
    if (plan.reason !== null) list.append(reasonLine(plan.reason))
    if (plan.shape === 'rows') {
      for (const option of FAST_OPTIONS) list.append(this.row('fast', option, false, plan.usable))
      return
    }
    const on = plan.on
    const button = document.createElement('button')
    button.className = 'sctl__row sctl__switch'
    button.type = 'button'
    button.setAttribute('role', 'menuitemcheckbox')
    button.setAttribute('aria-checked', on ? 'true' : 'false')
    // Drawn at the position the session is at, and refusing the press: what is
    // in force is the thing worth seeing while it cannot be changed. The second
    // arm is the queue rather than a block — another control is mid-change, and
    // a switch that quietly did nothing would be the dead click again.
    if (!plan.usable || (this.busy !== null && this.busy !== 'fast')) markBlocked(button)
    const text = document.createElement('span')
    text.className = 'sctl__text'
    const label = document.createElement('span')
    label.textContent = controlName('fast')
    const hint = document.createElement('span')
    hint.className = 'sctl__hint'
    // The four words that must be read *here*, beside the rows they are about:
    // pick another model and fast mode goes off with nothing else saying so.
    hint.textContent = 'off if you switch model'
    text.append(label, hint)
    button.append(text)
    if (this.busy === 'fast') {
      // A switch mid-flight has no honest position — neither where it was nor
      // where it is going — so the word replaces the picture.
      const working = document.createElement('span')
      working.className = 'sctl__hint'
      working.textContent = 'Working…'
      button.append(working)
    } else {
      const track = document.createElement('span')
      track.className = 'sctl__track'
      track.setAttribute('aria-hidden', 'true')
      if (on) track.dataset.on = 'yes'
      const knob = document.createElement('span')
      knob.className = 'sctl__knob'
      track.append(knob)
      button.append(track)
    }
    button.addEventListener('click', () => this.apply('fast', fastFlip(fast)))
    list.append(button)
  }

  /**
   * What the session said about the last change — the CLI's own sentence,
   * with a dismiss. `role="status"` so a screen reader hears it land.
   */
  private noticeRow(notice: { ok: boolean; text: string }): HTMLElement {
    const row = document.createElement('p')
    row.className = 'sctl__notice'
    if (!notice.ok) row.dataset.bad = 'yes'
    row.setAttribute('role', 'status')
    const text = document.createElement('span')
    text.textContent = notice.text
    const close = document.createElement('button')
    close.className = 'sctl__close'
    close.type = 'button'
    close.setAttribute('aria-label', 'Dismiss')
    close.textContent = '×'
    close.addEventListener('click', () => {
      this.say(null)
      this.render()
    })
    row.append(text, close)
    return row
  }
}

/* The fragments every sheet shares. Module-level because they hold no state. */

function caption(text: string): HTMLElement {
  const head = document.createElement('p')
  head.className = 'sctl__group'
  head.setAttribute('role', 'presentation')
  head.textContent = text
  return head
}

/**
 * The one short line a block gets, above the rows it does not replace.
 *
 * Deliberately quieter than the rows and deliberately not styled as an error:
 * nothing has failed, and every state that reaches here — a turn in flight, a
 * dialog on screen, an account without the credits for fast mode — is a fact
 * about right now rather than about this control.
 */
function reasonLine(text: string): HTMLElement {
  const p = document.createElement('p')
  p.className = 'sctl__blocked'
  p.textContent = text
  return p
}

/**
 * Draw a row back and stop it taking a press.
 *
 * Both halves, always together, which is the point of it being one function: a
 * row that refuses a press while still looking pressable is the dead click, and
 * a row that looks unavailable while still firing is worse. `disabled` is what
 * announces it and what swallows the press; the dim is the same picture the chip
 * above it wears for the same fact.
 */
function markBlocked(button: HTMLButtonElement): void {
  button.disabled = true
  button.dataset.blocked = 'yes'
  button.style.opacity = '0.45'
  button.style.cursor = 'default'
}

function caret(): HTMLElement {
  const mark = document.createElement('span')
  mark.className = 'sctl__caret'
  mark.setAttribute('aria-hidden', 'true')
  mark.innerHTML =
    '<svg viewBox="0 0 12 12" width="10" height="10"><path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>'
  return mark
}
