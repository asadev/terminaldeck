import type { CopilotChatMessage, CopilotStateReport } from '../remote/protocol'
import {
  MACHINES_COPILOT_CHAT_CHANNEL,
  MACHINES_COPILOT_STATE_CHANNEL,
  MACHINES_OUTPUT_CHANNEL,
} from '../remote/machines/ipc'
import { ActivityTracker } from '../session-activity'
import type { ChannelTap } from './channel-tap'

/**
 * What another machine has said to this one, kept so a tool can read it back.
 *
 * ## Why a tool needs a memory here at all
 *
 * Everything a paired machine tells this desktop that nobody asked a question
 * to get arrives as a *push*: a session's terminal output on `machines:output`,
 * the far copilot's conversation on `machines:copilot:chat`, its state on
 * `machines:copilot:state`. The window draws each one as it lands and keeps no
 * copy in the main process, because the window is the only reader. A tool is a
 * second reader that arrives later — *"what did the session on the Office PC say
 * in the end?"* — and a push that was drawn and forgotten cannot answer it.
 *
 * So this listens to the same pushes, through the tap, and keeps two things:
 *
 *  - **a screen per remote session** that something on this desktop is
 *    attached to — a real headless terminal, the same `ActivityTracker` every
 *    local session has, because an agent CLI is a full-screen program that
 *    repaints with cursor moves and the tail of the byte stream is not the
 *    screen. `session-activity.ts` has the measurement;
 *  - **the far copilot's conversation**, already parsed — the wire carries
 *    messages, never terminal bytes — merged by the rule the frame itself states.
 *
 * ## The size is read, never assumed
 *
 * A shadow terminal at the wrong width draws a different screen from the real
 * one. The window chose the size when it attached, so the size is taken from
 * the `machines:attach` and `machines:resize` calls themselves as the tap sees
 * them go by — the window's and a tool's alike. An attach always starts a fresh
 * terminal, because the far end answers an attach with a full replay of its
 * scrollback, and replaying into the old one would draw everything twice.
 *
 * ## Bounded
 *
 * {@link MAX_SCREENS} terminals and {@link MAX_MESSAGES} messages per machine.
 * The oldest screen is let go first: a remote session nobody has looked at in
 * the longest time is the one least likely to be asked about next.
 */

export const MAX_SCREENS = 16
export const MAX_MESSAGES = 200

export interface RemoteScreen {
  /** The visible screen, as a person would see it. */
  text: string
  /**
   * Is output still arriving? False once whatever attached here has detached —
   * the text is then the last screen this desktop saw, and says so.
   */
  live: boolean
  cols: number
  rows: number
  /** When the last byte arrived, epoch ms, or null when none has yet. */
  lastOutputAt: number | null
}

export interface FarConversation {
  /** The far copilot's run these messages belong to, or null before any frame. */
  run: string | null
  messages: CopilotChatMessage[]
  state: CopilotStateReport | null
  /** When anything here last changed, epoch ms. */
  changedAt: number | null
}

export interface MachineWatch {
  /** The screen of one session over there, or null when nothing here has seen it. */
  screen(machineId: string, sessionId: string): Promise<RemoteScreen | null>
  /** Is something on this desktop attached to that session right now? */
  attached(machineId: string, sessionId: string): boolean
  conversation(machineId: string): FarConversation
  /**
   * Wait for the far copilot to answer something said after `since`.
   *
   * `since` is the id of the newest message before the caller spoke — read from
   * {@link conversation} *before* saying anything — so a reply that was already
   * on screen cannot be mistaken for the answer to the new question. Settles
   * when, after that message, one of ours has appeared and the newest message is
   * the agent's and has not changed for `settleMs`: the conversation streams, so
   * a reply is extended in place under one id, and "it has stopped growing" is
   * the only signal the frame gives that it is finished. A `since` that is no
   * longer in the conversation (a reset replaced it) counts everything as new.
   * Answers false at the ceiling.
   */
  replied(machineId: string, since: string | null, ceilingMs: number, settleMs?: number): Promise<boolean>
  /** The next time anything about that machine's copilot changes; false at the ceiling. */
  nextChange(machineId: string, ceilingMs: number): Promise<boolean>
  dispose(): void
}

interface Screen {
  tracker: ActivityTracker
  cols: number
  rows: number
  live: boolean
  lastOutputAt: number | null
  touchedAt: number
}

