import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { ProviderId } from '../shared/types'
import { AGENT_CATALOG, LOOKUP_AGENTS } from '../shared/agent-catalog'
import type { CustomAgent } from '../shared/custom-agents'
import {
  canStart,
  resolveAgentBinaries,
  type AgentBinary,
  type ResolveOptions,
} from './agent-binaries'
import { currentPlatform, envPath, isWindows, type Env, type Platform } from './platform/host'
import { loginPathSpec } from './platform/lookup'
import {
  IN_DISTRO_TIMEOUT_MS,
  WSL_EXE,
  decodeWslOutput,
  shellCommandLine,
  shellQuote,
  wslLaunch,
  type WslTarget,
} from './wsl'

const run = promisify(execFile)

export interface ProviderSpec {
  id: ProviderId
  label: string
  /**
   * The **name to look up**, not necessarily a thing that can be executed.
   *
   * `prerequisites.ts` and `alerts.ts` both ask "is this installed?" by looking
   * this up on PATH, so it has to stay the CLI's own name on every platform. On
   * Windows the thing that answers that lookup is frequently a `.cmd` shim from
   * npm — which settles the install question and cannot be spawned. See `spawn`.
   */
  bin: string
  /** Args used when starting a fresh session. */
  args: string[]
  /** Args used when continuing the most recent session in a folder. */
  resumeArgs: string[]
  /**
   * What actually has to be executed to get this agent running in a PTY.
   *
   * On macOS this is `bin` with the same argument lists, so nothing changes.
   * On Windows it is not: `node-pty` hands the command straight to
   * `CreateProcess` (verified by reading `windowsPtyAgent.js` in the installed
   * copy — it calls `startProcess(file, commandLine, …)` with no PATHEXT
   * resolution of its own), and `CreateProcess` will not run a `.cmd` batch
   * file. An npm-installed `claude` on Windows *is* a `.cmd`, so spawning the
   * bare name fails with ENOENT after `detectProviders` has already reported it
   * present — a tab that dies with no explanation.
   *
   * Going through the command processor is what makes a shim launchable, and it
   * is the same thing a person typing `claude` into a terminal gets. Each list
   * is a complete argument tail rather than a suffix, because the caller picks
   * one *or* the other and a shared prefix would be lost on the resume path.
   *
   * This is what `startSession` in `src/main/index.ts` reads: it passes
   * `spawn.command` and whichever of `spawn.args` / `spawn.resumeArgs` applies
   * straight to the PTY. The field was inert for a while and the note above
   * that call is where the wiring landed; it also records what spawning `bin`
   * there actually did on Windows 11, which was a bare "File not found:" and a
   * tab that died with no message.
   *
   * Still unverified, and worth keeping straight from the above: nothing in
   * this repository runs on Windows, so what is checked here is the *shape* —
   * `providers.test.ts` pins the exact Windows table this builds, so the
   * `cmd /c` form cannot drift silently — and not the argument lists
   * themselves. Those are still only as good as the `--help` output they were
   * read from, which the note on the table below spells out.
   */
  spawn: {
    command: string
    args: string[]
    resumeArgs: string[]
    /**
     * Where the *operating-system* process starts, when that is not the
     * session's own folder.
     *
     * Only ever set for a WSL session, and there it is not a refinement but the
     * difference between working and not: the session's folder is a Linux path,
     * `node-pty` resolves the cwd it is given through `path.win32.resolve`, and
     * `C:\home\asad\proj` does not exist. The Linux directory travels in
     * `wsl.exe --cd` instead. See `windowsFallbackCwd` in `wsl.ts`.
     */
    hostCwd?: string
  }
}

/**
 * The provider table for a platform.
 *
 * A function rather than a literal so both platforms' answers can be pinned by
 * a test on either — `PROVIDERS` below is this applied to the real platform.
 *
 * ## The third argument
 *
 * `wsl` is what turns this into the table for a session running *inside* a
 * distribution rather than on Windows itself, and it carries the session's
 * folder because `wsl.exe --cd` is part of the launch. That makes the table
 * per-session on that one path, which is why `PROVIDERS` below — the table for
 * everything that only wants `bin` or `resumeArgs` — passes nothing and stays a
 * constant. `startSession` builds its own with the target it is about to use.
 *
 * A target is honoured on Windows only. `wsl.exe` exists nowhere else, and
 * silently accepting one on macOS would produce a table that cannot spawn.
 */
