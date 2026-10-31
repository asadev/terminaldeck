import { IMAGE_EXTENSIONS, insideRoot } from './mentions'

/**
 * The three ways a file gets into a message from outside the open project.
 *
 * Browse, drop and paste. They are one module because they are one feature —
 * *"I should be able to take anything from my PC to paste here"* — and because
 * each of them is two lines of UI on top of one main-process call. Split across
 * three files they would grow three slightly different ideas of what a failed
 * attach looks like.
 *
 * ## This is now the whole feature, not the escape hatch
 *
 * It used to be the row underneath an in-app, project-scoped file list. That
 * list is gone — deleted, not hidden — because it was the answer to a question
 * nobody asked:
 *
 *   > *"If I click on add files, it is opening like this. It should open our
 *   > file manager instead of staying inside. It should be directly browse —
 *   > not even click. We should not even have this search bar and this button to
 *   > click at all. Add folder → directly open the file manager. Add file →
 *   > directly. Add an image → directly. That's it. Simple."*
 *
 * The argument for the project list was a good one on its own terms — faster
 * for the common case, every row valid, short paths — and it lost anyway,
 * because it made the app's own file browser the thing you meet when you press
 * a button labelled with the name of a thing the operating system already does.
 * The three menu rows now call `browseForAttachment` on the click that opens
 * them; there is no intermediate screen and no search field.
 *
 * ## Everything crosses as `unknown`
 *
 * The main-process module owns these shapes, so they arrive unnarrowed and are
 * read defensively here. In the harness an unimplemented bridge method
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
  bringAttachmentsIn(sessionId: string, paths: string[]): Promise<unknown>
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

/*
 * `browseLabel` used to live here — "Browse this Mac…" / "Browse this PC…" — for
 * a row that sat between the project list's search field and its results. Both
 * the row and the list are gone: every entry in the attach menu opens the
 * machine's own panel now, so a button whose whole job was to say "the real one
 * this time" has nothing left to distinguish itself from.
 */

/**
 * What came back from copying files into a confined session.
 *
 * `brought` pairs each original with where it landed; `refused` is a count and
 * not a list of sentences. See `main/attach-bring-in.ts` for why the count.
 */
export interface BroughtIn {
  from: string
  path: string
}

export function readBringIn(response: unknown): { brought: BroughtIn[]; refused: number } {
  if (!response || typeof response !== 'object') return { brought: [], refused: 0 }
  const body = response as { brought?: unknown; refused?: unknown }
  const brought: BroughtIn[] = []
  if (Array.isArray(body.brought)) {
    for (const entry of body.brought) {
      if (!entry || typeof entry !== 'object') continue
      const row = entry as { from?: unknown; path?: unknown }
      if (typeof row.from !== 'string' || typeof row.path !== 'string' || row.path === '') continue
      brought.push({ from: row.from, path: row.path })
    }
  }
  const refused = typeof body.refused === 'number' && Number.isFinite(body.refused) ? body.refused : 0
  return { brought, refused }
}

/**
 * The one short line about files that could not be brought in, or ''.
 *
 * Where a paragraph used to be. The old sentence — *"<name> was not attached.
 * This session is held inside <folder>, so it cannot read a file from anywhere
 * else."* — was true and it was the answer to the wrong question, because the
 * app can simply put the file where the session can read it, and now does. What
 * is left is the residue: a folder, something over the size cap, a disk that
 * would not take it. That is rare, boring, and worth exactly one clause.
 *
 * A count rather than names, for the reason `main/attach-bring-in.ts` returns
 * one: three filenames in a notice line wrap to three lines and stop being a
 * line.
 */
export function bringInRefusal(refused: number): string {
  if (refused <= 0) return ''
  return refused === 1 ? 'One file did not come in.' : `${refused} files did not come in.`
}

/**
 * Copy the picks a confined session cannot read into it, and answer with the
 * list to attach.
 *
 * Order is kept: the batch that comes back is the picks in the order they were
 * dropped, with the ones that were copied replaced by their new paths and the
 * ones that could not be copied left out. A drop of three photos should put
 * three chips up in the order the person dragged them, not the readable ones
 * first.
 */
export async function bringInside(
  bridge: AttachOutsideBridge,
  sessionId: string,
  picks: readonly OutsidePick[],
): Promise<{ picks: OutsidePick[]; refused: number }> {
  if (picks.length === 0) return { picks: [], refused: 0 }
  let answer: { brought: BroughtIn[]; refused: number }
  try {
    answer = readBringIn(await bridge.bringAttachmentsIn(sessionId, picks.map((pick) => pick.path)))
  } catch {
    return { picks: [], refused: picks.length }
  }
  const landed = new Map(answer.brought.map((row) => [row.from, row.path]))
  const inside: OutsidePick[] = []
  for (const pick of picks) {
    const path = landed.get(pick.path)
    // Only files are ever copied, so anything that made it in is one.
    if (path !== undefined) inside.push({ path, isDirectory: false })
  }
  return { picks: inside, refused: answer.refused }
}

/**
 * Can this session actually read that path?
 *
 * `true` for every path on an unconfined session, which is every session
 * started at this keyboard. On a confined one it is containment in the folder
 * the OS is holding it inside, or in any of the projects it was granted.
 *
 * It is not a gate — the operating system enforces the boundary whatever this
 * returns. All it decides now is which picks need {@link bringInside} first: a
 * path already inside is attached where it lies, and a path outside is copied
 * in rather than refused.
 */
export function readableOn(boundary: AttachBoundary, path: string): boolean {
  if (!boundary.confined) return true
  if (boundary.folder !== '' && insideRoot(boundary.folder, path)) return true
  return boundary.projects.some((project) => insideRoot(project, path))
}

/**
 * A batch of picks split into the ones this session can read and the rest.
 *
 * The second half used to be the ones that were *dropped*, with a sentence
 * saying why. It is now the ones that get copied inside first — same split, and
 * the difference is what happens to the right-hand list. See
 * `main/attach-bring-in.ts`.
 *
 * The split still earns its place: a pick already inside the boundary must not
 * be copied. Copying one would write a second copy of a file the session can
 * already open, in a folder nobody chose, and hand the agent the duplicate.
 */
export function splitByBoundary(
  boundary: AttachBoundary,
  picks: readonly OutsidePick[],
): { allowed: OutsidePick[]; refused: OutsidePick[] } {
  const allowed: OutsidePick[] = []
  const refused: OutsidePick[] = []
  for (const pick of picks) (readableOn(boundary, pick.path) ? allowed : refused).push(pick)
  return { allowed, refused }
}

/**
 * Where the open panel should start, for this session.
 *
 * The project, normally — argued at `browseForAttachment`. On a confined
 * session the project may be somewhere the session cannot read at all, and
 * opening a file browser in a directory whose every row will be refused is a
 * worse first frame than opening in the one directory that certainly works.
 */
export function browseStart(boundary: AttachBoundary, root: string): string {
  if (!boundary.confined) return root
  if (root !== '' && readableOn(boundary, root)) return root
  return boundary.folder
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
    'bringAttachmentsIn',
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
