import { describe, expect, it } from 'vitest'
import {
  CAPABILITIES,
  CLOSE,
  MAX_COLS,
  MAX_INPUT_BYTES,
  MAX_MESSAGE_BYTES,
  MAX_NET_DATA_CHARS,
  MAX_ROWS,
  MIN_COLS,
  MIN_ROWS,
  MAX_CWD_BYTES,
  MAX_PROVIDER_LENGTH,
  MAX_UPLOAD_BYTES,
  MAX_UPLOAD_DATA_CHARS,
  MAX_UPLOAD_NAME_BYTES,
  NET_WINDOW_BYTES,
  SHA256_HEX_LENGTH,
  OUTPUT_CHUNK_BYTES,
  PROTOCOL_ERROR_CODES,
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
  create: true,
  ports: true,
  'tunnel.open': true,
  'tunnel.close': true,
  'net.open': true,
  'net.data': true,
  'net.ack': true,
  'net.close': true,
  'upload.begin': true,
  'upload.data': true,
  'upload.end': true,
  'upload.cancel': true,
  'credential.ack': true,
  'credential.answer': true,
  'credential.deny': true,
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
  created: true,
  folders: true,
  ports: true,
  'tunnel.opened': true,
  'tunnel.closed': true,
  'net.data': true,
  'net.ack': true,
  'net.close': true,
  'upload.ready': true,
  'upload.ack': true,
  'upload.done': true,
  'upload.failed': true,
  'credential.request': true,
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
  { t: 'create' },
  { t: 'create', cwd: '/Users/apple/Projects/terminaldeck' },
  { t: 'create', cols: 80, rows: 24 },
  { t: 'create', cwd: '/Users/apple/Projects/terminaldeck', cols: 100, rows: 30 },
  { t: 'create', provider: 'shell' },
  { t: 'create', cwd: '/Users/apple/Projects/terminaldeck', provider: 'claude', cols: 100, rows: 30 },
  { t: 'ports' },
  { t: 'tunnel.open', id: 'tun-1', port: 3000 },
  { t: 'tunnel.close', id: 'tun-1' },
  { t: 'net.open', ch: 'c1', tunnel: 'tun-1' },
  { t: 'net.data', ch: 'c1', data: Buffer.from('GET / HTTP/1.1\r\n\r\n').toString('base64') },
  { t: 'net.ack', ch: 'c1', bytes: 1448 },
  { t: 'net.close', ch: 'c1' },
  { t: 'upload.begin', id: 'up-1', name: 'IMG_4823.HEIC', size: 3_145_728 },
  { t: 'upload.data', id: 'up-1', data: Buffer.from([0xff, 0xd8, 0xff, 0xe0]).toString('base64') },
  { t: 'upload.end', id: 'up-1', sha256: 'e'.repeat(SHA256_HEX_LENGTH) },
  { t: 'upload.cancel', id: 'up-1' },
  // A client that claims nothing and one that claims what it can do. Both are
  // legal `hello`s and the first is what every build before the field sends.
  { t: 'hello', protocol: PROTOCOL_VERSION, token: TOKEN, device: DEVICE, capabilities: ['credential'] },
  { t: 'credential.ack', id: 'req-1' },
  { t: 'credential.answer', id: 'req-1', username: 'octocat', password: 'ghp_notarealtoken' },
  { t: 'credential.answer', id: 'req-1', username: 'octocat', password: 'ghp_notarealtoken', remember: true },
  { t: 'credential.deny', id: 'req-1' },
  { t: 'credential.deny', id: 'req-1', reason: 'no-account' },
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
  {
    t: 'welcome',
    protocol: PROTOCOL_VERSION,
    deviceId: 'dev-1',
    deviceName: 'iPhone',
    token: null,
    sessions: [SESSION],
    capabilities: CAPABILITIES,
  },
  { t: 'sessions', sessions: [] },
  { t: 'ports', ports: [{ port: 3000, process: 'node', guessed: false }] },
  { t: 'tunnel.opened', id: 'tun-1', port: 3000 },
  { t: 'tunnel.closed', id: 'tun-1', message: 'Stopped from the desktop.' },
  { t: 'net.data', ch: 'c1', data: Buffer.from('HTTP/1.1 200 OK\r\n\r\n').toString('base64') },
  { t: 'net.ack', ch: 'c1', bytes: 19 },
  { t: 'net.close', ch: 'c1' },
  { t: 'attached', id: SESSION_ID },
  { t: 'detached', id: SESSION_ID },
  { t: 'output', id: SESSION_ID, data: '\u001b[2K\rready ❯ ' },
  { t: 'output', id: SESSION_ID, data: 'old output', replay: true },
  { t: 'status', id: SESSION_ID, status: 'waiting' },
  { t: 'exit', id: SESSION_ID, exitCode: 130 },
  { t: 'error', code: 'unknown-session', message: 'That session is not open.' },
  { t: 'pong' },
  { t: 'created', session: SESSION },
  { t: 'folders', folders: ['/Users/apple/Projects/terminaldeck'] },
  // Empty is a frame that gets sent: it is a person having removed the last
  // folder from a device, which is a different message from never having chosen
  // one, and it has to survive the round trip as itself.
  { t: 'folders', folders: [] },
  { t: 'upload.ready', id: 'up-1', path: '/Users/apple/Downloads/Terminal Deck/IMG_4823.HEIC' },
  { t: 'upload.ack', id: 'up-1', bytes: 24 * 1024 },
  {
    t: 'upload.done',
    id: 'up-1',
    path: '/Users/apple/Downloads/Terminal Deck/IMG_4823.HEIC',
    bytes: 3_145_728,
    sha256: 'e'.repeat(SHA256_HEX_LENGTH),
  },
  { t: 'upload.failed', id: 'up-1', message: 'Cancelled on the phone.' },
  {
    t: 'credential.request',
    id: 'req-1',
    host: 'github.com',
    repo: 'asadev/terminaldeck',
    operation: 'write',
    prompt: true,
  },
  // Null is a frame that gets sent: git supplied no path to derive a name from,
  // and a client is expected to say so rather than invent one.
  { t: 'credential.request', id: 'req-2', host: 'github.com', repo: null, operation: 'read', prompt: false },
]

