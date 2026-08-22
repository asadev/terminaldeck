/**
 * Which login a session's agent is actually running under — established from
 * evidence, or withheld.
 *
 * ## The defect this exists to end
 *
 * An account name printed beside a session is a claim about that session. Until
 * this module existed the app could only make that claim for a session it had
 * started itself: `SessionMeta.profileId` is written at spawn from the profile
 * `host-core.ts` resolved, and it is exact. For everything else the app fell
 * through to the machine's own install and named it anyway — `accountFor` in
 * `usage-ipc.ts` returned `systemProfileFor(provider)`, and `AccountChip` fell
 * back to `accountForFolder`, which resolves the *folder's* default account.
 * Neither had looked at the session.
 *
 * That fallback was defended, in the header of `usage-ipc.ts`, as a statement of
 * fact rather than a guess: a plain shell spawns with no `CLAUDE_CONFIG_DIR`, so
 * an agent started inside one must be on the default install. The premise is
 * true about the *spawn* and false about the *session*, because the person at
 * the keyboard can export the variable, or `cd` into a project whose direnv
 * does, or start the agent somewhere this app never looked. Asad reported the
 * consequence twice, the second time pointing at a local session:
 *
 *   > "here it is showing actually the wrong account — app.imatch.ae is not the
 *   > correct account which is connected to this session … this is your terminal
 *   > account which is becoming visible here"
 *
 * And, separately, that those outside sessions must keep appearing:
 *
 *   > "I did not start this session … this is actually your session where I am
 *   > talking to you inside the terminal … which is okay, I want it that way"
 *
 * So the answer is not to hide them. It is to stop guessing their account.
 *
 * ## The ladder, in the order it is climbed
 *
 *  1. **The spawn.** A session this app started carries the profile it was
 *     resolved to, and that profile carries the configuration directory this app
 *     handed the process. Nothing can be more direct than the app's own record
 *     of what it did, so this stops here and never probes.
 *
 *  2. **The agent's own report, through its hooks.** The hook command runs as a
 *     child of the agent, so it inherits — *is* — the agent's environment, and
 *     the Windows hook client reads the config-directory variables out of its
 *     own process and sends them with every event (`hook-server.ts`,
 *     {@link AgentEnvReport}). This is the only honest channel on Windows,
 *     where nothing unelevated can read another process's environment, and it
 *     is evidence of exactly the same kind rung 3 gathers with `ps`: the
 *     variable as the agent's process actually has it, or its absence with the
 *     rest of the environment as proof. Kept per session while the agent keeps
 *     firing events; dropped on `SessionEnd` and when the pty goes.
 *
 *     This rung is what answers for **Run Claude** as well as for a typed-in
 *     agent, on Windows: that button does not spawn — `AccountChip.tsx` writes
 *     `claude\r` into the existing shell pty — so those sessions carry no
 *     spawn record, and Claude fires `SessionStart` at CLI startup, which
 *     means the report lands the moment the agent starts rather than a turn
 *     later.
 *
 *  3. **The process's own environment.** A session with no profile — a plain
 *     shell with an agent typed into it, which is the case above — is a real pty
 *     with a real pid, and the agent is a descendant of it. On macOS and Linux
 *     `ps eww -p <pid>` prints a process's whole environment, so the store that
 *     agent is using can be *read* rather than assumed. Measured on this Mac
 *     against Claude Code 2.1.234:
 *
 *         $ ps eww -p 2471 | tr ' ' '\n' | grep -c '='
 *         28                      # the full environment, 1410 bytes
 *         $ env CLAUDE_CONFIG_DIR=/tmp/fake-cfg node -e '…' &
 *         $ ps eww -p $! | tr ' ' '\n' | grep CLAUDE_CONFIG_DIR
 *         CLAUDE_CONFIG_DIR=/tmp/fake-cfg
 *
 *     Two things about that measurement decide the code below. The environment
 *     of a **SIP-protected** system binary is scrubbed by the kernel — the same
 *     command against `/bin/sleep` prints the command line and no environment at
 *     all — which is why a *missing* variable is only believed when the rest of
 *     the environment came back with it. And the agent is frequently not the
 *     pty's own child: in Terminal it is a child of the login shell, so the
 *     process table is walked rather than the immediate child inspected.
 *
 *     An absent `CLAUDE_CONFIG_DIR` in an environment that was genuinely read is
 *     an answer, not a gap: it means the agent is on its own default store,
 *     `$HOME/.claude`. Asked as `systemConfigDir(provider, {})` and *not* as
 *     "the machine's own install" — those are the same string on an ordinary
 *     machine and different ones on a Deck launched from a terminal that was
 *     itself inside a session on another profile, where the app inherits that
 *     profile's variable. This branch has just read the agent's own environment
 *     and found no variable in it, so the app's environment has nothing to say
 *     about it. It is only believed when `HOME` matches this app's own, because
 *     a default store is `$HOME/.claude` and another `HOME` is another store
 *     this app has no record of.
 *
 *  4. **Nothing else, and this was checked rather than assumed.** The obvious
 *     third rung is the transcript, and it does not exist: every line of all 542
 *     transcripts under `~/.claude/projects` was parsed looking for a structural
 *     field named `emailAddress`, `accountUuid`, `organizationName`,
 *     `oauthAccount` or `email`, and there were **zero**. A transcript records
 *     `sessionId`, `cwd`, `gitBranch`, `version`, `userType` and the messages —
 *     nothing about who is signed in. `<configDir>/.claude.json` does carry it
 *     (`oauthAccount.emailAddress`, and `cachedUsageUtilization.accountUuid`),
 *     but that answers *which account is signed into a directory*, which is only
 *     useful once the directory is known — so it is the step after this one, not
 *     a step of it. See {@link accountEmail}.
 *
 * Everything that falls off the bottom is {@link SessionAccountAnswer} `kind:
 * 'withheld'` with a sentence, which is the vocabulary `usage-reach.ts` already
 * uses for "these are somebody else's figures, and here is why you are not being
 * shown them". Deliberately the same word: a second name for one idea is how two
 * screens come to word the same refusal differently.
 *
 * ## Cost
 *
 * `ps` twice, both bounded, both a few milliseconds. Nothing here spawns an
 * agent CLI. `claude auth status` costs ~245 ms and is *not* on this path at
 * all; the email beside a directory is read from `.claude.json`, once per
 * directory, and memoised for the life of the process.
 */

