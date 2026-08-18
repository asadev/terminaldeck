import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import {
  attachedFor,
  canMintCode,
  codeSecondsLeft,
  codeShown,
  connectionNote,
  deviceLabel,
  deviceStateAfter,
  missingRemoteMethods,
  READ_DEADLINE_MS,
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
import { withDeadline } from '../deadline'
import type { MachineActions, MachinesHalf } from '../machines/MachineLinks'
import type { Machine, MachineLinkState } from '../machines/types'
import { CODE_LENGTH } from '../../shared/short-code'

/**
 * What this section says in each of the states it can be in.
 *
 * The states are the point. This is the screen that decides whether a stranger
 * gets a shell on the machine, and every one of its failure modes has to be a
 * sentence rather than a spinner: not wired into the build, not serving and
 * here is why, nothing paired, something waiting to be let in, something
 * attached right now. A regression in any of those looks like a working panel
 * and is not one, so each is pinned to the words it puts on screen.
 *
 * It is also the merged section now — the sidebar's Machines page folded into
 * Remote — so a second class of regression matters here: a capability that used
 * to be on the other screen and is quietly not on this one. Those are pinned
 * together, under "the merge", against the list of what the machines page could
 * do.
 *
 * `renderToStaticMarkup` never runs an effect, which is why `RemoteView` takes
 * its state as props — a component that fetched its own status would only ever
 * be testable in the empty state.
 */

const NOW = Date.UTC(2026, 7, 13, 12, 0, 0)

const NOTHING: RemoteActions = {
  enable: () => {},
  reread: () => {},
  pair: () => {},
  closePairing: () => {},
  approve: () => {},
  beginApproval: () => {},
  cancelApproval: () => {},
  approvalStep: () => {},
  approvalKind: () => {},
  approvalAddFolder: () => {},
  approvalRemoveFolder: () => {},
  deny: () => {},
  revoke: () => {},
  disconnect: () => {},
  stopTunnel: () => {},
}

const NO_MACHINE_ACTIONS: MachineActions = {
  type: () => {},
  pair: () => {},
  connect: () => {},
  disconnect: () => {},
  forget: () => {},
  newSession: () => {},
  open: () => {},
  close: () => {},
  openPort: () => {},
  refreshPorts: () => {},
}

/** A paired desktop, and the link to it. Both halves of one row. */
const STUDIO: Machine = {
  id: 'MACHINE1',
  name: 'Studio PC',
  hostId: 'MACHINE1',
  fingerprint: 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ',
  platform: 'win32',
  pairedAt: NOW - 86_400_000,
  lastConnectedAt: NOW - 60_000,
}

const STUDIO_LINK: MachineLinkState = {
  id: 'MACHINE1',
  state: 'online',
  reason: null,
  sessions: [
    {
      id: 's1',
      title: 'agent',
      cwd: '/Users/a/projects/deck',
      provider: 'claude',
      status: 'running',
      exitCode: null,
    },
  ],
  folders: ['/Users/a/projects/deck'],
  capabilities: ['create'],
  ports: [],
  hostPlatform: 'win32',
  retryAt: null,
}

function machinesHalf(over: Partial<MachinesHalf> = {}): MachinesHalf {
  return {
    wired: true,
    view: { machines: [], links: [], blocked: null },
    reading: false,
    entry: { digits: '', busy: false, error: null, blocked: null },
    open: null,
    actions: NO_MACHINE_ACTIONS,
    ...over,
  }
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

/** Both ways in, which is the state a Mac that also runs a mesh VPN is in. */
const RUNNING: RemoteState = {
  running: true,
  url: 'https://asads-macbook-pro-1.taile59277.ts.net:8443',
  address: '100.86.107.119',
  reason: null,
  relay: RELAY,
  devices: [],
  connections: [],
}

/**
 * The ordinary Mac, and the one the relay was built for: no direct route, and
 * remote access entirely up. Nearly every machine running this is in this state.
 */
const RELAY_ONLY: RemoteState = {
  ...RUNNING,
  url: null,
  address: null,
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

/**
 * `platform` is pinned rather than sniffed, and that is not a detail.
 *
 * `detectPlatform()` reads `navigator`, and Node's own `navigator.platform` is
 * `MacIntel` on this machine — so every assertion below about the words "this
 * Mac" was passing because of where the test was *run*, not because of what the
 * component does. The same suite on a Windows runner would have read "this PC"
 * and gone red for the right sentence. Pinning it makes the macOS copy a fact
 * the test states, and lets the Windows copy be checked in the same run rather
 * than on hardware nobody has in CI.
 */
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
      machines={machinesHalf()}
      actions={NOTHING}
      now={NOW}
      platform="mac"
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
    // The word, in the switch's own help line rather than in a paragraph under
    // it. There is no confirmation step behind this switch any more, so the one
    // sentence a person reads before pressing has to carry the one word that
    // decides it.
    expect(html).toContain('gets a shell here')
    // Not "off by default" any more — the app dials out on launch, and a help
    // line describing the opposite of the switch beside it is worse than none.
    expect(html).not.toContain('Off by default')
  })

  it('is one paragraph shorter than the screen it replaced', () => {
    // The six-line "What you are turning on" block is behind the row's ⓘ. The
    // heading it used to carry must not be back on the page — that is the
    // regression, and it is the shape of the whole complaint about this screen.
    expect(html).not.toContain('What you are turning on')
    expect(html).toContain('class="settings-info"')
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

  /**
   * The tailnet is off this screen, on a machine that has one.
   *
   * `RUNNING` is the state of a Mac with a working direct route — a URL, a
   * tailnet IP, the lot — and none of it is drawn. That is the assertion, not a
   * side effect of one: the card came back four times, most recently wearing a
   * green **Ready** badge, and a green badge on the route almost nobody has
   * reads as the recommended one. See the comment on the paths group.
   */
  it('draws no tailnet card, even on a machine that has a tailnet', () => {
    expect(html).not.toContain('Direct on your tailnet')
    expect(html).not.toContain('>Ready<')
    expect(html).not.toContain('https://asads-macbook-pro-1.taile59277.ts.net:8443')
    expect(html).not.toContain('100.86.107.119')
    expect(html).not.toContain('same tailnet')
  })

  it('draws the relay, and the relay is the whole of "how a device gets here"', () => {
    expect(html).toContain('Through the relay')
    expect(html).toContain('>Connected<')
    // One row. Two `remote-path` items here means a second route has been put
    // back on the page.
    expect(html.match(/class="remote-path"/g)).toHaveLength(1)
  })

  it('prints neither the host id nor the fingerprint on the resting card', () => {
    // The fingerprint was on screen twice at once. It belongs where the
    // comparison happens — beside a live code — and nowhere else; the host id
    // is this machine's name at the rendezvous and there is nothing to do with
    // it. Both are still in the state and both are deliberately unread here.
    expect(html).not.toContain(RELAY.hostId)
    expect(html).not.toContain(RELAY.fingerprint)
  })

  it('draws no empty rosters at all', () => {
    /*
     * The wall of text, as a test.
     *
     * With nothing paired this page used to carry a Devices heading over "No
     * device has been paired", an "Attached now" heading over "Nothing is
     * attached", three paragraphs of folder policy ending in "there is nothing
     * to choose for", and a machines block ending in "No other machine yet" —
     * four headings and five paragraphs about things that did not exist. His
     * words: *"until there is nothing activated or something or no device is
     * connected… this only text doesn't make any sense."*
     */
    expect(html).not.toContain('No device has been paired')
    expect(html).not.toContain('Nothing is attached')
    expect(html).not.toContain('Attached now')
    expect(html).not.toContain('Devices')
  })

  it('offers pairing, and says a code alone lets nothing in', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Show a code<\/button>/)
    expect(html).toContain('it lets nothing in on its own')
  })
})

