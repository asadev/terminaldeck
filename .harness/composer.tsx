/**
 * The chat composer, on its own, in a real browser.
 *
 * It exists because this composer's failure mode is not a thrown error — it is
 * a control that is no longer on screen. That cannot be seen in a diff and it
 * cannot be seen in a static render either, because a shut popover renders
 * nothing at all: a menu with three rows behind the plus and a menu with none
 * are the same string. So the popover has to be opened and looked at, which
 * needs a DOM, which needs this page.
 *
 * The agent's controls used to be handed to this composer as a `controls` slot
 * and drawn on its bottom row. They are not any more — they are the window
 * bar's, and `shell/SessionControls.tsx` draws them there — so this page shows
 * what the box actually is now: text, attach, microphone, send.
 *
 * Two composers side by side, because the regression that prompted it hit only
 * one of them: an agent session kept its plus and its pickers, and a shell
 * session was left with a microphone and a send button.
 *
 * `chat.tsx` is the other chat harness and mounts the whole `ChatView`; this
 * one deliberately does not, so the box is the only thing on the page.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { ChatComposer } from '../src/renderer/components/ChatComposer'

const CWD = '/Users/apple/Projects/terminaldeck'

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
  const [sent, setSent] = useState<string[]>([])
  document.documentElement.setAttribute('data-theme', theme)

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', background: 'var(--bg-primary)' }}>
      <div style={{ display: 'flex', gap: 8, padding: 8 }}>
        <button type="button" style={{ font: 'inherit' }} onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}>
          theme: {theme}
        </button>
        <span id="sent" style={{ font: '11px var(--font-mono)', color: 'var(--text-muted)' }}>
          {sent.map((line) => JSON.stringify(line)).join('  ')}
        </span>
      </div>

      <div style={{ flex: 1, minHeight: 0, display: 'flex', gap: 24 }}>
        <Panel title="Agent session">
          <div id="agent">
            <ChatComposer onSend={(text) => setSent((all) => [...all, text])} cwd={CWD} />
          </div>
        </Panel>

        <Panel title="Shell session">
          <div id="shell">
            <ChatComposer
              onSend={(text) => setSent((all) => [...all, text])}
              cwd={CWD}
              shell
              placeholder="Run a command in this shell…"
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
