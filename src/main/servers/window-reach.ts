/**
 * This computer's `deck-control` endpoint, reachable from the server's own
 * loopback and from nowhere else.
 *
 * ## What it is for
 *
 * `servers/forward.ts` carries a server's `localhost` here. This is the other
 * direction, and it exists for the one cell of Asad's sentence that was left
 * over:
 *
 *   > *"from any session from any device to any device's browser in one app"*
 *
 * A shell on a server is a session everywhere else in this app — a tab, a row
 * in the rail, and, since `browser-binding.ts` learnt to key a window
 * `<serverId>\0<shellId>`, browser windows of its own. He opened *Session 1
 * Office PC*, attached a window to it, and the agent in that shell could not see
 * anything: the window is a `WebContentsView` in the app on **this** screen and
 * the agent is a process on somebody else's Linux box. Nothing carried a verb
 * from the second to the first.
 *
 * For a **paired machine** the carrier is `window.call` over the relay
 * (`remote/machines/window-serve.ts`). A server has no app to speak that, so the
 * rule that is applied instead is the one the local build already uses: *let the
 * session reach the `deck-control` of the machine that owns the window*. Only
 * the transport changes — SSH instead of the relay — and this file is that
 * transport.
 *
 * ## Why this does not open the endpoint to the network
 *
 * `deck-control/server.ts` rests its whole security case on one sentence: *"It
 * binds to 127.0.0.1. Nothing off this machine can reach it. That is the
 * boundary that actually matters."* Nothing here weakens it.
 *
 * `forwardIn` asks the **server** to listen on *its* `127.0.0.1` and hand every
 * connection it accepts back down the SSH connection **this Mac opened**. So the
 * two loopback rules are the same rule, said on two machines: only a process on
 * that server can reach the forwarded port, exactly as only a process on this
 * Mac can reach the endpoint itself. Nothing is bound on any public interface at
 * either end, no port is opened in any firewall, and the socket the bytes
 * finally arrive on is `127.0.0.1` on this machine — the one the endpoint has
 * always been on. There is no Chromium debugging port anywhere in this, and
 * `deck-control/server.ts`'s header explains at length why there never will be.
 *
 * The bearer token is not the layer this rests on, any more than it is for the
 * endpoint itself. It is the second layer, and it is per session.
 *
 * ## The one setting that could make that untrue, and why it is measured
 *
 * `GatewayPorts`. OpenSSH's default is `no`, which binds every remote forward to
 * loopback and is exactly what is wanted; `clientspecified` honours the
 * `127.0.0.1` asked for below. But **`GatewayPorts yes` ignores the requested
 * bind address and binds the wildcard**, which would put a tunnel to this Mac's
 * control endpoint on a port anybody who can reach that server can dial. That is
 * the one configuration this feature must not be quietly wrong about.
 *
 * It cannot be read from this end — the reply to a forward request carries the
 * port and not the address — so it is asked, in the terms `forward.ts` sets for
 * its own mirror-image question: *detect, do not assume*. {@link BIND_CHECK}
 * runs on the server and reports what the port is actually bound to, and an
 * answer that is not loopback tears the forward down before a single byte
 * crosses it.
 *
 * **And an answer of "I could not find out" refuses too**, which is the one
 * place this file is stricter than the rest of the servers feature. Everywhere
 * else a fact that could not be measured is a third state that draws a sentence
 * and changes nothing (`facts.ts`); here the unmeasured thing *is* the boundary,
 * and the cost of refusing is that a person on a box with neither `ss` nor
 * `netstat` does not get a capability that was off by default anyway. That is
 * the direction to fail in.
 *
 * ## Why this file does not import `ssh2`
 *
 * `host-key-checked.test.ts` walks the syntax tree of every source in this
 * folder and fails the build if anything but `connection.ts` reaches the
 * transport. `forward.ts` states the value of that guard at length and it
 * applies here unchanged, so the connection arrives as {@link ReverseConnection}
 * — the three calls this module makes, named — and an `ssh2` `Client` satisfies
 * it structurally.
 */

