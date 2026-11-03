import { generateKeyPairSync } from 'node:crypto'
import { createServer as createHttpServer, get as httpGet, type Server as HttpServer } from 'node:http'
import { createConnection } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { Client, Server } from 'ssh2'
import { createRemoteReach, type RemoteReach } from '../localhost-reach'
import { askWhetherItForwards, createSshTunnelHost, forwardOn, WILL_NOT_FORWARD } from './forward'

/**
 * A server's own `localhost`, opened here, over a **real SSH connection**.
 *
 * ## Why this is not a unit test, and why it is not the live one either
 *
 * The failure this codebase keeps re-finding is not a module's bookkeeping. It
 * is *the mechanism written and the connection absent* — seven times this week,
 * by the brief's own count. Both halves of this pipe pass their unit tests
 * against stand-ins that agree with them, so the only thing worth proving is
 * that the halves talk to each other **through the real library**, and the only
 * way to prove that without a machine on the internet is to put a real SSH
 * server at the other end of a real socket.
 *
 * So everything in the path here is the shipping article:
 *
 *  - `ssh2`'s own `Server`, doing the real handshake and the real key exchange
 *    over a real loopback socket;
 *  - `forwardOn`, which is `Client.forwardOut` — the same call `ssh -L` is
 *    built out of, and the app's only transport for this feature;
 *  - `createSshTunnelHost`, unchanged;
 *  - `createRemoteReach` from `localhost-reach.ts`, unchanged and shared with
 *    the relay path — the loopback listener, the port ladder, the flow control
 *    and the flush-versus-discard fix are all its own code;
 *  - a real HTTP server standing in for whatever the far machine is running,
 *    and a real `http.get` standing in for the browser.
 *
 * The only thing this cannot prove is that a **stranger's** sshd behaves like
 * `ssh2`'s server. That is what `reach.live.test.ts` is for, against a real
 * Ubuntu box, and it is opt-in because a test that needs the public internet
 * has no business failing a build on a train.
 *
 * ## The refusal, and why it is a first-class case here
 *
 * `AllowTcpForwarding no` is real and common on hardened machines, and the
 * standing rule is **detect, do not assume**. It is exercised here rather than
 * described, and the exercise is faithful rather than approximate: an `ssh2`
 * server with no `tcpip` listener rejects a `direct-tcpip` channel with
 * `ADMINISTRATIVELY_PROHIBITED`, which is the identical wire answer OpenSSH
 * sends when that setting is off. Read out of `lib/server.js` and then
 * measured, rather than assumed.
 */

/**
 * One host key, made once, by Node rather than by the library.
 *
 * `PKCS#1` RSA — the `BEGIN RSA PRIVATE KEY` form — because `ssh2`'s key
 * generator lives on `utils`, and `utils` is already declared in `ssh2.d.ts`
 * with exactly one member on purpose. Widening that declaration for a test
 * would have meant editing the file whose whole job is to stay narrow.
 *
 * 2048 bits and generated once for the file: this is the slowest line here, and
 * every test would otherwise pay for it.
 */
const HOST_KEY = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
  publicKeyEncoding: { type: 'pkcs1', format: 'pem' },
}).privateKey

const shutting: Array<{ close(cb?: () => void): unknown }> = []
const clients: Array<{ end(): unknown }> = []
const reaches: RemoteReach[] = []

afterEach(async () => {
  for (const reach of reaches.splice(0)) reach.closeAll('the test ended')
  for (const client of clients.splice(0)) client.end()
  await Promise.all(
    shutting.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))),
  )
})

/**
 * An SSH server that either forwards or refuses, on a loopback port.
 *
 * When it forwards it does the honest thing rather than a convenient one: it
 * dials the address the client asked for, from this process, and rejects when
 * nothing answers there. That is what OpenSSH does, and it is what makes
 * "nothing is listening on that port" a case this file can exercise at all.
 */
async function sshServer(options: { forwards: boolean }): Promise<number> {
  const server = new Server({ hostKeys: [HOST_KEY] }, (client) => {
    client.on('authentication', (ctx) => ctx.accept())
    if (!options.forwards) return
    client.on('tcpip', (accept, reject, info) => {
      const socket = createConnection({ host: info.destIP, port: info.destPort })
      socket.once('error', () => reject())
      socket.once('connect', () => {
        const channel = accept()
        socket.pipe(channel).pipe(socket)
      })
    })
  })
  shutting.push(server)
  return new Promise<number>((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      resolve(typeof address === 'object' && address !== null ? address.port : 0)
    })
  })
}

async function sshClient(port: number) {
  const client = new Client()
  clients.push(client)
  await new Promise<void>((resolve, reject) => {
    client.once('ready', resolve)
    client.once('error', reject)
    client.connect({
      host: '127.0.0.1',
      port,
      username: 'anybody',
      password: 'anything',
      // The one thing a test may not weaken elsewhere. Here the server is one
      // this process just started, so its key is not a claim about anybody.
      hostVerifier: () => true,
      agent: false,
    })
  })
  return client
}

/** The two halves, wired to each other exactly as `reach.ts` wires them. */
function pipeThrough(client: Client, name = 'the box'): RemoteReach {
  let host: ReturnType<typeof createSshTunnelHost> | null = null
  const reach = createRemoteReach({
    send: (message) => {
      if (host === null) return false
      host.handle(message)
      return true
    },
  })
  host = createSshTunnelHost({ forward: forwardOn(client), send: (m) => reach.handle(m), name })
  reaches.push(reach)
  return reach
}

