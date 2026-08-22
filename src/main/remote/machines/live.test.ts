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
import { CopilotAccess } from '../copilot-access'
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
import type { CopilotRemote, CopilotSink } from '../copilot-remote'
import type { CopilotStateReport, RemoteSession, ServerMessage } from '../protocol'
import { createMachineLink, type MachineLinkState } from './guest'
/*
 * The app's own binding map, not an imitation of it: the key `attach` files
 * under is the fact this file's last test is about.
 *
 * The renderer's picker is deliberately *not* imported. It reads this roster and
 * is the other half of the same chain, but `src/renderer` is not in this
 * project's file list and dragging it in pulls a `.tsx` and a `window` into the
 * main typecheck. `browser/guest-sessions.contract.test.ts` reads this file's
 * `RemoteConnection` as text from the other side instead, which is the same
 * guard the preload contract test uses across the same kind of seam.
 */
import { attach, resetForTests as resetBindings, view as bindingView } from '../../browser-binding'
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
  /** Every account switch this layer was asked to perform, in order. */
  switched: Array<{ sessionId: string; accountId: string }>
  /** The session list, which a test can grow to stand in for one started at that desk. */
  rows: RemoteSession[]
  typed: string[]
  started: string[]
  /**
   * Every session this layer was asked to subscribe to, in order.
   *
   * Recorded so that a test can assert an attach did *not* happen. That is the
   * whole property behind `CAPABILITY.send`: a fix that worked by quietly
   * attaching first would deliver the same bytes and would take a terminal
   * pane's handle away in the real app.
   */
  attaches: string[]
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
  const attaches: string[] = []
  const switched: Array<{ sessionId: string; accountId: string }> = []
  const grants = new Map<string, string[]>()
  const session: RemoteSession = {
    id: SESSION_ID,
    title: 'agent',
    cwd: '/tmp/project',
    provider: 'claude',
    status: 'running',
    exitCode: null,
  }
  const rows: RemoteSession[] = [session]
  return {
    typed,
    started,
    attaches,
    switched,
    rows,
    list: () => rows,
    grants,
    attach(id): SessionHandle | null {
      attaches.push(id)
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
    /*
     * The control cluster, **with the far machine's connectors on it**.
     *
     * Present because its presence is what makes that machine advertise the
     * `controls` capability at all — see `SessionAccess.controls` — and the
     * connectors are on the reading rather than on a frame of their own because
     * that is where `host-core.ts` puts them. Asad, on a session running on his
     * PC: *"I want it exactly like the local ones."*
     */
    controls: {
      read: (id) =>
        Promise.resolve({
          model: { value: 'opus-5', label: 'Opus 5', source: 'screen' },
          effort: { value: 'xhigh', label: 'Extra high', source: 'screen' },
          fast: { value: 'off', label: 'Off', source: 'screen' },
          permission: { value: null, label: null, source: null },
          live: id === SESSION_ID,
          agent: { running: true, saw: 'Claude Code' },
          gate: { canType: true, reason: null },
          connectors: [
            { id: 'user:github', name: 'github', scope: 'user', transport: 'stdio', enabled: true, disabledReason: null },
            {
              id: 'project:figma',
              name: 'figma',
              scope: 'project',
              transport: 'http',
              enabled: false,
              disabledReason: 'Not approved for this project',
            },
          ],
        }),
      apply: () =>
        Promise.resolve({ ok: true, message: 'Model is now Opus 5.', reading: { value: 'opus-5', label: 'Opus 5', source: 'screen' } }),
    },
    /*
     * And the account chip's seam, which is the other half of the same sentence.
     *
     * `switch` **replaces the session**, so the fixture does what the real one
     * does: it puts a new row in the list and answers with its id. A test that
     * echoed the old id back would let a window that ignores the new one pass.
     */
    account: {
      read: () =>
        Promise.resolve({
          current: { id: 'work', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
          accounts: [
            { id: 'work', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
            { id: 'system', name: 'Default', provider: 'claude', color: 'acct-1', system: true },
          ],
        }),
      switch: (sessionId, accountId) => {
        switched.push({ sessionId, accountId })
        const replacement = { ...session, id: `${SESSION_ID}-as-${accountId}` }
        rows.splice(0, rows.length, replacement)
        return Promise.resolve({ ok: true, message: '', session: replacement.id })
      },
    },
    // Keyed by device, exactly as `folder-grants.ts` is. A paired desktop is a
    // device with a device id like any phone, and this is what makes the claim
    // that folder grants apply to it something the test can check rather than
    // something the design says.
    folders: (deviceId) => grants.get(deviceId) ?? [],
  }
}

/**
 * The far machine's copilot, real everywhere the test is about it.
 *
 * `CopilotAccess` is the genuine article rather than a stub, and that is the
 * point of the fixture: the question this whole feature turns on — *does this
 * device reach the copilot* — is answered by the module that answers it in the
 * app, reading the same `DeviceKinds` file a person writes by pressing **My
 * device** or **Guest** on the approval screen. A fake that returned `true`
 * would prove the wire and nothing about the rule the wire exists to carry.
 *
 * What is faked is the part that spawns an agent: `start` mints a run id
 * instead of a process, and `say` records the words and pushes a bubble back
 * through the subscription the way a real turn does. That asymmetry is
 * deliberate — this file already says it stands up the real relay and the real
 * pairing because *"every bug the relay path has had lived in a seam a mock
 * replaces"*, and no bug in that class has ever lived inside a Claude CLI.
 */
interface FakeCopilot extends CopilotRemote {
  /** Devices whose `copilot.hello` was served. Empty is "nothing ever opened it". */
  opened: string[]
  started: string[]
  said: Array<{ deviceId: string; text: string }>
}

function fakeCopilot(kinds: DeviceKinds): FakeCopilot {
  const access = new CopilotAccess({ isMine: (deviceId) => kinds.kindOf(deviceId) === 'mine' })
  const opened: string[] = []
  const started: string[] = []
  const said: Array<{ deviceId: string; text: string }> = []
  const sinks = new Map<string, CopilotSink>()
  const runs = new Map<string, string>()

  const report = (deviceId: string): CopilotStateReport => ({
    // The copilot at that desk, which is a different thing from this device's
    // own run and is reported separately for that reason. `stopped` is honest
    // here: nobody is sitting at the fixture.
    desk: 'stopped',
    run: runs.get(deviceId) ?? null,
    profile: 'Personal',
    signedIn: true,
    tools: 14,
    turnTokens: 2200,
    pending: 0,
    grant: access.granted(deviceId),
    available: true,
    reason: null,
  })

  return {
    opened,
    started,
    said,
    granted: (deviceId) => access.granted(deviceId),
    linked: (deviceId) => access.linked(deviceId),
    open: (deviceId) => {
      opened.push(deviceId)
      return Promise.resolve({ ok: true })
    },
    closed: () => {},
    state: report,
    sessions: () => [],
    log: () => ({ rows: [], more: false }),
    pending: () => [],
    answer: () => false,
    watch: (deviceId, sink) => {
      sinks.set(deviceId, sink)
      return () => sinks.delete(deviceId)
    },
    start: (deviceId) => {
      started.push(deviceId)
      runs.set(deviceId, `run-${started.length}`)
      return Promise.resolve({ ok: true })
    },
    say: (deviceId, text) => {
      said.push({ deviceId, text })
      /*
       * Answered on the subscription, not as a reply to the frame, because that
       * is the shape of the real one and the shape the client has to survive.
       * There is no request id anywhere on the copilot wire: `copilot.say`
       * returns nothing at all, and what a person sees comes back as a pushed
       * `copilot.chat`. A fixture that resolved with the answer would let a
       * client that never subscribed pass.
       */
      sinks
        .get(deviceId)
        ?.chat(runs.get(deviceId) ?? 'run-0', [{ id: `m${said.length}`, role: 'you', text, at: 1 }], false)
      return Promise.resolve({ ok: true })
    },
    cancel: () => ({ ok: true }),
    stop: () => ({ ok: true }),
    revoked: () => {},
    stopAll: () => {},
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

/**
 * The machine on the other side of the room: a relay, and a host dialled into it.
 *
 * `copilot: true` gives it the copilot layer **and** the eligibility rule that
 * decides who is told about it, and the two travel together on purpose: without
 * the rule every device is eligible, which is the default a host written before
 * device kinds existed still gets, and a test that switched one on without the
 * other would be measuring a machine nobody ships.
 *
 * It is opt-in rather than always on because the rule is not only about the
 * copilot. `capabilitiesFor` withholds `web` and `localhost` from an ineligible
 * device too — one eligibility question behind all three, so a device cannot be
 * a guest for one and an owner for another — and switching it on for every test
 * in this file would silently narrow what the older ones are talking to.
 */
async function farMachine(
  options: {
    copilot?: boolean
    /**
     * The two halves of *this* machine holding a browser window for a session on
     * the computer that dialled it.
     *
     * `serveWindows` is what makes the endpoint advertise `hostWindows` at all —
     * see `capabilityOffered` in `server.ts` — and `windowsHeldFor` is the answer
     * it sends on that capability. Both are optional so every other test in this
     * file builds the machine it always built.
     */
    serveWindows?: (deviceId: string, call: { sessionId: string; tool: string; args: string }) => Promise<{ ok: boolean; body: string }>
    windowsHeldFor?: (deviceId: string) => readonly string[]
  } = {},
): Promise<{
  relayUrl: string
  auth: RemoteAuth
  desk: ReturnType<typeof pairingDesk>
  sessions: Sessions
  endpoint: RemoteEndpoint
  offer: MachineOffer
  kinds: DeviceKinds
  copilot: FakeCopilot
}> {
  const relayUrl = await loopbackRelay()

  const dir = tempDir()
  const auth = new RemoteAuth(dir)
  const desk = pairingDesk(auth)
  const sessions = fakeSessions()
  const kinds = new DeviceKinds(tempDir())
  const copilot = fakeCopilot(kinds)
  const endpoint = createRemoteEndpoint({
    sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: join(dir, 'nowhere'),
    pingIntervalMs: 0,
    ...(options.copilot
      ? { copilot, copilotEligible: (deviceId: string): boolean => kinds.kindOf(deviceId) === 'mine' }
      : {}),
    ...(options.serveWindows ? { serveWindows: options.serveWindows } : {}),
    ...(options.windowsHeldFor ? { windowsHeldFor: options.windowsHeldFor } : {}),
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
    kinds,
    copilot,
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
      // Nothing here revokes, so the store half of the cascade is a no-op stand-in.
      forgetDevice: () => {},
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

  it('types into a session on the other machine without ever attaching to it', async () => {
    /*
     * The cross-machine proof of `CAPABILITY.send`, with the same relay, the
     * same pairing and the same two endpoints as the test above it — and with
     * the one thing that test does deliberately left out.
     *
     * His words on the 2026-08-20 review: *"if the browser is local, it should
     * be able to send to the remote session too. Not just local sessions. If
     * they are visible here, they should be working too."* The browser's picker
     * has listed the far machine's sessions since 2026-08-18 and could type into
     * none of them, because the only verb that wrote into a session was `input`
     * and the host refuses one without an attach — and attaching in order to
     * type would take the handle away from whatever terminal pane on this link
     * already held it and replay its whole scrollback at the person reading it.
     *
     * So the assertions that matter here are the negative ones. `attaches` is
     * empty and `output` is empty: nothing subscribed, nothing was replayed,
     * and the text still arrived at the far machine's pty.
     */
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    beacon?.stop()

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
      onState: () => {},
      onOutput: (_sessionId, data) => output.push(data),
      onWelcome: () => {},
      baseBackoffMs: 20,
      maxBackoffMs: 60,
    })
    closers.push(() => link.disconnect())
    link.connect()

    await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
    const deviceId = far.auth.listDevices()[0].id
    far.sessions.grants.set(deviceId, ['/tmp/project'])
    far.auth.approveDevice(deviceId)
    await waitFor(() => link.state().state === 'online', 'the link to come up after approval')

    // Advertised by that machine without anybody arranging it: `SessionAccess.write`
    // is a required member of the interface, so every host serves this.
    expect(link.state().capabilities).toContain('send')

    const answer = await link.send(SESSION_ID, 'look at this button\r')
    expect(answer).toEqual({ ok: true, message: 'Sent.' })
    // It reached the other machine's pty, through the relay, over the sealed
    // channel, into the same `write` an ordinary keystroke goes to.
    expect(far.sessions.typed.join('')).toContain('look at this button')

    // And nothing subscribed on the way. No handle was taken from the far end,
    // so no pane lost one — and no scrollback came back to be printed at
    // somebody a second time.
    expect(far.sessions.attaches, 'the send attached to the far session').toEqual([])
    expect(output, 'the send replayed the far session at this machine').toEqual([])

    link.disconnect()
  }, 30_000)

  it('draws all four chips over a session on the other machine, and moves it to another login', async () => {
    /*
     * The cross-machine proof of the two seams the 2026-08-20 review was still
     * missing, on the same relay and the same pairing as the tests above.
     *
     * Asad, watching a session running on his PC:
     *
     *   > *"on the remote sessions, I don't have any of these features. We had
     *   > this before, but I don't have it now. I want it exactly like the local
     *   > ones."*
     *
     * and, a minute later:
     *
     *   > *"Then also bring the account selection here for the remote sessions
     *   > too."*
     *
     * Two chips were missing and both were missing for the same reason: nothing
     * on the wire carried the fact. The connectors ride the reading the control
     * cluster was already asking for, and the account is a capability of its own
     * because it is a different act — `switch` stops a process over there and
     * starts another, which is why the answer carries a **new session id** and
     * why that is the assertion that matters most here.
     */
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    beacon?.stop()

    const states: MachineLinkState[] = []
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
      onOutput: () => {},
      onWelcome: () => {},
      baseBackoffMs: 20,
      maxBackoffMs: 60,
    })
    closers.push(() => link.disconnect())
    link.connect()

    await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
    const deviceId = far.auth.listDevices()[0].id
    far.sessions.grants.set(deviceId, ['/tmp/project'])
    far.auth.approveDevice(deviceId)
    await waitFor(() => link.state().state === 'online', 'the link to come up after approval')

    // Both advertised, and each off its own member of `SessionAccess` — a host
    // that could read a screen but not replace a session says only the first.
    expect(link.state().capabilities).toContain('controls')
    expect(link.state().capabilities).toContain('account')

    /* ------------------------------------------------------ connectors -- */

    const reading = await link.readControls(SESSION_ID)
    expect(reading?.model.label).toBe('Opus 5')
    // The far machine's own `mcp:list`, resolved for the far session's folder,
    // arriving over the relay on the reading the cluster was already asking for.
    expect(reading?.connectors?.map((row) => row.name)).toEqual(['github', 'figma'])
    // Every field the chip draws survives, including the CLI's own reason for a
    // server it would skip — the wording is composed on the drawing side by
    // `rowDetail`, so what has to travel is the facts.
    expect(reading?.connectors?.[1]).toEqual({
      id: 'project:figma',
      name: 'figma',
      scope: 'project',
      transport: 'http',
      enabled: false,
      disabledReason: 'Not approved for this project',
    })

    /* --------------------------------------------------------- account -- */

    const account = await link.readAccount(SESSION_ID)
    expect(account?.current?.name).toBe('work@example.com')
    expect(account?.accounts.map((row) => row.id)).toEqual(['work', 'system'])

    const moved = await link.switchAccount(SESSION_ID, 'system')
    expect(moved.ok).toBe(true)
    // It reached the far machine's own switch — the same operation the window at
    // that desk performs — with the session and the account it was given.
    expect(far.sessions.switched).toEqual([{ sessionId: SESSION_ID, accountId: 'system' }])
    /*
     * And came back with the id the session has *now*, which is not the id it
     * was asked about. This is the field with no counterpart on `controls`: a
     * switch replaces the process, so a window that kept the old id would sit
     * attached to a pty that machine has already killed.
     */
    expect(moved.session).toBe(`${SESSION_ID}-as-system`)
    expect(moved.session).not.toBe(SESSION_ID)

    link.disconnect()
  }, 30_000)

  it('shows a session started at the other machine’s own keyboard, without being asked', async () => {
    /*
     * K2, watched rather than reasoned about.
     *
     * `sessionsChanged()` is wired in `src/main/index.ts` from the core's own
     * `onSessionStarted` and `onSessionRemoved` hooks, and `server.test.ts` pins
     * that it puts a `sessions` frame on every live socket. What nobody had done
     * is watch a session appear at one end and turn up at the other **with
     * nothing on this side asking** — which is the whole claim, because this
     * link polls for nothing and a list that only refreshed on `list` would look
     * identical in source.
     *
     * So: no `link.list()` anywhere below. The far machine grows a session the
     * way its own keyboard would, calls the same hook `index.ts` calls, and the
     * assertion is on the state this link published on its own.
     */
    const far = await farMachine()
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    beacon?.stop()

    const link = createMachineLink({
      id: paired.offer.hostId,
      secrets: {
        hostId: paired.offer.hostId,
        hostPublicKey: Buffer.from(paired.offer.publicKey, 'base64'),
        relayUrl: paired.offer.relayUrl,
        credential: paired.credential,
        guestKeys: paired.guestKeys,
      },
      onState: () => {},
      onOutput: () => {},
      onWelcome: () => {},
      baseBackoffMs: 20,
      maxBackoffMs: 60,
    })
    closers.push(() => link.disconnect())
    link.connect()

    await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
    const deviceId = far.auth.listDevices()[0].id
    far.sessions.grants.set(deviceId, ['/tmp/project'])
    far.auth.approveDevice(deviceId)
    await waitFor(() => link.state().state === 'online', 'the link to come up after approval')
    await waitFor(() => link.state().sessions.length === 1, 'the list that arrives with the welcome')

    // Somebody sits down at the other machine and starts a session. The core's
    // `onSessionStarted` is what calls this; nothing here is a shortcut past it.
    far.sessions.rows.push({
      id: 'started-at-that-desk',
      title: 'agent',
      cwd: '/tmp/project',
      provider: 'claude',
      status: 'running',
      exitCode: null,
    })
    expect(far.endpoint.sessionsChanged()).toBe(1)

    await waitFor(
      () => link.state().sessions.some((row) => row.id === 'started-at-that-desk'),
      'the new session to arrive on its own',
    )

    // And the other direction: it ends over there, and the row leaves this list
    // without a reload. `onSessionRemoved` calls the same function.
    far.sessions.rows.splice(1, 1)
    expect(far.endpoint.sessionsChanged()).toBe(1)
    await waitFor(
      () => link.state().sessions.every((row) => row.id !== 'started-at-that-desk'),
      'the ended session to leave on its own',
    )

    link.disconnect()
  }, 30_000)

  it('lets the computer being dialled attach a window to a session on the one dialling it', async () => {
    /*
     * The fourth cell of *"from any session from any device to any device's
     * browser in one app"*, watched end to end rather than reasoned about.
     *
     * Every part of it existed before today and none of it could fire.
     * `window-grants.ts` held the permission, `server.ts` sent the device
     * `window.holds`, `window-serve.ts` decided its `window.call`, and
     * `index.ts`'s `windowsHeldFor(deviceId)` filtered the binding map for it —
     * and that filter was always empty, correctly, because nothing in the app
     * could name a session on a computer that had dialled *in*, so no window was
     * ever attached to one, so no binding was ever filed under a device's id.
     *
     * The direction here is the one this file usually runs backwards. `far` is
     * the computer with the **screen and the browser window** — the endpoint —
     * and `link` is the computer with the **ptys**, dialling in. So the roster on
     * `far` is where the sessions have to arrive, the picker on `far` is what has
     * to produce a row, and the announcement has to come back to `link` for its
     * agent to have anywhere to send a browser verb.
     *
     * Nothing below asks for any of it. No `list()`, no poll: the link announces
     * on its own welcome, and `far` announces back the moment a window is
     * attached.
     */
    resetBindings()
    const ptys: RemoteSession[] = [
      {
        id: 'pty-on-the-dialling-machine',
        title: 'terminaldeck',
        cwd: '/Users/apple/Projects/terminaldeck',
        provider: 'claude',
        status: 'idle',
        exitCode: null,
      },
    ]

    const served: Array<{ deviceId: string; sessionId: string; tool: string }> = []
    const far = await farMachine({
      // Its presence is what advertises `hostWindows`, which is the capability
      // both halves of this conversation travel on — and it is also the end of
      // the chain, so what reaches it is recorded rather than discarded.
      serveWindows: (deviceId, call) => {
        served.push({ deviceId, sessionId: call.sessionId, tool: call.tool })
        return Promise.resolve({ ok: true, body: '{}' })
      },
      // The real read `index.ts` makes, against the real binding map.
      windowsHeldFor: (deviceId) =>
        bindingView()
          .sessions.filter((binding) => binding.machineId === deviceId && binding.windows.length > 0)
          .map((binding) => binding.sessionId),
    })
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    beacon?.stop()

    let heldThere: readonly string[] = []
    const link = createMachineLink({
      id: paired.offer.hostId,
      secrets: {
        hostId: paired.offer.hostId,
        hostPublicKey: Buffer.from(paired.offer.publicKey, 'base64'),
        relayUrl: paired.offer.relayUrl,
        credential: paired.credential,
        guestKeys: paired.guestKeys,
      },
      onState: () => {},
      onOutput: () => {},
      onWelcome: () => {},
      // What is running on this machine, which the far one cannot derive.
      ownSessions: () => ptys,
      // And what it says back: which of these sessions has a window over there.
      onWindowHolds: (sessions) => {
        heldThere = sessions
      },
      baseBackoffMs: 20,
      maxBackoffMs: 60,
    })
    closers.push(() => link.disconnect())
    link.connect()

    await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
    const deviceId = far.auth.listDevices()[0].id
    far.auth.approveDevice(deviceId)
    await waitFor(() => link.state().state === 'online', 'the link to come up after approval')

    // 1. The announcement arrives with nothing on that side asking for it.
    await waitFor(
      () => far.endpoint.connections()[0]?.sessions.length === 1,
      'the dialling machine to say what it is running',
    )

    // 2. And it arrives wearing the row the picker reads: the device's id, the
    //    device's name, and that device's own sessions. Those four field names
    //    are the seam, and `browser/guest-sessions.contract.test.ts` is what
    //    stops them drifting apart from the reader on the other side.
    const roster = far.endpoint.connections()[0]
    expect(roster.deviceId).toBe(deviceId)
    expect(roster.deviceName).not.toBe('')
    expect(roster.sessions[0].id).toBe('pty-on-the-dialling-machine')

    // 3. Somebody ticks it in the menu the picker built. The relation is filed
    //    under the **device's** id, which is the half of
    //    `<machineId>\0<sessionId>` that had never held one.
    attach({
      sessionId: roster.sessions[0].id,
      machineId: roster.deviceId,
      browserTabId: 'browser:1:1',
      url: 'https://example.com',
      title: 'Example',
    })

    // 4. Which is what `windowsHeldFor` has been answering emptily about all
    //    along, and it is no longer empty.
    expect(far.endpoint.windowsHeldChanged()).toBe(1)

    // 5. And it lands on the machine the pty is on, so its agent's browser verbs
    //    have somewhere to go.
    await waitFor(
      () => heldThere.includes('pty-on-the-dialling-machine'),
      'the far machine to say it is holding a window for that session',
    )

    // 6. Which is what the agent in that pty has been waiting for. It asks, over
    //    the same link, and the ask arrives at the computer whose browser it is —
    //    named by the same device id the window was filed under. Everything past
    //    this point is `window-serve.ts`'s grant and `deck-control`'s dispatcher,
    //    both pinned elsewhere; what was never true before is that the frame had
    //    anywhere to go.
    expect(
      link.askWindow({
        t: 'window.call',
        id: 'ask-1',
        session: 'pty-on-the-dialling-machine',
        tool: 'browser.read',
        args: '{}',
      }),
    ).toBe(true)
    await waitFor(() => served.length === 1, 'the browser verb to reach the machine with the window')
    expect(served[0]).toEqual({
      deviceId,
      sessionId: 'pty-on-the-dialling-machine',
      tool: 'browser.read',
    })

    // 7. A terminal closed over there leaves the picker on its own, which is how
    //    the row stops being offered for a pty that has gone.
    ptys.length = 0
    expect(link.announceSessions()).toBe(true)
    await waitFor(
      () => far.endpoint.connections()[0]?.sessions.length === 0,
      'the closed terminal to leave the roster',
    )

    link.disconnect()
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

/**
 * This desktop reaching the copilot on **the other machine**, over the real wire.
 *
 * ## What it is for
 *
 * His words on the 2026-08-20 review, about two paired machines and one copilot
 * page: *"the same switch we have for sessions"* at the top of it, so the
 * copilot can be used against either. The host half of that has existed for
 * weeks — `server.ts` advertises the capability, answers `copilot.hello`,
 * serves `copilot.attach` and pushes state and chat — and until now **nothing
 * on this side had ever sent one of those frames**. That is the failure this
 * repository keeps re-finding under different names: the mechanism written, the
 * connection absent.
 *
 * ## Where it actually broke, which is one line in the shared parser
 *
 * `parseServerFrame` rebuilt a `welcome` field by name and never copied
 * `copilot`. A desktop guest therefore received every welcome with the copilot
 * key silently removed, so the only per-device fact that says *this machine
 * shares its copilot with you* could not reach this side at all. The PWA
 * survived it by re-attaching the key in a private shim after calling the
 * shared parser; nothing else had one. The first assertion below is that
 * amputation, as a positive statement.
 *
 * ## The two cases, and why the second one is the load-bearing one
 *
 * `mine` proves the pipe. `guest` proves the rule the pipe exists to carry, and
 * it is the one that has to hold: the absence of a copilot key is the whole of
 * *"the copilot is never shared"* — not a capability advertised and refused, an
 * absence — and a client that manufactured a link out of that absence would put
 * a copilot on screen for a machine that never offered one and refuse every
 * press on it.
 */
describe('reaching the other machine’s copilot', () => {
  /**
   * Pair to that machine, be approved as `kind`, and come up online.
   *
   * The kind is written before the device is let in, which is the order the
   * approval screen uses and not an incidental one:
   * `remote:device:approve` claims the kind first and abandons the whole
   * approval if the claim does not take, because a device admitted with no kind
   * reads as a guest with no folders and looks to its owner like a device that
   * paired and then broke. It also cannot be changed afterwards —
   * `DeviceKinds.claim` writes once and there is deliberately no method that
   * overwrites one — so this is the only moment in either test where the answer
   * is still open.
   */
  async function pairAs(
    far: Awaited<ReturnType<typeof farMachine>>,
    kind: 'mine' | 'guest',
    watchers: {
      onCopilotState?: (state: CopilotStateReport) => void
      onCopilotChat?: (chat: Extract<ServerMessage, { t: 'copilot.chat' }>) => void
    } = {},
  ): Promise<{
    link: ReturnType<typeof createMachineLink>
    deviceId: string
    states: MachineLinkState[]
  }> {
    const code = far.desk.create()
    const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
    closers.push(() => beacon?.stop())
    expect(await beacon?.ready()).toBe(true)

    const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
    if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
    beacon?.stop()

    const states: MachineLinkState[] = []
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
      onOutput: () => {},
      onWelcome: () => {},
      ...watchers,
      baseBackoffMs: 20,
      maxBackoffMs: 60,
    })
    closers.push(() => link.disconnect())
    link.connect()

    await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
    const deviceId = far.auth.listDevices()[0].id
    expect(far.kinds.claim(deviceId, kind)).toBe(true)
    far.sessions.grants.set(deviceId, ['/tmp/project'])
    far.auth.approveDevice(deviceId)
    await waitFor(() => link.state().state === 'online', 'the link to come up after approval')
    return { link, deviceId, states }
  }

  it('opens, attaches, starts a run and says something, all from the other desktop', async () => {
    const far = await farMachine({ copilot: true })
    const reports: CopilotStateReport[] = []
    const chats: Array<Extract<ServerMessage, { t: 'copilot.chat' }>> = []
    const { link, deviceId, states } = await pairAs(far, 'mine', {
      onCopilotState: (state) => reports.push(state),
      onCopilotChat: (chat) => chats.push(chat),
    })

    /* ------------------------------------ the welcome carried the copilot -- */

    /*
     * Read off the *first* online state rather than off the link now, because
     * that snapshot is the welcome itself — `open` false, before this socket
     * had said hello — and it is the one the shared parser used to drop the key
     * out of. Asserting on the current state a moment later would pass against
     * a build that learned about the copilot from the `copilot.grant` push and
     * knew nothing at the welcome, which is a different feature.
     */
    const welcomed = states.find((state) => state.state === 'online')
    expect(welcomed?.capabilities).toContain('copilot')
    expect(welcomed?.copilot).toEqual({
      linked: true,
      open: false,
      grant: { read: true, act: true, alter: true },
    })

    /* ------------------------------------------- and the stream is opened -- */

    /*
     * Sent by the link on the welcome, not by anything a person pressed. Every
     * copilot verb — the read-tier ones included — is refused by that machine
     * until this socket has said hello, and the socket is new after every
     * reconnect, so an opening that lived in a window would be an opening that
     * a sleeping laptop silently loses.
     */
    await waitFor(() => link.state().copilot?.open === true, 'the copilot stream to open')
    expect(far.copilot.opened).toEqual([deviceId])

    /* ------------------------------------------------- watching, and state -- */

    expect(link.copilotAttach()).toEqual({ ok: true, message: 'Watching that machine’s copilot.' })
    await waitFor(() => reports.length > 0, 'the copilot state to arrive')
    // `desk` and `run` are two different things and the frame keeps them apart:
    // the copilot at that machine's own keyboard is stopped, and this desktop
    // has no run of its own yet. A surface that read the first as the second
    // would offer to start something that is already running, or refuse to
    // because something unrelated is.
    expect(reports[0]).toMatchObject({ desk: 'stopped', run: null, profile: 'Personal' })
    expect(reports[0].grant).toEqual({ read: true, act: true, alter: true })

    /* ------------------------------------------------- a run, and a message -- */

    expect(link.copilotStart().ok).toBe(true)
    await waitFor(() => far.copilot.started.length === 1, 'the run to start over there')
    // The run id comes back on the same subscription, which is what turns a
    // composer from a control that cannot work into one that can: `say` has
    // nothing to talk to while `run` is null.
    await waitFor(() => reports.some((state) => state.run !== null), 'the run id to come back')

    expect(link.copilotSay('which of my sessions is stuck?')).toEqual({ ok: true, message: 'Sent.' })
    await waitFor(() => far.copilot.said.length === 1, 'the message to reach the copilot')
    // It arrived over there attributed to *this* device, which is what makes a
    // run its own rather than a second keyboard on somebody else's.
    expect(far.copilot.said).toEqual([{ deviceId, text: 'which of my sessions is stuck?' }])

    // And came back as a pushed bubble rather than as a reply to the frame,
    // carrying the run it belongs to — the field that lets a client drop a
    // frame from a run that has ended instead of splicing it onto a live one.
    await waitFor(() => chats.length > 0, 'the chat frame to come back')
    expect(chats[0].run).toBe('run-1')
    expect(chats[0].messages).toEqual([
      { id: 'm1', role: 'you', text: 'which of my sessions is stuck?', at: 1 },
    ])

    link.disconnect()
  }, 30_000)

  it('shares nothing at all with a desktop paired as a guest, and refuses every verb', async () => {
    const far = await farMachine({ copilot: true })
    const reports: CopilotStateReport[] = []
    const chats: unknown[] = []
    const { link } = await pairAs(far, 'guest', {
      onCopilotState: (state) => reports.push(state),
      onCopilotChat: (chat) => chats.push(chat),
    })

    /*
     * **Absent, not false**, and the difference is the whole design. A guest is
     * sent no `copilot` key and is not told the capability exists, because a
     * client that is told draws the surface and a surface that refuses on every
     * press is a worse answer than one that was never there. So there is no
     * frame this desktop can send that measures whether that machine has a
     * copilot at all — which is why the two reasons it might see nothing get
     * one sentence between them.
     */
    expect(link.state().copilot).toBeNull()
    expect(link.state().capabilities).not.toContain('copilot')
    // `web` goes with it — opening a page puts a window on the owner's screen,
    // which is driving the machine rather than reaching a folder. One
    // eligibility question behind both, so a device cannot be a guest for one
    // and an owner for the other.
    expect(link.state().capabilities).not.toContain('web')
    /*
     * `localhost` does **not** go with them, and the split is deliberate.
     *
     * It used to be stripped here on the argument that a port cannot be
     * attributed to a folder — true of a port *scan*, false of the dev servers
     * this app started itself in a folder it was given. Stripping the capability
     * made that difference invisible and left a feature half-built: a guest
     * granted a folder could already ask this host to start its dev server and
     * be told the port, and then could not open it.
     *
     * So the capability is advertised and the narrowing moved into the hub,
     * where one list decides both what is offered and what may be dialled. A
     * guest with no granted folder is offered an empty list, which is an honest
     * answer rather than a refusal — pinned at the socket in
     * `src/main/remote/server.test.ts` ("what a guest may reach on the
     * loopback"), which is where the ports plumbing lives.
     */
    expect(link.state().capabilities).toContain('localhost')

    // Nothing said hello, because nothing had a copilot key to say it about.
    expect(far.copilot.opened).toEqual([])

    for (const outcome of [
      link.copilotAttach(),
      link.copilotStart(),
      link.copilotState(),
      link.copilotSay('what are you working on?'),
    ]) {
      expect(outcome.ok).toBe(false)
      // The sentence names the remedy, and the remedy is pairing again rather
      // than a setting, because there is no setting: a device's kind is decided
      // once and there is deliberately no control that overwrites it.
      expect(outcome.message).toMatch(/guest/i)
    }

    /*
     * Refused **here**, without a frame leaving this machine, which is the
     * property that matters rather than the wording.
     *
     * A host that has never heard of a frame answers it by closing the channel,
     * so a hopeful send is not a failed request — it is a disconnection that
     * takes every terminal session on this link with it. The link is still up
     * and the far copilot was never touched.
     */
    expect(link.state().state).toBe('online')
    expect(far.copilot.opened).toEqual([])
    expect(far.copilot.started).toEqual([])
    expect(far.copilot.said).toEqual([])
    expect(reports).toEqual([])
    expect(chats).toEqual([])

    // And the guest is a perfectly good guest. Nothing about the copilot
    // refusal touches the sessions it was granted, which is the whole point of
    // the kind being about the copilot rather than about being let in.
    expect(link.state().sessions.map((session) => session.id)).toEqual([SESSION_ID])

    link.disconnect()
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