/**
 * How this platform gets a command running in a pty, as a function of the
 * command.
 *
 * `wsl.exe … -- <login shell> -lic '<cli>'` inside a distro, `cmd.exe /c <cli>`
 * on Windows, the CLI itself everywhere else.
 *
 * `exec` in front of the in-distro command so the agent replaces the login shell
 * rather than running as its child: without it the pty's foreground process is a
 * shell, so a Ctrl-C reaches the shell, and the exit code the tab reports is the
 * shell's rather than the agent's.
 *
 * Lifted out of `providersFor`, where it was a closure, when a second caller
 * appeared: {@link customProviderSpec} builds the same field for an agent the
 * person added. Two copies of this would have been two answers to "how does a
 * command start on Windows", and the added agent — the one nobody here has
 * tested — would have had the copy that was never exercised.
 */
function launcher(
  platform: Platform,
  env: Env,
  wsl: WslTarget | null,
): (bin: string, args: string[], resumeArgs: string[]) => ProviderSpec['spawn'] {
  const windows = isWindows(platform)
  const target = windows ? wsl : null

  return (bin: string, args: string[], resumeArgs: string[]): ProviderSpec['spawn'] => {
    if (target) {
      const start = wslLaunch({
        distro: target.distro,
        cwd: target.cwd,
        inner: shellCommandLine(['exec', bin, ...args]),
        env,
      })
      const resume =
        resumeArgs.length > 0
          ? wslLaunch({
              distro: target.distro,
              cwd: target.cwd,
              inner: shellCommandLine(['exec', bin, ...resumeArgs]),
              env,
            })
          : null
      return {
        command: start.command,
        args: start.args,
        // Empty stays empty, for the reason the `cmd.exe` branch gives below.
        resumeArgs: resume === null ? [] : resume.args,
        hostCwd: start.hostCwd,
      }
    }
    if (!windows) return { command: bin, args, resumeArgs }
    const shell = env.COMSPEC || 'cmd.exe'
    return {
      command: shell,
      args: ['/c', bin, ...args],
      resumeArgs: resumeArgs.length > 0 ? ['/c', bin, ...resumeArgs] : [],
    }
  }
}

/**
 * The spawn spec for an agent somebody added.
 *
 * Everything a session start needs, built the same way and by the same function
 * as the four shipped agents' — which is the whole reason this is here rather
 * than in `custom-agents.ts`. An added agent is a name, two argument lists and a
 * folder; nothing about how a command is launched on Windows or inside a
 * distribution changes because this build has not heard of it, and a second
 * launch path for the agents nobody has tested would be the one that breaks
 * first and quietest.
 *
 * `label` and `bin` come straight off the record: `bin` is the name to look up,
 * which for an added agent is the command as typed, and `providers.ts`'s own
 * distinction between `bin` and `spawn.command` applies unchanged — the first
 * answers "is it installed", the second is what actually runs.
 */
export function customProviderSpec(
  agent: CustomAgent,
  platform: Platform,
  env: Env,
  wsl: WslTarget | null = null,
): ProviderSpec {
  const args = [...agent.args]
  const resumeArgs = [...agent.resumeArgs]
  return {
    id: agent.id,
    label: agent.label,
    bin: agent.command,
    args,
    resumeArgs,
    spawn: launcher(platform, env, wsl)(agent.command, args, resumeArgs),
  }
}

