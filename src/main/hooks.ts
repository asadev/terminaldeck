/**
 * Provider hooks — installing our own callbacks into each agent CLI's real
 * settings file.
 *
 * Every hook entry we write ends with the shell comment `# terminaldeck-hook`, and that
 * marker is the *only* thing that makes an entry ours. Nothing is ever removed
 * because it looks like ours, sits where ours would sit, or points at our port:
 * a machine that also runs Vibeyard has 26 hooks in the same file tagged
 * `# vibeyard-hook`, and eating those would break a working install of somebody
 * else's product.
 *
 * The schemas here were read off this machine, not guessed:
 *
 *   claude  ~/.claude/settings.json   `hooks` -> event -> [{ matcher, hooks: [] }]
 *   codex   ~/.codex/hooks.json       same shape, and needs
 *                                     `[features] codex_hooks = true` in config.toml
 *   gemini  ~/.gemini/settings.json   same shape; entries also accept `name`,
 *                                     `description` and `env`
 *
 * Three details that only reading the real thing exposes:
 *
 *  - Claude's `timeout` is in SECONDS, Gemini's in MILLISECONDS. Same key name,
 *    1000x apart. A shared constant here would be a bug in one of them.
 *  - Gemini's `hooks` object legally holds `enabled`, `disabled` and
 *    `notifications` alongside the event arrays, so anything that walks the
 *    object as "event -> array" has to skip non-arrays rather than assume.
 *  - `~/.claude/settings.json` is mode 0600 while the other two are 0644.
 *    A naive rewrite widens the first one, so the mode is carried across.
 *
 * Writes are atomic (temp file, fsync, rename) and the file is copied to a
 * backup before the first time we ever touch it. Anything we cannot parse as
 * strict JSON is left alone entirely — a config we do not understand is a
 * config we must not rewrite.
 */

import { randomBytes } from 'node:crypto'
import {
  chmodSync,
  closeSync,
  copyFileSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, win32 } from 'node:path'
import type { SessionStatus } from '../shared/types'
import { BRAND } from '../shared/brand'
import { CONFIG_FILE, currentHookEndpoint, type HookEndpoint } from './hook-server'
import { currentPlatform, isWindows, type Env, type Platform } from './platform/host'

/* ------------------------------------------------------------------ types -- */

export type HookProviderId = 'claude' | 'codex' | 'gemini'

/**
 * `stale` means the hooks are installed and tagged as ours but aimed somewhere
 * other than this app's endpoint, so they fire into nothing.
 *
 * It used to be the *normal* state, on every launch, because the command
 * carried a port and a token that were minted fresh each run. It is now a rare
 * one, and the three things that can still cause it are all real: an install
 * written by an older version of this app, an install written by a different
 * copy of it (a packaged build and a dev build keep separate data directories),
 * or a hand-edited config. All three are a one-click fix, not an error.
 */
export type HookInstallState = 'none' | 'partial' | 'complete' | 'stale' | 'error'

export interface HookProviderStatus {
  id: HookProviderId
  label: string
  /** Absolute path of the settings file these hooks live in. */
  file: string
  /** The file exists on disk. Absence is normal — the CLI may not be set up. */
  fileExists: boolean
  state: HookInstallState
  /** Our events currently installed and pointing at the live endpoint. */
  installedEvents: string[]
  /** Our events that are installed but aimed at a dead endpoint. */
  staleEvents: string[]
  /** Events we would install that are not there. */
  missingEvents: string[]
  /** Hooks in this file belonging to somebody else, which we never touch. */
  foreignHooks: number
  /** Who they appear to belong to, from their own `# x-hook` markers. */
  foreignOwners: string[]
  /** Where the untouched original was copied before our first write. */
  backupPath: string | null
  /** Plain sentence for the panel — the reason for the state, not a restatement. */
  message: string
}

export interface HookWriteResult {
  ok: boolean
  message: string
  status: HookProviderStatus
}

/** Everything the pure functions need, so tests never touch a real home dir. */
export interface HookContext {
  /** Home directory the provider config lives under. */
  home: string
  /** Directory pristine copies are kept in. */
  backupDir: string
  /** Where hooks should call back to, or null when the server is not up. */
  endpoint: HookEndpoint | null
  /**
   * Which platform's command to write and to compare against. Defaults to this
   * machine's.
   *
   * A parameter for the reason `platform/host.ts` argues: CI here is macOS-only,
   * so the Windows form of the command would otherwise be a branch nothing in
   * this suite can reach — which is precisely how it came to say, in a comment,
   * that no Windows form existed.
   */
  platform?: Platform
  /** Read for `SystemRoot`. Defaults to `process.env`, injected for the same reason. */
  env?: Env
}

/* -------------------------------------------------------------- providers -- */

interface HookProviderSpec {
  id: HookProviderId
  label: string
  /** Settings file, relative to home. */
  path: string[]
  /** Events we install, in the order the panel lists them. */
  events: string[]
  /**
   * Unit of the per-entry `timeout` key, or null to omit it. Claude counts
   * seconds and Gemini milliseconds; Codex's schema could not be read on this
   * machine (its vendored binary is missing), so it gets no timeout at all
   * rather than a guessed one in the wrong unit.
   */
  timeout: { key: 'timeout'; value: number } | null
  /** Entries here accept a `name`, which makes ownership legible in the file. */
  supportsName: boolean
  /** Shown under the row when the CLI needs more than the file to honour hooks. */
  requirement: string | null
}

/**
 * Claude's full event list is 26 long; these ten are the lifecycle. Installing
 * all 26 means 26 curl spawns for events nothing consumes — the transitions
 * below are the ones that move a session's status.
 */
