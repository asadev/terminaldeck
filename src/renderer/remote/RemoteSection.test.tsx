import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  attachedFor,
  connectionNote,
  deviceStateAfter,
  missingRemoteMethods,
  pairingUrl,
  remoteActions,
  RemoteSection,
  RemoteView,
  resolveRemoteBridge,
  toRemoteConnections,
  toRemoteDevices,
  toRemotePairing,
  toRemoteState,
  whenSeen,
  type RemoteActions,
  type RemoteBridge,
  type RemoteConnection,
  type RemoteDevice,
  type RemotePairing,
  type RemoteState,
  type RemoteViewProps,
} from './RemoteSection'

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
  approve: () => {},
  deny: () => {},
  revoke: () => {},
  disconnect: () => {},
}

const RUNNING: RemoteState = {
  running: true,
  url: 'https://asads-macbook-pro-1.taile59277.ts.net:8443',
  address: '100.86.107.119',
  reason: null,
  devices: [],
  connections: [],
}

const PHONE = {
  id: 'dev-1',
  name: 'Asad’s iPhone',
  state: 'pending' as const,
  addedAt: NOW - 3 * 3_600_000,
  lastSeenAt: NOW - 10_000,
}

const ATTACHED: RemoteConnection = {
  id: 'conn-1',
  deviceId: 'dev-1',
  deviceName: 'Asad’s iPhone',
  platform: 'iOS 26',
  address: '100.86.107.42',
  connectedAt: NOW - 12 * 60_000,
  sessionIds: ['s1', 's2'],
}

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

  it('says the lists are empty rather than showing empty lists', () => {
    expect(html).toContain('No device has been paired')
    expect(html).toContain('Nothing is attached')
  })

  it('offers pairing, and says a code alone lets nothing in', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Pair a device<\/button>/)
    expect(html).toContain('it does not let anything in')
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
})

describe('a live pairing code', () => {
  const pairing = { token: '8fb1c2d4e5a6b7c8d9e0f1a2', expiresAt: NOW + 45_000 }
  const html = render({ state: RUNNING, pairing, secondsLeft: 45 })
  const expected = 'https://asads-macbook-pro-1.taile59277.ts.net:8443/#8fb1c2d4e5a6b7c8d9e0f1a2'

  it('draws the code as an SVG with a real path in it', () => {
    expect(html).toContain('<svg class="remote-qr"')
    expect(html).toMatch(/<path class="remote-qr-ink" d="M\d+ \d+h/)
  })

  it('counts down', () => {
    expect(html).toContain('Expires in 45s')
  })

  it('prints the same address for anyone who cannot scan it', () => {
    expect(html).toContain(expected)
    expect(html).toContain('Can’t scan it?')
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
    // And the address goes with it — a dead URL left on screen to type is worse
    // than no URL at all.
    expect(expired).not.toContain(expected)
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

  it('drops a pairing with no token, because the token is the whole code', () => {
    expect(toRemotePairing({ expiresAt: 1 })).toBeNull()
    expect(toRemotePairing(null)).toBeNull()
    expect(toRemotePairing({ token: 'abc' })).toEqual({ token: 'abc', expiresAt: null })
    expect(toRemotePairing({ token: 'abc', expiresAt: 'soon' })?.expiresAt).toBeNull()
  })
})

describe('pairingUrl', () => {
  it('puts the token in the fragment, where it never reaches a server log', () => {
    expect(pairingUrl('https://host.ts.net', 'abc')).toBe('https://host.ts.net/#abc')
    expect(pairingUrl('https://host.ts.net/', 'abc')).toBe('https://host.ts.net/#abc')
    expect(pairingUrl('https://host.ts.net:8443/', 'abc')).toBe('https://host.ts.net:8443/#abc')
  })

  it('replaces an existing fragment rather than nesting one inside it', () => {
    // Two hashes would make the token part of the first one's value, and the
    // phone would send a token that is not the token.
    expect(pairingUrl('https://host.ts.net/#stale', 'abc')).toBe('https://host.ts.net/#abc')
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

/* ----------------------------------------------------------- the actions -- */

/**
 * The nine buttons, exercised directly.
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
  ]
  const bridge: Record<string, unknown> = {}
  for (const name of names) {
    bridge[name] = (arg?: unknown): Promise<unknown> => {
      calls.push(arg === undefined ? `${name}()` : `${name}(${String(arg)})`)
      return Promise.resolve(answers[name] ?? null)
    }
  }
  return { bridge: bridge as Partial<RemoteBridge>, calls }
}

function harness(bridge: Partial<RemoteBridge>, pairing: RemotePairing | null = null): Harness {
  const notices: Harness['notices'] = []
  const pending: Array<Promise<void>> = []
  const state = { pairing, confirming: false }
  const actions = remoteActions({
    bridge,
    pairing,
    setPairing: (next) => {
      state.pairing = next
    },
    setConfirmEnable: (next) => {
      state.confirming = next
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
    await h.settled()
    expect(h.notices).toHaveLength(8)
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

  it('never leaves a tokenless answer on screen as if it were a code', async () => {
    const { bridge } = fakeBridge({ startRemotePairing: { expiresAt: NOW } })
    const h = harness(bridge)
    h.actions.pair()
    await h.settled()
    expect(h.pairing).toBeNull()
    expect(h.notices).toEqual([{ ok: false, text: expect.stringContaining('did not return') }])
  })
})
