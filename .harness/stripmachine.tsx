/**
 * The top bar with a browser window that is **not on this computer**.
 *
 * `strip.tsx` is the bar's own page and measures widths; this one exists for a
 * single question that has no answer in a static render: does the strip say
 * which machine a browser window is on? Until 2026-08-20 it did not, and the
 * fact lived only inside two native menus you had to open. *"Now I don't know
 * if it is actually there or here."*
 *
 * The store is seeded directly rather than through `BrowserWorkspace`, which is
 * the honest way to test the consumer: the panel's job is to publish, this
 * page's job is to prove the strip draws what was published.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/shell/shell.css'
import { WorkspaceTabStrip } from '../src/renderer/browser/WorkspaceTabStrip'
import { setWindowMachine } from '../src/renderer/browser/window-machine'
import { setBindings } from '../src/renderer/browser/binding-view'
import { machineTabId, type WorkspaceTab } from '../src/renderer/shell/workspace-tabs'

const params = new URLSearchParams(location.search)
if (params.get('theme') === 'light') document.documentElement.dataset.theme = 'light'

const OFFICE = { id: 'mach-1', name: 'Office PC' }

const TABS: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Session 1', status: 'working', projectPath: '/Users/apple/Templates', closable: true },
  { id: 'b1', kind: 'browser', label: 'New tab', closable: true },
  { id: 'b2', kind: 'browser', label: 'localhost:5199', closable: true },
  { id: 'b3', kind: 'browser', label: 'Stripe Dashboard', closable: true },
  /*
    A session on the same machine one of the windows is served by — which is the
    whole of what he asked to be able to see in one place: *"all the desktop
    browser, including session, should be at one place."* Without it this page
    proves only that a window can be labelled, not that a machine's two kinds of
    window are drawn together.
  */
  { id: machineTabId(OFFICE.id, '7'), kind: 'session', label: 'Session 1', status: 'idle', projectPath: '/Users/apple/Projects/site', machine: OFFICE, closable: true },
]

// b2 is the one on the other machine. b1 and b3 are here, and must wear nothing.
setWindowMachine('b2', OFFICE)
setBindings({
  sessions: [
    {
      sessionId: 's1',
      machineId: '',
      colour: 0,
      ended: false,
      windows: [{ n: 1, browserTabId: 'b2', url: 'http://127.0.0.1:5199/', title: 'localhost:5199' }],
    },
  ],
})

function seededStorage(): Storage {
  const held = new Map<string, string>([
    ['terminaldeck.strip.promoted', JSON.stringify(TABS.map((tab) => tab.id))],
  ])
  return {
    get length() {
      return held.size
    },
    clear: () => held.clear(),
    getItem: (key: string) => held.get(key) ?? null,
    key: (index: number) => [...held.keys()][index] ?? null,
    removeItem: (key: string) => void held.delete(key),
    setItem: (key: string, value: string) => void held.set(key, value),
  }
}

function Harness() {
  const [store] = useState(seededStorage)
  const [active, setActive] = useState<string | null>('b2')
  return (
    <div style={{ height: '100vh', background: 'var(--bg-primary)' }}>
      <WorkspaceTabStrip
        tabs={TABS}
        activeTabId={active}
        onSelect={setActive}
        onShowInstead={setActive}
        onCloseWindow={() => {}}
        onNewSession={() => {}}
        onNewBrowserTab={() => {}}
        storage={store}
      />
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
