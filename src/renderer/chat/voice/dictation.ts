/**
 * Dictation into the composer, and why it is the operating system's and not
 * ours.
 *
 * The obvious build is the Web Speech API: `SpeechRecognition` exists in this
 * Electron's Chromium, so a microphone button looks like twenty lines of work.
 * It was measured in this exact Electron (41.10.5, Chromium 146) before any of
 * it was written, and it does not work:
 *
 *  - `recognition.start()` fires `start` after 180ms and then emits **nothing**
 *    for the next ten seconds. No `audiostart`, no `result`, no `end`, and — the
 *    part that decides this — no `error`. A control whose failure mode is
 *    indistinguishable from listening cannot be made honest at runtime, because
 *    there is no signal to react to.
 *  - `SpeechRecognition.available({ processLocally: true })` never settles at
 *    all; it was still pending after two minutes. There is no on-device model.
 *  - The cloud path compiled into the framework is Chrome's private endpoint,
 *    `https://www.google.com/speech-api/full-duplex/v1`, which answers only for
 *    builds carrying Google's API keys. Electron ships none, and no
 *    configuration in this repo can add them.
 *  - Microphone authorisation for the app reads `not-determined`, and the
 *    packaged bundle declares no `NSMicrophoneUsageDescription` — on macOS,
 *    touching the microphone without that key terminates the process rather
 *    than prompting.
 *
 * So there is no recording state to render, no level to meter and no stop to
 * offer. What there is: macOS Dictation types into whatever text field has
 * focus, including this one, needs no permission from this app, and is already
 * enabled on the machine this was written on. The button therefore does the one
 * useful mechanical thing — puts the caret in the composer — and says plainly
 * where the microphone lives.
 */

/** Whether the Web Speech constructor exists at all. */
export type SpeechSupport = 'missing' | 'present-but-silent'

interface SpeechScope {
  SpeechRecognition?: unknown
  webkitSpeechRecognition?: unknown
}

/**
 * What the runtime offers, reported without flattery.
 *
 * `present-but-silent` is deliberately not called `available`: the constructor
 * being there is exactly the observation that misleads, and naming it after
 * what it does instead of what it is stops the next reader from wiring a
 * recorder to it.
 */
export function speechSupport(scope: SpeechScope | undefined = globalThis as SpeechScope): SpeechSupport {
  if (!scope) return 'missing'
  const ctor = scope.SpeechRecognition ?? scope.webkitSpeechRecognition
  return typeof ctor === 'function' ? 'present-but-silent' : 'missing'
}

export function isMac(userAgent: string): boolean {
  return /Mac|iPhone|iPad/.test(userAgent)
}

export interface DictationGuidance {
  /** Sentence one: where dictation comes from. */
  summary: string
  /** The steps, in order, each short enough to read at a glance. */
  steps: string[]
  /** Why it is not in this window. Shown smaller, and only once asked for. */
  reason: string
}

const WHY_NOT_IN_APP =
  'Speech recognition in this window would need Chrome’s own speech service, which Electron does not ship — it starts and then stays silent forever, so there is no honest recording state to show.'

/**
 * The guidance the popover renders.
 *
 * The macOS shortcut is deliberately not asserted: this machine has the
 * Dictation hotkey unbound in `com.apple.symbolichotkeys`, so "press Fn twice"
 * would have been confidently wrong. The Edit menu item is always present —
 * macOS appends it to any app with a standard Edit menu, and this app has one.
 */
export function dictationGuidance(userAgent: string): DictationGuidance {
  if (isMac(userAgent)) {
    return {
      summary: 'Dictation comes from macOS and types straight into this box.',
      steps: [
        'The composer is focused, ready for it.',
        'Choose Edit ▸ Start Dictation in the menu bar.',
        'Or use the shortcut set in System Settings ▸ Keyboard ▸ Dictation.',
        'Speak. Stop the same way, then edit before sending.',
      ],
      reason: WHY_NOT_IN_APP,
    }
  }
  return {
    summary: 'Dictation comes from the operating system and types into this box.',
    steps: [
      'The composer is focused, ready for it.',
      'On Windows, press Win + H.',
      'On Linux, use whichever dictation tool your desktop provides.',
      'Speak. Stop the same way, then edit before sending.',
    ],
    reason: WHY_NOT_IN_APP,
  }
}

/**
 * Appending dictated — or any — text to what is already typed.
 *
 * Kept here because the spacing rule is the whole reason a caller would want a
 * function: dictation lands mid-thought as often as not, and gluing `and then`
 * onto `fix the parser` without a space is the one thing that makes the feature
 * feel broken.
 */
export function appendSpoken(existing: string, spoken: string): string {
  const addition = spoken.trim()
  if (addition === '') return existing
  if (existing === '') return addition
  return /\s$/.test(existing) ? existing + addition : `${existing} ${addition}`
}
