import { useCallback, useEffect, useId, useMemo, useState } from 'react'
import { SegmentedSwitch } from '../../components/SegmentedSwitch'
import { Button, Group, Notice, Row, SectionHead, Switch } from '../controls'
import { sectionMeta } from '../settings-schema'
import {
  APPS,
  LEVELS,
  levelCopy,
  setupFor,
  toAiAppsResult,
  toAiAppsState,
  usedLine,
  type AccessKeyRow,
  type AccessLevel,
  type AiAppsResult,
  type AiAppsState,
  type AppId,
  type SetupWhere,
} from './ai-apps-setup'
import './AiAppsSection.css'

/**
 * Settings → Connect an AI app.
 *
 * ## What it is for, in his words
 *
 *   > *"I will give [it] to my copilot in any other application… I just keep it
 *   > open and any other AI from any other application from internet through
 *   > the MCP can connect to it… it should be able to start sessions, drive
 *   > sessions, look for the answers."*
 *
 * So the page does three things and is laid out in that order: switch the
 * internet road on or off, see and manage the keys that exist, and make a new
 * one — which shows the key once and hands out copy-ready setup for every app
 * that can hold one, never only one of them.
 *
 * ## Plain about what it costs
 *
 * Two sentences on this page are load-bearing rather than decoration, and must
 * not be softened into product copy. *Work* says a session can run any command
 * on this Mac. Internet reach says the relay can read what passes through it,
 * which is true of this road and not of the phone's. Both are true whether or
 * not the page says them; saying them is what lets a person decide.
 *
 * ## No control that does nothing
 *
 * "Ask me before big changes" is drawn only for a Full control key, because for
 * the other two levels there are no big changes to ask about — a switch there
 * would change nothing, which is the defect this app keeps finding. The folder
 * limit says where sessions may be *started*, and its sentence says that is
 * all it says.
 */

/* -------------------------------------------------------------- the bridge -- */

/**
 * What this pane needs from `window.deck`. The names are the preload's: the
 * contract test matches every `*Bridge` interface against what it exposes.
 */
