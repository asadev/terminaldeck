import { spawn, type ChildProcess } from 'node:child_process'
import { randomBytes, randomUUID } from 'node:crypto'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { connect, type Socket } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Engine } from './engine'
import { encodeFrame, FRAME, FrameReader } from './frames'

/**
 * One running copy of the device engine, and the one connection to it.
 *
 * ## The shape of a conversation with it
 *
 * Documented by the engine (`docs/protocol.md`, protocol version 4) and
 * re-stated here only as far as this client depends on it:
 *
 *  1. Start `simview-core serve` with a fresh socket path in a private folder
 *     and a random token written to its **stdin** — never its arguments, which
 *     every other process on the Mac can read with `ps`.
 *  2. Connect, and the first request must be `hello` with that token. Anything
 *     else, or nothing within the engine's deadline, and it hangs up.
 *  3. After that, JSON requests with ids and JSON responses that echo them, and
 *     in between them pictures: a JPEG per screen change once a preview has
 *     been switched on, and a PNG straight after a screenshot's response.
 *
 * ## One engine per device, owned by this process
 *
 * `--parent-pid` is this process, so if the app is killed the engine notices
 * and exits on its own instead of holding a simulator's screen open for ever;
 * `--idle-timeout` is the second net. The engine has its own way of sharing one
 * copy between several of its own clients, through a registry in the user's
 * temporary folder. This app does not join it: that registry's layout is not
 * part of the documented protocol, and a change to it in some later version
 * would break this app in a way nothing here could detect. Two engines looking
 * at one simulator is a supported arrangement — it is what happens whenever two
 * incompatible builds of the engine meet.
 */

/** Protocol version this client speaks. The engine refuses any other. */
export const PROTOCOL_VERSION = 4

/** A failure the engine itself reported, with its stable code. */
export class EngineError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly recoverable: boolean,
  ) {
    super(message)
  }
}

interface Pending {
  method: string
  resolve(value: unknown): void
  reject(error: Error): void
  timer: ReturnType<typeof setTimeout>
}

/**
 * How long each kind of request is allowed, in milliseconds.
 *
 * Most answer in tens of milliseconds. The exceptions were measured or are
 * documented: starting capture right after an app launch took most of a minute
 * once on this Mac, an orientation change waits for the rotation animation, and
 * starting the XCTest runner inside a simulator is a build-less test launch
 * with a thirty-second budget of the engine's own.
 */
function timeoutFor(method: string): number {
  if (method === 'accessibility.enableXCTestProvider') return 45_000
  if (method === 'capture.start' || method === 'device.orientation.set') return 30_000
  if (method === 'capture.screenshot') return 20_000
  return 10_000
}

export interface CoreClientOptions {
  engine: Engine
  deviceId: string
  /**
   * Which stream the engine sends. `h264` is the engine's own preferred path —
   * VideoToolbox on the Mac, a hardware decoder in the window — and the one its
   * own preview uses. `mjpeg` is a whole JPEG per change, kept for a window
   * that cannot decode H.264. Measured on an iPhone 17 Pro simulator, 0.16.1:
   * MJPEG managed 11.8 frames a second while scrolling at 21 Mbit/s of
   * full-resolution JPEGs; see `session.ts`.
   */
  codec?: 'h264' | 'mjpeg'
  maxWidth?: number
  maxHeight?: number
  maxFrameRate?: number
}

/** One unit of the H.264 stream: the decoder's configuration, or one coded picture. */
export type VideoPacket = { kind: 'config'; avcC: Buffer } | { kind: 'chunk'; data: Buffer }

export class CoreClient {
  private readonly pending = new Map<string, Pending>()
  private readonly reader = new FrameReader()
  private readonly jpegListeners = new Set<(jpeg: Buffer) => void>()
  private readonly videoListeners = new Set<(packet: VideoPacket) => void>()
  private readonly closeListeners = new Set<(reason: string) => void>()
  /** Screenshot requests, one at a time, each waiting for the PNG after its response. */
  private pngWaiter: ((png: Buffer) => void) | null = null
  private shotChain: Promise<unknown> = Promise.resolve()
  private closed = false
  private stderrTail = ''

