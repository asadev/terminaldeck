/**
 * Text a person typed, on its way onto a row.
 *
 * Two features in this client let somebody write down something a machine could
 * not tell them — the name of a port (`port-book.ts`) and the name of a machine
 * (`machines.ts`) — and both land in the same place: one line of a row that has
 * to stay one line. So the cleaning rule lives once, here, rather than being
 * written twice and drifting by a `trim()`.
 *
 * It is deliberately **not** the same rule as `plain` in `main.ts`, and the
 * difference is the direction the text came from. `plain` is for strings that
 * arrived over the socket and are about to be written into an emulator that
 * executes what it is given; this is for a string the reader typed into a field in
 * front of them. Nothing here is a security boundary — it is a layout one. The
 * text still reaches the DOM as `textContent` and never as markup, which is what
 * actually makes it safe.
 */

/**
 * The text as it will be stored, or null when there is nothing left of it.
 *
 * Null, empty and whitespace all clear the value, deliberately: a rename field
 * starts populated with whatever is already there, so selecting it all and
 * deleting is the obvious way somebody undoes a name, and it must not leave an
 * empty string behind that reads as a nameless row with a name.
 *
 * Newlines go with the other control characters rather than being turned into
 * spaces. A name with a line break in it is a paste accident, not an intention,
 * and joining the halves with a space guesses at what was meant.
 *
 * The cut happens on the way **in** rather than as an ellipsis on the way out, so
 * the value in the rename field is the value on the row. A field that shows
 * something longer than what was kept is a field that lies about what pressing
 * Save did.
 */
export function cleanLabel(raw: string | null | undefined, maximum: number): string | null {
  if (raw === null || raw === undefined) return null
  // Escaped, never literal: a raw control byte in a character class is invisible
  // in every diff, which is the trap `protocol.ts` documents and `plain` in
  // main.ts follows for the same reason.
  const stripped = raw.replace(/[\u0000-\u001f\u007f]/g, '')
  const trimmed = stripped.trim()
  if (trimmed === '') return null
  if (trimmed.length <= maximum) return trimmed
  // Trimmed again after the cut: a name that runs out mid-word leaves a trailing
  // space, which would come back from storage as a different string than the one
  // the field showed.
  return trimmed.slice(0, maximum).trimEnd()
}
