/**
 * The browser client's half of "send a photo, a video or a file into a session".
 *
 * Asad, 2026-08-20:
 *
 *   > *"And photo dropping, the way we did with the phone — also any kind of
 *   > media dropping from your PC to any session should smoothly work."*
 *
 * *The way we did with the phone* was true of two of the three phone clients.
 * iOS has had `PHPickerViewController` and `FileUpload.swift` since the transfer
 * shipped and Android has `PickVisualMedia`; the page you get in a browser —
 * which is the client he actually opens on his phone, because it needs no
 * TestFlight build — had no picker, no drop handler and not one `upload.*` frame
 * anywhere in it. So this is not a new protocol: it is the same four verbs, in
 * the same order, with the same window and the same digest that
 * `ios/TerminalDeck/Transfer/FileUpload.swift` sends, so the desktop cannot tell
 * which kind of device is talking to it and there is no second set of bugs to
 * find later.
 *
 * ## The window, and why progress is drawn from acknowledgements
 *
 * A file read out of a browser's memory is handed to the socket far faster than
 * any link carries it. Without a bound, a 200 MB video is queued in a couple of
 * seconds and then sits in the desktop's heap until its backpressure cap drops
 * this browser — a feature that fails *only* on the large files, which is the
 * worst way for one to fail. So no more than {@link UPLOAD_WINDOW_BYTES} may be
 * unacknowledged at once and the next read is armed by an acknowledgement rather
 * than by a timer.
 *
 * The line on screen is drawn from the same acknowledgements. Drawn from bytes
 * handed to the socket it would reach 100% in two seconds and stay there for a
 * minute, which is not progress, it is an animation.
 *
 * ## The digest
 *
 * A truncated video with the right name is worse than no video: it surfaces
 * later, somewhere else, as a file nobody can open. This hashes what it reads,
 * the desktop hashes what it writes, and a mismatch deletes the file over there
 * rather than renaming it into place.
 *
 * ## What is deliberately not here
 *
 * No queue. The desktop serves one upload per connection
 * (`MAX_UPLOADS_PER_CONNECTION`), so a second pick while one is in flight is
 * refused with one line rather than parked — a file whose path appears at the
 * prompt two minutes after it was chosen is a surprise, not a feature.
 */

import { sha256 } from '@noble/hashes/sha2.js'
import {
  MAX_UPLOAD_BYTES,
  MAX_UPLOAD_CHUNK_BYTES,
  UPLOAD_WINDOW_BYTES,
  type ClientMessage,
  type ServerMessage,
} from '../../src/main/remote/protocol'

/** How a surface draws one transfer. The same five fields the desktop uses. */
export interface UploadProgress {
  name: string
  size: number
  /** Bytes the desktop says it has written. Never bytes handed to the socket. */
  sent: number
  phase: 'opening' | 'sending' | 'finishing' | 'landed' | 'failed'
  /** Set only on `failed`, and always a line a person can read. */
  message: string
}

/**
 * A byte count as a person would say it.
 *
 * Decimal units, matching `shared/byte-size.ts` on the desktop and `byteSize` on
 * iOS. It appears in a refusal beside the cap, and two numbers in one sentence
 * produced by two different rules read as nonsense.
 */
export function byteSize(bytes: number): string {
  const units = ['bytes', 'KB', 'MB', 'GB']
  let value = bytes
  let unit = 0
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000
    unit += 1
  }
  if (unit === 0) return `${bytes} bytes`
  return `${value < 10 ? value.toFixed(1) : value.toFixed(0)} ${units[unit]}`
}

/**
 * One short line about a transfer, or '' when there is nothing to say.
 *
 * Deliberately not a sentence. *"Sending holiday photo.jpg — 42%"* is prose on a
 * terminal; the name and the number are the two things a person cannot see for
 * themselves, and nothing is said once it has landed because the path appearing
 * at the prompt is the success signal they asked for.
 *
 * The same function as `renderer/terminal-drop.ts`'s `transferLine`, written
 * again here rather than imported because that module is renderer-only and this
 * one compiles into a page served to a phone. Pinned by a test on both sides.
 */
