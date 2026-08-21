/**
 * The desktop's half of "send a photo, a video or a file from the phone".
 *
 * A person picks something in their phone's own picker; this receives it in
 * slices over the sealed channel they are already on, writes it to a folder this
 * machine chose, and answers with the path. The phone then types that path into
 * the terminal. That is the whole feature.
 *
 * ## Why no message here names a Mac, or a PC
 *
 * Every `upload.failed` message below is sealed up and read on a phone, and a
 * phone can be paired to several machines at once — a Mac and a Windows PC, at
 * the same time, which is the arrangement this app now has to be correct for.
 * The phone already prints the machine's own label beside anything that machine
 * says (`StoredCredential.label` on iOS), so "This Mac could not write that
 * file" next to a row reading `desktop-ddgmncv` is either redundant or a lie,
 * and on a Windows host it is always the second one. Copy the *host* user reads
 * names the platform — that is what `machineNoun()` in `platform/host.ts` is
 * for. Copy that crosses the wire names nothing.
 *
 * ## Why the desktop names the folder, and the sender names at most a menu entry
 *
 * The obvious design lets the phone say where the file should go, and it is the
 * one thing this must not do. `upload.begin` arrives from the network, and a
 * `path` field on it is a `writeFile` at an attacker-chosen location — the same
 * class of hole as `create.cwd`, except that `create` at least resolves against
 * a list of folders the desktop is already offering. So the sender sends a
 * **name**, `safeName` reduces it to one path component, and the directory is
 * never built here out of what arrived.
 *
 * `upload.begin.dir` is the one thing that changed, and it changed *into* the
 * shape the paragraph above envied. It is not a path this module trusts: it is
 * handed to {@link UploadDeps.store}, which is the host's own function, and the
 * host answers with a store or with `null` — meaning "that is not a folder this
 * device may write to". Everything here does with a `null` what it does with any
 * other refusal. There is still no code path in this file that builds a path out
 * of two pieces of network input.
 *
 * ## Why the path is sent before the bytes
 *
 * `upload.ready` goes out after the file is opened and before a single slice is
 * asked for. The person holding the phone is told where on their Mac something is
 * about to appear at the moment they can still cancel it. A design that uploaded
 * first and reported the location afterwards would be telling them where the file
 * *is*, which is a different sentence.
 *
 * ## Why it lands as `.part` and is renamed
 *
 * A half-written video with the right name and the right extension is worse than
 * no video: the failure does not surface here, it surfaces later, in whatever
 * opens it, as a corrupt file nobody can trace back to a dropped connection. So
 * bytes go to `<name>.part`, the digest the phone reports is compared against the
 * one computed over what was actually written, and only then is the file renamed
 * into place. Anything else — a cancel, a dropped socket, a mismatch — deletes it.
 *
 * ## Flow control
 *
 * Straight out of `tunnel.ts`, for the same reason and with the same numbers.
 * Each slice is acknowledged **from the write callback**, so an acknowledgement
 * means the kernel has the bytes rather than that we called `write`; the phone
 * stops reading once it is `UPLOAD_WINDOW_BYTES` ahead. Without it a phone on
 * wifi reading a 200 MB video off flash hands the whole thing to the socket faster
 * than a spinning disk can take it, and `MAX_BUFFERED_BYTES` in the server answers
 * by dropping the phone — a feature that fails only on the large files, which is
 * the worst way for it to fail. It is also what makes the progress bar honest:
 * drawn from acknowledgements, it measures the Mac's appetite rather than the
 * phone's read speed.
 */

import { createHash, type Hash } from 'node:crypto'
import type { WriteStream } from 'node:fs'
import { mkdir, open, rename, unlink } from 'node:fs/promises'
import { extname, join } from 'node:path'
import { MAX_UPLOAD_NAME_BYTES, type ServerMessage } from './protocol'

/**
 * A file being written, as this module needs it.
 *
 * An interface rather than a `WriteStream` so the tests can watch what was
 * written without a temporary directory, and — more usefully — so the awkward
 * part is stated once: `write` reports completion through a callback because
 * that callback is what an acknowledgement means. A promise-returning `write`
 * would read better and would quietly change the meaning of the window.
 */
export interface UploadSink {
  /** `done` fires when the kernel has the bytes, or with the error that stopped it. */
  write(chunk: Buffer, done: (error?: Error | null) => void): void
  /** Finish and move the file into place at its final path. */
  commit(): Promise<void>
  /** Finish and delete whatever landed. Never throws. */
  discard(): Promise<void>
}

