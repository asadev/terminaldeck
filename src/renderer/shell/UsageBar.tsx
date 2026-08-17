import { useCallback, useEffect, useRef, useState } from 'react'
import type { ProviderId } from '@shared/types'
import { accountIdentity, useAccountIdentity } from '../accounts'
import { useFeatures } from '../features/FeaturesProvider'
import { ProviderBadge } from '../components/ProviderBadge'
import { providerOption } from '../components/ProviderPicker'
import { useOneMenu } from './one-menu'
import {
  alertReading,
  primaryReading,
  sourceSentence,
  usageReadout,
  type UsageReadout,
  type UsageReport,
} from './usage-bar-model'
import { useUsageBar } from './useUsageBar'
import './UsageBar.css'

/**
 * How much of the account's limit is gone, on the session's own bar.
 *
 * ## What this is answering
 *
 * Asad, twice, the second time listing it among what was still missing:
 *
 *   > *"Where we show the account, next to it we show a bar of the five-hour
 *   > limit — how much limit is completed, how much is left, with the time of
 *   > renewal."* … *"and also bring that usage bar."*
 *
 * The numbers were built and they worked. What never happened was the placement:
 * the only surface that drew them was `UsageStrip`, inside the chat composer's
 * Options panel — so a session drawn as a terminal, which is how this app opens
 * every session, had no way to see them at all, and a session drawn as a chat
 * had to open a panel first. This is the same reading, in the chrome, for
 * terminal and chat alike, beside the account it is about.
 *
 * It sits in `SessionControls` and is therefore mounted twice for the same
 * reason everything else in that cluster is: the window's bar carries the host
 * session's, each guest pane carries its own, and both are this component with
 * their own `sessionId`. A split can hold two accounts, and two accounts have
 * two different five-hour windows.
 *
 * ## The three things it will not do
 *
 * This feature was nearly cancelled twice for being unreliable, so the refusals
 * matter more than the drawing. They are argued in `usage-bar-model.ts` and
 * enforced there; what this file does is respect them:
 *
 *  1. **A bar only when both halves are real** — a measured fraction *and* a
 *     renewal time. Everything else is words.
 *  2. **"Not reported" is a distinct state**, never a zero. An empty bar and an
 *     absent one are opposite claims and they are drawn differently.
 *  3. **Nothing comes from `~/.claude.json`.** Its `cachedUsageUtilization`
 *     block has exactly the fields a bar wants and was measured at 21.3 hours
 *     stale, describing a window that had ended 17 hours earlier. The only
 *     sources are the two in `usage-ipc.ts`: Claude Code's own screen, and the
 *     rollout Codex writes as it works.
 *
 * ## Whose it is
 *
 * The panel names the agent, the login and the window, in that order, and the
 * login is resolved through `accountIdentity` — the same function the account
 * chip a few inches away calls. That is not a nicety: the bar sits beside the
 * account precisely so the two agree, and the way to make two surfaces agree is
 * to have them ask the same function rather than to word the same answer twice.
 */

export interface UsageBarViewProps {
  /** What the session's usage looks like right now, or null before the first answer. */
  report: UsageReport | null
  /** Which agent the session runs. Decides whether `/usage` can be asked for. */
  provider?: ProviderId
  /** The cluster is folded into one chip, so this one has to get out of the way. */
  folded?: boolean
  /** What the account chip would call this login, resolved by the same function. */
  accountLabel: string | null
  /** True when the build has no usage channel at all. */
  unwired?: boolean
  canCheck?: boolean
  checking?: boolean
  refusal?: string | null
  /** Runs `/usage` in the session. Claude only — see the panel below. */
  onCheck?: () => void
  /** Clock, for tests and for the harness. */
  now: number
}

/**
 * The bar itself.
 *
 * 44 pixels rather than the usage strip's 72: this one is on a toolbar shared
 * with a session name, a folder, an account, three pickers and a mode switch,
 * and it is read as "roughly how far along", not measured off. The strip is at
 * the bottom of a pane with a whole row to itself.
 */