/*
 * `createConnection` rather than its shorter alias `connect`, and the reason is
 * a guard rather than taste: `host-key-checked.test.ts` walks this folder's
 * syntax tree and demands that every call spelled `connect(...)` passes
 * `hostVerifier`, because the hole it exists to stop is a *second SSH dial*
 * written by somebody who has not read `connection.ts`. A loopback TCP socket is
 * not that, and the honest way to say so is not to spell it like one.
 */
import { createConnection, type Socket } from 'node:net'

/** The address the far end is asked to bind. Never a name; see `forward.ts`. */
export const LOOPBACK_V4 = '127.0.0.1'

/**
 * How long the server may take to answer a forward request.
 *
 * The same five seconds `forward.ts` allows a channel open, for the same
 * reason: this is one round trip on a connection that is already up, so the
 * ordinary answer — refusal included — is back long before it, and something
 * that has not answered inside it is wedged rather than slow.
 */
const REQUEST_TIMEOUT_MS = 5_000

/**
 * Connections one server may hold open to this endpoint at once.
 *
 * An MCP call over this is one short HTTP request and one answer, and the CLI
 * makes them one at a time. Sixteen is many times what a real session uses and
 * exists for the reason `forward.ts`'s own ceiling does: every one of these is a
 * channel on a single SSH connection, and a connection with unbounded channels
 * on it is a way to make somebody's server refuse the shell they were about to
 * open.
 */
export const MAX_REACH_STREAMS = 16

/* ------------------------------------------------------- what it asks for -- */

/** One end of a byte stream, named by what the pump below asks of it. */
export interface ReachStream {
  on(event: 'data', listener: (chunk: Buffer) => void): unknown
  on(event: 'end' | 'close', listener: () => void): unknown
  on(event: 'error', listener: (error: Error) => void): unknown
  write(chunk: Buffer): boolean
  /** Send what is queued and then end-of-file. Never `destroy` for an orderly close. */
  end(): void
  destroy(): void
  pause(): void
  resume(): void
}

/** What one accepted connection says about itself. */
export interface IncomingTcp {
  destIP: string
  destPort: number
}

/**
 * A live connection, named by the four things this module asks of it.
 *
 * See the header for why the class is not named. The declaration of the real
 * methods, with everything odd about their failure paths, is in `ssh2.d.ts`.
 */
export interface ReverseConnection {
  on(event: 'close', listener: () => void): unknown
  on(
    event: 'tcp connection',
    listener: (info: IncomingTcp, accept: () => ReachStream, reject: () => void) => void,
  ): unknown
  removeListener(event: string, listener: (...args: never[]) => void): unknown
  forwardIn(
    bindAddr: string,
    bindPort: number,
    callback: (error: Error | undefined, port: number) => void,
  ): unknown
  unforwardIn(bindAddr: string, bindPort: number, callback: (error?: Error) => void): unknown
}

/** What a server may be running that can answer the bind-address question. */
export type BindAnswer = 'loopback' | 'public' | 'unknown'

/**
 * What the port is bound to, asked of the server rather than assumed.
 *
 * `ss` first and `netstat` second, which is the order `probe.sh.ts` already
 * uses and for the reason it gives: one of the two is on essentially every
 * machine, and the two print the same column in the same place. Neither is a
 * dependency this app installs — a server with neither answers `unknown`, and
 * the caller refuses on it.
 *
 * The bracket form is what `ss` prints for a v6 loopback bind (`[::1]:8080`),
 * and it is quoted in the `case` so the shell reads it as five characters rather
 * than as a bracket expression. `*:8080`, `0.0.0.0:8080` and `[::]:8080` all
 * fall through to the last branch, which is the whole point of this script.
 */
