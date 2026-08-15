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
      // Read off the request rather than the spawn spec: `resumeArgs` is empty
      // for providers with no resume flag, so the spec cannot say whether the
      // user asked to continue — and a continued session writes into a
      // transcript older than itself, which is the one case where "started
      // before this tab did" stops meaning "not this tab's".
      resumed: input.resume === true,
      // Spread rather than assigned so a session with no account carries no
      // key at all: `profileName: undefined` and "this session has no account"
      // are the same thing to a renderer, and only one of them survives JSON.
      ...(spawnSpec.profile
        ? { profileId: spawnSpec.profile.id, profileName: spawnSpec.profile.name }
        : {}),
    }

    // Built before the spawn rather than inline, because one step of it is a
    // deletion and an object literal has no way to say that. Everything the
    // literal used to do happens here in the same order; only the `removeEnv`
    // pass at the end is new.
    const env = this.environmentFor(id, spawnSpec)

    const proc = pty.spawn(spawnSpec.command, spawnSpec.args, {
      name: 'xterm-256color',
      cols: input.cols,
      rows: input.rows,
      // The *process's* directory, which is the session's folder in every case
      // but one. See `hostCwd`.
      cwd: spawnSpec.hostCwd ?? input.cwd,
      env,
    })

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
   * What the session is showing right now, or null when there is no such
   * session. Not the same thing as `scrollback`: agent CLIs repaint with cursor
   * moves, so the raw stream and the screen say different things, and every
   * question of the form "what state is the agent in?" needs the screen.
   */
  async screen(id: string): Promise<string | null> {
    const session = this.sessions.get(id)
    return session ? session.activity.settledText() : null
  }

  kill(id: string): void {
    const s = this.sessions.get(id)
    if (!s) return
    s.activity.dispose()
    try {
      s.proc.kill()
    } catch {
      /* already gone */
    }
    this.sessions.delete(id)
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
