/**
 * The usage window, assembled per session and pushed to whoever asks.
 *
 * Two readers feed this: `plan-limit.ts`, which reads Claude Code's own screen,
 * and `codex-usage.ts`, which reads the struct Codex writes into its rollout.
 * Neither knows which login it is describing — one watches a terminal, the
 * other a directory — so attributing the numbers to an account is this module's
 * job, and it is the job worth being careful about. Two accounts sharing one
 * bar is the same class of bug as two accounts sharing one credential, and this
 * app has already had that one.
 *
 * ## Which account a reading belongs to
 *
 * An account here is a configuration directory, exactly as in
 * `provider-accounts.ts`. A session carries the profile it was *resolved* to at
 * spawn (`SessionMeta.profileId`), which is the only trustworthy answer — the
 * request that started it usually said null, meaning "whatever this project's
 * default is", and re-running that resolution now could land somewhere else.
 *
 * For a session running an agent other than the one a reading came from, the
 * account is the machine's own install of that agent, and that is not a
 * fallback — it is what is actually true. A plain shell spawns with no
 * `CLAUDE_CONFIG_DIR` (see `sessionEnv`, which returns nothing for the system
 * profile and nothing for a provider that cannot be redirected), so a `/usage`
 * panel printed inside one is describing the default install's subscription. It
 * would be wrong to attribute it to the session's own profile and equally wrong
 * to leave it unattributed.
 *
 * ## Which readers run for which session
 *
 * Claude's reader runs for every watched session, because Claude Code can be
 * started by hand inside any of them and its output is unmistakable —
 * `plan-limit.ts` refuses anything that does not name both a window and the
 * word "limit".
 *
 * Codex's reader runs only for a Codex session, and reads only that session's
 * own `CODEX_HOME`. Folding the machine's Codex numbers into a Claude session's
 * report would put a bar next to an account it says nothing about.
 */

import type { IpcMain, IpcMainInvokeEvent, WebContents } from 'electron'
import type { ProviderId, SessionMeta } from '../shared/types'
import { CodexUsageWatcher, readCodexUsage } from './codex-usage'
import { planUsageReadings, watchPlanSnapshots, type PlanLimitSnapshot } from './plan-limit'
import { findProfile, getState, listProfilesForProvider, systemProfileFor } from './profiles'
import { onWebContentsDestroyed } from './web-contents-teardown'
import {
  USAGE_CHANNEL,
  usageReport,
  type UsageAccountRef,
  type UsageReport,
  type UsageWindowReading,
} from './usage-window'

/* -------------------------------------------------------------------------- */
/* Accounts                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * The account a reading from `provider` belongs to, given the session it was
 * read in.
 *
 * The session's own profile when the session runs that agent, the machine's own
 * install otherwise — see the module header for why the second is a statement
 * of fact rather than a guess. The provider check on the found profile is not
 * redundant: `profiles.json` is a file on disk, and a hand-edited one can point
 * a Claude session at a Codex account.
 */
export function accountFor(provider: ProviderId, session: SessionMeta | null): UsageAccountRef {
  const state = getState()
  if (session && session.provider === provider && typeof session.profileId === 'string') {
    const profile = findProfile(state, session.profileId)
    if (profile && profile.provider === provider) {
      return { provider, id: profile.id, name: profile.name, configDir: profile.configDir }
    }
  }
  const system = systemProfileFor(provider, state)
  return { provider, id: system.id, name: system.name, configDir: system.configDir }
}

/* -------------------------------------------------------------------------- */
/* Reasons                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * The sentences shown when there is nothing to draw.
 *
 * Written out rather than composed from fragments because each one has to say
 * what the user could do about it, and "no data" says nothing. An empty report
 * is the ordinary state of a fresh session, not a failure.
 */
const NOTHING_YET =
  'No usage has been reported for this session yet. Claude Code prints its limits only near one, or when /usage is run; Codex records them when a turn completes.'
const CODEX_SILENT =
  'Codex has not recorded a rate limit under this account yet — it writes one into its rollout when a turn completes.'
const UNKNOWN_SESSION =
  'That session is not running here, so there is no screen to read and no account to attribute a reading to.'

/* -------------------------------------------------------------------------- */
/* Assembly                                                                    */
/* -------------------------------------------------------------------------- */

