/**
 * Annotate in the browser, on its own, in a real browser.
 *
 *     npx vite --config .harness/vite.config.ts --port 5199
 *     open http://localhost:5199/annotate.html        (add ?light for the light theme)
 *
 * Why a page of its own: the full harness cannot open a browser tab — the
 * panel has no native view to drive outside Electron, and pressing the globe
 * there spins React for good (true of the base this was built on too). So this
 * draws the toolbar, a page rectangle with a drawn website in it, and opens the
 * same `BrowserAnnotate` the workspace opens on the first click — with the same
 * capture shape, the same later picks (`devices-stub.ts` answers them from the
 * drawing's layout) and a session picker with two sessions in it.
 *
 * `window.__sent` collects what a session would have received.
 */
// The full stub for `window.deck`, because a send hands its picture to
// `session-transfer.ts`, which reads the transfer half off the preload.
import './stub'
import { StrictMode, useEffect, useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/browser/BrowserWorkspace.css'
import { Toolbar } from '../src/renderer/browser/Toolbar'
import { newTab } from '../src/renderer/browser/tabs'
import { BrowserAnnotate } from '../src/renderer/browser/BrowserAnnotate'
import { useAgentTarget } from '../src/renderer/browser/useAgentTarget'
import type { BrowserCapture } from '../src/renderer/browser/bridge'
import { devicesStub } from './devices-stub'

const light = new URLSearchParams(location.search).has('light')
document.documentElement.dataset.theme = light ? 'light' : 'dark'

const sent: Array<{ id: string; data: string }> = []
;(globalThis as unknown as { __sent: typeof sent }).__sent = sent
const sessions = [
  { id: 's1', cwd: '/Users/apple/Projects/coffee-shop', title: 'coffee-shop', provider: 'claude', exitCode: null, createdAt: Date.now() },
  { id: 's2', cwd: '/Users/apple/Projects/coffee-shop', title: 'coffee-shop', provider: 'codex', exitCode: null, createdAt: Date.now() },
]
const bridge = {
  listSessions: async () => sessions,
  writeToSession: (id: string, data: string) => void sent.push({ id, data }),
  onSessionCreated: () => () => {},
  onSessionExit: () => () => {},
}

function Board() {
  const agent = useAgentTarget(bridge)
  const pageRef = useRef<HTMLDivElement | null>(null)
  const [capture, setCapture] = useState<BrowserCapture | null>(null)
  const [rect, setRect] = useState({ x: 0, y: 0, width: 0, height: 0 })
  const tab = useMemo(() => ({ ...newTab('t1'), id: 'b1', url: 'http://localhost:3000/', title: 'Coffee', inspecting: true }), [])

  useEffect(() => {
    const box = pageRef.current?.getBoundingClientRect()
    if (box) setRect({ x: box.left, y: box.top, width: box.width, height: box.height })
    const listen = devicesStub.onBrowserElement as (l: (id: string, c: BrowserCapture) => void) => () => void
    return listen((_id, next) => setCapture(next))
  }, [])

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100vh', background: 'var(--bg-primary)' }}>
      <Toolbar
        tab={tab}
        progress={0}
        resolution={{ kind: 'url', url: 'http://localhost:3000/', display: 'localhost:3000' }}
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
        drawing={false}
        deviceOpen={false}
        onToggleDevice={() => {}}
        menuOpen={false}
        onMenu={() => {}}
        profilesOpen={false}
        profileName="Default"
        profileAvatar=""
      />
      <div ref={pageRef} className="bw-stage" style={{ flex: 1, position: 'relative' }} />
      {capture && (
        <BrowserAnnotate
          capture={capture}
          rect={rect}
          zoom={1}
          tabId="b1"
          title="Coffee"
          agent={agent}
          pickAt={devicesStub.browserAnnotatePick as (id: string, x: number, y: number) => Promise<BrowserCapture | null>}
          save={devicesStub.annotateSave as never}
          sent={devicesStub.annotateSent as never}
          drawApi={{}}
          onClose={() => setCapture(null)}
        />
      )}
    </div>
  )
}

createRoot(document.getElementById('root')!).render(<StrictMode><Board /></StrictMode>)
