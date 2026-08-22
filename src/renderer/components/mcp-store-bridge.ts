/**
 * The renderer's half of the MCP store.
 *
 * Optional, every method, for the reason `browser/store-bridge.ts` gives about
 * its own: `McpInspector`'s `resolveBridge` refuses to resolve at all when one
 * of `BRIDGE_METHODS` is missing, which is right for the methods the page
 * cannot draw a pixel without and catastrophic for a new one. A preload older
 * than this feature must cost the page its **Store tab**, never the whole MCP
 * page — so the store's methods are looked up separately and their absence is a
 * missing tab rather than an empty window.
 *
 * The types are mirrors rather than imports, again for the reason the rest of
 * this folder gives: the renderer's tsconfig does not include `src/main`. Every
 * value that arrives is narrowed below rather than trusted, because a main
 * process one version behind sends a shape these types only promise.
 */

/** Mirrors `McpRuntime` in `src/main/mcp-catalogue.ts`. */
export type McpRuntime = 'node' | 'python' | 'docker'

/** Mirrors `McpInputKind`. */
export type McpInputKind = 'secret' | 'path' | 'text'

/** Mirrors `McpOrigin`. */
export type McpOrigin = 'reference' | 'reference-archived' | 'third-party'

/** Mirrors `McpStoreState` in `src/main/mcp-store.ts`. */
export type McpStoreState = 'available' | 'installed' | 'taken' | 'unavailable'

export type McpEnvironmentSource = 'login-shell' | 'process' | 'unavailable'

export interface McpStoreInput {
  key: string
  label: string
  hint: string
  kind: McpInputKind
  into: 'env' | 'arg'
  required: boolean
  inEnvironment: boolean
}

export interface McpStoreRow {
  id: string
  name: string
  summary: string
  homepage: string
  registry: string
  licence: string
  version: string
  runtime: McpRuntime
  runtimeBinary: string
  origin: McpOrigin
  command: string
  inputs: McpStoreInput[]
  state: McpStoreState
  scope: '' | 'user' | 'project' | 'local'
  taken: string
  blocked: string
  caveat: string
}

export interface McpRuntimeReport {
  id: McpRuntime
  binary: string
  found: boolean
  path: string
  needs: string
}

export interface McpStoreView {
  rows: McpStoreRow[]
  runtimes: McpRuntimeReport[]
  writer: { found: boolean; path: string }
  environmentSource: McpEnvironmentSource
  projectPath: string
}

export interface McpStoreResult {
  ok: boolean
  message: string
}

export interface McpStoreApi {
  mcpStore?(projectPath?: string | null): Promise<unknown>
  mcpStoreInstall?(request: unknown): Promise<unknown>
  /**
   * The removal, which is the page's own — see the note in `src/preload`. It is
   * named here because the store's rows carry a Remove and a bridge that could
   * list and install but not remove would be the half a control panel the MCP
   * page was already criticised for being.
   */
  removeMcpServer?(request: unknown): Promise<unknown>
  /**
   * The whole-server write, which is what “Add your own” goes through.
   *
   * Not `mcpStoreInstall`: that channel installs a *catalogue row by id* and
   * would refuse a hand-written command, which is the half of this store Asad
   * called the point — *"they can just click and attach their own things"*. One
   * write path per kind of thing being written, and both are named here so the
   * tab is only offered when both exist.
   */
  addMcpServer?(request: unknown): Promise<unknown>
}

const METHODS = [
  'mcpStore',
  'mcpStoreInstall',
  'removeMcpServer',
  'addMcpServer',
] as const satisfies readonly (keyof McpStoreApi)[]

export function resolveMcpStoreApi(host?: unknown): McpStoreApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as McpStoreApi
}

/**
 * Is the store wired in this build?
 *
 * All four, the same bar `storeAvailable` sets next door and for the same
 * reason: a store with a list and no Install is a catalogue of things you cannot
 * have, one with an Install and no Remove is a one-way door, and one that cannot
 * take a server you typed yourself is a walled garden. Any of those is worse
 * than the tab not being there.
 */
export function mcpStoreAvailable(api: McpStoreApi): boolean {
  return METHODS.every((name) => typeof api[name] === 'function')
}

/* --------------------------------------------------------------- reading -- */

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function flag(value: unknown): boolean {
  return value === true
}

const KINDS: readonly McpInputKind[] = ['secret', 'path', 'text']
const STATES: readonly McpStoreState[] = ['available', 'installed', 'taken', 'unavailable']
const ORIGINS: readonly McpOrigin[] = ['reference', 'reference-archived', 'third-party']
const RUNTIMES: readonly McpRuntime[] = ['node', 'python', 'docker']
const SOURCES: readonly McpEnvironmentSource[] = ['login-shell', 'process', 'unavailable']

function oneOf<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return allowed.find((candidate) => candidate === value) ?? fallback
}