const CLAUDE_EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'PostToolUseFailure',
  'PermissionRequest',
  'Notification',
  'Stop',
  'StopFailure',
  'SessionEnd',
]

/**
 * Only the five that a real Codex install on this machine is already using.
 * Codex's own binary is not present here to check a longer list against, and an
 * invented event name in a config file is a silent no-op at best.
 */
const CODEX_EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']

/** Gemini names its lifecycle differently — Before/After rather than Pre/Post. */
const GEMINI_EVENTS = [
  'SessionStart',
  'BeforeAgent',
  'BeforeTool',
  'AfterTool',
  'AfterAgent',
  'Notification',
  'SessionEnd',
]

export const HOOK_PROVIDERS: Record<HookProviderId, HookProviderSpec> = {
  claude: {
    id: 'claude',
    label: 'Claude Code',
    path: ['.claude', 'settings.json'],
    events: CLAUDE_EVENTS,
    // Seconds. Long enough to survive a stalled loopback connect, short enough
    // that a wedged hook never becomes a wedged session.
    timeout: { key: 'timeout', value: 5 },
    supportsName: false,
    requirement: null,
  },
  codex: {
    id: 'codex',
    label: 'Codex CLI',
    path: ['.codex', 'hooks.json'],
    events: CODEX_EVENTS,
    timeout: null,
    supportsName: false,
    requirement: 'Codex only runs hooks with `codex_hooks = true` under [features] in ~/.codex/config.toml.',
  },
  gemini: {
    id: 'gemini',
    label: 'Gemini CLI',
    path: ['.gemini', 'settings.json'],
    events: GEMINI_EVENTS,
    // Milliseconds — same key, different unit from Claude's.
    timeout: { key: 'timeout', value: 5000 },
    supportsName: true,
    requirement: null,
  },
}

export const HOOK_PROVIDER_IDS = Object.keys(HOOK_PROVIDERS) as HookProviderId[]

/**
 * What each event means for a session's status, so the rest of the app can act
 * on a hook without re-deriving the vocabulary. Events absent from this map
 * carry information (tool names, failures) but do not move the status.
 */
export const EVENT_STATUS: Record<HookProviderId, Record<string, SessionStatus>> = {
  claude: {
    SessionStart: 'waiting',
    UserPromptSubmit: 'working',
    PreToolUse: 'working',
    PostToolUse: 'working',
    PostToolUseFailure: 'working',
    PermissionRequest: 'input',
    Notification: 'input',
    Stop: 'completed',
    // Not 'exited': the CLI is still running, it just gave up on this turn.
    StopFailure: 'waiting',
    SessionEnd: 'exited',
  },
  codex: {
    SessionStart: 'waiting',
    UserPromptSubmit: 'working',
    PreToolUse: 'working',
    PostToolUse: 'working',
    Stop: 'completed',
  },
  gemini: {
    SessionStart: 'waiting',
    BeforeAgent: 'working',
    BeforeTool: 'working',
    AfterTool: 'working',
    AfterAgent: 'completed',
    Notification: 'input',
    SessionEnd: 'exited',
  },
}

/* ----------------------------------------------------------------- marker -- */

/** The tag that makes an entry ours. Built from the brand, never spelled out. */
export const HOOK_MARKER = `# ${BRAND.id}-hook`

/**
 * The one header this module still writes into a command.
 *
 * The token header used to be here too. It is not any more, and it is not
 * declared here unused either: `hook-server.ts` owns it now, because it is the
 * module that writes the curl config the token lives in. A constant kept in two
 * files for a value only one of them uses is the shape of a fact that drifts.
 */
export const SESSION_HEADER = `x-${BRAND.id}-session`

/** Somebody else's marker, e.g. `# vibeyard-hook`, so we can name the owner. */
const FOREIGN_MARKER_RE = /#\s*([a-z][a-z0-9_-]*)-hook\b/i

/**
 * curl by absolute path. Hooks run through a login-ish shell whose PATH we do
 * not control, and `curl: command not found` at every tool call would be a
 * spectacular way to make sessions feel broken.
 */
const CURL = '/usr/bin/curl'

/**
 * Windows PowerShell by absolute path, for the same reason and one more.
 *
 * `PATH` on Windows routinely contains directories the user — or anything
 * running as the user — can write to, and this string is executed by their
 * shell on every tool call. Resolving it through `PATH` would let whatever put
 * a `powershell.exe` in a writable directory run once per hook.
 * `remote/secret-file.ts` addresses `icacls` the same way, for the same reason.
 *
 * `win32.join`, not the host's, so a Mac asking for the Windows answer gets the
 * Windows answer.
 */
