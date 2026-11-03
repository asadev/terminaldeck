/**
 * The store, on the phone — the storefront, and not the preferences file.
 *
 * ## The bug this replaces, and what it actually was
 *
 * Asad, on the Store tab of his phone, pointed at his own headless server:
 * **"This machine could not answer that panel."** That sentence is the `catch`
 * at the bottom of `panelFor` in `remote/server.ts`, and the whole of what it
 * was swallowing is one line:
 *
 *     const state = store().read()
 *
 * `store()` answers a `Store`, and `Store` has no `read`. Its accessor is
 * `getState()`. So the first statement of the branch threw
 * `TypeError: store(...).read is not a function`, every time, on **every** host
 * — a desktop with a window as surely as a daemon on a server — and the catch
 * turned a missing method into a sentence about the machine.
 *
 * It is worth being exact about why, because the reflex diagnosis is wrong and
 * would have sent the fix somewhere useless. This was **not** Electron.
 * `platform/paths.ts` already moved `app.getPath('userData')` behind
 * `installPaths`, `src/headless/daemon.ts` installs `nodePaths()` at the top of
 * `main()`, and `Store.load` reads a missing or corrupt `state.json` into
 * `DEFAULTS` rather than throwing. A headless host has a store and it opens
 * fine. What no host has ever had is a `read` method.
 *
 * It survived because the typecheck that would have named it is not the one
 * anybody reaches for. `npx tsc --noEmit` in the repository root checks
 * *nothing*: the root `tsconfig.json` is `files: []` plus two project
 * references, so it exits 0 with no output on a tree that does not compile. The
 * config that holds the sources says it outright:
 *
 *     src/main/remote/server.ts: error TS2339:
 *       Property 'read' does not exist on type 'Store'.
 *
 * `npm run typecheck` is `tsc --noEmit -p tsconfig.node.json && … -p
 * tsconfig.web.json`, and that is the pair that answers.
 *
 * ## It was also the wrong subject entirely
 *
 * What the branch reported, had it run, was the desktop's *preferences*:
 * default coding tool, theme, restore-sessions, a count of open projects. None
 * of that is what this product calls a Store. The Store is the storefront —
 * `renderer/store/StorePage.tsx`, reached from the rail, two departments and
 * sixteen shelves between them — and it is the thing Asad has actually been
 * describing:
 *
 *   > *"store must be like a proper store with full page not just popup, and
 *   > should allow custom tools and store, and maybe some other tools paid ones
 *   > too not just open source"*
 *
 *   > *"these pages are not just to view the information — exactly all actions
 *   > that we have in desktop application, they should be inside each option of
 *   > them."*
 *
 * So this serves the catalogue, in the desktop's own department order — the
 * browser tools this app installs into its own engine, then the MCP servers it
 * writes into your agent's configuration — and it installs and removes from
 * both.
 *
 * ## Everything arrives injected, and that is the fix as much as the rewrite is
 *
 * Nothing below reaches for a module that knows where it is running.
 * {@link StorePanelDeps} is six functions; `server.ts` builds them out of
 * `mcp-store.ts` and `browser-store.ts`, each of which is already plain Node
 * with no Electron in it. An absent function is not an error and is never drawn
 * as a button — it is a sentence in `note`, because *"nothing to show"* and
 * *"cannot be shown from here"* are different facts and only one of them is
 * worth a person's time.
 *
 * A dependency that **throws** is caught at its own department's boundary and
 * becomes a sentence in `note` too. That is deliberately not left to the catch
 * in `server.ts`: that catch is what produced the screen this file exists to
 * fix, and a panel that relies on it can only ever say the one useless thing it
 * says. `store.test.ts` pins this behaviour by name.
 *
 * ## What the search box is
 *
 * `renderer/store/storefront.ts` — a module with no imports of its own, written
 * to be *"the one storefront model, shared by both stores"* so that the two
 * halves cannot drift into two ideas of what a partial word is. Reimplementing
 * `matchesQuery` over here so that `src/main` need not name a file under
 * `src/renderer` would produce exactly that drift: `sequentialthinking` finding
 * the row on the desktop and nothing on the phone. So the search is that
 * function, over the same {@link StoreFacets} projection both departments
 * already build, and the shelf names come from `mcp-catalogue.ts`, which has no
 * imports either.
 *
 * That import is why `tsconfig.node.json` now names `src/renderer/store/
 * storefront.ts` beside the `logo-data.ts` line already there. The node project
 * is `composite`, and a composite project refuses a file it does not list —
 * `error TS6307` — however pure the file is. `store-logos.test.ts` records the
 * same one-line consequence of the same judgement.
 */