import { execFile } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, join, resolve, win32 } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { AGENT_CATALOG } from '../shared/agent-catalog'
import type { ProviderId, SessionMeta } from '../shared/types'
import { onHookEvent, type AgentEnvReport, type HookEvent } from './hook-server'
import { currentPlatform, isWindows, type Platform } from './platform/host'
import { findProfile, getState, supportsProfiles, systemConfigDir, systemProfileFor } from './profiles'

const run = promisify(execFile)

/* ------------------------------------------------------------------ model -- */

/**
 * How the answer was arrived at, so a screen can show its working.
 *
 * `spawn` — this app's own record of what it started. `hook` — the agent's own
 * hook reported the environment it is running with. `process` — read from the
 * process table with `ps eww`.
 */
export type SessionAccountSource = 'spawn' | 'hook' | 'process'

export interface KnownSessionAccount {
  kind: 'known'
  /** The agent the account is a login of. */
  provider: ProviderId
  /** The configuration directory that agent is actually reading. Never empty. */
  configDir: string
  /** The profile record, when this app has one for that directory. */
  profileId: string | null
  profileName: string | null
  source: SessionAccountSource
}

/**
 * `withheld` rather than `unknown`, matching `renderer/shell/usage-reach.ts`.
 *
 * The reason travels with the refusal because it is the whole of what a reader
 * gets in place of a name, and a bare boolean would have every call site
 * inventing its own wording for it.
 */
export interface WithheldSessionAccount {
  kind: 'withheld'
  reason: string
}

export type SessionAccountAnswer = KnownSessionAccount | WithheldSessionAccount

/** The sentences, written out so each one says what a person could do about it. */
const NO_SESSION =
  'That session is not running on this computer, so there is no process to read an account from.'
const NO_AGENT =
  'No agent is running in this session, so there is no login to name. Start one and this will say which account it is on.'
const UNREADABLE =
  'This session was started outside the app and its account could not be read, so no account is named rather than this computer’s default being shown.'
const FOREIGN_HOME =
  'The agent in this session is running under a different home directory, so its login is one this app has no record of.'
/**
 * The Windows last resort, reworded when the hook rung was added. It used to
 * declare the whole question unanswerable — "Windows does not let one process
 * read another's environment" — which was true of the `ps` rung and false of
 * the app: an agent's own hooks answer it from inside the process. So the
 * sentence now says what is actually missing (no report yet) and what a person
 * can do about it (install the hooks; the agent reports from its next event).
 */
