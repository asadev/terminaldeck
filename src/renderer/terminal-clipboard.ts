/**
 * The other half of the clipboard: a program *inside* a session putting
 * something on the clipboard of the machine you are sitting at.
 *
 * ## The gap this closes, in his words
 *
 * Asad, 2026-08-20:
 *
 *   > *"if I copy from there I cannot paste here. So it should be also smoothly
 *   > working from cross devices — anything to anywhere."*
 *
 * Half of that already worked and is worth separating out, because the two
 * halves fail for completely different reasons. Selecting text with the mouse in
 * a session on another machine and pressing ⌘C has always worked: the selection
 * belongs to the xterm instance drawing the pane, which is on *this* Mac, so the
 * copy never crosses the wire at all. What has never worked is the case a person
 * actually hits — an agent, a `tmux`, a `vim`, a `gh` printing a token, or
 * anything else running over there deciding to *put something on the clipboard*.
 * The way a terminal program does that is OSC 52, and xterm.js does not
 * implement it: `InputHandler.ts` in 6.0.0 registers OSC handlers for 0, 1, 2,
 * 4, 8, 10, 11, 12, 104, 110, 111 and 112, and 52 is not among them. So the
 * sequence was parsed, matched nothing, and was dropped in silence — on remote
 * sessions and on local ones alike.
 *
 * ## Why the read form is refused and never answered
 *
 * OSC 52 has two forms. `\x1b]52;c;<base64>` is *set the clipboard*, which is
 * what this implements. `\x1b]52;c;?` is *tell me what is on the clipboard*, and
 * the reply goes back down the same pty — which on a remote pane means this
 * Mac's clipboard is written into a socket to another computer, by a program
 * that computer is running, without anybody pressing anything. Every terminal
 * that ships OSC 52 turns the read half off by default for exactly that reason,
 * and this one does not implement it at all: there is no flag, because a flag is
 * a thing somebody eventually turns on.
 *
 * ## Why a set is allowed without asking
 *
 * Because it is indistinguishable from what the person is already doing. They
 * ran the command; the command copied its output. The bound that matters is
 * size rather than permission — a clipboard is not a file transfer — so a
 * payload over {@link MAX_OSC_CLIPBOARD_BYTES} is refused with a line rather
 * than truncated, since a half-copied token or diff pastes as something that
 * looks right and is not.
 *
 * ## Why it is attached to local sessions too
 *
 * *"the shape of the application should not be changing for local and remote
 * devices."* A local session's OSC 52 was dropped by the same missing handler,
 * and a feature that appeared only on remote panes would be the app changing
 * shape per machine — the rule `RemoteTerminal` already had to be rewritten for.
 */

import type { Terminal } from '@xterm/xterm'
import { byteSize } from '../shared/byte-size'
import { MAX_PASTE_BYTES } from '../shared/paste-cap'
import { promptWord } from './terminal-drop'
import {
  pathForSession,
  type SessionPlace,
  type TransferBridge,
  type TransferSource,
} from './session-transfer'

/** The one line a person sees when a paste is too big to cross. */
export const PASTE_TOO_BIG = `That paste is too big to send — the limit is ${byteSize(MAX_PASTE_BYTES)}.`

/**
 * The most a program may put on the clipboard in one sequence, decoded.
 *
 * A megabyte, the same number a paste in the other direction is bounded by, and
 * deliberately the same: one number for "how much text may cross between a
 * session and the clipboard", whichever way it is going, is one number to
 * explain. It is far above anything real — a full `git diff` of a large change
 * is tens of kilobytes — and low enough that a runaway program cannot make this
 * renderer hold a hundred megabytes of base64 it decoded on the paint thread.
 */
export const MAX_OSC_CLIPBOARD_BYTES = 1024 * 1024

/** How a pane is told a copy was refused. One short line, or nothing. */
export type ClipboardRefusal = (line: string) => void

