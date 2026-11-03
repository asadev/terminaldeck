/**
 * Whether an agent's binary will actually *run*, asked before anything spawns it.
 *
 * ## The failure this exists to end
 *
 * Recorded, frame by frame, on 2026-08-16. Pressing Sign in beside a Codex
 * account opened a blank session, and the terminal printed this and died:
 *
 *     Error: spawn /opt/homebrew/lib/node_modules/@openai/codex/node_modules/
 *       @openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex ENOENT
 *       errno: -2, code: 'ENOENT', syscall: 'spawn …/codex'
 *     [process exited]
 *
 * Twice, identically, leaving five orphan sessions in the sidebar. His words:
 * *"I cannot log in also the codecs… it's very inconvenient and not
 * understandable for me as not a technical actual coder."*
 *
 * Every check in this app answered the wrong question. `which codex` resolves —
 * the npm package installs a JavaScript launcher and that launcher is on PATH —
 * so `detectProviders` said installed, `checkPrerequisites` said Ready, the
 * picker offered it, and the sign-in probe ran it and pasted its stack trace
 * into the account row. What none of them asked is whether the thing on PATH can
 * be executed at all. Here it cannot: the launcher spawns a vendored native
 * binary that the package did not ship on this machine.
 *
 * So the question this module answers is **"does it run?"**, and the cheapest
 * honest way to answer it is to run it: `<binary> --version`, stdin closed, hard
 * timeout, and the answer cached for a few seconds so the account menu opening
 * three times does not spawn nine processes.
 *
 * ## Why an alternate path is tried, and why that is not a workaround
 *
 * A complete, working copy of the same CLI is installed on this machine inside
 * Codex's own plugin directory and answers `codex-cli 0.146.0-alpha.3.1` to
 * every question the broken launcher throws on. Preferring it is not papering
 * over a broken install: it is the difference between "Codex cannot be used
 * here" and "Codex works", for a user who has Codex installed and signed in.
 * The candidate list is declared per agent in `shared/agent-catalog.ts`, never
 * hardcoded here, and every candidate is *probed* before it is used — so a path
 * that stops existing degrades to the ordinary "not runnable" answer instead of
 * becoming a second ENOENT.
 *
 * ## Nothing here ever guesses
 *
 * Three outcomes, and the middle one is the one the product was missing:
 *
 *  - **runnable** — a path was executed and printed something. `version` holds
 *    the first line.
 *  - **broken** — the name resolves on PATH, nothing runnable was found, and
 *    `said` is the first line of what the failed launch actually wrote. That
 *    sentence goes on screen next to the install command, and no PTY is opened.
 *  - **missing** — the name does not resolve at all.
 *
 * A probe that times out is reported as *not* runnable rather than as runnable,
 * which is the conservative direction: refusing to open a session is recoverable,
 * opening one that dies is the bug.
 */

import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { ProviderId } from '../shared/types'
import { AGENT_CATALOG, LOOKUP_AGENTS, type AgentEntry } from '../shared/agent-catalog'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { killTree, systemRootOf } from './kill-tree'
import { firstLookupPath, lookupSpec } from './platform/lookup'
import { launchSpec } from './tool-probe'

const run = promisify(execFile)

/* ------------------------------------------------------------------ model -- */

export interface AgentBinary {
  id: ProviderId
  /** The name looked up on PATH, or null for the shell. */
  bin: string | null
  /** Where the PATH lookup landed, runnable or not. */
  onPath: string | null
  /**
   * A path that was executed successfully, or null.
   *
   * This — not `onPath` — is what a spawn should use. They differ exactly in the
   * case this module was written for.
   */
  runnable: string | null
  /** The first line the runnable copy printed for its version args. */
  version: string | null
  /** On PATH, and nothing runnable. The stack-trace case. */
  broken: boolean
  /** The first line of what the broken launch said. Never invented. */
  said: string | null
  /** True when the runnable copy is not the one on PATH. */
  usedAlternate: boolean
  checkedAt: number
}

/** Long enough for a cold CLI start, short enough that a menu still paints. */
export const BINARY_PROBE_TIMEOUT_MS = 6000

