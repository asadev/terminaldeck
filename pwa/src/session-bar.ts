/**
 * The three things a session's bar says on a Mac, on a phone.
 *
 * Asad, 2026-08-20: *"app needs enrichment"* — and, about the same three chips
 * on a remote session at the desk, *"I want it exactly like the local ones"*.
 * The phone had none of them: no usage figure, no context figure, no account.
 * It listed sessions and drew a terminal, and everything the desktop's bar tells
 * you about the session you are inside stopped at the edge of the app.
 *
 * ## Nothing new is on the wire, and that is the finding
 *
 * `CAPABILITY.usage` and `CAPABILITY.account` have shipped since 2026-08-18.
 * `host-core.ts` wires `createUsageServe` and `createAccountServe` into the same
 * fanout that serves this client, so a desktop is *already* answering
 * `usage.read` and `account.read`/`account.switch` for whoever asks. The two
 * clients that ask are the desktop's own remote window and iOS. This browser —
 * the client he actually opens on his phone, because it needs no TestFlight
 * build — never sent one of those frames.
 *
 * So this module is a client, not a feature. Every figure here is the far
 * machine's own, read by the same `readUsage`, `readContextWindow` and
 * `sessionAccount` that draw the bar at the desk, which is what keeps one
 * session from having two different truths depending on which screen is looking.
 *
 * ## Which shapes are mirrored and which are read raw
 *
 * `usage.reading` carries `Record<string, unknown>` — the far machine's own
 * record — because the client that shape was designed for is another copy of
 * this app. This one is not, so the two readers below narrow field by field and
 * answer null for anything they cannot read. A figure this build does not
 * understand is a chip that is not drawn, never a chip drawn with a guess.
 *
 * ## What it deliberately does not draw
 *
 * Words. There is no sentence anywhere in here — no "not reported", no "this
 * session is on", no reason string, no label under a number. A chip whose figure
 * is unknown is **absent**, which is the same rule the desktop's remote bar
 * follows and the one he has now stated four times. The `title` and `aria-label`
 * attributes carry what a screen reader needs; the screen carries a ring, a bar,
 * a dot and a name.
 *
 * ## Polling
 *
 * None. `context` and `plan` are asked once on attach and then only when the
 * session's own output goes quiet — the same event the desktop's bar rides —
 * with `plan` throttled because it is a memory read on the far side but still a
 * round trip. `refresh` is only ever sent because somebody pressed the ring.
 */

import type { AccountWire, ClientMessage, ServerMessage, UsageWant } from '../../src/main/remote/protocol'

/* --------------------------------------------------------------- reading -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * A fraction in 0..1, or null.
 *
 * Bounded rather than trusted. The far end reports a fraction and a bar drawn
 * from 3.4 is a bar that leaves its own frame — which is literally the defect he
 * filmed on the desktop (*"this window is going out of the frame"*), one element
 * down.
 */
function fraction(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null
  return Math.min(1, Math.max(0, value))
}

/**
 * The highest plan window a report carries, as a fraction.
 *
 * The highest rather than a chosen one: a person is limited by whichever window
 * they are nearest the end of, and picking "the five-hour one" would draw a calm
 * ring while the weekly window is what actually stops them working. The desktop's
 * own bar orders by `sortReadings` and shows them all; a ring is one number, so
 * it is the worst one.
 *
 * `used` is a union — `{ state: 'reported', fraction }` or `{ state:
 * 'not-reported' }` — precisely so that nothing can `?? 0` its way past the
 * difference, and this reader keeps that: a report whose every window is
 * unreported answers null, which draws no ring at all rather than an empty one
 * that reads as "you have used nothing".
 */
export function planFraction(reading: unknown): number | null {
  if (!isRecord(reading) || !Array.isArray(reading.readings)) return null
  let worst: number | null = null
  for (const row of reading.readings) {
    if (!isRecord(row) || !isRecord(row.used)) continue
    if (row.used.state !== 'reported') continue
    const used = fraction(row.used.fraction)
    if (used === null) continue
    if (worst === null || used > worst) worst = used
  }
  return worst
}

/**
 * How full the context window is, as a fraction.
 *
 * `percent` on the far end's record is 0..100 — `emptyUsageReading` writes it as
 * null and `readContextWindow` as a percentage — so it is divided here and
 * nowhere else. `state` is what says whether there is a figure at all: anything
 * other than a live reading answers null and the bar is not drawn.
 */
export function contextFraction(reading: unknown): number | null {
  if (!isRecord(reading)) return null
  if (reading.state === 'not-reported') return null
  if (typeof reading.percent !== 'number' || !Number.isFinite(reading.percent)) return null
  return fraction(reading.percent / 100)
}

