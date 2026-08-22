/**
 * The half of *"a session on a server drives the browser window attached to
 * it"* that has to reach a command line this app did not write.
 *
 * ## The hard part, stated plainly
 *
 * Everywhere else in this app, a session is started by `host-core.ts`, which
 * composes the argv and can fold `--mcp-config <file>` into it
 * (`deck-control/session-tools.ts`). A server shell is not that. It is an SSH
 * pty: `connection.ts` asks for `client.shell()`, the far end runs the account's
 * login shell, and the **person** types `claude` into it. There is no argv for
 * this app to add a flag to, and `--mcp-config` is read once, at exec.
 *
 * Four ways were considered and three were rejected:
 *
 *  1. **`client.shell({ env })`.** SSH can carry environment variables, and
 *     `sshd` accepts almost none of them: `AcceptEnv` on a default OpenSSH is
 *     `LANG LC_*` and nothing else. A mechanism that silently does nothing on
 *     the ordinary configuration is the dead control this whole round is about.
 *  2. **Write it into the account's `~/.bashrc` or `~/.profile`.** That is a
 *     permanent edit to somebody's machine to buy a per-terminal capability,
 *     and it survives this app being uninstalled. §7 of `SERVERS-DESIGN.md`
 *     draws the line: what goes on a server goes there because a person pressed
 *     a button, with a way back, and this is neither.
 *  3. **A project `.mcp.json` in whatever folder the shell lands in.** Claude
 *     Code reads one, and then asks the person to approve it — a dialog inside
 *     the very session that was supposed to already have the tools — and the
 *     file is left in somebody's repository.
 *  4. **A wrapper first on that shell's `PATH`.** Chosen. It is exactly the
 *     shape `open-shim.ts` already uses here for the same class of problem: a
 *     PATH lookup is something this app can answer without the agent knowing,
 *     and the flag is added by the thing that gets looked up.
 *
 * The `PATH` itself is set by **typing the line into the shell**, which is the
 * precedent `connection.ts` set for `startIn`: SSH has no "start here" either,
 * so the app types the `cd` a person would have typed. The line is echoed by the
 * far end and sits in the scrollback where it can be read, which is the honest
 * property rather than an accepted cost — nothing about this is hidden from the
 * person whose machine it is.
 *
 * ## What was checked rather than assumed
 *
 * That the CLI on **that** server takes the flag. Not the one on this Mac —
 * `--mcp-config` is a Claude Code flag and the version on somebody's Ubuntu box
 * may predate it — so {@link honoursMcpConfig} reads that machine's own
 * `claude --help`, and a server whose CLI does not list the flag is told so
 * instead of being handed a wrapper that makes every invocation fail.
 *
 * The same read answers the second question. `claude mcp list`, `claude doctor`
 * and `claude update` are **subcommands**, and a subcommand handed
 * `--mcp-config` fails on an unknown option. So the wrapper passes those through
 * untouched, and the list of which words those are comes from that server's own
 * help output rather than from a list baked in here that would be wrong the
 * first time a subcommand is added.
 *
 * ## And which agents this cannot reach, said out loud
 *
 * One. `--mcp-config` is Claude Code's; Codex and Gemini have no per-run MCP
 * override that can be put on a command line, so there is nothing for a wrapper
 * to add. A shell on a server where only those are installed gets no wrapper and
 * {@link WHY_NOT.agent} is the sentence that says why. `session-verbs.ts`'s
 * `provider` reason makes the same distinction for a local session and is worth
 * reading beside this: the honest answer to *"we cannot give this one the
 * verbs"* is always to say so, because an agent told merely that something did
 * not work goes looking for another way in.
 *
 * ## And the second half, added when the same shell turned out not to know where
 * it was
 *
 * The wrapper above is about *verbs*. It is not the only thing an SSH shell is
 * missing, and the other two came back as one complaint:
 *
 * > *"server session is still opening browser in where its based like inside the
 * > server not in the app, and dont get to know about terminal deck until we talk
 * > about it, and dont get to know about browser connection even if we connect it
 * > manually."*
 *
 * Same root: no `open` shim and no hooks, because both of those are things
 * `host-core.ts` arranges for a session it starts and nobody arranges for a shell
 * a person types into. Both are answered by the same directory this file already
 * puts first on that shell's `PATH`, and `window-belong.ts` is what goes in it.
 * The only thing that changes here is that the folder now holds more than two
 * files, and that filling it is a second round trip — see {@link scoutScript} for
 * why that is a simplification rather than a cost.
 *
 * The two halves fail apart on purpose. A server with no `curl`, or a `claude`
 * too old for `--settings`, still gets a terminal and still gets the browser
 * verbs; what it does not get is claimed nowhere, in the app or in the agent's
 * own context.
 *
 * ## No `ssh2` here either
 *
 * `host-key-checked.test.ts` walks this folder and fails the build if anything
 * but `connection.ts` reaches the transport. Everything below is text and
 * promises; the connection arrives as functions.
 */

