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
 * A session with no such profile — a plain shell with an agent typed into it,
 * or an agent this app cannot redirect — used to be attributed to the machine's
 * own install, and that paragraph argued it was a statement of fact rather than
 * a fallback: a shell spawns with no `CLAUDE_CONFIG_DIR` (see `sessionEnv`), so
 * a `/usage` panel printed inside one must be describing the default install.
 *
 * It is a fact about the *spawn* and a guess about the *session*. The person at
 * the keyboard can export the variable before starting the agent, and then the
 * app was drawing one login's plan figures under another login's name — which
 * Asad caught twice, the second time pointing at a local session reading an
 * address that belongs to a terminal he was not looking at. So that rung is gone
 * and `session-account.ts` replaces it: the account of a session this app did
 * not start is *read* out of the agent process's own environment, and where it
 * cannot be read the reading is left unattributed and the bar says why.
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
import { forgetfulAccountLimits, type AccountLimitMemory } from './account-limits'
import { CodexUsageWatcher, readCodexUsage } from './codex-usage'
import { blankContextReading, readContextWindow, type ContextWindowReading } from './context-window'
import { planBilling, planUsageReadings, watchPlanSnapshots, type PlanLimitSnapshot } from './plan-limit'
import { findProfile, getState, listProfilesForProvider, systemProfileFor } from './profiles'
import { establishedAccount, sessionAccount } from './session-account'
import {
  CLI_CACHE_WRITE_THROTTLE_MS,
  probeUsage,
  readCachedUsage,
  type UsageProbeOptions,
} from './usage-probe'
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
 * Three answers, and the third one is the whole of the 2026-08-19 change:
 *
 *  1. **The session's own profile**, when the session runs that agent and this
 *     app started it. The provider check on the found profile is not redundant:
 *     `profiles.json` is a file on disk, and a hand-edited one can point a
 *     Claude session at a Codex account.
 *  2. **The machine's own install**, when there is no session at all. That is
 *     the folder case and the machine-wide case, where the question really is
 *     "which login would this app use", and the answer really is the default.
 *  3. **Nothing**, for a session whose account this app has not established —
 *     which `session-account.ts` establishes by reading the agent process's own
 *     environment, and answers `null` for until it has.
 *
 * The third used to be the second, and the module header above defended it: a
 * plain shell spawns with no `CLAUDE_CONFIG_DIR`, so an agent typed into one
 * must be on the default install. That is true of the spawn and false of the
 * session — the person at the keyboard can export the variable — and the cost of
 * it being false is a plan figure drawn under the wrong person's name. A ref
 * with no `configDir` is already handled everywhere downstream as "unattributed,
 * read nothing, say why": `profileFor` in `usage-probe.ts` returns null for it,
 * `combine` pools nothing under it, and `refreshUsage` declines with
 * {@link UNKNOWN_SESSION} rather than starting a `claude` under a login that has
 * nothing to do with the session on screen.
 */
export function accountFor(provider: ProviderId, session: SessionMeta | null): UsageAccountRef {
  const state = getState()
  if (session && session.provider === provider && typeof session.profileId === 'string') {
    const profile = findProfile(state, session.profileId)
    if (profile && profile.provider === provider) {
      return { provider, id: profile.id, name: profile.name, configDir: profile.configDir }
    }
  }
  if (session === null) {
    const system = systemProfileFor(provider, state)
    return { provider, id: system.id, name: system.name, configDir: system.configDir }
  }
  /*
   * Read, not guessed. `establishedAccount` answers from what the agent's own
   * environment said, or `null` while nothing has said anything — and kicks off
   * the one bounded `ps` that will answer it, so the next push carries a name
   * where this one carried a refusal.
   */
  const established = establishedAccount(session.id)
  if (established !== null && established.provider === provider) {
    return {
      provider,
      id: established.profileId,
      name: established.profileName,
      configDir: established.configDir,
    }
  }
  return { provider, id: null, name: null, configDir: null }
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
/**
 * The same "not running here" for the context window, which is a different miss.
 *
 * {@link UNKNOWN_SESSION} is about an account: there is no login to hang a plan
 * figure on. The context window is not read off an account at all — it is read
 * out of the transcript the agent writes in its own working directory — so what
 * is missing here is the folder, not the login, and saying "no account" about it
 * would send a reader looking in the wrong place.
 */
const UNKNOWN_SESSION_CONTEXT =
  'That session is not running here, so this app does not know its folder and cannot find the transcript the figure is read from.'

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
  /**
   * Where an account's settled answer is kept, shared with `plan-limit.ts`.
   *
   * The same memory, deliberately: "this login has no subscription limits" is
   * one fact, and two modules holding two copies of it is how one of them comes
   * to spend four seconds of CPU every half hour re-establishing something the
   * other wrote down at launch. Absent in a test, which then degrades to asking
   * every time rather than to a wrong answer.
   */
  accounts?: AccountLimitMemory
  /** Passed straight to `probeUsage`. Tests replace the transport; nothing else does. */
  probe?: UsageProbeOptions
}

