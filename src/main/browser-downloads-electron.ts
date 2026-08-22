import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { app, dialog, shell, type BrowserWindow, type DownloadItem, type IpcMain, type Session } from 'electron'
import { BRAND } from '../shared/brand'
import {
  cancelDownload,
  chooseSavePath,
  clearDownloads,
  completeDownload,
  downloadDestination,
  downloadName,
  downloadsView,
  findDownloadRow,
  forgetDownloadCanceller,
  nextDownloadId,
  patchDownloadRow,
  putDownloadRow,
  registerDownloadCanceller,
  saveDownloads,
  setDownloadDestination,
  stagingDir,
} from './browser-downloads-store'

/**
 * Downloads on the desktop: the Electron half of the ledger.
 *
 * ## What this is, and what it is not
 *
 * The reasoning for *why downloads exist at all* — the refusal that was here
 * before, "nothing is allowed to vanish quietly", why a delivery is a move — is
 * in `browser-downloads-store.ts`, which is where the rows and the move live and
 * which has no Electron in it. This file is the part that could not follow it
 * across the seam: an Electron `Session`'s `will-download` event, the
 * `DownloadItem` it hands over, and the native dialog and `shell` a person's
 * Open and Reveal reach for. The server's equivalent is
 * `browser-downloads-cdp.ts`, and both feed the one store through the same feed
 * functions, so a download looks identical on the panel whichever transport
 * fetched it.
 *
 * ## Where a file lands, and the one thing this cannot do
 *
 * The page is always fetched by *this* process — the browser panel is an
 * Electron `WebContentsView` on this desktop even when its address bar is
 * pointed at another machine's `localhost` through a tunnel. So every download
 * begins on this disk, and "download it onto the Office PC" is necessarily
 * *fetch here, then hand it over*. That ordering is his too:
 *
 *   > *"So it will download from internet first of all, and then it will move to
 *   > that path, whatever path we want to have the thing. So this will move
 *   > there and delete from previous place"*
 */

/** This machine's downloads folder: the one every other transfer already uses. */
export function defaultDownloadDir(): string {
  return join(app.getPath('downloads'), BRAND.name)
}

/* -------------------------------------------------------------- the event -- */

/**
 * Wire one guest session's downloads.
 *
 * Called from `harden()` in both `browser-profiles.ts` and
 * `browser-isolation.ts`, which is not a duplication to be tidied away: those
 * two are the only places a guest partition is minted, and a build where one of
 * them called this and the other did not would download from ordinary tabs and
 * silently refuse from isolated ones. `browser-isolation.test.ts` asserts the
 * event list for that reason.
 *
 * The save path is set synchronously inside the handler, which is what stops
 * Chromium opening its own Save-As sheet. There is deliberately no "ask where to
 * save each file": the destination can be another computer, and a native sheet
 * cannot offer a folder on one.
 */
export function attachDownloads(ses: Session): void {
  ses.on('will-download', (_event, item: DownloadItem) => {
    const id = nextDownloadId()
    const suggested = item.getFilename()
    const bound = downloadDestination()

    let savePath: string
    try {
      savePath = chooseSavePath(bound, stagingDir() || defaultDownloadDir(), suggested)
      item.setSavePath(savePath)
    } catch (error) {
      /*
       * The folder could not be made — a path that is a file, a permission, a
       * drive that is not mounted any more. Cancelling is the only thing left to
       * do with the item, and the row is what stops it being a click that did
       * nothing.
       */
      item.cancel()
      putDownloadRow({
        id,
        name: downloadName(suggested),
        url: item.getURL(),
        bytes: item.getTotalBytes(),
        received: 0,
        state: 'failed',
        path: '',
        onMachine: '',
        onMachineName: '',
        message: `That folder could not be written to — ${
          error instanceof Error ? error.message : 'unknown reason'
        }.`,
        startedAt: Date.now(),
        digest: '',
      })
      saveDownloads()
      return
    }

    registerDownloadCanceller(id, () => item.cancel())
    putDownloadRow({
      id,
      name: downloadName(suggested),
      url: item.getURL(),
      bytes: item.getTotalBytes(),
      received: 0,
      state: 'downloading',
      path: savePath,
      onMachine: '',
      onMachineName: '',
      message: '',
      startedAt: Date.now(),
      digest: '',
    })
    /*
     * Written down as soon as it exists, rather than only when it ends.
     *
     * Every other branch below saves at its own ending, and the cross-machine
     * one used to be the single path whose *first* save was after the far
     * machine had answered and the local copy had been unlinked. Quitting in
     * the middle of that — which is most of the wall-clock time of a large file
     * going to another computer — lost every trace that the download had ever
     * been asked for. `load()` reads a `downloading` row back as a failure,
     * which is exactly right for a row this save leaves behind.
     */
    saveDownloads()

    /*
     * `updated` also fires with `interrupted`, and that is not an ending — the
     * item can still resume. So the row stays `downloading` and the bar simply
     * stops moving, which is the honest drawing of a stall. Only `done` decides.
     */
    item.on('updated', () => {
      patchDownloadRow(id, { received: item.getReceivedBytes(), bytes: item.getTotalBytes() })
    })

    item.once('done', (_doneEvent, state) => {
      forgetDownloadCanceller(id)
      if (state === 'cancelled') {
        patchDownloadRow(id, {
          state: 'cancelled',
          received: item.getReceivedBytes(),
          message: 'Stopped.',
        })
        saveDownloads()
        return
      }
      if (state !== 'completed') {
        patchDownloadRow(id, {
          state: 'failed',
          received: item.getReceivedBytes(),
          message: 'The download was interrupted.',
        })
        saveDownloads()
        return
      }
      const landed = item.getSavePath() || savePath
      patchDownloadRow(id, {
        received: item.getReceivedBytes(),
        bytes: item.getTotalBytes(),
        path: landed,
      })
      // The same reason as the save above: the file is on this disk now, and
      // that is worth knowing even if the delivery after it never returns.
      saveDownloads()
      /*
       * The destination is read as it was when the download *started*, not as it
       * is now. Changing where downloads go while one is in flight should decide
       * the next one, not redirect a file somebody already asked for — and the
       * alternative is a file that lands on a machine nobody chose for it.
       */
      completeDownload(id, landed, bound)
    })
  })
}

