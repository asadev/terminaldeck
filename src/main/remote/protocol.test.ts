import { describe, expect, it } from 'vitest'
import {
  CLOSE,
  MAX_COLS,
  MAX_INPUT_BYTES,
  MAX_MESSAGE_BYTES,
  MAX_ROWS,
  MIN_COLS,
  MIN_ROWS,
  OUTPUT_CHUNK_BYTES,
  PROTOCOL_VERSION,
  chunkOutput,
  parseClientMessage,
  serialize,
  type ClientMessage,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from './protocol'

/**
 * Two properties are worth testing here, and they pull in opposite directions.
 *
 * Every valid frame must survive `serialize` → `parseClientMessage` unchanged,
 * because a protocol that quietly drops a field is worse than one that refuses
 * it: the phone looks like it worked.
 *
 * Everything else must be refused, with a code the server can act on. The list
 * below is deliberately unfriendly — ids that are paths, sizes that are `NaN`,
 * `Infinity` or half a million columns, frames that are arrays or binary, and a
 * paste twice the cap that a naive length check waves through.
 *
 * Byte arithmetic is checked against `Buffer.byteLength` rather than against
 * this module's own idea of the answer. `Buffer` is fine in a test — it is the
 * *module* that must stay free of node built-ins, because the phone compiles it
 * too, and `npx tsc -p pwa/tsconfig.json` is what says so.
 */

const SESSION_ID = '4f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5'
const DEVICE = { name: 'Asad’s iPhone', platform: 'iOS 26' }
const TOKEN = 'a'.repeat(64)

/** Adding a client frame without a round-trip case fails to compile here. */
const CLIENT_TYPES: Record<ClientMessage['t'], true> = {
  hello: true,
  list: true,
  attach: true,
  detach: true,
  input: true,
  resize: true,
  ping: true,
}

/** Same guard for the other direction. */
const SERVER_TYPES: Record<ServerMessage['t'], true> = {
  welcome: true,
  sessions: true,
  attached: true,
  detached: true,
  output: true,
  status: true,
  exit: true,
  error: true,
  pong: true,
}

const VALID_CLIENT: ClientMessage[] = [
  { t: 'hello', protocol: PROTOCOL_VERSION, token: TOKEN, device: DEVICE },
  { t: 'list' },
  { t: 'attach', id: SESSION_ID },
  { t: 'attach', id: SESSION_ID, cols: 80, rows: 24 },
  { t: 'detach', id: SESSION_ID },
  { t: 'input', id: SESSION_ID, data: 'git status\r' },
  { t: 'resize', id: SESSION_ID, cols: 120, rows: 40 },
  { t: 'ping' },
]

const SESSION: RemoteSession = {
  id: SESSION_ID,
  title: 'terminaldeck',
  cwd: '/Users/apple/Projects/terminaldeck',
  provider: 'claude',
  status: 'working',
  exitCode: null,
}

const VALID_SERVER: ServerMessage[] = [
  { t: 'welcome', protocol: PROTOCOL_VERSION, deviceId: 'dev-1', deviceName: 'iPhone', token: null, sessions: [SESSION] },
  { t: 'sessions', sessions: [] },
  { t: 'attached', id: SESSION_ID },
  { t: 'detached', id: SESSION_ID },
  { t: 'output', id: SESSION_ID, data: '\u001b[2K\rready ❯ ' },
  { t: 'output', id: SESSION_ID, data: 'old output', replay: true },
  { t: 'status', id: SESSION_ID, status: 'waiting' },
  { t: 'exit', id: SESSION_ID, exitCode: 130 },
  { t: 'error', code: 'unknown-session', message: 'That session is not open.' },
  { t: 'pong' },
]

const ERROR_CODES: ProtocolErrorCode[] = [
  'bad-message',
  'unauthenticated',
  'unauthorized',
  'unknown-session',
  'too-large',
  'version',
]

function accepted(frame: unknown, label = 'frame'): ClientMessage {
  const result = parseClientMessage(frame)
  if (!result.ok) throw new Error(`${label}: expected acceptance, got ${result.code} — ${result.reason}`)
  return result.message
}

function refused(frame: unknown, label = 'frame'): { code: ProtocolErrorCode; reason: string } {
  const result = parseClientMessage(frame)
  expect(result.ok, `${label}: expected a refusal`).toBe(false)
  if (result.ok) throw new Error('unreachable')
  expect(ERROR_CODES, `${label}: refusal code must be one both ends know`).toContain(result.code)
  expect(result.reason.length, `${label}: a refusal must say why`).toBeGreaterThan(0)
  return result
}

const hello = (patch: Record<string, unknown>): Record<string, unknown> => ({
  t: 'hello',
  protocol: PROTOCOL_VERSION,
  token: TOKEN,
  device: { ...DEVICE },
  ...patch,
})

describe('round-trip', () => {
  it('carries every client message through serialize → parse unchanged', () => {
    for (const message of VALID_CLIENT) {
      expect(accepted(serialize(message), message.t)).toEqual(message)
    }
  })

  it('covers every client frame the union declares', () => {
    expect(new Set(VALID_CLIENT.map((m) => m.t))).toEqual(new Set(Object.keys(CLIENT_TYPES)))
  })

  it('serializes every server message to JSON the phone can read back', () => {
    for (const message of VALID_SERVER) {
      expect(JSON.parse(serialize(message))).toEqual(message)
    }
    expect(new Set(VALID_SERVER.map((m) => m.t))).toEqual(new Set(Object.keys(SERVER_TYPES)))
  })

  it('accepts an already-decoded object, so no transport skips the checks', () => {
    expect(accepted({ t: 'attach', id: SESSION_ID, cols: 80, rows: 24 })).toEqual({
      t: 'attach',
      id: SESSION_ID,
      cols: 80,
      rows: 24,
    })
  })

  it('keeps the control bytes that make a terminal a terminal', () => {
    const data = '\u001b[A\r\n\u0003'
    expect(accepted(serialize({ t: 'input', id: SESSION_ID, data }))).toEqual({ t: 'input', id: SESSION_ID, data })
  })
})

describe('frames that are not frames', () => {
  it('refuses JSON that is not an object', () => {
    for (const text of ['[]', '"hello"', '42', 'null', 'true', '[{"t":"list"}]']) {
      expect(refused(text, text).code).toBe('bad-message')
    }
  })

  it('refuses text that is not JSON', () => {
    for (const text of ['', '{', 'undefined', '{t:"list"}', "{'t':'list'}", '<html>login</html>']) {
      expect(refused(text, JSON.stringify(text)).reason).toBe('not JSON')
    }
  })

  it('refuses values that are neither text nor a record', () => {
    for (const value of [undefined, null, 42, true, Symbol('x'), () => 'list', []]) {
      expect(refused(value, String(typeof value)).code).toBe('bad-message')
    }
  })

  it('refuses a binary frame instead of reading it as an empty record', () => {
    // A socket in binary mode delivers a view, and `typeof` calls that an
    // object — every field check would then see `undefined` and say so, which
    // is a true statement about the wrong problem.
    expect(refused(new Uint8Array([123, 125]), 'Uint8Array').reason).toBe('binary frame')
    expect(refused(new ArrayBuffer(2), 'ArrayBuffer').reason).toBe('binary frame')
  })
})

describe('the type tag', () => {
  it('refuses a missing or non-string tag', () => {
    for (const t of [undefined, null, 1, true, {}, ['list']]) {
      expect(refused({ t, id: SESSION_ID }, String(t)).code).toBe('bad-message')
    }
  })

  it('refuses a verb this desktop does not implement', () => {
    for (const t of ['kill', 'exec', 'spawn', 'create', 'welcome', 'output', 'HELLO', 'Attach', '']) {
      expect(refused({ t }, t).code).toBe('bad-message')
    }
  })

  it('refuses inherited property names, which are not frame types', () => {
    // `{t: 'toString'}` names a real function on any object reached through a
    // lookup table. A switch does not care; this test says so on purpose.
    for (const t of ['toString', 'constructor', '__proto__', 'hasOwnProperty', 'valueOf']) {
      expect(refused({ t }, t).code).toBe('bad-message')
    }
  })
})

describe('hello', () => {
  it('refuses a protocol version that is not a whole number', () => {
    // The `NaN` case is the one that matters: an earlier draft read a missing
    // version as 0 and therefore read `NaN` as a version too, which no
    // comparison against PROTOCOL_VERSION can ever reject.
    for (const protocol of [undefined, null, '1', 1.5, -1, NaN, Infinity, -Infinity, 70000, true, {}]) {
      expect(refused(hello({ protocol }), String(protocol)).code).toBe('bad-message')
    }
  })

  it('accepts a version this desktop does not speak, and leaves the verdict to the server', () => {
    // Refusing to parse it would leave no way to answer "your app is too old",
    // which is the one thing that situation needs. That is the `version` code.
    const message = accepted(hello({ protocol: 99 }))
    expect(message).toEqual({ t: 'hello', protocol: 99, token: TOKEN, device: DEVICE })
  })

  it('refuses a token that is missing, empty, oversized or has control bytes', () => {
    for (const token of [undefined, null, 42, '', 'x'.repeat(201), 'tok\u0000en', 'tok\nen', 'tok\u007f']) {
      expect(refused(hello({ token }), JSON.stringify(token)).code).toBe('bad-message')
    }
  })

  it('does not lock the token charset, which belongs to device-auth', () => {
    // A base64url pairing token today; a charset pinned here would turn any
    // change to what that module mints into a login that fails silently.
    for (const token of ['xY7-_aB9', 'ab12 cd34', 'AB12-CD34', 'x'.repeat(200)]) {
      expect(accepted(hello({ token }), token)).toEqual({
        t: 'hello',
        protocol: PROTOCOL_VERSION,
        token,
        device: DEVICE,
      })
    }
  })

  it('refuses a device descriptor that is missing or not made of strings', () => {
    for (const device of [undefined, null, 'iPhone', 42, [], {}, { name: 'x' }, { name: 1, platform: 'iOS' }, { name: 'x', platform: null }]) {
      expect(refused(hello({ device }), JSON.stringify(device)).code).toBe('bad-message')
    }
  })

  it('sanitises the device name rather than refusing it', () => {
    // A name is display text. Refusing a login over an emoji in a phone's name
    // would be absurd; letting a control byte into the paired-devices list and
    // from there into a log would not.
    const message = accepted(hello({ device: { name: '  iPhone\u0007\u001b[31m  ', platform: 'iOS\u0000' } }))
    expect(message).toEqual({
      t: 'hello',
      protocol: PROTOCOL_VERSION,
      token: TOKEN,
      device: { name: 'iPhone[31m', platform: 'iOS' },
    })
  })

  it('caps a name that is a paragraph, and names the unnamed', () => {
    const long = accepted(hello({ device: { name: 'n'.repeat(500), platform: 'p'.repeat(500) } }))
    const device = (long as { device: { name: string; platform: string } }).device
    expect(device.name).toHaveLength(60)
    expect(device.platform).toHaveLength(40)

    const blank = accepted(hello({ device: { name: '   ', platform: '\u0001' } }))
    expect((blank as { device: { name: string; platform: string } }).device).toEqual({
      name: 'Unnamed device',
      platform: 'unknown',
    })
  })
})

/** Ids reach maps, log lines and a lookup against live sessions. */
const BAD_IDS: unknown[] = [
  undefined,
  null,
  42,
  true,
  {},
  ['id'],
  '',
  '../../../etc/passwd',
  'a/b',
  'a\\b',
  'a b',
  'a\u0000b',
  'a\nb',
  'session;rm -rf ~',
  '-leading-dash',
  '_leading-underscore',
  '😀',
  'x'.repeat(65),
]

describe('session ids', () => {
  it('are shape-checked on every frame that carries one', () => {
    for (const value of BAD_IDS) {
      const label = JSON.stringify(value)
      expect(refused({ t: 'attach', id: value }, label).code).toBe('bad-message')
      expect(refused({ t: 'detach', id: value }, label).code).toBe('bad-message')
      expect(refused({ t: 'input', id: value, data: 'x' }, label).code).toBe('bad-message')
      expect(refused({ t: 'resize', id: value, cols: 80, rows: 24 }, label).code).toBe('bad-message')
    }
  })

  it('accepts a well-formed id that names nothing, because that is the server’s question', () => {
    // The parser is not an authorisation check and must not be mistaken for one.
    expect(accepted({ t: 'attach', id: 'not-a-live-session' })).toEqual({ t: 'attach', id: 'not-a-live-session' })
  })
})

const BAD_SIZES: unknown[] = [undefined, null, '80', true, {}, 0, -1, 1.5, NaN, Infinity, -Infinity, 1e9]

describe('cols and rows', () => {
  it('refuses anything that is not a whole number in range', () => {
    for (const value of BAD_SIZES) {
      const label = String(value)
      expect(refused({ t: 'resize', id: SESSION_ID, cols: value, rows: 24 }, `cols=${label}`).code).toBe('bad-message')
      expect(refused({ t: 'resize', id: SESSION_ID, cols: 80, rows: value }, `rows=${label}`).code).toBe('bad-message')
    }
  })

  it('refuses sizes outside the range a phone could want', () => {
    for (const [cols, rows] of [
      [MIN_COLS - 1, 24],
      [MAX_COLS + 1, 24],
      [80, MIN_ROWS - 1],
      [80, MAX_ROWS + 1],
    ]) {
      expect(refused({ t: 'resize', id: SESSION_ID, cols, rows }, `${cols}x${rows}`).code).toBe('bad-message')
    }
    expect(accepted({ t: 'resize', id: SESSION_ID, cols: MIN_COLS, rows: MIN_ROWS })).toBeTruthy()
    expect(accepted({ t: 'resize', id: SESSION_ID, cols: MAX_COLS, rows: MAX_ROWS })).toBeTruthy()
  })

  it('refuses a size that arrived as JSON null or as an overflowed literal', () => {
    // `JSON.stringify(NaN)` is `null`, so a client that computes a bad size
    // over JSON sends null rather than NaN. Both have to lose.
    expect(refused(`{"t":"resize","id":"${SESSION_ID}","cols":null,"rows":24}`).code).toBe('bad-message')
    expect(refused(`{"t":"resize","id":"${SESSION_ID}","cols":1e999,"rows":24}`).code).toBe('bad-message')
  })

  it('takes a viewport on attach, both or neither', () => {
    expect(accepted({ t: 'attach', id: SESSION_ID })).toEqual({ t: 'attach', id: SESSION_ID })
    expect(accepted({ t: 'attach', id: SESSION_ID, cols: 60, rows: 20 })).toEqual({
      t: 'attach',
      id: SESSION_ID,
      cols: 60,
      rows: 20,
    })
    expect(refused({ t: 'attach', id: SESSION_ID, cols: 60 }, 'cols only').code).toBe('bad-message')
    expect(refused({ t: 'attach', id: SESSION_ID, rows: 20 }, 'rows only').code).toBe('bad-message')
    expect(refused({ t: 'attach', id: SESSION_ID, cols: 60, rows: 9999 }, 'out of range').code).toBe('bad-message')
  })
})

describe('input', () => {
  it('refuses data that is not a string', () => {
    // `{toString: 'x'}` is in the list because it is what a client sends when
    // it serialises a wrapper object by accident, and because `String()` throws
    // on it — labels go through JSON.stringify for that reason.
    for (const data of [undefined, null, 42, true, {}, ['x'], { toString: 'x' }]) {
      expect(refused({ t: 'input', id: SESSION_ID, data }, JSON.stringify(data)).code).toBe('bad-message')
    }
  })

  it('caps a paste by bytes, at the exact limit', () => {
    const under = 'a'.repeat(MAX_INPUT_BYTES)
    const over = 'a'.repeat(MAX_INPUT_BYTES + 1)
    expect(Buffer.byteLength(under)).toBe(MAX_INPUT_BYTES)
    expect(accepted({ t: 'input', id: SESSION_ID, data: under })).toBeTruthy()
    expect(refused({ t: 'input', id: SESSION_ID, data: over }).code).toBe('too-large')
  })

  it('counts an emoji as four bytes and not as two units', () => {
    // The case a length check waves through: 4,097 emoji are 8,194 UTF-16 units
    // — half a 16,384 cap read as length — and 16,388 bytes on the wire.
    const atCap = '😀'.repeat(MAX_INPUT_BYTES / 4)
    const overCap = '😀'.repeat(MAX_INPUT_BYTES / 4 + 1)
    expect(Buffer.byteLength(atCap)).toBe(MAX_INPUT_BYTES)
    expect(overCap.length).toBeLessThan(MAX_INPUT_BYTES)
    expect(accepted({ t: 'input', id: SESSION_ID, data: atCap })).toBeTruthy()
    expect(refused({ t: 'input', id: SESSION_ID, data: overCap }).code).toBe('too-large')
  })

  it('counts a lone surrogate the way an encoder does', () => {
    const half = '\ud800'
    expect(Buffer.byteLength(half)).toBe(3)
    const atCap = half.repeat(Math.floor(MAX_INPUT_BYTES / 3))
    const overCap = half.repeat(Math.floor(MAX_INPUT_BYTES / 3) + 1)
    expect(Buffer.byteLength(overCap)).toBeGreaterThan(MAX_INPUT_BYTES)
    expect(accepted({ t: 'input', id: SESSION_ID, data: atCap })).toBeTruthy()
    expect(refused({ t: 'input', id: SESSION_ID, data: overCap }).code).toBe('too-large')
  })
})

describe('frame size', () => {
  it('refuses a frame over the message limit', () => {
    const frame = serialize({ t: 'input', id: SESSION_ID, data: 'a'.repeat(MAX_MESSAGE_BYTES) })
    expect(refused(frame).code).toBe('too-large')
  })

  it('measures the frame in bytes, not in characters', () => {
    // 40,000 euro signs: well under the cap in units, 120,000 bytes on the wire.
    const frame = '€'.repeat(40_000)
    expect(frame.length).toBeLessThan(MAX_MESSAGE_BYTES)
    expect(Buffer.byteLength(frame)).toBeGreaterThan(MAX_MESSAGE_BYTES)
    expect(refused(frame).code).toBe('too-large')
  })

  it('checks the size before parsing, so a huge frame is never decoded', () => {
    // Deliberately not JSON. `too-large` rather than `not JSON` is the only
    // observable proof that JSON.parse never saw it.
    const refusal = refused('a'.repeat(MAX_MESSAGE_BYTES + 1))
    expect(refusal.code).toBe('too-large')
    expect(refusal.reason).not.toBe('not JSON')
  })

  it('accepts a frame just under the cap', () => {
    const data = 'a'.repeat(MAX_INPUT_BYTES)
    const frame = serialize({ t: 'input', id: SESSION_ID, data })
    expect(Buffer.byteLength(frame)).toBeLessThan(MAX_MESSAGE_BYTES)
    expect(accepted(frame)).toEqual({ t: 'input', id: SESSION_ID, data })
  })
})

describe('the object path is not the weak path', () => {
  /**
   * `parseClientMessage` takes `unknown`, so a caller may hand it an object
   * that never went through `JSON.parse`. On that path a property is not
   * necessarily a stored value: a getter can answer the type check with one
   * thing and the forwarding read with another. Every field therefore has to be
   * bound to a local once and checked there. These four cases are what happens
   * when it is not, and all four were real before this test existed.
   */
  const reading = <T>(...answers: T[]) => {
    let n = 0
    return () => answers[Math.min(n++, answers.length - 1)]
  }

  it('does not forward an input payload other than the one it measured', () => {
    const huge = 'A'.repeat(MAX_INPUT_BYTES * 10)
    const frame = { t: 'input', id: SESSION_ID, get data() { return next() } }
    const next = reading('ok', 'ok', huge)
    const result = parseClientMessage(frame)
    if (result.ok) {
      // Accepting is allowed; delivering the unmeasured value is not.
      expect(result.message.t).toBe('input')
      const data = (result.message as { data: string }).data
      expect(Buffer.byteLength(data)).toBeLessThanOrEqual(MAX_INPUT_BYTES)
    }
  })

  it('does not forward an input payload that is not a string', () => {
    const next = reading('ok', 'ok', { evil: true } as unknown as string)
    const result = parseClientMessage({ t: 'input', id: SESSION_ID, get data() { return next() } })
    if (result.ok) expect(typeof (result.message as { data: unknown }).data).toBe('string')
  })

  it('does not throw when a device field changes under it', () => {
    // The contract is a refusal, never an exception: this runs on a socket's
    // data event inside the main process.
    const next = reading('phone', 42 as unknown as string)
    const frame = hello({ device: { get name() { return next() }, platform: 'iOS' } })
    let result: ReturnType<typeof parseClientMessage> | undefined
    expect(() => { result = parseClientMessage(frame) }).not.toThrow()
    if (result?.ok) expect(typeof (result.message as { device: { name: unknown } }).device.name).toBe('string')
  })

  it('never throws for any shape a caller can hand it', () => {
    const nasty: unknown[] = [
      { t: 'input', id: SESSION_ID, get data(): string { throw new Error('boom') } },
      { get t(): string { throw new Error('boom') } },
      // Built literally rather than through `hello()`: the spread in that
      // helper would run the getter before the parser ever saw the frame.
      { t: 'hello', protocol: PROTOCOL_VERSION, token: TOKEN, get device(): unknown { throw new Error('boom') } },
      Object.create(null),
      new Proxy({ t: 'list' }, {}),
      new Map([['t', 'list']]),
      new Date(),
      /regex/,
    ]
    for (const frame of nasty) {
      // A throwing getter is the caller's own bug and may propagate; what must
      // not happen is this parser throwing on a value it accepted or refused.
      try {
        const result = parseClientMessage(frame)
        expect(typeof result.ok).toBe('boolean')
      } catch (error) {
        expect((error as Error).message).toBe('boom')
      }
    }
  })

})

describe('display strings a person will read', () => {
  const nameOf = (name: string): string => {
    const result = accepted(hello({ device: { name, platform: 'iOS' } }))
    return (result as { device: { name: string } }).device.name
  }

  it('never ends a capped name in half a surrogate pair', () => {
    // The same defect chunkOutput avoids on the wire: slice() counts UTF-16
    // units, so a pair straddling the 60th unit leaves a lone half behind.
    for (const lead of [58, 59, 60, 61]) {
      const name = nameOf('a'.repeat(lead) + '\u{1F600}' + 'tail')
      const orphan = name.replace(/[\ud800-\udbff][\udc00-\udfff]/g, '')
      expect(/[\ud800-\udfff]/.test(orphan), `lead ${lead}: left half a pair`).toBe(false)
      expect(name.length).toBeLessThanOrEqual(60)
    }
  })

  it('strips C1 controls, which are escape sequences in eight-bit form', () => {
    // U+009B is CSI. Stripping C0 and stopping there leaves the same hole open
    // for any terminal that honours eight-bit controls.
    expect(nameOf('iPhone\u009b31m red')).toBe('iPhone31m red')
    expect(nameOf('iPhone\u0085\u0090x')).toBe('iPhonex')
  })

  it('strips the bidi controls that make a name render as another name', () => {
    // The approval list is where a human grants shell access by reading this
    // string. A right-to-left override reverses what follows it.
    for (const control of ['\u202a', '\u202b', '\u202c', '\u202d', '\u202e', '\u2066', '\u2067', '\u2068', '\u2069']) {
      expect(nameOf(`iPhone${control}drowssap`), control).toBe('iPhonedrowssap')
    }
    expect(nameOf('a\u2028b\u2029c')).toBe('abc')
  })

  it('leaves emoji, joiners and non-Latin scripts alone', () => {
    // Zero-width joiner carries every multi-part emoji; stripping it would
    // mangle ordinary names to defend against an invisible character.
    for (const name of ['\u{1F468}\u200d\u{1F4BB} dev', 'Asad\u2019s iPhone', '\u0623\u062d\u0645\u062f', '\u05d3\u05d5\u05d3', '\u5c0f\u7c73']) {
      expect(nameOf(name), name).toBe(name)
    }
  })

  it('still refuses a token carrying a C1 byte', () => {
    expect(refused(hello({ token: 'tok\u009ben' })).code).toBe('bad-message')
  })
})

describe('what a frame cannot smuggle', () => {
  it('does not let __proto__ out of the frame', () => {
    const message = accepted('{"t":"list","__proto__":{"polluted":true}}')
    expect(Object.getPrototypeOf(message)).toBe(Object.prototype)
    expect('polluted' in message).toBe(false)
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()
  })

  it('drops fields it does not know rather than refusing them', () => {
    // Forward compatibility: a newer phone sends more and still works here.
    const message = accepted({ t: 'list', cwd: '/etc', shell: '/bin/sh', admin: true })
    expect(message).toEqual({ t: 'list' })
    expect(Object.keys(message)).toEqual(['t'])
  })

  it('returns only the fields the frame type declares', () => {
    const message = accepted({ t: 'detach', id: SESSION_ID, data: 'rm -rf ~', cols: 80 })
    expect(Object.keys(message).sort()).toEqual(['id', 't'])
  })

  it('never quotes the refused value back', () => {
    // Reasons are logged and sent over the wire; echoing attacker text puts it
    // in both places at once.
    const canary = 'CANARY-9d2b'
    expect(refused({ t: canary }).reason).not.toContain(canary)
    expect(refused({ t: 'input', id: `${canary}/../..`, data: 'x' }).reason).not.toContain(canary)
    expect(refused(hello({ token: `${canary}\u0000` })).reason).not.toContain(canary)
  })
})

describe('refusals', () => {
  it('carry a code the server can put straight into an error frame', () => {
    const refusal = refused({ t: 'input', id: SESSION_ID, data: 42 })
    const error: ServerMessage = { t: 'error', code: refusal.code, message: refusal.reason }
    expect(JSON.parse(serialize(error))).toEqual(error)
  })

  it('separate "too big" from "malformed", because the close codes differ', () => {
    expect(CLOSE.messageTooBig).toBe(1009)
    expect(CLOSE.protocolError).toBe(1002)
    expect(refused('a'.repeat(MAX_MESSAGE_BYTES + 1)).code).toBe('too-large')
    expect(refused('{').code).toBe('bad-message')
  })
})

describe('chunkOutput', () => {
  const bytesOf = (chunks: string[]): number[] => chunks.map((c) => Buffer.byteLength(c))

  it('sends nothing for nothing and one frame for a short burst', () => {
    expect(chunkOutput('')).toEqual([])
    expect(chunkOutput('ready ❯ ')).toEqual(['ready ❯ '])
  })

  it('splits on a byte budget and loses nothing', () => {
    const data = 'a'.repeat(10)
    expect(chunkOutput(data, 4)).toEqual(['aaaa', 'aaaa', 'aa'])
    const scrollback = 'x'.repeat(OUTPUT_CHUNK_BYTES * 2 + 17)
    const chunks = chunkOutput(scrollback)
    expect(chunks.join('')).toBe(scrollback)
    expect(Math.max(...bytesOf(chunks))).toBeLessThanOrEqual(OUTPUT_CHUNK_BYTES)
  })

  it('measures the budget in bytes, so a multibyte burst is not four times the cap', () => {
    const chunks = chunkOutput('😀'.repeat(3), 8)
    expect(chunks).toEqual(['😀😀', '😀'])
    expect(bytesOf(chunks)).toEqual([8, 4])
  })

  it('never cuts a surrogate pair in half', () => {
    // Cutting UTF-16 at a fixed offset sends two lone halves, which JSON
    // encodes happily and the phone renders as two replacement characters —
    // one corrupted glyph per chunk boundary, blamed on the terminal.
    const data = ('😀'.repeat(7) + 'ok').repeat(200)
    for (const size of [5, 7, 8, 13, 64]) {
      const chunks = chunkOutput(data, size)
      expect(chunks.join(''), `size ${size}`).toBe(data)
      for (const chunk of chunks) {
        const orphan = chunk.replace(/[\ud800-\udbff][\udc00-\udfff]/g, '')
        expect(/[\ud800-\udfff]/.test(orphan), `size ${size}: split a pair`).toBe(false)
      }
    }
  })

  it('keeps a code point whole even when it alone exceeds the budget', () => {
    // Nothing else is possible: the alternative is emitting half a character.
    expect(chunkOutput('😀😀', 2)).toEqual(['😀', '😀'])
  })
})