const WINDOWS =
  'No agent in this session has reported its login yet. Windows does not let this app read another process’s environment, so an agent started at this prompt names its own account through its hooks — from its next turn, once hooks are installed in Setup.'

/* ----------------------------------------------------------- process table -- */

/** One row of `ps -Ao pid=,ppid=,command=`. */
export interface ProcessRow {
  pid: number
  ppid: number
  command: string
}

/**
 * Parse the whole process table.
 *
 * Whole, and once, rather than a `ps` per generation: a session's agent can be
 * two or three levels down and the table is a single bounded read either way.
 * The same shape `remote/credentials.ts` parses, kept separate because that one
 * walks *up* from a known pid and this walks *down* from one.
 */
export function parseProcessTable(stdout: string): ProcessRow[] {
  const rows: ProcessRow[] = []
  for (const line of stdout.split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
    if (!match) continue
    rows.push({ pid: Number(match[1]), ppid: Number(match[2]), command: match[3] })
  }
  return rows
}

/**
 * The first descendant of `root` running one of `binaries`, breadth-first.
 *
 * Breadth-first because the shallowest match is the one the person started: a
 * `claude` that has itself spawned a `claude` — a subagent, a hook, `--print` —
 * is a child of the session's agent and inherits its environment anyway, so
 * either would answer the same, and preferring the shallower one keeps the
 * answer stable while children come and go.
 *
 * The command is matched on the basename of its first word. An absolute path, a
 * bare name and a shim on the PATH all arrive here spelled differently and all
 * of them are the same agent.
 */
export function agentUnder(
  rows: readonly ProcessRow[],
  root: number,
  binaries: readonly string[],
): ProcessRow | null {
  const wanted = new Set(binaries)
  const children = new Map<number, ProcessRow[]>()
  for (const row of rows) {
    const list = children.get(row.ppid)
    if (list) list.push(row)
    else children.set(row.ppid, [row])
  }
  const queue = [...(children.get(root) ?? [])]
  const seen = new Set<number>([root])
  while (queue.length > 0) {
    const row = queue.shift()
    if (!row || seen.has(row.pid)) continue
    seen.add(row.pid)
    const first = row.command.trim().split(/\s+/)[0] ?? ''
    if (wanted.has(basename(first))) return row
    queue.push(...(children.get(row.pid) ?? []))
  }
  return null
}

/* ------------------------------------------------------------- environment -- */

/**
 * One variable's value out of `ps eww` output, or null when it is not there.
 *
 * `ps eww` prints the command line and then the environment, all separated by
 * single spaces, with no delimiter between the two halves and no quoting — so a
 * value ends where the next `NAME=` begins, and that is exactly what this looks
 * for. The **last** occurrence is taken: an argument on the command line can
 * spell `FOO=bar` too, and the environment is printed after the arguments.
 */
export function environmentValue(psOutput: string, name: string): string | null {
  const marker = new RegExp(`(?:^|\\s)${name}=`, 'g')
  let start = -1
  for (let hit = marker.exec(psOutput); hit !== null; hit = marker.exec(psOutput)) {
    start = hit.index + hit[0].length
  }
  if (start < 0) return null
  const rest = psOutput.slice(start)
  const boundary = rest.search(/\s[A-Za-z_][A-Za-z0-9_]*=/)
  const value = (boundary === -1 ? rest : rest.slice(0, boundary)).trim()
  return value.length > 0 ? value : null
}

/**
 * Did `ps eww` actually print an environment, or only a command line?
 *
 * The distinction is load-bearing and is the one thing a naive reader of this
 * would get wrong. macOS scrubs the environment of SIP-protected binaries, so
 * `ps eww` against `/bin/sleep` succeeds, exits zero and prints no variables at
 * all — and a caller treating "no `CLAUDE_CONFIG_DIR` in the output" as "the
 * variable is unset" would then confidently report the default account for a
 * process whose environment it never saw. `PATH` is the probe because every
 * process that can find an agent binary has one.
 */
export function environmentWasRead(psOutput: string): boolean {
  return environmentValue(psOutput, 'PATH') !== null
}

/* -------------------------------------------------------------------- deps -- */