export function transferLine(progress: UploadProgress): string {
  if (progress.phase === 'failed') return progress.message
  if (progress.phase === 'landed') return ''
  if (progress.phase === 'finishing') return `${progress.name} — finishing`
  if (progress.size <= 0) return progress.name
  const percent = Math.min(100, Math.floor((progress.sent / progress.size) * 100))
  return `${progress.name} — ${percent}%`
}

/**
 * A path as it should appear at a prompt: quoted, with one trailing space.
 *
 * Single quotes, because inside them a shell interprets nothing at all — no `$`,
 * no backtick, no backslash — and a file name really can contain every one of
 * those. The only character needing care is the quote itself, which is closed,
 * escaped and reopened. A Windows path is double-quoted instead, because a
 * `cmd`-shaped path is what the far machine answered with and single quotes mean
 * nothing there.
 *
 * The trailing space is not cosmetic: without it a second path abuts the first
 * and the shell reads one word.
 */
export function promptWord(path: string): string {
  if (/^[A-Za-z]:/.test(path) || path.startsWith('\\\\')) return `"${path}" `
  return `'${path.replace(/'/g, `'\\''`)}' `
}

/** Base64 for one slice. Chunked so a large file cannot blow the call stack. */
function base64(bytes: Uint8Array): string {
  let binary = ''
  const step = 8192
  for (let at = 0; at < bytes.length; at += step) {
    binary += String.fromCharCode(...bytes.subarray(at, at + step))
  }
  return btoa(binary)
}

/** Lower-case hex, the spelling `upload.end` is validated against. */
function hex(bytes: Uint8Array): string {
  let out = ''
  for (const byte of bytes) out += byte.toString(16).padStart(2, '0')
  return out
}

export interface UploadDeps {
  /** Put one frame on the link. False when the socket is not up. */
  send(message: ClientMessage): boolean
  /** Told on every change, so a surface can draw one line about it. */
  onProgress(progress: UploadProgress): void
  /** Called once, with the far path, when the file has landed. */
  onLanded(path: string): void
  /** Ids come from here so a test can pin them. */
  newId?(): string
}

/**
 * One file on its way to the machine, and the frames that answer it.
 *
 * Created in `opening`: `upload.begin` is on the wire and the desktop has not
 * named a path yet. Nothing is read off the file until it does — a path
 * announced and then never filled would leave a prompt holding the name of a
 * file that does not exist.
 */
export class Upload {
  readonly id: string
  readonly name: string
  readonly size: number

  private readonly file: Blob
  private readonly deps: UploadDeps
  private readonly digest = sha256.create()

  private phase: UploadProgress['phase'] = 'opening'
  private message = ''
  /** Bytes read off the file and handed to the socket. Runs ahead of `acked`. */
  private read = 0
  /** Bytes the desktop says it has written. What the line is drawn from. */
  private acked = 0
  /** Read and sent but not acknowledged. Never above the window. */
  private inFlight = 0
  /** Set once `upload.end` has gone, so a late ack cannot send it twice. */
  private ended = false
  private finished = false
  /** One read at a time: `Blob.arrayBuffer` is asynchronous and the pump is not. */
  private reading = false

  constructor(file: File, deps: UploadDeps) {
    this.file = file
    this.name = file.name
    this.size = file.size
    this.deps = deps
    this.id = deps.newId?.() ?? crypto.randomUUID()
  }

  /** Announce the file. Refusals that never leave this page happen here. */
  start(): void {
    if (this.size <= 0) {
      this.end('failed', 'That file is empty.')
      return
    }
    if (this.size > MAX_UPLOAD_BYTES) {
      // Refused before anything is announced, so an over-size file is one line
      // rather than a round trip that ends in one.
      this.end('failed', `That file is ${byteSize(this.size)} — the most that can be sent is ${byteSize(MAX_UPLOAD_BYTES)}.`)
      return
    }
    if (!this.deps.send({ t: 'upload.begin', id: this.id, name: this.name, size: this.size })) {
      this.end('failed', 'The connection to the machine is not up.')
      return
    }
    this.report()
  }

  /** The one control a stalled transfer has. */
  cancel(): void {
    this.end('failed', 'Cancelled.', true)
  }

  /** The socket went away. The desktop deletes its half on its own. */
  connectionLost(detail: string): void {
    this.end('failed', detail)
  }

  /**
   * A frame from the machine. True when it belonged to this upload.
   *
   * Answering a boolean rather than filtering upstream keeps the routing in one
   * place: nothing above this knows which upload ids are whose, and telling it
   * would be a second copy of this state to keep in step.
   */
  receive(message: ServerMessage): boolean {
    if (!('id' in message) || message.id !== this.id) return false
    switch (message.t) {
      case 'upload.ready':
        this.begin()
        return true
      case 'upload.ack':
        this.acknowledge(message.bytes)
        return true
      case 'upload.done':
        // The machine decided it is over, so it is not told again.
        this.end('landed', '')
        this.deps.onLanded(message.path)
        return true
      case 'upload.failed':
        this.end('failed', message.message)
        return true
      default:
        return false
    }
  }

  private begin(): void {
    if (this.phase !== 'opening') return
    this.phase = 'sending'
    this.report()
    void this.pump()
  }

  /**
   * Read and send until the window is full or the file is done.
   *
   * `inFlight + a whole slice <= window`, not `inFlight < window`: the looser
   * condition reads one more slice when it is already a window ahead and
   * overshoots by a chunk, which is the difference between a bound a test can
   * assert and one that is approximately true.
   */
  private async pump(): Promise<void> {
    if (this.reading) return
    this.reading = true
    try {
      while (
        this.phase === 'sending' &&
        this.inFlight + MAX_UPLOAD_CHUNK_BYTES <= UPLOAD_WINDOW_BYTES &&
        this.read < this.size
      ) {
        const end = Math.min(this.size, this.read + MAX_UPLOAD_CHUNK_BYTES)
        let slice: Uint8Array
        try {
          slice = new Uint8Array(await this.file.slice(this.read, end).arrayBuffer())
        } catch {
          // A `File` handed over by the picker whose backing store has gone —
          // the photo was deleted, or an OS moved it. Stopping is the honest
          // answer; sending a shorter file is not.
          this.end('failed', 'This browser could not read that file any more.', true)
          return
        }
        if (this.phase !== 'sending') return
        if (slice.length === 0) {
          this.end('failed', 'That file changed while it was being sent.', true)
          return
        }
        this.read += slice.length
        this.digest.update(slice)
        if (!this.deps.send({ t: 'upload.data', id: this.id, data: base64(slice) })) {
          this.end('failed', 'The connection to the machine dropped.')
          return
        }
        this.inFlight += slice.length
      }
    } finally {
      this.reading = false
    }
  }

  private acknowledge(bytes: number): void {
    if (this.phase !== 'sending') return
    this.acked = Math.min(this.size, this.acked + bytes)
    this.inFlight = Math.max(0, this.inFlight - bytes)
    this.report()
    if (this.acked >= this.size) {
      if (this.ended) return
      this.ended = true
      this.phase = 'finishing'
      this.report()
      if (!this.deps.send({ t: 'upload.end', id: this.id, sha256: hex(this.digest.digest()) })) {
        this.end('failed', 'The connection to the machine dropped.')
      }
      return
    }
    void this.pump()
  }

  private end(phase: UploadProgress['phase'], message: string, tellMachine = false): void {
    if (this.finished) return
    this.finished = true
    if (tellMachine) this.deps.send({ t: 'upload.cancel', id: this.id })
    this.phase = phase
    this.message = message
    this.report()
  }

  private report(): void {
    this.deps.onProgress({
      name: this.name,
      size: this.size,
      sent: this.acked,
      phase: this.phase,
      message: this.message,
    })
  }

  /** Whether anything is still expected on the wire for this transfer. */
  get live(): boolean {
    return !this.finished
  }
}
