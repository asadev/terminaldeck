import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import {
  readStoreResult,
  readStoreView,
  storeAvailable,
  type StoreApi,
  type StoreView,
} from './store-bridge'
import {
  CATEGORY_NAMES,
  CATEGORY_ORDER,
  extensionsAvailable,
  matchesSearch,
  readExtensionResult,
  readExtensionsView,
  type ExtensionCategory,
  type ExtensionsApi,
  type ExtensionsView,
  type StoreExtension,
} from './extensions-bridge'
import { ToolRow } from './ToolRow'
import { ExtensionRow } from './ExtensionRow'

/**
 * The tools store. One door, one dialog, both kinds of thing — with the line
 * between them drawn on screen.
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
 * verdict and gets no button. That honesty was hard-won — every verdict in the
 * catalogue was earned by running the release in this app's own Electron — and
 * a store that softened it to look fuller would be lying at exactly the moment
 * somebody is deciding what to trust.
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
  open: boolean
  store: StoreApi
  extensions: ExtensionsApi
  /** The profile the browser is on, so the extension half opens on the right one. */
  profileId: string
  onClose(): void
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

export function StorePanel({ open, store, extensions, profileId, onClose }: Props) {
  const toolsWired = storeAvailable(store)
  const extensionsWired = extensionsAvailable(extensions)

  const [tools, setTools] = useState<StoreView>(EMPTY_TOOLS)
  const [toolsProblem, setToolsProblem] = useState('')
  const [ext, setExt] = useState<ExtensionsView>(EMPTY_EXTENSIONS)
  const [extProblem, setExtProblem] = useState('')
  const [loaded, setLoaded] = useState(false)
  /** Which profile the extension half is showing. Starts at the browser's own. */
  const [showing, setShowing] = useState(profileId)
  /** Prefixed row key → the sentence the last action on that row produced. */
  const [said, setSaid] = useState<Record<string, string>>({})
  /** The row with something in flight, so its button can say so. */
  const [busy, setBusy] = useState('')
  /** What has been typed into the search box. */
  const [query, setQuery] = useState('')
  /** Which shelf is being looked at, or `'all'`. */
  const [category, setCategory] = useState<ExtensionCategory | 'all'>('all')

  useEffect(() => {
    if (open) setShowing(profileId)
  }, [open, profileId])

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
      setExt(readExtensionsView(await extensions.browserExtensions(showing)))
      setExtProblem('')
    } catch (error) {
      setExt(EMPTY_EXTENSIONS)
      setExtProblem(error instanceof Error ? error.message : 'The list could not be read.')
    }
  }, [extensions, showing])

  useEffect(() => {
    if (!open) return
    void Promise.all([loadTools(), loadExtensions()]).then(() => setLoaded(true))
  }, [open, loadTools, loadExtensions])

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

  return (
    <Modal open={open} title="Tools store" onClose={onClose} size="lg">
      {!loaded ? null : (
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
          query={query}
          category={category}
          onShowProfile={setShowing}
          onQuery={setQuery}
          onCategory={setCategory}
          onTool={(id, verb) => void actTool(id, verb)}
          onExtension={(id, verb) => void actExtension(id, verb)}
          onEnable={(id, on) => void setEnabled(id, on)}
          onOpenPopup={(id) => void openPopup(id)}
          onOpenOptions={(id) => void openOptions(id)}
          onAddOwn={(kind) => void addOwn(kind)}
        />
      )}
    </Modal>
  )
}

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
  query: string
  category: ExtensionCategory | 'all'
  onShowProfile(id: string): void
  onQuery(next: string): void
  onCategory(next: ExtensionCategory | 'all'): void
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
  query,
  category,
  onShowProfile,
  onQuery,
  onCategory,
  onTool,
  onExtension,
  onEnable,
  onOpenPopup,
  onOpenOptions,
  onAddOwn,
}: StoreBodyProps) {
  const installed = ext.extensions.filter(
    (one) => one.state === 'installed' || one.state === 'damaged',
  )

  const extensionRow = (extension: StoreExtension) => (
    <ExtensionRow
      key={extension.id}
      extension={extension}
      busy={busy === `e:${extension.id}`}
      said={said[`e:${extension.id}`] ?? ''}
      canOpenPopup={canOpenPopup}
      canOpenOptions={canOpenOptions}
      onAct={(verb) => onExtension(extension.id, verb)}
      onEnable={(on) => onEnable(extension.id, on)}
      onOpenPopup={() => onOpenPopup(extension.id)}
      onOpenOptions={() => onOpenOptions(extension.id)}
    />
  )

  /*
   * Everything that is not already installed, in shelf order, filtered by
   * whatever is typed and whichever shelf is chosen.
   *
   * Within a shelf: what can be installed, then what was measured failing, then
   * what nothing was measured on. That order is the store being honest about
   * itself twice over — the useful rows come first, and the two kinds of
   * buttonless row stay apart rather than being swept into one bin at the
   * bottom that reads as *the broken ones*.
   */
  const rank: Record<string, number> = {
    available: 0,
    installed: 0,
    damaged: 0,
    unavailable: 1,
    'not-offered': 2,
  }
  const browsing = ext.extensions
    .filter((one) => one.state !== 'installed' && one.state !== 'damaged')
    .filter((one) => category === 'all' || one.category === category)
    .filter((one) => matchesSearch(one, query))
  const shelves = CATEGORY_ORDER.map((id) => ({
    id,
    name: CATEGORY_NAMES[id],
    rows: browsing
      .filter((one) => one.category === id)
      .sort((a, b) => (rank[a.state] ?? 0) - (rank[b.state] ?? 0)),
  })).filter((shelf) => shelf.rows.length > 0)
  const filtering = query.trim() !== '' || category !== 'all'

  /* Installed first, so "do I have this" is answered by order as well as by
     the chip on the row — the built-in half is one list, not two sections. */
  const builtIn = [...tools.tools].sort(
    (a, b) => Number(b.state !== 'available') - Number(a.state !== 'available'),
  )

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

          {installed.length > 0 && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">
                Installed in {ext.profileName || 'this profile'}
              </h3>
              <ul className="bw-store-list">{installed.map(extensionRow)}</ul>
            </section>
          )}

          {/*
            The browsing controls. A catalogue this size stopped being a list
            somebody reads top to bottom, and a store that cannot be searched is
            a list with a nicer name.
          */}
          <section className="bw-store-section bw-store-browse">
            <label className="bw-store-search" htmlFor="bw-ext-search">
              <span className="bw-store-note">Search</span>
              <input
                id="bw-ext-search"
                type="search"
                value={query}
                placeholder="blocker, dark, password…"
                onChange={(event) => onQuery(event.target.value)}
              />
            </label>
            <div className="bw-store-chips">
              <button
                type="button"
                className={category === 'all' ? 'bw-chip bw-chip-on' : 'bw-chip'}
                aria-pressed={category === 'all'}
                onClick={() => onCategory('all')}
              >
                Everything
              </button>
              {/*
                Only the shelves that have something on them to browse. Built
                from what is *browsable* rather than from the whole catalogue,
                because everything installed is drawn above this and a chip that
                filtered down to "nothing matches that" would be a control that
                does nothing — which is the thing this app keeps being about.
              */}
              {CATEGORY_ORDER.filter((id) =>
                ext.extensions.some(
                  (one) =>
                    one.category === id &&
                    one.state !== 'installed' &&
                    one.state !== 'damaged',
                ),
              ).map((id) => (
                <button
                  key={id}
                  type="button"
                  className={category === id ? 'bw-chip bw-chip-on' : 'bw-chip'}
                  aria-pressed={category === id}
                  onClick={() => onCategory(id)}
                >
                  {CATEGORY_NAMES[id]}
                </button>
              ))}
            </div>
            {/*
              The two things every shelf below mixes, said once rather than under
              each heading. A row with no Install is not an oversight and the
              reason it has none differs by row — so the sentence points at the
              row rather than trying to say it for all of them.
            */}
            <p className="bw-store-note">
              Nothing here ships inside this app. Install fetches it from the address on its row
              and checks it against the fingerprint beside it before a byte is saved. Some rows
              have no Install at all: either this app ran them here and watched them fail, or
              their project publishes nothing this app could fetch and fingerprint. Each of those
              rows says which.
            </p>
          </section>

          {shelves.length === 0 ? (
            <p className="bw-muted">
              {filtering
                ? 'Nothing in the store matches that.'
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
      {toolsWired && toolsProblem === '' && (
        <section className="bw-store-section">
          <h3 className="bw-store-heading">Built into this app</h3>
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
