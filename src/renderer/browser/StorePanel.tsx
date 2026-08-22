import { useCallback, useEffect, useState } from 'react'
import {
  readStoreResult,
  readStoreView,
  storeAvailable,
  type StoreApi,
  type StoreTool,
  type StoreView,
} from './store-bridge'
import {
  CATEGORY_NAMES,
  CATEGORY_ORDER,
  EXTENSION_FACETS,
  extensionFacets,
  extensionsAvailable,
  readExtensionResult,
  readExtensionsView,
  type ExtensionsApi,
  type ExtensionsView,
  type StoreExtension,
} from './extensions-bridge'
import { ToolRow } from './ToolRow'
import { ExtensionRow } from './ExtensionRow'
import { StoreFilterBar } from '../store/StoreFilterBar'
import { StoreDetail } from '../store/StoreDetail'
import { withoutShelf } from '../store/store-nav'
import {
  ANY,
  facetControls,
  filtering as anyFilter,
  matchesFilter,
  matchesQuery,
  NO_FILTER,
  shelve,
  withFacet,
  type StoreFacet,
  type StoreFacets,
  type StoreFilter,
} from '../store/storefront'

/**
 * The browser half of the store: extensions and the built-in page-reading tools,
 * with the line between them drawn on screen.
 *
 * ## The file is still called `StorePanel.tsx`, and that is deliberate
 *
 * There is no panel in it any more. The name is kept because three other lanes
 * were editing this file the week it changed, and renaming a file is the one
 * edit that turns every one of their diffs into a conflict for no gain. What a
 * reader needs is this paragraph, not a different filename.
 *
 * ## It was a dialog and it is a department
 *
 * This was a modal over the browser chrome — *"the browser has no page to put
 * one on"* — and that argument stopped applying when the store got a page of its
 * own. Asad: *"store must be like a proper store with full page not just
 * popup."* So the `<Modal>` is gone and what is left is a **section**, mounted
 * by `store/StorePage.tsx` beside the MCP department, with the search box and
 * the shelf rail owned by the page above it. Everything below that line — what a
 * row may claim, which rows get an Install, where the bytes come from — is
 * unchanged, and deliberately so: it was never about the surface it was drawn
 * on.
 *
 *   > *"i think we can have a tools store for extensions to this browser with
 *   > all open source best tools in the market so people can use the tool of
 *   > their choice in the browser, which tools will not be here only when they
 *   > download."*
 *
 * ## Why one panel, when they were two
 *
 * This app first built two doors: a Tools dialog holding six page-reading
 * recipes it wrote itself, every one bundled, and an Extensions dialog holding
 * the real open-source downloads. The split had an argument — a recipe is
 * selectors this app runs, an extension is a program somebody else wrote — but
 * what it produced was his ask inverted: the surface called the tools store
 * contained nothing that downloads, and the store of *"most famous open source
 * tools"* lived behind a different word. The store he described is one place.
 * This is that place, and the real distinction the split protected is kept as
 * the thing it always was — a fact about each row, said on the row and on the
 * section it sits in, not a wall between two dialogs.
 *
 * ## The line the sections draw
 *
 * **Downloaded when chosen.** The open-source extensions ship nowhere inside
 * this app. Each is fetched from its own project's release page when Install is
 * pressed, at a pinned byte count, against a sha256 pinned in this app's own
 * bytes — and the row shows the URL, the byte count and the fingerprint, before
 * and after. There is no fallback: a download that cannot be fetched and
 * verified is a refusal on the row, never a bundled copy pretending it arrived.
 *
 * **Built into this app.** The six page-reading tools are not downloads and do
 * not pretend to be: their section says they ship in the app's own bytes, and
 * their rows say installing one fetches nothing. They are still installed
 * rather than always-on, because *"not here only when they download"* is about
 * what exists for an agent to call — an uninstalled tool has no id anything can
 * name and no file on disk.
 *
 * **Cannot work in this browser.** A row this app measured failing keeps its
 * verdict and gets no Install. That honesty was hard-won — every verdict in the
 * catalogue was earned by running the release in this app's own Electron — and
 * a store that softened it to look fuller would be lying at exactly the moment
 * somebody is deciding what to trust.
 *
 * What such a row does get is **Get it**, which opens the project's own page and
 * installs nothing. *"or maybe only link of the application from github or
 * wherever they can go and download it, it will just redirect them and they can
 * install if not possible to bring button to install."* The refusal is kept and
 * the dead end is not, which is also what lets the catalogue hold everything
 * worth holding rather than only what this browser can run.
 *
 * ## Browsing: one bar, shared with the MCP store
 *
 * The search, the five filters and their counts are `store/StoreFilterBar.tsx`
 * over `store/storefront.ts`, and the MCP store draws the same component over
 * the same model. This panel had a search box and a row of category chips
 * written out here; the MCP store had neither. Copying the box across would have
 * been the last moment the two agreed — see `store/storefront.ts` for the whole
 * argument, and for the one rule every control obeys: an option that would leave
 * nothing on screen is not drawn at all.
 *
 * ## Why every failure lands on the row
 *
 * An install that refuses says which check refused it — the digest, the length,
 * the schema, a grant, the network — on the row, in a sentence. A store that
 * answered "couldn't install" would be asking somebody to guess between a
 * broken download and a tool that wanted more than it was allowed, and those
 * are opposite problems.
 *
 * ## Loading
 *
 * The two halves load independently and a failure in one is printed where that
 * half's rows would be. A dialog that opens and stays blank reads as a store
 * with nothing in it, which is a different and much more misleading thing than
 * a store that could not be read — so each half finishes loading either way and
 * says which one happened.
 */

