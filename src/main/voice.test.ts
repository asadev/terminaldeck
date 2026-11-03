import { describe, expect, it, vi } from 'vitest'

/*
 * `voice.ts` imports `electron` for `safeStorage`, which does not exist outside
 * a running Electron. Only the storage half needs it, and the half under test
 * here is the request half, so the module is stubbed to the smallest thing that
 * lets the import succeed. Encryption itself is not simulated: a fake keychain
 * would prove nothing about a real one.
 */
vi.mock('electron', () => ({
  safeStorage: {
    isEncryptionAvailable: () => false,
    encryptString: () => Buffer.alloc(0),
    decryptString: () => '',
  },
}))

const { VOICE_PROVIDERS, checkVoiceKey, describeFailure, readTranscript, silentWav, transcribe, voiceProvider } =
  await import('./voice')

describe('the providers', () => {
  /*
   * Each of these was read off the provider's own documentation while this was
   * written, and the endpoint is the part that must not drift into a plausible
   * guess. `whisper-large-v3` on Groq is the specific one that matters: it is
   * the same model the "can we bundle large-v3" question was about, which is
   * what makes the hosted path and the local path the same feature.
   */
  it('names a real endpoint and a real model for each', () => {
    expect(voiceProvider('groq')).toMatchObject({
      endpoint: 'https://api.groq.com/openai/v1/audio/transcriptions',
      model: 'whisper-large-v3',
      auth: 'bearer',
      modelField: 'model',
    })
    expect(voiceProvider('elevenlabs')).toMatchObject({
      endpoint: 'https://api.elevenlabs.io/v1/speech-to-text',
      model: 'scribe_v1',
      auth: 'xi-api-key',
      modelField: 'model_id',
    })
    expect(voiceProvider('openai')).toMatchObject({
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
    })
    expect(voiceProvider('nope')).toBeNull()
  })

  it('sends every request to https, since it carries a key', () => {
    for (const provider of VOICE_PROVIDERS) expect(provider.endpoint.startsWith('https://'), provider.id).toBe(true)
  })

  it('tells the user where to get a key, for every provider it offers', () => {
    // A provider row with no way to reach the thing it is asking for is the
    // "not-ready item with nothing to press" this product keeps being reviewed
    // for.
    for (const provider of VOICE_PROVIDERS) expect(provider.keysUrl, provider.id).toMatch(/^https:\/\//)
  })
})

describe('the silent WAV the key check is made of', () => {
  it('is a real WAV, not an empty file', () => {
    const wav = silentWav(200)
    expect(wav.subarray(0, 4).toString('ascii')).toBe('RIFF')
    expect(wav.subarray(8, 12).toString('ascii')).toBe('WAVE')
    expect(wav.subarray(36, 40).toString('ascii')).toBe('data')
    // 200 ms of 16-bit mono at 16 kHz is 3,200 samples of two bytes, plus the
    // 44-byte header.
    expect(wav.length).toBe(44 + 3200 * 2)
    expect(wav.readUInt32LE(4)).toBe(wav.length - 8)
    expect(wav.readUInt32LE(40)).toBe(wav.length - 44)
  })

  /*
   * The reason it is valid rather than empty. A provider handed a malformed
   * upload answers 400 whatever the key was — so a check built on garbage
   * cannot tell a bad key from a bad request, which is the exact confusion it
   * exists to remove.
   */
  it('is the whole point of checking by transcribing rather than by asking', () => {
    expect(silentWav(200).readUInt16LE(22)).toBe(1) // mono
    expect(silentWav(200).readUInt32LE(24)).toBe(16000) // 16 kHz
  })
})

describe('what the provider said', () => {
  it('blames the key only when the provider did', () => {
    expect(describeFailure(401, '{"error":{"message":"Invalid API Key"}}')).toMatch(/rejected the key/)
    expect(describeFailure(401, '{"error":{"message":"Invalid API Key"}}')).toMatch(/Invalid API Key/)
    expect(describeFailure(500, '')).toMatch(/Nothing is wrong with the key/)
    expect(describeFailure(429, '')).toMatch(/rate-limiting/)
  })

  it('quotes the provider rather than paraphrasing it', () => {
    // Three response shapes, all real: OpenAI and Groq nest under `error`,
    // ElevenLabs answers `detail`, and some gateways answer plain text.
    expect(describeFailure(400, '{"error":{"message":"file too short"}}')).toBe('file too short')
    expect(describeFailure(400, '{"detail":"invalid model_id"}')).toBe('invalid model_id')
    expect(describeFailure(400, 'no.')).toBe('no.')
  })

  it('reads a transcript out of either answer shape', () => {
    expect(readTranscript('{"text":"hello there"}')).toBe('hello there')
    expect(readTranscript('hello there')).toBe('hello there')
    expect(readTranscript('')).toBeNull()
    expect(readTranscript('{"nothing":1}')).toBeNull()
  })
})

describe('the request itself', () => {
  function capture(response: Response): { calls: Array<{ url: string; init: RequestInit }> } {
    const calls: Array<{ url: string; init: RequestInit }> = []
    vi.stubGlobal('fetch', (url: string, init: RequestInit) => {
      calls.push({ url, init })
      return Promise.resolve(response)
    })
    return { calls }
  }

  it('posts multipart to the provider’s own endpoint with its own auth header', async () => {
    const { calls } = capture(new Response('{"text":"ok"}', { status: 200 }))
    const groq = voiceProvider('groq')
    expect(groq).not.toBeNull()
    const answer = await transcribe(groq!, 'sk-test', silentWav(50), 'speech.wav')
    expect(answer).toEqual({ ok: true, text: 'ok', message: '' })
    expect(calls[0].url).toBe('https://api.groq.com/openai/v1/audio/transcriptions')
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe('Bearer sk-test')
    const body = calls[0].init.body as FormData
    expect(body.get('model')).toBe('whisper-large-v3')
    expect((body.get('file') as File).name).toBe('speech.wav')
  })

  it('uses the header ElevenLabs actually wants, not the one the others do', async () => {
    const { calls } = capture(new Response('{"text":""}', { status: 200 }))
    await transcribe(voiceProvider('elevenlabs')!, 'xi-test', silentWav(50), 'speech.wav')
    const headers = calls[0].init.headers as Record<string, string>
    expect(headers['xi-api-key']).toBe('xi-test')
    expect(headers.Authorization).toBeUndefined()
    expect((calls[0].init.body as FormData).get('model_id')).toBe('scribe_v1')
  })

  /*
   * The filename is load-bearing and it is not obvious: these APIs sniff the
   * container from the extension rather than from the content type, so a blob
   * posted with no extension is refused by two of the three. Losing it would
   * produce a feature that works in this test and fails in the app.
   */
  it('keeps the extension on the file it uploads', async () => {
    const { calls } = capture(new Response('{"text":""}', { status: 200 }))
    await transcribe(voiceProvider('groq')!, 'k', silentWav(50), 'speech.webm')
    expect((calls[0].init.body as FormData).get('file')).toBeInstanceOf(File)
    expect(((calls[0].init.body as FormData).get('file') as File).name).toBe('speech.webm')
  })

  it('separates "your key is wrong" from "the network is down"', async () => {
    capture(new Response('{"error":{"message":"Invalid API Key"}}', { status: 401 }))
    const rejected = await transcribe(voiceProvider('groq')!, 'bad', silentWav(50), 'a.wav')
    expect(rejected.ok).toBe(false)
    expect(rejected.message).toMatch(/rejected the key/)

    vi.stubGlobal('fetch', () => Promise.reject(new TypeError('fetch failed')))
    const offline = await transcribe(voiceProvider('groq')!, 'good', silentWav(50), 'a.wav')
    expect(offline.ok).toBe(false)
    expect(offline.message).toMatch(/Could not reach the provider/)
    // And it must not say the key is wrong, because it has no idea.
    expect(offline.message).not.toMatch(/key/i)
  })
})

describe('checking a key', () => {
  it('counts an empty transcript as success, because silence has no words', async () => {
    vi.stubGlobal('fetch', () => Promise.resolve(new Response('{"text":""}', { status: 200 })))
    const answer = await checkVoiceKey(voiceProvider('groq')!, 'sk-test')
    expect(answer.ok).toBe(true)
    expect(answer.message).toMatch(/accepted the key/)
    expect(answer.message).toMatch(/whisper-large-v3/)
  })

  /*
   * The gate, stated as a test. A key that does not work must not be storable,
   * because storing it is what makes the microphone appear — and his instruction
   * about the microphone was that *"it should not come there in live until it is
   * solved."*
   */
  it('fails a key the provider will not take', async () => {
    vi.stubGlobal('fetch', () => Promise.resolve(new Response('{"error":{"message":"nope"}}', { status: 401 })))
    expect((await checkVoiceKey(voiceProvider('groq')!, 'bad')).ok).toBe(false)
  })
})