export interface AiAppsBridge {
  aiAppsState(): Promise<unknown>
  aiAppsCreate(input: { name: string; level: AccessLevel; askFirst: boolean; folders: string[] | null }): Promise<unknown>
  aiAppsRename(id: string, name: string): Promise<unknown>
  aiAppsLevel(id: string, level: AccessLevel): Promise<unknown>
  aiAppsAskFirst(id: string, on: boolean): Promise<unknown>
  aiAppsFolders(id: string, folders: string[] | null): Promise<unknown>
  aiAppsRevoke(id: string): Promise<unknown>
  aiAppsInternet(on: boolean): Promise<unknown>
  onAiAppsChanged(callback: () => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof AiAppsBridge> = [
  'aiAppsState',
  'aiAppsCreate',
  'aiAppsRename',
  'aiAppsLevel',
  'aiAppsAskFirst',
  'aiAppsFolders',
  'aiAppsRevoke',
  'aiAppsInternet',
  'onAiAppsChanged',
]

/**
 * The bridge as it exists, each method called through its host — for the
 * reason `PowerSection` gives: a preload whose functions sit on a prototype
 * throws on `this` the first time a button is pressed, and only in a packaged
 * build. `globalThis` so the pane renders to a string in tests.
 */
export function resolveAiAppsBridge(host?: unknown): Partial<AiAppsBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const all = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof all[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown => (all[name] as (...a: unknown[]) => unknown).apply(all, args)
  }
  return bridge as Partial<AiAppsBridge>
}

/* ------------------------------------------------------------- clipboard -- */

function useCopy(): { copied: string | null; copy(id: string, value: string): void } {
  const [copied, setCopied] = useState<string | null>(null)
  useEffect(() => {
    if (copied === null) return
    const timer = window.setTimeout(() => setCopied(null), 1600)
    return () => window.clearTimeout(timer)
  }, [copied])
  const copy = useCallback((id: string, value: string) => {
    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    if (!clipboard?.writeText) {
      setCopied(`${id}:failed`)
      return
    }
    void clipboard.writeText(value).then(
      () => setCopied(id),
      () => setCopied(`${id}:failed`),
    )
  }, [])
  return { copied, copy }
}

function CopyButton({ id, value, copied, onCopy }: { id: string; value: string; copied: string | null; onCopy(id: string, value: string): void }) {
  const label = copied === id ? 'Copied' : copied === `${id}:failed` ? 'Select and copy it by hand' : 'Copy'
  return (
    <Button onClick={() => onCopy(id, value)} title="Copy to the clipboard">
      {label}
    </Button>
  )
}

/* ------------------------------------------------------------------ pane -- */

export function AiAppsSection({ bridge: injected }: { bridge?: Partial<AiAppsBridge> } = {}) {
  const meta = sectionMeta('ai-apps')
  const bridge = useMemo(() => injected ?? resolveAiAppsBridge(), [injected])
  const [state, setState] = useState<AiAppsState | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [making, setMaking] = useState(false)
  const [made, setMade] = useState<{ key: string; id: string; name: string } | null>(null)

  const wired = typeof bridge.aiAppsState === 'function'

  const load = useCallback(async () => {
    if (!bridge.aiAppsState) return
    try {
      const next = toAiAppsState(await bridge.aiAppsState())
      if (next === null) setProblem('The app answered with something this page cannot read.')
      setState(next)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    }
  }, [bridge])

  useEffect(() => {
    void load()
    // Pushed by the main process when a key or the switch changes — including
    // from another window, and when an app's call updates "last used".
    return bridge.onAiAppsChanged?.(() => void load())
  }, [bridge, load])

  /** Run one change and draw what came back, or the sentence that says why not. */
  const run = useCallback(async (change: () => Promise<unknown> | undefined): Promise<AiAppsResult | null> => {
    const pending = change()
    if (!pending) return null
    setBusy(true)
    try {
      const result = toAiAppsResult(await pending)
      if (result.state) setState(result.state)
      setProblem(result.ok ? null : result.message)
      return result
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
      return null
    } finally {
      setBusy(false)
    }
  }, [])

  if (!wired) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <Notice>This build has no channels for AI app keys wired into its preload.</Notice>
      </>
    )
  }

  const setInternet = (on: boolean): void => void run(() => bridge.aiAppsInternet?.(on))

  return (
    <div className="ai-apps">
      <SectionHead title={meta.label} blurb={meta.blurb} />
      {problem && (
        <Notice tone="error">{problem}</Notice>
      )}
      {state?.problem && <Notice tone="warn">{state.problem}</Notice>}

      {state === null ? (
        <p className="ai-apps-quiet">Reading the keys…</p>
      ) : (
        <>
          <InternetGroup state={state} busy={busy} onChange={setInternet} />
          <LocalGroup state={state} />

          <Group title="Keys">
            {state.keys.length === 0 && !making && made === null && (
              <p className="ai-apps-quiet">No keys yet. Make one for each AI app you connect, so you can take one back without the others.</p>
            )}
            <ul className="settings-profiles ai-keys">
              {state.keys.map((key) => (
                <KeyRow
                  key={key.id}
                  row={key}
                  folders={state.folders}
                  busy={busy}
                  bridge={bridge}
                  run={run}
                />
              ))}
            </ul>

            {made !== null ? (
              <NewKeyMade
                made={made}
                state={state}
                busy={busy}
                onInternet={() => setInternet(true)}
                onDone={() => setMade(null)}
              />
            ) : making ? (
              <NewKeyForm
                folders={state.folders}
                busy={busy}
                onCancel={() => setMaking(false)}
                onMake={async (input) => {
                  const result = await run(() => bridge.aiAppsCreate?.(input))
                  if (result?.ok && result.key !== null && result.id !== null) {
                    setMaking(false)
                    setMade({ key: result.key, id: result.id, name: input.name })
                  }
                }}
              />
            ) : (
              <div className="settings-actions">
                <Button tone="primary" onClick={() => setMaking(true)} disabled={busy}>
                  New key
                </Button>
              </div>
            )}
          </Group>
        </>
      )}
    </div>
  )
}

/* ------------------------------------------------------------ internet -- */

