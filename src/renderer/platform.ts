/**
 * What platform this window is running on, and what to call the machine it is
 * running on in a sentence a person reads.
 *
 * ## Why this exists at all
 *
 * The renderer was written on a Mac, for a Mac, and it said so out loud in two
 * ways that are both wrong on Windows:
 *
 *   1. **Glyphs.** ⌘, ⌥ and ⌃ were typed as literals into the command palette,
 *      the empty state and a couple of tooltips. `keymap.ts` has rendered
 *      chords per platform since it was written — the literals were copies of
 *      its output, taken on a Mac, and a copy of a platform-dependent fact is
 *      wrong on the other platform by construction. Windows has no Command key
 *      at all, so `⌘T` is not a shortcut a Windows user can press; it is a
 *      character they cannot type.
 *   2. **Nouns.** "this Mac" appears throughout the remote-access panel. On a
 *      Windows host every one of those sentences is false.
 *
 * `src/main/platform/host.ts` already carries `machineNoun()` for the main
 * process and makes the argument for it at length. This is the renderer's copy
 * of the same decision, and it is a copy on purpose: the renderer cannot import
 * from `src/main` (different bundle, different runtime) and `src/shared` would
 * have to pick between `process.platform` and `navigator`, which are not the
 * same question. The main process reads `process.platform`; a window reads its
 * own user agent. Both describe the machine the app is installed on, because
 * the renderer is always in the same process tree as its main process.
 *
 * ## The one rule for copy that leaves the machine
 *
 * A string **sent to a phone** must name no platform at all — not "Mac", not
 * "PC". One phone can be paired to several machines at once, and the phone
 * already prints the machine's own label beside anything that machine says
 * (`StoredCredential.label` on iOS). "This Mac could not write that file" next
 * to a row that says "desktop-ddgmncv" is either wrong or redundant, and it is
 * wrong far more often. Host-side copy is the opposite: there is exactly one
 * machine in front of the reader, so naming it correctly is the whole point.
 */

/** Just enough of `navigator` to sniff, so this is testable without a DOM. */
export interface NavigatorLike {
  platform?: string
  userAgent?: string
}

export type UiPlatform = 'mac' | 'windows' | 'other'

/**
 * The platform a navigator describes.
 *
 * Both fields are searched rather than `platform ?? userAgent`, which is what
 * `detectMac` used to do and which fails in the one environment that matters
 * for tests: a DOM shim that defines `navigator.platform` as `''` short-circuits
 * the `??` and never reaches the user agent that does say Macintosh. Windows is
 * checked first because it is the narrower match — a Windows user agent
 * contains neither "Mac" nor "iPhone", but nothing guarantees the reverse
 * forever.
 *
 * `'other'` is a real answer, not a fallback for "probably a Mac". Linux has no
 * build target today, and Node — where most of this project's tests run — has a
 * `navigator` whose user agent is `Node.js/22`. Both should get a noun that is
 * true rather than a guess that is usually true.
 */
export function platformFrom(nav: NavigatorLike | undefined | null): UiPlatform {
  if (!nav) return 'other'
  const hay = `${nav.platform ?? ''} ${nav.userAgent ?? ''}`
  if (/Win(?:dows|32|64|CE)/i.test(hay)) return 'windows'
  if (/Mac|iPhone|iPad/.test(hay)) return 'mac'
  return 'other'
}

/** This window's platform. Guarded so the module imports cleanly under vitest. */
export function detectPlatform(): UiPlatform {
  return platformFrom((globalThis as { navigator?: NavigatorLike }).navigator)
}

/**
 * The word for the machine the app is running on.
 *
 * "PC" rather than "computer" on Windows for the reason `host.ts` gives: it is
 * the word a Windows user uses, and matching the reader's word is the entire
 * point of doing this.
 */
export function machineNoun(platform: UiPlatform = detectPlatform()): string {
  if (platform === 'windows') return 'PC'
  if (platform === 'mac') return 'Mac'
  return 'computer'
}

/**
 * The name of the operating system, for the sentences that are about the OS
 * rather than the machine.
 *
 * "macOS decided not to show it" is a different claim from "this Mac is out of
 * disk", and only the first one wants this word. `'other'` gets a phrase with
 * no product name in it rather than a guess, for the same reason `machineNoun`
 * does: Linux has no build target today and a wrong OS name in an error message
 * sends someone looking in a settings app they do not have.
 */
export function osName(platform: UiPlatform = detectPlatform()): string {
  if (platform === 'windows') return 'Windows'
  if (platform === 'mac') return 'macOS'
  return 'your operating system'
}

/** "this Mac" / "this PC" / "this computer", for the middle of a sentence. */
export function thisMachine(platform: UiPlatform = detectPlatform()): string {
  return `this ${machineNoun(platform)}`
}

/** The same, capitalised, for the start of one. */
export function ThisMachine(platform: UiPlatform = detectPlatform()): string {
  return `This ${machineNoun(platform)}`
}

/**
 * How the reader takes a screenshot on their own machine.
 *
 * Windows' Win+Shift+S copies to the clipboard and only writes a file if the
 * Snipping Tool is configured to, so the sentence around this has to say "save
 * it into the project folder" rather than "it lands on your desktop" — which is
 * what the macOS-only copy used to imply.
 */
export function screenshotShortcut(platform: UiPlatform = detectPlatform()): string {
  if (platform === 'windows') return 'Win+Shift+S'
  if (platform === 'mac') return '⇧⌘4'
  return 'your desktop’s screenshot shortcut'
}