export function providersFor(
  platform: Platform,
  env: Env,
  wsl: WslTarget | null = null,
): Record<ProviderId, ProviderSpec> {
  const windows = isWindows(platform)
  const target = windows ? wsl : null
  const launch = launcher(platform, env, wsl)

  /**
   * The plain shell tab.
   *
   * `$SHELL -l` is a POSIX idea twice over: Windows sets no `SHELL`, and `-l`
   * is not a flag `cmd.exe` has. `%COMSPEC%` is what Windows guarantees points
   * at its command processor, and it is preferred over naming PowerShell
   * because PowerShell's location and availability vary by edition while
   * `COMSPEC` is set on every install.
   *
   * Inside a distro it is neither: the shell is whatever that user's passwd
   * entry says, which is a question only the distro can answer, so the thing
   * being launched is `wsl.exe` and the login-shell resolution happens on the
   * far side. `bin` says `wsl.exe` for the same reason — it is the name that
   * honestly answers "what opens a shell on this machine" there, and unlike a
   * host shell path it is not a claim about a binary that is not being run.
   */
  const wslShell = target
    ? wslLaunch({ distro: target.distro, cwd: target.cwd, inner: '', env })
    : null
  const shellBin = wslShell ? WSL_EXE : windows ? env.COMSPEC || 'cmd.exe' : env.SHELL || '/bin/zsh'
  const shellArgs = wslShell ? wslShell.args : windows ? [] : ['-l']

  /**
   * One agent's spec, read out of the catalogue rather than written here.
   *
   * The three object literals this replaced said the same thing three times —
   * an id, a label, a binary name and two argument lists — in a file that also
   * has to know about `cmd.exe`, `wsl.exe` and login shells. Every one of those
   * facts is about the CLI rather than about a platform, so they live in
   * `shared/agent-catalog.ts` where the renderer's picker reads the same copy,
   * and adding a fifth agent stops meaning "edit this function".
   *
   * The launch wrapper is what stays here, because that genuinely is a platform
   * question: the same `codex` is spawned bare on macOS, through `cmd.exe` on
   * Windows and through `wsl.exe` inside a distribution.
   */
  const fromCatalog = (id: 'claude' | 'codex' | 'gemini'): ProviderSpec => {
    const entry = AGENT_CATALOG[id]
    // Narrowed for the type only. `bin` is null for the shell alone, and the
    // shell is built below rather than passed through here.
    const bin = entry.bin ?? id
    const args = [...entry.args]
    const resumeArgs = [...entry.resumeArgs]
    return { id, label: entry.label, bin, args, resumeArgs, spawn: launch(bin, args, resumeArgs) }
  }

  return {
    claude: fromCatalog('claude'),
    codex: fromCatalog('codex'),
    gemini: fromCatalog('gemini'),
    shell: {
      id: 'shell',
      label: 'Shell',
      bin: shellBin,
      args: shellArgs,
      resumeArgs: [],
      // Already an executable path, so it needs no command-processor wrapper.
      spawn: {
        command: shellBin,
        args: shellArgs,
        resumeArgs: [],
        ...(wslShell ? { hostCwd: wslShell.hostCwd } : {}),
      },
    },
  }
}

export const PROVIDERS: Record<ProviderId, ProviderSpec> = providersFor(currentPlatform(), process.env)

/**
 * The PATH a spawned CLI should get.
 *
 * GUI apps on macOS inherit a minimal PATH, so a CLI installed via nvm,
 * Homebrew or ~/.local/bin is frequently invisible. Ask the user's login
 * shell for its real PATH once and reuse it for every spawn.
 *
 * On Windows there is no login shell to ask and no such deficit to make up: a
 * process started from Explorer already carries the merged machine-and-user
 * PATH out of the registry. `loginPathSpec` says so by answering `null`, and
 * this returns the environment's own value rather than spawning something that
 * does not exist. See `platform/lookup.ts` for the full reasoning.
 */
let cachedPath: string | null = null

/** Drops the memo. Exported for tests, which pin one platform per case. */
export function resetLoginPathCache(): void {
  cachedPath = null
}

export async function loginPath(platform: Platform = currentPlatform()): Promise<string> {
  if (cachedPath) return cachedPath

  const spec = loginPathSpec(platform, process.env)
  if (spec === null) {
    cachedPath = envPath(process.env, platform)
    return cachedPath
  }

  try {
    const { stdout } = await run(spec.command, spec.args, { timeout: 5000 })
    cachedPath = stdout.trim() || envPath(process.env, platform)
  } catch {
    cachedPath = envPath(process.env, platform)
  }
  return cachedPath
}

/**
 * The prefix an in-distro probe prints for each CLI it found.
 *
 * A marker rather than bare names because the answer comes back through a login
 * shell, and a login shell prints whatever the user's `.bashrc` prints — a
 * fortune, a `neofetch`, a "you have mail". `firstLookupPath` takes the first
 * non-empty line, so unmarked output would have the app reading somebody's motd
 * as the location of Claude Code. Only lines carrying this prefix are read, and
 * everything else on the stream is ignored rather than guessed at.
 */
export const WSL_FOUND_PREFIX = 'agent-found:'