function InternetGroup({ state, busy, onChange }: { state: AiAppsState; busy: boolean; onChange(on: boolean): void }) {
  const ids = useId()
  const relay = state.internet.relayHost ?? 'the relay'
  /*
   * Two sentences, and the second is the honest one. It is in the help line —
   * on screen, beside the switch — rather than behind the ⓘ, because it is the
   * thing a person needs *before* turning this on, and a caveat that has to be
   * found is a caveat that was hidden.
   */
  const status = !state.internet.on
    ? 'Off. Only apps on this Mac can connect.'
    : state.internet.connected
      ? `On. Apps on the web reach this Mac through ${relay}.`
      : 'On, but this Mac is not connected to the relay right now.'
  const help = `${status} Unlike your phone’s connection, this traffic can be read at the relay.`
  return (
    <Group title="From the internet">
      <Row
        label="Internet reach"
        help={help}
        more={
          `Claude and ChatGPT on the web can only reach this Mac through the relay at ${relay}, the same one your phone uses. ` +
          'Unlike your phone’s connection, this one is not sealed end to end: the relay can read what an app asks and what comes back. ' +
          'If that matters to you, run your own relay and point this app at it. Turning this off stops every internet key at once; keys on this Mac keep working.'
        }
        labelId={`${ids}-label`}
        helpId={`${ids}-help`}
        control={
          <Switch
            checked={state.internet.on}
            disabled={busy}
            labelledBy={`${ids}-label`}
            describedBy={`${ids}-help`}
            onChange={onChange}
          />
        }
      />
      {state.internet.on && !state.internet.connected && state.internet.reason && (
        <Notice tone="warn">{state.internet.reason}</Notice>
      )}
    </Group>
  )
}

function LocalGroup({ state }: { state: AiAppsState }) {
  const { copied, copy } = useCopy()
  return (
    <Group title="On this Mac">
      <Row
        label="Local address"
        help={state.local.url ?? 'The tools are not running right now.'}
        more="Apps on this Mac connect here with a key in their settings. The address stays the same after a restart unless something else takes its port."
        control={
          state.local.url === null ? null : (
            <CopyButton id="local" value={state.local.url} copied={copied} onCopy={copy} />
          )
        }
      />
      {state.local.movedFrom !== null && (
        <Notice tone="warn">
          The address moved from port {state.local.movedFrom}, because something else was using it. Apps you set up before need the new address.
        </Notice>
      )}
    </Group>
  )
}

/* ---------------------------------------------------------------- a key -- */

type Run = (change: () => Promise<unknown> | undefined) => Promise<AiAppsResult | null>

function folderSummary(folders: string[] | null): string {
  if (folders === null || folders.length === 0) return 'Sessions in any project'
  const names = folders.map((folder) => folder.split(/[\\/]/).filter(Boolean).pop() ?? folder)
  return `Sessions only in ${names.join(', ')}`
}

function KeyRow({
  row,
  folders,
  busy,
  bridge,
  run,
}: {
  row: AccessKeyRow
  folders: string[]
  busy: boolean
  bridge: Partial<AiAppsBridge>
  run: Run
}) {
  const [open, setOpen] = useState(false)
  const [revoking, setRevoking] = useState(false)
  const [name, setName] = useState(row.name)
  const ids = useId()
  useEffect(() => setName(row.name), [row.name])

  return (
    <li className="settings-profile ai-key" data-open={open ? '' : undefined}>
      <div className="settings-profile-main">
        <span className="settings-profile-name">
          {row.name}
          <span className="settings-badge quiet">{levelCopy(row.level).label}</span>
        </span>
        <span className="settings-tool-note">{usedLine(row)}</span>
        <span className="settings-tool-note">
          {folderSummary(row.folders)}
          {row.level === 'full' && (row.askFirst ? ' · Asks before big changes' : ' · Big changes without asking')}
        </span>
      </div>
      <div className="settings-profile-actions">
        <Button onClick={() => setOpen((was) => !was)} disabled={busy}>
          {open ? 'Close' : 'Change'}
        </Button>
      </div>

      {open && (
        <div className="ai-key-edit">
          <div className="ai-field">
            <label className="settings-label" htmlFor={`${ids}-name`}>
              Name
            </label>
            <span className="ai-field-row">
              <input
                id={`${ids}-name`}
                className="settings-input wide"
                value={name}
                maxLength={60}
                disabled={busy}
                onChange={(event) => setName(event.target.value)}
              />
              <Button
                disabled={busy || name.trim() === '' || name.trim() === row.name}
                onClick={() => void run(() => bridge.aiAppsRename?.(row.id, name.trim()))}
              >
                Rename
              </Button>
            </span>
          </div>

          <div className="ai-field">
            <span className="settings-label">What it may do</span>
            <SegmentedSwitch<AccessLevel>
              inline
              label="What this key may do"
              options={LEVELS.map((entry) => ({ id: entry.id, label: entry.label }))}
              value={row.level}
              disabled={busy}
              onChange={(next) => void run(() => bridge.aiAppsLevel?.(row.id, next))}
            />
            <span className="settings-help">{levelCopy(row.level).help}</span>
          </div>

          {row.level === 'full' && (
            <AskFirstRow
              on={row.askFirst}
              busy={busy}
              onChange={(next) => void run(() => bridge.aiAppsAskFirst?.(row.id, next))}
            />
          )}

          <FolderPicker
            available={folders}
            chosen={row.folders}
            busy={busy}
            onSave={(next) => void run(() => bridge.aiAppsFolders?.(row.id, next))}
          />

          {revoking ? (
            <div className="settings-confirm" role="group" aria-label={`Revoke ${row.name}`}>
              <span>Revoke “{row.name}”? The app stops working right away.</span>
              <Button
                tone="danger"
                disabled={busy}
                onClick={() => void run(() => bridge.aiAppsRevoke?.(row.id))}
              >
                Revoke
              </Button>
              <Button onClick={() => setRevoking(false)}>Keep it</Button>
            </div>
          ) : (
            <div className="settings-actions">
              <Button tone="danger" disabled={busy} onClick={() => setRevoking(true)}>
                Revoke…
              </Button>
            </div>
          )}
        </div>
      )}
    </li>
  )
}

