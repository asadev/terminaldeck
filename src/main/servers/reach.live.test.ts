import { readFileSync } from 'node:fs'
import { connect } from 'node:net'
import { request as httpRequest } from 'node:http'
import { afterAll, describe, expect, it } from 'vitest'
import { Client } from 'ssh2'
import { createRemoteReach, type RemoteReach } from '../localhost-reach'
import { askWhetherItForwards, createSshTunnelHost, forwardOn } from './forward'

/**
 * The one test that opens a real server's own `localhost` in this process.
 *
 * Opt-in, because a test that needs a machine on the public internet has no
 * business failing a build on a train:
 *
 *     TERMINALDECK_LIVE_SSH=178.105.248.86 \
 *     TERMINALDECK_LIVE_SSH_USER=root \
 *     TERMINALDECK_LIVE_SSH_KEY=~/.ssh/hetzner_personal \
 *     TERMINALDECK_LIVE_SSH_PORT=8000 \
 *       npx vitest run src/main/servers/reach.live.test.ts
 *
 * ## What this proves that `reach.ssh.test.ts` cannot
 *
 * That file puts `ssh2`'s own server at the far end, which proves the two
 * halves of this app talk to each other over a real handshake. What it cannot
 * prove is that a **stranger's** sshd behaves the way this app expects — that
 * `AllowTcpForwarding` really is what decides it, that a refused connection to
 * an empty port really does come back as reason 2 rather than as a hang, that
 * a real reverse proxy's response survives the pipe intact. Those are facts
 * about OpenSSH and about somebody's actual machine, and the only way to
 * establish them is to ask one.
 *
 * ## What it does to the machine
 *
 * Nothing. It opens connections and reads. There is no setup, no teardown and
 * no scratch anything, because everything here is a question: *will you
 * forward*, *what is on this port*. The box it was written against runs a live
 * relay and somebody's containers, and the standing instruction about it was
 * **read-only on services — never restart, stop or update anything**. Opening
 * a connection is read-only in that sense and a `GET /` is a page view.
 */

const host = process.env.TERMINALDECK_LIVE_SSH ?? ''
const username = process.env.TERMINALDECK_LIVE_SSH_USER ?? 'root'
const keyPath = (process.env.TERMINALDECK_LIVE_SSH_KEY ?? '').replace(
  /^~/,
  process.env.HOME ?? '~',
)
/** A port the far machine is really serving on. Never guessed — passed in. */
const servingPort = Number(process.env.TERMINALDECK_LIVE_SSH_PORT ?? '0')
const live = host !== '' && keyPath !== '' && servingPort > 0

const clients: Client[] = []
const reaches: RemoteReach[] = []

afterAll(() => {
  for (const reach of reaches.splice(0)) reach.closeAll('the test ended')
  for (const client of clients.splice(0)) client.end()
})

/**
 * One connection for the whole file, not one per test.
 *
 * Measured while writing this, against the box itself: four handshakes inside
 * nine seconds and the fifth was dropped before the key exchange — *"Connection
 * lost before handshake"*, and the system `ssh` client does the same thing
 * intermittently against the same address. A real machine on the public
 * internet defends itself against repeated connections, and a test that dials
 * once per case is measuring that defence rather than this feature.
 *
 * It is also what the app does. `ServerConnections` reference-counts one
 * connection per server and every page, shell and tunnel joins it, so a file
 * that dialled five times would be exercising something the app never does.
 */
let shared: Promise<Client> | null = null

function connected(): Promise<Client> {
  shared ??= dial()
  return shared
}

/**
 * Dial, and try again when the machine drops the handshake.
 *
 * Not defensive habit — measured on the box this was written against, and the
 * numbers are the explanation. `sshd -T` there reports `maxstartups 10:30:100`,
 * the stock setting: once ten connections are past the socket and short of
 * authenticating, thirty per cent are dropped at random, rising to all of them
 * at thirty. And that box sits at **twenty-three established connections on
 * port 22**, because the platform running on it opens one every time it
 * deploys anything.
 *
 * So a dropped handshake there is not a fault, it is the machine being busy,
 * and the system `ssh` client fails the same way from the same laptop. Three
 * attempts with a second between them turns a real condition into the answer a
 * person would eventually get, and a genuine refusal — a wrong key, a closed
 * port — still fails on the first attempt with its own message.
 */
