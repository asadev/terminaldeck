/**
 * Attaching from outside the project, in a real browser.
 *
 * Three states of one feature that a static render cannot tell apart, because
 * the difference between them is a popover that is open and a button that is
 * disabled — and a shut popover renders nothing at all. `composer.tsx` exists
 * for the same reason and deliberately does not cover this: it is about which
 * controls survive on the box's own row, and this is about what is behind the
 * plus once it is pressed.
 *
 * ## The state that cannot be reached by clicking
 *
 * The third panel is the point of this page. A session is confined only when a
 * paired device or the copilot started it, and on a confined session a file from
 * outside the granted folder cannot be read at all — measured, see
 * `src/main/session-boundary.test.ts`. The composer therefore attaches the picks
 * that fall inside the boundary and refuses the ones that do not, saying why.
 * Reproducing that in the app needs a phone on the other end of a pairing code;
 * here it needs one stub returning `confined: true`, which is exactly what the
 * real `attach:boundary` answers for the copilot's own session — checked against
 * a live one rather than imagined.
 *
 * The stub's browse and drop return real-looking picks so the chips can be
 * looked at. It cannot open an NSOpenPanel or read the pasteboard, and it does
 * not pretend to: `stub.ts` answers "nothing on the clipboard" for a paste,
 * because in a browser that is the truth.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { ChatComposer } from '../src/renderer/components/ChatComposer'
import type { AttachOutsideBridge } from '../src/renderer/chat/attach/outside'

const CWD = '/Users/apple/Projects/terminaldeck'

/** What the desktop answers for every session started at this keyboard. */
const OPEN_BRIDGE: AttachOutsideBridge = {
  browseForAttachment: async (request) => ({
    ok: true,
    picks:
      request.mode === 'folder'
        ? [{ path: '/Users/apple/Downloads/handover', isDirectory: true }]
        : [
            { path: '/Users/apple/Desktop/screenshot.png', isDirectory: false },
            { path: '/Users/apple/Downloads/invoice.pdf', isDirectory: false },
          ],
  }),
  inspectAttachPaths: async (paths) =>
    paths.map((path) => ({ path, isDirectory: !/\.[a-z0-9]+$/i.test(path) })),
  pasteAttachment: async () => ({ ok: false, reason: 'nothing', detail: 'Nothing on the clipboard.' }),
  sessionAttachBoundary: async () => ({ confined: false, folder: '', projects: [] }),
  pathForDroppedFile: () => '',
}

const COPILOT_FOLDER = '/Users/apple/Library/Application Support/terminaldeck/copilot'

/**
 * What it answers for the copilot's own session, copied from a live one.
 *
 * Both fields matter. The folder is what makes the sentence about *this tab*
 * rather than about confinement in general, and the projects list is what stops
 * the sentence being wrong: the copilot really can read the projects you have
 * open, and saying otherwise would be a worse failure than saying nothing.
 *
 * ## Why this panel returns a *mixed* batch now
 *
 * Because the refusal moved from the button to the pick. It used to be the whole
 * of Browse that was disabled on a confined session, and that was affordable
 * only while the in-app project list existed as a second door. That list is gone
 * — *"we should not even have this search bar"* — so refusing everything would
 * leave the copilot unable to attach even the files inside the folder it is
 * held in, which is a control that cannot act.
 *
 * So the panel hands back one file the session genuinely can read and one it
 * cannot, and this page is where you look to see that the first becomes a chip
 * and the second becomes a sentence.
 */
const CONFINED_BRIDGE: AttachOutsideBridge = {
  ...OPEN_BRIDGE,
  browseForAttachment: async () => ({
    ok: true,
    picks: [
      { path: `${COPILOT_FOLDER}/memory/today.md`, isDirectory: false },
      { path: '/Users/apple/Desktop/screenshot.png', isDirectory: false },
    ],
  }),
  sessionAttachBoundary: async () => ({
    confined: true,
    folder: COPILOT_FOLDER,
    projects: [CWD],
  }),
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
      <h2
        style={{
          margin: 0,
          padding: '12px 24px',
          font: '600 13px var(--font-ui)',
          color: 'var(--text-secondary)',
        }}
      >
        {title}
      </h2>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
        {children}
      </div>
    </section>
  )
}

function Harness() {
  const initial = new URLSearchParams(location.search).get('theme') === 'light' ? 'light' : 'dark'
  const [theme, setTheme] = useState(initial)
  document.documentElement.setAttribute('data-theme', theme)

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', background: 'var(--bg-primary)' }}>
      <div style={{ display: 'flex', gap: 8, padding: 8 }}>
        <button type="button" style={{ font: 'inherit' }} onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}>
          theme: {theme}
        </button>
      </div>

      <div style={{ flex: 1, minHeight: 0, display: 'flex', gap: 24 }}>
        <Panel title="Agent session — Browse is open">
          <div id="agent">
            <ChatComposer onSend={() => {}} cwd={CWD} sessionId="open" outsideBridge={OPEN_BRIDGE} />
          </div>
        </Panel>

        <Panel title="Shell session — the same paths, quoted">
          <div id="shell">
            <ChatComposer
              onSend={() => {}}
              cwd={CWD}
              shell
              placeholder="Run a command in this shell…"
              sessionId="open-shell"
              outsideBridge={OPEN_BRIDGE}
            />
          </div>
        </Panel>

        <Panel title="Confined session — attaches what it can read, refuses the rest">
          <div id="confined">
            <ChatComposer
              onSend={() => {}}
              cwd={CWD}
              sessionId="confined"
              outsideBridge={CONFINED_BRIDGE}
            />
          </div>
        </Panel>
      </div>
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
