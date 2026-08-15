import { describe, expect, it } from 'vitest'
import {
  MAX_INPUT_BYTES,
  MAX_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  parseServerMessage,
} from '../../src/main/remote/protocol'
import {
  CLAIMED_CAPABILITIES,
  chunkInput,
  decodeLastActivity,
  decodeServerMessage,
  encode,
  helloMessage,
} from './protocol-client'

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
      // Absent from the frame above, and read as "protocol v1 only" rather than
      // as unknown — which is what every desktop older than the capability
      // field is in fact telling us.
      capabilities: [],
    })
  })

  it('reads the capabilities a newer desktop advertises, and ignores nonsense in the list', () => {
    const result = decodeServerMessage(welcome({ capabilities: ['localhost', '', 42, null, 'x'.repeat(64)] }))
    expect(result.ok).toBe(true)
    if (result.ok && result.message.t === 'welcome') {
      expect(result.message.capabilities).toEqual(['localhost'])
    }
  })

  it('does not fail a welcome whose capabilities are the wrong shape entirely', () => {
    // A field this client has only just learned about must not be able to cost
    // it the connection: an older or stranger desktop that sends a string here
    // is still a desktop whose sessions are worth listing.
    for (const capabilities of ['localhost', 7, null, {}]) {
      const result = decodeServerMessage(welcome({ capabilities }))
      expect(result.ok, JSON.stringify(capabilities)).toBe(true)
      if (result.ok && result.message.t === 'welcome') expect(result.message.capabilities).toEqual([])
    }
  })

  it('carries the desktop’s platform through raw, and leaves the field off when it is absent', () => {
    // Raw rather than mapped: the noun is presentation and belongs to the
    // screens. What the decoder must not do is *invent* one — the field being
    // missing has to stay visible as missing, because "this desktop predates
    // the field" is the case that produced "Running on the Mac" on a PC.
    const said = decodeServerMessage(welcome({ hostPlatform: 'win32' }))
    expect(said.ok && said.message.t === 'welcome' && said.message.hostPlatform).toBe('win32')

    const silent = decodeServerMessage(welcome())
    expect(silent.ok && silent.message.t === 'welcome' && 'hostPlatform' in silent.message).toBe(false)
  })

  it('does not fail a welcome whose platform is the wrong shape', () => {
    // Same rule as `capabilities`: a field this client has only just learned
    // about must never be able to cost it the connection.
    for (const hostPlatform of [7, null, {}, []]) {
      const result = decodeServerMessage(welcome({ hostPlatform }))
      expect(result.ok, JSON.stringify(hostPlatform)).toBe(true)
      if (result.ok && result.message.t === 'welcome') expect(result.message.hostPlatform).toBeUndefined()
    }
  })

  it('reads the folders this device was granted, and keeps an empty list empty', () => {
    // Empty is a person having chosen no folders for this device, and it has a
    // remedy printed next to it on screen. It is not the same fact as a desktop
    // that never mentioned folders — see the next test — and a decoder that
    // reported one as the other would either invent a lock-out or hide one.
    const granted = decodeServerMessage(welcome({ folders: ['/Users/asad/Projects/api'] }))
    expect(granted.ok && granted.message.t === 'welcome' && granted.message.folders).toEqual([
      '/Users/asad/Projects/api',
    ])

    const none = decodeServerMessage(welcome({ folders: [] }))
    expect(none.ok && none.message.t === 'welcome' && none.message.folders).toEqual([])
  })

  it('leaves the field off entirely when the desktop is older than it', () => {
    const silent = decodeServerMessage(welcome())
    expect(silent.ok && silent.message.t === 'welcome' && 'folders' in silent.message).toBe(false)
  })

  it('does not fail a welcome whose folders are the wrong shape, and drops the rows that are', () => {
    // Same rule as `capabilities` and `hostPlatform`: a field this client has
    // only just learned about must never be able to cost it the connection.
    for (const folders of ['/one', 7, null, {}]) {
      const result = decodeServerMessage(welcome({ folders }))
      expect(result.ok, JSON.stringify(folders)).toBe(true)
      if (result.ok && result.message.t === 'welcome') expect(result.message.folders).toBeUndefined()
    }

    const mixed = decodeServerMessage(welcome({ folders: ['/one', 4, '', null, '/two'] }))
    expect(mixed.ok && mixed.message.t === 'welcome' && mixed.message.folders).toEqual(['/one', '/two'])
  })

  it('reads the folder list the desktop pushes when somebody edits it', () => {
    const pushed = decodeServerMessage(JSON.stringify({ t: 'folders', folders: ['/one'] }))
    expect(pushed.ok && pushed.message).toEqual({ t: 'folders', folders: ['/one'] })

    // The frame that takes the last folder away. It has to survive decoding as
    // an empty list rather than as nothing, because it is the moment a picker
    // must stop offering anything.
    const emptied = decodeServerMessage(JSON.stringify({ t: 'folders', folders: [] }))
    expect(emptied.ok && emptied.message).toEqual({ t: 'folders', folders: [] })
  })

  it('refuses a folders frame with no list in it', () => {
    // Unlike the optional field in `welcome`, this frame is nothing else. A
    // client that read a malformed one as "no folders" would take the picker
    // away on the strength of a bad message.
    expect(decodeServerMessage(JSON.stringify({ t: 'folders' })).ok).toBe(false)
    expect(decodeServerMessage(JSON.stringify({ t: 'folders', folders: '/one' })).ok).toBe(false)
  })

  it('reads the created session the desktop answers a request with', () => {
    const result = decodeServerMessage(JSON.stringify({ t: 'created', session }))
    expect(result.ok && result.message).toEqual({ t: 'created', session })
  })

  it('refuses a created frame with no usable session in it', () => {
    // This frame *is* the session, so half of one is not usable: the id in it
    // is what this client is about to attach to.
    expect(decodeServerMessage(JSON.stringify({ t: 'created' })).ok).toBe(false)
    expect(decodeServerMessage(JSON.stringify({ t: 'created', session: { id: 'x' } })).ok).toBe(false)
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

describe('one parser, not two', () => {
  // This client used to carry its own decoder for the same frames the desktop
  // decodes in `parseServerMessage`, and two readers of one wire drift silently:
  // the phone keeps compiling, keeps connecting, and quietly stops understanding
  // a frame somebody added on the other side. There is one implementation now,
  // and this is the test that fails if a second one ever grows back here.
  const frames = [
    welcome(),
    welcome({ token: null }),
    welcome({ folders: ['/one'], hostPlatform: 'win32', capabilities: ['localhost'] }),
    JSON.stringify({ t: 'sessions', sessions: [session] }),
    JSON.stringify({ t: 'created', session }),
    JSON.stringify({ t: 'folders', folders: ['/one'] }),
    JSON.stringify({ t: 'output', id: 'abc-123', data: 'hi', replay: true }),
    JSON.stringify({ t: 'status', id: 'a', status: 'waiting' }),
    JSON.stringify({ t: 'exit', id: 'a', exitCode: 0 }),
    JSON.stringify({ t: 'attached', id: 'a' }),
    JSON.stringify({ t: 'detached', id: 'a' }),
    JSON.stringify({ t: 'error', code: 'unauthorized', message: 'no' }),
    JSON.stringify({ t: 'pong' }),
    '{"t":"nope"}',
    'not json at all',
  ]

  it('answers exactly what the desktop’s own parser answers', () => {
    for (const frame of frames) {
      const mine = decodeServerMessage(frame)
      const theirs = parseServerMessage(frame)
      expect(mine.ok, frame).toBe(theirs.ok)
      if (mine.ok && theirs.ok) expect(mine.message, frame).toEqual(theirs.message)
    }
  })

  it('refuses a frame past the message cap, the way every other reader of this wire does', () => {
    // The old copy had no size check at all: it would happily `JSON.parse` a
    // megabyte handed to it by whatever answered the socket. The shared parser
    // caps it, and inheriting that cap is most of the point of sharing.
    const huge = JSON.stringify({ t: 'output', id: 'abc-123', data: 'x'.repeat(MAX_MESSAGE_BYTES) })
    const result = decodeServerMessage(huge)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toBe('larger than the message cap')
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

  it('carries the times beside a session list, keyed by session id', () => {
    // Beside rather than inside, because `RemoteSession` has no such field and
    // inventing one would put a time on screen for every session whether or not
    // a desktop ever said anything about it.
    const at = 1_700_000_000_000
    const result = decodeServerMessage(
      JSON.stringify({ t: 'sessions', sessions: [{ ...session, lastActivityAt: at }] }),
    )
    expect(result.ok && result.activity?.get(session.id)).toBe(at)
  })

  it('carries them out of a welcome as well', () => {
    const at = 1_700_000_000_000
    const result = decodeServerMessage(welcome({ sessions: [{ ...session, lastActivityAt: at }] }))
    expect(result.ok && result.activity?.get(session.id)).toBe(at)
  })

  it('says nothing at all when no row carried a time', () => {
    // Undefined rather than an empty map: the caller merges what it gets into a
    // map it keeps, and "the desktop never mentioned it" must not read as a
    // list of zero facts that were mentioned.
    const result = decodeServerMessage(welcome())
    expect(result.ok && result.activity).toBeUndefined()
  })

  it('does not key a time to a row the parser threw away', () => {
    // The caller stores this map for the life of the tab. A timestamp for a
    // session that never made it into the list is a leak with a session id on
    // it, and it would never be cleared, because nothing on screen owns it.
    const result = decodeServerMessage(
      JSON.stringify({ t: 'sessions', sessions: [{ id: 'half-a-row', lastActivityAt: 1_700_000_000_000 }] }),
    )
    expect(result.ok && result.message.t === 'sessions' && result.message.sessions).toEqual([])
    expect(result.ok && result.activity).toBeUndefined()
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
      capabilities: CLAIMED_CAPABILITIES,
    })
    expect(JSON.parse(encode(hello))).toEqual(hello)
  })

  it('claims `credential`, and claims nothing it merely wants to ask for', () => {
    // Load bearing rather than informational: a desktop that does not see
    // `credential` here never sends `credential.request`, so a push from a
    // folder this browser was granted fails with "your device isn't reachable"
    // about a tab that is open and connected. `create`, `localhost` and `upload`
    // are things this client asks *for* and are gated on what the desktop
    // advertised, so claiming them would say nothing.
    expect(CLAIMED_CAPABILITIES).toEqual(['credential'])
  })
})

describe('the one frame the shared parser deliberately does not read', () => {
  // `parseServerMessage` exists for a desktop acting as another desktop's guest,
  // and that guest speaks v1 only — it advertises no capability, so it can never
  // be sent a frame that needs one. This client does advertise `credential`, so
  // `credential.request` is a frame it has agreed to receive. One branch, for
  // one frame; everything else still goes to the shared parser.
  const frame = (over: Record<string, unknown> = {}) =>
    JSON.stringify({
      t: 'credential.request',
      id: 'req-1',
      host: 'github.com',
      repo: 'asadev/terminaldeck',
      operation: 'write',
      prompt: true,
      ...over,
    })

  it('reads a request the shared parser refuses outright', () => {
    expect(parseServerMessage(frame()).ok).toBe(false)
    const result = decodeServerMessage(frame())
    expect(result).toEqual({
      ok: true,
      message: {
        t: 'credential.request',
        id: 'req-1',
        host: 'github.com',
        repo: 'asadev/terminaldeck',
        operation: 'write',
        prompt: true,
      },
    })
  })

  it('passes a repository the desktop could not name through as null', () => {
    const result = decodeServerMessage(frame({ repo: null }))
    expect(result.ok && result.message.t === 'credential.request' && result.message.repo).toBeNull()
  })

  it('reads an over-long repository as null rather than losing the frame', () => {
    // Same answer this client already has to draw, and the notice says so. A
    // refusal would lose a push over a long string.
    const result = decodeServerMessage(frame({ repo: 'a'.repeat(400) }))
    expect(result.ok && result.message.t === 'credential.request' && result.message.repo).toBeNull()
  })

  it('refuses one with no id, because there is nothing to answer', () => {
    expect(decodeServerMessage(frame({ id: '' }))).toEqual({ ok: false, reason: 'incomplete credential.request' })
  })

  it('refuses a host longer than the wire allows', () => {
    expect(decodeServerMessage(frame({ host: 'h'.repeat(300) })).ok).toBe(false)
  })

  it('treats anything but a literal true as “do not interrupt a person”', () => {
    for (const prompt of [undefined, 'yes', 1, null]) {
      const result = decodeServerMessage(frame({ prompt }))
      expect(result.ok && result.message.t === 'credential.request' && result.message.prompt).toBe(false)
    }
  })

  it('falls to write for an operation it does not recognise', () => {
    // The desktop's own failure direction: prompting for a fetch costs one tap
    // nobody needed, and saying "read" about a push is the feature not working.
    const result = decodeServerMessage(frame({ operation: 'sideways' }))
    expect(result.ok && result.message.t === 'credential.request' && result.message.operation).toBe('write')
  })

  it('never parses a frame past the message cap, whatever its type', () => {
    const huge = JSON.stringify({ t: 'credential.request', id: 'x'.repeat(MAX_MESSAGE_BYTES), host: 'github.com' })
    const result = decodeServerMessage(huge)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toBe('larger than the message cap')
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