/** Everything one entry knows, so a push can be rebuilt from either half. */
interface Sources {
  plan: PlanLimitSnapshot | null
  codex: UsageWindowReading[]
  /** Null when this session has no Codex account to read. */
  codexHome: string | null
}

/* -------------------------------------------------------------------------- */
/* One account, one reading                                                    */
/* -------------------------------------------------------------------------- */

/**
 * The newest Claude reading held for each account, by reading id.
 *
 * ## Why a reading is not a property of the session it was read in
 *
 * Because of what it describes. `Current session` and `Current week` are
 * *subscription* windows — they belong to the login, they are the same figure
 * whichever terminal happens to print them, and `readingId` already builds their
 * identity out of the account rather than out of the pty. Two sessions on one
 * login are two views of one number.
 *
 * Holding them per session anyway had a cost, and it was the cost Asad reported
 * on 2026-08-18: *"it keeps coming in the running sessions"*. Each session's bar
 * knew only what its own screen had said, so each one waited until its own figure
 * went stale and then typed `/usage` into its own terminal to learn what the
 * session next to it already knew. Five sessions meant five panels, on one
 * account, for one number — and a session opened fresh sat empty until it had
 * spent a panel of its own, even though the answer was already in the process.
 *
 * Sharing them removes both. A new session on a login that has been read shows
 * the figure immediately and never types; and because `leadIsLive` in the
 * renderer is what decides whether to fetch at all, a session with a shared live
 * reading does not even reach the gate. What is left is one read per account per
 * staleness cycle, which is the loop this feature is meant to have.
 *
 * Nothing is invented in the process: a shared reading keeps the timestamps of
 * the moment it was actually taken, so it ages, goes stale and says so on
 * exactly the schedule it would have on the bar it was read for.
 */
const claudeByAccount = new Map<string, Map<string, UsageWindowReading>>()

/**
 * Fold this session's own Claude readings into its account's, and hand back the
 * account's.
 *
 * Newest wins per window, compared on `reportedAt` — which is when the *source*
 * produced the number, not when this app last looked at it. That is the right
 * comparison and the distinction matters: a session re-reading an hour-old
 * `/usage` panel that is still sitting on its screen would otherwise present it
 * as newer than a genuinely fresh reading from the session next door.
 */
function shareClaudeReadings(
  configDir: string,
  own: readonly UsageWindowReading[],
): UsageWindowReading[] {
  const held = claudeByAccount.get(configDir) ?? new Map<string, UsageWindowReading>()
  for (const reading of own) {
    const previous = held.get(reading.id)
    if (!previous || reading.reportedAt >= previous.reportedAt) held.set(reading.id, reading)
  }
  if (held.size > 0) claudeByAccount.set(configDir, held)
  return [...held.values()]
}

/** Forget every shared reading. Tests only; nothing in the app needs it. */
export function resetSharedUsage(): void {
  claudeByAccount.clear()
}

/**
 * Whether this session may be shown its account's Claude readings.
 *
 * A session that is explicitly running some other agent may not, and the reason
 * is the same one the module header gives for not folding Codex's numbers into a
 * Claude session: a bar next to an account it says nothing about. A Codex session
 * has its own subscription and its own windows, and putting this machine's Claude
 * limits on it would push the reading it *does* have off the bar.
 *
 * A Claude session may, obviously. So may a shell and so may a session this
 * process cannot describe, and that is not a loophole: typing `claude` at a shell
 * prompt is an ordinary thing to do — this app offers a button that does exactly
 * that — and such a session runs under the machine's own Claude install, which is
 * the account whose readings these are.
 */
function mayShareClaude(session: SessionMeta | null): boolean {
  return session === null || session.provider === 'claude' || session.provider === 'shell'
}

