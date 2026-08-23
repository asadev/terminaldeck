/**
 * Sign in to a real host, over a real relay, from the real browser client.
 *
 * ## Why this file exists at all
 *
 * The complaint this whole lane answers is not that sign-in was broken. It is
 * that there was **nowhere to do it**: the wire shipped, `signin.ts` shipped and
 * was tested, `enroll.ts` shipped and was tested, and no screen in any client
 * called either. Two halves that each pass their own suite and have never been
 * introduced is precisely the shape of "I don't see a difference" — so a unit
 * test of the client half would have been the same mistake with more green
 * ticks on it.
 *
 * So this is the introduction, and almost nothing in it is a stand-in:
 *
 *   - the **relay** is `relay/src/rendezvous.ts`, the deployed one, on loopback;
 *   - the **host** is `createRemoteEndpoint` with a real `RemoteAuth` on a real
 *     temp directory, dialled into that relay by the real `createRelayClient`;
 *   - the **client** is `runSignIn` from the Add-server screen, opening the real
 *     `relaySocket` — the same sealed channel a phone opens;
 *   - the **address** goes through `readServerAddress`, so what the screen
 *     parses is what the host's own identity actually is.
 *
 * One thing is injected, and it is the one thing a test may not do: the SSH
 * probe. `verifyLoopbackSsh` opens a real socket to this machine's sshd and
 * tries a real login, which needs somebody's actual password. `createEnrollAccess`
 * carries the seam for exactly this reason, and the probe has its own tests in
 * `ssh-verify.test.ts`. Everything on either side of it here is production code.
 *
 * ## What it proves, in order
 *
 *  1. An address a real host could print is read back into the endpoint it
 *     names — including a `ws://` relay, which is the one case a loopback test
 *     needs and which `isRelayUrl` allows for it.
 *  2. `enroll` → `enrolled` → `hello` → `welcome` completes on one socket
 *     against the real server loop, which is the sequence no test on either side
 *     had ever run end to end.
 *  3. The credential that comes back **works on a second connection** with the
 *     same device key. That is the whole claim of the screen — a machine that
 *     stays in the list and reconnects — and it is the half that would silently
 *     be missing if `enrollDevice` bound the row to the wrong key.
 *  4. A refused login comes back as the host's own collapsed sentence, with no
 *     install command under it — that server works.
 *  5. A host that serves **no** sign-in refuses the handshake outright, because
 *     `isKnownDevice` only lets an unknown key through on a host that serves
 *     enroll. That is worth stating plainly, and it was found by running this
 *     rather than by reading: from a first-contact browser, *a machine with no
 *     sign-in is indistinguishable from a machine that is not there*, and the
 *     screen's sentence has to be true of both. An older host — the case that
 *     actually matters — refuses for exactly the same reason.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { createRelayServer } from '../../relay/src/rendezvous'
import { DeviceKinds } from '../../src/main/remote/device-kind'
import { RemoteAuth } from '../../src/main/remote/device-auth'
import { createEnrollAccess } from '../../src/main/remote/enroll'
import { loadHostIdentity } from '../../src/main/remote/host-identity'
import { createRelayClient } from '../../src/main/remote/relay-client'
import {
  authenticatorFor,
  createRemoteEndpoint,
  pairingDesk,
  SIGN_IN_NOT_SERVED,
  type SessionAccess,
} from '../../src/main/remote/server'
import { PROTOCOL_VERSION, serialize, type ServerMessage } from '../../src/main/remote/protocol'
import { generateStatic } from '../../src/shared/sealed'
import { runSignIn } from '../src/add-server'
import { readServerAddress } from '../src/server-address'
import { relaySocket } from '../src/relay-socket'

const DEVICE = { name: 'Chrome on Mac', platform: 'macOS' }

/** The least a host can have and still answer a welcome. Sessions are not the subject. */
const NO_SESSIONS: SessionAccess = {
  list: () => [],
  attach: () => null,
  write: () => {},
  resize: () => {},
  detach: () => {},
}

const closers: Array<() => void> = []
const dirs: string[] = []