/**
 * Ask a distribution which of these CLIs it has, in one round trip.
 *
 * One `wsl.exe` for the whole table rather than one per agent. Each call has to
 * start a login shell inside the distro — and, if the distro is asleep, boot a
 * virtual machine first — so three calls is three times a cost that is already
 * the largest thing on the New Session path.
 *
 * `command -v` rather than `which`: it is a POSIX shell builtin, so it is there
 * on a distro with no `which` binary (Alpine's default install has none), and it
 * answers about the PATH of the shell that just sourced the user's rc files,
 * which is the entire question.
 *
 * Nothing here throws: a distro that is missing, refuses to start, or times out
 * answers "none of them", and the caller's existing fallback turns the tab into
 * a plain shell rather than a spawn that dies.
 */
async function detectInsideDistro(
  target: WslTarget,
  names: readonly string[],
  env: Env,
): Promise<Set<string>> {
  const inner =
    `for n in ${names.map(shellQuote).join(' ')}; do ` +
    // `\\n` and not a real newline: this whole string travels as one Windows
    // command-line argument, and a raw line break inside one is a thing that
    // happens to survive rather than a thing that is meant to. `printf` turns
    // the two characters into the line break on the far side, where it belongs.
    `command -v $n >/dev/null 2>&1 && printf ${shellQuote(`${WSL_FOUND_PREFIX}%s\\n`)} $n; ` +
    `done`
  // No `--cd`: this asks about the distro, not about a folder, and pointing it
  // at a folder that has since been deleted would fail the probe over something
  // it is not asking about.
  const launch = wslLaunch({ distro: target.distro, cwd: null, inner, env })

  try {
    const { stdout } = await run(launch.command, launch.args, {
      timeout: IN_DISTRO_TIMEOUT_MS,
      windowsHide: true,
      // Decoded by hand: `wsl.exe` writes its *own* messages as UTF-16LE, and
      // reading them as utf8 is how a working distro reports nothing installed.
      // `decodeWslOutput` sniffs, so passthrough output from the Linux process —
      // which is plain UTF-8 — is unaffected.
      encoding: 'buffer',
    })
    const text = decodeWslOutput(Buffer.isBuffer(stdout) ? stdout : Buffer.from(String(stdout)))
    const found = new Set<string>()
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim()
      if (trimmed.startsWith(WSL_FOUND_PREFIX)) found.add(trimmed.slice(WSL_FOUND_PREFIX.length))
    }
    return found
  } catch {
    return new Set<string>()
  }
}

/**
 * Which agents a session can actually be started on, so the UI can grey out the
 * rest.
 *
 * ## "Installed" was the wrong question
 *
 * This used to answer whether the name resolved on PATH, and that is what let
 * the worst bug in the 2026-08-16 recording through. The npm `@openai/codex`
 * package puts a JavaScript launcher on PATH whose vendored native binary is
 * missing on this machine, so `which codex` succeeds, this said `codex: true`,
 * the picker offered it, a PTY opened, and the first thing the user saw was a
 * Node `ENOENT` stack trace in a session they then had to close by hand. Five
 * times.
 *
 * So the question is now "does it run", answered by running it — see
 * `agent-binaries.ts`, which also knows where a working copy lives when the one
 * on PATH is broken. The name of this function is unchanged because the whole
 * app already asks it in the right place; only the answer got honest.
 *
 * `wsl` decides **which machine is being asked about**, and that is not a
 * detail: whether `claude` exists is a question about Ubuntu's PATH, not about
 * Windows', on a machine where the agent was installed inside Ubuntu. Asking the
 * wrong side is the whole reported bug — `where.exe claude` answers "not found",
 * every agent is reported missing, and every session quietly becomes a cmd.exe
 * shell on a machine with a perfectly good Claude Code install six inches away.
 *
 * ## Why the three agents are named rather than derived
 *
 * This used to open with `(Object.keys(table) as ProviderId[]).filter(id => id
 * !== 'shell')` and fill a `{} as Record<ProviderId, boolean>` key by key. Both
 * casts were assertions nothing checked. `Object.keys` answers `string[]` no
 * matter what it was handed, so renaming a key in `providersFor` would have
 * left this iterating a name that no longer existed — every agent reported
 * missing, which is the exact symptom the function exists to prevent — and the
 * empty-object cast promised a complete record while the loop that filled it
 * ran later, so an early `return` would have shipped `{ shell: true }` to a UI
 * that believed it had four answers.
 *
 * Naming them costs three words per branch and buys a real check: `table.codex`
 * stops compiling if the key is renamed, and both returns are object literals
 * measured against `Record<ProviderId, boolean>`, so a provider added to the
 * union fails *here* instead of being silently skipped.
 */
