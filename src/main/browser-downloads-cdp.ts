import { copyFileSync, existsSync, renameSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import {
  chooseSavePath,
  completeDownload,
  downloadDestination,
  downloadName,
  failDownload,
  forgetDownloadCanceller,
  nextDownloadId,
  patchDownloadRow,
  putDownloadRow,
  saveDownloads,
  type DownloadDestination,
} from './browser-downloads-store'

/**
 * Downloads on the server: the CDP half of the ledger.
 *
 * ## The shape of a download with no `will-download` under it
 *
 * The desktop learns a file is coming through an Electron `Session`'s
 * `will-download` event and drives an Electron `DownloadItem`
 * (`browser-downloads-electron.ts`). A headless server has neither. What it has
 * is CDP's own download protocol, armed once per browser context:
 *
 *     Browser.setDownloadBehavior { behavior: 'allowAndName',
 *                                   downloadPath: <the host downloads dir>,
 *                                   eventsEnabled: true }
 *
 * and then two events — `Browser.downloadWillBegin` when one starts and
 * `Browser.downloadProgress` as it moves and when it ends. Both feed the *same*
 * ledger the desktop does, through the same feed functions in
 * `browser-downloads-store.ts`, so a file fetched on the server looks identical
 * on the panel to one fetched on the desktop.
 *
 * ## Why `allowAndName`, and why a rename at the end
 *
 * `allowAndName` is the only download behaviour the screening will pass — the
 * whole escalation the desktop refused this call over was a *caller-named*
 * directory, and `screenDownloadBehavior` in `browser-cdp.ts` closes it by
 * pinning both the behaviour and the path. Under it Chromium writes the file
 * into the pinned directory under its **GUID** as the filename, not the name the
 * server suggested. So the naming this app cares about — one path component, no
 * `../`, the dedup that stops two `report.pdf`s colliding — is done here with the
 * same `chooseSavePath` the desktop uses, and when the download completes the
 * GUID file is moved onto that chosen path. The move is a rename where it can be
 * one and a copy-then-remove across a filesystem boundary, because a chosen
 * folder may be on a different volume from the downloads dir.
 *
 * ## What this does not do: stop a download
 *
 * There is no canceller registered for a CDP row. `Browser.cancelDownload` is
 * deliberately absent from the CDP allow-list (`browser-cdp.ts`), so a Stop
 * pressed on a server download would be a command the screened channel refuses —
 * and a button that looks like it worked and did not is the class of lie the
 * downloads pass exists to remove. Cancellation over CDP is a later concern; a
 * `Browser.downloadProgress` with `state: 'canceled'` (the browser's own doing,
 * or a context torn down) is still honoured and lands a `cancelled` row.
 *
 * ## No Electron
 *
 * `node:fs` and `node:path` only. This module is in the headless closure the
 * server walks; the CDP transport it talks to is injected as {@link
 * CdpDownloadChannel}, wired to the driver's screened `send` and the pipe's
 * event demux by the host.
 */

/* ------------------------------------------------------------ the channel -- */

/**
 * The slice of the CDP transport this module needs.
 *
 * `send` is the driver's screened send — every command here is checked by
 * `screenCommand({ transport: 'cdp', … })` before it reaches the wire, so
 * `Browser.setDownloadBehavior`'s path is pinned to `downloadsDir` upstream, not
 * trusted from in here. `on` subscribes to one browser-level event method and
 * returns an unsubscribe.
 */
export interface CdpDownloadChannel {
  send(method: string, params?: unknown): Promise<unknown>
  on(method: string, handler: (params: Record<string, unknown>) => void): () => void
}

export interface CdpDownloadDeps {
  channel: CdpDownloadChannel
  /**
   * The host downloads directory. Two jobs: it is the `downloadPath` pinned into
   * `Browser.setDownloadBehavior` (and the value `screenDownloadBehavior`
   * requires it to equal), and it is where a completed file waits under its GUID
   * before the move.
   */
  downloadsDir: string
  /**
   * The dir a fetch stages into when no local folder was chosen. Defaults to the
   * downloads dir; the desktop uses `deps.defaultDir()` and the two are the same
   * place on a server.
   */
  stagingDir?: string
  /** Move a finished file onto its chosen path. Injected for tests; defaults below. */
  moveFile?: (from: string, to: string) => void
  /** Does a path exist? Injected for tests; defaults to `node:fs`. */
  exists?: (path: string) => boolean
}

/** What the install hands back: how to stop listening, and when the arming settled. */
export interface CdpDownloadHandle {
  /** Stop listening for download events. Does not disarm the browser. */
  dispose(): void
  /** Resolves when `Browser.setDownloadBehavior` has been acknowledged (or refused). */
  ready: Promise<void>
}

/** What we remember between a download's begin and its end, keyed by GUID. */
interface Pending {
  id: string
  savePath: string
  bound: DownloadDestination
}

/**
 * Move a completed download onto its chosen path.
 *
 * A rename where it can be one — same filesystem, one syscall, no second copy of
 * a two-gigabyte file — and a copy-then-remove across a boundary, because a
 * chosen folder can be on a different volume from the downloads dir and
 * `renameSync` answers `EXDEV` there. The remove is of the GUID staging file
 * only, after the copy has landed, which is the same "confirm before delete"
 * discipline the cross-machine delivery keeps.
 */
function defaultMove(from: string, to: string): void {
  try {
    renameSync(from, to)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EXDEV') throw error
    copyFileSync(from, to)
    rmSync(from, { force: true })
  }
}

function count(raw: unknown): number {
  return typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : 0
}

/**
 * Arm CDP downloads and feed the ledger from the browser's own events.
 *
 * Call once per browser context that may download — its events all carry the
 * context's session on the pipe, and the host subscribes {@link
 * CdpDownloadChannel.on} to that session. Returns a handle whose `dispose`
 * stops the two subscriptions.
 */
export function installCdpDownloads(deps: CdpDownloadDeps): CdpDownloadHandle {
  const { channel, downloadsDir } = deps
  const stagingDir = deps.stagingDir ?? downloadsDir
  const moveFile = deps.moveFile ?? defaultMove
  const exists = deps.exists ?? existsSync
  const pending = new Map<string, Pending>()

  function onWillBegin(params: Record<string, unknown>): void {
    const guid = typeof params.guid === 'string' ? params.guid : ''
    if (guid === '') return
    const url = typeof params.url === 'string' ? params.url : ''
    const suggested = typeof params.suggestedFilename === 'string' ? params.suggestedFilename : ''
    const bound = downloadDestination()
    const id = nextDownloadId()

    let savePath: string
    try {
      savePath = chooseSavePath(bound, stagingDir, suggested)
    } catch (error) {
      /*
       * The folder could not be made — the same class of failure the desktop
       * handler turns into a `failed` row rather than a click that did nothing.
       * The GUID file, if the browser already wrote it, is left where it is: no
       * chosen path means nowhere to move it to, and deleting on a failure is how
       * a download becomes no file at all.
       */
      putDownloadRow({
        id,
        name: downloadName(suggested),
        url,
        bytes: 0,
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

    pending.set(guid, { id, savePath, bound })
    putDownloadRow({
      id,
      name: downloadName(suggested),
      url,
      bytes: 0,
      received: 0,
      state: 'downloading',
      // The row points at where the file *will* be, not the GUID staging name,
      // because that is the path a person opens and the panel reveals.
      path: savePath,
      onMachine: '',
      onMachineName: '',
      message: '',
      startedAt: Date.now(),
      digest: '',
    })
    saveDownloads()
  }

  function onProgress(params: Record<string, unknown>): void {
    const guid = typeof params.guid === 'string' ? params.guid : ''
    const entry = guid === '' ? undefined : pending.get(guid)
    if (entry === undefined) return
    const received = count(params.receivedBytes)
    const total = count(params.totalBytes)
    const state = params.state

    if (state === 'inProgress') {
      patchDownloadRow(entry.id, { received, bytes: total })
      return
    }

    // Either ending removes the GUID from the map; there is nothing more coming
    // for it.
    pending.delete(guid)
    forgetDownloadCanceller(entry.id)

    if (state === 'canceled') {
      patchDownloadRow(entry.id, { state: 'cancelled', received, message: 'Stopped.' })
      saveDownloads()
      return
    }

    if (state !== 'completed') {
      // The protocol only names inProgress/completed/canceled, but an unknown
      // state is still an ending, and an ending that is not a completion is a
      // failure — the honest reading of a download that stopped moving.
      failDownload(entry.id, 'The download did not finish.')
      return
    }

    const guidPath = join(downloadsDir, guid)
    try {
      moveFile(guidPath, entry.savePath)
    } catch (error) {
      // The bytes are still on disk under the GUID name; point the row at them
      // rather than lose the trace.
      failDownload(
        entry.id,
        `The download could not be saved — ${error instanceof Error ? error.message : 'unknown reason'}.`,
        exists(guidPath) ? guidPath : '',
      )
      return
    }

    patchDownloadRow(entry.id, {
      received: received || total,
      bytes: total || received,
      path: entry.savePath,
    })
    // The file is on this disk now, and that is worth knowing even if the
    // delivery after it never returns.
    saveDownloads()
    // Local downloads seal here; cross-machine ones deliver. The destination is
    // the snapshot the download *started* with, taken in `onWillBegin`.
    completeDownload(entry.id, entry.savePath, entry.bound)
  }

  const offBegin = channel.on('Browser.downloadWillBegin', onWillBegin)
  const offProgress = channel.on('Browser.downloadProgress', onProgress)

  /*
   * Arm last, so a `downloadWillBegin` that races the acknowledgement already has
   * its listener. A refusal here (the screening said no, or the pipe is gone) is
   * swallowed to `void`: it means no downloads, not a crash, the same way a
   * missing binary is a named non-event elsewhere in this feature.
   */
  const ready = channel
    .send('Browser.setDownloadBehavior', {
      behavior: 'allowAndName',
      downloadPath: downloadsDir,
      eventsEnabled: true,
    })
    .then(() => undefined)
    .catch(() => undefined)

  return {
    dispose() {
      offBegin()
      offProgress()
    },
    ready,
  }
}
