import { describe, expect, it } from 'vitest'
import {
  chooseRecordingType,
  readTranscriptionAnswer,
  readVoiceStatus,
  refuseRecording,
  RECORDING_TYPES,
} from './transcription'

/**
 * The gate, and it is the whole of this feature's promise.
 *
 * Asad, on the microphone: *"it should not come there in live until it is
 * solved."* Every test in the first block is that sentence turned into a rule —
 * every state that is not "a key that has already worked" has to resolve to "do
 * not draw a microphone", including the states that are somebody else's bug.
 */
describe('whether there is a microphone at all', () => {
  it('is ready only when a key is stored for a known provider', () => {
    expect(readVoiceStatus({ hasKey: true, provider: 'groq', canStore: true, reason: null })).toEqual({
      kind: 'ready',
      provider: 'groq',
    })
  })

  it('is not ready when there is no key', () => {
    expect(readVoiceStatus({ hasKey: false, provider: null, canStore: true, reason: null })).toEqual({
      kind: 'no-key',
      reason: null,
    })
  })

  it('carries the reason when nothing can be stored at all', () => {
    const state = readVoiceStatus({ hasKey: false, provider: null, canStore: false, reason: 'No keyring.' })
    expect(state).toEqual({ kind: 'no-key', reason: 'No keyring.' })
  })

  /*
   * The direction a malformed answer has to fail in. A garbled status must not
   * produce a microphone — that would be a live-looking control drawn on the
   * strength of a message nobody could read, which is the exact failure the gate
   * exists to prevent.
   */
  it('draws no microphone for an answer it cannot understand', () => {
    for (const answer of [null, undefined, 'yes', 42, [], {}, { hasKey: 'true' }, { hasKey: true }]) {
      expect(readVoiceStatus(answer).kind, JSON.stringify(answer) ?? 'undefined').not.toBe('ready')
    }
  })
})

describe('what the transcription said', () => {
  it('reads a successful answer', () => {
    expect(readTranscriptionAnswer({ ok: true, text: 'hello', message: '' })).toEqual({
      ok: true,
      text: 'hello',
      message: '',
    })
  })

  it('treats a missing answer as a failure with something to read', () => {
    expect(readTranscriptionAnswer(undefined).ok).toBe(false)
    expect(readTranscriptionAnswer(undefined).message).not.toBe('')
  })
})

describe('what to record in', () => {
  it('takes the first type the runtime actually supports', () => {
    expect(chooseRecordingType((mime) => mime === 'audio/webm')).toEqual({ mime: 'audio/webm', extension: 'webm' })
    expect(chooseRecordingType((mime) => mime === 'audio/mp4')).toEqual({ mime: 'audio/mp4', extension: 'm4a' })
  })

  it('answers null rather than guessing when nothing is supported', () => {
    // Hardcoding a type `MediaRecorder` rejects throws at the moment the user
    // presses record, which is the worst possible moment to find out.
    expect(chooseRecordingType(() => false)).toBeNull()
  })

  /*
   * The extension is load-bearing: the transcription APIs sniff the container
   * from the filename rather than from the content type, so a type whose
   * extension did not match its container would be refused by the provider with
   * a message about the file.
   */
  it('pairs every type with the extension its container is named by', () => {
    for (const entry of RECORDING_TYPES) {
      expect(entry.mime, entry.extension).toContain(entry.extension === 'm4a' ? 'mp4' : entry.extension)
    }
  })
})

describe('a recording not worth sending', () => {
  it('catches a tap before the provider has to', () => {
    // A tap produces a container header and no audio; every provider answers
    // 400 to it, with a message about the file. Saying "you did not record
    // anything" is the same fact from somebody who knows what happened.
    expect(refuseRecording(300, 120)).toMatch(/too short/)
    expect(refuseRecording(120, 2000)).toMatch(/Nothing was recorded/)
  })

  it('lets a real recording through', () => {
    expect(refuseRecording(48_000, 3000)).toBeNull()
  })
})
