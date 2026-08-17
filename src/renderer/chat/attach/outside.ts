import { basename, IMAGE_EXTENSIONS } from './mentions'
import { machineNoun, type UiPlatform } from '../../platform'

/**
 * The three ways a file gets into a message from outside the open project.
 *
 * Browse, drop and paste. They are one module because they are one feature —
 * *"I should be able to take anything from my PC to paste here"* — and because
 * each of them is two lines of UI on top of one main-process call. Split across
 * three files they would grow three slightly different ideas of what a failed
 * attach looks like.
 *
 * ## What this is not
 *
 * It is not a replacement for `AttachPicker`. That component's header argues for
 * a project-scoped list and the argument holds: it is faster for the common
 * case, every row in it works, and the paths stay short. This is the row
 * underneath it. The default is unchanged; what changed is that there is now a
 * way out.
 *
 * ## Everything crosses as `unknown`
 *
 * The main-process module owns these shapes, so they arrive unnarrowed and are
 * read defensively here — the same rule, for the same reason, as
 * `AttachPicker.readFiles`. In the harness an unimplemented bridge method
 * resolves to `null`, and reading `.picks` off that throws inside a promise and
 * takes the composer down through the error boundary, which reads as a broken
 * feature rather than an unwired one.
 */

/** Channels this feature needs. Every one is on the bridge. */
export interface AttachOutsideBridge {
  browseForAttachment(request: {
    mode: 'file' | 'folder' | 'image'
    startIn?: string
    extensions?: string[]
  }): Promise<unknown>
  inspectAttachPaths(paths: string[]): Promise<unknown>
  pasteAttachment(): Promise<unknown>
  sessionAttachBoundary(sessionId: string): Promise<unknown>
  pathForDroppedFile(file: File): string
}

/** One thing the user chose, wherever they chose it from. */
export interface OutsidePick {
  path: string
  isDirectory: boolean
}

/**
 * What this session is held inside.
 *
 * `confined: false` is the answer for every session started in this window, and
 * it is the answer the harness and the tests get. See `main/session-boundary.ts`
 * for why the question exists at all.
 */
export interface AttachBoundary {
  confined: boolean
  folder: string
  /** The person's own projects it may also read. The copilot's grant, only. */
  projects: readonly string[]
}

export const UNCONFINED: AttachBoundary = { confined: false, folder: '', projects: [] }

/* ---------------------------------------------------------------- reading -- */

function pickFrom(value: unknown): OutsidePick | null {
  if (!value || typeof value !== 'object') return null
  const row = value as { path?: unknown; isDirectory?: unknown }
  if (typeof row.path !== 'string' || row.path === '') return null
  return { path: row.path, isDirectory: row.isDirectory === true }
}

export function readPicks(response: unknown): OutsidePick[] {
  if (!Array.isArray(response)) return []
  return response.map(pickFrom).filter((pick): pick is OutsidePick => pick !== null)
}

/**
 * The browse result, with a cancel told apart from a failure.
 *
 * Pressing Escape in an open panel is the single most common way this call ends
 * and it is not an error. Collapsing it into "nothing was chosen" would be fine
 * for the chips and wrong for the one case that matters: a build where the
 * channel is missing would look identical to a user changing their mind, which
 * is how an unwired feature ships looking finished.
 */
export type BrowseOutcome =
  | { kind: 'picked'; picks: OutsidePick[] }
  | { kind: 'cancelled' }
  | { kind: 'failed'; message: string }

export function readBrowse(response: unknown): BrowseOutcome {
  if (!response || typeof response !== 'object') {
    return { kind: 'failed', message: 'The file browser is not available in this build.' }
  }
  const body = response as { ok?: unknown; picks?: unknown; reason?: unknown }
  if (body.ok === true) {
    const picks = readPicks(body.picks)
    return picks.length === 0 ? { kind: 'cancelled' } : { kind: 'picked', picks }
  }
  if (body.reason === 'cancelled') return { kind: 'cancelled' }
  return {
    kind: 'failed',
    message:
      body.reason === 'no-window'
        ? 'The file browser could not open over this window.'
        : 'The file browser could not open.',
  }
}

export type PasteOutcome =
  | { kind: 'picked'; picks: OutsidePick[]; source: 'files' | 'image' }
  /** Nothing attachable on the clipboard. Not a failure — usually it is text. */
  | { kind: 'nothing' }
  | { kind: 'failed'; message: string }

export function readPaste(response: unknown): PasteOutcome {
  if (!response || typeof response !== 'object') {
    return { kind: 'failed', message: 'Pasting a file is not available in this build.' }
  }
  const body = response as { ok?: unknown; picks?: unknown; source?: unknown; detail?: unknown; reason?: unknown }
  if (body.ok === true) {
    const picks = readPicks(body.picks)
    if (picks.length === 0) return { kind: 'nothing' }
    return { kind: 'picked', picks, source: body.source === 'image' ? 'image' : 'files' }
  }
  if (body.reason === 'nothing') return { kind: 'nothing' }
  return {
    kind: 'failed',
    message:
      typeof body.detail === 'string' && body.detail !== ''
        ? `That image could not be saved: ${body.detail}`
        : 'That could not be pasted.',
  }
}

export function readBoundary(response: unknown): AttachBoundary {
  if (!response || typeof response !== 'object') return UNCONFINED
  const body = response as { confined?: unknown; folder?: unknown; projects?: unknown }
  if (body.confined !== true) return UNCONFINED
  return {
    confined: true,
    folder: typeof body.folder === 'string' ? body.folder : '',
    projects: Array.isArray(body.projects)
      ? body.projects.filter((p): p is string => typeof p === 'string')
      : [],
  }
}

