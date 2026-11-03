/**
 * The renderer's half of browser downloads.
 *
 * Optional, every method of it, and for the reason `accounts-bridge.ts` states
 * at length: `bridge.ts` refuses to resolve at all when one of `BRIDGE_METHODS`
 * is missing, which is right for the methods the panel cannot draw a pixel
 * without and catastrophic for a new one. A preload older than this feature must
 * cost the browser its downloads list, never the whole browser.
 *
 * The types are mirrors rather than imports, again for the reason `bridge.ts`
 * gives: the renderer's tsconfig does not include `src/main`. Each one names the
 * module it mirrors, and every value that arrives is narrowed below rather than
 * trusted — the discipline every `unknown` on this side gets, and what makes an
 * older or newer main process a quiet no-op instead of a crash inside an effect.
 */

/** Mirrors `DownloadState` in `src/main/browser-downloads.ts`. */
export type DownloadState = 'downloading' | 'delivering' | 'done' | 'cancelled' | 'failed'

/** Mirrors `DownloadRow` in `src/main/browser-downloads.ts`. */
export interface DownloadRow {
  id: string
  name: string
  url: string
  bytes: number
  received: number
  state: DownloadState
  path: string
  onMachine: string
  onMachineName: string
  message: string
  startedAt: number
}

/** Mirrors `DownloadDestination` in `src/main/browser-downloads.ts`. */
export interface DownloadDestination {
  machineId: string
  machineName: string
  folder: string
}

/** Mirrors `DownloadsView` in `src/main/browser-downloads.ts`. */
export interface DownloadsView {
  destination: DownloadDestination
  /** This machine's own downloads folder, absolute. Named on the destination line. */
  defaultFolder: string
  items: DownloadRow[]
}

/** Mirrors the `{ ok, message }` an open or a reveal answers with. */
export interface DownloadAction {
  ok: boolean
  message: string
}

export interface DownloadsApi {
  browserDownloads?(): Promise<unknown>
  browserDownloadDestination?(destination: DownloadDestination): Promise<unknown>
  browserDownloadCancel?(id: string): Promise<unknown>
  browserDownloadClear?(): Promise<unknown>
  browserDownloadOpen?(id: string): Promise<unknown>
  browserDownloadReveal?(id: string): Promise<unknown>
  browserDownloadFolder?(): Promise<unknown>
  onBrowserDownloads?(cb: (view: unknown) => void): () => void
}

const METHODS = [
  'browserDownloads',
  'browserDownloadDestination',
  'browserDownloadCancel',
  'browserDownloadClear',
  'browserDownloadOpen',
  'browserDownloadReveal',
  'browserDownloadFolder',
  'onBrowserDownloads',
] as const satisfies readonly (keyof DownloadsApi)[]

export function resolveDownloadsApi(host?: unknown): DownloadsApi {
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
  return api as DownloadsApi
}

/**
 * Is the feature wired in this build?
 *
 * The list and the push, and nothing else. Those two are what a downloads entry
 * *is*: without them there is no list to draw and the row would never move. The
 * four verbs degrade one control each — an Open that is missing takes its own
 * button off the row — and the honest way to handle a half-wired preload is to
 * lose the control rather than the panel. A menu row that opens a panel which
 * cannot list anything is exactly the shape of half-feature this review is
 * about, which is why the two reads are the bar and the rest are not.
 */
export function downloadsAvailable(api: DownloadsApi): boolean {
  return typeof api.browserDownloads === 'function' && typeof api.onBrowserDownloads === 'function'
}

/* ---------------------------------------------------------------- reading -- */

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

function count(raw: unknown): number {
  return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : 0
}

function readState(raw: unknown): DownloadState {
  return raw === 'downloading' ||
    raw === 'delivering' ||
    raw === 'done' ||
    raw === 'cancelled' ||
    raw === 'failed'
    ? raw
    : 'failed'
}

/**
 * A view off the wire, narrowed into one that is always drawable.
 *
 * A row with no id is dropped rather than drawn with a blank one: every control
 * on a row sends that id back, so a row without one is a row whose buttons could
 * only ever do nothing.
 */
export function readDownloadsView(raw: unknown): DownloadsView {
  const empty: DownloadsView = {
    destination: { machineId: '', machineName: '', folder: '' },
    defaultFolder: '',
    items: [],
  }
  if (typeof raw !== 'object' || raw === null) return empty
  const value = raw as Record<string, unknown>

  const destination =
    typeof value.destination === 'object' && value.destination !== null
      ? (value.destination as Record<string, unknown>)
      : {}

  const list = Array.isArray(value.items) ? value.items : []
  const items: DownloadRow[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const id = text(record.id)
    if (id === '') continue
    items.push({
      id,
      name: text(record.name),
      url: text(record.url),
      bytes: count(record.bytes),
      received: count(record.received),
      state: readState(record.state),
      path: text(record.path),
      onMachine: text(record.onMachine),
      onMachineName: text(record.onMachineName),
      message: text(record.message),
      startedAt: count(record.startedAt),
    })
  }

  return {
    destination: {
      machineId: text(destination.machineId),
      machineName: text(destination.machineName),
      folder: text(destination.folder),
    },
    defaultFolder: text(value.defaultFolder),
    items,
  }
}