/** What a chip prints inside itself. Whole percent, never a decimal on a phone. */
export function percentText(value: number): string {
  return `${Math.round(value * 100)}%`
}

/* ----------------------------------------------------------------- state -- */

export interface SessionBarState {
  /** Null until an answer has arrived, and again whenever there is no figure. */
  plan: number | null
  context: number | null
  account: AccountWire | null
  accounts: AccountWire[]
  /** A `refresh` is in flight, or an account switch is. */
  busy: boolean
  /** The account sheet is open. */
  picking: boolean
}

export const NO_BAR: SessionBarState = {
  plan: null,
  context: null,
  account: null,
  accounts: [],
  busy: false,
  picking: false,
}

/* -------------------------------------------------------------- the view -- */

export interface SessionBarDeps {
  /** True from the socket, false while it is down. Nothing is asked while false. */
  send: (message: ClientMessage) => boolean
  /** Which of `usage` and `account` this machine advertised. */
  capabilities: () => readonly string[]
  /** The session this bar is about, or null when nothing is attached. */
  sessionId: () => string | null
  now?: () => number
}

/** How long before a quiet session's plan figure is worth asking for again. */
export const PLAN_THROTTLE_MS = 60_000

/**
 * A request id nothing else will mint.
 *
 * `rid` is what makes two panels asking two questions of one machine able to
 * tell the answers apart, and this client can have a terminal and a copilot in
 * flight at once.
 */
let counter = 0
function rid(): string {
  counter += 1
  return `bar-${counter}-${Math.random().toString(36).slice(2, 8)}`
}

/**
 * The dot's colour, or null.
 *
 * `AccountWire.color` is a custom property **name** — `--accent`,
 * `--status-completed` — and never a colour value, so the palette stays in one
 * stylesheet and a machine cannot send `#c96` over a wire. The desktop's own
 * chip writes `var(${account.color})`, dashes and all, which is what this had to
 * match: `var(--${color})` produces `var(----accent)` and paints nothing, which
 * is exactly how the dot came out blank the first time this was rendered.
 *
 * Checked rather than interpolated, because this string arrives from another
 * machine and lands inside a style attribute. Anything that is not a plain
 * custom-property name is dropped and the dot keeps the neutral fill its class
 * gives it.
 */
export function accountDotColor(color: string | null): string | null {
  if (color === null || !/^--[a-z0-9-]{1,40}$/i.test(color)) return null
  return `var(${color})`
}

/**
 * Is this a login of a *different* agent than the session is running?
 *
 * `account.read` answers with every login the machine has, across agents —
 * `listProfiles()` is not filtered by provider and should not be, because the
 * chip has to be able to name whatever the current account is. Which of them can
 * be *pressed* is the client's decision, and it is the same one
 * `MachineAccountChip` makes at the desk from the same two fields.
 *
 * It matters because the far side already refuses the switch:
 * `session-switch.ts` answers *"… is a Codex CLI login and this session is
 * running Claude Code"* and stops. Nothing on this bar draws that sentence — and
 * nothing should, per *"don't put any single statement in anywhere"* — so a
 * pressable row was a press that spun the chip and then changed nothing at all.
 * Measured on 2026-08-20 from a phone against a real Claude session on this Mac:
 * pressing *Default (Codex CLI)* did nothing, said nothing and left no trace.
 *
 * Both providers have to be *known* before two of them can be said to differ. A
 * row whose own provider is null stays pressable rather than being greyed out
 * because an older machine did not name its agent.
 */
export function foreignAccount(current: AccountWire | null, account: AccountWire): boolean {
  if (current === null || current.provider === null || account.provider === null) return false
  return account.provider !== current.provider
}

export class SessionBar {
  readonly element = document.createElement('div')

  private state: SessionBarState = { ...NO_BAR }
  private readonly pending = new Map<string, UsageWant | 'account' | 'switch'>()
  private askedPlanAt = 0
  private quiet: ReturnType<typeof setTimeout> | null = null
  private readonly now: () => number

  constructor(private readonly deps: SessionBarDeps) {
    this.now = deps.now ?? Date.now
    this.element.className = 'sbar'
    this.render()
  }

  /** Ask for everything this machine will answer. Called once, on attach. */
  start(): void {
    this.askUsage('context')
    this.askPlan()
    this.askAccount()
  }

  /**
   * The session produced output and has now gone quiet.
   *
   * The same event the desktop's own bar rides, rather than a timer: a context
   * window only moves when the agent writes to its transcript, and a phone that
   * asked on a clock would be a phone dialling a relay every few seconds to be
   * told the same number.
   */
  noteOutput(): void {
    if (this.quiet !== null) clearTimeout(this.quiet)
    this.quiet = setTimeout(() => {
      this.quiet = null
      this.askUsage('context')
      this.askPlan()
    }, 1200)
  }

