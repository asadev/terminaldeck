/**
 * The "This server" section of the phone's Settings screen.
 *
 * Two settings this machine owns rather than this browser — the coding tool a
 * fresh session starts with, and whether the last layout is restored at launch —
 * reached over the `settings` capability the desktop-as-guest and the headless
 * host both serve. Everything else in Settings is the browser's own; these two
 * are facts about the machine at the other end, the same on every device that
 * reaches it, so changing one here changes the server.
 *
 * ## The vocabulary and the wire are imported, not copied
 *
 * The keys, the frame shapes and the byte caps come from
 * `src/main/remote/protocol.ts` — the one wire-truth file, which `upload.test.ts`
 * already lists as a deliberate crossing. `SERVER_SETTINGS` is the closed
 * allowlist, so the picker cannot compose a `settings.apply` for a key the
 * parser would refuse; the only thing kept locally is a four-entry label map for
 * the builtin provider ids, and a provider it does not recognise (a `custom:`
 * agent) simply shows its id.
 *
 * ## Honest states, the same rules the control cluster follows
 *
 * Nothing is drawn until a `settings.state` answers, and nothing at all over a
 * machine whose welcome did not name `settings` — so an older desktop or a guest
 * device gets a Settings screen that is exactly what it was rather than a section
 * explaining what it is missing. While an apply is in flight both controls lock
 * and the pressed one reads "Working…" (two writes never race into one store).
 * The value shown is always the machine's own re-read from `settings.applied`,
 * never the pressed value, so a refused apply reverts by construction; a refusal
 * keeps the server's own sentence until the next action, a confirmation clears
 * itself, and an apply nobody answered times out into a fresh read.
 */

import {
  CAPABILITY,
  SERVER_SETTINGS,
  settingFlag,
  type ClientMessage,
  type ServerMessage,
  type ServerSettingKey,
  type ServerSettingWire,
} from '../../src/main/remote/protocol'

export const READ_TIMEOUT_MS = 20_000
export const APPLY_TIMEOUT_MS = 60_000
const CONFIRM_MS = 4000

/**
 * The builtin provider ids, in the words the desktop's own picker uses. A
 * `custom:` agent or an id this build has not heard of shows as itself — better
 * a readable id than a guessed label.
 */
const PROVIDER_LABELS: Record<string, string> = {
  claude: 'Claude Code',
  codex: 'Codex CLI',
  gemini: 'Gemini CLI',
  shell: 'Plain shell',
}

export function providerLabel(id: string): string {
  return PROVIDER_LABELS[id] ?? id
}

/**
 * Merge machine-sent rows into the held set, replacing by key and keeping the
 * order of {@link SERVER_SETTINGS} so the section never reshuffles on a push. A
 * pure function so the merge — the one piece of `receive` with a decision in it —
 * can be tested where the DOM `render` cannot be. Rows the parser has already
 * dropped never reach here; a key not in the allowlist cannot occur.
 */
export function mergeRows(
  current: readonly ServerSettingWire[] | null,
  next: readonly ServerSettingWire[],
): ServerSettingWire[] {
  const byKey = new Map<ServerSettingKey, ServerSettingWire>()
  for (const row of current ?? []) byKey.set(row.key, row)
  for (const row of next) byKey.set(row.key, row)
  return SERVER_SETTINGS.map((key) => byKey.get(key)).filter(
    (row): row is ServerSettingWire => row !== undefined,
  )
}

export interface ServerSettingsDeps {
  /** True from the socket, false while it is down. */
  send: (message: ClientMessage) => boolean
  /** What the machine advertised. Nothing is asked without `settings` in it. */
  capabilities: () => readonly string[]
}

interface Pending {
  kind: 'read' | 'apply'
  /** Which setting an apply was for; reads carry none. */
  key?: ServerSettingKey
  timer: ReturnType<typeof setTimeout>
}

/** A request id nothing else will mint. Same scheme the control cluster uses, its own prefix. */
let counter = 0
function rid(): string {
  counter += 1
  return `set-${counter}-${Math.random().toString(36).slice(2, 8)}`
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag)
  node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

