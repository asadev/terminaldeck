/**
 * One running plugin: a child process, and the conversation on its stdin and
 * stdout.
 *
 * ## The wire
 *
 * JSON-RPC 2.0, one message per line — the framing MCP's stdio transport uses,
 * so anybody who has written an MCP server has written this. Both sides ask:
 * this app sends `initialize`, `tools/call` and a `shutdown` notification; the
 * plugin sends the requests its capabilities cover (`tasks.list`, `notify`, …),
 * each of which {@link PluginProcessOptions.onRequest} answers or refuses.
 *
 * ## The bounds, and why each one kills rather than complains
 *
 *  - **A message larger than {@link MAX_MESSAGE_BYTES}.** Counted on the bytes
 *    as they arrive, before a newline is found and before anything is parsed —
 *    the only measurement that bounds the work, the same reasoning
 *    `MAX_MANIFEST_BYTES` gives. A plugin streaming a line with no end would
 *    otherwise grow this process's memory for as long as it liked.
 *  - **A request it does not answer in time.** A plugin that has stopped
 *    answering one question has stopped answering, and every later call would
 *    queue behind it. So the timeout stops the process; the next call that needs
 *    it starts it again, from nothing.
 *  - **A line that is not a message.** Not JSON, or JSON in no shape this
 *    protocol has. A peer that writes garbage on the channel that carries its
 *    permissions is not one to keep talking to.
 *  - **Too many of its own requests at once.** Refused one at a time with an
 *    error, not a kill: a plugin with a burst of work is not misbehaving, and
 *    the refusal tells it to wait.
 *
 * Every kill carries a sentence, and the sentence is what the Settings pane
 * shows under a plugin that stopped.
 *
 * ## No shell, anywhere
 *
 * `spawn` with an argument list and `shell: false`. The command is this app's
 * own runtime (or `sandbox-exec` in front of it), and the only argument that
 * came from the plugin is the path of its main file — already checked to be
 * inside its own folder.
 */

import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process'

/** The largest message either side may send, in bytes of one line. */
export const MAX_MESSAGE_BYTES = 256 * 1024

/** How long a request waits for its answer before the plugin is stopped. */
export const DEFAULT_REQUEST_TIMEOUT_MS = 30_000

/** How many of the plugin's own requests may be in hand at once. */
export const MAX_PLUGIN_REQUESTS = 8

/** How long a plugin asked to stop has before it is made to. */
export const STOP_GRACE_MS = 1_000

/** Kept from what the plugin wrote on stderr, for the sentence under a plugin that stopped. */
const STDERR_TAIL = 300

export type Spawner = (command: string, args: readonly string[], options: SpawnOptions) => ChildProcess

/** A refusal or failure with a JSON-RPC code, as the plugin receives it. */
export class PluginError extends Error {
  constructor(
    readonly code: number,
    message: string,
  ) {
    super(message)
    this.name = 'PluginError'
  }
}

/** The codes this protocol uses. The first two are JSON-RPC's own. */
export const ERROR_CODES = Object.freeze({
  unknownMethod: -32601,
  badParams: -32602,
  failed: -32000,
  notDeclared: -32001,
  notGranted: -32002,
  unavailable: -32003,
  busy: -32004,
  tooLarge: -32005,
})

export interface PluginProcessOptions {
  command: string
  args: readonly string[]
  cwd: string
  env: Record<string, string>
  /** Answer one request the plugin made. Throw {@link PluginError} to refuse it. */
  onRequest(method: string, params: unknown): Promise<unknown>
  /** Called once, when the process is gone, with why. */
  onExit(why: string): void
  timeoutMs?: number
  maxMessageBytes?: number
  spawner?: Spawner
}

