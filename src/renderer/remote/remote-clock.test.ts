import { describe, expect, it } from 'vitest'
import {
  attachedFor,
  codeSecondsLeft,
  nextClockChange,
  retryNote,
  unsettled,
  whenSeen,
  type RemoteConnection,
  type RemoteDevice,
  type RemoteRelay,
  type RemoteState,
} from './RemoteSection'

/**
 * The panel's clock used to be a 500 ms interval. It is now a single wake-up
 * scheduled for the moment a label would read differently, which is only an
 * improvement if that moment is actually right — a tick computed one second
 * late is a countdown that skips a number, and a tick computed too early is the
 * interval back again under another name.
 *
 * So these tests do one thing: take the moment `nextClockChange` returns, and
 * check that the text really is the same just before it and different at it.
 */

const NOW = 1_700_000_000_000
const SECOND = 1000
const MINUTE = 60_000

function state(over: Partial<RemoteState> = {}): RemoteState {
  return {
    running: true,
    url: 'https://mac.tail.ts.net:7420',
    address: '100.64.0.1',
    reason: null,
    relay: null,
    devices: [],
    connections: [],
    ...over,
  }
}

function device(over: Partial<RemoteDevice> = {}): RemoteDevice {
  return {
    id: 'dev-1',
    name: 'iPhone',
    state: 'approved',
    addedAt: null,
    lastSeenAt: null,
    fingerprint: null,
    ...over,
  }
}

function connection(over: Partial<RemoteConnection> = {}): RemoteConnection {
  return {
    id: 'conn-1',
    deviceId: 'dev-1',
    deviceName: 'iPhone',
    platform: 'ios',
    address: '100.64.0.9',
    connectedAt: NOW,
    sessionIds: [],
    tunnels: [],
    ...over,
  }
}

function relay(over: Partial<RemoteRelay> = {}): RemoteRelay {
  return {
    url: 'wss://relay.example',
    hostId: 'host',
    publicKey: 'key',
    fingerprint: 'ab cd',
    connected: true,
    channels: 0,
    reason: null,
    retryAt: null,
    ...over,
  }
}

