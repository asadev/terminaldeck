import { describe, expect, it } from 'vitest'
import type { DeviceRosterRow } from '../../src/main/remote/protocol'
import { deviceStanding, devicesOffered, fingerprintText, lastSeenSentence } from './devices'

const row = (patch: Partial<DeviceRosterRow> = {}): DeviceRosterRow => ({
  id: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
  name: 'iPhone',
  kind: 'mine',
  status: 'approved',
  addedAt: 0,
  lastSeenAt: null,
  connected: false,
  fingerprint: 'aa bb cc dd ee ff',
  ...patch,
})

describe('devicesOffered', () => {
  it('is true only when the host named the capability', () => {
    expect(devicesOffered(['devices'])).toBe(true)
    expect(devicesOffered(['credential', 'devices'])).toBe(true)
    expect(devicesOffered(['credential'])).toBe(false)
    expect(devicesOffered([])).toBe(false)
  })
})

describe('deviceStanding', () => {
  it('leads a pending row with the wait, because Remove is all it can offer', () => {
    expect(deviceStanding(row({ status: 'pending', kind: 'guest' }))).toBe('Waiting to be approved')
  })

  it('names the kind of an approved row', () => {
    expect(deviceStanding(row({ status: 'approved', kind: 'mine' }))).toBe('Your device')
    expect(deviceStanding(row({ status: 'approved', kind: 'guest' }))).toBe('Guest')
  })
})

describe('lastSeenSentence', () => {
  it('says connected now over any time', () => {
    expect(lastSeenSentence(row({ connected: true, lastSeenAt: 0 }), 10_000_000)).toBe('Connected now')
  })

  it('says never connected when there is no time', () => {
    expect(lastSeenSentence(row({ connected: false, lastSeenAt: null }), 10_000_000)).toBe('Never connected')
  })

  it('reads a time as minutes, hours and days ago', () => {
    const now = 10_000_000
    expect(lastSeenSentence(row({ lastSeenAt: now - 5 * 60_000 }), now)).toBe('Seen 5m ago')
    expect(lastSeenSentence(row({ lastSeenAt: now - 3 * 3_600_000 }), now)).toBe('Seen 3h ago')
    expect(lastSeenSentence(row({ lastSeenAt: now - 26 * 3_600_000 }), now)).toBe('Seen yesterday')
    expect(lastSeenSentence(row({ lastSeenAt: now - 3 * 86_400_000 }), now)).toBe('Seen 3d ago')
  })
})

describe('fingerprintText', () => {
  it('shows the groups, or a sentence for a keyless device', () => {
    expect(fingerprintText(row({ fingerprint: 'aa bb cc' }))).toBe('aa bb cc')
    expect(fingerprintText(row({ fingerprint: null }))).toContain('No key')
  })
})
