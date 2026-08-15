import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, isAbsolute, join, resolve } from 'node:path'
import { app } from 'electron'

/**
 * Per-project dashboard layout persistence.
 *
 * One JSON file per project under `<userData>/dashboards/`, so a corrupt or
 * oversized layout can only ever affect the project it belongs to.
 *
 * This is a deliberately dumb, durable store: it guards the *shape* of what it
 * writes and hands back whatever it read. Repair, migration and collision
 * fixing live in `src/renderer/dashboard/layout.ts` beside their tests, and the
 * main-process bundle has no reason to reach into renderer code to do them.
 */

/** Refuse anything larger. A real layout is a few hundred bytes. */
const MAX_LAYOUT_BYTES = 512 * 1024

/** A dashboard of more tiles than this is a runaway loop, not a user's choice. */
const MAX_WIDGETS = 200

/**
 * Filename for a project's layout: readable prefix plus a hash of the absolute
 * path. The hash is the real identity — two folders called `web` in different
 * trees must not share a dashboard, and the path itself contains separators
 * the filesystem would reject.
 */
export function dashboardFileName(projectPath: string): string {
  // Resolve before hashing. `/w/app` and `/w/app/` are the same project, and a
  // raw hash gives them different files — the user opens the folder one way,
  // gets the starter dashboard back, and it looks like their arrangement was
  // thrown away.
  const canonical = resolve(projectPath)
  const slug = basename(canonical).replace(/[^a-zA-Z0-9._-]+/g, '-').slice(0, 40)
  const hash = createHash('sha256').update(canonical).digest('hex').slice(0, 10)
  return `${slug || 'project'}-${hash}.json`
}

function dashboardsDir(): string {
  return join(app.getPath('userData'), 'dashboards')
}

export function dashboardFilePath(projectPath: string): string {
  return join(dashboardsDir(), dashboardFileName(projectPath))
}

function assertProjectPath(projectPath: unknown): asserts projectPath is string {
  if (typeof projectPath !== 'string' || !isAbsolute(projectPath)) {
    throw new Error('dashboard: an absolute project path is required')
  }
}

/**
 * Structural gate, not a validator — it only decides whether a payload is
 * layout-shaped enough to be worth persisting. Field-level repair happens in
 * the renderer when the layout is read back.
 *
 * An empty `widgets` array passes on purpose: a user who removes every tile
 * has expressed a preference, and refusing to store it would hand them the
 * starter dashboard again on the next launch.
 */
function isLayoutLike(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return Array.isArray(candidate.widgets) && candidate.widgets.length <= MAX_WIDGETS
}

/**
 * Read a project's layout. Returns `null` when there is nothing usable — first
 * run, a deleted file, or truncated JSON — which `parseLayout` in the renderer
 * turns into the default dashboard.
 */
export function loadDashboard(projectPath: string): unknown {
  assertProjectPath(projectPath)
  const file = dashboardFilePath(projectPath)
  try {
    // Check the size before reading. Capping only the write path is no cap at
    // all: a hand-edited or externally written file would still be pulled into
    // memory whole and then parsed into something several times larger.
    const { size } = statSync(file)
    if (size > MAX_LAYOUT_BYTES) {
      console.error(`[dashboard] ignoring an oversized layout file (${size} bytes):`, file)
      return null
    }
    return JSON.parse(readFileSync(file, 'utf8')) as unknown
  } catch (err) {
    // A missing file is the normal first-run case, so only shout about the rest.
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('[dashboard] unreadable layout, falling back to the default:', err)
    }
    return null
  }
}

/**
 * Write a project's layout.
 *
 * The write goes to a temp file that is then renamed over the target: rename is
 * atomic within a filesystem, so a crash or a power cut mid-write leaves the
 * previous layout intact rather than a truncated file that would read back as
 * "no layout" and silently reset the user's arrangement.
 */
export function saveDashboard(projectPath: string, layout: unknown): void {
  assertProjectPath(projectPath)
  if (!isLayoutLike(layout)) {
    throw new Error('dashboard: refusing to save a payload that is not a layout')
  }

  // Persist the caller's path, never one carried in the payload, so a layout
  // can never claim to belong to a different project.
  const json = JSON.stringify({ ...layout, projectPath }, null, 2)
  // Bytes, not UTF-16 code units — the cap must mean the same thing for a file
  // full of non-ASCII widget ids as for an ASCII one.
  if (Buffer.byteLength(json, 'utf8') > MAX_LAYOUT_BYTES) {
    throw new Error('dashboard: payload too large to save')
  }

  const file = dashboardFilePath(projectPath)
  // Scoped to this process: two windows saving the same project must not write
  // through each other's temp file and rename a half-written layout into place.
  const tmp = `${file}.${process.pid}.tmp`
  mkdirSync(dashboardsDir(), { recursive: true })

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

/** Forget a project's layout, so the next open starts from the defaults. */
export function clearDashboard(projectPath: string): void {
  assertProjectPath(projectPath)
  try {
    unlinkSync(dashboardFilePath(projectPath))
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
  }
}

/**
 * Wire the dashboard channels into the main process.
 * Call once during startup: `registerDashboardIpc(ipcMain)`.
 *
 * Channels:
 *  - `dashboard:load`  (projectPath)         -> unknown | null
 *  - `dashboard:save`  (projectPath, layout) -> void
 *  - `dashboard:clear` (projectPath)         -> void
 */
export function registerDashboardIpc(ipcMain: Electron.IpcMain): void {
  ipcMain.handle('dashboard:load', (_e, projectPath: string) => loadDashboard(projectPath))
  ipcMain.handle('dashboard:save', (_e, projectPath: string, layout: unknown) => {
    saveDashboard(projectPath, layout)
  })
  ipcMain.handle('dashboard:clear', (_e, projectPath: string) => {
    clearDashboard(projectPath)
  })
}
