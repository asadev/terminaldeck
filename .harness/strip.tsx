/**
 * The top bar, looked at rather than asserted.
 *
 * Three things about the strip can only be judged by rendering it, and all
 * three came out of Asad's 2026-08-20 review: whether the two openers still
 * collide with the last tab when the bar is full (they did — `?tabs=11`),
 * whether every tab really is the same width (they were not — `?tabs=6` and a
 * long name), and — the one that matters most — whether pressing the ✕ on a
 * session tab leaves that session in the rail. If it vanished from both panels
 * the press would look exactly like a kill, which is the one thing it is not.
 *
 * None of that is reachable from the vitest run: there is no layout engine
 * there, so "the same width" is only ever pinned as the CSS declarations that
 * should produce it. This page is where the produced widths are read.
 *
 * `?tabs=N` sets how many, `?theme=light` flips the theme, and the readout at
 * the bottom prints every tab's measured width — so a screenshot of this page
 * carries the answer without anybody having to trust a ruler.
 */
import './stub'
import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
// The rail's own sheet. `App.tsx` pulls it in, and without it the sidebar here
// renders as a bare list — which looks like a defect and is only a missing import.
import '../src/renderer/shell/shell.css'
import { WorkspaceTabStrip } from '../src/renderer/browser/WorkspaceTabStrip'
import { Sidebar } from '../src/renderer/shell/Sidebar'
import { ModeSwitch } from '../src/renderer/shell/ModeSwitch'
import type { WorkspaceTab } from '../src/renderer/shell/workspace-tabs'

const params = new URLSearchParams(location.search)
const COUNT = Number(params.get('tabs') ?? 6)
if (params.get('theme') === 'light') document.documentElement.dataset.theme = 'light'

/**
 * A mixed bar: sessions with accounts and long agent names, browser windows,
 * a copilot. The point is the variety — a row of identical "Session 1" tabs
 * would look uniform whatever the stylesheet said.
 */
