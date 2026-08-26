import { randomUUID } from 'node:crypto'
import { basename } from 'node:path'
import * as pty from 'node-pty'
import { BRAND } from '../shared/brand'
import { stripInheritedSessionEnv } from './session-env'
import { currentPlatform, isWindows, withPath } from './platform/host'
import type { CreateSessionInput, ProviderId, SessionMeta, SessionStatus } from '../shared/types'
import { ActivityTracker } from './session-activity'

/** Fully resolved launch instruction, decided by the caller. */
export interface SpawnSpec {
  provider: ProviderId
  command: string
  args: string[]
  path: string
  /** Extra environment, e.g. a profile's redirected config directory. */
  env?: Record<string, string>
  /**
   * Variables to take away from the session rather than set on it.
   *
   * Spreading an object can only add, and for a session started from somebody
   * else's device the load-bearing half is subtraction: `SSH_AUTH_SOCK` and
   * `GH_TOKEN` have to be *gone*, not blank. The difference is not pedantic —
   * `ssh` reading an empty agent path is a different failure from `ssh` with no
   * agent at all, and a `gh` handed an empty token reports being signed in as
   * nobody rather than being signed out. `git-guest.ts` says which variables and
   * why each one is on the list.
   */
  removeEnv?: readonly string[]
  /**
   * The account this session runs as, once the caller has resolved it.
   *
   * Carried onto `SessionMeta` and no further: nothing in this class reads it,
   * because the environment that *makes* it true is already in `env`. It is
   * here so a window can say which login a tab belongs to without recomputing a
   * resolution it does not have the inputs for — see `SessionMeta.profileId`.
   *
   * Left unset by callers when no account applies, which is a plain shell or an
   * agent whose config directory this app cannot redirect.
   */
  profile?: { id: string; name: string }
  /**
   * The conversation id the caller put on the command line, when it put one
   * there.
   *
   * Carried onto `SessionMeta` and no further, exactly like `profile` above:
   * nothing in this class reads it, because the thing that *makes* it true is
   * already in `args`. It is here so that a reader of a transcript can name the
   * file instead of picking the folder's most recent one — see
   * `SessionMeta.agentSessionId` for what picking cost.
   *
   * Left unset whenever the caller did not name the conversation: a resumed
   * session, any agent but Claude Code, and every session this app did not
   * start.
   */
  agentSessionId?: string
  /**
   * Whether the arguments above carry the agent's continue flag.
   *
   * Carried onto `SessionMeta` and no further, exactly like the two fields
   * around it. See `SessionMeta.resumed` for why a request to resume is not
   * evidence that one happened.
   */
  resumed?: boolean
  /**
   * Where the operating-system process starts, when that is not the session's
   * own folder.
   *
   * There is exactly one case, and it is not a nicety. A session inside WSL has
   * a Linux `cwd` — `/home/asad/proj` — and node-pty on Windows runs
   * `path.resolve(cwd)` before handing it to ConPTY (read in
   * `windowsPtyAgent.js` in the installed copy: `cwd = path.resolve(cwd)`, then
   * `startProcess(file, commandLine, env, cwd, …)`). `path.win32.resolve` turns
   * that into `C:\home\asad\proj`, which does not exist, so the process is never
   * created and the tab dies with nothing printed in it. The directory the
   * session actually runs in travels in `wsl.exe --cd` instead, and this is the
   * harmless Windows directory the launcher itself starts in.
   *
   * `meta.cwd` is still the session's real folder. This is about the process,
   * not about the session.
   */
  hostCwd?: string
  /**
   * The tab this session is, carried onto `SessionMeta` and no further.
   *
   * Decided by `startSession` rather than here, because the one condition that
   * settles it — is this session written into `openSessions` at all — is the
   * same condition that decides whether `ledger.note` is called, and it lives
   * there. See {@link SessionMeta.tabKey}.
   */
  tabKey?: string
}

interface Session {
  meta: SessionMeta
  proc: pty.IPty
  /** Rolling buffer so a tab can be re-rendered after switching away. */
  scrollback: string[]
  activity: ActivityTracker
}

const SCROLLBACK_LIMIT = 4000