import type { RemoteAppContext } from '../app-context'
import type { AgentFact } from './facts'
import type { PreparedElsewhere } from '../deck-control/session-tools'
import {
  CONTEXT_SUBDIR,
  OPENER_NAMES,
  SETTINGS_FILE,
  SETTINGS_FLAG,
  belongFiles,
  honoursSettings,
  type ScratchFile,
} from './window-belong'
import type { ReachResult, WindowReach } from './window-reach'

/* ------------------------------------------------------ reading the help -- */

/** The flag the whole mechanism rests on. Spelled once. */
export const MCP_FLAG = '--mcp-config'

/**
 * Does this server's own CLI take the flag?
 *
 * Read out of its `--help` rather than out of a version number, because a
 * version number would have to be compared against a table of which release
 * added it — a table in this repository about somebody else's software, wrong
 * the moment either moves.
 */
export function honoursMcpConfig(help: string): boolean {
  return help.includes(MCP_FLAG)
}

/**
 * The subcommand words in a `--help`, or an empty list when there is no
 * `Commands:` section to read.
 *
 * Deliberately conservative in what it accepts: a word of lowercase letters,
 * digits and hyphens, at the start of an indented line, in the block after
 * `Commands:`. Aliases printed as `plugin|plugins` are both taken. Anything
 * else — a heading, a wrapped description, a line with a bracket in it — is not
 * a subcommand and is skipped, because the cost of a wrong word here is a
 * `claude` invocation that silently loses its flag.
 */
export function subcommandsFrom(help: string): string[] {
  const lines = help.split('\n')
  const start = lines.findIndex((line) => /^commands:\s*$/i.test(line.trim()))
  if (start === -1) return []
  const found = new Set<string>()
  for (const line of lines.slice(start + 1)) {
    // A line with no leading space has left the block: the next heading, or the
    // end of the output.
    if (line.trim() !== '' && !/^\s/.test(line)) break
    const head = /^\s{1,4}([a-z][a-z0-9|-]*)(\s|$)/.exec(line)
    if (head === null) continue
    for (const word of head[1].split('|')) {
      if (/^[a-z][a-z0-9-]*$/.test(word)) found.add(word)
    }
  }
  return [...found].sort()
}

/* --------------------------------------------------- what is put on there -- */

/**
 * Where the scratch folder is made, and the shape of its name.
 *
 * `/tmp` and `mktemp -d`, exactly as `setup.ts`'s sign-in scratch does, for the
 * three reasons that file gives: the account always has it, `mktemp` cannot
 * collide with a second terminal on the same box, and `0700` on a machine with
 * three home folders on it keeps the other two out. The prefix is this app's so
 * that a folder left behind by a link that died can be recognised.
 */
export const SCRATCH_PREFIX = '/tmp/td-drive-'

/**
 * The mark the scout prints before its answers.
 *
 * A sentinel rather than counting lines back from the end, because the number of
 * answers grew once already: it was the folder and the login shell, and it is now
 * those plus `curl` and every opener name. Counting from the end works and goes
 * quietly wrong the next time something is added to the list, which is the shape
 * of bug this whole round is about.
 */
export const SCOUT_MARK = 'TD_SCOUTED'

/**
 * Make the folder, and measure the machine everything else is composed against.
 *
 * ## Why this is a round trip of its own, and the wrapper is not in it
 *
 * It used to write the files as well, and the price was a heredoc that had to be
 * *unquoted* so the far end could expand the folder `mktemp` had just chosen —
 * with every `$`, backtick and backslash in everything it wrote suddenly
 * meaningful. That was survivable for one JSON file. It is not survivable for a
 * settings file, three shim scripts and three Markdown documents full of code
 * spans, and the failure mode is a script on somebody's `PATH` with a mangled
 * line in it.
 *
 * So the folder is chosen first and *answered*, and {@link armScript} then writes
 * every file with the path already in it, in quoted heredocs that expand nothing.
 * One extra round trip on a connection that is already up, in exchange for there
 * being no shell expansion anywhere in the bytes this app puts on somebody's
 * server.
 *
 * ## What it measures, and why here
 *
 * All of it is free — the connection is open and the answers are one `command -v`
 * each — and all of it has to be known *before* anything is composed:
 *
 *  - **The login shell.** `sshd` exports `$SHELL` from that account's passwd
 *    entry, so it is already in this script's environment. It decides whether
 *    the `PATH` line can be typed at all; see {@link takesAnExportLine}.
 *  - **`curl`.** Everything in `window-belong.ts` is a `curl` — the hooks and
 *    the `open` shim both — and a server without one gets neither rather than
 *    scripts that fail on every call.
 *  - **Each opener.** The shim needs the *absolute* path of the thing it falls
 *    back to, resolved now, while this directory is nowhere near any `PATH`.
 *    `open-shim.ts` states the rule at length: a `PATH` lookup at run time would
 *    find the shim, which would exec the shim, for ever.
 *
 * An answer that is not an absolute path, or that has a quote in it, is returned
 * as nothing at all. `command -v` answers with a bare word for a builtin and with
 * nothing for a program that is not there, and neither is something to bake into
 * a script.
 */
