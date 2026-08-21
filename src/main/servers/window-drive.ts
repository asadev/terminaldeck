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
 * ## No `ssh2` here either
 *
 * `host-key-checked.test.ts` walks this folder and fails the build if anything
 * but `connection.ts` reaches the transport. Everything below is text and
 * promises; the connection arrives as functions.
 */

import type { AgentFact } from './facts'
import type { PreparedElsewhere } from '../deck-control/session-tools'
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
 * The script that lands the config and the wrapper, and prints where.
 *
 * ## Why a script on standard input and not files over SFTP
 *
 * Because one of the two files is a **bearer token**. `connection.ts`'s
 * `runScript` hands the whole text to `sh -s` on the far end's standard input,
 * which is the door it opened precisely so that a command line does not appear
 * in that machine's process list where anybody signed into it can read it. SFTP
 * would work for the bytes and would then need a second round trip to `chmod`
 * the result, leaving a window in which the file exists and is readable.
 *
 * `umask 077` before anything is written closes that window instead of chasing
 * it: every file this creates is `0600` from the instant it exists, inside a
 * directory that is `0700`.
 *
 * ## Why the config path is interpolated by the shell and everything else by us
 *
 * The directory is chosen by `mktemp` on the far end, so only the shell knows
 * it — hence the one unquoted heredoc, which expands `$d` and nothing else,
 * because the line it contains is fixed text with no other `$` in it. The
 * wrapper's body is a quoted heredoc, so nothing in it is expanded at write
 * time and every `$1`, `$@` and `$REAL` reaches the file as written.
 */
export function armScript(input: {
  /** The whole config file, as `PreparedElsewhere.configFor` composed it. */
  config: string
  /** The absolute path of `claude` on that server, from the probe. */
  real: string
  /** That server's own subcommands, from its own `--help`. */
  subcommands: readonly string[]
}): string {
  return [
    'umask 077',
    `d=$(mktemp -d ${SCRATCH_PREFIX}XXXXXX) || exit 1`,
    'chmod 700 "$d" || exit 1',
    'mkdir "$d/bin" || exit 1',
    "cat > \"$d/deck-control.json\" <<'TD_CONFIG'",
    input.config.replace(/\n+$/, ''),
    'TD_CONFIG',
    'cat > "$d/bin/claude" <<TD_HEAD',
    '#!/bin/sh',
    'CONFIG="$d/deck-control.json"',
    'TD_HEAD',
    "cat >> \"$d/bin/claude\" <<'TD_BODY'",
    wrapperBody(input.real, input.subcommands),
    'TD_BODY',
    'chmod 700 "$d/bin/claude" || exit 1',
    /*
     * Two lines: where it landed, and which shell the person is about to be
     * dropped into.
     *
     * The second is asked here rather than in a round trip of its own because it
     * is free — `sshd` exports `$SHELL` from that account's passwd entry, so it
     * is already in the environment this script runs in — and because the answer
     * decides whether the `PATH` line below can be typed at all. See
     * {@link pathLine}.
     */
    'printf \'%s\\n%s\' "$d" "${SHELL:-}"',
  ].join('\n')
}

/**
 * What {@link armScript} answered: the folder, and the account's login shell.
 *
 * A shell that printed a warning before either — plenty of `.profile`s do — is
 * read from the end rather than the start, because the two lines this cares
 * about are the last two.
 */
