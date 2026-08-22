import { useCallback, useEffect, useMemo, useState } from 'react'
import { HoverNote } from './HoverNote'
import { McpAddForm, scopeChoices, type McpAddResult, type McpAddScope } from './McpAddForm'
import { McpStoreRow } from './McpStoreRow'
import { PageEmpty, PageNote } from './PageEmpty'
import { panelSpec } from '../shell/panels'
import { SegmentedSwitch } from './SegmentedSwitch'
import {
  EMPTY_STORE_VIEW,
  readMcpStoreResult,
  readMcpStoreView,
  type McpStoreApi,
  type McpStoreRow as Row,
  type McpStoreView,
} from './mcp-store-bridge'

/**
 * The MCP store: a catalogue of servers, and a form for anything not in it.
 *
 * ## Where this lives, and why it is a tab rather than a page or a dialog
 *
 * It is the **second tab of the MCP servers page**, beside the list of what is
 * configured. Three placements were possible and the other two are worse for
 * reasons worth writing down, because the next person will reach for one of
 * them:
 *
 *  - **A new rail entry.** `shell/panels.ts` argues at length against growing
 *    that union — every member is a route the window can be restored into, and
 *    two rail rows about MCP servers is the *Machines vs Remote* split he
 *    already made us undo: *"they should be one."* Browsing servers and seeing
 *    which you have are two views of one subject, not two subjects.
 *  - **A modal, like the browser's tools store.** That store is a dialog because
 *    the browser has no page to put it on — it is a chrome with tabs in it, and
 *    a dialog is the only surface there is. The MCP page exists, so a dialog
 *    over it would be a second window over a screen that was already about this.
 *
 * A tab keeps one place, one heading in the rail, and one answer to *do I have
 * this* — the store reads the same `loadServers` the list does, so a row cannot
 * claim "not installed" about something the other tab is showing.
 *
 * ## Add your own is first, and that is the point
 *
 *   > *"people like to use their own kind of extension … they can just click and
 *   > attach their own things to this application."*
 *
 * So the form is at the top, in its own section, with its own heading — not
 * under nineteen rows, and not behind a link at the bottom reading "advanced".
 * The catalogue is the convenience; arbitrary servers are the capability. A
 * store that buried the second under the first would be offering a walled
 * garden with a suggestion box.
 *
 * ## What the machine report is for
 *
 * One line naming `npx`, `uvx` and `docker` and whether each was found, with the
 * path when it was. It is there because every "cannot work here" sentence on a
 * row below refers back to it, and a claim about somebody's machine should show
 * its working. A missing runtime is not an error — a person with no Docker is
 * not doing anything wrong — so it is stated, not warned about.
 */

interface Props {
  api: McpStoreApi
  /** The open folder, so `local` and `project` scopes can be offered. */
  projectPath: string | null
  /** What this computer is called, for the sentence about where installs land. */
  here: string
  /** Re-read the servers list next door after anything is written. */
  onChanged(): void
}

/** Which section a row belongs to. The order below is the order on screen. */
const SECTIONS: ReadonlyArray<{ key: Row['state']; heading: string; note: string }> = [
  {
    key: 'installed',
    heading: 'Installed',
    note: 'Configured on this machine. Remove takes the line back out of the configuration.',
  },
  {
    key: 'available',
    heading: 'Ready to install',
    note:
      'Nothing here ships inside this app. Install writes the command onto the row into your ' +
      'configuration; the server itself is fetched by npx, uvx or docker the first time it runs.',
  },
  {
    key: 'taken',
    heading: 'A server already has this name',
    note:
      'Something with this name is configured and it is not this row, so nothing is offered — ' +
      'overwriting somebody else’s server is not this store’s business. Add it under another ' +
      'name from “Add your own” if you want both.',
  },
  {
    key: 'unavailable',
    heading: 'Cannot run on this machine',
    note:
      'The runtime each of these needs was looked for on this machine and not found. There is no ' +
      'Install for them, because installing one would only write a command that cannot start.',
  },
]