import {
  COST_WORDS,
  matchesQuery,
  type StoreFacets,
} from '../../../renderer/store/storefront'
import { MCP_CATEGORIES } from '../../mcp-catalogue'
import type { McpAddResult, McpAddScope, McpRemoveRequest } from '../../mcp-add'
import type {
  McpInstallRequest,
  McpStoreResult,
  McpStoreRow,
  McpStoreView,
} from '../../mcp-store'
import type { StoreResult, StoreTool, StoreView } from '../../browser-store'
import type { PanelAction, PanelField, PanelRow, PanelScope } from '../protocol'
import type { Panel, PanelActionRequest, PanelPayload, PanelRequest } from './contract'

/* ------------------------------------------------------------------ deps -- */

/**
 * The MCP half, as `mcp:store`, `mcp:store-install` and `mcp:remove` already
 * answer it.
 *
 * `install` and `remove` are separately optional from `read`, and that is the
 * shape the requirement asks for rather than tidiness: a host that can list the
 * catalogue and genuinely cannot write to it lists the catalogue and says so.
 * The alternative — one optional object for the whole department — can only
 * offer all three or none, and would have to draw an Install that fails.
 */
export interface ServerStoreDeps {
  /** The storefront for one folder. `null` means no project is in view. */
  read(projectPath: string | null): Promise<McpStoreView>
  install?(request: McpInstallRequest): Promise<McpStoreResult>
  remove?(request: McpRemoveRequest): Promise<McpAddResult>
}

/**
 * The browser half, as `browser-store:list`, `:install` and `:remove` answer it.
 *
 * Every method is a promise even though `ToolStore.view` and `ToolStore.remove`
 * are synchronous. One shape for six functions, and the cost is one `async`
 * arrow at the wiring site; the alternative is `Promise<T> | T` on half of an
 * interface that is read far more often than it is implemented.
 */
export interface ToolStoreDeps {
  read(): Promise<StoreView>
  install?(id: string): Promise<StoreResult>
  remove?(id: string): Promise<StoreResult>
}

/**
 * Both departments, both optional.
 *
 * The desktop shell wires both. A headless daemon wires whichever it has: the
 * MCP half needs nothing but a child process, and the browser half needs a
 * store built over `userData`, which `browser-store-ipc.ts` only builds inside
 * `registerIpc()`. A daemon that has not built one passes nothing and the panel
 * says so.
 */
export interface StorePanelDeps {
  tools?: ToolStoreDeps
  servers?: ServerStoreDeps
}

/* ----------------------------------------------------------------- rows -- */

/**
 * The two id spaces, kept apart for good.
 *
 * `page-links` is a browser tool and `filesystem` is an MCP server, and today
 * nothing collides. They are two independent catalogues maintained in two files
 * by two arguments, though, so the day one of them mints a name the other
 * already has, an action would be delivered to the wrong department and install
 * something nobody asked for. `mcp-custom.ts` prefixes its own ids for exactly
 * this reason — *"keeps it out of the catalogue's id space for good"* — and
 * this is the same measure one level up.
 */
const SERVER = 'server:'
const TOOL = 'tool:'

/**
 * The shelf a row sits on, in words, for the search haystack.
 *
 * `matchesQuery` searches the shelf's name as well as the row's, so that typing
 * *passwords* finds what is on the passwords shelf even though no summary says
 * the word. `MCP_CATEGORIES` is the catalogue's own list, imported rather than
 * copied; `your-own` is not on it and never can be, because no catalogue entry
 * may carry it, so its one word is spelled here. See {@link BUILT_IN_NAME} for
 * the two others in the same position and why none of them can be imported.
 */