async function dial(attemptsLeft = 3): Promise<Client> {
  try {
    return await handshake()
  } catch (error) {
    const message = error instanceof Error ? error.message : ''
    if (attemptsLeft <= 1 || !/before handshake|ECONNRESET/i.test(message)) throw error
    await new Promise((resolve) => setTimeout(resolve, 1_000))
    return dial(attemptsLeft - 1)
  }
}

async function handshake(): Promise<Client> {
  const client = new Client()
  clients.push(client)
  await new Promise<void>((resolve, reject) => {
    client.once('ready', resolve)
    client.once('error', reject)
    client.connect({
      host,
      port: 22,
      username,
      privateKey: readFileSync(keyPath),
      // The app records a fingerprint and compares it; this file is not testing
      // that, and `host-key-checked.test.ts` is what holds the app to it.
      hostVerifier: () => true,
      agent: false,
      readyTimeout: 20_000,
    })
  })
  return client
}

function pipeThrough(client: Client): RemoteReach {
  let far: ReturnType<typeof createSshTunnelHost> | null = null
  const reach = createRemoteReach({
    send: (message) => {
      if (far === null) return false
      far.handle(message)
      return true
    },
  })
  far = createSshTunnelHost({ forward: forwardOn(client), send: (m) => reach.handle(m), name: host })
  reaches.push(reach)
  return reach
}

/** Is anything on **this** machine answering there? Used to prove a negative. */
function answersHere(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: '127.0.0.1', port })
    const done = (answer: boolean): void => {
      socket.destroy()
      resolve(answer)
    }
    socket.setTimeout(1000, () => done(true))
    socket.once('connect', () => done(true))
    socket.once('error', () => done(false))
  })
}

function head(url: string): Promise<{ status: number; headers: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const call = httpRequest(url, { method: 'GET' }, (response) => {
      response.resume()
      resolve({ status: response.statusCode ?? 0, headers: response.headers })
    })
    call.on('error', reject)
    call.end()
  })
}

describe.skipIf(!live)('a real server’s own localhost, opened here', () => {
  it('is not already answering on this machine, so the page cannot be a local one', async () => {
    // The whole proof rests on this. Without it, "localhost:8000 loaded" says
    // nothing at all about the other computer.
    expect(await answersHere(servingPort)).toBe(false)
  }, 30_000)

  it('says the server allows it, having asked the server', async () => {
    const answer = await askWhetherItForwards(forwardOn(await connected()), {
      listening: [servingPort],
    })
    expect(answer).toEqual({ known: 'yes' })
  }, 60_000)

  it('serves that port at an ordinary address on this machine, on the same number', async () => {
    const reach = pipeThrough(await connected())
    const opened = await reach.open(servingPort)
    expect(opened.ok, opened.ok ? '' : opened.message).toBe(true)
    if (!opened.ok) return
    expect(opened.url).toBe(`http://127.0.0.1:${servingPort}/`)
    expect(opened.sameNumber).toBe(true)

    const answered = await head(opened.url)
    expect(answered.status).toBeGreaterThan(0)
    /*
     * The header that makes the port ladder in `localhost-reach.ts` worth its
     * three rungs, rather than a nicety.
     *
     * Measured on the box this was written against: Coolify on 8000 answers
     * `GET /` with `Location: http://127.0.0.1:8000/login`. A far end writes
     * its own port into its own output — redirects, hot-reload sockets, cookies
     * scoped to a port — and every one of those escapes a page served at a
     * different number. The assertion is deliberately loose about *what* the
     * server says and strict about the connection having been made: this file
     * must not encode one particular website.
     */
    expect(answered.headers).toBeDefined()
  }, 60_000)

  it('opens the same address a second time without a second pipe', async () => {
    const reach = pipeThrough(await connected())
    const first = await reach.open(servingPort)
    const second = await reach.open(servingPort)
    expect(second).toEqual(first)
    expect(reach.list()).toHaveLength(1)
  }, 60_000)

  it('says nothing is answering, rather than hanging, on a port with nothing on it', async () => {
    const reach = pipeThrough(await connected())
    // Port 1: the same choice `deadPort` makes, and for the same reason — it is
    // certainly empty, so no real service on somebody's live box is touched.
    expect(await reach.open(1)).toEqual({
      ok: false,
      message: `Nothing is answering on port 1 on ${host}.`,
    })
  }, 60_000)
})
