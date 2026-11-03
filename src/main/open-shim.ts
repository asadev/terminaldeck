/**
 * The `open` a session finds first, so a URL an agent opens lands in the
 * browser he is looking at.
 *
 * ## The hole this fills
 *
 * Asad, 2026-08-19: *"when i ask any session to open a website or link they
 * should open in app the browser we built so they know where we are and what we
 * are talking about."* An agent inside a session does not ask this app for
 * anything when it opens a page — it shells out. Claude runs `$BROWSER` or
 * `open`; Gemini 0.46.0 ignores `$BROWSER` entirely and spawns a bare `open`.
 * Both of those are a PATH lookup, and a PATH lookup is something this app can
 * answer, in the session's own environment, without a single new tool, MCP
 * entry or protocol message.
 *
 * So: a directory this app writes at every start, first on the session's PATH,
 * holding a small script named exactly like the opener the platform already
 * has. It is written per run and deleted at shutdown for the same reason
 * `hook-server.ts` regenerates its Windows client — an upgrade must never leave
 * a stale script talking to a new endpoint.
 *
 * ## The order of the script is the safety case, and it is not negotiable
 *
 *  1. more or fewer than one argument  → exec the real opener, argv untouched
 *  2. the argument starts with `-`     → exec the real opener, argv untouched
 *  3. the argument is not `http(s)://` → exec the real opener, argv untouched
 *  4. otherwise ask this app, and fall back to the real opener on any doubt
 *
 * Rules 1–3 are why `open .`, `open -a Xcode file.swift`, `open -R file`,
 * `open report.pdf` and a bare `open` keep behaving byte for byte as they did.
 * This shim goes on the PATH of **every** session in the app, including every
 * session belonging to somebody who never asked for this feature, and a shim
 * that swallows `open .` breaks all of them.
 *
 * ## The one line that could brick the app
 *
 * `REAL_OPENER` is a **baked-in absolute literal**, resolved here at generation
 * time and written into the script. It is never a PATH lookup — no `command -v`,
 * no bare `open`. PATH now *begins* with this directory, so a lookup would find
 * this script, which would exec this script, for ever, in every session, on
 * every URL. Nothing else in this design can do that much damage, which is why
 * it is stated here and pinned by a test.
 *
 * ## No path may drop a URL
 *
 * Every branch either lands the URL in a window and prints which one, or
 * reaches the real opener and prints that it did. Exiting 0 having opened
 * nothing must never happen: Claude maps exit 0 to success and the model will
 * believe it, and the same silent-success failure is what made this whole area
 * worth fixing.
 *
 * ## Windows is not built here, and is not half-built either
 *
 * Windows has no `open` and `cmd.exe`'s `start` is a shell builtin that no PATH
 * entry can shadow, so the same trick does not transfer and the honest answer
 * is a different mechanism rather than a script that looks like this one and
 * catches nothing. Nothing is written there and nothing is prepended, so a
 * Windows session is exactly as it was.
 */

import { chmodSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import { BRAND } from '../shared/brand'
import { isWindows, type Platform } from './platform/host'

/** The directory, inside the app's own data directory. */
export const SHIM_DIR = 'shim'

/**
 * Every opener name this shims, and where the real one lives.
 *
 * macOS has exactly one and it is at a fixed path in the system, which is the
 * best possible case: no search, nothing to get wrong. Linux has two worth
 * catching — `xdg-open` is what almost everything calls, and `sensible-browser`
 * is what Debian's own tooling calls — and both have to be *found*, so both are
 * resolved against the environment's PATH before this directory is prepended to
 * it.
 */
const OPENERS: Record<string, readonly string[]> = {
  darwin: ['open'],
  linux: ['xdg-open', 'sensible-browser'],
}

/** Where the shim directory lives for one data directory. */
export function shimDir(dir: string): string {
  return join(dir, SHIM_DIR)
}

/**
 * The absolute path of the real opener called `name`, or null.
 *
 * Searched against the PATH this process inherited, which is by construction
 * the PATH before anything was prepended to it — and the search deliberately
 * skips our own directory, so that a second start cannot resolve the shim
 * written by the first one and bake a self-reference into the script.
 */
export function resolveOpener(name: string, dir: string, path: string | undefined): string | null {
  if (name === 'open') {
    // macOS ships it here and has since the system was called OS X. Looked up
    // by existence rather than by searching PATH, because a PATH search is the
    // thing this file is most careful never to depend on.
    return existsSync('/usr/bin/open') ? '/usr/bin/open' : null
  }
  const ours = shimDir(dir)
  for (const entry of (path ?? '').split(delimiter)) {
    if (entry === '' || entry === ours) continue
    const candidate = join(entry, name)
    if (existsSync(candidate)) return candidate
  }
  return null
}

/**
 * The script, with its two absolute paths already in it.
 *
 * `sh`, not `bash`: this runs on whatever a session's shell hands it, and the
 * whole script is `case`, `printf`, `head`, `sed`, `curl` and `exec`. Nothing
 * here needs an interpreter that a minimal container might not have.
 *
 * The answer from the app is deliberately **two lines of text**, not JSON: the
 * first names the route and the second is the sentence to print. A shell script
 * cannot assume `jq` exists, and hand-parsing JSON in `sed` is how a URL ends up
 * dropped by a quoting bug. Two lines need `head -n1` and nothing else.
 *
 * The URL is sent as the raw body with `content-type: text/plain` for the same
 * reason: building `{"url":"…"}` in the shell means escaping quotes and
 * backslashes that can legally appear in a URL, and getting that wrong loses
 * the address. The endpoint accepts either form; the shim uses the one with no
 * escaping in it at all.
 */
export function shimScript(realOpener: string, configPath: string): string {
  return `#!/bin/sh
# Written by ${BRAND.name} at every start, and deleted when it quits.
# Do not edit: this file is regenerated, and an edit here would be lost on the
# next launch while looking permanent in between.
#
# It exists so that a URL opened by an agent inside a session lands in that
# session's own browser window instead of in a browser somewhere else on the
# machine. Everything that is not a http(s) URL is handed straight to the real
# opener with its arguments untouched.

# Absolute, and never a PATH lookup: this directory is FIRST on PATH, so a
# lookup would find this script and exec it for ever, on every URL, in every
# session.
REAL_OPENER='${shellSingleQuote(realOpener)}'
CONFIG='${shellSingleQuote(configPath)}'

open_for_real() {
  if [ -x "$REAL_OPENER" ]; then
    exec "$REAL_OPENER" "$@"
  fi
  printf '%s\\n' "Could not open $1: no opener at $REAL_OPENER" >&2
  exit 1
}

# 1. Anything that is not exactly one argument is not a plain "open this URL".
[ "$#" -eq 1 ] || open_for_real "$@"

# 2 and 3. A flag, or an argument that is not a http(s) URL — a folder, a file,
# a custom scheme. Mixed-case schemes fall through here too, which fails in the
# safe direction: the URL still opens, just not in the app.
case "$1" in
  http://*|https://*|HTTP://*|HTTPS://*|Http://*|Https://*) ;;
  *) open_for_real "$@" ;;
esac

# 4. Ask the app. The session id is what ties this URL to the tab he is looking
# at; the config file holds the socket path and this run's token, exactly as the
# hook commands read it.
ANSWER=$(printf '%s' "$1" | curl -s \\
  --connect-timeout 1 \\
  --max-time 3 \\
  -X POST \\
  -H 'content-type: text/plain' \\
  -H "x-${BRAND.id}-session: $${BRAND.sessionEnvVar}" \\
  -K "$CONFIG" \\
  --data-binary @- \\
  'http://localhost/open' 2>/dev/null)

ROUTE=$(printf '%s\\n' "$ANSWER" | head -n 1)
LINE=$(printf '%s\\n' "$ANSWER" | sed -n '2,$p')

if [ "$ROUTE" = "tab" ]; then
  printf '%s\\n' "$LINE"
  exit 0
fi

# Everything else lands here: the app said "system", the app is not running, the
# socket refused, curl timed out, or the answer was something this script does
# not understand. All of them mean the same thing to whoever ran the command —
# the app did not take it, so the machine gets it — and all of them say so out
# loud rather than exiting 0 having done nothing.
if [ -n "$LINE" ]; then
  printf '%s\\n' "$LINE"
else
  printf '%s\\n' "${BRAND.name} did not take this link — opening it in your default browser."
fi
open_for_real "$@"
`
}

/** A value going inside single quotes in the generated script. */
function shellSingleQuote(value: string): string {
  return value.split("'").join("'\\''")
}

export interface OpenShim {
  /** The directory to put first on a session's PATH. */
  dir: string
  /** What `$BROWSER` should be set to, or null when nothing was written. */
  browser: string | null
}

/**
 * The shim this run wrote, for the one place that has to put it on a PATH.
 *
 * Module state rather than an argument threaded through `createHostCore`,
 * because the two ends are decided in different places and at different times:
 * the shim can only be written once the hook endpoint exists and knows its own
 * config path, and a session is started long afterwards from a file that has no
 * business knowing what a hook endpoint is. Null until it is written and null
 * again after shutdown, which is exactly the state a session should see when
 * there is nothing to point it at.
 */
let installed: OpenShim | null = null

/** What this run wrote, or null on a platform or a run that wrote nothing. */
export function currentOpenShim(): OpenShim | null {
  return installed
}

/**
 * Write the shim directory for this run, replacing whatever was there.
 *
 * Returns null on a platform this does not shim, and null when the real opener
 * could not be found — a shim with nowhere to fall back to is worse than no
 * shim, because it would break `open .` for a session that never asked for any
 * of this.
 */
export function writeOpenShim(
  dir: string,
  configPath: string,
  platform: Platform,
  path: string | undefined = process.env.PATH,
): OpenShim | null {
  if (isWindows(platform)) return null
  const names = OPENERS[platform]
  if (!names || names.length === 0) return null

  const target = shimDir(dir)
  // Removed first rather than written over: an opener that used to resolve and
  // no longer does must lose its script, or the session keeps a shim pointing
  // at a binary that has been uninstalled.
  removeOpenShim(dir)
  mkdirSync(target, { recursive: true })

  let browser: string | null = null
  for (const name of names) {
    const real = resolveOpener(name, dir, path)
    if (!real) continue
    const file = join(target, name)
    writeFileSync(file, shimScript(real, configPath), 'utf8')
    chmodSync(file, 0o755)
    // `$BROWSER` gets the first one that exists, which on macOS is `open` and on
    // Linux is `xdg-open` — the same order the platform itself would have used.
    if (browser === null) browser = file
  }

  if (browser === null) {
    removeOpenShim(dir)
    return null
  }
  installed = { dir: target, browser }
  return installed
}

/**
 * Delete it. Called at shutdown, and before every write.
 *
 * A shim left behind by a crashed run is not dangerous — it falls through to
 * the real opener when the socket does not answer — but it is a file this app
 * put on a PATH and no longer owns, and leaving those around is how an upgrade
 * ends up with two of them.
 */
export function removeOpenShim(dir: string): void {
  installed = null
  rmSync(shimDir(dir), { recursive: true, force: true })
}

/**
 * Put the shim in front of a PATH string.
 *
 * A separate function so that the one call site in `host-core.ts` reads as what
 * it is, and so a test can prove the directory appears exactly once — prepending
 * twice would be harmless and would also mean two call sites, which is one more
 * than this may ever have.
 */
export function prependShim(path: string, shim: string | null): string {
  if (!shim) return path
  const parts = path.split(delimiter).filter((part) => part !== shim)
  return [shim, ...parts].join(delimiter)
}