afterEach(() => {
  while (closers.length > 0) closers.pop()?.()
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

interface Host {
  /** What the machine would print for somebody to paste. */
  address: string
  auth: RemoteAuth
  /** Put a pairing code up on the machine, which opens the desk. */
  showCode(): void
}

/**
 * A machine on a relay, with sign-in served or not.
 *
 * `isKnownDevice` is written exactly as `server.ts` writes it for a host that
 * serves enroll — `knowsDeviceKey(key) || desk.open() || enrollServed` — because
 * that third term is the whole reason a browser that has never been here can
 * open a channel at all, and a test that let every key through would hide the
 * one thing that makes an older host refuse.
 */
async function host(options: { signin?: boolean; login?: 'ok' | 'refused' } = {}): Promise<Host> {
  const relay = createRelayServer()
  closers.push(() => relay.close())
  await new Promise<void>((settle) => relay.server.listen(0, '127.0.0.1', settle))
  const port = (relay.server.address() as AddressInfo).port

  const dir = mkdtempSync(join(tmpdir(), 'deck-signin-'))
  dirs.push(dir)
  const auth = new RemoteAuth(dir)
  const desk = pairingDesk(auth)
  const kinds = new DeviceKinds(dir)
  const served = options.signin !== false

  const endpoint = createRemoteEndpoint({
    sessions: NO_SESSIONS,
    auth: authenticatorFor(auth, desk),
    webRoot: join(dir, 'nowhere'),
    pingIntervalMs: 0,
    ...(served
      ? {
          enroll: createEnrollAccess({
            auth,
            kinds,
            // The one stand-in, and the reason is in the header: the real probe
            // is a login against this machine's own sshd.
            verify: async () =>
              options.login === 'refused' ? { ok: false as const, reason: 'auth' as const } : { ok: true as const },
          }),
        }
      : {}),
  })

  const identity = loadHostIdentity(dir)
  const link = createRelayClient({
    url: `ws://127.0.0.1:${port}`,
    identity,
    isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open() || served,
    baseBackoffMs: 20,
    maxBackoffMs: 100,
    watchdogMs: 0,
  })
  closers.push(() => link.stop())
  link.start(endpoint.attachTransport)

  const until = Date.now() + 5_000
  while (!link.state().connected) {
    if (Date.now() > until) throw new Error('the host never claimed its slot at the relay')
    await new Promise((settle) => setTimeout(settle, 10))
  }

  return {
    auth,
    showCode: () => {
      desk.create()
    },
    // Exactly the three facts, in the shape `asEndpoint` validates — see
    // `server-address.ts`, which reads this and every other encoding of it.
    address: JSON.stringify({
      kind: 'relay',
      url: `ws://127.0.0.1:${port}`,
      hostId: identity.hostId,
      hostKey: identity.keys.publicKey.toString('base64'),
    }),
  }
}

/** The endpoint the screen would have parsed out of that paste. */
function endpointOf(address: string) {
  const read = readServerAddress(address)
  expect(read.ok, 'a real host address did not parse').toBe(true)
  if (!read.ok) throw new Error('unreachable')
  return read.endpoint
}

describe('signing in to a server from the browser client', () => {
  it('turns an address and a login into a credential that reconnects', async () => {
    const machine = await host()
    const endpoint = endpointOf(machine.address)
    // This browser's durable identity. The same pair signs in and then
    // reconnects, because the device row is bound to whichever key opened the
    // channel it was minted on.
    const deviceKeys = generateStatic()

    const outcome = await runSignIn({
      endpoint,
      username: 'asad',
      secret: 'hunter2',
      method: 'password',
      device: DEVICE,
      deviceKeys,
      timeoutMs: 15_000,
    })

    expect(outcome.ok, outcome.ok ? '' : outcome.message).toBe(true)
    if (!outcome.ok) throw new Error('unreachable')
    // `<deviceId>.<secret>` — the shape `device-auth.ts` mints and `pair.ts`
    // stores.
    expect(outcome.token).toContain('.')
    expect(outcome.token.startsWith(`${outcome.deviceId}.`)).toBe(true)
    expect(outcome.welcome.protocol).toBe(PROTOCOL_VERSION)
    // Pre-approved, which is the point of signing in rather than pairing: no
    // human at the machine, so the welcome is a welcome and not a wait.
    expect(outcome.welcome.deviceId).toBe(outcome.deviceId)

    // And now the claim the screen actually makes: this machine stays in the
    // list and reconnects. A second socket, the same key, the stored credential.
    const welcome = await helloWith(endpoint, deviceKeys, outcome.token)
    expect(welcome.t).toBe('welcome')
    if (welcome.t !== 'welcome') throw new Error('unreachable')
    expect(welcome.deviceId).toBe(outcome.deviceId)
  }, 30_000)

  it('binds the device to the key that signed in, so a different browser is refused', async () => {
    const machine = await host()
    const endpoint = endpointOf(machine.address)
    const deviceKeys = generateStatic()
    const outcome = await runSignIn({
      endpoint,
      username: 'asad',
      secret: 'hunter2',
      method: 'password',
      device: DEVICE,
      deviceKeys,
      timeoutMs: 15_000,
    })
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) throw new Error('unreachable')

    // The credential copied off this browser, presented by another one. The
    // machine remembers the key the row was bound to and refuses — which is
    // what makes the private half in `endpoint.ts` worth keeping.
    const stranger = await helloWith(endpoint, generateStatic(), outcome.token).catch(() => null)
    expect(stranger === null || stranger.t !== 'welcome').toBe(true)
  }, 30_000)

  it('reports a refused login in the host own words', async () => {
    const machine = await host({ login: 'refused' })
    const outcome = await runSignIn({
      endpoint: endpointOf(machine.address),
      username: 'asad',
      secret: 'not-the-password',
      method: 'password',
      device: DEVICE,
      deviceKeys: generateStatic(),
      timeoutMs: 15_000,
    })
    expect(outcome.ok).toBe(false)
    if (outcome.ok) throw new Error('unreachable')
    expect(outcome.kind).toBe('refused')
    // Collapsed on the host so the wire cannot tell a bad guess from a lockout,
    // and passed through here rather than rewritten.
    expect(outcome.message).toContain('refused')
    // No install command under a wrong password: that server is working.
    expect(outcome.install).toBe(false)
  }, 30_000)

  /*
   * The two shapes of "this machine will not sign you in", and they are
   * genuinely different from the browser's side. This pair was written the wrong
   * way round first, and the run corrected it — which is the reason for running
   * it against the real host rather than a fake.
   */
  it('cannot tell a machine with no sign-in from one that is not there, and says so', async () => {
    const machine = await host({ signin: false })
    const outcome = await runSignIn({
      endpoint: endpointOf(machine.address),
      username: 'asad',
      secret: 'hunter2',
      method: 'password',
      device: DEVICE,
      deviceKeys: generateStatic(),
      timeoutMs: 15_000,
    })
    expect(outcome.ok).toBe(false)
    if (outcome.ok) throw new Error('unreachable')
    /*
     * The handshake never completes. `isKnownDevice` is
     * `knowsDeviceKey(key) || desk.open() || enrollServed`, so a host that does
     * not serve enroll refuses a browser it has never seen *before a single
     * frame of the protocol crosses* — and an older host, which is the case that
     * matters, refuses for the same reason. From here that is byte for byte a
     * machine that is asleep, which is why the sentence names both and why the
     * install command goes under it: on this evidence, a box with nothing
     * installed on it is one of the two live possibilities.
     */
    expect(outcome.kind).toBe('unreachable')
    expect(outcome.install).toBe(true)
  }, 30_000)

  it('passes on the refusal in full when the channel does open', async () => {
    const machine = await host({ signin: false })
    // A code on screen opens the desk, which is the other term in
    // `isKnownDevice` — so the channel opens and the `enroll` frame reaches the
    // server, which answers rather than closing.
    machine.showCode()
    const outcome = await runSignIn({
      endpoint: endpointOf(machine.address),
      username: 'asad',
      secret: 'hunter2',
      method: 'password',
      device: DEVICE,
      deviceKeys: generateStatic(),
      timeoutMs: 15_000,
    })
    expect(outcome.ok).toBe(false)
    if (outcome.ok) throw new Error('unreachable')
    expect(outcome.kind).toBe('unavailable')
    // The host's own sentence, which names the remedy this client cannot offer.
    expect(outcome.message).toBe(SIGN_IN_NOT_SERVED)
    // And no install command under it. The host answered this frame, so it is
    // running and new enough to know the word — see `signInFor`.
    expect(outcome.install).toBe(false)
  }, 30_000)
})

/**
 * One ordinary connection with a credential, the way `Connection` makes one.
 *
 * Written out rather than reusing `Connection` because what is being asked is a
 * single question — does this credential authenticate on a fresh socket — and
 * the reconnect, the heartbeat and the backoff would all have to be disarmed to
 * ask it.
 */
function helloWith(
  endpoint: { url: string; hostId: string; hostKey: string },
  deviceKeys: ReturnType<typeof generateStatic>,
  token: string,
): Promise<ServerMessage> {
  const socket = relaySocket({
    relayUrl: endpoint.url,
    hostId: endpoint.hostId,
    hostPublicKey: Buffer.from(endpoint.hostKey, 'base64'),
    deviceKeys,
  })
  return new Promise<ServerMessage>((resolve, reject) => {
    const done = setTimeout(() => {
      socket.close(1000, 'timed out')
      reject(new Error('nothing answered the hello'))
    }, 15_000)
    socket.onopen = () => {
      socket.send(serialize({ t: 'hello', protocol: PROTOCOL_VERSION, token, device: DEVICE }))
    }
    socket.onmessage = (event) => {
      if (typeof event.data !== 'string') return
      const parsed = JSON.parse(event.data) as ServerMessage
      clearTimeout(done)
      socket.close(1000, 'answered')
      resolve(parsed)
    }
    socket.onclose = () => {
      clearTimeout(done)
      reject(new Error('the channel closed with no answer'))
    }
  })
}