export function McpStore({ api, projectPath, here, onChanged }: Props) {
  const [view, setView] = useState<McpStoreView>(EMPTY_STORE_VIEW)
  const [problem, setProblem] = useState('')
  const [loading, setLoading] = useState(true)
  const [scope, setScope] = useState<McpAddScope>('user')
  const [adding, setAdding] = useState(false)
  /** Row id → what was typed into its fields. */
  const [values, setValues] = useState<Record<string, Record<string, string>>>({})
  /** Row id → the sentence its last press produced. */
  const [said, setSaid] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState('')
  const [arming, setArming] = useState('')

  const scopes = useMemo(() => scopeChoices(projectPath), [projectPath])

  // A folder closing takes `local` and `project` with it. Without this the
  // picker would keep a scope it no longer offers and every install would be
  // refused by the main process for a reason nothing on screen explains.
  useEffect(() => {
    if (!scopes.some((choice) => choice.value === scope)) setScope('user')
  }, [scopes, scope])

  const load = useCallback(async () => {
    if (!api.mcpStore) return
    setLoading(true)
    try {
      setView(readMcpStoreView(await api.mcpStore(projectPath)))
      setProblem('')
    } catch (error) {
      setView(EMPTY_STORE_VIEW)
      setProblem(error instanceof Error ? error.message : 'The catalogue could not be read.')
    } finally {
      setLoading(false)
    }
  }, [api, projectPath])

  useEffect(() => {
    void load()
  }, [load])

  const act = useCallback(
    async (row: Row, verb: 'install' | 'remove') => {
      const call = verb === 'install' ? api.mcpStoreInstall : api.removeMcpServer
      if (!call) return
      setBusy(row.id)
      setArming('')
      try {
        const request =
          verb === 'install'
            ? { id: row.id, scope, projectPath, values: values[row.id] ?? {} }
            : { name: row.name, scope: row.scope === '' ? scope : row.scope, projectPath }
        const result = readMcpStoreResult(await call(request))
        setSaid((was) => ({ ...was, [row.id]: result.message }))
        if (result.ok && verb === 'install') {
          // The typed secret does not stay in the renderer's state once it has
          // been written. Nothing reads it back — the row redraws as installed —
          // and a token sitting in a React state tree for the rest of the
          // session is a token in a heap snapshot for the rest of the session.
          setValues((was) => {
            const next = { ...was }
            delete next[row.id]
            return next
          })
        }
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [row.id]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        // Off the configuration, not off an assumption about what the call did.
        await load()
        onChanged()
      }
    },
    [api, scope, projectPath, values, load, onChanged],
  )

  const setValue = useCallback((id: string, key: string, value: string) => {
    setValues((was) => ({ ...was, [id]: { ...(was[id] ?? {}), [key]: value } }))
  }, [])

  if (!api.mcpStore) {
    return (
      <PageEmpty icon={panelSpec('mcp').icon} title="The store is not in this build">
        This window was opened by an older version of the app, which has no catalogue to read.
      </PageEmpty>
    )
  }

  return (
    <div className="mcp-store">
      <StoreHeader
        view={view}
        here={here}
        loading={loading}
        scope={scope}
        scopes={scopes}
        adding={adding}
        onScope={setScope}
        onReload={() => void load()}
        onAdd={() => setAdding((open) => !open)}
      />

      {adding && (
        <McpAddForm
          projectPath={projectPath}
          onSubmit={(request) => submitAdd(api, request)}
          onAdded={() => {
            setAdding(false)
            void load()
            onChanged()
          }}
          onCancel={() => setAdding(false)}
        />
      )}

      {problem !== '' && <p className="mcp-error">{problem}</p>}

      {loading && view.rows.length === 0 && problem === '' && (
        <PageNote page busy>
          Looking at what this machine can run…
        </PageNote>
      )}

      {!view.writer.found && !loading && (
        <p className="mcp-note">
          Claude Code’s command line tool is what writes this configuration, and it was not found on
          this machine. Nothing below can be installed until it is.
        </p>
      )}

      <StoreBody
        view={view}
        busy={busy}
        values={values}
        said={said}
        arming={arming}
        onValue={setValue}
        onAct={(row, verb) => void act(row, verb)}
        onArm={(id, on) => setArming(on ? id : '')}
      />
    </div>
  )
}

/* ----------------------------------------------------------------- body -- */

export interface StoreBodyProps {
  view: McpStoreView
  /** The row id with something in flight, so its button can say so. */
  busy: string
  /** Row id → what was typed into its fields. */
  values: Record<string, Record<string, string>>
  /** Row id → the sentence its last press produced. */
  said: Record<string, string>
  /** The row whose Remove is waiting for its second press. */
  arming: string
  onValue(id: string, key: string, value: string): void
  onAct(row: Row, verb: 'install' | 'remove'): void
  onArm(id: string, on: boolean): void
}

/**
 * Every section, as a pure function of the loaded view.
 *
 * Split from {@link McpStore} for the reason `browser/StorePanel.tsx` gives
 * about its own `StoreBody`: the panel loads through effects, which SSR never
 * runs, so a test that rendered the panel would be asserting on an empty shell
 * — *"proof by a function nothing calls"*. This is the surface a person
 * actually reads, so this is the surface that gets rendered and looked at.
 */
