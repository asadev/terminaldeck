/**
 * The half of a server session that is about **belonging** — where it is, what
 * is attached to it, and where a page it opens goes.
 *
 * ## The two failures, and the one root under both
 *
 * Asad, testing a session on one of his servers:
 *
 * > *"server session is still opening browser in where its based like inside the
 * > server not in the app, and dont get to know about terminal deck until we
 * > talk about it, and dont get to know about browser connection even if we
 * > connect it manually."*
 *
 * Three complaints, one cause. Everywhere else in this app a session is started
 * by `host-core.ts`, which puts `open-shim.ts`'s directory on its PATH and whose
 * account already has this app's hooks in `~/.claude/settings.json`. A server
 * shell is neither: `connection.ts` asks for `client.shell()`, the far end runs
 * the account's login shell, and a **person** types `claude` into it. So:
 *
 *  1. `open <url>` finds that server's own `xdg-open`, which is why the page
 *     appeared on the server.
 *  2. No hook of ours fires, so `app-context.ts`'s boot map never arrives —
 *     *"doesn't get to know about Terminal Deck"*.
 *  3. `browser-binding.ts`'s `hookContext` and `takeAnnouncement` ride the same
 *     hook reply, so a window he attached by hand was never announced either.
 *
 * All three are the same missing thing: a way for that shell to reach this Mac's
 * **hook endpoint**. `window-reach.ts` already knows how to give a server a
 * loopback port that lands here, and `window-drive.ts` already puts a directory
 * first on that shell's PATH. This module is what goes in that directory.
 *
 * ## Why hooks and not `--append-system-prompt-file`
 *
 * The wrapper composes the command line, so a standing fact could be handed over
 * as a file the way `copilot-session.ts` hands the copilot its identity. It was
 * weighed and it loses on requirement 3, decisively:
 *
 *  - **A file is read once, at exec.** He attaches a browser window *while the
 *    agent is working*, and asked for it out loud: *"whenever I just connect, it
 *    should get a context."* Nothing written before the session started can
 *    carry a window attached afterwards. Hooks can, because `PostToolUse` is a
 *    question the agent asks us mid-turn.
 *  - **The same channel already answers all three.** `hook-server.ts`'s
 *    `contextFor` composes the boot description, the boot map and the mid-turn
 *    announcement from one place. A system-prompt file would be a *second*
 *    spelling of "you are inside this app, and B2 is a window" that drifts from
 *    the first the day one of them is edited.
 *  - **A system prompt is not free and not droppable.** It rides every turn for
 *    the life of the session whether or not anything changed, which is the cost
 *    `hookContext` was shaped to avoid.
 *
 * So: hooks, and nothing here writes a system prompt.
 *
 * ## Why `--settings` and not this account's `~/.claude/settings.json`
 *
 * `hooks.ts` installs into a provider's real settings file, and it is careful
 * about it — every entry tagged, only tagged entries removed, atomic writes. It
 * would work here too. It is still the wrong door for a server, for two reasons:
 *
 *  - **The values are per terminal, and that file is per account.** The hook has
 *    to name *this* shell's session id and *this* shell's loopback port, and two
 *    terminals open on one server have two of each. One account-wide file cannot
 *    hold both, and the environment cannot carry the difference — `sshd`'s
 *    `AcceptEnv` is `LANG LC_*` on a default install, which is the first thing
 *    `window-drive.ts` rejected.
 *  - **It is somebody else's machine.** §7 of `SERVERS-DESIGN.md` draws the
 *    line: what goes on a server goes there because a person pressed a button,
 *    with a way back. A per-terminal folder under `/tmp` that is removed when
 *    the terminal closes is a better way back than a tagged edit to a file in
 *    somebody's home that survives this app being uninstalled.
 *
 * `--settings` is what makes that possible, and it was **measured** rather than
 * hoped, twice, against Claude Code 2.1.238 in a scratch `HOME`:
 *
 *  - A `SessionStart` hook in `~/.claude/settings.json` and a *different* one in
 *    a file passed to `--settings` **both fired on one run**. So the flag is an
 *    *additional* layer — the word its own `--help` uses — and this app adds three
 *    hooks to a server without taking any of that account's own away.
 *  - The exact file {@link settingsFile} composes was then handed to a real
 *    `claude`, which ran {@link posterScript} and handed it the genuine event
 *    JSON on stdin. What the script posted was the endpoint below, the session
 *    header below, and `-K` naming the config below. Everything in this module
 *    except the tunnel itself has been run end to end.
 *
 * The version on somebody's Ubuntu box may predate it, so it is read out of
 * *that machine's* `claude --help` ({@link honoursSettings}), exactly as
 * `window-drive.ts` reads `--mcp-config` out of the same text. A server whose CLI
 * does not list it gets the `open` shim and no hooks, rather than a flag that
 * makes every invocation fail.
 *
 * ## What this puts on somebody's server, and what takes it away
 *
 * Everything below lands inside the one `/tmp/td-drive-XXXXXX` folder
 * `window-drive.ts` already makes per terminal, `0700`, with every file `0600`
 * from the instant it exists. Nothing is written into that account's home
 * directory: `~/.claude/settings.json`, `~/.bashrc` and `~/.profile` on that
 * machine are exactly as their owner left them. `WindowDrives.disarm` removes
 * the whole folder when the terminal closes, `revoke` does it for every terminal
 * on a server the moment the switch is unticked, and `stop` does it at shutdown.
 * Every file also carries {@link HOOK_MARKER} or this app's name in its first
 * line, so a folder left behind by a link that died can be recognised for what
 * it is.
 *
 * ## The one thing this widens, said plainly
 *
 * The hook endpoint's token now leaves this Mac. It is written into `hook.conf`
 * on that server so `curl -K` can read it at call time — never onto a command
 * line, because a command line is in that machine's process list where anybody
 * signed in can read it, which is the same argument `window-drive.ts` makes
 * about `runScript`.
 *
 * That is a real widening and it is bounded: the file is `0600` inside a `0700`
 * folder that goes when the terminal does, the token is per run of this app and
 * dies with it, and the folder **already** holds a bearer token for
 * `deck-control` for the same terminal. What a holder of it could do is post
 * hook events and `/open` requests naming a session id — and the session ids are
 * `randomUUID()`, so it cannot address a session on a different server without
 * guessing one.
 *
 * ## Nothing here prints anything into his terminal
 *
 * Not one line. The `PATH` line `window-drive.ts` types is the only visible
 * thing this feature does and it is deliberate; this adds nothing to it. The
 * hooks answer over HTTP, and `hook-server.ts`'s `CONTEXT_EVENTS` records which
 * events are withheld from which CLI precisely because Codex prints hook output
 * on screen. Only Claude Code is installed here, and only the three events that
 * carry context.
 */

