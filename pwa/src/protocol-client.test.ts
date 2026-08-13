import { describe, expect, it } from 'vitest'
import { MAX_INPUT_BYTES, PROTOCOL_VERSION } from '../../src/main/remote/protocol'
import { chunkInput, decodeLastActivity, decodeServerMessage, encode, helloMessage } from './protocol-client'

const session = {
  id: 'abc-123',
  title: 'terminaldeck',
  cwd: '/Users/asad/Projects/terminaldeck',
  provider: 'claude',
  status: 'working',
  exitCode: null,
}

function welcome(patch: Record<string, unknown> = {}): string {
  return JSON.stringify({
    t: 'welcome',
    protocol: PROTOCOL_VERSION,
    deviceId: 'dev-1',
    deviceName: 'iPhone',
    token: 'dev-1.c2VjcmV0',
    sessions: [session],
    ...patch,
  })
}

describe('decoding what the desktop sends', () => {
  it('accepts a welcome and keeps every field', () => {
    const result = decodeServerMessage(welcome())
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.message).toEqual({
      t: 'welcome',
      protocol: PROTOCOL_VERSION,
      deviceId: 'dev-1',
      deviceName: 'iPhone',
      token: 'dev-1.c2VjcmV0',
      sessions: [session],
    })
  })

  it('accepts a welcome whose token is null — that means "you already have one"', () => {
    const result = decodeServerMessage(welcome({ token: null }))
    expect(result.ok).toBe(true)
    if (result.ok && result.message.t === 'welcome') expect(result.message.token).toBeNull()
  })

  it('refuses a welcome with no token field at all', () => {
    // Absent is not the same as null, and reading it as null would leave the
    // phone believing it holds a credential it never received.
    const { token, ...rest } = JSON.parse(welcome()) as Record<string, unknown>
    expect(token).toBeDefined()
    expect(decodeServerMessage(JSON.stringify(rest)).ok).toBe(false)
  })

  it('reads output frames, including the replay flag', () => {
    const live = decodeServerMessage(JSON.stringify({ t: 'output', id: 'abc-123', data: 'hello' }))
    expect(live.ok && live.message).toEqual({ t: 'output', id: 'abc-123', data: 'hello' })

    const replay = decodeServerMessage(JSON.stringify({ t: 'output', id: 'abc-123', data: 'old', replay: true }))
    expect(replay.ok && replay.message).toEqual({ t: 'output', id: 'abc-123', data: 'old', replay: true })
  })

  it('reads status, exit, attached, detached and pong', () => {
    expect(decodeServerMessage(JSON.stringify({ t: 'status', id: 'a', status: 'waiting' })).ok).toBe(true)
    expect(decodeServerMessage(JSON.stringify({ t: 'exit', id: 'a', exitCode: 0 })).ok).toBe(true)
    expect(decodeServerMessage(JSON.stringify({ t: 'attached', id: 'a' })).ok).toBe(true)
    expect(decodeServerMessage(JSON.stringify({ t: 'detached', id: 'a' })).ok).toBe(true)
    expect(decodeServerMessage(JSON.stringify({ t: 'pong' })).ok).toBe(true)
  })

  it('reads the error codes the client has to act on differently', () => {
    for (const code of ['unauthenticated', 'unauthorized', 'version', 'unknown-session']) {
      const result = decodeServerMessage(JSON.stringify({ t: 'error', code, message: 'no' }))
      expect(result.ok, code).toBe(true)
      if (result.ok && result.message.t === 'error') expect(result.message.code).toBe(code)
    }
  })

  it('refuses an error code it has no handling for', () => {
    // Treating an unknown code as a generic failure would let a future
    // "re-pair required" arrive here as a silent retry loop.
    expect(decodeServerMessage(JSON.stringify({ t: 'error', code: 'teapot' })).ok).toBe(false)
  })

  it('survives a captive portal answering with HTML', () => {
    const portal = decodeServerMessage('<!doctype html><title>Sign in to WiFi</title>')
    expect(portal.ok).toBe(false)
    if (!portal.ok) expect(portal.reason).toBe('not JSON')
  })

  it('rejects junk without throwing', () => {
    expect(decodeServerMessage('').ok).toBe(false)
    expect(decodeServerMessage('null').ok).toBe(false)
    expect(decodeServerMessage('[1,2,3]').ok).toBe(false)
    expect(decodeServerMessage('{"t":"nope"}').ok).toBe(false)
    expect(decodeServerMessage('{"t":"output","id":"a"}').ok).toBe(false)
    expect(decodeServerMessage('{"t":"sessions"}').ok).toBe(false)
  })

  it('drops a malformed session row rather than the whole list', () => {
    const result = decodeServerMessage(
      JSON.stringify({ t: 'sessions', sessions: [session, { id: 'x' }, { ...session, id: 'ok-2' }] }),
    )
    expect(result.ok).toBe(true)
    if (result.ok && result.message.t === 'sessions') {
      expect(result.message.sessions.map((entry) => entry.id)).toEqual(['abc-123', 'ok-2'])
    }
  })

  it('keeps an exit code of zero, which is the one that matters most', () => {
    const result = decodeServerMessage(JSON.stringify({ t: 'sessions', sessions: [{ ...session, exitCode: 0 }] }))
    if (result.ok && result.message.t === 'sessions') expect(result.message.sessions[0].exitCode).toBe(0)
  })
})

