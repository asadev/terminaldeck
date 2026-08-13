import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { panelSpec } from '../shell/panels'
import { PageEmpty } from './PageEmpty'
import './HooksPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/hooks.ts`, duplicated rather than imported
 * because the renderer tsconfig cannot see `src/main`. Same arrangement as
 * ReadinessPanel; when the orchestrator lifts them into `src/shared/types.ts`
 * this block goes away and the imports point there instead.
 */
export type HookInstallState = 'none' | 'partial' | 'complete' | 'stale' | 'error'

export interface HookProviderStatus {
  id: string
  label: string
  file: string
  fileExists: boolean
  state: HookInstallState
  installedEvents: string[]
  staleEvents: string[]
  missingEvents: string[]
  foreignHooks: number
  foreignOwners: string[]
  backupPath: string | null
  message: string
}

export interface HookWriteResult {
  ok: boolean
  message: string
  status: HookProviderStatus
}

export interface HookServerInfo {
  port: number | null
  running: boolean
}

/** The slice of the preload bridge this panel needs. */
export interface HooksBridge {
  hooksStatus(): Promise<HookProviderStatus[]>
  installHooks(providerId: string): Promise<HookWriteResult>
  removeHooks(providerId: string): Promise<HookWriteResult>
  hookServerInfo(): Promise<HookServerInfo>
}

export interface HooksPanelProps {
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: HooksBridge
}

/* ---------------------------------------------------------------- helpers -- */

const BRIDGE_METHODS = ['hooksStatus', 'installHooks', 'removeHooks', 'hookServerInfo'] as const

/**
 * Read defensively: hooks are wired into the preload separately, so the panel
 * has to explain itself rather than crash if it mounts first.
 */
function resolveBridge(): HooksBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Record<string, unknown> }).deck
  if (!host) return null
  return BRIDGE_METHODS.every((name) => typeof host[name] === 'function')
    ? (host as unknown as HooksBridge)
    : null
}

/**
 * The two write calls, each closed over its own bridge.
 *
 * Passing `bridge.installHooks` straight to a handler detaches it from the
 * object it came from: a preload that exposes plain functions survives that, a
 * bridge with methods on a prototype throws on `this` the first time the user
 * clicks Install. Calling through the object costs nothing and never does.
 */
export function bridgeCalls(bridge: HooksBridge): {
  install(id: string): Promise<HookWriteResult>
  remove(id: string): Promise<HookWriteResult>
} {
  return {
    install: (id) => bridge.installHooks(id),
    remove: (id) => bridge.removeHooks(id),
  }
}

export const STATE_LABEL: Record<HookInstallState, string> = {
  complete: 'Installed',
  stale: 'Needs reinstalling',
  partial: 'Incomplete',
  none: 'Not installed',
  error: 'Cannot read',
}

/**
 * What the primary button does, given the state.
 *
 * A stale install is the interesting case: the hooks are there and tagged, but
 * they carry the port and token of a previous run, so the button says Reinstall
 * rather than Install — the user is not adding anything, they are re-aiming it.
 */
export function primaryAction(state: HookInstallState): { label: string; enabled: boolean } {
  switch (state) {
    case 'complete':
      return { label: 'Reinstall', enabled: true }
    case 'stale':
      return { label: 'Reinstall', enabled: true }
    case 'partial':
      return { label: 'Repair', enabled: true }
    case 'error':
      // The file could not be parsed; writing to it would be the one genuinely
      // damaging thing this panel can do.
      return { label: 'Install', enabled: false }
    default:
      return { label: 'Install', enabled: true }
  }
}

/** Whether removal is worth offering — there has to be something of ours there. */
export function canRemove(status: HookProviderStatus): boolean {
  return status.state === 'complete' || status.state === 'stale' || status.state === 'partial'
}