export interface SessionAccountDeps {
  /** The pty's own pid, or null when this app is not running that session. */
  pidOf(sessionId: string): number | null
  describeSession(sessionId: string): SessionMeta | null
  platform?: Platform
  /**
   * This account's home directory, for the foreign-home comparison against a
   * hook report. Defaults to `homedir()`; a parameter so a test can hold both
   * sides of the comparison rather than depending on the runner's account.
   */
  home?: string
  /** Injected for tests. Resolves with stdout; rejects the way `execFile` does. */
  exec?(command: string, args: readonly string[]): Promise<string>
}

/**
 * The one registration, module-level for the reason `remote/hidden-sessions.ts`
 * gives about its own: a rule a shell has to remember to install is a rule the
 * other shell forgets. Both `accountFor` in `usage-ipc.ts` and the IPC below ask
 * this module, and neither should have to be handed a `pidOf` to do it.
 */
let deps: SessionAccountDeps | null = null

/** The live hook subscription, so a reconfigure never stacks a second one. */
let unhook: (() => void) | null = null

export function configureSessionAccounts(next: SessionAccountDeps | null): void {
  deps = next
  answers.clear()
  inFlight.clear()
  hookReports.clear()
  unhook?.()
  // Subscribed here rather than wired in `index.ts`, for the same reason the
  // registration is module-level: a subscription a shell has to remember to
  // install is one the other shell forgets. The listener set in
  // `hook-server.ts` survives the server not being up yet, so order with
  // `startHookServer` does not matter.
  unhook = next === null ? null : onHookEvent(noteHookEvent)
}

async function shell(command: string, args: readonly string[]): Promise<string> {
  if (deps?.exec) return deps.exec(command, args)
  const { stdout } = await run(command, [...args], { timeout: 4000, maxBuffer: 8 * 1024 * 1024 })
  return stdout
}

/* ------------------------------------------------------------------- cache -- */

interface CacheEntry {
  answer: SessionAccountAnswer
  /** The pty pid the answer was established against, so a restart invalidates. */
  pid: number | null
  expiresAt: number
}

const answers = new Map<string, CacheEntry>()
const inFlight = new Map<string, Promise<SessionAccountAnswer>>()

/**
 * How long a probed answer stands.
 *
 * A spawn answer never expires — it is this app's own record of what it did. A
 * probed one does, because an agent can be started and stopped inside a shell
 * session at any moment, and an account name that outlives the process it
 * describes is the same class of wrong claim this module exists to end. Fifteen
 * seconds is two `ps` calls a minute for a session somebody is actually looking
 * at, which is nothing beside the ~245 ms `claude auth status` this path
 * deliberately never runs.
 */
const PROBE_TTL_MS = 15_000

/** Forget one session, or all of them. Called when a pty goes. */
export function dropSessionAccount(sessionId?: string): void {
  if (sessionId === undefined) {
    answers.clear()
    inFlight.clear()
    hookReports.clear()
    return
  }
  answers.delete(sessionId)
  inFlight.delete(sessionId)
  hookReports.delete(sessionId)
}

/* ------------------------------------------------------------ hook reports -- */

/** One session's latest report from inside its agent, and who sent it. */
interface HeldReport {
  provider: ProviderId
  /** The variable that decides this agent's store, from the catalog. */
  configEnv: string
  report: AgentEnvReport
  receivedAt: number
}

/**
 * The latest report per session. One entry, not a history: every hook event
 * carries the same environment for the life of the agent process, and the one
 * that matters is the one describing the agent that is running now.
 *
 * Dropped in three places, each of which is an "the agent this describes is
 * gone": the provider's `SessionEnd` event, `dropSessionAccount` when the pty
 * exits, and `configureSessionAccounts` when the wiring itself is replaced.
 * What that leaves uncovered is stated in {@link noteHookEvent}.
 */
const hookReports = new Map<string, HeldReport>()

/** The catalog entry for a hook's provider segment, when it can hold a login. */
function agentSpec(provider: string): { provider: ProviderId; configEnv: string } | null {
  for (const entry of Object.values(AGENT_CATALOG)) {
    if (entry.id === provider && entry.configEnv !== null) {
      return { provider: entry.id, configEnv: entry.configEnv }
    }
  }
  return null
}