/** What a pane can tell this handler about the frames it is writing. */
export interface ClipboardOscOptions {
  /**
   * Whether the sequence being parsed right now is the session speaking.
   *
   * False while a remote pane is writing the scrollback the far machine replayed
   * at it, so a copy made an hour ago is not re-performed on this machine's
   * clipboard every time somebody opens the tab. Omitted by a local session,
   * which has no replay to tell apart.
   */
  accept(): boolean
}

/**
 * Everything after `ESC ] 52 ;`, split into the two fields OSC 52 defines.
 *
 * Returns null for anything that is not a set — including the read form `?`,
 * which is refused here rather than deeper in so that there is exactly one place
 * in this file where a reply could ever be composed, and it does not exist.
 *
 * Exported so the parsing can be tested without a terminal: the interesting
 * cases are all strings.
 */
export function readOsc52(payload: string): string | null {
  // `c;<data>` — the targets field may name several selections (`c`, `p`, `s`,
  // or a run of them) and may be empty, which means the default. None of that
  // changes what is done with it: this platform has one clipboard.
  const semicolon = payload.indexOf(';')
  if (semicolon === -1) return null
  const data = payload.slice(semicolon + 1)
  // The read form, and anything that is not base64. `?` is the spelling in the
  // specification; `atob` would throw on it, and a `try` that swallowed the
  // throw would be a place where "we do not answer reads" was an accident.
  if (data === '' || data === '?') return null
  return data
}

/**
 * Decode a set payload, or null if it is not usable.
 *
 * `atob` rather than a hand-rolled decoder because this runs in a browser
 * engine, and the length check comes first so a hostile 200 MB sequence is
 * refused before anything allocates. Base64 is four characters per three bytes,
 * so the encoded length bounds the decoded one without decoding it.
 */
export function decodeOsc52(data: string): { text: string } | { tooLarge: true } | null {
  if ((data.length / 4) * 3 > MAX_OSC_CLIPBOARD_BYTES) return { tooLarge: true }
  let binary: string
  try {
    binary = atob(data)
  } catch {
    return null
  }
  if (binary.length > MAX_OSC_CLIPBOARD_BYTES) return { tooLarge: true }
  // The bytes are UTF-8 — every terminal that emits this sends UTF-8 — and
  // `atob` hands back one character per byte, so they have to be reassembled
  // rather than used directly, or an accented character arrives as mojibake.
  const bytes = new Uint8Array(binary.length)
  for (let at = 0; at < binary.length; at += 1) bytes[at] = binary.charCodeAt(at)
  try {
    return { text: new TextDecoder('utf-8', { fatal: false }).decode(bytes) }
  } catch {
    return null
  }
}

/**
 * Let this terminal put things on the clipboard, and refuse the rest.
 *
 * Returns the disposal, so a pane that tears its terminal down does not leave a
 * handler bound to a disposed parser.
 */