/**
 * How long an answer is reused.
 *
 * Every New Session dialog, every account menu and every Setup visit asks this
 * about every agent. A binary does not become runnable while a menu is open; a
 * person who has just installed one presses Check again, which passes
 * `refresh`.
 */
export const BINARY_CACHE_MS = 20_000

/** What `execFile` hangs off its error. */
interface ExecFailure {
  code?: number | string
  killed?: boolean
  signal?: string | null
  stdout?: string
  stderr?: string
}

/**
 * The same guard `tool-probe.ts` keeps, for the same reason: on Windows a probe
 * can reach the command processor, so nothing may be run that did not come out
 * of a table in this repository.
 */
const SAFE_BIN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

/**
 * `~/…` means the user's home, and only at the front.
 *
 * Expanded here rather than in the catalogue because the catalogue is imported
 * by the renderer, which has no home directory to ask about and no business
 * knowing one.
 */
export function expandHome(path: string, home: string = homedir()): string {
  if (path === '~') return home
  if (path.startsWith('~/')) return join(home, path.slice(2))
  return path
}

/* ---------------------------------------------------------------- probing -- */

/**
 * Run something and say whether it ran.
 *
 * "Ran" is a stricter test than "exited zero", and the difference is the whole
 * point: the broken Codex launcher exits **1** after printing a Node stack
 * trace, and an agent that exits non-zero for `--version` while being perfectly
 * launchable is a thing that also exists. So a non-zero exit is only fatal when
 * the output looks like a spawn failure rather than like a version — which is
 * checked by asking whether anything at all was printed that is not a Node
 * error report.
 */
export interface RunProbe {
  ok: boolean
  /** The first meaningful line of output, whichever stream it came from. */
  line: string | null
}

/**
 * Does this output look like Node failing to start a child process?
 *
 * Matched on the shape rather than on the exact path, because the path is
 * different on every machine. Both markers have to be present: `spawn` on its
 * own appears in ordinary help text, and `ENOENT` on its own is what a CLI
 * prints when *its* argument names a file that is not there — which is a
 * working CLI answering a question, not a CLI that failed to start.
 */
export function looksLikeSpawnFailure(output: string): boolean {
  return /\bENOENT\b/.test(output) && /\bspawn\b/i.test(output)
}

/** First line worth showing a person: no blanks, no stack frames. */
export function firstMeaningfulLine(output: string): string | null {
  for (const raw of output.split('\n')) {
    const line = raw.trim()
    if (line === '') continue
    // `at Foo (…:1:2)` and the `{ errno: -2 …}` tail are the parts of a Node
    // error report that mean nothing to the person reading the screen.
    if (line.startsWith('at ')) continue
    return line.slice(0, 200)
  }
  return null
}

/**
 * The default `probe`: run a candidate and say whether it ran.
 *
 * Exported only so `agent-binaries.test.ts` can drive the deadline directly.
 * Everything else in this module reaches it through the injected `probe` seam,
 * and should keep doing so — the seam is what lets a test model a machine, and
 * this function is what actually spawns.
 */
