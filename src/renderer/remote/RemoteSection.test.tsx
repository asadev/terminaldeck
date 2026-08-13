import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  attachedFor,
  connectionNote,
  deviceStateAfter,
  missingRemoteMethods,
  remoteActions,
  RemoteSection,
  RemoteView,
  resolveRemoteBridge,
  toRemoteConnections,
  retryNote,
  toRemoteDevices,
  toRemotePairing,
  toRemoteRelay,
  toRemoteState,
  toRemoteTunnels,
  tunnelNote,
  whenSeen,
  type RemoteActions,
  type RemoteBridge,
  type RemoteConnection,
  type RemoteDevice,
  type RemotePairing,
  type RemoteRelay,
  type RemoteState,
  type RemoteTunnel,
  type RemoteViewProps,
} from './RemoteSection'
import type { PairPath } from './pairing-link'

/**
 * What this panel says in each of the states it can be in.
 *
 * The states are the point. This is the screen that decides whether a stranger
 * gets a shell on the machine, and every one of its failure modes has to be a
 * sentence rather than a spinner: not wired into the build, not serving and
 * here is why, nothing paired, something waiting to be let in, something
 * attached right now. A regression in any of those looks like a working panel
 * and is not one, so each is pinned to the words it puts on screen.
 *
 * `renderToStaticMarkup` never runs an effect, which is why `RemoteView` takes
 * its state as props — a component that fetched its own status would only ever
 * be testable in the empty state.
 */

const NOW = Date.UTC(2026, 7, 13, 12, 0, 0)

const NOTHING: RemoteActions = {
  enable: () => {},
  confirmEnable: () => {},
  dismissEnable: () => {},
  pair: () => {},
  closePairing: () => {},
  choosePath: () => {},
  approve: () => {},
  deny: () => {},
  revoke: () => {},
  disconnect: () => {},
  stopTunnel: () => {},
}

/** A relay that is up, with the identity a pairing link is built from. */
const RELAY: RemoteRelay = {
  url: 'wss://relay.terminaldeck.dev',
  hostId: 'AXGK7VAEYZHKTTVUKZ4U9HZQ7J',
  publicKey: 'Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhmb29iYXI',
  fingerprint: 'K7QM-3XTB-9WHD-2PVJ-6RNY-4CFG',
  connected: true,
  channels: 0,
  reason: null,
  retryAt: null,
}

/** Both ways in, which is the state a healthy Mac on a tailnet is in. */
const RUNNING: RemoteState = {
  running: true,
  url: 'https://asads-macbook-pro-1.taile59277.ts.net:8443',
  address: '100.86.107.119',
  reason: null,
  directReason: null,
  relay: RELAY,
  devices: [],
  connections: [],
}

/** The Mac the relay was built for: no tailnet, and remote access still up. */
const RELAY_ONLY: RemoteState = {
  ...RUNNING,
  url: null,
  address: null,
  directReason:
    'Tailscale is installed but this Mac is logged out of the tailnet. Open the Tailscale menu bar icon and sign in, then turn this on again.',
}

const PHONE = {
  id: 'dev-1',
  name: 'Asad’s iPhone',
  state: 'pending' as const,
  addedAt: NOW - 3 * 3_600_000,
  lastSeenAt: NOW - 10_000,
  fingerprint: 'H4TC-8MKD-2QWX-7BNP-5ZRJ-9VFY',
}

const ATTACHED: RemoteConnection = {
  id: 'conn-1',
  deviceId: 'dev-1',
  deviceName: 'Asad’s iPhone',
  platform: 'iOS 26',
  address: '100.86.107.42',
  connectedAt: NOW - 12 * 60_000,
  sessionIds: ['s1', 's2'],
  tunnels: [],
}

/** A dev server on this Mac, being read by a browser on the phone. */
const TUNNEL: RemoteTunnel = {
  id: 'tun-1',
  port: 5173,
  streams: 3,
  openedAt: NOW - 4 * 60_000,
}

/** The same page with nothing moving through it, which is its resting state. */
const IDLE_TUNNEL: RemoteTunnel = { id: 'tun-2', port: 8080, streams: 0, openedAt: NOW - 40_000 }

const TUNNELLED: RemoteConnection = { ...ATTACHED, tunnels: [TUNNEL, IDLE_TUNNEL] }

function render(props: Partial<RemoteViewProps> = {}): string {
  return renderToStaticMarkup(
    <RemoteView
      state={null}
      wired
      problem={null}
      notice={null}
      pairing={null}
      secondsLeft={null}
      busy={null}
      confirmEnable={false}
      pairPath={null}
      actions={NOTHING}
      now={NOW}
      {...props}
    />,
  )
}

describe('when the build has no remote channels', () => {
  it('says so instead of rendering controls that do nothing', () => {
    const html = renderToStaticMarkup(<RemoteSection bridge={{}} />)
    expect(html).toContain('not wired into this build')
    expect(html).not.toContain('Pair a device')
  })

  it('reaches that state through the real bridge resolution, not a special case', () => {
    // No `deck` on the global in this process, so this is the packaged app's
    // "the preload did not expose it" path, exercised end to end.
    expect(resolveRemoteBridge()).toEqual({})
    expect(renderToStaticMarkup(<RemoteSection />)).toContain('not wired into this build')
  })
})

