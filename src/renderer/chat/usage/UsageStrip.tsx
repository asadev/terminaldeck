import { useMemo } from 'react'
import type { SessionSummary } from './types'
import {
  contextReadout,
  contextWarningOf,
  formatExact,
  formatTokens,
  pickSession,
  tokenTotals,
  usageToday,
  type TodayUsage,
} from './usage-model'
import { useUsage, type UsageBridge } from './useUsage'
import './UsageStrip.css'

/**
 * What this session has moved: tokens, requests, and how full the window is.
 *
 * A reading strip, not a dashboard: the session inspector already owns the
 * per-request detail. Everything here comes from figures the main process has
 * already computed — `cost.ts` for the token and context maths, `transcript.ts`
 * for the incremental tail.
 *
 * There is no money on this strip. Two items carried it — "Session" and "Today"
 * — and both are gone or re-based on tokens; the argument is at the bottom of
 * `src/main/cost.ts`.
 *
 * ## The subscription limit is not here any more, and that is deliberate
 *
 * It used to be: a "Plan" item reading `Session 5% Week 80% · resets 4am`, plus
 * the Check button that types `/usage`. Both moved to `shell/UsageBar.tsx`, on
 * the session's own chrome beside the account chip, because that is where Asad
 * asked for them — *"where we show the account, next to it we show a bar of the
 * five-hour limit"* — and because down here they could not be reached at all
 * from a session drawn as a terminal, which is how this app opens every session.
 *
 * They did not stay in both places. This strip and that bar would have been two
 * readings of one fact, drawn from two different channels (`plan:*` here,
 * `usage:*` there) with two different rules about staleness — so the day one of
 * them refused to draw an expired window and the other went on printing it,
 * a person looking at a chat session would have had two answers on one screen
 * and no way to tell which was the true one.
 *
 * What is left is exactly the thing this strip's own heading promises, in
 * `AgentControls`: *"This session — how many tokens it has used, and how full
 * the context window is."* A subscription window is a fact about an **account**,
 * not about a session, which is the other half of why it belongs beside the
 * account and not under a composer.
 *
 * One honesty rule still runs through what remains: context occupancy above
 * 100% is shown as it is. Auto-compaction fires at the limit, so the last
 * request before it genuinely tips over; only the bar clamps, because a bar
 * cannot do otherwise.
 */

/* ------------------------------------------------------------------ pieces */

function Meter({ percent, level }: { percent: number; level: 'ok' | 'warning' | 'critical' }) {
  return (
    <span className="us-meter" data-level={level} aria-hidden="true">
      {/* Clamped for the bar only — a 104% prompt still renders as a full bar,
          while the label beside it keeps saying 104%. */}
      <span className="us-meter-fill" style={{ width: `${Math.min(100, Math.max(0, percent))}%` }} />
    </span>
  )
}

function Item({
  label,
  title,
  children,
  wide,
}: {
  label: string
  title?: string
  children: React.ReactNode
  wide?: boolean
}) {
  return (
    <div className={wide ? 'us-item us-item-wide' : 'us-item'} title={title}>
      <span className="us-label">{label}</span>
      {children}
    </div>
  )
}

/* -------------------------------------------------------------------- view */

export interface UsageStripViewProps {
  session: SessionSummary | null
  today: TodayUsage
  /** True while the main process is still reading this project's history. */
  scanning: boolean
  /**
   * Whether the empty state is about one session or the whole project. Only
   * the sentence changes: "no usage for this project" is plainly false on a
   * screen where the project has plenty and this session simply has none yet.
   */
  scoped?: boolean
  unwired?: boolean
  /**
   * The session this strip is reporting on, for the copilot's focus overlay.
   *
   * Absent on a project-wide strip, and the attribute is then absent too rather
   * than being written with a placeholder: an anchor that exists but names
   * nothing is worse than no anchor, because a lookup for it succeeds and boxes
   * the wrong strip. See `driving/focus-target.ts`.
   */
  sessionId?: string
}

interface Note {
  tone: 'muted' | 'warning' | 'critical'
  text: string
}

/** At most this many notes; the strip is meant to stay quiet. */
const MAX_NOTES = 2

/**
 * Presentational half, exported for its own tests.
 *
 * Every figure arrives already decided, so the rules about what is shown and
 * what is caveated are testable without a bridge, a watcher or a DOM.
 */
