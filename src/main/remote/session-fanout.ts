import type { RemoteSession } from './protocol'
import type { CreateOutcome, CreateRequest, SessionAccess, SessionHandle } from './server'

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
 *
 * ## Some sessions are not the network's business, and that was a live hole
 *
 * `list()` used to be `ptys.list()` mapped with no filter, and `attach()`
 * admitted any id that came back from that same list. Remote access is on by
 * default. So on every machine with a paired device, that device could `list`,
 * find the row whose folder is `<userData>/copilot`, `attach` to it and `input`
 * straight into the Claude CLI holding `deck-control` — bypassing the per-device
 * copilot grant, every tier check, every budget and every confirmation dialog,
 * because none of those sit between a pty and its keyboard.
 *
 * That is not a gap in an unbuilt feature; it was true of a shipped build, and
 * shipping a new phone client would not have changed it. {@link PtySource.hidden}
 * is the fix and it is deliberately a predicate rather than a list: the set is
 * the copilot's session plus every per-device copilot run, and both change while
 * the app is running.
 *
 * Two details are load-bearing:
 *
 *  - **`attach` honours it as well as `list`.** Hiding an id from the listing
 *    alone makes it unlisted, not unreachable, and these ids are recoverable —
 *    they appear in `SessionMeta.originRunId`, in alerts, and in a transcript
 *    path. `write` and `resize` honour it too, so nothing that took a handle
 *    before the predicate started answering true keeps a keyboard afterwards.
 *  - **The folder is filtered too.** `folders()` is assembled partly from the
 *    cwd of every running session, so an unfiltered list would *offer* the
 *    copilot's own folder to a phone's New Session picker. `refuseStateDirectory`
 *    would then refuse to start there, which is the right answer arriving in the
 *    wrong place: a picker should not show a row whose only outcome is a
 *    refusal.
 */

/** The slice of `PtyManager` this needs. Narrow so tests can supply a literal. */
export interface PtySource {
  list(): Array<{ id: string; title: string; cwd: string; provider?: string; exitCode: number | null }>
  write(id: string, data: string): void
  resize(id: string, cols: number, rows: number): void
  scrollback(id: string): string
  /**
   * Start a session, or say why not. Absent when this host has no PTY layer.
   *
   * Its absence is what stops the desktop advertising the `create` capability —
   * see `SessionAccess.create` — so it is optional here too rather than a
   * method that exists and always refuses.
   */
  create?(request: CreateRequest): Promise<CreateOutcome>
  /**
   * The folders one device may start a session in — the list `create` enforces,
   * sent to that device so its picker matches. Optional and absent together
   * with `create`, for the same reason it is.
   */
  folders?(deviceId: string): string[]
  /**
   * Is this session none of the network's business?
   *
   * True for the copilot's own session and for every per-device copilot run.
   * Those are reachable through `copilot.*` frames, which carry parsed messages
   * and are gated per device and per tier — never as a raw pty, which is a
   * keyboard, and a keyboard on a Claude CLI with Bash is the whole machine.
   *
   * Optional, and its absence means "nothing is hidden", which is what a host
   * with no copilot layer honestly wants — `scripts/remote-host.ts` and the
   * public demo box both have a session layer and no copilot. It is a predicate
   * rather than a set because the answer changes while the app runs: the copilot
   * restarts with a new id, and a run appears the moment a granted phone taps
   * Start.
   *
   * It must never throw. It is consulted on the read path of a socket, and an
   * exception there would be a main process that dies over a `list`. The
   * implementations wrap it; see {@link SessionFanout.isHidden}.
   */
  hidden?(sessionId: string): boolean
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

  /**
   * Present only when the source can start a session, and that is deliberate.
   *
   * `server.ts` decides whether to advertise the `create` capability by asking
   * whether this method exists. A class method always exists, so declaring it
   * on the prototype and having it refuse would advertise a button on every
   * host — including the ones with no terminals at all. Assigned here instead,
   * so the answer to "can this desktop start a session" is one fact rather than
   * two that have to be kept in step.
   */
  readonly create?: (request: CreateRequest) => Promise<CreateOutcome>

