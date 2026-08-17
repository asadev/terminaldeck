/**
 * The one thing in this window that asks the main process for alerts.
 *
 * `src/main/alerts.ts` has no push side. The panel asks and it answers, and the
 * answer costs a scan of up to forty transcripts, a `git status`, a `stat` of
 * every dirty file and a `which` probe through a login shell. That price is why
 * the bell's count was left unwired: the sheet only mounts while it is open, so
 * closing it left nothing producing reports, and the obvious fix — run the scan
 * on a timer so the dot is always right — is a background cost the window was
 * not willing to pay for a dot.
 *
 * ## Events, not polling
 *
 * The standing rule in this project is that the main process pushes and the
 * renderer subscribes; `schedule.ts` says it at the top and lists the two kinds
 * of thing allowed to keep a clock. So this feed scans when something happened
 * that could change an alert, and at no other time. An app sitting idle with a
 * folder open does zero scans, for as long as it sits there.
 *
 * The signal it subscribes to is **session status**, and that is not a
 * compromise — it is the closest thing this app has to "the project changed".
 * Every one of the six rules in `alerts.ts` is about work: a session blocked on
 * a question, a context filling up, tokens moving, a tree going dirty under a
 * run, a CLI that a session needs and cannot find. All of them are downstream
 * of an agent doing something, and an agent doing something moves its status
 * through `idle → working → input → idle` on the very channel this window is
 * already listening to for the sidebar's dots. Sessions starting and exiting
 * are in for the same reason and cost nothing — they are rare.
 *
 * What is deliberately *not* subscribed to is `git:status-changed` and
 * `cost:update`. Both would be more direct signals for two of the rules, and
 * both require this window to hold a watch open on the project for the whole
 * session — `watchGit` and `watchProjectCost` are refcounted holds that the Git
 * panel and the usage strip take while they are on screen. Two permanent
 * filesystem watchers per project, to make a dot two seconds fresher than the
 * next status change would have made it, is the wrong trade. The bell learns
 * about a dirty tree the next time an agent does anything, which is also the
 * next time it matters.
 *
 * ## The one thing that genuinely needs a clock
 *
 * `BLOCKED_WARNING_MS` and `BLOCKED_CRITICAL_MS` turn a session that asked a
 * question into an alert after ten minutes, and a louder one after forty-five.
 * A blocked session is by definition not doing anything — nothing writes,
 * nothing is spent, no channel fires — so that alert comes into existence
 * purely because time passed. It cannot be an event.
 *
 * But it does not need a poll either. The moment a session enters `input` is an
 * event, and the two moments its alert changes are that moment plus two known
 * constants. So this arms **one wake-up at the exact deadline**, on the shared
 * scheduler, and re-arms for the next one when it fires. That is a timer with
 * one tick per threshold rather than one tick a minute forever, and behind a
 * hidden window `schedule.ts` disarms it entirely.
 *
 * ## Cost ceiling
 *
 * {@link MIN_SCAN_GAP_MS} is the floor between two scans. Status changes arrive
 * in bursts — five agents all finishing a turn — and each one is a full scan of
 * the project. Requests inside the floor coalesce into one scan at the end of
 * it, so a busy machine costs two scans a minute at most, which is what the
 * panel already cost while it was open, and an idle one costs none.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { AlertReport } from './components/AlertsPanel'
import { at } from './schedule'

/* ------------------------------------------------------------------ bounds -- */

/**
 * The shortest gap between two event-driven scans.
 *
 * A minute, and the number is measured rather than guessed. The panel used to
 * poll itself every sixty seconds while it was open, so a minute is the rate
 * this project has already decided a scan of every transcript is worth — and
 * making the always-on feed *faster* than the thing it replaced would be
 * spending more to show less. Instrumenting the running app with eleven live
 * sessions showed why the ceiling matters at all: status changes arrive
 * continuously on a busy machine, so without a floor this would scan on every
 * one of them, and with a thirty-second floor it settled at two scans a minute
 * indefinitely. One a minute at the very worst, none at all when nothing is
 * happening, is the shape that was wanted.
 *
 * The one alert this could make late is exempt: the blocked deadlines below
 * call the scan directly rather than through {@link AlertsFeed.rescan}'s
 * coalescing sibling, so the rule that is actually about a clock is never
 * delayed by the rule that is about cost. Everything else this report contains
 * — a dirty tree, a missing CLI, a context filling up, a session that moved a
 * million tokens — has been true for many minutes by the time it is worth
 * saying, and is not made wrong by arriving a minute after it became true.
 */
