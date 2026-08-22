import { useCallback, useEffect, useMemo, useState } from 'react'
import { HoverNote } from './HoverNote'
import { McpAddForm, scopeChoices, type McpAddResult, type McpAddScope } from './McpAddForm'
import { McpStoreRow } from './McpStoreRow'
import { PageEmpty, PageNote } from './PageEmpty'
import { panelSpec } from '../shell/panels'
import { SegmentedSwitch } from './SegmentedSwitch'
import {
  EMPTY_STORE_VIEW,
  MCP_CATEGORY_NAMES,
  MCP_CATEGORY_ORDER,
  MCP_FACETS,
  mcpFacets,
  readMcpStoreResult,
  readMcpStoreView,
  type McpStoreApi,
  type McpStoreRow as Row,
  type McpStoreView,
} from './mcp-store-bridge'
import { StoreFilterBar } from '../store/StoreFilterBar'
import { StoreDetail } from '../store/StoreDetail'
import { withoutShelf } from '../store/store-nav'
import {
  facetControls,
  filtering as anyFilter,
  matchesFilter,
  NO_FILTER,
  shelve,
  withFacet,
  type StoreFacet,
  type StoreFacets,
  type StoreFilter,
} from '../store/storefront'

/**
 * The MCP store: a catalogue of servers, and a form for anything not in it.
 *
 * ## Where this lives, and why it stopped being a tab
 *
 * It was the **second tab of the MCP servers page**, and the argument for that
 * was a good one: browsing servers and seeing which you have are two views of
 * one subject, and a new rail row would have been the *Machines vs Remote* split
 * he already made us undo. What that argument missed is that there was a second
 * store — the browser's, behind a three-dot menu — and the two of them are also
 * one subject. Asad: *"store must be like a proper store with full page not just
 * popup."*
 *
 * So this is a **department** now, mounted by `store/StorePage.tsx` beside the
 * browser's, and the MCP page keeps one door to it rather than a copy of it. The
 * old argument still holds where it applied: there is exactly one place that
 * browses servers, and it reads the same catalogue the list next door does, so a
 * row cannot claim "not installed" about something the other screen is showing.
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
 * ## Why it browses by shelf rather than by state
 *
 *   > *"make a proper search page and everything proper filters and search and
 *   > separation of the categories … so they can categorize and choose which
 *   > specific tool they want."*
 *
 * This used to draw four sections named after a row's **state**: Installed,
 * Ready to install, A server already has this name, Cannot run on this machine.
 * Nineteen rows in four bins, sorted by an answer to a question nobody arrives
 * with. State did not disappear — it moved onto the row, as a chip and a
 * sentence, which is where the browser store has always carried it — and the
 * headings are now the nine things a server can do for you.
 *
 * The search box, the five filters and their counts are
 * `store/StoreFilterBar.tsx` over `store/storefront.ts`, which is the *same*
 * component and the same model the browser's store draws. Two stores in one
 * release have to read as one product, and two nearly-identical search boxes is
 * how that stops being true by the third change to either.
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
  /**
   * What the store page is searching and filtering for.
   *
   * Controlled from above, because one search box searching the whole store is
   * the thing a page can do that two dialogs could not. The shelf inside it
   * belongs to this department alone — `store/store-nav.ts` says why the two
   * catalogues cannot share one.
   */
  filter: StoreFilter
  onFilter(next: StoreFilter): void
  /** The one row being looked at on its own, or `''`. A row id, not a key. */
  detail: string
  onDetail(key: string): void
  /**
   * What this department loaded, as the shared storefront model sees it, so the
   * page's rail can count its shelves. See the same prop on the browser
   * department for why the loading stays down here.
   */
  onRows(rows: StoreFacets[]): void
}

/**
 * Where a row sits *within* its shelf.
 *
 * What can be installed first, then a name collision, then a runtime this
 * machine does not have. The same shape as the browser store's ordering and for
 * the same reason: the useful rows come first, and the two kinds of row with no
 * Install stay apart rather than being swept into one bin that reads as *the
 * broken ones*. Neither is a dead end now — both carry a Get it.
 */
const RANK: Readonly<Record<Row['state'], number>> = {
  available: 0,
  installed: 0,
  taken: 1,
  unavailable: 2,
}

export function McpStore({
  api,
  projectPath,
  here,
  onChanged,
  filter,
  onFilter,
  detail,
  onDetail,
  onRows,
}: Props) {
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

  /* What is on these shelves, for the page's rail. Keyed on the loaded view
     rather than on a derived array, so it fires once per read. */
  useEffect(() => {
    onRows(view.rows.map(mcpFacets))
  }, [view, onRows])

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

  /*
   * One server, on its own, when the page has been sent to one.
   *
   * Resolved out of the same `view` the shelves are drawn from, so a row that
   * left the catalogue between reads cannot leave a detail view framing nothing:
   * it is simply not found, and the shelves come back.
   *
   * The header stays above it — the scope picker, the runtime report, Add your
   * own. Every one of those is a fact about *this machine* that the Install
   * button on the row below depends on, and hiding the report while showing the
   * row that refers to it would leave the sentence *"docker is not on this
   * machine"* pointing at nothing.
   */
  const open = view.rows.find((row) => row.id === detail)

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

      {open ? (
        <StoreDetail
          backTo={MCP_CATEGORY_NAMES[open.category] ?? 'the store'}
          onBack={() => onDetail('')}
        >
          <ul className="mcp-store-list">
            <McpStoreRow
              row={open}
              busy={busy === open.id}
              values={values[open.id] ?? {}}
              said={said[open.id] ?? ''}
              arming={arming === open.id}
              onValue={(key, value) => setValue(open.id, key, value)}
              onAct={(verb) => void act(open, verb)}
              onArm={(on) => setArming(on ? open.id : '')}
            />
          </ul>
        </StoreDetail>
      ) : (
        <StoreBody
          view={view}
          busy={busy}
          values={values}
          said={said}
          arming={arming}
          filter={filter}
          onFilter={onFilter}
          onOpenRow={onDetail}
          onValue={setValue}
          onAct={(row, verb) => void act(row, verb)}
          onArm={(id, on) => setArming(on ? id : '')}
        />
      )}
    </div>
  )
}