const SHELF_NAMES = new Map<string, string>([
  ...MCP_CATEGORIES.map((shelf): [string, string] => [shelf.id, shelf.name]),
  ['your-own', 'Added by you'],
])

/**
 * The browser department's one shelf, spelled here because the desktop spells it
 * inside a React component.
 *
 * `BUILT_IN_SHELF` and `BUILT_IN_NAME` live in `renderer/browser/StorePanel.tsx`,
 * a React component that a daemon's import graph may not contain at any price.
 * *Added by you* lives in `renderer/components/mcp-store-bridge.ts`, which the
 * main process could import — but that file is itself the renderer's mirror of
 * `MCP_CATEGORIES`, and importing a mirror to avoid copying one word out of it
 * is the wrong direction to reach. The shelf list comes from the catalogue that
 * declares it and these three strings are spelled here; they are the only words
 * in this file that exist twice in the repository.
 */
const BUILT_IN = 'built-in'
const BUILT_IN_NAME = 'Built into this app'

/** One row of the store, with everything the filters need to decide about it. */
interface Entry {
  row: PanelRow
  facets: StoreFacets
  /**
   * Whether this row is offering an Install *right now*.
   *
   * Not `!installed`: a row whose runtime is missing, whose name is already
   * taken by somebody else's server, or that sits on a host with no writer is
   * not something that can be added, and a chip that answered *can be added*
   * with those in it would be a control that leads to no button.
   */
  addable: boolean
}

/**
 * The form behind an Install, when the row needs one.
 *
 * No field is ever prefilled. `PanelField.value` is drawn into a text box on
 * somebody's phone, and most of these are API keys — this app's standing rule
 * is that a secret's *name* crosses a wire and its value does not, which is why
 * `ConfiguredServer` carries `envKeys` and nothing else.
 *
 * A key the machine's login shell already exports is not required and says so,
 * because `buildInstall` treats a blank one as inherited and writing a second
 * copy of it into a configuration file is strictly worse than leaving it there.
 */
function installFields(row: McpStoreRow): PanelField[] {
  return row.inputs.map(
    (field): PanelField => ({
      id: field.key,
      label: field.label,
      placeholder: field.inEnvironment
        ? `Leave this blank to use the ${field.key} this machine already exports`
        : field.hint,
      required: field.required && !field.inEnvironment,
    }),
  )
}

/**
 * One MCP catalogue or hand-written row, as a panel row.
 *
 * `detail` is the summary only while the summary is the useful sentence. A row
 * with no Install has to say *what is missing* — `mcp-store.ts` builds that
 * sentence into `blocked` precisely so that *"a row is never merely greyed
 * out"*, and printing the summary over it would leave a phone showing a thing
 * you cannot have and no reason why.
 */
