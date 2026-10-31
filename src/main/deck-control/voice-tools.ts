/**
 * Dictation: the transcription key, and turning recorded audio into words.
 *
 * The Voice section of Settings, as tools — which provider to transcribe with,
 * saving and forgetting its key, and transcribing a recording.
 *
 * ## The key goes in and never comes out
 *
 * `voice.ts` says it of its own channels: *"no channel that hands the key
 * back."* The same is true here. `voice.status` says whether there is a key and
 * which provider it is for; `voice.save_key` takes one, has the provider check
 * it, stores it in the operating system's secure store only if it works, and
 * answers with a sentence. The key is taken out of the arguments before the
 * action log writes them down ({@link ToolSpec.redactArgs}) — the log's own
 * pass matches names like `apiKey` and `token`, and this argument is called
 * `key`, which it deliberately does not match because `key` is far too common a
 * word in every other tool's arguments.
 *
 * ## Tiers
 *
 * Saving and forgetting a key change a credential, so both are `alter`.
 * Transcribing spends the person's API credit on audio somebody chose to send,
 * which is the ordinary `act` of using what they set up.
 */

import type { ToolSpec } from './catalogue'
import { BadArgument } from './catalogue'
import { optStr, str } from './agents-area-args'
import { Refused } from './surface'

export interface VoiceToolDeps {
  /** `VOICE_PROVIDERS` — who can transcribe, with their model and where keys are issued. */
  providers(): readonly unknown[]
  /** `voiceStatus` — whether a key is stored and for whom. Never the key. */
  status(): unknown
  /** `saveCheckedVoiceKey`. */
  save(provider: string, key: string): Promise<{ ok: boolean; message: string }>
  /** `clearVoiceKey`. */
  forget(): void
  /** `transcribeWithStoredKey`. */
  transcribe(audio: Uint8Array, filename: string): Promise<{ ok: boolean; text: string; message: string }>
}

/**
 * Largest recording `voice.transcribe` takes, decoded.
 *
 * The providers' own ceiling is 25 MB per file; this sits under it so a
 * recording is refused here with a sentence rather than by the provider with
 * an HTTP status, after it has been uploaded.
 */
export const MAX_AUDIO_BYTES = 20 * 1024 * 1024

export function voiceTools(deps: VoiceToolDeps): ToolSpec[] {
  return [
    {
      id: 'voice.status',
      wire: 'voice_status',
      tier: 'read',
      title: 'Read the dictation setup',
      description:
        'Whether dictation can transcribe on this computer: which providers are offered (with their model and ' +
        'where a key is issued), whether a key is stored and which provider it is for, and whether this ' +
        'computer can store one securely at all. The key itself is never returned.',
      index: 'Whether dictation has a transcription key, and which providers are offered.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Read the dictation setup',
      run: async () => ({ value: { providers: deps.providers(), status: deps.status() }, summary: {} }),
    },

    {
      id: 'voice.save_key',
      wire: 'voice_save_key',
      tier: 'alter',
      title: 'Save a transcription key',
      description:
        'Store an API key for one dictation provider. The key is tried against the provider first and stored ' +
        'only if it works — the result says which. It replaces any key already stored, is kept in the ' +
        'operating system’s secure store, and is never shown back. The person confirms it.',
      index: 'Store a transcription API key for dictation (it is checked first, never shown back).',
      inputSchema: {
        type: 'object',
        properties: {
          provider: { type: 'string', description: 'A provider id from voice.status.' },
          key: { type: 'string', description: 'The API key.' },
        },
        required: ['provider', 'key'],
        additionalProperties: false,
      },
      redactArgs: (args) => ({ ...args, key: '[redacted]' }),
      precheck: (args) => {
        str(args, 'provider')
        str(args, 'key')
      },
      // The provider and nothing else. A dialog is a screen, and screens are photographed.
      summary: (args) => `Save a ${optStr(args, 'provider') ?? '?'} transcription key`,
      run: async (args) => {
        const provider = str(args, 'provider')
        const result = await deps.save(provider, str(args, 'key'))
        if (!result.ok) throw new Refused('not-permitted', `the key was not saved: ${result.message}`)
        return { value: { saved: true, message: result.message, status: deps.status() }, summary: { provider } }
      },
    },

    {
      id: 'voice.forget_key',
      wire: 'voice_forget_key',
      tier: 'alter',
      title: 'Forget the transcription key',
      description: 'Delete the stored dictation key. The microphone button goes away until another key is saved.',
      index: 'Delete the stored dictation key.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Delete the stored transcription key',
      run: async () => {
        deps.forget()
        return { value: { forgotten: true, status: deps.status() }, summary: {} }
      },
    },

    {
      id: 'voice.transcribe',
      wire: 'voice_transcribe',
      tier: 'act',
      title: 'Transcribe a recording',
      description:
        'Turn a recording into text with the stored dictation key — the same request the microphone button ' +
        'makes. Send the audio as base64 (webm, wav, mp3, m4a or ogg), up to 20 MB. Uses the person’s API ' +
        'credit with that provider. Needs a key; voice.status says whether there is one.',
      index: 'Turn a recording (base64 audio) into text with the dictation key.',
      inputSchema: {
        type: 'object',
        properties: {
          audio: { type: 'string', description: 'The recording, base64-encoded.' },
          filename: { type: 'string', description: 'Its name with the right extension, e.g. note.m4a. Default speech.webm.' },
        },
        required: ['audio'],
        additionalProperties: false,
      },
      // A recording is somebody's voice; the log keeps that one was sent, not what it said.
      redactArgs: (args) => ({
        ...args,
        audio: typeof args['audio'] === 'string' ? `[${args['audio'].length} base64 characters]` : '[none]',
      }),
      precheck: (args) => {
        decode(str(args, 'audio'))
      },
      summary: () => 'Transcribe a recording with the dictation key',
      run: async (args) => {
        const audio = decode(str(args, 'audio'))
        const result = await deps.transcribe(audio, optStr(args, 'filename') ?? 'speech.webm')
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return { value: { text: result.text, message: result.message }, summary: { bytes: audio.length, chars: result.text.length } }
      },
    },
  ]
}

/** Base64 to bytes, refusing what is not base64 or is too big, before anything is uploaded. */
function decode(audio: string): Uint8Array {
  const compact = audio.replace(/\s+/g, '')
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(compact)) throw new BadArgument('audio must be base64')
  if (Math.floor((compact.length * 3) / 4) > MAX_AUDIO_BYTES) {
    throw new BadArgument(`audio is larger than ${MAX_AUDIO_BYTES / (1024 * 1024)} MB`)
  }
  const bytes = Buffer.from(compact, 'base64')
  if (bytes.length === 0) throw new BadArgument('audio is empty')
  return new Uint8Array(bytes)
}
