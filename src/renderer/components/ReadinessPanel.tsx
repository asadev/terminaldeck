import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { panelSpec } from '../shell/panels'
import { AgentCliUpdate } from './AgentCliUpdate'
import { PageEmpty } from './PageEmpty'
import {
  dismiss,
  idsFor,
  readDismissed,
  restoreAll,
  writeDismissed,
  type DismissedMap,
} from './readiness-dismissed'
import './ReadinessPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/readiness.ts`, duplicated rather than
 * imported because the renderer tsconfig does not include `src/main`. When the
 * orchestrator lifts them into `src/shared/types.ts` this block goes away and
 * the imports point there instead.
 */
export type ReadinessStatus = 'pass' | 'warn' | 'fail' | 'skip'

export type ReadinessBand = 'strong' | 'fair' | 'weak' | 'at-risk'

export interface ReadinessFix {
  id: string
  label: string
  description: string
  touches: string[]
  destructive: boolean
}

export interface ReadinessCheck {
  id: string
  title: string
  status: ReadinessStatus
  weight: number
  detail: string
  fix: ReadinessFix | null
  gate: boolean
  /** Project-relative file this row is about, when it is about exactly one. */
  opens: string | null
}

export interface ReadinessReport {
  projectPath: string
  score: number
  band: ReadinessBand
  checks: ReadinessCheck[]
  cappedBy: string | null
  scannedAt: string
}

export interface ReadinessFixResult {
  ok: boolean
  message: string
  changed: string[]
}

/** The slice of the preload bridge this panel needs. */
export interface ReadinessBridge {
  scanReadiness(projectPath: string): Promise<ReadinessReport>
  applyReadinessFix(projectPath: string, fixId: string): Promise<ReadinessFixResult>
  /**
   * Hand a file to the machine, which is how a row with no automatic fix still
   * gets a button.
   *
   * Optional, and the panel simply draws no Open button without it — the same
   * bargain every other capability in this window makes. `file:` is not one of
   * the schemes `link-open.ts` refuses for a link the *app itself* raises, only
   * for one a guest page raises, so this opens the person's own editor on their
   * own file and nothing else.
   */
  openLinkExternally?(url: string): Promise<unknown>
}

/**
 * A `file:` URL for one file inside a project.
 *
 * `encodeURI` rather than encoding each segment: a Windows project path starts
 * `C:/…`, and per-segment encoding turns that colon into `%3A`, which is not a
 * path any file URL handler will open. Only the two characters `encodeURI`
 * deliberately leaves alone — the fragment and query marks, both legal in a
 * filename on every platform here — are dealt with afterwards.
 */
export function fileUrlFor(projectPath: string, relPath: string): string {
  const base = projectPath.replace(/[/\\]+$/, '').replace(/\\/g, '/')
  const rest = relPath.replace(/\\/g, '/').replace(/^\/+/, '')
  const joined = `${base}/${rest}`
  const absolute = joined.startsWith('/') ? joined : `/${joined}`
  return `file://${encodeURI(absolute).replace(/#/g, '%23').replace(/\?/g, '%3F')}`
}

export interface ReadinessPanelProps {
  /** Absolute path of the project to score. */
  projectPath: string
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: ReadinessBridge
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Read defensively: readiness is wired into the preload separately, so the
 * panel has to render an explanation rather than crash if it mounts first.
 */
function resolveBridge(): ReadinessBridge | null {
  // Tests render this to static markup, where there is no window at all.
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<ReadinessBridge> }).deck
  if (!host || typeof host.scanReadiness !== 'function' || typeof host.applyReadinessFix !== 'function') {
    return null
  }
  return host as ReadinessBridge
}

/**
 * Which action a not-passing row offers, and why there is never more than one
 * plus the door out.
 *
 * A row with a fix offers the fix: it is the thing that actually repairs the
 * finding, and putting an Open beside it invites somebody to do by hand what
 * the button next to it does properly. A row with no fix offers the file it is
 * about, because "your instructions file is still the skeleton" is a true
 * finding that no machine can act on and a person can act on in ten seconds
 * with the file in front of them. A row with neither offers only the dismissal.
 *
 * Nothing that is passing offers anything. There is nothing to do about good
 * news, and a Dismiss on every green row would be five controls asking to be
 * read on a page whose whole job is to be skimmed.
 */
