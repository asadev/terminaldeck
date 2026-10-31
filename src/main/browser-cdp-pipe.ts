/**
 * The debugger channel for the server that has no Electron under it.
 *
 * On the desktop the driver talks to one `WebContents` through
 * `webContents.debugger`, an in-process message channel this process already
 * holds a reference to — nothing outside the process can reach it, so there is
 * nothing to authenticate and nothing to scan for. On a headless Linux server
 * there is no `WebContents`, so this file is the same channel spelled for the
 * one transport that keeps that property: `--remote-debugging-pipe`.
 *
 * ## Why a pipe and not a port
 *
 * `browser-cdp.ts`'s header makes the argument at length and it is not repeated
 * here, but the short form belongs where the code is. Chromium's
 * `--remote-debugging-port` has **no authentication of any kind**: opening it
 * demotes "another user cannot reach this" to "another user can", silently, for
 * everybody, and the browser's own targets sit on it. `--remote-debugging-pipe`
 * has neither a port nor a socket. The launched Chromium child inherits fd 3
 * (the host WRITES commands here) and fd 4 (the host READS results and events
 * here) as an anonymous inherited pipe pair. There is no listener, no file to
 * open and no socket to scan — it is reachable only from inside this process
 * family, which is the exact in-process analogue of `webContents.debugger`, and
 * `DRIVABLE-BROWSER.md` §2.1's no-socket invariant holds verbatim.
 *
 * ## What this file is, and is not
 *
 * It is the framing and the multiplexing, and nothing above them. It does NOT
 * spawn Chromium — that is `browser-chromium-launch.ts`, which hands this file
 * the two fd streams — and it does NOT decide what may be sent: every command
 * is screened by `browser-driver.ts`'s `send()` through
 * `screenCommand({ transport: 'cdp', … })` BEFORE it reaches {@link
 * CdpPipe.command}, which is the one door onto the wire. So this file has a
 * single fd-write site (pinned by its test), the way the desktop driver
 * funnels every command through one `webContents.debugger` send.
 *
 * ## The framing
 *
 * NUL-delimited JSON, both directions. A command the host sends is
 * `{ id, sessionId?, method, params }`; a reply is
 * `{ id, sessionId?, result | error }`; an event is `{ sessionId?, method,
 * params }` with no id. JSON never emits a raw NUL of its own — control
 * characters are shown as an escape, not a raw byte — so the only NUL byte on the wire is the
 * one delimiter, and the reader splits on it with no ambiguity.
 *
 * ## Flatten mode, which is why there is only one pipe
 *
 * The host arms `Target.setAutoAttach { flatten: true }` (through the screened
 * path, not from in here), and from then on every target and every browser
 * context multiplexes onto this one pipe, each frame tagged with the
 * `sessionId` it belongs to. This file reads that tag off every reply and event
 * and routes accordingly: a reply by its `id` (the pending-promise map), an
 * event by its `method` and `sessionId` (the per-session emitter that feeds a
 * `DrivenPage.onEvent`). A frame with no `sessionId` is browser-level, and its
 * listeners subscribe with `undefined`. One pipe, one process, every target.
 */

/* -------------------------------------------------------- the fd streams -- */

/**
 * The half of a Node `Writable` this file uses — no more, so a test can hand it
 * a fake with two methods rather than a whole stream. In production this is
 * `child.stdio[3]`, the write end of the command pipe.
 */
export interface WritableLike {
  write(chunk: Buffer): boolean
  once(event: 'drain', listener: () => void): unknown
  /**
   * Subscribe to the write side's failures.
   *
   * Optional so a test can still hand this two methods, and subscribed to
   * whenever it is there — see the constructor for why that is not a nicety.
   */
  on?(event: 'error', listener: (error: Error) => void): unknown
}

/**
 * The half of a Node `Readable` this file uses. In production this is
 * `child.stdio[4]`, the read end of the result/event pipe.
 */
export interface ReadableLike {
  on(event: 'data', listener: (chunk: Buffer) => void): unknown
  on(event: 'end', listener: () => void): unknown
  on(event: 'close', listener: () => void): unknown
  on(event: 'error', listener: (error: Error) => void): unknown
}

/* ------------------------------------------------------------ the frames -- */

/** A command the host sends. `id` is assigned by {@link CdpPipe.command}. */
export interface CdpCommand {
  method: string
  params?: unknown
  sessionId?: string
}