export function powershellPath(env: Env): string {
  return win32.join(
    env.SystemRoot ?? 'C:\\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  )
}

/**
 * Single-quote a value for the shell that will run this command.
 *
 * Today every interpolated value is provably tame — the token is 48 hex
 * characters, the port is a number, the provider and event names come from the
 * table above. But this string is written into the user's config file and
 * executed by their shell on every tool call, so the cost of a future change
 * that loosens any of those is arbitrary code execution in their session, on
 * every session. Quoting now makes that failure impossible rather than
 * unlikely.
 */
function shellQuote(value: string): string {
  return `'${value.split("'").join(`'\\''`)}'`
}

/**
 * The command each hook runs.
 *
 * Reads the event JSON the CLI writes to stdin and POSTs it verbatim. It has to
 * consume stdin — a command that exits without reading leaves the CLI writing
 * into a closed pipe, which Claude reports as an EPIPE hook failure. It also
 * has to succeed unconditionally: `|| true` means a hook firing while the app
 * is closed is silence, not an error in the user's session.
 *
 * ## Every value in here is stable across runs, and that is the feature
 *
 * This command used to contain the endpoint's port and its token, both of which
 * are minted fresh on every launch. So every launch invalidated every installed
 * hook: the file still held a tagged, well-formed command aimed at a socket that
 * no longer existed. All three providers reported "Needs reinstalling" forever,
 * and a user who did not press it three times per launch got no lifecycle events
 * at all — no session-finished, and nothing built on it.
 *
 * Now there are exactly two interpolated values and neither ever changes:
 *
 *  - `--unix-socket` comes out of the config file, not out of here.
 *  - `-K <configPath>` names a file in the app's own data directory. The token
 *    is inside it, rewritten on every start, read by curl at call time. The
 *    hook command therefore holds no secret at all, which also takes a 48-hex
 *    credential back out of `~/.gemini/settings.json` (mode 0644).
 *
 * The consequence worth stating plainly: an install written today is still
 * correct after a restart, an upgrade, and a reboot. `readStatus` compares the
 * installed command against this one, so "stale" stops being the normal state
 * and starts meaning what it says.
 *
 * ## What happens when the app is not running
 *
 * The config file and the socket are both deleted on shutdown, so curl fails to
 * read its config and exits 26 without connecting to anything. `2>/dev/null`
 * keeps that off the agent's screen and `|| true` keeps it out of the session's
 * exit status, so a hook firing against a closed app is silence — which is the
 * same behaviour as before, arrived at more safely. The old form could still
 * *connect*: a recycled port number belonging to some other program would have
 * been handed the agent's tool input. A path this app owns cannot be reassigned
 * to a stranger by the kernel.
 *
 * Measured rather than assumed: with `-K` naming a file that does not exist,
 * curl still drains stdin before exiting, so the CLI writing the event never
 * sees EPIPE. That was checked against the real `/usr/bin/curl` on this machine
 * with a 200 KB payload, because it is exactly the kind of detail that is
 * obvious once it breaks somebody's session and invisible until then.
 *
 * ## Windows: the same sentence, a different program
 *
 * This used to say there was no Windows form, and that writing one meant
 * knowing which shell a provider CLI hands a hook command to there — which
 * nothing here had watched one do. It has now been watched. Claude Code 2.1.233
 * on Windows 11 runs a hook command through **`/usr/bin/bash`**: a settings
 * file carrying a `cmd.exe`-shaped command came back as
 * `/usr/bin/bash: line 1: C:WindowsSystem32...powershell.exe: command not
 * found`, which is a POSIX shell eating the backslashes as escapes. So the
 * shell is the same shell, and everything that was called out as POSIX-only —
 * `|| true`, `2>/dev/null`, single-quoted arguments, the trailing `#` comment —
 * is exactly right there too. Measured in Git Bash on that machine: a
 * single-quoted `'C:\…\powershell.exe'` runs, `-File 'C:\…\hook-post.ps1'`
 * runs, and stdin arrives intact.
 *
 * What changes is the *program*, because `curl` cannot reach the endpoint on
 * Windows however it is spelled — {@link hookClientPath} has the measurement.
 * So Windows runs the client script the endpoint writes beside its config,
 * and the command is the same three stable things: an absolute program, the
 * config path, and no secret.
 *
 * Two smaller differences fall out of it:
 *
 *  - **No `$VAR` for the session id.** The client is ours, so it reads the
 *    environment variable itself. One less thing for a shell to expand.
 *  - **No `-o /dev/null` or timeouts.** The client answers for its own
 *    behaviour: it drops the response, gives the pipe one second to connect,
 *    and exits 0 whatever happens.
 *
 * The one thing this does *not* claim is Codex and Gemini on Windows. Neither
 * is installed on the Windows machine available here, so which shell they use
 * is unmeasured; what they get is the shell Claude was measured using, which is
 * a far better guess than the POSIX command that could not run at all.
 *
 * ## The one place the response is now allowed back in, and what it costs
 *
 * Everything above is written from the position that this command throws the
 * response away — `-o /dev/null` — because the endpoint answered `204` with no
 * body and there was nothing to read. That is still true of three of the five
 * events, byte for byte.
 *
 * It is no longer true of `SessionStart` and `UserPromptSubmit`. Those two are
 * the moments an agent's context is assembled, and they are the only channel by
 * which an agent can be told which browser windows are attached to its session
 * *without typing a character into the terminal Asad is looking at* — a thing he
 * has objected to three times and this app will not do. So for those two events
 * the command keeps the body, and `hook-server.ts` answers them with a small
 * `additionalContext` JSON when, and only when, that session has a window
 * attached. Every other case is the same empty 204 it always was.
 *
 * The price is real and is paid once, deliberately, with his agreement:
 *
 *  - `readStatus` compares the installed command against this one **per
 *    (provider, event)**, so every provider reports "Needs reinstalling" until
 *    it is reinstalled once. The other three events' commands are unchanged, so
 *    only two entries per provider actually differ.
 *  - Codex persists a `trusted_hash` per hook entry, so two of its ten entries
 *    invalidate and are re-trusted on that reinstall.
 *
 * This re-enters, for one release and for two events, the state the paragraphs
 * above worked to eliminate. That is different from drifting back into it: it is
 * a one-time, visible reinstall in exchange for the agent knowing what `B2` is,
 * and the staleness fix itself — a stable address and no secret in the command —
 * is untouched.
 */

/**
 * The events whose answer the CLI must read rather than discard.
 *
 * Kept beside the command rather than imported from `hook-server.ts` because
 * they are two different facts that happen to agree today: this set decides what
 * the *command* does with the body, and the server's `CONTEXT_EVENTS` decides
 * whether there is a body at all. A mismatch fails safely in both directions —
 * a body nobody reads, or a reader with nothing to read — and `hooks.test.ts`
 * pins the pair so it cannot go unnoticed.
 */
const EVENTS_THAT_KEEP_THE_BODY: ReadonlySet<string> = new Set([
  'SessionStart',
  'UserPromptSubmit',
  // The mid-turn door. `hook-server.ts` says why at `CONTEXT_EVENTS`: these two
  // fire at the top of a turn, and a browser window attached *during* one is
  // otherwise not learned about until the next prompt. It answers with
  // something only in the turn after an attach or a detach; the rest of the
  // time it is the same empty 204 as before, thrown away by curl either way.
  'PostToolUse',
])
export function hookCommand(
  provider: HookProviderId,
  event: string,
  endpoint: HookEndpoint,
  platform: Platform = currentPlatform(),
  env: Env = process.env,
): string {
  if (isWindows(platform) && endpoint.clientPath) {
    return [
      shellQuote(powershellPath(env)),
      // No profile and no execution policy of the machine's: `Restricted` is
      // the default and is what the Windows machine this was measured on has,
      // so without `Bypass` every hook is "running scripts is disabled on this
      // system". The script is one this app wrote into its own data directory a
      // moment ago, not something the user is being asked to trust.
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy Bypass',
      `-File ${shellQuote(endpoint.clientPath)}`,
      // This run's token is on the far side of this one stable path, exactly as
      // `-K` puts it on the far side of one on POSIX.
      shellQuote(endpoint.configPath),
      provider,
      event,
      '2>/dev/null',
      '|| true',
      HOOK_MARKER,
    ].join(' ')
  }

  // `localhost` is a placeholder the socket makes meaningless — curl needs a
  // host to build a request line and a Host header, and connects to the path
  // from the config file instead of resolving this. The path segments are what
  // actually route the event.
  const url = `http://localhost/hook/${provider}/${event}`
  return [
    CURL,
    '-s',
    // Kept for three of the five events and dropped for the two that carry an
    // answer worth reading. See the section above for what that costs and why
    // it is worth it; without this the body would be written to /dev/null and
    // the agent would be told nothing about its own browser windows.
    ...(EVENTS_THAT_KEEP_THE_BODY.has(event) ? [] : ['-o /dev/null']),
    '--connect-timeout 1',
    '--max-time 3',
    '-X POST',
    "-H 'content-type: application/json'",
    // Double-quoted so the shell expands it: the PTY injects this per session,
    // which is what ties a hook back to the tab the user is looking at. Inside
    // double quotes `$VAR` expands but its *value* is never re-evaluated, so a
    // session id is data here no matter what it contains.
    `-H "${SESSION_HEADER}: $${BRAND.sessionEnvVar}"`,
    // The socket path and this run's token, read at call time. Everything that
    // changes between runs is on the far side of this one stable path.
    `-K ${shellQuote(endpoint.configPath)}`,
    '--data-binary @-',
    shellQuote(url),
    // curl's config-file errors are written before `-s` can suppress them, and
    // a missing config file is the ordinary state of a closed app.
    '2>/dev/null',
    '|| true',
    HOOK_MARKER,
  ].join(' ')
}

/* ------------------------------------------------------------ file access -- */

interface LoadedSettings {
  raw: string
  data: Record<string, unknown>
  exists: boolean
  /** Permission bits to write back, so a 0600 config stays 0600. */
  mode: number
  indent: string
  trailingNewline: boolean
}

/** A config we are about to hold a token in defaults to owner-only. */
const NEW_FILE_MODE = 0o600

/** Indent the file already uses, so writing back does not reformat it. */
export function detectIndent(text: string): string {
  const match = /\n([ \t]+)"/.exec(text)
  return match ? match[1] : '  '
}

class SettingsError extends Error {}

function loadSettings(file: string): LoadedSettings {
  let raw: string
  let mode = NEW_FILE_MODE
  try {
    raw = readFileSync(file, 'utf8')
    mode = statSync(file).mode & 0o777
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return { raw: '', data: {}, exists: false, mode: NEW_FILE_MODE, indent: '  ', trailingNewline: true }
    }
    throw new SettingsError(`could not be read: ${(error as Error).message}`)
  }

  // An empty file is a fresh start, not a parse failure.
  if (raw.trim() === '') {
    return { raw, data: {}, exists: true, mode, indent: '  ', trailingNewline: true }
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    // Comments, a trailing comma, a half-written edit — whatever it is, we do
    // not understand this file well enough to rewrite it without loss.
    throw new SettingsError(`is not valid JSON (${(error as Error).message}), so it was left untouched`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new SettingsError('is not a JSON object, so it was left untouched')
  }

  return {
    raw,
    data: parsed as Record<string, unknown>,
    exists: true,
    mode,
    indent: detectIndent(raw),
    trailingNewline: raw.endsWith('\n'),
  }
}

function serialise(settings: LoadedSettings, data: Record<string, unknown>): string {
  const body = JSON.stringify(data, null, settings.indent)
  return settings.trailingNewline ? `${body}\n` : body
}

/**
 * The path a write must actually land on.
 *
 * A rename replaces the *name*, and plenty of people keep `~/.claude` under a
 * dotfiles repo with `settings.json` symlinked into it. Renaming over the link
 * leaves a plain file where the link was: the CLI reads our copy, the repo
 * still holds the old one, and every future edit the user makes in their
 * dotfiles silently stops reaching the CLI. Follow the link and write the file
 * it points at, which is the one they think they are managing.
 *
 * A path that does not resolve — the usual case being a file we are about to
 * create — is returned unchanged.
 */
export function resolveWriteTarget(file: string): string {
  try {
    return realpathSync(file)
  } catch {
    return file
  }
}

/**
 * Write via a temp file in the same directory and rename over the target.
 *
 * Same directory matters: rename is only atomic within a filesystem, and a temp
 * file in /tmp can land on a different one. fsync before the rename so a crash
 * cannot leave the new name pointing at a partially flushed file — the failure
 * mode this whole feature has to avoid is a user's config truncated to nothing.
 */
export function writeAtomic(target: string, text: string, mode: number): void {
  const file = resolveWriteTarget(target)
  mkdirSync(dirname(file), { recursive: true })
  // Random, not just pid+time: two writes in the same millisecond of the same
  // process — a double-clicked Install — would otherwise collide on `wx` and
  // fail the second one for no reason the user could act on.
  const tmp = join(dirname(file), `.${BRAND.id}-${process.pid}-${randomBytes(6).toString('hex')}.tmp`)
  const fd = openSync(tmp, 'wx', mode)
  try {
    writeSync(fd, text)
    fsyncSync(fd)
  } finally {
    closeSync(fd)
  }
  try {
    // openSync's mode is masked by the process umask; set it explicitly so a
    // 0600 settings file does not come back as 0644.
    chmodSync(tmp, mode)
    renameSync(tmp, file)
  } catch (error) {
    try {
      unlinkSync(tmp)
    } catch {
      // The rename failure is the one worth reporting.
    }
    throw error
  }
}

/** Where the pristine copy of a provider's config is kept. */
export function backupPathFor(context: HookContext, id: HookProviderId): string {
  return join(context.backupDir, `${id}-${HOOK_PROVIDERS[id].path.join('-')}.bak`)
}

/**
 * Copy the file aside the first time we ever write to it, and never again.
 *
 * `wx` is what makes "the first time" true: a later backup would capture a file
 * we had already modified, which is exactly the copy that is no use to anybody
 * trying to get back to how things were before Deck arrived.
 */
function backupOnce(context: HookContext, id: HookProviderId, file: string): string | null {
  const target = backupPathFor(context, id)
  try {
    mkdirSync(dirname(target), { recursive: true })
    copyFileSync(file, target, 1 /* COPYFILE_EXCL */)
    return target
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'EEXIST') return target
    // No source file yet — there is nothing to preserve.
    if (code === 'ENOENT') return null
    throw error
  }
}

function hasBackup(context: HookContext, id: HookProviderId): string | null {
  const target = backupPathFor(context, id)
  try {
    statSync(target)
    return target
  } catch {
    return null
  }
}

/* --------------------------------------------------------- hook structure -- */

/**
 * One entry inside a matcher group. Unknown keys are carried through untouched
 * — this is somebody's real config and we are not the authority on its schema.
 */
type HookEntry = Record<string, unknown> & { type?: unknown; command?: unknown }
type MatcherGroup = Record<string, unknown> & { hooks?: unknown }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Does this entry carry our marker? The single test for ownership. */
export function isOurs(entry: unknown): boolean {
  if (!isRecord(entry)) return false
  return typeof entry.command === 'string' && entry.command.includes(HOOK_MARKER)
}

/** Whose hook is this, if it announces itself the way ours does? */
export function ownerOf(entry: unknown): string | null {
  if (!isRecord(entry) || typeof entry.command !== 'string') return null
  const match = FOREIGN_MARKER_RE.exec(entry.command)
  return match ? match[1].toLowerCase() : null
}

/**
 * The event arrays inside a `hooks` object.
 *
 * Gemini stores `enabled`, `disabled` and `notifications` in here alongside the
 * events, so "every key is an event" is wrong on a real file. Anything that is
 * not an array is somebody's setting and is skipped, not walked and not pruned.
 */
function eventEntries(hooks: Record<string, unknown>): Array<[string, unknown[]]> {
  const out: Array<[string, unknown[]]> = []
  for (const [key, value] of Object.entries(hooks)) {
    if (Array.isArray(value)) out.push([key, value])
  }
  return out
}

function hooksObject(data: Record<string, unknown>): Record<string, unknown> {
  const existing = data.hooks
  if (existing === undefined) return {}
  if (!isRecord(existing)) {
    throw new SettingsError('has a `hooks` key that is not an object, so it was left untouched')
  }
  return existing
}

/** Our entries in this file, by event name. */
function ourEntriesByEvent(hooks: Record<string, unknown>): Map<string, HookEntry[]> {
  const found = new Map<string, HookEntry[]>()
  for (const [event, groups] of eventEntries(hooks)) {
    const entries: HookEntry[] = []
    for (const group of groups) {
      if (!isRecord(group) || !Array.isArray(group.hooks)) continue
      for (const entry of group.hooks) {
        if (isOurs(entry)) entries.push(entry as HookEntry)
      }
    }
    if (entries.length > 0) found.set(event, entries)
  }
  return found
}

/** Everything in the file that is somebody else's, counted and attributed. */
function surveyForeign(hooks: Record<string, unknown>): { count: number; owners: string[] } {
  let count = 0
  const owners = new Set<string>()
  for (const [, groups] of eventEntries(hooks)) {
    for (const group of groups) {
      if (!isRecord(group) || !Array.isArray(group.hooks)) continue
      for (const entry of group.hooks) {
        if (!isRecord(entry) || isOurs(entry)) continue
        count++
        const owner = ownerOf(entry)
        if (owner) owners.add(owner)
      }
    }
  }
  return { count, owners: [...owners].sort() }
}

/** The entry we install for one event. */
function buildEntry(
  spec: HookProviderSpec,
  event: string,
  endpoint: HookEndpoint,
  platform: Platform,
  env: Env,
): HookEntry {
  const entry: HookEntry = {
    type: 'command',
    command: hookCommand(spec.id, event, endpoint, platform, env),
  }
  if (spec.timeout) entry[spec.timeout.key] = spec.timeout.value
  if (spec.supportsName) {
    entry.name = `${BRAND.id}-hook`
    entry.description = `${BRAND.name} session tracking`
  }
  return entry
}

/**
 * Replace our hooks for one provider, leaving everything else exactly as found.
 *
 * Ours go in their own matcher group rather than joining an existing one. It
 * costs a few lines in the file and buys unambiguous ownership: removal drops a
 * group we created whole, and never has to reason about whether the group it is
 * emptying belonged to somebody else.
 */
export function applyInstall(
  data: Record<string, unknown>,
  spec: HookProviderSpec,
  endpoint: HookEndpoint,
  platform: Platform = currentPlatform(),
  env: Env = process.env,
): Record<string, unknown> {
  const hooks = hooksObject(data)
  const next: Record<string, unknown> = { ...hooks }

  // Start from a clean slate for our own entries — including events we no
  // longer install, which an older version of the app may have left behind.
  // An event we emptied and are not about to refill leaves no empty array
  // behind: `"RetiredEvent": []` is litter in somebody's config.
  for (const [event, groups] of eventEntries(next)) {
    const kept = stripOurs(groups)
    if (!kept.changed) continue
    if (kept.groups.length === 0 && !spec.events.includes(event)) delete next[event]
    else next[event] = kept.groups
  }

  for (const event of spec.events) {
    const existing = next[event]
    if (existing !== undefined && !Array.isArray(existing)) {
      throw new SettingsError(`has a \`hooks.${event}\` that is not an array, so it was left untouched`)
    }
    const groups = Array.isArray(existing) ? [...existing] : []
    groups.push({ matcher: '', hooks: [buildEntry(spec, event, endpoint, platform, env)] })
    next[event] = groups
  }

  return { ...data, hooks: next }
}

/**
 * Drop our entries from one event's matcher groups.
 *
 * A group that still holds somebody else's hook is rebuilt with only its
 * `hooks` array replaced, so `sequential`, `matcher` and any key we have never
 * heard of survive. A group is only discarded when we emptied it ourselves —
 * a group that arrived empty is left exactly as it was found.
 */
function stripOurs(groups: unknown[]): { groups: unknown[]; changed: boolean; removed: number } {
  let removed = 0
  const out: unknown[] = []

  for (const group of groups) {
    if (!isRecord(group) || !Array.isArray(group.hooks)) {
      out.push(group)
      continue
    }
    const kept = (group.hooks as unknown[]).filter((entry) => !isOurs(entry))
    const dropped = group.hooks.length - kept.length
    removed += dropped
    if (dropped === 0) {
      out.push(group)
      continue
    }
    if (kept.length === 0) continue
    out.push({ ...group, hooks: kept } as MatcherGroup)
  }

  return { groups: out, changed: removed > 0, removed }
}

/**
 * Remove every trace of us, and nothing else.
 *
 * Pruning is deliberately conservative: an event key disappears only if we
 * removed something from it and it is now empty, and the whole `hooks` key
 * disappears only if it is now empty of events *and* of the non-event settings
 * Gemini keeps in there.
 */
export function applyRemove(
  data: Record<string, unknown>,
): { data: Record<string, unknown>; removed: number } {
  const hooks = hooksObject(data)
  const next: Record<string, unknown> = { ...hooks }
  let removed = 0

  for (const [event, groups] of eventEntries(hooks)) {
    const result = stripOurs(groups)
    if (!result.changed) continue
    removed += result.removed
    if (result.groups.length === 0) delete next[event]
    else next[event] = result.groups
  }

  if (removed === 0) return { data, removed: 0 }

  const out = { ...data }
  if (Object.keys(next).length === 0) delete out.hooks
  else out.hooks = next
  return { data: out, removed }
}

/* ----------------------------------------------------------------- status -- */

function fileFor(context: HookContext, id: HookProviderId): string {
  return join(context.home, ...HOOK_PROVIDERS[id].path)
}

function errorStatus(
  spec: HookProviderSpec,
  file: string,
  context: HookContext,
  message: string,
): HookProviderStatus {
  return {
    id: spec.id,
    label: spec.label,
    file,
    fileExists: true,
    state: 'error',
    installedEvents: [],
    staleEvents: [],
    missingEvents: [...spec.events],
    foreignHooks: 0,
    foreignOwners: [],
    backupPath: hasBackup(context, spec.id),
    message,
  }
}

/**
 * What is actually in the file right now.
 *
 * `stale` is decided by comparing the installed command against the one we would
 * write today, byte for byte. That comparison is only useful because the command
 * no longer contains anything that changes between runs — when it held a port
 * and a token, this test answered "stale" for every provider on every launch and
 * so told the user nothing.
 */
export function readStatus(context: HookContext, id: HookProviderId): HookProviderStatus {
  const spec = HOOK_PROVIDERS[id]
  const file = fileFor(context, id)

  let settings: LoadedSettings
  try {
    settings = loadSettings(file)
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error)
    return errorStatus(spec, file, context, `${file} ${detail}`)
  }

  let hooks: Record<string, unknown>
  try {
    hooks = hooksObject(settings.data)
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error)
    return errorStatus(spec, file, context, `${file} ${detail}`)
  }

  const ours = ourEntriesByEvent(hooks)
  const foreign = surveyForeign(hooks)

  const installed: string[] = []
  const stale: string[] = []
  const missing: string[] = []

  for (const event of spec.events) {
    const entries = ours.get(event)
    if (!entries || entries.length === 0) {
      missing.push(event)
      continue
    }
    const expected = context.endpoint
      ? hookCommand(
          spec.id,
          event,
          context.endpoint,
          context.platform ?? currentPlatform(),
          context.env ?? process.env,
        )
      : null
    const current = entries.some((entry) => expected !== null && entry.command === expected)
    if (current) installed.push(event)
    else stale.push(event)
  }

  // Events we installed in some earlier version and no longer manage still
  // count as ours for removal, but not toward the health of this install.
  const orphaned = [...ours.keys()].filter((event) => !spec.events.includes(event))

  const state: HookInstallState =
    installed.length === spec.events.length
      ? 'complete'
      : stale.length > 0 && installed.length + stale.length === spec.events.length
        ? 'stale'
        : installed.length + stale.length === 0 && orphaned.length === 0
          ? 'none'
          : 'partial'

  return {
    id: spec.id,
    label: spec.label,
    file,
    fileExists: settings.exists,
    state,
    installedEvents: installed,
    staleEvents: stale,
    missingEvents: missing,
    foreignHooks: foreign.count,
    foreignOwners: foreign.owners,
    backupPath: hasBackup(context, spec.id),
    message: describe(spec, state, settings.exists, stale.length),
  }
}

