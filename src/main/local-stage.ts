/**
 * Bytes this window is holding, written to a file on **this** machine.
 *
 * ## Why anything needs this
 *
 * Every other way of handing a file to a session starts from a path. A drag out
 * of Finder has one; a screenshot the browser took has one. A **paste** does
 * not: ⌘⇧⌃4 on a Mac, *Copy image* in a web page, or anything else a program put
 * on the clipboard as pixels arrives as bytes with no file behind it anywhere.
 *
 * Both halves of the transfer rule in `renderer/session-transfer.ts` need a
 * file. A session on this machine has to be handed a path to something that
 * exists; a session on another machine goes through `upload-send.ts`, which
 * reads from a path **by design** — handing it an ArrayBuffer would put a large
 * paste through two heaps on its way to a third computer, which is the argument
 * `preload/index.ts` already makes about `uploadToMachine` taking a path.
 *
 * So the bytes become a file here, once, and the ordinary rule then runs over
 * the path that produced. There is no second transfer: this writes a local file
 * and nothing else, and the cross-machine leg is the same four `upload.*` verbs
 * the phone sends.
 *
 * ## Why it lands where an upload lands
 *
 * The same folder a file *from* a phone lands in — `<downloads>/Terminal Deck`,
 * which `index.ts` passes as `uploadsDir` — and through the same
 * {@link diskUploadStore}, which is what gives it the same collision rule: a
 * second paste of the same name lands *beside* the first rather than over it,
 * with the name the store chose answered back. A pasted screenshot sent to a
 * remote session therefore ends up at the same shape of path on both machines,
 * which is the least surprising thing that can happen to it and is one fewer
 * difference between "here" and "there" for somebody to notice.
 *
 * Deliberately not a temporary directory, for the reason `diskUploadStore`
 * already gives: the point is that the file is *there afterwards*, because an
 * agent may open it minutes later.
 *
 * ## Why the renderer cannot name the folder
 *
 * It sends a **name**; `safeName` reduces that to one path component and the
 * directory is a function this module was handed. That is the same rule
 * `uploads.ts` opens with, and it is the same rule for the same reason one layer
 * in: a channel that built a path out of two pieces of caller input would be a
 * `writeFile` anywhere on the disk.
 */

import type { IpcMain } from 'electron'
import { byteSize } from '../shared/byte-size'
import { MAX_UPLOAD_BYTES } from './remote/protocol'
import { diskUploadStore, safeName } from './remote/uploads'

/** The channel. One verb, one answer: a path on this machine, or a sentence. */
export const STAGE_CHANNEL = 'transfer:stage'

/** What the renderer gets back. The same shape `machines:upload` answers with. */
export type StageResult = { ok: true; path: string } | { ok: false; message: string }

export interface StageDeps {
  /** Where files land. A function, because the folder is resolved from `app`. */
  dir(): string
}

/**
 * Write one blob and answer where it went.
 *
 * Separated from the IPC registration so it can be exercised against a real
 * temporary folder in a test without an Electron main process — the interesting
 * half is the refusals and the path, and neither needs `ipcMain`.
 *
 * Never throws. Every caller is a gesture somebody made — a ⌘V on a terminal —
 * and the only wrong answer is silence, so a full disk or a name every variant
 * of which is taken comes back as a sentence like every other refusal.
 */
export async function stageBytes(deps: StageDeps, name: unknown, bytes: unknown): Promise<StageResult> {
  const buffer =
    bytes instanceof ArrayBuffer
      ? Buffer.from(bytes)
      : ArrayBuffer.isView(bytes)
        ? Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength)
        : null
  if (!buffer || buffer.byteLength === 0) return { ok: false, message: 'There was nothing to send.' }
  // The host's own ceiling, checked here as well, so an over-size paste is one
  // sentence rather than a file written and then refused by the wire.
  if (buffer.byteLength > MAX_UPLOAD_BYTES) {
    return { ok: false, message: `That is too big to send — the limit is ${byteSize(MAX_UPLOAD_BYTES)}.` }
  }

  const suggested = typeof name === 'string' && name.trim() !== '' ? name : 'file'
  try {
    const { path, sink } = await diskUploadStore(deps.dir()).open(safeName(suggested))
    try {
      await new Promise<void>((settle, fail) => {
        sink.write(buffer, (error) => (error ? fail(error) : settle()))
      })
      await sink.commit()
    } catch (error) {
      // Nothing half-written is left wearing a real name — the same promise the
      // phone's uploads make, and for the same reason: a truncated image is
      // worse than no image, because the failure surfaces later in whatever
      // opens it.
      await sink.discard()
      throw error
    }
    return { ok: true, path }
  } catch {
    return { ok: false, message: 'That could not be saved on this machine.' }
  }
}

/** Wire the one channel. */
export function registerStageIpc(ipcMain: IpcMain, deps: StageDeps): void {
  ipcMain.handle(STAGE_CHANNEL, (_event, name: unknown, bytes: unknown) => stageBytes(deps, name, bytes))
}
