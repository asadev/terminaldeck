import { randomBytes } from 'node:crypto'
import { mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { clipboard, dialog, type BrowserWindow, type IpcMain } from 'electron'
import { linuxPathFromUnc } from './wsl'

/**
 * Getting a file into a message from somewhere other than the open project.
 *
 * ## Why this exists
 *
 * `renderer/chat/attach/AttachPicker.tsx` argues, at length and correctly, that
 * a project-scoped list beats a native dialog for the common case: it is faster,
 * every row it offers is a row that works, and the paths stay relative. None of
 * that is wrong. What was wrong is that it was the **only** way in, so there was
 * no way at all to attach a screenshot sitting on the desktop, a PDF in
 * Downloads, or a file from a second checkout. Reported in those words:
 *
 *   > "I should be able to take anything from my PC to paste here… If I just
 *   > click, it should just open browse my file manager of the PC or Windows or
 *   > MacBook, and I should be able to just choose something from there instead
 *   > of opening something inside."
 *
 * So this is the escape hatch, not a replacement. The project list is still what
 * opens first; this is the row underneath it, the drop target, and the paste.
 *
 * ## Three doors, one shape
 *
 * Browse, drop and paste all end at the same place — a list of absolute paths
 * with a straight answer about whether each one is a directory — because the
 * composer downstream has one rule for what to do with a path and should not
 * grow three. {@link OutsidePick} is that shape.
 *
 * ## What the clipboard actually holds, measured rather than assumed
 *
 * Run on this machine against Electron 41 (`clipboard.availableFormats()` and
 * three `clipboard.read` calls, with the pasteboard set two different ways):
 *
 * | pasteboard | `availableFormats()` | `public.file-url` | `NSFilenamesPboardType` | `readImage()` |
 * | --- | --- | --- | --- | --- |
 * | a PNG **file** copied in Finder | `["text/uri-list"]` | the `file://` URL | an XML plist listing every path | **not empty** |
 * | a screenshot copied as a **bitmap** | `["image/png"]` | `""` | `""` | not empty |
 *
 * Two things fall out of that table and both are load-bearing:
 *
 *  1. **The file check has to come before the image check.** macOS renders a
 *     preview of a copied image *file* into the pasteboard, so `readImage()` is
 *     non-empty in both rows. Testing the image first would take a file the user
 *     already has on disk, write a second copy of it into this app's storage,
 *     and attach the copy — a path they have never seen, in a folder they do not
 *     know about, for a file that was sitting right there. Order is the fix.
 *  2. **`text/uri-list` is a lie on this platform.** It is what
 *     `availableFormats()` reports, and `clipboard.read('text/uri-list')` returns
 *     the empty string for the same pasteboard that answers `public.file-url`
 *     with a real URL. Anything reading the advertised format would conclude the
 *     clipboard was empty.
 */

/* -------------------------------------------------------------- the shape -- */

/** One thing the user chose, wherever they chose it from. */
export interface OutsidePick {
  /** Absolute. Not relative to anything — that is the whole point of it. */
  path: string
  /**
   * Stat-ed rather than inferred from which dialog was open.
   *
   * A macOS bundle — `Something.app`, an Xcode project, a Logic session — is a
   * directory that the open panel presents as a single file, so a pick made in
   * "choose a file" mode can be a directory and the caller has to be told. The
   * distinction decides what the agent is asked for: a file's contents, or a
   * folder's listing.
   */
  isDirectory: boolean
}

export type BrowseResult =
  | { ok: true; picks: OutsidePick[] }
  /**
   * `cancelled` is not an error and the caller must not draw one. It is
   * separated from `no-window` because the second is this app being wrong — the
   * dialog is modal to a window and there was none — and somebody debugging that
   * should not have to tell it apart from a user pressing Escape.
   */
  | { ok: false; reason: 'cancelled' | 'no-window' }

export type PasteResult =
  | { ok: true; picks: OutsidePick[]; source: 'files' | 'image' }
  | { ok: false; reason: 'nothing' | 'write-failed'; detail: string }

export interface BrowseRequest {
  mode: 'file' | 'folder' | 'image'
  /**
   * Where the panel should stand when it opens.
   *
   * Optional, and when it is absent the panel is given the user's home rather
   * than nothing. Handing `showOpenDialog` no `defaultPath` is not "no
   * preference" — `project-picker.ts` has the whole measurement, but the short
   * version is that AppKit then restores a bookmark nothing in this app writes,
   * which on a recorded walkthrough pointed at an empty folder and made the
   * picker list zero rows four openings in a row.
   */
  startIn?: string
  /**
   * Extensions for the image filter, lower case and without the dot.
   *
   * Passed in rather than held here so that the list lives in exactly one place.
   * The renderer's `chat/attach/mentions.ts` owns `IMAGE_EXTENSIONS`, because it
   * is the module that decides whether a path *is* an image when the chip is
   * drawn and when the mention is built; a second copy in the main process would
   * be a filter that quietly disagrees with the label on the result.
   */
  extensions?: string[]
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * A path the way the rest of the app stores paths.
 *
 * The UNC translation is the same one `project:pick` does at the same point, and
 * for the same reason: a folder browsed to inside a WSL distribution comes back
 * from Explorer as `\\wsl.localhost\Ubuntu\home\asad\thing`, which is not a path
 * anything can run in or `cd` to. It is translated once, here, where the path
 * enters the app, so that no copy of it downstream ever has to know.
 */
function normalisePick(path: string): string {
  return linuxPathFromUnc(path)?.path ?? path
}

/**
 * Is this a directory? Stat rather than trust.
 *
 * A missing file answers `false` rather than throwing. The caller is about to
 * hand the path to an agent that will produce its own error if it is not there,
 * and refusing the attachment on a stat race would be this app inventing a
 * failure the user cannot act on.
 */
function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

function pickOf(path: string): OutsidePick {
  const target = normalisePick(path)
  return { path: target, isDirectory: isDirectory(target) }
}

/**
 * Every file path on the clipboard, most complete source first.
 *
 * `NSFilenamesPboardType` is asked first because it is the only one of the two
 * that can carry more than one path: copying three files in Finder puts three
 * `<string>` entries in that plist, while `public.file-url` hands back exactly
 * one however many were copied. It is deprecated and it is also still what a
 * Finder copy writes on macOS 27 — measured, not read — so it is tried and then
 * fallen back on rather than relied upon.
 *
 * The plist is scanned with a regular expression rather than parsed. That is a
 * deliberately small claim: if the pasteboard ever carries the *binary* plist
 * form instead, no `<string>` matches, this returns nothing, and the caller
 * falls through to `public.file-url` and attaches one file instead of three.
 * A degraded answer, never a wrong one — and never a crash, which a real parser
 * fed a binary blob would be.
 */
export function clipboardFilePaths(read: (format: string) => string): string[] {
  const plist = read('NSFilenamesPboardType')
  const paths: string[] = []
  if (plist !== '') {
    for (const match of plist.matchAll(/<string>([^<]*)<\/string>/g)) {
      const value = decodeXml(match[1] ?? '')
      if (value !== '') paths.push(value)
    }
  }
  if (paths.length > 0) return paths

  const url = read('public.file-url')
  const single = pathFromFileUrl(url)
  return single === null ? [] : [single]
}

/** The five entities XML has to escape. A filename may legitimately contain `&`. */
function decodeXml(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

/**
 * `file:///Users/apple/a%20file.png` → `/Users/apple/a file.png`.
 *
 * Hand-rolled rather than `fileURLToPath` because the input is not this app's:
 * a malformed URL on the pasteboard should mean "there is no file here", not an
 * exception on a paste. Anything that is not a `file:` URL answers null, which
 * is how a clipboard holding plain text falls through to the image check.
 */
export function pathFromFileUrl(url: string): string | null {
  const trimmed = url.trim()
  if (!trimmed.toLowerCase().startsWith('file://')) return null
  const withoutScheme = trimmed.slice('file://'.length)
  // A `file://host/path` URL keeps the host; only the localhost forms are a
  // plain path, and those are the only ones a pasteboard produces.
  const path = withoutScheme.startsWith('/') ? withoutScheme : null
  if (path === null) return null
  try {
    const decoded = decodeURIComponent(path)
    return decoded === '' ? null : decoded.replace(/\/$/, '')
  } catch {
    return null
  }
}

/**
 * Filenames for pasted bitmaps, and why they are not `paste-1.png`.
 *
 * The date is for the person who eventually opens this folder and wonders what
 * it is; the random tail is because two pastes in the same second are one
 * keyboard repeat apart, and a collision would silently replace an image
 * already attached to a message that has not been sent yet.
 */
export function pastedImageName(now: Date, random: string): string {
  const stamp = now.toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19)
  return `pasted-${stamp}-${random}.png`
}

/**
 * How long a pasted image stays on disk.
 *
 * These are the app's litter, not the user's documents — the original never
 * moved and is still wherever it was — so they are cleaned up rather than kept
 * forever. Two weeks is well past the life of the message that referenced them
 * and well short of "this folder is now a gigabyte".
 */
export const PASTE_KEEP_MS = 14 * 24 * 60 * 60 * 1000

/**
 * Delete pasted images older than {@link PASTE_KEEP_MS}.
 *
 * Best effort on purpose, and swallowed as a whole: a file that will not delete
 * — open in Preview, on a volume that went away — must not turn the next paste
 * into a failure. The worst case is one stale PNG.
 */
export function prunePasted(dir: string, now: number, keepMs = PASTE_KEEP_MS): void {
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return
  }
  for (const name of entries) {
    const file = join(dir, name)
    try {
      if (now - statSync(file).mtimeMs > keepMs) rmSync(file, { force: true })
    } catch {
      /* see above */
    }
  }
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * What the composer is told about the session it is writing to.
 *
 * `confined: false` is the answer for every session started at this keyboard,
 * and it means "an absolute path from anywhere on this disk will resolve". The
 * other answer means the opposite and names the folder, so the sentence on
 * screen can be about *this* session rather than about confinement in general.
 */
export interface BoundaryAnswer {
  confined: boolean
  /** The granted folder. Empty when the session is not confined. */
  folder: string
  /**
   * The person's own projects this session may also read — the copilot's grant,
   * and nothing else has one.
   *
   * Sent because the sentence on screen is otherwise wrong about a whole
   * feature. A copilot session is confined to its own folder *and* granted read
   * access to every project the person has added, so telling them it "cannot
   * read a file from anywhere else" would be false in the one case they are
   * most likely to hit.
   */
  projects: string[]
}

export interface AttachOutsideDeps {
  /** The window the panel is modal to. Null while none is up. */
  window(): BrowserWindow | null
  /** Where a pasted bitmap is written. Created on first use. */
  pasteDir: string
  /** The user's home, for a browse with nowhere better to start. */
  home(): string
  /**
   * What this session is held inside, or null when it is held inside nothing.
   *
   * A function rather than a value because the answer is per session and only
   * exists once the session has been spawned. `session-boundary.ts` says why the
   * question has to be asked of the main process at all — the short version is
   * that a confined session looks exactly like any other tab from the renderer's
   * side, and attaching a file it cannot read would be a feature that fails at
   * the agent rather than at the click.
   */
  boundaryOf(sessionId: string): { folder: string; readableProjects: readonly string[] } | null
  /** Injected so the clipboard can be driven in a test without a pasteboard. */
  clipboard?: {
    read(format: string): string
    readImage(): { isEmpty(): boolean; toPNG(): Buffer }
  }
  now?(): number
}

export function registerAttachOutsideIpc(ipcMain: IpcMain, deps: AttachOutsideDeps): void {
  const board = deps.clipboard ?? clipboard
  const clock = deps.now ?? Date.now

  /**
   * Whether this session can be given a path from outside its folder.
   *
   * Asked once when the composer's session changes rather than once per
   * attachment: a boundary is fixed for the life of a session — it is decided
   * before the process starts and cannot be widened afterwards — so a second
   * call would return the same answer for the same id every time.
   */
  ipcMain.handle('attach:boundary', async (_event, sessionId: unknown): Promise<BoundaryAnswer> => {
    const none: BoundaryAnswer = { confined: false, folder: '', projects: [] }
    if (typeof sessionId !== 'string' || sessionId === '') return none
    const boundary = deps.boundaryOf(sessionId)
    return boundary === null
      ? none
      : { confined: true, folder: boundary.folder, projects: [...boundary.readableProjects] }
  })

  ipcMain.handle('attach:browse', async (_event, request: BrowseRequest): Promise<BrowseResult> => {
    const window = deps.window()
    if (!window) return { ok: false, reason: 'no-window' }

    const folder = request.mode === 'folder'
    const extensions = (request.extensions ?? []).filter((e) => typeof e === 'string' && e !== '')
    const { canceled, filePaths } = await dialog.showOpenDialog(window, {
      /*
       * `multiSelections` on the two file modes, and deliberately not on the
       * folder one.
       *
       * Attaching three screenshots should be one trip through the panel — the
       * picker beside this one already stays open for exactly that reason. A
       * folder is the other case: each one expands into a listing in front of
       * the question, so three of them is a wall of paths and the message the
       * agent was meant to read is at the bottom of it.
       */
      properties: folder ? ['openDirectory'] : ['openFile', 'multiSelections'],
      title: folder ? 'Add a folder' : request.mode === 'image' ? 'Add an image' : 'Add files',
      buttonLabel: 'Add',
      /*
       * A filter only where there is something true to filter by.
       *
       * "Add an image" narrows to the extensions the CLI actually attaches as
       * image content, with an All files escape underneath it so the panel can
       * never become a dead end for a `.heic` this app has not learned about.
       * "Add files" gets no filter at all, because every extension is a valid
       * answer there and a filter that excludes nothing is a control that does
       * nothing.
       */
      ...(request.mode === 'image' && extensions.length > 0
        ? { filters: [{ name: 'Images', extensions }, { name: 'All files', extensions: ['*'] }] }
        : {}),
      defaultPath:
        typeof request.startIn === 'string' && request.startIn !== ''
          ? request.startIn
          : deps.home(),
    })

    if (canceled || filePaths.length === 0) return { ok: false, reason: 'cancelled' }
    return { ok: true, picks: filePaths.map(pickOf) }
  })

  /**
   * What was dropped, once the renderer has turned its `File` objects into
   * paths.
   *
   * The renderer cannot answer `isDirectory` on its own — a dropped directory
   * arrives as a `File` with size 0 and no type, which is also what an empty
   * file looks like — and it has no `fs`. So the paths come here to be stat-ed.
   */
  ipcMain.handle('attach:inspect', async (_event, paths: string[]): Promise<OutsidePick[]> => {
    if (!Array.isArray(paths)) return []
    return paths.filter((p): p is string => typeof p === 'string' && p !== '').map(pickOf)
  })

  ipcMain.handle('attach:paste', async (): Promise<PasteResult> => {
    const files = clipboardFilePaths((format) => {
      try {
        return board.read(format)
      } catch {
        // An unknown format is not an error on any platform that does not have
        // it — Windows has no `NSFilenamesPboardType` and says so by throwing on
        // some Electron versions and returning '' on others.
        return ''
      }
    })
    if (files.length > 0) return { ok: true, picks: files.map(pickOf), source: 'files' }

    const image = board.readImage()
    if (image.isEmpty()) {
      return {
        ok: false,
        reason: 'nothing',
        detail: 'There is no file or image on the clipboard.',
      }
    }

    try {
      mkdirSync(deps.pasteDir, { recursive: true, mode: 0o700 })
      prunePasted(deps.pasteDir, clock())
      const name = pastedImageName(new Date(clock()), randomBytes(3).toString('hex'))
      const file = join(deps.pasteDir, name)
      writeFileSync(file, image.toPNG(), { mode: 0o600 })
      return { ok: true, picks: [{ path: file, isDirectory: false }], source: 'image' }
    } catch (error) {
      /*
       * Said out loud rather than swallowed.
       *
       * A pasted image has to become a file before an agent can be pointed at
       * it, and this is the only step that can fail for a reason the user might
       * be able to do something about — a full disk, a storage directory that
       * has been made read-only. A paste that quietly does nothing is
       * indistinguishable from a paste handler that was never wired.
       */
      return {
        ok: false,
        reason: 'write-failed',
        detail: error instanceof Error ? error.message : String(error),
      }
    }
  })
}