import { HOOK_MARKER } from '../hooks'
import { SESSION_HEADER, TOKEN_HEADER } from '../hook-server'
import { BRAND } from '../../shared/brand'

/* ------------------------------------------------------ reading the help -- */

/** The flag that carries the hooks. Spelled once. */
export const SETTINGS_FLAG = '--settings'

/**
 * Does this server's own CLI take it?
 *
 * Read out of its `--help` for the reason `honoursMcpConfig` gives about the
 * other flag: a version number would have to be compared against a table in this
 * repository about somebody else's software, wrong the moment either moves.
 *
 * `--setting-sources` is a different flag and does not match — the character
 * after `--setting` is a hyphen there and an `s` here.
 */
export function honoursSettings(help: string): boolean {
  return help.includes(SETTINGS_FLAG)
}

/* ------------------------------------------------------------- the events -- */

/**
 * The three Claude events installed on a server, and why only three.
 *
 * `hooks.ts` installs ten locally, because the other seven move the status dot
 * on a session's tab. A server shell's status does not come from hooks at all —
 * `servers/ipc.ts` reads it off the screen with an `ActivityTracker`, and says
 * why: *"A server shell is read from its screen or it reports nothing."* So an
 * event nothing consumes would be a `curl` spawned over an SSH tunnel, per tool
 * call, for an answer this app throws away.
 *
 * What is left is exactly the set `hook-server.ts` will answer with something:
 *
 *  - `SessionStart` — where it is, and the map. Fires again on `resume`,
 *    `clear` and `compact`, which is every moment a context is rebuilt.
 *  - `UserPromptSubmit` — the standing description, at the top of each turn.
 *  - `PostToolUse` — the mid-turn door, and the whole of requirement 3.
 *    `browser-binding.ts` answers it only in the turn after a window is attached
 *    or detached; every other tool call gets the same empty 204 it always did.
 *
 * Claude Code only. Codex and Gemini have no per-run settings file that can be
 * named on a command line somebody types themselves, which is the same limit
 * `window-drive.ts`'s `WHY_NOT.agent` already states for the browser verbs.
 */
