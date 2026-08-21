/**
 * The browser's tools store: what may be offered, what is on disk, and the
 * verification between the two.
 *
 * ## What Asad asked for
 *
 *   > *"i think we can have a tools store for extensions to this browser with
 *   > all open source best tools in the market so people can use the tool of
 *   > their choice in the browser, which tools will not be here only when they
 *   > download."*
 *
 * The last clause is the requirement that shapes this file: **nothing is in the
 * browser until somebody chooses it.** An uninstalled tool has no row in any
 * schema, no id an agent can name, and no bytes under `<userData>`.
 *
 * ## Why this is not a Chrome extension store
 *
 * Electron has `session.loadExtension`, for *unpacked* extensions, with a
 * partial API surface and no Web Store — no `chrome.*` beyond a fraction, no
 * update channel, no signature, no reviews. A store built on it would promise
 * the extension ecosystem and deliver a subset nobody can predict from the
 * outside, which is the shape of half-feature `BrowserMenu.tsx` already refuses
 * to draw a row for. There is no extension loading in this build and the store
 * says so in one sentence rather than implying parity it does not have.
 *
 * What this app *does* have is a tool surface with an allow-list as its security
 * model (`deck-control/`), and a page-reading engine whose whole design is that
 * an agent contributes data and never code (`browser-drive-script.ts`). A store
 * built on those two is safe by construction rather than by review.
 *
 * ## The four questions a store has to answer, and the answers
 *
 * **Where does a tool come from, and how is its identity checked?** From
 * {@link StoreCatalogue} — a curated table compiled into this app, which is a
 * positive list for exactly the reason `session-tools.ts` gives about
 * `SESSION_TOOLS`: *"A grant is a thing somebody writes down."* Each entry pins
 * the artifact's **sha256**, and that digest is in the app's own bytes, not in
 * anything fetched. `fetch-update.ts` already makes the argument this leans on:
 * *"HTTPS proves you are talking to a host. It says nothing about what that host
 * was handed at upload time, what a proxy did in between, or whether the disk
 * wrote every byte it accepted."*
 *
 * The digest is checked **at install and again on every load**, and the second
 * check is not ceremony. `<userData>` is writable by every process running as
 * this user; an installed recipe that was edited after it was installed is
 * caught the next time it is read, and the tool is reported damaged rather than
 * run.
 *
 * **May a new tool gain the reach of the built-in ones?** No, and the bound is
 * structural rather than promised: a store tool is a recipe run by
 * `browser-store-script.ts` in the same isolated world with the same secret
 * guard, so its ceiling is `browser.read` on a window the caller already holds
 * — and a recipe that names hosts has strictly less, because it refuses to run
 * anywhere else. On top of that, {@link install} refuses a recipe asking for a
 * grant or an origin the store row a person read did not say. A row that said
 * one thing and a file that says another is not installed under either.
 *
 * **Do install and remove both work?** {@link remove} deletes the directory and
 * then **reads the disk back** before reporting success. A removal that returned
 * ok because `rm` did not throw is the shape of the three scripts in the
 * pipeline that reported success while doing nothing.
 *
 * **What if it cannot be verified?** It does not install, and the sentence says
 * which check failed — the digest, the schema, a grant, or the network.
 */

import { createHash, timingSafeEqual } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import {
  MAX_RECIPE_BYTES,
  parseRecipe,
  type Grant,
  type Recipe,
} from './browser-store-recipe'

/* -------------------------------------------------------------- the shapes -- */

/**
 * Where an entry's bytes come from.
 *
 * `bundled` ships inside the app. It is still installed rather than always
 * present, because *"which tools will not be here only when they download"* is
 * about what is switched on, and it still goes through the same verifier — so
 * the digest keeps meaning something after the file reaches the disk.
 *
 * `fetched` is an exact https URL and an exact byte count. Both are pinned in
 * the catalogue beside the digest, so a response of the wrong length is refused
 * before it is hashed and a response of the right length with the wrong bytes is
 * refused after.
 */
export type StoreSource =
  | { kind: 'bundled'; text: string }
  | { kind: 'fetched'; url: string; bytes: number }

/** One row of the curated table. */
export interface StoreEntry {
  id: string
  name: string
  /** One line. What it does, in the words a person would use. */
  summary: string
  /** Where the thing itself lives, so the row is not this app's word for it. */
  homepage: string
  licence: string
  version: string
  /** What the row promises it may touch. The recipe may not exceed this. */
  grants: readonly Grant[]
  /** The hosts the row promises it runs on. The recipe may not exceed this. */
  origins: readonly string[]
  source: StoreSource
  /** Hex sha256 of the artifact's bytes, pinned here and nowhere else. */
  sha256: string
}