export class ServerSettings {
  readonly element = document.createElement('div')

  private rows: ServerSettingWire[] | null = null
  /** Sent a read on this connection already — reset by `renew` on each welcome. */
  private requested = false
  private busy: ServerSettingKey | null = null
  private notice: { ok: boolean; text: string } | null = null
  private readonly pending = new Map<string, Pending>()
  private confirm: ReturnType<typeof setTimeout> | null = null

  constructor(private readonly deps: ServerSettingsDeps) {
    this.element.className = 'srvset'
    this.render()
  }

  /** Whether this machine serves the two settings at all. */
  offered(): boolean {
    return this.deps.capabilities().includes(CAPABILITY.settings)
  }

  /**
   * Ask for the settings once, when the screen that shows them is opened. A no-op
   * over a machine that does not serve them, and a no-op after the first ask on a
   * connection — the `settings.changed` push keeps the rows fresh without a poll.
   */
  ensureRead(): void {
    if (!this.offered() || this.requested || this.rows !== null) return
    this.ask()
  }

  /**
   * A new welcome: forget what the last machine said and re-read on the next
   * visit. Called for every welcome, because the machine on the other end can
   * change — a re-pair, a switch between two paired hosts.
   */
  renew(): void {
    for (const entry of this.pending.values()) clearTimeout(entry.timer)
    this.pending.clear()
    if (this.confirm !== null) clearTimeout(this.confirm)
    this.confirm = null
    this.rows = null
    this.requested = false
    this.busy = null
    this.notice = null
    this.render()
  }

  private ask(): void {
    if (!this.offered()) return
    const key = rid()
    if (!this.deps.send({ t: 'settings.read', rid: key })) return
    this.requested = true
    this.pending.set(key, {
      kind: 'read',
      timer: setTimeout(() => {
        this.pending.delete(key)
        // A read that never answered is not an error to show — the screen simply
        // stays as it was, and the next visit tries again.
        this.requested = false
      }, READ_TIMEOUT_MS),
    })
  }

  private apply(key: ServerSettingKey, value: string): void {
    if (this.busy !== null) return
    const requestId = rid()
    if (!this.deps.send({ t: 'settings.apply', rid: requestId, key, value })) return
    this.busy = key
    this.notice = null
    this.pending.set(requestId, {
      kind: 'apply',
      key,
      timer: setTimeout(() => {
        this.pending.delete(requestId)
        if (this.busy !== key) return
        this.busy = null
        // The guest's own no-claim sentence, and a fresh read to settle on what
        // the machine actually holds.
        this.say({ ok: false, text: 'The server did not answer; nothing was changed.' })
        this.requested = false
        this.ask()
        this.render()
      }, APPLY_TIMEOUT_MS),
    })
    this.render()
  }

  private settle(requestId: string, asked: Pending): void {
    clearTimeout(asked.timer)
    this.pending.delete(requestId)
  }

  private say(notice: { ok: boolean; text: string }): void {
    this.notice = notice
    if (this.confirm !== null) clearTimeout(this.confirm)
    this.confirm = null
    // A confirmation clears itself; a refusal stays until the next action, for
    // the same reason the control cluster keeps its failures on screen.
    if (notice.ok) {
      this.confirm = setTimeout(() => {
        this.confirm = null
        this.notice = null
        this.render()
      }, CONFIRM_MS)
    }
  }

  /** Merge one machine-sent row into the held set, replacing by key. */
  private absorb(next: readonly ServerSettingWire[]): void {
    this.rows = mergeRows(this.rows, next)
  }