function Meter({ percent, level, state }: { percent: number; level: string; state: string }) {
  return (
    <span className="ub-meter" data-level={level} data-state={state} aria-hidden="true">
      {/* Clamped, because a bar cannot draw past its own track. The number
          beside it is not clamped — a limit can be exceeded, and 104% is the
          finding rather than an error. */}
      <span className="ub-meter-fill" style={{ width: `${Math.min(100, Math.max(0, percent))}%` }} />
    </span>
  )
}

const CARET = 'M2.5 4.5 6 8l3.5-3.5'

/** The agent's own name — "Claude Code", "Codex CLI" — never the internal id. */
function providerLabel(provider: ProviderId | undefined): string | null {
  return provider === undefined ? null : (providerOption(provider)?.label ?? null)
}

/**
 * One line in the panel: a window, what it has used, and when it renews.
 *
 * Every window is listed, not only the one on the bar, because the bar shows the
 * shortest and a weekly limit at 100% behind a quiet five-hour one is the exact
 * screen this feature must not produce.
 */
function WindowRow({ readout }: { readout: UsageReadout }) {
  /*
   * A row that has a bar states its facts; a row that has none explains itself.
   *
   * The two are different jobs. With a bar the numbers are already on screen and
   * what is left to say is when it renews and how old it is — one line, in the
   * source's own unabridged words. Without one the interesting thing *is* the
   * absence, and `detail` is the sentence that accounts for it.
   *
   * They are not both printed. The first version did, and every row then carried
   * its reset time twice — once inside the sentence and once under it, three
   * lines apart, which is precisely the "one fact printed twice" this app's own
   * account chip was corrected for.
   */
  const facts = [readout.reset ? `Renews ${readout.reset}` : null, readout.age ? `read ${readout.age}` : null]
    .filter((part): part is string => part !== null)
    .join(' · ')

  return (
    <div className="ub-row" data-state={readout.state}>
      <div className="ub-row-head">
        {/* The source's own words for the window — "Current week (all models)",
            "30-day limit" — not this app's paraphrase of them. */}
        <span className="ub-row-name">{readout.reading.label || readout.short}</span>
        <span className="ub-row-value" data-level={readout.level}>
          {readout.value}
        </span>
      </div>
      {readout.bar ? (
        <>
          <Meter percent={readout.percent ?? 0} level={readout.level} state={readout.state} />
          {facts === '' ? null : <p className="ub-row-reset">{facts}</p>}
        </>
      ) : (
        <p className="ub-row-detail">{readout.detail}</p>
      )}
    </div>
  )
}

/**
 * The presentational half, exported for its own tests and for the harness.
 *
 * Every figure arrives already decided, so what the bar says and refuses to say
 * is testable without a bridge, a session or a DOM — which is the arrangement
 * `UsageStripView` already uses, and the reason its rules could be checked at
 * all.
 */
