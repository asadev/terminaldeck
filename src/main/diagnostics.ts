/**
 * Diagnostics — the support bundle, and the instrumentation the Debug panel
 * reads.
 *
 * The bundle answers the questions that get asked when something is wrong and
 * the person who can see the screen is not the person who can read the code:
 * what version is this, what did it detect, where does it keep its files, which
 * parts of the app actually wired themselves up, and what did the log say just
 * before it went wrong.
 *
 * Everything it returns has been through `redact`. That is the whole contract:
 * a bundle is written to be pasted somewhere public, so a leak here is worse
 * than having no bundle at all. Nothing in this module returns raw text.
 *
 * Two deliberate omissions:
 *
 *  - IPC *arguments* are never recorded. A call log is useful because of what
 *    was called and how long it took; the arguments are where the file
 *    contents, prompts and tokens are, and a debug panel that shows them is a
 *    leak with a nice table around it.
 *  - Environment variables are reported by name, never by value, except for a
 *    short allowlist (PATH, SHELL, TERM…) that carries no secrets and answers
 *    the single most common support question this app has.
 */

import { arch, freemem, platform, release, totalmem, type as osType } from 'node:os'
import { delimiter, join } from 'node:path'
import { app, type IpcMain, type IpcMainEvent, type IpcMainInvokeEvent, type WebContents } from 'electron'
import { BRAND } from '../shared/brand'
import { appLog, logger } from './app-log'
import { currentPlatform, isWindows, type Env, type Platform } from './platform/host'
import { checkPrerequisites, type ToolState } from './prerequisites'
import { loginPath } from './providers'
import { store } from './store'
import {
  redact,
  redactValue,
  redactWithCount,
  secretEnvNames,
  secretsFromEnv,
  type RedactOptions,
} from './redact'

export { redact, redactLines, redactValue, redactWithCount, looksSecret, entropy } from './redact'

/* ------------------------------------------------------------------ types -- */

export interface AboutInfo {
  name: string
  tagline: string
  version: string
  electron: string
  chrome: string
  node: string
  v8: string
  platform: string
  arch: string
  packaged: boolean
}

export interface CliInfo {
  id: string
  label: string
  state: ToolState
  version?: string
}

export interface IpcModuleInfo {
  /** Channel prefix — `git`, `cost`, `session`. */
  name: string
  channels: string[]
}

export interface IpcInfo {
  modules: IpcModuleInfo[]
  invokeChannels: number
  sendChannels: number
  /** False when timings are unavailable — see `instrumentIpc`. */
  instrumented: boolean
}

export interface DiagnosticsBundle {
  generatedAt: number
  app: AboutInfo & { locale: string; uptimeSeconds: number }
  system: {
    os: string
    release: string
    arch: string
    memoryTotalMb: number
    memoryFreeMb: number
    processRssMb: number
  }
  clis: CliInfo[]
  ipc: IpcInfo
  paths: Record<string, string>
  preferences: Record<string, unknown>
  environment: {
    path: string[]
    shell: string
    term: string
    lang: string
    /** Names only. Never values. */
    secretsPresent: string[]
  }
  log: {
    file: string
    bytes: number
    lines: string[]
  }
  redaction: {
    /** How many substitutions were made across the whole bundle. */
    count: number
  }
}

export interface IpcCallRecord {
  seq: number
  channel: string
  kind: 'invoke' | 'send'
  at: number
  /** Milliseconds, one decimal place. */
  ms: number
  ok: boolean
  /** Redacted and truncated. */
  error?: string
}

/* ------------------------------------------------------- ipc introspection -- */

/**
 * Electron's invoke handlers, read off the internal map.
 *
 * `ipcMain` exposes no way to ask what has been registered, and "which modules
 * wired themselves up" is one of the more useful things a bundle can say —
 * a panel that is silently dead because its `registerXIpc` was never called
 * looks identical to one with no data. Verified against the Electron 41.10.5
 * binary in this repo: `IpcMainImpl` holds `_invokeHandlers` as a `Map`.
 *
 * Guarded on every access, so a future Electron that renames it degrades to
 * "no invoke channels listed" instead of throwing inside a support tool.
 */