function serverEntry(
  row: McpStoreRow,
  folder: string,
  canInstall: boolean,
  canRemove: boolean,
): Entry {
  const addable = row.state === 'available' && row.blocked === '' && canInstall
  const actions: PanelAction[] = []

  if (addable) {
    const fields = installFields(row)
    const form = fields.length > 0 ? { fields } : {}
    /*
     * Two buttons rather than a scope field, and `local` is deliberately not a
     * third.
     *
     * The desktop offers `user`, `project` and `local` in a picker. `PanelField`
     * is a text box, so carrying the choice as a field would be asking somebody
     * to spell `project` correctly on a phone, and `resolveInstall` reads
     * anything it does not recognise as `user` — a typo would write the server
     * into a different file than the person chose and report success. Two
     * labelled taps carry the distinction that matters, which is *who else gets
     * this*: yourself everywhere, or this folder, where a committed `.mcp.json`
     * hands it to whoever clones the repository. `local` differs from `project`
     * only in that it is not shared, and a third button on every row of a
     * forty-row list under a thumb costs more than that distinction is worth
     * here. It stays a desktop choice, and a server installed with it is still
     * listed, and still removable, from this panel.
     */
    actions.push({ id: 'install', label: 'Install', ...form })
    if (folder !== '') {
      actions.push({ id: 'install.here', label: 'Install for this folder', ...form })
    }
  }

  if (row.state === 'installed' && row.scope !== '' && canRemove) {
    actions.push({
      id: 'remove',
      label: 'Remove',
      kind: 'destructive',
      confirm:
        `${row.name} is unwritten from Claude Code’s configuration, and any key you typed into ` +
        'it goes with it — this app never kept a copy to put back.',
    })
  }

  /*
   * A missing runtime outranks being installed. A hand-written server whose
   * `docker` has since been uninstalled is genuinely in the configuration and
   * genuinely cannot start, and a green tick beside the sentence saying its
   * runtime is gone would be the panel contradicting itself in one line.
   */
  const cannotRun = row.blocked !== '' || row.runtimeMissing
  const detail =
    row.blocked !== ''
      ? row.blocked
      : row.runtimeMissing && row.caveat !== ''
        ? row.caveat
        : row.summary

  return {
    row: {
      title: row.name,
      detail,
      value: row.state === 'installed' ? 'Installed' : COST_WORDS[row.cost],
      ...(cannotRun ? { status: 'warn' } : row.state === 'installed' ? { status: 'ok' } : {}),
      id: `${SERVER}${row.id}`,
      ...(actions.length > 0 ? { actions } : {}),
    },
    facets: {
      id: row.id,
      name: row.name,
      summary: row.summary,
      category: row.category,
      categoryName: SHELF_NAMES.get(row.category) ?? '',
      tags: row.tags,
      cost: row.cost,
      /*
       * `runtimeMissing` rather than `state === 'unavailable'`, which is the
       * distinction `mcpCompat` in the renderer's bridge spends a paragraph on:
       * the two coincide only for catalogue rows, and a configured server whose
       * runtime went missing never reaches that state.
       */
      compat: row.runtimeMissing ? 'cannot' : 'unknown',
      installed: row.state === 'installed',
      source: row.custom ? 'your-own' : row.origin,
      /*
       * Empty on purpose. `needs` is read by one thing — `matchesFacet`'s
       * `needs` case — and this panel draws no *what you must bring* control,
       * for the reason given where the chips are declared. Deriving it here
       * would be a second copy of `mcpNeeds`, kept in step with the renderer's
       * by nobody, feeding a filter that does not exist.
       */
      needs: [],
    },
    addable,
  }
}

/**
 * What a browser tool's row says in the place a server's says its price.
 *
 * A tool that ships in this app's own bytes has no price to report, so the slot
 * carries its state instead — and `damaged` and `outdated` are states worth a
 * word rather than being folded into *Installed*, which is what would make a
 * tool that has stopped working look like one that has not.
 */
const TOOL_WORDS: Readonly<Record<StoreTool['state'], string>> = {
  available: COST_WORDS.free,
  installed: 'Installed',
  outdated: 'Update available',
  damaged: 'Damaged',
}

/**
 * One tool this app installs into its own browser, as a panel row.
 *
 * `damaged` and `outdated` both keep their Remove and both offer the install
 * again under the word that describes what pressing it does. That is what the
 * desktop does, and it is the difference between a row a person can fix and a
 * row that has quietly stopped working.
 */
