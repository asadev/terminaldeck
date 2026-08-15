/**
 * The chat composer, on its own, in a real browser.
 *
 * It exists because this composer's failure mode is not a thrown error — it is
 * a control that is no longer on screen. That cannot be seen in a diff and it
 * cannot be seen in a static render either, because a shut popover renders
 * nothing at all: the markup of a composer whose Options panel holds four
 * controls and one whose panel holds two are the same string. So the panel has
 * to be opened and looked at, which needs a DOM, which needs this page.
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
import { AgentControls } from '../src/renderer/chat/controls/AgentControls'
import { UsageStripView } from '../src/renderer/chat/usage'

const CWD = '/Users/apple/Projects/terminaldeck'

/**
 * A stand-in for the usage strip.
 *
 * The real one reads a transcript through the bridge and this page has none, so
 * it would render its own empty state — which is the wrong thing to look at
 * when the question is how the panel lays out a readout that is present.
 */
function Usage() {
  const cost = { input: 0.42, output: 1.9, cacheWrite: 0.31, cacheRead: 0.08, total: 2.71 }
  return (
    <UsageStripView
      session={{
        sessionId: 'harness',
        transcriptPath: `${CWD}/harness.jsonl`,
        cwd: CWD,
        models: ['claude-opus-5[1m]'],
        requests: 37,
        usage: { input: 18_400, output: 6_210, cacheWrite5m: 44_000, cacheWrite1h: 0, cacheRead: 512_000 },
        cost: { cost, byModel: { 'claude-opus-5[1m]': cost }, unpricedModels: [], usedLegacyRate: false },
        context: { tokens: 96_400, window: 200_000, percent: 48, remaining: 103_600, level: 'ok' },
        warnings: [],
        preContextTokens: 12_000,
        compactions: 0,
        sidechainRequests: 4,
        startedAt: Date.now() - 3_600_000,
        lastActivityAt: Date.now() - 60_000,
      }}
      today={{ total: 11.4, sessions: 3, carriedOver: 0, hasUnpriced: false }}
      plan={null}
      scanning={false}
      now={Date.now()}
    />
  )
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
            <ChatComposer
              onSend={(text) => setSent((all) => [...all, text])}
              cwd={CWD}
              controls={
                <AgentControls sessionId="harness" cwd={CWD} provider="claude" extra={<Usage />} />
              }
            />
          </div>
        </Panel>

        <Panel title="Shell session">
          <div id="shell">
            <ChatComposer
              onSend={(text) => setSent((all) => [...all, text])}
              cwd={CWD}
              shell
              placeholder="Run a command in this shell…"
              controls={<AgentControls sessionId="harness" cwd={CWD} provider="shell" />}
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
