/**
 * Hoot's island, for the native macOS window.
 *
 * In Electron the island is a window of the main process (`main/hoot-menubar.ts`)
 * with its page in `hoot-panel/HootPanel.tsx`. Its resting shape — the pill at
 * the top of the screen — says one line: a session that just needed you or just
 * finished, for four seconds (`MomentTracker`), and otherwise how many sessions
 * are open, working and waiting (`pillLabel`). Hoot's own window is never one of
 * them. All of that is `shared/hoot-panel-model.ts`, so it is used here as it is.
 *
 * In the native window the Electron island is off and the shape is drawn
 * natively. Two things feed it:
 *
 *  - the **main page** posts `{type: 'island', state: {status, badge, line}}`
 *    whenever the resting shape would change ({@link createIslandPublisher}),
 *    from the same sessions, the same labels (the rail's — what `App.tsx`
 *    reports to the Electron island as `session:labels`) and the same moments;
 *  - the **island page** (`/?island=1`, `IslandPage.tsx`) is what the shape
 *    holds when it opens: Hoot's conversation, a line to ask Hoot something,
 *    and every session. It gets the session list from the main page over
 *    {@link openIslandRelay}, and hands a press on a session back the same way.
 */

import {
  MOMENT_MS,
  MomentTracker,
  needsYou,
  pillLabel,
  readSnapshot,
  type HootMoment,
  type HootSessionView,
} from '../../shared/hoot-panel-model'
import type { CopilotStage } from '../copilot/copilot-model'
import { openRelay, type ChannelLike, type Relay } from '../native-relay'

/* ---------------------------------------------------------------- state -- */

export type IslandStatus = 'idle' | 'working' | 'needs-you' | 'offline'

export interface IslandState {
  status: IslandStatus
  /** How many sessions are waiting on you — the pill's "waiting" count. */
  badge: number
  /** The pill's own words. */
  line: string
}

/**
 * The resting shape, from the sessions (Hoot's own excluded), Hoot's stage and
 * the moment in progress, if any.
 *
 * `status` orders what the pill gives weight to: a session waiting on you, then
 * one working, then Hoot not running at all (`offline` — there is nobody at the
 * island to ask), and otherwise nothing to say.
 */
export function islandState(
  sessions: readonly HootSessionView[],
  hootStage: CopilotStage | null,
  moment: HootMoment | null,
  assistant: string,
): IslandState {
  const badge = needsYou(sessions).length
  const working = sessions.some((session) => session.status === 'working')
  const status: IslandStatus =
    badge > 0 ? 'needs-you' : working ? 'working' : hootStage === 'stopped' ? 'offline' : 'idle'
  return { status, badge, line: pillLabel(moment, sessions, assistant).text }
}

/** The island's sessions, from what the main window draws: every session but Hoot's own, by the rail's name. */
export function islandSessions<T extends { id: string; kind: string; isCopilot?: boolean; status?: string }>(
  tabs: readonly T[],
  labelOf: (tab: T) => string,
): HootSessionView[] {
  return readSnapshot({
    sessions: tabs
      .filter((tab) => tab.kind === 'session' && tab.isCopilot !== true)
      .map((tab) => ({ id: tab.id, label: labelOf(tab), status: tab.status ?? 'idle' })),
  }).sessions
}

/**
 * Posts the resting shape whenever it changes, and runs the moments the way
 * the Electron island does: the statuses on the first look are the baseline
 * (nothing that was already true when the island appeared is announced), a
 * moment lasts {@link MOMENT_MS}, and a later one replaces it.
 */