/**
 * What to say when a process would not start.
 *
 * ## Why this exists, and why it is not defensive wrapping
 *
 * One line, repeated seven times in Asad's app log on 2026-08-17, telling him
 * nothing whatsoever:
 *
 *     [ipc] session:create failed File not found:
 *
 * Note what is after the colon: nothing. It is accurate. node-pty's `conpty.cc`
 * builds that sentence as `"File not found: " + shellpath` and reaches it
 * precisely when it has no path to name — `get_shell_path` hands back an empty
 * string when a *relative* program name is found next to the calling process's
 * own working directory (`wsl.ts`'s `wslExePath` carries the measurement). No
 * amount of formatting downstream can recover a detail that was never in the
 * string: `diagnostics.ts` writes `error.message`, and there was nothing else
 * there to write.
 *
 * So the facts are added at the last layer that still has them, and there are
 * four: which agent, which folder the *session* is in, which program, and which
 * directory the *process* was to start in. The last two are separate on purpose
 * — for a session inside WSL they are deliberately different, the session being
 * in Ubuntu while the launcher starts on the Windows side, so a message naming
 * only one of them explains the wrong half.
 *
 * The original message is kept verbatim and **last**: it is the only part
 * written by whoever actually refused, and replacing it with a sentence of our
 * own is how a specific failure becomes a vague one. When there is no original —
 * which is the very case this exists for — the sentence simply ends, rather than
 * trailing an em dash with nothing after it, which is the same defect as the
 * colon it replaces.
 *
 * A pure function rather than a block inside the `catch`, because it is only
 * reachable on Windows: node-pty on POSIX never throws from `spawn` — a missing
 * program, a missing working directory and a bare name all return a live pty
 * whose process exits a moment later (measured, all three). A sentence that can
 * only be read on the platform where reading it means a bug report is a
 * sentence nobody checks.
 */
export function spawnFailureMessage(
  spawnSpec: SpawnSpec,
  sessionCwd: string,
  procCwd: string,
  error: unknown,
): string {
  const why = error instanceof Error ? error.message.trim() : String(error).trim()
  return (
    `could not start ${spawnSpec.provider} in ${sessionCwd}: ` +
    `${spawnSpec.command} would not run from ${procCwd}` +
    (why === '' ? '' : ` — ${why}`)
  )
}

/**
 * Why a session left the manager, for the one caller that has to tell them apart.
 *
 * `stopped` is every ordinary ending: a tab closed, the copilot's `sessions.stop`,
 * a phone stopping one, a routine, the shutdown sweep. Anything drawing a row for
 * it should take the row away, because after this the session cannot be written
 * to, cannot be re-attached and is not in {@link PtyManager.list}.
 *
 * `replaced` is the account switch, and it is the one case where taking the row
 * away is wrong. A CLI is authenticated at spawn, so changing the account means
 * stopping the process and starting another in its place — and to the person it
 * is still *this session*, in the same tab, with the name they gave it.
 * `withReplacedSession` in the renderer's store does that swap by finding the old
 * id, and it deliberately returns the list unchanged when the old id has already
 * gone (two rows for one pty being worse than a missing one). So a removal
 * announced for the outgoing half would race the swap, and on the losing side of
 * that race the tab disappears in the middle of a switch nobody asked to lose.
 */
export type RemovalReason = 'stopped' | 'replaced'

/**
 * Owns every live terminal process. The renderer never touches node-pty —
 * it addresses sessions by id and receives output through the IPC bridge.
 */
export class PtyManager {
  private sessions = new Map<string, Session>()
  /**
   * Processes signalled but not yet confirmed dead. See `drain`.
   *
   * Counted rather than derived from `sessions`, because `kill` removes the
   * session immediately — the caller must stop seeing it at once — while the
   * process itself lives on until the OS reaps it.
   */
  private pendingExits = 0
  /**
   * Whether anything is listening to session status. True unless a headless
   * host has said otherwise; see {@link setWatched}.
   */
  private watched = true

