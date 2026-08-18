import { get as httpGet, createServer as createHttpServer, type Server } from 'node:http'
import {
  createConnection,
  createServer as createTcpServer,
  type Server as TcpServer,
} from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { createRemoteReach, type RemoteReach } from './localhost-reach'
import { ownPorts } from './own-ports'
import { parseClientMessage, parseServerMessage, serialize } from './remote/protocol'
import { createTunnelHub, type LocalhostMessage } from './remote/tunnel'

/**
 * Both halves of the wire, wired to each other, over real sockets.
 *
 * This is not a unit test of `localhost-reach.ts` and deliberately not: the
 * thing that has gone wrong six times in this codebase is not a module's
 * bookkeeping, it is **the mechanism written and the connection absent**. So the
 * far machine here is the real `createTunnelHub` from `remote/tunnel.ts` — the
 * same object a PC runs — the dev server is a real HTTP server, the browser is a
 * real `http.get`, and every frame that passes between the two halves goes
 * through the real parsers on its way.
 *
 * That last part is what makes this worth more than a mock. `parseClientMessage`
 * is what a *host* would run this end's frames through, and it enforces things
 * no type does: the id alphabet, base64 with no stray characters, a `net.ack`
 * inside the window, a chunk under the message cap. A frame this file emits that
 * a real desktop would refuse fails here rather than on his PC.
 */

const started: Array<Server | TcpServer> = []
const accepted: Array<{ destroy(): void }> = []
const reaches: RemoteReach[] = []

afterEach(async () => {
  for (const reach of reaches.splice(0)) reach.closeAll('the test ended')
  for (const socket of accepted.splice(0)) socket.destroy()
  await Promise.all(
    started.splice(0).map(
      (server) =>
        new Promise<void>((settle) => {
          if ('closeAllConnections' in server) server.closeAllConnections()
          server.close(() => settle())
        }),
    ),
  )
})

/** A dev server "on the other machine", on a port the OS chose. */
async function devServer(body: string): Promise<number> {
  const server = createHttpServer((request, response) => {
    response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`${body} ${request.url ?? ''}`)
  })
  started.push(server)
  server.on('connection', (socket) => accepted.push(socket))
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', () => settle()))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  return address.port
}

/**
 * This machine's reach, talking to a hub that serves `ports`.
 *
 * The two `send`s are the relay, and both of them serialise and re-parse. A
 * frame either side would refuse throws here, naming itself.
 */
function pair(ports: number[]): { reach: RemoteReach; frames: LocalhostMessage[] } {
  const frames: LocalhostMessage[] = []
  const hub = createTunnelHub({
    scan: async () => ports.map((port) => ({ port, process: 'node', guessed: false })),
    send: (message) => {
      const parsed = parseServerMessage(serialize(message))
      if (!parsed.ok) throw new Error(`the host sent something unreadable: ${parsed.reason}`)
      reach.handle(parsed.message)
    },
  })
  const reach = createRemoteReach({
    send: (message) => {
      frames.push(message)
      const parsed = parseClientMessage(serialize(message))
      if (!parsed.ok) throw new Error(`this end sent something a host would refuse: ${parsed.reason}`)
      hub.handle(parsed.message as LocalhostMessage)
      return true
    },
  })
  reaches.push(reach)
  return { reach, frames }
}

/** The id this end minted for a `tunnel.open`, as the far machine saw it. */
function openedId(frames: readonly LocalhostMessage[]): string {
  const frame = frames.find((message) => message.t === 'tunnel.open')
  if (frame === undefined || frame.t !== 'tunnel.open') throw new Error('nothing opened a tunnel')
  return frame.id
}

/**
 * Read a URL the way the browser would.
 *
 * `agent: false` so every call dials its own socket. Node's global agent keeps
 * connections alive, and a pooled socket into a tunnel that has since been taken
 * down fails as `ECONNRESET` — which is true of the socket and says nothing
 * about whether the address is still being served. A fresh dial asks the
 * question the test is actually asking.
 *
 * **Both objects get an error handler, and the response one is not decoration.**
 * A body cut short of its `Content-Length` is reported on the *response*, never
 * on the request: there is no `end`, no rejection, and no unhandled error —
 * measured, with this exact function, by serving 300 KB of a declared 300,000
 * byte body and hanging up. The promise simply stayed pending, forever.
 *
 * That is how a truncation arrived on the Windows runner as `Test timed out in
 * 5000ms` with no assertion and nothing naming a socket. Listening here costs
 * one line and turns the same failure into `ECONNRESET`, which says what
 * happened.
 */