export interface UsageOptions {
  /**
   * What a session is — which agent it runs and which account it resolved to.
   *
   * Supplied by the wiring rather than looked up here: `PtyManager` owns that
   * answer and this module must not hold a second, drifting copy of it. Absent
   * in a build that has not wired it, in which case every session reads as
   * unknown and says so instead of attributing readings to the wrong login.
   */
  describeSession?: (sessionId: string) => SessionMeta | null
}

/** Everything one entry knows, so a push can be rebuilt from either half. */
interface Sources {
  plan: PlanLimitSnapshot | null
  codex: UsageWindowReading[]
  /** Null when this session has no Codex account to read. */
  codexHome: string | null
}

function combine(sessionId: string | null, sources: Sources, session: SessionMeta | null): UsageReport {
  const readings: UsageWindowReading[] = []
  if (sources.plan) {
    readings.push(...planUsageReadings(sources.plan, accountFor('claude', session)))
  }
  readings.push(...sources.codex)

  // The most specific true sentence available, and only when there is nothing
  // to show. `plan-limit.ts` writes its own — "has not printed a plan-limit
  // line in this session yet", "was released to make room" — and those say more
  // than anything that could be composed here.
  let reason = NOTHING_YET
  if (sources.plan?.reason) reason = sources.plan.reason
  else if (sources.codexHome !== null) reason = CODEX_SILENT
  /*
   * Whose report this is, stated even when it is empty.
   *
   * The session's own agent and the login it resolved to at spawn — the same
   * pair `accountFor` gives a reading, asked once more for the report as a
   * whole. Without it a chrome bar showing "not reported" could not say who had
   * not reported, which is most of this feature's life on screen: Claude Code
   * prints nothing about limits until it is near one or is asked.
   */
  const account = session ? accountFor(session.provider, session) : null
  return usageReport(sessionId, readings, reason, Date.now(), account)
}

/**
 * Where this session's Codex rollouts live, or null when it has none.
 *
 * Only a Codex session has one. A Claude session's report must not carry Codex
 * numbers even though they are sitting readable on disk: they describe a
 * different subscription under a different login.
 */
function codexHomeFor(session: SessionMeta | null): string | null {
  if (!session || session.provider !== 'codex') return null
  return accountFor('codex', session).configDir
}

/* -------------------------------------------------------------------------- */
/* Registry                                                                    */
/* -------------------------------------------------------------------------- */

interface Entry {
  sessionId: string
  session: SessionMeta | null
  sources: Sources
  subscribers: Set<WebContents>
  stopPlan: () => void
  codexWatcher: CodexUsageWatcher | null
}

const entries = new Map<string, Entry>()

function push(entry: Entry): void {
  const report = combine(entry.sessionId, entry.sources, entry.session)
  for (const contents of entry.subscribers) {
    if (contents.isDestroyed()) {
      entry.subscribers.delete(contents)
      continue
    }
    try {
      contents.send(USAGE_CHANNEL, entry.sessionId, report)
    } catch (err) {
      entry.subscribers.delete(contents)
      console.error('[usage] dropping a dead subscriber:', err)
    }
  }
}

function ensureEntry(sessionId: string, options: UsageOptions): Entry {
  const existing = entries.get(sessionId)
  if (existing) return existing

  const session = options.describeSession?.(sessionId) ?? null
  const entry: Entry = {
    sessionId,
    session,
    sources: { plan: null, codex: [], codexHome: codexHomeFor(session) },
    subscribers: new Set(),
    stopPlan: () => {},
    codexWatcher: null,
  }
  entries.set(sessionId, entry)

  const watched = watchPlanSnapshots(sessionId, (snapshot) => {
    entry.sources.plan = snapshot
    push(entry)
  })
  entry.sources.plan = watched.snapshot
  entry.stopPlan = watched.stop

  if (entry.sources.codexHome !== null) {
    const watcher = new CodexUsageWatcher(
      entry.sources.codexHome,
      accountFor('codex', session),
      (readings) => {
        entry.sources.codex = readings
        push(entry)
      },
    )
    entry.codexWatcher = watcher
    // Fire and forget: the first read is asynchronous and arrives as a push, so
    // `usage:watch` answers immediately with the screen reading rather than
    // waiting on a directory walk. A window that only ever gets the push is
    // still correct; one that waits for a slow disk is not.
    void watcher.start()
  }

  return entry
}

