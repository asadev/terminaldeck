/**
 * What a capture is *worth saying*, as three pure functions.
 *
 * This file used to be the docked panel at the bottom of the browser as well.
 * The panel is gone, and so is the popup that replaced it — a clicked element
 * opens an Annotate round now, see `BrowserAnnotate.tsx` — but the rules it
 * carried are used by all three
 * senders and are the only part of it that was ever testable without a DOM:
 * where a label came from, how a string is flattened on its way into a PTY, and
 * exactly what the agent receives.
 */

import type { LabelSource } from './bridge'

/** How a capture panel names where the label came from. */
export function describeLabelSource(source: LabelSource): string {
  return source === 'text' ? 'text' : source === 'none' ? '' : source
}

/**
 * Flatten anything on its way to the agent.
 *
 * Deck types this into a PTY running a coding CLI, where a newline submits the
 * prompt — a two-line message would send the first line as the whole
 * instruction. The main process already guarantees this for the context half;
 * this covers what the user typed into the instruction field.
 */
export function oneLine(value: string): string {
  let out = ''
  for (const char of value) {
    const code = char.codePointAt(0) ?? 0
    // C0 and C1 controls plus the Unicode line separators, written as numbers
    // rather than a regex escape so the intent survives a copy-paste: a newline
    // in this string submits the agent's prompt early, and an ESC can repaint
    // the terminal it lands in.
    const control =
      code < 0x20 || (code >= 0x7f && code <= 0x9f) || code === 0x2028 || code === 0x2029
    out += control ? ' ' : char
  }
  return out.replace(/\s+/g, ' ').trim()
}

/** The exact string the agent receives. */
export function composeSend(context: string, instruction: string): string {
  const lead = oneLine(instruction)
  const tail = oneLine(context)
  return lead ? `${lead} ${tail}` : tail
}

/**
 * How much of an element's text a row shows before eliding it.
 *
 * The main process already clamps to 150 characters. That is the right size for
 * the line an agent receives and far too much for a row in a small popup, where
 * it wraps to four lines and pushes the send box off the bottom. The full text
 * is on the `title`, and the agent still gets all 150.
 */
const TEXT_SHOWN = 90

/** Cut on a word boundary where one is near enough, so it does not end mid-word. */
export function elide(text: string, max = TEXT_SHOWN): string {
  if (text.length <= max) return text
  const cut = text.slice(0, max)
  const space = cut.lastIndexOf(' ')
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).trimEnd()}…`
}
