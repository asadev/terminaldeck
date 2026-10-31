import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { unlink } from 'node:fs/promises'
import { dirname, isAbsolute, join } from 'node:path'
import { BRAND } from '../shared/brand'
import { digestFile } from './browser-asset-digest'
import { freeDownloadPath } from './browser-download-names'

/**
 * The download ledger, without a transport under it.
 *
 * ## What this is, and why it is split out of `browser-downloads.ts`
 *
 * A download begins two different ways now. On the desktop Chromium hands
 * Electron a `DownloadItem` through a session's `will-download` event, and
 * `browser-downloads-electron.ts` drives it. On the headless server there is no
 * Electron and no `DownloadItem`; the same file arrives as a
 * `Browser.downloadWillBegin` / `Browser.downloadProgress` pair over CDP, and
 * `browser-downloads-cdp.ts` drives that. Both arrive at the *same* ledger — the
 * rows a person reads, the dedup that stops two `report.pdf`s writing over each
 * other, the digest a resume keys on, and the move-to-another-machine logic —
 * and that ledger is this file.
 *
 * The split is the same one the whole wave-2 seam is: everything that can run
 * with nothing but `node:fs` lives here, and the two things that cannot (an
 * Electron `Session`, a CDP channel) live behind it. So this module has **no
 * Electron import** and `src/headless/seam.test.ts` walks it clean — it is the
 * half of downloads the server can carry.
 *
 * Every sentence of the original module's reasoning is preserved where the code
 * it explains lives: the states nobody wants each get a row, a delivery to
 * another machine is a *move* (fetch here, hand over, then delete — his own
 * words), the destination is one setting rather than a question per file, and the
 * digest is computed at the one place a file lands from a socket. See
 * `browser-downloads-electron.ts` for the `will-download` binding and the folder
 * chooser, and `browser-downloads-cdp.ts` for the CDP path.
 */

/* ------------------------------------------------------------------ shape -- */

/**
 * Where downloads are being put.
 *
 * `machineId` empty means this computer, which is the same spelling
 * `session-transfer.ts` uses for "runs here" and is deliberately not a separate
 * boolean — one of the two ways of saying it would eventually disagree with the
 * other. `folder` empty means the caller's default dir, so an install that has
 * never opened the panel has a real answer rather than a null.
 */
export interface DownloadDestination {
  machineId: string
  /** What to call that machine on the row. Empty for this one; the panel names it. */
  machineName: string
  folder: string
}

/**
 * Characters that are never part of a name or a path somebody chose.
 *
 * A NUL truncates a path at the syscall boundary, so a name carrying one is a
 * different string on screen from the file it actually makes. The rest are
 * unprintable and would draw as nothing in a row. `uploads.ts` refuses the same
 * set on the wire, one layer out.
 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/

/** Every state a row can be in. Five, and each of them is drawn differently. */
export type DownloadState =
  /** Bytes are moving onto this disk. */
  | 'downloading'
  /** Fetched here, now on its way to the machine that was chosen. */
  | 'delivering'
  /** It is where it was meant to end up. */
  | 'done'
  /** Somebody pressed Stop. */
  | 'cancelled'
  /** Chromium gave up, or the disk did, or the far machine refused it. */
  | 'failed'