export function scoutScript(): string {
  return [
    'umask 077',
    `d=$(mktemp -d ${SCRATCH_PREFIX}XXXXXX) || exit 1`,
    'chmod 700 "$d" || exit 1',
    'mkdir "$d/bin" || exit 1',
    // One program, absolutely, or an empty line. Never a builtin, never a
    // relative word, and never anything this app would have to escape.
    'found() {',
    '  v=$(command -v "$1" 2>/dev/null) || v=',
    '  case "$v" in /*) ;; *) v= ;; esac',
    `  case "$v" in *"'"*) v= ;; esac`,
    "  printf '%s\\n' \"$v\"",
    '}',
    `printf '%s\\n' '${SCOUT_MARK}' "$d" "\${SHELL:-}"`,
    'found curl',
    ...OPENER_NAMES.map((name) => `found ${name}`),
  ].join('\n')
}

/** What {@link scoutScript} answered. */
export interface Scouted {
  /** The folder it made, or `''` when the answer was not one of ours. */
  dir: string
  /** The account's login shell, or `''` when its passwd entry names none. */
  shell: string
  /** Absolute `curl` on that server, or `''` when it has none. */
  curl: string
  /** Absolute path of each opener in {@link OPENER_NAMES}, `''` where absent. */
  openers: Readonly<Record<string, string>>
}

/**
 * Read the scout's answers, past whatever a `.profile` printed before them.
 *
 * Found by {@link SCOUT_MARK} rather than by position, and by the **last** one:
 * a login file that echoed the mark itself would otherwise be read as the start
 * of the answers, and the real answers are always the ones at the end.
 */
export function readScouted(stdout: string): Scouted {
  const lines = stdout.split('\n').map((line) => line.replace(/\r$/, '').trim())
  const at = lines.lastIndexOf(SCOUT_MARK)
  const take = (offset: number): string => (at === -1 ? '' : (lines[at + offset] ?? ''))
  const openers: Record<string, string> = {}
  OPENER_NAMES.forEach((name, index) => {
    openers[name] = take(4 + index)
  })
  return { dir: take(1), shell: take(2), curl: take(3), openers }
}

/**
 * Write every file into a folder the far end already made and already named.
 *
 * ## Why every heredoc here is quoted
 *
 * Because there is nothing left for the shell to fill in. The folder came back
 * from {@link scoutScript}, so every path in every file is already a literal by
 * the time this is composed — which means the far end can be told to expand
 * *nothing*, and a backtick in a Markdown code span, a `$1` in a shim and a
 * backslash in a JSON string all reach the file as written. `umask 077` before
 * anything is written is what makes each of them `0600` from the instant it
 * exists rather than a `chmod` later that chases a window it cannot close.
 *
 * ## And why it refuses rather than escapes
 *
 * The guard on `$d` is `disarmScript`'s, and the guard on each path is the same
 * idea one level down: these become filenames inside a double-quoted word on
 * somebody's machine, so a path this module cannot vouch for is a throw rather
 * than a clever quoting rule. Every caller is inside `arm`'s `try`, where a throw
 * is already a refusal with the folder taken back.
 */
export function armScript(input: { dir: string; files: readonly ScratchFile[] }): string {
  const lines = [
    `d='${singleQuote(input.dir)}'`,
    `case "$d" in ${SCRATCH_PREFIX}??????) ;; *) exit 1 ;; esac`,
    'umask 077',
  ]

  const folders = new Set<string>()
  for (const file of input.files) {
    if (!/^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/.test(file.path)) {
      throw new Error(`window-drive: refusing to write ${file.path}`)
    }
    const slash = file.path.lastIndexOf('/')
    if (slash > 0) folders.add(file.path.slice(0, slash))
  }
  for (const folder of [...folders].sort()) lines.push(`mkdir -p "$d/${folder}" || exit 1`)

  input.files.forEach((file, index) => {
    const tag = `TD_FILE_${index}`
    const body = file.body.replace(/\n+$/, '')
    // A file whose own text contains the delimiter would end its heredoc early
    // and leave the rest of it running as shell. It cannot happen with anything
    // this app composes, and it is not a thing to find out about later.
    if (body.split('\n').includes(tag)) throw new Error(`window-drive: ${file.path} contains ${tag}`)
    lines.push(`cat > "$d/${file.path}" <<'${tag}'`, body, tag)
    if (file.executable) lines.push(`chmod 700 "$d/${file.path}" || exit 1`)
  })

  lines.push('exit 0')
  return lines.join('\n')
}

