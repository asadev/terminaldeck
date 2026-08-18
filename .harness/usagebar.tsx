/**
 * Every state the chrome's usage element can be in, at every width, in both
 * themes, without Electron.
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
 * The Claude rows are the real ones too, off this machine's own `/usage` panel:
 * 18% of the five-hour window resetting `4am (Asia/Dubai)` and 55% of
 * `Current week (all models)` resetting `Aug 21 at 2pm (Asia/Dubai)` — the two
 * figures he used as his example when he asked for two stacked bars. The `81%`
 * row is the screen he was actually looking at: nothing for the five-hour
 * window, and the weekly one promoted into its place by the old single-window
 * bar, printing `Week 81% resets Aug 21 at 2pm`.
 */
import { createRoot } from 'react-dom/client'
import { UsageBarView } from '../src/renderer/shell/UsageBar'
import type { UsageReport, UsageWindowReading } from '../src/renderer/shell/usage-bar-model'
import '../src/renderer/styles/tokens.css'
// The app's own reset, and it is not optional. Without it every `<button>` in
// here is drawn as an operating-system button — a grey `buttonface` fill and a
// bevel — so the chips came back looking like nothing in the product, and the
// first read of the board was "why does the usage bar have a background". A
// harness that invents a bug is worse than no harness. `app.css` is what the
// real window loads, so it is what this loads.
import '../src/renderer/styles/app.css'
// The chip's own shape lives with the composer, and its value spans with the
// agent controls — the same two files the real cluster picks up on the way in.
// Without them this board draws the right words with none of the spacing.
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
    used: { state: 'reported', fraction: 0.18 },
    resets: { state: 'described', text: '4am (Asia/Dubai)' },
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
  used: { state: 'reported', fraction: 0.55 },
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

/** The state he described, and the one every width below is measured in. */
const BOTH: Case = {
  title: 'Both windows measured — the ask, in his numbers',
  note: 'Five-hour above, weekly below. A percentage on each. The renewal time on the five-hour line only: no “Week”, no dates.',
  props: {
    report: report([claude(), week], null),
    provider: 'claude',
    accountLabel: 'app.imatch.ae@gmail.com',
    now: NOW,
  },
}

