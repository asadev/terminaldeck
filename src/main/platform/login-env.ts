/**
 * Which environment variables the user's *login* shell has, by name only.
 *
 * ## Why the question is asked at all
 *
 * The MCP store has rows that need a secret — a GitHub token, a Tavily key —
 * and there are exactly two places such a value can live where the thing that
 * needs it will find it:
 *
 *  1. **In the configuration**, written by `claude mcp add -e KEY=value`. That
 *     is plain text in `~/.claude.json`.
 *  2. **In the environment the agent is started with**, which on POSIX is the
 *     login shell's — `providers.ts` spawns every agent CLI through `-l`, and
 *     an MCP server is a child of that agent, so it inherits.
 *
 * The second is strictly better and costs nothing, but only if the variable is
 * *already there*. Offering it blind would be the dead control this app is not
 * allowed to have: a row saying "leave it blank, your shell has it" to somebody
 * whose shell does not, producing a server that starts and fails on its first
 * call with an unauthorised error nobody can trace back to this button.
 *
 * So it is measured, and the answer decides what the row offers.
 *
 * ## `printenv | sed …` — names, never values
 *
 * This process never receives the secret. `printenv` prints `KEY=value` lines
 * and the `sed` substitution keeps only the identifier at the start of a line
 * that has an `=` after it, so what comes back over the pipe is a list of
 * identifiers. That matters for more than tidiness: a value that reached this
 * process would reach its crash reports, its logs and its memory dumps, for a
 * question that only ever needed a yes or a no.
 *
 * The `sed` is deliberately doing the filtering rather than a plain
 * `cut -d= -f1`, and the difference is a real defect rather than a preference. A
 * multi-line value — an exported shell function, a PEM certificate — puts its
 * own body through the pipe as lines of its own, and `cut` on a line with no `=`
 * in it returns **the whole line**. A base64 continuation like `MIIBIjANBg` is a
 * perfectly good shell identifier, so it would come back as a variable name; ask
 * about a key that happened to collide and the store would tell somebody the
 * token was already in their shell when what was in their shell was the second
 * line of a certificate. Anchoring on `^NAME=` drops every such line at the
 * source. {@link parseEnvNames} keeps the same shape as a second filter, because
 * a guard on one side of a pipe is a guard on one side of a pipe.
 *
 * It also means **nothing is interpolated into the shell command**. The obvious
 * implementation builds a script out of the key names it is asking about —
 * `for k in GITHUB_TOKEN …` — and that is a string this app assembles and a
 * shell then parses. The names here come from a constant in this app's own
 * bytes, so it would be safe today and one careless caller away from not being.
 * A fixed command with the filtering done in Node cannot acquire that bug.
 *
 * ## Windows asks nothing
 *
 * The same split `lookup.ts` documents for PATH, for the same reason: a process
 * started from Explorer already carries the merged machine-and-user environment
 * out of the registry, and there is no login shell to ask. `null` is the honest
 * answer — there is no command to run — and the caller reads `process.env`
 * instead, which on that platform *is* the user's environment.
 */

import { isWindows, type Platform } from './host'
import type { CommandSpec } from './lookup'

/**
 * How to ask this platform for the names in the login environment, or `null`
 * when the environment this process already has is the answer.
 *
 * Deliberately the same shell invocation `loginPathSpec` uses — an interactive
 * login shell — because a variable exported from `.zshrc` rather than
 * `.zprofile` is only in one of the two, and `-i` is what makes this agree with
 * the PATH the rest of the app resolves.
 */
export function loginEnvSpec(
  platform: Platform,
  env: Record<string, string | undefined>,
): CommandSpec | null {
  if (isWindows(platform)) return null
  return {
    command: env.SHELL || '/bin/zsh',
    args: ['-lic', "printenv | sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'"],
  }
}

/** A shell variable name. Anything else in the output is not one and is dropped. */
const NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/

/**
 * The set of names in whatever the spec printed.
 *
 * Pure and exported so the parsing is pinned by a test rather than by a spawn.
 * The `sed` above has already dropped everything that is not `NAME=…`; this is
 * the second half of the same filter, and it is what catches the Windows path,
 * where there is no shell in between and the names come straight off
 * `process.env`.
 */
export function parseEnvNames(stdout: string): Set<string> {
  const out = new Set<string>()
  for (const line of stdout.split(/\r?\n/)) {
    const name = line.trim()
    if (NAME_PATTERN.test(name)) out.add(name)
  }
  return out
}