/**
 * The state, in a sentence.
 *
 * Deliberately says nothing about other tools' hooks: `foreignHooks` and
 * `foreignOwners` are on the status already and the panel renders them as their
 * own line. Saying it here too put the same fact on screen twice in every row.
 */
function describe(
  spec: HookProviderSpec,
  state: HookInstallState,
  fileExists: boolean,
  staleCount: number,
): string {
  switch (state) {
    case 'complete':
      return `All ${spec.events.length} events are installed and pointing at this run.`
    case 'stale':
      return `Installed, but ${staleCount} event${staleCount === 1 ? '' : 's'} point somewhere other than this copy of the app. Reinstall to aim them here.`
    case 'partial':
      return 'Only some events are installed, so parts of a session go unreported.'
    default:
      return fileExists
        ? 'No hooks from this app in this file yet.'
        : 'This file does not exist yet; installing creates it.'
  }
}

export function readAllStatus(context: HookContext): HookProviderStatus[] {
  return HOOK_PROVIDER_IDS.map((id) => readStatus(context, id))
}

/* ------------------------------------------------------------ install/rm -- */

export function installHooks(context: HookContext, id: HookProviderId): HookWriteResult {
  const spec = HOOK_PROVIDERS[id]
  const file = fileFor(context, id)

  if (!context.endpoint) {
    return {
      ok: false,
      message: 'The local hook endpoint is not running, so there is no address to install.',
      status: readStatus(context, id),
    }
  }

  let settings: LoadedSettings
  try {
    settings = loadSettings(file)
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error)
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id) }
  }

  let next: Record<string, unknown>
  try {
    next = applyInstall(
      settings.data,
      spec,
      context.endpoint,
      context.platform ?? currentPlatform(),
      context.env ?? process.env,
    )
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error)
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id) }
  }

  const backup = settings.exists ? backupOnce(context, id, file) : null
  writeAtomic(file, serialise(settings, next), settings.mode)

  const status = readStatus(context, id)
  const note = backup ? ` The original was kept at ${backup}.` : ''
  const requirement = spec.requirement ? ` ${spec.requirement}` : ''
  return {
    ok: true,
    message: `Installed ${spec.events.length} hooks into ${file}.${note}${requirement}`,
    status,
  }
}