function invokeHandlers(ipcMain: IpcMain): Map<string, unknown> | null {
  const internal = (ipcMain as unknown as { _invokeHandlers?: unknown })._invokeHandlers
  return internal instanceof Map ? (internal as Map<string, unknown>) : null
}

/** Channels registered with `ipcMain.on`, from the public EventEmitter API. */
function sendChannels(ipcMain: IpcMain): string[] {
  try {
    return ipcMain
      .eventNames()
      .filter((name): name is string => typeof name === 'string')
      .filter((name) => name !== 'error')
  } catch {
    return []
  }
}

/** Group `git:status`, `git:diff` under `git`. */
export function groupChannels(channels: readonly string[]): IpcModuleInfo[] {
  const modules = new Map<string, string[]>()
  for (const channel of [...channels].sort()) {
    const name = channel.includes(':') ? channel.slice(0, channel.indexOf(':')) : 'app'
    const list = modules.get(name) ?? []
    list.push(channel)
    modules.set(name, list)
  }
  return [...modules.entries()]
    .map(([name, list]) => ({ name, channels: list }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

export function ipcInfo(ipcMain: IpcMain): IpcInfo {
  const handlers = invokeHandlers(ipcMain)
  const invoke = handlers ? [...handlers.keys()] : [...recordedChannels]
  const send = sendChannels(ipcMain)
  return {
    modules: groupChannels([...new Set([...invoke, ...send])]),
    invokeChannels: invoke.length,
    sendChannels: send.length,
    instrumented,
  }
}

/* ------------------------------------------------------- ipc call logging -- */

const MAX_RECORDS = 500
const records: IpcCallRecord[] = []
const recordedChannels = new Set<string>()
const wrapped = new WeakSet<object>()
/**
 * Live subscribers, each mapped to the teardown for the `destroyed` listener
 * that removes it.
 *
 * A bare Set was not enough: `debug:unsubscribe` dropped the entry but left the
 * `once('destroyed')` handler attached, so every subscribe/unsubscribe cycle
 * added another one to the same WebContents. The Debug panel does exactly that
 * on each toggle of debug mode, and eleven toggles was enough for Node to start
 * printing MaxListenersExceededWarning.
 */
const subscribers = new Map<WebContents, () => void>()

function dropSubscriber(contents: WebContents): void {
  const release = subscribers.get(contents)
  subscribers.delete(contents)
  try {
    release?.()
  } catch {
    /* the window is already gone, which is the outcome we wanted */
  }
}
let instrumented = false
let sequence = 0

/**
 * Channels excluded from the call log.
 *
 * The Debug panel reads its own data over IPC, so recording those calls makes
 * the log describe itself — a feedback loop that pushes the real traffic out of
 * the ring buffer the moment the panel opens.
 */
function ignored(channel: string): boolean {
  return channel.startsWith('debug:') || channel === 'log:recent'
}

function push(record: IpcCallRecord): void {
  records.push(record)
  if (records.length > MAX_RECORDS) records.splice(0, records.length - MAX_RECORDS)
  for (const contents of [...subscribers.keys()]) {
    // `isDestroyed` is as capable of throwing as `send` is once the window is
    // gone, and it used to sit outside the guard — see `finish`.
    try {
      if (contents.isDestroyed()) {
        dropSubscriber(contents)
        continue
      }
      contents.send('debug:ipc-call', record)
    } catch {
      dropSubscriber(contents)
    }
  }
}

function errorText(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error)
  return redact(message).slice(0, 300)
}

function timed<T extends unknown[]>(
  channel: string,
  kind: 'invoke' | 'send',
  fn: (...args: T) => unknown,
): (...args: T) => unknown {
  const wrapper = (...args: T): unknown => {
    if (ignored(channel)) return fn(...args)
    const started = performance.now()
    /**
     * Wholly guarded, and that is the point.
     *
     * This runs on the success path of every wrapped handler — `finish(true)`
     * is called before the real return value is handed back — so anything that
     * throws in here converts a call that worked into a call that failed. A
     * destroyed subscriber or a full disk would have made every IPC channel in
     * the app start rejecting, which is a far worse bug than the one this
     * instrumentation exists to help diagnose.
     */
    const finish = (ok: boolean, error?: unknown): void => {
      try {
        sequence += 1
        const message = ok ? undefined : errorText(error)
        push({
          seq: sequence,
          channel,
          kind,
          at: Date.now(),
          ms: Math.round((performance.now() - started) * 10) / 10,
          ok,
          error: message,
        })
        // A failed IPC call is the single most useful thing a support bundle
        // can carry, and it is also the thing nobody thinks to write down. The
        // trace above only survives until the ring buffer wraps; the log
        // outlives the window.
        if (!ok) logger.error('ipc', `${channel} failed`, message)
      } catch {
        /* measuring a call must never be the reason it fails */
      }
    }
    try {
      const result = fn(...args)
      if (result instanceof Promise) {
        return result.then(
          (value) => {
            finish(true)
            return value
          },
          (error: unknown) => {
            finish(false, error)
            throw error
          },
        )
      }
      finish(true)
      return result
    } catch (error) {
      finish(false, error)
      throw error
    }
  }
  wrapped.add(wrapper)
  // How Node's own `once()` wrappers stay removable: `EventEmitter.removeListener`
  // compares against `listener.listener` as well as the listener itself. Without
  // this, wrapping `ipcMain.on` silently broke `ipcMain.off(channel, fn)` for
  // every caller — the registered function was the wrapper, so nothing matched
  // and the listener stayed attached for the life of the process.
  ;(wrapper as { listener?: unknown }).listener = fn
  return wrapper
}

/**
 * Wrap `ipcMain` so every call is timed.
 *
 * Handlers registered *before* this runs are re-wrapped in place through the
 * internal map, and `handle`/`on` are replaced so later registrations are
 * caught too. That combination is what makes the call log complete regardless
 * of where in `registerIpc()` this ends up — but registering diagnostics first
 * is still worth doing, because only the replacement path can time `on`
 * listeners.
 *
 * Idempotent: calling it twice does not double-count.
 */
export function instrumentIpc(ipcMain: IpcMain): boolean {
  if (instrumented) return true

  try {
    const handlers = invokeHandlers(ipcMain)
    if (handlers) {
      for (const [channel, handler] of handlers) {
        if (typeof handler !== 'function' || wrapped.has(handler)) continue
        recordedChannels.add(channel)
        const original = handler as (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown
        handlers.set(channel, timed(channel, 'invoke', original))
      }
    }

    // `handle` is an own arrow property on IpcMainImpl, so assigning over it
    // works; `handleOnce` calls through `this.handle` and is covered for free.
    const originalHandle = ipcMain.handle.bind(ipcMain)
    ipcMain.handle = ((channel: string, listener: (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown) => {
      recordedChannels.add(channel)
      originalHandle(channel, timed(channel, 'invoke', listener) as typeof listener)
    }) as IpcMain['handle']

    const originalOn = ipcMain.on.bind(ipcMain)
    ipcMain.on = ((channel: string, listener: (event: IpcMainEvent, ...args: unknown[]) => void) => {
      // `error` is Electron's own no-op listener, not a channel.
      if (channel === 'error') return originalOn(channel, listener)
      return originalOn(channel, timed(channel, 'send', listener) as typeof listener)
    }) as IpcMain['on']

    instrumented = true
    return true
  } catch {
    // Instrumentation is a convenience; the bundle and the log still work.
    instrumented = false
    return false
  }
}

/** Most recent calls, newest last. */
export function recentIpcCalls(limit = MAX_RECORDS): IpcCallRecord[] {
  return records.slice(-Math.max(1, limit))
}

export function clearIpcCalls(): void {
  records.length = 0
}

/* ----------------------------------------------------------------- bundle -- */

export function aboutInfo(): AboutInfo {
  return {
    name: BRAND.name,
    tagline: BRAND.tagline,
    version: safe(() => app.getVersion(), '0.0.0'),
    electron: process.versions.electron ?? 'n/a',
    chrome: process.versions.chrome ?? 'n/a',
    node: process.versions.node,
    v8: process.versions.v8,
    platform: platform(),
    arch: arch(),
    packaged: safe(() => app.isPackaged, false),
  }
}

function safe<T>(read: () => T, fallback: T): T {
  try {
    return read()
  } catch {
    return fallback
  }
}

function mb(bytes: number): number {
  return Math.round(bytes / (1024 * 1024))
}

/* -------------------------------------------------------- environment -- */

/**
 * PATH as a list, split on the separator *this* platform uses.
 *
 * This was a literal `':'`, which is the one character a Windows PATH is
 * guaranteed to contain and the one it never separates on. Every entry carries
 * a drive letter, so `C:\Program Files\nodejs;C:\Windows\system32` came out as
 * `['C', '\Program Files\nodejs;C', '\Windows\system32']` — three fragments,
 * none of them a directory. The PATH list is what somebody pastes into an issue
 * when the app cannot find their CLI, so it was garbage on the single platform
 * where anyone would need to read it.
 *
 * The delimiter is a parameter with `path.delimiter` as its default so a test on
 * a Mac can pin the Windows answer; see `platform/host.ts` on why this codebase
 * passes the platform in rather than branching on it.
 */
export function pathEntries(rawPath: string, separator: string = delimiter): string[] {
  return rawPath.split(separator).filter(Boolean)
}

/**
 * What to report as "the shell", which is not a question Windows has an answer
 * to.
 *
 * `process.env.SHELL` is a POSIX variable; Windows does not set it, so this line
 * read `shell: ` with nothing after it on every Windows bundle. That is not a
 * missing value — there is genuinely no login shell there, which is exactly why
 * `platform/lookup.ts` returns `null` for the login-PATH command — so reporting
 * an empty string invites the reader to go looking for a setting that does not
 * exist. What Windows does have, and what this app actually spawns for a shell
 * tab, is the command processor named by `%COMSPEC%`, so the bundle names that
 * and says what it is.
 */
export function shellName(env: Env, host: Platform): string {
  if (!isWindows(host)) return env.SHELL ?? ''
  return `${env.COMSPEC ?? 'cmd.exe'} (COMSPEC — Windows has no login shell)`
}

export interface CollectOptions {
  /** Needed for the registered-channel list. */
  ipcMain?: IpcMain
  /** Lines of log tail to include. */
  logLines?: number
  /**
   * Probing the agent CLIs shells out and can take a couple of seconds; the
   * Debug panel wants it, a fast refresh does not.
   */
  includeClis?: boolean
  redaction?: RedactOptions
}

/**
 * Collect everything, redact it, and report how much was redacted.
 *
 * The redaction options pick up any secret-looking environment values, so a
 * token that is live in this process is stripped from the bundle even when it
 * looks like nothing at all.
 */
export async function collectDiagnostics(options: CollectOptions = {}): Promise<DiagnosticsBundle> {
  const redaction: RedactOptions = {
    ...options.redaction,
    extraSecrets: [...secretsFromEnv(), ...(options.redaction?.extraSecrets ?? [])],
  }

  let count = 0
  // Substitutions, not "strings that changed". The bundle prints this number as
  // a claim about itself — a line that redacted four secrets used to count as
  // one, which understates exactly where it matters most.
  const clean = (value: string): string => {
    const result = redactWithCount(value, redaction)
    count += result.count
    return result.text
  }

  const about = aboutInfo()
  const log = appLog()
  const status = safe(() => log.status(), { dir: '', file: '', bytes: 0, files: [], maxBytes: 0, keep: 0 })

  const clis: CliInfo[] = options.includeClis === false ? [] : await collectClis()
  const rawPath = await safeLoginPath()

  const userData = safe(() => app.getPath('userData'), '')
  const paths: Record<string, string> = {
    userData,
    logs: status.dir,
    state: userData ? join(userData, 'state.json') : '',
    temp: safe(() => app.getPath('temp'), ''),
    home: safe(() => app.getPath('home'), ''),
    appPath: safe(() => app.getAppPath(), ''),
    exe: safe(() => app.getPath('exe'), ''),
  }

  const preferences = safe(
    () => redactValue(store().getPreferences() as unknown as Record<string, unknown>, redaction),
    {} as Record<string, unknown>,
  )

  const bundle: DiagnosticsBundle = {
    generatedAt: Date.now(),
    app: {
      ...about,
      locale: safe(() => app.getLocale(), 'unknown'),
      uptimeSeconds: Math.round(process.uptime()),
    },
    system: {
      os: osType(),
      release: release(),
      arch: arch(),
      memoryTotalMb: mb(totalmem()),
      memoryFreeMb: mb(freemem()),
      processRssMb: mb(process.memoryUsage().rss),
    },
    clis: clis.map((cli) => ({ ...cli, version: cli.version ? clean(cli.version) : undefined })),
    ipc: options.ipcMain
      ? ipcInfo(options.ipcMain)
      : { modules: [], invokeChannels: 0, sendChannels: 0, instrumented },
    paths: Object.fromEntries(Object.entries(paths).map(([key, value]) => [key, clean(value)])),
    preferences,
    environment: {
      // Split, because the answer to "why can it not find my CLI" is read one
      // entry at a time and a single 900-character line is unreadable.
      path: pathEntries(rawPath).map(clean),
      shell: clean(shellName(process.env, currentPlatform())),
      term: process.env.TERM ?? '',
      lang: process.env.LANG ?? '',
      secretsPresent: secretEnvNames(),
    },
    log: {
      file: clean(status.file),
      bytes: status.bytes,
      lines: safe(() => log.tail(options.logLines ?? 200), []).map(clean),
    },
    redaction: { count: 0 },
  }

  bundle.redaction.count = count
  return bundle
}

async function collectClis(): Promise<CliInfo[]> {
  try {
    const prereq = await checkPrerequisites()
    return prereq.tools.map((tool) => ({
      id: tool.id,
      label: tool.label,
      state: tool.state,
      version: tool.version,
    }))
  } catch {
    return []
  }
}

async function safeLoginPath(): Promise<string> {
  try {
    return await loginPath()
  } catch {
    return process.env.PATH ?? ''
  }
}

/* ---------------------------------------------------------------- format -- */

const CLI_STATE_LABEL: Record<ToolState, string> = {
  ready: 'ready',
  'installed-not-authed': 'installed, not signed in',
  missing: 'not found',
  unknown: 'unknown',
}

function preferenceText(value: unknown): string {
  if (value === null || typeof value !== 'object') return String(value)
  try {
    return JSON.stringify(value) ?? String(value)
  } catch {
    return '[unserialisable]'
  }
}

/**
 * The bundle as text, formatted in the main process so there is exactly one
 * copy of this layout — the renderer's copy button sends this string straight
 * to the clipboard.
 */
export function formatDiagnostics(bundle: DiagnosticsBundle): string {
  const lines: string[] = []
  const section = (title: string): void => {
    lines.push('', `## ${title}`)
  }
  const row = (label: string, value: string | number | boolean): void => {
    lines.push(`- ${label}: ${value}`)
  }

  lines.push(`# ${bundle.app.name} diagnostics`)
  lines.push(`Generated ${new Date(bundle.generatedAt).toISOString()}`)
  lines.push(
    `All values below were passed through redaction (${bundle.redaction.count} substitutions).`,
  )

  section('App')
  row('version', bundle.app.version)
  row('packaged', bundle.app.packaged)
  row('locale', bundle.app.locale)
  row('uptime', `${bundle.app.uptimeSeconds}s`)

  section('Runtime')
  row('electron', bundle.app.electron)
  row('chrome', bundle.app.chrome)
  row('node', bundle.app.node)
  row('v8', bundle.app.v8)
  row('os', `${bundle.system.os} ${bundle.system.release} (${bundle.system.arch})`)
  row('memory', `${bundle.system.memoryFreeMb} MB free of ${bundle.system.memoryTotalMb} MB`)
  row('process rss', `${bundle.system.processRssMb} MB`)

  section('Agent CLIs')
  if (bundle.clis.length === 0) lines.push('- not probed')
  for (const cli of bundle.clis) {
    row(cli.label, `${CLI_STATE_LABEL[cli.state]}${cli.version ? ` — ${cli.version}` : ''}`)
  }

  section('IPC')
  row('instrumented', bundle.ipc.instrumented)
  row('invoke channels', bundle.ipc.invokeChannels)
  row('send channels', bundle.ipc.sendChannels)
  for (const module of bundle.ipc.modules) {
    row(module.name, `${module.channels.length} channel${module.channels.length === 1 ? '' : 's'}`)
  }

  section('Paths')
  for (const [key, value] of Object.entries(bundle.paths)) row(key, value)

  section('Preferences')
  // `String(value)` renders every nested preference as `[object Object]`, which
  // is the one shape guaranteed to answer no question anybody had.
  for (const [key, value] of Object.entries(bundle.preferences)) row(key, preferenceText(value))

  section('Environment')
  row('shell', bundle.environment.shell)
  row('term', bundle.environment.term || 'unset')
  row('lang', bundle.environment.lang || 'unset')
  row(
    'secret-looking vars set',
    bundle.environment.secretsPresent.length > 0
      ? bundle.environment.secretsPresent.join(', ')
      : 'none',
  )
  lines.push('- PATH:')
  for (const entry of bundle.environment.path) lines.push(`  - ${entry}`)

  section(`Log (${bundle.log.file}, ${bundle.log.bytes} bytes)`)
  lines.push('```')
  lines.push(...(bundle.log.lines.length > 0 ? bundle.log.lines : ['(empty)']))
  lines.push('```')

  return lines.join('\n')
}

/* -------------------------------------------------------------------- ipc -- */

/** Log lines a caller may ask the bundle to carry. */
const MIN_LOG_LINES = 1
const MAX_LOG_LINES = 2000
const DEFAULT_LOG_LINES = 200

/**
 * Narrow whatever the renderer sent down to the two fields the bundle accepts.
 *
 * The previous form spread the raw argument into `CollectOptions`, which meant
 * the caller could set `redaction` — the very thing that makes a bundle safe to
 * paste — or replace `ipcMain`. Nothing legitimate did, but a support tool is
 * the wrong place to trust an argument, and an out-of-range `logLines` was
 * enough on its own to pull the whole log into the bundle instead of 200 lines.
 */
function requestOptions(raw: unknown): { includeClis: boolean; logLines: number } {
  const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
  // `Number(null)` is 0, not NaN, so an explicit null has to be caught here or
  // "no opinion" would clamp to a single line.
  const asked = input.logLines === undefined || input.logLines === null ? Number.NaN : Number(input.logLines)
  const logLines = Number.isFinite(asked)
    ? Math.min(Math.max(Math.floor(asked), MIN_LOG_LINES), MAX_LOG_LINES)
    : DEFAULT_LOG_LINES
  return { includeClis: input.includeClis !== false, logLines }
}

export function registerDiagnosticsIpc(ipcMain: IpcMain): void {
  // Self-instrumenting, so the call log is populated even when this module is
  // wired last. Registering it first is still better — see `instrumentIpc`.
  instrumentIpc(ipcMain)

  ipcMain.handle('debug:about', () => aboutInfo())

  ipcMain.handle('debug:diagnostics', async (_event, options?: unknown) =>
    collectDiagnostics({ ipcMain, ...requestOptions(options) }),
  )

  ipcMain.handle('debug:diagnostics-text', async (_event, options?: unknown) =>
    formatDiagnostics(await collectDiagnostics({ ipcMain, ...requestOptions(options) })),
  )

  ipcMain.handle('debug:ipc-log', (_event, limit?: number) => recentIpcCalls(Number(limit) || MAX_RECORDS))

  ipcMain.handle('debug:ipc-clear', () => {
    clearIpcCalls()
  })

  /** Live call events, pushed to whoever asked. */
  ipcMain.handle('debug:subscribe', (event: IpcMainInvokeEvent) => {
    const contents = event.sender
    if (subscribers.has(contents)) return true
    // A reloaded window would otherwise leave a dead WebContents behind, and
    // every send to it throws. The teardown is kept so unsubscribing detaches
    // this listener too, rather than leaving one behind per subscribe.
    const onDestroyed = (): void => {
      subscribers.delete(contents)
    }
    subscribers.set(contents, () => contents.removeListener('destroyed', onDestroyed))
    contents.once('destroyed', onDestroyed)
    return true
  })

  ipcMain.handle('debug:unsubscribe', (event: IpcMainInvokeEvent) => {
    dropSubscriber(event.sender)
  })
}
