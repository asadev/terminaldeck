/**
 * Look at the remote-access panel without Electron, in every state that matters.
 *
 *     npx vite --config .harness/vite.config.ts --port 5211
 *     open http://localhost:5211/remote.html
 *
 * `RemoteView` takes everything it draws, so each state below is a fixture
 * rather than a sequence of clicks — which is the only way to see the states
 * that need a relay, a phone and a sixty-second window to reach for real.
 *
 * The panel is mounted inside the same `.settings` / `.settings-panel` wrapper
 * the real window uses, at the real width, because half the defects this page
 * exists to catch are alignment and wrapping ones that only appear at 690px.
 */
import { createRoot } from 'react-dom/client'
import {
  RemoteView,
  type RemoteActions,
  type RemoteConnection,
  type RemoteDevice,
  type RemoteRelay,
  type RemoteState,
} from '../src/renderer/remote/RemoteSection'
import type {
  MachineActions,
  MachinesHalf,
} from '../src/renderer/machines/MachineLinks'
import type { Machine, MachineLinkState } from '../src/renderer/machines/types'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'

const NOW = Date.now()

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
  stopTunnel: () => {},
}

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

const BOTH: RemoteState = {
  running: true,
  url: 'https://asads-macbook-pro-1.taile59277.ts.net:8443',
  address: '100.86.107.119',
  reason: null,
  relay: RELAY,
  devices: [],
  connections: [],
}

const RELAY_ONLY: RemoteState = {
  ...BOTH,
  url: null,
  address: null,
}

const NOTHING_UP: RemoteState = {
  ...RELAY_ONLY,
  relay: {
    ...RELAY,
    connected: false,
    reason:
      'The relay could not be reached: getaddrinfo ENOTFOUND relay.terminaldeck.dev. Check this Mac’s network, then turn remote access off and on again.',
    retryAt: NOW + 8_000,
  },
}

const PHONE: RemoteDevice = {
  id: 'dev-1',
  name: 'Asad’s iPhone',
  state: 'pending',
  addedAt: NOW - 40_000,
  lastSeenAt: NOW - 20_000,
  fingerprint: 'H4TC-8MKD-2QWX-7BNP-5ZRJ-9VFY',
}

const LAPTOP: RemoteDevice = {
  id: 'dev-2',
  name: 'iPad mini',
  state: 'approved',
  addedAt: NOW - 6 * 3_600_000,
  lastSeenAt: NOW - 90_000,
  fingerprint: 'B2WK-6HJN-4TDX-8CRM-3YFQ-7PZV',
}

/** Paired before there were keys: tailnet only, and the row has to say so. */
const OLD_PHONE: RemoteDevice = {
  id: 'dev-3',
  name: 'Pixel 8 (paired in July)',
  state: 'approved',
  addedAt: NOW - 30 * 86_400_000,
  lastSeenAt: NOW - 3 * 86_400_000,
  fingerprint: null,
}

const ATTACHED: RemoteConnection = {
  id: 'conn-1',
  deviceId: 'dev-2',
  deviceName: 'iPad mini',
  platform: 'iPadOS 26',
  address: 'relay:8Kd2Nq4Rt7Vw1Yb3',
  connectedAt: NOW - 12 * 60_000,
  sessionIds: ['s1', 's2'],
  tunnels: [],
}

/**
 * The same phone reading two dev servers on this Mac.
 *
 * One busy and one idle, because the row prints the socket count for the first
 * and stays silent on the second — and a five-digit port next to a four-digit
 * one is what shows whether the chips are aligned or merely close.
 */
const TUNNELLED: RemoteConnection = {
  ...ATTACHED,
  tunnels: [
    { id: 'tun-1', port: 5173, streams: 3, openedAt: NOW - 4 * 60_000 },
    { id: 'tun-2', port: 8080, streams: 0, openedAt: NOW - 40_000 },
  ],
}

const PAIRING = { token: '482913', expiresAt: NOW + 45_000 }

/* ------------------------------------------------- the machines half ----- */

const NO_MACHINE_ACTIONS: MachineActions = {
  type: () => {},
  pair: () => {},
  connect: () => {},
  disconnect: () => {},
  forget: () => {},
  newSession: () => {},
  open: () => {},
  close: () => {},
}

const STUDIO: Machine = {
  id: 'MACHINE1',
  name: 'Studio PC',
  hostId: 'MACHINE1',
  fingerprint: 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ',
  platform: 'win32',
  pairedAt: NOW - 9 * 86_400_000,
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
      cwd: '/Users/a/projects/terminaldeck',
      provider: 'claude',
      status: 'running',
      exitCode: null,
    },
    {
      id: 's2',
      title: 'build',
      cwd: '/Users/a/projects/terminaldeck/pwa',
      provider: 'shell',
      status: 'idle',
      exitCode: null,
    },
  ],
  folders: ['/Users/a/projects/terminaldeck'],
  capabilities: ['create'],
  hostPlatform: 'win32',
  retryAt: null,
}