  private constructor(
    private readonly socket: Socket,
    private readonly child: ChildProcess | null,
    private readonly folder: string | null,
  ) {
    socket.on('data', (chunk: Buffer) => {
      let frames
      try {
        frames = this.reader.push(chunk)
      } catch (error) {
        this.shutDown(error instanceof Error ? error.message : String(error))
        return
      }
      for (const frame of frames) this.handle(frame.kind, frame.payload)
    })
    socket.on('error', (error) => this.shutDown(error.message))
    socket.on('close', () => this.shutDown('The simulator engine closed the connection.'))
    child?.stderr?.on('data', (chunk: Buffer) => {
      // The last few hundred characters only. It is read once, to explain a
      // start that failed, and an engine that logs for an hour must not grow
      // this string for an hour.
      this.stderrTail = (this.stderrTail + chunk.toString('utf8')).slice(-800)
    })
    child?.on('exit', () => this.shutDown('The simulator engine stopped.'))
  }

  /**
   * Start an engine for one device and complete the handshake.
   *
   * Rejects with a sentence a person can read; every path out of here that
   * fails also stops the process it started and removes its folder.
   */
  static async start(options: CoreClientOptions): Promise<CoreClient> {
    const folder = mkdtempSync(join(tmpdir(), 'tdsim-'))
    const socketPath = join(folder, 'core.sock')
    const token = randomBytes(32).toString('hex')
    const child = spawn(
      options.engine.core,
      [
        'serve',
        '--socket',
        socketPath,
        '--token-fd',
        '0',
        '--parent-pid',
        String(process.pid),
        '--idle-timeout',
        '120',
        '--device-id',
        options.deviceId,
      ],
      { stdio: ['pipe', 'ignore', 'pipe'], env: { ...process.env, ...options.engine.env } },
    )
    child.stdin?.end(token)
    let exited = false
    child.once('exit', () => {
      exited = true
    })
    const cleanup = (): void => {
      if (!exited) child.kill('SIGTERM')
      rmSync(folder, { recursive: true, force: true })
    }
    try {
      const socket = await waitForSocket(socketPath, () => exited, 10_000)
      const client = new CoreClient(socket, child, folder)
      await client.hello(token, options)
      return client
    } catch (error) {
      cleanup()
      throw error instanceof Error ? error : new Error(String(error))
    }
  }

  /** Join an engine somebody else started. Tests use this against a fake one. */
  static async attach(socketPath: string, token: string, options: Partial<CoreClientOptions> = {}): Promise<CoreClient> {
    const socket = await waitForSocket(socketPath, () => false, 5_000)
    const client = new CoreClient(socket, null, null)
    await client.hello(token, options)
    return client
  }

  private async hello(token: string, options: Partial<CoreClientOptions>): Promise<void> {
    await this.request('hello', {
      token,
      codecs: [options.codec ?? 'mjpeg'],
      ...(options.maxWidth ? { maxWidth: options.maxWidth } : {}),
      ...(options.maxHeight ? { maxHeight: options.maxHeight } : {}),
      maxFrameRate: options.maxFrameRate ?? 30,
    })
  }

  get isClosed(): boolean {
    return this.closed
  }

  private handle(kind: number, payload: Buffer): void {
    if (kind === FRAME.response) {
      let message: { id?: unknown; result?: unknown; error?: { message?: unknown; code?: unknown; recoverable?: unknown } }
      try {
        message = JSON.parse(payload.toString('utf8'))
      } catch {
        return
      }
      if (typeof message.id !== 'string') return
      const waiting = this.pending.get(message.id)
      if (!waiting) return
      this.pending.delete(message.id)
      clearTimeout(waiting.timer)
      if (message.error) {
        const text = typeof message.error.message === 'string' ? message.error.message : 'The simulator engine refused that.'
        const code = typeof message.error.code === 'string' ? message.error.code : 'ENGINE_ERROR'
        waiting.reject(new EngineError(text, code, message.error.recoverable === true))
      } else {
        waiting.resolve(message.result)
      }
      return
    }
    if (kind === FRAME.jpeg) {
      for (const listener of this.jpegListeners) listener(payload)
      return
    }
    if (kind === FRAME.h264Config || kind === FRAME.h264Data) {
      // Passed on as the engine framed it: for a chunk, an 8-byte big-endian
      // microsecond timestamp, a keyframe flag byte, then the AVCC picture —
      // which is exactly what the window's decoder is fed.
      const packet: VideoPacket = kind === FRAME.h264Config ? { kind: 'config', avcC: payload } : { kind: 'chunk', data: payload }
      for (const listener of this.videoListeners) listener(packet)
      return
    }
    if (kind === FRAME.png) {
      const waiter = this.pngWaiter
      this.pngWaiter = null
      waiter?.(payload)
    }
  }

