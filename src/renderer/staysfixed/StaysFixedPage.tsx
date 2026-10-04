import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { STAYS_FIXED } from '../../shared/stays-fixed'
import { HoverNote } from '../components/HoverNote'
import { PageEmpty } from '../components/PageEmpty'
import { Switch } from '../settings/controls'
import type { PanelId } from '../shell/panels'
import {
  asCheck,
  asMark,
  asReadiness,
  asResults,
  asSetup,
  asStatus,
  resolveStaysFixedBridge,
  type FixedDifference,
  type FixedMarkOutcome,
  type FixedReadiness,
  type FixedResults,
  type StaysFixedBridge,
  type StaysFixedStatus,
} from './bridge'
import { agentNames, count, elapsed, headline, listWords, picturesOf, sentenceCase, startedBy, statusTone, subline } from './model'
import './StaysFixedPage.css'

/**
 * A project's Stays Fixed page.
 *
 * ## What it is for, in the owner's terms
 *
 * Stays Fixed is his own tool: after an agent changes code, it proves that what
 * already worked still works, and reports only the differences nobody asked
 * for. This page is that tool for somebody who has never opened a terminal —
 * one button to set it up, one to check, one to say "this build is good" — and
 * the agents in this project get the same engine as tools of their own.
 *
 * ## Two states, and what each one shows
 *
 * **Not set up**: one line saying what it is, a Set up button, and what this
 * Mac can and cannot check here with the exact fix for each gap — Stays Fixed's
 * own `doctor`, which already writes its gaps for a person.
 *
 * **Set up**: the last check's verdict and when, the build marked as good, Run
 * check (with the engine's own steps while it runs), the differences nobody
 * asked for — with a before and an after picture where the check kept them —
 * and everything unchanged as **one line**, never a list. Then the guards, the
 * agents' switch, and, folded away, what this Mac can check.
 *
 * ## Words
 *
 * The owner's rule for this app is no sentences nobody needs: *"We want
 * simplicity."* So every explanation that is not the answer itself is behind
 * an ⓘ (`HoverNote`), and the page body is verdicts, values and buttons.
 */

interface Props {
  projectPath: string
  onShowPanel?(id: PanelId): void
  /** For tests; the page reads `window.deck` otherwise. */
  bridge?: Partial<StaysFixedBridge>
}

const SHIELD = 'M12 3.5l7 2.6v5.4c0 4.2-2.9 7.7-7 9-4.1-1.3-7-4.8-7-9V6.1zM9 12.2l2.1 2.1 4-4.3'

function Glyph({ path, className }: { path: string; className?: string }) {
  return (
    <svg
      className={className}
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={path} />
    </svg>
  )
}

const TONE_GLYPH = {
  positive: 'M5 12.5l4.2 4.2L19 7',
  warning: 'M12 7v6M12 16.8v.2',
  critical: 'M7 7l10 10M17 7L7 17',
  muted: 'M7 12h10',
} as const

