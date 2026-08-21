/**
 * This desktop's half of "drop a file onto a session on another machine".
 *
 * `remote/uploads.ts` is the receiving half and was written for a phone. This is
 * the sending half, written for the case Asad asked for on 2026-08-20:
 *
 *   > "photo dropping, the way we did with the phone — also any kind of media
 *   > dropping from your PC to any session should smoothly work."
 *
 * *The way we did with the phone* is meant literally. There is no
 * desktop-to-desktop dialect here: this sends the same four verbs
 * `ios/TerminalDeck/Transfer/FileUpload.swift` sends, in the same order, with
 * the same window and the same digest, and the far machine cannot tell which
 * kind of device is talking to it. A second protocol for the same act would be
 * a second set of bugs, and the host would have had to grow a branch for it.
 *
 * ## What is different from the phone, and why
 *
 * The phone reads a file the OS picker copied into its own sandbox. This reads a
 * path Finder or Explorer handed over in a drag, which is a file the user owns
 * and this process must not delete — so nothing here unlinks anything, and
 * `PickedFile.temporary` has no counterpart.
 *
 * ## Where the file lands, and what the agent is told
 *
 * The far machine decides, and it answers with the path before a single byte
 * moves. On a desktop host that folder is `<downloads>/Terminal Deck`
 * (`main/index.ts` passes it as `uploadsDir`); a headless host uses the same
 * shape. This end never proposes a path — `upload.begin` carries a *name*, and
 * `safeName` over there reduces it to one path component. A `path` field on that
 * frame would be a `writeFile` at a location chosen across a network, which is
 * the argument the receiving half opens with.
 *
 * `send`'s optional `dir` is the one qualification of that, and it is not a
 * `path`: it is a *folder*, and the far machine resolves it against the list it
 * published to this device and refuses anything outside — `storeForFolder` in
 * `server.ts`. So this end still proposes nothing it has not been offered. It
 * exists for browser downloads, where the person choosing the destination is
 * sitting at this keyboard and picked the folder off that machine's own list.
 *
 * The path that comes back is what gets typed at the prompt, shell-quoted, by
 * the caller — the same thing the phone does with it. Nothing is typed until the
 * file has actually landed: a path announced at `upload.ready` and then never
 * filled would be a prompt holding a name for a file that does not exist.
 *
 * ## The three bounds, stated
 *
 * - **Size.** `MAX_UPLOAD_BYTES` is 512 MB and belongs to the host. It is
 *   checked here as well, before anything is announced, so an over-size file is
 *   one sentence rather than a round trip that ends in one.
 * - **Concurrency.** One at a time per machine, because the host allows exactly
 *   one per connection (`MAX_UPLOADS_PER_CONNECTION`). A second drop is refused
 *   with a sentence rather than queued: a queue would make the second file's
 *   path arrive minutes after the drop that asked for it.
 * - **Interruption.** A dropped link, a cancel or a mismatched digest all end
 *   with the far machine deleting its `.part` file — nothing half-written is
 *   left wearing a real name — and with this end resolving a refusal. There is
 *   no path here that resolves nothing.
 */

import { createHash } from 'node:crypto'
import { open, stat, type FileHandle } from 'node:fs/promises'
import { basename } from 'node:path'
import { byteSize } from '../../../shared/byte-size'
import {
  MAX_UPLOAD_BYTES,
  MAX_UPLOAD_CHUNK_BYTES,
  UPLOAD_WINDOW_BYTES,
  type ClientMessage,
  type ServerMessage,
} from '../protocol'

/** What the caller gets back. A path on the far machine, or a sentence. */
export type SendFileOutcome = { ok: true; path: string } | { ok: false; message: string }

/**
 * A transfer as a surface would draw it.
 *
 * `sent` is acknowledged bytes, never bytes handed to the socket, for the reason
 * the receiving half acknowledges from its write callback: progress drawn from
 * what this end has read fills in two seconds on any file and then sits at 100%
 * for a minute, which is not a progress bar.
 */
export interface UploadProgress {
  id: string
  name: string
  size: number
  sent: number
  /** Where it is going, once the far machine has said. Empty until then. */
  path: string
  phase: 'opening' | 'sending' | 'finishing' | 'landed' | 'failed'
  /** Set only on `failed`, and always a sentence a person can read. */
  message: string
}

export interface UploadSenderDeps {
  /** Put one frame on the link. False when the socket is not up. */
  send(message: ClientMessage): boolean
  /** Told on every change, so a pane can draw one line about it. */
  onProgress(progress: UploadProgress): void
}

export interface UploadSender {
  /**
   * Send one file and resolve with the path it landed at.
   *
   * Resolves rather than throws on every failure, including the ones that never
   * leave this machine, because the caller is a drop on a terminal pane and the
   * only wrong answer is silence.
   */
  send(filePath: string, dir?: string): Promise<SendFileOutcome>
  /** A frame off the wire. True when it belonged to the transfer in flight. */
  receive(message: ServerMessage): boolean
  /** The link went away. Whatever was in flight ends, visibly. */
  closeAll(reason: string): void
}

