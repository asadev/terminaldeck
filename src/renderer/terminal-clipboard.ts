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
export function attachClipboardOsc(term: Terminal, refused?: ClipboardRefusal): () => void {
  const handler = term.parser.registerOscHandler(52, (payload: string): boolean => {
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
