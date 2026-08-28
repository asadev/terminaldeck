/**
 * The pure fold from {@link HostControlFacts} to the wire shape — pinned as a
 * function so the mapping is a thing a test can read directly rather than a step
 * hidden inside the server handler.
 */

import { describe, expect, it } from 'vitest'
import { hostControlWire, type HostControlFacts } from './host-lifecycle'

const FACTS: HostControlFacts = {
  version: '0.14.0',
  address: 'terminaldeck://slot.relay',
  pid: 4242,
  startedAt: 1_900_000_000_000,
  uptimeSeconds: 3600,
  managed: 'systemd',
}

describe('hostControlWire', () => {
  it('carries the facts through and always says running', () => {
    expect(hostControlWire(FACTS, null)).toEqual({
      running: true,
      version: '0.14.0',
      address: 'terminaldeck://slot.relay',
      pid: 4242,
      startedAt: 1_900_000_000_000,
      uptimeSeconds: 3600,
      managed: 'systemd',
      note: null,
    })
  })

  it('folds a restart/stop note in — the last thing the phone hears', () => {
    const wire = hostControlWire(FACTS, 'Restarting over the relay.')
    expect(wire.note).toBe('Restarting over the relay.')
    expect(wire.running).toBe(true)
  })
})
