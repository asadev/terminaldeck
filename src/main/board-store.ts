import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, isAbsolute, join, resolve } from 'node:path'
import { app } from 'electron'

/**
 * Per-project kanban persistence.
 *
 * One JSON file per project under `<userData>/boards/`, rather than one big
 * document, so a corrupt or oversized board can only ever affect its own
 * project.
 *
 * This module is deliberately a dumb, durable store: it guards the *shape* of
 * what it writes and hands back whatever it read, while the board model in
 * `src/renderer/board/board-state.ts` owns migration and repair through
 * `parseBoard`. Keeping the model out of here means the main-process bundle
 * has no reason to reach into renderer code, and repair logic lives in exactly
 * one place with its tests beside it.
 */

/** Refuse anything larger. A real board is a few KB; a megabyte means a bug. */
const MAX_BOARD_BYTES = 4 * 1024 * 1024

/**
 * Filename for a project's board: readable prefix plus a hash of the absolute
 * path. The hash is what actually identifies the project — two folders called
 * `web` in different trees must not share a board, and the path itself cannot
 * be used directly because it contains separators the filesystem would reject.
 */
export function boardFileName(projectPath: string): string {
  // Resolve before hashing. `/w/app` and `/w/app/` are the same project, and a
  // raw hash gives them different files — the user opens the folder one way,
  // gets an empty board, and it looks like every card was deleted.
  const canonical = resolve(projectPath)
  const slug = basename(canonical).replace(/[^a-zA-Z0-9._-]+/g, '-').slice(0, 40)
  const hash = createHash('sha256').update(canonical).digest('hex').slice(0, 10)
  return `${slug || 'project'}-${hash}.json`
}

function boardsDir(): string {
  return join(app.getPath('userData'), 'boards')
}

export function boardFilePath(projectPath: string): string {
  return join(boardsDir(), boardFileName(projectPath))
}

function assertProjectPath(projectPath: unknown): asserts projectPath is string {
  if (typeof projectPath !== 'string' || !isAbsolute(projectPath)) {
    throw new Error('board: an absolute project path is required')
  }
}

/**
 * Structural gate, not a validator — it only decides whether a payload is
 * board-shaped enough to be worth persisting. Field-level repair happens in
 * the renderer when the board is read back.
 */
function isBoardLike(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return (
    Array.isArray(candidate.columns) &&
    typeof candidate.cards === 'object' &&
    candidate.cards !== null &&
    !Array.isArray(candidate.cards)
  )
}

/**
 * Read a project's board file. Returns `null` when there is nothing usable —
 * first run, a deleted file, or truncated JSON — which `parseBoard` in the
 * renderer turns into an empty board.
 */
export function loadBoard(projectPath: string): unknown {
  assertProjectPath(projectPath)
  const file = boardFilePath(projectPath)
  try {
    // Check the size before reading. Capping only the write path is no cap at
    // all: a hand-edited or externally written file would still be pulled into
    // memory whole and then parsed into something several times larger again.
    const { size } = statSync(file)
    if (size > MAX_BOARD_BYTES) {
      console.error(`[board] ignoring an oversized board file (${size} bytes):`, file)
      return null
    }
    return JSON.parse(readFileSync(file, 'utf8')) as unknown
  } catch (err) {
    // A missing file is the normal first-run case, so only shout about the rest.
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('[board] unreadable board, starting a fresh one:', err)
    }
    return null
  }
}

/**
 * Write a project's board.
 *
 * The write goes to a temp file that is then renamed over the target: rename
 * is atomic within a filesystem, so a crash or a power cut mid-write leaves
 * the previous board intact rather than a truncated file that would read back
 * as an empty board and look like the user's cards had been deleted.
 */
export function saveBoard(projectPath: string, board: unknown): void {
  assertProjectPath(projectPath)
  if (!isBoardLike(board)) {
    throw new Error('board: refusing to save a payload that is not a board')
  }

  // Persist the caller's path, never one carried in the payload, so a board
  // can never claim to belong to a different project.
  const json = JSON.stringify({ ...board, projectPath }, null, 2)
  // Bytes, not UTF-16 code units: a board written in Arabic or Chinese is
  // three times longer on disk than `json.length` claims, so measuring the
  // string would let a 12 MB file through a 4 MB cap.
  if (Buffer.byteLength(json, 'utf8') > MAX_BOARD_BYTES) {
    throw new Error('board: payload too large to save')
  }

  const file = boardFilePath(projectPath)
  // Scoped to this process: two windows saving the same project must not write
  // through each other's temp file and rename a half-written board into place.
  const tmp = `${file}.${process.pid}.tmp`
  mkdirSync(boardsDir(), { recursive: true })

  try {
    writeFileSync(tmp, json, 'utf8')
    renameSync(tmp, file)
  } catch (err) {
    // Leaving the temp file behind would make a later partial write look like
    // a complete one.
    try {
      unlinkSync(tmp)
    } catch {
      // Already gone, or never created — nothing to clean up.
    }
    throw err
  }
}

/**
 * Wire the board channels into the main process.
 * Call once during startup: `registerBoardIpc(ipcMain)`.
 */
export function registerBoardIpc(ipcMain: Electron.IpcMain): void {
  ipcMain.handle('board:load', (_e, projectPath: string) => loadBoard(projectPath))
  ipcMain.handle('board:save', (_e, projectPath: string, board: unknown) => {
    saveBoard(projectPath, board)
  })
}
