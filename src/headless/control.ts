/**
 * How `terminaldeck status` reaches the host that has been running for a week.
 *
 * The CLI and the daemon are two processes, and they have to talk. This is the
 * smallest thing that can carry four commands: a Unix domain socket in the state
 * directory (a named pipe on Windows), one JSON object per line, one request per
 * connection.
 *
 * ## Why not a loopback HTTP port
 *
 * Because a port is reachable by every process on the machine, and two of these
 * commands are not read-only — `pair` mints a code that lets a stranger's device
 * in, and `stop` ends every session. A Unix socket is a filesystem object with
 * an owner and a mode, so "only this user" is enforced by the kernel rather than
 * by a check somebody has to remember to write.
 *
 * ## Why there is a token as well
 *
 * Because Windows named pipes do not inherit that guarantee, and because a
 * socket left behind by a crashed daemon can be inherited by whatever binds it
 * next. The token lives in a 0600 file beside the socket and is compared with a
 * constant-time equality — the same rule the rest of this codebase follows for
 * anything a caller can guess at repeatedly. A caller that cannot read the file
 * cannot talk to the host, which is the same boundary the socket already draws
 * and costs one field to make true on both platforms.
 *
 * ## Why one request per connection
 *
 * There is no session state to keep and no reason to multiplex: the CLI runs one
 * command and exits. A long-lived control connection would need its own
 * heartbeat, and the standing rule here is one heartbeat layer, not two.
 */

import { timingSafeEqual } from 'node:crypto'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { createConnection, createServer, type Server, type Socket } from 'node:net'
import { join } from 'node:path'
import { BRAND } from '../shared/brand'
import { writeSecretFile } from '../main/remote/secret-file'
import type { Platform } from '../main/platform/host'

/** The file that says a host is running, and how to reach it. */
export const RECORD_FILE = 'host.json'

/** Nothing useful is this big. A control message is a command and two words. */
export const MAX_CONTROL_BYTES = 64 * 1024

export interface ControlRequest {
  token: string
  cmd: string
  args: string[]
}

/**
 * Why a call failed, for the one difference a caller has to *act* on.
 *
 * `no-listener` means the socket named in the record answered nothing, because
 * there is no file there or nothing is bound to it. Every other failure — a
 * refused token, a command that threw, a host that is up and wedged — is a
 * sentence to show and nothing more, so none of them gets a code.
 *
 * The distinction exists because the record on disk is not proof. It survives a
 * machine that has been switched off, and {@link processAlive} can only ask
 * whether *a* process holds that pid, not whether it is this host: a WSL
 * distribution restarts pids from 1, so a record written by a host systemd
 * started early in the previous boot names a pid that almost certainly belongs
 * to something else now. Asking the socket is the only thing that actually
 * proves a host is there, and this field is how the answer gets back.
 */
export type ControlFailure = 'no-listener'

export type ControlResponse =
  | { ok: true; value: unknown }
  | { ok: false; error: string; reason?: ControlFailure }

export interface DaemonRecord {
  pid: number
  /** Where to connect. Absolute path, or a `\\.\pipe\…` name on Windows. */
  socket: string
  token: string
  startedAt: number
  version: string
}

/* ------------------------------------------------------------------ paths -- */

/**
 * Where the socket and the record live for a given state directory.
 *
 * The socket is beside the state rather than in `/tmp` on purpose: `/tmp` is
 * shared, world-writable and cleaned by the system on a schedule nobody
 * controls, and a control socket that a stranger can pre-create is a control
 * socket a stranger can answer.
 *
 * The one cost is a real one and worth naming: a Unix socket path is limited to
 * about 104 bytes on macOS and 108 on Linux, and a state directory under a very
 * long home would exceed it. `bind` fails loudly with ENAMETOOLONG when it does,
 * which is the correct direction to fail — the alternative is a host that runs
 * with no way to talk to it.
 */
export function controlPaths(
  stateDir: string,
  platform: Platform,
): { socket: string; record: string } {
  const record = join(stateDir, RECORD_FILE)
  if (platform === 'win32') {
    // Named pipes are not files and do not live in a directory. The state
    // directory is still what makes the name unique to this install, so it is
    // folded in rather than assuming one host per machine.
    const tag = stateDir.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase()
    return { socket: `\\\\.\\pipe\\${BRAND.id}-${tag || 'host'}`, record }
  }
  return { socket: join(stateDir, 'host.sock'), record }
}

/* ----------------------------------------------------------------- record -- */

export function writeDaemonRecord(stateDir: string, record: DaemonRecord): void {
  // 0600, through a temp file and a rename, exactly as every other secret this
  // app writes. The token is a bearer secret; it does not get a weaker file than
  // the relay identity does. `writeSecretFile` wants the directory and the *full
  // path* — the directory is what it creates and fsyncs, the path is what it
  // renames onto — which is why the join is not redundant.
  writeSecretFile(stateDir, join(stateDir, RECORD_FILE), JSON.stringify(record, null, 2))
}