function release(sessionId: string): void {
  const entry = entries.get(sessionId)
  if (!entry) return
  entry.stopPlan()
  entry.codexWatcher?.dispose()
  entries.delete(sessionId)
}

function releaseAll(contents: WebContents): void {
  for (const [sessionId, entry] of [...entries]) {
    entry.subscribers.delete(contents)
    if (entry.subscribers.size === 0) release(sessionId)
  }
}

/** Forget a session — call when its process exits or its tab closes. */
export function dropUsageSession(sessionId: string): void {
  release(sessionId)
}

/* -------------------------------------------------------------------------- */
/* One-shot reads                                                              */
/* -------------------------------------------------------------------------- */

/**
 * Read everything readable right now, without subscribing.
 *
 * A null session id is the machine-wide read: every Codex account this app
 * knows about, and nothing from Claude, because a Claude reading has to be read
 * off a terminal and there is no terminal in that question. It is what a
 * surface outside any session — an account row in Settings, say — can honestly
 * show.
 *
 * Every Codex account rather than only the machine's own install: a second
 * login has its own `CODEX_HOME` with its own rollouts, and each reading
 * carries the account it came from, so listing them together cannot confuse
 * them. Listing only the first would silently show one person's usage on
 * another person's row.
 */
export async function readUsage(
  sessionId: string | null,
  options: UsageOptions = {},
): Promise<UsageReport> {
  if (sessionId === null) {
    const readings: UsageWindowReading[] = []
    for (const profile of listProfilesForProvider('codex')) {
      const account: UsageAccountRef = {
        provider: 'codex',
        id: profile.id,
        name: profile.name,
        configDir: profile.configDir,
      }
      readings.push(...(await readCodexUsage(profile.configDir, account)))
    }
    return usageReport(null, readings, CODEX_SILENT)
  }

  const live = entries.get(sessionId)
  if (live) return combine(sessionId, live.sources, live.session)

  const session = options.describeSession?.(sessionId) ?? null
  if (!session && options.describeSession) {
    return usageReport(sessionId, [], UNKNOWN_SESSION)
  }
  // Not watched, so there is no shadow terminal and no screen reading — but the
  // Codex half is a file on disk and can be answered anyway.
  const home = codexHomeFor(session)
  const codex = home ? await readCodexUsage(home, accountFor('codex', session)) : []
  return combine(sessionId, { plan: null, codex, codexHome: home }, session)
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

function sessionKey(value: unknown): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error('usage: a session id is required')
  }
  return value
}

/**
 * Register the usage-window IPC.
 *
 * Channels:
 *  - `usage:watch`   (invoke, sessionId)        -> UsageReport   subscribe; pushes `usage:update`
 *  - `usage:read`    (invoke, sessionId | null) -> UsageReport   one-shot, no subscription
 *  - `usage:unwatch` (send,   sessionId)        -> void
 *
 * Separate from `plan:*` rather than replacing it. `plan:refresh` types into a
 * session and is a Claude-specific action with Claude-specific refusals; this
 * is the read side, and the chrome that draws a bar should not have to know
 * that one of its two sources can be prodded and the other cannot.
 */
export function registerUsageIpc(ipcMain: IpcMain, options: UsageOptions = {}): void {
  ipcMain.handle('usage:watch', (event: IpcMainInvokeEvent, sessionId: unknown): UsageReport => {
    const id = sessionKey(sessionId)
    const entry = ensureEntry(id, options)
    entry.subscribers.add(event.sender)
    // One teardown listener per WebContents, not one per session: eleven
    // watched tabs in one window used to mean eleven listeners on one emitter,
    // which is where Node starts warning. `web-contents-teardown.ts` has it.
    onWebContentsDestroyed(event.sender, 'usage', () => releaseAll(event.sender))
    return combine(id, entry.sources, entry.session)
  })

  ipcMain.handle(
    'usage:read',
    (_e: IpcMainInvokeEvent, sessionId: unknown): Promise<UsageReport> =>
      readUsage(typeof sessionId === 'string' && sessionId !== '' ? sessionId : null, options),
  )

  ipcMain.on('usage:unwatch', (event, sessionId: unknown) => {
    if (typeof sessionId !== 'string' || sessionId === '') return
    const entry = entries.get(sessionId)
    if (!entry) return
    entry.subscribers.delete(event.sender)
    if (entry.subscribers.size === 0) release(sessionId)
  })
}
