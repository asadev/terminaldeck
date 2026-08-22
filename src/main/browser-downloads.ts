/**
 * Downloads — the compatibility surface over the split.
 *
 * This module used to hold the whole feature. Wave-2 split it so the headless
 * server could carry downloads without Electron under it:
 *
 *  - `browser-downloads-store.ts` — the ledger, the dedup, the digest and the
 *    move-to-another-machine logic, with no Electron in it at all.
 *  - `browser-downloads-electron.ts` — the desktop transport: a `Session`'s
 *    `will-download`, the `DownloadItem` it hands over, and the native dialog
 *    and `shell` that Open, Reveal and the folder chooser reach for.
 *  - `browser-downloads-cdp.ts` — the server transport, driven over CDP.
 *
 * This file re-exports the public surface both halves used to expose from here,
 * so every existing caller — `browser-profiles.ts`, `browser-isolation.ts`,
 * `index.ts` and the two download tests — keeps importing from
 * `./browser-downloads` unchanged. New code should import from the split file it
 * actually needs; this surface is the seam's compatibility layer, not a fourth
 * place logic lives.
 */

export {
  MAX_DOWNLOAD_ROWS,
  DOWNLOADS_CHANNEL,
  downloadsPath,
  readDownloadsFile,
  readDestination,
  chooseSavePath,
  installDownloads,
  resetDownloadsForTests,
  downloadsView,
  setDownloadDestination,
  cancelDownload,
  clearDownloads,
  findDownloadRow,
  downloadName,
  freeDownloadPath,
  MAX_NAME_VARIANTS,
  type DownloadDestination,
  type DownloadState,
  type DownloadRow,
  type DownloadsView,
  type DownloadDeps,
  type DeliveryOutcome,
} from './browser-downloads-store'

export {
  defaultDownloadDir,
  attachDownloads,
  openDownload,
  revealDownload,
  chooseDownloadFolder,
  setDownloadWindow,
  registerBrowserDownloadIpc,
} from './browser-downloads-electron'