interface Props {
  store: StoreApi
  extensions: ExtensionsApi
  /**
   * What the store page is searching and filtering for.
   *
   * Controlled from above rather than kept here, and that is the whole point of
   * there being a page: **one** search box searches the whole store, and this
   * department is handed whatever it produced with its own shelf applied. See
   * `store/store-nav.ts` for why the shelf cannot simply live in this value for
   * both departments at once.
   */
  filter: StoreFilter
  onFilter(next: StoreFilter): void
  /**
   * The one row being looked at on its own, or `''`.
   *
   * A row id, not a key: the page has already decided this department owns it.
   * When it is set, this draws that row and nothing else — see
   * {@link StoreDetail}, and note that the row itself is the *same component*
   * the shelves draw, so a detail view cannot end up saying less than the list
   * it came from. `StorePanel.test.tsx` pins that: the download URL and the
   * fingerprint are on the browsing screen, not hidden behind a click.
   */
  detail: string
  onDetail(key: string): void
  /**
   * What this department loaded, as the shared storefront model sees it.
   *
   * The page's rail counts every shelf across both departments, and it cannot
   * count what it has not read. Rather than hoist two catalogues' worth of
   * loading, network handling and per-row failure into the page — which would
   * make the page the thing that has to know about `.crx` signatures and
   * `npx` — each department reports the one projection they already both share.
   * `store/store-nav.ts` takes {@link StoreFacets} and nothing else, so the rail
   * has no idea which half of the store it is counting.
   */
  onRows(rows: StoreFacets[]): void
}

const EMPTY_TOOLS: StoreView = { tools: [], folder: '', orphans: [] }

const EMPTY_EXTENSIONS: ExtensionsView = {
  profileId: '',
  profileName: '',
  extensions: [],
  folder: '',
  orphans: [],
  profiles: [],
  limits: [],
}