describe('off', () => {
  const html = render({ state: { ...RUNNING, running: false, url: null, reason: null } })

  it('says what is behind the switch before it is pressed', () => {
    expect(html).toMatch(/<strong>shell<\/strong>/)
    expect(html).toContain('Off by default')
  })

  it('leaves the switch off', () => {
    expect(html).toContain('role="switch"')
    expect(html).not.toContain('checked=""')
  })

  it('offers nothing to pair with, and claims nothing is attached', () => {
    expect(html).not.toContain('Pair a device')
    expect(html).not.toContain('Attached now')
  })

  it('does not invent a failure out of being switched off', () => {
    expect(html).not.toContain('Not serving')
  })
})

describe('asked for, but not serving', () => {
  const reason =
    'Tailscale is installed but this Mac is logged out of the tailnet. Open the Tailscale menu bar icon and sign in, then turn this on again.'
  const html = render({ state: { ...RUNNING, running: false, url: null, reason } })

  it('prints the main process’s sentence verbatim', () => {
    // Verbatim because the main process is the only thing that knows what the
    // tailnet is doing, and its sentences are written to say what to do.
    expect(html).toContain(reason)
    expect(html).toContain('Not serving')
  })

  it('explains why the switch is off rather than leaving it looking broken', () => {
    expect(html).toContain('shows whether it is actually serving')
  })

  it('offers no pairing code that would point at nothing', () => {
    expect(html).not.toContain('Pair a device')
  })

  it('never leaves a spinner over it', () => {
    expect(html).not.toContain('Reading the current state')
  })
})

describe('serving, with nothing paired', () => {
  const html = render({ state: RUNNING })

  it('shows the address the phone should open, and the tailnet address behind it', () => {
    expect(html).toContain('https://asads-macbook-pro-1.taile59277.ts.net:8443')
    expect(html).toContain('100.86.107.119')
    expect(html).toContain('same tailnet')
  })

  it('draws both ways in, each with its own state', () => {
    expect(html).toContain('Direct on your tailnet')
    expect(html).toContain('Through the relay')
    expect(html).toContain('>Ready<')
    expect(html).toContain('>Connected<')
  })

  it('names this Mac at the relay, and the key a phone will check it by', () => {
    expect(html).toContain(RELAY.hostId)
    expect(html).toContain(RELAY.fingerprint)
  })

  it('says the lists are empty rather than showing empty lists', () => {
    expect(html).toContain('No device has been paired')
    expect(html).toContain('Nothing is attached')
  })

  it('offers pairing, and says a code alone lets nothing in', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Pair a device<\/button>/)
    expect(html).toContain('it does not let anything in')
  })
})

/**
 * The state this whole feature exists for.
 *
 * A Mac with no tailnet has no URL, and the panel used to disable Pair on
 * exactly that — so the users the relay was built for were the one group who
 * could never reach it. Every assertion here is that regression.
 */
describe('reachable only through the relay', () => {
  const html = render({ state: RELAY_ONLY })

  it('still offers to pair, with no URL anywhere in sight', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Pair a device<\/button>/)
  })

  it('says why the faster path is missing without calling remote access broken', () => {
    expect(html).toContain('logged out of the tailnet')
    expect(html).toContain('Remote access is still up')
    // That sentence belongs to the direct row. Printed as *the* reason it would
    // tell somebody their working feature had failed.
    expect(html).not.toContain('Not serving')
  })

  it('marks the tailnet unavailable and the relay connected, in that order', () => {
    expect(html).toContain('>Unavailable<')
    expect(html).toContain('>Connected<')
    expect(html.indexOf('Direct on your tailnet')).toBeLessThan(html.indexOf('Through the relay'))
  })
})

describe('the relay is not connected', () => {
  const reason = 'The relay refused this Mac’s host secret. Turn remote access off and on again.'
  const state: RemoteState = {
    ...RELAY_ONLY,
    relay: { ...RELAY, connected: false, reason, retryAt: NOW + 8000 },
  }
  const html = render({ state })

  it('looks different from connected, and says which it is', () => {
    expect(html).toContain('>Not connected<')
    expect(html).not.toContain('>Connected<')
    expect(html).toContain('data-state="down"')
  })

  it('prints the relay’s own sentence, and when it will try again', () => {
    expect(html).toContain(reason)
    expect(html).toContain('Trying again in 8s')
  })

  it('refuses to hand out a code for a path that is down, and says why', () => {
    // A code minted here produces a phone that scans, waits, and fails.
    expect(html).toMatch(/<button[^>]*disabled[^>]*>Pair a device<\/button>/)
    expect(html).toContain('Neither way in is up')
  })

  it('never claims the identity of a link that could not be used', () => {
    expect(html).not.toContain(RELAY.hostId)
  })
})

describe('the relay is switched off in this build', () => {
  const html = render({ state: { ...RUNNING, relay: null } })

  it('says so rather than drawing a relay that is not there', () => {
    expect(html).toContain('>Off<')
    expect(html).toContain('not dialling a relay')
  })

  it('still pairs, because the tailnet is a whole path on its own', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Pair a device<\/button>/)
  })
})

describe('a device waiting to be let in', () => {
  const html = render({ state: { ...RUNNING, devices: [PHONE] } })

  it('offers both answers, not just the friendly one', () => {
    expect(html).toContain('>Approve</button>')
    expect(html).toContain('>Deny</button>')
  })

  it('names it and dates it', () => {
    expect(html).toContain('Asad’s iPhone')
    expect(html).toContain('Waiting for you')
    expect(html).toContain('Last seen just now')
    expect(html).toContain('paired 3 hours ago')
  })

  it('warns against approving the wrong one', () => {
    expect(html).toContain('Approve only the one you are holding')
  })
})