interface Live {
  id: string
  name: string
  size: number
  path: string
  handle: FileHandle
  digest: ReturnType<typeof createHash>
  /** Bytes read off this disk and handed to the socket. Runs ahead of `acked`. */
  read: number
  /** Bytes the far machine says it has written. What progress is drawn from. */
  acked: number
  /** Read and sent, not yet acknowledged. Never above `UPLOAD_WINDOW_BYTES`. */
  inFlight: number
  /** Set once `upload.end` has gone, so a late ack cannot send it twice. */
  ended: boolean
  /**
   * Whether a read is already in the air for this transfer.
   *
   * The pump is re-entered from every acknowledgement, and a read is
   * asynchronous, so without this two of them overlap: both see the same
   * `read` offset, both send the same slice, and the far machine answers
   * *"that file sent more bytes than it said it would"* and deletes it.
   * Measured — it is what the first run of `transfer-live.test.ts` produced on
   * a 200 KB file.
   *
   * A flag rather than reserving the range before the await, because the digest
   * is order-sensitive: two reads that reserved different ranges would still
   * hash them in whichever order the disk answered.
   */
  pumping: boolean
  settle(outcome: SendFileOutcome): void
}

/**
 * Ids are minted here rather than derived from the file name.
 *
 * An id is a routing key on a wire shared with another machine; a file name is
 * text a stranger's camera chose. Deriving one from the other would let two
 * drops of the same photo collide on a key the far end uses to tell transfers
 * apart. The shape satisfies the host's `ID_RE` — leading alphanumeric, then
 * alphanumerics, `_` and `-`.
 */
function mintId(counter: number): string {
  return `up-${Date.now().toString(36)}-${counter.toString(36)}`
}