/**
 * The login shells the `export` line below is true in.
 *
 * Measured by syntax rather than by popularity: every one of these is a Bourne
 * descendant where `export NAME=value` is a statement. `fish` and the `csh`
 * family are the two real shells where it is not — `fish` has no `export`
 * builtin at all and `csh` spells it `setenv` — and neither is silently wrong:
 * a shell that does not understand the line prints an error into the terminal
 * somebody is working in, and *that* is the outcome this list exists to avoid.
 *
 * They are refused rather than translated. Writing `set -gx` and `setenv`
 * branches would be three syntaxes to keep correct against two shells that
 * almost never appear on a server, and a wrong branch fails in the same visible,
 * confusing way as no branch at all. Naming the shell in a sentence is the
 * honest version of not supporting it.
 */
const BOURNE_SHELLS: ReadonlySet<string> = new Set([
  'sh',
  'bash',
  'zsh',
  'ksh',
  'ksh93',
  'mksh',
  'dash',
  'ash',
  'busybox',
])

/** Is `export NAME=value` a statement in this account's login shell? */
export function takesAnExportLine(shell: string): boolean {
  const name = shell.split('/').pop() ?? ''
  // An account whose passwd entry names no shell gets `/bin/sh`, which is the
  // one shell every one of these systems has and is on the list above.
  if (name === '') return true
  return BOURNE_SHELLS.has(name)
}

/**
 * The wrapper, whole.
 *
 * ## The order of the branches is the safety case
 *
 * The same shape `open-shim.ts` states for its own script, and for the same
 * reason — this goes on the `PATH` of a terminal somebody is working in, and a
 * wrapper that breaks an ordinary invocation is worse than no wrapper at all:
 *
 *  1. **no arguments, or a first argument that is a flag** → add the flags.
 *     `claude`, `claude -c`, `claude --resume`, `claude -p "…"`.
 *  2. **a first argument that this server's own help listed as a subcommand** →
 *     exec untouched. `claude mcp list`, `claude update`, `claude doctor`.
 *  3. **anything else** → a prompt, so add the flags. `claude "fix the build"`.
 *
 * ## The one line that could brick a terminal
 *
 * `REAL` is a **baked-in absolute path**, taken from the probe's `command -v`,
 * and it is never a `PATH` lookup. The directory this script sits in is *first*
 * on that shell's `PATH`, so a lookup would find this script, which would exec
 * this script, for ever. `open-shim.ts` states the same rule about its own
 * `REAL_OPENER` and it is the one line in either file that is worth reading
 * twice.
 *
 * ## Two flags now, and the second is optional twice over
 *
 * `--mcp-config` is what gives the agent this app's browser verbs, and it is why
 * this wrapper exists at all. {@link SETTINGS_FLAG} is what gives it the hooks
 * that tell it where it is and what has just been attached to it
 * (`window-belong.ts`), and it is added only when **both** are true: this
 * server's own `--help` listed the flag, and the settings file it would name was
 * actually written. A flag naming a file that is not there is a `claude` that
 * refuses to start, which is the one failure this whole file is careful about.
 *
 * Every path in here is a literal, because {@link scoutScript} already answered
 * with the folder. Nothing in this script is expanded when it is written.
 */
