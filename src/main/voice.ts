/**
 * Dictation that actually transcribes: the key, and the request it is for.
 *
 * ## Why this exists at all, and what was checked before a line of it was written
 *
 * The microphone in the chat box has never recorded anything. It focuses the
 * composer and points at the operating system's own dictation, for the reasons
 * measured in `renderer/chat/voice/dictation.ts`. Asad's instruction was to stop
 * shipping that shape:
 *
 *   > *"Opening the microphone should ask for a key for an online transcription
 *   > model… Do not ship it live until it works."*
 *
 * and, separately, about running the model locally instead:
 *
 *   > *"Let's bring a proper V3 thing properly set up in here… we can give a
 *   > button to download, so after installing they can just download and it will
 *   > be patched here — if it is allowed legally from the V3 to using the tools.
 *   > If not, then no need this feature, with that only key can be here."*
 *
 * ## The licence question, answered
 *
 * It is clean, and nothing legal stands in the way of the download button:
 *
 *  - OpenAI's Whisper repository ships under the **MIT** licence, © OpenAI 2022
 *    (`https://github.com/openai/whisper/blob/main/LICENSE`).
 *  - The `openai/whisper-large-v3` weights on Hugging Face are published under
 *    **Apache-2.0**. The card's cautions about high-risk domains are guidance,
 *    not licence terms.
 *  - `ggerganov/whisper.cpp`, which is where a desktop app would actually get
 *    runnable weights, publishes its GGML conversions under the **MIT** licence.
 *
 * All three permit commercial use and redistribution, with attribution. So the
 * blocker on shipping a "download large-v3" button turned out not to be legal at
 * all: it is that this app has no local inference runtime to hand the weights
 * to. Downloading three gigabytes into an application that cannot run them is
 * the exact shape of dead control this codebase keeps being audited for, so the
 * button is not shipped today, the finding is recorded here so nobody has to
 * establish it twice, and what ships is the half he asked for unconditionally:
 * a key, and a microphone that does not appear until the key works.
 *
 * ## Why the same model is still reachable
 *
 * Groq serves **whisper large-v3 itself** over HTTP, so "the V3 thing" is what
 * gets used either way — hosted today, local if a runtime is ever added. That is
 * why it is the first provider in the list rather than the most familiar one.
 *
 * ## Why the key is checked by transcribing rather than by asking
 *
 * Every provider has some account endpoint that would answer 200 for a valid
 * key, and checking that would prove only that the key is a key. What has to be
 * true before a microphone appears is the whole path: this app's network reach,
 * the provider's auth, the multipart upload, the model id, and the response
 * shape. So the check posts a **real, valid, silent WAV** to the real
 * transcription endpoint and requires a real answer. It costs a fraction of a
 * second of audio and it cannot pass while anything in the chain is broken.
 */

import { safeStorage, type IpcMain } from 'electron'
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/* -------------------------------------------------------------------------- */
/* Providers                                                                   */
/* -------------------------------------------------------------------------- */

export interface VoiceProvider {
  id: string
  /** What a person calls it. */
  label: string
  /** The model that actually does the work, named so the choice is informed. */
  model: string
  /** One line on when to pick this one. Facts, not marketing. */
  note: string
  endpoint: string
  /** How the key is presented. Two shapes exist and both are in use below. */
  auth: 'bearer' | 'xi-api-key'
  /** The multipart field naming the model, which is not spelled the same way twice. */
  modelField: string
  /** Where the key is issued, so the settings row can say where to go. */
  keysUrl: string
}

/**
 * The three that were checked, with the endpoint and model id each one
 * documents.
 *
 * Groq is first on purpose. It runs `whisper-large-v3` — the same weights the
 * download question was about — so choosing it makes the local option a
 * performance decision later rather than a different feature.
 *
 * ElevenLabs is here because of a finding that already cost time once: Whisper
 * drops Urdu badly, and Scribe does not. Asad speaks Urdu, and a transcription
 * feature that silently mangles half of what he says is not a feature.
 */
export const VOICE_PROVIDERS: readonly VoiceProvider[] = [
  {
    id: 'groq',
    label: 'Groq',
    model: 'whisper-large-v3',
    note: 'Whisper large-v3 itself, hosted. Fast, and free at low volume.',
    endpoint: 'https://api.groq.com/openai/v1/audio/transcriptions',
    auth: 'bearer',
    modelField: 'model',
    keysUrl: 'https://console.groq.com/keys',
  },
  {
    id: 'elevenlabs',
    label: 'ElevenLabs Scribe',
    model: 'scribe_v1',
    note: 'Strongest on languages Whisper handles badly, including Urdu.',
    endpoint: 'https://api.elevenlabs.io/v1/speech-to-text',
    auth: 'xi-api-key',
    modelField: 'model_id',
    keysUrl: 'https://elevenlabs.io/app/settings/api-keys',
  },
  {
    id: 'openai',
    label: 'OpenAI',
    model: 'whisper-1',
    note: 'The hosted Whisper. Note it is large-v2, not v3.',
    endpoint: 'https://api.openai.com/v1/audio/transcriptions',
    auth: 'bearer',
    modelField: 'model',
    keysUrl: 'https://platform.openai.com/api-keys',
  },
]