export function bindCheckScript(port: number): string {
  return [
    `p=${port}`,
    'if command -v ss >/dev/null 2>&1; then',
    '  found=$(ss -H -tln 2>/dev/null | awk -v p=":$p\\$" \'$4 ~ p {print $4}\')',
    'elif command -v netstat >/dev/null 2>&1; then',
    '  found=$(netstat -tln 2>/dev/null | awk -v p=":$p\\$" \'/LISTEN/ && $4 ~ p {print $4}\')',
    'else',
    '  echo unknown; exit 0',
    'fi',
    'if [ -z "$found" ]; then echo unknown; exit 0; fi',
    'for a in $found; do',
    '  case "$a" in',
    '    127.0.0.1:*) ;;',
    '    "[::1]:"*) ;;',
    '    ::1:*) ;;',
    '    *) echo public; exit 0 ;;',
    '  esac',
    'done',
    'echo loopback',
  ].join('\n')
}

/** Read {@link bindCheckScript}'s one word, however much noise came with it. */
export function readBindAnswer(stdout: string): BindAnswer {
  const words = stdout.trim().split(/\s+/)
  const last = words[words.length - 1] ?? ''
  if (last === 'loopback') return 'loopback'
  if (last === 'public') return 'public'
  return 'unknown'
}

/** The sentence each refusal puts in front of a person, in this app's words. */
export const CANNOT_FORWARD =
  'this server would not open a port of its own for this app to answer on. Its SSH settings decide ' +
  'that — `AllowTcpForwarding` and `PermitListen` — and only somebody who can change them on that ' +
  'machine can turn it on.'

export const BOUND_TOO_WIDELY =
  'this server put that port on every one of its network addresses instead of on its own loopback, ' +
  'which is what `GatewayPorts yes` in its SSH settings does. Nothing was connected and the port has ' +
  'been closed again: a way in to this computer’s browser must not be reachable from that server’s ' +
  'network.'

export const CANNOT_TELL_WHERE_BOUND =
  'this server has neither `ss` nor `netstat`, so this app cannot check that the port it opened there ' +
  'is on that machine’s loopback and nowhere else. That check is the whole boundary here, so the port ' +
  'has been closed again rather than used unchecked.'

/* -------------------------------------------------------------- the reach -- */

export interface WindowReach {
  /** The port on the **server's** loopback that reaches this endpoint. */
  port: number
  /** Stop listening and drop every connection still on it. Idempotent. */
  close(): void
}

export interface WindowReachDeps {
  /** The endpoint's port on **this** machine. `deck-control`'s, always. */
  localPort: number
  /** Run one short script on that server. `ServerConnections.runScript`. */
  runScript(script: string): Promise<{ stdout: string }>
  /**
   * Dial this machine's loopback. Injected only so a test can stand in for a
   * real socket — the same seam, and the same one-line reason, that
   * `ServerConnections` gives for `newClient`.
   */
  openLocal?(port: number): ReachStream
}

export type ReachResult =
  | { ok: true; reach: WindowReach }
  | { ok: false; message: string }

/**
 * Ask the server for a port of its own that lands here, and prove where it is.
 *
 * Never throws: every failure is a sentence, because the caller is deciding
 * whether to hand a terminal a capability and a rejected promise there would
 * turn a server's SSH settings into a stack trace.
 */
export async function openWindowReach(
  client: ReverseConnection,
  deps: WindowReachDeps,
): Promise<ReachResult> {
  const port = await bind(client)
  if (port === null) return { ok: false, message: CANNOT_FORWARD }

  let answer: BindAnswer
  try {
    answer = readBindAnswer((await deps.runScript(bindCheckScript(port))).stdout)
  } catch {
    // A connection that died while we asked. Treat it as not knowing, which
    // means the forward comes down — there is nothing left to serve anyway.
    answer = 'unknown'
  }
  if (answer !== 'loopback') {
    unbind(client)
    return { ok: false, message: answer === 'public' ? BOUND_TOO_WIDELY : CANNOT_TELL_WHERE_BOUND }
  }

  return { ok: true, reach: serve(client, port, deps) }
}

/** One `forwardIn`, with the ceiling the library does not have. */
function bind(client: ReverseConnection): Promise<number | null> {
  return new Promise<number | null>((resolve) => {
    let settled = false
    const done = (value: number | null): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(value)
    }
    const timer = setTimeout(() => done(null), REQUEST_TIMEOUT_MS)
    timer.unref?.()
    try {
      client.forwardIn(LOOPBACK_V4, 0, (error, bound) => {
        // A zero here is a server that answered without naming a port, which is
        // an address nothing can be pointed at. Refused rather than used.
        done(error !== undefined || !Number.isInteger(bound) || bound <= 0 ? null : bound)
      })
    } catch {
      // `forwardIn` throws rather than calling back when the socket has already
      // gone — see `ssh2.d.ts`. Same trap as `forwardOut` and `sftp`.
      done(null)
    }
  })
}

