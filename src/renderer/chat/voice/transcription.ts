/**
 * Whether there is a microphone at all, and what it would send.
 *
 * ## The rule this file exists to enforce
 *
 * Asad, on the microphone, twice and in the same words both times:
 *
 *   > *"Opening the microphone should ask for a key… it should not come there in
 *   > live until it is solved."*
 *
 * So the chat box gets a microphone **only** when a transcription key is stored
 * and has already been proved to work — the key is checked against the
 * provider's real transcription endpoint before it is saved at all, in
 * `src/main/voice.ts`. There is no state in which the button is drawn and cannot
 * transcribe, which means there is also no need for a disabled microphone or a
 * tooltip apologising for one.
 *
 * ## Why the state is parsed here rather than trusted
 *
 * It arrives as `unknown` off an IPC channel, and the *default* matters more
 * here than in most places: an answer this cannot understand has to mean "no
 * key", because the alternative is a microphone drawn on the strength of a
 * message nobody could read.
 */

/** What the composer should draw, and why. */
export type VoiceState =
  /** No bridge — an older build, or the harness. Draw nothing. */
  | { kind: 'unwired' }
  /** Nothing stored, or nothing storable. Draw nothing; Settings explains. */
  | { kind: 'no-key'; reason: string | null }
  /** A key that has been used successfully. Draw the microphone. */
  | { kind: 'ready'; provider: string }

export interface VoiceStatusShape {
  provider: string | null
  hasKey: boolean
  canStore: boolean
  reason: string | null
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function readVoiceStatus(value: unknown): VoiceState {
  if (!isRecord(value)) return { kind: 'no-key', reason: null }
  if (value.hasKey !== true || typeof value.provider !== 'string' || value.provider === '') {
    return { kind: 'no-key', reason: typeof value.reason === 'string' ? value.reason : null }
  }
  return { kind: 'ready', provider: value.provider }
}

/** The answer to a transcription request, parsed the same defensive way. */
export interface TranscriptionAnswer {
  ok: boolean
  text: string
  message: string
}

export function readTranscriptionAnswer(value: unknown): TranscriptionAnswer {
  if (!isRecord(value)) return { ok: false, text: '', message: 'No answer came back from the transcription service.' }
  return {
    ok: value.ok === true,
    text: typeof value.text === 'string' ? value.text : '',
    message: typeof value.message === 'string' ? value.message : '',
  }
}

/**
 * What to record in, and what to call the file that carries it.
 *
 * The extension is not cosmetic. Every provider in `src/main/voice.ts` sniffs
 * the container from the **filename**, not from the content type, so audio
 * uploaded as `speech` with no extension is refused by two of the three — with
 * a message about the file rather than about the name, which is a bad afternoon
 * for whoever debugs it next.
 *
 * The list is in preference order and is asked of the runtime rather than
 * assumed: this Chromium records WebM/Opus, a future one may not, and a
 * hardcoded type that `MediaRecorder` rejects throws at the moment the user
 * presses record — the worst possible moment to find out.
 */
export const RECORDING_TYPES: ReadonlyArray<{ mime: string; extension: string }> = [
  { mime: 'audio/webm;codecs=opus', extension: 'webm' },
  { mime: 'audio/webm', extension: 'webm' },
  { mime: 'audio/ogg;codecs=opus', extension: 'ogg' },
  { mime: 'audio/mp4', extension: 'm4a' },
]

export function chooseRecordingType(
  supported: (mime: string) => boolean,
): { mime: string; extension: string } | null {
  return RECORDING_TYPES.find((entry) => supported(entry.mime)) ?? null
}

/**
 * Why a recording is not worth sending, or null when it is.
 *
 * A tap rather than a press produces a container header and no audio — a few
 * hundred bytes — and every provider answers 400 to it. Catching that here
 * turns "the provider says your file is too short" into "you did not record
 * anything", which is the same fact told by somebody who knows what happened.
 */
export function refuseRecording(bytes: number, ms: number): string | null {
  if (ms < 400) return 'That was too short to transcribe — hold the button while you speak.'
  if (bytes < 1024) return 'Nothing was recorded. Check that this app has permission to use the microphone.'
  return null
}
