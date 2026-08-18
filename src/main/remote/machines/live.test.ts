/**
 * One desktop reaching another, end to end, with nothing stubbed in the middle.
 *
 * Every component here is the real one: the relay from `relay/src/rendezvous`
 * on a loopback port, the far machine's `createRelayClient` and
 * `createRemoteEndpoint` over a real `RemoteAuth` in a temp directory, the real
 * pairing desk, the real code from `shared/short-code.ts`, and this desktop's
 * real `startBeacon`, `pairWithCode`, `dialMachine` and `createMachineLink`.
 *
 * That is deliberate rather than thorough. Every bug the relay path has had
 * lived in a seam a mock replaces — masking on client frames, the bytes that
 * arrive in the same TCP segment as the `101`, a transcript hash that differs by
 * one field, a cipher that exists under Node and not under Electron. A test that
 * called a handler with a hand-made buffer would pass against a client that
 * cannot complete one real connection.
 *
 * What it does **not** prove is stated plainly because somebody will read this
 * file and believe it: both ends are this process, on loopback, on one operating
 * system. A Mac talking to a Windows PC across the internet is the same code and
 * has not been run.
 */

import { randomBytes } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { connect as netConnect } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import type { Server, Socket } from 'node:net'
import { createRelayServer } from '../../../../relay/src/rendezvous'
import { RemoteAuth } from '../device-auth'
import { loadHostIdentity } from '../host-identity'
import { createRelayClient } from '../relay-client'
import { FolderGrants } from '../folder-grants'
import { DeviceKinds } from '../device-kind'
import {
  authenticatorFor,
  createRemoteEndpoint,
  pairingDesk,
  registerRemoteIpc,
  type CreateOutcome,
  type RemoteEndpoint,
  type SessionAccess,
  type SessionHandle,
} from '../server'
import type { RemoteSession } from '../protocol'
import { createMachineLink, type MachineLinkState } from './guest'
import { pairWithCode, lookupMachine } from './pair'
import { offerFrom, rendezvousIdentity, startBeacon, type MachineOffer } from './rendezvous'

const SESSION_ID = 'live-session-7f31'
const SCROLLBACK = 'SCROLLBACK-FROM-THE-OTHER-MACHINE'

const temps: string[] = []
const closers: Array<() => void | Promise<void>> = []

afterEach(async () => {
  for (const close of closers.splice(0).reverse()) await close()
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-machines-live-'))
  temps.push(dir)
  return dir
}

async function listen(server: Server): Promise<number> {
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', () => settle()))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  return address.port
}

async function waitFor(predicate: () => boolean, label: string, timeoutMs = 8000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (predicate()) return
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise((settle) => setTimeout(settle, 5))
  }
}

interface Sessions extends SessionAccess {
  typed: string[]
  started: string[]
  /** Which folders each device may use, keyed the way the real store is. */
  grants: Map<string, string[]>
}

/**
 * A session layer with `create` and `folders` on it, because their *presence*
 * is what makes the far machine advertise the `create` capability — see
 * `SessionAccess.create`. A fixture without them would be a fixture that quietly
 * tests a host which cannot start a session.
 */
function fakeSessions(): Sessions {
  const typed: string[] = []
  const started: string[] = []
  const grants = new Map<string, string[]>()
  const session: RemoteSession = {
    id: SESSION_ID,
    title: 'agent',
    cwd: '/tmp/project',
    provider: 'claude',
    status: 'running',
    exitCode: null,
  }
  return {
    typed,
    started,
    grants,
    list: () => [session],
    attach(id): SessionHandle | null {
      return id === SESSION_ID ? { sessionId: id, replay: SCROLLBACK } : null
    },
    write(_id, data): void {
      typed.push(data)
    },
    resize(): void {},
    detach(): void {},
    create(request): Promise<CreateOutcome> {
      started.push(request.cwd ?? '')
      return Promise.resolve({
        ok: true,
        session: { ...session, id: `${SESSION_ID}-2`, cwd: request.cwd ?? session.cwd },
      })
    },
    // Keyed by device, exactly as `folder-grants.ts` is. A paired desktop is a
    // device with a device id like any phone, and this is what makes the claim
    // that folder grants apply to it something the test can check rather than
    // something the design says.
    folders: (deviceId) => grants.get(deviceId) ?? [],
  }
}