/**
 * Where files go. Injected so that nothing in the tests touches a real disk, and
 * so the one place that decides a path is a function this module is handed.
 */
export interface UploadStore {
  /**
   * Reserve a place for a file and open it.
   *
   * Takes the *suggested* name and answers with the path it actually chose —
   * which can differ, because a second file of the same name lands beside the
   * first rather than over it. Creating the folder is this method's job: it is
   * the moment it is known to be needed, and a folder made at startup for a
   * feature nobody used would be litter in somebody's Downloads.
   */
  open(name: string): Promise<{ path: string; sink: UploadSink }>
}

export interface UploadDeps {
  /**
   * The store for a destination, or `null` when that destination is refused.
   *
   * A function rather than a value, and the argument is the whole reason: `null`
   * means the folder the sender named is not one this device may write to, and
   * only the host can answer that — it is the one that knows which folders it
   * published to which device. `null` for `dir` is "wherever you normally put
   * them", which is the phone's case and every case before 2026-08-21, and a
   * host must always answer that one with a store.
   */
  store(dir: string | null): UploadStore | null
  /** Send a frame to the phone this desk belongs to. */
  send(message: ServerMessage): void
}

export interface UploadDesk {
  /** The `upload` verbs. Anything else is not this module's business. */
  handle(message: UploadMessage): void
  /** The phone is gone. Whatever it was sending is deleted, not left half-written. */
  closeAll(): void
}

/** The subset of `ClientMessage` this module answers. */
export type UploadMessage =
  | { t: 'upload.begin'; id: string; name: string; size: number; dir?: string }
  | { t: 'upload.data'; id: string; data: string }
  | { t: 'upload.end'; id: string; sha256: string }
  | { t: 'upload.cancel'; id: string }

/**
 * Uploads one phone may have in flight at once.
 *
 * One, and the number is a decision rather than a limitation. A person sends a
 * file, watches the bar, and gets a path back; two at once would need two bars
 * and two paths and would still be limited by the same link. What it buys is that
 * every failure here has one obvious subject — "the upload" rather than "an
 * upload" — and that a phone cannot make this process hold sixty open file
 * descriptors by tapping quickly.
 */
const MAX_UPLOADS_PER_CONNECTION = 1

/** How many `name (2)` variants to try before giving up on a colliding name. */
const MAX_NAME_ATTEMPTS = 99

interface Live {
  id: string
  name: string
  path: string
  size: number
  /** Bytes handed to `write`, whether or not the kernel has them yet. */
  taken: number
  /** Bytes acknowledged to the phone. What the progress bar is drawn from. */
  acked: number
  sink: UploadSink
  digest: Hash
  /** Set once anything has gone wrong, so the failure is announced exactly once. */
  finished: boolean
}