describe('something attached right now', () => {
  const html = render({
    state: {
      ...RUNNING,
      devices: [{ ...PHONE, state: 'approved' }],
      connections: [ATTACHED],
    },
  })

  it('counts it in the heading and marks it live', () => {
    expect(html).toContain('Attached now — 1')
    expect(html).toContain('remote-live-dot')
    expect(html).toContain('role="status"')
  })

  it('says how long, from where, and how much of the machine it has', () => {
    expect(html).toContain('attached for 12 minutes')
    expect(html).toContain('100.86.107.42')
    expect(html).toContain('2 sessions open')
  })

  it('offers one press to end it', () => {
    expect(html).toContain('>Disconnect</button>')
  })

  it('separates revoking from disconnecting, and says revoking is immediate', () => {
    expect(html).toContain('>Revoke</button>')
    expect(html).toMatch(/<strong>Revoking is immediate\.<\/strong>/)
    expect(html).toContain('not at its next connection')
    expect(html).toContain('can attach again straight away')
  })

  it('adds nothing at all for a phone that has not tapped a port', () => {
    // The ordinary case by a wide margin. A "no pages open" line under every
    // attached row would be noise about the state almost every row is in.
    expect(html).not.toContain('remote-tunnels')
    expect(html).not.toContain('>Stop</button>')
    expect(html).not.toContain('localhost:')
  })
})

/**
 * A phone reading a dev server on this Mac.
 *
 * This is the second thing on the panel that is a live claim about the machine
 * rather than a setting: while one of these is up, a browser somewhere else is
 * being served by a process running here. The rule it exists for is that it
 * must be *visible* on the Mac and *endable* from the Mac, so both halves are
 * pinned — the port on screen, and one press that closes it.
 */
describe('a phone with a page open on one of this Mac’s ports', () => {
  const html = render({
    state: {
      ...RUNNING,
      devices: [{ ...PHONE, state: 'approved' }],
      connections: [TUNNELLED],
    },
  })

  it('names the port, which is the whole sentence the row says', () => {
    expect(html).toContain('localhost:5173')
    expect(html).toContain('localhost:8080')
  })

  it('says in plain words what that is', () => {
    // "Tunnel" is the main process's word for the mechanism. What a person at
    // this Mac needs to know is that somebody else is looking at one of their
    // ports, and that sentence contains no jargon at all.
    expect(html).toContain('open in a browser on this phone')
    expect(html).toContain('served from this Mac to that phone’s browser')
  })

  it('says how long it has been open, reusing the attachment’s own clock', () => {
    expect(html).toContain('open for 4 minutes')
  })

  it('counts sockets only where the count says something', () => {
    // Zero is what every page that has finished loading sits at, so printing
    // it would read as a fault on a page that is working.
    expect(html).toContain('carrying 3 sockets')
    expect(html).not.toContain('carrying 0 sockets')
  })

  it('offers one press per page, and does not ask twice', () => {
    // Stopping one closes a web page. Nothing is lost and the phone can tap
    // the port again, so the confirmation step the switch and the QR get would
    // be friction bought with nothing.
    expect(html.match(/>Stop<\/button>/g)).toHaveLength(2)
    expect(html).not.toContain('settings-confirm')
  })

  it('says what Stop does, so nobody leaves a page open rather than risk it', () => {
    expect(html).toMatch(/<strong>Stop closes the page, and nothing else\.<\/strong>/)
    expect(html).toContain('The session keeps running')
  })

  it('leaves the attached row itself exactly as it was', () => {
    // The tunnels are a line inside that row, not a replacement for it: the
    // sessions count is still the thing that says how much of the machine this
    // phone has.
    expect(html).toContain('2 sessions open')
    expect(html).toContain('>Disconnect</button>')
  })
})