/** An event the browser pushed — no `id`, routed by `method` and `sessionId`. */
export interface CdpEvent {
  sessionId?: string
  method: string
  params: unknown
}

/** The `error` half of a reply. */
export interface CdpError {
  code?: number
  message: string
  data?: unknown
}

/** A rejected command carries the protocol's own code and data. */
export interface CdpCommandError extends Error {
  code?: number
  data?: unknown
}

type Pending = {
  resolve: (result: unknown) => void
  reject: (error: Error) => void
}

const NUL = 0

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

/* -------------------------------------------------------------- the pipe -- */

export class CdpPipe {
  private readonly out: WritableLike
  private readonly pending = new Map<number, Pending>()
  /** Event listeners keyed by sessionId; the empty string is browser-level. */
  private readonly listeners = new Map<string, Set<(event: CdpEvent) => void>>()
  private readonly closeListeners = new Set<(error?: Error) => void>()
  private readonly queue: Buffer[] = []
  private leftover: Buffer = Buffer.alloc(0)
  private nextId = 0
  private paused = false
  private closed = false

  constructor(out: WritableLike, incoming: ReadableLike) {
    this.out = out
    incoming.on('data', (chunk) => this.receive(chunk))
    incoming.on('end', () => this.close())
    incoming.on('close', () => this.close())
    incoming.on('error', (error) => this.close(error))

    /*
     * The write side needs a listener too, and this one is not symmetry.
     *
     * A Node stream with no `'error'` listener **throws** when it errors —
     * `events` re-raises it as an uncaught exception — and the write end of a
     * pipe onto a dead Chromium errors with `EPIPE` the moment anything is
     * written to it. Measured on Ubuntu 24.04 on 2026-08-22, against a real
     * Chromium that aborted at startup: writing one `Browser.getVersion` frame
     * into its fd 3 produced `throw er; // Unhandled 'error' event` and took the
     * whole Node process down. On a headless host that process is the daemon,
     * so a browser that failed to start would kill the sessions, the pairing and
     * the relay connection along with it — and the operator's only clue would be
     * a V8 stack trace in a log.
     *
     * So it is caught and turned into the same close every other end-of-pipe
     * goes through: everything in flight rejects with a named error, the close
     * listeners fire, and `browser-headless-host.ts` reports a sentence.
     */
    if (typeof out.on === 'function') {
      out.on('error', (error) => this.close(error))
    }
  }

