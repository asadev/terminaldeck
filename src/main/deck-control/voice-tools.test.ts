import { describe, expect, it, vi } from 'vitest'
import { fakeContext, tool } from './agents-area.fixture'
import { MAX_AUDIO_BYTES, voiceTools, type VoiceToolDeps } from './voice-tools'

function deps(overrides: Partial<VoiceToolDeps> = {}): VoiceToolDeps {
  return {
    providers: () => [{ id: 'groq', label: 'Groq' }],
    status: () => ({ provider: 'groq', hasKey: true, canStore: true, reason: null }),
    save: async () => ({ ok: true, message: 'That key works.' }),
    forget: () => undefined,
    transcribe: async () => ({ ok: true, text: 'hello there', message: '' }),
    ...overrides,
  }
}

describe('the dictation key', () => {
  it('takes the key, and keeps it out of the log and out of the dialog', async () => {
    const save = vi.fn<VoiceToolDeps['save']>(deps().save)
    const { context } = fakeContext()
    const spec = tool(voiceTools(deps({ save })), 'voice.save_key')
    const args = { provider: 'groq', key: 'gsk_live_secret_value' }
    const out = await spec.run(args, context)
    expect(save).toHaveBeenCalledWith('groq', 'gsk_live_secret_value')
    expect(JSON.stringify(out.value)).not.toContain('gsk_live')
    expect(JSON.stringify(spec.redactArgs?.(args))).not.toContain('gsk_live')
    expect(spec.summary(args, context)).toBe('Save a groq transcription key')
  })

  it('reports a key the provider rejected as not saved', async () => {
    const { context } = fakeContext()
    const spec = tool(voiceTools(deps({ save: async () => ({ ok: false, message: 'Groq said the key is invalid.' }) })), 'voice.save_key')
    await expect(spec.run({ provider: 'groq', key: 'x' }, context)).rejects.toThrow(/not saved: Groq said/)
  })
})

describe('transcribing', () => {
  it('decodes base64 audio and hands the bytes over', async () => {
    const transcribe = vi.fn<VoiceToolDeps['transcribe']>(deps().transcribe)
    const { context } = fakeContext()
    const audio = Buffer.from('RIFF....WAVE').toString('base64')
    const out = await tool(voiceTools(deps({ transcribe })), 'voice.transcribe').run({ audio, filename: 'n.wav' }, context)
    expect(Buffer.from(transcribe.mock.calls[0][0]).toString()).toBe('RIFF....WAVE')
    expect(transcribe.mock.calls[0][1]).toBe('n.wav')
    expect(out.value).toEqual({ text: 'hello there', message: '' })
  })

  it('refuses what is not base64, or is too large, before anything is uploaded', () => {
    const { context } = fakeContext()
    const spec = tool(voiceTools(deps()), 'voice.transcribe')
    expect(() => spec.precheck?.({ audio: 'not base64!' }, context)).toThrow(/must be base64/)
    const big = 'A'.repeat(Math.ceil((MAX_AUDIO_BYTES * 4) / 3) + 8)
    expect(() => spec.precheck?.({ audio: big }, context)).toThrow(/larger than/)
  })

  it('logs that a recording was sent, never the recording', () => {
    const spec = tool(voiceTools(deps()), 'voice.transcribe')
    expect(spec.redactArgs?.({ audio: 'QUJD' })).toEqual({ audio: '[4 base64 characters]' })
  })
})
