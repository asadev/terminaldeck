import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { HoverNote } from './HoverNote'
import {
  editStart,
  importStart,
  McpAddForm,
  scopeChoices,
  type McpAddResult,
  type McpAddScope,
  type McpFormStart,
} from './McpAddForm'
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
  readMcpImport,
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
 * ## Add your own is a shelf of the store, not a button above it
 *
 *   > *"people like to use their own kind of extension … they can just click and
 *   > attach their own things to this application."*
 *   > *"should allow custom tools and store"*
 *
 * The form used to open from a button in the bar, and that was half of it: you
 * could add a server, and then the thing you added **was not in the store**. It
 * went into the configuration, the list on the MCP page showed it, and the store
 * you added it from carried on drawing the catalogue, none of which was yours.
 * Nothing to search, nothing to filter to, no row to read back what you typed,
 * no Edit, and the only Remove was on a different screen. That is an escape
 * hatch out of the store rather than a part of it.
 *
 * So *Added by you* is now the **first shelf**: the door is a card on it, and
 * every server somebody added is a row on it, with the same chips, the same
 * search, an Edit and a Remove. `src/main/mcp-custom.ts` builds those rows and
 * says what such a row is and is not allowed to claim; the *Added by you* value
 * of the **Where it comes from** filter sits next to *Official reference*, which
 * is where a person looks for it, and the page's rail carries the same shelf for
 * this department that it already carried for the browser's.
 *
 * The catalogue is the convenience; arbitrary servers are the capability. A
 * store that buried the second under the first would be offering a walled garden
 * with a suggestion box.
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
  /**
   * The form is open, and what it is doing.
   *
   * One piece of state rather than three booleans, because *adding*, *editing
   * this row* and *editing that row* are one exclusive choice and three flags
   * would eventually be two of them true. `start` carries whatever the form
   * opens filled in with — an edit's fields, or a definition read out of a file.
   */
  const [form, setForm] = useState<
    { mode: 'add' | 'edit'; row: Row | null; start: McpFormStart | undefined } | null
  >(null)
  /** What the last add, import or export said. Not attached to any one row. */
  const [saidOwn, setSaidOwn] = useState('')
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

  /**
   * Open the form on a server that is already configured.
   *
   * The fields it opens with are the ones this app is allowed to know: the
   * command as it is written, and the variable **names**. Their values are not
   * sent to a renderer and never have been, so they arrive as `KEY=` with
   * nothing after — and an empty value means *keep what is saved*, which the
   * form says out loud and `src/main/mcp-edit.ts` enforces.
   */
  const edit = useCallback((row: Row) => {
    setSaidOwn('')
    setForm({
      mode: 'edit',
      row,
      start: editStart({
        name: row.name,
        // `''` cannot happen on a configured row — `buildStoreView` fills the
        // scope for anything it found in the configuration — but the type allows
        // it, and `user` is the one scope that is always writable.
        scope: row.scope === '' ? 'user' : row.scope,
        transport: row.transport,
        command: row.command,
        envKeys: row.envKeys,
      }),
    })
  }, [])

  /**
   * Read a definition somebody sent, into the form.
   *
   * Never a write. What comes back is a draft with its variables empty — the
   * file carries names and no values, on purpose — so the person fills them in
   * and presses the button, exactly as they would for a catalogue row that needs
   * a token. See `src/main/mcp-share.ts`.
   */
  const importOne = useCallback(async () => {
    if (!api.importMcpServer) return
    setBusy('own')
    try {
      const result = readMcpImport(await api.importMcpServer())
      setSaidOwn(result.message)
      if (result.ok && result.draft !== null) {
        setForm({ mode: 'add', row: null, start: importStart(result.draft, scope) })
      }
    } catch (error) {
      setSaidOwn(error instanceof Error ? error.message : 'That file could not be read.')
    } finally {
      setBusy('')
    }
  }, [api, scope])

  /** Write one out as a file. The dialog and the path both stay in the main process. */
  const exportOne = useCallback(
    async (row: Row) => {
      if (!api.exportMcpServer) return
      setBusy(row.id)
      try {
        const result = readMcpStoreResult(
          await api.exportMcpServer(row.name, row.scope === '' ? 'user' : row.scope, projectPath),
        )
        // A cancelled dialog answers ok with an empty message. Changing your
        // mind is not a failure and must not be drawn as one.
        if (result.message !== '') setSaid((was) => ({ ...was, [row.id]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [row.id]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
      }
    },
    [api, projectPath],
  )

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
   * The header stays above it — the scope picker and the runtime report. Both
   * are facts about *this machine* that the Install button on the row below
   * depends on, and hiding the report while showing the row that refers to it
   * would leave the sentence *"docker is not on this machine"* pointing at
   * nothing.
   */
  const open = view.rows.find((row) => row.id === detail)

  /*
   * The form itself, handed down as one node.
   *
   * A slot rather than a flag, because the section that draws it lives in
   * `StoreBody` — which is the surface this project can render and look at,
   * since the panel around it loads through effects that SSR never runs. A
   * `StoreBody` that constructed the form would drag the whole bridge into
   * every test that wanted to read one shelf.
   */
  const formNode: ReactNode =
    form === null ? null : (
      <McpAddForm
        // Keyed on what is being edited, so switching straight from one row's
        // Edit to another's replaces the form's state instead of leaving the
        // first server's command sitting in the second server's form.
        key={form.row?.id ?? 'add'}
        projectPath={projectPath}
        mode={form.mode}
        start={form.start}
        onSubmit={(request) =>
          form.mode === 'edit' && form.row !== null
            ? submitEdit(api, form.row, projectPath, request)
            : submitAdd(api, request)
        }
        onAdded={(message) => {
          setForm(null)
          setSaidOwn(message)
          void load()
          onChanged()
        }}
        onCancel={() => setForm(null)}
      />
    )

  return (
    <div className="mcp-store">
      <StoreHeader
        view={view}
        here={here}
        loading={loading}
        scope={scope}
        scopes={scopes}
        onScope={setScope}
        onReload={() => void load()}
      />

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
              /* A row read on its own keeps every control it has on the shelf.
                 Edit sends the person back to the shelves, because that is where
                 the form is drawn — one form, in one place. */
              onEdit={
                open.custom && api.editMcpServer
                  ? () => {
                      onDetail('')
                      edit(open)
                    }
                  : undefined
              }
              onExport={
                open.custom && api.exportMcpServer ? () => void exportOne(open) : undefined
              }
            />
          </ul>
        </StoreDetail>
      ) : (
        <StoreBody
          view={view}
          busy={busy}
          values={values}
          said={said}
          saidOwn={saidOwn}
          arming={arming}
          filter={filter}
          form={formNode}
          canEdit={typeof api.editMcpServer === 'function'}
          canExport={typeof api.exportMcpServer === 'function'}
          canImport={typeof api.importMcpServer === 'function'}
          onFilter={onFilter}
          onOpenRow={onDetail}
          onValue={setValue}
          onAct={(row, verb) => void act(row, verb)}
          onArm={(id, on) => setArming(on ? id : '')}
          onAddOwn={() => {
            setSaidOwn('')
            setForm({ mode: 'add', row: null, start: undefined })
          }}
          onImport={() => void importOne()}
          onEdit={edit}
          onExport={(row) => void exportOne(row)}
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
  /** What the last add, import or export said. Belongs to the shelf, not a row. */
  saidOwn?: string
  /** The row whose Remove is waiting for its second press. */
  arming: string
  filter: StoreFilter
  /**
   * The add/edit form, or `null` when it is shut.
   *
   * A slot rather than a flag: the form needs the bridge and this component is
   * the one thing here a test can render on its own, so building it here would
   * put the bridge in the way of reading a shelf. The harness passes a stand-in.
   */
  form?: ReactNode
  /** Whether this build's preload carries each of the three optional doors. */
  canEdit?: boolean
  canExport?: boolean
  canImport?: boolean
  onFilter(next: StoreFilter): void
  /**
   * Open one row on its own. Optional, and the rows draw no way in without it —
   * see `store/StoreRowName.tsx` for why that is absent rather than disabled.
   */
  onOpenRow?(id: string): void
  onValue(id: string, key: string, value: string): void
  onAct(row: Row, verb: 'install' | 'remove'): void
  onArm(id: string, on: boolean): void
  onAddOwn(): void
  onImport(): void
  onEdit(row: Row): void
  onExport(row: Row): void
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
  saidOwn = '',
  arming,
  filter,
  form = null,
  canEdit = false,
  canExport = false,
  canImport = false,
  onFilter,
  onOpenRow,
  onValue,
  onAct,
  onArm,
  onAddOwn,
  onImport,
  onEdit,
  onExport,
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
  /*
   * Yours, and then the catalogue's. A custom row is always installed — that is
   * what being in the configuration means — so without this split every server
   * somebody typed would sit under *Installed* between two catalogue rows, which
   * is where they were invisible in the first place.
   */
  const own = kept.filter((row) => row.custom)
  const installed = kept.filter((row) => row.state === 'installed' && !row.custom)
  const browsing = kept.filter((row) => row.state !== 'installed')
  /** How many of yours there are before the filter, so the empty line can be true. */
  const ownTotal = view.rows.filter((row) => row.custom).length
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
      /*
       * Both are handed down only for a row they can act on, and only when this
       * build has the channel behind them. `McpStoreRow` draws no button for an
       * absent handler — absent rather than disabled, which is this app's
       * standing rule for a control that cannot do anything.
       */
      onEdit={row.custom && canEdit ? () => onEdit(row) : undefined}
      onExport={row.custom && canExport ? () => onExport(row) : undefined}
    />
  )

  return (
    <>
      {/*
        The browsing controls, shared with the browser's store — same component,
        same search, same rule about not drawing a chip that would leave nothing.

        This store used to group by *state*: Installed, Ready to install, A
        server already has this name, Cannot run on this machine. That is four
        bins holding the whole catalogue and it answers only one question, which is one
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

      {/*
        Added by you — the first shelf, and a shelf rather than a button.

        The form used to open from the bar above and what it added did not appear
        here at all: it went into the configuration, the MCP page listed it, and
        this store carried on showing a catalogue none of which was yours. So the
        door is a card on this shelf and everything you added is a row on it —
        same chips, same search, an Edit and a Remove. `mcp-custom.ts` builds
        those rows and is careful about what one is allowed to claim.

        The shelf is drawn whether or not you have anything on it, and that is
        deliberate: it is the way *in*, not a result. What the filter decides is
        which of your rows are listed under it.
      */}
      <section className="mcp-store-section mcp-store-own">
        <h3 className="mcp-store-heading">{MCP_CATEGORY_NAMES['your-own']}</h3>
        <p className="mcp-store-note">
          Any MCP server at all — one you are writing, one from a README, one your team runs.
          It is written into the same configuration the rows below are, through the same command
          line tool. This app measures one thing about it, which is whether the command it starts
          is on this machine, and claims nothing else.
        </p>
        {/*
          The form replaces the buttons rather than appearing under them: two
          ways into one form, both on screen, is two controls where the second
          does nothing.
        */}
        {form ?? (
          <div className="mcp-store-own-actions">
            <button type="button" className="mcp-store-install" onClick={onAddOwn}>
              Add your own tool…
            </button>
            {/* Reading a definition somebody sent. Drawn only when this build
                has the channel; see `mcp-share.ts` for what is in such a file
                and, just as importantly, what is not. */}
            {canImport && (
              <button
                type="button"
                className="mcp-server-action"
                disabled={busy === 'own'}
                onClick={onImport}
              >
                {busy === 'own' ? 'Reading…' : 'Open a shared one…'}
              </button>
            )}
          </div>
        )}
        {saidOwn !== '' && <p className="mcp-store-said">{saidOwn}</p>}
        {own.length > 0 && <ul className="mcp-store-list">{own.map(line)}</ul>}
        {/*
          Only when you have some and the filter is hiding all of them. Silence
          here would read as "you have added nothing", which would be false.
        */}
        {own.length === 0 && ownTotal > 0 && (
          <p className="mcp-store-note">
            {ownTotal === 1
              ? 'The one you added does not match that.'
              : `None of the ${ownTotal} you added match that.`}
          </p>
        )}
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
/**
 * Hand the form's draft to the edit channel, wrapped in what it addresses.
 *
 * The *original* name and scope travel beside the new ones, because those two
 * are what say which server is being changed — and a rename is a legitimate
 * edit, so the new name cannot be the one that finds it. See
 * `src/main/mcp-edit.ts` for the write itself, which is a remove and an add with
 * the original written back if the add fails.
 */
async function submitEdit(
  api: McpStoreApi,
  row: Row,
  projectPath: string | null,
  next: Record<string, unknown>,
): Promise<McpAddResult> {
  if (!api.editMcpServer) return { ok: false, message: 'This build cannot change servers.' }
  return readMcpStoreResult(
    await api.editMcpServer({
      name: row.name,
      scope: row.scope === '' ? 'user' : row.scope,
      projectPath,
      next,
    }),
  )
}

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
  onScope(next: McpAddScope): void
  onReload(): void
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
  onScope,
  onReload,
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
          {/*
            The "Add your own" button that was here is gone, and it went
            downwards rather than away: it is a card on the store's first shelf
            now, beside the rows it produces. A door in the bar over a store that
            did not contain what it added was the shape of the problem.
          */}
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