/**
 * Taken from the module rather than restated, which is the whole point of it
 * being a value: three clients validate an inbound code against a copy of this
 * list, and a test with its own copy would be a fourth place to forget.
 */
const ERROR_CODES: readonly ProtocolErrorCode[] = PROTOCOL_ERROR_CODES

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
    // `new` and `session.create` are in this list on purpose: they are the two
    // shapes the phone clients invented against their own stand-ins before any
    // desktop could serve one. Exactly one of the three spellings is the
    // protocol, and it is `create`; the other two are refused like any other
    // verb nobody agreed on.
    for (const t of ['kill', 'exec', 'spawn', 'new', 'session.create', 'welcome', 'output', 'HELLO', 'Attach', '']) {
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

  /*
   * The budget is spent in bytes of *frame*, not bytes of text.
   *
   * These use control characters rather than ASCII on purpose. ASCII costs one
   * byte either way, so every earlier case in this block passes just as well
   * against an accounting that ignores JSON escaping — which is exactly how the
   * defect survived: the tests were written in the one alphabet that cannot see
   * it, while a terminal speaks the alphabet that can.
   */
  it('counts what JSON escaping costs, not what the text weighs', () => {
    // Six bytes of frame each, one byte of text each.
    const escapes = '\u001b'.repeat(24)
    expect(chunkOutput(escapes, 12)).toEqual(Array.from({ length: 12 }, () => '\u001b\u001b'))
    // Two-byte forms: `"` and `\` and the five named escapes.
    expect(chunkOutput('""""""', 4)).toEqual(['""', '""', '""'])
    expect(chunkOutput('\\\\\\\\', 4)).toEqual(['\\\\', '\\\\'])
    expect(chunkOutput('\n\n\n\n', 4)).toEqual(['\n\n', '\n\n'])
    // A tab is `\t`, two bytes — not the six a bare C0 control costs.
    expect(chunkOutput('\t\t\t', 6)).toEqual(['\t\t\t'])
  })

  it('never builds an output frame past the cap every client refuses at', () => {
    /*
     * The failure this exists to stop, in one sentence: 32 KiB of escapes
     * serialised to 192 KiB, three times `MAX_MESSAGE_BYTES`, and the phone
     * answers an oversized frame by closing the socket. What the person saw was
     * a session that dropped whenever the agent drew something colourful — and
     * nothing in the logs pointed here, because from this side the chunk was
     * comfortably inside its budget.
     */
    const scrollback = ('\u001b[1;31m' + 'x'.repeat(40) + '\u001b[0m\r\n').repeat(4000)
    const chunks = chunkOutput(scrollback)
    expect(chunks.join('')).toBe(scrollback)
    expect(chunks.length).toBeGreaterThan(1)
    for (const piece of chunks) {
      const frame = serialize({ t: 'output', id: SESSION_ID, data: piece })
      expect(Buffer.byteLength(frame)).toBeLessThanOrEqual(MAX_MESSAGE_BYTES)
      // And the piece itself is inside the budget it was cut to, envelope aside.
      expect(Buffer.byteLength(JSON.stringify(piece)) - 2).toBeLessThanOrEqual(OUTPUT_CHUNK_BYTES)
    }
  })

  it('does not hand back an oversized burst whole for being short in raw bytes', () => {
    // The old fast path measured raw UTF-8 and returned early, so the biggest
    // frames this function produced were the ones it never looked at.
    const escapes = '\u001b'.repeat(OUTPUT_CHUNK_BYTES)
    const chunks = chunkOutput(escapes)
    // Six bytes of frame per escape, so a chunk holds a sixth of the budget.
    // This used to come back as one chunk of 192 KiB, which is the bug.
    const perChunk = Math.floor(OUTPUT_CHUNK_BYTES / 6)
    expect(chunks.length).toBe(Math.ceil(escapes.length / perChunk))
    expect(chunks.join('')).toBe(escapes)
    for (const piece of chunks) {
      expect(Buffer.byteLength(JSON.stringify(piece)) - 2).toBeLessThanOrEqual(OUTPUT_CHUNK_BYTES)
    }
  })
})