export function createUploadDesk(deps: UploadDeps): UploadDesk {
  const live = new Map<string, Live>()
  /**
   * Uploads whose file is being opened.
   *
   * `open` is the one asynchronous step here, and it breaks the property every
   * other frame on this connection relies on: that messages are handled in the
   * order they arrived. A `upload.cancel` sent while the `mkdir` is still running
   * would find nothing to cancel, return, and then be overtaken by an open that
   * installs the upload it was meant to stop — leaving a file on somebody's disk
   * that they had already cancelled. So an open is visible from the moment it
   * starts, and a cancel that lands on one cancels it. Exactly the shape
   * `tunnel.ts` uses for the same reason.
   */
  const opening = new Map<string, { cancelled: boolean }>()

  /** Announce a failure once, delete the partial file, and forget the upload. */
  function fail(id: string, message: string): void {
    const upload = live.get(id)
    if (!upload) {
      // Either it never started or it has already ended. The phone is told
      // anyway: it may be sitting on a progress bar for something this end has
      // no record of, and silence there is a bar that never moves again.
      deps.send({ t: 'upload.failed', id, message })
      return
    }
    live.delete(id)
    upload.finished = true
    void upload.sink.discard()
    deps.send({ t: 'upload.failed', id, message })
  }

  async function begin(id: string, name: string, size: number, dir: string | null): Promise<void> {
    if (live.has(id) || opening.has(id)) {
      deps.send({ t: 'upload.failed', id, message: 'That upload is already running.' })
      return
    }
    if (live.size + opening.size >= MAX_UPLOADS_PER_CONNECTION) {
      deps.send({
        t: 'upload.failed',
        id,
        message: 'This phone is already sending a file. Wait for it to finish, or cancel it.',
      })
      return
    }

    /*
     * Where it goes, decided by the host and not by this module.
     *
     * `null` is a refusal, not an error: the sender named a folder this device
     * may not write to. Answered before anything is opened, so a refused
     * destination never leaves a `.part` file behind, and answered on the
     * upload's own id so the sender ends the right progress bar.
     */
    const store = deps.store(dir)
    if (store === null) {
      deps.send({
        t: 'upload.failed',
        id,
        message: 'That machine will not put a file in that folder.',
      })
      return
    }

    const pending = { cancelled: false }
    opening.set(id, pending)
    let opened: { path: string; sink: UploadSink }
    try {
      opened = await store.open(safeName(name))
    } catch (error) {
      opening.delete(id)
      console.error('[upload] could not open a file:', error)
      if (!pending.cancelled) {
        deps.send({
          t: 'upload.failed',
          id,
          // The folder is not named in this sentence: it is about to be shown on
          // the phone by `upload.ready` in the successful case, and a failure is
          // the wrong moment to be quoting a path from somebody's home directory
          // into a message that crosses a network.
          message: 'Could not create a file for that. Check that the downloads folder is writable.',
        })
      }
      return
    }
    opening.delete(id)

    // A cancel overtook the open. The file exists and nobody asked for it.
    if (pending.cancelled) {
      void opened.sink.discard()
      return
    }

    live.set(id, {
      id,
      name: basenameOf(opened.path),
      path: opened.path,
      size,
      taken: 0,
      acked: 0,
      sink: opened.sink,
      digest: createHash('sha256'),
      finished: false,
    })
    // Before a single byte is asked for. See the header.
    deps.send({ t: 'upload.ready', id, path: opened.path })
  }

  function data(id: string, encoded: string): void {
    const upload = live.get(id)
    // Not an error worth announcing: the realistic cause is a slice that was
    // already on the wire when a cancel went the other way, and answering it
    // would contradict the `upload.failed` the phone has already been sent.
    if (!upload || upload.finished) return

    const bytes = Buffer.from(encoded, 'base64')
    if (bytes.length === 0) return

    // Refused rather than truncated. A file that claimed one size and delivered
    // another is either a bug on the phone or an attempt to fill this disk, and
    // silently writing the extra would make `upload.done`'s byte count a lie.
    if (upload.taken + bytes.length > upload.size) {
      fail(id, 'That file sent more bytes than it said it would. Nothing was saved.')
      return
    }

    upload.taken += bytes.length
    upload.digest.update(bytes)
    upload.sink.write(bytes, (error) => {
      if (upload.finished) return
      if (error) {
        console.error('[upload] write failed:', error)
        fail(id, 'Writing that file stopped part way through. Nothing was saved.')
        return
      }
      // From the callback, so the acknowledgement means the kernel has it. See
      // `UPLOAD_WINDOW_BYTES`.
      upload.acked += bytes.length
      deps.send({ t: 'upload.ack', id, bytes: bytes.length })
    })
  }

  async function end(id: string, claimed: string): Promise<void> {
    const upload = live.get(id)
    if (!upload || upload.finished) {
      deps.send({ t: 'upload.failed', id, message: 'There is no upload with that id.' })
      return
    }

    if (upload.taken !== upload.size) {
      fail(id, `That upload ended early — ${upload.taken} of ${upload.size} bytes arrived. Nothing was saved.`)
      return
    }

    const actual = upload.digest.digest('hex')
    if (actual !== claimed) {
      // Deleted, not renamed. See the header: a corrupt file with the right name
      // is the failure that surfaces somewhere else, later.
      fail(id, 'That file arrived corrupted — the checksum does not match. Nothing was saved.')
      return
    }

    live.delete(id)
    upload.finished = true
    try {
      await upload.sink.commit()
    } catch (error) {
      console.error('[upload] could not move the file into place:', error)
      void upload.sink.discard()
      deps.send({
        t: 'upload.failed',
        id,
        message: 'Could not move that file into the downloads folder. Nothing was saved.',
      })
      return
    }
    deps.send({ t: 'upload.done', id, path: upload.path, bytes: upload.size, sha256: actual })
  }

  return {
    handle(message: UploadMessage): void {
      switch (message.t) {
        case 'upload.begin':
          void begin(message.id, message.name, message.size, message.dir ?? null)
          return
        case 'upload.data':
          data(message.id, message.data)
          return
        case 'upload.end':
          void end(message.id, message.sha256)
          return
        case 'upload.cancel': {
          const pending = opening.get(message.id)
          if (pending) {
            pending.cancelled = true
            opening.delete(message.id)
            deps.send({ t: 'upload.failed', id: message.id, message: 'Cancelled on the phone.' })
            return
          }
          fail(message.id, 'Cancelled on the phone.')
          return
        }
      }
    },

    closeAll(): void {
      for (const upload of live.values()) {
        upload.finished = true
        // Nothing is announced: the socket this would have gone down is the one
        // that just went away. What matters is that no half-written file is left
        // sitting in the user's downloads folder wearing a real name.
        void upload.sink.discard()
      }
      live.clear()
      for (const pending of opening.values()) pending.cancelled = true
      opening.clear()
    },
  }
}

