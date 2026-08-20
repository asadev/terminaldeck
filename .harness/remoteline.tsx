/**
 * The title line and the control cluster over a session on **another machine**,
 * in a real browser.
 *
 *     npx vite --config .harness/vite.config.ts --port 5199
 *     open http://localhost:5199/remoteline.html
 *
 * Why this page exists rather than a static-markup test: both of the things the
 * 2026-08-20 review asked for here are invisible in a string.
 *
 *  - **A shut popover renders nothing at all.** The account chip's rows, the
 *    tick beside the login in force, and the connector list are all inside
 *    menus; a static render of this bar is a row of chips with no evidence that
 *    anything is behind them. `controls.tsx` says the same thing about the row
 *    beside it and exists for the same reason.
 *  - **Which chips are there.** Asad, on a session running on his PC: *"on the
 *    remote sessions, I don't have any of these features … I want it exactly
 *    like the local ones."* That is a claim about what is on the bar, and the
 *    only honest way to answer it is a picture of the bar.
 *
 * Everything below is fed through the **real** bridge names — `readMachineControls`
 * and `readMachineAccount` — carrying the **wire shapes** those channels
 * actually return, so what is drawn is drawn from what a paired machine sends.
 * `?old` is the other machine this has to be honest about: a build that predates
 * the two capabilities, which answers nothing and must degrade in silence.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/components/ChatComposer.css'
// The bar's own layout. `App.tsx` is what pulls this in inside the app; a
// harness page loads only what it reaches, and without it `.toolbar` is not a
// flex row and the heading, the chips and the cluster stack on top of each other.
import '../src/renderer/shell/shell.css'
import '../src/renderer/machines/machines.css'
import { WindowToolbar } from '../src/renderer/shell/WindowToolbar'
import { SessionControls } from '../src/renderer/shell/SessionControls'
import { FolderTitle } from '../src/renderer/shell/FolderChip'
import { MachineAccountChip } from '../src/renderer/machines/MachineAccountChip'
import type { MachineAccount } from '../src/renderer/machines/machine-account'

const query = new URLSearchParams(location.search)
/** A machine whose build predates `controls`' connectors and `account` outright. */
const old = query.has('old')

const SESSION = 'a1b2c3d4-5e6f-4071-8293-a4b5c6d7e8f9'
const MACHINE = 'office-pc'
const CWD = 'C:\\Users\\Imza\\Projects\\terminaldeck'

/** The far machine's own `mcp:list`, as `ControlsReadingWire.connectors` carries it. */
const CONNECTORS = [
  { id: 'user:github', name: 'github', scope: 'user', transport: 'stdio', enabled: true, disabledReason: null },
  { id: 'project:playwright', name: 'playwright', scope: 'project', transport: 'stdio', enabled: true, disabledReason: null },
  {
    id: 'user:figma',
    name: 'figma',
    scope: 'user',
    transport: 'http',
    enabled: false,
    disabledReason: 'Not approved for this project',
  },
]

/** What that machine's `controls.read` answers for a live Claude session. */
const READING = {
  model: { value: 'opus-5', label: 'Opus 5', source: 'screen' },
  effort: { value: 'xhigh', label: 'Extra high', source: 'screen' },
  fast: { value: 'off', label: 'Off', source: 'screen' },
  permission: { value: 'bypassPermissions', label: 'Bypass', source: 'screen' },
  live: true,
  agent: { running: true, saw: 'Claude Code' },
  gate: { canType: true, reason: null },
  ...(old ? {} : { connectors: CONNECTORS }),
}

/** And what its `account.read` answers — `AccountWire`, field for field. */
const ACCOUNTS: MachineAccount[] = [
  { id: 'system', name: 'Default', provider: 'claude', color: '--acct-1', system: true },
  { id: 'app-imatch-ae', name: 'app.imatch.ae@gmail.com', provider: 'claude', color: '--acct-3', system: false },
  { id: 'school-asadiqbal', name: 'school.asadiqbal@gmail.com', provider: 'claude', color: '--acct-5', system: false },
  { id: 'system:codex', name: 'Codex CLI', provider: 'codex', color: '--acct-2', system: true },
]

const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck
deck.readMachineControls = async () => READING
deck.applyMachineControl = async () => ({ ok: true, message: 'Model is now Sonnet 5.', reading: READING.model })
deck.readMachineAccount = async () =>
  old ? null : { current: ACCOUNTS[1], accounts: ACCOUNTS }
deck.switchMachineAccount = async () => ({
  ok: false,
  // The far machine's own sentence, which is what the line under the chip prints.
  message: 'That account has never signed in on this computer.',
  session: SESSION,
})
deck.onMachineOutput = () => () => undefined

function Board({ width, label }: { width: number; label: string }) {
  const [account, setAccount] = useState<MachineAccount | null>(old ? null : ACCOUNTS[1])
  const [problem, setProblem] = useState<string | null>(null)
  return (
    <section style={{ marginBottom: 28 }}>
      <p style={{ font: '12px/1.4 ui-monospace, monospace', opacity: 0.6, margin: '0 0 6px' }}>{label}</p>
      {/* `overflow: visible` on purpose: both menus on this bar hang below it,
          and a wrapper that clipped them would hide the only thing this page
          exists to photograph. */}
      <div style={{ width, border: '1px solid rgba(128,128,128,.35)', borderRadius: 10 }}>
        <WindowToolbar
          title="terminaldeck"
          subtitle="on Office PC"
          sidebarHidden
          meta={
            <div className="toolbar-chips">
              <FolderTitle path={CWD} />
              <span className="toolbar-chip-sep" aria-hidden="true" />
              <span className="toolbar-subtitle">on Office PC</span>
              {/* Absent, not empty, over a machine that answered nothing —
                  which is `?old`. Same rule as the connectors chip beside it. */}
              {account !== null || !old ? (
                <>
              <span className="toolbar-chip-sep" aria-hidden="true" />
              <MachineAccountChip
                current={account}
                accounts={old ? [] : ACCOUNTS}
                busy={false}
                onOpen={() => undefined}
                onPick={(id) => {
                  // The harness's stand-in for the round trip: the refusal above
                  // for one account, and a real move for the others, so both
                  // outcomes are on screen rather than argued about.
                  if (id === 'school-asadiqbal') {
                    setProblem('That account has never signed in on this computer.')
                    return
                  }
                  setProblem(null)
                  setAccount(ACCOUNTS.find((row) => row.id === id) ?? null)
                }}
              />
              {problem === null ? null : (
                <span className="machine-switch-host">
                  <span className="machine-switch-problem" role="status">
                    {problem}
                  </span>
                </span>
              )}
                </>
              ) : null}
            </div>
          }
        >
          <SessionControls
            sessionId={SESSION}
            cwd={CWD}
            provider="claude"
            exited={false}
            onOpenConnectors={() => undefined}
            target={{ kind: 'machine', machineId: MACHINE }}
          />
        </WindowToolbar>
      </div>
    </section>
  )
}

function Page() {
  return (
    <div style={{ padding: 24, display: 'grid', gap: 8 }}>
      <Board width={1180} label="1180 — a window with room for every chip" />
      <Board width={820} label="820 — the width the cluster folds at" />
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
