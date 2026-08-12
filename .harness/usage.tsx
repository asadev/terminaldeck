/**
 * Look at the usage strip without Electron.
 *
 *     npx vite --config .harness/vite.config.ts --port 5210
 *     open http://localhost:5210/usage.html
 *
 * Renders the presentational half against fixtures, in both themes, in a column
 * the width of a real chat pane — because a strip that typechecks and passes
 * its tests can still wrap into three lines or lose its meter on screen.
 */
import { createRoot } from 'react-dom/client'
import { UsageStripView } from '../src/renderer/chat/usage/UsageStrip'
import type { PlanLimitSnapshot, SessionSummary, TokenUsage } from '../src/renderer/chat/usage/types'
import '../src/renderer/styles/tokens.css'

const NOW = Date.now()

function usage(over: Partial<TokenUsage> = {}): TokenUsage {
  return { input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, ...over }
}

function session(over: Partial<SessionSummary> = {}): SessionSummary {
  return {
    sessionId: 's1',
    transcriptPath: '/t/s1.jsonl',
    cwd: '/p',
    models: ['claude-opus-5'],
    requests: 47,
    usage: usage({ input: 1240, output: 34_100, cacheRead: 1_240_000, cacheWrite1h: 88_400 }),
    cost: {
      cost: { input: 0.01, output: 0.85, cacheWrite: 0.88, cacheRead: 0.12, total: 1.86 },
      byModel: {},
      unpricedModels: [],
      usedLegacyRate: false,
    },
    context: { tokens: 142_000, window: 200_000, percent: 71, remaining: 58_000, level: 'warning' },
    warnings: [{ kind: 'context-window', level: 'warning', percent: 71, message: 'Context 71% full.' }],
    preContextTokens: 24_000,
    compactions: 0,
    sidechainRequests: 3,
    startedAt: NOW - 5_400_000,
    lastActivityAt: NOW,
    ...over,
  }
}

const plan: PlanLimitSnapshot = {
  sessionId: 'pty-1',
  available: true,
  source: 'usage-panel',
  message: null,
  capturedAt: NOW - 4 * 60_000,
  reason: null,
  limits: [
    { id: 'session', label: 'Current session', scope: 'session', percent: 5, resetsAt: '4am (Asia/Dubai)' },
    { id: 'week', label: 'Current week (all models)', scope: 'week', percent: 80, resetsAt: 'Aug 14 at 2pm (Asia/Dubai)' },
    { id: 'week:fable', label: 'Current week (Fable)', scope: 'week', percent: 100, resetsAt: 'Aug 14 at 2pm (Asia/Dubai)' },
  ],
}

const CASES: Array<{ title: string; node: React.ReactNode }> = [
  {
    title: 'Typical — healthy session, plan read from /usage',
    node: <UsageStripView session={session()} today={{ total: 4.1, sessions: 3, carriedOver: 0, hasUnpriced: false }} plan={plan} scanning={false} now={NOW} />,
  },
  {
    title: 'Context over the limit, compacted twice, unpriced model, today carried over',
    node: (
      <UsageStripView
        session={session({
          compactions: 2,
          context: { tokens: 208_400, window: 200_000, percent: 104.2, remaining: 0, level: 'critical' },
          warnings: [
            {
              kind: 'context-window',
              level: 'critical',
              percent: 104.2,
              message: 'Context 104% full — compaction is imminent, and quality drops before it lands.',
            },
          ],
          cost: {
            cost: { input: 0.02, output: 1.4, cacheWrite: 2.2, cacheRead: 0.4, total: 4.02 },
            byModel: {},
            unpricedModels: ['claude-experimental-9'],
            usedLegacyRate: true,
          },
        })}
        today={{ total: 12.44, sessions: 5, carriedOver: 2, hasUnpriced: true }}
        plan={{ ...plan, source: 'warning', message: "You've used 92% of your weekly limit · resets Aug 14 at 2pm", capturedAt: NOW - 40 * 60_000, limits: [{ id: 'week', label: 'weekly limit', scope: 'week', percent: 92, resetsAt: 'Aug 14 at 2pm' }] }}
        scanning={false}
        now={NOW}
      />
    ),
  },
  {
    title: 'Plan limit not available — with the Check control wired',
    node: (
      <UsageStripView
        session={session({ compactions: 1 })}
        today={{ total: 0.004, sessions: 1, carriedOver: 0, hasUnpriced: false }}
        plan={null}
        scanning={false}
        now={NOW}
        canRefreshPlan
        onRefreshPlan={() => {}}
      />
    ),
  },
  {
    title: 'Plan limit named without a number, refusal explained',
    node: (
      <UsageStripView
        session={session()}
        today={{ total: 4.1, sessions: 3, carriedOver: 0, hasUnpriced: false }}
        plan={{
          ...plan,
          source: 'warning',
          message: 'Approaching weekly limit',
          limits: [{ id: 'week', label: 'weekly limit', scope: 'week', percent: null, resetsAt: null }],
        }}
        scanning={false}
        now={NOW}
        canRefreshPlan
        onRefreshPlan={() => {}}
        refreshReason="The session is working — try again once it is idle."
      />
    ),
  },
  {
    title: 'No request yet / still scanning / nothing recorded / unwired',
    node: (
      <>
        <UsageStripView session={session({ context: null, warnings: [], compactions: 0 })} today={{ total: 0, sessions: 1, carriedOver: 0, hasUnpriced: false }} plan={null} scanning={false} now={NOW} />
        <UsageStripView session={null} today={{ total: 0, sessions: 0, carriedOver: 0, hasUnpriced: false }} plan={null} scanning now={NOW} />
        <UsageStripView session={null} today={{ total: 0, sessions: 0, carriedOver: 0, hasUnpriced: false }} plan={null} scanning={false} now={NOW} />
        <UsageStripView session={null} today={{ total: 0, sessions: 0, carriedOver: 0, hasUnpriced: false }} plan={null} scanning={false} now={NOW} unwired />
      </>
    ),
  },
]

function Board({ theme, width }: { theme: 'dark' | 'light'; width: number }) {
  return (
    <div
      data-theme={theme}
      style={{
        background: 'var(--bg-primary)',
        color: 'var(--text-primary)',
        fontFamily: 'var(--font-ui)',
        padding: '18px 20px 26px',
      }}
    >
      <p style={{ color: 'var(--text-muted)', fontSize: 12, margin: '0 0 12px' }}>
        {theme} · pane {width}px
      </p>
      {CASES.map((entry) => (
        <div key={entry.title} style={{ marginBottom: 18, width, maxWidth: '100%' }}>
          <p style={{ color: 'var(--text-secondary)', fontSize: 12, margin: '0 0 4px' }}>{entry.title}</p>
          <div style={{ border: '1px solid var(--border)', borderRadius: 'var(--radius-md)', overflow: 'hidden' }}>
            <div style={{ background: 'var(--bg-primary)', padding: '26px 14px', color: 'var(--text-muted)', fontSize: 12 }}>
              …conversation…
            </div>
            {entry.node}
          </div>
        </div>
      ))}
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <>
    <Board theme="dark" width={760} />
    <Board theme="light" width={760} />
    <Board theme="dark" width={420} />
  </>,
)