export function removeHooks(context: HookContext, id: HookProviderId): HookWriteResult {
  const file = fileFor(context, id)

  let settings: LoadedSettings
  try {
    settings = loadSettings(file)
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error)
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id) }
  }
  if (!settings.exists) {
    return { ok: true, message: `${file} does not exist — nothing to remove.`, status: readStatus(context, id) }
  }

  let result: { data: Record<string, unknown>; removed: number }
  try {
    result = applyRemove(settings.data)
  } catch (error) {
    const detail = error instanceof SettingsError ? error.message : String(error)
    return { ok: false, message: `${file} ${detail}`, status: readStatus(context, id) }
  }

  if (result.removed === 0) {
    // Rewriting a file to produce a byte-identical result is pure risk.
    return {
      ok: true,
      message: `No hooks from this app were in ${file} — it was not modified.`,
      status: readStatus(context, id),
    }
  }

  backupOnce(context, id, file)
  writeAtomic(file, serialise(settings, result.data), settings.mode)

  return {
    ok: true,
    message: `Removed ${result.removed} hook${result.removed === 1 ? '' : 's'} from ${file}. Nothing else in the file was changed.`,
    status: readStatus(context, id),
  }
}

/**
 * Re-point every provider that already has our hooks at the current endpoint.
 *
 * Called from `src/main/index.ts` once the hook server is listening — which is
 * the wiring that was missing, and the reason this function existed for weeks
 * without ever running. `grep installHooks src/main/` used to find only the
 * renderer: the repair was a button in Settings and nothing else, so the app
 * could only fix itself if somebody opened a settings pane and pressed it.
 *
 * With a stable endpoint address this is a no-op on an ordinary restart, because
 * the installed command already matches the one we would write. What it still
 * does is migrate: an install written by a version of this app that baked the
 * port in reads as `stale` exactly once, gets rewritten once, and is correct
 * from then on without anybody being told to press anything.
 *
 * What it deliberately does **not** do is claim hooks another copy of the app
 * wrote — see {@link staleHooksBelongToAnotherCopy}. Those read `stale` here and
 * stay that way until somebody presses Reinstall, because a startup pass that
 * silently re-points them makes the last app launched the owner of every session
 * event on the machine.
 */