export async function tryRun(
  command: string,
  args: readonly string[],
  env: NodeJS.ProcessEnv,
  shell: boolean,
  platform: Platform,
  timeoutMs: number = BINARY_PROBE_TIMEOUT_MS,
): Promise<RunProbe> {
  /*
   * The deadline is ours, and `execFile`'s own `timeout:` is deliberately not
   * passed. This looks like extra work for the same behaviour; on Windows it is
   * the difference between a probe that cleans up and one that leaks.
   *
   * `timeout:` makes Node kill the process it spawned when the clock runs out.
   * On Windows, when `shell` is true — which is every npm-installed agent CLI,
   * because what is on PATH is a `.cmd` shim and Node has refused to spawn
   * those without a shell since CVE-2024-27980 — the process Node spawned is
   * `cmd.exe`. The `node …\claude --version` that is actually hung is its
   * grandchild, and `TerminateProcess` does not descend. So a hung probe left a
   * whole agent CLI behind on Windows and left nothing behind on macOS: the
   * Setup panel leaks one process per hung probe, and it probes every tool on
   * every open.
   *
   * There is no way to make Node's own timeout kill a tree, and there is no
   * ordering trick either: arming a second timer at the same deadline loses,
   * because Node created its timer first and same-expiry timers fire in
   * creation order — and `taskkill /T` must run *before* the shell dies or the
   * grandchild is already orphaned and no longer in anyone's tree
   * (`kill-tree.ts` argues this at length). So there is exactly one deadline
   * here and it is this one.
   *
   * What a caller observes is unchanged on every platform. When the tree is
   * killed the child exits non-zero, `execFile` rejects exactly as it did when
   * the timeout was Node's, and the `catch` below turns that into the same
   * `{ ok: false }` it always produced. `timeoutMs` is a parameter only so a
   * test can use a deadline shorter than the six seconds a cold CLI needs.
   */
  const pending = run(command, [...args], {
    env,
    encoding: 'utf8',
    shell,
    windowsHide: true,
    maxBuffer: 256 * 1024,
  })
  const deadline = setTimeout(() => {
    void killTree(pending.child, { platform, shell, systemRoot: systemRootOf(env) })
  }, timeoutMs)
  try {
    const { stdout, stderr } = await pending
    const output = `${stdout}\n${stderr}`
    // A zero exit that still printed a spawn failure is the launcher pattern
    // wearing a different exit code. Refuse it rather than trust the status.
    if (looksLikeSpawnFailure(output)) return { ok: false, line: firstMeaningfulLine(output) }
    return { ok: true, line: firstMeaningfulLine(output) }
  } catch (error) {
    const failure = error as ExecFailure
    const output = `${failure.stdout ?? ''}\n${failure.stderr ?? ''}`
    return { ok: false, line: firstMeaningfulLine(output) }
  } finally {
    clearTimeout(deadline)
  }
}

/**
 * The seam every test drives this through.
 *
 * Two injectables rather than one, because the two questions fail
 * independently: a machine can answer "where is it" and then fail to run what it
 * found, which is precisely the case being modelled.
 */
export interface ResolveOptions {
  platform?: Platform
  /** The PATH to look up and run under. Production passes the login PATH. */
  path?: string
  /** Bypass the cache. What "Check again" passes. */
  refresh?: boolean
  home?: string
  /** Where a name resolves on PATH, or null. */
  lookup?(bin: string): Promise<string | null>
  /** Whether an absolute path (or a bare name) can be executed. */
  probe?(command: string, args: readonly string[], shell: boolean): Promise<RunProbe>
  /** Whether a candidate path exists at all. Skips a spawn that cannot work. */
  exists?(path: string): boolean
}

/** Answers still worth reusing, keyed by agent and PATH. */
const cache = new Map<string, AgentBinary>()

/** Drop the memo. Exported for tests and for anything that installs a CLI. */
export function resetAgentBinaryCache(): void {
  cache.clear()
}

/**
 * The shell entry, which is never looked up.
 *
 * `providersFor` resolves `$SHELL` / `%COMSPEC%` itself and a machine without a
 * login shell is not a machine. Answering here keeps every caller able to ask
 * about any `ProviderId` without special-casing the one that is not an agent.
 */
function shellAnswer(id: ProviderId, now: number): AgentBinary {
  return {
    id,
    bin: null,
    onPath: null,
    runnable: null,
    version: null,
    broken: false,
    said: null,
    usedAlternate: false,
    checkedAt: now,
  }
}

async function defaultLookup(
  bin: string,
  platform: Platform,
  env: NodeJS.ProcessEnv,
): Promise<string | null> {
  const spec = lookupSpec(platform, bin)
  try {
    // `timeout:` is Node's own here, unlike `tryRun` above, and that is correct
    // rather than inconsistent: `lookupSpec` runs `where.exe` on Windows and
    // `command -v` through no shell elsewhere, so there is never a command
    // processor between this process and the one being timed. Node's kill
    // reaches the only child there is. The moment this grows a `shell: true`
    // it has to move to the owned-deadline shape `tryRun` uses.
    const { stdout } = await run(spec.command, spec.args, { env, windowsHide: true, timeout: 4000 })
    return firstLookupPath(stdout)
  } catch {
    // A non-zero exit *is* the "not installed" answer; a rejection here would
    // take the whole table down over the ordinary case.
    return null
  }
}