export function wrapperScript(input: {
  /** Absolute `claude` on that server. */
  real: string
  /** That server's own subcommands, from its own `--help`. */
  subcommands: readonly string[]
  /** Absolute path of the MCP config beside it. */
  config: string
  /** Absolute path of the settings file, or null when there is none. */
  settings: string | null
}): string {
  const safe = input.subcommands.filter((word) => /^[a-z][a-z0-9-]*$/.test(word))
  const lines = [
    '#!/bin/sh',
    '# Written by this app when the terminal it is on was opened, and removed when',
    '# that terminal closes. It adds one or two flags to `claude` so that the agent',
    '# in this shell can act on the browser windows attached to this session and can',
    '# be told what it is running inside. It changes nothing else about how `claude`',
    '# runs.',
    '#',
    '# Absolute, and never a PATH lookup: the directory this file is in is FIRST on',
    "# this shell's PATH, so a lookup would find this script and exec it for ever.",
    `REAL='${singleQuote(input.real)}'`,
    `CONFIG='${singleQuote(input.config)}'`,
    ...(input.settings === null ? [] : [`SETTINGS='${singleQuote(input.settings)}'`]),
    '',
    '# A subcommand does not take these flags and would fail on them. This list is',
    "# what this machine's own `claude --help` printed when the terminal opened.",
    'case "${1:-}" in',
  ]
  if (safe.length > 0) lines.push(`  ${safe.join('|')}) exec "$REAL" "$@" ;;`)
  lines.push('  *) ;;', 'esac', '')
  if (input.settings === null) {
    lines.push(`exec "$REAL" ${MCP_FLAG} "$CONFIG" "$@"`)
  } else {
    // Tested rather than assumed, because the folder can be taken back while a
    // shell is still open — an unticked switch does exactly that — and a flag
    // naming a file that has gone is every `claude` in this terminal refusing to
    // start rather than one capability quietly missing.
    lines.push(
      'if [ -f "$SETTINGS" ]; then',
      `  exec "$REAL" ${MCP_FLAG} "$CONFIG" ${SETTINGS_FLAG} "$SETTINGS" "$@"`,
      'fi',
      `exec "$REAL" ${MCP_FLAG} "$CONFIG" "$@"`,
    )
  }
  return lines.join('\n')
}

/**
 * The line typed into the shell, and the comment that says what it is.
 *
 * A `#` comment on the same line is echoed with it and ignored by the shell, so
 * the scrollback carries its own explanation rather than an unexplained path.
 * The person is looking at this terminal; a line they cannot account for in it
 * is a worse outcome than a line that is three words longer.
 */
export function pathLine(dir: string): string {
  // Bourne syntax, and {@link takesAnExportLine} is what makes that true rather
  // than assumed: `fish` and `csh` would print an error into the terminal
  // somebody is working in, so they are refused before this is ever composed.

  return (
    `export PATH='${singleQuote(dir)}/bin':$PATH ` +
    // Widened when the folder grew an `open` shim beside the `claude` wrapper.
    // The line is the one thing this feature does that he can see, so what it
    // says has to cover everything it buys rather than the half it bought first.
    '# so what runs here can reach the browser windows you attach to this terminal\n'
  )
}

/**
 * The way back, and it removes exactly what was added.
 *
 * The guard is `removeScript`'s in `setup.ts`, narrowed: this may only ever
 * delete a path that is one of *our own* scratch folders, so a caller that
 * somehow arrived with a different string deletes nothing at all.
 */
export function disarmScript(dir: string): string {
  return [
    `p='${singleQuote(dir)}'`,
    `case "$p" in ${SCRATCH_PREFIX}??????) ;; *) exit 1 ;; esac`,
    'rm -rf "$p"',
    'exit 0',
  ].join('\n')
}

/** A value going inside single quotes in a generated script. */
function singleQuote(value: string): string {
  return value.split("'").join("'\\''")
}

/* ------------------------------------------------- why one could not be armed -- */

/**
 * Every reason a server shell is opened without the verbs, in this app's words.
 *
 * A closed set for the reason `NoVerbsReason` in `session-verbs.ts` is one:
 * these become sentences a person reads beside a menu row, and a caller
 * composing its own would be a second place that has to know how this app talks
 * about itself.
 */
export const WHY_NOT = Object.freeze({
  'not-allowed':
    'acting on browser windows here has been turned off for this server. The switch is under ' +
    'Advanced on its page — it is on for every server you add unless somebody unticks it.',
  agent:
    'this app can only add its browser verbs to Claude Code, and this server has no `claude` this ' +
    'sign-in can run. Codex and Gemini have no per-run setting that could be added to a command line ' +
    'somebody types themselves.',
  flag:
    'the `claude` on this server is too old to take the setting this needs (`--mcp-config`). Updating ' +
    'it on that machine is the only way in.',
  endpoint: 'this app’s control endpoint is not running here yet.',
  shell:
    'this app can only add its browser verbs to a terminal running a Bourne shell — `sh`, `bash`, ' +
    '`zsh` and their relatives. The sign-in on this server lands in a shell that spells things ' +
    'differently, and a line written the wrong way would print an error into the terminal rather ' +
    'than do anything.',
} as const)

export type WhyNot = keyof typeof WHY_NOT

/** What a shell was given, or the sentence saying why it was given nothing. */
export type ArmOutcome =
  | { ok: true; line: string }
  | { ok: false; why: string }

/* ------------------------------------------------------------ the coordinator -- */

