import type { SessionStatus } from './types'
import { BRAND } from './brand'
import { decide, NOTIFY_COOLDOWN_MS } from './notify-rule'

/**
 * What Hoot's menu bar item says, worked out from what the app already knows.
 *
 * Shared by both halves: the main process sets the menu bar title from it (the
 * badge, and the moment "Session 2 needs you"), and the dropdown panel draws
 * its header and its list from it. One function each, so the menu bar and the
 * panel under it cannot word the same fact two ways.
 *
 * Pure, so every sentence is pinned by a test without a window. The moment uses
 * the app's own rule for what is worth interrupting somebody for —
 * `decide()` in `notify-rule.ts`, the one the desktop banners go through — so a
 * banner and the menu bar can never disagree about whether "Session 2
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
  /** Light or dark, as the panel's glass is drawn. Null until the main process says. */
  appearance: 'light' | 'dark' | null
  hoot: { status: 'running' | 'starting' | 'stopped'; problem: string | null }
  sessions: HootSessionView[]
  messages: HootMessageView[]
}

const STATUSES: readonly SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']

export const EMPTY_SNAPSHOT: HootPanelSnapshot = {
  assistant: BRAND.assistant,
  appearance: null,
  hoot: { status: 'stopped', problem: null },
  sessions: [],
  messages: [],
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
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
  return {
    assistant: typeof raw.assistant === 'string' && raw.assistant !== '' ? raw.assistant : BRAND.assistant,
    appearance: raw.appearance === 'dark' || raw.appearance === 'light' ? raw.appearance : null,
    hoot: { status, problem: typeof hoot.problem === 'string' ? hoot.problem : null },
    sessions,
    messages,
  }
}

/** The sessions waiting on the person, in the order the main window lists them. */
export function needsYou(sessions: readonly HootSessionView[]): HootSessionView[] {
  return sessions.filter((session) => session.status === 'input')
}

/**
 * The one line the resting pill carries, or nothing.
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

/** A moment: one line the menu bar says for a few seconds, then settles to the badge. */
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
        // The menu bar is on every screen and over every app; whether the main
        // window is showing this session is not a question it can answer, and
        // a word in the menu bar is small enough that saying it twice costs
        // nothing.
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

/** How long the menu bar says a moment before it settles to the badge. */
export const MOMENT_MS = 4000

/** How long the pointer rests on the menu bar icon before the panel opens, and is away before it closes. */
export const OPEN_DELAY_MS = 160
export const CLOSE_DELAY_MS = 500

/**
 * The menu bar's title beside the owl: the moment while it lasts, then the
 * number of sessions waiting on the person, and nothing when none are.
 *
 * Kept tiny on purpose — the menu bar is shared with every other app on the
 * Mac, and a long title pushes other people's icons off it. A moment is cut to
 * {@link MAX_TITLE} characters; the badge is a number.
 */
export const MAX_TITLE = 24

export function menuBarTitle(moment: HootMoment | null, sessions: readonly HootSessionView[]): string {
  if (moment !== null) {
    const text = moment.text.length > MAX_TITLE ? `${moment.text.slice(0, MAX_TITLE - 1)}…` : moment.text
    return ` ${text}`
  }
  const waiting = needsYou(sessions).length
  return waiting > 0 ? ` ${waiting}` : ''
}
