import { createServer } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createRelayServer } from '../../relay/src/rendezvous'
import { installPaths, nodePaths, resetPaths } from '../main/platform/paths'
import { dialMachine } from '../main/remote/machines/dial'
import { PROTOCOL_VERSION, parseServerMessage, serialize } from '../main/remote/protocol'
import { SIGN_IN_NOT_SERVED } from '../main/remote/server'
import { generateStatic } from '../shared/sealed'
import { createHeadlessHost, type HeadlessHost } from './host'

/**
 * A headless host, a relay, and a phone signing in. All three real.
 *
 * ## Why this test exists
 *
 * On 2026-08-22 a headless host running 0.10.1 refused sign-in from a phone all
 * evening. Every reading of the source said it could not: `host.ts` passes
 * `signin: true`, `registerRemoteIpc` builds an `EnrollAccess` from it,
 * `createRemoteServer` is spread the object, and `enrol()` reads it. The
 * investigation that followed traced that chain by eye, decided `enroll` must
 * be missing, and spent the evening looking for where it was dropped. It was
 * never dropped. The host was serving sign-in the whole time and saying, in the
 * sentence a host with sign-in *switched off* sends, that it was not — because
 * `enroll.ts` reused it for a loopback probe that could not reach sshd.
 *
 * Nothing in this repository could have told the difference, and that is the
 * part worth fixing. `host.ts`'s sign-in wiring was covered by
 * `seam.test.ts` reading the file as **text**, and by `public-host.test.ts`
 * asserting the demo box serves none — a pair that is green whether or not a
 * real host ever answers a real `enroll` frame. So this file does not read
 * anything. It starts the relay in-process, brings up a real `createHeadlessHost`
 * against it, dials in as a guest through `dialMachine` exactly as a phone does,
 * completes the Noise handshake, and sends an `enroll` frame down the sealed
 * channel.
 *
 * ## What it asserts, and why not the obvious thing
 *
 * Not "sign-in succeeds": that would need this machine's own sshd and a real
 * login, which is a test that passes on one laptop. The probe is pointed at a
 * port nothing is listening on, so the refusal is deterministic everywhere —
 * and the refusal is the interesting part. It must be the *probe's* sentence,
 * naming the port that was dialled, and never {@link SIGN_IN_NOT_SERVED}, which
 * is the only sentence in this codebase that means the feature is not there.
 *
 * A headless host that served no sign-in at all would answer
 * {@link SIGN_IN_NOT_SERVED} here and this file would go red — which is the
 * failure the evening was spent hunting and the one nothing could see.
 */

const relay = createRelayServer({})
let relayPort = 0
let dir = ''
let host: HeadlessHost
/** A port with nothing on it, so the probe fails the same way on every machine. */
let deadSshdPort = 0
const savedEnv = { relay: process.env.TERMINALDECK_RELAY_URL, sshd: process.env.TERMINALDECK_SSHD_PORT }

/** Ask the operating system for a port, then give it straight back. */
async function closedPort(): Promise<number> {
  const probe = createServer()
  const port = await new Promise<number>((settle) => {
    probe.listen(0, '127.0.0.1', () => {
      const address = probe.address()
      settle(typeof address === 'object' && address !== null ? address.port : 0)
    })
  })
  await new Promise<void>((settle) => probe.close(() => settle()))
  return port
}

/** One real enroll frame down a real sealed channel, and whatever comes back. */
async function signInFromAPhone(): Promise<{ code: string; message: string }> {
  const state = (await host.status()).remote.relay
  if (!state) throw new Error('the host is not relaying')

  return new Promise((resolve, reject) => {
    let settled = false
    const answer = (value: { code: string; message: string }): void => {
      if (settled) return
      settled = true
      resolve(value)
    }
    void dialMachine({
      relayUrl: `ws://127.0.0.1:${relayPort}`,
      hostId: state.hostId,
      hostPublicKey: Buffer.from(state.publicKey, 'base64url'),
      // A device this host has never seen — which is the whole point of sign-in,
      // and the reason the relay has to let it through the handshake at all.
      guestKeys: generateStatic(),
      handlers: {
        message: (text) => {
          const frame = parseServerMessage(text)
          if (!frame.ok) return reject(new Error(`unparseable answer: ${text}`))
          if (frame.message.t !== 'error') return reject(new Error(`expected a refusal, got ${frame.message.t}`))
          answer({ code: frame.message.code, message: frame.message.message })
        },
        closed: (why) => {
          if (!settled) reject(new Error(`the channel closed before answering: ${why}`))
        },
      },
    })
      .then((channel) => {
        channel.send(
          serialize({
            t: 'enroll',
            protocol: PROTOCOL_VERSION,
            device: { name: 'Asad’s iPhone', platform: 'iOS 26' },
            username: 'asad',
            secret: 'not the real password',
            method: 'password',
          }),
        )
      })
      .catch(reject)
  })
}

beforeAll(async () => {
  relayPort = await closedPort()
  await new Promise<void>((settle) => relay.server.listen(relayPort, '127.0.0.1', () => settle()))
  deadSshdPort = await closedPort()

  dir = mkdtempSync(join(tmpdir(), 'td-signin-served-'))
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  process.env.TERMINALDECK_RELAY_URL = `ws://127.0.0.1:${relayPort}`
  process.env.TERMINALDECK_SSHD_PORT = String(deadSshdPort)

  host = await createHeadlessHost({
    storageDir: dir,
    // The one seam left real. Everything this file is about happens on the
    // relay path, because that is the only path that carries a peer key — the
    // direct listener attaches no sealed identity, so `enrol` refuses it before
    // it reaches sign-in at all.
    relayEnabled: true,
    readTailnet: async () => ({
      ready: false,
      state: 'logged-out',
      reason: 'This machine is signed out of Tailscale.',
    }),
    serve: {
      on: async () => ({ ok: false, message: 'not in a test' }),
      off: async () => undefined,
    },
  })

  const deadline = Date.now() + 20_000
  while (Date.now() < deadline && !(await host.status()).remote.relay?.connected) {
    await new Promise((settle) => setTimeout(settle, 100))
  }
  const state = (await host.status()).remote.relay
  if (!state?.connected) throw new Error(`the host never reached the relay: ${state?.reason ?? 'no reason'}`)
}, 40_000)

afterAll(async () => {
  await host?.stop()
  await new Promise<void>((settle) => relay.server.close(() => settle()))
  resetPaths()
  rmSync(dir, { recursive: true, force: true })
  process.env.TERMINALDECK_RELAY_URL = savedEnv.relay
  process.env.TERMINALDECK_SSHD_PORT = savedEnv.sshd
  if (savedEnv.relay === undefined) delete process.env.TERMINALDECK_RELAY_URL
  if (savedEnv.sshd === undefined) delete process.env.TERMINALDECK_SSHD_PORT
})

describe('a headless host, asked to sign a phone in', () => {
  it('serves sign-in at all', async () => {
    const refusal = await signInFromAPhone()
    // The assertion the evening was spent proving by hand, and the only one
    // that would have caught a headless host that served none.
    expect(refusal.message).not.toBe(SIGN_IN_NOT_SERVED)
  }, 30_000)

  it('says which port it could not reach, rather than that it has no sign-in', async () => {
    const refusal = await signInFromAPhone()
    expect(refusal.code).toBe('unavailable')
    expect(refusal.message).toContain(String(deadSshdPort))
    expect(refusal.message).toContain('TERMINALDECK_SSHD_PORT')
  }, 30_000)
})
