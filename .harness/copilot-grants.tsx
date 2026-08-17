/**
 * Look at the copilot-grant panel without Electron, in every state that matters.
 *
 *     npx vite --config .harness/vite.config.ts
 *     open http://localhost:5199/copilot-grants.html
 *
 * `DeviceCopilotView` takes everything it draws, so each state below is a
 * fixture rather than a sequence of clicks — which is the only way to see the
 * states that need a paired device, a store on disk and a failed write to reach
 * for real.
 *
 * Mounted inside the same `.settings` / `.settings-panel` wrapper the real
 * window uses, at the real width, because the defects this page exists to catch
 * are wrapping and alignment ones that only appear at 690px: the third row's
 * two-line description beside a checkbox, and a device name long enough to
 * fight the summary beside it.
 *
 * Both themes, one under the other. Neither is the "real" one and a colour
 * defined only inside `[data-theme='dark']` is a bug this page shows in one
 * scroll.
 */
import { createRoot } from 'react-dom/client'
import {
  DeviceCopilotView,
  type CopilotAccess,
  type CopilotDevice,
  type DeviceCopilotViewProps,
} from '../src/renderer/remote/DeviceCopilot'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'

const PHONE: CopilotDevice = { id: 'dev-1', name: 'Asad’s iPhone', sealed: true }
const TABLET: CopilotDevice = { id: 'dev-2', name: 'iPad mini', sealed: true }
/** A name long enough to fight the summary beside it. That is the point of it. */
const LONG: CopilotDevice = { id: 'dev-3', name: 'MacBook Pro in the other room', sealed: true }
const OLD: CopilotDevice = { id: 'dev-4', name: 'Old iPhone (paired 2025)', sealed: false }

function grants(entries: Array<[string, CopilotAccess]>): Map<string, CopilotAccess> {
  return new Map(entries)
}

interface Scene {
  title: string
  props: Partial<DeviceCopilotViewProps>
}

const SCENES: Scene[] = [
  {
    title: 'The ordinary state — every device off, which is what a real machine starts in',
    props: { devices: [PHONE, TABLET], grants: grants([]) },
  },
  {
    title: 'One watching, one working — the two grants side by side',
    props: {
      devices: [PHONE, TABLET],
      grants: grants([
        ['dev-1', { read: true, act: false }],
        ['dev-2', { read: true, act: true }],
      ]),
    },
  },
  {
    title: 'Before the first read lands — says “Reading…”, never “No access”',
    props: { devices: [PHONE, TABLET], grants: null },
  },
  {
    title: 'A write in flight on the first device',
    props: { devices: [PHONE, TABLET], grants: grants([['dev-1', { read: true, act: false }]]), busy: 'dev-1' },
  },
  {
    title: 'A write that failed — what is on screen may be stale',
    props: {
      devices: [PHONE, TABLET],
      grants: grants([['dev-1', { read: true, act: false }]]),
      problem: 'Could not save that. The copilot access is unchanged.',
    },
  },
  {
    title: 'A long device name, and a device with no key',
    props: { devices: [LONG, OLD], grants: grants([['dev-3', { read: true, act: true }]]) },
  },
  {
    title: 'Nothing approved yet',
    props: { devices: [], grants: grants([]) },
  },
  {
    title: 'A build with no copilot channels — no dead boxes anywhere',
    props: { devices: [PHONE], grants: grants([]), wired: false },
  },
]

function Panel({ scene }: { scene: Scene }) {
  return (
    <div style={{ marginBottom: 26 }}>
      <p style={{ color: 'var(--text-muted)', fontSize: 12, margin: '0 0 8px' }}>{scene.title}</p>
      {/*
        The panel's own ground, not the board's.

        A device card is `--bg-secondary`, which is also what a bare harness
        board is — so on that ground the fill is invisible and the list reads as
        flat text with no grouping at all. That is a false picture of the panel
        in the one respect this page exists to check. In the real window the
        panel sits on `--bg-primary`, so this reproduces it, exactly as
        `remote.tsx` does for the same reason.
      */}
      <div
        style={{
          background: 'var(--bg-primary)',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius-lg)',
          padding: '16px 20px',
        }}
      >
      <div className="settings" style={{ maxWidth: 690 }}>
        {/*
          The rail's placeholder, and it is not decoration.

          `.settings` is a two-column grid — `var(--settings-rail) minmax(0, 1fr)`
          — so a panel dropped in as the only child lands in the *first* column
          and renders 196px wide, wrapping every sentence into a ribbon. Which is
          exactly what the first screenshot of this page showed, and exactly the
          kind of thing that looks like a component bug and is not. `remote.tsx`
          carries the same empty div for the same reason.
        */}
        <div />
        <div className="settings-panel">
          <DeviceCopilotView
            devices={[PHONE]}
            grants={new Map()}
            wired={true}
            problem={null}
            busy={null}
            onChange={() => {}}
            platform="mac"
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