  constructor(
    private readonly onData: (id: string, data: string) => void,
    private readonly onExit: (id: string, exitCode: number) => void,
    private readonly onStatus: (id: string, status: SessionStatus) => void,
    /**
     * This manager is no longer holding that session — tell whoever is drawing
     * rows for it.
     *
     * Deliberately separate from {@link onExit}, and the distinction is the
     * whole of the bug it closes. `onExit` is a *process* ending, which leaves
     * the session in the map with an exit code and its scrollback intact,
     * because somebody wants to read what it printed. This fires from {@link
     * kill}, at the moment the entry is deleted, after which the session cannot
     * be written to, cannot be re-attached, and does not appear in {@link list}.
     *
     * Optional because the headless host and every test that builds a manager
     * for its ptys has nothing to tell.
     */
    private readonly onRemoved?: (id: string, reason: RemovalReason) => void,
  ) {}

  /**
   * The environment one session runs with.
   *
   * Order is the whole of it, and the last step is the only one that could not
   * be written as a spread:
   *
   *  1. Not `process.env` directly: if this app was launched from inside an
   *     agent session, its markers are in here and the CLI would treat the new
   *     session as a child — which turns transcript saving off, and chat mode
   *     and cost both read those transcripts.
   *  2. A GUI app inherits a minimal PATH; use the login shell's instead so CLIs
   *     installed via nvm/Homebrew/~/.local/bin resolve. Written through
   *     `withPath` rather than as a literal `PATH:` key — Windows spells the
   *     variable `Path`, and a spread copy would hand the child both spellings
   *     with no defined winner. `platform/host.ts` documents it.
   *  3. A profile redirects the agent's config dir, which is what actually keeps
   *     two logins apart. Applied after the inherited environment so it wins.
   *  4. Then the removals, **last**, so that taking a variable away is final. A
   *     deletion that ran before the spreads would be undone by the copy of
   *     `process.env` they are built from, which is exactly where the variable
   *     being removed came from in the first place.
   */
  private environmentFor(id: string, spawnSpec: SpawnSpec): Record<string, string> {
    const env: Record<string, string> = {
      ...withPath(
        stripInheritedSessionEnv(process.env, BRAND.sessionEnvVar),
        spawnSpec.path,
        currentPlatform(),
      ),
      ...(spawnSpec.env ?? {}),
      [BRAND.sessionEnvVar]: id,
      TERM: 'xterm-256color',
      COLORTERM: 'truecolor',
    }
    const doomed = spawnSpec.removeEnv ?? []
    if (doomed.length === 0) return env
    // Windows environment names are case-insensitive, so `Gh_Token` and
    // `GH_TOKEN` are one variable there and deleting only the spelling we were
    // handed would leave the other one behind holding the same token. On POSIX
    // they genuinely are two variables and an exact match is the only correct
    // answer — folding case there would let a request to remove `PATH` take
    // `Path` with it.
    if (isWindows(currentPlatform())) {
      const folded = new Set(doomed.map((name) => name.toLowerCase()))
      for (const name of Object.keys(env)) {
        if (folded.has(name.toLowerCase())) delete env[name]
      }
      return env
    }
    for (const name of doomed) delete env[name]
    return env
  }