function readInput(raw: unknown): McpStoreInput | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const key = text(record.key)
  if (key === '') return null
  const into = record.into === 'arg' ? 'arg' : 'env'
  return {
    key,
    label: text(record.label) || key,
    hint: text(record.hint),
    kind: oneOf(record.kind, KINDS, 'text'),
    into,
    required: flag(record.required),
    // Belt and braces on top of the main process's own rule: an `arg` can never
    // be inherited, so a build that sent `true` for one would be offering a
    // choice that does nothing.
    inEnvironment: into === 'env' && flag(record.inEnvironment),
  }
}

function readRow(raw: unknown): McpStoreRow | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = text(record.id)
  if (id === '') return null
  const scope = record.scope
  return {
    id,
    name: text(record.name) || id,
    summary: text(record.summary),
    homepage: text(record.homepage),
    registry: text(record.registry),
    licence: text(record.licence),
    version: text(record.version),
    runtime: oneOf(record.runtime, RUNTIMES, 'node'),
    runtimeBinary: text(record.runtimeBinary),
    origin: oneOf(record.origin, ORIGINS, 'third-party'),
    command: text(record.command),
    inputs: Array.isArray(record.inputs)
      ? record.inputs.map(readInput).filter((one): one is McpStoreInput => one !== null)
      : [],
    state: oneOf(record.state, STATES, 'available'),
    scope: scope === 'user' || scope === 'project' || scope === 'local' ? scope : '',
    taken: text(record.taken),
    blocked: text(record.blocked),
    caveat: text(record.caveat),
  }
}

function readRuntime(raw: unknown): McpRuntimeReport | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = RUNTIMES.find((candidate) => candidate === record.id)
  if (id === undefined) return null
  return {
    id,
    binary: text(record.binary),
    found: flag(record.found),
    path: text(record.path),
    needs: text(record.needs),
  }
}

export const EMPTY_STORE_VIEW: McpStoreView = {
  rows: [],
  runtimes: [],
  writer: { found: false, path: '' },
  environmentSource: 'unavailable',
  projectPath: '',
}

export function readMcpStoreView(raw: unknown): McpStoreView {
  if (typeof raw !== 'object' || raw === null) return EMPTY_STORE_VIEW
  const record = raw as Record<string, unknown>
  const writer =
    typeof record.writer === 'object' && record.writer !== null
      ? (record.writer as Record<string, unknown>)
      : {}
  return {
    rows: Array.isArray(record.rows)
      ? record.rows.map(readRow).filter((one): one is McpStoreRow => one !== null)
      : [],
    runtimes: Array.isArray(record.runtimes)
      ? record.runtimes.map(readRuntime).filter((one): one is McpRuntimeReport => one !== null)
      : [],
    writer: { found: flag(writer.found), path: text(writer.path) },
    environmentSource: oneOf(record.environmentSource, SOURCES, 'unavailable'),
    projectPath: text(record.projectPath),
  }
}

/**
 * A result, narrowed.
 *
 * A shape that is not a result is a failure with the honest sentence, never a
 * silent success: `ok` defaulting to true would turn a main process that threw
 * into a green message over a thing that did not happen.
 */
export function readMcpStoreResult(raw: unknown): McpStoreResult {
  if (typeof raw !== 'object' || raw === null) return { ok: false, message: 'That did not work.' }
  const record = raw as Record<string, unknown>
  const message = text(record.message)
  const ok = record.ok === true
  return { ok, message: message === '' ? (ok ? 'Done.' : 'That did not work.') : message }
}

/* ---------------------------------------------------------------- words -- */

/** What each origin means, in a phrase, on the row. */
export const ORIGIN_WORDS: Readonly<Record<McpOrigin, string>> = {
  reference: 'Reference server',
  'reference-archived': 'Archived reference server',
  'third-party': 'Third party',
}

/** How each runtime fetches and starts the server, on the row. */
export const RUNTIME_WORDS: Readonly<Record<McpRuntime, string>> = {
  node: 'npx — fetched from npm the first time it runs',
  python: 'uvx — fetched from PyPI the first time it runs',
  docker: 'docker — pulled as a container image',
}

/**
 * What a row needs, in one phrase, before anything is pressed.
 *
 * Pure and exported because it is the sentence the section list is sorted and
 * filtered by, and *"a row that cannot work without one says so BEFORE install
 * rather than failing after"* is the whole requirement. Deriving it in JSX would
 * put that promise in a place no test can reach.
 */
export function needsWords(row: McpStoreRow): string {
  const required = row.inputs.filter((input) => input.required)
  if (required.length === 0) return row.inputs.length === 0 ? 'Nothing' : 'Nothing required'
  // The labels' own case, not lowered. This phrase and the "Needs …" line under
  // the button name the same fields, and two spellings of one field on one row
  // reads as two different things.
  return required.map((input) => input.label).join(', ')
}

/**
 * Which fields still have to be filled before Install can do anything.
 *
 * The button is disabled on this and the row names them, rather than the press
 * going to the main process to be refused there. Both ends check — the main
 * process must, because a bridge is not a boundary you trust — but a user
 * should never be the one to discover it.
 */
export function unfilled(row: McpStoreRow, values: Record<string, string>): string[] {
  return row.inputs
    .filter((input) => input.required)
    .filter((input) => (values[input.key] ?? '').trim() === '' && !input.inEnvironment)
    .map((input) => input.label)
}