export function attachClipboardOsc(
  term: Terminal,
  refused?: ClipboardRefusal,
  options?: ClipboardOscOptions,
): () => void {
  const handler = term.parser.registerOscHandler(52, (payload: string): boolean => {
    /*
     * Scrollback is not a copy somebody just made.
     *
     * A session on another machine replays its whole history into this terminal
     * the moment a pane attaches, and that history is raw pty output — so an
     * OSC 52 a program emitted an hour ago is parsed again on every attach, and
     * would silently overwrite whatever is on this Mac's clipboard the instant
     * somebody opens the tab. Nobody pressed anything; there is nothing on
     * screen to connect the loss to. `accept` is how the pane says which frames
     * are the session speaking now, and the default is every frame, which is the
     * right answer for a local session that has no replay.
     *
     * `true` still, because the sequence *was* handled: answering `false` would
     * only put an unhandled-sequence line in a console.
     */
    if (options?.accept && !options.accept()) return true
    const data = readOsc52(payload)
    // `true` means handled — including for the read form. Answering `false`
    // would let xterm pass it to a fallback handler, and there is none, so the
    // only difference would be a console line about an unhandled sequence.
    // Silence is right here: refusing to answer a clipboard *read* is not a
    // failure a person needs to be told about, it is the design.
    if (data === null) return true

    const decoded = decodeOsc52(data)
    if (decoded === null) return true
    if ('tooLarge' in decoded) {
      refused?.('That copy was too large to put on the clipboard.')
      return true
    }
    if (decoded.text === '') return true

    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    if (!clipboard?.writeText) {
      refused?.('This window cannot reach the clipboard.')
      return true
    }
    void clipboard.writeText(decoded.text).catch(() => {
      // Denied by the platform, or the window lost focus between the sequence
      // arriving and the write. Said out loud rather than swallowed: the whole
      // point of this pass is that a copy which does nothing must not also say
      // nothing.
      refused?.('That copy did not reach the clipboard.')
    })
    return true
  })
  return () => handler.dispose()
}

/* ------------------------------------------------------------------ *
 * The other direction: something on this machine's clipboard, pasted
 * into a session — which may not be on this machine.
 * ------------------------------------------------------------------ */

/**
 * What a paste is actually carrying, once text has been ruled out.
 *
 * Two shapes reach a paste handler and only one of them has a file behind it.
 *
 *  - **A file copied in Finder or Explorer.** Chromium exposes it as a `File`
 *    with a real path underneath, which `webUtils.getPathForFile` can produce —
 *    the same call a drop already uses. Nothing has to be written: the file is
 *    on this disk, at a path, exactly as if it had been dragged.
 *  - **An image with no file.** ⌘⇧⌃4 on a Mac, *Copy image* in a web page,
 *    anything a program put on the clipboard as pixels. There is no path,
 *    because there is no file. The bytes have to become one before either half
 *    of the transfer rule can run over them.
 *
 * Both are returned rather than one being preferred, because which one arrives
 * is decided by whatever the person copied and not by anything this app can
 * influence, and a handler that understood only the first would do nothing at
 * all for a pasted screenshot — the single most common thing there is to paste
 * at an agent.
 */
export interface PastedFile {
  /** What it should be called. Never empty; the platform's name where there is one. */
  name: string
  /** The path on this machine, when the clipboard had a real file behind it. */
  path: string
  /** The `File` itself, for reading bytes when there is no path. */
  file: File
}

/** MIME types worth naming when the clipboard hands over an unnamed image. */
const IMAGE_EXTENSIONS: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
  'image/tiff': 'tiff',
  'image/bmp': 'bmp',
}

/**
 * A name for something the clipboard handed over without one.
 *
 * Chromium calls a pasted screenshot `image.png` on some platforms and hands
 * over an empty name on others, so a name is composed rather than trusted. The
 * timestamp is local and is there so that pasting three screenshots in a row
 * produces three names a person can tell apart in the folder they land in —
 * the far machine would otherwise answer `image (2).png`, `image (3).png`,
 * which is true and tells them nothing about which is which.
 *
 * Exported for the tests, which are about the shape of the string and need no
 * clipboard to check it.
 */
export function pastedName(file: { name?: string; type?: string }, now: Date): string {
  const given = (file.name ?? '').trim()
  if (given !== '') return given
  const extension = IMAGE_EXTENSIONS[(file.type ?? '').toLowerCase()] ?? 'bin'
  const stamp = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
    '-',
    String(now.getHours()).padStart(2, '0'),
    String(now.getMinutes()).padStart(2, '0'),
    String(now.getSeconds()).padStart(2, '0'),
  ].join('')
  return `pasted-${stamp}.${extension}`
}

/** What this needs to turn a pasted `File` back into a path. Mirrors the drop's. */
export interface PastePathBridge {
  pathForDroppedFile(file: File): string
}

