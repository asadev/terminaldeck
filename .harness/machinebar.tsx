/**
 * The three states of "which computer is this page on", side by side.
 *
 * `toolbar.tsx` measures the bar; this page is about one chip on it. Asad,
 * having moved a window to his PC and then navigated it somewhere else:
 *
 * > *"Maybe in this kind of situation, we will need to keep this so we know
 * > actually where it is running right now, or it should be unsuccessful here
 * > also, because we always need a truth. So we will not know the truth if we
 * > remove from inside where it is exactly running. So just be sure we always be
 * > able to see the truth."*
 *
 * The failure that shipped was that the chip appeared for a tunnelled page and
 * *disappeared* otherwise, so a window whose picker read `Office PC` and whose
 * page was being fetched by this Mac said so only by an element not being there.
 * Three rows, then, because the rule is about the relationship between two
 * controls and cannot be judged from one of them:
 *
 *  1. picker here, page here — the field is only the link, which is the other
 *     thing he asked for in the same minute.
 *  2. picker there, page there, same port — nothing, because the picker says the
 *     machine and the address says the port; a name in both places a centimetre
 *     apart is the duplication he struck out for `local`.
 *  3. picker there, page there, a *different* port — the origin port alone, the
 *     one fact neither of the other two controls can say.
 *  4. picker there, page here — the disagreement, said out loud.
 */
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/browser/BrowserWorkspace.css'
import { Toolbar } from '../src/renderer/browser/Toolbar'
import { MachinePicker } from '../src/renderer/browser/MachinePicker'
import { THIS_MACHINE, type MachineChoice } from '../src/renderer/browser/machines-bridge'
import type { ServedBy } from '../src/renderer/browser/served-mark'
import { newTab } from '../src/renderer/browser/tabs'
import { Tooltips } from '../src/renderer/shell/Tooltips'
import '../src/renderer/shell/tooltip.css'

const params = new URLSearchParams(location.search)
if (params.get('theme') === 'light') document.documentElement.dataset.theme = 'light'

const MACHINES: MachineChoice[] = [
  { kind: 'desktop', id: 'office-pc', name: 'Office PC', noun: 'PC', ports: [3000, 5199], refusal: null },
] as unknown as MachineChoice[]

function tabAt(url: string) {
  return { ...newTab('tab-1', url), url, canGoBack: true, canGoForward: false }
}

interface Row {
  label: string
  url: string
  selected: string
  served: ServedBy | null
}

const ROWS: Row[] = [
  {
    label: 'picker: this machine · page: this machine',
    url: 'http://localhost:3000/orders',
    selected: THIS_MACHINE,
    served: null,
  },
  {
    label: 'picker: Office PC · page: Office PC (tunnelled, same port)',
    url: 'http://127.0.0.1:5199/orders',
    selected: 'office-pc',
    served: { name: 'Office PC', port: 5199, localPort: 5199, sameNumber: true, agrees: true },
  },
  {
    label: 'picker: Office PC · page: Office PC (tunnel took another port)',
    url: 'http://127.0.0.1:53412/orders',
    selected: 'office-pc',
    served: { name: 'Office PC', port: 5199, localPort: 53412, sameNumber: false, agrees: true },
  },
  {
    label: 'picker: Office PC · page: fetched HERE',
    url: 'http://example.com/',
    selected: 'office-pc',
    served: { name: 'This machine', port: null, localPort: 0, sameNumber: true, agrees: false },
  },
]

function Bar({ row }: { row: Row }) {
  const tab = tabAt(row.url)
  return (
    <div style={{ marginBottom: 18 }}>
      <div style={{ font: '11px/1.6 ui-monospace, monospace', opacity: 0.7, padding: '2px 6px' }}>
        {row.label}
      </div>
      <div className="bw" style={{ width: 1040, height: 'auto' }}>
        <Toolbar
          tab={tab}
          security={row.url.startsWith('http://example') ? 'insecure' : 'local'}
          progress={1}
          resolution={{ kind: 'url', url: tab.url, display: tab.url }}
          focusToken={0}
          onDraft={() => {}}
          onEditing={() => {}}
          onSubmit={() => {}}
          onBack={() => {}}
          onForward={() => {}}
          onReload={() => {}}
          onStop={() => {}}
          onHome={() => {}}
          onInspect={() => {}}
          onRecord={() => {}}
          onScreenshot={() => {}}
          onDevtools={() => {}}
          devtoolsOpen={false}
          recording={false}
          onDraw={() => {}}
          drawing={false}
          deviceOpen={false}
          onToggleDevice={() => {}}
          onMenu={() => {}}
          menuOpen={false}
          profileName="Default"
          steps={0}
          machinePicker={
            <MachinePicker machines={MACHINES} selected={row.selected} onSelect={() => {}} />
          }
          servedBy={row.served}
        />
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div style={{ padding: 16, background: 'var(--bg-primary)', minHeight: '100vh' }}>
      {ROWS.map((row) => (
        <Bar key={row.label} row={row} />
      ))}
      <Tooltips />
    </div>
  </StrictMode>,
)