/**
 * Fold one hook event into the report store.
 *
 * Exported for tests; wired through `onHookEvent` in
 * {@link configureSessionAccounts} for the app.
 *
 * `SessionEnd` is the drop: an account name that outlives the process it
 * describes is the class of claim this module exists to end, and both CLIs
 * that report environments here (Claude, Gemini — Codex has no `SessionEnd`
 * hook installed) fire it on exit. What this does not cover is an agent killed
 * too hard to run its own hooks — that report stands until the pty dies. On
 * POSIX the `ps` rung never reaches this store, so the staleness window exists
 * only where the alternative was no answer at all.
 *
 * A cached *probed* answer is invalidated when the evidence changes, so the
 * next read re-climbs the ladder; a spawn answer is this app's own record and
 * outranks anything a hook says, so it is never touched.
 */
export function noteHookEvent(event: HookEvent): void {
  const sessionId = event.sessionId
  if (sessionId === null) return
  if (event.event === 'SessionEnd') {
    if (hookReports.delete(sessionId)) dropProbedAnswer(sessionId)
    return
  }
  if (event.agentEnv === null) return
  const spec = agentSpec(event.provider)
  if (spec === null) return
  const held = hookReports.get(sessionId)
  hookReports.set(sessionId, {
    provider: spec.provider,
    configEnv: spec.configEnv,
    report: event.agentEnv,
    receivedAt: event.receivedAt,
  })
  const changed =
    held === undefined ||
    held.provider !== spec.provider ||
    held.report.envRead !== event.agentEnv.envRead ||
    held.report.home !== event.agentEnv.home ||
    (held.report.vars[held.configEnv] ?? null) !== (event.agentEnv.vars[spec.configEnv] ?? null)
  if (changed) dropProbedAnswer(sessionId)
}

/**
 * Drop a cached answer that new evidence has overtaken — unless it is a spawn
 * answer, which is this app's own record and no hook's to move.
 *
 * The in-flight probe is detached too: a probe that started before the report
 * arrived would otherwise cache the pre-report answer *after* it, and a
 * withheld reading would sit on screen for a TTL it no longer deserves.
 */
function dropProbedAnswer(sessionId: string): void {
  const cached = answers.get(sessionId)
  if (cached && cached.answer.kind === 'known' && cached.answer.source === 'spawn') return
  answers.delete(sessionId)
  inFlight.delete(sessionId)
}

/* ------------------------------------------------------------------ ladder -- */

/** Every agent binary whose login this app can tell apart, and its variable. */
function accountableAgents(): { bin: string; provider: ProviderId; configEnv: string }[] {
  const out: { bin: string; provider: ProviderId; configEnv: string }[] = []
  for (const entry of Object.values(AGENT_CATALOG)) {
    if (entry.bin === null || entry.configEnv === null) continue
    out.push({ bin: entry.bin, provider: entry.id, configEnv: entry.configEnv })
  }
  return out
}

/** The profile record for a directory, when this app has one. */
function profileForDir(provider: ProviderId, configDir: string): { id: string; name: string } | null {
  const state = getState()
  const system = systemProfileFor(provider, state)
  if (resolve(system.configDir) === resolve(configDir)) return { id: system.id, name: system.name }
  for (const profile of state.profiles) {
    if (profile.provider !== provider) continue
    if (resolve(profile.configDir) === resolve(configDir)) {
      return { id: profile.id, name: profile.name }
    }
  }
  return null
}

/** The spawn rung: what this app itself handed the process. Null when it did not. */
function fromSpawn(session: SessionMeta): KnownSessionAccount | null {
  if (typeof session.profileId !== 'string') return null
  if (!supportsProfiles(session.provider)) return null
  const profile = findProfile(getState(), session.profileId)
  if (!profile || profile.provider !== session.provider) return null
  return {
    kind: 'known',
    provider: session.provider,
    configDir: profile.configDir,
    profileId: profile.id,
    profileName: profile.name,
    source: 'spawn',
  }
}

/** Two spellings of one directory? Windows compares case-folded, POSIX exact. */
function sameDir(a: string, b: string, platform: Platform): boolean {
  if (isWindows(platform)) return win32.resolve(a).toLowerCase() === win32.resolve(b).toLowerCase()
  return resolve(a) === resolve(b)
}

