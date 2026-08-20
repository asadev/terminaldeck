import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { panelSpec } from '../shell/panels'
import { AgentCliUpdate } from './AgentCliUpdate'
import { PageEmpty } from './PageEmpty'
import { Pill, PillRow } from './Pill'
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

/**
 * The same project graded for one named agent. Mirrors `ReadinessForAgent` in
 * `src/main/readiness.ts`, where the argument for it is written down.
 */
export interface ReadinessForAgent {
  agent: string
  label: string
  file: string
  check: ReadinessCheck
  score: number
  band: ReadinessBand
  cappedBy: string | null
}

export interface ReadinessReport {
  projectPath: string
  score: number
  band: ReadinessBand
  checks: ReadinessCheck[]
  cappedBy: string | null
  /**
   * One entry per agent whose instructions file the scan knows.
   *
   * Optional, and read as `[]` when it is absent, for the reason every mirror
   * in this file is defensive: what arrives is an IPC payload, and a window
   * whose main process predates this field would otherwise take the page down
   * inside a `.map`. No entries means no pills, which is the honest degrade —
   * there is nothing to switch between.
   */
  agents?: ReadinessForAgent[]
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

/**
 * The report as one agent sees it — the instructions row swapped, and the score
 * that follows from the swap.
 *
 * Pure, exported and tested, because it is the join that can silently come
 * apart: a page that swapped the row and left the ring showing the neutral
 * number would be *"1 of 5 checks passing"* over twelve rows all over again,
 * one release later. `scanReadiness` scored each variant with the same
 * `scoreChecks` the neutral one went through, so everything here is a
 * substitution and nothing is arithmetic.
 *
 * A pick this report has no entry for — an agent that left the catalogue
 * between the scan and the click — falls back to the neutral view rather than
 * to an empty one.
 */
export interface ReadinessView {
  checks: ReadinessCheck[]
  score: number
  band: ReadinessBand
  cappedBy: string | null
  /** The agent this view is graded for, or null for the project's own answer. */
  agent: ReadinessForAgent | null
}

export function reportFor(report: ReadinessReport, agent: string | null): ReadinessView {
  const picked = agent === null ? null : (report.agents ?? []).find((entry) => entry.agent === agent)
  if (!picked) {
    return {
      checks: report.checks,
      score: report.score,
      band: report.band,
      cappedBy: report.cappedBy,
      agent: null,
    }
  }
  return {
    checks: report.checks.map((check) => (check.id === picked.check.id ? picked.check : check)),
    score: picked.score,
    band: picked.band,
    cappedBy: picked.cappedBy,
    agent: picked,
  }
}

/**
 * The line under the band, and the arithmetic it has to survive.
 *
 * Asad, on the readiness page, reading *"38 out of 100 — 1 of 5 checks passing,
 * weighted"* above twelve rows:
 *
 *   > *"Maybe you know the reason why it is at risk, AI readiness."*
 *
 * The reasons were printed — every row carried one. What was missing is why the
 * headline counted five things while the page listed twelve: seven of them were
 * *skipped*, which the scan decides ("No package.json to look for a lint script
 * in") and the score honours by leaving them out of the denominator. The page
 * showed skipped rows in the same list, in the same shape, with nothing saying
 * they were outside the count.
 *
 * So the count says which five it means, and how many rows it is not counting.
 * Add the two and you have the rows on screen, which is the property that was
 * missing rather than a longer sentence for its own sake.
 */
export function headlineFor(
  score: number,
  passing: number,
  applicable: number,
  skipped: number,
): string {
  const counted = `${score} out of 100 — ${passing} of ${applicable} applicable check${applicable === 1 ? '' : 's'} passing, weighted`
  return skipped === 0 ? `${counted}.` : `${counted} · ${skipped} not applicable here.`
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

/**
 * The pills that choose what this page is a report on.
 *
 * Its own component so it can be rendered on its own in a test, which is where
 * the rule about offering every agent is pinned. `neutral-naming.test.ts` says
 * so in as many words: *"whether a screen could support three agents is a
 * question about what the code behind it can do, and no scan over string
 * literals can answer it… it is checked by the screens' own tests."* This is
 * that test's subject.
 *
 * Nothing at all when the scan answered for no agents — a build whose main
 * process predates the per-agent report. A lone "Any agent" pill with nothing
 * to switch to is a control that cannot be used, which is the one thing this
 * window is not allowed to have.
 */
export function AgentPills({
  agents,
  pick,
  onPick,
}: {
  agents: readonly ReadinessForAgent[]
  pick: string | null
  onPick(agent: string | null): void
}) {
  if (agents.length === 0) return null
  return (
    <PillRow label="Which agent this page is graded for" lead="Report on">
      <Pill
        on={pick === null}
        title="Any agent — passes if any of their instructions files is here"
        onClick={() => onPick(null)}
      >
        Any agent
      </Pill>
      {agents.map((entry) => (
        <Pill
          key={entry.agent}
          on={pick === entry.agent}
          title={`Grade this project for ${entry.label}, which reads ${entry.file}`}
          onClick={() => onPick(entry.agent)}
        >
          {entry.label}
        </Pill>
      ))}
    </PillRow>
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
  /*
   * Which agent the page is graded for, or null for the project's own answer.
   *
   * Held here rather than remembered across launches, deliberately: it is a
   * question about what you are reading right now, and a pill that came back
   * pressed from three weeks ago would grade somebody's next project against an
   * agent they picked once for a different one. `readiness-dismissed.ts` stores
   * what it stores because a dismissal is a decision about a *project*; this is
   * not one.
   */
  const [pick, setPick] = useState<string | null>(null)

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
    // The agent goes back to the project's own answer with the project. A pill
    // left pressed across a change of folder would put the previous project's
    // question on this one's page.
    setPick(null)
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

  /*
   * The report as the chosen agent sees it. `reportFor` carries the whole of
   * the substitution — see the note there — so the ring, the headline and the
   * rows are three readings of one object rather than three of two.
   */
  const view = useMemo(() => (report ? reportFor(report, pick) : null), [report, pick])
  const rows = useMemo(() => (view ? sortChecks(view.checks) : []), [view])
  const passing = rows.filter((check) => check.status === 'pass').length
  const applicable = rows.filter((check) => check.status !== 'skip').length
  const skipped = rows.length - applicable
  /** Every agent this scan answered for, and the pills that switch between them. */
  const agents = report?.agents ?? []
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
        {view ? <ScoreRing score={view.score} band={view.band} /> : <div className="readiness-ring" />}
        <div className="readiness-headline">
          {view ? (
            <>
              <p className="readiness-band" data-band={view.band}>
                {BAND_COPY[view.band]}
              </p>
              {/* The number in the ring is a *weighted* score out of 100 —
                  `scoreChecks` gives every check a share of it — so "87" and
                  "7 of 10" are both true and do not follow from one another.
                  Printing the count alone left the 87 unexplained and looking
                  like arithmetic that had gone wrong; the word "weighted" is
                  the whole of what the trailing clause was doing, and the rest
                  of it moves to the hover. The count itself is `headlineFor`,
                  which is where the twelve-rows-over-five problem is answered. */}
              <p
                className="readiness-summary"
                title="Each check carries a share of the score, sized by how much it matters."
              >
                {headlineFor(view.score, passing, applicable, skipped)}
              </p>
              {/* Which target this is a report on, said in the header — the
                  pills below say it too, and a pressed pill is a control's
                  state rather than a sentence somebody reads. Absent for the
                  project's own answer, where there is no target to name. */}
              {view.agent ? (
                <p className="readiness-target">
                  Graded for {view.agent.label} · reads {view.agent.file}
                </p>
              ) : null}
            </>
          ) : (
            <p className="readiness-summary">{error ? 'Scan failed' : 'Scanning…'}</p>
          )}
        </div>
        <button type="button" className="readiness-rescan" onClick={() => void scan()} disabled={scanning}>
          {scanning ? 'Scanning…' : 'Rescan'}
        </button>
      </header>

      {/*
        What this page is reporting on, as pills.

        Asad: *"So maybe here we also need pills to switch between and see MCP
        server and machine."* This is the agent half of that, and it is the half
        this page has something to switch: one of these ten checks is about an
        agent rather than about the project, and until now it was about an
        unnamed one. Pressing a pill re-reads nothing — the scan already
        answered for every agent, so the swap is instant and cannot disagree
        with the ring.

        There is no machine pill here, and that is an absence rather than an
        omission: no frame on the wire carries a paired machine's project
        readiness, so a pill for one could only lead to an apology. The MCP
        servers page *can* report on another machine — its connectors ride the
        controls frame — and it has the machine pills for that reason.

        Drawn only when there is more than one thing to be, which is his most
        repeated rule about controls: *"a dropdown only when some exist."*
      */}
      <AgentPills agents={agents} pick={pick} onPick={setPick} />

      {error ? <p className="readiness-error">{error}</p> : null}

      {view?.cappedBy ? (
        <p className="readiness-cap" role="status">
          Score held at {view.score} by <strong>{view.cappedBy}</strong> — fix that first.
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
        {shown.map((check, index) => (
          <Fragment key={check.id}>
            {/*
              Where the counted rows stop.

              `sortChecks` has always put the skipped ones last; nothing said so
              on screen, so twelve rows sat in one list under a headline that
              counted five of them. One caption at the seam is the whole fix —
              it needs no count of its own, because the headline above carries
              both numbers and two places counting the same rows is how they
              come to disagree.
            */}
            {check.status === 'skip' && (index === 0 || shown[index - 1]?.status !== 'skip') ? (
              <li className="readiness-aside">Not applicable to this project</li>
            ) : null}
            <CheckRow
              check={check}
              busy={busyFix === check.id}
              result={results[check.id] ?? null}
              onApply={(target) => void applyFix(target)}
              onOpen={resolved.openLinkExternally ? openFile : null}
              onDismiss={putAway}
            />
          </Fragment>
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