  /**
   * Send one command and resolve when its reply arrives.
   *
   * The single door onto the wire. The caller — always `browser-driver.ts`'s
   * `send()` — has already screened `{ method, params }` through `screenCommand`
   * with `transport: 'cdp'`; this assigns the id, frames it, and returns a
   * promise that settles with the reply's `result` or rejects with its `error`.
   */
  command(command: CdpCommand): Promise<unknown> {
    if (this.closed) {
      return Promise.reject(new Error('the debugger pipe is closed'))
    }
    const id = ++this.nextId
    const frame: Record<string, unknown> = { id, method: command.method }
    if (command.params !== undefined) frame.params = command.params
    if (command.sessionId !== undefined) frame.sessionId = command.sessionId
    return new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.enqueue(frame)
    })
  }

  /**
   * Subscribe to events for one session, or to browser-level events with
   * `undefined`. Returns an unsubscribe.
   */
  on(sessionId: string | undefined, listener: (event: CdpEvent) => void): () => void {
    const key = sessionId ?? ''
    let set = this.listeners.get(key)
    if (set === undefined) {
      set = new Set()
      this.listeners.set(key, set)
    }
    set.add(listener)
    return () => {
      set?.delete(listener)
    }
  }

  /** Called when the pipe ends — fd EOF, an error, or an explicit {@link close}. */
  onClose(listener: (error?: Error) => void): () => void {
    this.closeListeners.add(listener)
    return () => {
      this.closeListeners.delete(listener)
    }
  }

  /**
   * Tear the pipe down: reject everything still in flight and tell the close
   * listeners. It does NOT touch the Chromium process — the launcher owns the
   * child's lifetime, and a pipe that killed the browser would be the
   * `browser.close()`-in-a-finally instability this whole feature avoids.
   */
  close(error?: Error): void {
    if (this.closed) return
    this.closed = true
    const reason = error ?? new Error('the debugger pipe closed')
    for (const pending of this.pending.values()) pending.reject(reason)
    this.pending.clear()
    for (const listener of [...this.closeListeners]) listener(error)
  }

  /** How many commands are awaiting a reply. Test seam for the in-flight count. */
  get inFlight(): number {
    return this.pending.size
  }

  /* --------------------------------------------------------------- sending -- */

  private enqueue(frame: Record<string, unknown>): void {
    // JSON.stringify escapes any control character, so the NUL appended here is
    // the only NUL in the buffer and the reader can split on it safely.
    this.queue.push(Buffer.from(JSON.stringify(frame) + '\0', 'utf8'))
    this.pump()
  }

  /**
   * The one place bytes go onto the fd.
   *
   * It respects backpressure: `write` returns false when the pipe's buffer is
   * full, and the next frame is held until `drain` rather than piled on top —
   * so a slow reader on the far end leaves exactly one frame in flight, not a
   * growing queue in this process. `browser-cdp-pipe.test.ts` pins that this is
   * the sole write site.
   */
  private pump(): void {
    if (this.paused || this.closed) return
    while (this.queue.length > 0) {
      const frame = this.queue.shift() as Buffer
      let ok: boolean
      try {
        ok = this.out.write(frame)
      } catch (error) {
        // A stream that has already been destroyed throws here rather than
        // emitting — `ERR_STREAM_DESTROYED` — which is the other half of the
        // dead-browser case the constructor's `'error'` listener covers. Same
        // answer: the pipe is closed with a named reason, and nothing in flight
        // is left waiting for a reply that cannot come.
        this.close(error instanceof Error ? error : new Error('the debugger pipe could not be written to'))
        return
      }
      if (!ok) {
        this.paused = true
        this.out.once('drain', () => {
          this.paused = false
          this.pump()
        })
        return
      }
    }
  }

  /* ------------------------------------------------------------- receiving -- */

  private receive(chunk: Buffer): void {
    const buffer = this.leftover.length === 0 ? chunk : Buffer.concat([this.leftover, chunk])
    let start = 0
    let nul = buffer.indexOf(NUL, start)
    while (nul !== -1) {
      if (nul > start) this.dispatch(buffer.subarray(start, nul))
      start = nul + 1
      nul = buffer.indexOf(NUL, start)
    }
    // Keep the tail — a frame split across two chunks — as its own buffer, not a
    // view onto the concatenated one, so nothing holds the whole chunk alive.
    this.leftover = start >= buffer.length ? Buffer.alloc(0) : Buffer.from(buffer.subarray(start))
  }

  private dispatch(slice: Buffer): void {
    let frame: unknown
    try {
      frame = JSON.parse(slice.toString('utf8'))
    } catch {
      // A malformed frame is dropped rather than crashing the reader — the far
      // end is Chromium, but the discipline is the same as any wire parser's.
      return
    }
    if (isRecord(frame)) this.route(frame)
  }

  private route(frame: Record<string, unknown>): void {
    const id = frame.id
    if (typeof id === 'number') {
      const pending = this.pending.get(id)
      if (pending === undefined) return
      this.pending.delete(id)
      if (frame.error !== undefined && frame.error !== null) {
        pending.reject(toError(frame.error))
      } else {
        pending.resolve(frame.result)
      }
      return
    }
    const method = frame.method
    if (typeof method === 'string') {
      const sessionId = typeof frame.sessionId === 'string' ? frame.sessionId : undefined
      this.emit(sessionId, { sessionId, method, params: frame.params })
    }
  }

  private emit(sessionId: string | undefined, event: CdpEvent): void {
    const set = this.listeners.get(sessionId ?? '')
    if (set === undefined) return
    for (const listener of [...set]) listener(event)
  }
}

/** Turn a reply's `error` into an Error carrying the protocol code and data. */
function toError(raw: unknown): CdpCommandError {
  const source: CdpError = isRecord(raw)
    ? {
        code: typeof raw.code === 'number' ? raw.code : undefined,
        message: typeof raw.message === 'string' ? raw.message : 'CDP command failed',
        data: raw.data,
      }
    : { message: 'CDP command failed' }
  const error = new Error(source.message) as CdpCommandError
  if (source.code !== undefined) error.code = source.code
  if (source.data !== undefined) error.data = source.data
  return error
}