function AskFirstRow({ on, busy, onChange }: { on: boolean; busy: boolean; onChange(next: boolean): void }) {
  const ids = useId()
  return (
    <Row
      label="Ask me before big changes"
      help={on ? 'Your Mac and your phone show the question. No answer in 45 seconds means no.' : 'Off: big changes run without asking. Each one is still in the activity log.'}
      more="Big changes are things like changing a setting or stopping a session. Your phone shows the question while the app is open on it."
      labelId={`${ids}-label`}
      helpId={`${ids}-help`}
      control={
        <Switch checked={on} disabled={busy} labelledBy={`${ids}-label`} describedBy={`${ids}-help`} onChange={onChange} />
      }
    />
  )
}

function FolderPicker({
  available,
  chosen,
  busy,
  onSave,
}: {
  available: string[]
  chosen: string[] | null
  busy: boolean
  onSave(next: string[] | null): void
}) {
  const [editing, setEditing] = useState(false)
  const [picked, setPicked] = useState<Set<string>>(new Set(chosen ?? []))
  useEffect(() => setPicked(new Set(chosen ?? [])), [chosen])
  // A chosen folder this app no longer has open is still a limit; it stays listed.
  const all = useMemo(() => [...new Set([...(chosen ?? []), ...available])], [available, chosen])

  if (!editing) {
    return (
      <div className="ai-field">
        <span className="settings-label">Where it may start sessions</span>
        <span className="ai-field-row">
          <span className="settings-help">{folderSummary(chosen)}</span>
          <Button disabled={busy || all.length === 0} onClick={() => setEditing(true)} title={all.length === 0 ? 'Open a project first' : undefined}>
            Choose…
          </Button>
        </span>
      </div>
    )
  }

  return (
    <div className="ai-field">
      <span className="settings-label">Where it may start sessions</span>
      <span className="settings-help">Tick none for any project. This decides where it may start one, not what that session can touch.</span>
      <ul className="ai-folders">
        {all.map((folder) => (
          <li key={folder}>
            <label className="ai-folder">
              <input
                type="checkbox"
                checked={picked.has(folder)}
                disabled={busy}
                onChange={(event) => {
                  const next = new Set(picked)
                  if (event.target.checked) next.add(folder)
                  else next.delete(folder)
                  setPicked(next)
                }}
              />
              <span className="settings-url-address">{folder}</span>
            </label>
          </li>
        ))}
      </ul>
      <div className="settings-actions">
        <Button
          tone="primary"
          disabled={busy}
          onClick={() => {
            onSave(picked.size === 0 ? null : [...picked])
            setEditing(false)
          }}
        >
          Save
        </Button>
        <Button onClick={() => setEditing(false)}>Cancel</Button>
      </div>
    </div>
  )
}

/* -------------------------------------------------------------- new key -- */

