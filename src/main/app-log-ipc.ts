/**
 * The four channels the Debug panel reads the app log through.
 *
 * Split out of `app-log.ts` when the headless build arrived, and the split is
 * along exactly one line: *writing* the log is core — the daemon needs it more
 * than the window does, because a background process's stdout has already been
 * thrown away by systemd or by `wsl.exe` — while *showing* it is a window's job,
 * and `log:open-folder` reaches for `shell.openPath`, which is the file manager
 * on somebody's screen.
 *
 * Leaving those four handlers where they were meant `app-log.ts` imported
 * Electron for one call, and that single import was enough to keep the whole
 * core out of a plain Node process. Nothing here is new; it is the same code
 * with the Electron half on the Electron side of the seam.
 */

import { mkdirSync } from 'node:fs'
import { shell, type IpcMain } from 'electron'
import { appLog } from './app-log'
import { redactLines } from './redact'

export function registerLogIpc(ipcMain: IpcMain): void {
  ipcMain.handle('log:recent', (_event, limit?: number) => {
    const log = appLog()
    const count = Math.min(Math.max(Number(limit) || 200, 1), 2000)
    // Redacted on the way out, not on the way in: the file is as trusted as
    // the rest of userData, but everything the panel shows can be screenshotted.
    return { file: redactLines([log.file])[0], lines: redactLines(log.tail(count)) }
  })

  ipcMain.handle('log:status', () => {
    const status = appLog().status()
    return { ...status, dir: redactLines([status.dir])[0], file: redactLines([status.file])[0] }
  })

  /** Opens the folder in the OS file manager. Returns '' on success. */
  ipcMain.handle('log:open-folder', async () => {
    const log = appLog()
    try {
      mkdirSync(log.dir, { recursive: true })
    } catch {
      /* openPath will report it */
    }
    return shell.openPath(log.dir)
  })

  ipcMain.handle('log:clear', () => {
    appLog().clear()
  })
}