/**
 * Which endpoint config files the hooks already in this file point at.
 *
 * The command carries no secret and no port any more — the one thing that says
 * *which copy of this app* an installed hook belongs to is the path it reads
 * its token from, and that path is inside that copy's own data directory. Both
 * command shapes name it: POSIX passes it to curl as `-K <path>`, Windows hands
 * it to the client script as its first argument. Rather than parse two command
 * grammars, this pulls out every single-quoted path ending in the config file's
 * name, which is exactly that argument in both.
 *
 * An empty result is meaningful and is not the same as "not ours": commands
 * written before the token moved out of line had no config path at all.
 */
function endpointConfigsNamedIn(hooks: Record<string, unknown>): string[] {
  const found = new Set<string>()
  const quoted = new RegExp(`'([^']*${CONFIG_FILE.replace('.', '\\.')})'`, 'g')
  for (const [, entries] of ourEntriesByEvent(hooks)) {
    for (const entry of entries) {
      if (typeof entry.command !== 'string') continue
      for (const match of entry.command.matchAll(quoted)) found.add(match[1])
    }
  }
  return [...found]
}

/**
 * Are these stale hooks another running copy's, rather than an older version of
 * ours?
 *
 * This question exists because the answer used to be assumed, and the
 * assumption cost real damage: a second copy of this app — a dev build, a beta
 * installed beside the stable one, a scratch profile — starts up, finds hooks
 * that do not match the command *it* would write, reads that as "stale" and
 * silently re-points all of them at itself. Every session event on the machine
 * then goes to whichever copy launched last, and the copy the person is
 * actually using goes deaf without ever saying so. On this machine that
 * happened three times in one week, to twenty-two hooks across three CLIs.
 *
 * Nothing about it is specific to a developer's machine. Two installs of the
 * same app is an ordinary thing for a person to have.
 *
 * The distinction is drawn from the config path in the installed command, not
 * from a probe of the socket, because a copy that is merely *closed* still owns
 * its hooks — it is going to be opened again. Liveness would hand ownership to
 * whoever happened to be running at the moment of the check, which is the very
 * behaviour being removed.
 *
 * `stale` remains a state the Settings panel reports and offers to fix. What is
 * withdrawn is doing it silently, at startup, to a file this copy did not write.
 */
