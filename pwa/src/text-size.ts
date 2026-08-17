/**
 * How big the terminal's characters are, as the person answered it.
 *
 * The phone has had this since the recording — `ios/TerminalDeck/Terminal/
 * TextSize.swift`, reached from a pinch, the session menu and Settings — and this
 * client has drawn every session at a hardcoded 13px since it existed. On a phone
 * that is defensible; in a browser tab it is not, because the same page is opened
 * on a 27" monitor and on a 6" screen held at arm's length, and there is no
 * system text-size setting a terminal emulator honours.
 *
 * ## Why the bounds are what they are
 *
 * The same two sentences the phone's file gives, measured against the same
 * problem. Below ten pixels a `1`, an `l` and an `I` are the same shape in
 * JetBrains Mono, which is the one thing a terminal may never let happen. Above
 * twenty-two a portrait phone cannot hold a shell prompt on one line, and
 * `terminal.ts` clamps the negotiated column count anyway — so a larger value
 * would stop changing anything and start refusing to fit.
 *
 * Thirteen is the standard because it is what this client has always drawn at, and
 * `createTerminal` still says why: it fits 80 columns on a 6.1" screen in
 * landscape, which is the width most CLI output is still written for.
 *
 * ## Why this is not the appearance's neighbour in `theme.ts`
 *
 * It nearly is — both are preferences about this browser rather than about a
 * machine, and both are read before anything is drawn. They are kept apart because
 * `theme.ts` also owns the *resolution* of `system`, the media-query subscription
 * and the emulator's colour object, and none of that has an analogue here. What
 * they do share is the store: `localStorage`, not the pairing's store, because a
 * font size identifies nobody and is the one preference somebody genuinely wants
 * to survive a pairing they deliberately let die with the tab.
 */

import type { StorageLike } from './remember'

/** Below this a `1`, an `l` and an `I` are the same shape. */
export const MIN_TEXT_SIZE = 10
/** Above this a portrait phone cannot hold a shell prompt on one line. */
export const MAX_TEXT_SIZE = 22
/** What this client has always drawn at, and what it still starts at. */
export const STANDARD_TEXT_SIZE = 13
/** One press of the smaller/larger control. */
export const TEXT_SIZE_STEP = 1

export const TEXT_SIZE_KEY = 'terminaldeck.text-size.v1'

/**
 * Rounded to a whole pixel and held inside the bounds.
 *
 * Every path into a font size goes through here, so there is exactly one place
 * that can be wrong — including the read below, because a value stored by a build
 * with different bounds, or typed into a devtools console, must not be able to
 * produce a one-pixel terminal somebody then cannot read well enough to fix.
 */
export function clampTextSize(size: number): number {
  if (!Number.isFinite(size)) return STANDARD_TEXT_SIZE
  return Math.min(MAX_TEXT_SIZE, Math.max(MIN_TEXT_SIZE, Math.round(size)))
}

export function largerText(size: number): number {
  return clampTextSize(size + TEXT_SIZE_STEP)
}

export function smallerText(size: number): number {
  return clampTextSize(size - TEXT_SIZE_STEP)
}

export function canGoLarger(size: number): boolean {
  return clampTextSize(size) < MAX_TEXT_SIZE
}

export function canGoSmaller(size: number): boolean {
  return clampTextSize(size) > MIN_TEXT_SIZE
}

/**
 * What the settings row reads.
 *
 * `px` rather than the phone's `pt`, because that is the unit this client's
 * emulator is actually configured in and a browser has no points. Naming the unit
 * at all is what makes the number mean something to somebody who has not seen the
 * control before.
 */
export function textSizeLabel(size: number): string {
  return `${clampTextSize(size)} px`
}

/**
 * The stored size, or the standard one.
 *
 * A store that throws — Safari in private mode does — is an unanswered question
 * rather than an error, and the unanswered answer is the size this client has
 * always used.
 */
export function readTextSize(storage: StorageLike): number {
  let raw: string | null
  try {
    raw = storage.getItem(TEXT_SIZE_KEY)
  } catch {
    return STANDARD_TEXT_SIZE
  }
  if (raw === null) return STANDARD_TEXT_SIZE
  const parsed = Number.parseFloat(raw)
  return Number.isFinite(parsed) ? clampTextSize(parsed) : STANDARD_TEXT_SIZE
}

export function writeTextSize(storage: StorageLike, size: number): void {
  try {
    storage.setItem(TEXT_SIZE_KEY, String(clampTextSize(size)))
  } catch {
    // Out of quota, or private mode. The terminal in front of the person is
    // already the size they asked for; only the next launch forgets.
  }
}
