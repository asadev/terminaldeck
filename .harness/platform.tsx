import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'
import '../src/renderer/remote/RemoteSection.css'
import { EmptyState } from '../src/renderer/components/EmptyState'
import { ShortcutsList } from '../src/renderer/components/ShortcutsSheet'
import { RemoteView } from '../src/renderer/remote/RemoteSection'
import { formatChord } from '../src/renderer/keymap'
import { detectPlatform, machineNoun, type UiPlatform } from '../src/renderer/platform'

/**
 * HARNESS — everything the app says that used to assume a Mac.
 *
 * This is a fixture page, not a screen in the product. It exists because the
 * four places that had Apple glyphs typed into them, and the remote panel's
 * "this Mac" sentences, are spread across four screens and three states that
 * are awkward to reach at once — and because the whole point of the change is
 * that the *reader's* platform decides the words. Opened on Windows this page
 * answers Windows, from the same components the app renders; opened on a Mac it
 * answers Mac. Nothing here is invented: every string comes out of the real
 * component or the real formatter.
 *
 * The banner at the top says what platform was detected, so a screenshot of
 * this page is self-describing rather than something to be taken on trust.
 */

const NOW = Date.now()

const REMOTE_STATE = {
  running: true,
  url: 'https://example-host.taile59277.ts.net:8443',
  address: '100.86.107.119',
  reason: null,
  directReason: null,
  relay: {
    url: 'wss://relay.terminaldeck.dev',
    hostId: 'AXGK7VAEYZHKTTVUKZ4U9HZQ7J',
    publicKey: 'Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhmb29iYXI',
    fingerprint: 'K7QM-3XTB-9WHD-2PVJ-6RNY-4CFG',
    connected: true,
    channels: 1,
    reason: null,
    retryAt: null,
  },
  devices: [
    {
      id: 'dev-1',
      name: 'HARNESS phone (fixture)',
      state: 'pending' as const,
      addedAt: NOW - 60_000,
      lastSeenAt: NOW - 5_000,
      fingerprint: 'H4TC-8MKD-2QWX-7BNP-5ZRJ-9VFY',
    },
  ],
  connections: [
    {
      id: 'conn-1',
      deviceId: 'dev-1',
      deviceName: 'HARNESS phone (fixture)',
      platform: 'iOS 26',
      address: 'relay:8Kd2Nq4Rt7Vw1Yb3',
      connectedAt: NOW - 12 * 60_000,
      sessionIds: ['s1'],
      tunnels: [{ id: 'tun-1', port: 5173, streams: 3, openedAt: NOW - 4 * 60_000 }],
    },
  ],
}

const NO_ACTIONS = {
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

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section style={{ marginBottom: 28 }}>
      <h2 style={{ font: '600 13px/1.4 var(--font-ui)', letterSpacing: '.04em', textTransform: 'uppercase', color: 'var(--text-faint)', margin: '0 0 10px' }}>
        {title}
      </h2>
      <div style={{ border: '1px solid var(--line)', borderRadius: 12, padding: 16, background: 'var(--surface)' }}>
        {children}
      </div>
    </section>
  )
}

function Harness() {
  const detected = detectPlatform()
  const [theme, setTheme] = useState<'dark' | 'light'>(
    (document.documentElement.dataset.theme as 'dark' | 'light') ?? 'dark',
  )
  const flip = () => {
    const next = theme === 'dark' ? 'light' : 'dark'
    document.documentElement.dataset.theme = next
    setTheme(next)
  }

  return (
    <div style={{ padding: 24, maxWidth: 920, margin: '0 auto', color: 'var(--text)' }}>
      <p
        data-testid="detected"
        style={{ font: '600 15px/1.5 var(--font-ui)', padding: '10px 14px', borderRadius: 10, background: 'var(--accent-soft, rgba(120,140,255,.14))', marginBottom: 6 }}
      >
        HARNESS FIXTURE · detected platform: <code>{detected}</code> · machine noun:{' '}
        <code>{machineNoun(detected)}</code> · <code>{navigator.userAgent}</code>
      </p>
      <p style={{ font: '400 12px/1.5 var(--font-ui)', color: 'var(--text-faint)', marginBottom: 18 }}>
        Not a screen in the product. Every string below is rendered by the real component or the
        real formatter, with the platform read from this browser.{' '}
        <button type="button" onClick={flip} style={{ font: 'inherit' }}>
          Switch to {theme === 'dark' ? 'light' : 'dark'}
        </button>
      </p>

      <Panel title="Empty state (was ⌘ O / ⌘ T, hand-typed)">
        <EmptyState onOpenProject={() => {}} />
      </Panel>

      <Panel title="Find bar tooltips (were ⇧↩ and ↩)">
        <ul data-testid="find-tips" style={{ font: '400 14px/1.9 var(--font-ui)', margin: 0, paddingLeft: 18 }}>
          <li>Previous match ({formatChord('shift+enter')})</li>
          <li>Next match ({formatChord('enter')})</li>
        </ul>
      </Panel>

      <Panel title="Remote access (was “this Mac”, 11 sentences)">
        <div className="settings-body" style={{ maxWidth: 760 }}>
          <RemoteView
            state={REMOTE_STATE}
            wired
            problem={null}
            notice={null}
            pairing={{ token: 'harness-token', expiresAt: NOW + 60_000 }}
            secondsLeft={42}
            busy={null}
            confirmEnable
            pairPath={null}
            actions={NO_ACTIONS}
            now={NOW}
          />
        </div>
      </Panel>

      <Panel title="Shortcuts sheet (already platform-correct; here for comparison)">
        <div className="shortcuts">
          <ShortcutsList />
        </div>
      </Panel>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