export function StaysFixedPage({ projectPath, onShowPanel, bridge: given }: Props) {
  const bridge = useMemo(() => given ?? resolveStaysFixedBridge(), [given])
  const [status, setStatus] = useState<StaysFixedStatus | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [busy, setBusy] = useState<'setup' | 'check' | 'mark' | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [mark, setMark] = useState<FixedMarkOutcome | null>(null)
  const [readiness, setReadiness] = useState<{ value: FixedReadiness | null; message: string | null } | null>(null)
  const [readinessOpen, setReadinessOpen] = useState(false)
  const [full, setFull] = useState<FixedResults | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const loading = useRef(false)
  const again = useRef(false)

  const load = useCallback(async () => {
    if (!bridge.staysFixedStatus) {
      setLoadError(`${STAYS_FIXED} is not wired into this build.`)
      return
    }
    // One read at a time; a burst of pushes while one is in flight is one more read.
    if (loading.current) {
      again.current = true
      return
    }
    loading.current = true
    try {
      do {
        again.current = false
        const raw = await bridge.staysFixedStatus(projectPath)
        setStatus(asStatus(raw, projectPath))
        setLoadError(null)
      } while (again.current)
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : String(error))
    } finally {
      loading.current = false
    }
  }, [bridge, projectPath])

  useEffect(() => {
    setStatus(null)
    setReadiness(null)
    setReadinessOpen(false)
    setMark(null)
    setProblem(null)
    setFull(null)
    void load()
  }, [load])

  useEffect(() => {
    if (!bridge.onStaysFixedChanged) return
    return bridge.onStaysFixedChanged((path) => {
      if (path === projectPath) void load()
    })
  }, [bridge, projectPath, load])

  const running = status?.running ?? null
  // Keyed on *whether* a check runs, not on the progress object: every step of
  // the check is a new object, and re-arming the clock on each one meant a
  // check reporting a step a second never let the clock tick at all.
  const isRunning = running !== null
  useEffect(() => {
    if (!isRunning) return
    setNow(Date.now())
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [isRunning])

  const loadReadiness = useCallback(
    async (refresh: boolean) => {
      if (!bridge.staysFixedReadiness) return
      setReadiness(null)
      try {
        const answer = asReadiness(await bridge.staysFixedReadiness(projectPath, refresh))
        setReadiness({ value: answer.readiness, message: answer.message })
      } catch (error) {
        setReadiness({ value: null, message: error instanceof Error ? error.message : String(error) })
      }
    },
    [bridge, projectPath],
  )

  // A folder that is not set up shows what this Mac can check straight away;
  // a set-up one keeps it folded until asked, because it takes a while.
  const setUp = status?.setUp ?? null
  useEffect(() => {
    if (setUp === false && status?.available) void loadReadiness(false)
  }, [setUp, status?.available, loadReadiness])

  const runSetup = async (): Promise<void> => {
    if (!bridge.staysFixedSetup) return
    setBusy('setup')
    setProblem(null)
    try {
      const outcome = asSetup(await bridge.staysFixedSetup(projectPath))
      if (!outcome.ok) setProblem(outcome.problem)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(null)
      await load()
    }
  }

  const runCheck = async (): Promise<void> => {
    if (!bridge.staysFixedCheck) return
    setBusy('check')
    setProblem(null)
    setMark(null)
    setFull(null)
    // The status read right after the press is what turns the button into Stop
    // and shows the first step; the push from the main process follows it.
    const started = bridge.staysFixedCheck(projectPath)
    void load()
    try {
      const answer = asCheck(await started)
      if (answer.message) setProblem(answer.message)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(null)
      await load()
    }
  }

  const stop = async (): Promise<void> => {
    await bridge.staysFixedStop?.(projectPath)
    await load()
  }

  const markGood = async (anyway: boolean): Promise<void> => {
    if (!bridge.staysFixedMarkGood) return
    setBusy('mark')
    setMark(null)
    try {
      setMark(asMark(await bridge.staysFixedMarkGood(projectPath, anyway)))
    } catch (error) {
      setMark({ ok: false, marked: false, already: false, refused: null, refusedFor: null, summary: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
      await load()
    }
  }

  const setAgents = async (on: boolean): Promise<void> => {
    if (!bridge.staysFixedAgents) return
    setStatus((current) => (current ? { ...current, agents: on } : current))
    try {
      setStatus(asStatus(await bridge.staysFixedAgents(projectPath, on), projectPath))
    } catch {
      await load()
    }
  }

  const openFull = async (): Promise<void> => {
    if (!bridge.staysFixedResults) return
    setFull(asResults(await bridge.staysFixedResults(projectPath, true)))
  }

  if (loadError && !status) {
    return <PageEmpty icon={SHIELD} title={`${STAYS_FIXED} could not be read`}>{loadError}</PageEmpty>
  }
  if (!status) return <div className="sf" aria-busy="true" />
  if (!status.available) {
    return (
      <PageEmpty icon={SHIELD} title={`${STAYS_FIXED} is not part of this build`}>
        {status.unavailable ?? ''}
      </PageEmpty>
    )
  }

  if (!status.setUp) {
    return (
      <section className="sf" aria-label={STAYS_FIXED}>
        <header className="sf-head">
          <div className="sf-verdict" data-tone="muted">
            <span className="sf-verdict-mark" aria-hidden="true">
              <Glyph path={SHIELD} />
            </span>
            <div className="sf-verdict-text">
              <h2 className="sf-headline">Not set up in this project</h2>
              <p className="sf-subline">
                After you or an agent change something, {STAYS_FIXED} checks that nothing that already worked has changed.
              </p>
            </div>
          </div>
          <div className="sf-actions">
            <button type="button" className="btn-primary" onClick={() => void runSetup()} disabled={busy === 'setup'}>
              {busy === 'setup' ? 'Setting up…' : 'Set up'}
            </button>
          </div>
        </header>
        {problem && <p className="sf-problem">{problem}</p>}
        <section className="sf-section sf-section-first" aria-label="On this Mac">
          <div className="sf-section-head">
            <h3 className="sf-section-title">On this Mac</h3>
            {readiness && (
              <button type="button" className="sf-link" onClick={() => void loadReadiness(true)}>
                Look again
              </button>
            )}
          </div>
          <Readiness state={readiness} onShowPanel={onShowPanel} />
        </section>
      </section>
    )
  }

  if (full) return <FullReport results={full} onBack={() => setFull(null)} />

  const tone = statusTone(status)
  const last = status.last

  return (
    <section className="sf" aria-label={STAYS_FIXED}>
      <header className="sf-head">
        <div className="sf-verdict" data-tone={tone}>
          <span className="sf-verdict-mark" aria-hidden="true">
            {running ? <span className="sf-spinner" /> : <Glyph path={TONE_GLYPH[tone]} />}
          </span>
          <div className="sf-verdict-text">
            <h2 className="sf-headline">{headline(status)}</h2>
            <p className="sf-subline">{subline(status, now)}</p>
          </div>
        </div>
        <div className="sf-actions">
          {running ? (
            <button type="button" className="sf-button" onClick={() => void stop()}>
              Stop
            </button>
          ) : (
            <button type="button" className="btn-primary" onClick={() => void runCheck()} disabled={busy !== null}>
              Run check
            </button>
          )}
          <button
            type="button"
            className="sf-button"
            onClick={() => void markGood(false)}
            disabled={running !== null || busy !== null}
          >
            {busy === 'mark' ? 'Marking…' : 'Mark this build as good'}
          </button>
          {last && !running && (
            <button type="button" className="sf-button" onClick={() => void openFull()}>
              Full report
            </button>
          )}
        </div>
      </header>

      {running && (
        <div className="sf-progress" role="status" aria-live="polite">
          <p className="sf-progress-step">{running.step}</p>
          <p className="sf-progress-meta">
            {startedBy(running)} · {elapsed(now - running.startedAt)}
          </p>
        </div>
      )}

      {problem && <p className="sf-problem">{problem}</p>}
      {!status.git && (
        // Set up works in a folder without git; a check does not — Stays Fixed
        // puts the old build back with git, and refuses rather than guess. So
        // the one thing in the way is said where the button that will fail is.
        <div className="sf-note" data-tone="warning" role="status">
          <p className="sf-note-text">This folder is not a git repository yet, so a check cannot run here.</p>
          {onShowPanel && (
            <button type="button" className="sf-button" onClick={() => onShowPanel('git')}>
              Source control
            </button>
          )}
        </div>
      )}
      {mark && (
        <MarkNote
          mark={mark}
          onAnyway={() => void markGood(true)}
          onCheck={() => void runCheck()}
          busy={busy !== null || running !== null}
        />
      )}
      {status.versionNote && <p className="sf-quiet">{status.versionNote}</p>}

      {last && !running && <Results results={last} />}

      <section className="sf-section" aria-label="Guards">
        <div className="sf-section-head">
          <h3 className="sf-section-title">Guards</h3>
          <HoverNote label="Guards">
            A guard is one rule, in plain words, for a bug that was already fixed once — so that bug can never come back
            unnoticed. Each one is a small file in .staysfixed/guards in this project; an agent can write one for you.
          </HoverNote>
        </div>
        {status.guardProblem && <p className="sf-problem">{status.guardProblem}</p>}
        {status.guards.length === 0 ? (
          <p className="sf-quiet">None yet.</p>
        ) : (
          <ul className="sf-guards">
            {status.guards.map((guard) => (
              <li key={guard.name} className="sf-guard">
                <Glyph path={SHIELD} className="sf-guard-mark" />
                <div>
                  <p className="sf-guard-name">{guard.name}</p>
                  {guard.because && <p className="sf-guard-because">{guard.because}</p>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="sf-section" aria-label="Agents">
        <div className="sf-row">
          <div className="sf-row-text">
            <p className="sf-row-title" id="sf-agents-title">
              Give agents {STAYS_FIXED}
            </p>
            <p className="sf-row-detail" id="sf-agents-detail">
              {agentNames()} sessions you start here can check their own work.
            </p>
          </div>
          <Switch
            checked={status.agents}
            labelledBy="sf-agents-title"
            describedBy="sf-agents-detail"
            onChange={(next) => void setAgents(next)}
          />
        </div>
      </section>

      <section className="sf-section" aria-label="What this Mac can check">
        <button
          type="button"
          className="sf-disclosure"
          aria-expanded={readinessOpen}
          onClick={() => {
            const next = !readinessOpen
            setReadinessOpen(next)
            if (next && readiness === null) void loadReadiness(false)
          }}
        >
          <Glyph path={readinessOpen ? 'M6 9l6 6 6-6' : 'M9 6l6 6-6 6'} />
          What this Mac can check
        </button>
        {readinessOpen && <Readiness state={readiness} onShowPanel={onShowPanel} />}
      </section>
    </section>
  )
}

/* ------------------------------------------------------------- results -- */

function Results({ results }: { results: FixedResults }) {
  return (
    <div className="sf-results">
      {results.differences.map((difference) => (
        <Difference key={difference.id} difference={difference} results={results} />
      ))}
      {results.unchanged && <p className="sf-unchanged">{results.unchanged}</p>}
      {results.notChecked && <p className="sf-quiet">{results.notChecked}</p>}
    </div>
  )
}

function Difference({ difference, results, all = false }: { difference: FixedDifference; results: FixedResults; all?: boolean }) {
  const pictures = picturesOf(results, difference.id)
  // Side by side shows that something moved; one above the other, each as wide
  // as the card, shows what. A press switches between the two.
  const [large, setLarge] = useState(false)
  return (
    <article className="sf-diff" data-person={difference.needsPerson || undefined}>
      <h4 className="sf-diff-title">{difference.title}</h4>
      {difference.needsPerson && <p className="sf-diff-person">{difference.needsPersonWhy}</p>}
      {pictures.map((picture) => (
        <div key={picture.journey} className="sf-pictures" data-large={large || undefined}>
          {(['before', 'after'] as const).map((side) =>
            picture[side] ? (
              <figure key={side} className="sf-picture">
                <button
                  type="button"
                  className="sf-picture-button"
                  onClick={() => setLarge(!large)}
                  aria-label={large ? 'Show the pictures side by side' : 'Show the pictures larger'}
                >
                  <img src={picture[side] ?? ''} alt={`${picture.journey}, ${side}`} />
                </button>
                <figcaption>{side === 'before' ? 'Before' : 'After'}</figcaption>
              </figure>
            ) : null,
          )}
        </div>
      ))}
      <ul className="sf-changes">
        {difference.changes.map((change, index) => (
          <li key={`${change.what}-${index}`} className="sf-change">
            <p className="sf-change-what">{change.what}</p>
            <div className="sf-values">
              <Value label="Before" text={change.kind === 'appeared' ? null : change.before} />
              <Value label="After" text={change.kind === 'vanished' ? null : change.after} />
            </div>
          </li>
        ))}
      </ul>
      {!all && difference.more > 0 && (
        <p className="sf-quiet">And {count(difference.more, 'more change')} — the full report has them.</p>
      )}
    </article>
  )
}

function Value({ label, text }: { label: string; text: string | null }) {
  return (
    <div className="sf-value">
      <span className="sf-value-label">{label}</span>
      {text === null ? <span className="sf-value-none">Not there</span> : <pre className="sf-value-text">{text}</pre>}
    </div>
  )
}

function MarkNote({
  mark,
  onAnyway,
  onCheck,
  busy,
}: {
  mark: FixedMarkOutcome
  onAnyway(): void
  onCheck(): void
  busy: boolean
}) {
  const tone = mark.marked || mark.already ? 'positive' : mark.refusedFor === 'differences' ? 'warning' : 'muted'
  return (
    <div className="sf-note" data-tone={tone} role="status">
      <p className="sf-note-text">{mark.summary}</p>
      {mark.refusedFor === 'differences' && (
        <button type="button" className="sf-button" onClick={onAnyway} disabled={busy}>
          Mark as good anyway
        </button>
      )}
      {mark.refusedFor === 'unchecked' && (
        <button type="button" className="sf-button" onClick={onCheck} disabled={busy}>
          Run check
        </button>
      )}
    </div>
  )
}

/* ----------------------------------------------------------- readiness -- */

function Readiness({
  state,
  onShowPanel,
}: {
  state: { value: FixedReadiness | null; message: string | null } | null
  onShowPanel?(id: PanelId): void
}) {
  if (state === null) {
    return (
      <p className="sf-quiet sf-looking">
        <span className="sf-spinner" aria-hidden="true" /> Looking at what this Mac can check…
      </p>
    )
  }
  if (state.value === null) return <p className="sf-problem">{state.message}</p>
  const r = state.value
  return (
    <div className="sf-readiness">
      {r.ready.length > 0 && (
        <p className="sf-ready">
          <Glyph path={TONE_GLYPH.positive} className="sf-ready-mark" />
          Can check {listWords(r.ready)}.
        </p>
      )}
      {r.gaps.length > 0 && (
        <ul className="sf-gaps">
          {r.gaps.map((gap, index) => (
            <li key={`${gap.name}-${gap.what}-${index}`} className="sf-gap">
              <p className="sf-gap-what">
                <span className="sf-gap-name">{sentenceCase(gap.name)}</span> needs {gap.what}.
                {gap.why && <HoverNote label={gap.what}>{gap.unlocks ? `${gap.why} It unlocks: ${gap.unlocks}` : gap.why}</HoverNote>}
              </p>
              {gap.fix && (
                <div className="sf-gap-fix">
                  <span className="sf-value-label">{gap.byPerson ? 'Only you can do this' : 'An agent can do this'}</span>
                  <Fix text={gap.fix} />
                  {gap.what === 'a git repository' && onShowPanel && (
                    <button type="button" className="sf-link" onClick={() => onShowPanel('git')}>
                      Source control
                    </button>
                  )}
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {r.notHere.length > 0 && <p className="sf-quiet">Not checked here: {listWords(r.notHere)}.</p>}
    </div>
  )
}

function Fix({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  const copy = (): void => {
    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    void clipboard?.writeText(text).then(
      () => {
        setCopied(true)
        window.setTimeout(() => setCopied(false), 1400)
      },
      () => setCopied(false),
    )
  }
  return (
    <span className="sf-fix">
      <code className="sf-fix-text">{text}</code>
      <button type="button" className="sf-link" onClick={copy}>
        {copied ? 'Copied' : 'Copy'}
      </button>
    </span>
  )
}

/* --------------------------------------------------------- full report -- */

function FullReport({ results, onBack }: { results: FixedResults; onBack(): void }) {
  return (
    <section className="sf sf-report" aria-label={`${STAYS_FIXED} full report`}>
      <div className="sf-report-head">
        <button type="button" className="sf-button" onClick={onBack}>
          Back
        </button>
        <h2 className="sf-headline">{results.headline}</h2>
      </div>
      {results.detail && <p className="sf-report-detail">{results.detail}</p>}
      <div className="sf-results">
        {results.differences.map((difference) => (
          <Difference key={difference.id} difference={difference} results={results} all />
        ))}
        {results.unchanged && <p className="sf-unchanged">{results.unchanged}</p>}
      </div>
      {results.gaps.length > 0 && (
        <section className="sf-section" aria-label="Not looked at">
          <h3 className="sf-section-title">Not looked at</h3>
          <ul className="sf-gaps">
            {results.gaps.map((gap, index) => (
              <li key={`${gap.what}-${index}`} className="sf-gap">
                <p className="sf-gap-what">{gap.what}</p>
                {gap.why && <p className="sf-quiet">{gap.why}</p>}
                {gap.unlockedBy && <p className="sf-quiet">To change that: {gap.unlockedBy}</p>}
              </li>
            ))}
          </ul>
        </section>
      )}
    </section>
  )
}