/** A real relay on a loopback port, torn down with the test. */
async function loopbackRelay(): Promise<string> {
  const relay = createRelayServer()
  /*
   * Every socket the relay accepts, so the harness can take the wire away.
   *
   * `relay.close()` on its own waits for the connection count to reach zero,
   * and an upgraded socket keeps counting. The relay half-closes one whenever a
   * guest asks for a host that is not there, and half-closed is not closed — so
   * a test that dials a code nobody is showing leaves `close()` waiting for a
   * connection nobody is going to finish. That is a property of Node's server
   * rather than a defect in anything here, and pulling the cable is what a real
   * network would eventually do anyway.
   */
  const wires = new Set<Socket>()
  relay.server.on('connection', (socket: Socket) => {
    wires.add(socket)
    socket.on('close', () => wires.delete(socket))
  })
  closers.push(() => {
    for (const socket of [...wires]) {
      // Silenced first: destroying a socket makes its peer read `ECONNRESET`,
      // and a Node socket with no `error` listener turns that into an uncaught
      // exception that fails the run from outside any test.
      socket.on('error', () => {})
      socket.destroy()
    }
    return relay.close()
  })
  return `ws://127.0.0.1:${await listen(relay.server)}`
}

/** The machine on the other side of the room: a relay, and a host dialled into it. */
async function farMachine(): Promise<{
  relayUrl: string
  auth: RemoteAuth
  desk: ReturnType<typeof pairingDesk>
  sessions: Sessions
  endpoint: RemoteEndpoint
  offer: MachineOffer
}> {
  const relayUrl = await loopbackRelay()

  const dir = tempDir()
  const auth = new RemoteAuth(dir)
  const desk = pairingDesk(auth)
  const sessions = fakeSessions()
  const endpoint = createRemoteEndpoint({
    sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: join(dir, 'nowhere'),
    pingIntervalMs: 0,
  })
  const identity = loadHostIdentity(dir)

  const link = createRelayClient({
    url: relayUrl,
    identity,
    // The production rule, both halves of it: a device this machine already
    // knows, or any device at all while a code is on screen.
    isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
    baseBackoffMs: 20,
    maxBackoffMs: 100,
    watchdogMs: 0,
  })
  closers.push(() => link.stop())
  link.start(endpoint.attachTransport)
  await waitFor(() => link.state().connected, 'the far machine to claim its host id')

  return {
    relayUrl,
    auth,
    desk,
    sessions,
    endpoint,
    offer: {
      relayUrl,
      hostId: identity.hostId,
      publicKey: identity.keys.publicKey.toString('base64'),
      name: 'Studio PC',
      platform: 'win32',
    },
  }
}

/**
 * This desktop, assembled by the registration the app runs at launch.
 *
 * Not a fixture standing in for it: `registerRemoteIpc` builds the trust store,
 * the pairing desk, the server and the relay link, and the handlers kept here
 * are the very functions the preload's `startRemotePairing` invokes. Nothing
 * about a pairing code can be proved by calling something that resembles the
 * handler — the defect this covers *was* a handler that did half of what its
 * neighbour did.
 *
 * Tailscale is reported missing and the proxy seam throws, so the only route
 * this machine has is the loopback relay. That is the situation of most people
 * who type a pairing code.
 *
 * `relay: false` builds the same desktop with the relay switched off in the
 * build, which is the cheapest honest way to reach `offerFrom(null)` — a
 * machine with no address to publish, so a code it mints cannot be looked up by
 * anything. Nothing is stubbed to produce that: the registration is told the
 * same thing `TERMINALDECK_RELAY=0` tells it, and the rest follows.
 */