export function createIslandPublisher(options: {
  post(message: { type: 'island'; state: IslandState }): void
  assistant: string
  schedule?(run: () => void, ms: number): { cancel(): void }
  now?(): number
}): { update(sessions: readonly HootSessionView[], hootStage: CopilotStage | null): IslandState } {
  const schedule =
    options.schedule ??
    ((run: () => void, ms: number) => {
      const timer = setTimeout(run, ms)
      return { cancel: () => clearTimeout(timer) }
    })
  const now = options.now ?? (() => Date.now())
  const tracker = new MomentTracker()
  let primed = false
  let moment: HootMoment | null = null
  let clearing: { cancel(): void } | null = null
  let sessions: readonly HootSessionView[] = []
  let stage: CopilotStage | null = null
  let seen = ''
  let last = ''

  const emit = (): IslandState => {
    const state = islandState(sessions, stage, moment, options.assistant)
    const text = JSON.stringify(state)
    if (text !== last) {
      last = text
      options.post({ type: 'island', state })
    }
    return state
  }

  return {
    update(nextSessions, nextStage) {
      const key = JSON.stringify([nextSessions, nextStage])
      if (key === seen) return islandState(sessions, stage, moment, options.assistant)
      seen = key
      sessions = nextSessions
      stage = nextStage
      const found = tracker.next(sessions, now())
      if (!primed) primed = true
      else if (found !== null) {
        moment = found
        clearing?.cancel()
        clearing = schedule(() => {
          clearing = null
          moment = null
          emit()
        }, MOMENT_MS)
      }
      return emit()
    },
  }
}

/* ---------------------------------------------------------------- relay -- */

export const ISLAND_RELAY_CHANNEL = 'terminaldeck:native-island'

/** What the island page needs to draw its list and its header. */
export interface IslandSnapshot {
  assistant: string
  stage: CopilotStage | null
  sessions: HootSessionView[]
  line: string
}

export type IslandRelayMessage =
  | { type: 'snapshot'; snapshot: IslandSnapshot }
  | { type: 'hello' }
  | { type: 'show-session'; id: string }

function isIslandMessage(value: unknown): value is IslandRelayMessage {
  if (typeof value !== 'object' || value === null) return false
  const message = value as { type?: unknown; id?: unknown; snapshot?: unknown }
  if (message.type === 'hello') return true
  if (message.type === 'show-session') return typeof message.id === 'string'
  return message.type === 'snapshot' && typeof message.snapshot === 'object' && message.snapshot !== null
}

export function openIslandRelay(open?: (name: string) => ChannelLike): Relay<IslandRelayMessage> {
  return openRelay(ISLAND_RELAY_CHANNEL, isIslandMessage, open)
}

/* ------------------------------------------------------------- the page -- */

/** True when this page load is the island. */
export function isIslandPage(search: string): boolean {
  return new URLSearchParams(search).get('island') === '1'
}

/**
 * `window.tdNative` on the island page: `island-expanded` with true or false,
 * which the native shape sends as it opens and closes.
 */
export function islandCommands(setExpanded: (expanded: boolean) => void): {
  run(name: string, arg?: unknown): boolean
} {
  return {
    run(name, arg) {
      if (name !== 'island-expanded' || typeof arg !== 'boolean') return false
      setExpanded(arg)
      return true
    },
  }
}

/**
 * The folder Hoot is actually running in — where its conversation is written.
 *
 * Hoot's session's own working folder, which is what Hoot's window in the app
 * names (its tab's `projectPath` is that session's `cwd`). Not the folder in
 * `copilot:state`'s paths: that is the folder Hoot *will* start in, and after
 * the person chooses another one Hoot keeps running in the old one until it is
 * restarted — so its words are still being written there. The configured folder
 * is the answer only while no Hoot session is running, when there is nothing
 * newer to read anyway.
 */
export function hootRunsIn(
  sessions: ReadonlyArray<{ id: string; cwd: string }>,
  hootSessionId: string | null,
  configured: string | null,
): string | null {
  const running = hootSessionId === null ? undefined : sessions.find((session) => session.id === hootSessionId)
  return running?.cwd || configured
}

/** Hoot's conversation, newest last, as many as the island has room for. */
export const ISLAND_MESSAGES = 8

/**
 * Fold a transcript read into what is held: a reset replaces everything, and a
 * message read again (one still being written) replaces its earlier copy.
 */
export function mergeIslandMessages<M extends { id: string }>(
  held: readonly M[],
  update: { messages: readonly M[]; reset: boolean },
): M[] {
  const next = update.reset ? [] : [...held]
  for (const message of update.messages) {
    const at = next.findIndex((entry) => entry.id === message.id)
    if (at === -1) next.push(message)
    else next[at] = message
  }
  return next.slice(-ISLAND_MESSAGES)
}
