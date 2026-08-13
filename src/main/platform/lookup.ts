/**
 * Two questions this app asks the operating system constantly, and which it
 * answers differently: *what is the user's real PATH*, and *where is this
 * binary*.
 *
 * ## The login shell is a macOS answer to a macOS problem
 *
 * `providers.ts` documents the original lesson: a GUI app on macOS is started
 * by launchd, inherits a minimal PATH, and therefore cannot see a CLI installed
 * by nvm, Homebrew or into `~/.local/bin`. Asking the user's login shell for
 * `$PATH` is the fix, and it is worth the cost of spawning `zsh -lic`.
 *
 * Windows has neither the problem nor the mechanism. A process launched from
 * Explorer inherits the environment Explorer has, which already holds the merged
 * machine-and-user PATH out of the registry — there is no "login shell" to ask,
 * and `zsh -lic` on Windows is simply a spawn that fails. So on Windows the
 * answer is the environment this process already has, and the honest way to say
 * that is `null`: there is no command to run.
 *
 * (The one real Windows caveat: a PATH edited in System Properties after
 * Explorer started is not visible to Explorer's children until sign-out. That
 * affects a login shell exactly as much, so it is not a reason to spawn one.)
 *
 * ## `where.exe`, not `which`
 *
 * `which` does not exist on Windows. `where.exe` is the shipped equivalent in
 * System32; it prints one absolute path per match, newest search order first,
 * and exits 1 with `INFO: Could not find files for the given pattern(s).` on
 * **stderr** when there is no match — so a caller that rejects on non-zero exit
 * already treats "not found" correctly and never parses that sentence.
 *
 * It is named with the `.exe` deliberately. `where` is also a PowerShell alias
 * for `Where-Object`, and while `execFile` never goes through a shell, spelling
 * the extension makes the target unambiguous to anyone reading it, and matches
 * how the command is documented.
 *
 * One difference the callers have to know about: on Windows `where.exe` reports
 * whatever satisfies PATHEXT, which for an npm-installed agent CLI is a
 * `.cmd` shim — a batch file, not something `CreateProcess` can execute. That is
 * the right answer to *"is it installed"* and the wrong thing to hand to a PTY.
 * `providers.ts` carries that distinction as separate `bin` and `spawn` fields.
 */

import { isWindows, type Platform } from './host'

/** A command and its arguments, resolved for a platform but not yet run. */
export interface CommandSpec {
  command: string
  args: string[]
}

/**
 * How to ask this platform where a binary is.
 *
 * `bin` is placed as an argument, never interpolated into a string, because
 * both of these run through `execFile` with no shell in between.
 */
export function lookupSpec(platform: Platform, bin: string): CommandSpec {
  return isWindows(platform)
    ? { command: 'where.exe', args: [bin] }
    : { command: 'which', args: [bin] }
}

/**
 * The first path a lookup printed, or null when it printed nothing usable.
 *
 * Handles both shapes at once: `which` prints a single LF-terminated line,
 * `where.exe` prints one CRLF-terminated line per match and callers want the
 * first. The `INFO:`/`ERROR:` guard is belt and braces — those go to stderr and
 * come with a non-zero exit, so a well-behaved caller never gets here with one,
 * but treating a diagnostic as a file path is the kind of mistake that then
 * gets handed to `accessSync` or a spawn.
 */
export function firstLookupPath(stdout: string): string | null {
  for (const line of stdout.split(/\r?\n/)) {
    const path = line.trim()
    if (path === '') continue
    if (/^(INFO|ERROR):/i.test(path)) continue
    return path
  }
  return null
}

/**
 * How to ask this platform for the user's real PATH, or `null` when the
 * environment this process already has *is* the answer.
 *
 * The command is deliberately the same one `providers.ts` has always run:
 * an interactive login shell, printing `$PATH` with no trailing newline.
 */
export function loginPathSpec(
  platform: Platform,
  env: Record<string, string | undefined>,
): CommandSpec | null {
  if (isWindows(platform)) return null
  return { command: env.SHELL || '/bin/zsh', args: ['-lic', 'echo -n "$PATH"'] }
}
