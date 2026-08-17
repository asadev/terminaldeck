import { DEFAULT_SPEED, normalizeSpeed, type ReadingSpeed } from './estimate'

/**
 * Where the reader's pace is kept, and why it is not a setting.
 *
 * `estimate.ts` argues the shape at length: a pace is five **names** rather than
 * a number, because nobody knows their own reading speed in words a minute — it
 * is not a fact anybody has ever been told about themselves — and a spinner
 * reading "190" is a control that can only be set by trial and error. What a
 * person can answer is *"was that too fast?"*.
 *
 * Two consequences for storage:
 *
 * 1. **It is a preference, not a schema setting.** `SettingsWindow.tsx` maps the
 *    `copilot` section to a bespoke `CopilotSection` which renders none of the
 *    schema's rows, so a `NumberSetting` declared into that section would be
 *    declared and drawn nowhere — and `settings/nothing-dropped.test.tsx` exists
 *    to fail on exactly that.
 * 2. **The key rides the bridge untyped.** Adding a field to
 *    `shared/types.ts` is what a typed preference would need, and that file is
 *    on `CLAUDE.md`'s list of files a parallel agent may not edit. The store
 *    merges and persists whatever it is handed, and `normalizeSpeed` is the
 *    narrowing on the way back — which is the same bargain every other feature
 *    on this bridge makes, and the reason it is safe is that a value that comes
 *    back unreadable becomes the documented default rather than an exception.
 *
 * The **scale** travels with the pace and is deliberately not a control. It is a
 * measurement the player derives from how somebody actually behaves; what they
 * are owed is to be able to see it in a sentence and to be able to throw it
 * away, which is what `ReadingSpeedControl` gives them.
 *
 * The copilot cannot change any of this. `PROTECTED_SETTING_PREFIXES` already
 * contains `copilot.`, and `WRITABLE_PREFERENCES` is a short allowlist this key
 * is not on — so `settings.write` refuses it with no new work. That is the
 * correct outcome and worth stating: **the reader's pace is the reader's.**
 */

export const SPEED_KEY = 'tourReadingSpeed'

interface PrefsBridge {
  getPreferences(): Promise<Record<string, unknown>>
  setPreferences(patch: Record<string, unknown>): Promise<Record<string, unknown>>
}

function bridge(): PrefsBridge | null {
  const deck = (globalThis as { deck?: Partial<PrefsBridge> }).deck
  if (!deck || typeof deck.getPreferences !== 'function' || typeof deck.setPreferences !== 'function') {
    return null
  }
  return deck as PrefsBridge
}

/** The stored pace, or the default. Never throws: a tour must still play. */
export async function loadSpeed(deck: PrefsBridge | null = bridge()): Promise<ReadingSpeed> {
  if (deck === null) return DEFAULT_SPEED
  try {
    const prefs = await deck.getPreferences()
    return normalizeSpeed(prefs[SPEED_KEY])
  } catch {
    return DEFAULT_SPEED
  }
}

/**
 * Remember it.
 *
 * Called from two places with two different meanings, and they are the same
 * write: the person picking a pace, and the player having learned a correction
 * at the end of a tour. Keeping them one function is deliberate — the stored
 * value is one thing, and a second writer for the learned half is how the two
 * come to disagree about which pace was chosen.
 */
export async function saveSpeed(
  speed: ReadingSpeed,
  deck: PrefsBridge | null = bridge(),
): Promise<void> {
  if (deck === null) return
  try {
    await deck.setPreferences({ [SPEED_KEY]: { pace: speed.pace, scale: speed.scale } })
  } catch {
    // A pace that could not be saved is a pace that resets next time. Worth
    // nothing more than this comment: it must not take a tour down with it.
  }
}