export function voiceProvider(id: string): VoiceProvider | null {
  return VOICE_PROVIDERS.find((entry) => entry.id === id) ?? null
}

/* -------------------------------------------------------------------------- */
/* Where the key lives                                                         */
/* -------------------------------------------------------------------------- */

export interface StoredVoiceKey {
  provider: string
  key: string
}

/**
 * Encrypted, or not stored at all.
 *
 * `safeStorage` is the right tool here in a way it is not elsewhere in this
 * repo: this is a secret **this application owns**, typed into this app's own
 * settings, sent by this app's own code. (Contrast `platform/credential-store.ts`,
 * which explains at length why encrypting an agent CLI's credentials would be
 * theatre — the app never holds them.)
 *
 * Where encryption is unavailable — a Linux box with no keyring is the usual
 * case — this refuses to store rather than falling back to a plain file. An API
 * key sitting in cleartext in a user-data directory is a real cost to a real
 * person, and "we saved it anyway" is not a decision to make on their behalf and
 * certainly not one to make silently.
 */
export function voiceKeyPath(userData: string): string {
  return join(userData, 'voice-key.bin')
}

export function saveVoiceKey(userData: string, entry: StoredVoiceKey): { ok: boolean; message: string } {
  if (!safeStorage.isEncryptionAvailable()) {
    return {
      ok: false,
      message:
        'This machine has no secure store available, so the key was not saved. On Linux that usually means no keyring is running; start one and try again.',
    }
  }
  const path = voiceKeyPath(userData)
  mkdirSync(dirname(path), { recursive: true })
  const blob = safeStorage.encryptString(JSON.stringify(entry))
  // Written through a temporary file for the same reason `settings-extra.ts`
  // does it: a half-written key file is indistinguishable from a corrupt one,
  // and the failure lands on the next launch rather than on this one.
  const temporary = `${path}.tmp`
  writeFileSync(temporary, blob)
  renameSync(temporary, path)
  return { ok: true, message: 'Saved.' }
}

export function readVoiceKey(userData: string): StoredVoiceKey | null {
  const path = voiceKeyPath(userData)
  if (!existsSync(path)) return null
  try {
    const parsed: unknown = JSON.parse(safeStorage.decryptString(readFileSync(path)))
    if (typeof parsed !== 'object' || parsed === null) return null
    const entry = parsed as Record<string, unknown>
    if (typeof entry.provider !== 'string' || typeof entry.key !== 'string' || entry.key === '') return null
    return { provider: entry.provider, key: entry.key }
  } catch {
    // A key encrypted by a different OS user, a different machine, or an older
    // format. Unreadable is the same as absent from here: the settings row asks
    // for it again, which is the only thing anybody could do about it anyway.
    return null
  }
}

export function clearVoiceKey(userData: string): void {
  const path = voiceKeyPath(userData)
  if (existsSync(path)) unlinkSync(path)
}

/* -------------------------------------------------------------------------- */
/* The request                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * A valid WAV containing `ms` milliseconds of silence.
 *
 * Built rather than bundled so there is no asset to lose, and *valid* rather
 * than empty because the point of the check is to exercise the whole path. A
 * provider handed a malformed upload answers 400 whatever the key was, which
 * would make a broken key and a broken request look identical — the confusion
 * this check exists to prevent.
 *
 * 16-bit mono at 16 kHz, which is what every speech model resamples to anyway,
 * so 200 ms costs 6,444 bytes.
 */
export function silentWav(ms: number): Buffer {
  const rate = 16000
  const samples = Math.max(1, Math.round((rate * ms) / 1000))
  const data = samples * 2
  const buffer = Buffer.alloc(44 + data)
  buffer.write('RIFF', 0, 'ascii')
  buffer.writeUInt32LE(36 + data, 4)
  buffer.write('WAVE', 8, 'ascii')
  buffer.write('fmt ', 12, 'ascii')
  buffer.writeUInt32LE(16, 16) // PCM header length
  buffer.writeUInt16LE(1, 20) // PCM
  buffer.writeUInt16LE(1, 22) // mono
  buffer.writeUInt32LE(rate, 24)
  buffer.writeUInt32LE(rate * 2, 28) // byte rate
  buffer.writeUInt16LE(2, 32) // block align
  buffer.writeUInt16LE(16, 34) // bits per sample
  buffer.write('data', 36, 'ascii')
  buffer.writeUInt32LE(data, 40)
  return buffer
}

