/**
 * The copilot page's machine switch, in every state a row can be in.
 *
 * Asad, 2026-08-20, on this switch: *"here icon not still choose the local
 * connected server, by the way, I think. Maybe server is not connected, I don't
 * know."* Two complaints in one sentence — he could not **choose** the machine,
 * and he could not tell whether it was **connected**. A round of this answered
 * the second by greying the row out and putting the reason on hover, which
 * answers the first by taking the choice away.
 *
 * So the switch has no `disabled` in it any more, and the three panes below are
 * the three answers a press can land on. Press the rows: the page below the
 * switch changes for every one of them, which is the whole claim.
 *
 * The App harness (`index.html`) covers the other half — the window's bar over
 * a chosen machine — because that half is `App.tsx` and cannot be seen here.
 */
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { CopilotMachines } from '../src/renderer/copilot/CopilotMachines'
import { RemoteCopilot } from '../src/renderer/copilot/RemoteCopilot'
import type { CopilotMachine } from '../src/renderer/copilot/useCopilotMachines'
import '../src/renderer/copilot/copilot.css'

/** This Mac, a PC that is up, a PC that is asleep, and one that made us a guest. */
const MACHINES: CopilotMachine[] = [
  { id: '', name: 'this Mac', reach: 'ready', open: true },
  { id: 'm1', name: 'office-pc', reach: 'ready', open: true },
  { id: 'm2', name: 'studio-pc', reach: 'unreachable', open: false },
  { id: 'm3', name: 'shared-mini', reach: 'refused', open: false },
]

/** Enough of the bridge to reach the states; nothing here answers with a run. */
const bridge = {
  attachMachineCopilot: async () => ({ ok: true, message: '' }),
  startMachineCopilot: async () => ({ ok: true, message: '' }),
  sayToMachineCopilot: async () => ({ ok: true, message: '' }),
  onMachineCopilotChat: () => () => {},
  onMachineCopilotState: (cb: (machineId: string, state: unknown) => void) => {
    // The state frame a settled attach brings back, so the reachable machine
    // lands on its Start rather than sitting on "Reaching…" forever.
    setTimeout(() => cb('m1', { desk: 'running', run: null }), 200)
    return () => {}
  },
}

function Page() {
  const [chosen, setChosen] = useState('')
  const machine = MACHINES.find((row) => row.id === chosen) ?? MACHINES[0]!
  return (
    <div className="copilot-page" data-visible={true} style={{ height: '100vh' }}>
      <CopilotMachines machines={MACHINES} chosen={chosen} onChoose={setChosen} />
      <div className="cp-body">
        {machine.id === '' ? (
          <div style={{ padding: 24, color: 'var(--text-secondary)' }}>
            (this computer — the real page draws its terminal here)
          </div>
        ) : (
          <RemoteCopilot
            key={machine.id}
            machineId={machine.id}
            machineName={machine.name}
            reach={machine.reach}
            open={machine.open}
            bridge={bridge}
          />
        )}
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