export interface WindowDriveDeps {
  /** Is the switch beside this server on? Asked every time, never captured. */
  allowed(serverId: string): boolean
  /** What the probe found. Cached by the caller; this asks once per shell. */
  claudeOn(serverId: string): Promise<AgentFact | null>
  /** Run one command, given as its parts. `ServerConnections.run`. */
  run(serverId: string, argv: readonly string[]): Promise<{ stdout: string; stderr: string }>
  /** Run one script on the far end's standard input. `ServerConnections.runScript`. */
  runScript(serverId: string, script: string): Promise<{ stdout: string }>
  /**
   * A port on that server's loopback that reaches one of this app's endpoints,
   * opened on first use and reference-counted. See `window-reach.ts`.
   *
   * Two kinds because there are two endpoints and they are separate listeners:
   * `control` is `deck-control`, which serves the browser verbs, and `hooks` is
   * the hook endpoint, which serves the `open` route and every answer an agent's
   * hooks are given. `hook-server.ts` opens with the post-mortem of the version
   * where those were one thing.
   */
  reach(serverId: string, kind: ReachKind): Promise<ReachResult>
  /** Let go of one reference to one of those reaches. */
  letGo(serverId: string, kind: ReachKind): void
  /** A token and a caller for a session this process will never see. */
  mint(grant: { allowed(): boolean }): PreparedElsewhere | null
  /**
   * This run's hook endpoint, or null when it is not running.
   *
   * Only the token, and only because a `curl` on somebody's server has to
   * present one. Null is an ordinary state — the endpoint binds a moment after
   * the window is built — and it means the belonging half is simply not arranged
   * for this terminal.
   */
  hookEndpoint?(): { token: string } | null
  /**
   * The documents and the map a session on this server should be given, or null
   * when this build has none to compose.
   *
   * `app-context.ts` owns the text. This only asks for it, per server, because
   * the pages name the server and say where the app itself is running — and
   * because `opensInApp` is a claim about what this particular arm just managed
   * to put on that shell's `PATH`.
   */
  remoteContext?(serverId: string, opensInApp: boolean): RemoteAppContext | null
}

/** Which of this app's two endpoints a reach leads to. */
export type ReachKind = 'control' | 'hooks'

/**
 * What a session in one shell should be told about where it is, beyond the
 * standing description `browser-binding.ts` composes.
 *
 * Null from {@link WindowDrives.belonging} covers two states on purpose — a
 * shell whose belonging half could not be arranged, and a shell this object has
 * never heard of — because both want the same answer at the call site: fall back
 * to what a local session is told, which for an id this app did not start is
 * nothing at all.
 */
export interface Belonging {
  /**
   * The map naming the documents **on that server**, or null when no hooks were
   * installed and so nothing would ever read it.
   *
   * Never this Mac's map. `<userData>/context/INDEX.md` is a path that does not
   * exist over there, and handing it over would be this app telling an agent to
   * read a file it cannot open.
   */
  map: string | null
  /** Whether this app's `open` really is first on that shell's `PATH`. */
  opensInApp: boolean
}

/**
 * Which shells were armed and which were not, and the one sentence each of the
 * second kind gets.
 *
 * Held here rather than in `ipc.ts` so the whole decision is exercisable with a
 * plain object — the same argument `servers/grants.ts` makes about itself, and
 * the reason this is a class with injected everything rather than four calls
 * inlined into an IPC handler.
 */
export class WindowDrives {
  private readonly armed = new Map<
    string,
    {
      serverId: string
      dir: string
      minted: PreparedElsewhere
      /** Whether this shell is holding a reference to the hook reach as well. */
      hooks: boolean
      /** What it should be told about where it is, or null. */
      belonging: Belonging | null
    }
  >()
  /** shellId → why it has no verbs. Absent means it has them, or is not ours. */
  private readonly withheld = new Map<string, string>()

  constructor(private readonly deps: WindowDriveDeps) {}