export const MIN_SCAN_GAP_MS = 60_000

/**
 * Mirrors of the two thresholds in `src/main/alerts.ts`.
 *
 * Duplicated rather than imported, for the reason `AlertsPanel` gives about the
 * alert types: the renderer tsconfig does not include `src/main`, so there is
 * no import to write. A duplicated constant is a constant that can drift, so
 * `alerts-feed.test.ts` reads the main-process file and fails if these two stop
 * agreeing with it — the check is cheap and the failure it prevents is silent
 * (a wake-up armed for a threshold that moved, so the bell lights minutes late
 * and nothing looks wrong).
 */
export const BLOCKED_WARNING_MS = 10 * 60 * 1000
export const BLOCKED_CRITICAL_MS = 45 * 60 * 1000

/* -------------------------------------------------------------------- gate -- */

/**
 * Latest-wins gate around the async scan.
 *
 * Two things went wrong without it, and both are invisible until they bite:
 *
 *  - **A superseded scan could still write.** Switching project cleared the
 *    report and started a new scan, but the *previous* project's scan was still
 *    in flight; whichever finished last won. A slow project handed its alerts
 *    to a different project's panel — naming sessions that are not in front of
 *    the user — which is exactly what the effect below claims it prevents.
 *  - **Refreshes stacked.** Requests arrived regardless of whether the last
 *    scan had finished, and a scan reads every transcript in the project. On a
 *    folder where one scan takes longer than the gap, that is unbounded pile-up
 *    on the main process.
 *
 * Kept as a plain object rather than as refs inside the hook so it can be
 * tested without a DOM — this project's renderer tests render to static markup
 * and never run an effect. It lived in `AlertsPanel.tsx` while the panel did
 * its own scanning; it moved here with the scanning.
 */
export interface ScanGate {
  /** Claim the next token. Anything already running is superseded. */
  begin(): number
  /** May the scan holding `token` write what it found? */
  isCurrent(token: number): boolean
  /** Mark the scan finished, whatever its outcome. */
  end(): void
  /** Is any scan still running? A request skips its turn when one is. */
  isBusy(): boolean
  /** Supersede everything in flight — a project switch, or unmount. */
  invalidate(): void
}

export function createScanGate(): ScanGate {
  let latest = 0
  let running = 0
  return {
    begin() {
      latest += 1
      running += 1
      return latest
    },
    isCurrent(token) {
      return token === latest
    },
    end() {
      running = Math.max(0, running - 1)
    },
    isBusy() {
      return running > 0
    },
    invalidate() {
      latest += 1
    },
  }
}

/* ---------------------------------------------------------------- schedule -- */

/**
 * How long a scan requested `now` has to wait for the floor.
 *
 * Zero when nothing has been scanned yet — the first look at a project is the
 * one nobody should have to wait for.
 */
export function scanDelayMs(
  lastScanAt: number | null,
  now: number,
  minGapMs: number = MIN_SCAN_GAP_MS,
): number {
  if (lastScanAt === null) return 0
  const waited = now - lastScanAt
  // A clock that went backwards (a manual change, an NTP step) would otherwise
  // park the feed for up to the whole gap. Treat it as due.
  if (waited < 0) return 0
  return waited >= minGapMs ? 0 : minGapMs - waited
}

/**
 * The next moment a blocked session's alert changes, or null if none will.
 *
 * Both thresholds are offered for every blocked session and the earliest future
 * one wins, so a second session blocking after the first has already crossed
 * ten minutes still gets its own wake-up.
 */
export function nextBlockedDeadline(blockedAt: Iterable<number>, now: number): number | null {
  let soonest: number | null = null
  for (const since of blockedAt) {
    for (const threshold of [BLOCKED_WARNING_MS, BLOCKED_CRITICAL_MS]) {
      const when = since + threshold
      if (when <= now) continue
      if (soonest === null || when < soonest) soonest = when
    }
  }
  return soonest
}