  /** Frames this section asked for, or the unsolicited change push. True when handled. */
  receive(message: ServerMessage): boolean {
    if (message.t === 'settings.state') {
      const asked = this.pending.get(message.rid)
      if (asked === undefined || asked.kind !== 'read') return false
      this.settle(message.rid, asked)
      this.rows = [...message.settings]
      this.render()
      return true
    }
    if (message.t === 'settings.applied') {
      const asked = this.pending.get(message.rid)
      if (asked === undefined || asked.kind !== 'apply') return false
      this.settle(message.rid, asked)
      this.busy = null
      // The server's own sentence, verbatim — never one composed here.
      this.say({ ok: message.ok, text: message.message })
      // Settle on the machine's own re-read, whether the apply took or was
      // refused, so a refusal reverts the control by construction.
      this.absorb([message.setting])
      this.render()
      return true
    }
    if (message.t === 'settings.changed') {
      // Unsolicited: another device (or the desktop pane, or the copilot) changed
      // one of these. No rid to match — it answers no ask.
      this.absorb(message.settings)
      this.render()
      return true
    }
    return false
  }

  private render(): void {
    this.element.replaceChildren()
    if (!this.offered()) return

    this.element.append(el('p', 'caption', 'This server'))

    if (this.rows === null) {
      this.element.append(el('p', 'note note--plain', 'Reading this machine’s settings…'))
      return
    }

    const group = el('div', 'group')
    for (const row of this.rows) {
      if (row.key === 'agents.defaultProvider') group.append(this.providerRow(row))
      else if (row.key === 'general.restoreSessions') group.append(this.toggleRow(row))
    }
    this.element.append(group)

    if (this.notice !== null) {
      this.element.append(
        el('p', this.notice.ok ? 'srvset__notice' : 'srvset__notice srvset__notice--bad', this.notice.text),
      )
    }

    this.element.append(
      el(
        'p',
        'note note--plain',
        'These belong to the machine, not this browser — every device that reaches it sees the same two.',
      ),
    )
  }

  private providerRow(row: ServerSettingWire): HTMLElement {
    const block = el('div', 'srvset__row')
    block.append(el('span', 'srvset__title', 'Default coding tool'))
    const options = el('div', 'srvset__options')
    // The ids the host said it can start; if it sent none, the current value is
    // still offered so the control is never empty.
    const ids = row.options && row.options.length > 0 ? row.options : [row.value]
    for (const id of ids) {
      const on = id === row.value
      const button = el('button', on ? 'srvset__option srvset__option--on' : 'srvset__option', providerLabel(id))
      ;(button as HTMLButtonElement).type = 'button'
      if (on) button.setAttribute('aria-pressed', 'true')
      const working = this.busy === row.key
      if (working || on) (button as HTMLButtonElement).disabled = true
      if (!working && !on) {
        button.addEventListener('click', () => this.apply('agents.defaultProvider', id))
      }
      options.append(button)
    }
    block.append(options)
    if (this.busy === row.key) block.append(el('span', 'srvset__working', 'Working…'))
    return block
  }

  /**
   * The switch, in three states. See {@link settingFlag} — a row whose value is
   * not one of the two words is *not told*, and drawing it as **Off** is how
   * this browser and the phone both claimed a machine was not restoring
   * sessions when neither had been told either way. It also refuses the press:
   * a control that sends `apply` from a state it does not know can turn a
   * setting off by being tapped while it was still catching up.
   */
  private toggleRow(row: ServerSettingWire): HTMLElement {
    const flag = settingFlag(row.value)
    const block = el('button', 'setting srvset__toggle')
    ;(block as HTMLButtonElement).type = 'button'
    block.append(el('span', 'setting__title', 'Restore sessions at launch'))
    const working = this.busy === row.key
    const reading = working ? 'Working…' : flag === null ? '—' : flag ? 'On' : 'Off'
    block.append(el('span', 'setting__value', reading))
    if (flag !== null) block.setAttribute('aria-pressed', flag ? 'true' : 'false')
    if (working || flag === null) {
      ;(block as HTMLButtonElement).disabled = true
    } else {
      block.addEventListener('click', () => this.apply('general.restoreSessions', flag ? 'false' : 'true'))
    }
    return block
  }

  destroy(): void {
    for (const entry of this.pending.values()) clearTimeout(entry.timer)
    this.pending.clear()
    if (this.confirm !== null) clearTimeout(this.confirm)
    this.confirm = null
    this.rows = null
    this.requested = false
    this.busy = null
    this.notice = null
    this.element.remove()
  }
}
