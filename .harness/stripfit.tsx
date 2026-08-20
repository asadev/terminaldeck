/**
 * The top bar when there is not enough room for what is on it.
 *
 * One question, and it is the one a static render answers and a unit test
 * cannot: with two browser windows attached to a session whose tab has been
 * squeezed, does the tab still say there are two? `BindChip`'s `useChipFit`
 * drops whole chips into a `+N` count as the tab narrows, and the count is the
 * only thing on screen saying a window was dropped — so if the count is itself
 * clipped, the bar shows `B1` and silently loses `B2` while the rail beside it
 * shows both. *"we always need a truth."*
 *
 * `?tabs=N` sets how many tabs share the bar; the readout under it prints each
 * tab's measured width and what the chip box actually contains, so a screenshot
 * of this page carries the answer.
 */
import './stub'
import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/shell/shell.css'
import { WorkspaceTabStrip } from '../src/renderer/browser/WorkspaceTabStrip'
import { Sidebar } from '../src/renderer/shell/Sidebar'
import { setBindings } from '../src/renderer/browser/binding-view'
import type { WorkspaceTab } from '../src/renderer/shell/workspace-tabs'

const params = new URLSearchParams(location.search)
const COUNT = Number(params.get('tabs') ?? 7)
if (params.get('theme') === 'light') document.documentElement.dataset.theme = 'light'

const POOL: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Update Claude Code terminal to new API', status: 'working', projectPath: '/Users/apple/Projects/terminaldeck', closable: true },
  { id: 's2', kind: 'session', label: 'Session 2', status: 'idle', projectPath: '/Users/apple/Projects/terminaldeck', closable: true },
  { id: 's3', kind: 'session', label: 'Fix the parser in the reader', status: 'input', projectPath: '/Users/apple/Templates', closable: true },
  { id: 'b1', kind: 'browser', label: 'Stripe Dashboard — Payments overview', closable: true },
  { id: 's4', kind: 'session', label: 'Session 4', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
  { id: 'b2', kind: 'browser', label: 'localhost:5173 — Terminal Deck harness', closable: true },
  { id: 's5', kind: 'session', label: 'Session 5', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
  { id: 's6', kind: 'session', label: 'Session 6', status: 'idle', projectPath: '/Users/apple/Templates', closable: true },
  /*
   * Two windows opened from the globe and nothing else — both called `New tab`,
   * which is a name collision, which is what used to send the qualifier ladder
   * all the way down to the id. A browser id is `browser:<epoch>:<seq>` and
   * `shortSessionId` has no hyphen to cut at, so the tab printed
   * **browser:1787199912** beside the name and cut the name to make room for it.
   * They are last so `?tabs=10` is the page that shows the pair.
   */
  { id: 'browser:1787199912:1', kind: 'browser', label: 'New tab', closable: true },
  { id: 'browser:1787199912:2', kind: 'browser', label: 'New tab', closable: true },
]

const TABS = POOL.slice(0, Math.max(1, Math.min(COUNT, POOL.length)))

setBindings({
  sessions: [
    {
      sessionId: 's1',
      machineId: '',
      colour: 0,
      ended: false,
      windows: [
        { n: 1, browserTabId: 'b1', url: 'https://dashboard.stripe.com/', title: 'Stripe Dashboard' },
        { n: 2, browserTabId: 'b2', url: 'http://localhost:5173/', title: 'localhost:5173' },
      ],
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
  const [active, setActive] = useState<string | null>('s1')
  const [readout, setReadout] = useState('')

  useEffect(() => {
    const id = setTimeout(() => {
      const tab = document.querySelector('[data-strip-tab][data-tab-id="s1"]')
      const chips = tab?.querySelector('.bind-chips') as HTMLElement | null
      const rail = tab?.closest('.strip-rail')
      const railChips = document.querySelector('.sb-row .bind-chips') as HTMLElement | null
      setReadout(
        [
          `s1 tab width: ${tab?.getBoundingClientRect().width.toFixed(1)}`,
          `strip chips text: ${JSON.stringify(chips?.innerText ?? null)}`,
          `strip chips box: ${chips ? `${chips.clientWidth.toFixed(1)} client / ${chips.scrollWidth.toFixed(1)} scroll` : 'none'}`,
          `sidebar chips text: ${JSON.stringify(railChips?.innerText ?? null)}`,
          `rail scrolls: ${rail ? rail.scrollWidth > rail.clientWidth : 'n/a'}`,
        ].join('\n'),
      )
    }, 400)
    return () => clearTimeout(id)
  }, [])

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', background: 'var(--bg-primary)' }}>
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
      <div style={{ display: 'flex', flex: 1, minHeight: 0 }}>
        <Sidebar
          width={230}
          projects={[
            { path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' },
            { path: '/Users/apple/Templates', name: 'Templates' },
          ]}
          tabs={TABS}
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
          onCloseTab={() => {}}
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
        <pre style={{ flex: 1, margin: 0, padding: 12, font: '12px ui-monospace, monospace', color: 'var(--text-secondary)', whiteSpace: 'pre-wrap' }}>
          {readout}
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
