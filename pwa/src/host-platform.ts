/**
 * What kind of machine is on the other end, and what this client is allowed to
 * call it.
 *
 * ## The bug this module exists to end
 *
 * A phone paired to a Windows PC read **"No sessions are running on the Mac."**
 * while looking at that PC's own sessions. Nothing had gone wrong on the wire:
 * the desktop never said what it was, so the noun was a string constant compiled
 * into this client, and the constant said Mac because the first machine anyone
 * pointed it at was one.
 *
 * `welcome.hostPlatform` now carries the raw `process.platform` — see the field's
 * own note in `src/main/remote/protocol.ts` — and every client maps it to a noun
 * in its own language. This is that mapping for the browser client.
 *
 * ## Why `unknown` is a real answer and not a placeholder
 *
 * The field is optional, and optional here means "a desktop released before this
 * existed". Those are still desktops this client has to talk to, and the honest
 * thing to say about one is a word that is true of all of them. Guessing "Mac"
 * for an absent field is precisely the defect above, so the fallback must never
 * name a specific machine — which is why `readHostPlatform` folds *everything*
 * it does not recognise, absent included, onto `unknown` rather than onto `mac`.
 *
 * ## Why it takes `unknown` and never throws
 *
 * The two callers are a decoded socket frame and a JSON blob out of
 * `localStorage`. Neither is this client's own data, so neither may be trusted
 * to be a string, and a narrowing function that accepts `unknown` is what keeps
 * a cast out of both call sites.
 */

export type HostPlatform = 'mac' | 'windows' | 'linux' | 'unknown'

/**
 * Map the desktop's raw `process.platform` onto something this client can say.
 *
 * `darwin`/`win32`/`linux` are the three Electron ships on. Anything else — a
 * BSD, a future platform, a truncated field, no field at all — is `unknown`
 * rather than a refusal: a desktop on a platform this build has never heard of
 * is still a desktop worth showing sessions for.
 */
export function readHostPlatform(wire: unknown): HostPlatform {
  switch (wire) {
    case 'darwin':
      return 'mac'
    case 'win32':
      return 'windows'
    case 'linux':
      return 'linux'
    default:
      return 'unknown'
  }
}

/**
 * Read back a value **this client wrote**, rather than one the desktop sent.
 *
 * Deliberately a second function rather than a wider `readHostPlatform`, because
 * the two vocabularies are genuinely different: the wire says `win32` and this
 * module's own type says `windows`, and one function that accepted both would be
 * one function that can no longer tell a desktop's answer from a stored one.
 *
 * That is not a hypothetical. `loadCredential` first read its stored value
 * through `readHostPlatform`, which knows only the wire words — so a phone that
 * had correctly learned `windows` wrote it to `localStorage`, read it back as
 * `unknown`, and went straight back to calling the machine a desktop on every
 * launch. The round-trip test in `pair.test.ts` is what caught it.
 *
 * Takes `unknown` because `localStorage` is JSON somebody could have edited, and
 * anything that is not one of the four names is `unknown` — the same neutral
 * answer, for the same reason.
 */
export function asHostPlatform(value: unknown): HostPlatform {
  switch (value) {
    case 'mac':
    case 'windows':
    case 'linux':
      return value
    default:
      return 'unknown'
  }
}

/**
 * The noun to drop into a sentence: "No sessions are running on the **Mac**".
 *
 * No article and no capital beyond the proper noun, so callers can compose. "PC"
 * rather than "computer" because it is the word a Windows user uses about their
 * own machine, and matching the reader's word is the entire point of doing this.
 * `unknown` reads "desktop", which is true of every host this client can reach
 * and singles out none of them.
 */
export function machineNoun(platform: HostPlatform): string {
  switch (platform) {
    case 'mac':
      return 'Mac'
    case 'windows':
      return 'PC'
    case 'linux':
      return 'machine'
    case 'unknown':
      return 'desktop'
  }
}