export function BrowserStoreDepartment({
  store,
  extensions,
  filter,
  onFilter,
  detail,
  onDetail,
  onRows,
}: Props) {
  const toolsWired = storeAvailable(store)
  const extensionsWired = extensionsAvailable(extensions)

  const [tools, setTools] = useState<StoreView>(EMPTY_TOOLS)
  const [toolsProblem, setToolsProblem] = useState('')
  const [ext, setExt] = useState<ExtensionsView>(EMPTY_EXTENSIONS)
  const [extProblem, setExtProblem] = useState('')
  const [loaded, setLoaded] = useState(false)
  /**
   * Which profile the extension half is showing.
   *
   * `''` until the first list comes back, and then whatever that list says it
   * read. This used to be handed in by the browser, because the store only ever
   * opened from inside one; the page can be reached with no browser open at all,
   * so the answer has to come from the same place the rows do. `''` is not a
   * guess sent down the wire either — `browser-extension:list` answers an
   * unrecognisable id with the profile that is actually current, and says which
   * one that was, which is the value this then settles on.
   */
  const [showing, setShowing] = useState('')
  /** Prefixed row key → the sentence the last action on that row produced. */
  const [said, setSaid] = useState<Record<string, string>>({})
  /** The row with something in flight, so its button can say so. */
  const [busy, setBusy] = useState('')

  const loadTools = useCallback(async () => {
    if (!store.browserStore) return
    try {
      setTools(readStoreView(await store.browserStore()))
      setToolsProblem('')
    } catch (error) {
      setTools(EMPTY_TOOLS)
      setToolsProblem(error instanceof Error ? error.message : 'The list could not be read.')
    }
  }, [store])

  const loadExtensions = useCallback(async () => {
    if (!extensions.browserExtensions) return
    try {
      const view = readExtensionsView(await extensions.browserExtensions(showing))
      setExt(view)
      // The profile this page is talking about, settled off the answer rather
      // than assumed — see `showing` above. Only ever from `''`: once somebody
      // has chosen a profile in the picker, a reload must not drag them back to
      // whichever one the browser happens to be on.
      setShowing((was) => (was === '' ? view.profileId : was))
      setExtProblem('')
    } catch (error) {
      setExt(EMPTY_EXTENSIONS)
      setExtProblem(error instanceof Error ? error.message : 'The list could not be read.')
    }
  }, [extensions, showing])

  useEffect(() => {
    void Promise.all([loadTools(), loadExtensions()]).then(() => setLoaded(true))
  }, [loadTools, loadExtensions])

  /*
   * Tell the page what is on the shelves, whenever that changes.
   *
   * Keyed on the two loaded views rather than on a derived array, so this fires
   * once per read and not once per render — a fresh array in the dependency list
   * would be a new value every time and the page would re-render this component
   * for ever.
   */
  useEffect(() => {
    onRows([...ext.extensions.map(extensionFacets), ...tools.tools.map(builtInFacets)])
  }, [ext, tools, onRows])

  const actTool = useCallback(
    async (id: string, verb: 'install' | 'remove') => {
      const call = verb === 'install' ? store.browserStoreInstall : store.browserStoreRemove
      if (!call) return
      setBusy(`t:${id}`)
      try {
        const result = readStoreResult(await call(id))
        setSaid((was) => ({ ...was, [`t:${id}`]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [`t:${id}`]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        // Re-read whatever happened, so the row's state comes off the disk
        // rather than off an assumption about what the call did.
        await loadTools()
      }
    },
    [store, loadTools],
  )

  const actExtension = useCallback(
    async (id: string, verb: 'install' | 'remove') => {
      const call =
        verb === 'install' ? extensions.browserExtensionInstall : extensions.browserExtensionRemove
      if (!call) return
      setBusy(`e:${id}`)
      try {
        const result = readExtensionResult(await call(showing, id))
        setSaid((was) => ({ ...was, [`e:${id}`]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [`e:${id}`]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        // Off the disk and the live session, not off an assumption.
        await loadExtensions()
      }
    },
    [extensions, showing, loadExtensions],
  )

  const setEnabled = useCallback(
    async (id: string, on: boolean) => {
      if (!extensions.browserExtensionEnable) return
      setBusy(`e:${id}`)
      try {
        const result = readExtensionResult(await extensions.browserExtensionEnable(showing, id, on))
        setSaid((was) => ({ ...was, [`e:${id}`]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [`e:${id}`]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        await loadExtensions()
      }
    },
    [extensions, showing, loadExtensions],
  )

  const openPopup = useCallback(
    async (id: string) => {
      if (!extensions.browserExtensionPopup) return
      try {
        const result = readExtensionResult(await extensions.browserExtensionPopup(showing, id))
        if (!result.ok) setSaid((was) => ({ ...was, [`e:${id}`]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [`e:${id}`]: error instanceof Error ? error.message : 'Its panel did not open.',
        }))
      }
    },
    [extensions, showing],
  )

  const openOptions = useCallback(
    async (id: string) => {
      if (!extensions.browserExtensionOptions) return
      try {
        const result = readExtensionResult(await extensions.browserExtensionOptions(showing, id))
        if (!result.ok) setSaid((was) => ({ ...was, [`e:${id}`]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [`e:${id}`]: error instanceof Error ? error.message : 'Its settings did not open.',
        }))
      }
    },
    [extensions, showing],
  )

  /**
   * Add a folder or a `.crx`.
   *
   * The path never travels through here. This calls the channel, the main
   * process opens the dialog, and what comes back is a sentence — so a renderer
   * cannot name a directory nobody chose. A cancelled dialog answers ok with an
   * empty message and nothing is printed, because changing your mind is not a
   * failure and must not be drawn as one.
   */
  const addOwn = useCallback(
    async (kind: 'folder' | 'crx') => {
      const call =
        kind === 'folder' ? extensions.browserExtensionAddFolder : extensions.browserExtensionAddCrx
      if (!call) return
      setBusy(`own:${kind}`)
      try {
        const result = readExtensionResult(await call(showing))
        setSaid((was) => ({ ...was, own: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          own: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        await loadExtensions()
      }
    },
    [extensions, showing, loadExtensions],
  )

  if (!loaded) return null

  /*
   * One row, on its own, when the page has been sent to one.
   *
   * Resolved out of the same two views the shelves are drawn from, so a detail
   * view cannot outlive the row it names: an extension removed from the
   * catalogue by an update, or a tool that was uninstalled in another window,
   * finds nothing here and the page falls back to the shelves rather than
   * drawing a frame around an empty space.
   */
  const openExtension = ext.extensions.find((one) => `e:${one.id}` === detail)
  const openTool = tools.tools.find((one) => `t:${one.id}` === detail)
  if (openExtension) {
    return (
      <StoreDetail
        backTo={CATEGORY_NAMES[openExtension.category] ?? 'the store'}
        onBack={() => onDetail('')}
      >
        <ul className="bw-store-list">
          <ExtensionRow
            extension={openExtension}
            busy={busy === `e:${openExtension.id}`}
            said={said[`e:${openExtension.id}`] ?? ''}
            canOpenPopup={typeof extensions.browserExtensionPopup === 'function'}
            canOpenOptions={typeof extensions.browserExtensionOptions === 'function'}
            onAct={(verb) => void actExtension(openExtension.id, verb)}
            onEnable={(on) => void setEnabled(openExtension.id, on)}
            onOpenPopup={() => void openPopup(openExtension.id)}
            onOpenOptions={() => void openOptions(openExtension.id)}
          />
        </ul>
      </StoreDetail>
    )
  }
  if (openTool) {
    return (
      <StoreDetail
        backTo="Built into this app"
        onBack={() => onDetail('')}
      >
        <ul className="bw-store-list">
          <ToolRow
            tool={openTool}
            busy={busy === `t:${openTool.id}`}
            said={said[`t:${openTool.id}`] ?? ''}
            onAct={(verb) => void actTool(openTool.id, verb)}
          />
        </ul>
      </StoreDetail>
    )
  }

  return (
    <StoreBody
      toolsWired={toolsWired}
      extensionsWired={extensionsWired}
      tools={tools}
      toolsProblem={toolsProblem}
      ext={ext}
      extProblem={extProblem}
      showing={showing}
      busy={busy}
      said={said}
      canOpenPopup={typeof extensions.browserExtensionPopup === 'function'}
      canOpenOptions={typeof extensions.browserExtensionOptions === 'function'}
      canAddFolder={typeof extensions.browserExtensionAddFolder === 'function'}
      canAddCrx={typeof extensions.browserExtensionAddCrx === 'function'}
      filter={filter}
      onShowProfile={setShowing}
      onFilter={onFilter}
      onOpenRow={onDetail}
      onTool={(id, verb) => void actTool(id, verb)}
      onExtension={(id, verb) => void actExtension(id, verb)}
      onEnable={(id, on) => void setEnabled(id, on)}
      onOpenPopup={(id) => void openPopup(id)}
      onOpenOptions={(id) => void openOptions(id)}
      onAddOwn={(kind) => void addOwn(kind)}
    />
  )
}

/* ------------------------------------------------------------ the shelves -- */

/**
 * The shelf the six built-in page-reading tools sit on.
 *
 * They were a *section* and never a shelf — the store's model has always seen
 * extensions and nothing else, so `Built into this app` was drawn below whatever
 * the filter left and was not affected by it. In a dialog that was merely
 * untidy. On a page with one search box across the whole store it is a lie:
 * typing `postgres` would print *"Nothing in the store matches that"* directly
 * above six rows that were still sitting there.
 *
 * So it is a shelf now, in the rail, with a count like every other. The id is
 * deliberately not one of `ExtensionCategory` — nothing can install an extension
 * onto it by accident, and an extension row can never match it.
 */
export const BUILT_IN_SHELF = 'built-in'

/**
 * A built-in tool, as the storefront model sees it.
 *
 * Only what is true of a thing that ships in the app's own bytes. `compat` is
 * `works` because this app wrote it and runs it in its own engine — that is a
 * measurement, not a hope — and `source` is its own word so it can never be
 * confused with a release somebody else published.
 */
export function builtInFacets(tool: StoreTool): StoreFacets {
  return {
    id: tool.id,
    name: tool.name,
    summary: tool.summary,
    // It ships in this app's own bytes, so there is nothing to pay and nothing
    // to sign up for — the one cost answer that is a measurement, not a claim.
    cost: 'free',
    category: BUILT_IN_SHELF,
    categoryName: BUILT_IN_NAME,
    tags: [],
    compat: 'works',
    installed: tool.state === 'installed',
    source: BUILT_IN_SHELF,
    needs: [],
  }
}

export const BUILT_IN_NAME = 'Built into this app'

/**
 * Every shelf this department has, in the order it draws them — the extension
 * shelves, then the built-ins.
 *
 * Exported for the page's rail, so the rail and the sections cannot come to two
 * different lists. `store/store-nav.ts` drops any of them that is empty.
 */
export const BROWSER_SHELVES: readonly { id: string; name: string }[] = [
  ...CATEGORY_ORDER.map((id) => ({ id, name: CATEGORY_NAMES[id] })),
  { id: BUILT_IN_SHELF, name: BUILT_IN_NAME },
]

/* ----------------------------------------------------------------- detail -- */



/* ------------------------------------------------------------------- body -- */

export interface StoreBodyProps {
  /** Whether the preload carries each half. An absent half draws nothing —
      absent rather than disabled, the standing rule for the whole menu. */
  toolsWired: boolean
  extensionsWired: boolean
  tools: StoreView
  /** Why the built-in half could not be read, or `''`. */
  toolsProblem: string
  ext: ExtensionsView
  /** Why the download half could not be read, or `''`. */
  extProblem: string
  showing: string
  busy: string
  said: Record<string, string>
  canOpenPopup: boolean
  canOpenOptions: boolean
  /** Whether this build's preload carries each Add-your-own door. */
  canAddFolder: boolean
  canAddCrx: boolean
  filter: StoreFilter
  onShowProfile(id: string): void
  onFilter(next: StoreFilter): void
  /**
   * Open one row on its own — the key, prefixed the way `busy` and `said` are.
   *
   * Optional, and the rows draw no way in without it. That is the standing
   * absent-not-disabled rule doing real work here rather than ceremony: this
   * body is also what `StorePanel.test.tsx` renders on its own, and a name that
   * looked pressable in a test fixture with nowhere to go would be exactly the
   * dead control the whole surface is written against.
   */
  onOpenRow?(key: string): void
  onTool(id: string, verb: 'install' | 'remove'): void
  onExtension(id: string, verb: 'install' | 'remove'): void
  onEnable(id: string, on: boolean): void
  onOpenPopup(id: string): void
  onOpenOptions(id: string): void
  onAddOwn(kind: 'folder' | 'crx'): void
}

/**
 * Everything under the title, as a pure function of the two loaded views.
 *
 * Split from {@link StorePanel} so the store's one screen can be rendered and
 * read by a test: the panel above it loads through effects, which SSR never
 * runs, so a test that rendered the panel would be asserting on an empty shell
 * — the exact "proof by a function nothing calls" this store was audited for.
 */
export function StoreBody({
  toolsWired,
  extensionsWired,
  tools,
  toolsProblem,
  ext,
  extProblem,
  showing,
  busy,
  said,
  canOpenPopup,
  canOpenOptions,
  canAddFolder,
  canAddCrx,
  filter,
  onShowProfile,
  onFilter,
  onOpenRow,
  onTool,
  onExtension,
  onEnable,
  onOpenPopup,
  onOpenOptions,
  onAddOwn,
}: StoreBodyProps) {
  /*
   * The whole catalogue, as the shared storefront sees it, computed once.
   *
   * Once because it feeds three things — the filter chips' counts, the Installed
   * section and the shelves below it — and three call sites deriving the same
   * projection is three chances for one of them to drift.
   */
  const facets = new Map(ext.extensions.map((one) => [one.id, extensionFacets(one)]))
  const facetsOf = (one: StoreExtension) => facets.get(one.id) ?? extensionFacets(one)
  const kept = ext.extensions.filter((one) => matchesFilter(facetsOf(one), filter))

  const installed = kept.filter((one) => one.state === 'installed' || one.state === 'damaged')

  const extensionRow = (extension: StoreExtension) => (
    <ExtensionRow
      key={extension.id}
      extension={extension}
      busy={busy === `e:${extension.id}`}
      said={said[`e:${extension.id}`] ?? ''}
      canOpenPopup={canOpenPopup}
      canOpenOptions={canOpenOptions}
      onOpen={onOpenRow === undefined ? undefined : () => onOpenRow(`e:${extension.id}`)}
      onAct={(verb) => onExtension(extension.id, verb)}
      onEnable={(on) => onEnable(extension.id, on)}
      onOpenPopup={() => onOpenPopup(extension.id)}
      onOpenOptions={() => onOpenOptions(extension.id)}
    />
  )

  /*
   * Everything that is not already installed, in shelf order.
   *
   * Within a shelf: what can be installed, then what was measured failing, then
   * what nothing was measured on. That order is the store being honest about
   * itself twice over — the useful rows come first, and the two kinds of row
   * with no Install stay apart rather than being swept into one bin at the
   * bottom that reads as *the broken ones*. Neither kind is a dead end any more:
   * both carry a Get it that opens the project's own page.
   */
  const rank: Record<string, number> = {
    available: 0,
    installed: 0,
    damaged: 0,
    unavailable: 1,
    'not-offered': 2,
  }
  const browsing = kept.filter((one) => one.state !== 'installed' && one.state !== 'damaged')
  const shelves = shelve(
    browsing,
    CATEGORY_ORDER.map((id) => ({ id, name: CATEGORY_NAMES[id] })),
    facetsOf,
    (one) => rank[one.state] ?? 0,
  )
  /*
   * Every facet except the shelf.
   *
   * The shelves are the store page's left rail now — with a count on every one,
   * across both departments — and a second row of chips saying the same thing
   * under this heading would be two controls for one choice, which is the
   * duplication this app keeps having to undo. `category` is still a *filter*:
   * the rail sets it, `matchesFilter` applies it, and every count below
   * cross-filters against it exactly as before. Only the chips are gone.
   */
  const controls = facetControls([...facets.values()], filter, withoutShelf(EXTENSION_FACETS))
  const isFiltering = anyFilter(filter)

  /*
   * The built-ins, searched like everything else and on their own shelf.
   *
   * This list used to ignore the filter entirely, because the storefront model
   * only ever saw extensions. In a dialog that was untidy; under one search box
   * spanning the whole store it is a lie — typing `postgres` printed *"Nothing
   * in the store matches that"* directly above six rows still sitting there.
   *
   * They answer to the **search** and to the **shelf**, and not to the chips.
   * That is deliberate rather than half a job: the chips are counted over the
   * extension catalogue — *Where it comes from*, *In this browser* — and their
   * vocabulary has no word that is true of a thing that ships in the app's own
   * bytes. Giving them one would mean inventing a measurement. Search and shelf
   * are the two controls whose meaning is the same for both kinds of row, so
   * they are the two that apply.
   *
   * Installed first, so "do I have this" is answered by order as well as by the
   * chip on the row.
   */
  const builtIn = tools.tools
    .filter(
      (tool) =>
        (filter.category === ANY || filter.category === BUILT_IN_SHELF) &&
        matchesQuery(builtInFacets(tool), filter.query),
    )
    .sort((a, b) => Number(b.state !== 'available') - Number(a.state !== 'available'))

  return (
    <>
      {extensionsWired && extProblem !== '' && <p className="bw-error">{extProblem}</p>}
      {extensionsWired && extProblem === '' && (
        <>
          {/*
            Said once, before the first row, because these change how the whole
            list should be read rather than qualifying any part of it.
          */}
          <details className="bw-store-section bw-store-limits">
            {/*
              A `details` and not a paragraph wall, and not React state either:
              nine measured sentences ahead of the first row turn a store into a
              disclaimer, and a `summary` that says how many there are and that
              every one was measured is a truer invitation than showing them all
              and having them scrolled past. It renders open or shut without a
              single line of JavaScript, which is why it works in a test that has
              no DOM.
            */}
            <summary className="bw-store-note">
              What an extension can and cannot do in this browser — {ext.limits.length} things,
              every one of them measured by running something here.
            </summary>
            {ext.limits.map((line) => (
              <p key={line} className="bw-store-note">
                {line}
              </p>
            ))}
          </details>

          {ext.profiles.length > 1 && (
            <label className="bw-store-note bw-ext-profile" htmlFor="bw-ext-profile">
              Extensions are installed into one profile and read every page in it. Showing{' '}
              <select
                id="bw-ext-profile"
                value={showing}
                onChange={(event) => onShowProfile(event.target.value)}
              >
                {ext.profiles.map((profile) => (
                  <option key={profile.id} value={profile.id}>
                    {profile.name}
                  </option>
                ))}
              </select>
            </label>
          )}

          {/*
            The browsing controls. A catalogue this size stopped being a list
            somebody reads top to bottom, and a store that cannot be searched is
            a list with a nicer name.

            The bar itself is `store/StoreFilterBar.tsx`, shared with the MCP
            store, and every count and every "is this chip worth drawing" answer
            in it comes from `store/storefront.ts`. This used to be a search box
            and one row of category chips written out here; the MCP store had
            neither, and the cheap fix — copy the box across — would have been
            the last moment the two agreed with each other.
          */}
          <section className="bw-store-section bw-store-browse">
            <StoreFilterBar
              idPrefix="bw-ext"
              /* The page carries the one search box, over both departments —
                 see `store/StorePage.tsx`. A second box under this heading
                 would search half a store while looking like it searched all
                 of it. */
              search={false}
              filter={filter}
              controls={controls}
              showing={kept.length}
              total={ext.extensions.length}
              active={isFiltering}
              onQuery={(next) => onFilter({ ...filter, query: next })}
              onFacet={(facet: StoreFacet, value) => onFilter(withFacet(filter, facet, value))}
              onClear={() => onFilter(NO_FILTER)}
            />
          </section>

          {installed.length > 0 && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">
                Installed in {ext.profileName || 'this profile'}
              </h3>
              <ul className="bw-store-list">{installed.map(extensionRow)}</ul>
            </section>
          )}

          {/*
            The three things every shelf below mixes, said once rather than
            under each heading. A row's button is the row's own fact and the
            reason for it differs by row — so the sentence points at the row
            rather than trying to say it for all of them.

            Directly above the first shelf rather than up with the controls,
            because it is about the rows and the controls are about the whole
            screen.
          */}
          {shelves.length > 0 && (
            <p className="bw-store-note">
              Nothing here ships inside this app. Install fetches it from the address on its row
              and checks it against the fingerprint beside it before a byte is saved. Some rows
              have no Install: either this app ran them here and watched them fail, or their
              project publishes nothing this app could fetch and fingerprint. Those rows carry
              <strong> Get it</strong> instead, which opens the project&rsquo;s own page — nothing
              is installed by pressing it, and each row still says which of the two it is.
            </p>
          )}

          {/*
            Three different true sentences, and the middle one had to be added
            after rendering this and looking at it. Filtering to a shelf whose
            only row is installed drew *"Nothing in the store matches that"* over
            a row that plainly matched and was sitting a few pixels above, under
            Installed. What is empty in that case is the browsing area, not the
            store — and those are not the same claim.
          */}
          {shelves.length === 0 ? (
            <p className="bw-muted">
              {kept.length === 0
                ? isFiltering
                  ? 'Nothing in the store matches that.'
                  : 'There is nothing in the store to browse.'
                : isFiltering
                  ? 'Everything that matches is already installed in this profile — it is above.'
                  : 'Everything this app can install is already installed in this profile.'}
            </p>
          ) : (
            shelves.map((shelf) => (
              <section key={shelf.id} className="bw-store-section">
                <h3 className="bw-store-heading">{shelf.name}</h3>
                <ul className="bw-store-list">{shelf.rows.map(extensionRow)}</ul>
              </section>
            ))
          )}

          {/*
            Add your own. Two doors, drawn only when the preload has them —
            absent rather than disabled, which is the standing rule for this
            whole menu.
          */}
          {(canAddFolder || canAddCrx) && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">Add your own</h3>
              <p className="bw-store-note">
                An extension you have on this machine — one you are writing, or one you got
                somewhere this app does not know about. It is copied into{' '}
                {ext.profileName || 'this profile'} and switched on. Nothing about it was measured
                here, no fingerprint is checked against it, and its row says exactly that instead
                of borrowing the confidence of the rows above.
              </p>
              <div className="bw-store-own">
                {canAddFolder && (
                  <button
                    type="button"
                    className="bw-store-install"
                    disabled={busy === 'own:folder'}
                    onClick={() => onAddOwn('folder')}
                  >
                    {busy === 'own:folder' ? 'Working…' : 'Add a folder…'}
                  </button>
                )}
                {canAddCrx && (
                  <button
                    type="button"
                    className="bw-text-button"
                    disabled={busy === 'own:crx'}
                    onClick={() => onAddOwn('crx')}
                  >
                    {busy === 'own:crx' ? 'Working…' : 'Add a .crx…'}
                  </button>
                )}
              </div>
              <p className="bw-store-note">
                A folder is the one with the manifest.json in it. A .crx is opened here rather
                than handed to the browser, and its own signature is checked first — which proves
                the file has not changed since it was packed and proves nothing about who packed
                it, because a .crx carries its own key.
              </p>
              {(said.own ?? '') !== '' && <p className="bw-store-said">{said.own}</p>}
            </section>
          )}
        </>
      )}

      {toolsWired && toolsProblem !== '' && <p className="bw-error">{toolsProblem}</p>}
      {/* The heading goes with its rows. A section title over nothing is the
          empty-section rule, and with a search across the whole store it now
          genuinely happens. */}
      {toolsWired && toolsProblem === '' && builtIn.length > 0 && (
        <section className="bw-store-section">
          <h3 className="bw-store-heading">{BUILT_IN_NAME}</h3>
          {/*
            The other side of the same seam. These six are this app's own work
            and no download will be pretended for them: the honest words for a
            thing that ships in the app's bytes are these, not a progress bar.
          */}
          <p className="bw-store-note">
            These are not downloads — each is a set of selectors that ships inside this app and
            runs in its own page-reading engine. Nothing installed from here is ever executed.
            Installing one switches it on for this browser&rsquo;s extract verb and
            fetches nothing; Remove deletes its file.
          </p>
          <ul className="bw-store-list">
            {builtIn.map((tool) => (
              <ToolRow
                key={tool.id}
                tool={tool}
                busy={busy === `t:${tool.id}`}
                said={said[`t:${tool.id}`] ?? ''}
                onOpen={onOpenRow === undefined ? undefined : () => onOpenRow(`t:${tool.id}`)}
                onAct={(verb) => onTool(tool.id, verb)}
              />
            ))}
          </ul>
        </section>
      )}

      {/*
        Folders this build has no row for — a tool or an extension withdrawn
        between releases. Offered rather than hidden: a file this app wrote and
        can no longer name is a file nobody has any way to delete.
      */}
      {(ext.orphans.length > 0 || tools.orphans.length > 0) && (
        <section className="bw-store-section">
          <h3 className="bw-store-heading">No longer offered</h3>
          <ul className="bw-store-list">
            {ext.orphans.map((id) => (
              <li key={`e:${id}`} className="bw-store-row">
                <div className="bw-store-head">
                  <span className="bw-store-name">{id}</span>
                  <span className="bw-grow" />
                  <button
                    type="button"
                    className="bw-text-button"
                    disabled={busy === `e:${id}`}
                    onClick={() => onExtension(id, 'remove')}
                  >
                    {busy === `e:${id}` ? 'Working…' : 'Remove'}
                  </button>
                </div>
                <p className="bw-store-summary">
                  This version of the app no longer offers this extension, so it is not loaded.
                  Its files are still on disk.
                </p>
                {(said[`e:${id}`] ?? '') !== '' && (
                  <p className="bw-store-said">{said[`e:${id}`]}</p>
                )}
              </li>
            ))}
            {tools.orphans.map((id) => (
              <li key={`t:${id}`} className="bw-store-row">
                <div className="bw-store-head">
                  <span className="bw-store-name">{id}</span>
                  <span className="bw-grow" />
                  <button
                    type="button"
                    className="bw-text-button"
                    disabled={busy === `t:${id}`}
                    onClick={() => onTool(id, 'remove')}
                  >
                    {busy === `t:${id}` ? 'Working…' : 'Remove'}
                  </button>
                </div>
                <p className="bw-store-summary">
                  This version of the app no longer offers this tool, so it cannot be run. Its
                  file is still on disk.
                </p>
                {(said[`t:${id}`] ?? '') !== '' && (
                  <p className="bw-store-said">{said[`t:${id}`]}</p>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Where the files are, because Remove says they are deleted and a person
          is entitled to go and look. */}
      {extensionsWired && extProblem === '' && ext.folder !== '' && (
        <p className="bw-store-note">
          This profile&rsquo;s extensions are kept in <code>{ext.folder}</code>.
        </p>
      )}
      {toolsWired && toolsProblem === '' && tools.folder !== '' && (
        <p className="bw-store-note">
          Installed built-in tools are kept in <code>{tools.folder}</code>.
        </p>
      )}
    </>
  )
}
