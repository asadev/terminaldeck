/**
 * The literal probe behind "Not found".
 *
 * `prerequisites.ts` answers *whether* a CLI is there. This answers *what the
 * machine said when we looked*, because that sentence is the only thing that
 * turns "GitHub Copilot — Not found" into something a person can act on: it
 * names the command they can paste into their own terminal and get the same
 * answer.
 *
 * Two things were checked on this machine rather than assumed:
 *
 *  - `which` is a shell builtin in zsh and prints `copilot not found` itself,
 *    while `/usr/bin/which` — what bash and sh get — prints nothing at all and
 *    only sets an exit status. So the shell's own words are used when there are
 *    any, and a sentence is written only when there are none.
 *  - The probe runs through the user's login PATH, not the app's. A GUI app on
 *    macOS inherits a minimal PATH, so probing without it reports half the
 *    machine as missing (`providers.ts` learned this first).
 */

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { currentPlatform, isWindows, withPath, type Platform } from './platform/host'
import { lookupSpec } from './platform/lookup'

const run = promisify(execFile)

export interface ProbeResult {
  /** The command as it was run, so the answer can be reproduced in a terminal. */
  command: string
  /** Exactly what the shell said — stdout and stderr together, trimmed. */
  output: string
  /** The shell's exit status, or -1 when it was killed or never ran. */
  exitCode: number
  found: boolean
  /** One line for the panel: the shell's own words whenever it had any. */
  line: string
}

/**
 * A probe spawns a shell, so nothing may reach it that did not come from a table
 * in this repo. Every caller today passes a literal from `providers.ts` or
 * `copilot.ts`; this makes that a checked claim rather than a convention, since
 * the cost of the convention slipping is a shell injection in the user's login
 * shell.
 */
const SAFE_BIN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

/** Long enough for a cold login shell, short enough that the panel still paints. */
const PROBE_TIMEOUT_MS = 5000

/** Enough of the answer to be useful; a probe is a line, not a log. */
const MAX_OUTPUT_CHARS = 240
const MAX_OUTPUT_LINES = 3

/** What to hand `execFile`, once the platform has had its say. */
export interface LaunchSpec {
  /** The `file` argument. Already quoted when `shell` is true. */
  command: string
  /** Whether the command processor has to run it. */
  shell: boolean
}

/**
 * How to actually *run* something a lookup found, which is not always "run it".
 *
 * On Windows the thing that answers a PATH lookup for an npm-installed agent CLI
 * is a `.cmd` shim, and Node refuses to spawn a `.bat` or `.cmd` without
 * `shell: true` — it throws EINVAL, deliberately, since 18.20.2/20.12.2 as the
 * fix for CVE-2024-27980. Without this every agent CLI reported no version at
 * all on Windows: the spawn never ran, the catch swallowed it, and the Setup
 * panel showed a tool it had just found as having no version.
 *
 * The quoting is the second half of the same fix and is easy to leave out.
 * `shell: true` makes Node build `cmd.exe /d /s /c "<file> <args>"` and it does
 * **not** quote `<file>`, so an absolute path out of `where.exe` —
 * `C:\Program Files\nodejs\claude.cmd` is the ordinary case, not a corner one —
 * splits at the space and cmd tries to run `C:\Program`. Quoting the file makes
 * the line `cmd /d /s /c ""C:\Program Files\nodejs\claude.cmd" --version"`, and
 * `/s` strips exactly the outer pair, leaving the inner quotes where they are
 * needed. A `"` cannot appear in a Windows path, so there is nothing to escape.
 *
 * When the caller does not know where the binary is, the command processor runs
 * it either way — a shim or an `.exe` — so that is the safer answer than
 * guessing. It is only reachable with a `bin` that passed `SAFE_BIN`, which
 * admits no shell metacharacter, so nothing can be smuggled through cmd.
 */
export function launchSpec(bin: string, resolved: string | null, platform: Platform): LaunchSpec {
  if (!isWindows(platform)) return { command: bin, shell: false }
  const batch = resolved === null || /\.(cmd|bat)$/i.test(resolved)
  if (!batch) return { command: bin, shell: false }
  return { command: `"${resolved ?? bin}"`, shell: true }
}

function clean(text: string): string {
  return text
    .split('\n')
    .map((line) => line.trimEnd())
    .filter((line) => line.trim() !== '')
    .slice(0, MAX_OUTPUT_LINES)
    .join('\n')
    .slice(0, MAX_OUTPUT_CHARS)
}

/** What a failed spawn tells us. execFile hangs stdout/stderr off the error. */
interface ExecFailure {
  code?: number | string
  stdout?: string
  stderr?: string
  killed?: boolean
}

/**
 * Turn a finished probe into the shape the panel renders.
 *
 * Pure, so the wording can be tested without spawning anything — which is also
 * the only way to test the bash case on a zsh machine.
 */
