import { useCallback, useMemo, useState, type ReactNode } from 'react'
import { PageEmpty } from '../components/PageEmpty'
import { useFeatures } from '../features/FeaturesProvider'
import { hereName } from '../machines/types'
import { useMachines } from '../machines/useMachines'
import { panelSpec } from '../shell/panels'
import {
  BROWSER_SHELVES,
  BrowserStoreDepartment,
} from '../browser/StorePanel'
import { extensionsAvailable, resolveExtensionsApi } from '../browser/extensions-bridge'
import { resolveStoreApi, storeAvailable } from '../browser/store-bridge'
import { McpStore } from '../components/McpStore'
import {
  MCP_CATEGORY_NAMES,
  MCP_CATEGORY_ORDER,
  mcpStoreAvailable,
  resolveMcpStoreApi,
} from '../components/mcp-store-bridge'
import {
  EVERYTHING,
  filterFor,
  navTotal,
  showsDepartment,
  storeEmpty,
  storeNav,
  storeShown,
  type StoreDepartmentId,
  type StoreDepartmentInput,
  type StoreNavDepartment,
  type StorePlace,
} from './store-nav'
import { NO_FILTER, type StoreFacets, type StoreFilter } from './storefront'
import './store-page.css'

/**
 * The store, as a page.
 *
 *   > *"store must be like a proper store with full page not just popup, and
 *   > should allow custom tools and store, and maybe some other tools paid ones
 *   > too not just open source, with logos, and also all other regular tools too
 *   > like google's ones or like this"*
 *
 * ## What was wrong, and it was not the styling
 *
 * There were **two** stores and neither of them was anywhere. The browser's was
 * a modal dialog reached from a three-dot menu inside a browser tab; the MCP one
 * was the second tab of the MCP servers page, which you had to already be on.
 * Both were argued for at the time and both arguments were locally right — the
 * browser chrome has no page to put a dialog on, and two rail rows about MCP
 * servers would have been the *Machines vs Remote* split we already had to undo.
 *
 * What neither argument could see is that they are **one subject**. Forty-odd
 * things you can add to this app, half of them behind one door and half behind
 * another, with a shared search model between them that no single screen ever
 * used at full size. `shell/panels.ts` carries the argument for why a store
 * earns a row in the rail where a pop-up and a window do not.
 *
 * ## One store, two departments
 *
 * The two halves genuinely install different kinds of thing — one fetches a
 * program and fingerprints it, the other writes a command line into your agent's
 * configuration — and `store/storefront.ts` spends a section on why they must
 * **not** be forced to share a vocabulary they did not both measure. So they are
 * departments, not a merged list: each keeps its own rows, its own words, its own
 * chips and its own honesty about what it did and did not measure.
 *
 * What the page adds on top is the part a dialog could not have:
 *
 *  - **One search box, over the whole store.** Typing `github` finds the browser
 *    extension and the MCP server in one go, and the rail says how many of each.
 *    Two boxes would have meant whichever half you typed into decided what you
 *    concluded the store contained.
 *  - **A rail of every shelf, with a count on each**, across both departments —
 *    which is the *"separation of the categories … so they can categorize and
 *    choose which specific tool they want"* he asked for, at a size where it
 *    fits.
 *  - **A detail view**, so one row can be read without the other forty. It shows
 *    the *same row component* the shelf does, and that is a rule rather than an
 *    accident: see `store/StoreDetail.tsx`.
 *
 * ## The old doors still open, and they open this
 *
 * The browser's three-dot → Store navigates here. The MCP page's Store control
 * navigates here. Neither draws a store of its own any more, so there is one
 * implementation and three ways to reach it — which is the opposite of what was
 * there before, where there were two implementations and two ways.
 *
 * ## Why the rail counts rows this page never loaded
 *
 * It does not: the departments load their own catalogues and report what they
 * found through `onRows`, as {@link StoreFacets} — the one projection both
 * halves already share. Hoisting the loading up here would have made the page
 * the thing that knows about `.crx` signatures *and* about `npx`, and every
 * per-row failure sentence would have had to travel through it. See
 * `store/store-nav.ts`, which takes facets and has no idea which half it is
 * counting.
 */