export function readDaemonRecord(stateDir: string): DaemonRecord | null {
  try {
    const raw: unknown = JSON.parse(readFileSync(join(stateDir, RECORD_FILE), 'utf8'))
    return parseDaemonRecord(raw)
  } catch {
    // Absent is the ordinary case — no host has ever run here. Corrupt is
    // treated the same way: the next start overwrites it, and reporting "not
    // running" for an unreadable record is both true and actionable.
    return null
  }
}

export function parseDaemonRecord(raw: unknown): DaemonRecord | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  const { pid, socket, token, startedAt, version } = value
  if (typeof pid !== 'number' || !Number.isInteger(pid) || pid <= 0) return null
  if (typeof socket !== 'string' || socket === '') return null
  if (typeof token !== 'string' || token === '') return null
  if (typeof startedAt !== 'number') return null
  if (typeof version !== 'string') return null
  return { pid, socket, token, startedAt, version }
}

export function clearDaemonRecord(stateDir: string, platform: Platform): void {
  const { socket, record } = controlPaths(stateDir, platform)
  try {
    rmSync(record, { force: true })
  } catch {
    /* a record we cannot delete is a record the next start overwrites */
  }
  if (platform !== 'win32') {
    try {
      rmSync(socket, { force: true })
    } catch {
      /* likewise: bind() removes a stale one before listening */
    }
  }
}

/**
 * Is the process in this record still there?
 *
 * `kill(pid, 0)` asks the kernel without sending anything. It is the only honest
 * way to tell "the daemon is running" from "the daemon died and left its record
 * behind", and telling those apart is the difference between `status` saying
 * "not running" and `status` hanging on a socket nobody is listening to.
 *
 * EPERM means the process exists and belongs to somebody else, which cannot
 * happen for a record in this user's own state directory — but it is still
 * "alive", and treating it as dead would have `pair` start a second host.
 */
export function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM'
  }
}

/* ------------------------------------------------------------------ token -- */

/**
 * Compare two tokens without leaking where they differ.
 *
 * `timingSafeEqual` throws on a length mismatch, so the length is checked first
 * — which does leak the length, and that is fine and unavoidable: the token is
 * fixed-width, so its length is public by construction.
 */
export function tokenMatches(expected: string, presented: string): boolean {
  const a = Buffer.from(expected, 'utf8')
  const b = Buffer.from(presented, 'utf8')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/* ------------------------------------------------------------------ frame -- */

export function encodeRequest(request: ControlRequest): string {
  return `${JSON.stringify(request)}\n`
}

export function parseRequest(line: string): ControlRequest | null {
  let raw: unknown
  try {
    raw = JSON.parse(line)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (typeof value.token !== 'string' || typeof value.cmd !== 'string') return null
  const args = Array.isArray(value.args) ? value.args : []
  if (!args.every((arg): arg is string => typeof arg === 'string')) return null
  return { token: value.token, cmd: value.cmd, args }
}

export function encodeResponse(response: ControlResponse): string {
  return `${JSON.stringify(response)}\n`
}

export function parseResponse(line: string): ControlResponse {
  let raw: unknown
  try {
    raw = JSON.parse(line)
  } catch {
    return { ok: false, error: 'The host answered with something that is not a message.' }
  }
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, error: 'The host answered with something that is not a message.' }
  }
  const value = raw as Record<string, unknown>
  if (value.ok === true) return { ok: true, value: value.value }
  return {
    ok: false,
    error: typeof value.error === 'string' ? value.error : 'The host refused, and did not say why.',
  }
}

/* ----------------------------------------------------------------- server -- */

export interface ControlServerOptions {
  socket: string
  token: string
  /** Runs one command. Throwing is fine; the message reaches the caller. */
  handle(cmd: string, args: string[]): Promise<unknown>
  platform: Platform
}

export interface ControlServer {
  close(): Promise<void>
}

export async function serveControl(options: ControlServerOptions): Promise<ControlServer> {
  // A socket file left by a crashed daemon makes `listen` fail with EADDRINUSE
  // however dead the process behind it is. The caller has already checked that
  // no live host holds this state directory, so removing it here is safe and is
  // the difference between a host that starts after a power cut and one that
  // never starts again.
  if (options.platform !== 'win32' && existsSync(options.socket)) {
    try {
      rmSync(options.socket, { force: true })
    } catch {
      /* listen will report it */
    }
  }

  const server: Server = createServer((socket) => {
    handleConnection(socket, options).catch(() => socket.destroy())
  })

  await new Promise<void>((resolve, reject) => {
    server.once('error', (error: NodeJS.ErrnoException) => reject(listenFailure(error, options.socket)))
    server.listen(options.socket, () => {
      server.removeListener('error', reject)
      resolve()
    })
  })

  return {
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve())
      }),
  }
}

/**
 * The sockaddr_un limit, which nothing tells you about until it bites.
 *
 * A Unix socket path is copied into a fixed 104-byte field on macOS and 108 on
 * Linux, and the kernel does not report that as a name-too-long error: macOS
 * answers `EINVAL`, which reads as "invalid argument" and sends a person looking
 * at the wrong thing entirely. This was hit on the first real run of the host —
 * from a state directory nested deep under a temporary home — and the process
 * printed one line of syscall and stayed alive with no control socket, which is
 * the worst of both.
 *
 * 104 is used for both, because the smaller of the two is the one that has to
 * hold on a machine this was not tested on.
 */