function machines(over: Partial<MachinesHalf> = {}): MachinesHalf {
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

/** A stand-in for the terminal, which needs a real machine on the other end. */
const PANE = (
  <div
    style={{
      flex: 1,
      minHeight: '12rem',
      display: 'grid',
      placeItems: 'center',
      color: 'var(--text-muted)',
      fontFamily: 'var(--font-mono)',
      fontSize: 12,
    }}
  >
    the remote terminal mounts here
  </div>
)

interface Scene {
  title: string
  note: string
  props: Partial<Parameters<typeof RemoteView>[0]>
}

const SCENES: Scene[] = [
  {
    title: 'Both ways in',
    note: 'tailnet ready, relay connected — nothing paired yet',
    props: { state: BOTH },
  },
  {
    title: 'Relay only',
    note: 'no tailnet, and remote access is not broken — this is the state the relay exists for',
    props: { state: RELAY_ONLY },
  },
  {
    title: 'Nothing is up',
    note: 'relay disconnected, tailnet gone — Pair is dead and says why',
    props: { state: NOTHING_UP },
  },
  {
    title: 'Relay switched off in this build',
    note: 'TERMINALDECK_RELAY=off — the tailnet is the only path',
    props: { state: { ...BOTH, relay: null } },
  },
  {
    title: 'A code on screen',
    note: 'six digits, and the fingerprint is the check a person can make',
    props: { state: BOTH, pairing: PAIRING, secondsLeft: 45 },
  },
  {
    title: 'A code on a machine with no tailnet',
    note: 'the ordinary case: the relay is the whole answer',
    props: { state: RELAY_ONLY, pairing: PAIRING, secondsLeft: 45 },
  },
  {
    title: 'The code ran out',
    note: 'his words, and the button under them mints another',
    props: { state: BOTH, pairing: { ...PAIRING, expiresAt: NOW - 1000 }, secondsLeft: 0 },
  },
  {
    title: 'Half a code typed in',
    note: 'the entry side: auto-advancing boxes, and Pair stays dead until it is whole',
    props: {
      state: BOTH,
      machines: machines({ entry: { digits: '482', busy: false, error: null, blocked: null } }),
    },
  },
  {
    title: 'A code the far machine refused',
    note: 'its own sentence, printed verbatim — a wrong code and an expired one read the same',
    props: {
      state: BOTH,
      machines: machines({
        entry: {
          digits: '482913',
          busy: false,
          error:
            'No machine is showing that code. Check the digits, and that the code on the other machine has not run out — they last a minute.',
          blocked: null,
        },
      }),
    },
  },
  {
    title: 'Machines you can reach',
    note: 'the other half of the section: what this desktop dials out to',
    props: {
      state: BOTH,
      machines: machines({
        view: { machines: [STUDIO], links: [STUDIO_LINK], blocked: null },
      }),
    },
  },
  {
    title: 'A session open on another machine',
    note: 'the terminal lives inside the section, under the machine it belongs to',
    props: {
      state: BOTH,
      machines: machines({
        view: { machines: [STUDIO], links: [STUDIO_LINK], blocked: null },
        open: { machineId: 'MACHINE1', sessionId: 's1' },
        pane: PANE,
      }),
    },
  },
  {
    title: 'A machine waiting to be approved over there',
    note: 'the one sentence the far machine writes for the wrong reader, rewritten',
    props: {
      state: BOTH,
      machines: machines({
        view: {
          machines: [STUDIO],
          links: [{ ...STUDIO_LINK, state: 'awaiting-approval', sessions: [] }],
          blocked: null,
        },
      }),
    },
  },
  {
    title: 'The relay is down, so no code can be looked up',
    note: 'the entry side goes quiet with the main process’s own reason',
    props: {
      state: NOTHING_UP,
      machines: machines({
        view: {
          machines: [],
          links: [],
          blocked:
            'This machine is not connected to the relay yet, so it cannot show or read a pairing code. Turn remote access on and wait for it to connect.',
        },
        entry: {
          digits: '',
          busy: false,
          error: null,
          blocked:
            'This machine is not connected to the relay yet, so it cannot show or read a pairing code. Turn remote access on and wait for it to connect.',
        },
      }),
    },
  },
  {
    title: 'Devices',
    note: 'one waiting, one approved, one paired before keys existed, one attached now',
    props: {
      state: {
        ...BOTH,
        devices: [PHONE, LAPTOP, OLD_PHONE],
        connections: [ATTACHED],
      },
    },
  },
  {
    title: 'A phone with pages open on this Mac’s ports',
    note: 'one busy, one idle — the port is the row, and Stop closes a web page and nothing else',
    props: {
      state: {
        ...BOTH,
        devices: [LAPTOP],
        connections: [TUNNELLED],
      },
    },
  },
  {
    title: 'Off',
    note: '',
    props: {
      state: { ...BOTH, running: false, url: null, address: null, relay: null },
    },
  },
]

function Panel({ scene }: { scene: Scene }) {
  return (
    <div style={{ marginBottom: 28 }}>
      <p style={{ color: 'var(--text-primary)', fontSize: 13, fontWeight: 600, margin: '0 0 2px' }}>
        {scene.title}
      </p>
      {scene.note && (
        <p style={{ color: 'var(--text-muted)', fontSize: 12, margin: '0 0 8px' }}>{scene.note}</p>
      )}
      <div
        style={{
          background: 'var(--bg-primary)',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius-lg)',
          padding: '16px 20px',
        }}
      >
        <div className="settings">
          <div />
          <div className="settings-panel">
            <RemoteView
              state={null}
              wired
              problem={null}
              notice={null}
              pairing={null}
              secondsLeft={null}
              busy={null}
              confirmEnable={false}
              machines={machines()}
              actions={NOTHING}
              now={NOW}
              {...scene.props}
            />
          </div>
        </div>
      </div>
    </div>
  )
}

function Board({ theme }: { theme: 'dark' | 'light' }) {
  return (
    <div
      data-theme={theme}
      style={{
        background: 'var(--bg-secondary)',
        color: 'var(--text-primary)',
        fontFamily: 'var(--font-ui)',
        padding: '20px 24px 30px',
      }}
    >
      <p style={{ color: 'var(--text-muted)', fontSize: 12, margin: '0 0 14px' }}>{theme}</p>
      {SCENES.map((scene) => (
        <Panel key={`${theme}-${scene.title}`} scene={scene} />
      ))}
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <>
    <Board theme="dark" />
    <Board theme="light" />
  </>,
)