/**
 * Which agent's transcript store to read a context window out of — the one that
 * is *running*, not the one this app launched.
 *
 * ## The bug this exists to end, measured 2026-08-20
 *
 * The context figure vanished off the bar and this line is why. `usage:context`
 * handed `readContextWindow` the session record's own `provider`, and for a
 * shell that somebody has since started Claude in that word is `shell` — so the
 * read short-circuited on *"This tab is a plain shell, so there is no model and
 * no context window to measure"* and the bar drew nothing at all. Simulated
 * against his own disk with a real `~/ClaudeAsad` session: as `claude` it reads
 * 361,058 of 1,000,000; as `shell`, byte-identical folder, it reads
 * `not-reported` and `contextFigure` returns null.
 *
 * And a shell is what he has. *"Starting a session gives you a plain shell"* —
 * the header of `agent-presence.ts` — so every session where the agent was
 * started by pressing Run Claude or by typing `claude` at the prompt carries
 * `provider: 'shell'` forever, including the one he filmed. The figure was only
 * ever going to appear over sessions this app spawned the CLI into directly.
 *
 * ## Why the shell is answered rather than refused
 *
 * Because {@link mayShareClaude} decided this exact question one file-half ago
 * and decided it the other way: a shell prompt with `claude` typed at it *is* a
 * Claude session for reading purposes, and the plan half of this bar has been
 * treating it as one all along. One record, two halves, two answers is the
 * disagreement — not the shell.
 *
 * The renderer closes the same gap from its own side and is why this cannot
 * invent a figure over a bare terminal: `runningProvider` in
 * `SessionControls.tsx` returns `'shell'` until the session's *screen* says an
 * agent is there, and the whole controls cluster — this bar included — returns
 * null on that value. So a shell with nothing in it has no bar to draw a number
 * on, and by the time there is one, an agent has been seen.
 *
 * The residual case is a shell someone typed a *different* agent into, in a
 * folder Claude has also worked in. That reads Claude's newest conversation
 * there, `chosen: 'inferred'` with its rival count stated in the panel, which is
 * the same inference this app already makes for every session it did not start.
 * Narrowing it would mean asking the screen which CLI is on it, and this handler
 * has no screen — `readAgentFromScreen` lives behind `agent:controls:read`. The
 * honest fallback is already in place either way: a folder with no Claude
 * transcript answers `nothing-yet`, and nothing-yet draws nothing.
 */
function contextProvider(session: SessionMeta): ProviderId {
  return session.provider === 'shell' ? 'claude' : session.provider
}

function combine(sessionId: string | null, sources: Sources, session: SessionMeta | null): UsageReport {
  const readings: UsageWindowReading[] = []
  const claudeAccount = accountFor('claude', session)
  const own = sources.plan ? planUsageReadings(sources.plan, claudeAccount) : []
  /*
   * An account with no configuration directory is not an account anything may be
   * pooled under. `UsageAccountRef.configDir` is nullable because a reading can
   * arrive unattributed, and a pool keyed on "unknown" would put two different
   * logins' figures in one bucket — the exact confusion the account is carried
   * around to prevent. Such a session keeps its own reading and shares nothing.
   */
  const pool = mayShareClaude(session) ? claudeAccount.configDir : null
  readings.push(...(pool === null ? own : shareClaudeReadings(pool, own)))
  readings.push(...sources.codex)

  // The most specific true sentence available, and only when there is nothing
  // to show. `plan-limit.ts` writes its own — "has not printed a plan-limit
  // line in this session yet", "was released to make room" — and those say more
  // than anything that could be composed here.
  let reason = NOTHING_YET
  if (sources.plan?.reason) reason = sources.plan.reason
  else if (sources.codexHome !== null) reason = CODEX_SILENT
  /*
   * Whose report this is, stated even when it is empty — see
   * {@link sessionAccountRef}. Without it a chrome bar showing "not reported"
   * could not say who had not reported, which is most of this feature's life on
   * screen: Claude Code prints nothing about limits until it is near one or is
   * asked.
   */
  return usageReport(sessionId, readings, reason, Date.now(), sessionAccountRef(session))
}