function unbind(client: ReverseConnection): void {
  try {
    // The pair that was *asked* for, not the port that came back: the library
    // keys its own table on the request. See `ssh2.d.ts`.
    client.unforwardIn(LOOPBACK_V4, 0, () => undefined)
  } catch {
    // The connection has gone, which has already cancelled every forward on it.
  }
}

/**
 * Wire the accepted connections to this machine's endpoint, until told to stop.
 *
 * The listener is on the *connection*, so it sees every forward on it. Filtering
 * on `destPort` is therefore not defensive padding — it is what stops a second
 * reach on the same server from being served by the first one's socket.
 */
function serve(client: ReverseConnection, port: number, deps: WindowReachDeps): WindowReach {
  const open = new Set<ReachStream>()
  let closed = false
  const dial =
    deps.openLocal ?? ((to: number): ReachStream => createConnection(to, '127.0.0.1') as Socket)

  const onConnection = (
    info: IncomingTcp,
    accept: () => ReachStream,
    reject: () => void,
  ): void => {
    if (closed || info.destPort !== port) {
      reject()
      return
    }
    if (open.size >= MAX_REACH_STREAMS) {
      // Refused rather than queued. A queue here would hold a channel on
      // somebody's server open against a socket this side has not dialled, and
      // an MCP client reads a refused connection as an error it can retry.
      reject()
      return
    }
    let channel: ReachStream
    try {
      channel = accept()
    } catch {
      return
    }
    const local = dial(deps.localPort)
    open.add(channel)
    pump(channel, local, () => open.delete(channel))
  }

  client.on('tcp connection', onConnection)
  // The connection dying is the only thing besides `close()` that ends this,
  // and it is listened to rather than polled — his standing rule, and the same
  // line `ForwardingConnection.on('close')` exists for.
  client.on('close', () => stop(false))

  function stop(tell: boolean): void {
    if (closed) return
    closed = true
    client.removeListener('tcp connection', onConnection as (...args: never[]) => void)
    for (const channel of [...open]) channel.destroy()
    open.clear()
    if (tell) unbind(client)
  }

  return { port, close: () => stop(true) }
}

/**
 * Join two streams, and end each one when the other does.
 *
 * `end()` on end-of-file rather than `destroy()`, which is the fix a Windows
 * runner found in `localhost-reach.ts` and which applies to every pipe in this
 * app: `destroy()` throws away everything Node accepted from `write()` and has
 * not handed to the kernel, so a response larger than the socket buffer arrives
 * truncated and the reader waits forever for an `end` that never comes. An MCP
 * answer carrying a page outline is exactly that size.
 *
 * `pause`/`resume` around a failed `write` is the flow control. Without it a
 * fast reader on one side would buffer without bound on the other, which on this
 * path means a page read holding memory in the main process.
 */
function pump(a: ReachStream, b: ReachStream, done: () => void): void {
  let over = false
  const finish = (): void => {
    if (over) return
    over = true
    done()
    a.destroy()
    b.destroy()
  }

  const join = (from: ReachStream, to: ReachStream): void => {
    from.on('data', (chunk) => {
      if (!to.write(chunk)) {
        from.pause()
        // `write` answering false means the far side's buffer is full; `drain`
        // is the only event that says it is not any more. It is spelled through
        // `on` rather than `once` because the seam declares three events and
        // adding a fourth for one call site is a wider seam for a test to fake.
        ;(to as unknown as { once?(event: string, listener: () => void): unknown }).once?.(
          'drain',
          () => from.resume(),
        )
      }
    })
    from.on('end', () => to.end())
    from.on('close', finish)
    from.on('error', finish)
  }

  join(a, b)
  join(b, a)
}