async function thisDesktop(options: { relay?: boolean } = {}): Promise<{
  relayUrl: string
  hostId: string
  publicKey: Buffer
  invoke(channel: string): Promise<unknown>
}> {
  const wantsRelay = options.relay !== false
  const relayUrl = await loopbackRelay()
  const dir = tempDir()
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()

  const remote = registerRemoteIpc(
    {
      handle: (channel, listener) => {
        handlers.set(channel, listener)
      },
    },
    {
      sessions: fakeSessions(),
      folders: new FolderGrants(tempDir()),
      kinds: new DeviceKinds(tempDir()),
      webRoot: join(dir, 'nowhere'),
      storageDir: dir,
      broadcast: () => {},
      relayEnabled: wantsRelay,
      relayUrl,
      // Read no environment at all. `TERMINALDECK_RELAY_URL` set on the machine
      // running the tests would otherwise point this at the public relay, and a
      // green test would mean a socket to production.
      env: {},
      readTailnet: async () => ({
        ready: false,
        state: 'not-installed',
        reason: 'Tailscale is not installed on this machine.',
      }),
      serve: {
        on: async () => {
          throw new Error('nothing may ask Tailscale for a proxy in this test')
        },
        off: async () => {},
      },
    },
  )
  closers.push(() => void remote.server.stop())

  // Nobody pressed anything: `registerRemoteIpc` dials at launch. Waiting for
  // that is waiting for the same thing a person waits for before the panel says
  // it is connected.
  if (wantsRelay) {
    await waitFor(
      () => remote.server.status().relay?.connected === true,
      'this desktop to reach the relay',
    )
  }
  const relay = remote.server.status().relay
  if (wantsRelay && !relay) throw new Error('no relay state')

  return {
    relayUrl,
    hostId: relay?.hostId ?? '',
    publicKey: Buffer.from(relay?.publicKey ?? '', 'base64url'),
    invoke: async (channel) => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler(null)
    },
  }
}

