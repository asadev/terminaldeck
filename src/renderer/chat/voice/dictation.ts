/**
 * What this window's own speech recognition can do — which is nothing — and the
 * small text helpers dictation still needs.
 *
 * ## The measurement that decided the architecture
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
 *
 * So recognition is not asked of the browser. `MediaRecorder` and `getUserMedia`
 * are a different story — those are ordinary capture and they work — and the
 * recognition happens where it can: at a transcription service, behind a key the
 * user supplies. `DictateButton.tsx` does the recording, `transcription.ts`
 * decides whether there is a microphone at all, and `src/main/voice.ts` makes
 * the request.
 *
 * ## What is left in this file
 *
 * The `speechSupport` probe, because a future Electron in which this starts
 * working should be *noticed* rather than assumed, and two text helpers the
 * composer uses. What has gone is the guidance popover: the button used to
 * explain where macOS keeps its own dictation instead of recording, and there is
 * no longer anything to explain.
 *
 * The fourth measurement from the original pass — that the packaged bundle
 * declared no `NSMicrophoneUsageDescription`, so touching the microphone would
 * terminate the process rather than prompt — is the one thing here that has been
 * *fixed* rather than worked around. The key and the audio-input entitlement are
 * in `electron-builder.yml` and `build/entitlements.mac.plist`.
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

/**
 * Whether this is a Mac, for the one settings row that still names an operating
 * system.
 */
export function isMac(userAgent: string): boolean {
  return /Mac|iPhone|iPad/.test(userAgent)
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