export function UsageBarView({
  report,
  provider,
  folded = false,
  accountLabel,
  unwired = false,
  canCheck = false,
  checking = false,
  refusal = null,
  onCheck,
  now,
}: UsageBarViewProps) {
  const [open, setOpen] = useState(false)
  const host = useRef<HTMLDivElement>(null)
  const shut = useCallback(() => setOpen(false), [])
  // One menu at a time in this window. Without it, pressing this while the
  // model picker beside it is open leaves two panels overlapping on a bar that
  // is one row tall — the overlap `one-menu.ts` was written for.
  useOneMenu(open, shut)

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        setOpen(false)
      }
    }
    const onDown = (event: MouseEvent): void => {
      const root = host.current
      if (root && event.target instanceof Node && !root.contains(event.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open])

  const primary = primaryReading(report)
  const readout = primary === null ? null : usageReadout(primary, now)
  const alert = alertReading(report, primary, now)
  const agent = providerLabel(provider)

  /*
   * The sentence for a bar with nothing behind it.
   *
   * Three different nothings, and they are not interchangeable. A build with no
   * channel cannot ever have an answer; a report that arrived carrying a reason
   * has the main process's own sentence, which says more than anything that
   * could be composed here — "Claude Code has not printed a plan-limit line in
   * this session yet", or "was released to make room"; and a report that has not
   * arrived at all is still being asked for.
   */
  const nothing = unwired
    ? 'Usage is not wired into this build.'
    : report === null
      ? 'Asking this session what it has used…'
      : (report.reason ?? 'Nothing has been reported for this session yet.')

  const label = readout?.short ?? 'Usage'
  const value = readout?.value ?? (unwired ? 'Not wired' : report === null ? 'Reading…' : 'Not reported')
  const measured = readout?.percent !== null && readout?.percent !== undefined

  /*
   * Everything the chip cannot fit, for the hover label and for a screen reader.
   *
   * It names the agent and the login as well as the window, because the whole
   * reason this sits next to the account chip is that the two are statements
   * about one thing, and a reading that does not say whose it is invites exactly
   * the confusion a split window already caused once.
   */
  const whose = [agent, accountLabel].filter((part): part is string => part !== null).join(' · ')
  const sentence = readout === null ? nothing : readout.detail
  const title = whose === '' ? sentence : `${whose} — ${sentence}`

  return (
    <div className="usage-bar" ref={host} data-folded={folded || undefined}>
      <button
        type="button"
        className="cc-chip ub-chip"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={`Usage: ${title}`}
        title={title}
        onClick={() => setOpen((was) => !was)}
      >
        <span className="ac-name">{label}</span>
        {/*
          The figure before the bar, which is not the conventional order and is
          deliberate.

          A chip in this cluster clips from its right edge when the row is
          clamped — see `SessionControls.css`, where every chip is made to
          shrink so that none of them paints over the mode switch. With the
          meter first, a squeezed chip drew `5h ● 34` at a 900pt window: the bar
          survived and the number lost its percent sign, which is the one thing
          here that must never happen. Reversed, what the clip takes is the
          caret and then the bar — decoration, then a proportion that is still
          printed as a number an inch to its left.
        */}
        <span
          className={measured ? 'ac-value ub-value' : 'ac-value ub-value ac-value-unknown'}
          data-level={readout?.level ?? 'ok'}
        >
          {value}
        </span>
        {readout?.bar ? (
          <Meter percent={readout.percent ?? 0} level={readout.level} state={readout.state} />
        ) : null}
        {/* The renewal time is half of what he asked for, so it is on the bar
            rather than only in the tooltip — and it is the first thing to go
            when the bar is folded, because the alternative is a chip hanging
            off the end of the window. */}
        {!folded && readout !== null && readout.caveat !== '' ? (
          <span className="ub-caveat">{readout.caveat}</span>
        ) : null}
        {/* A second window, and only ever when it is in trouble. A weekly limit
            at 100% must not be hidden behind a five-hour bar reading 5%. */}
        {alert !== null ? (
          <span className="ub-alert" data-level={alert.level}>
            {alert.short} {alert.value}
          </span>
        ) : null}
        <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
          <path d={CARET} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </svg>
      </button>

      {open ? (
        <div className="ub-sheet scroll-fade" role="dialog" aria-label="Usage windows">
          {/* Whose, before what. The agent's mark and name, then the login as
              the account chip states it — same function, so the two cannot
              disagree — and only then the numbers. */}
          <header className="ub-whose">
            {provider ? <ProviderBadge provider={provider} size={13} /> : null}
            <span className="ub-whose-agent">{agent ?? 'This session'}</span>
            {accountLabel ? <span className="ub-whose-account">{accountLabel}</span> : null}
          </header>

          {report && report.readings.length > 0 ? (
            report.readings.map((reading) => (
              <WindowRow key={reading.id} readout={usageReadout(reading, now)} />
            ))
          ) : (
            <p className="ub-empty">{nothing}</p>
          )}

          {/* Where the numbers came from, once for the panel rather than once
              per row: a session runs one agent, so every reading in it has the
              same source, and repeating that sentence under each window was the
              same paragraph three times in a 300px card. */}
          {readout !== null ? <p className="ub-foot">{readout.source}</p> : null}

          {/*
            The one action, and it belongs to Claude alone.

            `plan:refresh` types `/usage` into the session and reads the panel
            the CLI draws — a Claude gesture with Claude's own refusals, gated on
            an idle session with an empty prompt. Codex needs no equivalent and
            must not be offered one: it writes its limits into its rollout as it
            works, so there is nothing to ask it for, and a button that typed
            `/usage` at a Codex prompt would just be an unknown command.
          */}
          {provider === 'claude' ? (
            <div className="ub-actions">
              <button
                type="button"
                className="ub-check"
                onClick={onCheck}
                disabled={!canCheck || checking}
                title={
                  canCheck
                    ? 'Types /usage into this session, reads the panel Claude Code draws, then closes it with Esc. Only runs while the session is idle and its prompt is empty.'
                    : 'Running /usage from here is not wired into this build.'
                }
              >
                {checking ? 'Checking…' : 'Check now'}
              </button>
              {refusal ? <p className="ub-refusal">{refusal}</p> : null}
            </div>
          ) : provider === 'codex' && readout === null ? (
            // Nothing has been reported and there is nothing to press: Codex
            // writes its limits as it works, so the honest thing to add here is
            // what will make one appear.
            <p className="ub-foot">{sourceSentence('codex-rollout')}</p>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

export interface UsageBarProps {
  /** The pty this reading is about. */
  sessionId: string
  provider?: ProviderId
  folded?: boolean
  /** Injectable for tests and for the harness; defaults to `window.deck`. */
  bridge?: Parameters<typeof useUsageBar>[1]
  /** Clock, for tests. */
  now?: number
}

export function UsageBar({ sessionId, provider, folded = false, bridge, now }: UsageBarProps) {
  /*
   * Usage is a feature that can be uninstalled, and this is one of its surfaces.
   *
   * Asked here rather than in `SessionControls`, which merely composes this:
   * the thing that can be left behind when a feature is switched off is the
   * control itself, so the control is what asks. `features/registry.ts` names
   * `chrome.usage` under the `usage` feature, beside `chat.usage`, and
   * `features-wiring.test.ts` holds this file to being the one that checks it.
   */
  const features = useFeatures()
  const usage = useUsageBar(sessionId, bridge)
  const primary = primaryReading(usage.report)
  /*
   * The login, asked for exactly the way the account chip asks for it.
   *
   * `useAccountIdentity` runs the agent's own `auth status` under that account's
   * configuration directory and is answered from the same place the chip beside
   * this one is answered from — so the bar cannot say "Default" while the chip
   * forty pixels away says an email address, which is a disagreement this app
   * has already shipped once in the sidebar.
   *
   * The reading's account when there is a reading, and the *report's* otherwise.
   * They are the same login; the second exists because the state this bar is in
   * most of the time has no readings at all, and "not reported" without a name
   * on it is exactly the half-answer this was moved here to stop giving.
   */
  const account = primary?.account ?? usage.report?.account ?? null
  const signIn = useAccountIdentity(account?.id ?? null)
  const identity =
    account === null
      ? null
      : accountIdentity({ id: account.id ?? '', name: account.name ?? '' }, signIn)

  // After the hooks, never before: a component that returns early above a hook
  // is a component whose hook order changes with a setting.
  if (!features.controlOn('chrome.usage')) return null

  return (
    <UsageBarView
      report={usage.report}
      provider={provider}
      folded={folded}
      accountLabel={identity?.label ?? null}
      unwired={usage.unwired}
      canCheck={usage.canCheck}
      checking={usage.checking}
      refusal={usage.refusal}
      onCheck={usage.check}
      now={now ?? Date.now()}
    />
  )
}