/**
 * Ask whether one agent's binary can be run, and which copy of it.
 *
 * Never rejects. Every failure is an `AgentBinary` saying what happened, because
 * a screen that shows nothing when a probe fails is a screen that looks broken
 * for a reason the user cannot see.
 */
export async function resolveAgentBinary(
  id: ProviderId,
  options: ResolveOptions = {},
): Promise<AgentBinary> {
  const entry: AgentEntry | undefined = AGENT_CATALOG[id]
  const now = Date.now()
  if (!entry || entry.bin === null) return shellAnswer(id, now)

  const platform = options.platform ?? currentPlatform()
  const PATH = options.path ?? ''
  const key = `${id}:${platform}:${PATH}`
  if (options.refresh !== true) {
    const cached = cache.get(key)
    if (cached && now - cached.checkedAt < BINARY_CACHE_MS) return cached
  }

  const env = withPath(process.env, PATH, platform)
  const exists = options.exists ?? existsSync
  const lookup = options.lookup ?? ((bin: string) => defaultLookup(bin, platform, env))
  const probe =
    options.probe ??
    ((command: string, args: readonly string[], shell: boolean) =>
      tryRun(command, args, env, shell, platform))

  const bin = entry.bin
  const onPath = SAFE_BIN.test(bin) ? await lookup(bin) : null

  // No version flag means no way to prove it runs, so the honest answer is the
  // one the lookup gave — reported as runnable, because refusing to offer an
  // agent on the strength of a question we cannot ask would be worse.
  if (entry.versionArgs === null) {
    const answer: AgentBinary = {
      id,
      bin,
      onPath,
      runnable: onPath,
      version: null,
      broken: false,
      said: null,
      usedAlternate: false,
      checkedAt: now,
    }
    cache.set(key, answer)
    return answer
  }

  let said: string | null = null

  if (onPath !== null) {
    const launch = launchSpec(bin, onPath, platform)
    const result = await probe(launch.command, entry.versionArgs, launch.shell)
    if (result.ok) {
      const answer: AgentBinary = {
        id,
        bin,
        onPath,
        // The bare name, not the resolved path: this is what a spawn should
        // use, and on Windows the resolved path is a `.cmd` shim that
        // `CreateProcess` will not run. `providers.ts` already wraps a bare
        // name in the command processor there.
        runnable: bin,
        version: result.line,
        broken: false,
        said: null,
        usedAlternate: false,
        checkedAt: now,
      }
      cache.set(key, answer)
      return answer
    }
    said = result.line
  }

  // The declared fallbacks, in order, and only ones that are actually there —
  // spawning a path that does not exist would produce a second ENOENT to
  // explain instead of the first.
  for (const candidate of entry.alternateBins) {
    const path = expandHome(candidate, options.home)
    if (!exists(path)) continue
    const result = await probe(path, entry.versionArgs, false)
    if (!result.ok) continue
    const answer: AgentBinary = {
      id,
      bin,
      onPath,
      runnable: path,
      version: result.line,
      // Not broken: this agent runs here. That the copy on PATH does not is a
      // fact about that copy, and `usedAlternate` is where it is recorded.
      broken: false,
      said,
      usedAlternate: true,
      checkedAt: now,
    }
    cache.set(key, answer)
    return answer
  }

  const answer: AgentBinary = {
    id,
    bin,
    onPath,
    runnable: null,
    version: null,
    // Broken means "you have it and it will not run", which is a different
    // sentence from "you do not have it" and sends a person somewhere else.
    broken: onPath !== null,
    said,
    usedAlternate: false,
    checkedAt: now,
  }
  cache.set(key, answer)
  return answer
}