export interface DownloadRow {
  id: string
  /** The file's name, as the server or the URL gave it. */
  name: string
  url: string
  /** Total size, or 0 when the server did not say. */
  bytes: number
  received: number
  state: DownloadState
  /** Where the file is now. Empty until there is a file. */
  path: string
  /** The machine {@link path} is on. Empty is this one. */
  onMachine: string
  /** What to call that machine. Empty while it is this one. */
  onMachineName: string
  /** Why it failed, or what was cancelled. Empty in the ordinary good state. */
  message: string
  startedAt: number
  /**
   * `sha256:<hex>` of the bytes that landed on this disk.
   *
   * Empty means *not known* — the download has not finished, or the file could
   * not be read back to hash it. It never means "no digest was needed".
   *
   * ## Why a row that already has a name, a URL, a size and a path needs this
   *
   * Because none of those four can tell a good file from a bad one. Asad's
   * property pipeline kept a resume ledger of exactly those fields, keyed on the
   * URL, and during a re-download that was started *because the files were
   * wrong* it recognised all 48,473 of them, skipped every one, and exited
   * reporting success. A ledger keyed on the URL answers *"did you ask for
   * this?"*, and the question is *"do you have it?"*.
   *
   * So the digest is computed here, at the one place in the app where a file
   * arrives from a socket, and it is what `browser-asset-ledger.ts` keys on. It
   * is also the thing that makes the no-transform guarantee checkable after the
   * fact rather than only in a test: the bytes were these bytes, and this is
   * what they hashed to when they landed.
   *
   * Computed **before** a cross-machine delivery, so the digest describes what
   * left this computer, and filled in asynchronously — the row goes to `done`
   * the instant the download reports the file is written, because a progress bar
   * that waited on a hash of a 2GB file would be a download that looks stuck.
   */
  digest: string
}

export interface DownloadsView {
  destination: DownloadDestination
  /**
   * This machine's own downloads folder, as an absolute path.
   *
   * On the view rather than composed in the renderer, because the renderer has
   * no way to know it — it is a main-process question — and because a panel that
   * printed "its downloads folder" where it could have printed the path would be
   * withholding the one fact somebody opens this to check. Supplied by the
   * caller's {@link DownloadDeps.defaultDir}; empty only before anything is
   * installed, which the panel never draws.
   */
  defaultFolder: string
  /** Newest first, which is the order a downloads list is read in. */
  items: DownloadRow[]
}

/** What a delivery to another machine answers with. */
export type DeliveryOutcome = { ok: true; path: string } | { ok: false; message: string }

/**
 * How many rows are kept.
 *
 * A cap rather than "for ever", because this file is read at launch and a list
 * that grows without bound is a JSON parse that gets slower every month. A
 * hundred is well past what anybody scrolls and small enough to read instantly.
 */
export const MAX_DOWNLOAD_ROWS = 100

/* -------------------------------------------------------------------- deps -- */

export interface DownloadDeps {
  /** Where `browser-downloads.json` lives. */
  userData(): string
  /** This machine's downloads folder, when no other has been chosen. */
  defaultDir(): string
  /** Push a fresh view at the window. Called on every change. */
  broadcast(view: DownloadsView): void
  /**
   * Hand a finished file to another machine, and answer where it landed.
   *
   * Injected because this module must not know whether the far end is a paired
   * desktop on the relay or a server over ssh — `index.ts` knows, and the two
   * answers have the same shape. Absent in a build that can reach neither, in
   * which case the destination picker offers only this machine and nothing here
   * can be asked to deliver.
   */
  deliver?(machineId: string, localPath: string, folder: string): Promise<DeliveryOutcome>
}

/* ------------------------------------------------------------------ state -- */

let deps: DownloadDeps | null = null

/** Rows, newest first. The whole of what the panel draws. */
let rows: DownloadRow[] = []

let destination: DownloadDestination = { machineId: '', machineName: '', folder: '' }

/**
 * The way to stop a live download, keyed by row id.
 *
 * A closure rather than the download object itself, because the two transports
 * hold two different things — Electron a `DownloadItem` whose `cancel()` this
 * calls, CDP a `guid` it turns into `Browser.cancelDownload`. Neither can be
 * serialised and neither must reach the renderer, so both register a `() =>
 * void` here and {@link cancelDownload} presses whichever one is registered. An
 * entry is removed the moment the download ends; a row without one is a download
 * that has finished one way or another.
 */
const cancellers = new Map<string, () => void>()

/**
 * Names this run has already reserved on disk.
 *
 * `existsSync` answers about files that exist, and two downloads of `report.pdf`
 * started a second apart would both be told the name is free before either had
 * written a byte. This set closes that window. It is only ever added to, because
 * a name that was taken and then deleted is still a name this run should not
 * hand out twice. Shared across both transports, so a desktop download and a CDP
 * download never pick the same staged name.
 */