  /** Send one request and wait for its answer. */
  request<T = unknown>(method: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<T> {
    if (this.closed) return Promise.reject(new Error('The simulator engine is not running.'))
    const id = randomUUID()
    const body = Buffer.from(JSON.stringify({ id, protocolVersion: PROTOCOL_VERSION, method, params }), 'utf8')
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new EngineError(`The simulator did not answer in time (${method}).`, 'TIMEOUT', true))
      }, timeoutMs ?? timeoutFor(method))
      this.pending.set(id, { method, resolve: (value) => resolve(value as T), reject, timer })
      // A socket the engine has already hung up on is closed here rather than
      // written to: the write would fail with EPIPE a tick later, after this
      // promise had been handed to somebody expecting an answer.
      if (this.socket.destroyed || !this.socket.writable) {
        this.shutDown('The simulator engine closed the connection.')
        return
      }
      this.socket.write(encodeFrame(FRAME.request, body))
    })
  }

  /**
   * A full-resolution PNG of the screen.
   *
   * The engine answers the request with the picture's size and then sends the
   * PNG as a separate frame with no id on it. So these are queued: two in
   * flight at once could not be told apart.
   */
  screenshot(): Promise<{ png: Buffer; width: number; height: number }> {
    const run = async (): Promise<{ png: Buffer; width: number; height: number }> => {
      const arrived = new Promise<Buffer>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.pngWaiter = null
          reject(new EngineError('The screenshot did not arrive.', 'TIMEOUT', true))
        }, 25_000)
        this.pngWaiter = (png) => {
          clearTimeout(timer)
          resolve(png)
        }
      })
      // The waiter goes in first: the PNG can arrive in the same read as the
      // response, before this line's promise has even been looked at.
      const meta = await this.request<{ width: number; height: number }>('capture.screenshot').catch((error) => {
        this.pngWaiter = null
        throw error
      })
      const png = await arrived
      return { png, width: meta.width, height: meta.height }
    }
    const next = this.shotChain.then(run, run)
    this.shotChain = next.catch(() => undefined)
    return next
  }

  onVideo(listener: (packet: VideoPacket) => void): () => void {
    this.videoListeners.add(listener)
    return () => this.videoListeners.delete(listener)
  }

  onJpeg(listener: (jpeg: Buffer) => void): () => void {
    this.jpegListeners.add(listener)
    return () => this.jpegListeners.delete(listener)
  }

  onClose(listener: (reason: string) => void): () => void {
    this.closeListeners.add(listener)
    return () => this.closeListeners.delete(listener)
  }

  /** What the engine last printed, for a start that failed. */
  get lastWords(): string {
    return this.stderrTail.trim()
  }

  private shutDown(reason: string): void {
    if (this.closed) return
    this.closed = true
    for (const waiting of this.pending.values()) {
      clearTimeout(waiting.timer)
      waiting.reject(new Error(reason))
    }
    this.pending.clear()
    this.socket.destroy()
    if (this.child && this.child.exitCode === null) this.child.kill('SIGTERM')
    if (this.folder) rmSync(this.folder, { recursive: true, force: true })
    for (const listener of this.closeListeners) {
      try {
        listener(reason)
      } catch {
        // One listener's fault must not stop the others hearing about the close.
      }
    }
  }

  /** Ask the engine to stop, then make sure it has. */
  async close(): Promise<void> {
    if (this.closed) return
    await this.request('server.shutdown', {}, 2_000).catch(() => undefined)
    const child = this.child
    if (child && child.exitCode === null) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          child.kill('SIGKILL')
          resolve()
        }, 3_000)
        child.once('exit', () => {
          clearTimeout(timer)
          resolve()
        })
      })
    }
    this.shutDown('Closed.')
  }
}

/** Wait for the engine's socket to accept a connection, or for the engine to die. */
async function waitForSocket(path: string, dead: () => boolean, budgetMs: number): Promise<Socket> {
  const deadline = Date.now() + budgetMs
  while (Date.now() < deadline) {
    if (dead()) throw new Error('The simulator engine stopped before it was ready.')
    if (existsSync(path)) {
      const socket = await new Promise<Socket | null>((resolve) => {
        const attempt = connect(path)
        attempt.once('connect', () => resolve(attempt))
        attempt.once('error', () => resolve(null))
      })
      if (socket) return socket
    }
    await new Promise((resolve) => setTimeout(resolve, 30))
  }
  throw new Error('The simulator engine did not start in time.')
}
