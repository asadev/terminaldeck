import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { panelSpec } from '../shell/panels'
import { sectionMeta } from '../settings/settings-schema'
import { PageEmpty, PageNote } from './PageEmpty'
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
  /** The socket path, or null when it is not listening. Never the token. */
  address: string | null
  running: boolean
  /**
   * Why it is not running, when the main process knows. Null when it is.
   *
   * Optional because a host that has not been restarted since this field was
   * added answers without it, and a panel that read `undefined` as a reason
   * would print the word "undefined" at somebody.
   */
  error?: string | null
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

/**
 * What Settings calls the pane that lists the coding assistants, read from the
 * schema rather than written here.
 *
 * This page's whole job is to point at that pane and say "the list of your
 * assistants is over there, this is one switch about them" — so a hardcoded
 * name is a sentence that goes stale the moment somebody renames a rail entry,
 * which happened the same night this was written: the section was called Agents
 * and became **Assistants**, because *"'Agents' is the wrong name for that
 * section"*. A cross-reference that names the wrong pane is worse than none.
 */
const ASSISTANTS_SECTION = sectionMeta('agents').label

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

/**
 * The row's state, said as what it means for the reader.
 *
 * It used to read Installed / Not installed / Incomplete — the state of a
 * *file*, which is the vocabulary that made this page look like a second copy
 * of the CLI list. Asad, on this page: *"Do you think hooks and CLIs are the
 * same thing? Because this is a hooks folder and we see CLI here."*
 *
 * They are not the same thing, and the page has to be the thing that says so.
 * The Assistants pane in Settings answers *which coding assistants do I have,
 * and who is each signed in as*. This page answers exactly one question about
 * each of them — *can a tab tell me what it is doing* — so every word on a row
 * is about that, and the assistant's name is the subject of a sentence rather
 * than the row's identity.
 */
export const STATE_LABEL: Record<HookInstallState, string> = {
  complete: 'Reporting',
  stale: 'Out of date',
  partial: 'Half set up',
  none: 'Not reporting',
  error: 'Cannot read its settings',
}