export function staleHooksBelongToAnotherCopy(context: HookContext, id: HookProviderId): boolean {
  const ours = context.endpoint?.configPath
  if (!ours) return false
  let named: string[]
  try {
    const settings = loadSettings(fileFor(context, id))
    named = endpointConfigsNamedIn(hooksObject(settings.data))
  } catch {
    // Unreadable or unparseable is already handled as `error` by readStatus, and
    // a file we cannot read is not one we should be rewriting either way.
    return true
  }
  // No config path at all is a command from before the token moved out of line.
  // Those really are ours to migrate — that migration is why this runs at all.
  if (named.length === 0) return false
  return named.some((path) => path !== ours)
}

export function syncInstalledHooks(context: HookContext): HookProviderStatus[] {
  const out: HookProviderStatus[] = []
  for (const id of HOOK_PROVIDER_IDS) {
    const status = readStatus(context, id)
    if (
      (status.state === 'stale' || status.state === 'partial') &&
      !staleHooksBelongToAnotherCopy(context, id)
    ) {
      try {
        out.push(installHooks(context, id).status)
        continue
      } catch (error) {
        // A refresh is best-effort: a failure here must not stop the app
        // starting, and the panel will still show the real state.
        console.error(`[hooks] could not refresh ${id}:`, error)
      }
    }
    out.push(status)
  }
  return out
}