/* ------------------------------------------------------------------- disk -- */

/**
 * The real store: a folder on this machine, created when the first file arrives.
 *
 * Deliberately not a temporary directory. The point of the feature is that the
 * file is *there afterwards* — the phone types the path into a terminal and an
 * agent works on it, possibly minutes later — so it goes somewhere a person would
 * think to look and somewhere the OS does not clean up underneath them.
 */
export function diskUploadStore(dir: string): UploadStore {
  return {
    async open(name: string): Promise<{ path: string; sink: UploadSink }> {
      await mkdir(dir, { recursive: true })

      // Reserved by *creating* the partial file with `wx` rather than by asking
      // whether the name is free and then using it. Two phones uploading the same
      // photo at the same moment both get an answer from a `stat`, and both then
      // write to the same file; `wx` fails for the second one, which is the whole
      // difference between a check and a reservation.
      for (const candidate of nameVariants(name)) {
        const path = join(dir, candidate)
        const partial = `${path}.part`
        let handle
        try {
          handle = await open(partial, 'wx')
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === 'EEXIST') continue
          throw error
        }
        // The final name has to be free too, or the rename at the end would land
        // on top of a file that was already there.
        try {
          const existing = await open(path, 'r')
          await existing.close()
          await handle.close()
          await unlink(partial).catch(() => {})
          continue
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
            await handle.close()
            await unlink(partial).catch(() => {})
            throw error
          }
        }
        // Off the handle that reserved the name, rather than by path: opening
        // the same path a second time would be a second race with whatever else
        // is in that folder, and the whole point of the `wx` above was that this
        // process already holds the only descriptor for that file.
        return { path, sink: streamSink(handle.createWriteStream({ autoClose: true }), partial, path) }
      }
      throw new Error('every variant of that file name is taken')
    },
  }
}

/**
 * A `WriteStream` behind the `UploadSink` contract.
 *
 * `shut` waits for `'close'` rather than for the callback `end` takes, and the
 * difference matters exactly once: `end`'s callback fires on `'finish'`, which is
 * "everything has been written", and the descriptor is still open at that point.
 * Renaming a file out from under an open descriptor is fine on POSIX and is not
 * on Windows, where the rename fails with EBUSY — so a commit that raced its own
 * close would work on the Mac this was written on and fail on the PC it ships to.
 * Memoised, because `discard` runs from teardown paths that can overlap.
 */
function streamSink(stream: WriteStream, partial: string, path: string): UploadSink {
  let closed: Promise<void> | null = null
  const shut = (): Promise<void> => {
    closed ??= new Promise<void>((settle) => {
      // Either event ends the wait. An error here has already lost the file; what
      // must not happen is a teardown that never settles and holds the
      // connection's cleanup open behind it.
      stream.once('close', () => settle())
      stream.once('error', () => settle())
      stream.end()
    })
    return closed
  }
  return {
    write(chunk, done): void {
      stream.write(chunk, done)
    },
    async commit(): Promise<void> {
      await shut()
      await rename(partial, path)
    },
    async discard(): Promise<void> {
      try {
        await shut()
        await unlink(partial)
      } catch (error) {
        // Best effort by contract. This runs on a dropped socket, and throwing
        // out of a teardown would take the connection's cleanup with it.
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
          console.error('[upload] could not delete a partial file:', error)
        }
      }
    },
  }
}

/* ------------------------------------------------------------------ names -- */

/**
 * Characters that cannot be in a file name on one of the three platforms this
 * ships to, plus the two path separators.
 *
 * `:` is here because it is the separator HFS used and Finder still displays that
 * way, and because it is forbidden on Windows. `<>"|?*` are Windows. The control
 * range is refused by `parseClientMessage` before this is reached and is repeated
 * here anyway, because this function is exported and a second caller must not
 * have to know that — written as escapes and never typed literally, because a
 * raw control byte in a character class is invisible in every diff and every
 * editor, and it makes the source file itself binary. This exact line was
 * written with real NUL, US and DEL bytes in it once, and what noticed was not a
 * test but `grep`, which stopped matching the file at all.
 *
 * Deliberately **not** here: spaces, quotes, `&`, `;`, `$`, backticks and the
 * rest of the shell's punctuation. All legal in a file name on every platform, a
 * photo really is called `Screenshot 2026-08-14 at 02.31.png`, and mangling them
 * would rename people's files to defend against a hazard that belongs somewhere
 * else: the path is *quoted* when it is typed into the terminal, on both phones,
 * which is where shell metacharacters stop mattering.
 */