/* --------------------------------------------------------------- container -- */

interface Props {
  /**
   * The folder this window has open, or `null`.
   *
   * The servers department needs it and the extensions department does not,
   * which is exactly why it is passed rather than reached for: an MCP server can
   * be installed for **this project** as well as for you, and the scope picker
   * cannot offer that choice without knowing whether there is a project. With no
   * folder open the picker offers `user` alone, which is true rather than
   * broken — the store is worth browsing on a fresh install with nothing opened.
   */
  projectPath: string | null
}

export function StorePage({ projectPath }: Props) {
  const features = useFeatures()
  /*
   * What this computer is called, for the servers department's sentence about
   * where an install lands. The same read the MCP page makes, through the same
   * hook, so the two screens cannot end up naming this machine differently.
   */
  const here = hereName(useMachines())

  /*
   * The bridges, resolved once. Nothing is asked of them here — each department
   * does its own reading — so this is only about whether the door exists.
   */
  const store = useMemo(() => resolveStoreApi(), [])
  const extensions = useMemo(() => resolveExtensionsApi(), [])
  const mcp = useMemo(() => resolveMcpStoreApi(), [])

  /*
   * Which departments this window can honestly draw.
   *
   * Two questions, and both have to be yes. **Is it wired** — a preload older
   * than a half cannot answer for it, and a department that could list nothing
   * and install nothing is not a department, it is an apology. **Is its feature
   * installed** — the browser department configures the built-in browser and the
   * servers department configures MCP servers, and with either uninstalled every
   * button in that half writes to something that is not there.
   *
   * This is why the page itself is owned by no feature: it has two, and a panel
   * can only be owned by one. `shell/panels.ts` has the full argument. The
   * consequence on screen is the standing rule — an unavailable department is
   * **absent**, not greyed, and the store is still a store with one of them.
   */
  const browserWired =
    features.on('browser') && (storeAvailable(store) || extensionsAvailable(extensions))
  const serversWired = features.on('mcp') && mcpStoreAvailable(mcp)

  /**
   * The one search box, and the two sets of chips.
   *
   * Split deliberately. A query means the same thing in both halves, so it is
   * shared and typing it searches the whole shop. A **chip** does not: an
   * extension comes from a `release` or from a folder somebody added, a server
   * from a `reference` project or a `third-party` one, and the two lists have no
   * word in common. Sharing that value made pressing a chip under one heading empty
   * the department under the other — found by rendering the page and looking at
   * it. `store/store-nav.ts` carries the argument.
   */
  const [query, setQuery] = useState('')
  const [chips, setChips] = useState<Record<StoreDepartmentId, StoreFilter>>({
    extensions: NO_FILTER,
    servers: NO_FILTER,
  })
  const [place, setPlace] = useState<StorePlace>(EVERYTHING)
  /**
   * The one row being read on its own, as a prefixed key, or `''`.
   *
   * Prefixed because three kinds of row can be opened and they are numbered
   * independently — `e:` an extension, `t:` a built-in tool, `m:` a server. The
   * prefix is also what tells this page which department owns the key without
   * asking either of them.
   */
  const [detail, setDetail] = useState('')
  /** What each department reported it had, for the rail's counts. */
  const [rows, setRows] = useState<Record<StoreDepartmentId, StoreFacets[]>>({
    extensions: [],
    servers: [],
  })

  const reportExtensions = useCallback((found: StoreFacets[]) => {
    setRows((was) => ({ ...was, extensions: found }))
  }, [])
  const reportServers = useCallback((found: StoreFacets[]) => {
    setRows((was) => ({ ...was, servers: found }))
  }, [])

  const departments: StoreDepartmentInput[] = [
    {
      id: 'extensions',
      name: 'Browser extensions',
      wired: browserWired,
      shelves: BROWSER_SHELVES,
      rows: rows.extensions,
      filter: { ...chips.extensions, query },
    },
    {
      id: 'servers',
      name: 'MCP servers',
      wired: serversWired,
      shelves: MCP_CATEGORY_ORDER.map((id) => ({ id, name: MCP_CATEGORY_NAMES[id] })),
      rows: rows.servers,
      filter: { ...chips.servers, query },
    },
  ]

  /*
   * Going somewhere else in the store closes whatever was open on its own.
   *
   * Without this, pressing a shelf while reading one row would filter a list
   * nobody can see and leave the person looking at the same row, which is a
   * control that appears to do nothing — the one defect this window's reviews
   * keep coming back to.
   */
  const goTo = useCallback((next: StorePlace) => {
    setDetail('')
    setPlace(next)
  }, [])

  const search = useCallback((next: string) => {
    setDetail('')
    setQuery(next)
  }, [])

  /* One department's chips, changed without touching the other's. The query
     rides along in the value each department is handed, so a bar that sets it
     — the Clear button does — is honoured for the whole store. */
  const setChipsFor = (id: StoreDepartmentId) => (next: StoreFilter) => {
    setQuery(next.query)
    setChips((was) => ({ ...was, [id]: next }))
  }

  return (
    <StorePageFrame
      departments={departments}
      place={place}
      detail={detail}
      onQuery={search}
      onPlace={goTo}
      onClear={() => {
        setDetail('')
        setQuery('')
        setChips({ extensions: NO_FILTER, servers: NO_FILTER })
        setPlace(EVERYTHING)
      }}
      department={(id) =>
        id === 'extensions' ? (
          <BrowserStoreDepartment
            store={store}
            extensions={extensions}
            filter={filterFor(place, departments[0])}
            onFilter={setChipsFor('extensions')}
            detail={detail}
            onDetail={setDetail}
            onRows={reportExtensions}
          />
        ) : (
          <McpStore
            api={mcp}
            projectPath={projectPath}
            here={here}
            /*
             * Nothing to tell. On the MCP page this re-read the list of
             * configured servers in the tab next door; here there is no tab next
             * door, and the department already re-reads its own rows after every
             * write, off the configuration rather than off an assumption. The
             * MCP page reads when it is opened, so it cannot show a stale answer
             * either.
             */
            onChanged={() => {}}
            filter={filterFor(place, departments[1])}
            onFilter={setChipsFor('servers')}
            detail={detail.startsWith('m:') ? detail.slice(2) : ''}
            onDetail={(id) => setDetail(id === '' ? '' : `m:${id}`)}
            onRows={reportServers}
          />
        )
      }
    />
  )
}