/** Something for the far end to be running. Returns its port. */
async function siteServing(body: string): Promise<{ port: number; server: HttpServer }> {
  const server = createHttpServer((_request, response) => {
    response.writeHead(200, { 'content-type': 'text/plain', 'content-length': String(body.length) })
    response.end(body)
  })
  shutting.push(server)
  const port = await new Promise<number>((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      resolve(typeof address === 'object' && address !== null ? address.port : 0)
    })
  })
  return { port, server }
}

function fetchText(url: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    httpGet(url, (response) => {
      let body = ''
      response.setEncoding('utf8')
      response.on('data', (chunk: string) => (body += chunk))
      response.on('end', () => resolve({ status: response.statusCode ?? 0, body }))
    }).on('error', reject)
  })
}

describe('a server’s own localhost, in this window’s browser', () => {
  it('serves a page from the far end at an ordinary http address on this machine', async () => {
    const site = await siteServing('hello from over there')
    const reach = pipeThrough(await sshClient(await sshServer({ forwards: true })))

    const answer = await reach.open(site.port)
    expect(answer.ok, answer.ok ? '' : answer.message).toBe(true)
    if (!answer.ok) return

    /*
     * The shape of the answer is the requirement, not a detail. It is a plain
     * `http://` URL, so the browser opens it with the ordinary navigation, in
     * the ordinary tab, with the ordinary address bar and history around it —
     * *"shape of the application should not be changing for local and remote
     * devices."* Anything else here would have meant a second kind of tab.
     */
    expect(answer.url).toMatch(/^http:\/\/(127\.0\.0\.1|\[::1\]):\d+\/$/)
    expect(await fetchText(answer.url)).toEqual({ status: 200, body: 'hello from over there' })
  }, 20_000)

  it('keeps the port number when it can, so the far end’s own links still land', async () => {
    const site = await siteServing('x')
    const reach = pipeThrough(await sshClient(await sshServer({ forwards: true })))
    const answer = await reach.open(site.port)
    expect(answer.ok).toBe(true)
    if (!answer.ok) return
    /*
     * Why this matters, measured on the real box rather than argued: Coolify on
     * port 8000 answers `GET /` with `Location: http://127.0.0.1:8000/login`.
     * A far end writes its own port into its own output — redirects, hot-reload
     * sockets, cookies scoped to a port — and every one of those escapes a page
     * served at a different number. The site under test here is on a port the
     * OS just handed out, so nothing on this machine is holding it and the
     * first rung of the ladder is free.
     */
    expect(answer.localPort).toBe(site.port)
    expect(answer.sameNumber).toBe(true)
  }, 20_000)

  it('carries a body far larger than a socket holds in flight', async () => {
    // 288 KB, for the reason `localhost-reach.ts` gives at length: it straddles
    // the line between macOS's ~320 KB loopback capacity and Windows's 64 KB,
    // which is exactly where a `destroy()` that does not flush truncates a
    // response and leaves the reader waiting forever for an `end` that never
    // comes. Here it also crosses a real SSH connection, which cuts it into
    // channel windows and packets on the way.
    const body = 'q'.repeat(288 * 1024)
    const site = await siteServing(body)
    const reach = pipeThrough(await sshClient(await sshServer({ forwards: true })))
    const answer = await reach.open(site.port)
    expect(answer.ok).toBe(true)
    if (!answer.ok) return
    const got = await fetchText(answer.url)
    expect(got.body.length).toBe(body.length)
    expect(got.body).toBe(body)
  }, 30_000)

  it('serves the same tunnel to a second tab rather than opening a second one', async () => {
    const site = await siteServing('once')
    const reach = pipeThrough(await sshClient(await sshServer({ forwards: true })))
    const [first, second] = await Promise.all([reach.open(site.port), reach.open(site.port)])
    expect(first).toEqual(second)
    expect(reach.list()).toHaveLength(1)
  }, 20_000)
})

describe('a server that will not allow it', () => {
  it('is detected before anything is drawn, rather than failing on a click', async () => {
    const client = await sshClient(await sshServer({ forwards: false }))
    // The picker asks this before it draws the row. `no` — not `cannot` — so
    // the row carries its sentence and is not selectable.
    expect(await askWhetherItForwards(forwardOn(client), { listening: [8000] })).toEqual({
      known: 'no',
      why: WILL_NOT_FORWARD,
    })
  }, 20_000)

  it('refuses an address with the sentence, and never leaves a listener behind', async () => {
    const reach = pipeThrough(await sshClient(await sshServer({ forwards: false })))
    const answer = await reach.open(3000)
    expect(answer).toEqual({ ok: false, message: WILL_NOT_FORWARD })
    // Nothing bound on this machine for a port that was never opened. A
    // listener here would answer in somebody's browser and then hang.
    expect(reach.list()).toEqual([])
  }, 20_000)

  it('says something different when the server allows it and nothing is there', async () => {
    const reach = pipeThrough(await sshClient(await sshServer({ forwards: true })))
    // Port 1: chosen the same way `deadPort` chooses, and for the same reason —
    // it is certainly empty, so no real service is touched to find out.
    const answer = await reach.open(1)
    expect(answer).toEqual({ ok: false, message: 'Nothing is answering on port 1 on the box.' })
  }, 20_000)
})
