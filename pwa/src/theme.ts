/**
 * Light, dark, and the third state everybody forgets.
 *
 * ## Three states, not two
 *
 * A switch has two positions and an appearance setting has three, and the third
 * one is the default: **follow the system**. Without it, a client either ignores
 * the operating system's own choice — which is the one the person already made,
 * once, for every application on the machine — or it obeys it and gives them no
 * way to disagree with it for this one page. Both of those are visible faults,
 * and the second is the one this client had: it was dark, always, on a laptop
 * whose owner had chosen light everywhere else.
 *
 * So the value stored here is a `ThemeChoice` of three, and what is stamped on
 * the document is an `Appearance` of two. `resolveAppearance` is the only place
 * the first becomes the second, which is what stops "system" leaking into the
 * rest of the client as a third palette that does not exist.
 *
 * ## Why the resolution is in JavaScript when CSS can do it
 *
 * `prefers-color-scheme` alone would handle the default state and nothing else —
 * CSS cannot know that this person chose light on a machine set to dark. But the
 * deciding reason is the terminal: xterm.js takes a colour *object*, not a
 * stylesheet, so its sixteen ANSI slots, its cursor and its selection can only
 * change when something in JavaScript tells them to. A page that themed its
 * chrome from a media query and left the emulator on its dark palette would be
 * the exact failure this is for — a black terminal in a white window.
 *
 * The stylesheet still carries the media query, and it is not redundant: it is
 * what paints the first frame correctly, in the moments between the stylesheet
 * arriving and this module running. See the "three states" comment in
 * `styles.css`, which is the other half of this file.
 *
 * ## Where the choice is kept, and why it is not the pairing's store
 *
 * `localStorage`, always — not the tab store, and not the one
 * `remember.ts` chose for the credential. Those two are one decision about a
 * *secret*: a bearer token on a computer somebody does not own has to be able to
 * leave with them. An appearance is not a secret. Nothing about "this browser
 * prefers light" identifies a machine, a person or a pairing, and the cost of
 * getting it wrong in the other direction is a borrowed laptop that flips back
 * to dark on every visit for somebody who has already told it twice.
 *
 * There is no DOM in this file. vitest runs here with no DOM environment, so
 * every decision that matters is a value a test can ask for; `stampAppearance`
 * takes the element it writes to rather than reaching for `document`.
 */

import type { MatchMedia, MediaQueryLike } from './physical-keyboard'
import type { StorageLike } from './remember'

/**
 * The query the system's own choice arrives on, as a constant so the suite can
 * pin the string.
 *
 * Worth pinning for the same reason `PHYSICAL_KEYBOARD_QUERY` is: the way this
 * feature would be broken is by somebody replacing the query with a guess, and a
 * test that only asserted the behaviour would keep passing while that happened.
 */
export const SYSTEM_DARK_QUERY = '(prefers-color-scheme: dark)'

/** What the person chose. `system` is the default and is a real answer. */
export type ThemeChoice = 'system' | 'light' | 'dark'

/** What is actually painted. Two, because a page is one or the other. */
export type Appearance = 'light' | 'dark'

/**
 * The three, in the order they are drawn.
 *
 * `system` first because it is the default and because a segmented control reads
 * left to right as "the automatic one, then the two overrides".
 */
export const THEME_CHOICES: readonly ThemeChoice[] = ['system', 'light', 'dark']

/**
 * What each choice is called on screen.
 *
 * "Auto" rather than "System": the control is three pills across the top of a
 * phone, and every character costs a pixel that the session title needs more.
 * The longer sentence lives in the accessible name below, where it is free.
 */
export const THEME_LABEL: Record<ThemeChoice, string> = {
  system: 'Auto',
  light: 'Light',
  dark: 'Dark',
}

/** The accessible name for each pill — what a screen reader says, in full. */
export const THEME_DESCRIPTION: Record<ThemeChoice, string> = {
  system: 'Follow this device’s appearance',
  light: 'Always light',
  dark: 'Always dark',
}

/**
 * Where the choice is written.
 *
 * Namespaced like every other key this client owns, so a browser profile with
 * something else on this origin cannot collide with it — and so that clearing
 * a pairing, which walks its own keys, visibly does not touch this one.
 */
export const THEME_KEY = 'terminaldeck.appearance'

/** Whether a string off storage is one of the three. Anything else is not read. */
function known(value: string | null): value is ThemeChoice {
  return value !== null && (THEME_CHOICES as readonly string[]).includes(value)
}

/**
 * The stored choice, or `system`.
 *
 * Defaults on absence *and* on rubbish, and the second is not paranoia: this is
 * `localStorage` on a shared origin, and the failure mode of trusting it is a
 * client that stamps `data-theme="undefined"` on the document and paints
 * whichever palette the cascade falls through to.
 */