/* ------------------------------------------------------------------ frame -- */

/**
 * Which department owns a row key, or `null` when nothing is open.
 *
 * The three prefixes are minted here — `e:` an extension, `t:` a built-in tool,
 * `m:` a server — because three kinds of row are numbered independently and a
 * bare id could name two of them. Reading them back is what lets the frame put
 * the *other* department away while one row is being read: without it, opening
 * uBlock Origin left eighteen MCP servers still on screen underneath it, which
 * is a detail view that is not one.
 *
 * Pure and exported so the harness stands the page in the same states the app
 * does, and so the mapping is one thing rather than a `startsWith` in three
 * places.
 */
export function departmentOfRow(key: string): StoreDepartmentId | null {
  if (key.startsWith('e:') || key.startsWith('t:')) return 'extensions'
  if (key.startsWith('m:')) return 'servers'
  return null
}

export interface StorePageFrameProps {
  /** Both halves, each carrying its own rows and its own filter. */
  departments: readonly StoreDepartmentInput[]
  place: StorePlace
  /** The prefixed key of the row being read on its own, or `''`. */
  detail: string
  onQuery(next: string): void
  onPlace(next: StorePlace): void
  onClear(): void
  /** One department's whole surface. Called for every wired department. */
  department(id: StoreDepartmentId): ReactNode
}