const reserved = new Set<string>()

let sequence = 0

/* ------------------------------------------------------------ persistence -- */

export function downloadsPath(userData: string): string {
  return join(userData, 'browser-downloads.json')
}

/**
 * Read a stored file into a state that is always usable.
 *
 * Anything unrecognised collapses to "no rows, this machine" rather than
 * throwing, for the reason `browser-profiles.ts` gives about its own file: a
 * browser panel that will not open because a JSON file has a stray comma in it
 * is a worse failure than a lost list.
 *
 * A row that was `downloading` or `delivering` when the app was last closed is
 * read back as `failed`, not as itself. Nothing is moving any more — the process
 * that was moving it is gone — and a progress bar restored at 40% would sit
 * there for ever telling somebody a lie about a file.
 */
export function readDownloadsFile(raw: unknown): {
  rows: DownloadRow[]
  destination: DownloadDestination
} {
  const empty = {
    rows: [] as DownloadRow[],
    destination: { machineId: '', machineName: '', folder: '' },
  }
  if (typeof raw !== 'object' || raw === null) return empty
  const value = raw as Record<string, unknown>

  const list = Array.isArray(value.items) ? value.items : []
  const read: DownloadRow[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const id = text(record.id)
    if (id === '') continue
    const stored = readState(record.state)
    const wasMoving = stored === 'downloading' || stored === 'delivering'
    read.push({
      id,
      name: text(record.name),
      url: text(record.url),
      bytes: count(record.bytes),
      received: count(record.received),
      state: wasMoving ? 'failed' : stored,
      path: text(record.path),
      onMachine: text(record.onMachine),
      onMachineName: text(record.onMachineName),
      message: wasMoving ? `${BRAND.name} closed while this was moving.` : text(record.message),
      startedAt: count(record.startedAt),
      digest: text(record.digest),
    })
    if (read.length >= MAX_DOWNLOAD_ROWS) break
  }

  return { rows: read, destination: readDestination(value.destination) }
}

/**
 * Narrow a destination, off disk or off the renderer.
 *
 * The same function for both on purpose. A folder arriving over IPC is a path
 * this process is about to write a file into, so it is checked for the two
 * shapes that are never a folder somebody picked — not a string, and a string
 * with a control character or a NUL in it — and everything else is left to the
 * filesystem, which is the only thing that can actually answer whether a path is
 * writable. A renderer that can name any folder is not a new power here: it is
 * the same window that already opens the native folder chooser and is handed
 * whatever comes back.
 */
