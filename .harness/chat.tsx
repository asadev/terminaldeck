/**
 * Adversarial harness for the chat view.
 *
 * Mounts the real `ChatView` against a bridge that hands it a hostile
 * transcript, in a real browser — the only place DOMPurify actually
 * initialises, and therefore the only place the sanitising path can be tested
 * at all. The static-markup test in `ChatView.test.tsx` exercises the *other*
 * branch (no window, no sanitiser, fall back to text).
 */
// The composer reaches for `window.deck` on its own — the picker and the
// connector list are not passed a bridge the way ChatView is — so this page
// needs the stub for the same reason the main harness does.
import './stub'
import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
// Without this the page renders against the browser's own defaults — every
// button grows a UA border — so the harness disagrees with the app about
// things that are not the component's fault. `main.tsx` has always loaded it.
import '../src/renderer/styles/app.css'
// `SessionViewMode` moved to the window's own mode switch when the standalone
// Terminal/Chat segmented control was folded into it. The harness deliberately
// does not import `ModeSwitch` in its place: this page exists to look at the
// chat view, and mounting the window's real mode control here would put a
// second, differently-wired copy of a shell control on a page that has no
// shell — the exact "harness disagrees with the app" failure `stub.ts` warns
// about. A plain button is honest about being scaffolding.
//
// It broke silently, which is worth recording: `ChatToggle.tsx` was deleted
// with this import left behind, so `chat.html` returned a vite 500 and rendered
// a blank white page. Nothing failed — no test covers a harness entry point —
// and the only symptom was that the one page that can show this view stopped
// showing it.
import { type SessionViewMode } from '../src/renderer/shell/ModeSwitch'
import { ChatView, type ChatBridge, type ChatMessage, type ChatUpdate } from '../src/renderer/components/ChatView'

const DAY = 24 * 60 * 60 * 1000
const NOW = Date.now()

const HOSTILE = [
  '<img src=x onerror="window.__xss1=1">',
  '<script>window.__xss2=1</script>',
  '<svg onload="window.__xss3=1"></svg>',
  '[a normal-looking link](javascript:window.__xss4=1)',
  '[<img src=y onerror="window.__xss5=1">](https://example.com/real)',
  '<iframe src="data:text/html,<script>window.__xss6=1<\/script>"></iframe>',
  '<a href="https://evil.example" onmouseover="window.__xss7=1">hover me</a>',
  '<details open onclick="window.__xss8=1"><summary>click</summary>x</details>',
  '![alt](x" onerror="window.__xss9=1)',
  '<style>body{display:none}</style>',
  '<form action="https://evil.example"><input name="p"><button>Send</button></form>',
  '<object data="x"></object><embed src="x">',
  '```js\n</code></pre><img src=x onerror="window.__xss10=1">\n```',
  '<div onfocus="window.__xss11=1" tabindex=0>focusable</div>',
].join('\n\n')

const RICH = `## What I changed

Rewrote the reader so **tool output** never reaches this pane. Three things:

1. \`isMeta\` alone was not enough — slash-command plumbing carries none.
2. The array form is tool results, ~97% of the time.
3. A \`<synthetic>\` line is the CLI talking, not the model.

| Shape | Lines | Kept |
|---|---|---|
| user, string | 487 | 354 |
| user, array | 5,315 | 29 |
| assistant | 2,061 | all prose |

> A compaction summary is a machine-written recap posted as a user turn.

Here is the gate, which you should not need to read:

\`\`\`ts
export function mayCarryChat(line: string): boolean {
  if (line.includes('"tool_use_id"')) return false
  return line.includes('"type":"user"') || line.includes('"type":"assistant"')
}
\`\`\`

See [the transcript module](https://example.com/chat-transcript.ts) for the rest.

---

Done. A very long unbroken token to prove the measure holds: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`

const MESSAGES: ChatMessage[] = [
  { id: 'you:1', role: 'you', text: 'yesterday: can we give a chat mode inside the terminal with a toggle', at: NOW - DAY },
  { id: 'agent:1', role: 'agent', text: 'Yes. It reads the JSONL transcript rather than the terminal buffer.', at: NOW - DAY },
  { id: 'you:2', role: 'you', text: '# 1 — show *this* verbatim\nsecond line, and a <b>tag</b> I typed myself', at: NOW - 3600_000 },
  { id: 'agent:2', role: 'agent', text: RICH, at: NOW - 3500_000 },
  { id: 'you:3', role: 'you', text: 'now render something hostile', at: NOW - 600_000 },
  { id: 'agent:3', role: 'agent', text: HOSTILE, at: NOW - 500_000 },
  { id: 'agent:4', role: 'agent', text: 'Everything above should be inert text.', at: NOW - 400_000 },
]

function update(messages: ChatMessage[]): ChatUpdate {
  return {
    transcriptPath: '/Users/apple/.claude/projects/-Users-apple-Projects-terminaldeck/harness.jsonl',
    sessionId: 'harness',
    cwd: '/Users/apple/Projects/terminaldeck',
    messages,
    reset: true,
    cursor: 0,
    found: true,
    complete: true,
    updatedAt: Date.now(),
  }
}

const bridge: ChatBridge = {
  loadChat: async () => update(MESSAGES),
  tailChat: async () => update([]),
  closeChat: () => {},
}

/**
 * The shape the Proxy in `stub.ts` used to hand back for an unimplemented
 * method. `?bridge=null` proves the view explains itself instead of throwing
 * on `null.found` and taking the pane down through the error boundary.
 */