/** "Vibeyard's 26 hooks" reads better than "26 foreign hooks". */
export function foreignNote(status: HookProviderStatus): string | null {
  if (status.foreignHooks <= 0) return null
  // Names arrive over IPC. An empty one indexed at [0] is undefined, and
  // `undefined.toUpperCase()` takes the whole settings screen down with it.
  const named = status.foreignOwners.filter((name) => typeof name === 'string' && name.length > 0)
  const owner =
    named.length > 0
      ? named.map((name) => name[0].toUpperCase() + name.slice(1)).join(' and ')
      : 'another tool'
  const count = status.foreignHooks
  return `${count} hook${count === 1 ? '' : 's'} here belong${count === 1 ? 's' : ''} to ${owner}. ${count === 1 ? 'It is' : 'They are'} never modified or removed.`
}

/* ------------------------------------------------------------------- rows -- */

export interface HookRowProps {
  status: HookProviderStatus
  busy: boolean
  result: HookWriteResult | null
  onInstall(id: string): void
  onRemove(id: string): void
}

export function HookRow({ status, busy, result, onInstall, onRemove }: HookRowProps) {
  const [confirming, setConfirming] = useState(false)
  const action = primaryAction(status.state)
  const foreign = foreignNote(status)

  // A finished write changes the row underneath any pending question; drop it
  // rather than leave "Yes, remove them" answering a stale one.
  useEffect(() => {
    setConfirming(false)
  }, [result, status.state])

  return (
    <li className="hooks-row" data-state={status.state}>
      <div className="hooks-row-body">
        <div className="hooks-row-head">
          <span className="hooks-dot" aria-hidden="true" />
          <span className="hooks-provider">{status.label}</span>
          <span className="hooks-state">{STATE_LABEL[status.state]}</span>
          {status.state === 'complete' || status.state === 'stale' ? (
            <span className="hooks-count">
              {status.installedEvents.length + status.staleEvents.length} events
            </span>
          ) : null}
        </div>

        <p className="hooks-message">{status.message}</p>
        <p className="hooks-file" title={status.file}>
          {status.file}
        </p>

        {foreign ? <p className="hooks-foreign">{foreign}</p> : null}

        {status.backupPath ? (
          <p className="hooks-backup">Original kept at {status.backupPath}</p>
        ) : null}

        {confirming ? (
          <p className="hooks-confirm">
            This removes only the entries tagged as ours from {status.file}. Every other hook and
            setting in the file is left exactly as it is.
          </p>
        ) : null}

        {result ? (
          <p className="hooks-result" data-ok={result.ok}>
            {result.message}
          </p>
        ) : null}
      </div>

      <div className="hooks-actions">
        {canRemove(status) ? (
          <button
            type="button"
            className="hooks-remove"
            data-confirming={confirming || undefined}
            disabled={busy}
            onClick={() => {
              if (!confirming) {
                setConfirming(true)
                return
              }
              setConfirming(false)
              onRemove(status.id)
            }}
          >
            {confirming ? 'Yes, remove' : 'Remove'}
          </button>
        ) : null}
        <button
          type="button"
          className="hooks-install"
          disabled={busy || !action.enabled}
          onClick={() => {
            setConfirming(false)
            onInstall(status.id)
          }}
          title={`Writes ${status.file}`}
        >
          {busy ? 'Working…' : action.label}
        </button>
      </div>
    </li>
  )
}

/* ------------------------------------------------------------------ panel -- */

/**
 * Hook installation, one row per provider.
 *
 * The panel is deliberately explicit about the file it is about to write and
 * about whose hooks are already in it: this is the user's real configuration,
 * shared with whatever else they have installed, and a button that quietly
 * rewrites it would deserve every bit of the distrust it earned.
 */
