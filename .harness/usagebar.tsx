/**
 * Every state the chrome's usage bar can be in, without Electron.
 *
 *     npx vite --config .harness/vite.config.ts --port 5199
 *     open http://localhost:5199/usagebar.html
 *
 * Two of these states cannot be produced in the running app on this machine and
 * that is exactly why the board exists: Codex's binary here is broken
 * (`codex --version` → ENOENT on its own vendored executable), so a Codex
 * session cannot be started to look at — while the *rollout* it wrote is still
 * on disk and still readable. So the Codex rows below are not invented numbers.
 * They are the reading the app itself returns for
 * `~/.codex/sessions/2026/06/04/rollout-…jsonl`, copied out of a live
 * `window.deck.readUsage(null)` on 2026-08-17:
 *
 *     { window: 'monthly', windowMinutes: 43200, label: '30-day limit',
 *       used: { state: 'reported', fraction: 0.05 },
 *       resets: { state: 'at', at: 1783130065000 },
 *       reportedAt: 1780538073460, source: 'codex-rollout' }
 *
 * — 5% of a thirty-day window, measured on 4 June, for a window that reset on
 * 4 July. Which is the whole argument for the expired state: a real number,
 * about a period that no longer exists.
 *
 * The Claude rows are the real ones too, off this machine's own `/usage` panel
 * at 05:47 on 2026-08-17: 34% of the five-hour window resetting `8:50am
 * (Asia/Dubai)`, and 60% of `Current week (all models)` resetting `Aug 21 at
 * 2pm (Asia/Dubai)`. The aged and alert rows move only the timestamps and the
 * percentages that those states are *about*.
 */
import { createRoot } from 'react-dom/client'
import { UsageBarView } from '../src/renderer/shell/UsageBar'
import type { UsageReport, UsageWindowReading } from '../src/renderer/shell/usage-bar-model'
import '../src/renderer/styles/tokens.css'
// The chip's own shape lives with the composer, and its name/value spans with
// the agent controls — the same two files the real cluster picks up on the way
// in. Without them this board draws the right words with none of the spacing,
// which is a harness that invents a bug rather than one that finds one.
import '../src/renderer/components/ChatComposer.css'
import '../src/renderer/chat/controls/AgentControls.css'

const NOW = Date.now()
const MINUTE = 60_000

function claude(over: Partial<UsageWindowReading> = {}): UsageWindowReading {
  return {
    id: 'claude/system/five-hour',
    account: { provider: 'claude', id: 'system', name: 'Default', configDir: '/Users/apple/.claude' },
    window: 'five-hour',
    windowMinutes: null,
    label: 'Current session',
    used: { state: 'reported', fraction: 0.34 },
    resets: { state: 'described', text: '8:50am (Asia/Dubai)' },
    observedAt: NOW,
    reportedAt: NOW - MINUTE,
    source: 'claude-usage-panel',
    ...over,
  }
}

const week = claude({
  id: 'claude/system/weekly',
  window: 'weekly',
  label: 'Current week (all models)',
  used: { state: 'reported', fraction: 0.6 },
  resets: { state: 'described', text: 'Aug 21 at 2pm (Asia/Dubai)' },
})

/** The record this machine actually holds for Codex. See the note above. */
const codex = claude({
  id: 'codex/system:codex/monthly',
  account: {
    provider: 'codex',
    id: 'system:codex',
    name: 'Default (Codex CLI)',
    configDir: '/Users/apple/.codex',
  },
  window: 'monthly',
  windowMinutes: 43200,
  label: '30-day limit',
  used: { state: 'reported', fraction: 0.05 },
  resets: { state: 'at', at: 1783130065000 },
  reportedAt: 1780538073460,
  source: 'codex-rollout',
})

const CLAUDE_ACCOUNT = { provider: 'claude' as const, id: 'system', name: 'Default', configDir: '/Users/apple/.claude' }
const CODEX_ACCOUNT = codex.account

function report(readings: UsageWindowReading[], reason: string | null, account = CLAUDE_ACCOUNT): UsageReport {
  return { sessionId: 'pty-1', readings, reason, account, assembledAt: NOW }
}

const NOTHING =
  'Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run.'
const CODEX_SILENT =
  'Codex has not recorded a rate limit under this account yet — it writes one into its rollout when a turn completes.'

interface Case {
  title: string
  note: string
  props: Parameters<typeof UsageBarView>[0]
}

