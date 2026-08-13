import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { SessionMeta } from '@shared/types'
import { useEvery } from '../schedule'
import './DebugPanel.css'

/**
 * Debug mode.
 *
 * Hidden unless it is switched on, because everything here is either noise or a
 * liability in normal use: a live IPC trace, the process table, and a support
 * bundle that is only safe because the main process redacts it first.
 *
 * Two rules this panel is built around:
 *
 *  - It shows what main sends and nothing more. IPC *arguments* are never
 *    recorded on the main side, so there is nothing here to leak even if the
 *    window is screenshotted — a debug panel that printed call payloads would
 *    be a credential viewer with a table around it.
 *  - The bundle is formatted in main and copied verbatim. Reformatting it here
 *    would mean two copies of the layout, and the copy the user pastes into an
 *    issue would be the one nobody tested.
 *
 * The switch itself lives in localStorage rather than in preferences: this is a
 * per-window developer affordance, not a setting worth syncing, and keeping it
 * out of the preferences file means no shared type had to change to add it.
 */

/* ------------------------------------------------------------------ types -- */

/** Mirrors `IpcCallRecord` in `src/main/diagnostics.ts`. */
export interface IpcCallRecord {
  seq: number
  channel: string
  kind: 'invoke' | 'send'
  at: number
  ms: number
  ok: boolean
  error?: string
}

export interface LogTail {
  file: string
  lines: string[]
}

/** The slice of the preload bridge this panel needs. */
export interface DebugBridge {
  diagnosticsText(options?: { includeClis?: boolean; logLines?: number }): Promise<string>
  ipcLog(limit?: number): Promise<IpcCallRecord[]>
  clearIpcLog(): Promise<void>
  subscribeDebug(): Promise<boolean>
  unsubscribeDebug(): Promise<void>
  onIpcCall(cb: (record: IpcCallRecord) => void): () => void
  listSessions(): Promise<SessionMeta[]>
  recentLog(limit?: number): Promise<LogTail>
  openLogFolder(): Promise<string>
  clearLog(): Promise<void>
}

const BRIDGE_METHODS = [
  'diagnosticsText',
  'ipcLog',
  'clearIpcLog',
  'subscribeDebug',
  'unsubscribeDebug',
  'onIpcCall',
  'listSessions',
  'recentLog',
  'openLogFolder',
  'clearLog',
] as const

export function resolveDebugBridge(): DebugBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Record<string, unknown> }).deck
  if (!host) return null
  return BRIDGE_METHODS.every((name) => typeof host[name] === 'function')
    ? (host as unknown as DebugBridge)
    : null
}

/* -------------------------------------------------------------- the switch -- */

/**
 * Deliberately brand-neutral: the product name lives in `shared/brand.ts` and
 * nothing else may hardcode it, and a storage key cannot wait for an async
 * brand lookup.
 */
export const DEBUG_MODE_KEY = 'app:debug-mode'

export function readDebugMode(): boolean {
  // Guarded on `window` rather than on `localStorage` directly: node exposes a
  // localStorage getter that prints an experimental warning when touched, and
  // these run under vitest's node environment.
  if (typeof window === 'undefined') return false
  try {
    return window.localStorage?.getItem(DEBUG_MODE_KEY) === 'on'
  } catch {
    // Storage can be unavailable (a locked-down profile, a test harness).
    return false
  }
}

export function writeDebugMode(on: boolean): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage?.setItem(DEBUG_MODE_KEY, on ? 'on' : 'off')
  } catch {
    /* nothing to do — the toggle still works for this window */
  }
}

export function useDebugMode(): [boolean, (on: boolean) => void] {
  const [on, setOn] = useState(readDebugMode)
  const set = useCallback((next: boolean) => {
    writeDebugMode(next)
    setOn(next)
  }, [])
  return [on, set]
}

/* ---------------------------------------------------------------- helpers -- */

export function formatMs(ms: number): string {
  if (ms >= 1000) return `${(ms / 1000).toFixed(2)} s`
  if (ms >= 10) return `${Math.round(ms)} ms`
  return `${ms.toFixed(1)} ms`
}