function NewKeyForm({
  folders,
  busy,
  onMake,
  onCancel,
}: {
  folders: string[]
  busy: boolean
  onMake(input: { name: string; level: AccessLevel; askFirst: boolean; folders: string[] | null }): void
  onCancel(): void
}) {
  const [name, setName] = useState('')
  const [level, setLevel] = useState<AccessLevel>('work')
  const [askFirst, setAskFirst] = useState(true)
  const [limit, setLimit] = useState<string[] | null>(null)
  const ids = useId()

  return (
    <form
      className="ai-new"
      onSubmit={(event) => {
        event.preventDefault()
        if (name.trim() === '') return
        onMake({ name: name.trim(), level, askFirst, folders: limit })
      }}
    >
      <h5 className="settings-explain-title">New key</h5>
      <label className="ai-field" htmlFor={`${ids}-name`}>
        <span className="settings-label">Name</span>
        <input
          id={`${ids}-name`}
          className="settings-input wide"
          placeholder="Which app is this for?"
          value={name}
          maxLength={60}
          autoFocus
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <div className="ai-field">
        <span className="settings-label">What it may do</span>
        <SegmentedSwitch<AccessLevel>
          inline
          label="What this key may do"
          options={LEVELS.map((entry) => ({ id: entry.id, label: entry.label }))}
          value={level}
          onChange={setLevel}
        />
        <span className="settings-help">{levelCopy(level).help}</span>
      </div>
      {level === 'full' && <AskFirstRow on={askFirst} busy={busy} onChange={setAskFirst} />}
      <FolderPicker available={folders} chosen={limit} busy={busy} onSave={setLimit} />
      <div className="settings-actions">
        <Button tone="primary" type="submit" disabled={busy || name.trim() === ''}>
          Make key
        </Button>
        <Button onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  )
}

function NewKeyMade({
  made,
  state,
  busy,
  onInternet,
  onDone,
}: {
  made: { key: string; id: string; name: string }
  state: AiAppsState
  busy: boolean
  onInternet(): void
  onDone(): void
}) {
  const [app, setApp] = useState<AppId>('claude-web')
  const [where, setWhere] = useState<SetupWhere>('this-mac')
  const { copied, copy } = useCopy()
  const choice = APPS.find((entry) => entry.id === app) ?? APPS[0]
  const setup = setupFor(app, {
    key: made.key,
    name: made.name,
    internetBase: state.internet.base,
    localUrl: state.local.url,
    where,
  })

  return (
    <div className="ai-new" aria-live="polite">
      <h5 className="settings-explain-title">“{made.name}” is ready</h5>
      <Notice tone="warn">Copy the key now. It is shown only this once — lose it and you make a new one.</Notice>
      <div className="ai-secret">
        <code className="ai-secret-value">{made.key}</code>
        <CopyButton id="key" value={made.key} copied={copied} onCopy={copy} />
      </div>

      <div className="ai-field">
        <span className="settings-label">Set it up in</span>
        <SegmentedSwitch<AppId>
          inline
          label="Which app to set it up in"
          options={APPS.map((entry) => ({ id: entry.id, label: entry.label }))}
          value={app}
          onChange={setApp}
        />
      </div>

      {!choice.web && (
        <SegmentedSwitch<SetupWhere>
          inline
          label="Where that app runs"
          options={[
            { id: 'this-mac', label: 'On this Mac' },
            { id: 'elsewhere', label: 'On another computer' },
          ]}
          value={where}
          onChange={setWhere}
        />
      )}

      {setup.needsInternet && !state.internet.on && (
        <div className="settings-confirm">
          <span>This needs internet reach, which is off.</span>
          <Button tone="primary" disabled={busy} onClick={onInternet}>
            Turn it on
          </Button>
        </div>
      )}

      <ol className="ai-steps">
        {setup.steps.map((step) => (
          <li key={step}>{step}</li>
        ))}
      </ol>
      {setup.snippet !== null ? (
        <div className="ai-snippet">
          <pre className="settings-code">{setup.snippet}</pre>
          <div className="settings-actions">
            <CopyButton id={`snippet-${app}-${where}`} value={setup.snippet} copied={copied} onCopy={copy} />
            {choice.web && (
              <span className="settings-help">The link holds the key. Treat it like a password.</span>
            )}
          </div>
        </div>
      ) : (
        setup.missing && <Notice tone="warn">{setup.missing}</Notice>
      )}

      <div className="settings-actions">
        {/* Not "Done": the sheet's own footer already says that, and this
            button is the one after which the key is gone from this screen. */}
        <Button onClick={onDone}>I’ve copied the key</Button>
      </div>
    </div>
  )
}