/* -------------------------------------------------------------------- hook -- */

/** The slice of the preload bridge this feed needs. */
export interface AlertsFeedBridge {
  projectAlerts(projectPath: string): Promise<AlertReport>
  onSessionStatus(cb: (id: string, status: string) => void): () => void
  onSessionCreated(cb: (meta: unknown) => void): () => void
  onSessionExit(cb: (id: string, exitCode: number) => void): () => void
}

/** What the bell and the sheet both read. One scan, one answer, no disagreement. */
export interface AlertsFeed {
  /** The latest report for the active project, or null before the first scan. */
  report: AlertReport | null
  /** A scan is running. The sheet's button says so and is disabled. */
  busy: boolean
  /** The last scan's failure, or null. */
  error: string | null
  /** Is there a main process to ask at all? */
  available: boolean
  /** "Check again" — scans immediately, because a person asking is not a burst. */
  rescan(): void
}

/**
 * Read defensively: alerts are wired into the preload separately, so this has
 * to explain itself rather than crash if it runs first.
 */
function resolveBridge(): AlertsFeedBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<AlertsFeedBridge> }).deck
  if (!host) return null
  if (
    typeof host.projectAlerts !== 'function' ||
    typeof host.onSessionStatus !== 'function' ||
    typeof host.onSessionCreated !== 'function' ||
    typeof host.onSessionExit !== 'function'
  ) {
    return null
  }
  return host as AlertsFeedBridge
}

export interface AlertsFeedOptions {
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: AlertsFeedBridge
  /**
   * Does this session belong to the project being watched?
   *
   * `session:status` is a machine-wide channel and carries no cwd, but a report
   * is about one folder: `alerts.ts` filters live sessions by `projectPath`
   * before any rule sees them, and transcripts are read from that project's
   * store alone. So an agent going idle in a *different* project cannot change
   * this project's alerts, and scanning forty transcripts to rediscover that is
   * the one avoidable cost in this design — the more avoidable the more
   * projects are open at once, which is the case this app exists for.
   *
   * Absent, every session counts, which is the safe direction: a scan too many
   * is waste, a scan too few is a bell that does not light.
   */
  sessionInProject?(sessionId: string): boolean
}

