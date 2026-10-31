import type { KeyFileOffer } from './types'

/**
 * Which of the three ways of giving a key are on screen, and what each says.
 *
 * Separated from `AddServer.tsx` for the reason `machines-bridge.ts` is
 * separated from the picker that draws it: there is no DOM in this project's
 * test run, so a decision made inside a component is a decision no test can
 * reach. What is left in the component is the drawing.
 *
 * The rule the shape encodes: **pasting is never taken away.** It is the one
 * route that cannot fail for a reason this screen would then have to explain —
 * no folder to read, no panel to open, no file to still be where it was. So it
 * is shown whenever there is nothing better to offer, and it stays one press
 * away when there is.
 */
export interface KeyRoutes {
  /** Draw the list of keys found on this computer. */
  list: boolean
  /** Draw the button that opens a native panel. */
  panel: boolean
  /** Draw the paste box. */
  paste: boolean
  /** Draw the button that brings the paste box back. */
  offerPaste: boolean
}

export function keyRoutes(input: {
  /** Whether this window can ask the main process at all. */
  hasChooser: boolean
  /** How many keys were found on this computer. */
  found: number
  /** Whether one has been chosen. */
  chosen: boolean
  /** Whether the person asked for the paste box. */
  pasting: boolean
}): KeyRoutes {
  const { hasChooser, found, chosen, pasting } = input
  /*
   * A form with no bridge is the form this screen was until today: a paste box
   * and nothing else. Not an error and not a notice — a copy of this component
   * rendered in the harness or a test has no main process to ask, and a list
   * that could only ever be empty is worse than no list.
   */
  if (!hasChooser) return { list: false, panel: false, paste: true, offerPaste: false }

  const paste = pasting || (found === 0 && !chosen)
  return { list: found > 0, panel: true, paste, offerPaste: !paste }
}

/**
 * What one row in the list says about a key, after its name.
 *
 * The lock is stated only when it is known to be there. `null` means the file
 * did not say — a third state, carried from `keyfiles.ts` intact — and silence
 * is the honest rendering of it: *"no password"* would be a claim we cannot
 * make, and the form asks for a passphrase after the attempt either way.
 */
export function keyRowSays(offer: KeyFileOffer): string {
  return offer.locked === true ? `${offer.what} · needs a password to open` : offer.what
}

/**
 * What the paste box holds when somebody asks for it.
 *
 * Empty when the key on the draft came out of a *file*, and this is a rule
 * about secrets rather than about tidiness. Choosing a key says *"Its contents
 * are not shown here"* — and then pressing **Paste it instead** put the whole
 * private key on screen in a textarea, because the field the chooser writes to
 * is the field the box reads from. Found by looking at it; nothing about the
 * code said so.
 *
 * Somebody who asks to paste is telling us they have a different key. So the
 * box starts empty, the chosen row is cleared with it, and no key material
 * appears on a screen that promised it would not.
 *
 * Anything typed by hand survives, because it was already on screen and putting
 * it away would be losing somebody's work to a toggle.
 */
export function pasteBoxText(input: { fromFile: boolean; typed: string }): string {
  return input.fromFile ? '' : input.typed
}