/**
 * Every agent at once. One round of probes, in parallel.
 *
 * The list that is *probed* comes from the catalogue, so a new entry is checked
 * by existing. The object that is *returned* names its four keys, so a provider
 * added to the union fails to compile here rather than coming back undefined to
 * a caller that believed the record was total — the mistake `providers.ts`
 * records having made with `{} as Record<ProviderId, boolean>`.
 */
export async function resolveAgentBinaries(
  options: ResolveOptions = {},
): Promise<Record<ProviderId, AgentBinary>> {
  const resolved = new Map<ProviderId, AgentBinary>()
  await Promise.all(
    LOOKUP_AGENTS.map(async (entry) => {
      resolved.set(entry.id, await resolveAgentBinary(entry.id, options))
    }),
  )
  const now = Date.now()
  const answer = (id: ProviderId): AgentBinary => resolved.get(id) ?? shellAnswer(id, now)
  return {
    claude: answer('claude'),
    codex: answer('codex'),
    gemini: answer('gemini'),
    shell: answer('shell'),
  }
}

/* -------------------------------------------------------------- sentences -- */

/**
 * What to put on screen when an agent cannot be used, or null when it can.
 *
 * One sentence, in the user's terms, ending in something to type. This is the
 * string that replaced a Node stack trace, so it is deliberately written for
 * somebody who has never seen one: no `ENOENT`, no `errno`, no path unless the
 * path is the thing that is wrong.
 */
export function binaryProblem(binary: AgentBinary): string | null {
  if (binary.runnable !== null) return null
  const entry = AGENT_CATALOG[binary.id]
  const label = entry?.label ?? binary.id
  const install = entry?.install

  if (!binary.broken) {
    return install
      ? `${label} is not installed. Install it with \`${install}\`, then check again.`
      : `${label} is not installed on this machine.`
  }

  /*
   * Present and unrunnable.
   *
   * The file is named because the file is the fault and the person may well want
   * to delete it. What is deliberately *not* here is the launcher's own output:
   * `Error: spawn …/codex ENOENT` was the entire error message the app used to
   * show, and the report it came from is a person saying it was "not
   * understandable for me as not a technical actual coder". The literal text is
   * still kept — `binaryEvidence` returns it, and the Setup panel prints it in
   * the slot it already has for a probe — so nothing is hidden; it is simply not
   * the sentence.
   */
  const where = binary.onPath ? ` at ${binary.onPath}` : ''
  return install
    ? `${label} is installed${where} but will not start. Reinstalling usually fixes it: \`${install}\`.`
    : `${label} is installed${where} but will not start.`
}

/**
 * What the machine actually said, for the one place that shows literals.
 *
 * Setup already prints a probe line under a tool it could not find — the
 * reasoning is in `tool-probe.ts`: "Not found" invites an argument, the command
 * we ran and what the shell answered ends it. A binary that is present and
 * unrunnable deserves the same treatment, and this is that line.
 */
export function binaryEvidence(binary: AgentBinary): string | null {
  if (binary.runnable !== null || !binary.broken) return null
  return binary.said
}

/**
 * A note worth showing when everything works but not the obvious way.
 *
 * Only for the alternate-path case. Silence would be simpler and would also be
 * the thing that makes a person distrust the app later, when they run `codex` in
 * their own terminal, watch it fail, and find it working here.
 */
export function binaryNote(binary: AgentBinary): string | null {
  if (binary.runnable === null || !binary.usedAlternate) return null
  const entry = AGENT_CATALOG[binary.id]
  const label = entry?.label ?? binary.id
  const install = entry?.install
  const fix = install ? ` Reinstalling with \`${install}\` would fix the one on your PATH.` : ''
  return `The \`${entry?.bin ?? binary.id}\` on your PATH will not start, so ${label} runs from ${binary.runnable} instead.${fix}`
}

/** True when a session on this agent can actually be opened. */
export function canStart(binary: AgentBinary | undefined): boolean {
  if (!binary) return false
  // The shell has no binary to prove and is always available; it is how this
  // app spawns everything else.
  return binary.bin === null || binary.runnable !== null
}