function toolEntry(tool: StoreTool, canInstall: boolean, canRemove: boolean): Entry {
  const actions: PanelAction[] = []
  if (canInstall && tool.state !== 'installed') {
    actions.push({
      id: 'install',
      label: tool.state === 'outdated' ? 'Update' : tool.state === 'damaged' ? 'Repair' : 'Install',
    })
  }
  if (canRemove && tool.state !== 'available') {
    actions.push({
      id: 'remove',
      label: 'Remove',
      kind: 'destructive',
      confirm:
        `The file ${tool.name} installed is deleted from this machine. Installing it again ` +
        'fetches it and checks it against the same fingerprint, so nothing is lost that cannot ' +
        'be got back.',
    })
  }

  return {
    row: {
      title: tool.name,
      detail: tool.message !== '' ? tool.message : tool.summary,
      value: TOOL_WORDS[tool.state],
      ...(tool.state === 'damaged'
        ? { status: 'warn' }
        : tool.state === 'available'
          ? {}
          : { status: 'ok' }),
      id: `${TOOL}${tool.id}`,
      ...(actions.length > 0 ? { actions } : {}),
    },
    facets: {
      id: tool.id,
      name: tool.name,
      summary: tool.summary,
      category: BUILT_IN,
      categoryName: BUILT_IN_NAME,
      tags: [],
      /* It ships in this app's own bytes: nothing to pay, nobody to sign up
         with. The one cost answer in either catalogue that is a measurement. */
      cost: 'free',
      /* This app wrote it and runs it in its own engine, which is a measurement
         and not a hope — `builtInFacets` says the same. */
      compat: 'works',
      /*
       * `!== 'available'` rather than `=== 'installed'`, which is where this
       * differs from `builtInFacets` and the reason is the chip it feeds. On the
       * desktop the *Installed* chip answers a catalogue question. Here it
       * answers *is there a Remove on this row*, and there is one for `damaged`
       * and `outdated` — a tool on the disk that no chip could reach would be
       * unremovable from a phone.
       */
      installed: tool.state !== 'available',
      source: BUILT_IN,
      needs: [],
    },
    addable: canInstall && tool.state === 'available',
  }
}

/* ---------------------------------------------------------------- chips -- */

interface Chip {
  id: string
  label: string
  /** The sentence for a list this chip emptied. */
  empty: string
  keep(entry: Entry): boolean
}

/**
 * Three filters out of six facets, and the chip that clears them.
 *
 * `PanelRequest.scope` is one string, so this is a single-select row of chips
 * and not the desktop's six independent facet groups. `storefront.ts` models
 * category, cost, compat, installed, source and needs; what survives a phone is
 * what somebody would press with a thumb while standing up.
 *
 *  - **Installed** and **Can be added** are the `installed` facet's two sides,
 *    with `Can be added` folding `compat` and the writer check into it. Those
 *    three answer one question between them — *what can I do here* — and
 *    splitting them would have produced a chip that narrows to rows with no
 *    button on them.
 *  - **Free** is the `cost` facet's first value. The other four ride on every
 *    row already, in `value`, in the words `COST_WORDS` gives both stores; a
 *    five-chip price control belongs on a page with a rail.
 *
 * Dropped, and each for its own reason. **Category**: thirteen MCP shelves plus
 * the browser's own is a rail on a full page and a scrolling strip on a phone,
 * and the search box answers *where is the postgres one* better than a shelf
 * does under a thumb. **Source**: `reference`, `vendor`, `hosted`, `archived` —
 * a provenance question somebody asks while reading one row, not while narrowing
 * a list. **Needs**: a set rather than a value, so a row that wants Docker *and*
 * a key belongs under two chips at once, and a single-select control would have
 * to pick one and hide the other.
 */
const CHIPS: readonly Chip[] = [
  { id: 'all', label: 'Everything', empty: 'This store is empty.', keep: () => true },
  {
    id: 'installed',
    label: 'Installed',
    empty: 'Nothing from this store is installed on this machine.',
    keep: (entry) => entry.facets.installed,
  },
  {
    id: 'addable',
    label: 'Can be added',
    empty: 'Nothing in the store can be installed from here.',
    keep: (entry) => entry.addable,
  },
  {
    id: 'free',
    label: 'Free',
    empty: 'Nothing in the store is free of both a bill and a sign-up.',
    keep: (entry) => entry.facets.cost === 'free',
  },
]

/**
 * The chips worth drawing, over what the search left.
 *
 * `storefront.ts`'s one standing rule, applied here rather than reinvented: *"a
 * filter option is drawn only if choosing it would leave something on screen"*.
 * Counted over the query's results and not the chosen chip's, which is the
 * cross-filter arrangement `facetOptions` argues for — counting over the fully
 * filtered set would zero every other chip the moment one was pressed and leave
 * no way back. The chosen chip is kept whatever its count, for the same reason.
 */