export function formatClock(at: number): string {
  const date = new Date(at)
  const pad = (value: number, width = 2): string => String(value).padStart(width, '0')
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`
}

/** `4m 12s`, for how long a session has been alive. */
export function formatDuration(ms: number): string {
  if (ms < 0) return '0s'
  const seconds = Math.floor(ms / 1000)
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

export interface ChannelSummary {
  channel: string
  calls: number
  avgMs: number
  maxMs: number
  errors: number
}

/**
 * Roll the call log up per channel, worst average first.
 *
 * The raw trace answers "what just happened"; this answers "what is slow",
 * which is the question that actually gets asked after a week of use.
 */
export function summarizeCalls(records: readonly IpcCallRecord[]): ChannelSummary[] {
  const byChannel = new Map<string, { total: number; calls: number; max: number; errors: number }>()
  for (const record of records) {
    const entry = byChannel.get(record.channel) ?? { total: 0, calls: 0, max: 0, errors: 0 }
    entry.total += record.ms
    entry.calls += 1
    entry.max = Math.max(entry.max, record.ms)
    if (!record.ok) entry.errors += 1
    byChannel.set(record.channel, entry)
  }
  return [...byChannel.entries()]
    .map(([channel, entry]) => ({
      channel,
      calls: entry.calls,
      avgMs: Math.round((entry.total / entry.calls) * 10) / 10,
      maxMs: entry.max,
      errors: entry.errors,
    }))
    .sort((a, b) => b.avgMs - a.avgMs)
}

/**
 * Filter the trace and put the newest call first — the interesting one is the
 * one that just happened.
 */
export function orderCalls(records: readonly IpcCallRecord[], filter: string): IpcCallRecord[] {
  const needle = filter.trim().toLowerCase()
  const rows = needle ? records.filter((call) => call.channel.toLowerCase().includes(needle)) : records
  return [...rows].reverse()
}

/** Keeps the trace bounded — main caps its own ring buffer at the same order. */
const MAX_ROWS = 500

/** How often the process table and its uptime column move. */
const SESSION_TICK_MS = 2000

/* ----------------------------------------------------------------- tables -- */

/**
 * The trace, and the per-channel roll-up above it.
 *
 * Split out from the panel so it can be rendered with data — the panel fills
 * itself from effects, which means a static render can only ever show its empty
 * state, and the row markup would go unexercised.
 */
export function IpcTrace({ calls, filter }: { calls: readonly IpcCallRecord[]; filter: string }) {
  const rows = useMemo(() => orderCalls(calls, filter), [calls, filter])
  const summary = useMemo(() => summarizeCalls(calls).slice(0, 6), [calls])

  if (rows.length === 0) {
    return (
      <p className="debug-empty">
        {calls.length === 0 ? 'No calls recorded yet.' : 'No channel matches that filter.'}
      </p>
    )
  }

  return (
    <>
      {summary.length > 0 && (
        <table className="debug-table debug-summary">
          <thead>
            <tr>
              <th>Channel</th>
              <th>Calls</th>
              <th>Average</th>
              <th>Slowest</th>
              <th>Errors</th>
            </tr>
          </thead>
          <tbody>
            {summary.map((row) => (
              <tr key={row.channel}>
                <td className="debug-channel">{row.channel}</td>
                <td className="debug-number">{row.calls}</td>
                <td className="debug-number">{formatMs(row.avgMs)}</td>
                <td className="debug-number">{formatMs(row.maxMs)}</td>
                <td className="debug-number" data-bad={row.errors > 0 || undefined}>
                  {row.errors}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <div className="debug-scroll">
        <table className="debug-table">
          <thead>
            <tr>
              <th>Time</th>
              <th>Channel</th>
              <th>Kind</th>
              <th>Took</th>
              <th>Result</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((call) => (
              <tr key={call.seq} data-bad={!call.ok || undefined}>
                <td className="debug-number">{formatClock(call.at)}</td>
                <td className="debug-channel">{call.channel}</td>
                <td>{call.kind}</td>
                <td className="debug-number" data-slow={call.ms >= 250 || undefined}>
                  {formatMs(call.ms)}
                </td>
                <td className="debug-result">{call.ok ? 'ok' : (call.error ?? 'failed')}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}

/** Every session process this window knows about. */
export function SessionTable({ sessions, now }: { sessions: readonly SessionMeta[]; now: number }) {
  if (sessions.length === 0) return <p className="debug-empty">No sessions are running.</p>

  return (
    <div className="debug-scroll">
      <table className="debug-table">
        <thead>
          <tr>
            <th>Session</th>
            <th>Agent</th>
            <th>Folder</th>
            <th>Uptime</th>
            <th>State</th>
          </tr>
        </thead>
        <tbody>
          {sessions.map((session) => (
            <tr key={session.id} data-bad={(session.exitCode !== null && session.exitCode !== 0) || undefined}>
              {/* Eight characters is enough to tell two sessions apart and
                  short enough not to push the useful columns off the table. */}
              <td className="debug-channel">{session.id.slice(0, 8)}</td>
              <td>{session.provider}</td>
              <td className="debug-path" title={session.cwd}>
                {session.title}
              </td>
              <td className="debug-number">{formatDuration(now - session.createdAt)}</td>
              <td>{session.exitCode === null ? 'running' : `exited ${session.exitCode}`}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/**
 * The log tail.
 *
 * `null` and "read, and it had no lines" are different facts and are said
 * differently. Collapsing them printed "The log is empty" whenever the read had
 * failed or had not happened yet — a confident claim about a file the panel had
 * never opened, made in the one place someone is looking because they do not
 * trust what the app is telling them.
 */
export function LogView({ log }: { log: LogTail | null }) {
  if (!log) return <p className="debug-empty">The log has not been read yet.</p>

  return (
    <>
      <p className="debug-path debug-hint">{log.file}</p>
      {log.lines.length > 0 ? (
        <pre className="debug-pre">{log.lines.join('\n')}</pre>
      ) : (
        <p className="debug-empty">The log is empty.</p>
      )}
    </>
  )
}

/* ------------------------------------------------------------------ panel -- */

export interface DebugPanelProps {
  /**
   * Overrides the stored switch. Pass it when debug mode lives somewhere else
   * — a preference, a launch flag — and this component should just obey.
   */
  enabled?: boolean
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: DebugBridge | null
  /** Off in tests, where there is nothing to poll. */
  live?: boolean
}

export function DebugPanel({ enabled, bridge, live = true }: DebugPanelProps) {
  const [stored, setStored] = useDebugMode()
  const on = enabled ?? stored

  const resolved = useMemo(() => bridge ?? resolveDebugBridge(), [bridge])

  const [calls, setCalls] = useState<IpcCallRecord[]>([])
  const [paused, setPaused] = useState(false)
  const [filter, setFilter] = useState('')
  const [sessions, setSessions] = useState<SessionMeta[]>([])
  const [bundle, setBundle] = useState<string | null>(null)
  const [collecting, setCollecting] = useState(false)
  const [copied, setCopied] = useState(false)
  const [log, setLog] = useState<LogTail | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const pausedRef = useRef(paused)
  pausedRef.current = paused

  /* -- live IPC trace -- */
  useEffect(() => {
    if (!on || !resolved || !live) return
    let live_ = true

    // Every bridge call here is an IPC invoke, and an invoke rejects whenever
    // the handler in main throws. Without the rejection arm each of these was an
    // unhandled promise rejection — noise at best, and a hard exit under
    // `--unhandled-rejections=strict`.
    resolved.ipcLog(MAX_ROWS).then(
      (initial) => {
        // A bridge that answers with something other than a list would take the
        // trace down on the next render.
        if (live_ && Array.isArray(initial)) setCalls(initial)
      },
      () => {},
    )
    resolved.subscribeDebug().catch(() => {})

    const off = resolved.onIpcCall((record) => {
      // Read through a ref: re-subscribing on every pause would drop events in
      // the gap between unsubscribe and subscribe.
      if (pausedRef.current) return
      setCalls((prev) => {
        const next = [...prev, record]
        return next.length > MAX_ROWS ? next.slice(next.length - MAX_ROWS) : next
      })
    })

    return () => {
      live_ = false
      off()
      resolved.unsubscribeDebug().catch(() => {})
    }
  }, [on, resolved, live])

  /* -- session process table -- */
  const refreshSessions = useCallback(() => {
    if (!resolved) return
    void resolved.listSessions().then(setSessions, () => setSessions([]))
  }, [resolved])

  useEffect(() => {
    if (!on || !live) return
    refreshSessions()
  }, [on, live, refreshSessions])

  /**
   * The one tick in this file, and why it cannot be an event.
   *
   * This table's whole subject is a clock: the uptime column exists to answer
   * "how long has that pty been up", which changes for no reason other than
   * time passing and which no channel will ever announce. Re-listing the
   * sessions on the same tick is free beside it — one wake-up already spent —
   * and is what keeps the row set honest without a second subscription in a
   * panel that exists to be looked at rather than to be efficient.
   *
   * It costs nothing when nobody is debugging: this component is in
   * `reachable.test.ts`'s allowlist because it is mounted by hand, `live` is a
   * switch on the panel itself, and the shared tick stops entirely behind a
   * hidden window.
   */
  useEvery(on && live ? SESSION_TICK_MS : null, () => {
    refreshSessions()
    // State rather than `Date.now()` at render time, so the numbers move.
    setNow(Date.now())
  })

  /* -- log tail -- */
  const refreshLog = useCallback(() => {
    if (!resolved) return
    void resolved.recentLog(200).then(setLog, () => setLog(null))
  }, [resolved])

  useEffect(() => {
    if (!on || !live) return
    refreshLog()
  }, [on, live, refreshLog])

  const collect = useCallback(() => {
    if (!resolved) return
    setCollecting(true)
    setCopied(false)
    void resolved
      .diagnosticsText({ includeClis: true, logLines: 200 })
      .then(setBundle, (error: unknown) => setBundle(`Could not collect diagnostics: ${String(error)}`))
      .finally(() => setCollecting(false))
  }, [resolved])

  const copyBundle = useCallback(() => {
    if (!bundle) return
    void navigator.clipboard?.writeText(bundle).then(
      () => setCopied(true),
      () => setCopied(false),
    )
  }, [bundle])

  if (!on) return null

  return (
    <div className="debug">
      <header className="debug-head">
        <div>
          <h2 className="debug-title">Debug</h2>
          <p className="debug-subtitle">
            {resolved
              ? 'Live view of the main process. Nothing here leaves the machine unless you copy it.'
              : 'The debug bridge is not available in this window.'}
          </p>
        </div>
        {enabled === undefined && (
          <button type="button" className="debug-button" onClick={() => setStored(false)}>
            Turn off debug mode
          </button>
        )}
      </header>

      {/* ------------------------------------------------------------ ipc -- */}
      <section className="debug-section">
        <div className="debug-section-head">
          <h3 className="debug-section-title">IPC calls</h3>
          <div className="debug-controls">
            <input
              type="search"
              className="debug-filter"
              value={filter}
              placeholder="Filter channels"
              aria-label="Filter IPC channels"
              onChange={(event) => setFilter(event.target.value)}
            />
            <button
              type="button"
              className="debug-button"
              data-active={paused || undefined}
              onClick={() => setPaused((value) => !value)}
            >
              {paused ? 'Resume' : 'Pause'}
            </button>
            <button
              type="button"
              className="debug-button"
              onClick={() => {
                setCalls([])
                resolved?.clearIpcLog().catch(() => {})
              }}
            >
              Clear
            </button>
          </div>
        </div>

        <IpcTrace calls={calls} filter={filter} />
      </section>

      {/* -------------------------------------------------------- sessions -- */}
      <section className="debug-section">
        <div className="debug-section-head">
          <h3 className="debug-section-title">Session processes</h3>
          <button type="button" className="debug-button" onClick={refreshSessions}>
            Refresh
          </button>
        </div>

        <SessionTable sessions={sessions} now={now} />
      </section>

      {/* ------------------------------------------------------ diagnostics -- */}
      <section className="debug-section">
        <div className="debug-section-head">
          <h3 className="debug-section-title">Support bundle</h3>
          <div className="debug-controls">
            <button type="button" className="debug-button" onClick={collect} disabled={collecting || !resolved}>
              {collecting ? 'Collecting…' : bundle ? 'Recollect' : 'Collect'}
            </button>
            <button type="button" className="debug-button" onClick={copyBundle} disabled={!bundle}>
              {copied ? 'Copied' : 'Copy'}
            </button>
          </div>
        </div>

        <p className="debug-hint">
          Versions, detected CLIs, registered IPC modules, config paths and the recent log. Tokens,
          API keys, authorization headers and your home directory are stripped out before it leaves
          the main process — check it before you paste it anyway.
        </p>

        {bundle && <pre className="debug-pre">{bundle}</pre>}
      </section>

      {/* -------------------------------------------------------------- log -- */}
      <section className="debug-section">
        <div className="debug-section-head">
          <h3 className="debug-section-title">Log</h3>
          <div className="debug-controls">
            <button type="button" className="debug-button" onClick={refreshLog} disabled={!resolved}>
              Refresh
            </button>
            <button
              type="button"
              className="debug-button"
              onClick={() => resolved?.openLogFolder().catch(() => {})}
              disabled={!resolved}
            >
              Open log folder
            </button>
            <button
              type="button"
              className="debug-button"
              onClick={() => {
                resolved?.clearLog().then(refreshLog, () => {})
              }}
              disabled={!resolved}
            >
              Clear
            </button>
          </div>
        </div>

        <LogView log={log} />
      </section>
    </div>
  )
}