  create(input: CreateSessionInput, spawnSpec: SpawnSpec): SessionMeta {
    const id = randomUUID()
    const meta: SessionMeta = {
      id,
      cwd: input.cwd,
      title: basename(input.cwd) || input.cwd,
      provider: spawnSpec.provider,
      exitCode: null,
      createdAt: Date.now(),
      /*
       * Whether this session actually continues an older conversation, which
       * matters because a continued one writes into a transcript older than
       * itself — the one case where "started before this tab did" stops meaning
       * "not this tab's".
       *
       * Off the spawn spec, not off the request, and that distinction is a
       * fixed defect rather than a preference. `one-conversation.ts` can refuse
       * a resume the caller asked for — a second tab in a folder that already
       * has a live session starts fresh, and so did every account switch until
       * it learnt to say which session it was replacing — and while this read
       * `input.resume` those sessions claimed to have continued something they
       * had not. `startSession` reads the flag off the argument list it spawned.
       *
       * The fallback keeps the old reading for callers that build a pty
       * directly and never fill the field in.
       */
      resumed: spawnSpec.resumed ?? input.resume === true,
      // Spread rather than assigned so a session with no account carries no
      // key at all: `profileName: undefined` and "this session has no account"
      // are the same thing to a renderer, and only one of them survives JSON.
      ...(spawnSpec.profile
        ? { profileId: spawnSpec.profile.id, profileName: spawnSpec.profile.name }
        : {}),
      // Same spread, same reason: an absent id means the transcript has to be
      // inferred, and that has to be distinguishable from an id that is present.
      ...(spawnSpec.agentSessionId ? { agentSessionId: spawnSpec.agentSessionId } : {}),
      // And again: absent means "this session is not one that comes back", which
      // the tab strip reads as "not part of the saved arrangement". A key that
      // survived JSON as `undefined` would be a tab claiming a place it can
      // never be put back into.
      ...(spawnSpec.tabKey ? { tabKey: spawnSpec.tabKey } : {}),
      /*
       * Who wanted this session, copied straight off the request.
       *
       * Read from `input` rather than from the spawn spec because it is not a
       * property of *how* the session runs — the command, the environment and
       * the confinement are all identical whoever asked — it is a property of
       * who asked. `startSession` resolves the spec and deliberately does not
       * touch this.
       *
       * Spread conditionally so a session nobody labelled carries no key at
       * all: `origin: undefined` and "no origin" are the same thing to a
       * renderer, and only one of them survives JSON.
       */
      ...(input.origin ? { origin: input.origin } : {}),
      ...(input.originRoutineId ? { originRoutineId: input.originRoutineId } : {}),
      ...(input.originRunId ? { originRunId: input.originRunId } : {}),
    }

    // Built before the spawn rather than inline, because one step of it is a
    // deletion and an object literal has no way to say that. Everything the
    // literal used to do happens here in the same order; only the `removeEnv`
    // pass at the end is new.
    const env = this.environmentFor(id, spawnSpec)

    const procCwd = spawnSpec.hostCwd ?? input.cwd
    let proc: pty.IPty
    try {
      proc = pty.spawn(spawnSpec.command, spawnSpec.args, {
        name: 'xterm-256color',
        cols: input.cols,
        rows: input.rows,
        // The *process's* directory, which is the session's folder in every case
        // but one. See `hostCwd`.
        cwd: procCwd,
        env,
      })
    } catch (error) {
      // The detail is added here because this is the last layer that still has
      // it. See `spawnFailureMessage`, which is where the sentence and the
      // reason for it live.
      throw new Error(spawnFailureMessage(spawnSpec, input.cwd, procCwd, error), { cause: error })
    }

    const activity = new ActivityTracker(id, this.onStatus, input.cols, input.rows)
    activity.setWatched(this.watched)
    const session: Session = { meta, proc, scrollback: [], activity }
    this.sessions.set(id, session)

    proc.onData((data) => {
      session.scrollback.push(data)
      if (session.scrollback.length > SCROLLBACK_LIMIT) session.scrollback.shift()
      activity.push(data)
      this.onData(id, data)
    })

    this.pendingExits += 1
    proc.onExit(({ exitCode }) => {
      this.pendingExits -= 1
      session.meta.exitCode = exitCode
      activity.markExited()
      this.onExit(id, exitCode)
    })

    return meta
  }

  /**
   * Give a session a name, or take the given name off it.
   *
   * > *"I said before, for being able to rename sessions."*
   *
   * An empty name is not a refusal — it restores the one derived from the folder,
   * which is the only way back from a rename and the reason this takes a string
   * rather than a `string | null`. The derived name is recomputed here rather
   * than remembered, so a session that has been renamed and un-renamed ends up
   * with exactly the title it was born with.
   *
   * Returns whether there was a session to rename, which is what the wire turns
   * into *no session by that name* rather than a silent success.
   */
  rename(id: string, title: string): boolean {
    const session = this.sessions.get(id)
    if (!session) return false
    const given = title.trim()
    session.meta.title = given === '' ? basename(session.meta.cwd) || session.meta.cwd : given
    return true
  }

  write(id: string, data: string): void {
    this.sessions.get(id)?.proc.write(data)
  }