export type StoreCatalogue = readonly StoreEntry[]

/** What a row is doing right now. */
export type ToolState = 'available' | 'installed' | 'damaged' | 'outdated'

/** One row as the panel draws it. */
export interface StoreTool {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  grants: readonly Grant[]
  origins: readonly string[]
  /** `''` for a bundled tool, the exact URL for a fetched one. */
  url: string
  fetched: boolean
  /**
   * The hex sha256 this row is pinned to, out of the app's own bytes.
   *
   * On the row because a store that says "verified" and will not say *against
   * what* is asking for the same trust it exists to replace. It is also the
   * only thing a panel can use to tell a listing with a real signature from one
   * carrying none — `digestMatches` refuses anything that is not 64 hex
   * characters, so a row whose digest is not that can never install, and a
   * screen that offered Install for it would be offering a control that cannot
   * work.
   */
  sha256: string
  state: ToolState
  /** The version on disk, when there is one. */
  installedVersion: string
  installedAt: number
  /** Why it is damaged, or `''`. Shown on the row rather than swallowed. */
  message: string
  /** What its recipe reads, so the row is not a black box. Empty until installed. */
  reads: string[]
}

export interface StoreView {
  tools: StoreTool[]
  /** Absolute, so the panel can say where installed tools live. */
  folder: string
}

export type StoreResult = { ok: boolean; message: string }

/** An installed, verified, parsed tool. What `browser.extract` runs. */
export interface InstalledTool {
  entry: StoreEntry
  recipe: Recipe
  installedAt: number
}

/* -------------------------------------------------------------- the digest -- */

export function sha256Hex(bytes: string | Buffer): string {
  return createHash('sha256').update(typeof bytes === 'string' ? Buffer.from(bytes, 'utf8') : bytes).digest('hex')
}

/**
 * Are these the bytes the catalogue wrote down?
 *
 * `timingSafeEqual` over decoded buffers rather than `===` over the hex, for the
 * reason `verifyArchive` gives one file over: comparing decoded values forces
 * the expected digest to be *decoded and length-checked* first, which is where a
 * truncated or differently-encoded digest gets caught instead of being blamed on
 * the download.
 */
export function digestMatches(bytes: string | Buffer, expectedHex: string): boolean {
  if (!/^[0-9a-f]{64}$/i.test(expectedHex)) return false
  const expected = Buffer.from(expectedHex.toLowerCase(), 'hex')
  const actual = Buffer.from(sha256Hex(bytes), 'hex')
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

/* --------------------------------------------------------------- the paths -- */

/** A store id is a directory name, so it is checked before it is ever joined. */
const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/

export function storeRoot(userData: string): string {
  return join(userData, 'browser-tools')
}

/* --------------------------------------------------------------- fetching -- */

export interface FetchedBytes {
  ok: boolean
  text: string
  /** Why not, for the row. */
  message: string
}

export type FetchBytes = (url: string, limit: number) => Promise<FetchedBytes>

/**
 * Read a pinned URL, over https, up to a hard byte ceiling.
 *
 * The ceiling is applied to what arrives rather than to `content-length`,
 * because a header is the server's claim and the cap has to hold against a
 * server that lies. `https:` only: a store that would install over plain http
 * is a store whose digest is the only thing between somebody's coffee-shop
 * network and this app's tool surface, and one line of defence is not enough
 * when the second one costs a scheme check.
 */
export const httpsFetchBytes: FetchBytes = async (url, limit) => {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, text: '', message: 'that is not a URL' }
  }
  if (parsed.protocol !== 'https:') {
    return { ok: false, text: '', message: 'a tool can only be fetched over https' }
  }
  try {
    const response = await fetch(url, {
      redirect: 'error',
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(30_000),
    })
    if (!response.ok) {
      return { ok: false, text: '', message: `the download answered ${response.status}` }
    }
    const buffer = Buffer.from(await response.arrayBuffer())
    if (buffer.byteLength > limit) {
      return { ok: false, text: '', message: `the download is larger than ${limit} bytes` }
    }
    return { ok: true, text: buffer.toString('utf8'), message: '' }
  } catch (error) {
    return {
      ok: false,
      text: '',
      message: error instanceof Error ? `the download failed: ${error.message}` : 'the download failed',
    }
  }
}

/* ---------------------------------------------------------------- the store -- */

export interface ToolStoreOptions {
  /** `<userData>/browser-tools`. */
  root: string
  catalogue: StoreCatalogue
  /** Replaced in tests. Production passes nothing and gets {@link httpsFetchBytes}. */
  fetchBytes?: FetchBytes
  now?: () => number
}

export interface ToolStore {
  view(): StoreView
  install(id: string): Promise<StoreResult>
  remove(id: string): StoreResult
  /** Every verified, parsed tool. What the MCP tool resolves an id against. */
  installed(): InstalledTool[]
}