function chipsFor(found: readonly Entry[], chosen: string): PanelScope[] {
  return CHIPS.filter(
    (chip) => chip.id === 'all' || chip.id === chosen || found.some((entry) => chip.keep(entry)),
  ).map((chip): PanelScope => ({ id: chip.id, label: chip.label, on: chip.id === chosen }))
}

/* ---------------------------------------------------------------- panel -- */

/** What went wrong, in the words the module that failed used. */
function because(cause: unknown): string {
  return cause instanceof Error && cause.message !== '' ? ` — ${cause.message}` : ''
}

/**
 * The store panel.
 *
 * @param deps Both departments, either of which may be absent or read-only. See
 * {@link StorePanelDeps}; `server.ts` builds them.
 */
export function storePanel(deps: StorePanelDeps): Panel {
  /**
   * Both catalogues, as rows, plus everything that could not be answered.
   *
   * Each department is read and turned into rows inside one `try`, so a
   * dependency that throws *and* a row this file cannot make sense of both land
   * in `note` rather than in `server.ts`'s catch. The other department is
   * unaffected: half a store is worth showing, and it is the half that says why
   * the other is missing.
   */
  async function gather(folder: string): Promise<{ entries: Entry[]; problems: string[] }> {
    const entries: Entry[] = []
    const problems: string[] = []

    if (deps.tools === undefined) {
      problems.push('The tools this app installs into its own browser cannot be read from here.')
    } else {
      const tools = deps.tools
      try {
        const view = await tools.read()
        const canInstall = tools.install !== undefined
        const canRemove = tools.remove !== undefined
        for (const tool of view.tools) entries.push(toolEntry(tool, canInstall, canRemove))
        if (!canInstall) {
          problems.push('Browser tools can be browsed from here and not installed from here.')
        }
      } catch (cause) {
        problems.push(`The browser tools could not be read${because(cause)}.`)
      }
    }

    if (deps.servers === undefined) {
      problems.push('The MCP server catalogue cannot be read from here.')
    } else {
      const servers = deps.servers
      try {
        const view = await servers.read(folder === '' ? null : folder)
        /*
         * Nothing is written without the CLI, so a host without it lists the
         * catalogue and offers no buttons at all. `buildStoreView` already puts
         * the same sentence on every affected row; this says it once at the top,
         * which is what the desktop store does with it too.
         */
        const canInstall = servers.install !== undefined && view.writer.found
        const canRemove = servers.remove !== undefined && view.writer.found
        for (const row of view.rows) entries.push(serverEntry(row, folder, canInstall, canRemove))
        if (!view.writer.found) {
          problems.push(
            'Claude Code’s command line tool is what writes and unwrites this configuration, and ' +
              'it was not found on this machine — the catalogue is listed, and nothing in it can ' +
              'be installed or removed until it is there.',
          )
        } else if (servers.install === undefined) {
          problems.push('MCP servers can be browsed from here and not installed from here.')
        }
      } catch (cause) {
        problems.push(`The MCP server catalogue could not be read${because(cause)}.`)
      }
    }

    return { entries, problems }
  }

  async function read(request: PanelRequest): Promise<PanelPayload> {
    const { entries, problems } = await gather(request.path)
    const query = request.query ?? ''
    const found = entries.filter((entry) => matchesQuery(entry.facets, query))
    const chosen = CHIPS.find((chip) => chip.id === request.scope) ?? CHIPS[0]
    const rows = found.filter((entry) => chosen.keep(entry)).map((entry) => entry.row)

    /*
     * An empty list gets its explanation first, then whatever is standing. When
     * there were no entries at all the problems already say why, and adding
     * "this store is empty" in front of them would be the panel restating a
     * failure as an inventory.
     */
    const note = [
      ...(rows.length === 0 && entries.length > 0
        ? [query !== '' ? `Nothing in the store matches “${query}”.` : chosen.empty]
        : []),
      ...problems,
    ].join(' ')

    const scopes = chipsFor(found, chosen.id)
    return {
      path: request.path,
      ...(note !== '' ? { note } : {}),
      /* One chip is not a control. The same rule `facetOptions` applies to a
         facet group whose options all collapse into one. */
      ...(scopes.length > 1 ? { scopes } : {}),
      rows,
    }
  }

  /** What just happened, in one line, or `''` for an action that did nothing. */
  async function performTool(id: string, request: PanelActionRequest): Promise<string> {
    const tools = deps.tools
    if (tools === undefined) return 'This host has no browser tool store.'
    try {
      if (request.action === 'install') {
        if (tools.install === undefined) return 'Nothing can be installed from here.'
        const done = await tools.install(id)
        return done.message !== '' ? done.message : done.ok ? 'Installed.' : 'That did not work.'
      }
      if (request.action === 'remove') {
        if (tools.remove === undefined) return 'Nothing can be removed from here.'
        const done = await tools.remove(id)
        return done.message !== '' ? done.message : done.ok ? 'Removed.' : 'That did not work.'
      }
    } catch (cause) {
      return `That could not be done${because(cause)}.`
    }
    return `This store has no “${request.action}”.`
  }

  async function performServer(id: string, request: PanelActionRequest): Promise<string> {
    const servers = deps.servers
    if (servers === undefined) return 'This host has no MCP server catalogue.'
    const folder = request.path

    /*
     * The row is resolved from a fresh read rather than from anything the phone
     * sent, and the cost of that read is the point rather than an oversight. A
     * Remove is addressed by *name and scope* — `mcp-add.ts` carries the scope
     * precisely because the CLI without one removes from whichever scope it
     * finds, so a user-scope and a project-scope server of the same name are one
     * press from the wrong one. A screen a person has had in their pocket for
     * ten minutes is not evidence about which file that name is in now.
     * `installFromCatalogue` re-probes the runtime for the same reason.
     */
    let view: McpStoreView
    try {
      view = await servers.read(folder === '' ? null : folder)
    } catch (cause) {
      return `That could not be done${because(cause)}.`
    }

    const row = view.rows.find((one) => one.id === id)
    if (row === undefined) return 'That row is not in this store.'
    if (!view.writer.found) {
      return 'Claude Code’s command line tool writes this configuration, and it is not on this machine.'
    }

    try {
      if (request.action === 'install' || request.action === 'install.here') {
        if (servers.install === undefined) return 'Nothing can be installed from here.'
        if (row.blocked !== '') return row.blocked
        if (row.state !== 'available') return `${row.name} is already in your configuration.`
        const scope: McpAddScope = request.action === 'install.here' ? 'project' : 'user'
        if (scope === 'project' && folder === '') return 'There is no folder in view to install into.'
        const done = await servers.install({
          id: row.id,
          scope,
          projectPath: folder === '' ? null : folder,
          values: request.fields,
        })
        return done.message !== '' ? done.message : done.ok ? `${row.name} is installed.` : 'That did not work.'
      }
      if (request.action === 'remove') {
        if (servers.remove === undefined) return 'Nothing can be removed from here.'
        if (row.scope === '') return `${row.name} is not in your configuration.`
        const done = await servers.remove({
          name: row.name,
          scope: row.scope,
          projectPath: folder === '' ? null : folder,
        })
        return done.message !== '' ? done.message : done.ok ? `${row.name} is removed.` : 'That did not work.'
      }
    } catch (cause) {
      return `That could not be done${because(cause)}.`
    }
    return `This store has no “${request.action}”.`
  }

  /**
   * An action answers with the panel.
   *
   * The redraw is the confirmation — the row a person installed comes back
   * wearing *Installed* and a Remove — and `notice` is the one line that rides
   * on it. A refusal is a notice too: nothing changed, the list says so, and
   * there is no second state for the phone to hold.
   */
  async function act(request: PanelActionRequest): Promise<PanelPayload> {
    const id = request.id ?? ''
    const notice = id.startsWith(TOOL)
      ? await performTool(id.slice(TOOL.length), request)
      : id.startsWith(SERVER)
        ? await performServer(id.slice(SERVER.length), request)
        : 'That row is not in this store.'
    const payload = await read(request)
    return notice === '' ? payload : { ...payload, notice }
  }

  return { read, act }
}