export function useProjectAlerts(
  projectPath: string | null,
  options: AlertsFeedOptions = {},
): AlertsFeed {
  const { bridge } = options
  const host = useMemo(() => bridge ?? resolveBridge(), [bridge])
  /*
   * Read through a ref, for the reason `useEvery` gives about its callback: the
   * caller builds this predicate from its session list, so it is a fresh
   * closure on every render, and putting it in the subscription's dependencies
   * would tear down and re-register three IPC listeners every time anything in
   * the window changed.
   */
  const inProject = useRef(options.sessionInProject)
  inProject.current = options.sessionInProject
  const [report, setReport] = useState<AlertReport | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const gate = useMemo(() => createScanGate(), [])
  const lastScanAt = useRef<number | null>(null)
  /** Cancels the coalesced scan already armed, or null when none is. */
  const armed = useRef<(() => void) | null>(null)
  /** Session id to the moment this window first saw it blocked on a question. */
  const blockedSince = useRef(new Map<string, number>())
  const [deadline, setDeadline] = useState<number | null>(null)

  const scan = useCallback(async () => {
    if (!host || projectPath === null) return
    const token = gate.begin()
    // Stamped before the work, not after: the floor is about how often this
    // window asks, and a scan that takes eight seconds has still asked once.
    lastScanAt.current = Date.now()
    setBusy(true)
    try {
      const next = await host.projectAlerts(projectPath)
      if (!gate.isCurrent(token)) return
      setReport(next)
      setError(null)
    } catch (err) {
      if (!gate.isCurrent(token)) return
      setError(err instanceof Error ? err.message : 'Could not check this project.')
    } finally {
      gate.end()
      // A superseded scan leaves `busy` alone: the one that superseded it is
      // still running, and clearing the flag would re-enable the button.
      if (gate.isCurrent(token)) setBusy(false)
    }
  }, [gate, host, projectPath])

  /**
   * Something happened that could change an alert. Scan, or arm one.
   *
   * One armed wake-up at a time: a burst of twenty status changes inside the
   * floor is one scan, and it runs at the end of the floor rather than at the
   * start, so it sees the state the burst settled on rather than its first
   * frame.
   */
  const request = useCallback(() => {
    if (!host || projectPath === null) return
    if (armed.current) return
    const now = Date.now()
    const delay = gate.isBusy() ? MIN_SCAN_GAP_MS : scanDelayMs(lastScanAt.current, now)
    if (delay <= 0) {
      void scan()
      return
    }
    armed.current = at(now + delay, () => {
      armed.current = null
      void scan()
    })
  }, [gate, host, projectPath, scan])

  /**
   * Scan now, whatever the floor says, and drop anything already armed.
   *
   * Two callers, and both are cases where waiting would be wrong rather than
   * merely slow: the "Check again" button, because a person pressing a button
   * and watching nothing happen for fifty seconds has been told the button is
   * broken; and the blocked-session deadlines, because those are the one thing
   * in this report that exists purely because a known moment arrived, and
   * rounding that moment up to the next minute would make the only genuinely
   * time-critical alert the only late one.
   */
  const scanNow = useCallback(() => {
    armed.current?.()
    armed.current = null
    void scan()
  }, [scan])

  useEffect(() => {
    // A project switch must not leave the previous project's alerts on screen —
    // they name sessions that are not in front of the user any more. Clearing
    // the state is not enough on its own: the old project's scan is still in
    // flight and will happily write its result over the new project's.
    gate.invalidate()
    armed.current?.()
    armed.current = null
    lastScanAt.current = null
    // Blocked sessions are recorded per watched project, so the previous
    // project's entries would otherwise arm wake-ups for a report that cannot
    // contain them.
    blockedSince.current.clear()
    setDeadline(null)
    setReport(null)
    setError(null)
    void scan()
    return () => {
      gate.invalidate()
      armed.current?.()
      armed.current = null
    }
  }, [gate, scan])

  /**
   * The subscription the whole design rests on.
   *
   * `blockedSince` is this window's own record and not the main process's
   * `statusSince`, which is the honest limitation to state: a session that was
   * already sitting on a question before this window opened is first seen here
   * at whatever moment it next changes status, so its wake-up is armed late.
   * The scan itself is unaffected — `alerts.ts` reads the real `statusSince`
   * from the session registry — so the alert is correct whenever a scan runs;
   * what is lost is only the wake-up that would have run one on the dot. Every
   * other status change on the machine covers it, and the sheet's own open is a
   * scan.
   */
  useEffect(() => {
    if (!host) return
    const mine = (id: string): boolean => inProject.current?.(id) ?? true
    const offStatus = host.onSessionStatus((id, status) => {
      if (!mine(id)) return
      const map = blockedSince.current
      if (status === 'input') {
        if (!map.has(id)) map.set(id, Date.now())
      } else {
        map.delete(id)
      }
      setDeadline(nextBlockedDeadline(map.values(), Date.now()))
      request()
    })
    const offCreated = host.onSessionCreated(() => request())
    const offExit = host.onSessionExit((id) => {
      // Not gated on `mine`: a session that has exited may already be gone from
      // the caller's list, so the predicate would answer "not this project"
      // for the very session whose departure changed it.
      blockedSince.current.delete(id)
      setDeadline(nextBlockedDeadline(blockedSince.current.values(), Date.now()))
      request()
    })
    return () => {
      offStatus()
      offCreated()
      offExit()
    }
  }, [host, request])

  /**
   * One wake-up, at the exact moment the blocked rule changes its mind.
   *
   * Re-armed from inside itself rather than from a `useEffect` dependency, so
   * the ten-minute wake-up schedules the forty-five-minute one without a render
   * in between.
   */
  useEffect(() => {
    if (deadline === null) return
    return at(deadline, () => {
      setDeadline(nextBlockedDeadline(blockedSince.current.values(), Date.now()))
      scanNow()
    })
  }, [deadline, scanNow])

  return { report, busy, error, available: host !== null, rescan: scanNow }
}