export function createUploadSender(deps: UploadSenderDeps): UploadSender {
  let live: Live | null = null
  let counter = 0

  function publish(phase: UploadProgress['phase'], message = ''): void {
    if (!live) return
    deps.onProgress({
      id: live.id,
      name: live.name,
      size: live.size,
      sent: live.acked,
      path: live.path,
      phase,
      message,
    })
  }

  /** End the transfer in flight, once, with a sentence and a closed file. */
  function fail(message: string, tellFarEnd: boolean): void {
    const upload = live
    if (!upload) return
    live = null
    if (tellFarEnd) deps.send({ t: 'upload.cancel', id: upload.id })
    publishFinal(upload, 'failed', message)
    void upload.handle.close().catch(() => {
      // The descriptor is being closed on a failure path; a second failure here
      // has nothing left to report to and must not take the link's teardown
      // with it.
    })
    upload.settle({ ok: false, message })
  }

  /** A `publish` that does not depend on `live` still pointing at this upload. */
  function publishFinal(upload: Live, phase: UploadProgress['phase'], message: string): void {
    deps.onProgress({
      id: upload.id,
      name: upload.name,
      size: upload.size,
      sent: upload.acked,
      path: upload.path,
      phase,
      message,
    })
  }

  /**
   * Read and send until the window is full or the file is done.
   *
   * Driven by acknowledgements, never by a timer: the far end acknowledges from
   * its own write callback, so this end reads exactly as fast as that disk can
   * take it. Without the window a 200 MB video is handed to the socket in a
   * couple of seconds and the far machine's `MAX_BUFFERED_BYTES` answers by
   * dropping the link — a feature that fails only on the large files, which is
   * the worst way for it to fail.
   *
   * `inFlight + a whole slice <= window`, not `inFlight < window`, so the bound
   * is one this can be tested against rather than one that is approximately
   * true. The read size is ours to choose here, so the exact form costs nothing.
   */
  async function pump(upload: Live): Promise<void> {
    if (upload.pumping) return
    upload.pumping = true
    try {
      await fill(upload)
    } finally {
      upload.pumping = false
    }
  }

  async function fill(upload: Live): Promise<void> {
    while (
      live === upload &&
      upload.inFlight + MAX_UPLOAD_CHUNK_BYTES <= UPLOAD_WINDOW_BYTES &&
      upload.read < upload.size
    ) {
      const want = Math.min(MAX_UPLOAD_CHUNK_BYTES, upload.size - upload.read)
      const buffer = Buffer.allocUnsafe(want)
      let got: number
      try {
        // Positioned explicitly rather than relying on the handle's cursor,
        // because this function is re-entered from an acknowledgement and two
        // overlapping reads off one cursor would interleave the file.
        const result = await upload.handle.read(buffer, 0, want, upload.read)
        got = result.bytesRead
      } catch {
        fail('That file could not be read any more.', true)
        return
      }
      // The transfer ended while the read was in the air — a cancel, a dropped
      // link. Whatever came back belongs to nothing.
      if (live !== upload) return
      if (got === 0) {
        // The file is shorter than `stat` said. Stopping quietly would send a
        // truncated file that the far end then refuses on the byte count; it is
        // clearer to say so from the end that knows why.
        fail('That file changed while it was being sent.', true)
        return
      }
      const slice = buffer.subarray(0, got)
      upload.read += got
      upload.digest.update(slice)
      if (!deps.send({ t: 'upload.data', id: upload.id, data: slice.toString('base64') })) {
        fail('The link to that machine dropped.', false)
        return
      }
      upload.inFlight += got
    }
  }

  function acknowledge(upload: Live, bytes: number): void {
    upload.acked = Math.min(upload.size, upload.acked + bytes)
    upload.inFlight = Math.max(0, upload.inFlight - bytes)
    if (upload.acked >= upload.size) {
      if (upload.ended) return
      upload.ended = true
      publish('finishing')
      const hex = upload.digest.digest('hex')
      if (!deps.send({ t: 'upload.end', id: upload.id, sha256: hex })) {
        fail('The link to that machine dropped.', false)
      }
      return
    }
    publish('sending')
    void pump(upload)
  }

  return {
    async send(filePath: string, dir?: string): Promise<SendFileOutcome> {
      if (live) {
        return {
          ok: false,
          message: 'One file at a time — wait for the one already going, or cancel it.',
        }
      }

      let size: number
      try {
        const info = await stat(filePath)
        if (!info.isFile()) return { ok: false, message: 'Only files can be sent, not folders.' }
        size = info.size
      } catch {
        return { ok: false, message: 'That file could not be read.' }
      }
      // Refused here rather than announced and refused there. The host's parser
      // rejects a size outside `1…MAX_UPLOAD_BYTES` by closing the socket, so a
      // 700 MB video dropped by mistake would cost the link.
      if (size === 0) return { ok: false, message: 'That file is empty.' }
      if (size > MAX_UPLOAD_BYTES) {
        return { ok: false, message: `That file is too big to send. The limit is ${byteSize(MAX_UPLOAD_BYTES)}.` }
      }

      let handle: FileHandle
      try {
        handle = await open(filePath, 'r')
      } catch {
        return { ok: false, message: 'That file could not be opened.' }
      }
      // Another drop landed while this file was being opened. Refused rather
      // than replacing the one in flight, which is the same rule the receiving
      // half applies to a cancel that overtakes an open.
      if (live) {
        await handle.close().catch(() => {})
        return {
          ok: false,
          message: 'One file at a time — wait for the one already going, or cancel it.',
        }
      }

      counter += 1
      const name = basename(filePath)
      return await new Promise<SendFileOutcome>((settle) => {
        const upload: Live = {
          id: mintId(counter),
          name,
          size,
          path: '',
          handle,
          digest: createHash('sha256'),
          read: 0,
          acked: 0,
          inFlight: 0,
          ended: false,
          pumping: false,
          settle,
        }
        live = upload
        publish('opening')
        // Announced, and then nothing is read until the far machine answers with
        // a path. That ordering is the receiving half's design and this end
        // keeps it: the person is told where the file is going while they can
        // still stop it.
        /*
         * `dir` is left off entirely when nothing was chosen, rather than sent
         * as an empty string. The far end reads absent and empty the same way,
         * but a build older than the field would carry an unknown key through
         * its parser, and an additive wire earns that by not adding keys nobody
         * asked for.
         */
        const begin =
          dir === undefined || dir === ''
            ? ({ t: 'upload.begin', id: upload.id, name, size } as const)
            : ({ t: 'upload.begin', id: upload.id, name, size, dir } as const)
        if (!deps.send(begin)) {
          fail('That machine is not connected.', false)
        }
      })
    },

    receive(message: ServerMessage): boolean {
      const upload = live
      if (!upload) return false
      switch (message.t) {
        case 'upload.ready':
          if (message.id !== upload.id) return false
          upload.path = message.path
          publish('sending')
          void pump(upload)
          return true
        case 'upload.ack':
          if (message.id !== upload.id) return false
          acknowledge(upload, message.bytes)
          return true
        case 'upload.done': {
          if (message.id !== upload.id) return false
          live = null
          upload.acked = message.bytes
          upload.path = message.path
          publishFinal(upload, 'landed', '')
          void upload.handle.close().catch(() => {})
          upload.settle({ ok: true, path: message.path })
          return true
        }
        case 'upload.failed':
          if (message.id !== upload.id) return false
          // The far end has already stopped and deleted its half, so it is not
          // told again. Its sentence wins over anything this end would invent:
          // it is the end that knows why.
          fail(message.message === '' ? 'That file did not send.' : message.message, false)
          return true
        default:
          return false
      }
    },

    closeAll(reason: string): void {
      if (!live) return
      // Not told: the socket this would go down is the one that has just gone.
      fail(reason, false)
    },
  }
}