/**
 * The files on a paste, in the order the clipboard listed them.
 *
 * `items` rather than `files`, because the two disagree exactly where it
 * matters: an image on the clipboard with no file behind it appears in `items`
 * with `kind: 'file'` and is reachable through `getAsFile()`, and several
 * Chromium versions have left it out of `files` altogether. Reading `items` is
 * what makes a pasted screenshot work.
 *
 * Returns an empty array for a plain text paste, which is the overwhelmingly
 * common case and must stay exactly as fast and exactly as unmolested as it was
 * — a paste of a diff into an agent is not a file transfer and must not become
 * one.
 */
export function pastedFiles(
  data: DataTransfer | null | undefined,
  bridge: PastePathBridge | null,
  now: Date = new Date(),
): PastedFile[] {
  if (!data) return []
  const out: PastedFile[] = []
  for (const item of Array.from(data.items ?? [])) {
    if (item.kind !== 'file') continue
    const file = item.getAsFile()
    if (!file) continue
    out.push({
      name: pastedName(file, now),
      path: bridge ? bridge.pathForDroppedFile(file) : '',
      file,
    })
  }
  return out
}

/** The half of xterm's `Terminal` this needs. Narrowed so tests need no emulator. */
export interface PastePrompt {
  paste(data: string): void
}

/**
 * What the typing half needs off a {@link PastedFile}.
 *
 * Narrower than `File` on purpose, and for the same reason as {@link
 * PastePrompt}: the interesting behaviour is the order of the hops and what
 * happens when one refuses, and neither needs a DOM to exercise.
 */
export interface PastedBlob {
  name: string
  path: string
  file: { arrayBuffer(): Promise<ArrayBuffer> }
}

/**
 * Put pasted files where the session can open them, and type their paths.
 *
 * The whole of R2, and deliberately the whole of it in one place: a paste into a
 * session on this computer and a paste into a session on a PC in another room
 * run these same lines, and the only thing that differs is what
 * `pathForSession` decides — which is the point. *"It should not matter which
 * device I am on currently running the session."*
 *
 * ## Why the terminal is re-read between files
 *
 * A transfer takes as long as it takes, and the pane can be closed or the
 * session left while it is running. A `Terminal` captured before the await would
 * be a disposed one, and `paste` on it throws inside a promise nobody is
 * watching. `resolve` is called after every hop for that reason, exactly as the
 * drop handler does it.
 *
 * ## Why one at a time, and why each is typed as it lands
 *
 * The host serves one upload per connection, so a multi-file paste to another
 * machine is one transfer after another. They are typed as they land rather than
 * after the last one, so the prompt fills as it goes — and a failure part way
 * through leaves the ones that did land on the line, which is true and useful,
 * rather than discarding them to keep the gesture atomic.
 *
 * ## Why bytes are only read when there is no path
 *
 * A file copied in Finder has a real path behind it, and reading it into this
 * renderer's heap to write it straight back out again would be a copy of
 * somebody's video through a JavaScript array for no purpose. Only a clipboard
 * image — which exists nowhere on the disk — is read.
 */
export async function pasteFilesInto(
  files: readonly PastedBlob[],
  place: SessionPlace,
  resolve: () => PastePrompt | null,
  say: (line: string, sticky?: boolean) => void,
  bridge?: TransferBridge | null,
): Promise<void> {
  for (const file of files) {
    const source: TransferSource =
      file.path !== '' ? { path: file.path } : { name: file.name, bytes: await file.file.arrayBuffer() }
    const outcome = await pathForSession(place, source, bridge)
    const live = resolve()
    if (!live) return
    if (!outcome.ok) {
      say(outcome.message)
      return
    }
    // Cleared here rather than by a `landed` frame alone, so the line goes at
    // the moment the path appears — which is the only success signal this needs,
    // and the reason there is no "sent" message.
    say('')
    live.paste(promptWord(outcome.path))
  }
}