/**
 * Everything a person reads, as a pure function of what the departments found.
 *
 * Split from {@link StorePage} for the reason both departments already split
 * theirs: the container loads through effects, which SSR never runs, so a test
 * or a harness rendering the container would be looking at an empty shell —
 * *"proof by a function nothing calls"*, which this store has been audited for
 * once already.
 */
export function StorePageFrame({
  departments,
  place,
  detail,
  onQuery,
  onPlace,
  onClear,
  department,
}: StorePageFrameProps) {
  const nav = storeNav(departments, place)
  const wired = departments.filter((one) => one.wired)
  const stock = wired.reduce((sum, one) => sum + one.rows.length, 0)
  const empty = storeEmpty(departments, place)
  const reading = departmentOfRow(detail)
  /* Every department is handed the same query — only the chips differ — so any
     of them can answer what was typed. */
  const query = wired[0]?.filter.query ?? ''
  const searching = query.trim() !== ''
  /**
   * Whether the page is showing less than the whole shop.
   *
   * What it decides: a department with nothing left in it is **taken off the
   * screen** rather than left drawing its headings, its notes and its "Add your
   * own" over a shelf of nothing. That had to be seen to be believed — searching
   * `github` drew *Browser extensions 0* followed by four paragraphs, two
   * buttons and two folder paths, above the one row that actually matched.
   *
   * Only while something is narrowed. With nothing typed and nothing chosen, an
   * empty department is a real state worth showing — it is where Add your own
   * lives, and a fresh install with no catalogue is entitled to say so.
   */
  const narrowed = searching || place.kind !== 'all'

  return (
    <div className="store-page">
      {/*
        The header. No title in it: the window's own bar already says **Store**
        — `App.tsx` takes it from `panelSpec` — and a page that repeats its own
        name in 24px is the duplication this window keeps having to delete.

        What is here instead is the one control that belongs to the whole store
        rather than to either half of it.
      */}
      <header className="store-head">
        <label className="store-search" htmlFor="store-search">
          <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
            <path
              d="M10.5 4.5a6 6 0 1 1 0 12 6 6 0 0 1 0-12zM15 15l4.5 4.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
            />
          </svg>
          <span className="store-search-label">Search the store</span>
          <input
            id="store-search"
            type="search"
            value={query}
            /*
             * Five words that each find something. `password` was one of them
             * and stopped being one: the extensions that answered it were
             * Chrome Web Store links and are gone, and no server's name, summary
             * or tags contains it either. A placeholder is a promise about what
             * is in the shop, and one that suggests a search returning nothing
             * is the same defect as a chip with a count of zero.
             */
            placeholder="adblock, cookies, youtube, postgres, github…"
            autoComplete="off"
            spellCheck={false}
            onChange={(event) => onQuery(event.target.value)}
          />
        </label>
        {/*
          The count, and the way out, and only once there is something to
          count away from. *"42 of 42"* before anybody has touched anything is
          noise, and a Clear with nothing to clear is a control that does
          nothing — the same rule the department bars obey.
        */}
        {narrowed && (
          <div className="store-head-summary">
            {/* What is on screen, over what the shop holds. Not the rail's
                numbers: those ignore the shelf you are standing on, by design,
                so summing them printed *44 of 44* over a shelf of two. */}
            <span className="store-head-count">
              {storeShown(departments, place)} of {stock}
            </span>
            <button type="button" className="store-head-clear" onClick={onClear}>
              Show everything
            </button>
          </div>
        )}
      </header>

      <div className="store-body">
        {/*
          The rail: every shelf in the shop, with how much is on it.

          Down the side rather than across the top because there are sixteen of
          them and a wrapped row of sixteen chips is a paragraph. It is a `nav`
          of buttons rather than links, because nothing here is a URL — pressing
          one filters the page it is on.
        */}
        <nav className="store-rail" aria-label="Departments and shelves">
          <button
            type="button"
            className="store-rail-all"
            data-on={place.kind === 'all' || undefined}
            aria-pressed={place.kind === 'all'}
            onClick={() => onPlace(EVERYTHING)}
          >
            Everything
            <span className="store-rail-count">{navTotal(nav)}</span>
          </button>
          {nav.map((entry) => (
            <RailDepartment key={entry.id} entry={entry} place={place} onPlace={onPlace} />
          ))}
        </nav>

        <div className="store-content">
          {/*
            The whole store's answer when nothing is on screen, and it is drawn
            *instead of* the departments rather than above them.

            Both of those matter. A department that has nothing left prints its
            own line — and its line can only speak for its own half, so under a
            single search box it would say "nothing matches" while the other
            department held two rows that did. `store/store-nav.ts` writes the
            sentence that can see the whole shop, and the halves stay mounted
            underneath so nothing is re-fetched when the search is cleared.
          */}
          {empty !== null && reading === null ? (
            <PageEmpty
              icon={panelSpec('store').icon}
              title={empty.title}
              action={
                empty.elsewhere > 0
                  ? { label: 'Look in the whole store', onClick: onClear, primary: true }
                  : undefined
              }
            >
              {empty.detail}
            </PageEmpty>
          ) : null}

          {wired.map((one) => (
              <section
                key={one.id}
                className="store-dept"
                /*
                  Hidden, never unmounted. A department that unmounted when you
                  pressed the other one would re-read its catalogue on the way
                  back, and — worse — the rail would lose the counts it reports,
                  so choosing *MCP servers* would blank the extension numbers on
                  the very control you used to get there.

                  Reading one row puts the other department away outright, and
                  that had to be found by looking: opening uBlock Origin drew its
                  detail view with eighteen MCP servers still browsing
                  underneath it, which is a page showing one thing and everything
                  else at the same time.
                */
                hidden={
                  reading !== null
                    ? reading !== one.id
                    : !showsDepartment(place, one.id) ||
                      empty !== null ||
                      (narrowed && (nav.find((entry) => entry.id === one.id)?.count ?? 0) === 0)
                }
              >
                <h2 className="store-dept-name">
                  {one.name}
                  {/* The size of the department, at the front door, where it
                      orients. Not while something is narrowed: the department's
                      own bar already says *2 of 18* six lines below, and a
                      second number beside the heading — with a different
                      denominator behind it — is one more thing to reconcile
                      for nothing. */}
                  {!narrowed && (
                    <span className="store-dept-count">
                      {nav.find((entry) => entry.id === one.id)?.count ?? 0}
                    </span>
                  )}
                </h2>
                {department(one.id)}
              </section>
            ))}
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------- rail -- */

function RailDepartment({
  entry,
  place,
  onPlace,
}: {
  entry: StoreNavDepartment
  place: StorePlace
  onPlace(next: StorePlace): void
}) {
  const on = place.kind === 'department' && place.department === entry.id
  return (
    <div className="store-rail-group">
      <button
        type="button"
        className="store-rail-dept"
        data-on={on || undefined}
        aria-pressed={on}
        onClick={() => onPlace({ kind: 'department', department: entry.id })}
      >
        {entry.name}
        <span className="store-rail-count">{entry.count}</span>
      </button>
      <ul className="store-rail-shelves">
        {entry.shelves.map((shelf) => {
          const chosen =
            place.kind === 'shelf' && place.department === entry.id && place.shelf === shelf.id
          return (
            <li key={shelf.id}>
              <button
                type="button"
                className="store-rail-shelf"
                data-on={chosen || undefined}
                aria-pressed={chosen}
                /* Pressing the shelf you are on goes back up to the whole
                   department rather than doing nothing — the same toggle the
                   storefront's chips have, so the rail cannot become a place
                   you can get into and not out of. */
                onClick={() =>
                  onPlace(
                    chosen
                      ? { kind: 'department', department: entry.id }
                      : { kind: 'shelf', department: entry.id, shelf: shelf.id },
                  )
                }
              >
                {shelf.name}
                <span className="store-rail-count">{shelf.count}</span>
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
