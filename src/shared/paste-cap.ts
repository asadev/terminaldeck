/**
 * How much text one ⌘V may push into a session on another machine.
 *
 * ## Why this is not in `remote/protocol.ts`
 *
 * Because it is not a wire rule. The wire's rule is `MAX_INPUT_BYTES`, which
 * bounds a *frame* and is enforced by the far machine's parser; a paste larger
 * than that is split by `chunkInput` and arrives whole, so the frame cap is no
 * longer something a person can run into. What is left is the honest question of
 * how big a single gesture may be — and that is a decision about a keyboard, not
 * a property of the protocol. Nothing on the far end enforces this number and
 * nothing should: a client that omitted the check would still be correct, only
 * slower and more likely to be dropped for buffering.
 *
 * Living in `shared` is also what makes there be one of it. The main process
 * needs it as a backstop on `MachineLink.input`, and the window needs it to say
 * a sentence when a paste is refused; a constant in the protocol module could
 * not be reached by the window at all — `tsconfig.web.json` includes
 * `src/renderer`, `src/shared` and nothing else — so the alternative was two
 * numbers that agree until somebody changes one.
 *
 * ## The number
 *
 * A megabyte, which is `Wire.maxPasteBytes` on iOS. The same limit the phone has
 * refused above since uploads shipped, so a paste that is too big is too big on
 * every surface rather than on whichever one you happened to be holding. It is
 * comfortably more than anything a person pastes into a prompt — a
 * hundred-thousand-line stack trace is well under it — and something over it is
 * a file, which is what dropping is for.
 *
 * Local sessions have no cap and are not asked about one. Their bytes go
 * straight into a pty on this machine with no frame around them, so there is
 * nothing to bound, and inventing a limit would be the app changing shape for a
 * reason nobody could see.
 */
export const MAX_PASTE_BYTES = 1024 * 1024

/**
 * Whether one paste is over the cap, measured in UTF-8 bytes.
 *
 * Counted the cheap way first: a UTF-16 code unit is never fewer than one UTF-8
 * byte, so `length > cap` already settles it and a 50 MB clipboard never costs a
 * 50 MB scan. Below that the count has to be exact — 300,000 emoji are 300,000
 * units and 1.2 MB, so length alone would wave a paste past the limit.
 *
 * The sentence for a person belongs to whoever caught the paste, because a
 * boolean has nowhere to put words. In the window that is `PASTE_TOO_BIG`, drawn
 * over the terminal; in the main process there is no surface at all, which is
 * why the check there is a backstop rather than the gate.
 */
export function overPasteCap(text: string): boolean {
  if (text.length > MAX_PASTE_BYTES) return true
  let bytes = 0
  for (const point of text) {
    const code = point.codePointAt(0) ?? 0
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4
    if (bytes > MAX_PASTE_BYTES) return true
  }
  return false
}