export function HooksPanel({ bridge }: HooksPanelProps) {
  const resolved = useMemo(() => bridge ?? resolveBridge(), [bridge])

  const [statuses, setStatuses] = useState<HookProviderStatus[] | null>(null)
  const [server, setServer] = useState<HookServerInfo | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [results, setResults] = useState<Record<string, HookWriteResult>>({})

  /**
   * Every write here is a round trip to the main process, and the panel is a
   * tab the user can close mid-flight. Without this the reply lands on an
   * unmounted component — and, worse, two overlapping refreshes can finish out
   * of order and leave the older answer on screen.
   */
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const refresh = useCallback(async () => {
    if (!resolved) return
    setError(null)
    try {
      const [next, info] = await Promise.all([resolved.hooksStatus(), resolved.hookServerInfo()])
      if (!alive.current) return
      setStatuses(next)
      setServer(info)
    } catch (cause) {
      if (!alive.current) return
      setError(cause instanceof Error ? cause.message : String(cause))
    }
  }, [resolved])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const run = useCallback(
    async (id: string, write: (id: string) => Promise<HookWriteResult>) => {
      setBusy(id)
      try {
        const result = await write(id)
        if (!alive.current) return
        setResults((prev) => ({ ...prev, [id]: result }))
        // Re-read whatever the outcome: a refusal usually means the file moved
        // on, and the row should show what is there now, not what we assumed.
        await refresh()
      } catch (cause) {
        if (!alive.current) return
        setResults((prev) => ({
          ...prev,
          [id]: {
            ok: false,
            message: cause instanceof Error ? cause.message : String(cause),
            status: prev[id]?.status ?? ({} as HookProviderStatus),
          },
        }))
      } finally {
        if (alive.current) setBusy(null)
      }
    },
    [refresh],
  )

  if (!resolved) {
    return (
      <section className="hooks">
        <p className="hooks-empty">Hooks are not available in this window.</p>
      </section>
    )
  }

  const calls = bridgeCalls(resolved)

  return (
    <section className="hooks" aria-label="Provider hooks">
      <header className="hooks-head">
        <div className="hooks-headline">
          {/* Visually hidden — see `.hooks-heading`. The toolbar says "Hooks"
              in the title voice already; this is here for anything reading the
              structure rather than looking at it. */}
          <h2 className="hooks-heading">Provider hooks</h2>
          <p className="hooks-sub">
            Agent CLIs can call out on session and tool events. Installing hooks lets this app
            follow a session without reading its terminal output.
          </p>
        </div>
        <button type="button" className="hooks-refresh" onClick={() => void refresh()}>
          Refresh
        </button>
      </header>

      <p className="hooks-endpoint" data-running={server?.running ?? false}>
        {server?.running
          ? `Listening on 127.0.0.1:${server.port}. The address and its token change every run, so hooks are reinstalled when the app starts.`
          : 'The local endpoint is not running, so hooks have nowhere to report to.'}
      </p>

      {error ? <p className="hooks-error">{error}</p> : null}

      <ul className="hooks-list">
        {(statuses ?? []).map((status) => (
          <HookRow
            key={status.id}
            status={status}
            busy={busy === status.id}
            result={results[status.id] ?? null}
            onInstall={(id) => void run(id, calls.install)}
            onRemove={(id) => void run(id, calls.remove)}
          />
        ))}
      </ul>

      {statuses === null && !error ? <p className="hooks-empty">Reading settings files…</p> : null}

      {/* An empty array is not the same as "still loading", and it used to
          print nothing at all — a page that ended in silence after the
          endpoint line, with no way to tell a working install from a broken
          one. There is nothing to install hooks into until a CLI exists. */}
      {/* The blank carries no action of its own: Refresh is already in this
          page's header, and two buttons with the same word on one screen is
          the redundancy the rules call out. */}
      {statuses !== null && statuses.length === 0 && !error ? (
        <PageEmpty icon={panelSpec('hooks').icon} title="No agent CLIs on this machine">
          There is nothing to install hooks into yet. Install Claude Code, Codex or Gemini CLI,
          then press Refresh.
        </PageEmpty>
      ) : null}
    </section>
  )
}
