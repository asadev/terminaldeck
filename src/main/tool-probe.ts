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
): Promise<ProbeResult> {
  const command = `which ${bin}`
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

  try {
    const { stdout, stderr } = await run(shell, ['-c', command], {
      env: { ...process.env, PATH },
      timeout: PROBE_TIMEOUT_MS,
      encoding: 'utf8',
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
 */
export async function readVersion(bin: string, PATH: string): Promise<string | undefined> {
  if (!SAFE_BIN.test(bin)) return undefined
  try {
    const { stdout } = await run(bin, ['--version'], {
      env: { ...process.env, PATH },
      timeout: PROBE_TIMEOUT_MS,
      encoding: 'utf8',
    })
    return stdout.trim().split('\n')[0]?.slice(0, 60) || undefined
  } catch {
    return undefined
  }
}