  destroy(): void {
    if (this.quiet !== null) clearTimeout(this.quiet)
    this.quiet = null
    this.pending.clear()
    this.state = { ...NO_BAR }
    this.element.remove()
  }

  /** Frames this bar asked for. True when it was one, so the router can stop. */
  receive(message: ServerMessage): boolean {
    if (message.t === 'usage.reading') {
      const want = this.pending.get(message.rid)
      if (want === undefined) return false
      this.pending.delete(message.rid)
      const reading = message.answer.reading
      if (want === 'context') this.state.context = contextFraction(reading)
      else {
        // A `refresh` answers with the outcome *and* the report; a `plan` answers
        // with the report alone. One reader, because the figure lives in the same
        // place in both and inventing a second path is how they come apart.
        const report = want === 'refresh' && isRecord(reading) ? reading.report : reading
        this.state.plan = planFraction(report)
        this.state.busy = false
      }
      this.render()
      return true
    }
    if (message.t === 'account.state') {
      if (!this.pending.delete(message.rid)) return false
      this.state.account = message.current
      this.state.accounts = message.accounts
      this.render()
      return true
    }
    if (message.t === 'account.switched') {
      if (!this.pending.delete(message.rid)) return false
      this.state.busy = false
      this.state.picking = false
      // Asked again rather than assumed: the far end decides whether a switch
      // took, and a chip that renamed itself on the press would be the one
      // surface that disagrees with the machine.
      this.askAccount()
      this.render()
      return true
    }
    return false
  }

  /* ------------------------------------------------------------- asking -- */

  private askUsage(want: UsageWant): void {
    const id = this.deps.sessionId()
    if (id === null || !this.deps.capabilities().includes('usage')) return
    const key = rid()
    if (!this.deps.send({ t: 'usage.read', rid: key, id, want, force: want === 'refresh' })) return
    this.pending.set(key, want)
    if (want === 'refresh') {
      this.state.busy = true
      this.render()
    }
  }

  private askPlan(): void {
    if (this.now() - this.askedPlanAt < PLAN_THROTTLE_MS) return
    this.askedPlanAt = this.now()
    this.askUsage('plan')
  }

  private askAccount(): void {
    const id = this.deps.sessionId()
    if (id === null || !this.deps.capabilities().includes('account')) return
    const key = rid()
    if (!this.deps.send({ t: 'account.read', rid: key, id })) return
    this.pending.set(key, 'account')
  }

  private switchTo(accountId: string): void {
    const id = this.deps.sessionId()
    if (id === null) return
    const key = rid()
    if (!this.deps.send({ t: 'account.switch', rid: key, id, accountId })) return
    this.pending.set(key, 'switch')
    this.state.busy = true
    this.render()
  }

  /* ------------------------------------------------------------ drawing -- */

  private render(): void {
    const parts: HTMLElement[] = []
    if (this.state.plan !== null) parts.push(this.ring(this.state.plan))
    if (this.state.context !== null) parts.push(this.contextBar(this.state.context))
    if (this.state.account !== null) parts.push(this.accountChip(this.state.account))
    /*
     * The `hidden` attribute, not a `data-` flag, and it needs a rule of its own.
     *
     * This is a flex container, and a flex container ignores `hidden` — the
     * escape hatch `.tabs`, `.ask`, `.dock` and `.sheet` each carry, and which
     * `tests/layout.test.ts` makes every new flex block in this stylesheet answer
     * for. Hidden rather than emptied because an empty row is still a 1px rule
     * across the top of a terminal, which reads as a rendering fault rather than
     * as a decision.
     */
    this.element.hidden = parts.length === 0
    this.element.replaceChildren(...parts)
    if (this.state.picking) this.element.append(this.sheet())
  }

