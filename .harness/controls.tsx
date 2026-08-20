/**
 * The window bar's control cluster, on its own, in a real browser.
 *
 * Two things about this row cannot be seen in a static render, and both of them
 * have shipped wrong.
 *
 *  - **A shut popover renders nothing at all.** `ControlToggle`'s unread state
 *    shipped with a chip that opened onto one sentence and nothing to press, so
 *    fast mode could not be changed on any session whose screen had not been
 *    read yet — and every one of that component's static-markup tests passed,
 *    because a menu with two rows behind it and a menu with none are the same
 *    string until somebody clicks. `composer.tsx` says the same thing about the
 *    chat box's own popovers and exists for the same reason.
 *  - **Widths.** `FIRST_GUESS` in `SessionControls.tsx` is what the cluster
 *    believes about its own size until `naturalWidth` measures it for real, and
 *    the only honest way to write those two numbers down is to draw the row and
 *    measure it. Twice: once in a bar wide enough for every chip, once in a bar
 *    narrow enough to fold them into the summary. This page is the two bars.
 *
 * The readings are overridden on top of `stub.ts` rather than changed in it. The
 * stub answers "nothing could be read, and the session cannot be typed into",
 * which is deliberate and is the state every other harness page wants; it is
 * also the one state in which this row has no working chips at all, so measuring
 * it would measure the wrong row. What is set here instead is the ordinary
 * working case the constants are meant to describe — a live session reading
 * `Opus 5` and `Extra high`, with fast mode off.
 */
import './stub'
import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
// The chip's own shape lives with the composer. `SessionControls.tsx` imports
// `AgentControls.css` and `SessionControls.css` on the way in but not this one,
// because in the packaged app every sheet in the module graph is bundled into
// one file and the composer is always somewhere in it. A harness page loads only
// what it reaches, so without this line the chips draw the right words with none
// of the shape — `usagebar.tsx` carries the same import for the same reason.
import '../src/renderer/components/ChatComposer.css'
import { SessionControls } from '../src/renderer/shell/SessionControls'
import { naturalWidth } from '../src/renderer/shell/control-room'

const CWD = '/Users/apple/Projects/terminaldeck'

/** What the row shows on an ordinary live Claude session. */
const READINGS = {
  model: { value: 'opus-5', label: 'Opus 5', source: 'screen' },
  effort: { value: 'xhigh', label: 'Extra high', source: 'screen' },
  fast: { value: 'off', label: 'Off', source: 'screen' },
  permission: { value: 'bypassPermissions', label: 'Bypass', source: 'screen' },
  live: true,
  agent: { running: true, evidence: 'screen', saw: 'Claude Code' },
  gate: { canType: true, reason: null },
}

/** And the same session before its first frame has been parsed — the state the
 *  toggle's unread branch is drawn for. `?unread` on the URL. */
const UNREAD = {
  ...READINGS,
  model: { value: null, label: null, source: null },
  effort: { value: null, label: null, source: null },
  fast: { value: null, label: null, source: null },
  permission: { value: null, label: null, source: null },
}

/**
 * The session whose model name broke the chip. `?long` on the URL.
 *
 * `Opus 5 with 1M context` is the picker's own name for the row Asad's account
 * defaults to, and at twenty-two characters against a fourteen-character chip it
 * drew as `Opus 5 with 1M…`. This is the fixture for `shortModelLabel` — the
 * chip has to read `Opus 5 1M`, with the full name still in the menu underneath
 * and in the chip's own `title`.
 */
const LONG_MODEL = {
  ...READINGS,
  model: { value: 'opus[1m]', label: 'Opus 5 with 1M context', source: 'screen' },
}

/** A session that has been read and cannot be typed into — the refusal. The
 *  sentence is `blockedFor`'s, quoted from the gate. `?blocked` on the URL. */
const BLOCKED = {
  ...READINGS,
  gate: { canType: false, reason: 'That session is busy, so nothing was sent.' },
}

/*
 * A five-hour window with something in it.
 *
 * The stub answers "the harness has no session to read usage from", which draws
 * `Usage Not reported` — narrower than the real element and, more to the point,
 * not the thing `FIRST_GUESS` describes. The figures are the shape
 * `usage-bar-model.ts` parses and the same ones `usagebar.tsx` boards.
 */
const NOW = Date.now()
const ACCOUNT = { provider: 'claude', id: 'system', name: 'Default', configDir: '/Users/apple/.claude' }
const USAGE = {
  sessionId: 'harness-session',
  assembledAt: NOW,
  reason: null,
  account: ACCOUNT,
  readings: [
    {
      id: 'claude/system/five-hour',
      account: ACCOUNT,
      window: 'five-hour',
      windowMinutes: null,
      label: 'Current session',
      used: { state: 'reported', fraction: 0.18 },
      resets: { state: 'described', text: '4am (Asia/Dubai)' },
      observedAt: NOW,
      reportedAt: NOW - 60_000,
      source: 'claude-usage-api',
    },
    {
      id: 'claude/system/weekly',
      account: ACCOUNT,
      window: 'weekly',
      windowMinutes: null,
      label: 'Current week (all models)',
      used: { state: 'reported', fraction: 0.55 },
      resets: { state: 'described', text: 'Aug 21 at 2pm (Asia/Dubai)' },
      observedAt: NOW,
      reportedAt: NOW - 60_000,
      source: 'claude-usage-api',
    },
  ],
}