/**
 * The state this whole feature exists for, and the state nearly every machine
 * is in.
 *
 * A Mac with no mesh VPN has no direct URL, and the panel used to disable Pair
 * on exactly that — so the users the relay was built for were the one group who
 * could never reach it. Then it kept the row and drew it grey. Every assertion
 * here is one of those two regressions.
 */
describe('reachable only through the relay', () => {
  const html = render({ state: RELAY_ONLY })

  it('still offers to pair, with no URL anywhere in sight', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Show a code<\/button>/)
  })

  it('does not draw a route this machine does not have', () => {
    /*
     * The rule, stated as a test: a route that does not exist here is not a
     * route that is down, and this panel says nothing about its absence.
     *
     * The row used to be permanent. It sat above the relay wearing an
     * "Unavailable" pill and quoting Tailscale's own complaint — "logged out of
     * the tailnet", or "Tailscale refused the request. Serving may be disabled
     * for this tailnet in the admin console" — beside a phone that was working
     * perfectly through the relay. Asad: *"a lot of users will not even know
     * about Tailscale."* To that reader it is a fault in this product, and it
     * sends them to an admin console to fix a machine that is fine.
     *
     * The softer version that replaced it — the row still there, pill reading
     * "Not in use", a sentence explaining that Tailscale would be faster — is
     * also gone. It still put a product the reader has not installed at the top
     * of the one section that answers "how does my phone get in".
     */
    expect(html).not.toContain('Direct on your tailnet')
    expect(html).not.toContain('Tailscale')
    expect(html).not.toContain('tailnet')
    expect(html).not.toContain('>Not in use<')
    expect(html).not.toContain('>Unavailable<')
    // Nothing has failed, so nothing says so.
    expect(html).not.toContain('Not serving')
  })

  it('shows the relay, connected, as the whole answer', () => {
    expect(html).toContain('Through the relay')
    expect(html).toContain('>Connected<')
    // The host id used to be printed here. It is this machine's name at the
    // rendezvous — nothing a person can act on — and it went with the duplicate
    // fingerprint beside it.
    expect(html).not.toContain(RELAY.hostId)
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

  it('still says nothing about the route this machine does not have', () => {
    /*
     * The last place the complaint survived, and the argument for keeping it was
     * the best one available: with the relay down and no direct address, nothing
     * can get in, so the missing direct route looked like half the diagnosis.
     *
     * It is not half of anything. This host has one problem — the relay is not
     * connected — and the row above states it in the relay's own words, with a
     * retry time. The additional news that a mesh VPN the reader has never
     * installed is also not installed is a second, unrelated errand, and the one
     * they are most likely to go and run because it is the one that sounds like
     * a cause.
     */
    expect(html).not.toContain('Unavailable')
    expect(html).not.toContain('Tailscale')
    expect(html).not.toContain('tailnet')
  })

  it('refuses to hand out a code for a path that is down, and says why', () => {
    // A code minted here produces a phone that scans, waits, and fails.
    expect(html).toMatch(/<button[^>]*disabled[^>]*>Show a code<\/button>/)
    // Not "neither way in": on this machine only one row was ever drawn, and
    // "neither" sent the reader looking for a second one.
    expect(html).toContain('Nothing above is up')
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
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Show a code<\/button>/)
  })
})

describe('a device waiting to be let in', () => {
  const html = render({ state: { ...RUNNING, devices: [PHONE] } })

  it('offers both answers, not just the friendly one', () => {
    // "Let it in…" rather than "Approve": the ellipsis is the promise that a
    // press opens the questions rather than settling them, which is the whole
    // difference between this flow and the one button it replaces.
    expect(html).toContain('>Let it in…</button>')
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
    // The line stays; the paragraph after it is behind an ⓘ, which renders it
    // into the button's `title` — so the words are still on the page, one hover
    // or one click from where they were.
    expect(html).toMatch(/<strong>Stop closes the page, and nothing else\.<\/strong>/)
    expect(html).toContain('leaves the session running')
  })

  it('leaves the attached row itself exactly as it was', () => {
    // The tunnels are a line inside that row, not a replacement for it: the
    // sessions count is still the thing that says how much of the machine this
    // phone has.
    expect(html).toContain('2 sessions open')
    expect(html).toContain('>Disconnect</button>')
  })
})