export const MAX_SOCKET_PATH = 104

function listenFailure(error: NodeJS.ErrnoException, socket: string): Error {
  const tooLong = socket.length >= MAX_SOCKET_PATH && (error.code === 'EINVAL' || error.code === 'ENAMETOOLONG')
  if (tooLong) {
    return new Error(
      `The control socket path is ${socket.length} characters and a Unix socket cannot be ` +
        `longer than ${MAX_SOCKET_PATH}:\n  ${socket}\n` +
        'Point XDG_DATA_HOME at a shorter directory and start the host again.',
    )
  }
  if (error.code === 'EACCES') {
    return new Error(`Not allowed to open the control socket at ${socket}: ${error.message}`)
  }
  return new Error(`Could not open the control socket at ${socket}: ${error.message}`)
}

async function handleConnection(socket: Socket, options: ControlServerOptions): Promise<void> {
  const line = await readLine(socket)
  if (line === null) {
    socket.end()
    return
  }
  const request = parseRequest(line)
  if (request === null) {
    socket.end(encodeResponse({ ok: false, error: 'That is not a control message.' }))
    return
  }
  if (!tokenMatches(options.token, request.token)) {
    // Deliberately the same sentence for a wrong token and a missing one. A
    // caller that can read the record has the token; one that cannot is not
    // owed a hint about which half it got wrong.
    socket.end(encodeResponse({ ok: false, error: 'This host did not recognise that caller.' }))
    return
  }
  try {
    const value = await options.handle(request.cmd, request.args)
    socket.end(encodeResponse({ ok: true, value }))
  } catch (error) {
    socket.end(
      encodeResponse({ ok: false, error: error instanceof Error ? error.message : String(error) }),
    )
  }
}

/**
 * Read one newline-terminated message, and refuse anything absurd.
 *
 * The cap is not about memory; it is about a caller that connects and then says
 * nothing but keeps talking. A daemon that buffered without limit would be a
 * denial of service reachable from a socket it opened itself.
 */
function readLine(socket: Socket): Promise<string | null> {
  return new Promise((resolve) => {
    let buffer = ''
    let settled = false
    const done = (value: string | null): void => {
      if (settled) return
      settled = true
      socket.removeAllListeners('data')
      resolve(value)
    }
    socket.setEncoding('utf8')
    socket.on('data', (chunk: string) => {
      buffer += chunk
      const newline = buffer.indexOf('\n')
      if (newline >= 0) {
        done(buffer.slice(0, newline))
        return
      }
      if (buffer.length > MAX_CONTROL_BYTES) done(null)
    })
    socket.once('error', () => done(null))
    socket.once('end', () => done(buffer.length > 0 ? buffer : null))
  })
}

/* ----------------------------------------------------------------- client -- */

export interface ControlCallOptions {
  socket: string
  token: string
  cmd: string
  args?: string[]
  /** How long to wait before giving up. A live host answers in milliseconds. */
  timeoutMs?: number
}

export const CONTROL_TIMEOUT_MS = 10_000

export async function callControl(options: ControlCallOptions): Promise<ControlResponse> {
  return new Promise((resolve) => {
    const socket = createConnection(options.socket)
    let buffer = ''
    let settled = false
    const finish = (response: ControlResponse): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      resolve(response)
    }

    const timer = setTimeout(
      () =>
        finish({
          ok: false,
          // Named as a timeout rather than as a refusal, because the two lead a
          // person to different places: a host that is up and wedged is a
          // different problem from a host that is not there.
          error: 'The host did not answer in time. It is running but not responding.',
        }),
      options.timeoutMs ?? CONTROL_TIMEOUT_MS,
    )

    socket.setEncoding('utf8')
    socket.on('connect', () => {
      socket.write(
        encodeRequest({ token: options.token, cmd: options.cmd, args: options.args ?? [] }),
      )
    })
    socket.on('data', (chunk: string) => {
      buffer += chunk
      const newline = buffer.indexOf('\n')
      if (newline >= 0) finish(parseResponse(buffer.slice(0, newline)))
      else if (buffer.length > MAX_CONTROL_BYTES) {
        finish({ ok: false, error: 'The host answered with more than a control message can hold.' })
      }
    })
    socket.on('end', () => {
      if (buffer.length > 0) finish(parseResponse(buffer))
      else finish({ ok: false, error: 'The host closed the connection without answering.' })
    })
    socket.on('error', (error: NodeJS.ErrnoException) => {
      // ENOENT is no socket file at all; ECONNREFUSED is a socket file whose
      // host is gone. Both mean the same thing to a caller — this record is
      // describing a host that does not exist — and both are told apart from
      // every other failure by the code, not by the sentence, so that nothing
      // has to match on prose that is free to change.
      finish(
        error.code === 'ENOENT' || error.code === 'ECONNREFUSED'
          ? { ok: false, error: 'No host is listening here.', reason: 'no-listener' }
          : { ok: false, error: `Could not reach the host: ${error.message}` },
      )
    })
  })
}
