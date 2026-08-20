/**
 * The rail with five sessions open on **one** paired machine, in one folder.
 *
 * The state has no answer in a static render and it is on his screen in the
 * recording: five rows that are the same word and then the same twenty-six
 * character machine id, because `shortSessionId` cuts a tab id at its first
 * hyphen and a remote tab's id is `machine <ULID> <n>`, which has none. What
 * separates these rows is the far machine's own session id, which is what that
 * machine calls them.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/shell/shell.css'
import { Sidebar } from '../src/renderer/shell/Sidebar'
import { machineTabId, type WorkspaceTab } from '../src/renderer/shell/workspace-tabs'

const MACHINE = { id: 'Q5JE8FAG53PML2W3VU9V3QTZ2U', name: 'MacBookPro' }

const remote: WorkspaceTab[] = [1, 2, 3, 4, 5].map((n) => ({
  id: machineTabId(MACHINE.id, String(n)),
  kind: 'session',
  label: 'terminaldeck',
  status: 'idle',
  projectPath: '/Users/apple/Projects/terminaldeck',
  machine: MACHINE,
  closable: true,
}))

function Harness() {
  const [active, setActive] = useState(remote[0].id)
  return (
    <div style={{ display: 'flex', height: '100vh', background: 'var(--bg-app)' }}>
      <Sidebar
        width={264}
        projects={[]}
        tabs={remote}
        machines={[{ machineId: MACHINE.id, name: MACHINE.name, sessions: remote, canClose: true }]}
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
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
