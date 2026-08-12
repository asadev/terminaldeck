import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
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
}

export interface ReadinessPanelProps {
  /** Absolute path of the project to score. */
  projectPath: string
  /** Injectable for tests; defaults to the preload bridge on `window.pawl`. */
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
  const host = (window as unknown as { pawl?: Partial<ReadinessBridge> }).pawl
  if (!host || typeof host.scanReadiness !== 'function' || typeof host.applyReadinessFix !== 'function') {
    return null
  }
  return host as ReadinessBridge
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
}

export function CheckRow({ check, busy, result, onApply }: RowProps) {
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
      <span className="readiness-glyph" title={STATUS_LABEL[check.status]} aria-hidden="true">
        {GLYPH[check.status]}
      </span>
      <div className="readiness-row-body">
        <div className="readiness-row-head">
          <span className="readiness-title">{check.title}</span>
          <span className="readiness-status-label">{STATUS_LABEL[check.status]}</span>
          {check.gate && check.status !== 'pass' ? (
            <span className="readiness-gate-tag">caps the score</span>
          ) : null}
        </div>
        <p className="readiness-detail">{check.detail}</p>

        {fix && confirming ? (
          <p className="readiness-fix-description">{fix.description}</p>
        ) : null}

        {result ? (
          <p className="readiness-result" data-ok={result.ok}>
            {result.message}
          </p>
        ) : null}
      </div>

      {fix ? (
        <div className="readiness-actions">
          {confirming ? (
            <button type="button" className="readiness-cancel" onClick={() => setConfirming(false)}>
              Cancel
            </button>
          ) : null}
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

  const rows = useMemo(() => (report ? sortChecks(report.checks) : []), [report])
  const passing = rows.filter((check) => check.status === 'pass').length
  const applicable = rows.filter((check) => check.status !== 'skip').length

  if (!resolved) {
    return (
      <section className="readiness">
        <p className="readiness-empty">Readiness is not available in this window.</p>
      </section>
    )
  }

  return (
    <section className="readiness" aria-label="AI readiness">
      <header className="readiness-head">
        {report ? <ScoreRing score={report.score} band={report.band} /> : <div className="readiness-ring" />}
        <div className="readiness-headline">
          <h2 className="readiness-heading">AI readiness</h2>
          {report ? (
            <>
              <p className="readiness-band" data-band={report.band}>
                {BAND_COPY[report.band]}
              </p>
              <p className="readiness-summary">
                {passing} of {applicable} checks passing
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
          Score held at {report.score} by <strong>{report.cappedBy}</strong>. A project that exposes
          credentials cannot score well here, however complete the rest of it is.
        </p>
      ) : null}

      <ul className="readiness-list">
        {rows.map((check) => (
          <CheckRow
            key={check.id}
            check={check}
            busy={busyFix === check.id}
            result={results[check.id] ?? null}
            onApply={(target) => void applyFix(target)}
          />
        ))}
      </ul>
    </section>
  )
}