function tabsFor(count: number): WorkspaceTab[] {
  const pool: WorkspaceTab[] = [
    { id: 's1', kind: 'session', label: 'Claude Code v2.1.236', status: 'working', projectPath: '/Users/apple/Templates', closable: true, account: { id: 'a1', name: 'sherzod.davlatov@gmail.com', provider: 'claude' } },
    { id: 's2', kind: 'session', label: 'Session 2', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
    { id: 'b1', kind: 'browser', label: 'New tab', closable: true },
    { id: 's3', kind: 'session', label: 'Session 3', status: 'input', projectPath: '/Users/apple/Projects/terminaldeck', closable: true },
    { id: 's4', kind: 'session', label: 'Fix the parser in the reader', status: 'working', projectPath: '/Users/apple/Projects/terminaldeck', closable: true },
    { id: 'b2', kind: 'browser', label: 'Sign in — iMatch Support', closable: true },
    { id: 's5', kind: 'session', label: 'Session 5', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
    { id: 's6', kind: 'session', label: 'Session 6', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
    { id: 'b3', kind: 'browser', label: 'localhost:5173', closable: true },
    { id: 's7', kind: 'session', label: 'Session 7', status: 'exited', projectPath: '/Users/apple/Templates', closable: true },
    { id: 's8', kind: 'session', label: 'Session 8', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
    { id: 's9', kind: 'session', label: 'Session 9', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
  ]
  return pool.slice(0, Math.max(1, Math.min(count, pool.length)))
}

/**
 * A promoted order holding every tab, because that is what the real window has.
 *
 * Without it the strip draws browser windows (which are always present since
 * 2026-08-20) plus whichever session is active, and nothing else — correct
 * behaviour, and useless for looking at a full bar. `App.tsx` promotes a
 * session as it opens it; this stands in for that.
 */
function seededStorage(tabs: readonly WorkspaceTab[]): Storage {
  const held = new Map<string, string>([
    ['terminaldeck.strip.promoted', JSON.stringify(tabs.map((tab) => tab.id))],
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
  const tabs = tabsFor(COUNT)
  const [store] = useState(() => seededStorage(tabs))
  const [active, setActive] = useState(tabs[0]?.id ?? null)
  const [widths, setWidths] = useState<string>('')

  /* Measured after paint, printed on the page, so the screenshot is the proof. */
  useEffect(() => {
    const id = setTimeout(() => {
      const found = [...document.querySelectorAll('[data-strip-tab]')].map((node) => {
        const box = node.getBoundingClientRect()
        return `${node.getAttribute('data-tab-id')}=${box.width.toFixed(1)}`
      })
      /*
       * The rail's edge against the corner's, not the last tab's against it.
       * The last tab can sit past the corner and be perfectly fine, because
       * once the strip is full the rail scrolls and clips its own contents —
       * measuring the tab was measuring the scroll position.
       */
      const openers = document.querySelector('.strip-openers')?.getBoundingClientRect()
      const rail = document.querySelector('.strip-rail')?.getBoundingClientRect()
      const clearance = openers && rail ? (openers.left - rail.right).toFixed(1) : 'n/a'
      const railEl = document.querySelector('.strip-rail')
      const scrolls = railEl ? railEl.scrollWidth > railEl.clientWidth : false
      const unique = new Set(found.map((entry) => entry.split('=')[1])).size
      setWidths(
        `${found.join('  ')}\ndistinct widths: ${unique}   rail → corner clearance: ${clearance}px   rail scrolls: ${scrolls}`,
      )
    }, 250)
    return () => clearTimeout(id)
  }, [])

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', background: 'var(--bg-primary)' }}>
      <WorkspaceTabStrip
        tabs={tabs}
        activeTabId={active}
        onSelect={setActive}
        /* The session ✕. It takes the tab off the bar and nothing else, which is
           the half of the 2026-08-20 rule that can only be judged by looking:
           press it and the session must still be in the rail below. */
        onShowInstead={setActive}
        onCloseWindow={(id) => console.log('close window', id)}
        onNewSession={() => console.log('new session')}
        onNewBrowserTab={() => console.log('new browser tab')}
        storage={store}
      />
      <div
        style={{
          display: 'flex',
          justifyContent: 'flex-end',
          gap: 12,
          padding: '8px 12px',
          borderBottom: '1px solid var(--border-subtle)',
        }}
      >
        <ModeSwitch mode="terminal" onChange={() => {}} />
        <ModeSwitch mode="chat" onChange={() => {}} />
        <ModeSwitch mode="split" view="chat" onChange={() => {}} />
      </div>
      {/*
        The rail beside the bar, because the 2026-08-20 change is a rule about
        *both* panels and only shows as one: a browser window belongs on the
        strip and nowhere else. Looking at either half alone would miss the two
        ways to get it wrong — a page listed twice, or a page listed nowhere.
      */}
      <div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
        <Sidebar
          width={230}
          projects={[
            { path: '/Users/apple/Templates', name: 'Templates' },
            { path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' },
          ]}
          tabs={tabs}
          activeTabId={active}
          activePanel={null}
          panels={[]}
          alerts={false}
          alertCount={0}
          unread={[]}
          held={[]}
          heldRetrying={[]}
          onRetryHeld={() => {}}
          onForgetHeld={() => {}}
          peeking={false}
          update={null}
          onSelectTab={setActive}
          onCloseTab={(id) => console.log('close from rail', id)}
          onSelectPanel={() => {}}
          onNewSession={() => {}}
          onNewBrowserTab={() => {}}
          onOpenProject={() => {}}
          onCloseProject={() => {}}
          onOpenSettings={() => {}}
          onOpenAlerts={() => {}}
          onToggleCollapsed={() => {}}
          onPeekStart={() => {}}
          onPeekEnd={() => {}}
          onStartResize={() => {}}
          storage={null}
        />
        <pre
          id="widths"
          style={{
            flex: 1,
            margin: 0,
            padding: 12,
            font: '12px ui-monospace, monospace',
            color: 'var(--text-secondary)',
            whiteSpace: 'pre-wrap',
          }}
        >
          {widths}
        </pre>
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