/* --------------------------------------------------------------- detail -- */



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
  filter: StoreFilter
  onFilter(next: StoreFilter): void
  /**
   * Open one row on its own. Optional, and the rows draw no way in without it —
   * see `store/StoreRowName.tsx` for why that is absent rather than disabled.
   */
  onOpenRow?(id: string): void
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
  filter,
  onFilter,
  onOpenRow,
  onValue,
  onAct,
  onArm,
}: StoreBodyProps) {
  /*
   * The whole catalogue as the shared storefront sees it, computed once. Once
   * because it feeds the chips' counts, the Installed section and the shelves,
   * and three call sites deriving the same projection is three chances for one
   * of them to drift.
   */
  const facets = new Map(view.rows.map((row) => [row.id, mcpFacets(row)]))
  const facetsOf = (row: Row) => facets.get(row.id) ?? mcpFacets(row)
  const kept = view.rows.filter((row) => matchesFilter(facetsOf(row), filter))
  const installed = kept.filter((row) => row.state === 'installed')
  const browsing = kept.filter((row) => row.state !== 'installed')
  const shelves = shelve(
    browsing,
    MCP_CATEGORY_ORDER.map((id) => ({ id, name: MCP_CATEGORY_NAMES[id] })),
    facetsOf,
    (row) => RANK[row.state],
  )
  /* Every facet except the shelf: the store page's left rail owns the shelves
     now, with a count on each and across both departments, and a second row of
     chips saying the same thing would be two controls for one choice. The
     category is still applied as a filter — only its chips are gone. */
  const controls = facetControls([...facets.values()], filter, withoutShelf(MCP_FACETS))
  const isFiltering = anyFilter(filter)

  const line = (row: Row) => (
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
      onOpen={onOpenRow === undefined ? undefined : () => onOpenRow(row.id)}
    />
  )

  return (
    <>
      {/*
        The browsing controls, shared with the browser's store — same component,
        same search, same rule about not drawing a chip that would leave nothing.

        This store used to group by *state*: Installed, Ready to install, A
        server already has this name, Cannot run on this machine. That is four
        bins holding nineteen rows and it answers only one question, which is one
        nobody arrives with. Asad: *"make a proper search page and everything
        proper filters and search and separation of the categories … so they can
        categorize and choose which specific tool they want."* State did not
        disappear — it moved onto the row, as a chip and a sentence, which is
        where the browser store has always carried it.
      */}
      <section className="mcp-store-section">
        <StoreFilterBar
          idPrefix="mcp"
          placeholder="files, search, postgres, github…"
          /* The store page carries the one search box, over both departments. */
          search={false}
          filter={filter}
          controls={controls}
          showing={kept.length}
          total={view.rows.length}
          active={isFiltering}
          onQuery={(next) => onFilter({ ...filter, query: next })}
          onFacet={(facet: StoreFacet, value) => onFilter(withFacet(filter, facet, value))}
          onClear={() => onFilter(NO_FILTER)}
        />
      </section>

      {installed.length > 0 && (
        <section className="mcp-store-section">
          <h3 className="mcp-store-heading">Installed</h3>
          <p className="mcp-store-note">
            Configured on this machine. Remove takes the line back out of the configuration.
          </p>
          <ul className="mcp-store-list">{installed.map(line)}</ul>
        </section>
      )}

      {/*
        The one thing every shelf below mixes, said once rather than under each
        heading. Directly above the first shelf rather than up with the controls,
        because it is about the rows and the controls are about the whole screen.
      */}
      {shelves.length > 0 && (
        <p className="mcp-store-note">
          Nothing here ships inside this app. Install writes the command on the row into your
          configuration; the server itself is fetched by npx, uvx or docker the first time it
          runs. A row with no Install says which of two things is true of it — the runtime it
          needs is not on this machine, or a server of that name is already configured and is not
          this one — and carries <strong>Get it</strong>, which opens the project&rsquo;s own page
          and installs nothing.
        </p>
      )}

      {/*
        Three different true sentences. The middle one had to be added after
        rendering this and looking at it: filtering to *Files on this machine*,
        whose one row is installed, drew "Nothing in the catalogue matches that"
        directly under the row that matched. What is empty there is the browsing
        area, not the catalogue.
      */}
      {shelves.length === 0 ? (
        <p className="mcp-note">
          {kept.length === 0
            ? isFiltering
              ? 'Nothing in the catalogue matches that.'
              : 'There is nothing in the catalogue to browse.'
            : isFiltering
              ? 'Everything that matches is already in your configuration — it is above.'
              : 'Everything in the catalogue is already in your configuration.'}
        </p>
      ) : (
        shelves.map((shelf) => (
          <section className="mcp-store-section" key={shelf.id}>
            <h3 className="mcp-store-heading">{shelf.name}</h3>
            <ul className="mcp-store-list">{shelf.rows.map(line)}</ul>
          </section>
        ))
      )}
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