export function readChoice(store: StorageLike): ThemeChoice {
  let stored: string | null = null
  try {
    stored = store.getItem(THEME_KEY)
  } catch {
    // A browser that refuses storage is one that has no choice recorded, which
    // is the same state as a first visit. `browserStores` already hands back a
    // memory stand-in for the throwing case; this is the belt for a store that
    // throws on read only.
    return 'system'
  }
  return known(stored) ? stored : 'system'
}

/**
 * Record the choice, or take it away again.
 *
 * `system` *removes* the key rather than writing the word. The two are the same
 * to `readChoice`, and the difference matters on the way out: somebody who set
 * light and then went back to Auto has said "I have no preference here", and
 * leaving `terminaldeck.appearance=system` behind in a borrowed browser's
 * storage would be this client keeping a note of a decision that has been
 * withdrawn.
 */
export function writeChoice(store: StorageLike, choice: ThemeChoice): void {
  try {
    if (choice === 'system') store.removeItem(THEME_KEY)
    else store.setItem(THEME_KEY, choice)
  } catch {
    // Private-mode Safari throws on write. The choice still applies for this
    // page — it is held in memory by the caller — and is simply not remembered,
    // which is the failure everything else in this client makes on that browser.
  }
}

/** The one place a three-valued choice becomes the two-valued thing on screen. */
export function resolveAppearance(choice: ThemeChoice, systemDark: boolean): Appearance {
  if (choice === 'light') return 'light'
  if (choice === 'dark') return 'dark'
  return systemDark ? 'dark' : 'light'
}

/**
 * The attribute the stylesheet switches on.
 *
 * Written out as a constant because it is spelled in two files that cannot
 * import each other — here, and in every `:root[data-theme='…']` selector in
 * `styles.css` — and a typo in either one is a page that silently keeps the
 * palette it had.
 */
export const THEME_ATTRIBUTE = 'data-theme'

/** The part of an element this module writes to. Structural, so a test can pass one. */
export interface ThemeSurface {
  setAttribute(name: string, value: string): void
}

/**
 * Put the resolved appearance on the document element.
 *
 * Always an explicit value, never absent: the stylesheet's media query is
 * written to stand down as soon as something has been stamped, so leaving the
 * attribute off for "system" would mean the person's *explicit* dark on a light
 * machine had nothing to beat the media query with.
 */
export function stampAppearance(root: ThemeSurface, appearance: Appearance): void {
  root.setAttribute(THEME_ATTRIBUTE, appearance)
}

/**
 * What the browser paints its own chrome with — the `theme-color` meta.
 *
 * The canvas colour of each theme, copied by value because a `<meta>` cannot
 * hold a `var()`. `pwa/tests/theme-tokens.test.ts` holds these against
 * `--bg-primary` in the stylesheet, which is the mechanism that stops the copy
 * drifting; two colours that must agree and are written twice are two colours
 * that will one day not agree.
 */
export const THEME_COLOR: Record<Appearance, string> = {
  light: '#ffffff',
  dark: '#191919',
}

export interface SystemAppearance {
  /** Whether the operating system is asking for dark right now. */
  dark: boolean
  /** Stop listening. Safe to call twice. */
  stop(): void
}

/**
 * The system's own answer, now and whenever it changes.
 *
 * Mirrors `watchPhysicalKeyboard` deliberately, down to the shape of the return
 * value: both are "ask the browser about the world, and keep asking", and having
 * them look alike is what stops the next one being written a third way.
 *
 * A browser with no `matchMedia` gets **dark**, and that is a decision rather
 * than a coin toss. Dark is the base of the stylesheet, the palette this client
 * shipped with, and the one a terminal is read in; a page that cannot ask the
 * question should land on the appearance that is right where this client is most
 * used rather than flipping to paper on a phone at night.
 *
 * `onChange` fires only on a genuine flip and never for the initial value — the
 * caller already has that in `dark`, and a spurious first call would re-theme the
 * emulator on the first tick of every page load.
 */
export function watchSystemAppearance(
  matchMedia: MatchMedia | undefined,
  onChange: (dark: boolean) => void,
): SystemAppearance {
  if (matchMedia === undefined) return { dark: true, stop: () => undefined }

  let query: MediaQueryLike
  try {
    query = matchMedia(SYSTEM_DARK_QUERY)
  } catch {
    return { dark: true, stop: () => undefined }
  }

  const watch: SystemAppearance = {
    dark: query.matches,
    stop(): void {
      query.removeEventListener('change', listener)
    },
  }

  const listener = (event: { matches: boolean }): void => {
    if (event.matches === watch.dark) return
    watch.dark = event.matches
    onChange(event.matches)
  }

  query.addEventListener('change', listener)
  return watch
}
