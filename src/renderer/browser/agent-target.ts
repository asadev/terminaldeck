import { folderName } from '../session-title'

/**
 * Which session the browser sends to — the model behind the picker.
 *
 * ## Why this exists at all
 *
 * Everything the browser could hand an agent went to `activeSessionId`: the tab
 * that happened to be focused behind the browser. He found that on camera on
 * 2026-08-16 and was unambiguous about it:
 *
 * > *"it will just randomly send to anyone whatever I say here… there should be
 * > an arrow next to it and I can choose which session I'm going to send it to
 * > and then I send, and I can make that specific popup from that browser to
 * > specifically link to one session. So every time when I send, it
 * > automatically sends to that specific session only, not to anyone… If I open
 * > a new browser, then I will have to select. Until I don't select the session
 * > this button will stay gray, will not be clickable."*
 *
 * So the rules, in his order, and each of them is pinned by a test below this
 * file:
 *
 *  1. **Nothing is chosen by default.** Not the focused session, not the newest,
 *     not the only one. An automatic choice is exactly the behaviour being
 *     replaced, and it is worse for being invisible.
 *  2. **The send control is dead until something is chosen.** Disabled, not
 *     hidden, and not "send anyway".
 *  3. **The choice sticks for that browser window** and is used by every send it
 *     makes — an element, a flow, a screenshot — until it is changed.
 *  4. **A dead session is not a target.** Its process has exited; writing to it
 *     goes nowhere and reports success.
 *
 * ## Why the labels are built here rather than read from the sidebar
 *
 * The rail's numbering lives in `renderer/shell`, which this file may not reach
 * into, so the scheme is reproduced rather than imported: sessions are grouped
 * by project folder and numbered in the order the main process lists them,
 * which is the order they were created. That is what makes the picker read
 * `terminaldeck · Session 2` — the same words as the row he would have clicked.
 */

/** One session, as a picker needs to see it. Mirrors `SessionMeta`. */
export interface AgentSession {
  id: string
  /** Absolute path of the project folder it runs in. */
  cwd: string
  /** What the picker calls it: `folder · Session 2`. */
  label: string
  /** Which agent CLI is in it, shown when a folder holds more than one kind. */
  provider: string
  /** Its process has exited. Listed, but never a target. */
  ended: boolean
}

/** The slice of `window.deck` this needs. Everything else about it is irrelevant. */
export interface AgentSessionBridge {
  listSessions(): Promise<unknown>
  writeToSession(id: string, data: string): void
  /** A session started elsewhere — from a phone, or another window. */
  onSessionCreated(callback: (meta: unknown) => void): () => void
  onSessionExit(callback: (id: string, exitCode: number) => void): () => void
}

const SESSION_METHODS = [
  'listSessions',
  'writeToSession',
  'onSessionCreated',
  'onSessionExit',
] as const satisfies readonly (keyof AgentSessionBridge)[]

/**
 * Read the session half of the preload, or null.
 *
 * Null is a real state and the picker draws it: a build whose preload predates
 * these methods gets a sentence saying so rather than a select that cannot be
 * filled, and — critically — no fallback that quietly sends somewhere else.
 */
export function resolveAgentSessions(host: unknown): AgentSessionBridge | null {
  if (typeof host !== 'object' || host === null) return null
  const record = host as Record<string, unknown>
  if (SESSION_METHODS.some((method) => typeof record[method] !== 'function')) return null
  return host as unknown as AgentSessionBridge
}

/** One session out of whatever the bridge sent, or null if it is not one. */
function readSession(value: unknown): { id: string; cwd: string; provider: string; ended: boolean } | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  if (typeof record.id !== 'string' || record.id === '') return null
  return {
    id: record.id,
    cwd: typeof record.cwd === 'string' ? record.cwd : '',
    provider: typeof record.provider === 'string' ? record.provider : '',
    // `exitCode` is null while the process lives and a number once it has gone.
    ended: typeof record.exitCode === 'number',
  }
}

/**
 * Turn the bridge's answer into a labelled list.
 *
 * The numbering is per project and follows list order, which is creation order
 * — the same rule the sidebar uses, so the two agree about which session is
 * "Session 2". A session with no folder is numbered in its own group rather
 * than being thrown in with the first project's, because it belongs to none.
 */
export function readSessions(value: unknown): AgentSession[] {
  if (!Array.isArray(value)) return []
  const counts = new Map<string, number>()
  const out: AgentSession[] = []
  for (const entry of value) {
    const session = readSession(entry)
    if (!session) continue
    const index = (counts.get(session.cwd) ?? 0) + 1
    counts.set(session.cwd, index)
    const folder = session.cwd ? folderName(session.cwd) : ''
    out.push({
      ...session,
      label: folder ? `${folder} · Session ${index}` : `Session ${index}`,
    })
  }
  return out
}

/**
 * The session a send would actually reach, given what is chosen.
 *
 * Null in three cases, and they are all the same answer to the user: nothing
 * chosen, a choice that is no longer in the list, and a choice whose process has
 * exited. The last one is the case he named — *"if that session dies, I need to
 * select again another session"* — and it is the reason this is a function over
 * the live list rather than a stored object.
 */
export function resolveTarget(
  chosenId: string,
  sessions: readonly AgentSession[],
): AgentSession | null {
  if (!chosenId) return null
  const found = sessions.find((session) => session.id === chosenId)
  if (!found || found.ended) return null
  return found
}

/**
 * Why the send button is off, in one sentence, or empty when it is on.
 *
 * A disabled control with no explanation is the thing this whole change is
 * against, so the disabled state carries its own reason and the three reasons
 * are different sentences.
 */
export function whyDisabled(
  chosenId: string,
  sessions: readonly AgentSession[],
  available: boolean,
): string {
  if (!available) return 'This build cannot list your sessions, so there is nothing to send to.'
  if (sessions.length === 0) return 'No sessions are open. Start one, then choose it here.'
  if (!chosenId) return 'Choose a session first — this will not guess one for you.'
  const found = sessions.find((session) => session.id === chosenId)
  if (!found) return 'That session is gone. Choose another one.'
  if (found.ended) return `${found.label} has exited. Choose another one.`
  return ''
}