/**
 * The code, and everything that used to be beside it.
 *
 * There was a QR code here and a copyable `terminaldeck://pair?…` link. Both are
 * gone — a QR can only be read by a phone, which left a second desktop with
 * nothing, and the link carried a live bearer token through whatever chat app
 * moved it. What is on screen now is six digits from `shared/short-code.ts`,
 * which any device can be told out loud.
 *
 * The negative assertions are the ones that matter. A QR figure or a link added
 * back would pass every positive check in this file and fail these.
 */
describe('a live pairing code', () => {
  const pairing = { token: '482913', expiresAt: NOW + 45_000, findable: true }
  const html = render({ state: RUNNING, pairing, secondsLeft: 45 })

  it('shows the code as digits, exactly as the main process minted it', () => {
    expect(html).toContain('>482913<')
    expect(html).toContain('class="remote-code"')
    // `codeShown` is the canonical form and it is idempotent, so what is on
    // screen is what the other machine will accept.
    expect(codeShown('482913')).toBe('482913')
    expect(codeShown('482 913')).toBe('482913')
    expect(html.match(/class="remote-code"[^>]*>(\d+)</)?.[1]).toHaveLength(CODE_LENGTH)
  })

  it('draws no QR code and no link, anywhere', () => {
    expect(html).not.toContain('<svg')
    expect(html).not.toContain('remote-qr')
    expect(html).not.toContain('terminaldeck://')
    expect(html).not.toContain('Can’t scan it?')
    expect(html).not.toContain('Scanning it')
    // The tailnet URL is still a fact about the route, on the route's own row —
    // what has gone is a *pairing link*, which is that address with a token
    // stapled to it.
    expect(html).not.toContain('#t=')
  })

  it('counts down, without announcing every second of it', () => {
    expect(html).toContain('Expires in 45s')
    expect(html).toContain('aria-live="off"')
    expect(codeSecondsLeft(NOW + 45_000, NOW)).toBe(45)
  })

  it('offers a copy, because the other device is often on the same clipboard', () => {
    expect(html).toContain('>Copy</button>')
  })

  it('shows this Mac’s fingerprint, so the device’s copy can be compared with it', () => {
    expect(html).toContain(RELAY.fingerprint)
    expect(html).toContain('same six groups')
  })

  it('has one press to kill the code early', () => {
    expect(html).toContain('Hide the code')
  })

  it('says a code minted with the relay down reaches only the tailnet', () => {
    // True and narrow. Nothing can look the code up without the relay, but a
    // device already on the tailnet can still reach the address above and
    // redeem it there — so this is neither "it works" nor "it is dead".
    const tailnet = render({
      state: { ...RUNNING, relay: { ...RELAY, connected: false, reason: 'The link dropped.' } },
      pairing,
      secondsLeft: 45,
    })
    // The direct address is printed here and *only* here. This is the single
    // state where the tailnet is the only way in and therefore the only thing
    // the reader can act on, which is why it survived the card's removal.
    expect(tailnet).toContain('only a device already on your tailnet can use it')
    expect(tailnet).toContain('https://asads-macbook-pro-1.taile59277.ts.net:8443')
    expect(tailnet).toContain('>482913<')
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

  it('says the right thing when every path goes away underneath it', () => {
    // Reachable: the relay drops while the code is on screen on a machine with
    // no tailnet. "Expired" would be the wrong reason and would send somebody to
    // make another one that would be just as unreachable.
    const stranded = render({
      state: { ...RELAY_ONLY, relay: { ...RELAY, connected: false, reason: 'The link dropped.' } },
      pairing,
      secondsLeft: 45,
    })
    expect(stranded).toContain('nowhere to point this code')
    expect(stranded).not.toContain('That code has expired')
    expect(stranded).not.toContain('>482913<')
  })
})

/**
 * A code the rendezvous never took, which is the state this panel used to draw
 * as success.
 *
 * The failure it stands for is real and was measured on the live relay: the
 * main process mints a code and claims the slot that code names, and that claim
 * can fail — nothing to publish, a beacon that would not build, or a slot that
 * did not come up in six seconds — under a relay row that says Connected. The
 * handler computed the answer, dropped it, and returned the code alone, so all
 * four of those paths produced six digits, a countdown and a Copy button.
 *
 * What made it expensive is where the failure surfaced. The person reads the
 * digits onto a phone, the phone derives the same slot, finds nobody in it, and
 * says "no machine is showing that code" — a minute later, on the device that
 * did nothing wrong, with no way to name the end that did. Every assertion here
 * is about saying it on this screen instead, while somebody is still standing in
 * front of the machine.
 */
describe('a code the rendezvous never took', () => {
  const unfindable = { token: '482913', expiresAt: NOW + 45_000, findable: false }

  it('does not present the digits as usable when nothing can look them up', () => {
    // No direct route, so there is no client left that could redeem this code.
    // The digits come off the screen: six digits nobody can use are worse than
    // none, because somebody types them and then waits out the minute.
    const html = render({ state: RELAY_ONLY, pairing: unfindable, secondsLeft: 45 })
    expect(html).not.toContain('>482913<')
    expect(html).toContain('could not take its place at the rendezvous')
    expect(html).toContain('The digits are not shown')
  })

  it('does not offer to copy a code that reaches nothing', () => {
    // Copy is the panel handing somebody the failure to carry to another
    // device, which is the one thing this state must not do.
    const html = render({ state: RELAY_ONLY, pairing: unfindable, secondsLeft: 45 })
    expect(html).not.toContain('>Copy</button>')
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Try again<\/button>/)
  })

  it('does not count down, because there is nothing to wait for', () => {
    const html = render({ state: RELAY_ONLY, pairing: unfindable, secondsLeft: 45 })
    expect(html).not.toContain('Expires in 45s')
    // And it does not claim the code expired either — it did not, and "expired"
    // would send somebody to mint another one exactly like it.
    expect(html).not.toContain('That code has expired')
  })

  it('blames the rendezvous rather than the relay row, which may say Connected', () => {
    // RELAY_ONLY's relay *is* connected. A sentence asserting the relay is down
    // sends the reader to stare at a row that disagrees with it.
    const html = render({ state: RELAY_ONLY, pairing: unfindable, secondsLeft: 45 })
    expect(html).toContain('>Connected<')
    expect(html).not.toContain('The relay is not connected')
  })

  it('keeps the digits when this machine has a direct route, and narrows the claim', () => {
    /*
     * The other half, and the reason this is not one flag.
     *
     * With a tailnet address the code is not dead: the browser client this
     * machine serves has the address in its own origin and needs no lookup, so
     * a device already on that tailnet can still redeem it. Withholding the
     * digits here would take away a pairing that works.
     */
    const html = render({ state: RUNNING, pairing: unfindable, secondsLeft: 45 })
    expect(html).toContain('>482913<')
    expect(html).toContain('Nothing can look this code up')
    expect(html).toContain('only a device already on your tailnet can use it')
  })

  it('says nothing about findability when the main process did not say', () => {
    // An older main process against this window. Absent is not false, and the
    // panel falls back to what it can see for itself — a connected relay, so
    // nothing to warn about.
    const quiet = { token: '482913', expiresAt: NOW + 45_000, findable: null }
    const html = render({ state: RELAY_ONLY, pairing: quiet, secondsLeft: 45 })
    expect(html).toContain('>482913<')
    expect(html).toContain('Expires in 45s')
    expect(html).not.toContain('could not take its place at the rendezvous')
    expect(html).not.toContain('Nothing can look this code up')
  })
})

/**
 * The state he screenshotted, on Windows, and the dead end behind it.
 *
 * The wording is his and it is right: it says what happened and what to do
 * about it in one line. What was wrong was the second half — the panel it was
 * printed on could reach a state where "show another one" was not a thing you
 * could do, because the only control that would mint one was disabled or absent.
 * So the sentence is pinned *and* the button under it is, in both directions.
 */
describe('a code that expired while the panel was open', () => {
  const pairing = { token: '482913', expiresAt: NOW - 1_000, findable: true }
  const html = render({ state: RUNNING, pairing, secondsLeft: 0 })

  it('says so in the words that were already right', () => {
    expect(html).toContain('That code has expired. Show another one.')
  })

  it('leaves nothing on screen that could still be typed', () => {
    expect(html).not.toContain('>482913<')
    expect(html).toContain('Expired')
  })

  it('offers a live button that mints another, which is the whole fix', () => {
    // Not disabled: the dead end was an expired code beside a control that
    // could not replace it.
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Show another one<\/button>/)
    expect(html).toContain('>Done</button>')
  })

  it('and that button is `pair`, the same one that minted the first code', () => {
    // Pinned on the action rather than the markup: a second "mint" path is how
    // the two screens' codes drifted apart before they were merged.
    const pressed: string[] = []
    const actions: RemoteActions = { ...NOTHING, pair: () => pressed.push('pair') }
    const markup = renderToStaticMarkup(
      <RemoteView
        state={RUNNING}
        wired
        problem={null}
        notice={null}
        pairing={pairing}
        secondsLeft={0}
        busy={null}
        machines={machinesHalf()}
        actions={actions}
        now={NOW}
        platform="mac"
      />,
    )
    expect(markup).toContain('Show another one')
    // The press itself is exercised in "the switch"/"pairing" below, through
    // `remoteActions`; what this pins is that the control exists in this state.
    actions.pair()
    expect(pressed).toEqual(['pair'])
  })

  it('says why instead, when nothing could mint one', () => {
    // The other half of the same rule. The button is still there and it is
    // *disabled*, which is the treatment the first press already gets on this
    // screen — and the sentence beside it is the reason, in place of the
    // expiry notice. What must not happen is an enabled button whose only
    // possible outcome is a failure notice, or a disabled one with nothing
    // saying why.
    const stranded = render({
      state: { ...RELAY_ONLY, relay: { ...RELAY, connected: false, reason: 'The link dropped.' } },
      pairing,
      secondsLeft: 0,
    })
    expect(stranded).toContain('nowhere to point this code')
    expect(stranded).toMatch(/<button[^>]*disabled[^>]*>Show another one<\/button>/)
    expect(stranded).not.toContain('That code has expired')
  })

  it('knows when a code could be minted at all', () => {
    expect(canMintCode(null)).toBe(false)
    expect(canMintCode({ ...RUNNING, running: false })).toBe(false)
    expect(canMintCode(RELAY_ONLY)).toBe(true)
    // The relay is down, but this machine has a tailnet address — which is a
    // way in, and refusing to mint on it is the bug the relay-only users hit
    // from the other direction.
    expect(canMintCode({ ...RUNNING, relay: { ...RELAY, connected: false } })).toBe(true)
    expect(
      canMintCode({ ...RELAY_ONLY, relay: { ...RELAY, connected: false } }),
    ).toBe(false)
  })
})