  /**
   * Give one shell the verbs and, when it can be arranged, a sense of where it
   * is. Never throws.
   *
   * Called **before** the shell is opened rather than after, which costs a few
   * hundred milliseconds on the first terminal for a server and is the whole
   * point: the `PATH` line has to be the first thing in that shell, or there is
   * a window in which the person types `claude` and gets a session that quietly
   * cannot see. `session-verbs.ts` is a page about that exact failure.
   *
   * ## Two halves, and only the first can refuse
   *
   * The **control half** — a token, `deck-control`'s reach and the `--mcp-config`
   * the wrapper adds — is what the switch beside this server is about, and every
   * way it can fail already has a sentence in {@link WHY_NOT}. It is unchanged.
   *
   * The **belonging half** — the `open` shim, the hooks and the documents
   * (`window-belong.ts`) — is added on top and is silent when it cannot happen.
   * That is deliberate: a server with no `curl`, or a `claude` too old for
   * {@link SETTINGS_FLAG}, still gets a terminal and still gets the browser
   * verbs, and nothing on screen claims otherwise. What is *never* silent is the
   * consequence — `opensInApp` on {@link Belonging} is what this arm actually
   * managed, so the documents and the boot description say the true thing rather
   * than the hoped one.
   */
  async arm(serverId: string, shellId: string): Promise<ArmOutcome> {
    const refuse = (why: string): ArmOutcome => {
      this.withheld.set(shellId, why)
      return { ok: false, why }
    }
    if (!this.deps.allowed(serverId)) return refuse(WHY_NOT['not-allowed'])

    let claude: AgentFact | null
    try {
      claude = await this.deps.claudeOn(serverId)
    } catch {
      claude = null
    }
    if (claude === null || claude.path === '') return refuse(WHY_NOT.agent)

    let help = ''
    try {
      const answer = await this.deps.run(serverId, [claude.path, '--help'])
      help = `${answer.stdout}\n${answer.stderr}`
    } catch {
      // A CLI that will not even print its help is one this app cannot reason
      // about. `agent` rather than `flag`, because "found and will not start"
      // is what the probe already calls not having it — see `probe.sh.ts`.
      return refuse(WHY_NOT.agent)
    }
    if (!honoursMcpConfig(help)) return refuse(WHY_NOT.flag)

    const minted = this.deps.mint({ allowed: () => this.deps.allowed(serverId) })
    if (minted === null) return refuse(WHY_NOT.endpoint)

    const reach = await this.deps.reach(serverId, 'control')
    if (!reach.ok) {
      minted.drop()
      return refuse(reach.message)
    }

    let scouted: Scouted
    try {
      scouted = readScouted((await this.deps.runScript(serverId, scoutScript())).stdout)
    } catch {
      minted.drop()
      this.deps.letGo(serverId, 'control')
      return refuse('this app could not make a folder of its own on that server.')
    }
    const dir = scouted.dir

    /** Give everything back, including what is now on the far end. */
    let holdingHooks = false
    const undo = (why: string): ArmOutcome => {
      minted.drop()
      this.deps.letGo(serverId, 'control')
      if (holdingHooks) this.deps.letGo(serverId, 'hooks')
      if (dir.startsWith(SCRATCH_PREFIX)) {
        void this.deps.runScript(serverId, disarmScript(dir)).catch(() => undefined)
      }
      return refuse(why)
    }
    if (!dir.startsWith(SCRATCH_PREFIX)) {
      return undo('that server did not answer with a folder this app could use.')
    }
    /*
     * The last question of the control half, and it is asked after the folder
     * rather than before because the answer arrives with it for free — `sshd`
     * exports `$SHELL` into the scout's own environment. A shell that cannot
     * take the line is a refusal with the folder removed, not a line typed
     * hopefully.
     */
    if (!takesAnExportLine(scouted.shell)) return undo(WHY_NOT.shell)

    /* ------------------------------------------ and now the belonging half -- */

    let belonging: Belonging | null = null
    let settingsPath: string | null = null
    let extras: ScratchFile[] = []
    const endpoint = this.deps.hookEndpoint?.() ?? null
    if (scouted.curl !== '' && endpoint !== null) {
      const hookReach = await this.deps.reach(serverId, 'hooks')
      if (hookReach.ok) {
        holdingHooks = true
        // Two flags, two questions. `--mcp-config` was already required above;
        // this one decides only whether the hooks can be installed at all, and a
        // server that cannot take it still gets the `open` shim.
        const withHooks = honoursSettings(help)
        /*
         * `true` before the files are written, and it is not a guess: the
         * openers are the one thing `belongFiles` always writes when it writes
         * anything at all, so the pages are either composed beside a shim that
         * exists or thrown away with everything else a few lines below.
         */
        const remote = withHooks ? (this.deps.remoteContext?.(serverId, true) ?? null) : null
        extras = belongFiles({
          dir,
          curl: scouted.curl,
          port: hookReach.reach.port,
          sessionId: shellId,
          token: endpoint.token,
          openers: scouted.openers,
          pages: remote?.pages ?? null,
          hooks: withHooks,
        })
        if (extras.length === 0) {
          // Something this module would have had to interpolate was not what it
          // said it was. Nothing half-written goes on somebody's PATH.
          this.deps.letGo(serverId, 'hooks')
          holdingHooks = false
        } else {
          if (withHooks) settingsPath = `${dir}/${SETTINGS_FILE}`
          belonging = {
            map: remote === null ? null : remote.mapFor(`${dir}/${CONTEXT_SUBDIR}`),
            opensInApp: true,
          }
        }
      }
    }

    /* ------------------------------------------------- everything, written -- */

    try {
      const config = `${dir}/deck-control.json`
      await this.deps.runScript(
        serverId,
        armScript({
          dir,
          files: [
            {
              path: 'deck-control.json',
              // The address is the *server's* view of this endpoint: its own
              // loopback, on the port it chose. See `window-reach.ts` for why
              // that keeps the endpoint's own loopback rule true on both
              // machines.
              body: minted.configFor(`http://127.0.0.1:${reach.reach.port}/mcp`),
            },
            ...extras,
            /*
             * The wrapper is written **last**, and that ordering is the one that
             * matters: it names the settings file, so it must not exist before
             * the file it points at. A `cat` that failed halfway leaves a folder
             * with no `bin/claude` in it, which is a terminal with no wrapper —
             * recoverable — rather than a wrapper naming a file that is not
             * there, which is a `claude` that refuses to start.
             */
            {
              path: 'bin/claude',
              body: wrapperScript({
                real: claude.path,
                subcommands: subcommandsFrom(help),
                config,
                settings: settingsPath,
              }),
              executable: true,
            },
          ],
        }),
      )
    } catch {
      return undo('this app could not put the files it needs on that server.')
    }

    // Bound only now, and to the server rather than to this machine: the binding
    // map keys a window `<serverId>\0<shellId>`, so the caller has to carry the
    // server where a machine id goes or every one of its verbs would look for a
    // window on this computer. See `browser-binding.ts`.
    minted.started(shellId, serverId)
    this.armed.set(shellId, { serverId, dir, minted, hooks: holdingHooks, belonging })
    this.withheld.delete(shellId)
    return { ok: true, line: pathLine(dir) }
  }