export function readArmed(stdout: string): { dir: string; shell: string } {
  const lines = stdout.split('\n')
  return {
    dir: (lines[lines.length - 2] ?? '').trim(),
    shell: (lines[lines.length - 1] ?? '').trim(),
  }
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
 * The wrapper itself, minus the one line the shell writes above it.
 *
 * ## The order of the branches is the safety case
 *
 * The same shape `open-shim.ts` states for its own script, and for the same
 * reason — this goes on the `PATH` of a terminal somebody is working in, and a
 * wrapper that breaks an ordinary invocation is worse than no wrapper at all:
 *
 *  1. **no arguments, or a first argument that is a flag** → add `--mcp-config`.
 *     `claude`, `claude -c`, `claude --resume`, `claude -p "…"`.
 *  2. **a first argument that this server's own help listed as a subcommand** →
 *     exec untouched. `claude mcp list`, `claude update`, `claude doctor`.
 *  3. **anything else** → a prompt, so add the flag. `claude "fix the build"`.
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
 * The shebang and the one line naming the config file are not here: they are the
 * two lines {@link armScript} writes above this in its *unquoted* heredoc,
 * because only the far end knows the folder `mktemp` chose. Everything below is
 * written literally, so every `$1`, `$@` and `$REAL` in it reaches the file as
 * typed.
 */
function wrapperBody(real: string, subcommands: readonly string[]): string {
  const safe = subcommands.filter((word) => /^[a-z][a-z0-9-]*$/.test(word))
  const lines = [
    '# Written by this app when the terminal it is on was opened, and removed when',
    '# that terminal closes. It adds one flag to `claude` so that the agent in this',
    '# shell can act on the browser windows attached to this session, and it changes',
    '# nothing else about how `claude` runs.',
    '#',
    '# Absolute, and never a PATH lookup: the directory this file is in is FIRST on',
    "# this shell's PATH, so a lookup would find this script and exec it for ever.",
    `REAL='${singleQuote(real)}'`,
    '',
    '# A subcommand does not take --mcp-config and would fail on it. This list is',
    "# what this machine's own `claude --help` printed when the terminal opened.",
    'case "${1:-}" in',
  ]
  if (safe.length > 0) lines.push(`  ${safe.join('|')}) exec "$REAL" "$@" ;;`)
  lines.push(
    '  *) ;;',
    'esac',
    '',
    `exec "$REAL" ${MCP_FLAG} "$CONFIG" "$@"`,
  )
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
    '# so `claude` here can drive the browser windows you attach to this terminal\n'
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
    'sessions on this server are not allowed to act on browser windows here. You can turn that on for ' +
    'this one server under Advanced on its page.',
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
   * The port on that server's loopback that reaches this endpoint, opened on
   * first use and reference-counted. See `window-reach.ts`.
   */
  reach(serverId: string): Promise<ReachResult>
  /** Let go of one reference to that reach. */
  letGo(serverId: string): void
  /** A token and a caller for a session this process will never see. */
  mint(grant: { allowed(): boolean }): PreparedElsewhere | null
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
    { serverId: string; dir: string; minted: PreparedElsewhere }
  >()
  /** shellId → why it has no verbs. Absent means it has them, or is not ours. */
  private readonly withheld = new Map<string, string>()

  constructor(private readonly deps: WindowDriveDeps) {}

  /**
   * Give one shell the verbs, or say why it cannot have them. Never throws.
   *
   * Called **before** the shell is opened rather than after, which costs a few
   * hundred milliseconds on the first terminal for a server and is the whole
   * point: the `PATH` line has to be the first thing in that shell, or there is
   * a window in which the person types `claude` and gets a session that quietly
   * cannot see. `session-verbs.ts` is a page about that exact failure.
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

    const reach = await this.deps.reach(serverId)
    if (!reach.ok) {
      minted.drop()
      return refuse(reach.message)
    }

    let landed: { dir: string; shell: string }
    try {
      const answer = await this.deps.runScript(
        serverId,
        armScript({
          // The address is the *server's* view of this endpoint: its own
          // loopback, on the port it chose. See `window-reach.ts` for why that
          // keeps the endpoint's own loopback rule true on both machines.
          config: minted.configFor(`http://127.0.0.1:${reach.reach.port}/mcp`),
          real: claude.path,
          subcommands: subcommandsFrom(help),
        }),
      )
      landed = readArmed(answer.stdout)
    } catch {
      minted.drop()
      this.deps.letGo(serverId)
      return refuse('this app could not put the files it needs on that server.')
    }
    const dir = landed.dir
    /** Give everything back, including what is now on the far end. */
    const undo = (why: string): ArmOutcome => {
      minted.drop()
      this.deps.letGo(serverId)
      if (dir.startsWith(SCRATCH_PREFIX)) {
        void this.deps.runScript(serverId, disarmScript(dir)).catch(() => undefined)
      }
      return refuse(why)
    }
    if (!dir.startsWith(SCRATCH_PREFIX)) {
      return undo('that server did not answer with a folder this app could use.')
    }
    /*
     * The last question, and it is asked after the files rather than before
     * because the answer arrives with them for free — `sshd` exports `$SHELL`
     * into the script's own environment. A shell that cannot take the line is a
     * refusal with the folder removed, not a line typed hopefully.
     */
    if (!takesAnExportLine(landed.shell)) return undo(WHY_NOT.shell)

    // Bound only now, and to the server rather than to this machine: the binding
    // map keys a window `<serverId>\0<shellId>`, so the caller has to carry the
    // server where a machine id goes or every one of its verbs would look for a
    // window on this computer. See `browser-binding.ts`.
    minted.started(shellId, serverId)
    this.armed.set(shellId, { serverId, dir, minted })
    this.withheld.delete(shellId)
    return { ok: true, line: pathLine(dir) }
  }

  /**
   * The shell has gone. The token stops working, the folder goes, and the reach
   * is let go of.
   *
   * The token is dropped **first**, and that ordering is the one that matters: a
   * removal that failed on the far end would otherwise leave a config file
   * naming a token that still worked.
   */
  disarm(shellId: string): void {
    this.withheld.delete(shellId)
    const entry = this.armed.get(shellId)
    if (entry === undefined) return
    this.armed.delete(shellId)
    entry.minted.drop()
    this.deps.letGo(entry.serverId)
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
