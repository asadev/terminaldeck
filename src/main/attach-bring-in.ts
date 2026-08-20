/**
 * Bringing a file from anywhere on this disk *inside* a confined session.
 *
 * ## The gesture that had three different answers
 *
 * He asked for one thing:
 *
 *   > *"And photo dropping, the way we did with the phone — also any kind of
 *   > media dropping from your PC to any session should smoothly work."*
 *
 * As shipped, dropping the same photo on the same session did three different
 * things depending on which view was showing. On a **local terminal** the path
 * was typed at the prompt. On a **remote terminal** the file was transferred to
 * the far machine and the path it landed at was typed — `terminal-drop.ts` and
 * `remote/machines/upload-send.ts`. And in the **chat composer**, which is the
 * mode he actually works in, it was *refused*, with a sentence explaining that
 * the session is held inside a folder and cannot read a file from anywhere else.
 *
 * The refusal was true. `confine/escapes.test.ts` measures it: a confined
 * session — one a phone started, or the copilot's own — genuinely cannot open a
 * path outside its grant, so attaching one would have produced a chip, a
 * mention, and an agent a minute later saying it could not read the file.
 *
 * What was wrong is that a true refusal was the *whole* answer. The normal case
 * for a photo is `~/Pictures`, `~/Downloads`, the desktop — never inside the
 * project — so "outside the boundary" is not an edge case for this feature, it
 * is the feature. And the app already knew what to do about it: the remote drop
 * has copied files across a network into `<downloads>/Terminal Deck` since the
 * day it was written. This is the same act over a much shorter distance.
 *
 * ## What it does
 *
 * Copies the file to `<the session's folder>/Terminal Deck/` and answers with
 * the path it landed at, which is inside the boundary and therefore readable.
 * The caller attaches *that* path. The original never moves.
 *
 * The folder is named the same as the one a phone's upload lands in, and for the
 * same reason: a person who finds it should be able to tell at a glance what put
 * it there. Its own directory rather than the grant root, because for a session
 * a phone started the grant root is one of his projects, and a photo dropped
 * into a repository root is litter in somebody's working tree.
 *
 * ## What it will not do
 *
 * **A directory.** A folder from outside would be a recursive copy of unknown
 * size started by a drag, and the thing that makes the file case safe — one
 * named file, one bounded size — is exactly what a folder does not have.
 *
 * **Anything over {@link MAX_UPLOAD_BYTES}.** The same 512 MB the wire path
 * enforces, so the two doors into a session cannot disagree about what is too
 * big to move.
 */

import { constants as fsConstants } from 'node:fs'
import { copyFile, mkdir, stat } from 'node:fs/promises'
import { extname, join } from 'node:path'
import type { IpcMain } from 'electron'
import { BRAND } from '../shared/brand'
import { MAX_UPLOAD_BYTES } from './remote/protocol'
import { safeName } from './remote/uploads'

/** How many `name (2)` variants to try before giving up on a colliding name. */
const MAX_NAME_ATTEMPTS = 99

/** One file that made it in, and the path it made it in *at*. */
export interface BroughtIn {
  /** The path it was dropped from. Lets the caller match answers to requests. */
  from: string
  /** Where it is now. Absolute, inside the boundary, and what gets attached. */
  path: string
}

export interface BringInResult {
  brought: BroughtIn[]
  /**
   * How many were not brought in, for any reason.
   *
   * A count and not a list of sentences. The caller draws one short line and a
   * file that will not copy is a rare, boring failure — a folder, something too
   * big, a disk that is full. Four explanations of four different failures on a
   * composer would be the paragraph this whole pass is removing.
   */
  refused: number
}

/** `photo.jpg`, then `photo (2).jpg`. Lazily, so most names cost one attempt. */
function* nameVariants(name: string): Generator<string> {
  yield name
  const extension = extname(name)
  const stem = extension === '' ? name : name.slice(0, -extension.length)
  for (let n = 2; n <= MAX_NAME_ATTEMPTS; n += 1) yield `${stem} (${n})${extension}`
}

/** Where files brought into a session land. Created when the first one arrives. */
export function bringInDir(folder: string): string {
  return join(folder, BRAND.name)
}

/**
 * Copy one file into `folder`, and answer with the path it landed at.
 *
 * Reserved by *creating* the file with `COPYFILE_EXCL` rather than by asking
 * whether the name is free and then writing it. Two drops of the same photo a
 * moment apart both get an answer from a `stat`, and both then write to the same
 * path; the exclusive copy fails for the second, which is the whole difference
 * between a check and a reservation. A second `photo.jpg` lands beside the first
 * rather than over it — the same rule `diskUploadStore` holds to.
 */
export async function bringOneIn(source: string, folder: string): Promise<string | null> {
  let size: number
  try {
    const info = await stat(source)
    // Not a directory, and not a device or a socket either: `isFile` is the
    // question, and everything else is something a copy would do nothing useful
    // with.
    if (!info.isFile()) return null
    size = info.size
  } catch {
    return null
  }
  if (size > MAX_UPLOAD_BYTES) return null

  const dir = bringInDir(folder)
  try {
    await mkdir(dir, { recursive: true })
  } catch {
    return null
  }

  const wanted = safeName(source)
  for (const candidate of nameVariants(wanted)) {
    const target = join(dir, candidate)
    try {
      await copyFile(source, target, fsConstants.COPYFILE_EXCL)
      return target
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'EEXIST') continue
      return null
    }
  }
  return null
}

export const ATTACH_BRING_IN_CHANNEL = 'attach:bring-in'

export interface BringInDeps {
  /**
   * What this session is held inside, or null when it is held inside nothing.
   *
   * The same function `attach:boundary` is built on, and asking it here rather
   * than trusting a folder from the renderer is the point: this handler writes
   * to a directory, and a window that could name that directory would be a
   * window that could write a file anywhere on the disk.
   */
  boundaryOf(sessionId: string): { folder: string } | null
}

export function registerAttachBringInIpc(ipcMain: IpcMain, deps: BringInDeps): void {
  ipcMain.handle(
    ATTACH_BRING_IN_CHANNEL,
    async (_event, sessionId: unknown, paths: unknown): Promise<BringInResult> => {
      const none: BringInResult = { brought: [], refused: 0 }
      if (typeof sessionId !== 'string' || sessionId === '') return none
      if (!Array.isArray(paths)) return none
      const wanted = paths.filter((path): path is string => typeof path === 'string' && path !== '')
      if (wanted.length === 0) return none

      // An unconfined session has nothing to be brought inside of, and copying
      // for one would be this app writing a second copy of a file the person
      // already has, in a folder they did not choose.
      const boundary = deps.boundaryOf(sessionId)
      if (boundary === null || boundary.folder === '') return { brought: [], refused: wanted.length }

      const brought: BroughtIn[] = []
      let refused = 0
      // One at a time, so a 400 MB video does not have three other copies racing
      // it for the same disk.
      for (const from of wanted) {
        const landed = await bringOneIn(from, boundary.folder)
        if (landed === null) refused += 1
        else brought.push({ from, path: landed })
      }
      return { brought, refused }
    },
  )
}
