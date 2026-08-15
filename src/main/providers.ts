import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { ProviderId } from '../shared/types'
import { currentPlatform, envPath, isWindows, withPath, type Env, type Platform } from './platform/host'
import { firstLookupPath, loginPathSpec, lookupSpec } from './platform/lookup'
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
export function providersFor(
  platform: Platform,
  env: Env,
  wsl: WslTarget | null = null,
): Record<ProviderId, ProviderSpec> {
  const windows = isWindows(platform)
  const target = windows ? wsl : null

  /**
   * `wsl.exe … -- <login shell> -lic '<cli>'` inside a distro, `cmd.exe /c <cli>`
   * on Windows, the CLI itself everywhere else.
   *
   * `exec` in front of the in-distro command so the agent replaces the login
   * shell rather than running as its child: without it the pty's foreground
   * process is a shell, so a Ctrl-C reaches the shell, and the exit code the tab
   * reports is the shell's rather than the agent's.
   */
  const launch = (bin: string, args: string[], resumeArgs: string[]): ProviderSpec['spawn'] => {
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

  return {
    // --continue verified against `claude --help` on this machine.
    claude: {
      id: 'claude',
      label: 'Claude Code',
      bin: 'claude',
      args: [],
      resumeArgs: ['--continue'],
      spawn: launch('claude', [], ['--continue']),
    },
    // UNVERIFIED: codex/gemini --help block on stdin so the flags could not be
    // confirmed here. An empty resumeArgs simply starts a fresh session, so a
    // wrong guess would silently do the wrong thing — codex is left in because
    // `resume --last` is documented, gemini is left empty until confirmed.
    codex: {
      id: 'codex',
      label: 'Codex CLI',
      bin: 'codex',
      args: [],
      resumeArgs: ['resume', '--last'],
      spawn: launch('codex', [], ['resume', '--last']),
    },
    gemini: {
      id: 'gemini',
      label: 'Gemini CLI',
      bin: 'gemini',
      args: [],
      resumeArgs: [],
      spawn: launch('gemini', [], []),
    },
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
 * Which provider CLIs are actually installed, so the UI can grey out the rest.
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

  const PATH = await loginPath(platform)
  // Never `{ ...process.env, PATH }`: on Windows that leaves two spellings of
  // the same variable in one object. `withPath` removes the ambiguity.
  const env = withPath(process.env, PATH, platform)

  /**
   * Does this name resolve on that PATH? Never throws: `which`/`where.exe`
   * exiting non-zero *is* the "not installed" answer, and a rejected promise
   * here would take the whole table down over the ordinary case.
   */
  const onPath = async (bin: string): Promise<boolean> => {
    const spec = lookupSpec(platform, bin)
    try {
      const { stdout } = await run(spec.command, spec.args, { env, windowsHide: true })
      // `where.exe` exits 0 having printed nothing only in cases that are not
      // a match; requiring a path keeps "found" meaning "there is a file".
      return firstLookupPath(stdout) !== null
    } catch {
      return false
    }
  }

  const [claude, codex, gemini] = await Promise.all([
    onPath(table.claude.bin),
    onPath(table.codex.bin),
    onPath(table.gemini.bin),
  ])
  // The shell is never looked up: it is a path this table already resolved.
  return { claude, codex, gemini, shell: true }
}
