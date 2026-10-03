import type { SessionStatus } from './types'
import { BRAND } from './brand'
import type { IslandNotch } from './hoot-island'
import { decide, NOTIFY_COOLDOWN_MS } from './notify-rule'

/**
 * What Hoot's island says, worked out from what the app already knows.
 *
 * Shared by both halves: the main process works out the resting pill's words
 * (the short line, and the moment "Session 2 needs you"), and the page draws
 * the pill and the grown panel's lists from the same functions. One function
 * each, so the pill and the panel it grows into cannot word the same fact two
 * ways.
 *
 * Pure, so every sentence is pinned by a test without a window. The moment uses
 * the app's own rule for what is worth interrupting somebody for —
 * `decide()` in `notify-rule.ts`, the one the desktop banners go through — so a
 * banner and the island can never disagree about whether "Session 2
 * finished" was news, and a status that flickers is swallowed by the same
 * cooldown.
 */

export interface HootSessionView {
  id: string
  label: string
  status: SessionStatus
}

export interface HootMessageView {
  id: string
  role: 'you' | 'agent'
  text: string
}

export interface HootPanelSnapshot {
  assistant: string
  hoot: { status: 'running' | 'starting' | 'stopped'; problem: string | null }
  sessions: HootSessionView[]
  messages: HootMessageView[]
  /** What the resting pill says. */
  label: { text: string; attention: boolean }
  /** Grown into the panel, or resting as the pill. */
  expanded: boolean
  /** The display: its menu bar's height, its width, and its notch if it has one. */
  geometry: { barHeight: number; displayWidth: number; notch: IslandNotch | null }
}

const STATUSES: readonly SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']