/**
 * The merge itself: what the sidebar's Machines page could do, on this screen.
 *
 * Two screens became one and the failure mode of that is not a broken build —
 * it is a control that quietly did not come across, found weeks later by
 * somebody who used to have it. So this suite is written against the list of
 * what that page did: show a code, take a code, list the machines, say what is
 * running on each, start a session, connect, disconnect, forget, and open a
 * session as a terminal. Every one of them is asserted on the merged section.
 */
describe('the merge', () => {
  const both = render({
    state: { ...RUNNING, devices: [{ ...PHONE, state: 'approved' }] },
    machines: machinesHalf({
      view: { machines: [STUDIO], links: [STUDIO_LINK], blocked: null },
    }),
  })

  it('holds a phone and a second computer on one screen', () => {
    // The whole argument of the merge, in one render: the roster of things that
    // can reach this machine, and the roster of machines it can reach.
    expect(both).toContain('Asad’s iPhone')
    expect(both).toContain('Studio PC')
    expect(both).toContain('Devices')
    expect(both).toContain('Machines you can reach')
  })

  it('draws both halves of pairing, in the order somebody does them', () => {
    // Show a code here, type one from there. Splitting those across two screens
    // meant explaining which screen to open on which machine before anything
    // could happen, inside a code that lasts a minute.
    expect(both).toContain('Let a device in')
    expect(both).toContain('Add another computer')
    expect(both.indexOf('Let a device in')).toBeLessThan(both.indexOf('Add another computer'))
  })

  it('takes a code in one box per digit, numeric, and nothing else', () => {
    const boxes = both.match(/class="machine-entry-box"/g) ?? []
    expect(boxes).toHaveLength(CODE_LENGTH)
    expect(both).toContain('inputMode="numeric"')
    expect(both).toContain('autoComplete="one-time-code"')
    // The old field's placeholder was a real-looking example code set in the
    // same mono face, so an empty field read as a filled one. There is no
    // placeholder at all now — six empty boxes say what is wanted.
    expect(both).not.toMatch(/placeholder="[0-9]/)
  })

  it('will not send an incomplete code', () => {
    expect(both).toMatch(/<button[^>]*disabled[^>]*>Pair<\/button>/)
    const ready = render({
      state: RUNNING,
      machines: machinesHalf({ entry: { digits: '482913', busy: false, error: null, blocked: null } }),
    })
    expect(ready).toMatch(/<button(?![^>]*disabled)[^>]*>Pair<\/button>/)
  })

  it('prints the far machine’s own words when a code is refused', () => {
    // Verbatim, because `pairWithCode` writes these to say what to do — "no
    // machine is showing that code" and "they last a minute" is the answer to
    // both a wrong code and an expired one.
    const refused = render({
      state: RUNNING,
      machines: machinesHalf({
        entry: {
          digits: '482913',
          busy: false,
          error:
            'No machine is showing that code. Check the digits, and that the code on the other machine has not run out — they last a minute.',
          blocked: null,
        },
      }),
    })
    expect(refused).toContain('No machine is showing that code')
    expect(refused).toContain('aria-invalid="true"')
  })

  it('goes quiet with a reason rather than failing on submit', () => {
    const blocked = render({
      state: RUNNING,
      machines: machinesHalf({
        entry: {
          digits: '',
          busy: false,
          error: null,
          blocked: 'This machine is not connected to the relay yet, so it cannot show or read a pairing code.',
        },
      }),
    })
    expect(blocked).toContain('not connected to the relay yet')
    expect(blocked).toMatch(/<input[^>]*class="machine-entry-box"[^>]*disabled/)
  })

  it('keeps every control the machines page had on a machine row', () => {
    expect(both).toContain('>New session</button>')
    expect(both).toContain('>Disconnect</button>')
    expect(both).toContain('>Forget</button>')
    // Its state, its kind, and the key a person compares with the other screen.
    expect(both).toContain('Connected')
    expect(both).toContain('PC')
    expect(both).toContain(STUDIO.fingerprint)
    // And what is running on it, as a control that opens it.
    expect(both).toContain('agent')
    expect(both).toContain('…/projects/deck')
    expect(both).toContain('aria-pressed="false"')
  })

  it('offers Connect instead when the link is down, and says what to do while it waits', () => {
    const offline = render({
      state: RUNNING,
      machines: machinesHalf({
        view: {
          machines: [STUDIO],
          links: [{ ...STUDIO_LINK, state: 'awaiting-approval', sessions: [] }],
          blocked: null,
        },
      }),
    })
    expect(offline).toContain('>Connect</button>')
    expect(offline).toContain('Waiting to be approved')
    // The one sentence the far machine writes for the wrong reader: it says
    // "approve it in the desktop app" to a desktop that *is* the app.
    expect(offline).toContain('Approve this Mac on Studio PC')
    expect(offline).not.toContain('in the desktop app')
  })

  it('opens a session as a terminal in the same section', () => {
    const open = render({
      state: RUNNING,
      machines: machinesHalf({
        view: { machines: [STUDIO], links: [STUDIO_LINK], blocked: null },
        open: { machineId: 'MACHINE1', sessionId: 's1' },
        // The real one builds an xterm against a DOM, which is why it arrives
        // as a node rather than being built by the view.
        pane: <div className="pane-stand-in" />,
      }),
    })
    expect(open).toContain('machines-pane')
    expect(open).toContain('pane-stand-in')
    expect(open).toContain('/Users/a/projects/deck')
    expect(open).toContain('aria-pressed="true"')
    expect(open).toContain('>Close</button>')
  })

  it('says so plainly when this build cannot reach the machine channels', () => {
    const older = render({ state: RUNNING, machines: machinesHalf({ wired: false }) })
    expect(older).toContain('older preload')
    expect(older).toContain('cannot pair with another desktop')
    // And nothing that looks like it would work.
    expect(older).toMatch(/<input[^>]*class="machine-entry-box"[^>]*disabled/)
  })

  it('draws nothing at all when there is no other machine', () => {
    // Not "says the list is empty" any more. A heading, two lines about pairing
    // going both ways and a sentence saying there is nothing in the list is
    // three paragraphs describing an absence, on the page whose complaint was
    // that it describes too much. The way to get a machine — "Add another
    // computer" — is in the pairing block above.
    const empty = render({ state: RUNNING })
    expect(empty).not.toContain('Machines you can reach')
    expect(empty).not.toContain('No other machine yet')
  })

  it('waits out loud while the first read is running, and stops waiting', () => {
    const reading = render({ state: RUNNING, machines: machinesHalf({ reading: true }) })
    expect(reading).toContain('Reading the machines this desktop knows')

    // The half of this that was missing. That sentence stood on screen for the
    // length of a 47-minute recording, because a read that never settles has no
    // state to move to. It has one now — see `READ_DEADLINE_MS`.
    const failed = render({
      state: RUNNING,
      machines: machinesHalf({
        error: 'The machines this desktop knows did not answer within 8 seconds.',
        retry: () => {},
      }),
    })
    expect(failed).toContain('did not answer within 8 seconds')
    expect(failed).toContain('Try again')
    expect(failed).not.toContain('No other machine yet')
  })

  it('puts the folder chooser between the devices and the machines', () => {
    // The order is the argument the section makes: pair a device, approve it,
    // choose what it may open, and then the machines this one dials out to.
    const ordered = render({
      state: { ...RUNNING, devices: [{ ...PHONE, state: 'approved' }] },
      folders: <div className="folders-stand-in" />,
      machines: machinesHalf({ view: { machines: [STUDIO], links: [STUDIO_LINK], blocked: null } }),
    })
    expect(ordered.indexOf('Devices')).toBeLessThan(ordered.indexOf('folders-stand-in'))
    expect(ordered.indexOf('folders-stand-in')).toBeLessThan(
      ordered.indexOf('Machines you can reach'),
    )
  })

  it('keeps the machines half even when remote access is not in the build', () => {
    // Two features of the main process: one lets a device in, the other dials
    // out. A build missing the first can perfectly well have the second, and
    // hiding the machines would take a working half away with the other one.
    const markup = renderToStaticMarkup(
      <RemoteView
        state={null}
        wired={false}
        problem={null}
        notice={null}
        pairing={null}
        secondsLeft={null}
        busy={null}
        machines={machinesHalf({
          view: { machines: [STUDIO], links: [STUDIO_LINK], blocked: null },
        })}
        actions={NOTHING}
        now={NOW}
        platform="mac"
      />,
    )
    expect(markup).toContain('not wired into this build')
    expect(markup).toContain('Studio PC')
  })
})

describe('when the read itself fails', () => {
  it('shows the error and admits what is on screen may be stale', () => {
    const html = render({ state: RUNNING, problem: 'tailscale status exited with code 1.' })
    expect(html).toContain('tailscale status exited with code 1.')
    expect(html).toContain('may be out of date')
  })

  it('offers the read again, so the failure is not another dead end', () => {
    // A failure with nothing to press is the loading line again, one sentence
    // longer. This is the other end of the deadline below: the read now always
    // finishes, and every way it can finish has a way out of it.
    const html = render({ state: null, problem: 'The remote access state did not answer.' })
    expect(html).toContain('Try again')
  })

  it('stops waiting for a read that never answers', async () => {
    /*
     * The bug this closes, and it is not a slow read — it is a read that never
     * settles at all. `ipcRenderer.invoke` against a handler that never returns
     * neither resolves nor rejects, so "Reading the current state…" had no
     * state to move to and stood on screen for the whole of a 47-minute
     * recording.
     *
     * A fake clock rather than a real wait: eight seconds of real time in a
     * test suite is eight seconds nobody gets back, and what is being checked
     * is the deadline, not the machine's ability to count.
     */
    vi.useFakeTimers()
    try {
      const never = new Promise<never>(() => {})
      const raced = withDeadline(never, 'The remote access state', READ_DEADLINE_MS)
      const landed = vi.fn()
      void raced.catch(landed)

      await vi.advanceTimersByTimeAsync(READ_DEADLINE_MS - 1)
      expect(landed).not.toHaveBeenCalled()

      await vi.advanceTimersByTimeAsync(2)
      expect(landed).toHaveBeenCalledOnce()
      expect(String(landed.mock.calls[0][0])).toContain('did not answer')
    } finally {
      vi.useRealTimers()
    }
  })

  it('claims nothing about devices before the first answer arrives', () => {
    const html = render({ state: null })
    expect(html).toContain('Reading the current state')
    expect(html).not.toContain('No device has been paired')
  })
})

describe('turning it on', () => {
  /**
   * The confirmation step is gone, and these are what replaced it.
   *
   * The old test asserted a second dialogue — "Turn on remote access?" with a
   * "Leave it off" beside it — and it is deliberately deleted rather than
   * skipped: the two-press flow was removed on the owner's instruction, and a
   * test that still demanded it would be a test arguing with the product.
   *
   * What the confirmation *said* had to survive, and does. The word `shell` is
   * on the switch's own row, where it is read before the press rather than
   * after it, and the rest of that paragraph is behind the row's ⓘ.
   */
  it('says what is being handed over before the switch is pressed, not after', () => {
    const html = render({ state: { ...RUNNING, running: false } })
    expect(html).toContain('gets a shell here')
    expect(html).not.toContain('Turn on remote access?')
    expect(html).not.toContain('Leave it off')
  })

  it('keeps every clause of the paragraph the confirmation used to carry', () => {
    const html = render({ state: { ...RUNNING, running: false } })
    for (const clause of [
      // The two kinds replaced "any session running here", which described a
      // world where approving was one button and a device with no folder record
      // got whatever the desktop had open. Both halves are asserted, because the
      // guest half is the one somebody reads before handing a phone to a
      // colleague and it is the one that used to be missing.
      'One of your own gets everything',
      'A guest gets the folders you choose and nothing else',
      'never the copilot',
      'sealed end to end',
      'an approval you give here',
    ]) {
      expect(html).toContain(clause)
    }
  })
})

/* ---------------------------------------------- what the machine is called -- */

/**
 * The same panel on a Windows host.
 *
 * This app ships on Windows now, and one phone can be paired to a Mac and a
 * Windows PC at the same time — so "this Mac" is not a harmless Apple-ism, it
 * is the app being wrong about the computer the reader is sitting at. Every
 * sentence on this screen names that computer, which is why the noun is a
 * prop and why both answers are asserted here in one run.
 *
 * The negative assertion is the one that matters. A sentence added later with
 * "Mac" typed into it passes every positive check above and fails this.
 */
describe('the noun for the machine', () => {
  /** Everything on the panel at once: paths, code, fingerprint, tunnels. */
  const busy = {
    state: {
      ...RUNNING,
      devices: [PHONE],
      connections: [TUNNELLED],
    },
    pairing: { token: '482913', expiresAt: NOW + 60_000, findable: true } as RemotePairing,
    secondsLeft: 42,
  }

  const mac = render(busy)
  const pc = render({ ...busy, platform: 'windows' })

  it('says Mac on a Mac', () => {
    expect(mac).toContain('Drive this Mac from a phone')
    expect(mac).toContain('this Mac dials out to it')
    expect(mac).toContain('whatever types it finds this Mac there')
    expect(mac).toContain('This Mac’s fingerprint')
    expect(mac).toContain('served from this Mac to that phone’s browser')
    expect(mac).toContain('the row below shows what this Mac received')
  })

  it('says PC on Windows, in every one of those sentences', () => {
    expect(pc).toContain('Drive this PC from a phone')
    expect(pc).toContain('this PC dials out to it')
    expect(pc).toContain('whatever types it finds this PC there')
    expect(pc).toContain('This PC’s fingerprint')
    expect(pc).toContain('served from this PC to that phone’s browser')
    expect(pc).toContain('the row below shows what this PC received')
  })

  it('never says Mac on Windows anywhere on the panel', () => {
    // Everything the panel renders, including labels a screen reader gets.
    //
    // A word boundary rather than a substring, and that is not a loosening: the
    // merged section has a heading reading "Machines you can reach", which
    // contains those three letters and is the correct English word for a
    // Windows PC, a Mac and a Linux box together. What must never appear is the
    // Apple noun, and `\bMac\b` is exactly that — "Machines" does not match it
    // and "this Mac" does.
    expect(pc).not.toMatch(/\bMac\b/)
  })

  it('falls back to a word that is true rather than guessing Mac', () => {
    // Linux has no build target and Node has no platform worth trusting; both
    // land here. "computer" is not a Mac and not a PC, and it is not wrong.
    const other = render({ ...busy, platform: 'other' })
    expect(other).toContain('Drive this computer from a phone')
    expect(other).not.toMatch(/\bMac\b/)
    expect(other).not.toContain('this PC')
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
    expect(toRemotePairing({ token: 'abc' })).toEqual({
      token: 'abc',
      expiresAt: null,
      findable: null,
    })
    expect(toRemotePairing({ token: 'abc', expiresAt: 'soon' })?.expiresAt).toBeNull()
  })

  it('carries whether the code can be looked up, in all three of its states', () => {
    /*
     * The field this panel lost, pinned at the seam it was lost in.
     *
     * `remote:pair` computes `findable` while it claims the rendezvous slot the
     * code names, and it used to answer with the code alone — so a code nothing
     * could look up arrived here indistinguishable from one anything could, and
     * was drawn the same. If this narrowing ever goes back to picking `token`
     * and `expiresAt` out of the answer, this is what fails.
     *
     * Three states rather than a boolean, because absent is not false: a main
     * process too old to send the field has not said the code is unfindable,
     * and printing that over a working code is the same class of lie in the
     * other direction.
     */
    expect(toRemotePairing({ token: 'abc', expiresAt: 1, findable: true })?.findable).toBe(true)
    expect(toRemotePairing({ token: 'abc', expiresAt: 1, findable: false })?.findable).toBe(false)
    expect(toRemotePairing({ token: 'abc', expiresAt: 1 })?.findable).toBeNull()
    // Not coerced. A string, a number or a null in that field is a main process
    // saying something this window cannot read, which is "did not say".
    expect(toRemotePairing({ token: 'abc', expiresAt: 1, findable: 'yes' })?.findable).toBeNull()
    expect(toRemotePairing({ token: 'abc', expiresAt: 1, findable: 1 })?.findable).toBeNull()
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

  it('drops the direct route’s excuse on the floor, in every state', () => {
    /*
     * The main process still computes `directReason` — it is a real diagnosis
     * and `tailnet.ts` writes it carefully. This side does not narrow it, does
     * not keep it, and therefore cannot draw it by accident later.
     *
     * Pinned on the narrowing rather than only on the markup because that is
     * what makes it stay true: a field that survived into `RemoteState` would be
     * one JSX line away from being on screen again, and the JSX tests only cover
     * the states somebody thought to write down.
     */
    const state = toRemoteState(
      { running: true, reason: null, directReason: 'Tailscale is logged out.' },
      [],
    )
    expect(state?.reason).toBeNull()
    expect(JSON.stringify(state)).not.toContain('Tailscale')
    expect(Object.keys(state ?? {})).not.toContain('directReason')
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
  /** How many times the panel was asked to re-read. */
  rereads: number
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
    'listRemoteDeviceKinds',
    'pickProjectFolder',
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
  const state = { pairing, rereads: 0 }
  const actions = remoteActions({
    bridge,
    pairing,
    setPairing: (next) => {
      state.pairing = next
    },
    reread: () => {
      state.rereads += 1
    },
    // No flow open. These tests drive the actions directly, which is the layer
    // below the flow — `approve` is called with the answers the flow would have
    // collected, so the answers are explicit in each test rather than assembled
    // by a component nothing here renders.
    approving: null,
    setApproving: () => {},
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
    get rereads() {
      return state.rereads
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
  /**
   * One press, each way.
   *
   * There were two presses on the way on, and this file used to pin them: a
   * first press that armed a confirmation and a second that started the server.
   * Asad removed it — *"don't give two step of this like turn on… only this one
   * is good enough, and if I click on that, it turns on."* — and the reason it
   * is safe to remove is that the confirmation was never the gate. Nothing can
   * connect until a device is handed a sixty-second code and then approved by
   * hand on this screen, and those two acts are pinned further down this file.
   */
  it('starts on the first press, because the confirmation was never the gate', async () => {
    const { bridge, calls } = fakeBridge({ startRemote: { running: true, url: 'https://h.ts.net' } })
    const h = harness(bridge)
    h.actions.enable(true)
    await h.settled()
    expect(calls).toEqual(['startRemote()'])
    expect(h.notices).toEqual([{ ok: true, text: expect.stringContaining('Remote access is on') }])
  })

  it('says, on turning on, that nothing can connect yet', async () => {
    // The sentence carries what the deleted confirmation used to say. Turning
    // this on opens onto another door, and the notice has to say so or one
    // press reads as "my machine is now reachable by anybody".
    const { bridge } = fakeBridge({ startRemote: { running: true } })
    const h = harness(bridge)
    h.actions.enable(true)
    await h.settled()
    expect(h.notices[0].text).toContain('pair and approve a device')
  })

  it('turns off in one press too', async () => {
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
    const h = harness(bridge, { token: 'abc', expiresAt: NOW + 60_000, findable: true })
    h.actions.enable(false)
    await h.settled()
    expect(calls).toEqual(['cancelRemotePairing()', 'stopRemote()'])
    expect(h.pairing).toBeNull()
  })

  it('reports a start that did not take in the main process’s own words', async () => {
    const reason = 'Tailscale is installed but this Mac is logged out of the tailnet.'
    const { bridge } = fakeBridge({ startRemote: { running: false, reason } })
    const h = harness(bridge)
    h.actions.enable(true)
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
    h.actions.approve(PENDING_DEVICE, 'guest', ['/Users/apple/Projects/alpha'])
    await h.settled()
    // The kind and the folders travel with the approval, in the same call. A
    // channel that took only an id is the arrangement in which a device was let
    // in with the folder question unanswered — and unanswered used to mean yes.
    expect(calls).toEqual([
      'approveRemoteDevice(dev-1, guest, /Users/apple/Projects/alpha)',
    ])
    expect(h.notices).toEqual([{ ok: true, text: 'Asad’s iPhone can open one folder.' }])
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
    h.actions.approve(PENDING_DEVICE, 'guest', ['/Users/apple/Projects/alpha'])
    await h.settled()
    expect(h.notices).toEqual([{ ok: false, text: expect.stringContaining('did not take') }])
  })

  it('falls back to what it asked for when the answer is not a device list', async () => {
    const { bridge } = fakeBridge({ approveRemoteDevice: { ok: true } })
    const h = harness(bridge)
    h.actions.approve(PENDING_DEVICE, 'guest', ['/Users/apple/Projects/alpha'])
    await h.settled()
    expect(h.notices).toEqual([{ ok: true, text: 'Asad’s iPhone can open one folder.' }])
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
    h.actions.enable(true)
    h.actions.pair()
    h.actions.closePairing()
    h.actions.approve(PENDING_DEVICE, 'guest', ['/Users/apple/Projects/alpha'])
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
    // `findable: null` because this fixture's main process did not say — which
    // is a state the panel has to hold rather than resolve, and is exactly what
    // a window running against an older build would get.
    expect(h.pairing).toEqual({ token: 'tok-1', expiresAt: NOW + 60_000, findable: null })
    h.actions.closePairing()
    await h.settled()
    expect(calls).toEqual(['startRemotePairing()', 'cancelRemotePairing()'])
    expect(h.pairing).toBeNull()
  })

  it('mints a fresh code from an expired one rather than re-showing it', async () => {
    // The Windows dead end, pinned on the action: pressing "Show another one"
    // has to reach `remote:pair` and replace what is on screen. A guard that
    // refused while `pairing` was still set — the expired code is still in
    // state at that moment — would leave the button doing nothing at all.
    const { bridge, calls } = fakeBridge({
      startRemotePairing: { token: '913482', expiresAt: NOW + 60_000, findable: true },
    })
    const dead = { token: '482913', expiresAt: NOW - 1_000, findable: true }
    const h = harness(bridge, dead)
    h.actions.pair()
    await h.settled()
    expect(calls).toEqual(['startRemotePairing()'])
    // The whole answer, findability included: the panel narrows what the main
    // process sent rather than rebuilding a code out of the fields it happens to
    // care about, which is how the field went missing on the way through before.
    expect(h.pairing).toEqual({ token: '913482', expiresAt: NOW + 60_000, findable: true })
  })

  it('leaves no stale code on screen when the mint fails', async () => {
    // Otherwise the expired code stays up next to a failure notice, which reads
    // as a code somebody could still type.
    const { bridge } = fakeBridge({ startRemotePairing: { expiresAt: NOW } })
    const h = harness(bridge, { token: '482913', expiresAt: NOW - 1_000, findable: true })
    h.actions.pair()
    await h.settled()
    expect(h.pairing).toBeNull()
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


describe('what a device is called on screen', () => {
  /**
   * A real paired phone arrived here as "Google sdk_gphone64_arm64" — Android's
   * system-image build target, reported as the model — and that string was the
   * title of a card whose whole job is answering "which of your devices is
   * this".
   */
  it('names the Android emulator instead of printing its build target', () => {
    expect(deviceLabel('Google sdk_gphone64_arm64')).toBe('Android emulator')
    expect(deviceLabel('sdk_gphone64_x86_64')).toBe('Android emulator')
  })

  it('reads an underscored identifier as the words it stands for', () => {
    expect(deviceLabel('SM_G991B')).toBe('SM G991B')
  })

  it('leaves a name somebody would recognise exactly as it is', () => {
    expect(deviceLabel('Pixel 7')).toBe('Pixel 7')
    expect(deviceLabel("Asad's iPhone")).toBe("Asad's iPhone")
  })

  it('says so rather than drawing an empty title', () => {
    expect(deviceLabel('   ')).toBe('Unnamed device')
  })

  it('is applied where the rows read it, not only where it is defined', () => {
    const [device] = toRemoteDevices([
      { id: 'd1', name: 'Google sdk_gphone64_arm64', approved: true },
    ])
    expect(device.name).toBe('Android emulator')
  })
})