export const BELONG_EVENTS: readonly string[] = ['SessionStart', 'UserPromptSubmit', 'PostToolUse']

/**
 * How long Claude may wait for one of these, in seconds.
 *
 * The same five `hooks.ts` gives the local hooks, and it is doing more work here
 * — a round trip over an SSH tunnel rather than over a unix socket on the same
 * machine. Still enormous for the real traffic: the request is a few hundred
 * bytes each way on a connection that is already up. The `curl` inside is capped
 * at three, so this is never the thing that fires.
 */
export const HOOK_TIMEOUT_S = 5

/**
 * Every opener name shimmed on a server.
 *
 * The same list `open-shim.ts` uses for Linux, plus `open` — which is not a
 * standard Linux command and is exactly why it is here. An agent that learnt
 * `open <url>` on a Mac types it on a server too, and today that is
 * `sh: open: not found` and a page nobody sees. With a shim in front of it the
 * URL lands in the window he is looking at, and everything that is *not* a
 * single http(s) URL falls through to whatever that name did before — which,
 * for `open` on a Linux box, is the same "not found" it always was.
 */
export const OPENER_NAMES: readonly string[] = ['open', 'xdg-open', 'sensible-browser']

/* -------------------------------------------------------------- the files -- */

/** One file to put in the scratch folder, by its path inside it. */
export interface ScratchFile {
  /** Relative to the scratch folder, with `/` separators. */
  path: string
  body: string
  /** `0700` rather than the `0600` `umask 077` already gives it. */
  executable?: boolean
}

export interface BelongInput {
  /** The scratch folder on the server, absolute. Known before any of this. */
  dir: string
  /** The absolute `curl` on that server, from the scout. */
  curl: string
  /** The port on that server's loopback that reaches this app's hook endpoint. */
  port: number
  /** The shell id this app knows this terminal by. Not a secret. */
  sessionId: string
  /** This run's hook-endpoint token. A secret, and it only ever goes in one file. */
  token: string
  /** Absolute path of each real opener on that server, empty where there is none. */
  openers: Readonly<Record<string, string>>
  /** The app's documents, filename → body, or null to write none. */
  pages: Readonly<Record<string, string>> | null
  /** Whether this server's `claude` takes {@link SETTINGS_FLAG}. */
  hooks: boolean
}

/** Where the settings file lands, relative to the scratch folder. */
export const SETTINGS_FILE = 'settings.json'
/** Where the curl config holding the token lands. */
export const HOOK_CONFIG_FILE = 'hook.conf'
/** The one script the hooks run. */
export const POSTER_FILE = 'bin/td-hook'
/** The folder the documents land in, relative to the scratch folder. */
export const CONTEXT_SUBDIR = 'context'

/**
 * Every file the belonging half puts on a server, or an empty list when it
 * cannot.
 *
 * Returns nothing at all rather than a partial set when anything it would have
 * to interpolate is not what it says it is — see {@link plainEnough}. A shim
 * built around a value this module could not vouch for is a script on somebody's
 * `PATH` with a quoting bug in it, which is not a missing feature but every
 * `open` in that terminal behaving strangely.
 */
export function belongFiles(input: BelongInput): ScratchFile[] {
  if (!Number.isInteger(input.port) || input.port <= 0) return []
  if (!plainEnough(input.dir) || !input.dir.startsWith('/')) return []
  if (!plainEnough(input.curl) || !input.curl.startsWith('/')) return []
  if (!plainEnough(input.sessionId)) return []
  if (!/^[0-9a-f]+$/.test(input.token)) return []

  const files: ScratchFile[] = [
    { path: HOOK_CONFIG_FILE, body: hookConfig(input.token) },
  ]

  for (const name of OPENER_NAMES) {
    const real = input.openers[name] ?? ''
    // A real opener that is not an absolute path this module can quote is
    // treated as no opener at all: the shim still routes URLs, and everything
    // else says "not found" exactly as the shell would have.
    const usable = plainEnough(real) && real.startsWith('/') ? real : ''
    files.push({ path: `bin/${name}`, body: openerScript(name, usable, input), executable: true })
  }

  if (input.hooks) {
    files.push({ path: POSTER_FILE, body: posterScript(input), executable: true })
    files.push({ path: SETTINGS_FILE, body: settingsFile(input.dir) })
    for (const [name, body] of Object.entries(input.pages ?? {})) {
      files.push({ path: `${CONTEXT_SUBDIR}/${name}`, body })
    }
  }

  return files
}