export function actionFor(check: ReadinessCheck, canOpen: boolean): 'fix' | 'open' | 'none' {
  if (check.status === 'pass') return 'none'
  if (check.fix) return 'fix'
  return canOpen && check.opens !== null ? 'open' : 'none'
}

const BAND_COPY: Record<ReadinessBand, string> = {
  strong: 'Ready',
  fair: 'Workable',
  weak: 'Rough',
  'at-risk': 'At risk',
}

const STATUS_LABEL: Record<ReadinessStatus, string> = {
  pass: 'Passing',
  warn: 'Warning',
  fail: 'Failing',
  skip: 'Not applicable',
}

/** Failures first — the panel is a worklist, not a report card. */
const STATUS_ORDER: Record<ReadinessStatus, number> = { fail: 0, warn: 1, pass: 2, skip: 3 }

export function sortChecks(checks: ReadinessCheck[]): ReadinessCheck[] {
  const rank = (check: ReadinessCheck): number =>
    // An unclean gate sits above every ordinary failure: nothing else on the
    // list matters while credentials are exposed. A passing gate takes its
    // normal place, so the panel does not open on good news.
    check.gate && (check.status === 'fail' || check.status === 'warn')
      ? -1
      : STATUS_ORDER[check.status]

  return [...checks].sort((a, b) => rank(a) - rank(b) || b.weight - a.weight)
}

/* -------------------------------------------------------------- score ring -- */

const RING_SIZE = 84
const RING_RADIUS = 34
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS

export function ScoreRing({ score, band }: { score: number; band: ReadinessBand }) {
  return (
    <div className="readiness-ring" data-band={band}>
      <svg
        viewBox={`0 0 ${RING_SIZE} ${RING_SIZE}`}
        width={RING_SIZE}
        height={RING_SIZE}
        role="img"
        aria-label={`AI readiness score ${score} out of 100 — ${BAND_COPY[band]}`}
      >
        <circle className="readiness-ring-track" cx={RING_SIZE / 2} cy={RING_SIZE / 2} r={RING_RADIUS} />
        <circle
          className="readiness-ring-arc"
          cx={RING_SIZE / 2}
          cy={RING_SIZE / 2}
          r={RING_RADIUS}
          strokeDasharray={RING_CIRCUMFERENCE}
          strokeDashoffset={RING_CIRCUMFERENCE * (1 - Math.max(0, Math.min(100, score)) / 100)}
        />
      </svg>
      <div className="readiness-ring-value" aria-hidden="true">
        {score}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------- rows -- */

const GLYPH: Record<ReadinessStatus, string> = { pass: '✓', warn: '!', fail: '✕', skip: '–' }

export interface RowProps {
  check: ReadinessCheck
  busy: boolean
  result: ReadinessFixResult | null
  onApply(check: ReadinessCheck): void
  /**
   * Open the file this row is about. Null when this window cannot hand a file
   * to the machine, in which case no Open button is drawn — see
   * {@link ReadinessBridge.openLinkExternally}.
   */
  onOpen?: ((check: ReadinessCheck) => void) | null
  /**
   * Put this row away.
   *
   * Null only where dismissal makes no sense, which is a passing row. Every
   * other row has it, including the ones that already carry a fix: an offer to
   * add a lint script is still an offer somebody is entitled to decline, and a
   * finding that cannot be declined is a finding that nags forever.
   */
  onDismiss?: ((check: ReadinessCheck) => void) | null
}

export function CheckRow({ check, busy, result, onApply, onOpen, onDismiss }: RowProps) {
  const [confirming, setConfirming] = useState(false)
  const fix = check.fix

  // A fix that has just run leaves the row; drop any pending confirmation with
  // it so a re-scan cannot land on a half-open prompt. The same applies when a
  // re-scan swaps the offered fix underneath an open prompt: rows are matched
  // by check id, so "Yes, apply it" would otherwise be answering a question
  // about an action that is no longer the one on the button.
  useEffect(() => {
    setConfirming(false)
  }, [result, fix?.id])

  const action = actionFor(check, Boolean(onOpen))
  // Anything that is not good news can be put away. See `RowProps.onDismiss`.
  const dismissable = check.status !== 'pass' && Boolean(onDismiss)

  const handleClick = useCallback(() => {
    if (!fix) return
    // Destructive fixes touch git's index, which no amount of deleting a file
    // undoes — so the button is a request to confirm, not the action itself.
    if (fix.destructive && !confirming) {
      setConfirming(true)
      return
    }
    setConfirming(false)
    onApply(check)
  }, [check, confirming, fix, onApply])

  return (
    <li className="readiness-row" data-status={check.status} data-gate={check.gate || undefined}>
      {/* The glyph is the status, and it is a *shape* (✓ ! ✕ –) before it is a
          colour, so it survives being read without one. The word used to be
          printed beside every title as well — "Passing" on all seven passing
          rows, saying exactly what the tick already said. It moves into the
          label, where a screen reader still gets it and the eye does not have
          to read it ten times. */}
      <span className="readiness-glyph" role="img" aria-label={STATUS_LABEL[check.status]}>
        {GLYPH[check.status]}
      </span>
      <div className="readiness-row-body">
        <div className="readiness-row-head">
          <span className="readiness-title">{check.title}</span>
          {check.gate && check.status !== 'pass' ? (
            <span className="readiness-gate-tag">caps the score</span>
          ) : null}
        </div>
        <p className="readiness-detail">{check.detail}</p>

        {/*
          What this button is about to touch, before it is pressed.

          The full description is a paragraph and it appears at the confirm
          step — which only exists for a `destructive` fix, so for every other
          one it was reachable by hovering the button and in no other way. That
          is not a disclosure for the audience this ships to:

            > *"my audience will be mostly non-technical vibe coders"*

          and a hover is not a thing that happens on a trackpad you are not
          resting on, on a touch screen, or to anybody reading with a keyboard.

          The gap became load-bearing on 2026-08-18, when the instructions row
          stopped reciting `CLAUDE.md` in its finding — the review's rule is
          that copy describing a *mechanism* must not name one vendor's file —
          leaving the fix's own description as the only place this app says
          which file it is about to create. So the file list comes out of the
          tooltip and onto the row.

          `touches` rather than a sentence, because it is the fix's own
          declaration of what it writes and it cannot drift from the code the
          way a re-worded description can. Rendered as the bare list under a
          label so the same shape works for the one that writes a file and the
          one that also rewrites git's index.
        */}
        {fix && fix.touches.length > 0 ? (
          <p className="readiness-touches">
            <span className="readiness-touches-label">Changes</span>
            {fix.touches.join(', ')}
          </p>
        ) : null}

        {fix && confirming ? (
          <p className="readiness-fix-description">{fix.description}</p>
        ) : null}

        {result ? (
          <p className="readiness-result" data-ok={result.ok}>
            {result.message}
          </p>
        ) : null}
      </div>

      {action !== 'none' || dismissable ? (
        <div className="readiness-actions">
          {fix && confirming ? (
            <button type="button" className="readiness-cancel" onClick={() => setConfirming(false)}>
              Cancel
            </button>
          ) : null}

          {action === 'fix' && fix ? (
            <button
              type="button"
              className="readiness-fix"
              data-destructive={fix.destructive || undefined}
              data-confirming={confirming || undefined}
              disabled={busy}
              onClick={handleClick}
              title={fix.description}
            >
              {busy ? 'Working…' : confirming ? 'Yes, apply it' : fix.label}
            </button>
          ) : null}

          {/* The action for a finding no machine can repair. It opens the file
              in whatever the person already uses for it, which is the only
              honest place to fill in a README from. */}
          {action === 'open' && onOpen ? (
            <button
              type="button"
              className="readiness-fix"
              onClick={() => onOpen(check)}
              title={`Open ${check.opens ?? ''} on this machine`}
            >
              Open it
            </button>
          ) : null}

          {dismissable && onDismiss ? (
            <button
              type="button"
              className="readiness-cancel"
              onClick={() => onDismiss(check)}
              title="Hide this check. It still counts towards the score, and you can bring it back."
            >
              Dismiss
            </button>
          ) : null}
        </div>
      ) : null}
    </li>
  )
}

/* ------------------------------------------------------------------ panel -- */

/**
 * AI readiness for one project: a score ring, one row per check, and a Fix
 * button wherever the main process offered a described action.
 *
 * Nothing is ever fixed by opening this panel. A scan only reads; a fix runs
 * when its button is pressed, and destructive ones ask a second time first.
 */
export function ReadinessPanel({ projectPath, bridge }: ReadinessPanelProps) {
  const resolved = useMemo(() => bridge ?? resolveBridge(), [bridge])

  const [report, setReport] = useState<ReadinessReport | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [scanning, setScanning] = useState(false)
  const [busyFix, setBusyFix] = useState<string | null>(null)
  const [results, setResults] = useState<Record<string, ReadinessFixResult>>({})
  /*
   * Rows this person has put away, read once on first render rather than in an
   * effect. An effect would paint the full list and then remove rows from under
   * a pointer that is already moving, which is a misclick rather than a blink —
   * the same argument `features/state.ts` makes for reading its own map
   * synchronously.
   */
  const [put, setPut] = useState<DismissedMap>(() => readDismissed())

  // Guards against a slow scan for a project the user has already navigated
  // away from overwriting the one they are now looking at.
  const requestRef = useRef(0)
  // Bumped once per project, not once per scan: a fix outlives the scan it
  // triggers, so it needs a marker that a re-scan does not move.
  const contextRef = useRef(0)

  const scan = useCallback(async () => {
    if (!resolved) return
    const token = ++requestRef.current
    setScanning(true)
    setError(null)
    try {
      const next = await resolved.scanReadiness(projectPath)
      if (token !== requestRef.current) return
      setReport(next)
    } catch (cause) {
      if (token !== requestRef.current) return
      setError(cause instanceof Error ? cause.message : String(cause))
    } finally {
      if (token === requestRef.current) setScanning(false)
    }
  }, [projectPath, resolved])

  useEffect(() => {
    contextRef.current += 1
    setReport(null)
    setResults({})
    setBusyFix(null)
    void scan()
  }, [scan])

  const applyFix = useCallback(
    async (check: ReadinessCheck) => {
      if (!resolved || !check.fix) return
      // Switching project clears the results and starts a new scan, and without
      // this the fix still in flight for the old project reports "Created
      // CLAUDE.md" under a row belonging to the new one — a message about a
      // file the user is not looking at.
      const context = contextRef.current
      const current = (): boolean => context === contextRef.current

      setBusyFix(check.id)
      try {
        const result = await resolved.applyReadinessFix(projectPath, check.fix.id)
        if (!current()) return
        setResults((prev) => ({ ...prev, [check.id]: result }))
        // Re-scan whatever the outcome: a refusal usually means the world
        // already moved on, and the rows should show that rather than the
        // state they were rendered from.
        await scan()
      } catch (cause) {
        if (!current()) return
        setResults((prev) => ({
          ...prev,
          [check.id]: {
            ok: false,
            message: cause instanceof Error ? cause.message : String(cause),
            changed: [],
          },
        }))
      } finally {
        if (current()) setBusyFix(null)
      }
    },
    [projectPath, resolved, scan],
  )

  /**
   * Put a row away, and remember it.
   *
   * The write happens inside the updater so the stored map and the rendered one
   * are the same object — a `writeDismissed(put)` outside it would persist the
   * state from *before* this click on any render React batches.
   */
  const putAway = useCallback(
    (check: ReadinessCheck) => {
      setPut((prev) => {
        const next = dismiss(prev, projectPath, check.id)
        writeDismissed(next)
        return next
      })
    },
    [projectPath],
  )

  const bringBack = useCallback(() => {
    setPut((prev) => {
      const next = restoreAll(prev, projectPath)
      writeDismissed(next)
      return next
    })
  }, [projectPath])

  const openFile = useCallback(
    (check: ReadinessCheck) => {
      if (!resolved?.openLinkExternally || check.opens === null) return
      void resolved.openLinkExternally(fileUrlFor(projectPath, check.opens))
    },
    [projectPath, resolved],
  )

  const rows = useMemo(() => (report ? sortChecks(report.checks) : []), [report])
  const passing = rows.filter((check) => check.status === 'pass').length
  const applicable = rows.filter((check) => check.status !== 'skip').length
  /*
   * Hidden rows are hidden and nothing else. They are still in `rows`, so they
   * are still counted above and still weighted by `scoreChecks` in the main
   * process — dismissing a finding must never move the number, or the number
   * stops meaning anything and the panel becomes the sort of control this
   * release exists to remove.
   */
  const away = new Set(idsFor(put, projectPath))
  const shown = rows.filter((check) => !away.has(check.id))
  const hidden = rows.length - shown.length

  if (!resolved) {
    return (
      <section className="readiness">
        <PageEmpty icon={panelSpec('readiness').icon} title="AI readiness is not available here">
          This window was opened without the readiness bridge.
        </PageEmpty>
      </section>
    )
  }

  return (
    <section className="readiness" aria-label="AI readiness">
      <header className="readiness-head">
        {report ? <ScoreRing score={report.score} band={report.band} /> : <div className="readiness-ring" />}
        <div className="readiness-headline">
          {report ? (
            <>
              <p className="readiness-band" data-band={report.band}>
                {BAND_COPY[report.band]}
              </p>
              {/* The number in the ring is a *weighted* score out of 100 —
                  `scoreChecks` gives every check a share of it — so "87" and
                  "7 of 10" are both true and do not follow from one another.
                  Printing the count alone left the 87 unexplained and looking
                  like arithmetic that had gone wrong; the word "weighted" is
                  the whole of what the trailing clause was doing, and the rest
                  of it moves to the hover. */}
              <p
                className="readiness-summary"
                title="Each check carries a share of the score, sized by how much it matters."
              >
                {report.score} out of 100 — {passing} of {applicable} checks passing, weighted.
              </p>
            </>
          ) : (
            <p className="readiness-summary">{error ? 'Scan failed' : 'Scanning…'}</p>
          )}
        </div>
        <button type="button" className="readiness-rescan" onClick={() => void scan()} disabled={scanning}>
          {scanning ? 'Scanning…' : 'Rescan'}
        </button>
      </header>

      {error ? <p className="readiness-error">{error}</p> : null}

      {report?.cappedBy ? (
        <p className="readiness-cap" role="status">
          Score held at {report.score} by <strong>{report.cappedBy}</strong> — fix that first.
        </p>
      ) : null}

      {/* Not a project finding, and it is here because this is one of the two
          places a person is standing when it bites them. See `AgentCliUpdate`.
          It draws nothing at all when every agent CLI on the machine is current,
          which is the usual case. */}
      <div className="readiness-machine">
        <AgentCliUpdate />
      </div>

      <ul className="readiness-list">
        {shown.map((check) => (
          <CheckRow
            key={check.id}
            check={check}
            busy={busyFix === check.id}
            result={results[check.id] ?? null}
            onApply={(target) => void applyFix(target)}
            onOpen={resolved.openLinkExternally ? openFile : null}
            onDismiss={putAway}
          />
        ))}
      </ul>

      {/*
        The door back, and the sentence that keeps dismissal honest.

        Both halves matter. "Don't ask again" with no way to un-ask it was
        called out by name in the same review — *"once ticked there is no way to
        turn it back on. That has to exist."* And saying that a hidden check
        still counts is what stops this from being a button that raises your
        score by looking away.
      */}
      {hidden > 0 ? (
        <p className="readiness-hidden">
          {hidden === 1 ? '1 check hidden' : `${hidden} checks hidden`} — still counted in the
          score.{' '}
          <button type="button" className="readiness-link" onClick={bringBack}>
            Show {hidden === 1 ? 'it' : 'them'} again
          </button>
        </p>
      ) : null}
    </section>
  )
}
