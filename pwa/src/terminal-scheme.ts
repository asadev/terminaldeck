/**
 * The terminal's colours, in the browser client.
 *
 * ## One model, two stores
 *
 * The schemes themselves — the shape, the thirteen that ship, the parsing, the
 * export — are `src/shared/terminal-theme.ts`, imported rather than restated.
 * That is the whole reason that file is in `src/shared`: this client and the
 * desktop draw the same sessions and had better draw them in the same colours,
 * and the way two clients come to disagree about a palette is by each keeping
 * its own copy of it. `terminal.ts`'s own two `ITheme` objects are the standing
 * example — they are this client's *appearance*, not a scheme, and they stay.
 *
 * What is local is **where the choice is kept**, and it is `localStorage`, for
 * the same two reasons `text-size.ts` gives at length. A scheme is a preference
 * about this browser rather than about a machine: it identifies nobody, it says
 * nothing about a pairing, and somebody who has told a borrowed laptop twice
 * that they want a light terminal should not be told a third time. It therefore
 * survives a pairing they deliberately let die with the tab.
 *
 * ## Why one key holds every custom scheme here and not on the desktop
 *
 * The desktop stores one settings key per scheme, because its settings file
 * cuts a string at 4096 characters *silently* and a list of schemes would grow
 * past that and take the whole list with it. `localStorage` has no such cut —
 * its limit is megabytes and exceeding it throws, which is a failure that can
 * be caught and reported rather than a value that comes back quietly torn. So
 * this side keeps the simpler shape, and the two are not inconsistent: they are
 * the same data stored the way each store is safe to store it.
 *
 * There is no DOM in this file, like `theme.ts` and `text-size.ts` beside it:
 * every decision is a value a test can ask for.
 */

import {
  BUILTIN_SCHEMES,
  FOLLOW_APP_SCHEME_ID,
  MAX_CUSTOM_SCHEMES,
  isTerminalScheme,
  schemeById,
  type TerminalScheme,
} from '../../src/shared/terminal-theme'
import type { StorageLike } from './remember'

/** Which scheme is on. `follow-app` — the default — means "neither of these". */
export const SCHEME_KEY = 'terminaldeck.terminal-scheme.v1'

/** Every scheme this browser's owner made, as one JSON array. */
export const CUSTOM_SCHEMES_KEY = 'terminaldeck.terminal-schemes.v1'

/**
 * The stored choice, or the default.
 *
 * A store that throws — Safari in private mode does — is an unanswered question
 * rather than an error, and the unanswered answer is the appearance this client
 * has always had.
 */
export function readSchemeChoice(storage: StorageLike): string {
  try {
    return storage.getItem(SCHEME_KEY) ?? FOLLOW_APP_SCHEME_ID
  } catch {
    return FOLLOW_APP_SCHEME_ID
  }
}

export function writeSchemeChoice(storage: StorageLike, id: string): void {
  try {
    storage.setItem(SCHEME_KEY, id)
  } catch {
    // Out of quota, or private mode. The terminal in front of the person is
    // already in the colours they asked for; only the next launch forgets.
  }
}

/**
 * The schemes somebody made here.
 *
 * Anything that is not a scheme is dropped rather than thrown on, and the
 * dropping is per entry: one damaged object in the array must not cost somebody
 * the other four. The same rule the desktop's reader lives by, for the same
 * reason — this is a file shared with whatever build of this page loads next.
 */
export function readCustomSchemes(storage: StorageLike): TerminalScheme[] {
  let raw: string | null
  try {
    raw = storage.getItem(CUSTOM_SCHEMES_KEY)
  } catch {
    return []
  }
  if (raw === null) return []
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return []
  }
  if (!Array.isArray(parsed)) return []
  return parsed.filter((entry): entry is TerminalScheme => isTerminalScheme(entry)).slice(0, MAX_CUSTOM_SCHEMES)
}

export function writeCustomSchemes(storage: StorageLike, schemes: readonly TerminalScheme[]): void {
  try {
    storage.setItem(CUSTOM_SCHEMES_KEY, JSON.stringify(schemes.slice(0, MAX_CUSTOM_SCHEMES)))
  } catch {
    // See above. Nothing on screen changes; the next launch has one fewer.
  }
}

/**
 * What to paint, given a choice and the schemes this browser holds.
 *
 * `null` means *follow the app's own light and dark*, which is what this client
 * has always done and what an untouched browser still does. An id nothing
 * answers resolves to `null` too — that is a scheme deleted in another tab, or
 * a page served by an older build — and the fallback is deliberately the
 * appearance rather than the first built-in: repainting somebody's terminal in
 * a colour they never chose is worse than ignoring a choice that has gone.
 */
export function resolveScheme(
  choice: string,
  customs: readonly TerminalScheme[],
): TerminalScheme | null {
  if (choice === '' || choice === FOLLOW_APP_SCHEME_ID) return null
  return schemeById(choice, customs)
}

/** Everything the picker draws, in the order it draws them. */
export function schemesToOffer(customs: readonly TerminalScheme[]): TerminalScheme[] {
  return [...BUILTIN_SCHEMES, ...customs]
}