/**
 * Whose report this is, stated even when it is empty — asked about the agent
 * that is **running**, not the one this app launched.
 *
 * ## The disagreement this line used to cause
 *
 * It read `accountFor(session.provider, session)`, and for the commonest session
 * this app has that is a question with no answer. `provider` is a record of the
 * spawn, and *"Starting a session gives you a plain shell"* — the header of
 * `renderer/shell/agent-presence.ts` — so every session where the agent was
 * started by pressing Run Claude or by typing `claude` at the prompt carries
 * `provider: 'shell'` for the rest of its life. There is no such thing as a
 * shell account: `supportsProfiles('shell')` is false, no profile is ever a
 * login of one, and {@link accountFor} correctly answers "nothing" for it.
 *
 * So the bar beside the account chip named nobody over exactly the sessions the
 * chip had just been taught to name, and it named somebody again the moment a
 * reading arrived — because a *reading* is stamped with
 * `accountFor('claude', …)`, which does ask the right question. One control
 * flickering between "no account" and an address while the chip forty pixels
 * away holds one name is the disagreement Asad reported, and it is this line.
 *
 * ## The one place that answers it
 *
 * `establishedAccount` in `session-account.ts` — the same answer the account
 * chip reads over `session:account`, and the same answer the plan readings are
 * stamped with. It knows which agent is actually running because it read the
 * process's own environment to find out, so its provider is the provider to ask
 * about. A session with nothing established falls back to the spawn record's
 * provider and gets the unattributed ref it had before, which every reader
 * downstream already draws as "nothing was read" with a sentence.
 *
 * Exported so `usage-ipc.test.ts` can hold this and `readSessionAccount` to the
 * same answer, which is the assertion that would have caught the divergence.
 */
export function sessionAccountRef(session: SessionMeta | null): UsageAccountRef | null {
  if (session === null) return null
  return accountFor(establishedAccount(session.id)?.provider ?? session.provider, session)
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

/**
 * Push to every other watched session on the same Claude login.
 *
 * The delivery half of {@link shareClaudeReadings}, and it has to exist for the
 * same reason the pool does. A reading arrives on the session whose screen
 * printed it, and nothing else in this process is subscribed to that session —
 * so the bar two panes over would learn nothing until its own screen said
 * something, which for a session sitting at its prompt is never.
 *
 * Called only from the plan-snapshot callback, so it cannot recur: the pushes it
 * makes read the pool rather than adding to it.
 */
function pushAccountSiblings(source: Entry): void {
  if (!mayShareClaude(source.session)) return
  const account = accountFor('claude', source.session).configDir
  if (account === null) return
  for (const other of entries.values()) {
    if (other === source) continue
    if (!mayShareClaude(other.session)) continue
    if (accountFor('claude', other.session).configDir !== account) continue
    push(other)
  }
}

/**
 * The work `usage:watch` starts and deliberately does not wait for, held so
 * that something else can.
 *
 * `usage:watch` has to answer in the same tick — a bar that waits on a disk is a
 * bar that flashes empty first — so the reads below are fired off and forgotten.
 * Forgotten by the *caller*: the promises still exist, they still finish, and
 * what they do when they finish is write a reading into `claudeByAccount`, which
 * is module state shared by every session on that login.
 *
 * That is correct in the app, where a login's directory outlives any one
 * session, and it is a race everywhere else. A suite is the everywhere else: one
 * test's watch starts a read, the test ends, `resetSharedUsage()` clears the
 * pool for the next test, and *then* the read lands — putting the previous
 * test's figure, stamped a moment ago, into a pool that was supposed to be
 * empty. The next test asks whether a probe is worth starting, is told the login
 * already has a figure from thirty seconds ago, and answers `cached` without
 * asking anything. Reproduced deliberately in `usage-ipc-race.test.ts` by
 * holding one `readFile`; observed in the wild as
 * "goes and asks once the CLI would fetch again" failing under full-suite load
 * with `probe.calls()` of 0, and passing every time it was run alone.
 *
 * So the promises are kept. {@link settleUsageWatch} is the join, and it is the
 * only thing in this file that needs them.
 */
const backgroundWork = new Set<Promise<unknown>>()

/**
 * Keep hold of one piece of fire-and-forget work.
 *
 * Two details rather than a bare `add`. The `.catch`, because these are
 * `void`ed at the call site precisely so that a failed disk read does not become
 * an unhandled rejection, and holding the promise without one would reintroduce
 * exactly that. And the `.finally`, so a set that is joined many times over a
 * long-lived process does not grow: it runs as a microtask, which is what makes
 * the assignment below guaranteed to have happened before it fires — the same
 * ordering `TranscriptWatcher.drain` documents.
 */
function inBackground(work: Promise<unknown>): void {
  const tracked = work
    .catch(() => undefined)
    .finally(() => {
      backgroundWork.delete(tracked)
    })
  backgroundWork.add(tracked)
}

/**
 * Wait until nothing `usage:watch` started is still running. Tests only.
 *
 * A loop rather than one `Promise.all`, because one of these pieces of work
 * starts another: the account probe resolves and *then* reads the disk. Waiting
 * on the set once would return with the second read still outstanding, which is
 * the same race one layer down.
 *
 * Nothing in the app calls this. The app wants these reads to arrive whenever
 * they arrive — that is what makes a bar fill in a moment after it appears.
 */
export async function settleUsageWatch(): Promise<void> {
  while (backgroundWork.size > 0) await Promise.all([...backgroundWork])
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
    // And everyone else on this login, because the figure that just arrived is
    // theirs as well. Without this the sharing would only reach a bar that
    // mounted *after* the reading — a session already open would sit on its own
    // stale figure until it went and typed `/usage` for a number this process
    // is holding. See `pushAccountSiblings`.
    pushAccountSiblings(entry)
  })
  entry.sources.plan = watched.snapshot
  entry.stopPlan = watched.stop

  /*
   * The free half of this feature, run the moment anything watches a session.
   *
   * Fire and forget, exactly as the Codex watcher below is: `usage:watch`
   * answers immediately with whatever is already pooled, and the file read
   * arrives as a push a few milliseconds later. A bar that waits on a disk is a
   * bar that flashes empty first.
   */
  /*
   * Establish whose account this is *before* reading a figure off its disk.
   *
   * The order is the point. `accountFor` answers "not established" until the
   * `ps` in `session-account.ts` has landed, and seeding against an
   * unestablished account reads nothing at all — correctly, but then nothing
   * would come back to try again. So the probe is awaited and the seed is what
   * happens next, both still fire-and-forget as far as `usage:watch` is
   * concerned: it answers immediately with whatever is already pooled and both
   * of these arrive as a push a few milliseconds later.
   *
   * The `push` in between is not incidental. A session whose account has just
   * been established has a name to put on a bar that a moment ago had a sentence
   * saying it had none.
   */
  if (mayShareClaude(session)) inBackground(seedFromDisk(accountFor('claude', session)))

  /*
   * And, for a session whose account is not this app's own spawn record,
   * establish whose it is and then do the same read again.
   *
   * Two seeds rather than one reordered seed, and that is deliberate. The line
   * above is unchanged and still runs first, so a session this app started is
   * seeded on exactly the schedule it always was — the probe below cannot delay
   * it. For a session this app did not start, that first seed is a no-op
   * (`accountFor` answers "not established", `profileFor` reads nothing), and
   * this is what fills the bar in once the agent's own environment has said
   * which login it is on.
   *
   * The `push` in between is not incidental: a session whose account has just
   * been established has a name to put on a bar that a moment ago carried a
   * sentence saying it had none.
   */
  inBackground(
    sessionAccount(entry.sessionId).then((answer) => {
      if (answer.kind !== 'known') return
      if (entries.get(entry.sessionId) !== entry) return
      push(entry)
      return seedFromDisk(accountFor('claude', session))
    }),
  )

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
    inBackground(watcher.start())
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
/* Refreshing, without touching anybody's session                              */
/* -------------------------------------------------------------------------- */