interface Pending {
  method: string
  resolve(value: unknown): void
  reject(error: Error): void
  timer: ReturnType<typeof setTimeout>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export class PluginProcess {
  private child: ChildProcess | null = null
  private readonly pending = new Map<number, Pending>()
  private nextId = 1
  private buffer: Buffer[] = []
  private buffered = 0
  private inFlight = 0
  private stderrTail = ''
  private exitReason: string | null = null
  private exited = false
  /** Killed and not yet reaped: already not alive, so nothing new is sent to it or started behind it. */
  private killed = false
  private readonly timeoutMs: number
  private readonly maxBytes: number

  constructor(private readonly options: PluginProcessOptions) {
    this.timeoutMs = Math.max(Math.trunc(options.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS), 1)
    this.maxBytes = Math.max(Math.trunc(options.maxMessageBytes ?? MAX_MESSAGE_BYTES), 64)
  }

  get alive(): boolean {
    return this.child !== null && !this.exited && !this.killed
  }

  get pid(): number | null {
    return this.child?.pid ?? null
  }

  start(): void {
    if (this.child !== null) throw new Error('plugins: a process is started once')
    const spawner = this.options.spawner ?? spawn
    const child = spawner(this.options.command, this.options.args, {
      cwd: this.options.cwd,
      env: this.options.env,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false,
      windowsHide: true,
    })
    this.child = child
    child.stdout?.on('data', (chunk: Buffer) => this.receive(chunk))
    child.stderr?.on('data', (chunk: Buffer) => {
      this.stderrTail = `${this.stderrTail}${chunk.toString('utf8')}`.slice(-STDERR_TAIL)
    })
    // A write to a pipe the child already closed is an exit in progress, not a crash of this app.
    child.stdin?.on('error', () => undefined)
    child.on('error', (error) => this.gone(`it could not be started (${error.message})`))
    child.on('exit', (code, signal) => {
      const said = this.stderrTail.trim().split('\n').pop()?.trim() ?? ''
      const how = signal !== null ? `it was stopped (${signal})` : `it exited with code ${String(code)}`
      this.gone(said === '' ? how : `${how}; it last wrote: ${said}`)
    })
  }

  /** Ask the plugin something and wait for the answer. */
  request(method: string, params: unknown, options: { timeoutMs?: number; signal?: AbortSignal } = {}): Promise<unknown> {
    if (!this.alive) return Promise.reject(new PluginError(ERROR_CODES.failed, 'the plugin is not running'))
    const id = this.nextId++
    const line = JSON.stringify({ jsonrpc: '2.0', id, method, params })
    if (Buffer.byteLength(line, 'utf8') > this.maxBytes) {
      return Promise.reject(new PluginError(ERROR_CODES.tooLarge, `that request is larger than ${this.maxBytes} bytes`))
    }
    const wait = Math.max(Math.min(Math.trunc(options.timeoutMs ?? this.timeoutMs), this.timeoutMs), 1)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.kill(`it did not answer ${method} within ${Math.round(wait / 100) / 10} seconds`)
      }, wait)
      timer.unref?.()
      this.pending.set(id, { method, resolve, reject, timer })
      options.signal?.addEventListener(
        'abort',
        () => {
          const entry = this.pending.get(id)
          if (!entry) return
          this.pending.delete(id)
          clearTimeout(entry.timer)
          entry.reject(new PluginError(ERROR_CODES.failed, 'the caller hung up'))
        },
        { once: true },
      )
      this.write(line)
    })
  }

  /** Tell the plugin something that needs no answer. */
  notify(method: string, params?: unknown): void {
    if (!this.alive) return
    this.write(JSON.stringify({ jsonrpc: '2.0', method, ...(params === undefined ? {} : { params }) }))
  }

  /**
   * Stop it: a `shutdown` notification and a closed stdin, then a kill if it is
   * still there after {@link STOP_GRACE_MS}. Resolves once it has gone.
   */
  async stop(why = 'it was stopped'): Promise<void> {
    if (!this.alive) return
    this.exitReason ??= why
    const child = this.child as ChildProcess
    const exited = new Promise<void>((resolve) => child.once('exit', () => resolve()))
    this.notify('shutdown')
    child.stdin?.end()
    const timer = setTimeout(() => child.kill('SIGKILL'), STOP_GRACE_MS)
    timer.unref?.()
    await exited
    clearTimeout(timer)
  }

  /** Stop it now, saying why. */
  kill(why: string): void {
    if (!this.alive) return
    this.exitReason ??= why
    this.killed = true
    this.child?.kill('SIGKILL')
    // Everything waiting is refused at once rather than when the exit event arrives.
    this.failPending(why)
  }

  private write(line: string): void {
    try {
      this.child?.stdin?.write(`${line}\n`)
    } catch {
      /* the exit handler reports it */
    }
  }

  private failPending(why: string): void {
    for (const [id, entry] of [...this.pending]) {
      this.pending.delete(id)
      clearTimeout(entry.timer)
      entry.reject(new PluginError(ERROR_CODES.failed, `the plugin stopped: ${why}`))
    }
  }

  private gone(how: string): void {
    if (this.exited) return
    this.exited = true
    const why = this.exitReason ?? how
    this.failPending(why)
    this.buffer = []
    this.buffered = 0
    this.options.onExit(why)
  }

  private receive(chunk: Buffer): void {
    if (this.exited || this.exitReason !== null) return
    let rest = chunk
    for (;;) {
      const newline = rest.indexOf(0x0a)
      if (newline === -1) {
        this.buffered += rest.length
        if (this.buffered > this.maxBytes) {
          this.kill(`it sent a message larger than ${this.maxBytes} bytes`)
          return
        }
        if (rest.length > 0) this.buffer.push(rest)
        return
      }
      const head = rest.subarray(0, newline)
      if (this.buffered + head.length > this.maxBytes) {
        this.kill(`it sent a message larger than ${this.maxBytes} bytes`)
        return
      }
      const line = Buffer.concat([...this.buffer, head]).toString('utf8').trim()
      this.buffer = []
      this.buffered = 0
      rest = rest.subarray(newline + 1)
      if (line !== '') this.handle(line)
      if (this.exitReason !== null) return
    }
  }

  private handle(line: string): void {
    let message: unknown
    try {
      message = JSON.parse(line)
    } catch {
      this.kill('it sent something that is not a message')
      return
    }
    if (!isRecord(message) || message.jsonrpc !== '2.0') {
      this.kill('it sent something that is not a message')
      return
    }
    const hasId = typeof message.id === 'number' || typeof message.id === 'string'
    if (typeof message.method === 'string') {
      // A notification from the plugin has nothing this app listens for.
      if (hasId) void this.answer(message.id as number | string, message.method, message.params)
      return
    }
    if (typeof message.id !== 'number') {
      this.kill('it sent something that is not a message')
      return
    }
    const entry = this.pending.get(message.id)
    if (!entry) return
    this.pending.delete(message.id)
    clearTimeout(entry.timer)
    if (isRecord(message.error)) {
      const code = typeof message.error.code === 'number' ? message.error.code : ERROR_CODES.failed
      const text = typeof message.error.message === 'string' ? message.error.message.slice(0, 500) : 'the plugin refused'
      entry.reject(new PluginError(code, text))
    } else {
      entry.resolve(message.result)
    }
  }

  private async answer(id: number | string, method: string, params: unknown): Promise<void> {
    if (this.inFlight >= MAX_PLUGIN_REQUESTS) {
      this.reply(id, null, new PluginError(ERROR_CODES.busy, `at most ${MAX_PLUGIN_REQUESTS} requests may wait at once`))
      return
    }
    this.inFlight += 1
    try {
      this.reply(id, await this.options.onRequest(method, params), null)
    } catch (error) {
      this.reply(
        id,
        null,
        error instanceof PluginError ? error : new PluginError(ERROR_CODES.failed, error instanceof Error ? error.message : String(error)),
      )
    } finally {
      this.inFlight -= 1
    }
  }

  private reply(id: number | string, result: unknown, error: PluginError | null): void {
    if (!this.alive) return
    let line =
      error === null
        ? JSON.stringify({ jsonrpc: '2.0', id, result: result ?? null })
        : JSON.stringify({ jsonrpc: '2.0', id, error: { code: error.code, message: error.message } })
    if (Buffer.byteLength(line, 'utf8') > this.maxBytes) {
      line = JSON.stringify({
        jsonrpc: '2.0',
        id,
        error: { code: ERROR_CODES.tooLarge, message: `the answer is larger than ${this.maxBytes} bytes` },
      })
    }
    this.write(line)
  }
}