describe('a live pairing code', () => {
  const pairing = { token: '8fb1c2d4e5a6b7c8d9e0f1a2', expiresAt: NOW + 45_000 }
  const html = render({ state: RUNNING, pairing, secondsLeft: 45 })
  const relayLink = `terminaldeck://pair?v=1&r=wss%3A%2F%2Frelay.terminaldeck.dev&h=${RELAY.hostId}&k=${RELAY.publicKey}&t=${pairing.token}`
  const directLink = 'https://asads-macbook-pro-1.taile59277.ts.net:8443/#t=8fb1c2d4e5a6b7c8d9e0f1a2'

  it('draws the code as an SVG with a real path in it', () => {
    expect(html).toContain('<svg class="remote-qr"')
    expect(html).toMatch(/<path class="remote-qr-ink" d="M\d+ \d+h/)
  })

  it('counts down', () => {
    expect(html).toContain('Expires in 45s')
  })

  it('hands over the relay path first, because that is the endpoint the phone keeps', () => {
    // Pairing on the tailnet produces a phone that only works on the tailnet,
    // which is a surprise waiting at an airport.
    expect(html).toContain(relayLink.replaceAll('&', '&amp;'))
    expect(html).toContain('Can’t scan it?')
  })

  it('offers the other path as a button rather than a second code', () => {
    expect(html).toContain('Direct on your tailnet')
    expect(html).toMatch(/aria-pressed="true"[^>]*>Through the relay</)
  })

  it('honours that choice, and prints the tailnet link instead', () => {
    const chosen = render({ state: RUNNING, pairing, secondsLeft: 45, pairPath: 'direct' })
    expect(chosen).toContain(directLink)
    expect(chosen).not.toContain(relayLink.replaceAll('&', '&amp;'))
    expect(chosen).toMatch(/aria-pressed="true"[^>]*>Direct on your tailnet</)
  })

  it('names the parameter in the tailnet link, because the PWA reads it as one', () => {
    // A bare `#<token>` reads as no token at all in `pwa/src/pair.ts`, and the
    // phone lands on the pair screen as if the QR had not been scanned.
    const chosen = render({ state: RUNNING, pairing, secondsLeft: 45, pairPath: 'direct' })
    expect(chosen).toContain('/#t=')
  })

  it('shows this Mac’s fingerprint, so the phone’s copy can be compared with it', () => {
    expect(html).toContain(RELAY.fingerprint)
    expect(html).toContain('same six groups')
  })

  it('drops the fingerprint on the tailnet path, where no key is exchanged', () => {
    const chosen = render({ state: RUNNING, pairing, secondsLeft: 45, pairPath: 'direct' })
    expect(chosen).not.toContain('same six groups')
  })

  it('offers no choice when there is only one way in', () => {
    const only = render({ state: RELAY_ONLY, pairing, secondsLeft: 45 })
    expect(only).toContain(relayLink.replaceAll('&', '&amp;'))
    expect(only).not.toContain('aria-pressed')
  })

  it('has one press to kill the code early', () => {
    expect(html).toContain('Cancel this code')
  })

  it('says plainly when it has run out, rather than leaving a dead code on screen', () => {
    const expired = render({ state: RUNNING, pairing, secondsLeft: 0 })
    expect(expired).toContain('That code has expired')
    expect(expired).toContain('Nothing was let in')
    expect(expired).toContain('New code')
    expect(expired).not.toContain('<svg class="remote-qr"')
    // And the link goes with it — a dead one left on screen to type is worse
    // than none at all.
    expect(expired).not.toContain(relayLink.replaceAll('&', '&amp;'))
    expect(expired).not.toContain(directLink)
  })

  it('says the right thing when every path goes away underneath it', () => {
    // Reachable: the relay drops while the code is on screen. "Expired" would
    // be the wrong reason and would send somebody to make another one.
    const stranded = render({
      state: { ...RELAY_ONLY, relay: { ...RELAY, connected: false, reason: 'The link dropped.' } },
      pairing,
      secondsLeft: 45,
    })
    expect(stranded).toContain('nowhere to point this code')
    expect(stranded).not.toContain('<svg class="remote-qr"')
    expect(stranded).not.toContain('That code has expired')
  })

  it('does not count down when the main process never said when it expires', () => {
    const html2 = render({
      state: RUNNING,
      pairing: { ...pairing, expiresAt: null },
      secondsLeft: null,
    })
    expect(html2).toContain('did not say when this expires')
    expect(html2).not.toMatch(/Expires in/)
  })
})

describe('when the read itself fails', () => {
  it('shows the error and admits what is on screen may be stale', () => {
    const html = render({ state: RUNNING, problem: 'tailscale status exited with code 1.' })
    expect(html).toContain('tailscale status exited with code 1.')
    expect(html).toContain('may be out of date')
  })

  it('claims nothing about devices before the first answer arrives', () => {
    const html = render({ state: null })
    expect(html).toContain('Reading the current state')
    expect(html).not.toContain('No device has been paired')
  })
})

describe('turning it on', () => {
  it('asks a second time, and says what is being handed over', () => {
    const html = render({ state: { ...RUNNING, running: false }, confirmEnable: true })
    expect(html).toContain('Turn on remote access?')
    expect(html).toContain('shell on this Mac')
    expect(html).toContain('Leave it off')
  })
})

/* ------------------------------------------------------------- narrowing -- */

describe('narrowing what the main process sends', () => {
  it('is null for an answer that is not an object at all', () => {
    expect(toRemoteState(null, [])).toBeNull()
    expect(toRemoteState('yes', [])).toBeNull()
  })

  it('defaults to not running, so a broken answer never opens anything', () => {
    const state = toRemoteState({}, null)
    expect(state?.running).toBe(false)
    expect(state?.url).toBeNull()
    expect(state?.devices).toEqual([])
  })

  it('treats an unreadable device state as pending, never as approved', () => {
    const devices = toRemoteDevices([
      { id: 'a', name: 'A', status: 'approved' },
      { id: 'b', name: 'B', status: 'nonsense' },
      { id: 'c', name: 'C' },
      { name: 'no id at all' },
    ])
    expect(devices.map((device) => device.state)).toEqual(['approved', 'pending', 'pending'])
  })

  it('falls back to the flags when the derived status is missing, revocation first', () => {
    const devices = toRemoteDevices([
      { id: 'a', approved: true },
      { id: 'b', approved: true, revoked: true },
    ])
    expect(devices.map((device) => device.state)).toEqual(['approved', 'revoked'])
  })

  it('names a connection from its device when the connection did not carry one', () => {
    const devices = toRemoteDevices([{ id: 'dev-1', name: 'Asad’s iPhone', status: 'approved' }])
    expect(toRemoteConnections([{ id: 'conn-1', deviceId: 'dev-1' }], devices)[0].deviceName).toBe(
      'Asad’s iPhone',
    )
  })

  it('falls back to something printable when it cannot name the device at all', () => {
    expect(toRemoteConnections([{ id: 'conn-1' }], [])[0].deviceName).toBe('Unnamed device')
  })

  it('gives every connection a tunnel list, so no row has to guard against one', () => {
    expect(toRemoteConnections([{ id: 'conn-1' }], [])[0].tunnels).toEqual([])
    expect(toRemoteConnections([{ id: 'conn-1', tunnels: 'yes' }], [])[0].tunnels).toEqual([])
  })

  it('drops a tunnel it could not name or could not point at', () => {
    // The port is the whole sentence the row says and the id is the only thing
    // Stop can name, so a row missing either would be a claim this panel has
    // no way to act on.
    const tunnels = toRemoteTunnels([
      { id: 'a', port: 5173, streams: 2, openedAt: NOW },
      { id: 'b', streams: 1, openedAt: NOW },
      { port: 3000, streams: 1, openedAt: NOW },
      { id: 'd', port: 'eighty', openedAt: NOW },
    ])
    expect(tunnels.map((tunnel) => tunnel.id)).toEqual(['a'])
  })

  it('defaults an unreadable socket count to none rather than inventing traffic', () => {
    const [tunnel] = toRemoteTunnels([{ id: 'a', port: 5173 }])
    expect(tunnel.streams).toBe(0)
    expect(tunnel.openedAt).toBeNull()
  })

  it('drops a pairing with no token, because the token is the whole code', () => {
    expect(toRemotePairing({ expiresAt: 1 })).toBeNull()
    expect(toRemotePairing(null)).toBeNull()
    expect(toRemotePairing({ token: 'abc' })).toEqual({ token: 'abc', expiresAt: null })
    expect(toRemotePairing({ token: 'abc', expiresAt: 'soon' })?.expiresAt).toBeNull()
  })
})

describe('narrowing the relay half of the status', () => {
  it('is null when there is no link at all, which is the ordinary stopped state', () => {
    expect(toRemoteRelay(null)).toBeNull()
    expect(toRemoteState({ running: true }, [])?.relay).toBeNull()
  })

  it('defaults to not connected, so an unreadable answer never draws a live link', () => {
    const relay = toRemoteRelay({ url: 'wss://r', hostId: 'X', reason: 'dialling' })
    expect(relay?.connected).toBe(false)
    expect(relay?.channels).toBe(0)
    expect(relay?.reason).toBe('dialling')
    expect(relay?.retryAt).toBeNull()
  })

  it('keeps the two "why" fields apart, because they are two different facts', () => {
    const state = toRemoteState(
      { running: true, reason: null, directReason: 'Tailscale is logged out.' },
      [],
    )
    expect(state?.reason).toBeNull()
    expect(state?.directReason).toBe('Tailscale is logged out.')
  })

  it('reads a device that has no key as having none, rather than inventing one', () => {
    const devices = toRemoteDevices([
      { id: 'a', name: 'A', status: 'approved', fingerprint: 'ABCD-EFGH' },
      { id: 'b', name: 'B', status: 'approved' },
      { id: 'c', name: 'C', status: 'approved', fingerprint: '' },
    ])
    expect(devices.map((device) => device.fingerprint)).toEqual(['ABCD-EFGH', null, null])
  })
})

describe('retryNote', () => {
  it('says a reconnect is coming, which is the difference between waiting and fixing', () => {
    expect(retryNote(NOW + 8_000, NOW)).toBe('Trying again in 8s.')
    expect(retryNote(NOW + 90_000, NOW)).toBe('Trying again in 2 minutes.')
    expect(retryNote(NOW + 60_000, NOW)).toBe('Trying again in 1 minute.')
  })

  it('never counts backwards past zero', () => {
    expect(retryNote(NOW - 5_000, NOW)).toBe('Trying again now.')
  })

  it('says nothing when nothing is scheduled', () => {
    expect(retryNote(null, NOW)).toBeNull()
  })
})

describe('the bridge', () => {
  it('calls through the host object rather than detaching its methods', () => {
    // A preload whose functions live on a prototype throws on `this` the first
    // time a button is pressed, and only in a packaged build.
    const host = {
      secret: 'kept',
      remoteStatus(): Promise<unknown> {
        return Promise.resolve({ running: (this as { secret: string }).secret === 'kept' })
      },
    }
    const bridge = resolveRemoteBridge(host)
    expect(typeof bridge.remoteStatus).toBe('function')
    return bridge.remoteStatus?.().then((answer) => {
      expect(toRemoteState(answer, [])?.running).toBe(true)
    })
  })

  it('picks up only the methods that exist', () => {
    const bridge = resolveRemoteBridge({ remoteStatus: () => Promise.resolve({}) })
    expect(Object.keys(bridge)).toEqual(['remoteStatus'])
  })
})

/* --------------------------------------------------------- words for times -- */

describe('whenSeen', () => {
  it('says never rather than showing an epoch', () => {
    expect(whenSeen(null, NOW)).toBe('never')
  })

  it('reads in whichever unit is legible', () => {
    expect(whenSeen(NOW - 10_000, NOW)).toBe('just now')
    expect(whenSeen(NOW - 60_000, NOW)).toBe('1 minute ago')
    expect(whenSeen(NOW - 5 * 60_000, NOW)).toBe('5 minutes ago')
    expect(whenSeen(NOW - 3 * 3_600_000, NOW)).toBe('3 hours ago')
    expect(whenSeen(NOW - 5 * 86_400_000, NOW)).toMatch(/\d/)
  })
})

describe('attachedFor', () => {
  it('does not round a fresh connection up to a minute', () => {
    expect(attachedFor(NOW - 20_000, NOW)).toBe('less than a minute')
  })

  it('gets the singular right', () => {
    expect(attachedFor(NOW - 60_000, NOW)).toBe('1 minute')
    expect(attachedFor(NOW - 90 * 60_000, NOW)).toBe('2 hours')
  })
})

describe('connectionNote', () => {
  it('always ends with how many sessions it is inside', () => {
    expect(connectionNote(ATTACHED, NOW)).toBe(
      'attached for 12 minutes · iOS 26 · 100.86.107.42 · 2 sessions open',
    )
  })

  it('says none rather than zero, and skips what it was not told', () => {
    expect(
      connectionNote(
        { ...ATTACHED, platform: '', address: '', connectedAt: null, sessionIds: [] },
        NOW,
      ),
    ).toBe('attached · no session open')
  })
})

describe('tunnelNote', () => {
  it('says how long the page has been open, in the same words the row above uses', () => {
    expect(tunnelNote(TUNNEL, NOW)).toBe('open for 4 minutes · carrying 3 sockets')
  })

  it('stays silent at zero, which is what a finished page sits at', () => {
    expect(tunnelNote(IDLE_TUNNEL, NOW)).toBe('open for less than a minute')
  })

  it('gets the singular right', () => {
    expect(tunnelNote({ ...TUNNEL, streams: 1 }, NOW)).toBe('open for 4 minutes · carrying 1 socket')
  })

  it('prints no age it was never given, rather than 56 years', () => {
    expect(tunnelNote({ ...TUNNEL, openedAt: null, streams: 0 }, NOW)).toBe('open')
  })
})

/* ----------------------------------------------------------- the actions -- */

/**
 * Every button, exercised directly.
 *
 * Everything above this line renders markup, and markup cannot tell you what a
 * press *does*. That gap is not academic here: with only the rendering tests,
 * deleting the two-press confirmation, or wiring Deny to `approveRemoteDevice`
 * so that refusing a stranger let it in, left the whole suite green. What is
 * behind these functions is a shell on this machine, so they are pinned to the
 * channel each one calls and to the sentence it is allowed to print.
 */

interface Harness {
  actions: RemoteActions
  /** Channel calls in order, as `name(argument)`. */
  calls: string[]
  notices: Array<{ ok: boolean; text: string }>
  pairing: RemotePairing | null
  confirming: boolean
  path: PairPath | null
  settled(): Promise<void>
}

function fakeBridge(
  answers: Partial<Record<keyof RemoteBridge, unknown>> = {},
  only?: ReadonlyArray<keyof RemoteBridge>,
): { bridge: Partial<RemoteBridge>; calls: string[] } {
  const calls: string[] = []
  const names: ReadonlyArray<keyof RemoteBridge> = only ?? [
    'remoteStatus',
    'listRemoteDevices',
    'startRemote',
    'stopRemote',
    'startRemotePairing',
    'cancelRemotePairing',
    'approveRemoteDevice',
    'revokeRemoteDevice',
    'disconnectRemoteConnection',
    'stopRemoteTunnel',
  ]
  const bridge: Record<string, unknown> = {}
  for (const name of names) {
    // Every argument, not just the first: `remote:tunnel:stop` takes two ids,
    // and a recorder that kept only the connection would pass a Stop wired to
    // the wrong tunnel — which on a phone with two pages open is the whole bug.
    bridge[name] = (...args: unknown[]): Promise<unknown> => {
      calls.push(`${name}(${args.map((arg) => String(arg)).join(', ')})`)
      return Promise.resolve(answers[name] ?? null)
    }
  }
  return { bridge: bridge as Partial<RemoteBridge>, calls }
}

function harness(bridge: Partial<RemoteBridge>, pairing: RemotePairing | null = null): Harness {
  const notices: Harness['notices'] = []
  const pending: Array<Promise<void>> = []
  const state = { pairing, confirming: false, path: null as PairPath | null }
  const actions = remoteActions({
    bridge,
    pairing,
    setPairing: (next) => {
      state.pairing = next
    },
    setConfirmEnable: (next) => {
      state.confirming = next
    },
    setPairPath: (next) => {
      state.path = next
    },
    run: (_key, work, done) => {
      pending.push(
        work().then(
          () => {
            if (done) notices.push({ ok: true, text: done })
          },
          (error: unknown) => {
            notices.push({ ok: false, text: error instanceof Error ? error.message : String(error) })
          },
        ),
      )
    },
    isAlive: () => true,
  })
  return {
    actions,
    calls: [],
    notices,
    get pairing() {
      return state.pairing
    },
    get confirming() {
      return state.confirming
    },
    get path() {
      return state.path
    },
    settled: async () => {
      await Promise.all(pending)
    },
  }
}

const PENDING_DEVICE: RemoteDevice = {
  id: 'dev-1',
  name: 'Asad’s iPhone',
  state: 'pending',
  addedAt: NOW,
  lastSeenAt: null,
  fingerprint: null,
}

describe('the switch', () => {
  it('starts nothing on the first press — turning it on takes two', async () => {
    const { bridge, calls } = fakeBridge()
    const h = harness(bridge)
    h.actions.enable(true)
    await h.settled()
    // The press that matters is the second one. If this ever passes with
    // `startRemote()` in `calls`, the confirmation has been deleted.
    expect(calls).toEqual([])
    expect(h.confirming).toBe(true)
    expect(h.notices).toEqual([])
  })

  it('starts on the second press, and only then', async () => {
    const { bridge, calls } = fakeBridge({ startRemote: { running: true, url: 'https://h.ts.net' } })
    const h = harness(bridge)
    h.actions.enable(true)
    h.actions.confirmEnable()
    await h.settled()
    expect(calls).toEqual(['startRemote()'])
    expect(h.confirming).toBe(false)
    expect(h.notices).toEqual([{ ok: true, text: expect.stringContaining('Remote access is on') }])
  })

  it('turns off in one press, because the safe direction must not be the slow one', async () => {
    const { bridge, calls } = fakeBridge({ stopRemote: { running: false } })
    const h = harness(bridge)
    h.actions.enable(false)
    await h.settled()
    expect(calls).toEqual(['stopRemote()'])
    expect(h.notices).toEqual([{ ok: true, text: 'Remote access is off.' }])
  })

  it('kills a live pairing code on the way off, before the server goes', async () => {
    // Otherwise the token outlives the switch for the rest of its minute, and
    // turning remote access back on inside that window would still let a
    // photographed QR redeem.
    const { bridge, calls } = fakeBridge()
    const h = harness(bridge, { token: 'abc', expiresAt: NOW + 60_000 })
    h.actions.enable(false)
    await h.settled()
    expect(calls).toEqual(['cancelRemotePairing()', 'stopRemote()'])
    expect(h.pairing).toBeNull()
  })

  it('reports a start that did not take in the main process’s own words', async () => {
    const reason = 'Tailscale is installed but this Mac is logged out of the tailnet.'
    const { bridge } = fakeBridge({ startRemote: { running: false, reason } })
    const h = harness(bridge)
    h.actions.confirmEnable()
    await h.settled()
    // `remote:start` resolves rather than throwing, so a start that failed
    // arrives looking like a success. It must not be printed as one.
    expect(h.notices).toEqual([{ ok: false, text: reason }])
  })
})

describe('approving and refusing', () => {
  it('approves through the approve channel', async () => {
    const { bridge, calls } = fakeBridge({
      approveRemoteDevice: [{ id: 'dev-1', name: 'Asad’s iPhone', status: 'approved' }],
    })
    const h = harness(bridge)
    h.actions.approve(PENDING_DEVICE)
    await h.settled()
    expect(calls).toEqual(['approveRemoteDevice(dev-1)'])
    expect(h.notices).toEqual([{ ok: true, text: 'Asad’s iPhone can connect.' }])
  })

  it('denies through the revoke channel, and never through the approve one', async () => {
    // The bug this exists for: Deny wired to `approveRemoteDevice` would let in
    // the exact device the user just refused, and would look identical on
    // screen until the phone started typing.
    const { bridge, calls } = fakeBridge({
      revokeRemoteDevice: [{ id: 'dev-1', name: 'Asad’s iPhone', status: 'revoked' }],
    })
    const h = harness(bridge)
    h.actions.deny(PENDING_DEVICE)
    h.actions.revoke({ ...PENDING_DEVICE, state: 'approved' })
    await h.settled()
    expect(calls).toEqual(['revokeRemoteDevice(dev-1)', 'revokeRemoteDevice(dev-1)'])
    expect(calls.join()).not.toContain('approve')
    expect(h.notices.every((notice) => notice.ok)).toBe(true)
  })

  it('says a refusal is final, because the registry never approves a revoked device', async () => {
    const { bridge } = fakeBridge({
      revokeRemoteDevice: [{ id: 'dev-1', name: 'Asad’s iPhone', status: 'revoked' }],
    })
    const h = harness(bridge)
    h.actions.deny(PENDING_DEVICE)
    await h.settled()
    expect(h.notices[0].text).toContain('cannot be approved later')
  })

  it('believes the list that comes back, not the fact that the call returned', async () => {
    // `approveDevice` answers false for a device that was revoked or has since
    // gone, and the IPC handler returns the list either way. "can connect" over
    // a row that still reads Revoked is the one lie this screen cannot afford.
    const { bridge } = fakeBridge({
      approveRemoteDevice: [{ id: 'dev-1', name: 'Asad’s iPhone', status: 'revoked' }],
    })
    const h = harness(bridge)
    h.actions.approve(PENDING_DEVICE)
    await h.settled()
    expect(h.notices).toEqual([{ ok: false, text: expect.stringContaining('did not take') }])
  })

  it('falls back to what it asked for when the answer is not a device list', async () => {
    const { bridge } = fakeBridge({ approveRemoteDevice: { ok: true } })
    const h = harness(bridge)
    h.actions.approve(PENDING_DEVICE)
    await h.settled()
    expect(h.notices).toEqual([{ ok: true, text: 'Asad’s iPhone can connect.' }])
    expect(deviceStateAfter({ ok: true }, 'dev-1')).toBeUndefined()
  })
})

describe('stopping one page a phone has open', () => {
  /** What `remote:tunnel:stop` answers with: the fresh connection list. */
  const AFTER = [
    {
      id: 'conn-1',
      deviceId: 'dev-1',
      deviceName: 'Asad’s iPhone',
      platform: 'iOS 26',
      address: '100.86.107.42',
      connectedAt: NOW - 12 * 60_000,
      sessionIds: ['s1', 's2'],
      tunnels: [{ id: 'tun-2', port: 8080, streams: 0, openedAt: NOW - 40_000 }],
    },
  ]

  it('names both ids, because a tunnel id only means anything inside its connection', async () => {
    // Two phones can each have a page open on port 3000. A stop that carried
    // only one of the two ids would be a coin flip over which one closed.
    const { bridge, calls } = fakeBridge({ stopRemoteTunnel: AFTER })
    const h = harness(bridge)
    h.actions.stopTunnel(TUNNELLED, TUNNEL)
    await h.settled()
    expect(calls).toEqual(['stopRemoteTunnel(conn-1, tun-1)'])
  })

  it('goes on the first press — there is no confirmation to get through', async () => {
    const { bridge, calls } = fakeBridge({ stopRemoteTunnel: AFTER })
    const h = harness(bridge)
    h.actions.stopTunnel(TUNNELLED, TUNNEL)
    await h.settled()
    // If this ever needs a second call to reach the channel, a confirm step
    // has been added to something that closes a web page.
    expect(calls).toHaveLength(1)
  })

  it('says what closed and that it can come back', async () => {
    const { bridge } = fakeBridge({ stopRemoteTunnel: AFTER })
    const h = harness(bridge)
    h.actions.stopTunnel(TUNNELLED, TUNNEL)
    await h.settled()
    expect(h.notices).toEqual([
      { ok: true, text: 'Closed the page on port 5173. Asad’s iPhone can open it again.' },
    ])
  })

  it('draws the list that came back, not the one that was on screen', () => {
    // The handler answers with the fresh connections for the same reason the
    // device channels do: what this panel claims about the machine comes from
    // an answer, never from the fact that a call returned. The row that was
    // stopped goes; the one beside it stays.
    const redrawn = render({
      state: { ...RUNNING, connections: toRemoteConnections(AFTER, []) },
    })
    expect(redrawn).not.toContain('localhost:5173')
    expect(redrawn).toContain('localhost:8080')
  })

  it('draws nothing extra once the last page is closed', () => {
    const empty = [{ ...AFTER[0], tunnels: [] }]
    const redrawn = render({ state: { ...RUNNING, connections: toRemoteConnections(empty, []) } })
    expect(redrawn).not.toContain('remote-tunnels')
    expect(redrawn).not.toContain('>Stop</button>')
    // The phone is still attached, though — closing its page is not a
    // disconnect, and the row it lives on has to stay.
    expect(redrawn).toContain('>Disconnect</button>')
  })
})

describe('a channel this build does not have', () => {
  const CONNECTION: RemoteConnection = { ...ATTACHED }

  it('fails loudly rather than printing the success sentence for a call never made', async () => {
    // `bridge.stopRemote?.() ?? Promise.resolve()` is the shape this guards:
    // it resolves, so the panel would announce "Remote access is off." over a
    // server that is still serving.
    const h = harness({})
    h.actions.enable(false)
    h.actions.confirmEnable()
    h.actions.pair()
    h.actions.closePairing()
    h.actions.approve(PENDING_DEVICE)
    h.actions.deny(PENDING_DEVICE)
    h.actions.revoke(PENDING_DEVICE)
    h.actions.disconnect(CONNECTION)
    h.actions.stopTunnel(CONNECTION, TUNNEL)
    await h.settled()
    expect(h.notices).toHaveLength(9)
    expect(h.notices.every((notice) => !notice.ok)).toBe(true)
    for (const notice of h.notices) expect(notice.text).toContain('half wired')
  })

  it('names the gaps on screen instead of drawing buttons that cannot work', () => {
    const { bridge } = fakeBridge({}, ['remoteStatus', 'listRemoteDevices'])
    expect(missingRemoteMethods(bridge)).toContain('disconnectRemoteConnection')
    const html = render({
      state: RUNNING,
      missing: ['disconnectRemoteConnection', 'onRemoteConnections'],
    })
    expect(html).toContain('missing 2 of the remote channels')
    expect(html).toContain('disconnectRemoteConnection')
  })

  it('reports nothing missing when every channel is there', () => {
    const { bridge } = fakeBridge()
    expect(missingRemoteMethods({ ...bridge, onRemoteConnections: () => () => {} })).toEqual([])
  })
})

describe('pairing', () => {
  it('shows a minted code and cancels it through its own channel', async () => {
    const { bridge, calls } = fakeBridge({
      startRemotePairing: { token: 'tok-1', expiresAt: NOW + 60_000 },
    })
    const h = harness(bridge)
    h.actions.pair()
    await h.settled()
    expect(calls).toEqual(['startRemotePairing()'])
    expect(h.pairing).toEqual({ token: 'tok-1', expiresAt: NOW + 60_000 })
    h.actions.closePairing()
    await h.settled()
    expect(calls).toEqual(['startRemotePairing()', 'cancelRemotePairing()'])
    expect(h.pairing).toBeNull()
  })

  it('re-points a live code without minting a second one', async () => {
    // Both paths carry the same one-shot token. A second mint here would burn
    // the code that is on screen and being photographed.
    const { bridge, calls } = fakeBridge()
    const h = harness(bridge, { token: 'tok-1', expiresAt: NOW + 60_000 })
    h.actions.choosePath('direct')
    await h.settled()
    expect(calls).toEqual([])
    expect(h.path).toBe('direct')
    expect(h.pairing).toEqual({ token: 'tok-1', expiresAt: NOW + 60_000 })
  })

  it('never leaves a tokenless answer on screen as if it were a code', async () => {
    const { bridge } = fakeBridge({ startRemotePairing: { expiresAt: NOW } })
    const h = harness(bridge)
    h.actions.pair()
    await h.settled()
    expect(h.pairing).toBeNull()
    expect(h.notices).toEqual([{ ok: false, text: expect.stringContaining('did not return') }])
  })
})