/**
 * The floor between two probes on one login.
 *
 * A minute, and like the pool above it is covering a race rather than setting a
 * rate. The renderer only asks when the figure it is drawing has gone stale,
 * which for a five-hour window is twenty-five minutes; nothing here is what
 * decides how often a reading is taken. What this covers is the second between
 * one bar asking and the answer arriving, into which every other bar in the
 * window walks when somebody brings it forward — {@link inFlight} absorbs the
 * ones that arrive while a probe is running, and this absorbs the ones that
 * arrive just after a probe that found nothing to show for it.
 *
 * A press goes past it. That is what a press is for.
 */
const PROBE_FLOOR_MS = 60_000

/** When a probe last finished for a login, whatever it found. */
const lastProbeAt = new Map<string, number>()

/** Probes running right now, so several bars asking at once ask once. */
const inFlight = new Map<string, Promise<UsageRefreshResult>>()

/** Forget the probe floor and any in-flight probe. Tests only. */
export function resetUsageProbes(): void {
  lastProbeAt.clear()
  inFlight.clear()
}

/**
 * What a refresh did, said plainly enough to put on the bar.
 *
 * `ok` is true only when there are numbers to show for it. Everything else
 * carries a sentence, and none of them is terminal for the session the way the
 * old `/usage` failures had to be: nothing here was paid for out of somebody's
 * terminal, so nothing here has to be prevented from happening again. That is
 * the whole difference between this and what it replaced.
 */
