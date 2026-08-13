import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { ProviderId } from '../shared/types'
import { currentPlatform, envPath, isWindows, withPath, type Env, type Platform } from './platform/host'
import { firstLookupPath, loginPathSpec, lookupSpec } from './platform/lookup'

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
   * UNVERIFIED on Windows: nothing in this repo can run there. It is written
   * this way because the alternative is a spawn that certainly fails, not
   * because it has been watched working.
   *
   * NOT YET READ BY ANYTHING. `src/main/index.ts` still spawns `bin` and `args`
   * in its `session:create` handler, so on Windows a session still tries to
   * `CreateProcess` a `.cmd` and the tab dies with no message. This field is
   * the answer to that and is inert until that handler reads it — which is one
   * two-line edit in a file this change was not allowed to touch. Until then
   * the Windows agent path is not fixed, only prepared, and `reachable.test.ts`
   * cannot notice: it checks that modules are imported, not that fields are
   * used.
   */
  spawn: { command: string; args: string[]; resumeArgs: string[] }
}

/**
 * The provider table for a platform.
 *
 * A function rather than a literal so both platforms' answers can be pinned by
 * a test on either — `PROVIDERS` below is this applied to the real platform.
 */
export function providersFor(platform: Platform, env: Env): Record<ProviderId, ProviderSpec> {
  const windows = isWindows(platform)

  /** `cmd.exe /c <cli>` on Windows; the CLI itself everywhere else. */
  const launch = (bin: string, args: string[], resumeArgs: string[]): ProviderSpec['spawn'] => {
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
   */
  const shellBin = windows ? env.COMSPEC || 'cmd.exe' : env.SHELL || '/bin/zsh'
  const shellArgs = windows ? [] : ['-l']

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
      spawn: { command: shellBin, args: shellArgs, resumeArgs: [] },
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

/** Which provider CLIs are actually installed, so the UI can grey out the rest. */
export async function detectProviders(
  platform: Platform = currentPlatform(),
): Promise<Record<ProviderId, boolean>> {
  const PATH = await loginPath(platform)
  // Never `{ ...process.env, PATH }`: on Windows that leaves two spellings of
  // the same variable in one object. `withPath` removes the ambiguity.
  const env = withPath(process.env, PATH, platform)
  // The table for the platform being asked about, not the one this process
  // happens to be on. Identical in production, where they are the same value;
  // the difference is that a test pinning the Windows branch then looks up the
  // names Windows would look up instead of this Mac's.
  const table = providersFor(platform, process.env)
  const found = {} as Record<ProviderId, boolean>

  await Promise.all(
    (Object.keys(table) as ProviderId[]).map(async (id) => {
      if (id === 'shell') {
        found[id] = true
        return
      }
      const spec = lookupSpec(platform, table[id].bin)
      try {
        const { stdout } = await run(spec.command, spec.args, { env, windowsHide: true })
        // `where.exe` exits 0 having printed nothing only in cases that are not
        // a match; requiring a path keeps "found" meaning "there is a file".
        found[id] = firstLookupPath(stdout) !== null
      } catch {
        found[id] = false
      }
    }),
  )
  return found
}