function fetchText(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const request = httpGet(url, { agent: false }, (response) => {
      let text = ''
      response.setEncoding('utf8')
      response.on('data', (chunk: string) => {
        text += chunk
      })
      response.on('end', () => resolve(text))
      response.on('error', reject)
    })
    request.on('error', reject)
  })
}

/**
 * Turn the event loop until `look` finds something, or give up after a while.
 *
 * The alternative is a fixed sleep, and a fixed sleep is a wrong answer twice
 * over: too short on a loaded machine, and wasted time on every other run.
 */
async function waitFor<T>(look: () => T | undefined): Promise<T> {
  for (let turn = 0; turn < 500; turn += 1) {
    const found = look()
    if (found !== undefined) return found
    await new Promise<void>((settle) => setTimeout(settle, 10))
  }
  throw new Error('waited and it never happened')
}

describe('reaching another machine’s port from this one', () => {
  it('serves a remote port at a URL this machine can open', async () => {
    const port = await devServer('hello from the PC')
    const { reach } = pair([port])

    const answer = await reach.open(port)
    if (!answer.ok) throw new Error(answer.message)

    // The whole feature in one line: an ordinary http URL, opened ordinarily,
    // answered by a server this process never dialled directly.
    expect(await fetchText(`${answer.url}some/path`)).toBe('hello from the PC /some/path')
  })

  it('keeps the port number when it can, so the far server’s own links still work', async () => {
    const port = await devServer('same number')
    const { reach } = pair([port])

    const answer = await reach.open(port)
    if (!answer.ok) throw new Error(answer.message)
    // 127.0.0.1 is taken here — it is the test's own dev server — so this is the
    // second rung, `[::1]`, which is what makes the number survivable at all on
    // a machine already serving that port.
    expect(answer.localPort).toBe(port)
    expect(answer.sameNumber).toBe(true)
    expect(answer.url).toBe(`http://[::1]:${port}/`)
  })

  it('falls back to another port, and says so, when both loopbacks are taken', async () => {
    const port = await devServer('busy both ways')
    // The v6 rung, occupied. Now every address carrying the original number is
    // in use on this machine, which is the case the phone refuses and a desktop
    // must not.
    const blocker = createTcpServer()
    started.push(blocker)
    await new Promise<void>((settle) => blocker.listen(port, '::1', () => settle()))

    const { reach } = pair([port])
    const answer = await reach.open(port)
    if (!answer.ok) throw new Error(answer.message)

    expect(answer.localPort).not.toBe(port)
    expect(answer.sameNumber).toBe(false)
    expect(await fetchText(answer.url)).toBe('busy both ways /')
  })

  it('reuses one tunnel for one port, however many times it is asked for', async () => {
    const port = await devServer('reused')
    const { reach, frames } = pair([port])

    const [first, second] = await Promise.all([reach.open(port), reach.open(port)])
    const third = await reach.open(port)
    if (!first.ok || !second.ok || !third.ok) throw new Error('one of the opens was refused')

    expect(second.url).toBe(first.url)
    expect(third.url).toBe(first.url)
    // Two clicks in the same instant are one open, not a race to bind the same
    // address — one of which would have lost and returned a refusal.
    expect(frames.filter((frame) => frame.t === 'tunnel.open')).toHaveLength(1)
    expect(reach.list()).toHaveLength(1)
  })

  it('refuses a port nothing is listening on over there, in the far machine’s words', async () => {
    const port = await devServer('not this one')
    // The hub scans and finds nothing on 9, so it refuses before a socket exists.
    const { reach } = pair([port])

    const answer = await reach.open(9)
    expect(answer.ok).toBe(false)
    if (answer.ok) return
    expect(answer.message).toContain('9')
  })

  it('refuses when the link is not online, rather than binding anything', async () => {
    const reach = createRemoteReach({ send: () => false })
    reaches.push(reach)
    const answer = await reach.open(3000)
    expect(answer.ok).toBe(false)
    if (answer.ok) return
    expect(answer.message).toContain('not connected')
  })

  it('holds its local port out of this machine’s own port list', async () => {
    const port = await devServer('reserved')
    const { reach } = pair([port])
    const answer = await reach.open(port)
    if (!answer.ok) throw new Error(answer.message)

    // Without this a phone paired to *this* machine would be offered this
    // listener and could tunnel through it into a PC it never paired with.
    expect(ownPorts()).toContain(answer.localPort)
    reach.closeAll('the test asked')
    expect(ownPorts()).not.toContain(answer.localPort)
  })

  it('takes the page down when the far machine closes the tunnel', async () => {
    const port = await devServer('going away')
    const { reach, frames } = pair([port])
    const answer = await reach.open(port)
    if (!answer.ok) throw new Error(answer.message)
    expect(await fetchText(answer.url)).toBe('going away /')

    // Exactly what a desktop sends when its own server stops or somebody ends
    // the tunnel from over there.
    reach.handle({ t: 'tunnel.closed', id: openedId(frames), message: 'Stopped over there.' })

    expect(reach.list()).toHaveLength(0)
    await expect(fetchText(answer.url)).rejects.toMatchObject({ code: 'ECONNREFUSED' })
  })

  it('carries a body far larger than one frame, in order', async () => {
    // Twelve times the chunk cap, so `forward` splits it and the acknowledgements
    // are what let the rest through.
    const body = 'x'.repeat(24 * 1024 * 12)
    const server = createHttpServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'text/plain' })
      response.end(body)
    })
    started.push(server)
    server.on('connection', (socket) => accepted.push(socket))
    await new Promise<void>((settle) => server.listen(0, '127.0.0.1', () => settle()))
    const address = server.address()
    if (address === null || typeof address === 'string') throw new Error('no port')

    const { reach } = pair([address.port])
    const answer = await reach.open(address.port)
    if (!answer.ok) throw new Error(answer.message)
    expect(await fetchText(answer.url)).toBe(body)
  })

  it('delivers what is already queued when the far machine closes the channel', async () => {
    /*
     * The Windows failure above, reduced to the property it was actually about
     * and pinned so that it fails on this Mac too.
     *
     * The test above can only catch this on a platform whose socket buffers are
     * small enough for a 288 KB body to leave something queued — 64 KB on
     * Windows, about 320 KB here — which is why it passed on every Mac run and
     * hung on the runner. This one takes the buffer out of the question by
     * making the reader stop reading and then pushing far more at it than any
     * loopback socket holds: whatever the kernel takes, the rest is sitting in
     * this process when `net.close` arrives, on any machine.
     *
     * `net.close` is what an ordinary `Connection: close` response looks like
     * from this side — the far server answered and hung up — so this is the
     * common case rather than an edge one. Closing that channel with `destroy()`
     * dropped the tail of every response larger than a socket buffer.
     */
    const port = await devServer('unused')
    const { reach, frames } = pair([port])
    const answer = await reach.open(port)
    if (!answer.ok) throw new Error(answer.message)

    // A browser that has connected and is not reading yet. Everything written to
    // it past the kernel's appetite queues inside this process.
    //
    // The address comes off the answer rather than being written out: which rung
    // of the ladder was free is the previous tests' subject, and hard-coding one
    // here would make this test fail for a reason that has nothing to do with it.
    const seen: Buffer[] = []
    const target = new URL(answer.url)
    const reading = new Promise<void>((settle, fail) => {
      const socket = createConnection(
        { host: target.hostname.replace(/^\[|\]$/g, ''), port: Number(target.port) },
        () => {
          socket.pause()
          setTimeout(() => socket.resume(), 200)
        },
      )
      socket.on('data', (chunk: Buffer) => seen.push(chunk))
      socket.on('end', () => settle())
      socket.on('error', fail)
      accepted.push(socket)
    })

    // Wait for the listener to accept rather than sleeping a guessed number of
    // milliseconds at it — a fixed wait is the thing that turns a loaded runner
    // into a red test for no reason, which is most of what this session was about.
    const opened = await waitFor(() => frames.find((frame) => frame.t === 'net.open'))
    if (opened.t !== 'net.open') throw new Error('no channel was opened')

    // Forty frames at the chunk cap — 960 KB, several times what any loopback
    // socket will hold — and then the hang-up, in the same turn of the loop.
    const piece = Buffer.alloc(24 * 1024, 0x79)
    for (let sent = 0; sent < 40; sent += 1) {
      reach.handle({ t: 'net.data', ch: opened.ch, data: piece.toString('base64') })
    }
    reach.handle({ t: 'net.close', ch: opened.ch })

    await reading
    expect(Buffer.concat(seen)).toHaveLength(piece.length * 40)
  })
})