export function StoreBody({
  view,
  busy,
  values,
  said,
  arming,
  onValue,
  onAct,
  onArm,
}: StoreBodyProps) {
  return (
    <>
      {SECTIONS.map((section) => {
        const rows = view.rows.filter((row) => row.state === section.key)
        if (rows.length === 0) return null
        return (
          <section className="mcp-store-section" key={section.key}>
            <h3 className="mcp-store-heading">{section.heading}</h3>
            <p className="mcp-store-note">{section.note}</p>
            <ul className="mcp-store-list">
              {rows.map((row) => (
                <McpStoreRow
                  key={row.id}
                  row={row}
                  busy={busy === row.id}
                  values={values[row.id] ?? {}}
                  said={said[row.id] ?? ''}
                  arming={arming === row.id}
                  onValue={(key, value) => onValue(row.id, key, value)}
                  onAct={(verb) => onAct(row, verb)}
                  onArm={(on) => onArm(row.id, on)}
                />
              ))}
            </ul>
          </section>
        )
      })}
    </>
  )
}

/**
 * Hand the add form's draft to the bridge.
 *
 * A named function rather than an inline arrow so the "add your own" path has
 * one call site and the same narrowing every other write here gets. The form
 * wants an `McpAddResult`, which is the same two fields under a different name.
 */
async function submitAdd(api: McpStoreApi, request: Record<string, unknown>): Promise<McpAddResult> {
  // Deliberately not `mcpStoreInstall`: that channel installs *catalogue rows*
  // by id and would reject a hand-written command. The add form has always gone
  // through `mcp:add`, which is the channel that takes a whole server, so it
  // keeps going through it — one write path per kind of thing being written.
  if (!api.addMcpServer) return { ok: false, message: 'This build cannot write servers.' }
  return readMcpStoreResult(await api.addMcpServer(request))
}

/* ----------------------------------------------------------------- head -- */

export interface StoreHeaderProps {
  view: McpStoreView
  here: string
  loading: boolean
  scope: McpAddScope
  scopes: ReturnType<typeof scopeChoices>
  adding: boolean
  onScope(next: McpAddScope): void
  onReload(): void
  onAdd(): void
}

/**
 * The store's own bar: where installs land, what this machine has, and the two
 * things you can do that are not about one row.
 *
 * Its own component, and exported, because this project renders tests to static
 * markup — the panel above loads through an effect, which SSR never runs, so
 * anything worth asserting has to live somewhere that can be rendered on its
 * own.
 */
export function StoreHeader({
  view,
  here,
  loading,
  scope,
  scopes,
  adding,
  onScope,
  onReload,
  onAdd,
}: StoreHeaderProps) {
  return (
    <>
      <header className="mcp-head">
        <div className="mcp-subheading">
          <HoverNote label="Where these are installed">
            {`Install writes the server into your Claude Code configuration on ${here}, through the same command line tool that owns that file. Nothing here is downloaded by this app: the server itself is fetched by npx, uvx or docker the first time a session starts it.`}
          </HoverNote>
          {scopes.length > 1 && (
            <SegmentedSwitch
              inline
              options={scopes.map((choice) => ({
                id: choice.value,
                label: choice.label,
                title: choice.help,
              }))}
              value={scope}
              onChange={onScope}
              label="Where an installed server is saved"
            />
          )}
        </div>
        <div className="mcp-head-actions">
          <button type="button" className="mcp-add-open" onClick={onAdd}>
            {adding ? 'Close' : 'Add your own'}
          </button>
          <button type="button" className="mcp-refresh" onClick={onReload} disabled={loading}>
            {loading ? 'Reading…' : 'Reload'}
          </button>
        </div>
      </header>

      {/*
        What was looked for on this machine, and what was found. Every "cannot
        run on this machine" sentence below refers back to this line, so it is
        shown whether or not anything is missing — a claim about somebody's
        computer should show its working.
      */}
      {view.runtimes.length > 0 && (
        <ul className="mcp-store-runtimes">
          {view.runtimes.map((runtime) => (
            <li key={runtime.id} data-found={runtime.found}>
              <code>{runtime.binary}</code>
              {runtime.found ? (
                <span className="mcp-meta-dim" title={runtime.path}>
                  {runtime.path}
                </span>
              ) : (
                <span className="mcp-meta-dim">not on this machine — needs {runtime.needs}</span>
              )}
            </li>
          ))}
          {/*
            Where the "already in your shell" offers come from, said once.
            `unavailable` is not "nothing is set" — it is "the shell could not be
            asked" — and the two must not read the same, or somebody pastes a
            token they already had.
          */}
          <li data-found={view.environmentSource !== 'unavailable'}>
            <code>environment</code>
            <span className="mcp-meta-dim">
              {view.environmentSource === 'login-shell'
                ? 'read from your login shell, by name only — no value ever reaches this app'
                : view.environmentSource === 'process'
                  ? 'read from this app’s own environment, which on Windows is yours'
                  : 'your login shell could not be asked, so no field claims a value is already there'}
            </span>
          </li>
        </ul>
      )}
    </>
  )
}
