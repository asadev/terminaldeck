/**
 * Hoot in the menu bar, looked at rather than asserted.
 *
 * A stand-in for the top of somebody's Mac — a menu bar with the clock and the
 * Wi-Fi, Hoot's owl among them with its title — and, when it is open, the real
 * panel page (`HootPanel`) in a box placed the way `main/hoot-menubar.ts` places
 * the window: just under the owl. The box stands in for the system's popover
 * glass, which only a real window has.
 *
 *   ?state=quiet | working | needs | stopped    what the sessions and Hoot are doing
 *   ?closed                                     the menu bar alone, panel shut
 *   ?moment                                     the title says the moment ("Session 2 needs you")
 *   ?light                                      light menu bar and light theme
 */
import './stub'
import { StrictMode, useLayoutEffect } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { HootPanel } from '../src/renderer/hoot-panel/HootPanel'
import { HOOT_TRAY_ICONS } from '../src/main/hoot-tray-icons'
import { menuBarTitle, readSnapshot } from '../src/shared/hoot-panel-model'

const params = new URLSearchParams(location.search)
const state = params.get('state') ?? 'working'
const light = params.has('light')
if (light) document.documentElement.dataset.theme = 'light'

const sessions = [
  { id: 's1', label: 'Session 1', status: state === 'working' || state === 'needs' ? 'working' : 'idle' },
  { id: 's2', label: 'Session 2', status: state === 'needs' ? 'input' : state === 'working' ? 'working' : 'idle' },
  { id: 's3', label: 'Fix the parser', status: 'idle' },
]
let snapshot: Record<string, unknown> = {
  assistant: 'Hoot',
  // What the main process sends: the glass's light or dark.
  appearance: light ? 'light' : 'dark',
  hoot: state === 'stopped' ? { status: 'stopped', problem: null } : { status: 'running', problem: null },
  sessions,
  messages:
    state === 'stopped'
      ? []
      : [
          { id: 'm1', role: 'you', text: 'Which of my sessions are still working?', at: 0 },
          {
            id: 'm2',
            role: 'agent',
            text: 'Session 1 is running the test suite, and Session 2 is waiting for you to approve an edit to reader.ts.',
            at: 0,
          },
        ],
}
const listeners = new Set<(raw: unknown) => void>()
const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck
deck.hootPanelSnapshot = async () => snapshot
deck.onHootPanelSnapshot = (cb: (raw: unknown) => void) => {
  listeners.add(cb)
  return () => listeners.delete(cb)
}
deck.onHootPanelShown = () => () => {}
// What Hoot's transcript would show a moment later: the message. No Hoot out here answers it.
deck.hootPanelSay = async (text: string) => {
  snapshot = { ...snapshot, messages: [...(snapshot.messages as unknown[]), { id: `m${Date.now()}`, role: 'you', text, at: 0 }] }
  for (const listener of [...listeners]) listener(snapshot)
  return { ok: true, message: '' }
}
deck.hootPanelStartHoot = async () => ({ ok: false, message: 'The harness has no Hoot to start.' })
for (const name of ['hootPanelShowSession', 'hootPanelPointer', 'hootPanelHeld', 'hootPanelFocus', 'hootPanelClose', 'hootPanelSize']) {
  deck[name] = () => undefined
}

const moment = params.has('moment') ? { sessionId: 's2', text: 'Session 2 needs you', attention: true } : null
const title = menuBarTitle(moment, readSnapshot(snapshot).sessions)
const owl = `data:image/png;base64,${HOOT_TRAY_ICONS.open.colour2x}`

const style = document.createElement('style')
style.textContent = `
body { margin: 0; background: ${light ? 'linear-gradient(160deg,#c9d6e8,#eef2f7)' : 'linear-gradient(160deg,#1f2a3a,#3b4a63)'}; height: 100vh; }
.mb { display: flex; align-items: center; gap: 18px; height: 24px; padding: 0 14px; font: 13px -apple-system, system-ui;
      background: ${light ? 'rgba(246,246,246,0.86)' : 'rgba(28,28,30,0.86)'}; color: ${light ? '#111' : '#f2f2f2'}; backdrop-filter: blur(20px); }
.mb .apple { font-weight: 600; }
.mb .right { margin-left: auto; display: flex; align-items: center; gap: 16px; }
.mb .owl { display: inline-flex; align-items: center; gap: 2px; padding: 0 5px; height: 22px; border-radius: 5px; ${params.has('closed') ? '' : `background: ${light ? 'rgba(0,0,0,0.1)' : 'rgba(255,255,255,0.16)'};`} }
.mb .owl img { width: 18px; height: 18px; }
.mb .owl span { font-variant-numeric: tabular-nums; }
.glass { position: absolute; top: 28px; width: 360px; border-radius: 12px; overflow: hidden;
         background: var(--material-bg-strong); background-image: var(--material-sheen); backdrop-filter: var(--material-filter);
         box-shadow: var(--shadow-lg); }
`
document.head.append(style)

function Desktop() {
  // Under the owl, as the real window is placed: centred on it, kept on screen.
  useLayoutEffect(() => {
    const icon = document.getElementById('owl')?.getBoundingClientRect()
    const panel = document.getElementById('panel')
    if (!icon || !panel) return
    panel.style.left = `${Math.min(Math.max(icon.left + icon.width / 2 - 180, 8), window.innerWidth - 368)}px`
  }, [])
  return (
    <>
      <div className="mb">
        <span className="apple"></span>
        <span>Finder</span><span>File</span><span>Edit</span><span>View</span>
        <span className="right">
          <span className="owl" id="owl">
            <img src={owl} alt="" />
            {title ? <span>{title.trim()}</span> : null}
          </span>
          <span>Wi‑Fi</span>
          <span>Fri 3 Oct 20:45</span>
        </span>
      </div>
      {params.has('closed') ? null : (
        <div className="glass" id="panel">
          <HootPanel />
        </div>
      )}
    </>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Desktop />
  </StrictMode>,
)

