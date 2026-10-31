import { describe, expect, it } from 'vitest'
import { parseClientMessage } from '../../src/main/remote/protocol'
import { decodeServerMessage, encode, type ClientMessage, type ServerMessage } from './protocol-client'
import { INSTALL_COMMAND, SignIn, enrollMessage, type SignInInput } from './signin'

/**
 * The client half of `enroll`, checked against the real wire on both ends: the
 * frame this builds is parsed by the desktop's own `parseClientMessage`, and the
 * frames it reacts to arrive through the real `decodeServerMessage`. Nothing here
 * compares strings — a test that hand-rolled the JSON would pass against a client
 * that cannot actually talk to the host.
 */

const DEVICE = { name: 'Asad’s iPhone', platform: 'iOS 26' }
const INPUT: SignInInput = { username: 'asad', secret: 'hunter2', method: 'password', device: DEVICE }

/** Decode a server frame the way the client really does, from its JSON. */
function serverFrame(message: ServerMessage): ServerMessage {
  const decoded = decodeServerMessage(JSON.stringify(message))
  if (!decoded.ok) throw new Error(`fixture did not decode: ${decoded.reason}`)
  return decoded.message
}

describe('the frame a sign-in opens with', () => {
  it('is one the desktop parser accepts, and carries the credential capability', () => {
    const parsed = parseClientMessage(encode(enrollMessage(INPUT)))
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) throw new Error('unreachable')
    if (parsed.message.t !== 'enroll') throw new Error('wrong frame')
    expect(parsed.message.username).toBe('asad')
    expect(parsed.message.method).toBe('password')
    expect(parsed.message.capabilities).toContain('credential')
  })

  it('sends a key as a key', () => {
    const parsed = parseClientMessage(encode(enrollMessage({ ...INPUT, method: 'key', secret: 'k' })))
    expect(parsed.ok && parsed.message.t === 'enroll' && parsed.message.method).toBe('key')
  })
})

describe('the exchange', () => {
  it('trades enrolled for a hello and then reports the welcome', async () => {
    const sent: ClientMessage[] = []
    const signIn = new SignIn((frame) => sent.push(frame))
    const done = signIn.start(INPUT)

    // First frame out is the enroll.
    expect(sent).toHaveLength(1)
    expect(sent[0]?.t).toBe('enroll')

    // The host mints and answers enrolled.
    signIn.receive(
      serverFrame({ t: 'enrolled', deviceId: 'dev-9', deviceName: 'Asad’s iPhone', credential: 'dev-9.mint' }),
    )

    // The client immediately says hello with the credential, on the same socket.
    expect(sent).toHaveLength(2)
    const hello = sent[1]
    expect(hello?.t).toBe('hello')
    if (hello?.t !== 'hello') throw new Error('unreachable')
    expect(hello.token).toBe('dev-9.mint')

    // The welcome ends it in success.
    const welcome: ServerMessage = {
      t: 'welcome',
      protocol: 1,
      deviceId: 'dev-9',
      deviceName: 'Asad’s iPhone',
      token: null,
      sessions: [],
      capabilities: [],
    }
    signIn.receive(serverFrame(welcome))

    const outcome = await done
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) throw new Error('unreachable')
    expect(outcome.token).toBe('dev-9.mint')
    expect(outcome.deviceId).toBe('dev-9')
  })

  it('reports a refused sign-in in the host’s own words, and sends no hello', async () => {
    const sent: ClientMessage[] = []
    const signIn = new SignIn((frame) => sent.push(frame))
    const done = signIn.start(INPUT)

    signIn.receive(serverFrame({ t: 'error', code: 'unauthorized', message: 'That sign-in was refused.' }))

    const outcome = await done
    expect(outcome).toEqual({ ok: false, message: 'That sign-in was refused.' })
    // Only the enroll went out — no hello after a refusal.
    expect(sent.map((frame) => frame.t)).toEqual(['enroll'])
  })

  it('reports unavailable when the host does not offer sign-in', async () => {
    const signIn = new SignIn(() => {})
    const done = signIn.start(INPUT)
    signIn.receive(
      serverFrame({ t: 'error', code: 'unavailable', message: 'Sign-in is not available on this machine. Pair it with a code instead.' }),
    )
    const outcome = await done
    expect(outcome.ok).toBe(false)
    if (outcome.ok) throw new Error('unreachable')
    expect(outcome.message.toLowerCase()).toContain('pair')
  })

  it('ignores stray frames before the welcome', async () => {
    const sent: ClientMessage[] = []
    const signIn = new SignIn((frame) => sent.push(frame))
    void signIn.start(INPUT)
    signIn.receive(serverFrame({ t: 'enrolled', deviceId: 'd', deviceName: 'iPhone', credential: 'd.x' }))
    // A sessions frame arriving mid-handshake changes nothing.
    signIn.receive(serverFrame({ t: 'sessions', sessions: [] }))
    expect(sent.map((frame) => frame.t)).toEqual(['enroll', 'hello'])
  })

  it('refuses to be started twice', () => {
    const signIn = new SignIn(() => {})
    void signIn.start(INPUT)
    expect(() => signIn.start(INPUT)).toThrow()
  })
})

describe('the install command', () => {
  it('is the one-liner from HEADLESS.md', () => {
    expect(INSTALL_COMMAND).toContain('install.sh')
    expect(INSTALL_COMMAND).toContain('| sh')
  })
})