export function toProbeResult(
  bin: string,
  command: string,
  raw: { stdout?: string; stderr?: string; exitCode: number },
): ProbeResult {
  const output = clean(`${raw.stdout ?? ''}\n${raw.stderr ?? ''}`)
  const found = raw.exitCode === 0
  if (found) {
    return {
      command,
      output,
      exitCode: 0,
      found: true,
      line: output !== '' ? output : `${bin} is on your PATH.`,
    }
  }
  const status = raw.exitCode < 0 ? 'did not finish' : `exited ${raw.exitCode}`
  return {
    command,
    output,
    exitCode: raw.exitCode,
    found: false,
    // The shell's sentence, verbatim, whenever it wrote one — `copilot not
    // found` is zsh's own wording and repeating it in our words would be a
    // second, slightly different truth.
    line: output !== '' ? output : `${bin} not found (${command} ${status}).`,
  }
}

/**
 * Ask the user's shell where a binary is, and keep whatever it says.
 *
 * Never rejects: a probe that throws would take out the whole setup check, and
 * "we could not even look" is itself a result worth showing.
 */
export async function probeBinary(
  bin: string,
  PATH: string,
  shell: string = process.env.SHELL || '/bin/zsh',
  platform: Platform = currentPlatform(),
): Promise<ProbeResult> {
  // `which` is not a Windows command and `/bin/zsh` is not a Windows shell, so
  // the POSIX form of this probe did not report "not found" on Windows — it
  // failed to run at all, and every tool came back missing with a sentence
  // naming a command the user cannot type. `where.exe` is the shipped
  // equivalent; `platform/lookup.ts` documents its exit-status and stderr
  // behaviour, which is already what `toProbeResult` expects.
  //
  // The POSIX path still goes through the login shell on purpose: zsh's `which`
  // builtin writes its own "copilot not found", and that sentence is the whole
  // point of this module. Windows has no equivalent wording to preserve, so it
  // runs `where.exe` directly with no shell in between.
  const windows = isWindows(platform)
  const spec = lookupSpec(platform, bin)
  const command = windows ? `${spec.command} ${bin}` : `which ${bin}`
  if (!SAFE_BIN.test(bin)) {
    return {
      command,
      output: '',
      exitCode: -1,
      found: false,
      // Unreachable from the tables that call this; reported rather than thrown
      // so a future caller sees it on screen instead of losing the panel.
      line: `${bin} is not a name this app is willing to run a probe for.`,
    }
  }

  const target = windows ? spec.command : shell
  const args = windows ? spec.args : ['-c', command]
  try {
    const { stdout, stderr } = await run(target, args, {
      env: withPath(process.env, PATH, platform),
      timeout: PROBE_TIMEOUT_MS,
      encoding: 'utf8',
      // The Setup panel probes every tool on open, so without this Windows
      // flashes a console window per tool over whatever the user is doing.
      windowsHide: true,
    })
    return toProbeResult(bin, command, { stdout, stderr, exitCode: 0 })
  } catch (error) {
    const failure = error as ExecFailure
    return toProbeResult(bin, command, {
      stdout: failure.stdout,
      stderr: failure.stderr,
      exitCode: typeof failure.code === 'number' ? failure.code : -1,
    })
  }
}

/**
 * A version string, or nothing.
 *
 * The same hazard `prerequisites.ts` documents applies here: several agent CLIs
 * open an interactive session when run with no arguments and some block on
 * stdin even for `--version`, so this runs with a hard timeout and treats a
 * timeout as "installed, version unknown" rather than as a failure.
 *
 * `resolved` is the absolute path a lookup already printed, when the caller has
 * one. It is what tells `launchSpec` whether this is a Windows `.cmd` shim that
 * has to go through the command processor; pass it rather than paying for a
 * second `where.exe`.
 */
export async function readVersion(
  bin: string,
  PATH: string,
  platform: Platform = currentPlatform(),
  resolved: string | null = null,
): Promise<string | undefined> {
  if (!SAFE_BIN.test(bin)) return undefined
  const launch = launchSpec(bin, resolved, platform)
  try {
    const { stdout } = await run(launch.command, ['--version'], {
      // `{ ...process.env, PATH }` would leave Windows holding both `Path` and
      // `PATH`; see `platform/host.ts`.
      env: withPath(process.env, PATH, platform),
      timeout: PROBE_TIMEOUT_MS,
      encoding: 'utf8',
      shell: launch.shell,
      // A version read happens for every installed tool the panel lists, and a
      // shelled-out one is a whole `cmd.exe`; neither may put a window on screen.
      windowsHide: true,
    })
    return stdout.trim().split('\n')[0]?.slice(0, 60) || undefined
  } catch {
    return undefined
  }
}