export interface TranscriptionResult {
  ok: boolean
  /** What was heard. Empty on failure, and empty is legitimate on success too. */
  text: string
  /** Shown to a person verbatim, so it says what to do rather than what broke. */
  message: string
}

/**
 * How long a transcription may take before it is abandoned.
 *
 * A minute of speech through a hosted Whisper is a second or two; twenty is
 * generous for a bad connection and short enough that a stuck request does not
 * leave a microphone spinning with no way out.
 */
const REQUEST_TIMEOUT_MS = 20_000

/**
 * Turn what the provider said into a sentence worth showing.
 *
 * The status code carries most of it, and the distinction that matters to a
 * person is *whose problem it is*: 401 and 403 mean the key, 429 means waiting,
 * 4xx otherwise means the request, 5xx means them. Anything the provider
 * bothered to write in the body is quoted rather than paraphrased, because the
 * real message is nearly always more specific than the generic one.
 */
export function describeFailure(status: number, body: string): string {
  const detail = ((): string => {
    try {
      const parsed: unknown = JSON.parse(body)
      if (typeof parsed === 'object' && parsed !== null) {
        const error = (parsed as { error?: unknown }).error
        if (typeof error === 'string') return error
        if (typeof error === 'object' && error !== null) {
          const message = (error as { message?: unknown }).message
          if (typeof message === 'string') return message
        }
        const message = (parsed as { message?: unknown }).message
        if (typeof message === 'string') return message
        const rawDetail = (parsed as { detail?: unknown }).detail
        if (typeof rawDetail === 'string') return rawDetail
      }
    } catch {
      // Not JSON. The trimmed body is still better than nothing, and providers
      // do sometimes answer with plain text.
    }
    return body.trim().slice(0, 300)
  })()

  if (status === 401 || status === 403) {
    return `The provider rejected the key${detail ? ` — ${detail}` : '.'}`
  }
  if (status === 429) {
    return `The provider is rate-limiting this key${detail ? ` — ${detail}` : '.'} Wait a moment and try again.`
  }
  if (status >= 500) {
    return `The provider had a problem of its own (${status})${detail ? ` — ${detail}` : '.'} Nothing is wrong with the key.`
  }
  return detail !== '' ? detail : `The provider answered ${status} and said nothing else.`
}

/** The text out of a response body, whichever of the two shapes it is in. */
export function readTranscript(body: string): string | null {
  try {
    const parsed: unknown = JSON.parse(body)
    if (typeof parsed === 'object' && parsed !== null) {
      const text = (parsed as { text?: unknown }).text
      if (typeof text === 'string') return text
    }
  } catch {
    // `response_format=text` answers with the bare transcript, which is a
    // perfectly good answer and simply is not JSON.
    return body.trim() === '' ? null : body.trim()
  }
  return null
}

/**
 * Send audio to the provider and come back with what it heard.
 *
 * `audio` is whatever the renderer's `MediaRecorder` produced — WebM/Opus on
 * this Chromium — and every provider in the list above accepts it. The filename
 * matters: these APIs sniff the container from the extension rather than from
 * the content type, so a blob posted as `audio` with no extension is refused by
 * two of the three.
 */