/* --------------------------------------------------------------- the API -- */

/**
 * Open a finished download, or say why it cannot be opened.
 *
 * Refuses for a file on another machine rather than opening something else: the
 * path in the row is a path over there, and `shell.openPath` would resolve it
 * against this disk and either fail obscurely or open a different file with the
 * same name. The panel does not draw the button in that case; this is the second
 * guard, because a channel is reachable from more places than one component.
 */
export async function openDownload(id: unknown): Promise<{ ok: boolean; message: string }> {
  const row = findDownloadRow(id)
  if (!row) return { ok: false, message: 'That download is not in the list any more.' }
  if (row.onMachine !== '') {
    return { ok: false, message: `That file is on ${row.onMachineName || 'another machine'}.` }
  }
  if (row.path === '' || !existsSync(row.path)) {
    return { ok: false, message: 'That file is not there any more.' }
  }
  const problem = await shell.openPath(row.path)
  return problem === '' ? { ok: true, message: '' } : { ok: false, message: problem }
}

/** Show a finished download in Finder or Explorer. Same refusals as {@link openDownload}. */
export function revealDownload(id: unknown): { ok: boolean; message: string } {
  const row = findDownloadRow(id)
  if (!row) return { ok: false, message: 'That download is not in the list any more.' }
  if (row.onMachine !== '') {
    return { ok: false, message: `That file is on ${row.onMachineName || 'another machine'}.` }
  }
  if (row.path === '' || !existsSync(row.path)) {
    return { ok: false, message: 'That file is not there any more.' }
  }
  shell.showItemInFolder(row.path)
  return { ok: true, message: '' }
}

/**
 * The native folder chooser, for a destination on **this** machine.
 *
 * Only this machine: a folder on another computer cannot be picked with a sheet
 * that reads this one's filesystem, and a chooser that quietly returned a local
 * path while the destination said "Office PC" would be the exact class of lie
 * this pass is removing. The other machines' folders come from those machines —
 * see the picker in `DownloadsPanel.tsx`.
 */
export async function chooseDownloadFolder(): Promise<string> {
  const parent = downloadWindow?.() ?? null
  const options = {
    properties: ['openDirectory' as const, 'createDirectory' as const],
    defaultPath: downloadsView().destination.folder || stagingDir() || defaultDownloadDir(),
  }
  const answer = parent
    ? await dialog.showOpenDialog(parent, options)
    : await dialog.showOpenDialog(options)
  return answer.canceled || answer.filePaths.length === 0 ? '' : answer.filePaths[0]
}

/**
 * The window a folder-chooser sheet hangs from.
 *
 * Kept on this Electron-only module rather than in the store's `DownloadDeps`,
 * because a `BrowserWindow` is exactly the kind of thing the store must never
 * name. `index.ts` sets it beside `installDownloads`.
 */
let downloadWindow: (() => BrowserWindow | null) | undefined

export function setDownloadWindow(next: () => BrowserWindow | null): void {
  downloadWindow = next
}

/* -------------------------------------------------------------- register -- */

/**
 * Wire downloads. Call once from `registerIpc()`, before any tab is opened:
 *
 *     installDownloads({ userData, defaultDir, broadcast, deliver })
 *     setDownloadWindow(() => mainWindow)
 *     registerBrowserDownloadIpc(ipcMain)
 *
 * Channels:
 * - `browser-download:list`        (invoke)          → DownloadsView
 * - `browser-download:destination` (invoke, dest)    → DownloadsView
 * - `browser-download:cancel`      (invoke, id)      → DownloadsView
 * - `browser-download:clear`       (invoke)          → DownloadsView
 * - `browser-download:open`        (invoke, id)      → `{ ok, message }`
 * - `browser-download:reveal`      (invoke, id)      → `{ ok, message }`
 * - `browser-download:folder`      (invoke)          → a path, or `''`
 */
export function registerBrowserDownloadIpc(ipcMain: IpcMain): void {
  ipcMain.handle('browser-download:list', () => downloadsView())
  ipcMain.handle('browser-download:destination', (_event, dest: unknown) =>
    setDownloadDestination(dest),
  )
  ipcMain.handle('browser-download:cancel', (_event, id: unknown) => cancelDownload(id))
  ipcMain.handle('browser-download:clear', () => clearDownloads())
  ipcMain.handle('browser-download:open', (_event, id: unknown) => openDownload(id))
  ipcMain.handle('browser-download:reveal', (_event, id: unknown) => revealDownload(id))
  ipcMain.handle('browser-download:folder', () => chooseDownloadFolder())
}
