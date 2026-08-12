import { randomUUID } from 'node:crypto'
import { basename } from 'node:path'
import * as pty from 'node-pty'
import { BRAND } from '../shared/brand'
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

  constructor(
    private readonly onData: (id: string, data: string) => void,
    private readonly onExit: (id: string, exitCode: number) => void,
    private readonly onStatus: (id: string, status: SessionStatus) => void,
  ) {}

  create(input: CreateSessionInput, spawnSpec: SpawnSpec): SessionMeta {
    const id = randomUUID()
    const meta: SessionMeta = {
      id,
      cwd: input.cwd,
      title: basename(input.cwd) || input.cwd,
      provider: spawnSpec.provider,
      exitCode: null,
      createdAt: Date.now(),
    }

    const proc = pty.spawn(spawnSpec.command, spawnSpec.args, {
      name: 'xterm-256color',
      cols: input.cols,
      rows: input.rows,
      cwd: input.cwd,
      env: {
        ...(process.env as Record<string, string>),
        // A GUI app inherits a minimal PATH; use the login shell's instead so
        // CLIs installed via nvm/Homebrew/~/.local/bin resolve.
        PATH: spawnSpec.path,
        // A profile redirects the agent's config dir, which is what actually
        // keeps two logins apart. Applied last so it wins.
        ...(spawnSpec.env ?? {}),
        [BRAND.sessionEnvVar]: id,
        TERM: 'xterm-256color',
        COLORTERM: 'truecolor',
      },
    })

    const activity = new ActivityTracker(id, this.onStatus, input.cols, input.rows)
    const session: Session = { meta, proc, scrollback: [], activity }
    this.sessions.set(id, session)

    proc.onData((data) => {
      session.scrollback.push(data)
      if (session.scrollback.length > SCROLLBACK_LIMIT) session.scrollback.shift()
      activity.push(data)
      this.onData(id, data)
    })

    proc.onExit(({ exitCode }) => {
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

  killAll(): void {
    for (const id of [...this.sessions.keys()]) this.kill(id)
  }
}