/**
 * The hook rung: what the agent's own hook read out of its own environment.
 *
 * The same three-way reading as the `ps` rung below, because it is the same
 * evidence gathered by a witness that is *closer* — the hook process inherits
 * the agent's environment rather than parsing it out of a process dump:
 *
 *  - the variable is set → that directory, looked up like any other;
 *  - absent, in an environment that provably arrived (`envRead`) but under a
 *    different home → withheld, a login this app has no record of;
 *  - absent, same home → the agent's own default store, asked with `{}` for
 *    the reason the process rung documents at length.
 *
 * Null when there is nothing here to answer with — no report, a report whose
 * environment never provably arrived — and the ladder continues. Only the
 * Windows client sends reports today; on POSIX this rung is always empty and
 * the `ps` probe below answers as it always has.
 */
function fromHookReport(sessionId: string, wiring: SessionAccountDeps): SessionAccountAnswer | null {
  const held = hookReports.get(sessionId)
  if (held === undefined) return null

  const declared = held.report.vars[held.configEnv] ?? null
  if (declared !== null) {
    const found = profileForDir(held.provider, declared)
    return {
      kind: 'known',
      provider: held.provider,
      configDir: declared,
      profileId: found?.id ?? null,
      profileName: found?.name ?? null,
      source: 'hook',
    }
  }

  // An absence is believed only when the environment provably arrived — the
  // same rule `environmentWasRead` applies to a SIP-scrubbed `ps` dump.
  if (!held.report.envRead) return null

  const platform = wiring.platform ?? currentPlatform()
  const home = held.report.home
  if (home !== null && !sameDir(home, wiring.home ?? homedir(), platform)) {
    return { kind: 'withheld', reason: FOREIGN_HOME }
  }

  // The agent's own default store, asked with an empty environment — see the
  // process rung below for why `{}` and not this app's inherited one.
  const configDir = systemConfigDir(held.provider, {})
  const found = profileForDir(held.provider, configDir)
  return {
    kind: 'known',
    provider: held.provider,
    configDir,
    profileId: found?.id ?? null,
    profileName: found?.name ?? null,
    source: 'hook',
  }
}

/** The process rung: what the running agent's own environment says. */
async function fromProcess(pid: number): Promise<SessionAccountAnswer> {
  const agents = accountableAgents()
  let table: readonly ProcessRow[]
  try {
    table = parseProcessTable(await shell('ps', ['-Ao', 'pid=,ppid=,command=']))
  } catch {
    return { kind: 'withheld', reason: UNREADABLE }
  }
  const agent = agentUnder(table, pid, agents.map((entry) => entry.bin))
  if (agent === null) return { kind: 'withheld', reason: NO_AGENT }

  const first = basename(agent.command.trim().split(/\s+/)[0] ?? '')
  const spec = agents.find((entry) => entry.bin === first)
  if (!spec) return { kind: 'withheld', reason: NO_AGENT }

  let dump: string
  try {
    dump = await shell('ps', ['eww', '-p', String(agent.pid)])
  } catch {
    return { kind: 'withheld', reason: UNREADABLE }
  }
  // The environment has to have actually arrived before its *absences* mean
  // anything — see `environmentWasRead`, which is the SIP case.
  if (!environmentWasRead(dump)) return { kind: 'withheld', reason: UNREADABLE }

  const declared = environmentValue(dump, spec.configEnv)
  if (declared !== null) {
    const found = profileForDir(spec.provider, declared)
    return {
      kind: 'known',
      provider: spec.provider,
      configDir: declared,
      profileId: found?.id ?? null,
      profileName: found?.name ?? null,
      source: 'process',
    }
  }

  /*
   * No variable, in an environment that was genuinely read: the agent is on its
   * own default store. That is only this machine's default store if it is under
   * the same home — `profiles.ts` documents at length that a default install
   * keeps its config at `~/.claude.json`, one level above the directory — so a
   * different `HOME` is a different store and gets no name.
   */
  const home = environmentValue(dump, 'HOME')
  if (home !== null && resolve(home) !== resolve(homedir())) {
    return { kind: 'withheld', reason: FOREIGN_HOME }
  }
  /*
   * The agent's *default* store, asked with an empty environment.
   *
   * This used to read `systemProfileFor(provider).configDir`, which resolves
   * through this app process's own environment — and that is a different
   * question. If Deck was launched from a terminal inside a session on another
   * profile it carries that profile's `CLAUDE_CONFIG_DIR`, so "the machine's
   * own install" answered the redirected directory; meanwhile the branch that
   * reaches this line has just *read this agent's environment* and found no
   * such variable in it, which means this agent is on `$HOME/.claude` and on
   * nothing else. The two disagreed, and the app printed the one it had not
   * looked at. Asking with `{}` is asking the question this branch is actually
   * in: where does this agent keep its login when nothing redirects it.
   *
   * The profile record is then looked up by that directory like any other, so a
   * machine where nothing was inherited answers exactly as it did — the system
   * profile, by name — and a machine where something was inherited names the
   * store rather than a profile that is not this session's.
   */
  const configDir = systemConfigDir(spec.provider, {})
  const found = profileForDir(spec.provider, configDir)
  return {
    kind: 'known',
    provider: spec.provider,
    configDir,
    profileId: found?.id ?? null,
    profileName: found?.name ?? null,
    source: 'process',
  }
}

