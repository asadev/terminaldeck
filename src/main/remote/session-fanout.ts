import type { RemoteSession } from './protocol'
import type { SessionAccess, SessionHandle } from './server'

/**
 * Lets more than one watcher follow the same session.
 *
 * `PtyManager` reports each session's output through a single callback, which
 * the main process forwards to the window. A phone is a second watcher of the
 * same bytes, and there can be several — the laptop, the phone, a tablet — so
 * something has to fan one stream out to many without either of them stealing
 * it from the other.
 *
 * It deliberately does not own the PTY. Sessions belong to `PtyManager` and
 * outlive every remote connection, which is the whole reason attaching from a
 * phone is better than SSH: closing the phone detaches a listener, it does not
 * end the agent's work.
 */

/** The slice of `PtyManager` this needs. Narrow so tests can supply a literal. */
export interface PtySource {
  list(): Array<{ id: string; title: string; cwd: string; provider?: string; exitCode: number | null }>
  write(id: string, data: string): void
  resize(id: string, cols: number, rows: number): void
  scrollback(id: string): string
}

interface Listener {
  readonly handle: SessionHandle
  readonly onData: (data: string) => void
  readonly onStatus: (status: string) => void
  readonly onExit: (exitCode: number) => void
}

export class SessionFanout implements SessionAccess {
  private readonly listeners = new Map<string, Set<Listener>>()
  /** Last status seen per session, so a late attach knows the state. */
  private readonly status = new Map<string, string>()

  constructor(private readonly ptys: PtySource) {}

  /* ----------------------------------------------------- from PtyManager -- */

  /** Call from the PtyManager data callback, alongside the window broadcast. */
  noteData(id: string, data: string): void {
    for (const l of this.listeners.get(id) ?? []) l.onData(data)
  }

  noteStatus(id: string, status: string): void {
    this.status.set(id, status)
    for (const l of this.listeners.get(id) ?? []) l.onStatus(status)
  }

  noteExit(id: string, exitCode: number): void {
    for (const l of this.listeners.get(id) ?? []) l.onExit(exitCode)
    // The session is gone; holding its listeners would leak them for the life
    // of the app, and every one of them is a live socket callback.
    this.listeners.delete(id)
    this.status.delete(id)
  }

  /* ---------------------------------------------------- SessionAccess -- */

  list(): RemoteSession[] {
    // No cast. The first draft asserted `as RemoteSession[]` over an object
    // carrying `exited: boolean`, which the real type does not have — the cast
    // silenced exactly the mismatch it should have surfaced.
    return this.ptys.list().map((s) => ({
      id: s.id,
      title: s.title,
      cwd: s.cwd,
      provider: s.provider ?? 'shell',
      status: this.status.get(s.id) ?? 'idle',
      exitCode: s.exitCode,
    }))
  }

  attach(
    id: string,
    onData: (data: string) => void,
    onStatus: (status: string) => void,
    onExit: (exitCode: number) => void,
  ): SessionHandle | null {
    // Never attach to a session that is not there: the id came off the network,
    // and a handle for a made-up id would be a listener nothing ever removes.
    if (!this.ptys.list().some((s) => s.id === id)) return null

    // Snapshot and subscribe in the same tick, with no await between them.
    // Reading first loses whatever arrives in the gap; subscribing first sends
    // it twice. This is the only ordering with neither.
    const replay = this.ptys.scrollback(id)
    const handle: SessionHandle = { sessionId: id, replay }
    const set = this.listeners.get(id) ?? new Set<Listener>()
    set.add({ handle, onData, onStatus, onExit })
    this.listeners.set(id, set)
    return handle
  }

  detach(handle: SessionHandle): void {
    const set = this.listeners.get(handle.sessionId)
    if (!set) return
    for (const l of set) {
      if (l.handle === handle) set.delete(l)
    }
    if (set.size === 0) this.listeners.delete(handle.sessionId)
  }

  write(id: string, data: string): void {
    this.ptys.write(id, data)
  }

  resize(id: string, cols: number, rows: number): void {
    this.ptys.resize(id, cols, rows)
  }

  /** For the desktop UI: how many remote watchers a session has. */
  watcherCount(id: string): number {
    return this.listeners.get(id)?.size ?? 0
  }
}