export function UsageStripView({
  session,
  today,
  scanning,
  scoped = false,
  unwired = false,
  sessionId,
}: UsageStripViewProps) {
  /*
   * Written on all three of this component's returns, including the two empty
   * states, and that is the point rather than an oversight.
   *
   * "This session has spent nothing yet" is a thing worth pointing at — it is
   * the honest answer when the copilot has been asked which session is
   * expensive and one of them turns out never to have run. An anchor present
   * only on the populated strip would make the overlay silently fail on exactly
   * the sessions whose emptiness is the finding.
   */
  const anchor = sessionId === undefined ? undefined : `usage-strip:${sessionId}`

  if (unwired) {
    return (
      <div className="usage-strip usage-strip-empty" data-drive-anchor={anchor}>
        <span className="us-muted">Usage is not wired into this build.</span>
      </div>
    )
  }

  if (!session) {
    return (
      <div className="usage-strip usage-strip-empty" data-drive-anchor={anchor}>
        <span className="us-muted">
          {scanning
            ? 'Reading transcripts…'
            : scoped
              ? 'Nothing recorded for this session yet.'
              : 'No usage recorded for this project yet.'}
        </span>
      </div>
    )
  }

  const context = contextReadout(session.context)
  const tokens = tokenTotals(session.usage)

  const notes: Note[] = []
  const warning = contextWarningOf(session)
  if (warning) notes.push({ tone: warning.level, text: warning.message })
  if (today.carriedOver > 0) {
    notes.push({
      tone: 'muted',
      text: `Today includes ${today.carriedOver} session${today.carriedOver === 1 ? '' : 's'} that started earlier, counted in full.`,
    })
  }

  return (
    <div
      className="usage-strip"
      role="group"
      aria-label="What this session has used"
      data-drive-anchor={anchor}
    >
      <div className="us-items">
        {context ? (
          <Item label="Context" title={context.title} wide>
            <Meter percent={context.width} level={context.level} />
            <span className="us-value" data-level={context.level}>
              {context.label}
            </span>
            {context.over ? (
              <span
                className="us-flag"
                title="The prompt exceeded the window — this is the request auto-compaction fires on."
              >
                over
              </span>
            ) : null}
          </Item>
        ) : (
          <Item label="Context" title="No request has been made in this session yet.">
            <span className="us-value us-muted">—</span>
          </Item>
        )}

        {/*
          "Requests", where the session's money used to be.

          The item it replaces printed this session's spend, and the four token
          classes behind it in the tooltip. Both were money. The request count
          was already in that tooltip and is the other thing a person wants
          beside a token total — a million tokens across six requests and a
          million across four hundred are very different sessions.
        */}
        <Item
          label="Requests"
          title={`${session.requests} deduplicated API request${
            session.requests === 1 ? '' : 's'
          } in this session. One request writes several transcript lines and every one of them repeats the same usage block, so these are counted per request rather than per line.`}
        >
          <span className="us-value">{session.requests}</span>
        </Item>

        <Item
          label="Today"
          title={`${formatExact(today.tokens)} tokens across ${today.sessions} session${
            today.sessions === 1 ? '' : 's'
          } active today in this project. Sessions are counted in full, so one that started yesterday makes this an upper bound.`}
        >
          <span className="us-value">{formatTokens(today.tokens)}</span>
        </Item>

        <Item
          label="Tokens"
          title={`${formatExact(tokens.input)} fresh input · ${formatExact(tokens.output)} output · ${formatExact(
            tokens.cacheRead,
          )} cache read · ${formatExact(tokens.cacheWrite)} cache write. Cache reads and writes are most of the traffic; fresh input is only the part of each prompt that was neither cached nor read from cache.`}
          wide
        >
          <span className="us-value">
            in {formatTokens(tokens.input)} · out {formatTokens(tokens.output)}
          </span>
          <span className="us-sub">
            cache {formatTokens(tokens.cacheRead)} read / {formatTokens(tokens.cacheWrite)} write
          </span>
        </Item>

        {session.compactions > 0 ? (
          <Item
            label="Compacted"
            title={`This session was compacted ${session.compactions} time${
              session.compactions === 1 ? '' : 's'
            }. Auto-compaction fires when the window fills; /compact does it on request — the totals do not distinguish them. Context above is measured after the most recent one.`}
          >
            <span className="us-value">×{session.compactions}</span>
          </Item>
        ) : null}

      </div>

      {notes.length > 0 ? (
        <p className="us-notes">
          {notes.slice(0, MAX_NOTES).map((note) => (
            <span key={note.text} className="us-note" data-tone={note.tone}>
              {note.text}
            </span>
          ))}
        </p>
      ) : null}
    </div>
  )
}

/* ------------------------------------------------------------- the strip */

export interface UsageStripProps {
  /** Project folder — the transcript watcher is keyed on it. */
  cwd: string | null
  /** A specific transcript. Wins over the project's newest session. */
  transcriptPath?: string
  /**
   * True when this strip is about one session rather than the whole project.
   *
   * It exists because an absent `transcriptPath` means two different things.
   * For a project view it means "no preference, describe the newest session",
   * which is what `pickSession` falls back to. For a session view it means
   * "this session has not written a transcript yet" — and there the fallback is
   * a lie: it borrows whichever session in the folder ran last and prints its
   * tokens and its context fill under a heading that says "This session". A tab
   * opened under a second account, which by definition has no transcript in the
   * default account's store, showed the default account's numbers.
   *
   * So the flag is not a display preference. It is the difference between a
   * number about you and a number about somebody else.
   */
  scoped?: boolean
  /**
   * Which session this strip belongs to, so the copilot can point at it.
   *
   * Deliberately separate from `transcriptPath`, which is the same fact told a
   * different way and is not always present: a session that has not written a
   * transcript yet still has an id, still has a strip on screen, and is still
   * something a tour has a reason to point at — "this one has spent nothing"
   * being the reason.
   */
  sessionId?: string
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: UsageBridge
  /** Clock, for tests. */
  now?: number
}

export function UsageStrip({
  cwd,
  transcriptPath,
  scoped = false,
  sessionId,
  bridge,
  now,
}: UsageStripProps) {
  const usage = useUsage(cwd, bridge)
  const at = now ?? Date.now()

  const session = useMemo(
    () =>
      // Asked about one session that has no transcript, the honest answer is
      // "nothing yet" — never the newest session that happens to be lying
      // around in the same folder. See `scoped`.
      scoped && !transcriptPath ? null : pickSession(usage.summary, { transcriptPath }),
    [usage.summary, transcriptPath, scoped],
  )
  const today = useMemo(() => usageToday(usage.summary, at), [usage.summary, at])

  return (
    <UsageStripView
      session={session}
      today={today}
      scanning={usage.summary?.scanning ?? false}
      scoped={scoped}
      unwired={usage.unwired}
      sessionId={sessionId}
    />
  )
}