/**
 * The answer for one session, probing at most once at a time.
 *
 * Deduped on the id rather than debounced on a timer: two windows and the usage
 * registry all ask about the session on screen, and three `ps` runs for one
 * question is three times the cost of the only one that was needed.
 */
export function sessionAccount(sessionId: string): Promise<SessionAccountAnswer> {
  const wiring = deps
  if (wiring === null) return Promise.resolve({ kind: 'withheld', reason: NO_SESSION })

  const pid = wiring.pidOf(sessionId)
  const cached = answers.get(sessionId)
  if (cached && cached.pid === pid && cached.expiresAt > Date.now()) {
    return Promise.resolve(cached.answer)
  }
  const running = inFlight.get(sessionId)
  if (running) return running

  const work = establish(sessionId, wiring, pid)
    .then((answer) => {
      // Only while this is still the registered probe: a hook report that
      // arrived mid-flight detached it (`dropProbedAnswer`), and caching then
      // would stamp a pre-report answer with a post-report TTL.
      if (inFlight.get(sessionId) === work) {
        answers.set(sessionId, {
          answer,
          pid,
          // A spawn answer is this app's own record and does not go stale.
          expiresAt:
            answer.kind === 'known' && answer.source === 'spawn'
              ? Number.POSITIVE_INFINITY
              : Date.now() + PROBE_TTL_MS,
        })
      }
      return answer
    })
    .finally(() => {
      // Conditional for the same reason: an unconditional delete here would
      // remove whichever *newer* probe replaced this one.
      if (inFlight.get(sessionId) === work) inFlight.delete(sessionId)
    })
  inFlight.set(sessionId, work)
  return work
}

async function establish(
  sessionId: string,
  wiring: SessionAccountDeps,
  pid: number | null,
): Promise<SessionAccountAnswer> {
  const session = wiring.describeSession(sessionId)
  if (session === null) return { kind: 'withheld', reason: NO_SESSION }

  const spawned = fromSpawn(session)
  if (spawned !== null) return spawned

  // The agent's own report outranks a probe — it is the same environment, read
  // from inside rather than parsed out of `ps` — and it is the only rung that
  // can answer for a typed-in agent on Windows.
  const reported = fromHookReport(sessionId, wiring)
  if (reported !== null) return reported

  if (isWindows(wiring.platform ?? currentPlatform())) {
    // Not "unanswerable" any more — the sentence says what is missing and what
    // installs the channel that answers it. See {@link WINDOWS}.
    return { kind: 'withheld', reason: WINDOWS }
  }
  if (pid === null) return { kind: 'withheld', reason: NO_SESSION }
  return fromProcess(pid)
}

/**
 * Whatever has already been established, without starting anything.
 *
 * For the synchronous callers — `accountFor` in `usage-ipc.ts` is one, and it
 * runs inside a push loop. A miss is answered `null`, which those callers turn
 * into a withheld reading rather than into somebody else's account, and one
 * probe is kicked off so the *next* push has the answer. That is the whole of
 * why the miss is not an error: it is a not-yet, and it resolves itself.
 */
export function establishedAccount(sessionId: string): KnownSessionAccount | null {
  const pid = deps?.pidOf(sessionId) ?? null
  const cached = answers.get(sessionId)
  if (cached && cached.pid === pid && cached.expiresAt > Date.now()) {
    return cached.answer.kind === 'known' ? cached.answer : null
  }
  void sessionAccount(sessionId).catch(() => undefined)
  return null
}