const FORBIDDEN = /[<>:"|?*\\/\u0000-\u001f\u007f]/g

/**
 * Names Windows refuses whatever the extension, because they are devices.
 *
 * `CON.txt` is the console on Windows, not a text file. Checked against the stem
 * rather than the whole name for exactly that reason.
 */
const DEVICE_NAMES = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i

/**
 * Whatever the phone sent, reduced to one file name.
 *
 * The only thing between a network string and a path, so it is written to be
 * boring: take the last component, remove what cannot be in a name, refuse the
 * shapes that mean something other than a file, and cap the length. It never
 * returns an empty string and never returns anything containing a separator —
 * those two properties are what the caller relies on, and they are what the tests
 * check.
 *
 * Exported because it is the interesting half of this module and deserves to be
 * tested directly rather than through a filesystem.
 */
export function safeName(suggested: string): string {
  // Both separators, because the phone may be sending a name it read from
  // somewhere else entirely and `\` is a legal character in a POSIX file name.
  const components = suggested.split(/[\\/]/)
  const last = components[components.length - 1] ?? ''
  let name = last.replace(FORBIDDEN, '_')

  // Leading dots make a hidden file on macOS and Linux — a photo that vanishes
  // from the folder the user was told to look in — and `.` and `..` are not names
  // at all. Trailing dots and spaces are silently dropped by Windows, which turns
  // `report.txt.` into a file that does not have the name it was given.
  name = name.replace(/^[.\s]+/, '').replace(/[.\s]+$/, '')

  if (name === '') return 'file'

  const extension = extname(name)
  const stem = extension === '' ? name : name.slice(0, -extension.length)
  // A name that is *only* an extension — `.gitignore` after the leading dot was
  // stripped is `gitignore`, but `..zshrc` is not — is kept as a stem.
  if (stem !== '' && DEVICE_NAMES.test(stem)) name = `_${name}`

  return capBytes(name, MAX_UPLOAD_NAME_BYTES)
}

/**
 * Cap a name at a byte length, keeping the extension.
 *
 * A file called `<200 emoji>.mov` is 800 bytes and cannot be created; truncating
 * it from the end would leave `<n emoji>` with no extension, so the phone gets
 * back a path that Quick Look and every `open` on the Mac then treat as unknown.
 * The stem is what gets shortened.
 */
function capBytes(name: string, cap: number): string {
  if (Buffer.byteLength(name, 'utf8') <= cap) return name
  const extension = extname(name)
  const keep = Math.max(0, cap - Buffer.byteLength(extension, 'utf8'))
  const stem = extension === '' ? name : name.slice(0, -extension.length)
  let bytes = 0
  let out = ''
  // By code point, so a cut never lands between the halves of a surrogate pair
  // and leaves a replacement character in the middle of somebody's file name.
  for (const point of stem) {
    const cost = Buffer.byteLength(point, 'utf8')
    if (bytes + cost > keep) break
    out += point
    bytes += cost
  }
  const capped = `${out}${extension}`
  // An extension alone longer than the cap. Not a real file name; keep the head.
  return capped === extension && extension.length > 0 ? extension.slice(0, cap) : capped || 'file'
}

/**
 * `photo.jpg`, then `photo (2).jpg`, and so on. Lazily, so most names cost one.
 *
 * Exported for the same reason {@link safeName} is: it is a *rule* about what a
 * landing file is called, and every place a file lands has to use the same one
 * or the app names the same photo two ways depending on which computer it went
 * to. `servers/connection.ts` is the second caller — a file put on a server over
 * SFTP — and it walks these variants against the far end's `stat` exactly as the
 * store below walks them against `open(…, 'wx')`.
 */
export function* nameVariants(name: string): Generator<string> {
  yield name
  const extension = extname(name)
  const stem = extension === '' ? name : name.slice(0, -extension.length)
  for (let n = 2; n <= MAX_NAME_ATTEMPTS; n += 1) {
    yield capBytes(`${stem} (${n})${extension}`, MAX_UPLOAD_NAME_BYTES)
  }
}

/** The last path component, for reporting the name a file actually got. */
function basenameOf(path: string): string {
  const parts = path.split(/[\\/]/)
  return parts[parts.length - 1] ?? path
}