describe('the code the Remote panel shows a phone', () => {
  /*
   * The defect, as three assertions.
   *
   * A six-digit code only works if the machine showing it is sitting in
   * the rendezvous slot `hostIdFor(scrypt(code))` names, answering with its real
   * address. Only `machines:code` ever started that beacon; `remote:pair` — the
   * phone pairing — minted the same-looking code and published nothing, so
   * typing it reached a slot with nobody in it and the person was told no
   * machine was showing their code. The relay was fine. Nothing was broken
   * except the half that had never been wired.
   */
  it('is findable at the rendezvous, the same as one from Machines → Add', async () => {
    const deck = await thisDesktop()
    const minted = (await deck.invoke('remote:pair')) as {
      token: string
      expiresAt: number
      findable: boolean
    }

    // Said in the answer, not only in the world. The handler computes this while
    // it claims the slot and threw it away for a release, so the panel drew
    // every failure below as a success — see the false case in the next test.
    expect(minted.findable).toBe(true)

    // The lookup is given the code and a relay, and nothing else — no host id,
    // no key, no link. That is exactly what a person typing six digits
    // into another machine has.
    const found = await lookupMachine({ code: minted.token, relayUrl: deck.relayUrl })
    expect(found?.hostId).toBe(deck.hostId)
    expect(found?.relayUrl).toBe(deck.relayUrl)
    // Through the base64/base64url boundary the offer crosses, because a key
    // that survives the frame and not the encoding is a machine nobody can dial.
    expect(Buffer.from(found?.publicKey ?? '', 'base64').equals(deck.publicKey)).toBe(true)
  }, 30_000)

  it('pairs from those six digits, and stops being findable once they are spent', async () => {
    const deck = await thisDesktop()
    const minted = (await deck.invoke('remote:pair')) as { token: string }

    // The whole chain the phone panel promises: find the machine from the code,
    // dial its real address, redeem the code, come away with a credential.
    const paired = await pairWithCode({ code: minted.token, relayUrl: deck.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    expect(paired.offer.hostId).toBe(deck.hostId)
    expect(paired.credential).toContain('.')

    // The token is single-use and was burned on the match. A slot still sitting
    // there would be this machine advertising an address that now refuses the
    // code it is advertising — and nothing on the redeeming path calls a cancel
    // button, which is why the rendezvous had to belong to the desk.
    expect(
      await lookupMachine({ code: minted.token, relayUrl: deck.relayUrl, lookupTimeoutMs: 2000 }),
    ).toBeNull()
  }, 30_000)

  it('says so in its answer when there was nothing to publish', async () => {
    /*
     * The guard, and the half that was missing.
     *
     * This desktop has the relay switched off in the build and no tailnet, so
     * `offerFrom` has no address to put in a slot and the code is minted with
     * no rendezvous behind it. It is still a real code — the tailnet-served
     * browser client can redeem it where the page's own origin is the address —
     * which is why the handler answers rather than refuses.
     *
     * What it must not do is answer with six digits and nothing else. That is
     * the shape the Remote panel drew as success: a code, a countdown and a
     * Copy button, for a pairing that could not happen. The failure then landed
     * a minute later on a phone, which could only say "no machine is showing
     * that code" and could not say which end was at fault.
     *
     * This case survives every fix to the rendezvous itself: a relay that is
     * down, a network that blocks it, or a laptop on a captive-portal wifi all
     * arrive here, and the answer has to carry the bad news.
     */
    const deck = await thisDesktop({ relay: false })
    const minted = (await deck.invoke('remote:pair')) as { token: string; findable: boolean }

    expect(minted.token).not.toBe('')
    expect(minted.findable).toBe(false)
    // And it really is unfindable — the flag is not a label somebody set by
    // hand. Nothing claimed the slot those digits name.
    expect(
      await lookupMachine({ code: minted.token, relayUrl: deck.relayUrl, lookupTimeoutMs: 2000 }),
    ).toBeNull()
  }, 30_000)

  it('stops being findable when the panel is closed', async () => {
    const deck = await thisDesktop()
    const minted = (await deck.invoke('remote:pair')) as { token: string }
    expect(await lookupMachine({ code: minted.token, relayUrl: deck.relayUrl })).not.toBeNull()

    await deck.invoke('remote:pair:cancel')
    // Close is one press and it has to mean both halves: the desk stops
    // honouring the code and the machine leaves the slot. A Close that only
    // stopped drawing it would leave a live rendezvous for a code the trust
    // store has already forgotten.
    expect(
      await lookupMachine({ code: minted.token, relayUrl: deck.relayUrl, lookupTimeoutMs: 2000 }),
    ).toBeNull()
  }, 30_000)
})

describe('finding a machine from a typed code', () => {
  it('reads the far machine’s address off the rendezvous the code names', async () => {
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    expect(beacon).not.toBeNull()
    closers.push(() => beacon?.stop())
    // The slot is a WebSocket dial, so a code shown before it lands is a code
    // that answers "nobody is showing that". `machines:code` waits on exactly
    // this before it puts one on screen.
    expect(await beacon?.ready()).toBe(true)

    const found = await lookupMachine({ code: code.token, relayUrl: far.relayUrl })
    expect(found).toEqual(far.offer)
  })

  it('accepts the code however it was typed', async () => {
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    // Lower case, no hyphen. Both ends normalise before deriving, or pairing
    // would depend on which keyboard somebody used.
    const typed = code.token.replace('-', '').toLowerCase()
    expect(await lookupMachine({ code: typed, relayUrl: far.relayUrl })).toEqual(far.offer)
  })

  it('finds nothing for a code nobody is showing', async () => {
    const far = await farMachine()
    // A well-formed code that was never minted. The rendezvous it names has no
    // host in it, and the relay says nothing either way — answering would make
    // the endpoint an oracle for which machines are online.
    const found = await lookupMachine({
      code: '482913',
      relayUrl: far.relayUrl,
      lookupTimeoutMs: 1200,
    })
    expect(found).toBeNull()
  })

  it('finds nothing for a string that is not a code', async () => {
    const far = await farMachine()
    expect(
      await lookupMachine({ code: 'nope', relayUrl: far.relayUrl, lookupTimeoutMs: 1200 }),
    ).toBeNull()
  })
})

describe('pairing, and then being a guest', () => {
  it('pairs, waits to be approved, and then opens a session on the other machine', async () => {
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    /* ---------------------------------------------------------- pairing -- */

    const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    expect(paired.offer.hostId).toBe(far.offer.hostId)
    // `<deviceId>.<secret>` — the credential the far machine minted, and the
    // only thing that lets this desktop come back.
    expect(paired.credential).toContain('.')
    expect(far.auth.listDevices()).toHaveLength(1)
    expect(far.auth.listDevices()[0].status).toBe('pending')

    beacon?.stop()

    /* ------------------------------------------ refused until approved -- */

    const states: MachineLinkState[] = []
    const output: string[] = []
    const link = createMachineLink({
      id: paired.offer.hostId,
      secrets: {
        hostId: paired.offer.hostId,
        hostPublicKey: Buffer.from(paired.offer.publicKey, 'base64'),
        relayUrl: paired.offer.relayUrl,
        credential: paired.credential,
        guestKeys: paired.guestKeys,
      },
      onState: (state) => states.push(state),
      onOutput: (_sessionId, data) => output.push(data),
      onWelcome: () => {},
      baseBackoffMs: 20,
      maxBackoffMs: 60,
    })
    closers.push(() => link.disconnect())
    link.connect()

    // The far machine says "approve this device" and closes. That is a state a
    // person can act on, not an error — printing it as one sends them to the
    // wrong screen.
    await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
    expect(link.state().reason).toMatch(/approve/i)

    /* ------------------------------------------------- and then, in -- */

    const deviceId = far.auth.listDevices()[0].id
    // The grant is made before the device is let in, the way a person does it:
    // approve the machine and choose what it may open, both on the far keyboard.
    far.sessions.grants.set(deviceId, ['/tmp/project'])
    far.auth.approveDevice(deviceId)
    // No poke, no re-press: the link is already redialling on its backoff, which
    // is what makes approval work without anything watching for it.
    await waitFor(() => link.state().state === 'online', 'the link to come up after approval')

    const state = link.state()
    expect(state.sessions.map((session) => session.id)).toEqual([SESSION_ID])
    expect(state.hostPlatform).toBe(process.platform)
    expect(state.capabilities).toContain('create')
    /*
     * The point of the uniform model, as an assertion.
     *
     * Nothing here asked for a desktop-shaped rule. The far machine ran the same
     * `folders(deviceId)` it runs for a phone, against the device id it minted
     * when this desktop paired, and the answer arrived in the same `welcome`
     * field a phone reads.
     */
    expect(state.folders).toEqual(['/tmp/project'])

    // And a change made over there reaches this machine without a reconnect,
    // through the pushed frame rather than through anybody asking again.
    far.sessions.grants.set(deviceId, ['/tmp/other'])
    expect(far.endpoint.foldersChanged(deviceId)).toBe(1)
    await waitFor(
      () => JSON.stringify(link.state().folders) === JSON.stringify(['/tmp/other']),
      'the pushed folder list',
    )

    /* ---------------------------------------------------- the session -- */

    expect(link.attach(SESSION_ID, 100, 30)).toBe(true)
    await waitFor(() => output.join('').includes(SCROLLBACK), 'the scrollback to replay')

    expect(link.input(SESSION_ID, 'echo hello\r')).toBe(true)
    await waitFor(() => far.sessions.typed.join('').includes('echo hello'), 'the keystrokes to land')

    expect(link.resize(SESSION_ID, 120, 40)).toBe(true)
    expect(link.detach(SESSION_ID)).toBe(true)

    link.disconnect()
    expect(link.state().state).toBe('offline')
  }, 30_000)

  it('refuses a code that has already been spent', async () => {
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    expect((await pairWithCode({ code: code.token, relayUrl: far.relayUrl })).ok).toBe(true)
    // Single use. The desk cancels the window the moment the code is redeemed,
    // so the second attempt cannot even complete a handshake.
    const second = await pairWithCode({
      code: code.token,
      relayUrl: far.relayUrl,
      lookupTimeoutMs: 1500,
      pairTimeoutMs: 1500,
    })
    expect(second.ok).toBe(false)
  }, 30_000)
})

describe('the rendezvous is not something the relay can answer', () => {
  it('refuses a beacon that was started with a different code', async () => {
    // The responder key is derived from the code, so a machine sitting in the
    // slot with the wrong one cannot complete `es` — which is the property that
    // stops a hostile relay substituting its own address for the real one.
    const far = await farMachine()
    const code = far.desk.create()
    const imposter = startBeacon({
      code: '999999',
      offer: { ...far.offer, name: 'Not the right machine' },
      relayUrl: far.relayUrl,
    })
    closers.push(() => imposter?.stop())
    expect(await imposter?.ready()).toBe(true)

    // The imposter is at a *different* slot, so the honest lookup finds nothing
    // rather than finding a lie.
    expect(
      await lookupMachine({ code: code.token, relayUrl: far.relayUrl, lookupTimeoutMs: 1200 }),
    ).toBeNull()
  }, 20_000)
})

/* ------------------------------------------- what a raw upgrade can prove -- */

/**
 * Open one HTTP upgrade at the relay and report the status line, then hang up.
 *
 * Deliberately raw rather than through `dialMachine`: the thing being pinned
 * below is what the relay's *HTTP surface* answers, and a client that speaks the
 * sealed handshake on top of it would hide the very distinction at issue.
 */
async function upgradeStatus(relayUrl: string, path: string): Promise<number> {
  const url = new URL(relayUrl)
  return new Promise<number>((resolve) => {
    let settled = false
    const done = (status: number): void => {
      if (settled) return
      settled = true
      socket.removeAllListeners()
      socket.on('error', () => {})
      socket.destroy()
      resolve(status)
    }
    const socket = netConnect({ host: url.hostname, port: Number(url.port) }, () => {
      socket.write(
        [
          `GET ${path} HTTP/1.1`,
          `Host: ${url.hostname}:${url.port}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}`,
          'Sec-WebSocket-Version: 13',
          '',
          '',
        ].join('\r\n'),
      )
    })
    let head = ''
    socket.on('data', (chunk: Buffer) => {
      head += chunk.toString('latin1')
      if (head.indexOf('\r\n\r\n') === -1) return
      done(Number(/^HTTP\/1\.1 (\d+)/.exec(head)?.[1] ?? 0))
    })
    // Zero for anything that ended without a status line at all, which is a
    // failure of this helper rather than an answer worth asserting on.
    socket.on('error', () => done(0))
    socket.on('close', () => done(0))
  })
}

/**
 * What an HTTP probe at the relay can and cannot tell you about a slot.
 *
 * This exists because of a wrong diagnosis, and it is written down so the same
 * one cannot be reached twice. On **2026-08-16** a pairing failure was root-caused
 * to "the beacon never claims its rendezvous slot", on the strength of one
 * measurement: an upgrade to `wss://relay.terminaldeck.dev/?host=<slot>`, inside
 * the code's sixty seconds, answered **404** — the same answer as a control slot
 * of all A's that nobody could possibly be sitting in.
 *
 * Both halves of that reasoning are wrong, and the two assertions below are the
 * two halves:
 *
 *  - `/?host=…` is not the guest endpoint. `GUEST_PATH` is `/v1/join`, and the
 *    relay answers 404 to every path it does not serve. A slot this test *proves*
 *    is claimed answers 404 there too, so the measurement distinguished nothing.
 *  - `/v1/join?host=…` cannot be used as the control either, and that is
 *    deliberate rather than accidental: it answers **101 whether or not anybody
 *    is in the slot**, and only then closes an unroutable one. A 404/101 split
 *    would make the endpoint an oracle for which machines are online, which is
 *    exactly what a relay treated as hostile must not offer.
 *
 * The honest probe is the one the rest of this file uses — `lookupMachine`,
 * which dials the slot and reads the offer, and which was run by hand against
 * the public relay on 2026-08-16 from both plain Node and the shipped 0.2.0
 * build: the slot was claimed in ~0.5s and the offer came back in under a
 * second, both times.
 */
describe('probing a rendezvous slot over plain HTTP', () => {
  it('answers 404 on the wrong path even for a slot that is provably claimed', async () => {
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)
    const slot = rendezvousIdentity(code.token)?.hostId ?? ''
    expect(slot).not.toBe('')

    // Claimed — not by assertion, by reading the offer off it.
    expect(await lookupMachine({ code: code.token, relayUrl: far.relayUrl })).toEqual(far.offer)

    // And the probe that "proved" it empty says 404 about it anyway.
    expect(await upgradeStatus(far.relayUrl, `/?host=${slot}`)).toBe(404)
    expect(await upgradeStatus(far.relayUrl, `/v1/join?host=${slot}`)).toBe(101)
  }, 20_000)

  it('answers 101 on the guest path for a slot nobody is in, so 101 means nothing', async () => {
    const far = await farMachine()
    // A well-formed host id that was never claimed. The upgrade succeeds and the
    // relay then closes the channel, because saying "not online" in the status
    // line would answer a question this service refuses to answer.
    const empty = 'AAAAAAAAAAAAAAAAAAAAAAAAAA'
    expect(await upgradeStatus(far.relayUrl, `/v1/join?host=${empty}`)).toBe(101)
    expect(await upgradeStatus(far.relayUrl, `/?host=${empty}`)).toBe(404)
  }, 20_000)
})

/* ------------------------------------------ two copies, one host identity -- */

/**
 * Two copies of this app on one machine, and why pairing then fails silently.
 *
 * Measured on Asad's Mac on **2026-08-16**, and this is the failure he actually
 * hit rather than the one that was reported. `/Applications/Terminal Deck.app`
 * and a `npm run dev` build were both running. `pinUserData` sends both to
 * `~/Library/Application Support/terminaldeck`, so both loaded the *same*
 * `relay-identity.json` and both dialled the relay claiming the same host name.
 * `Rendezvous.attachHost` replaces an incumbent rather than refusing the newcomer
 * — correct, and the reason is in its comment: the usual cause is one machine
 * reconnecting after a network change, and refusing would lock somebody out of
 * their own Mac. So the loser is cut, reconnects on its backoff, and cuts the
 * winner. `lsof` against the relay's address showed the two processes trading the
 * connection every 25–55 seconds for three minutes, never both present.
 *
 * What that does to a pairing code is this test:
 *
 *  - The **rendezvous slot is fine**. It is named by the code, not by the
 *    machine, so the copy that minted the code claims it uninterrupted and
 *    `findable` is true. Every measurement aimed at the rendezvous therefore
 *    comes back clean, which is what sent the first diagnosis to the wrong place.
 *  - The **address inside the offer is the shared host id**. The phone reads it,
 *    dials it, and the relay routes it to whichever copy holds the name at that
 *    instant — which is a coin flip, and half the time it is the copy that has no
 *    code on screen.
 *  - That copy refuses, and refuses *silently by design*: `isKnownDevice` is
 *    false for a first-time device on a desk with nothing minted, and
 *    `relay-client.ts` closes a refused handshake with nothing on the wire and a
 *    throttled line in a log nobody is reading, so the relay gets no oracle. The
 *    phone says "no machine is showing that code" and the Mac shows no approval
 *    prompt — which is exactly what was reported.
 *
 * The fix is not in this directory: one process per machine, in
 * `src/main/index.ts`, is what stops two of them sharing an identity. This test
 * is here so the symptom is never re-diagnosed as a broken rendezvous.
 */
describe('two copies of this app sharing one host identity', () => {
  /**
   * One copy: its own endpoint and desk, the shared identity, its own link.
   *
   * The backoff is pushed far out on purpose. The eviction war is real and its
   * period is a minute; reproducing the *war* would make this test a race, and
   * what is being pinned is the routing it causes, which is deterministic.
   */
  async function copyOfTheApp(relayUrl: string, dir: string): Promise<{
    desk: ReturnType<typeof pairingDesk>
    auth: RemoteAuth
    connected(): boolean
    offer(): MachineOffer | null
  }> {
    const auth = new RemoteAuth(dir)
    const desk = pairingDesk(auth)
    const endpoint = createRemoteEndpoint({
      sessions: fakeSessions(),
      auth: authenticatorFor(auth, desk),
      webRoot: join(dir, 'nowhere'),
      pingIntervalMs: 0,
    })
    const link = createRelayClient({
      url: relayUrl,
      // The whole point: `loadHostIdentity` reads one file, and two processes
      // pointed at one user-data directory get one identity between them.
      identity: loadHostIdentity(dir),
      isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
      baseBackoffMs: 60_000,
      maxBackoffMs: 60_000,
      watchdogMs: 0,
    })
    closers.push(() => link.stop())
    link.start(endpoint.attachTransport)
    return {
      desk,
      auth,
      connected: () => link.state().connected,
      // Read the same way `remote:pair` reads it, so the host id in the offer is
      // the one the app would really publish rather than one this test composed.
      offer: () => offerFrom(link.state()),
    }
  }

  it('leaves the second copy holding the name, and the first copy unreachable', async () => {
    const relayUrl = await loopbackRelay()
    const dir = tempDir()

    const first = await copyOfTheApp(relayUrl, dir)
    await waitFor(() => first.connected(), 'the first copy to claim the host name')
    const second = await copyOfTheApp(relayUrl, dir)
    await waitFor(() => second.connected(), 'the second copy to claim the host name')
    // The relay cut the incumbent the moment the newcomer proved the same
    // secret. Both copies are running, both think remote access is on, and only
    // one of them is reachable.
    await waitFor(() => !first.connected(), 'the first copy to be cut')

    const offer = second.offer()
    expect(offer).not.toBeNull()
    // One name between two processes, which is the fault stated as an equality.
    expect(first.offer()).toBeNull()
    expect(offer?.hostId).toBe(loadHostIdentity(dir).hostId)
  }, 30_000)

  it('mints a findable code on the wrong copy, which nothing can then pair with', async () => {
    const relayUrl = await loopbackRelay()
    const dir = tempDir()

    const first = await copyOfTheApp(relayUrl, dir)
    await waitFor(() => first.connected(), 'the first copy to claim the host name')
    // Captured while the first copy still holds the name, because that is the
    // window in which somebody presses the button: the panel says Connected, the
    // status is honest, and the address it is about to publish is correct.
    const offer = first.offer()
    expect(offer).not.toBeNull()

    const second = await copyOfTheApp(relayUrl, dir)
    await waitFor(() => second.connected(), 'the second copy to take the host name')
    await waitFor(() => !first.connected(), 'the first copy to be cut')

    if (offer === null) throw new Error('the first copy had no address to publish')
    const shown = await first.desk.show(offer)
    /*
     * Findable, and that is the trap.
     *
     * The slot is named by the code, so the copy that minted it sits in the slot
     * on a second connection of its own and nothing contends for that. Every
     * check aimed at the rendezvous passes; the guard added for the *other*
     * failure cannot fire here, because there is nothing wrong with the
     * rendezvous.
     */
    expect(shown.findable).toBe(true)
    const found = await lookupMachine({ code: shown.code.token, relayUrl })
    expect(found?.hostId).toBe(offer.hostId)

    /*
     * And then it fails, at the second dial, where nothing says why.
     *
     * The address is right, the relay is up, the code is live — and the relay
     * routes the host name to the *second* copy, whose desk minted nothing. A
     * first-time device has no key that copy knows and no code open there, so
     * the sealed handshake is refused and the channel closes with nothing on
     * the wire. `pairWithCode` can only report that the machine stopped
     * answering.
     */
    const paired = await pairWithCode({
      code: shown.code.token,
      relayUrl,
      lookupTimeoutMs: 4000,
      pairTimeoutMs: 4000,
    })
    expect(paired.ok).toBe(false)
    // Nobody was added anywhere, on either copy. That is the missing approval
    // prompt, as an assertion.
    expect(second.auth.listDevices()).toHaveLength(0)
  }, 30_000)
})