const nullBridge = {
  loadChat: async () => null,
  tailChat: async () => null,
  closeChat: () => {},
} as unknown as ChatBridge

/** `?bridge=throw`: the preload rejects. Should read as empty, not as a crash. */
const throwingBridge: ChatBridge = {
  loadChat: async () => {
    throw new Error('ipc exploded')
  },
  tailChat: async () => {
    throw new Error('ipc exploded')
  },
  closeChat: () => {},
}

function pickBridge(): ChatBridge {
  const which = new URLSearchParams(location.search).get('bridge')
  if (which === 'null') return nullBridge
  if (which === 'throw') return throwingBridge
  return bridge
}

/** What the harness proves, printed on screen so a screenshot carries the result. */
function audit(): string[] {
  const root = document.querySelector('.cv-scroll')
  if (!root) return ['no chat view mounted']
  const out: string[] = []
  const banned = ['script', 'img', 'iframe', 'a', 'svg', 'form', 'input', 'button', 'object', 'embed', 'style', 'link']
  for (const tag of banned) {
    const n = root.querySelectorAll(tag).length
    if (n > 0) out.push(`FAIL ${n} <${tag}> in the view`)
  }
  const attrs = new Set<string>()
  for (const el of root.querySelectorAll('*')) {
    for (const a of el.attributes) {
      attrs.add(a.name)
      if (/^on/i.test(a.name)) out.push(`FAIL event attribute ${a.name} on <${el.tagName.toLowerCase()}>`)
      if (/^(href|src|srcset|xlink:href|formaction)$/i.test(a.name)) out.push(`FAIL url attribute ${a.name}`)
    }
  }
  const win = window as unknown as Record<string, unknown>
  const fired = Object.keys(win).filter((k) => k.startsWith('__xss'))
  if (fired.length > 0) out.push(`FAIL payloads executed: ${fired.join(', ')}`)
  if (root.textContent?.includes('tool_result')) out.push('FAIL tool_result text in view')
  out.push(`attributes present: ${[...attrs].sort().join(', ') || 'none'}`)
  if (!out.some((l) => l.startsWith('FAIL'))) out.unshift('PASS — nothing executable survived sanitising')
  return out
}

function Harness() {
  const initial = new URLSearchParams(location.search).get('theme') === 'light' ? 'light' : 'dark'
  const [theme, setTheme] = useState(initial)
  const [mode, setMode] = useState<SessionViewMode>('chat')
  const [report, setReport] = useState<string[]>([])
  const [sent, setSent] = useState<string[]>([])

  // Runs itself so a headless screenshot carries the verdict, and so no click
  // is needed to get the audit into `--dump-dom`.
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', initial)
    const t = setTimeout(() => setReport(audit()), 400)
    return () => clearTimeout(t)
  }, [initial])

  const flip = () => {
    const next = theme === 'dark' ? 'light' : 'dark'
    document.documentElement.setAttribute('data-theme', next)
    setTheme(next)
  }
  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', background: 'var(--bg-primary)' }}>
      <div className="chat-toggle-bar" style={{ justifyContent: 'space-between' }}>
        <button
          type="button"
          style={{ font: 'inherit' }}
          onClick={() => setMode(mode === 'chat' ? 'terminal' : 'chat')}
        >
          view: {mode}
        </button>
        <span style={{ display: 'flex', gap: 8 }}>
          <button type="button" onClick={() => setReport(audit())} style={{ font: 'inherit' }}>
            Audit the DOM
          </button>
          <button type="button" onClick={flip} style={{ font: 'inherit' }}>
            theme: {theme}
          </button>
        </span>
      </div>
      {report.length > 0 ? (
        <pre
          id="audit"
          style={{
            margin: 0,
            padding: '8px 12px',
            font: '12px var(--font-mono)',
            whiteSpace: 'pre-wrap',
            color: report.some((l) => l.startsWith('FAIL')) ? 'var(--color-critical)' : 'var(--status-completed)',
            borderBottom: '1px solid var(--border)',
            background: 'var(--bg-secondary)',
          }}
        >
          {report.join('\n')}
        </pre>
      ) : null}
      {sent.length > 0 ? (
        <pre
          id="sent"
          style={{
            margin: 0,
            padding: '6px 12px',
            font: '11px var(--font-mono)',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-all',
            color: 'var(--text-secondary)',
            borderBottom: '1px solid var(--border)',
            background: 'var(--bg-tertiary)',
          }}
        >
          {sent.map((line) => `→ pty: ${JSON.stringify(line + '\r')}`).join('\n')}
        </pre>
      ) : null}
      <div style={{ flex: 1, minHeight: 0 }}>
        {mode === 'chat' ? (
          <ChatView
            cwd="/Users/apple/Projects/terminaldeck"
            refreshMs={0}
            bridge={pickBridge()}
            // The real App writes this straight into the pty and appends \r.
            // Recording it verbatim is the only way to see what an attachment
            // actually sends — the chips are the UI, this is the wire.
            onSend={(text) => {
              ;(window as unknown as Record<string, unknown>).__lastSend = text
              setSent((all) => [...all, text])
            }}
          />
        ) : (
          <div style={{ padding: 24, color: 'var(--text-muted)', font: '13px var(--font-ui)' }}>
            (the terminal lives here in the real app)
          </div>
        )}
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