/**
 * A value this module is willing to put inside single quotes in a script it
 * writes onto somebody's machine.
 *
 * Deliberately a whitelist rather than an escaper. Every value here is one this
 * app minted or read out of `command -v` on a server, so the ordinary case is
 * boring; and the cost of being wrong is not a failed feature but a `PATH` entry
 * that breaks a command somebody depends on. A refusal is a session with fewer
 * capabilities, which is recoverable, and a broken shim is not.
 */
export function plainEnough(value: string): boolean {
  return value !== '' && /^[A-Za-z0-9 _.,:@+=/-]+$/.test(value)
}

/**
 * The curl config the token lives in, and the only file that holds it.
 *
 * curl's own config syntax, values double-quoted, which is the form
 * `hook-server.ts` already writes for the local hooks — the difference being
 * that this one carries no `unix-socket` line, because on a server the endpoint
 * is a port on that machine's loopback rather than a socket on this one's.
 */
export function hookConfig(token: string): string {
  return [
    `# Written by ${BRAND.name} for this terminal only, and removed when it closes.`,
    `header = "${TOKEN_HEADER}: ${token}"`,
    '',
  ].join('\n')
}

/**
 * The settings layer the wrapper names, holding three hooks and nothing else.
 *
 * One key, deliberately. `--settings` is an additional layer over that account's
 * own settings and this app has no business having an opinion about their model,
 * their permissions or their status line — so the file says one thing.
 *
 * Every command runs {@link POSTER_FILE} rather than spelling `curl` out three
 * times, which is the same call `hook-server.ts` makes about its Windows client:
 * a script this app wrote can read its own configuration and can be fixed in one
 * place, and the entry in the settings file is then a path and a word.
 *
 * The marker rides on the end as a `#` comment. Claude runs a hook command
 * through a shell, so it is stripped before the program is found — and it is what
 * makes an entry recognisably ours in a file somebody might one day open.
 */
export function settingsFile(dir: string): string {
  const poster = `${dir}/${POSTER_FILE}`
  const hooks: Record<string, unknown> = {}
  for (const event of BELONG_EVENTS) {
    hooks[event] = [
      {
        matcher: '',
        hooks: [
          {
            type: 'command',
            command: `${poster} ${event} ${HOOK_MARKER}`,
            timeout: HOOK_TIMEOUT_S,
          },
        ],
      },
    ]
  }
  return `${JSON.stringify({ hooks }, null, 2)}\n`
}

/**
 * The one script the hooks run: read the event on stdin, post it, print the
 * answer.
 *
 * What it has to get right, in the order it goes wrong if it does not — the same
 * list `hook-server.ts` keeps beside its Windows client, because the failure
 * modes belong to the job rather than to the platform:
 *
 *  - **It reads stdin to the end.** `--data-binary @-` is what does that. A hook
 *    that exits without reading leaves the CLI writing into a closed pipe, which
 *    Claude reports as an EPIPE hook failure — in the terminal.
 *  - **It always exits 0.** A hook that fires while the app is gone, or while the
 *    tunnel is down, must be silence rather than an error in somebody's session.
 *  - **It keeps the body.** All three of these events are answered with context,
 *    so unlike three of the five local commands there is no `-o /dev/null` here.
 *    The answer on stdout is what reaches the model.
 *  - **It refuses an event it was not given.** The argument comes from a settings
 *    file this app wrote, so this can only fire if something else runs the
 *    script — and a word off a command line becoming a URL path is not a thing to
 *    leave open.
 */
export function posterScript(input: BelongInput): string {
  return `#!/bin/sh
# Written by ${BRAND.name} for this terminal, and removed when it closes.
${HOOK_MARKER}
#
# Posts one Claude Code hook event back to the app over the port this server
# opened on its own loopback for it. Prints the app's answer, which the CLI reads
# as hook output; nothing is ever written to the terminal.

CURL='${input.curl}'
CONF='${input.dir}/${HOOK_CONFIG_FILE}'
SESSION='${input.sessionId}'
BASE='http://127.0.0.1:${input.port}/hook/claude/'

case "\${1:-}" in
${BELONG_EVENTS.map((event) => `  ${event}) ;;`).join('\n')}
  *) exit 0 ;;
esac

"$CURL" -s \\
  --connect-timeout 1 \\
  --max-time 3 \\
  -X POST \\
  -H 'content-type: application/json' \\
  -H "${SESSION_HEADER}: $SESSION" \\
  -K "$CONF" \\
  --data-binary @- \\
  "$BASE$1" 2>/dev/null

# Whatever happened — no app, no tunnel, a curl that could not read its config —
# this is somebody's session carrying on regardless.
exit 0
`
}