/**
 * The `localhost` verbs.
 *
 * These carry two things nothing else in this protocol does: a port, which is a
 * number that decides what a socket connects to, and base64, which is a decoder
 * that does not fail. `Buffer.from(x, 'base64')` silently skips bytes it does
 * not recognise and returns a short buffer, so a corrupted frame would arrive at
 * the dev server as a truncated request rather than as an error — which reads,
 * to whoever is debugging it, as the dev server being broken.
 */
describe('localhost tunnels', () => {
  it('refuses a port that is not a port', () => {
    for (const port of [0, -1, 65_536, 1.5, NaN, Infinity, '3000', null, undefined, true]) {
      expect(refused({ t: 'tunnel.open', id: 'tun-1', port }, JSON.stringify(port)).code).toBe('bad-message')
    }
  })

  it('accepts the ends of the port range', () => {
    for (const port of [1, 80, 3000, 65_535]) {
      const message = accepted({ t: 'tunnel.open', id: 'tun-1', port }, String(port))
      expect(message).toEqual({ t: 'tunnel.open', id: 'tun-1', port })
    }
  })

  it('shape-checks the channel and tunnel ids like every other id', () => {
    for (const value of ['', '../etc/passwd', 'a b', '-leading', 'x'.repeat(65), 7, null]) {
      const label = JSON.stringify(value)
      expect(refused({ t: 'net.open', ch: value, tunnel: 'tun-1' }, label).code).toBe('bad-message')
      expect(refused({ t: 'net.open', ch: 'c1', tunnel: value }, label).code).toBe('bad-message')
      expect(refused({ t: 'net.data', ch: value, data: '' }, label).code).toBe('bad-message')
      expect(refused({ t: 'net.close', ch: value }, label).code).toBe('bad-message')
      expect(refused({ t: 'tunnel.close', id: value }, label).code).toBe('bad-message')
    }
  })

  it('refuses payloads that are not base64, rather than decoding what it can', () => {
    for (const data of ['not base64!', 'AAA', 'AA=A', 'QUJD\n', '☃', 12, null, undefined]) {
      expect(refused({ t: 'net.data', ch: 'c1', data }, JSON.stringify(data)).code).toBe('bad-message')
    }
  })

  it('accepts real base64, padding included', () => {
    for (const text of ['', 'A', 'AB', 'ABC', 'GET / HTTP/1.1\r\nHost: localhost:3000\r\n\r\n']) {
      const data = Buffer.from(text).toString('base64')
      const message = accepted({ t: 'net.data', ch: 'c1', data }, JSON.stringify(text))
      expect(message).toEqual({ t: 'net.data', ch: 'c1', data })
      expect(Buffer.from(data, 'base64').toString()).toBe(text)
    }
  })

  it('caps a chunk at the encoded length of the raw limit', () => {
    const atCap = 'A'.repeat(MAX_NET_DATA_CHARS)
    expect(accepted({ t: 'net.data', ch: 'c1', data: atCap })).toEqual({
      t: 'net.data',
      ch: 'c1',
      data: atCap,
    })
    // Four more characters, so it is still valid base64 and only the size is wrong.
    expect(refused({ t: 'net.data', ch: 'c1', data: 'A'.repeat(MAX_NET_DATA_CHARS + 4) }).code).toBe('too-large')
  })

  it('refuses an acknowledgement of more than a whole window', () => {
    // An ack larger than anything that can be in flight is either a bug or an
    // attempt to unblock a paused reader by claiming progress that never
    // happened, and there is no reason to tell the two apart.
    for (const bytes of [0, -1, 1.5, NaN, NET_WINDOW_BYTES + 1, '100', null]) {
      expect(refused({ t: 'net.ack', ch: 'c1', bytes }, JSON.stringify(bytes)).code).toBe('bad-message')
    }
    expect(accepted({ t: 'net.ack', ch: 'c1', bytes: NET_WINDOW_BYTES })).toEqual({
      t: 'net.ack',
      ch: 'c1',
      bytes: NET_WINDOW_BYTES,
    })
  })

  it('reads the payload once, so a getter cannot swap it after the size check', () => {
    let reads = 0
    const frame = {
      t: 'net.data',
      ch: 'c1',
      get data(): string {
        reads += 1
        return reads === 1 ? 'QUJD' : 'A'.repeat(MAX_NET_DATA_CHARS + 4)
      },
    }
    const message = accepted(frame)
    expect(message).toEqual({ t: 'net.data', ch: 'c1', data: 'QUJD' })
  })
})