interface Held {
  run: string | null
  messages: Map<string, CopilotChatMessage>
  state: CopilotStateReport | null
  changedAt: number | null
}

const key = (machineId: string, sessionId: string): string => `${machineId}\u0000${sessionId}`

function text(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function size(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 1 ? Math.min(Math.trunc(value), 1000) : fallback
}

/**
 * Has the agent answered something of ours said after `since`?
 *
 * Exported for its own test, because it is the one judgement in this file a
 * wrong answer from would be believed: "the copilot replied" when it had not is
 * a tool handing back the previous answer as the new one.
 */
export function answeredAfter(messages: readonly CopilotChatMessage[], since: string | null): boolean {
  const at = since === null ? -1 : messages.findIndex((message) => message.id === since)
  const after = messages.slice(at + 1)
  const ours = after.findIndex((message) => message.role === 'you')
  if (ours < 0) return false
  const last = after[after.length - 1]
  return after.length - 1 > ours && last.role === 'agent' && last.text.trim() !== ''
}

export function watchMachines(
  tap: Pick<ChannelTap, 'onPush' | 'onInvoke'>,
  options: { now?: () => number; maxScreens?: number } = {},
): MachineWatch {
  const now = options.now ?? Date.now
  const maxScreens = options.maxScreens ?? MAX_SCREENS
  const screens = new Map<string, Screen>()
  const held = new Map<string, Held>()
  const changed = new Map<string, Set<() => void>>()

  const heldFor = (machineId: string): Held => {
    const found = held.get(machineId)
    if (found) return found
    const fresh: Held = { run: null, messages: new Map(), state: null, changedAt: null }
    held.set(machineId, fresh)
    return fresh
  }

  const tell = (machineId: string): void => {
    for (const listener of [...(changed.get(machineId) ?? [])]) listener()
  }

  const drop = (id: string): void => {
    screens.get(id)?.tracker.dispose()
    screens.delete(id)
  }

  const open = (machineId: string, sessionId: string, cols: number, rows: number): void => {
    const id = key(machineId, sessionId)
    drop(id)
    while (screens.size >= maxScreens) {
      let oldest: string | null = null
      let at = Infinity
      for (const [candidate, screen] of screens) {
        if (screen.touchedAt < at) {
          at = screen.touchedAt
          oldest = candidate
        }
      }
      if (oldest === null) break
      drop(oldest)
    }
    const tracker = new ActivityTracker(id, () => undefined, cols, rows)
    // Nobody reads its status classification; only its screen. Unwatched means
    // the per-chunk settle timer never arms, which is the whole cost of one.
    tracker.setWatched(false)
    screens.set(id, { tracker, cols, rows, live: true, lastOutputAt: null, touchedAt: now() })
  }

  const unsubscribers = [
    tap.onInvoke((channel, args) => {
      const machineId = text(args[0])
      if (machineId === null) return
      if (channel === 'machines:forget') {
        for (const id of [...screens.keys()]) if (id.startsWith(`${machineId}\u0000`)) drop(id)
        held.delete(machineId)
        return
      }
      const sessionId = text(args[1])
      if (sessionId === null) return
      const id = key(machineId, sessionId)
      if (channel === 'machines:attach') {
        open(machineId, sessionId, size(args[2], 120), size(args[3], 30))
      } else if (channel === 'machines:resize') {
        const screen = screens.get(id)
        if (screen) {
          screen.cols = size(args[2], screen.cols)
          screen.rows = size(args[3], screen.rows)
          screen.tracker.resize(screen.cols, screen.rows)
        }
      } else if (channel === 'machines:detach') {
        const screen = screens.get(id)
        if (screen) screen.live = false
      } else if (channel === 'machines:close') {
        drop(id)
      }
    }),

    tap.onPush(MACHINES_OUTPUT_CHANNEL, (payload) => {
      const frame = payload as { machineId?: unknown; sessionId?: unknown; data?: unknown }
      const machineId = text(frame?.machineId)
      const sessionId = text(frame?.sessionId)
      if (machineId === null || sessionId === null || typeof frame.data !== 'string') return
      const screen = screens.get(key(machineId, sessionId))
      if (!screen) return
      screen.tracker.push(frame.data)
      screen.lastOutputAt = now()
      screen.touchedAt = screen.lastOutputAt
    }),

    tap.onPush(MACHINES_COPILOT_CHAT_CHANNEL, (payload) => {
      const frame = payload as {
        machineId?: unknown
        chat?: { run?: unknown; messages?: unknown; reset?: unknown }
      }
      const machineId = text(frame?.machineId)
      const chat = frame?.chat
      if (machineId === null || chat === undefined || !Array.isArray(chat.messages)) return
      const run = text(chat.run)
      const into = heldFor(machineId)
      /*
       * The frame's own rule, applied as the window applies it: `reset` replaces
       * everything; otherwise merge by id — but only into the same run. A frame
       * from a different run with no reset is the end of a dead conversation
       * arriving late, and splicing it on would put an answer under a question
       * that was never asked in this one.
       */
      if (chat.reset === true) {
        into.run = run
        into.messages = new Map()
      } else if (into.run !== null && run !== null && run !== into.run) {
        return
      } else if (into.run === null) {
        into.run = run
      }
      for (const raw of chat.messages as unknown[]) {
        const message = raw as CopilotChatMessage
        if (typeof message?.id !== 'string' || typeof message.text !== 'string') continue
        into.messages.delete(message.id)
        into.messages.set(message.id, message)
      }
      while (into.messages.size > MAX_MESSAGES) {
        const first = into.messages.keys().next().value
        if (first === undefined) break
        into.messages.delete(first)
      }
      into.changedAt = now()
      tell(machineId)
    }),

    tap.onPush(MACHINES_COPILOT_STATE_CHANNEL, (payload) => {
      const frame = payload as { machineId?: unknown; state?: unknown }
      const machineId = text(frame?.machineId)
      if (machineId === null || typeof frame.state !== 'object' || frame.state === null) return
      const into = heldFor(machineId)
      into.state = frame.state as CopilotStateReport
      into.changedAt = now()
      tell(machineId)
    }),
  ]

  return {
    async screen(machineId, sessionId) {
      const screen = screens.get(key(machineId, sessionId))
      if (!screen) return null
      screen.touchedAt = now()
      return {
        text: await screen.tracker.settledText(),
        live: screen.live,
        cols: screen.cols,
        rows: screen.rows,
        lastOutputAt: screen.lastOutputAt,
      }
    },

    attached: (machineId, sessionId) => screens.get(key(machineId, sessionId))?.live === true,

    conversation(machineId) {
      const found = held.get(machineId)
      return {
        run: found?.run ?? null,
        messages: found ? [...found.messages.values()] : [],
        state: found?.state ?? null,
        changedAt: found?.changedAt ?? null,
      }
    },

    replied(machineId, since, ceilingMs, settleMs = 2500) {
      return new Promise<boolean>((resolve) => {
        let settle: ReturnType<typeof setTimeout> | null = null
        const listeners = changed.get(machineId) ?? new Set()
        changed.set(machineId, listeners)
        const finish = (answer: boolean): void => {
          clearTimeout(ceiling)
          if (settle !== null) clearTimeout(settle)
          listeners.delete(check)
          resolve(answer)
        }
        const answered = (): boolean => answeredAfter([...(held.get(machineId)?.messages.values() ?? [])], since)
        function check(): void {
          if (settle !== null) clearTimeout(settle)
          settle = null
          if (!answered()) return
          settle = setTimeout(() => finish(true), settleMs)
          settle.unref?.()
        }
        const ceiling = setTimeout(() => finish(answered()), ceilingMs)
        ceiling.unref?.()
        listeners.add(check)
      })
    },

    nextChange(machineId, ceilingMs) {
      return new Promise<boolean>((resolve) => {
        const listeners = changed.get(machineId) ?? new Set()
        changed.set(machineId, listeners)
        const finish = (answer: boolean): void => {
          clearTimeout(ceiling)
          listeners.delete(heard)
          resolve(answer)
        }
        const heard = (): void => finish(true)
        const ceiling = setTimeout(() => finish(false), ceilingMs)
        ceiling.unref?.()
        listeners.add(heard)
      })
    },

    dispose() {
      for (const unsubscribe of unsubscribers) unsubscribe()
      for (const id of [...screens.keys()]) drop(id)
      held.clear()
      changed.clear()
    },
  }
}