/**
 * One opener, shimmed.
 *
 * ## The order of the branches is the safety case, and it is not negotiable
 *
 * Byte for byte the shape `open-shim.ts` states for the local shim, and for the
 * same reason: this goes on the `PATH` of a terminal somebody is working in.
 *
 *  1. more or fewer than one argument  → the real opener, argv untouched
 *  2. the argument starts with `-`     → the real opener, argv untouched
 *  3. the argument is not `http(s)://` → the real opener, argv untouched
 *  4. otherwise ask the app, and fall back to the real opener on any doubt
 *
 * ## The one line that could brick a terminal
 *
 * `REAL` is a **baked-in absolute literal**, resolved by `command -v` on that
 * server *before* this directory was put on any `PATH`, and it is never a lookup
 * at run time. This directory is first on that shell's `PATH`, so a lookup would
 * find this script, which would exec this script, for ever, on every URL.
 * `open-shim.ts` states the same rule about its own `REAL_OPENER` and it is the
 * one line in either file worth reading twice.
 *
 * ## And when there is no real opener at all
 *
 * Which is the ordinary case for `open` on a Linux server. The fallback then
 * prints what the shell would have printed and exits 127, so `open .` on a box
 * that never had an `open` still says the same thing it said yesterday. What it
 * must never do is exit 0 having opened nothing: Claude maps exit 0 to success
 * and the model will believe it.
 *
 * ## And the sentence at the bottom is different from the local one on purpose
 *
 * The local shim says *"opening it in your default browser"*, which is true on
 * the machine the person is sitting at. Here the fallback opens the page **on
 * the server** — which is the thing he reported as a bug — so the line says so.
 */
export function openerScript(name: string, real: string, input: BelongInput): string {
  return `#!/bin/sh
# Written by ${BRAND.name} for this terminal, and removed when it closes.
# Do not edit: this file is written per terminal and goes with it.
#
# It exists so that a http(s) URL opened by an agent in this shell lands in a
# browser window in the app, instead of opening on this server where nobody is
# looking. Everything else is handed to this machine's own opener untouched.

# Absolute, and never a PATH lookup: the directory this file is in is FIRST on
# this shell's PATH, so a lookup would find this script and exec it for ever.
REAL='${real}'
CURL='${input.curl}'
CONF='${input.dir}/${HOOK_CONFIG_FILE}'
SESSION='${input.sessionId}'
ENDPOINT='http://127.0.0.1:${input.port}/open'

open_for_real() {
  if [ -n "$REAL" ] && [ -x "$REAL" ]; then
    exec "$REAL" "$@"
  fi
  # What the shell itself would have said, and the status it would have said it
  # with. This name never existed on this machine; the shim must not invent it.
  printf '%s\\n' "${name}: not found" >&2
  exit 127
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

# 4. Ask the app, over the port this server opened on its own loopback for it.
# The session id ties this URL to the tab on the other end of that connection;
# the config file holds this run's token, exactly as the hook script reads it.
ANSWER=$(printf '%s' "$1" | "$CURL" -s \\
  --connect-timeout 1 \\
  --max-time 3 \\
  -X POST \\
  -H 'content-type: text/plain' \\
  -H "${SESSION_HEADER}: $SESSION" \\
  -K "$CONF" \\
  --data-binary @- \\
  "$ENDPOINT" 2>/dev/null)

ROUTE=$(printf '%s\\n' "$ANSWER" | head -n 1)
LINE=$(printf '%s\\n' "$ANSWER" | sed -n '2,$p')

if [ "$ROUTE" = "tab" ]; then
  printf '%s\\n' "$LINE"
  exit 0
fi

# Everything else lands here: the app said "system", the app is not running, the
# tunnel is down, curl timed out, or the answer was something this script does
# not understand. All of them mean the same thing to whoever ran the command, and
# all of them say so out loud rather than exiting 0 having done nothing.
if [ -n "$LINE" ]; then
  printf '%s\\n' "$LINE"
else
  printf '%s\\n' "${BRAND.name} did not take this link — opening it on this server instead."
fi
open_for_real "$@"
`
}