describe('create', () => {
  it('accepts a request that names nothing at all', () => {
    // The common case, and the whole reason every field is optional: a phone
    // that knows nothing about the Mac can still start work on it.
    expect(accepted({ t: 'create' })).toEqual({ t: 'create' })
  })

  it('refuses a folder that is not a usable string', () => {
    for (const cwd of ['', 7, null, true, {}, []]) {
      expect(refused({ t: 'create', cwd }, JSON.stringify(cwd)).code).toBe('bad-message')
    }
  })

  it('carries the provider, which is the field it used to drop on the floor', () => {
    /*
     * The regression test for the bug this field exists to close. The
     * desktop-to-desktop client had been sending `provider` since it was
     * written; this parser copied across the fields it knew and dropped the rest
     * without a word, so a request for `shell` reached the far machine as a
     * request for nothing and came back as a `claude` session — measured on a
     * real Windows PC.
     *
     * `toEqual` is the whole assertion: it fails if the field is dropped, and it
     * fails if the parser invents a value for a request that named none.
     */
    expect(accepted({ t: 'create', provider: 'shell' })).toEqual({ t: 'create', provider: 'shell' })
    expect(accepted({ t: 'create' })).toEqual({ t: 'create' })
  })

  it('refuses a provider that is not shaped like an agent name', () => {
    // Shape only — this parser does not hold the provider table. What it refuses
    // is anything that is not a bare identifier, because the value ends up
    // selecting a command to run and every trimming rule turns a hostile string
    // into a *different* legal-looking one.
    for (const provider of ['', 7, null, true, {}, [], 'Claude', '../claude', 'a b', 'claude\n', '-x']) {
      expect(refused({ t: 'create', provider }, JSON.stringify(provider)).code).toBe('bad-message')
    }
  })

  it('caps the provider name', () => {
    const atCap = 'a'.repeat(MAX_PROVIDER_LENGTH)
    expect(accepted({ t: 'create', provider: atCap })).toEqual({ t: 'create', provider: atCap })
    expect(refused({ t: 'create', provider: `${atCap}a` }).code).toBe('too-large')
  })

  it('does not decide whether the desktop has that agent', () => {
    // A name this desktop cannot start is a *refusal with a sentence* from
    // `session-create.ts`, not a closed socket from here. Closing the socket
    // over a typo would tell the person holding the phone nothing at all, so a
    // plausible-looking name that no desktop has must still parse.
    expect(accepted({ t: 'create', provider: 'nosuchagent' })).toEqual({
      t: 'create',
      provider: 'nosuchagent',
    })
  })

  it('refuses a control byte in a path rather than stripping it', () => {
    // A path is compared against a list and then handed to a process.
    // Stripping would turn a hostile value into a *different* legal-looking
    // path, which is the worse failure — unlike a device name, which is only
    // ever read. Built from char codes rather than written literally: a raw
    // control byte in source is invisible in every diff and every editor.
    for (const code of [0x00, 0x09, 0x0a, 0x0d, 0x1b, 0x7f, 0x9b]) {
      const cwd = `/tmp/a${String.fromCharCode(code)}b`
      expect(refused({ t: 'create', cwd }, `U+${code.toString(16)}`).code).toBe('bad-message')
    }
    // A space is not a control byte, and plenty of real folders have one.
    const spaced = '/Users/apple/My Projects'
    expect(accepted({ t: 'create', cwd: spaced })).toEqual({ t: 'create', cwd: spaced })
  })

  it('caps the path in bytes, not characters', () => {
    const atCap = `/${'a'.repeat(MAX_CWD_BYTES - 1)}`
    expect(accepted({ t: 'create', cwd: atCap })).toEqual({ t: 'create', cwd: atCap })
    expect(refused({ t: 'create', cwd: `${atCap}a` }).code).toBe('too-large')
    // 512 emoji are 1,024 UTF-16 units and 2,048 UTF-8 bytes; a length check
    // alone would wave this through at twice the cap.
    expect(refused({ t: 'create', cwd: '\u{1f600}'.repeat(MAX_CWD_BYTES / 2) }).code).toBe('too-large')
  })

  it('takes both sizes or neither, never one', () => {
    expect(refused({ t: 'create', cols: 80 }).code).toBe('bad-message')
    expect(refused({ t: 'create', rows: 24 }).code).toBe('bad-message')
    expect(accepted({ t: 'create', cols: 80, rows: 24 })).toEqual({ t: 'create', cols: 80, rows: 24 })
  })

  it('holds a size to the same range an attach is held to', () => {
    for (const [cols, rows] of [
      [MIN_COLS - 1, 24],
      [MAX_COLS + 1, 24],
      [80, MIN_ROWS - 1],
      [80, MAX_ROWS + 1],
      [NaN, 24],
      [80, Infinity],
      [80.5, 24],
    ]) {
      expect(refused({ t: 'create', cols, rows }, `${cols}x${rows}`).code).toBe('bad-message')
    }
  })

  it('does not decide whether the Mac will use the folder', () => {
    // Shape only. A path that satisfies this parser is a plausible path and
    // nothing more — `session-create.ts` answers whether this desktop offers
    // it, against the desktop's real project list.
    const cwd = '/definitely/not/a/folder/on/this/machine'
    expect(accepted({ t: 'create', cwd })).toEqual({ t: 'create', cwd })
  })

  it('reads the folder once, so a getter cannot swap it after the checks', () => {
    let reads = 0
    const frame = {
      t: 'create',
      get cwd(): string {
        reads += 1
        return reads === 1 ? '/tmp/ok' : `/${'x'.repeat(MAX_CWD_BYTES)}`
      },
    }
    expect(accepted(frame)).toEqual({ t: 'create', cwd: '/tmp/ok' })
  })
})

