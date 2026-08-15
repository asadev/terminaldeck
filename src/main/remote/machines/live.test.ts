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

import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import type { Server, Socket } from 'node:net'
import { createRelayServer } from '../../../../relay/src/rendezvous'
import { RemoteAuth } from '../device-auth'
import { loadHostIdentity } from '../host-identity'
import { createRelayClient } from '../relay-client'
import { FolderGrants } from '../folder-grants'
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
import { startBeacon, type MachineOffer } from './rendezvous'

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
 */
async function thisDesktop(): Promise<{
  relayUrl: string
  hostId: string
  publicKey: Buffer
  invoke(channel: string): Promise<unknown>
}> {
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
      webRoot: join(dir, 'nowhere'),
      storageDir: dir,
      broadcast: () => {},
      relayEnabled: true,
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
  await waitFor(() => remote.server.status().relay?.connected === true, 'this desktop to reach the relay')
  const relay = remote.server.status().relay
  if (!relay) throw new Error('no relay state')

  return {
    relayUrl,
    hostId: relay.hostId,
    publicKey: Buffer.from(relay.publicKey, 'base64url'),
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
   * An eight-character code only works if the machine showing it is sitting in
   * the rendezvous slot `hostIdFor(scrypt(code))` names, answering with its real
   * address. Only `machines:code` ever started that beacon; `remote:pair` — the
   * phone pairing — minted the same-looking code and published nothing, so
   * typing it reached a slot with nobody in it and the person was told no
   * machine was showing their code. The relay was fine. Nothing was broken
   * except the half that had never been wired.
   */
  it('is findable at the rendezvous, the same as one from Machines → Add', async () => {
    const deck = await thisDesktop()
    const minted = (await deck.invoke('remote:pair')) as { token: string; expiresAt: number }

    // The lookup is given the code and a relay, and nothing else — no host id,
    // no key, no link. That is exactly what a person typing eight characters
    // into another machine has.
    const found = await lookupMachine({ code: minted.token, relayUrl: deck.relayUrl })
    expect(found?.hostId).toBe(deck.hostId)
    expect(found?.relayUrl).toBe(deck.relayUrl)
    // Through the base64/base64url boundary the offer crosses, because a key
    // that survives the frame and not the encoding is a machine nobody can dial.
    expect(Buffer.from(found?.publicKey ?? '', 'base64').equals(deck.publicKey)).toBe(true)
  }, 30_000)

  it('pairs from those eight characters, and stops being findable once they are spent', async () => {
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
      code: 'H4K9-2FQT',
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
      code: 'ZZZZ-ZZZZ',
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