export function readDestination(raw: unknown): DownloadDestination {
  const none: DownloadDestination = { machineId: '', machineName: '', folder: '' }
  if (typeof raw !== 'object' || raw === null) return none
  const value = raw as Record<string, unknown>
  const folder = text(value.folder)
  if (CONTROL_CHARS.test(folder)) return none
  return { machineId: text(value.machineId), machineName: text(value.machineName), folder }
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

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

function count(raw: unknown): number {
  return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : 0
}

function load(): void {
  if (deps === null) return
  const path = downloadsPath(deps.userData())
  if (!existsSync(path)) return
  try {
    const read = readDownloadsFile(JSON.parse(readFileSync(path, 'utf8')) as unknown)
    rows = read.rows
    destination = read.destination
  } catch {
    // A file that will not parse is a file this feature does not need. The list
    // is history, not data anything depends on.
  }
}

function save(): void {
  if (deps === null) return
  const path = downloadsPath(deps.userData())
  try {
    mkdirSync(dirname(path), { recursive: true })
    // Through a temporary file, the same way `browser-profiles.ts` writes its
    // own: a half-written file is indistinguishable from a corrupt one, and the
    // failure would land on the next launch rather than on this one.
    const temporary = `${path}.tmp`
    writeFileSync(temporary, JSON.stringify({ version: 1, destination, items: rows }, null, 2))
    renameSync(temporary, path)
  } catch {
    // Losing the list is not a reason to lose the download that was being
    // recorded when the disk said no.
  }
}

/** The one place the ledger is persisted. Both transports call it at each ending. */
export function saveDownloads(): void {
  save()
}

/* ------------------------------------------------------------------ names -- */

/**
 * The naming rules live in `browser-download-names.ts` and are re-exported here.
 *
 * They moved when `browser-asset-fetch.ts` arrived, because that is a second
 * place where bytes come off a socket and land in a folder, and it needs the
 * same answer to *"is `../../.ssh/authorized_keys` a filename"*. Re-exported
 * rather than merely moved, so every caller that already imported them from
 * this module — and the tests that assert the rules — is unchanged.
 */
export { downloadName, freeDownloadPath, MAX_NAME_VARIANTS } from './browser-download-names'

/**
 * The folder a fetch goes into.
 *
 * A download bound for another machine still lands here first — this process is
 * the one holding the socket — so the staging folder is this machine's ordinary
 * downloads folder rather than a temporary directory. If the delivery then fails
 * the file is somewhere a person can find it, which is the whole reason not to
 * stage in `/tmp`.
 *
 * Throws when the folder cannot be made. The caller turns that into a row,
 * because a download that cannot be started is exactly the event this module
 * exists to stop being silent.
 */
export function chooseSavePath(
  dest: DownloadDestination,
  fallbackDir: string,
  suggested: string,
): string {
  /*
   * Absolute, or the default. A relative path would be resolved against this
   * process's working directory — a folder nobody chose, and a different one in
   * a packaged app than in an `npm start`. The only control that sets this is
   * the native chooser, which always answers absolute; the check is here because
   * the channel is reachable from more places than one component.
   */
  const chosen = dest.machineId === '' && dest.folder !== '' && isAbsolute(dest.folder)
  const dir = chosen ? dest.folder : fallbackDir
  mkdirSync(dir, { recursive: true })
  const path = freeDownloadPath(dir, suggested, existsSync, reserved)
  reserved.add(path)
  return path
}

/* ------------------------------------------------------------------- rows -- */

function view(): DownloadsView {
  return { destination, defaultFolder: deps?.defaultDir() ?? '', items: rows }
}

function publish(): void {
  deps?.broadcast(view())
}

function put(row: DownloadRow): void {
  const index = rows.findIndex((held) => held.id === row.id)
  if (index < 0) rows = [row, ...rows].slice(0, MAX_DOWNLOAD_ROWS)
  else rows = rows.map((held) => (held.id === row.id ? row : held))
  publish()
}

function patch(id: string, change: Partial<DownloadRow>): void {
  const held = rows.find((row) => row.id === id)
  if (!held) return
  put({ ...held, ...change })
}

/* ------------------------------------------------------- the feed the shells use -- */

/**
 * Mint a fresh row id.
 *
 * The same shape both transports have always used, kept in one place so a
 * desktop id and a CDP id are the same kind of thing and never collide.
 */
export function nextDownloadId(): string {
  sequence += 1
  return `dl-${Date.now().toString(36)}-${sequence}`
}

/**
 * The destination a download starting *now* is bound to, as a snapshot.
 *
 * A copy, not the live object, because a download reads where it is going once —
 * when it starts — and changing the destination while a file is in flight must
 * decide the next one, not redirect a file already asked for. Both transports
 * take this at `will-download` / `downloadWillBegin` time.
 */
export function downloadDestination(): DownloadDestination {
  return { ...destination }
}

/** The folder a fetch stages into when no local folder was chosen. */
export function stagingDir(): string {
  return deps?.defaultDir() ?? ''
}

/** Add or replace a row and push the new view. */
export function putDownloadRow(row: DownloadRow): void {
  put(row)
}

/** Change part of a row and push the new view. A row that has gone is a no-op. */
export function patchDownloadRow(id: string, change: Partial<DownloadRow>): void {
  patch(id, change)
}

/** Register how to stop this download. Called when the row is opened. */
export function registerDownloadCanceller(id: string, cancel: () => void): void {
  cancellers.set(id, cancel)
}

/** Forget the canceller for a download that has ended. */
export function forgetDownloadCanceller(id: string): void {
  cancellers.delete(id)
}

/* ---------------------------------------------------------------- integrity -- */

/**
 * Fingerprint a file that has just landed, and put the answer on its row.
 *
 * ## The guarantee this is evidence of
 *
 * `browser-asset-digest.ts` states it in full and it is one sentence: a
 * downloaded file is written exactly as the server sent it, and nothing in this
 * app rewrites those bytes. The transport is where that is either true or not —
 * the desktop hands Chromium a path and Chromium streams the response onto it,
 * and the CDP path lets the browser write the file itself and only renames it
 * afterwards, with no buffer in between that anything could transform. There is
 * no step to add one to, and there must never be.
 *
 * Reading the file back and hashing it is not a check *on that* — a transform
 * inserted above would be hashed just as happily. What it is, is the record that
 * makes every later question answerable: whether a resume already has this file
 * (`browser-asset-ledger.ts`), whether the copy on the far machine is the copy
 * that left this one, and whether the thing on disk today is the thing that
 * arrived. Asad has already lost 48,473 assets to a ledger that had every field
 * but this one.
 *
 * ## Why it does not hold up the row
 *
 * The row reaches `done` the moment the download reports the bytes are written,
 * and the digest arrives afterwards. A hash of a two-gigabyte file takes
 * seconds, and a downloads panel that sat at 100% for those seconds would be
 * reporting a stall that is not happening. An empty digest on a finished row
 * means *not known yet or not readable*, which the panel and the ledger both
 * already have to handle.
 */
async function seal(id: string, path: string): Promise<string> {
  if (path === '') return ''
  const digest = await digestFile(path)
  // The row may have been cleared, or the download re-listed, while the hash
  // ran. `patch` on a row that has gone is a no-op, which is the right answer.
  if (digest !== '') {
    patch(id, { digest })
    save()
  }
  return digest
}

/* --------------------------------------------------------------- delivery -- */

/**
 * Move a finished download to the machine it was meant for.
 *
 * The order is the whole of {@link DownloadDeps.deliver}'s contract, and it is
 * the order his sentence gives: transfer, confirm, *then* delete. The unlink is
 * guarded three ways — the delivery said ok, the path is the one this module
 * staged, and the far machine answered with a real path — because a delete on
 * the strength of a maybe is how a download becomes no file at all.
 *
 * A failure keeps the local file and says where it is. That is not a fallback
 * dressed up as a success: the row reads `failed`, carries the far machine's own
 * sentence, and points at the copy that does exist.
 */
async function deliver(
  id: string,
  localPath: string,
  target: DownloadDestination,
): Promise<void> {
  const hand = deps?.deliver
  if (hand === undefined) {
    patch(id, {
      state: 'failed',
      message: 'This build cannot send files to another machine.',
      path: localPath,
    })
    save()
    return
  }
  patch(id, { state: 'delivering', onMachine: '', onMachineName: '', path: localPath })
  /*
   * Hashed alongside the transfer, and joined before the unlink.
   *
   * It has to happen *some* time before the unlink, because that unlink is the
   * last moment at which the bytes that were downloaded exist on this disk — a
   * digest taken afterwards would describe whatever the far machine wrote, which
   * is a different question about a file this process cannot see.
   *
   * Started rather than awaited, because the two are independent: reading a
   * two-gigabyte file to hash it and pushing the same file down a socket have no
   * ordering between them, and awaiting first would add the whole read to the
   * time before a single byte leaves. The join is below, immediately before the
   * only `unlink` in this module.
   */
  const sealing = seal(id, localPath)

  let outcome: DeliveryOutcome
  try {
    outcome = await hand(target.machineId, localPath, target.folder)
  } catch (error) {
    outcome = {
      ok: false,
      message: error instanceof Error ? error.message : 'That could not be sent.',
    }
  }

  if (!outcome.ok || outcome.path === '') {
    patch(id, {
      state: 'failed',
      message: outcome.ok
        ? 'That machine did not say where it put the file.'
        : outcome.message,
      path: localPath,
      onMachine: '',
      onMachineName: '',
    })
    save()
    return
  }

  /*
   * The move, and the only `unlink` in this module.
   *
   * It runs after the far machine has named the path it wrote, which is the
   * point at which the file provably exists in two places. A failure to delete
   * is not reported as a failed download — the file is where he asked for it,
   * which is what he asked about — but it is not silent either: the row says the
   * copy is still here.
   */
  let leftBehind = ''
  // The join. After this line the local copy may go; before it, it may not.
  await sealing
  try {
    await unlink(localPath)
  } catch {
    leftBehind = `A copy is still on this machine, at ${localPath}.`
  }
  patch(id, {
    state: 'done',
    path: outcome.path,
    onMachine: target.machineId,
    onMachineName: target.machineName,
    message: leftBehind,
  })
  save()
}

/**
 * Finish a download whose bytes have landed on this disk.
 *
 * The one tail both transports share, and byte-for-byte the branch the desktop
 * `done` handler and the CDP `completed` handler used to each write themselves:
 * a download for this machine goes straight to `done` and is sealed afterwards,
 * and one bound elsewhere is delivered. `bound` is the destination *snapshot*
 * the download started with, not the current one.
 */
export function completeDownload(
  id: string,
  landedPath: string,
  bound: DownloadDestination,
): void {
  forgetDownloadCanceller(id)
  if (bound.machineId === '') {
    patch(id, { state: 'done' })
    save()
    // Not awaited: see `seal`. The row is already correct without it.
    void seal(id, landedPath)
    return
  }
  void deliver(id, landedPath, bound)
}

/**
 * Mark a download failed, keeping any local copy and saying why.
 *
 * Shared so an interruption, a folder that would not take the file, or a rename
 * that could not happen all leave the same shape of row — the thing this whole
 * module exists to guarantee: a download never disappears without a trace.
 */
export function failDownload(id: string, message: string, path?: string): void {
  forgetDownloadCanceller(id)
  patch(id, path === undefined ? { state: 'failed', message } : { state: 'failed', message, path })
  save()
}

/* --------------------------------------------------------------- the API -- */

export function installDownloads(next: DownloadDeps): void {
  deps = next
  load()
  publish()
}

/** For tests, which must not inherit each other's state. */
export function resetDownloadsForTests(): void {
  deps = null
  rows = []
  destination = { machineId: '', machineName: '', folder: '' }
  cancellers.clear()
  reserved.clear()
  sequence = 0
}

export function downloadsView(): DownloadsView {
  return view()
}

export function setDownloadDestination(raw: unknown): DownloadsView {
  destination = readDestination(raw)
  save()
  publish()
  return view()
}

/** Stop one download. A row that has already finished is left alone. */
export function cancelDownload(id: unknown): DownloadsView {
  if (typeof id === 'string') cancellers.get(id)?.()
  return view()
}

/**
 * Take the finished rows off the list.
 *
 * Never touches a file. "Clear" in every downloads list means the list, and a
 * control that deleted somebody's files under that word would be the worst
 * possible reading of it — so the rows go and the downloads stay.
 */
export function clearDownloads(): DownloadsView {
  rows = rows.filter((row) => row.state === 'downloading' || row.state === 'delivering')
  save()
  publish()
  return view()
}

/**
 * Is a download still on the list, and where are its bytes?
 *
 * The read `browser-downloads-electron.ts`'s open/reveal need before it touches
 * the disk, and the read a CDP-side check would need too — kept here so both ask
 * one function rather than reaching into `rows`.
 */
export function findDownloadRow(id: unknown): DownloadRow | undefined {
  return rows.find((entry) => entry.id === id)
}

/* -------------------------------------------------------------- register -- */

/** The push every window subscribes to. One channel, the whole view. */
export const DOWNLOADS_CHANNEL = 'browser:downloads'