  /**
   * The usage ring.
   *
   * His choice, in as many words, and the fourth time this figure has been drawn
   * a different way: *"give it a maybe ring icon will be better, just like
   * cloud, like this ring."* A circle whose stroke is dashed to the fraction,
   * with the number inside it — nothing else, and no label beside it.
   *
   * Pressing it is `refresh`, which is the one reading that costs anything over
   * there, so it happens because a person asked and never on its own.
   */
  private ring(used: number): HTMLElement {
    const button = document.createElement('button')
    button.className = 'sbar__ring'
    button.type = 'button'
    button.setAttribute('aria-label', `Usage ${percentText(used)}`)
    button.title = `Usage ${percentText(used)}`
    if (this.state.busy) button.dataset.busy = 'yes'
    // The stroke length of a circle of r=9, so the dash can be written as a
    // fraction of it without the stylesheet needing to know the radius.
    const circumference = 2 * Math.PI * 9
    button.innerHTML =
      `<svg viewBox="0 0 24 24" aria-hidden="true">` +
      `<circle class="sbar__track" cx="12" cy="12" r="9"></circle>` +
      `<circle class="sbar__used" cx="12" cy="12" r="9" ` +
      `stroke-dasharray="${(circumference * used).toFixed(2)} ${circumference.toFixed(2)}"></circle>` +
      `</svg>`
    const figure = document.createElement('span')
    figure.textContent = percentText(used)
    button.append(figure)
    button.addEventListener('click', () => this.askUsage('refresh'))
    return button
  }

  /**
   * The context window, as a bar.
   *
   * *"context window should be a bar instead of numbers. It should be a bar."*
   * The number stays beside it because a bar with no figure cannot be compared
   * to the one on the Mac, and one figure is not a statement.
   */
  private contextBar(used: number): HTMLElement {
    const wrap = document.createElement('div')
    wrap.className = 'sbar__ctx'
    wrap.setAttribute('role', 'img')
    wrap.setAttribute('aria-label', `Context ${percentText(used)}`)
    wrap.title = `Context ${percentText(used)}`
    const track = document.createElement('i')
    const fill = document.createElement('i')
    fill.style.width = `${(used * 100).toFixed(1)}%`
    // Three bands, the same three the desktop's own context readout uses, and
    // the only thing that says "you are near the end" without a sentence.
    fill.dataset.level = used >= 0.9 ? 'critical' : used >= 0.75 ? 'warning' : 'ok'
    track.append(fill)
    const figure = document.createElement('span')
    figure.textContent = percentText(used)
    wrap.append(track, figure)
    return wrap
  }

  /**
   * Whose login this session is on, and the way to change it.
   *
   * *"bring the account selection here for the remote sessions too"* — said
   * about a session on his PC, and true twice over of a session seen from a
   * phone. The dot is `AccountWire.color`, which is a custom property name and
   * never a colour value, so the palette stays in one stylesheet.
   */
  private accountChip(account: AccountWire): HTMLElement {
    const button = document.createElement('button')
    button.className = 'sbar__acct'
    button.type = 'button'
    button.title = account.name
    button.setAttribute('aria-label', `Account: ${account.name}`)
    button.setAttribute('aria-haspopup', 'menu')
    button.setAttribute('aria-expanded', this.state.picking ? 'true' : 'false')
    if (this.state.busy) button.dataset.busy = 'yes'
    const dot = document.createElement('i')
    dot.className = 'sbar__dot'
    const tint = accountDotColor(account.color)
    if (tint !== null) dot.style.background = tint
    const name = document.createElement('span')
    name.textContent = account.name
    button.append(dot, name)
    button.addEventListener('click', () => {
      this.state.picking = !this.state.picking
      this.render()
    })
    return button
  }

  /** See {@link foreignAccount}, which owns the rule. */
  private foreign(account: AccountWire): boolean {
    return foreignAccount(this.state.account, account)
  }

  private sheet(): HTMLElement {
    const list = document.createElement('div')
    list.className = 'sbar__sheet'
    list.setAttribute('role', 'menu')
    for (const account of this.state.accounts) {
      const chosen = this.state.account !== null && account.id === this.state.account.id
      const foreign = this.foreign(account)
      // A `div` rather than a disabled `button`, which is what the desktop's own
      // menu does: a row that cannot be pressed should not look like something
      // that is merely unavailable right now, and a screen reader is told with
      // `aria-disabled` rather than by the row vanishing.
      const row = document.createElement(foreign ? 'div' : 'button')
      row.className = 'sbar__row'
      if (row instanceof HTMLButtonElement) row.type = 'button'
      row.setAttribute('role', 'menuitemradio')
      row.setAttribute('aria-checked', chosen ? 'true' : 'false')
      if (chosen) row.dataset.chosen = 'yes'
      if (foreign) {
        row.dataset.inert = 'yes'
        row.setAttribute('aria-disabled', 'true')
      }
      const dot = document.createElement('i')
      dot.className = 'sbar__dot'
      const tint = accountDotColor(account.color)
      if (tint !== null) dot.style.background = tint
      const name = document.createElement('span')
      name.textContent = account.name
      row.append(dot, name)
      if (!foreign) {
        row.addEventListener('click', () => {
          this.state.picking = false
          if (!chosen) this.switchTo(account.id)
          else this.render()
        })
      }
      list.append(row)
    }
    return list
  }
}