describe('upload', () => {
  const begin = (patch: Record<string, unknown>): Record<string, unknown> => ({
    t: 'upload.begin',
    id: 'up-1',
    name: 'photo.jpg',
    size: 1024,
    ...patch,
  })

  it('refuses a name that is missing, empty or oversized', () => {
    refused(begin({ name: undefined }), 'no name')
    refused(begin({ name: '' }), 'empty name')
    refused(begin({ name: 42 }), 'numeric name')
    expect(refused(begin({ name: 'a'.repeat(MAX_UPLOAD_NAME_BYTES + 1) }), 'long name').code).toBe('too-large')
  })

  it('counts the name in bytes, so an emoji name is not four times the cap', () => {
    // 64 four-byte code points are 256 bytes and 128 UTF-16 units. A length
    // check would wave this through and the file would be unopenable.
    expect(refused(begin({ name: '🙂'.repeat(64) }), 'emoji name').code).toBe('too-large')
    expect(accepted(begin({ name: '🙂'.repeat(63) }), 'emoji name just under')).toMatchObject({
      name: '🙂'.repeat(63),
    })
  })

  it('refuses a control byte in a name rather than stripping it', () => {
    // Stripping would turn a hostile value into a *different* legal-looking
    // name, which is the worse failure — the same argument `create.cwd` makes.
    for (const name of ['pho\u0000to.jpg', 'photo\n.jpg', 'photo\u001b[2J.jpg']) {
      expect(refused(begin({ name }), name).code).toBe('bad-message')
    }
  })

  it('does not decide what the name becomes on disk', () => {
    // Shape only. `safeName` in `uploads.ts` is what reduces this to one path
    // component, against a real directory. A parser that answered the question
    // would be the most dangerous kind of wrong.
    const name = '../../etc/passwd'
    expect(accepted(begin({ name }))).toEqual({ t: 'upload.begin', id: 'up-1', name, size: 1024 })
  })

  it('refuses a size that is zero, negative, fractional or past the ceiling', () => {
    for (const size of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, null, '1024', MAX_UPLOAD_BYTES + 1]) {
      refused(begin({ size }), `size ${String(size)}`)
    }
    expect(accepted(begin({ size: MAX_UPLOAD_BYTES }))).toMatchObject({ size: MAX_UPLOAD_BYTES })
  })

  it('refuses payload that is not base64, rather than decoding what it can', () => {
    // Same rule as `net.data`, and for a sharper reason: a chunk `Buffer` half
    // decoded is a byte missing from the middle of somebody's video.
    for (const data of ['not base64!', 'AAA', 'AA=A', 'AAAA\n', 12, null]) {
      refused({ t: 'upload.data', id: 'up-1', data }, `data ${String(data)}`)
    }
  })

  it('caps a chunk at the encoded length of the raw limit', () => {
    const fits = 'A'.repeat(MAX_UPLOAD_DATA_CHARS)
    expect(accepted({ t: 'upload.data', id: 'up-1', data: fits })).toMatchObject({ data: fits })
    expect(refused({ t: 'upload.data', id: 'up-1', data: 'A'.repeat(MAX_UPLOAD_DATA_CHARS + 4) }).code).toBe(
      'too-large',
    )
  })

  it('insists on a whole hex digest and lower-cases it', () => {
    const digest = 'AB'.repeat(SHA256_HEX_LENGTH / 2)
    expect(accepted({ t: 'upload.end', id: 'up-1', sha256: digest })).toEqual({
      t: 'upload.end',
      id: 'up-1',
      // Lower-cased here so the comparison against `digest('hex')` can be `===`.
      sha256: digest.toLowerCase(),
    })
    for (const bad of ['', 'z'.repeat(SHA256_HEX_LENGTH), 'a'.repeat(SHA256_HEX_LENGTH - 1), 42, null]) {
      refused({ t: 'upload.end', id: 'up-1', sha256: bad }, `digest ${String(bad)}`)
    }
  })

  it('shape-checks the upload id like every other id', () => {
    for (const frame of [
      { t: 'upload.begin', id: '../x', name: 'a.jpg', size: 1 },
      { t: 'upload.data', id: '', data: 'AAAA' },
      { t: 'upload.end', id: 'a b', sha256: 'a'.repeat(SHA256_HEX_LENGTH) },
      { t: 'upload.cancel', id: 42 },
    ]) {
      refused(frame, String(frame.t))
    }
  })

  it('reads the name once, so a getter cannot swap it after the checks', () => {
    let reads = 0
    const frame = {
      t: 'upload.begin',
      id: 'up-1',
      size: 1024,
      get name(): string {
        reads += 1
        return reads === 1 ? 'photo.jpg' : 'x'.repeat(MAX_UPLOAD_NAME_BYTES + 1)
      },
    }
    expect(accepted(frame)).toMatchObject({ name: 'photo.jpg' })
  })
})