export interface UsageRefreshResult {
  ok: boolean
  /**
   * Which of the ways this went. `cached` means the answer was already on disk
   * and fresh enough that no process was started — the free path, and the
   * commonest one on a machine with more than one session open.
   */
  outcome: 'ok' | 'cached' | 'no-limits' | 'signed-out' | 'no-binary' | 'unreadable' | 'unwatched' | 'settled'
  detail: string
  /** Wall clock, so the cost of this feature is visible rather than asserted. */
  elapsedMs: number
  /** True when a `claude` process was started. False on both free paths. */
  spawned: boolean
}

/**
 * Fold readings into the account's pool and tell every bar on that login.
 *
 * The same two steps the plan-snapshot callback takes, for the same reason: a
 * reading belongs to the login, and the bar that asked for it is rarely the only
 * one showing it.
 */
function publishAccountReadings(configDir: string, readings: readonly UsageWindowReading[]): void {
  if (readings.length === 0) return
  shareClaudeReadings(configDir, readings)
  for (const entry of entries.values()) {
    if (!mayShareClaude(entry.session)) continue
    if (accountFor('claude', entry.session).configDir !== configDir) continue
    push(entry)
  }
}

/**
 * Read what the CLI already wrote for this login, and push it if it is news.
 *
 * Free — one file read — and worth doing the moment a bar appears. Three things
 * it covers that nothing else does: a bar that has just mounted shows a figure
 * immediately instead of four seconds later, a reading his own terminal
 * `claude` took by running `/usage` is picked up without this app asking for
 * anything, and an app that has just started knows what it knew before it was
 * closed.
 *
 * Never a substitute for the probe. `readCachedUsage` stamps every reading with
 * the moment the *CLI* fetched it, so an old block produces an old reading which
 * ages, goes stale and is refused a live bar exactly as it should be. See the
 * header of `usage-probe.ts` for why that distinction is the whole reason this
 * file is safe to read at all.
 */
async function seedFromDisk(account: UsageAccountRef): Promise<UsageWindowReading[]> {
  if (account.configDir === null) return []
  const cached = await readCachedUsage(account)
  publishAccountReadings(account.configDir, cached.readings)
  return cached.readings
}

/**
 * Whether a probe could possibly come back with a newer number than this login
 * already has.
 *
 * ## The bug this replaced, which is the whole reason it is spelled this way
 *
 * This used to ask `isDrawable` of every reading in the pool and skip the probe
 * if any one of them passed. Asad opened the panel and every row said
 * `read 12m ago`, on a design whose entire premise is that opening the panel is
 * the fetch — and the reason was here. `isDrawable` retires a reading after a
 * twelfth of *its own* window, so a five-hour reading survives twenty-five
 * minutes and a **weekly one survives fourteen hours**. Every reading from one
 * CLI fetch carries the same `fetchedAtMs`, so the weekly row kept the whole
 * login looking "live" and the probe was never started, for the rest of the day.
 * Measured on this machine while the fix was written: the block in
 * `~/.claude.json` was 31.9 minutes old and a panel open returned `cached`.
 *
 * ## Why the CLI's own throttle is the right question instead
 *
 * Because it is the only thing that decides whether asking can produce a
 * different answer. Claude Code rewrites `cachedUsageUtilization` at most once
 * every five minutes — `CLI_CACHE_WRITE_THROTTLE_MS`, read out of the binary —
 * so a probe inside that window is guaranteed to hand back the figure this
 * process already has, at a cost of a 725 MB boot. Outside it, a probe can
 * genuinely move the number, and the person looking at the panel asked for it.
 *
 * So this is a timestamp comparison after all, and deliberately not a judgement
 * about drawability: whether a reading is *worth drawing* is the renderer's
 * question and it goes on answering it — an aged row still says `read 12m ago`.
 * This one is only ever "is there anything to go and get".
 */
function accountFigureIsAsFreshAsItCanBe(configDir: string, now = Date.now()): boolean {
  const held = claudeByAccount.get(configDir)
  if (!held) return false
  for (const reading of held.values()) {
    if (reading.used.state !== 'reported') continue
    if (now - reading.reportedAt < CLI_CACHE_WRITE_THROTTLE_MS) return true
  }
  return false
}

/**
 * Bring this session's login's usage up to date, without going near a terminal.
 *
 * Disk first, then — only if that was not enough — one short-lived `claude` of
 * this app's own. See `usage-probe.ts` for what each costs, measured.
 *
 * `force` is a person pressing. It reaches past the floor and past a remembered
 * "this login has no subscription limits", which are the only two things that
 * can make this decline to do anything.
 */