describe('nextClockChange', () => {
  it('asks for no timer when nothing on screen depends on the clock', () => {
    expect(nextClockChange(null, null, NOW)).toBeNull()
    expect(nextClockChange(state(), null, NOW)).toBeNull()
  })

  it('keeps a daily timer while the label still counts days', () => {
    // "paired 3 days ago" moves once a day, so it gets one wake-up a day. A
    // window left open over a weekend used to freeze that label at "1 day ago"
    // on the row whose whole job is saying how long something has had a way in.
    const old = state({ devices: [device({ lastSeenAt: NOW - 40 * 3_600_000 })] })
    const at = nextClockChange(old, null, NOW)
    if (at === null) throw new Error('a day-counting label has to tick')
    expect(at).toBeGreaterThan(NOW)
    expect(at - NOW).toBeLessThanOrEqual(86_400_000)
  })

  it('asks for no timer once the label has become a fixed date', () => {
    // Past a month `whenSeen` prints a date, and a date does not move.
    const ancient = state({ devices: [device({ lastSeenAt: NOW - 60 * 86_400_000 })] })
    expect(nextClockChange(ancient, null, NOW)).toBeNull()
  })

  it('lands on the second the pairing countdown changes', () => {
    const pairing = { token: 'tok', expiresAt: NOW + 42_300 }
    const at = nextClockChange(null, pairing, NOW)
    if (at === null) throw new Error('a live code has to tick')

    const before = Math.max(0, Math.ceil((pairing.expiresAt - (at - 1)) / SECOND))
    const after = Math.max(0, Math.ceil((pairing.expiresAt - at) / SECOND))
    expect(before).toBe(43)
    expect(after).toBe(42)
  })

  it('stops ticking once the code has expired', () => {
    expect(nextClockChange(null, { token: 'tok', expiresAt: NOW - 1 }, NOW)).toBeNull()
  })

  it('a code with no expiry never asks for a tick', () => {
    expect(nextClockChange(null, { token: 'tok', expiresAt: null }, NOW)).toBeNull()
  })

  it('lands on the minute "last seen" changes', () => {
    const seen = NOW - 4 * MINUTE - 12_000
    const at = nextClockChange(state({ devices: [device({ lastSeenAt: seen })] }), null, NOW)
    if (at === null) throw new Error('a recent device has to tick')

    expect(whenSeen(seen, at - 1)).toBe(whenSeen(seen, NOW))
    expect(whenSeen(seen, at)).not.toBe(whenSeen(seen, NOW))
  })

  it('lands on the minute an attachment’s age changes', () => {
    const since = NOW - 7 * MINUTE - 3000
    const at = nextClockChange(state({ connections: [connection({ connectedAt: since })] }), null, NOW)
    if (at === null) throw new Error('a live attachment has to tick')

    expect(attachedFor(since, at - 1)).toBe(attachedFor(since, NOW))
    expect(attachedFor(since, at)).not.toBe(attachedFor(since, NOW))
  })

  it('lands on the minute a tunnel’s age changes, which is not the attachment’s', () => {
    // A page is opened whenever the phone taps a port, almost never at the
    // moment it attached. Ticking only for the connection would freeze "open
    // for 3 minutes" on a page that had been up for twenty.
    const attachedAt = NOW - 30_000
    const openedAt = NOW - 6 * MINUTE - 45_000
    const at = nextClockChange(
      state({
        connections: [
          connection({
            connectedAt: attachedAt,
            tunnels: [{ id: 'tun-1', port: 5173, streams: 1, openedAt }],
          }),
        ],
      }),
      null,
      NOW,
    )
    if (at === null) throw new Error('a live tunnel has to tick')

    expect(attachedFor(openedAt, at - 1)).toBe(attachedFor(openedAt, NOW))
    expect(attachedFor(openedAt, at)).not.toBe(attachedFor(openedAt, NOW))
    // And it is the tunnel's boundary that won, not the attachment's.
    expect(attachedFor(attachedAt, at)).toBe(attachedFor(attachedAt, NOW))
  })

  it('asks for no tick for a tunnel whose age it was never given', () => {
    const opaque = state({
      connections: [
        connection({ connectedAt: null, tunnels: [{ id: 'tun-1', port: 5173, streams: 0, openedAt: null }] }),
      ],
    })
    expect(nextClockChange(opaque, null, NOW)).toBeNull()
  })

  it('lands on the second the relay retry note changes', () => {
    const retryAt = NOW + 18_400
    const at = nextClockChange(state({ relay: relay({ connected: false, retryAt }) }), null, NOW)
    if (at === null) throw new Error('a scheduled retry has to tick')

    expect(retryNote(retryAt, at - 1)).toBe(retryNote(retryAt, NOW))
    expect(retryNote(retryAt, at)).not.toBe(retryNote(retryAt, NOW))
  })

  it('takes the soonest of several moving things', () => {
    const pairing = { token: 'tok', expiresAt: NOW + 30_500 }
    const both = state({ devices: [device({ lastSeenAt: NOW - 20_000 })] })
    const at = nextClockChange(both, pairing, NOW)
    // The code moves in half a second; "last seen" not for another ten.
    expect(at).toBe(NOW + 500)
  })

  it('never schedules a wake-up too close to now, which would spin', () => {
    // A change due in 101 ms is real, but arming for it repeatedly is how a
    // scheduler turns into a busy loop. It is held off to the floor instead.
    const at = nextClockChange(state({ relay: relay({ connected: false, retryAt: NOW + 600 }) }), null, NOW)
    expect(at).toBe(NOW + 250)
  })

  it('stops once the retry note has reached its last words', () => {
    // "Trying again now." is terminal; there is nothing after it to wake for.
    expect(nextClockChange(state({ relay: relay({ connected: false, retryAt: NOW + 1 }) }), null, NOW)).toBeNull()
    expect(nextClockChange(state({ relay: relay({ connected: false, retryAt: NOW - 5000 }) }), null, NOW)).toBeNull()
  })

  it('re-arms from the moment it returns, so the chain does not stall', () => {
    // Walking the chain forward has to reach the end of the countdown rather
    // than sitting on one second forever.
    const pairing = { token: 'tok', expiresAt: NOW + 5000 }
    let clock = NOW
    const seen: number[] = []
    for (let step = 0; step < 20; step++) {
      const at = nextClockChange(null, pairing, clock)
      if (at === null) break
      expect(at).toBeGreaterThan(clock)
      clock = at
      seen.push(Math.max(0, Math.ceil((pairing.expiresAt - clock) / SECOND)))
    }
    expect(seen).toEqual([4, 3, 2, 1, 0])
  })
})