const query = new URLSearchParams(location.search)
const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck
deck.readAgentControls = async () =>
  query.has('unread')
    ? UNREAD
    : query.has('blocked')
      ? BLOCKED
      : query.has('long')
        ? LONG_MODEL
        : READINGS
deck.watchUsage = async () => USAGE

/*
 * And the context reading, which is half the width of this element since
 * 2026-08-19.
 *
 * The stub has no `contextWindow`, so without this the bar draws its plan icon
 * and nothing else — which is a real state (a Gemini tab, a plain shell) and is
 * not the one `FIRST_GUESS` describes. The figure is the live reading this app
 * took off its own transcript in `~/ClaudeAsad` on the day the split was built:
 * 154,057 tokens of a 1,000,000 window. Five significant characters is also the
 * *widest* this element gets short of a million-token session printing `1.05M`,
 * which is one character narrower.
 */
deck.contextWindow = async () => ({
  provider: 'claude',
  state: 'ok',
  tokens: 154_057,
  window: 1_000_000,
  percent: 15.4057,
  windowBasis: 'model',
  model: 'claude-opus-5',
  source: {
    path: '/Users/apple/.claude/projects/-Users-apple-ClaudeAsad/92b0e6db.jsonl',
    sessionId: '92b0e6db-0f92-4cbb-bae9-0aa67f9a6868',
    chosen: 'inferred',
    rivals: 0,
  },
  reportedAt: NOW - 60_000,
  observedAt: NOW,
  detail: '154,057 of 1,000,000 tokens — 15% of the context window.',
})

/*
 * Every change this row asks for, recorded rather than performed.
 *
 * The stub's own `applyAgentControl` answers "the harness has no terminal to
 * type into", which is the truth and is useless for the one question this page
 * exists to settle: whether pressing a control *sends* anything. A row that is
 * drawn but wired to nothing is precisely the failure that shipped here — the
 * unread toggle looked like a control and had no way to act — so what a press
 * produced has to be observable from outside the page.
 */
const picks: { control: string; value: string }[] = []
;(globalThis as unknown as { picks: typeof picks }).picks = picks
deck.applyAgentControl = async (input: { control: string; value: string }) => {
  picks.push({ control: input.control, value: input.value })
  return {
    ok: true,
    message: `Fast mode ${input.value === 'on' ? 'On' : 'Off'}.`,
    reading: { value: input.value, label: input.value === 'on' ? 'On' : 'Off', source: 'screen' },
  }
}

function Bar({ id, width }: { id: string; width: number }) {
  return (
    <div style={{ padding: '16px 0' }}>
      <p style={{ margin: '0 0 4px', font: '11px var(--font-mono)', color: 'var(--text-muted)' }}>
        {id} — bar {width}px
      </p>
      {/*
        `WindowToolbar`'s own skeleton, not an approximation of it.
        `useClusterFit` walks out to the nearest `<header>` and `measureRoom`
        then charges every one of that header's other children its protected
        share — so a bar with the cluster hanging directly off it would be a
        different sum from the bar this row actually lives on, and the fold
        would be decided against a layout that does not exist. Lead, drag
        spacer, actions: the three children `WindowToolbar` renders, in order.
      */}
      <header className="toolbar" id={id} style={{ width, boxSizing: 'border-box' }}>
        <div className="toolbar-lead">
          <div className="toolbar-heading" data-focused="true">
            <h1 className="toolbar-title">Update Claude Code terminal to new version</h1>
          </div>
        </div>
        <div className="toolbar-drag" />
        <div className="toolbar-actions">
          <SessionControls
            sessionId="harness-session"
            cwd={CWD}
            provider="claude"
            exited={false}
            onOpenConnectors={() => {}}
          />
        </div>
      </header>
    </div>
  )
}

function Harness() {
  const [, tick] = useState(0)
  // A repaint after the readings land, so the numbers on screen are the ones
  // the row settled on rather than the ones it mounted with.
  useEffect(() => {
    const timer = setInterval(() => tick((n) => n + 1), 500)
    return () => clearInterval(timer)
  }, [])
  return (
    <div style={{ minHeight: '100vh', background: 'var(--bg-primary)', padding: 24 }}>
      <Bar id="wide" width={1400} />
      <Bar id="narrow" width={720} />
    </div>
  )
}

/*
 * `naturalWidth` published on the page, so a measurement taken from outside is
 * the *same function* the component seeds with `FIRST_GUESS` rather than a
 * second implementation of it that could disagree. A number produced by a
 * re-derivation would be arithmetic wearing a measurement's clothes, which is
 * exactly what the note on that constant refuses to do.
 */
;(globalThis as unknown as { measureCluster: (sel: string) => number | null }).measureCluster = (sel) => {
  const node = document.querySelector<HTMLElement>(sel)
  return node ? naturalWidth(node) : null
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