export async function detectProviders(
  platform: Platform = currentPlatform(),
  wsl: WslTarget | null = null,
): Promise<Record<ProviderId, boolean>> {
  // The table for the platform being asked about, not the one this process
  // happens to be on. Identical in production, where they are the same value;
  // the difference is that a test pinning the Windows branch then looks up the
  // names Windows would look up instead of this Mac's.
  //
  // Built without the WSL target on purpose: what is wanted from it here is
  // `bin`, the CLI's own name, and that is the same name on both sides of the
  // boundary. Passing the target would build a whole `wsl.exe` launch line for
  // a question that only needs three words out of it.
  const table = providersFor(platform, process.env)

  if (wsl !== null && isWindows(platform)) {
    const found = await detectInsideDistro(
      wsl,
      [table.claude.bin, table.codex.bin, table.gemini.bin],
      process.env,
    )
    return {
      claude: found.has(table.claude.bin),
      codex: found.has(table.codex.bin),
      gemini: found.has(table.gemini.bin),
      // The shell is always available: `wsl.exe` resolves the user's login shell
      // on the far side, and a distro without one is not a distro.
      shell: true,
    }
  }

  const binaries = await agentBinaries(platform)
  return {
    claude: canStart(binaries.claude),
    codex: canStart(binaries.codex),
    gemini: canStart(binaries.gemini),
    // The shell is never looked up: it is a path this table already resolved.
    shell: true,
  }
}

/**
 * Every agent's binary, resolved against the user's login PATH.
 *
 * A thin wrapper so the two callers in this module — and `prerequisites.ts`,
 * which asks the same question to draw a Setup row — cannot get the PATH
 * argument wrong. A GUI app on macOS inherits a minimal PATH, so probing
 * without `loginPath` reports half the machine as missing.
 */
export async function agentBinaries(
  platform: Platform = currentPlatform(),
  options: Omit<ResolveOptions, 'platform' | 'path'> = {},
): Promise<Record<ProviderId, AgentBinary>> {
  // Spelled `path:` from a call rather than through a `PATH` local: an object
  // literal holding a spread and a `PATH` token is the `{ ...process.env, PATH }`
  // shape `platform/env-path.test.ts` scans the whole tree for, and it cannot
  // tell this one from the one that leaves Windows holding two spellings of the
  // same variable.
  return resolveAgentBinaries({ ...options, platform, path: await loginPath(platform) })
}

/**
 * The spawn table with each agent pointed at a copy that actually runs.
 *
 * `providersFor` is pure and stays pure — it is pinned by a test on both
 * platforms and must keep answering the same thing without touching a disk. This
 * is the version a session start should use, and the difference is one field:
 * when the name on PATH will not execute and a declared alternate will,
 * `spawn.command` becomes that alternate's absolute path.
 *
 * Only ever applied to a session running on *this* machine. Inside WSL the
 * command is a `wsl.exe` line whose payload is resolved by the distribution's
 * own login shell, and substituting a macOS or Windows path into it would name a
 * file that side cannot see; on Windows the bare name is deliberate, because
 * what answers a lookup there is a `.cmd` shim that has to go through the
 * command processor rather than be executed directly. Both cases are left
 * exactly as `providersFor` built them.
 */
export async function resolvedProvidersFor(
  platform: Platform = currentPlatform(),
  env: Env = process.env,
  wsl: WslTarget | null = null,
): Promise<Record<ProviderId, ProviderSpec>> {
  const table = providersFor(platform, env, wsl)
  if (wsl !== null || isWindows(platform)) return table

  const binaries = await agentBinaries(platform)
  const point = (spec: ProviderSpec): ProviderSpec => {
    const binary = binaries[spec.id]
    // `runnable` is the bare name in the ordinary case, and only an absolute
    // path when the ordinary case failed — so this is a no-op unless something
    // is actually wrong with the install.
    if (!binary || binary.runnable === null || binary.runnable === spec.spawn.command) return spec
    return { ...spec, spawn: { ...spec.spawn, command: binary.runnable } }
  }

  return {
    claude: point(table.claude),
    codex: point(table.codex),
    gemini: point(table.gemini),
    // Nothing to point at: the shell is already an absolute path.
    shell: table.shell,
  }
}

/**
 * The agent names this build looks up, for anything that wants the list rather
 * than the answers. Derived from the catalogue, so a new entry joins by existing.
 */
export const LOOKUP_BINS: readonly string[] = LOOKUP_AGENTS.map((entry) => entry.bin ?? '')
