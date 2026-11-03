/**
 * The one test that talks to the real, deployed relay.
 *
 * Everything else about the relay is covered against a loopback server, which
 * is right: those tests must pass on a plane. But loopback runs `ws://`, and the
 * whole TLS path — `tls.connect`, certificate verification, SNI, ALPN, and
 * whatever the reverse proxy in front of the relay does to an upgrade — is
 * exercised by exactly none of it. That path was written blind and stayed
 * unproven until this file ran.
 *
 * Opt-in, because a test that needs the internet has no business failing a
 * build on a train:
 *
 *     TERMINALDECK_LIVE_RELAY=1 npx vitest run src/main/remote/relay-live.test.ts
 *
 * It connects a throwaway identity, so it pairs with nothing and leaves nothing
 * behind: the relay forgets a host the moment its socket closes.
 */

import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { DEFAULT_RELAY_URL } from '../../shared/relay-wire'
import { loadHostIdentity } from './host-identity'
import { createRelayClient } from './relay-client'

const live = process.env.TERMINALDECK_LIVE_RELAY === '1'
const url = process.env.TERMINALDECK_RELAY_URL ?? DEFAULT_RELAY_URL

interface Health {
  ok: boolean
  hosts: number
  guests: number
}

describe.skipIf(!live)('the deployed relay', () => {
  it('accepts this Mac over wss:// with a real certificate', async () => {
    const identity = loadHostIdentity(mkdtempSync(join(tmpdir(), 'td-live-')))
    const link = createRelayClient({
      url,
      identity,
      // Nothing is paired with a throwaway identity, so every device is a
      // stranger. Reaching the relay is what is under test, not letting anyone in.
      isKnownDevice: () => false,
      // A real interval, not zero. Zero means "off" by convention here, and
      // getting that wrong is how this option's footgun was found.
      heartbeatMs: 15_000,
      watchdogMs: 0,
    })
    link.start(() => {
      throw new Error('no device should ever be attached by this test')
    })

    const deadline = Date.now() + 25_000
    while (Date.now() < deadline && !link.state().connected) {
      await new Promise((resolve) => setTimeout(resolve, 250))
    }

    const state = link.state()
    expect(state.connected, `relay said: ${state.reason ?? 'nothing'}`).toBe(true)

    // And the relay agrees it is holding us, which proves the host secret was
    // accepted rather than merely that a socket opened.
    const health = (await (await fetch(`${url.replace(/^wss/, 'https')}/healthz`)).json()) as Health
    expect(health.ok).toBe(true)
    expect(health.hosts).toBeGreaterThanOrEqual(1)

    link.stop()
  }, 40_000)
})