/** The consequence of that state, in one line, so the button has a reason. */
export const STATE_CONSEQUENCE: Record<HookInstallState, string> = {
  complete: 'Its tabs show working, waiting for you, or done.',
  stale: 'It is reporting to an address this app no longer listens on.',
  partial: 'Some steps report and some do not, so a tab can go quiet mid-run.',
  none: 'Its tabs cannot tell whether it is working or waiting for you.',
  error: 'Its settings file could not be read, so nothing here will write to it.',
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
      return { label: 'Set up again', enabled: true }
    case 'stale':
      return { label: 'Fix it', enabled: true }
    case 'partial':
      return { label: 'Fix it', enabled: true }
    case 'error':
      // The file could not be parsed; writing to it would be the one genuinely
      // damaging thing this panel can do. Disabled *with a reason on the row* —
      // `STATE_CONSEQUENCE.error` says the settings file could not be read,
      // which is why the button is off and what would have to change.
      return { label: 'Turn on', enabled: false }
    default:
      return { label: 'Turn on', enabled: true }
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

/**
 * The line under the header: where the local endpoint is, or that it is not up.
 *
 * The running half used to carry a second sentence — that the address and its
 * token change every run, so hooks are reinstalled when the app starts. It was
 * cut for being a description of our own implementation, which was the right
 * call for the wrong reason: it was also a description of a defect, and cutting
 * it made the defect quieter rather than smaller. Neither half is true any more.
 * The address is a socket path that does not change between runs, and the token
 * is no longer in the hook command at all — see `hook-server.ts`.
 *
 * The *not* running half keeps its consequence, because "hooks have nowhere to
 * report to" is why the page underneath will look inert.
 *
 * And, since 2026-08-21, the reason — when the main process has one. That half
 * exists because of the failure it was written for: a data directory long enough
 * to overrun a unix socket path made the endpoint throw at launch, the app
 * logged one line to a console nobody has open, and every hook on the machine
 * silently stopped reporting. This page said "not running" and could not say
 * why, because nothing kept the sentence. `hook-server.ts` keeps it now.
 *
 * Pure and exported so all three halves can be pinned; `server` arrives from an
 * effect, which a static render never runs.
 */
export function endpointLine(server: HookServerInfo | null): string {
  if (server?.running) return `Listening on ${server.address}.`
  const why = server?.error
  return why
    ? `The local endpoint is not running, so hooks have nowhere to report to: ${why}`
    : 'The local endpoint is not running, so hooks have nowhere to report to.'
}

/**
 * What the panel promises before it writes to somebody's settings file.
 *
 * Two sentences before the app-wide shortening pass and one clause after it,
 * and it stayed on screen at all because it is the fact that makes the button
 * safe to press: this is a file the user may well have edited by hand, and the
 * removal reaches only the entries this app put there. Cutting it would have
 * been the shortening taking a real assurance with it.
 *
 * Exported so it can be pinned. The sentence itself only appears after a press,
 * and this project has no DOM in its tests — a static render can never reach
 * the state that draws it, so the string is asserted where it is written.
 */
export function removalPromise(file: string): string {
  return `Only our own entries are removed from ${file}. Everything else stays.`
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
        </div>

        {/*
          What that state means for the reader, and nothing about files.

          This row used to carry `status.message` — prose written for whoever
          was reading a settings file — and, on its own line, the absolute path
          of that file. *"For important parts of the application we don't need
          to give folders and file paths."* The path is still one hover away, on
          the button that writes it, which is the moment it is worth knowing.

          `status.message` survives only where it is the more specific answer:
          a row this app could not read, where the generic sentence would hide
          what actually went wrong.
        */}
        <p className="hooks-message">
          {status.state === 'error' ? status.message : STATE_CONSEQUENCE[status.state]}
        </p>

        {foreign ? <p className="hooks-foreign">{foreign}</p> : null}

        {/*
          The backup path, at the moment it reassures rather than clutters.

          It stood on every row as "Original kept at
          /Users/…/hook-backups/claude-.claude-settings.json.bak" — a second
          absolute path per row, on a page whose rows are meant to be sentences
          about an agent. Nobody needs to know where a backup is until they are
          about to undo something, so it appears with the confirmation, which is
          exactly that moment.
        */}
        {confirming ? (
          <p className="hooks-confirm">
            {removalPromise(status.file)}
            {status.backupPath ? ` The original is still at ${status.backupPath}.` : ''}
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
            {confirming ? 'Yes, turn it off' : 'Turn off'}
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
          // The path, at the moment it is worth knowing: this button is about to
          // write somebody's own configuration file, and the hover says which.
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
        <PageEmpty icon={panelSpec('hooks').icon} title="Hooks are not available here">
          This window was opened without the hooks bridge, so there is nothing for this page to
          read or install.
        </PageEmpty>
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
          <h2 className="hooks-heading">Session updates</h2>
          {/*
            The sentence that answers the question he asked on this page.

            *"Do you think hooks and CLIs are the same thing? Because this is a
            hooks folder and we see CLI here."* — a fair question about a page
            that listed the same three agent names as Settings → Agents, with a
            settings-file path under each. It is not a second list of your
            agents. It is one switch, per agent, for one thing: whether a tab
            can tell you what that agent is doing. So the page says which of the
            two it is, in the first line, in the words a reader would use.
          */}
          {/*
            The toolbar above this already says what the page does — its blurb
            in `shell/panels.ts` reads "Whether a tab can tell you an agent is
            working, waiting or done." So this line does not say it again; it
            says the *other* half, which is the half he asked about.
          */}
          <p className="hooks-sub">
            One switch per assistant. Which assistants you have, and who each is signed in as, is
            in Settings → {ASSISTANTS_SECTION}.
          </p>
        </div>
        <button type="button" className="hooks-refresh" onClick={() => void refresh()}>
          Refresh
        </button>
      </header>

      {/*
        The endpoint line, but only when it is bad news.

        Running, it said "Listening on /Users/…/hooks.sock" — an implementation
        detail and a file path, at the top of the page, above everything a
        reader came for. Not running is a different matter: it is the reason
        every row underneath will look inert, so it stays and says so.
      */}
      {!server?.running && (
        <p className="hooks-endpoint" data-running={false}>
          {endpointLine(server)}
        </p>
      )}

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

      {statuses === null && !error ? (
        <PageNote page busy>
          Reading settings files…
        </PageNote>
      ) : null}

      {/* An empty array is not the same as "still loading", and it used to
          print nothing at all — a page that ended in silence after the
          endpoint line, with no way to tell a working install from a broken
          one. There is nothing to install hooks into until a CLI exists. */}
      {/* The blank carries no action of its own: Refresh is already in this
          page's header, and two buttons with the same word on one screen is
          the redundancy the rules call out. */}
      {statuses !== null && statuses.length === 0 && !error ? (
        /*
          The empty state is where the two pages were most easily confused, so
          it is where the distinction is stated most plainly: there is nothing
          to switch on because there is no agent to switch it on *for*, and the
          place agents are installed is named. No specific tool is named here —
          *"you should not mention in any settings or any pop-up a specific tool
          or LLM, because they can use some other also."*
        */
        <PageEmpty icon={panelSpec('hooks').icon} title="Nothing to report on yet">
          This is a setting for the coding assistants you have installed, and there are none on
          this machine yet. Install one from Settings → {ASSISTANTS_SECTION}, then press Refresh.
        </PageEmpty>
      ) : null}
    </section>
  )
}