export async function refreshUsage(
  sessionId: string,
  options: UsageOptions = {},
  force = false,
): Promise<UsageRefreshResult> {
  const startedAt = Date.now()
  const done = (
    ok: boolean,
    outcome: UsageRefreshResult['outcome'],
    detail: string,
    spawned = false,
  ): UsageRefreshResult => ({ ok, outcome, detail, elapsedMs: Date.now() - startedAt, spawned })

  const session = entries.get(sessionId)?.session ?? options.describeSession?.(sessionId) ?? null
  if (!mayShareClaude(session)) {
    return done(false, 'unwatched', 'This session runs a different agent, so it has no Claude limits to read.')
  }
  const account = accountFor('claude', session)
  const configDir = account.configDir
  if (configDir === null) {
    return done(false, 'unwatched', UNKNOWN_SESSION)
  }

  // The free path, always, and before anything else is considered: a reading
  // taken two minutes ago by the session next door — or by his own terminal —
  // is the same number a probe would go and fetch.
  await seedFromDisk(account)
  if (!force && accountFigureIsAsFreshAsItCanBe(configDir)) {
    return done(
      true,
      'cached',
      'Claude Code fetched this less than five minutes ago and will not fetch it again yet, so this is its own newest figure — nothing was started.',
    )
  }

  const accounts = options.accounts ?? forgetfulAccountLimits()
  if (!force && accounts.read(configDir)?.answer === 'no-limits') {
    return done(false, 'settled', 'This login has no subscription limits, so there is nothing to read.')
  }
  /*
   * The gate that costs nothing at all, taken before the one that costs four
   * seconds.
   *
   * Claude Code prints `· Claude Max ·` or `· Claude API ·` on its own welcome
   * banner, and `plan-limit.ts` has been reading that line off the session's
   * screen all along. An `api` login has no rolling subscription window for
   * anything to report, so the answer is already known and starting a process
   * to be told it would be the whole complaint in miniature. Written down as
   * well as returned, because it is a fact about the login rather than about
   * this terminal, and every other session on it is owed the same shortcut.
   *
   * A press still gets through. The banner describes the CLI as it started, and
   * somebody who has since run `/login` is entitled to make this app look again
   * rather than be told what it read minutes ago.
   */
  if (!force && planBilling(sessionId) === 'api') {
    accounts.write(configDir, { billing: 'api', answer: 'no-limits' })
    return done(false, 'no-limits', 'This login is billed through the Claude API, which has no subscription limits to read.')
  }
  if (!force && Date.now() - (lastProbeAt.get(configDir) ?? 0) < PROBE_FLOOR_MS) {
    /*
     * A probe finished for this login moments ago and did not produce a figure.
     *
     * The reason it did not is already on the bar — the neighbour that ran it
     * got the sentence — so this says the same thing rather than inventing a
     * second explanation. A probe that *succeeded* cannot reach here: it
     * published into the pool that `accountFigureIsAsFreshAsItCanBe` above reads,
     * and its readings are stamped with the moment it ran.
     */
    return done(false, 'unreadable', 'This login was read a moment ago and had nothing to report.')
  }

  // Several bars on one login asking at the same instant is the ordinary case —
  // bringing the window forward wakes all of them in one tick — and it must cost
  // one process, not four.
  const running = inFlight.get(configDir)
  if (running) return await running

  const attempt = (async (): Promise<UsageRefreshResult> => {
    try {
      const result = await probeUsage(account, options.probe ?? {})
      lastProbeAt.set(configDir, Date.now())
      if (result.outcome === 'ok') {
        publishAccountReadings(configDir, result.readings)
        /*
         * A reading is proof the login has windows to read, so anything
         * remembered to the contrary is wrong now and is dropped. The same
         * clearing `plan-limit.ts` does on a successful panel, and for the same
         * reason: a different login in the same directory, or a plan bought
         * since, must not leave the feature switched off for ever.
         */
        accounts.forget(configDir)
        return done(true, 'ok', result.detail, true)
      }
      /*
       * The one answer worth writing down, and the only one.
       *
       * An account with no subscription behind it will not grow one, so asking
       * again every half hour is four seconds of somebody's CPU for a fact this
       * app already has. `signed-out` is deliberately not written: a person who
       * signs in expects the bar to start working, and the floor above is
       * enough to keep the asking cheap until they do.
       */
      if (result.outcome === 'no-limits') accounts.write(configDir, { answer: 'no-limits' })
      return done(false, result.outcome, result.detail, true)
    } finally {
      inFlight.delete(configDir)
    }
  })()
  inFlight.set(configDir, attempt)
  return await attempt
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
 *  - `usage:refresh` (invoke, sessionId, force?) -> UsageRefreshResult
 *  - `usage:context` (invoke, sessionId)        -> ContextWindowReading
 *  - `usage:unwatch` (send,   sessionId)        -> void
 *
 * `usage:refresh` is the channel that replaced `plan:refresh` for everything
 * except a person pressing something. The difference is the whole of the
 * 2026-08-18 change: `plan:refresh` types `/usage` into a session and draws a
 * panel over whatever is in it, and `usage:refresh` reads a file and, at worst,
 * starts a `claude` of this app's own in the user's home directory. Both answer
 * the same question about the same login. Only one of them can interrupt
 * somebody.
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

  /*
   * `force` is a person pressing, read defensively for the same reason
   * `plan:refresh` reads it that way: a renderer that predates the argument
   * sends nothing, and the honest default for "did somebody press this" is no.
   */
  ipcMain.handle(
    'usage:refresh',
    (_e: IpcMainInvokeEvent, sessionId: unknown, force?: unknown): Promise<UsageRefreshResult> =>
      refreshUsage(sessionKey(sessionId), options, force === true),
  )

  /*
   * How full the model's context window is, which is the one figure on this bar
   * that costs nothing to be sure of.
   *
   * A separate channel rather than a field on `UsageReport`, because the two
   * readings have opposite economics and Asad's settlement of 2026-08-19 turns
   * on exactly that asymmetry — plan limits behind a dropdown, context outside
   * it. A plan figure costs a whole Claude Code boot to refresh (725 MB peak
   * RSS, ~3s, measured with `PROBE_ARGS` in `usage-probe.ts`); a context figure
   * is a bounded tail read of a file the agent already wrote, measured on this
   * machine at 2–17 ms. Folding the cheap one into the expensive one's report
   * would tie its freshness to the expensive one's schedule, which is the whole
   * complaint.
   *
   * Unwatched and unpushed on purpose: nothing here subscribes, nothing here
   * remembers, and the renderer asks when the answer could have changed. See
   * `useContextWindow` in `src/renderer/shell/useUsageBar.ts` for which events
   * those are.
   */
  ipcMain.handle(
    'usage:context',
    async (_e: IpcMainInvokeEvent, sessionId: unknown): Promise<ContextWindowReading> => {
      const id = sessionKey(sessionId)
      const session = options.describeSession?.(id) ?? null
      if (!session) {
        return blankContextReading(null, 'not-reported', UNKNOWN_SESSION_CONTEXT)
      }
      /*
       * Which store to look in, which is a question about this session's
       * *account* and was not being asked at all.
       *
       * `readContextWindow` defaults its scope to `claudeConfigDir()` — the
       * machine's own install — so a session running under a named account had
       * its context read out of the wrong directory entirely. It found either
       * nothing or, worse, the default login's own conversation in the same
       * folder. `accountFor` is the one place that resolves a session's login,
       * and it is asked here rather than a second copy of the resolution being
       * written, for the reason `index.ts` gives where `describeSession` is
       * declared: two answers to "whose account is this session on" is how one
       * login's figure lands on another login's bar.
       *
       * Only for the agents whose transcripts live in a Claude store. Codex
       * takes `codexHome` below and reads nothing from `scope`.
       */
      const store =
        session.provider === 'codex' ? null : accountFor('claude', session).configDir
      return await readContextWindow({
        provider: contextProvider(session),
        cwd: session.cwd,
        // The conversation this app named at spawn, when it named one. Present
        // for a Claude session this app started fresh; absent for a resumed one,
        // for another agent, and for every session started somewhere else — all
        // of which keep the inference and are labelled as inferred.
        ...(session.agentSessionId ? { agentSessionId: session.agentSessionId } : {}),
        ...(store === null ? {} : { scope: { configDir: store } }),
        // Only a Codex session has one, and `codexHomeFor` is what already
        // decides that here — asking it again keeps one answer to the question
        // rather than two that can disagree about which account a tab reads.
        codexHome: codexHomeFor(session) ?? undefined,
      })
    },
  )

  ipcMain.on('usage:unwatch', (event, sessionId: unknown) => {
    if (typeof sessionId !== 'string' || sessionId === '') return
    const entry = entries.get(sessionId)
    if (!entry) return
    entry.subscribers.delete(event.sender)
    if (entry.subscribers.size === 0) release(sessionId)
  })
}
