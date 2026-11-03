/**
 * The renderer's half of the browser tools store.
 *
 * Optional, every method of it, for the reason `downloads-bridge.ts` states:
 * `bridge.ts` refuses to resolve at all when one of `BRIDGE_METHODS` is missing,
 * which is right for the methods the panel cannot draw a pixel without and
 * catastrophic for a new one. A preload older than this feature must cost the
 * browser its store, never the whole browser.
 *
 * The types are mirrors rather than imports, again for the reason `bridge.ts`
 * gives: the renderer's tsconfig does not include `src/main`. Every value that
 * arrives is narrowed below rather than trusted.
 */

/** Mirrors `Grant` in `src/main/browser-store-recipe.ts`. */
export type Grant = 'page-read'

/** Mirrors `GRANT_WORDS` in the same file — the line a row prints. */
export const GRANT_WORDS: Readonly<Record<string, string>> = {
  'page-read': 'Reads the page you point it at',
}

/** Mirrors `ToolState` in `src/main/browser-store.ts`. */
export type ToolState = 'available' | 'installed' | 'damaged' | 'outdated'

/** Mirrors `StoreTool`. */
export interface StoreTool {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  grants: string[]
  origins: string[]
  url: string
  fetched: boolean
  /** The hex sha256 the artifact is pinned to. `''` from an older build. */
  sha256: string
  state: ToolState
  installedVersion: string
  installedAt: number
  message: string
  reads: string[]
}

export interface StoreView {
  tools: StoreTool[]
  folder: string
  /** Folders under the store root this build no longer has a row for. */
  orphans: string[]
}

/** Mirrors `StoreResult`. */
export interface StoreResult {
  ok: boolean
  message: string
}

export interface StoreApi {
  browserStore?(): Promise<unknown>
  browserStoreInstall?(id: string): Promise<unknown>
  browserStoreRemove?(id: string): Promise<unknown>
}

const METHODS = [
  'browserStore',
  'browserStoreInstall',
  'browserStoreRemove',
] as const satisfies readonly (keyof StoreApi)[]

export function resolveStoreApi(host?: unknown): StoreApi {
  const source =
    host ??
    (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as StoreApi
}

/**
 * Is the store wired in this build?
 *
 * All three, and that is deliberate rather than the usual "the reads are the
 * bar". A store with a list and no Install is a catalogue of things you cannot
 * have, and a store with an Install and no Remove is worse than no store at all
 * — this app's own rule is that a control which looks like it works and does not
 * is the defect. So the menu row goes when any one of the three is missing,
 * rather than the panel opening onto buttons that cannot do anything.
 */
export function storeAvailable(api: StoreApi): boolean {
  return (
    typeof api.browserStore === 'function' &&
    typeof api.browserStoreInstall === 'function' &&
    typeof api.browserStoreRemove === 'function'
  )
}

/* ---------------------------------------------------------------- reading -- */

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

function count(raw: unknown): number {
  return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : 0
}

function words(raw: unknown, limit: number): string[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((entry): entry is string => typeof entry === 'string').slice(0, limit)
}

function readState(raw: unknown): ToolState {
  return raw === 'installed' || raw === 'damaged' || raw === 'outdated' ? raw : 'available'
}

function readTool(raw: unknown): StoreTool | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = text(record.id)
  if (id === '') return null
  return {
    id,
    name: text(record.name) || id,
    summary: text(record.summary),
    homepage: text(record.homepage),
    licence: text(record.licence),
    version: text(record.version),
    grants: words(record.grants, 8),
    origins: words(record.origins, 40),
    url: text(record.url),
    fetched: record.fetched === true,
    sha256: text(record.sha256),
    state: readState(record.state),
    installedVersion: text(record.installedVersion),
    installedAt: count(record.installedAt),
    message: text(record.message),
    reads: words(record.reads, 24),
  }
}

/** What `browser-store:list` answered, narrowed. Never throws. */
export function readStoreView(raw: unknown): StoreView {
  if (typeof raw !== 'object' || raw === null) return { tools: [], folder: '', orphans: [] }
  const record = raw as Record<string, unknown>
  const view = typeof record.view === 'object' && record.view !== null
    ? (record.view as Record<string, unknown>)
    : {}
  const tools = Array.isArray(view.tools)
    ? view.tools.map(readTool).filter((tool): tool is StoreTool => tool !== null)
    : []
  return { tools, folder: text(view.folder), orphans: words(record.orphans, 40) }
}

/** What an install or a remove answered, narrowed. */
export function readStoreResult(raw: unknown): StoreResult {
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, message: 'The app did not answer.' }
  }
  const record = raw as Record<string, unknown>
  return { ok: record.ok === true, message: text(record.message) }
}

/**
 * The sentence under "Runs on", mirroring `originWords` in the main process.
 *
 * Two spellings of one rule is how one of them ends up wrong, so this is the
 * one place the renderer turns origins into words — the panel never joins the
 * array itself.
 */
export function originWords(origins: readonly string[]): string {
  if (origins.length === 0) return 'nowhere'
  if (origins.includes('*')) return 'any page'
  return origins.join(', ')
}