export async function transcribe(
  provider: VoiceProvider,
  key: string,
  audio: Uint8Array,
  filename: string,
): Promise<TranscriptionResult> {
  const form = new FormData()
  // `Blob` and `FormData` are Node's own (undici) here, not the DOM's — the
  // main tsconfig has no DOM lib. Node's `Blob` accepts a `Buffer` directly, and
  // wrapping rather than copying keeps a minute of audio out of a second
  // allocation on its way to the socket.
  form.append('file', new Blob([Buffer.from(audio.buffer, audio.byteOffset, audio.byteLength)]), filename)
  form.append(provider.modelField, provider.model)

  const headers: Record<string, string> =
    provider.auth === 'bearer' ? { Authorization: `Bearer ${key}` } : { 'xi-api-key': key }

  try {
    const response = await fetch(provider.endpoint, {
      method: 'POST',
      headers,
      body: form,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
    const body = await response.text()
    if (!response.ok) return { ok: false, text: '', message: describeFailure(response.status, body) }
    const text = readTranscript(body)
    if (text === null) {
      return { ok: false, text: '', message: 'The provider answered, but not with a transcript this build understands.' }
    }
    return { ok: true, text, message: '' }
  } catch (error) {
    /*
     * A thrown fetch is a network fact, not a provider fact, and saying so is
     * the difference between "check your key" and "check your connection".
     * `AbortSignal.timeout` throws a `TimeoutError`, which is worth naming
     * separately: it is the one failure where trying again is likely to work.
     */
    const name = error instanceof Error ? error.name : ''
    if (name === 'TimeoutError') {
      return { ok: false, text: '', message: 'The provider did not answer within twenty seconds. Try again.' }
    }
    const reason = error instanceof Error ? error.message : String(error)
    return { ok: false, text: '', message: `Could not reach the provider — ${reason}` }
  }
}

/**
 * Prove the key works, by using it for exactly what it is for.
 *
 * An empty transcript is the *expected* success: two hundred milliseconds of
 * silence has nothing in it. What is being asserted is that the request was
 * accepted, so the result is reported on `ok` rather than on the text.
 */
export async function checkVoiceKey(provider: VoiceProvider, key: string): Promise<TranscriptionResult> {
  const answer = await transcribe(provider, key, silentWav(200), 'check.wav')
  if (!answer.ok) return answer
  return {
    ok: true,
    text: '',
    message: `${provider.label} accepted the key and answered with ${provider.model}.`,
  }
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

export interface VoiceStatus {
  /** Which provider the stored key is for, or null when there is no key. */
  provider: string | null
  /** True when a key is stored and this machine can decrypt it. */
  hasKey: boolean
  /** False where nothing can be stored at all, with `reason` saying why. */
  canStore: boolean
  reason: string | null
}

export function voiceStatus(userData: string): VoiceStatus {
  const canStore = safeStorage.isEncryptionAvailable()
  const stored = canStore ? readVoiceKey(userData) : null
  return {
    provider: stored?.provider ?? null,
    hasKey: stored !== null,
    canStore,
    reason: canStore
      ? null
      : 'This machine has no secure store, so a key cannot be kept here. On Linux, start a keyring and reopen the app.',
  }
}

/**
 * Every channel this feature needs, and no channel that hands the key back.
 *
 * `voice:status` reports *whether* there is a key and which provider it is for.
 * There is deliberately no reader for the key itself: the renderer never needs
 * it — it sends audio and receives text — and a bridge method that returns a
 * secret to a window running other people's web content is a hole that exists
 * for no reason.
 */
export function registerVoiceIpc(ipcMain: IpcMain, userData: () => string): void {
  ipcMain.handle('voice:providers', () => VOICE_PROVIDERS)
  ipcMain.handle('voice:status', () => voiceStatus(userData()))

  ipcMain.handle('voice:save', async (_event, request: { provider?: string; key?: string }) => {
    const provider = voiceProvider(String(request?.provider ?? ''))
    const key = String(request?.key ?? '').trim()
    if (!provider) return { ok: false, message: 'Pick a provider first.' }
    if (key === '') return { ok: false, message: 'Paste a key first.' }

    // Checked *before* it is stored, so a key that does not work never becomes
    // the thing that makes the microphone appear. That ordering is the whole
    // gate: "it should not come there in live until it is solved."
    const check = await checkVoiceKey(provider, key)
    if (!check.ok) return { ok: false, message: check.message }

    const saved = saveVoiceKey(userData(), { provider: provider.id, key })
    return saved.ok ? { ok: true, message: check.message } : saved
  })

  ipcMain.handle('voice:forget', () => {
    clearVoiceKey(userData())
    return { ok: true, message: 'Key removed. The microphone goes with it.' }
  })

  ipcMain.handle('voice:transcribe', async (_event, request: { audio?: unknown; filename?: unknown }) => {
    const stored = readVoiceKey(userData())
    if (!stored) return { ok: false, text: '', message: 'No transcription key is set.' }
    const provider = voiceProvider(stored.provider)
    if (!provider) return { ok: false, text: '', message: 'The stored key is for a provider this build does not have.' }
    const audio = request?.audio
    if (!(audio instanceof Uint8Array) && !ArrayBuffer.isView(audio) && !(audio instanceof ArrayBuffer)) {
      return { ok: false, text: '', message: 'No audio arrived.' }
    }
    const bytes = audio instanceof ArrayBuffer ? new Uint8Array(audio) : new Uint8Array((audio as ArrayBufferView).buffer)
    const filename = typeof request?.filename === 'string' && request.filename !== '' ? request.filename : 'speech.webm'
    return transcribe(provider, stored.key, bytes, filename)
  })
}