const CASES: Case[] = [
  {
    title: 'Claude, measured',
    note: 'Both halves real: a fraction off the /usage panel and a renewal time. The only state that gets a bar at full strength.',
    props: {
      report: report([claude(), week], null),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, measured, folded',
    note: 'The cluster beside it has folded into one chip. The reading stays and gives up its renewal clause — hidden, it would be indistinguishable from not reported.',
    props: {
      report: report([claude(), week], null),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      folded: true,
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, aged past a twelfth of its window',
    note: 'Forty minutes into a five-hour window with no new reading. The bar is drawn back and trades the renewal time for its own age.',
    props: {
      report: report([claude({ reportedAt: NOW - 40 * MINUTE })], null),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, weekly limit in trouble behind a quiet session',
    note: 'The bar shows the shortest window; a second window is put beside it only when it is near its limit, so 5% never hides 97%.',
    props: {
      report: report(
        [claude({ used: { state: 'reported', fraction: 0.05 } }), { ...week, used: { state: 'reported', fraction: 0.97 } }],
        null,
      ),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, warned without a figure',
    note: '“Approaching weekly limit” names a limit and no number. Not reported — never a zero — and the reset it did give is kept.',
    props: {
      report: report(
        [
          claude({
            window: 'weekly',
            label: 'weekly limit',
            used: { state: 'not-reported' },
            resets: { state: 'described', text: 'Aug 21 at 2pm (Asia/Dubai)' },
            source: 'claude-warning',
          }),
        ],
        null,
      ),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, a figure with no renewal time',
    note: '“You’ve used 85% of your weekly limit”, with no reset clause. The number is printed; the bar is not, and the missing half is named.',
    props: {
      report: report(
        [
          claude({
            window: 'weekly',
            label: 'weekly limit',
            used: { state: 'reported', fraction: 0.85 },
            resets: { state: 'not-reported' },
            source: 'claude-warning',
          }),
        ],
        null,
      ),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, nothing reported yet',
    note: 'The ordinary state of a fresh session, and the one the bar spends most of its life in. It still says whose session reported nothing.',
    props: {
      report: report([], NOTHING),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      now: NOW,
    },
  },
  {
    title: 'Claude, a refusal',
    note: 'Check ran and the session was busy. The sentence is the main process’s own, so the reason shown here and the reason returned there cannot drift.',
    props: {
      report: report([], NOTHING),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      canCheck: true,
      refusal: 'The session is working — try again once it is idle.',
      now: NOW,
    },
  },
  {
    title: 'Codex — the real rollout on this machine',
    note: '5% of a 30-day window, measured 4 June, for a window that reset 4 July. Exact, and about a period that no longer exists: no bar, no number, and the sentence that says why.',
    props: {
      report: report([codex], null, CODEX_ACCOUNT),
      provider: 'codex',
      accountLabel: 'Signed in · ChatGPT',
      now: NOW,
    },
  },
  {
    title: 'Codex, still inside its window',
    note: 'The same record with its own clock: what the bar looks like the day Codex takes a turn. There is no Check here — Codex writes its limits as it works.',
    props: {
      report: report(
        [{ ...codex, reportedAt: NOW - 30 * MINUTE, resets: { state: 'at', at: NOW + 6 * 24 * 3_600_000 } }],
        null,
        CODEX_ACCOUNT,
      ),
      provider: 'codex',
      accountLabel: 'Signed in · ChatGPT',
      now: NOW,
    },
  },
  {
    title: 'Codex, nothing recorded',
    note: 'A login that has never taken a turn under this configuration directory.',
    props: {
      report: report([], CODEX_SILENT, CODEX_ACCOUNT),
      provider: 'codex',
      accountLabel: 'Signed in · ChatGPT',
      now: NOW,
    },
  },
  {
    title: 'No usage channel in this build',
    note: 'Not a zero and not an empty bar: a build whose preload has no usage methods says so.',
    props: { report: null, provider: 'claude', accountLabel: null, unwired: true, now: NOW },
  },
]

function Board({ theme }: { theme: 'dark' | 'light' }) {
  return (
    <div
      data-theme={theme}
      style={{
        background: 'var(--bg-primary)',
        color: 'var(--text-primary)',
        fontFamily: 'var(--font-ui)',
        padding: '18px 20px 40px',
      }}
    >
      <p style={{ color: 'var(--text-muted)', fontSize: 12, margin: '0 0 14px' }}>{theme}</p>
      {CASES.map((entry) => (
        <div key={entry.title} style={{ marginBottom: 22 }}>
          <p style={{ color: 'var(--text-secondary)', fontSize: 12, margin: '0 0 2px' }}>{entry.title}</p>
          <p style={{ color: 'var(--text-muted)', fontSize: 11, margin: '0 0 6px', maxWidth: 640 }}>{entry.note}</p>
          {/* A strip of chrome the width of a real toolbar's action group, so the
              chip is looked at in the room it actually has. */}
          <div
            style={{
              display: 'flex',
              justifyContent: 'flex-end',
              alignItems: 'center',
              height: 48,
              width: 620,
              maxWidth: '100%',
              padding: '0 14px',
              borderRadius: 'var(--radius-md)',
              background: 'var(--chrome-solid, var(--bg-secondary))',
            }}
          >
            <UsageBarView {...entry.props} />
          </div>
        </div>
      ))}
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <>
    <Board theme="dark" />
    <Board theme="light" />
  </>,
)
