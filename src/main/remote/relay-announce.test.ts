/**
 * The relay's state changes reach the windows.
 *
 * ## The defect this pins
 *
 * The pairing screen's `blocked` sentence — "This machine is not connected to
 * the relay yet…" — is computed by `machines:list` from the relay's state. On
 * a machine with nothing paired there are no machine links, so nothing ever
 * pushed `machines:state` when the relay came up, and the warning outlived the
 * condition it warned about. The renderer papered over it with a four-second
 * poll, which is the exact shape of *"events, not polling — they make the
 * system heavier"*. The poll is deleted; this is the event that replaces it.
 *
 * Two halves, pinned separately because they can break separately:
 *
 *  1. `relayStateFanout` — a state change reaches the assembly's own hook AND
 *     the announcement, in that order, and the announcement fires even for an
 *     assembly that wired no hook (the desktop wires none).
 *  2. The wiring — `registerRemoteIpc` actually hands the fanout to
 *     `relayFor`, read off the source, because the pairing-announce bug this
 *     directory already documents was exactly a callback that existed and was
 *     never handed to anything.
 */

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { relayStateFanout } from './server'
import type { RelayState } from './relay-client'

const STATE: RelayState = {
  url: 'wss://relay.example',
  hostId: 'host-1',
  publicKey: 'pk',
  fingerprint: 'fp',
  connected: true,
  channels: 0,
  reason: null,
  retryAt: null,
}

describe('relayStateFanout', () => {
  it('announces to the windows even when no assembly hook is wired', () => {
    // The desktop is exactly this case: index.ts passes no onRelayState.
    let announced = 0
    relayStateFanout(undefined, () => announced++)(STATE)
    expect(announced).toBe(1)
  })

  it('still tells the assembly hook, with the state, before announcing', () => {
    const order: string[] = []
    const seen: RelayState[] = []
    relayStateFanout(
      (state) => {
        order.push('hook')
        seen.push(state)
      },
      () => order.push('announce'),
    )(STATE)
    expect(order).toEqual(['hook', 'announce'])
    expect(seen).toEqual([STATE])
  })

  it('is what registerRemoteIpc hands the relay', () => {
    // The callback-that-nothing-called failure is the one this directory has
    // already been bitten by (see pairing-announce.test.ts's header), so the
    // wiring is pinned too: relayFor receives the fanout, not the bare hook.
    const source = readFileSync(new URL('./server.ts', import.meta.url), 'utf8')
    expect(source).toMatch(/relayFor\([\s\S]{0,200}?relayStateFanout\(deps\.onRelayState/)
  })
})