  /**
   * What a session in this shell should be told about where it is, or null.
   *
   * Read by `index.ts` when a hook from that shell arrives, because it is the
   * one place that knows two things `app-context.ts` and `browser-binding.ts`
   * cannot: that this session is on a server at all, and what this app actually
   * managed to put on its `PATH`.
   */
  belonging(shellId: string): Belonging | null {
    return this.armed.get(shellId)?.belonging ?? null
  }

  /**
   * The shell has gone. The token stops working, the folder goes, and both
   * reaches are let go of.
   *
   * The token is dropped **first**, and that ordering is the one that matters: a
   * removal that failed on the far end would otherwise leave a config file
   * naming a token that still worked.
   *
   * The folder is the way back for everything, not just for the MCP config: the
   * `open` shim, the settings file holding the hooks, the curl config holding
   * this run's hook token and the documents are all inside it, and `rm -rf` on it
   * is what makes this app's whole footprint on somebody's server one directory
   * with a way back. Nothing was written into that account's home, so there is
   * nothing else to undo.
   */
  disarm(shellId: string): void {
    this.withheld.delete(shellId)
    const entry = this.armed.get(shellId)
    if (entry === undefined) return
    this.armed.delete(shellId)
    entry.minted.drop()
    this.deps.letGo(entry.serverId, 'control')
    if (entry.hooks) this.deps.letGo(entry.serverId, 'hooks')
    void this.deps
      .runScript(entry.serverId, disarmScript(entry.dir))
      .catch(() => undefined)
  }

  /**
   * Every shell on one server loses the verbs, now.
   *
   * This is what unticking the switch does, and it is deliberately more than the
   * per-call check in `session-tools.ts`: that one makes the next tool call
   * refuse, this one takes the token away entirely. `ServerGrants` argues for
   * exactly this doubling — one guards the grant existing, one guards it being
   * used, and a hole in either is a hole.
   */
  revoke(serverId: string): void {
    for (const [shellId, entry] of [...this.armed]) {
      if (entry.serverId !== serverId) continue
      this.disarm(shellId)
      this.withheld.set(shellId, WHY_NOT['not-allowed'])
    }
  }

  /**
   * Why this shell cannot drive a browser window, or null when it can.
   *
   * Null covers two states on purpose — a shell that was armed and a shell this
   * object has never heard of — because the honest thing to say about the second
   * is nothing. What earns a sentence is the case where this app positively
   * knows the row a person is about to press has nothing behind it.
   */
  whyNot(shellId: string): string | null {
    return this.withheld.get(shellId) ?? null
  }

  /** Test seam, and shutdown: let go of everything. */
  stop(): void {
    for (const shellId of [...this.armed.keys()]) this.disarm(shellId)
    this.withheld.clear()
  }
}

export type { WindowReach }