describe('unsettled', () => {
  it('is true while a code is on screen, because a pending device is not pushed', () => {
    expect(unsettled(state(), { token: 'tok', expiresAt: NOW + 60_000 })).toBe(true)
  })

  it('is true while the relay is mid-dial', () => {
    expect(unsettled(state({ relay: relay({ connected: false, retryAt: null }) }), null)).toBe(true)
  })

  it('is false once the relay has a retry scheduled — that moment is known', () => {
    expect(unsettled(state({ relay: relay({ connected: false, retryAt: NOW + 5000 }) }), null)).toBe(false)
  })

  it('is false with the relay connected', () => {
    expect(unsettled(state({ relay: relay() }), null)).toBe(false)
  })

  it('is false with the server stopped', () => {
    expect(unsettled(state({ running: false, relay: null }), null)).toBe(false)
  })

  it('is false with no relay in the build at all', () => {
    expect(unsettled(state({ relay: null }), null)).toBe(false)
  })

  it('is false before the first read lands', () => {
    expect(unsettled(null, null)).toBe(false)
  })
})

/**
 * The life left on a pairing code.
 *
 * The code is on screen for sixty seconds and for a while nothing said so: it
 * simply stopped working mid-typing, and the first anybody heard of a time
 * limit was the error afterwards. This is the function under that countdown,
 * and it is one function rather than the two the two screens used to have —
 * a merged section with two clocks rounding differently is a section where the
 * same code has two ages on it.
 */
describe('codeSecondsLeft', () => {
  it('counts whole seconds down, and never below zero', () => {
    expect(codeSecondsLeft(NOW + 60_000, NOW)).toBe(60)
    // Rounded up: with 59.4 seconds left the honest thing to print is 60,
    // because 59 would be the first number a reader sees and it would be a
    // second short of the truth.
    expect(codeSecondsLeft(NOW + 59_400, NOW)).toBe(60)
    expect(codeSecondsLeft(NOW + 1, NOW)).toBe(1)
    expect(codeSecondsLeft(NOW, NOW)).toBe(0)
    // A code that died while the window was asleep counts zero, not backwards.
    expect(codeSecondsLeft(NOW - 30_000, NOW)).toBe(0)
  })

  it('agrees with the tick that redraws it', () => {
    // The countdown's wake-up comes from `nextClockChange`, so the two have to
    // land on the same second: a tick computed a millisecond early redraws the
    // number that is already on screen and then never fires again.
    const pairing = { token: '482913', expiresAt: NOW + 45_000 }
    const at = nextClockChange(state(), pairing, NOW)
    expect(at).not.toBeNull()
    expect(codeSecondsLeft(pairing.expiresAt, (at ?? 0) - 1)).toBe(45)
    expect(codeSecondsLeft(pairing.expiresAt, at ?? 0)).toBe(44)
  })
})