export const EMPTY_SNAPSHOT: HootPanelSnapshot = {
  assistant: BRAND.assistant,
  hoot: { status: 'stopped', problem: null },
  sessions: [],
  messages: [],
  label: { text: BRAND.assistant, attention: false },
  expanded: false,
  geometry: { barHeight: 24, displayWidth: 1440, notch: null },
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

const positive = (value: unknown, fallback: number): number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : fallback

function readNotch(raw: unknown): IslandNotch | null {
  if (!isRecord(raw)) return null
  const width = positive(raw.width, 0)
  const height = positive(raw.height, 0)
  if (width === 0 || height === 0) return null
  return { left: typeof raw.left === 'number' && Number.isFinite(raw.left) ? raw.left : 0, width, height }
}

/** The snapshot off the wire. A field this build does not know is dropped, not guessed at. */
export function readSnapshot(raw: unknown): HootPanelSnapshot {
  if (!isRecord(raw)) return EMPTY_SNAPSHOT
  const hoot = isRecord(raw.hoot) ? raw.hoot : {}
  const status = hoot.status === 'running' || hoot.status === 'starting' ? hoot.status : 'stopped'
  const sessions: HootSessionView[] = []
  for (const entry of Array.isArray(raw.sessions) ? (raw.sessions as unknown[]) : []) {
    if (!isRecord(entry) || typeof entry.id !== 'string') continue
    const s = typeof entry.status === 'string' && (STATUSES as readonly string[]).includes(entry.status) ? (entry.status as SessionStatus) : 'idle'
    sessions.push({ id: entry.id, label: typeof entry.label === 'string' && entry.label !== '' ? entry.label : 'Session', status: s })
  }
  const messages: HootMessageView[] = []
  for (const entry of Array.isArray(raw.messages) ? (raw.messages as unknown[]) : []) {
    if (!isRecord(entry) || typeof entry.id !== 'string' || typeof entry.text !== 'string') continue
    if (entry.role !== 'you' && entry.role !== 'agent') continue
    if (entry.text.trim() === '') continue
    messages.push({ id: entry.id, role: entry.role, text: entry.text })
  }
  const assistant = typeof raw.assistant === 'string' && raw.assistant !== '' ? raw.assistant : BRAND.assistant
  const label = isRecord(raw.label) && typeof raw.label.text === 'string' && raw.label.text !== '' ? raw.label : null
  const geometry = isRecord(raw.geometry) ? raw.geometry : {}
  return {
    assistant,
    hoot: { status, problem: typeof hoot.problem === 'string' ? hoot.problem : null },
    sessions,
    messages,
    label: label === null ? { text: assistant, attention: false } : { text: String(label.text), attention: label.attention === true },
    expanded: raw.expanded === true,
    geometry: {
      barHeight: positive(geometry.barHeight, EMPTY_SNAPSHOT.geometry.barHeight),
      displayWidth: positive(geometry.displayWidth, EMPTY_SNAPSHOT.geometry.displayWidth),
      notch: readNotch(geometry.notch),
    },
  }
}

/** The sessions waiting on the person, in the order the main window lists them. */
export function needsYou(sessions: readonly HootSessionView[]): HootSessionView[] {
  return sessions.filter((session) => session.status === 'input')
}

/**
 * The one line about what is going on, or nothing — the grown panel's header
 * says it in full, and the pill's short line is cut from it.
 *
 * Nothing when all is quiet — the owl alone says Hoot is there. A session
 * waiting on the person beats any number working, because it is the one thing
 * here that needs them to do something.
 */
export function restingLine(sessions: readonly HootSessionView[]): { text: string; attention: boolean } | null {
  const waiting = needsYou(sessions)
  if (waiting.length === 1) return { text: `${waiting[0].label} needs you`, attention: true }
  if (waiting.length > 1) return { text: `${waiting.length} need you`, attention: true }
  const working = sessions.filter((session) => session.status === 'working').length
  if (working > 0) return { text: `${working} working`, attention: false }
  return null
}

/** A moment: one line the pill says for a few seconds, widened, before it settles to its short line. */
export interface HootMoment {
  sessionId: string
  text: string
  attention: boolean
}

/**
 * Remembers what each session's status was, so a change can be told from a
 * first sighting, and when each kind of moment last fired, for the cooldown.
 */
export class MomentTracker {
  private readonly last = new Map<string, SessionStatus>()
  private readonly fired = new Map<string, number>()

  /** The moment this snapshot produces, if any — the newest one when several land together. */
  next(sessions: readonly HootSessionView[], now: number): HootMoment | null {
    let moment: HootMoment | null = null
    const seen = new Set<string>()
    for (const session of sessions) {
      seen.add(session.id)
      const previous = this.last.get(session.id)
      this.last.set(session.id, session.status)
      const key = `${session.id}:${session.status}`
      const verdict = decide({
        status: session.status,
        previous,
        enabled: true,
        // The island is over every app; whether the main window is showing
        // this session is not a question it can answer, and a word in the pill
        // is small enough that saying it twice costs nothing.
        watching: false,
        lastFiredAt: this.fired.get(key) ?? null,
        now,
        cooldownMs: NOTIFY_COOLDOWN_MS,
      })
      if (!verdict.fire) continue
      this.fired.set(key, now)
      moment =
        session.status === 'input'
          ? { sessionId: session.id, text: `${session.label} needs you`, attention: true }
          : { sessionId: session.id, text: `${session.label} finished`, attention: false }
    }
    for (const id of [...this.last.keys()]) if (!seen.has(id)) this.last.delete(id)
    return moment
  }
}

/** How long the pill says a moment before it settles to its short line. */
export const MOMENT_MS = 4000

/** How long the pointer rests on the pill before it grows, and is off the shape before it settles. */
export const OPEN_DELAY_MS = 160
export const CLOSE_DELAY_MS = 500

/**
 * What the island's resting pill says: the moment while it lasts — "Session 2
 * needs you", "Session 1 finished" — then a compact line about what is going on
 * — "Needs you", "2 working" — and the assistant's name when all is quiet, so
 * the pill always reads as Hoot's rather than as a blank chip.
 *
 * The resting line is shorter than the panel's on purpose. The pill sits in the
 * middle of a menu bar shared with every other app on the Mac — and on a
 * MacBook, beside the notch — so it stays small; the full sentence is what it
 * *widens* to say, for a few seconds, and the grown panel names the session for
 * as long as it waits. Anything still too long is cut to {@link MAX_TITLE}
 * characters.
 */
export const MAX_TITLE = 22

export function pillLabel(
  moment: HootMoment | null,
  sessions: readonly HootSessionView[],
  assistant: string = BRAND.assistant,
): { text: string; attention: boolean } {
  const waiting = needsYou(sessions).length
  const compact =
    waiting === 1
      ? { text: 'Needs you', attention: true }
      : waiting > 1
        ? { text: `${waiting} need you`, attention: true }
        : restingLine(sessions)
  const line = moment ?? compact
  const text = line === null ? assistant : line.text
  return {
    text: text.length > MAX_TITLE ? `${text.slice(0, MAX_TITLE - 1)}…` : text,
    attention: line?.attention ?? false,
  }
}