/** An `{ ok, message }`, narrowed. An answer that is not one reads as a refusal. */
export function readAction(raw: unknown): DownloadAction {
  if (typeof raw !== 'object' || raw === null) return { ok: false, message: 'That did not work.' }
  const value = raw as Record<string, unknown>
  return { ok: value.ok === true, message: text(value.message) }
}

/* ---------------------------------------------------------------- drawing -- */

/**
 * What the indicator on the toolbar has to say, or null for "say nothing".
 *
 * Null is a real answer and it is the common one: Chrome's downloads button is
 * absent until there is a download and this is the same rule, because a
 * permanently-lit control that is empty nine days in ten teaches people to stop
 * looking at it. The menu row is the standing door; this is the thing that
 * appears when something happened.
 *
 * Pure, so the rule can be pinned — an indicator that failed to appear is a
 * download that vanished silently, which is the one outcome this whole feature
 * exists to prevent.
 */
export function downloadsBadge(
  items: readonly DownloadRow[],
): { label: string; tone: 'busy' | 'bad' | 'done' } | null {
  const moving = items.filter((row) => row.state === 'downloading' || row.state === 'delivering')
  if (moving.length > 0) {
    return { label: moving.length === 1 ? '1' : String(moving.length), tone: 'busy' }
  }
  if (items.length === 0) return null
  const newest = items[0]
  if (newest.state === 'failed') return { label: '!', tone: 'bad' }
  return { label: String(items.length), tone: 'done' }
}

/**
 * How far along one row is, as a fraction, or null when nothing can be said.
 *
 * Null rather than zero when the server sent no length: a bar sitting at 0%
 * while a file is arriving is a bar reporting a stall that is not happening.
 * The row prints the bytes it has instead, which is the true statement available.
 */
export function downloadProgress(row: DownloadRow): number | null {
  if (row.state !== 'downloading') return null
  if (row.bytes <= 0) return null
  return Math.min(1, row.received / row.bytes)
}

/**
 * The one line under a row's name.
 *
 * One line, because *"I don't want any kind of long descriptions anywhere"*, and
 * always present, because a row that says nothing about where a file went is the
 * defect rather than a tidy row. Every branch names a place or a reason; none of
 * them names both, and none is a sentence about something the person can see.
 */
export function downloadLine(row: DownloadRow, hereName: string): string {
  const machine = row.onMachine === '' ? hereName : row.onMachineName || 'another machine'
  switch (row.state) {
    case 'downloading':
      return row.bytes > 0 ? `${bytesLine(row.received)} of ${bytesLine(row.bytes)}` : bytesLine(row.received)
    case 'delivering':
      return `Moving to ${row.onMachineName || 'the chosen machine'}`
    case 'cancelled':
      return row.message || 'Stopped'
    case 'failed':
      return row.message || 'That did not finish'
    default:
      return machine === '' ? row.path : `${machine} · ${row.path}`
  }
}

/**
 * Bytes as somebody reads them.
 *
 * A local copy rather than `shared/byte-size.ts` would be a second vocabulary
 * for the same number, so this is a thin wrapper on the one that exists and is
 * here only to keep the null case out of the component.
 */
function bytesLine(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`
}

/**
 * What a machine with no folder chosen does with a file, in its own words.
 *
 * The two are genuinely different places and saying either about the other
 * would be wrong. A paired desktop puts it in `<downloads>/Terminal Deck` —
 * `uploadsDir` in `main/index.ts`. A **server** has no such folder and never
 * had one: an ssh connection carries no `welcome`, so an empty folder is
 * resolved by the server's own `realpath('.')`, which is wherever that sign-in
 * lands. `ServerFolderPicker.DEFAULT_FOLDER` says the same sentence about the
 * same fact, one panel over.
 */
export const REMOTE_DEFAULT_FOLDER = 'its downloads folder'
export const SERVER_DEFAULT_FOLDER = 'wherever the sign-in lands'

/**
 * What the destination line reads, given the destination and this machine's name.
 *
 * `hereName` rather than "This machine", because that phrase was the whole of
 * *"I don't know what to trust"* — see `hereName` in `machines/types.ts`. It
 * falls back to the phrase only when there is no name to use, and never to an
 * invented one.
 *
 * `elsewhereDefault` is what the chosen machine does with a file when no folder
 * was named, and it is a parameter rather than a constant because the two kinds
 * of machine do different things — see the two above.
 */
export function destinationLine(
  destination: DownloadDestination,
  hereName: string,
  defaultFolder: string,
  elsewhereDefault: string = REMOTE_DEFAULT_FOLDER,
): string {
  const machine =
    destination.machineId === ''
      ? hereName || 'This machine'
      : destination.machineName || 'the chosen machine'
  const folder =
    destination.folder !== ''
      ? destination.folder
      : destination.machineId === ''
        ? defaultFolder || REMOTE_DEFAULT_FOLDER
        : elsewhereDefault
  return `${machine} · ${folder}`
}