describe('last activity', () => {
  it('reads the field when the desktop sends one', () => {
    expect(decodeLastActivity({ ...session, lastActivityAt: 1_700_000_000_000 })).toBe(1_700_000_000_000)
  })

  it('answers null rather than a plausible-looking time when it does not', () => {
    expect(decodeLastActivity(session)).toBeNull()
    expect(decodeLastActivity({ lastActivityAt: 'yesterday' })).toBeNull()
    expect(decodeLastActivity({ lastActivityAt: 0 })).toBeNull()
    expect(decodeLastActivity(null)).toBeNull()
  })
})

describe('what the client sends', () => {
  it('greets with the protocol version it was compiled against', () => {
    const hello = helloMessage('tok', { name: 'iPhone', platform: 'iOS' })
    expect(hello).toEqual({
      t: 'hello',
      protocol: PROTOCOL_VERSION,
      token: 'tok',
      device: { name: 'iPhone', platform: 'iOS' },
    })
    expect(JSON.parse(encode(hello))).toEqual(hello)
  })

  it('leaves a normal keystroke as one frame', () => {
    expect(chunkInput('c')).toEqual(['c'])
    expect(chunkInput('')).toEqual([])
  })

  it('splits a paste the server would otherwise refuse', () => {
    // An oversized input frame is answered by closing the socket, so a long
    // paste has to be cut here or it looks like the network dropping.
    const paste = 'x'.repeat(MAX_INPUT_BYTES * 2 + 5)
    const chunks = chunkInput(paste)
    expect(chunks.length).toBe(3)
    expect(chunks.join('')).toBe(paste)
    for (const chunk of chunks) expect(new TextEncoder().encode(chunk).byteLength).toBeLessThanOrEqual(MAX_INPUT_BYTES)
  })

  it('counts bytes, not characters, and never splits a surrogate pair', () => {
    const emoji = '🙂'.repeat(40)
    const chunks = chunkInput(emoji, 16)
    expect(chunks.join('')).toBe(emoji)
    const encoder = new TextEncoder()
    const decoder = new TextDecoder()
    for (const chunk of chunks) {
      expect(encoder.encode(chunk).byteLength).toBeLessThanOrEqual(16)
      // A half of a surrogate pair does not survive a UTF-8 round trip — it
      // comes back as U+FFFD — so this is the assertion that a chunk boundary
      // never landed in the middle of one.
      expect(decoder.decode(encoder.encode(chunk))).toBe(chunk)
    }
  })
})