/* ----------------------------------------------------------------- copy --- */

/** "Browse this Mac…" / "Browse this PC…" — his words: *"browse my file manager"*. */
export function browseLabel(platform: UiPlatform): string {
  return `Browse this ${machineNoun(platform)}…`
}

/**
 * Why Browse is refused on a confined session, naming what it actually holds.
 *
 * The folder is in the sentence because "this session is confined" is a fact
 * about a feature and "this session can only read <folder>" is a fact about
 * *this tab*, and only the second one tells somebody what to do next — put the
 * file in that folder, or write to a different session.
 *
 * The projects clause is in it because leaving it out would be a wrong
 * explanation, which is a different failure from no explanation and not an
 * obviously smaller one. A copilot session is held inside its own folder *and*
 * granted read access to every project the person has added, so a flat "it
 * cannot read a file from anywhere else" is false for the confined session they
 * are by far the most likely to open.
 *
 * The refusal itself is real rather than defensive. Measured on this machine in
 * `main/session-boundary.test.ts` and `main/confine/escapes.test.ts`: a confined
 * session cannot read a file elsewhere by absolute path, so an attachment from
 * outside would produce a chip, a mention, and an agent reporting that it cannot
 * open the file.
 */
export function confinedRefusal(folder: string, projects: readonly string[] = []): string {
  /*
   * The folder's last segment, not the whole path, and that was decided by
   * looking at it. The copilot's folder is
   * `/Users/apple/Library/Application Support/terminaldeck/copilot`, and the
   * whole sentence with the whole path in it wrapped to four lines inside a
   * 336px popover — a paragraph where a hint goes. The last segment is also the
   * part that identifies it to a person: `copilot`, or the name of the folder
   * they granted a phone. Everything before it is where this app keeps things.
   */
  const named = folder === '' ? 'its own folder' : basename(folder)
  const also = projects.length > 0 ? ' and the projects you have open' : ''
  return `This session is held inside ${named}${also}, so it cannot read a file from anywhere else.`
}

/* -------------------------------------------------------------- the calls -- */

export function resolveOutsideBridge(injected?: AttachOutsideBridge): AttachOutsideBridge | null {
  if (injected) return injected
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<AttachOutsideBridge> }).deck
  if (!host) return null
  const needed: Array<keyof AttachOutsideBridge> = [
    'browseForAttachment',
    'inspectAttachPaths',
    'pasteAttachment',
    'sessionAttachBoundary',
    'pathForDroppedFile',
  ]
  return needed.every((name) => typeof host[name] === 'function')
    ? (host as AttachOutsideBridge)
    : null
}

/**
 * Open the real panel.
 *
 * `startIn` is the project, not the last place the panel was. That is the same
 * decision `project-picker.ts` made for the folder dialog and it was made
 * against a measurement: with no `defaultPath`, AppKit restores a bookmark
 * nothing in this app writes, and on a recorded walkthrough that bookmark
 * pointed at an empty directory and the panel listed zero rows four times in a
 * row. The project is the one directory that certainly is not empty, and
 * somebody reaching for Browse is usually looking for something beside it.
 */
export async function browseForAttachment(
  bridge: AttachOutsideBridge,
  mode: 'file' | 'folder' | 'image',
  startIn: string,
): Promise<BrowseOutcome> {
  try {
    const response = await bridge.browseForAttachment({
      mode,
      ...(startIn === '' ? {} : { startIn }),
      // The one list of image extensions in the app, sent to the panel rather
      // than duplicated in the main process — see `BrowseRequest.extensions`.
      ...(mode === 'image' ? { extensions: [...IMAGE_EXTENSIONS] } : {}),
    })
    return readBrowse(response)
  } catch {
    return { kind: 'failed', message: 'The file browser could not open.' }
  }
}

/**
 * The paths behind a drop, in the order they were dropped.
 *
 * Two steps, and the split is forced: only the preload can turn a `File` into a
 * path (`webUtils`, since Electron 32 removed `File.path`), and only the main
 * process can say whether that path is a directory — a dropped folder arrives as
 * a `File` with size 0 and no type, which is exactly what an empty file looks
 * like.
 */
export async function picksFromDrop(
  bridge: AttachOutsideBridge,
  files: readonly File[],
): Promise<OutsidePick[]> {
  const paths = files.map((file) => bridge.pathForDroppedFile(file)).filter((path) => path !== '')
  if (paths.length === 0) return []
  try {
    return readPicks(await bridge.inspectAttachPaths(paths))
  } catch {
    return []
  }
}

export async function pasteAttachment(bridge: AttachOutsideBridge): Promise<PasteOutcome> {
  try {
    return readPaste(await bridge.pasteAttachment())
  } catch {
    return { kind: 'failed', message: 'That could not be pasted.' }
  }
}

export async function sessionBoundary(
  bridge: AttachOutsideBridge,
  sessionId: string,
): Promise<AttachBoundary> {
  try {
    return readBoundary(await bridge.sessionAttachBoundary(sessionId))
  } catch {
    /*
     * Unconfined on failure, and this is the one place that choice deserves an
     * argument, because failing open looks wrong for anything security-shaped.
     *
     * It is not security-shaped. The OS holds the boundary whatever this
     * function returns; nothing here can widen what a session may read. All this
     * answer decides is whether the app *warns first*. Failing the other way
     * would withdraw Browse from every ordinary session the moment one IPC call
     * hiccuped — breaking the feature for the case that always works, in the
     * name of a case where the worst outcome is the agent saying it cannot read
     * a file.
     */
    return UNCONFINED
  }
}
