/**
 * Is this text really on that screen — asked identically on both sides of the
 * bridge.
 *
 * A tour stop carries a `quote`: a passage the copilot says is in another
 * session's output, which the app is about to draw a box around and print under
 * its own chrome. `DRIVING-MODE.md` §2d makes the rule that quote has to pass —
 * *"every stop's quote is verified against the real source before the tour
 * plays"* — and the reason it is a rule rather than a nicety is that the copilot
 * composed it from *other sessions' transcripts*, which
 * `COPILOT-CAPABILITIES.md` §3.2 item 8 classes as evidence from an untrusted
 * source. An unverified quote is a sentence a transcript wrote, appearing on
 * screen with the app's name on it.
 *
 * ## Why this lives in `shared/` rather than in either half
 *
 * The check happens **twice**, in two processes, and it has to be the same
 * check both times:
 *
 *  - **Main**, in `deck-control/tour.ts`, against the retained pty scrollback
 *    and the transcript. That is the gate: a stop that fails there never leaves
 *    the main process, so a fabricated quote cannot reach a window at all.
 *  - **The renderer**, in `driving/terminal-region.ts`, against the live xterm
 *    buffer, because that is where the box is actually placed and the buffer is
 *    the only thing that knows which *line* the text is on.
 *
 * Two implementations of "is this string in that text" would agree until the day
 * one of them learned about a control character the other did not, and the
 * failure would be silent in the worse direction: a stop main accepted and the
 * renderer cannot draw is a hole in a tour, and a stop the renderer would
 * happily draw that main never checked is the hole this file exists to close.
 * `terminal-region.ts` re-exports these rather than keeping a copy.
 *
 * Nothing here knows about terminals, sessions or tours. It is string handling,
 * and it is in `shared/` for the same reason `brand.ts` is: both processes need
 * exactly one answer.
 */

/**
 * How many printable characters of the first quoted line are matched on.
 *
 * A whole quote cannot be matched as one string — terminal output wraps at the
 * window width, and an agent CLI repaints a line with different padding as its
 * spinner column changes — so the match is anchored on the first line and the
 * rest is walked forward from there by whoever needs the extent. 64 characters
 * is long enough that a match is not a coincidence, and short enough to survive
 * a line that was truncated by the pane it was printed into.
 */
export const NEEDLE_CHARS = 64

/**
 * A line of output, reduced to what is worth comparing.
 *
 * Three normalisations, each for a fault seen in real agent output:
 *
 * - **Control characters go.** A quote that travelled through a transcript, an
 *   MCP payload and a JSON round-trip can carry stray C0/C1 bytes that were
 *   never on screen; and raw pty bytes are full of escape sequences that are
 *   invisible in the rendered line the copilot read.
 * - **Runs of whitespace collapse to one space.** A terminal pads to the column
 *   width, so a line that reads `done` is really `done` followed by 105 blanks.
 * - **Ends are trimmed.** Same reason, at both ends: box-drawing TUIs indent.
 *
 * Case is deliberately **not** folded. Terminal output is case-significant —
 * `ERROR` and `error` are different events — and the quote is claimed to have
 * come from this very text, so there is nothing to be tolerant of.
 */
export function normalizeLine(text: string): string {
  return text
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/** The first non-empty normalised line of a quote, cut to the needle length. */
export function needleOf(quote: string): string {
  for (const line of quote.split('\n')) {
    const clean = normalizeLine(line)
    if (clean !== '') return clean.slice(0, NEEDLE_CHARS)
  }
  return ''
}

/**
 * Strip the escape sequences out of raw pty bytes.
 *
 * The main process retains what the process *wrote*, not what xterm *drew*, so
 * the same line arrives here wrapped in cursor moves, colour changes and window
 * title updates. None of that was ever visible, and leaving it in means a needle
 * built from the rendered text never matches the raw bytes it came from.
 *
 * Three families, which is all this needs rather than a full terminal emulator,
 * stripped in this order because each one can otherwise be cut in half by the
 * next:
 *
 *  1. **OSC** — escape, `]`, a payload, then BEL or a string terminator. First,
 *     because its payload can contain a character that looks like a CSI final
 *     byte.
 *  2. **CSI** — escape, `[`, parameters, a final byte. The colour runs.
 *  3. **The short escapes** — escape, any intermediate bytes, one final byte.
 *     That covers both the C1 forms and the character-set designators such as
 *     escape `(B`, which a shell emits on almost every prompt. Written as a
 *     range rather than as the C1 set alone because the C1-only version was
 *     measured leaving `(B` behind as visible text at the head of a line — which
 *     is worse than leaving the escape intact, since the needle then has to
 *     match around noise that was never on screen.
 *
 * Anything left over is swept up by {@link normalizeLine}'s control-character
 * pass, which is the belt to this file's braces — the goal is a *conservative*
 * comparison, not a faithful emulation, and a leftover byte becoming a space
 * costs nothing because runs of whitespace collapse anyway.
 */
export function stripAnsi(raw: string): string {
  return (
    raw
      /*
       * OSC first: its payload can contain characters that look like a CSI
       * final byte, so removing CSI sequences before it would cut an OSC in
       * half and leave its tail behind as visible text — which is how a window
       * title ends up looking like terminal output. Claude Code sets its title
       * on almost every turn, so this is the common case rather than the exotic
       * one.
       */
      .replace(/\u001b\][\s\S]*?(?:\u0007|\u001b\\)/g, '')
      .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
      .replace(/\u001b[ -/]*[0-~]/g, '')
  )
}

/**
 * Is the quote's opening line present anywhere in this text?
 *
 * The needle rather than the whole quote, for the reason {@link NEEDLE_CHARS}
 * gives, and normalised per line rather than over the whole blob so that a
 * quote's line breaks do not have to fall where the source's did.
 *
 * Deliberately **permissive about the tail and strict about the head**. A
 * repaint can overwrite the last three lines of a five-line passage, and a stop
 * dropped because line four went missing is a real thing lost to a cosmetic
 * difference; a stop whose *first* line was never there is a stop about text
 * that was never on screen. The extent — how much of the rest is really present
 * — is a question for whoever is drawing the box, and `terminal-region.ts`
 * answers it against the live buffer.
 */
export function containsQuote(haystack: string, quote: string): boolean {
  const needle = needleOf(quote)
  if (needle === '') return false
  for (const line of haystack.split('\n')) {
    if (normalizeLine(line).includes(needle)) return true
  }
  /*
   * A second pass over the text with its own line breaks ignored.
   *
   * Raw pty bytes carry a carriage return with no line feed — that is how a CLI
   * redraws a line in place — so splitting on newlines alone can leave two
   * logically separate lines glued into one string. Normalising the whole blob
   * turns every one of those into a single space, which makes the needle
   * findable in the one case the line-wise pass cannot see. It runs second
   * because it is the looser test: a needle that spans what were really two
   * lines is a weaker match than one that sat on a line of its own.
   */
  return normalizeLine(haystack).includes(needle)
}