interface OnDisk {
  version: string
  installedAt: number
}

function readOnDisk(dir: string): OnDisk | null {
  try {
    const raw: unknown = JSON.parse(readFileSync(join(dir, 'installed.json'), 'utf8'))
    if (typeof raw !== 'object' || raw === null) return null
    const record = raw as Record<string, unknown>
    return {
      version: typeof record.version === 'string' ? record.version : '',
      installedAt: typeof record.installedAt === 'number' ? record.installedAt : 0,
    }
  } catch {
    return null
  }
}

/**
 * What the recipe reads, in one short list, for the row.
 *
 * A store row that says only "Reads the page" is asking somebody to trust a
 * name. The field names are the honest answer to *"what will this actually take
 * off my page"*, and they are read out of the installed recipe rather than out
 * of the catalogue, so what the row says is what is on the disk.
 */
function readsOf(recipe: Recipe): string[] {
  const names = recipe.fields.map((field) => field.name)
  if (recipe.rows) for (const field of recipe.rows.fields) names.push(field.name)
  const unique: string[] = []
  for (const name of names) if (!unique.includes(name)) unique.push(name)
  return unique.slice(0, 24)
}

export function createToolStore(options: ToolStoreOptions): ToolStore {
  const fetchBytes = options.fetchBytes ?? httpsFetchBytes
  const now = options.now ?? Date.now
  const entryFor = (id: string): StoreEntry | null =>
    options.catalogue.find((entry) => entry.id === id) ?? null
  const dirFor = (id: string): string => join(options.root, id)

  /**
   * Read one installed tool back off the disk, verifying it on the way.
   *
   * Three ways this answers "no", and each one is a sentence rather than a
   * silence, because a tool that disappears without a word is indistinguishable
   * from a tool that was never installed.
   */
  function load(entry: StoreEntry): { tool: InstalledTool } | { why: string } | null {
    const dir = dirFor(entry.id)
    const file = join(dir, 'recipe.json')
    if (!existsSync(file)) return null
    let bytes: string
    try {
      bytes = readFileSync(file, 'utf8')
    } catch {
      return { why: 'its file could not be read' }
    }
    if (!digestMatches(bytes, entry.sha256)) {
      /*
       * The check that earns its keep after the download is long finished. The
       * file is under `<userData>`, which every process running as this user can
       * write; this is the only thing that would notice one of them having
       * rewritten a recipe between installs.
       */
      return { why: 'the file on disk is not the one that was installed — remove it and install again' }
    }
    const parsed = parseRecipe(bytes, entry.id)
    if (!parsed.ok) return { why: parsed.why }
    const disk = readOnDisk(dir)
    return { tool: { entry, recipe: parsed.recipe, installedAt: disk?.installedAt ?? 0 } }
  }

  /**
   * The recipe may not promise more than the row a person read.
   *
   * The store row is the disclosure; the recipe is the thing that runs. When
   * they disagree the honest answer is neither, which is why this is a refusal
   * and not a widening or a narrowing.
   */
  function agreesWithRow(entry: StoreEntry, recipe: Recipe): string {
    if (recipe.version !== entry.version) {
      return `this is version ${recipe.version} and the store offered ${entry.version}`
    }
    for (const grant of recipe.grants) {
      if (!entry.grants.includes(grant)) {
        return `it asks to ${grant}, which is not what this store row says it does`
      }
    }
    for (const origin of recipe.origins) {
      if (!entry.origins.includes(origin)) {
        return `it wants to run on ${origin}, which is not what this store row says it does`
      }
    }
    return ''
  }

  return {
    view(): StoreView {
      const tools: StoreTool[] = options.catalogue.map((entry) => {
        const loaded = load(entry)
        const base = {
          id: entry.id,
          name: entry.name,
          summary: entry.summary,
          homepage: entry.homepage,
          licence: entry.licence,
          version: entry.version,
          grants: entry.grants,
          origins: entry.origins,
          url: entry.source.kind === 'fetched' ? entry.source.url : '',
          fetched: entry.source.kind === 'fetched',
          sha256: entry.sha256,
        }
        if (loaded === null) {
          return { ...base, state: 'available' as const, installedVersion: '', installedAt: 0, message: '', reads: [] }
        }
        if ('why' in loaded) {
          return {
            ...base,
            state: 'damaged' as const,
            installedVersion: readOnDisk(dirFor(entry.id))?.version ?? '',
            installedAt: 0,
            message: loaded.why,
            reads: [],
          }
        }
        const { recipe, installedAt } = loaded.tool
        return {
          ...base,
          state: 'installed' as const,
          installedVersion: recipe.version,
          installedAt,
          message: '',
          reads: readsOf(recipe),
        }
      })
      return { tools, folder: options.root }
    },

    async install(id: string): Promise<StoreResult> {
      if (!SAFE_ID.test(id)) return { ok: false, message: 'that is not a tool id' }
      const entry = entryFor(id)
      if (entry === null) return { ok: false, message: 'this store has no tool by that name' }

      let bytes: string
      if (entry.source.kind === 'bundled') {
        bytes = entry.source.text
      } else {
        const got = await fetchBytes(entry.source.url, Math.min(entry.source.bytes, MAX_RECIPE_BYTES))
        if (!got.ok) return { ok: false, message: `${entry.name} was not installed: ${got.message}.` }
        const length = Buffer.byteLength(got.text, 'utf8')
        if (length !== entry.source.bytes) {
          /*
           * Length first, as a cheap early-out that names the failure a
           * truncated transfer actually produces — the same ordering and the
           * same reasoning as `verifyArchive`. It is never a substitute for the
           * digest, which runs immediately below on everything that passes.
           */
          return {
            ok: false,
            message:
              `${entry.name} was not installed: the download is ${length} bytes and this app ` +
              `expects ${entry.source.bytes}.`,
          }
        }
        bytes = got.text
      }

      if (!digestMatches(bytes, entry.sha256)) {
        return {
          ok: false,
          message:
            `${entry.name} was not installed: these are not the bytes this app has written ` +
            `down for it. Nothing was saved.`,
        }
      }

      const parsed = parseRecipe(bytes, entry.id)
      if (!parsed.ok) {
        return { ok: false, message: `${entry.name} was not installed: ${parsed.why}.` }
      }

      const disagreement = agreesWithRow(entry, parsed.recipe)
      if (disagreement !== '') {
        return { ok: false, message: `${entry.name} was not installed: ${disagreement}.` }
      }

      const dir = dirFor(id)
      try {
        mkdirSync(dir, { recursive: true })
        writeFileAtomic(join(dir, 'recipe.json'), bytes)
        writeFileAtomic(
          join(dir, 'installed.json'),
          `${JSON.stringify({ id, version: parsed.recipe.version, sha256: entry.sha256, installedAt: now() }, null, 2)}\n`,
        )
      } catch (error) {
        return {
          ok: false,
          message: `${entry.name} was not installed: ${error instanceof Error ? error.message : 'it could not be saved'}.`,
        }
      }

      /*
       * The confirmation names a place. `FEATURE-STORE.md`: *"a short
       * confirmation says **where to find it** — the menu, the panel, the
       * settings section. That sentence is the whole onboarding, so it names a
       * real place, not a category."*
       */
      return {
        ok: true,
        message: `${entry.name} is installed. A session can use it by name with the browser's extract verb.`,
      }
    },

    remove(id: string): StoreResult {
      if (!SAFE_ID.test(id)) return { ok: false, message: 'that is not a tool id' }
      const entry = entryFor(id)
      const dir = dirFor(id)
      if (!existsSync(dir)) return { ok: true, message: 'It was not installed.' }
      try {
        rmSync(dir, { recursive: true, force: true })
      } catch (error) {
        return {
          ok: false,
          message: `It could not be removed: ${error instanceof Error ? error.message : 'the folder would not go'}.`,
        }
      }
      /*
       * Read the disk back before saying it is gone.
       *
       * Three scripts in the pipeline this feature comes out of reported success
       * while doing nothing, and an uninstall is the single worst place for that
       * — the row says Available, the file is still there, and the next install
       * writes over a file somebody thought they had deleted.
       */
      if (existsSync(dir)) {
        return { ok: false, message: 'It could not be removed: the folder is still on disk.' }
      }
      return { ok: true, message: `${entry?.name ?? 'The tool'} is removed. Its file is deleted.` }
    },

    installed(): InstalledTool[] {
      const out: InstalledTool[] = []
      for (const entry of options.catalogue) {
        const loaded = load(entry)
        if (loaded !== null && 'tool' in loaded) out.push(loaded.tool)
      }
      return out
    },
  }
}

/**
 * Directories under the store root with no catalogue entry.
 *
 * A tool withdrawn from the app between releases leaves its recipe behind, and
 * nothing above would ever look at it again — so it would sit on somebody's disk
 * forever, unreadable and unremovable through any control. Reported rather than
 * deleted on sight: this list is what the panel offers a Remove for.
 */
export function orphanIds(root: string, catalogue: StoreCatalogue): string[] {
  let names: string[]
  try {
    names = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
  } catch {
    return []
  }
  const known = new Set(catalogue.map((entry) => entry.id))
  return names.filter((name) => SAFE_ID.test(name) && !known.has(name)).sort()
}