  resize(id: string, cols: number, rows: number): void {
    const s = this.sessions.get(id)
    if (!s || s.meta.exitCode !== null) return
    // The shadow terminal must track the real one, or its viewport is the
    // wrong shape and status is read from the wrong lines.
    s.activity.resize(cols, rows)
    try {
      s.proc.resize(Math.max(cols, 1), Math.max(rows, 1))
    } catch {
      /* process died between the check and the resize — safe to ignore */
    }
  }

  /** Replay buffered output so a re-mounted terminal shows its history. */
  scrollback(id: string): string {
    return this.sessions.get(id)?.scrollback.join('') ?? ''
  }

  /**
   * The pid of the session's own process, or null when there is no such session.
   *
   * The pty's process is the *shell or agent this app launched*, which is not
   * always the agent someone is talking to: pressing Run, or simply typing
   * `claude`, starts one underneath it. So this is a root to walk down from
   * rather than an answer on its own — `session-account.ts` does the walking,
   * and is the only caller, because reading another process's environment is
   * the one way to establish which login a session this app did not start is
   * actually using.
   */
  pidOf(id: string): number | null {
    const session = this.sessions.get(id)
    if (!session || session.meta.exitCode !== null) return null
    const pid = session.proc.pid
    return typeof pid === 'number' && pid > 0 ? pid : null
  }


  /**
   * What the session is showing right now, or null when there is no such
   * session. Not the same thing as `scrollback`: agent CLIs repaint with cursor
   * moves, so the raw stream and the screen say different things, and every
   * question of the form "what state is the agent in?" needs the screen.
   */
  async screen(id: string): Promise<string | null> {
    const session = this.sessions.get(id)
    return session ? session.activity.settledText() : null
  }

  kill(id: string, reason: RemovalReason = 'stopped'): void {
    const s = this.sessions.get(id)
    if (!s) return
    s.activity.dispose()
    try {
      s.proc.kill()
    } catch {
      /* already gone */
    }
    this.sessions.delete(id)
    this.onRemoved?.(id, reason)
  }

  list(): SessionMeta[] {
    return [...this.sessions.values()].map((s) => s.meta)
  }

  /**
   * Tell every live session whether anybody is listening to its status.
   *
   * The headless host calls this from the attach and detach events — see
   * `idle.ts`. Nothing else does: a desktop has a window in front of a person
   * for as long as it is running, so it never leaves the watched state it starts
   * in. Applied to sessions started later too, in `create`, or a session opened
   * from a phone while the host is idle would be the one tracker still
   * classifying for nobody.
   */
  setWatched(watched: boolean): void {
    this.watched = watched
    for (const session of this.sessions.values()) session.activity.setWatched(watched)
  }

  killAll(): void {
    for (const id of [...this.sessions.keys()]) this.kill(id)
  }

  /**
   * Wait for the processes `killAll` signalled to actually be gone.
   *
   * `kill` sends a signal and returns; the process dies whenever the OS gets
   * round to it, and its `onExit` — which writes down the exit code and tells
   * every listener — fires after that. So `killAll()` returning means "asked",
   * not "finished", and anything that tears down state immediately afterwards is
   * racing a write it cannot see.
   *
   * That race is not theoretical. `src/headless/host.test.ts` removes its state
   * directory the moment `stop()` resolves, and under the full suite — where
   * dozens of files run at once and the machine is loaded — the removal walks a
   * tree that a dying pty is still writing into, and node answers `ENOTEMPTY`.
   * Alone, on an idle machine, it passes every time. A flake that only appears
   * under load is the shape of a real shutdown ordering bug, and the honest fix
   * is to make shutdown ordered rather than to retry the delete.
   *
   * Bounded, because a wedged process must not be able to hang a quit: after
   * `timeoutMs` this gives up and returns anyway. Returns true if everything
   * exited, false if it timed out — the caller may want to say so.
   */
  async drain(timeoutMs = 2000): Promise<boolean> {
    const deadline = Date.now() + timeoutMs
    while (this.pendingExits > 0) {
      if (Date.now() >= deadline) return false
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
    return true
  }
}