/* -------------------------------------------------------------------- ipc -- */

/** Default context: the real home directory and a backup folder beside it. */
export function defaultContext(): HookContext {
  const home = homedir()
  return {
    home,
    backupDir: join(home, BRAND.projectConfigDir, 'hook-backups'),
    endpoint: currentHookEndpoint(),
  }
}

function asProviderId(value: unknown): HookProviderId | null {
  return typeof value === 'string' && (HOOK_PROVIDER_IDS as string[]).includes(value)
    ? (value as HookProviderId)
    : null
}

/**
 * Wire the hook channels. One call from the main process:
 *
 *     import { registerHooksIpc } from './hooks'
 *     registerHooksIpc(ipcMain)
 *
 * Channels:
 *  - `hooks:status`  (invoke)              → HookProviderStatus[]
 *  - `hooks:install` (invoke, providerId)  → HookWriteResult
 *  - `hooks:remove`  (invoke, providerId)  → HookWriteResult
 *  - `hooks:sync`    (invoke)              → HookProviderStatus[]
 *
 * The renderer names a provider from a closed set and nothing else. It never
 * supplies a path, a command or a file to write — this module owns all three,
 * because a channel that accepted them would be a remote-write primitive
 * dressed up as a settings panel.
 */
export function registerHooksIpc(
  ipcMain: Electron.IpcMain,
  options: { context?: () => HookContext } = {},
): void {
  const context = options.context ?? defaultContext

  ipcMain.handle('hooks:status', () => readAllStatus(context()))

  ipcMain.handle('hooks:sync', () => syncInstalledHooks(context()))

  ipcMain.handle('hooks:install', (_event, providerId: unknown) => {
    const id = asProviderId(providerId)
    if (id === null) throw new Error('hooks: unknown provider')
    try {
      return installHooks(context(), id)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return { ok: false, message: `Install failed: ${message}`, status: readStatus(context(), id) }
    }
  })

  ipcMain.handle('hooks:remove', (_event, providerId: unknown) => {
    const id = asProviderId(providerId)
    if (id === null) throw new Error('hooks: unknown provider')
    try {
      return removeHooks(context(), id)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return { ok: false, message: `Remove failed: ${message}`, status: readStatus(context(), id) }
    }
  })
}