  /**
   * Present exactly when {@link create} is, and assigned the same way for the
   * same reason: `server.ts` reads whether these methods exist to decide what to
   * advertise, and a prototype method always exists.
   */
  readonly folders?: (deviceId: string) => string[]

  constructor(private readonly ptys: PtySource) {
    const start = ptys.create
    if (start) this.create = (request) => start(request)
    const offer = ptys.folders
    /*
     * The offered folder list has the hidden sessions taken out of it.
     *
     * The list a host assembles includes the cwd of every running session, so
     * without this the copilot's own folder — and every copilot run's, which is
     * the same folder — turns up in a phone's New Session picker. Filtered here
     * rather than in the host's own `folders` callback because *this* is the
     * class that knows which sessions are hidden, and a second copy of that
     * knowledge in the assembly is a second copy that can disagree.
     *
     * Compared by path rather than by id, because that is what the list carries.
     * The hidden sessions' folders are gathered from the pty list, so a folder
     * that is only ever a hidden session's cwd disappears and one that is also a
     * real project stays — which is right: a project the person opened is theirs
     * to grant whatever else happens to be running in it.
     */
    if (offer) {
      this.folders = (deviceId) => {
        const offered = offer(deviceId)
        const secret = this.hiddenFolders()
        return secret.size === 0 ? offered : offered.filter((folder) => !secret.has(folder))
      }
    }
  }

  /**
   * The predicate, made safe to call from a socket's data handler.
   *
   * A throw here would be an exception on the read path of a connection, which
   * is how a main process dies over a malformed `list` from a phone on a bad
   * network. It fails **closed** — a predicate that threw is a predicate whose
   * answer is unknown, and the safe reading of "I do not know whether this is
   * the copilot's terminal" is that it might be.
   */
  private isHidden(id: string): boolean {
    const ask = this.ptys.hidden
    if (!ask) return false
    try {
      return ask(id)
    } catch (error) {
      console.error('[remote] the hidden-session rule threw; treating the session as hidden:', error)
      return true
    }
  }

  /** Folders that exist only because a hidden session is running in one. */
  private hiddenFolders(): Set<string> {
    const folders = new Set<string>()
    if (!this.ptys.hidden) return folders
    for (const session of this.ptys.list()) {
      if (this.isHidden(session.id)) folders.add(session.cwd)
    }
    return folders
  }

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
    return this.ptys.list().filter((s) => !this.isHidden(s.id)).map((s) => ({
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
    /*
     * And never to one that is hidden, whatever the caller learned its id from.
     *
     * Checked here and not only in `list`, because these ids leak by design:
     * `SessionMeta.originRunId` points at them, an alert names them, and a
     * transcript path contains one. A session that is merely unlisted is a
     * session whose keyboard is protected by nobody happening to know a UUID.
     *
     * `null` is the same answer an unknown id gets, and deliberately: the caller
     * turns it into "No session <id> is running", which is what a device that
     * was never meant to see it should be told. A distinct refusal would confirm
     * that the id names something real.
     */
    if (this.isHidden(id)) return null

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

  /*
   * Both of these are already unreachable for a hidden session through the
   * protocol, because `server.ts` refuses an `input` or a `resize` for a session
   * this connection has no handle for and `attach` above is what mints a handle.
   * They check anyway, and the reason is the one this class's header gives about
   * `attach`: this is a `SessionAccess`, it is injected into more than one thing,
   * and a rule that holds only because of the order of checks in a different file
   * is a rule the next caller does not have. The cost is one predicate call per
   * keystroke; the alternative is a second door into a Claude CLI's keyboard.
   */
  write(id: string, data: string): void {
    if (this.isHidden(id)) return
    this.ptys.write(id, data)
  }

  resize(id: string, cols: number, rows: number): void {
    if (this.isHidden(id)) return
    this.ptys.resize(id, cols, rows)
  }

  /** For the desktop UI: how many remote watchers a session has. */
  watcherCount(id: string): number {
    return this.listeners.get(id)?.size ?? 0
  }
}