/**
 * The configuration directory one session's agent is reading, when that has been
 * established and it belongs to the agent being asked about.
 *
 * The synchronous seam for the surfaces that read *files* rather than name an
 * account: `agent-controls.ts` resolves `settings.json`,
 * `permissions.defaultMode` and this project's transcripts through it, having
 * previously read all three out of `claudeConfigDir()` — this app process's own
 * store — for every session whichever account it was running as. That is the
 * same class of wrong claim {@link sessionAccount} exists to end, one control
 * cluster along: a person on two logins saw the model, effort, fast mode and
 * permission mode of the one they were not using.
 *
 * `provider` is checked rather than assumed, and it is the whole reason this is
 * a function instead of `establishedAccount(id)?.configDir` written out at each
 * call site. A directory is an answer about *one* agent — `~/.codex` holds no
 * `settings.json` Claude has ever read — so a caller that wants Claude's store
 * gets null for a session running Codex, and falls back rather than reading a
 * file that means nothing to it.
 *
 * Null is the honest answer twice over: nothing established yet (the probe is
 * running, and the *next* read will have it), and this session running an agent
 * other than the one asked about. Both leave the caller on the fallback it had
 * before this existed, which is the rule that keeps an unknown account from
 * becoming a wrong one.
 */
export function establishedConfigDir(sessionId: string, provider: ProviderId = 'claude'): string | null {
  const account = establishedAccount(sessionId)
  return account !== null && account.provider === provider ? account.configDir : null
}

/* ------------------------------------------------------------------- email -- */

const emails = new Map<string, string | null>()

/**
 * The address signed into a configuration directory, read off the file the CLI
 * itself wrote, and remembered for the life of the process.
 *
 * `claude auth status --json` answers the same question and costs ~245 ms of
 * process start, so it is not on this path; `.claude.json` is a file read and
 * carries `oauthAccount.emailAddress`, verified on this machine. The file lives
 * *inside* a redirected directory and one level *above* the default one — the
 * asymmetry `profiles.ts` documents — so both are tried.
 *
 * Whitespace is not assumed away anywhere near this: an earlier lane found that
 * `claude auth status --json` prints pretty, not compact, so a substring match
 * on `"loggedIn":true` finds nothing. This parses rather than matching, which
 * has the same problem and does not care.
 */
export async function accountEmail(configDir: string): Promise<string | null> {
  const key = resolve(configDir)
  const remembered = emails.get(key)
  if (remembered !== undefined) return remembered

  const candidates =
    resolve(configDir) === resolve(join(homedir(), '.claude'))
      ? [join(homedir(), '.claude.json'), join(configDir, '.claude.json')]
      : [join(configDir, '.claude.json'), join(homedir(), '.claude.json')]

  let found: string | null = null
  for (const path of candidates) {
    try {
      const parsed: unknown = JSON.parse(await readFile(path, 'utf8'))
      const account =
        typeof parsed === 'object' && parsed !== null
          ? (parsed as { oauthAccount?: unknown }).oauthAccount
          : null
      const email =
        typeof account === 'object' && account !== null
          ? (account as { emailAddress?: unknown }).emailAddress
          : null
      if (typeof email === 'string' && email.trim() !== '') {
        found = email.trim()
        break
      }
    } catch {
      /* absent, unreadable or half-written — all of them are "nothing known" */
    }
  }
  emails.set(key, found)
  return found
}

/** Drops the memo. Exported for tests, which write a `.claude.json` per case. */
export function forgetAccountEmails(): void {
  emails.clear()
}

/* --------------------------------------------------------------------- ipc -- */

export const SESSION_ACCOUNT_CHANNEL = 'session:account'

/**
 * What the renderer is told. The same two shapes, plus the address, because the
 * chip's whole job is naming the account and an id is not a name.
 */
export type SessionAccountView =
  | (Omit<KnownSessionAccount, 'kind'> & { kind: 'known'; email: string | null })
  | WithheldSessionAccount

export async function readSessionAccount(sessionId: string): Promise<SessionAccountView> {
  const answer = await sessionAccount(sessionId)
  if (answer.kind === 'withheld') return answer
  return { ...answer, email: await accountEmail(answer.configDir) }
}

export function registerSessionAccountIpc(ipcMain: IpcMain, wiring: SessionAccountDeps): void {
  configureSessionAccounts(wiring)
  ipcMain.handle(SESSION_ACCOUNT_CHANNEL, async (_e: IpcMainInvokeEvent, id: unknown) => {
    if (typeof id !== 'string' || id.trim() === '') {
      return { kind: 'withheld', reason: NO_SESSION } satisfies SessionAccountView
    }
    return readSessionAccount(id)
  })
}