const CASES: Case[] = [
  BOTH,
  {
    title: 'Both measured, dense — the room is short',
    note: 'Under 210 pixels. The renewal clause goes and the meters narrow. Both readings stay: hidden, a reading is indistinguishable from one that was never reported.',
    props: { ...BOTH.props, fit: 'dense' as const },
  },
  {
    title: 'Both measured, tight — the narrowest window this app permits',
    note: 'Under 120 pixels. The window name, the meters, the renewal clause and the caret all go; the two figures do not. Measured at a 720pt window, where the whole cluster gets 56.',
    props: { ...BOTH.props, fit: 'tight' as const },
  },
  {
    title: 'The screen he was looking at: nothing for five hours, 81% for the week',
    note: 'The old bar promoted the weekly reading into its one slot and printed “Week 81% resets Aug 21 at 2pm”. Now the empty five-hour line stays, so which window is silent is visible.',
    props: {
      report: report([{ ...week, used: { state: 'reported', fraction: 0.81 } }], null),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      now: NOW,
    },
  },
  {
    title: 'Five-hour aged past a twelfth of its window',
    note: 'Forty minutes in with no new reading. The meter is drawn back and the line trades its renewal time for its own age — and a fetch is already on its way, which is why it is not simply dropped.',
    props: {
      report: report([claude({ reportedAt: NOW - 40 * MINUTE }), week], null),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      now: NOW,
    },
  },
  {
    title: 'A third window in trouble — “Current week (Opus)” at 97%',
    note: 'Only one weekly window can have the line, so any other that is near its limit is put beside them. 97% must never hide behind a comfortable pair.',
    props: {
      report: report(
        [
          claude(),
          week,
          claude({
            id: 'claude/system/weekly-opus',
            window: 'other',
            windowMinutes: 10080,
            label: 'Current week (Opus)',
            used: { state: 'reported', fraction: 0.97 },
          }),
        ],
        null,
      ),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      now: NOW,
    },
  },
  {
    title: 'Five-hour over its own limit',
    note: 'The meter clamps at the track; the figure does not. 104% is the finding, not an error.',
    props: {
      report: report(
        [claude({ used: { state: 'reported', fraction: 1.04 } }), { ...week, used: { state: 'reported', fraction: 0.92 } }],
        null,
      ),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      now: NOW,
    },
  },
  {
    title: 'Warned without a figure',
    note: '“Approaching weekly limit” names a limit and no number. Not reported — never a zero — and no meter, because an empty meter and an absent one are opposite claims.',
    props: {
      report: report(
        [
          claude(),
          claude({
            id: 'claude/system/weekly',
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
      now: NOW,
    },
  },
  {
    title: 'Nothing reported yet — one line, and it says so',
    note: 'The ordinary state of a fresh session. Two empty slots would be two dead readings, so it collapses to one line and the panel carries the sentence.',
    props: {
      report: report([], NOTHING),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      now: NOW,
    },
  },
  {
    title: 'A fetch in flight, which nobody started',
    note: 'There is no button any more. It runs itself when the session goes quiet, so the bar has to say what it is doing rather than sit on “Not reported”.',
    props: {
      report: report([], NOTHING),
      provider: 'claude',
      accountLabel: 'app.imatch.ae@gmail.com',
      fetching: true,
      now: NOW,
    },
  },
  {
    title: 'Codex — the real rollout on this machine',
    note: '5% of a 30-day window, measured 4 June, for a window that reset 4 July. Exact, and about a period that no longer exists: one line, no meter, no number, and the sentence that says why.',
    props: {
      report: report([codex], null, CODEX_ACCOUNT),
      provider: 'codex',
      accountLabel: 'Signed in · ChatGPT',
      now: NOW,
    },
  },
  {
    title: 'Codex, still inside its window',
    note: 'The same record with its own clock: what it looks like the day Codex takes a turn. One line, because Codex has neither of the two windows the pair is for.',
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
    note: 'Not a zero and not an empty meter: a build whose preload has no usage methods says so.',
    props: { report: null, provider: 'claude', accountLabel: null, unwired: true, now: NOW },
  },
]

/**
 * The widths a real toolbar's action group actually gets.
 *
 * 620 is a 1440pt window with the sidebar open; 300 is a guest pane at half of
 * one; 190 is the far end of a divider drag, where the cluster beside this has
 * long since folded and this is being clamped by `--sc-room`.
 */
const WIDTHS = [620, 460, 340, 260, 190]

function Strip({ width, props }: { width: number; props: Parameters<typeof UsageBarView>[0] }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
      <span style={{ color: 'var(--text-muted)', fontSize: 10, width: 30, textAlign: 'right' }}>{width}</span>
      {/* A strip of chrome the width of a real toolbar's action group, so the
          element is looked at in the room it actually has. `overflow: hidden`
          because the bar clips: anything painting outside this box is painting
          over the mode switch in the app. */}
      <div
        style={{
          display: 'flex',
          justifyContent: 'flex-end',
          alignItems: 'center',
          height: 48,
          width,
          overflow: 'hidden',
          padding: '0 14px',
          borderRadius: 'var(--radius-md)',
          background: 'var(--chrome-solid, var(--bg-secondary))',
        }}
      >
        <UsageBarView {...props} />
      </div>
    </div>
  )
}

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

      <p style={{ color: 'var(--text-secondary)', fontSize: 12, margin: '0 0 2px' }}>
        Both windows measured, at every width a toolbar gives it
      </p>
      <p style={{ color: 'var(--text-muted)', fontSize: 11, margin: '0 0 8px', maxWidth: 640 }}>
        The figures never shrink; the renewal clause goes first, then the meters.
      </p>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 26 }}>
        {WIDTHS.map((width) => (
          <Strip key={width} width={width} props={BOTH.props} />
        ))}
        {WIDTHS.map((width) => (
          <Strip key={`dense-${width}`} width={width} props={{ ...BOTH.props, fit: 'dense' as const }} />
        ))}
        {WIDTHS.map((width) => (
          <Strip key={`tight-${width}`} width={width} props={{ ...BOTH.props, fit: 'tight' as const }} />
        ))}
      </div>

      {CASES.map((entry) => (
        <div key={entry.title} style={{ marginBottom: 22 }}>
          <p style={{ color: 'var(--text-secondary)', fontSize: 12, margin: '0 0 2px' }}>{entry.title}</p>
          <p style={{ color: 'var(--text-muted)', fontSize: 11, margin: '0 0 6px', maxWidth: 640 }}>{entry.note}</p>
          <Strip width={620} props={entry.props} />
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
