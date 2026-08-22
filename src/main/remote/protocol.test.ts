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
  MAX_UPLOAD_DIR_BYTES,
  MAX_UPLOAD_NAME_BYTES,
  MAX_ANNOUNCED_SESSIONS,
  MAX_WINDOW_HOLDS,
  NET_WINDOW_BYTES,
  SHA256_HEX_LENGTH,
  OUTPUT_CHUNK_BYTES,
  CONTROL_IDS,
  MAX_WINDOW_ARGS_BYTES,
  MAX_WINDOW_RESULT_BYTES,
  PROTOCOL_ERROR_CODES,
  PROTOCOL_VERSION,
  chunkInput,
  chunkOutput,
  parseClientMessage,
  parseServerMessage,
  serialize,
  type ClientMessage,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from './protocol'
// Type-only, so this test does not drag a terminal emulator into the protocol
// suite. The pin below is what it is for.
import type { ControlId } from '../agent-controls'

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
const DEVICE_ID = 'd2b7f4a1-0c3e-4a9b-8e11-6f5a2c9d1b04'
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
  close: true,
  ports: true,
  'tunnel.open': true,
  'tunnel.close': true,
  'net.open': true,
  'net.data': true,
  'net.ack': true,
  'net.close': true,
  'web.open': true,
  'upload.begin': true,
  'upload.data': true,
  'upload.end': true,
  'upload.cancel': true,
  'credential.ack': true,
  'credential.answer': true,
  'credential.deny': true,
  'dev.status': true,
  'dev.start': true,
  'copilot.hello': true,
  'copilot.bye': true,
  'copilot.answer': true,
  'copilot.attach': true,
  'copilot.detach': true,
  'copilot.state': true,
  'copilot.sessions': true,
  'copilot.log': true,
  'copilot.pending': true,
  'copilot.start': true,
  'copilot.say': true,
  'copilot.cancel': true,
  'copilot.stop': true,
  'controls.read': true,
  'controls.apply': true,
  'usage.read': true,
  'session.send': true,
  'account.read': true,
  'account.switch': true,
  'logins.read': true,
  'logins.signin': true,
  'chat.read': true,
  'devices.list': true,
  'devices.revoke': true,
  'window.result': true,
  'window.holds': true,
  'window.call': true,
  'sessions.mine': true,
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
  closed: true,
  folders: true,
  ports: true,
  'tunnel.opened': true,
  'web.opened': true,
  'tunnel.closed': true,
  'net.data': true,
  'net.ack': true,
  'net.close': true,
  'upload.ready': true,
  'upload.ack': true,
  'upload.done': true,
  'upload.failed': true,
  'credential.request': true,
  'dev.state': true,
  'copilot.state': true,
  'copilot.chat': true,
  'copilot.tool': true,
  'copilot.sessions': true,
  'copilot.log': true,
  'copilot.pending': true,
  'copilot.grant': true,
  'copilot.ask': true,
  'copilot.settled': true,
  'controls.reading': true,
  'controls.applied': true,
  'usage.reading': true,
  'account.state': true,
  'account.switched': true,
  'logins.state': true,
  'logins.signedin': true,
  'session.sent': true,
  'devices.rows': true,
  'devices.revoked': true,
  'devices.changed': true,
  'chat.rows': true,
  'window.call': true,
  'window.holds': true,
  'window.result': true,
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
  // `create`'s opposite number. An id and nothing else — no signal, no force
  // flag, no reason string — because none of those are a phone's to choose.
  { t: 'close', id: SESSION_ID },
  { t: 'ports' },
  { t: 'tunnel.open', id: 'tun-1', port: 3000 },
  // The verb behind "open it on the machine" — the thing a browser tab cannot do
  // for itself, and the whole of what the web client's localhost screen was
  // missing.
  { t: 'web.open', url: 'http://localhost:5173/' },
  { t: 'tunnel.close', id: 'tun-1' },
  { t: 'net.open', ch: 'c1', tunnel: 'tun-1' },
  { t: 'net.data', ch: 'c1', data: Buffer.from('GET / HTTP/1.1\r\n\r\n').toString('base64') },
  { t: 'net.ack', ch: 'c1', bytes: 1448 },
  { t: 'net.close', ch: 'c1' },
  { t: 'upload.begin', id: 'up-1', name: 'IMG_4823.HEIC', size: 3_145_728 },
  // The same frame with a destination on it: a browser download being delivered
  // to a folder on the far machine rather than to its downloads folder.
  {
    t: 'upload.begin',
    id: 'up-2',
    name: 'report.pdf',
    size: 4096,
    dir: '/Users/asad/Projects/site',
  },
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
  { t: 'dev.status', folder: '/Users/apple/Projects/terminaldeck' },
  { t: 'dev.start', folder: '/Users/apple/Projects/terminaldeck' },
  // The copilot surface. Nine of the fourteen carry nothing at all, which is
  // the property `copilot-frames.test.ts` pins as text: a device names no tool,
  // no session and no path, so there is nothing in these frames to be careless
  // with. The five that carry something are a code, a credential, a decision, a
  // sentence and a log cursor — none of them a tool.
  //
  // The two that open and close it. They carry no tier and cannot: the tiers
  // are read off the connection these very frames establish. `copilot.hello`
  // carries nothing at all since 2026-08-19 — there is no copilot code and no
  // credential, because a device's kind is the authorisation.
  { t: 'copilot.hello' },
  { t: 'copilot.bye' },
  // Answering a confirmation. `approved` is a required boolean and only a
  // literal `true` is yes — a client whose wiring sent `undefined` must not have
  // it read as approval.
  { t: 'copilot.answer', id: '9f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5', approved: true },
  { t: 'copilot.answer', id: '9f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5', approved: false },
  { t: 'copilot.attach' },
  { t: 'copilot.detach' },
  { t: 'copilot.state' },
  { t: 'copilot.sessions' },
  { t: 'copilot.pending' },
  { t: 'copilot.log' },
  { t: 'copilot.log', limit: 50 },
  { t: 'copilot.log', limit: 50, before: '9f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5' },
  { t: 'copilot.start' },
  { t: 'copilot.say', text: 'which of my sessions is stuck?' },
  { t: 'copilot.cancel' },
  { t: 'copilot.stop' },
  // The controls a remote session's bar is drawn from. `rid` is the client's
  // own request id and the host echoes it untouched, which is what lets two
  // panes of a split ask about the same session without resolving each other's
  // answers.
  { t: 'controls.read', rid: 'ctl-1', id: SESSION_ID },
  // Every control, because each one composes a different command on the far
  // end. The values are the ones the CLI actually accepts — a model name with a
  // dot and a hyphen in it is the awkward shape, and it has to survive.
  { t: 'controls.apply', rid: 'ctl-2', id: SESSION_ID, control: 'model', value: 'opus-4-1' },
  { t: 'controls.apply', rid: 'ctl-3', id: SESSION_ID, control: 'effort', value: 'xhigh' },
  { t: 'controls.apply', rid: 'ctl-4', id: SESSION_ID, control: 'fast', value: 'on' },
  { t: 'controls.apply', rid: 'ctl-5', id: SESSION_ID, control: 'permission', value: 'plan' },
  // The usage bar's two figures, and all three `want`s, because the word is
  // what decides the cost on the far machine: `plan` and `context` read memory
  // and a file, and `refresh` boots a whole agent CLI there. `force` is a person
  // pressing rather than this app looking, and it must survive both ways — a
  // `force` that arrived as `false` when it was sent as `true` is a retry button
  // that silently does nothing.
  { t: 'usage.read', rid: 'use-1', id: SESSION_ID, want: 'plan', force: false },
  { t: 'usage.read', rid: 'use-2', id: SESSION_ID, want: 'refresh', force: true },
  { t: 'usage.read', rid: 'use-3', id: SESSION_ID, want: 'context', force: false },
  // Typing into a session without attaching to it. The same bytes `input`
  // carries — control characters included, because what this ends up doing is
  // the same `SessionAccess.write` — with a `rid` on the front, because unlike
  // `input` it is answered and two panels sending to two sessions on one
  // machine must not resolve each other's answers.
  { t: 'session.send', rid: 'snd-1', id: SESSION_ID, data: 'look at this button\r' },
  // Whose login a session is on, and running it as another one. The second is
  // the frame that stops a process and starts another, so its account id goes
  // through the same slug class a config directory's name has always been.
  { t: 'account.read', rid: 'acc-1', id: SESSION_ID },
  { t: 'account.switch', rid: 'acc-2', id: SESSION_ID, accountId: 'work-example-com' },
  // An agent's own install, whose id `systemProfileId` writes with a colon in
  // it. On every machine this app has ever run on, so a class that refused it
  // would refuse the one row that is always there.
  { t: 'account.switch', rid: 'acc-3', id: SESSION_ID, accountId: 'system:codex' },
  // The machine's own list, with no session in the question — the frame a
  // settings pane sends about a computer rather than about a terminal — and
  // signing one of those logins in over there.
  { t: 'logins.read', rid: 'lgn-1' },
  { t: 'logins.signin', rid: 'lgn-2', accountId: 'system:codex' },
  // The conversation, and the same view asking what has changed since.
  { t: 'chat.read', rid: 'cht-1', id: SESSION_ID, tail: false },
  { t: 'chat.read', rid: 'cht-2', id: SESSION_ID, tail: true },
  { t: 'devices.list', rid: 'dev-1' },
  { t: 'devices.revoke', rid: 'dev-2', device: DEVICE_ID },
  { t: 'window.result', id: 'win-1', ok: true, body: '{"url":"https://example.com"}' },
  { t: 'window.result', id: 'win-2', ok: false, body: '{"message":"no window by that name"}' },
  // Which of that machine's sessions this client is holding a browser window
  // for. The whole set every time, empty included: that is how a detach travels.
  { t: 'window.holds', sessions: [SESSION_ID] },
  { t: 'window.holds', sessions: [] },
  // And the mirror: a client with the pty asking the host, which is the one
  // holding the window. Same frame, opposite direction — see `WindowCallFrame`.
  { t: 'window.call', id: 'win-3', session: SESSION_ID, tool: 'browser.read', args: '{}' },
  // And the list that makes that mirror reachable: what is running on the
  // client's own computer, so the host can put a window beside one of them.
  // Written out rather than referring to `SESSION` below, which is declared
  // after this array and would be in its temporal dead zone here.
  {
    t: 'sessions.mine',
    sessions: [
      {
        id: SESSION_ID,
        title: 'terminaldeck',
        cwd: '/Users/apple/Projects/terminaldeck',
        provider: 'claude',
        status: 'working',
        exitCode: null,
      },
    ],
  },
  // Nothing running is a real answer and has exactly one spelling. It is also
  // how a device that closed its last terminal takes its rows out of the
  // picker.
  { t: 'sessions.mine', sessions: [] },
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
  { t: 'web.opened', url: 'http://localhost:5173/' },
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
  // The answer to one `session.send`, both ways round. The refusal is a frame
  // rather than an `error` on purpose — an `error` carries no `rid`, so it
  // could not be matched to the request that caused it, and the panel waiting
  // on that promise would sit out its own deadline over a refusal the host had
  // already decided.
  { t: 'session.sent', rid: 'snd-1', id: SESSION_ID, ok: true, message: 'Sent.' },
  { t: 'session.sent', rid: 'snd-2', id: SESSION_ID, ok: false, message: `No session ${SESSION_ID} is running.` },
  { t: 'devices.rows', rid: 'dev-1', devices: [] },
  {
    t: 'devices.rows',
    rid: 'dev-2',
    devices: [
      {
        id: DEVICE_ID,
        name: 'iPhone',
        kind: 'mine',
        status: 'approved',
        addedAt: 1_760_000_000_000,
        lastSeenAt: 1_760_000_500_000,
        connected: true,
        fingerprint: 'aa bb cc dd ee ff',
      },
      {
        id: 'c1a0f9e2-3b4c-4d5e-8f60-71829a3b4c5d',
        name: 'Nexus',
        kind: 'guest',
        status: 'pending',
        addedAt: 1_760_000_100_000,
        lastSeenAt: null,
        connected: false,
        fingerprint: null,
      },
    ],
  },
  { t: 'devices.revoked', rid: 'dev-3', ok: true, message: 'That device was removed.', devices: [] },
  { t: 'devices.revoked', rid: 'dev-4', ok: false, message: 'That device is not signed in here.', devices: [] },
  { t: 'devices.changed', devices: [] },
  {
    t: 'chat.rows',
    rid: 'cht-1',
    id: SESSION_ID,
    rows: [
      { id: 'm-1', role: 'you', text: 'what does this repo do', at: 1_787_000_000_000 },
      { id: 'm-2', role: 'agent', text: 'It is an Electron app.', at: 1_787_000_001_000 },
    ],
    reset: true,
    found: true,
  },
  // A folder with no transcript at all, which is not the same empty as a
  // session that has not spoken yet.
  { t: 'chat.rows', rid: 'cht-2', id: SESSION_ID, rows: [], reset: true, found: false },
  { t: 'window.call', id: 'win-1', session: SESSION_ID, tool: 'browser.read', args: '{}' },
  // The other direction of the same three frames: a host that holds the window
  // saying which of this client's sessions it holds one for, and answering the
  // client's ask.
  { t: 'window.holds', sessions: [SESSION_ID] },
  { t: 'window.holds', sessions: [] },
  { t: 'window.result', id: 'win-4', ok: true, body: '{"url":"https://example.com"}' },
  { t: 'window.result', id: 'win-5', ok: false, body: '{"message":"no window by that name"}' },
  { t: 'pong' },
  { t: 'created', session: SESSION },
  { t: 'closed', id: SESSION_ID },
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
  // The five dev-server states, because a client has to draw all five and the
  // serialiser has to carry the fields each one sets. `ready` is the one that
  // matters: `port` and `url` appear on it and on nothing else.
  { t: 'dev.state', state: { folder: '/Users/apple/Projects/x', status: 'no-dev-script' } },
  {
    t: 'dev.state',
    state: { folder: '/Users/apple/Projects/x', status: 'idle', script: 'dev', command: 'pnpm run dev' },
  },
  {
    t: 'dev.state',
    state: {
      folder: '/Users/apple/Projects/x',
      status: 'starting',
      script: 'dev',
      command: 'pnpm run dev',
      sessionId: SESSION_ID,
      note: 'VITE v7.1.0  ready in 412 ms',
    },
  },
  {
    t: 'dev.state',
    state: {
      folder: '/Users/apple/Projects/x',
      status: 'ready',
      script: 'dev',
      command: 'pnpm run dev',
      sessionId: SESSION_ID,
      port: 5173,
      url: 'http://localhost:5173',
    },
  },
  {
    t: 'dev.state',
    state: {
      folder: '/Users/apple/Projects/x',
      status: 'failed',
      script: 'dev',
      command: 'pnpm run dev',
      sessionId: SESSION_ID,
      message: 'Nothing accepted a connection within 90 seconds.',
    },
  },
  // The copilot surface, outbound. `welcome.copilot` is covered by the extra
  // `welcome` below rather than here, because a `welcome` carrying it and one
  // not carrying it are two frames a client has to survive.
  {
    t: 'copilot.state',
    state: {
      desk: 'running',
      run: 'run-1',
      profile: 'Personal',
      signedIn: true,
      tools: 14,
      turnTokens: 2200,
      pending: 0,
      grant: { read: true, act: false, alter: false },
      available: true,
      reason: null,
    },
  },
  {
    t: 'copilot.chat',
    run: 'run-1',
    messages: [{ id: 'm1', role: 'you', text: 'anything stuck?', at: 1_700_000_000_000 }],
  },
  {
    t: 'copilot.chat',
    run: 'run-1',
    reset: true,
    messages: [{ id: 'm2', role: 'agent', text: 'Session 3 has been…', at: 0, truncated: true }],
  },
  {
    t: 'copilot.tool',
    row: {
      id: 'row-1',
      at: '2026-08-17T09:00:00.000Z',
      tool: 'settings.write',
      tier: 'alter',
      outcome: 'refused',
      detail: 'Change a setting — refused (not-granted)',
      refusal: 'not-granted',
      deviceId: 'dev-1',
    },
  },
  {
    t: 'copilot.sessions',
    sessions: [
      {
        id: SESSION_ID,
        title: 'terminaldeck',
        cwd: '/Users/apple/Projects/terminaldeck',
        provider: 'claude',
        status: 'working',
        startedAt: 1_700_000_000_000,
        originRunId: 'row-1',
      },
    ],
  },
  { t: 'copilot.log', rows: [], more: false },
  {
    t: 'copilot.pending',
    questions: [
      {
        id: 'q-1',
        tool: 'settings.write',
        summary: 'Change theme to dark',
        requestedAt: 1_700_000_000_000,
        expiresAt: 1_700_000_120_000,
        mine: false,
      },
    ],
  },
  {
    t: 'copilot.grant',
    link: { linked: false, open: false, grant: { read: false, act: false, alter: false } },
  },
  {
    t: 'copilot.grant',
    link: { linked: true, open: true, grant: { read: true, act: true, alter: true } },
  },
  {
    // The frame with the arguments in it, and the only one that has them. A
    // device that may answer needs the value that will actually be written or
    // the prompt is a shape rather than a decision.
    t: 'copilot.ask',
    question: {
      id: 'q-1',
      tool: 'settings.write',
      tier: 'alter',
      summary: 'Change the density to compact',
      args: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
      origin: 'device:dev-1',
      requestedAt: 1_700_000_000_000,
      expiresAt: 1_700_000_120_000,
    },
  },
  {
    // `by` is the point of this frame: first answer wins, and the surface that
    // loses withdraws its dialog *saying where it went* rather than vanishing.
    t: 'copilot.settled',
    settled: { id: 'q-1', granted: true, by: 'device:dev-1', reason: null },
  },
  // A `welcome` carrying the per-device copilot grant. Separate from the one at
  // the top of this list because both shapes are on the wire at once: a desktop
  // older than the field sends no key, and a client has to be right about both.
  {
    t: 'welcome',
    protocol: PROTOCOL_VERSION,
    deviceId: 'dev-1',
    deviceName: 'iPhone',
    token: null,
    sessions: [],
    capabilities: CAPABILITIES,
    // `open` is false on every welcome, always: a session channel does not carry
    // the copilot by existing, and the client sends `copilot.hello` to open it.
    copilot: { linked: true, open: false, grant: { read: true, act: true, alter: true } },
  },
  // The controls coming back. Every field of a reading has a "nothing was read"
  // value and both shapes are on this wire at once: a session the far end could
  // read four things off, and one it could read none off — which is what a plain
  // shell honestly answers, and it must survive as nulls rather than as a
  // confident guess.
  {
    t: 'controls.reading',
    rid: 'ctl-1',
    id: SESSION_ID,
    reading: {
      model: { value: 'Opus 5', label: 'Opus 5', source: 'screen' },
      effort: { value: 'xhigh', label: 'Extra high', source: 'settings' },
      fast: { value: 'off', label: 'Off', source: 'screen', unavailableReason: 'Fast mode requires usage credits' },
      permission: { value: 'plan', label: 'Plan', source: 'screen' },
      live: true,
      agent: { running: true, saw: 'Claude Code v2.1.234' },
      gate: { canType: true, reason: null },
    },
  },
  {
    t: 'controls.reading',
    rid: 'ctl-2',
    id: SESSION_ID,
    reading: {
      model: { value: null, label: null, source: null },
      effort: { value: null, label: null, source: null },
      fast: { value: null, label: null, source: null },
      permission: { value: null, label: null, source: null },
      live: true,
      agent: { running: false, saw: null },
      gate: { canType: false, reason: 'This session is mid-turn.' },
    },
  },
  // And the answer to a change. Both outcomes, because the failing one is the
  // frame that matters: it carries the far end's own sentence, which is the only
  // thing that tells somebody what to do about a refusal.
  {
    t: 'controls.applied',
    rid: 'ctl-3',
    id: SESSION_ID,
    ok: true,
    message: 'Model is now Sonnet 5 — saved as your default for new sessions.',
    reading: { value: 'Sonnet 5', label: 'Sonnet 5', source: 'screen' },
  },
  {
    t: 'controls.applied',
    rid: 'ctl-4',
    id: SESSION_ID,
    ok: false,
    message: 'Mythos 5 isn’t available for your account yet.',
    reading: { value: null, label: null, source: null },
  },
  // The usage readings coming back. Both shapes are on this wire at once: a
  // machine that had something to report, and one that had nothing and said why
  // — which is what an older host degrades to, and it must survive as a sentence
  // rather than as an empty reading somebody would draw as a zero.
  {
    t: 'usage.reading',
    rid: 'use-1',
    id: SESSION_ID,
    want: 'plan',
    answer: {
      reading: {
        sessionId: SESSION_ID,
        readings: [],
        reason: 'Claude Code has not printed a plan-limit line in this session yet.',
        account: null,
        assembledAt: 1_755_000_000_000,
      },
    },
  },
  {
    t: 'usage.reading',
    rid: 'use-3',
    id: SESSION_ID,
    want: 'context',
    answer: {
      reading: null,
      unavailableReason: 'That machine is running a build that cannot report a context window from here.',
    },
  },
  // The account list, and the outcome of changing one. `session` is the id the
  // session has *now*: the same one on a refusal, a new one on a success,
  // because a switch replaces the process.
  {
    t: 'account.state',
    rid: 'acc-1',
    id: SESSION_ID,
    current: { id: 'work-example-com', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
    accounts: [
      { id: 'work-example-com', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
      { id: 'system-claude', name: 'Claude Code', provider: 'claude', color: null, system: true },
    ],
  },
  {
    t: 'account.switched',
    rid: 'acc-2',
    id: SESSION_ID,
    ok: true,
    message: 'Running as work@example.com.',
    session: '9a2f77d7-c0a1-4b3e-8f1d-4f1c2ae08f1d',
  },
  // The machine's list, with no `current` in it: there is no session in the
  // question, so there is nothing that could be running.
  {
    t: 'logins.state',
    rid: 'lgn-1',
    accounts: [
      { id: 'work-example-com', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
    ],
  },
  // And the terminal that machine opened so the login can be finished on it.
  {
    t: 'logins.signedin',
    rid: 'lgn-2',
    ok: true,
    message: 'A terminal is open on that machine; finish the login in it.',
    session: '9a2f77d7-c0a1-4b3e-8f1d-4f1c2ae08f1d',
  },
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

/**
 * The wire's list of controls and the module that performs them name the same
 * four things.
 *
 * Two copies exist on purpose — `agent-controls.ts` reaches Electron and the
 * CLI's screen readers, and `protocol.ts` is bundled for a plain-Node host and
 * for the PWA — so nothing but a test can stop them drifting. It fails two ways,
 * which is the point: the record fails to *compile* if `ControlId` gains a name,
 * and the comparison fails at *run time* if `CONTROL_IDS` does. A control added
 * to one and not the other is a menu row the far end refuses with "unknown
 * control", which reads as the feature being broken.
 */
const CONTROL_PIN: Record<ControlId, true> = { model: true, effort: true, fast: true, permission: true }

describe('the controls capability', () => {
  it('names the same four controls agent-controls.ts performs', () => {
    expect(new Set<string>(CONTROL_IDS)).toEqual(new Set(Object.keys(CONTROL_PIN)))
  })
})

describe('the account capability', () => {
  /*
   * The id on this frame selects a **configuration directory on somebody else's
   * computer**, and the frame that carries it ends in a process being stopped
   * and another started. So the class is checked here at the parser rather than
   * three files away, and the two ends of it are what these cases are about: a
   * slug is accepted, an agent's own install — which has a colon in it and is on
   * every machine — is accepted, and anything that could climb out of a
   * directory name is not.
   */
  it('takes a slug and an agent’s own install, and nothing that could be a path', () => {
    const base = { t: 'account.switch', rid: 'acc-9', id: SESSION_ID }
    expect(accepted(serialize({ ...base, accountId: 'work-example-com' } as ClientMessage))).toBeTruthy()
    expect(accepted(serialize({ ...base, accountId: 'system:gemini' } as ClientMessage))).toBeTruthy()

    for (const bad of ['../escape', 'a/b', 'a\\b', '.hidden', '', 'x'.repeat(300)]) {
      const result = parseClientMessage({ ...base, accountId: bad })
      expect(result.ok, `account id ${JSON.stringify(bad)} was accepted`).toBe(false)
    }
  })

  it('refuses a read or a switch with nothing to correlate or nothing to act on', () => {
    expect(parseClientMessage({ t: 'account.read', id: SESSION_ID }).ok).toBe(false)
    expect(parseClientMessage({ t: 'account.read', rid: 'acc-1' }).ok).toBe(false)
    expect(parseClientMessage({ t: 'account.switch', rid: 'acc-1', id: SESSION_ID }).ok).toBe(false)
  })

  /*
   * The machine-scoped pair, whose whole distinction from the two above is that
   * they carry no session — so the thing worth pinning is that they are not
   * quietly *required* to, and that the id they do carry goes through the same
   * class a configuration directory has always gone through.
   */
  it('reads a machine’s logins with no session in the question, and still guards the account id', () => {
    expect(parseClientMessage({ t: 'logins.read', rid: 'lgn-1' }).ok).toBe(true)
    expect(parseClientMessage({ t: 'logins.read' }).ok).toBe(false)
    expect(parseClientMessage({ t: 'logins.signin', rid: 'lgn-2' }).ok).toBe(false)
    expect(parseClientMessage({ t: 'logins.signin', rid: 'lgn-2', accountId: 'system:codex' }).ok).toBe(true)
    for (const bad of ['../escape', 'a/b', 'a\\b', '.hidden', '', 'x'.repeat(300)]) {
      const result = parseClientMessage({ t: 'logins.signin', rid: 'lgn-2', accountId: bad })
      expect(result.ok, `account id ${JSON.stringify(bad)} was accepted`).toBe(false)
    }
  })

  it('reads an empty login list as an answer, and a sign-in that opened nothing as null', () => {
    const empty = parseServerMessage(JSON.stringify({ t: 'logins.state', rid: 'lgn-1', accounts: [] }))
    if (!empty.ok || empty.message.t !== 'logins.state') throw new Error('unreachable')
    // A machine with nothing signed in, which is not the same fact as a read
    // that failed — that one arrives as an `error` frame.
    expect(empty.message.accounts).toEqual([])

    const refused = parseServerMessage(
      JSON.stringify({ t: 'logins.signedin', rid: 'lgn-2', ok: false, message: 'No such login here.' }),
    )
    if (!refused.ok || refused.message.t !== 'logins.signedin') throw new Error('unreachable')
    expect(refused.message.ok).toBe(false)
    expect(refused.message.session).toBeNull()
  })

  it('drops an account row a menu could not draw, and keeps the rest', () => {
    /*
     * An id and a name are the two fields a row cannot exist without — the id is
     * what a press sends back, the name is what a person reads — so a record
     * missing either is not a half-row. Everything else folds onto null rather
     * than onto a plausible value: a mark or a colour invented here is this app
     * asserting something the other machine never said.
     */
    const frame = parseServerMessage(
      JSON.stringify({
      t: 'account.state',
      rid: 'acc-1',
      id: SESSION_ID,
      current: { id: 'work' },
      accounts: [
        { id: 'work', name: 'work@example.com' },
        { id: 'nameless' },
        { name: 'idless' },
        'not a row',
      ],
      }),
    )
    expect(frame.ok).toBe(true)
    if (!frame.ok || frame.message.t !== 'account.state') throw new Error('unreachable')
    // `current` carried no name, so there is nothing to draw and nothing is claimed.
    expect(frame.message.current).toBeNull()
    expect(frame.message.accounts).toEqual([
      { id: 'work', name: 'work@example.com', provider: null, color: null, system: false },
    ])
  })

  /**
   * Who each login is, which is the half that was not on this wire.
   *
   * Without it the chip over a remote session had only the account's *name* to
   * print, and for the machine's own install that name is the key
   * `systemProfileId` generates — so it printed `Default` over a session whose
   * own terminal three lines below read `sherzod.davlatov@gmail.com`. Asad:
   * *"It is saying default, so never default."*
   */
  it('carries what the far machine’s CLI said about a login, and only the four fields', () => {
    const frame = parseServerMessage(
      JSON.stringify({
        t: 'account.state',
        rid: 'acc-1',
        id: SESSION_ID,
        current: {
          id: 'system',
          name: 'Default',
          signIn: {
            state: 'signed-in',
            account: 'sherzod.davlatov@gmail.com',
            plan: 'max',
            detail: 'Signed in as sherzod.davlatov@gmail.com on the max plan.',
            // Sent by nobody, and dropped here even so: a command line for a
            // shell on the far machine has no reader on this one.
            command: 'claude auth status --json',
          },
        },
        accounts: [],
      }),
    )
    expect(frame.ok).toBe(true)
    if (!frame.ok || frame.message.t !== 'account.state') throw new Error('unreachable')
    expect(frame.message.current?.signIn).toEqual({
      state: 'signed-in',
      account: 'sherzod.davlatov@gmail.com',
      plan: 'max',
      detail: 'Signed in as sherzod.davlatov@gmail.com on the max plan.',
    })
  })

  it('leaves the login absent when the frame said nothing readable about it', () => {
    /*
     * Absent, never a composed "unknown" — the two are different claims. A
     * machine whose build predates the field does not answer this question; a
     * machine that ran the probe and could not tell has answered. Composing the
     * second out of the first is how a build that reports nothing comes to look
     * like a login nobody can read.
     */
    const frame = parseServerMessage(
      JSON.stringify({
        t: 'account.state',
        rid: 'acc-1',
        id: SESSION_ID,
        current: { id: 'work', name: 'work@example.com', signIn: { state: '' } },
        accounts: [{ id: 'other', name: 'other@example.com' }],
      }),
    )
    expect(frame.ok).toBe(true)
    if (!frame.ok || frame.message.t !== 'account.state') throw new Error('unreachable')
    expect(frame.message.current?.signIn).toBeUndefined()
    expect(frame.message.accounts[0]?.signIn).toBeUndefined()
  })

  it('reads a switch that says nothing as a switch that did not happen', () => {
    // `ok` must be the literal `true`. A garbled frame read as success is a
    // window that follows a session id that was never created.
    const frame = parseServerMessage(
      JSON.stringify({ t: 'account.switched', rid: 'acc-2', id: SESSION_ID, ok: 'yes' }),
    )
    expect(frame.ok).toBe(true)
    if (!frame.ok || frame.message.t !== 'account.switched') throw new Error('unreachable')
    expect(frame.message.ok).toBe(false)
    expect(frame.message.session).toBeNull()
  })
})

describe('the connectors on a controls reading', () => {
  it('keeps absent and empty apart, because the chip depends on the difference', () => {
    /*
     * Empty is *"that folder has none"* and absent is *"nobody said"*. Neither
     * draws a chip, but only the first is an answer — and a build older than the
     * field sends neither, which must not be recorded as a folder with no
     * connectors.
     */
    const bare = parseServerMessage(
      JSON.stringify({ t: 'controls.reading', rid: 'ctl-1', id: SESSION_ID, reading: { live: true } }),
    )
    if (!bare.ok || bare.message.t !== 'controls.reading') throw new Error('unreachable')
    expect(bare.message.reading.connectors).toBeUndefined()

    const none = parseServerMessage(
      JSON.stringify({
        t: 'controls.reading',
        rid: 'ctl-1',
        id: SESSION_ID,
        reading: { live: true, connectors: [] },
      }),
    )
    if (!none.ok || none.message.t !== 'controls.reading') throw new Error('unreachable')
    expect(none.message.reading.connectors).toEqual([])
  })

  it('drops a row with no name and reads a missing `enabled` as on', () => {
    // `!== false`, matching `readServers` in the renderer: a row the far end did
    // not flag is a server its own CLI would load.
    const frame = parseServerMessage(
      JSON.stringify({
        t: 'controls.reading',
        rid: 'ctl-1',
        id: SESSION_ID,
        reading: {
          live: true,
          connectors: [{ id: 'user:github', name: 'github' }, { id: 'nameless' }],
        },
      }),
    )
    if (!frame.ok || frame.message.t !== 'controls.reading') throw new Error('unreachable')
    expect(frame.message.reading.connectors).toEqual([
      { id: 'user:github', name: 'github', scope: null, transport: null, enabled: true, disabledReason: null },
    ])
  })
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

/**
 * Typing into a session this connection is not attached to.
 *
 * Both frames are pinned here rather than only in the round trip above, because
 * the interesting half of `session.send` is what it shares with `input` — the
 * same bytes, the same cap, the same pty at the far end — and what it does not,
 * which is the attach. The cap is the part a parser can get wrong quietly: this
 * is the frame a browser panel sends, so the value on it is a page's text rather
 * than a keystroke, and a paste-sized payload is the ordinary case rather than
 * the hostile one.
 */
describe('sending to a session without attaching to it', () => {
  it('parses the client frame with its request id and its bytes intact', () => {
    const data = 'the login button on line 42\r'
    expect(accepted(serialize({ t: 'session.send', rid: 'snd-9', id: SESSION_ID, data }))).toEqual({
      t: 'session.send',
      rid: 'snd-9',
      id: SESSION_ID,
      data,
    })
  })

  it('refuses one with no request id, because the answer could not be routed', () => {
    // Unlike `input`, this frame is answered, and the asking side holds a promise
    // per `rid`. A send with nowhere to put its answer is a spinner.
    expect(refused({ t: 'session.send', id: SESSION_ID, data: 'x' }).code).toBe('bad-message')
    expect(refused({ t: 'session.send', rid: 'snd-9', data: 'x' }).code).toBe('bad-message')
  })

  it('refuses data that is not a string', () => {
    for (const data of [undefined, null, 42, true, {}, ['x'], { toString: 'x' }]) {
      expect(
        refused({ t: 'session.send', rid: 'snd-9', id: SESSION_ID, data }, JSON.stringify(data)).code,
      ).toBe('bad-message')
    }
  })

  it('caps the payload by bytes at the same limit `input` gets', () => {
    // The same cap and not a second one: this ends in the same
    // `SessionAccess.write`, so a bigger allowance here would be a way to paste
    // past `input`'s limit by choosing the other verb.
    const under = 'a'.repeat(MAX_INPUT_BYTES)
    const over = 'a'.repeat(MAX_INPUT_BYTES + 1)
    expect(Buffer.byteLength(under)).toBe(MAX_INPUT_BYTES)
    expect(accepted({ t: 'session.send', rid: 'snd-9', id: SESSION_ID, data: under })).toBeTruthy()
    expect(refused({ t: 'session.send', rid: 'snd-9', id: SESSION_ID, data: over }).code).toBe('too-large')
    // And in bytes rather than units, which is the check a length test waves
    // through: these emoji are half the cap as UTF-16 and over it on the wire.
    const emoji = '😀'.repeat(MAX_INPUT_BYTES / 4 + 1)
    expect(emoji.length).toBeLessThan(MAX_INPUT_BYTES)
    expect(refused({ t: 'session.send', rid: 'snd-9', id: SESSION_ID, data: emoji }).code).toBe('too-large')
  })

  it('does not forward a payload other than the one it measured', () => {
    // The object path, where a property can be a getter. The same defect
    // `input.data` had, on the frame that reaches the same pty.
    const huge = 'A'.repeat(MAX_INPUT_BYTES * 10)
    let reads = 0
    const answers = ['ok', 'ok', huge]
    const frame = {
      t: 'session.send',
      rid: 'snd-9',
      id: SESSION_ID,
      get data(): string {
        return answers[Math.min(reads++, answers.length - 1)]
      },
    }
    const result = parseClientMessage(frame)
    if (result.ok) {
      expect(Buffer.byteLength((result.message as { data: string }).data)).toBeLessThanOrEqual(MAX_INPUT_BYTES)
    }
  })

  it('reads the answer back, and reads only a literal true as success', () => {
    const sent = parseServerMessage(
      serialize({ t: 'session.sent', rid: 'snd-9', id: SESSION_ID, ok: true, message: 'Sent.' }),
    )
    expect(sent.ok && sent.message).toEqual({
      t: 'session.sent',
      rid: 'snd-9',
      id: SESSION_ID,
      ok: true,
      message: 'Sent.',
    })

    // A garbled frame must not read as text that landed in somebody's agent.
    const garbled = parseServerMessage(JSON.stringify({ t: 'session.sent', rid: 'snd-9', id: SESSION_ID }))
    expect(garbled.ok && garbled.message).toMatchObject({ ok: false, message: '' })
  })

  it('refuses an answer that could not be matched to a request', () => {
    for (const frame of [
      { t: 'session.sent', id: SESSION_ID, ok: true, message: 'Sent.' },
      { t: 'session.sent', rid: 'snd-9', ok: true, message: 'Sent.' },
    ]) {
      const result = parseServerMessage(JSON.stringify(frame))
      expect(result.ok).toBe(false)
    }
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

  /*
   * `dir` — the one field on this frame that names a place.
   *
   * The parser's job here is shape and nothing more. Whether the folder may
   * actually be written to is the host's question, answered against the list it
   * published to that device — `storeForFolder` in `server.ts`, pinned in
   * `server.test.ts`. A parser that decided it would be the most dangerous kind
   * of wrong, which is the argument `create.cwd` and the name above already make.
   */
  it('carries a destination folder, and treats absent and empty as the same answer', () => {
    expect(accepted(begin({ dir: '/srv/incoming' }))).toEqual({
      t: 'upload.begin',
      id: 'up-1',
      name: 'photo.jpg',
      size: 1024,
      dir: '/srv/incoming',
    })
    // Absent is every phone and every desktop before this field existed; empty
    // is a sender that chose nothing. Both mean the host's own folder, and both
    // come out of here as a frame with no `dir` on it at all.
    expect(accepted(begin({}))).not.toHaveProperty('dir')
    expect(accepted(begin({ dir: '' }))).not.toHaveProperty('dir')
  })

  it('refuses a folder that is not a string, is oversized, or hides a control byte', () => {
    refused(begin({ dir: 42 }), 'numeric folder')
    expect(refused(begin({ dir: `/${'x'.repeat(MAX_UPLOAD_DIR_BYTES)}` }), 'long folder').code).toBe(
      'too-large',
    )
    // Stripped would turn a hostile value into a different legal-looking path,
    // which is the worse failure — the same argument the name check makes.
    expect(refused(begin({ dir: '/srv/in\u0000coming' }), 'NUL in folder').code).toBe('bad-message')
  })

  it('reads the folder once, so a getter cannot swap it after the checks', () => {
    let reads = 0
    const frame = {
      t: 'upload.begin',
      id: 'up-1',
      name: 'photo.jpg',
      size: 1024,
      get dir(): string {
        reads += 1
        return reads === 1 ? '/srv/incoming' : `/${'x'.repeat(MAX_UPLOAD_DIR_BYTES)}`
      },
    }
    expect(accepted(frame)).toMatchObject({ dir: '/srv/incoming' })
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

/**
 * The copilot, coming *back*, which this parser used to drop on the floor.
 *
 * ## The defect, stated once
 *
 * `parseServerFrame` rebuilds a `welcome` field by name — protocol, device,
 * token, sessions, capabilities, then the optional platform and folders — and
 * it never copied `copilot`. Its `default` then refused every `copilot.*`
 * server frame as "unknown message type". So the shared reader, which advertises
 * itself as the one door inbound frames come through, was blind to a capability
 * `server.ts` has served for weeks.
 *
 * `pwa/src/protocol-client.ts` survived it by carrying a private shim that
 * re-attached the key after calling this function, and its own comment says the
 * cost of not reading it is *total* rather than cosmetic: the presence of the
 * key **is** whether there is a copilot, so losing it draws a machine with a
 * copilot and a device entitled to it as though neither existed. Every other
 * consumer had no shim — including `machines/guest.ts`, this desktop acting as
 * another desktop's client, which is the surface this pass exists for.
 *
 * ## What is asserted, and why the malformed cases are half of it
 *
 * Reading the key is only half a fix. Dropping a malformed one is the other
 * half and it is the half with teeth: a client that invented a link out of an
 * unreadable object would send `copilot.hello` to a machine that never offered
 * one and then draw a surface whose every frame comes back refused. Absent is
 * the answer a guest is supposed to get, so absent is what an unreadable key
 * has to become.
 */
describe('the copilot on the way back', () => {
  const WELCOME = {
    t: 'welcome',
    protocol: PROTOCOL_VERSION,
    deviceId: 'dev-1',
    deviceName: 'Studio PC',
    token: null,
    sessions: [],
    capabilities: ['copilot'],
  }

  function welcomeWith(copilot: unknown): Extract<ServerMessage, { t: 'welcome' }> {
    const parsed = parseServerMessage(serialize({ ...WELCOME, copilot } as unknown as ServerMessage))
    if (!parsed.ok) throw new Error(`welcome refused: ${parsed.reason}`)
    if (parsed.message.t !== 'welcome') throw new Error(`parsed as ${parsed.message.t}`)
    return parsed.message
  }

  it('carries the link through a welcome instead of silently removing it', () => {
    const link = { linked: true, open: false, grant: { read: true, act: true, alter: true } }
    expect(welcomeWith(link).copilot).toEqual(link)
  })

  it('leaves it absent for a machine that sent none, which is what a guest gets', () => {
    // Not false, not an empty object — **absent**. `copilot-access.ts` withholds
    // the key from a guest rather than sending one that says no, because an
    // advertised thing a device may not use invites the ask and the answer to
    // the ask is always no. A reader that manufactured a link here would put
    // that refusal back on the screen.
    const parsed = parseServerMessage(serialize(WELCOME as unknown as ServerMessage))
    if (!parsed.ok || parsed.message.t !== 'welcome') throw new Error('welcome refused')
    expect(parsed.message.copilot).toBeUndefined()
    expect('copilot' in parsed.message).toBe(false)
  })

  it('drops a malformed link rather than trusting it, in every shape it can arrive', () => {
    for (const bad of [
      // Not an object at all.
      null,
      'yes',
      42,
      true,
      [],
      // A grant that is missing, partial, or made of the wrong types. `no
      // access` must have exactly one spelling: a grant read as `{read: true}`
      // with the other two missing would draw a surface for a device that may
      // have been given everything, or nothing.
      { linked: true, open: false },
      { linked: true, open: false, grant: null },
      { linked: true, open: false, grant: { read: true } },
      { linked: true, open: false, grant: { read: true, act: true } },
      { linked: true, open: false, grant: { read: 'yes', act: true, alter: true } },
      { linked: true, open: false, grant: { read: 1, act: 1, alter: 1 } },
      // The two booleans that say whether there is a copilot and whether this
      // socket has opened it. Neither may be inferred from a missing field.
      { open: false, grant: { read: true, act: true, alter: true } },
      { linked: true, grant: { read: true, act: true, alter: true } },
      { linked: 'true', open: false, grant: { read: true, act: true, alter: true } },
    ]) {
      const welcome = welcomeWith(bad)
      expect(welcome.copilot, `copilot ${JSON.stringify(bad)}`).toBeUndefined()
      // And the *rest* of the welcome survives: one unreadable optional key must
      // not cost a device its session list, the way a bad row costs a list one
      // row rather than costing the frame.
      expect(welcome.deviceId, `copilot ${JSON.stringify(bad)}`).toBe('dev-1')
    }
  })

  /**
   * And the frames themselves, which the `default` branch used to refuse.
   *
   * Every frame a watching connection can be pushed is read — the state and the
   * chat this desktop draws, and the four it does not yet. That last part is
   * deliberate rather than thorough: a frame this parser refuses is reported by
   * `machines/guest.ts` as *"sent something unreadable"*, which is the sentence
   * reserved for a captive portal answering with HTML, and an ordinary tool
   * call on the far machine must not produce it.
   */
  it('reads every copilot frame the far machine pushes a watching connection', () => {
    const pushed = VALID_SERVER.filter((message) => message.t.startsWith('copilot.') && message.t !== 'copilot.log')
    // Named rather than counted, and asserted rather than derived: a filter is
    // the kind of thing that passes vacuously when it matches nothing, which is
    // exactly how this parser's blindness survived a suite this size.
    expect(new Set(pushed.map((message) => message.t))).toEqual(
      new Set([
        'copilot.state',
        'copilot.chat',
        'copilot.tool',
        'copilot.sessions',
        'copilot.pending',
        'copilot.grant',
        'copilot.ask',
        'copilot.settled',
      ]),
    )
    for (const message of pushed) {
      const parsed = parseServerMessage(serialize(message))
      if (!parsed.ok) throw new Error(`${message.t}: ${parsed.reason}`)
      expect(parsed.message, message.t).toEqual(message)
    }
  })

  it('refuses a copilot frame whose one fact is incomplete, rather than half-reading it', () => {
    for (const [label, frame] of [
      // A state with no `desk` would be drawn as "stopped", which is the one
      // claim on that surface somebody acts on — by pressing Start against
      // something that is already running.
      ['state without a desk', { t: 'copilot.state', state: { grant: { read: true, act: true, alter: true } } }],
      ['state without a grant', { t: 'copilot.state', state: { desk: 'running' } }],
      // Without a run id a client that reconnected after the grace window would
      // splice the end of a dead conversation onto the start of a live one.
      ['chat without a run', { t: 'copilot.chat', messages: [] }],
      ['chat without messages', { t: 'copilot.chat', run: 'run-1' }],
      ['grant without a link', { t: 'copilot.grant', link: { linked: true, open: true } }],
      // A consent prompt missing its arguments is the reflex Yes the whole
      // question type exists to prevent.
      ['ask without args', { t: 'copilot.ask', question: { id: 'q-1', tool: 'settings.write' } }],
      ['settled without a row', { t: 'copilot.settled', settled: {} }],
      ['tool without a row', { t: 'copilot.tool', row: { id: 'r-1', tool: 'settings.write' } }],
      ['sessions without a list', { t: 'copilot.sessions' }],
      ['pending without a list', { t: 'copilot.pending', questions: {} }],
    ] as Array<[string, unknown]>) {
      const parsed = parseServerMessage(JSON.stringify(frame))
      expect(parsed.ok, label).toBe(false)
    }
  })

  it('drops an unreadable row from a list rather than the list carrying it', () => {
    // The other half of the split, and the reason it is a split: a surface
    // showing four of five bubbles is useful, and one showing none because the
    // fifth had a null role is not.
    const parsed = parseServerMessage(
      JSON.stringify({
        t: 'copilot.chat',
        run: 'run-1',
        messages: [
          { id: 'm1', role: 'you', text: 'anything stuck?', at: 1 },
          { id: '', role: 'agent', text: 'no id, so no way to replace it later' },
          { role: 'agent', text: 'nor this one' },
          { id: 'm2', role: 'narrator', text: 'not a role this protocol has' },
          { id: 'm3', role: 'agent', text: 'session 3 is waiting', at: 2, truncated: true },
        ],
      }),
    )
    if (!parsed.ok || parsed.message.t !== 'copilot.chat') throw new Error('chat refused')
    expect(parsed.message.messages).toEqual([
      { id: 'm1', role: 'you', text: 'anything stuck?', at: 1 },
      { id: 'm3', role: 'agent', text: 'session 3 is waiting', at: 2, truncated: true },
    ])
  })
})

/**
 * A paste, split so it survives the wire.
 *
 * The defect these cover was measured end to end, not reasoned about: a
 * 49,160-character paste into a session on a paired machine typed **zero bytes**
 * and dropped the link, because the far end answers an oversized frame by
 * closing the socket. `chunkInput`'s own note carries the states that were
 * recorded. What is asserted here is the property that stops it: every piece
 * fits, and putting the pieces back together gives the paste.
 */
describe('chunkInput', () => {
  const rejoin = (data: string, size?: number): string => chunkInput(data, size).join('')
  const framed = (piece: string): number =>
    Buffer.byteLength(serialize({ t: 'input', id: SESSION_ID, data: piece }), 'utf8')

  it('leaves a paste that already fits in one piece', () => {
    expect(chunkInput('')).toEqual([])
    expect(chunkInput('echo hello\r')).toEqual(['echo hello\r'])
    const atCap = 'a'.repeat(MAX_INPUT_BYTES)
    expect(chunkInput(atCap)).toEqual([atCap])
  })

  it('splits a paste over the cap into frames the parser accepts, and loses nothing', () => {
    const paste = `START${'x'.repeat(MAX_INPUT_BYTES * 3)}END`
    const pieces = chunkInput(paste)
    expect(pieces.length).toBeGreaterThan(3)
    expect(pieces.join('')).toBe(paste)
    for (const piece of pieces) {
      const parsed = parseClientMessage(serialize({ t: 'input', id: SESSION_ID, data: piece }))
      expect(parsed.ok).toBe(true)
      expect(framed(piece)).toBeLessThan(MAX_MESSAGE_BYTES)
    }
  })

  it('never cuts between the halves of a surrogate pair', () => {
    // Every character is four bytes, so a chunker counting UTF-16 units would
    // land mid-character and deliver two replacement characters instead.
    const paste = '😀'.repeat(MAX_INPUT_BYTES)
    const pieces = chunkInput(paste)
    expect(pieces.join('')).toBe(paste)
    for (const piece of pieces) {
      expect(piece).not.toMatch(/[\uD800-\uDBFF]$/)
      expect(piece).not.toMatch(/^[\uDC00-\uDFFF]/)
    }
  })

  it('spends the frame budget in JSON bytes, not in text bytes', () => {
    /*
     * The case a cap counted in raw UTF-8 alone gets wrong. An escape is one
     * byte of text and six of JSON — `\u001b` — so 16 KiB of escape sequences
     * is under the payload cap by that measure and three times over the *frame*
     * cap once serialised, which the far end answers by closing the socket.
     */
    const ansi = '\u001b[1;32m'.repeat(4000)
    expect(Buffer.byteLength(ansi, 'utf8')).toBeGreaterThan(MAX_INPUT_BYTES)
    const pieces = chunkInput(ansi)
    expect(pieces.join('')).toBe(ansi)
    for (const piece of pieces) expect(framed(piece)).toBeLessThan(MAX_MESSAGE_BYTES)
  })

  it('keeps a bracketed paste in order, markers included', () => {
    // A pty reads a split paste identically because frames arrive in order —
    // what must not happen is the wrapper being reordered or dropped.
    const paste = `\u001b[200~${'y'.repeat(MAX_INPUT_BYTES * 2)}\u001b[201~`
    expect(rejoin(paste)).toBe(paste)
    const pieces = chunkInput(paste)
    expect(pieces[0].startsWith('\u001b[200~')).toBe(true)
    expect(pieces[pieces.length - 1].endsWith('\u001b[201~')).toBe(true)
  })
})

/**
 * The four answers a host gives an upload, read by the machine that is sending
 * one.
 *
 * They were missing from `parseServerFrame` for as long as the only client that
 * uploaded was a phone — and a frame this parser does not know is refused, so a
 * desktop dropping a file on another desktop would have announced it and then
 * heard nothing at all.
 */
describe('upload answers, on the client side of the wire', () => {
  const read = (frame: unknown): ReturnType<typeof parseServerMessage> =>
    parseServerMessage(JSON.stringify(frame))

  it('reads the path, the acknowledgements, the completion and the refusal', () => {
    const ready = read({ t: 'upload.ready', id: 'up-1', path: '/Users/a/Downloads/x.jpg' })
    expect(ready.ok && ready.message).toEqual({
      t: 'upload.ready',
      id: 'up-1',
      path: '/Users/a/Downloads/x.jpg',
    })

    const ack = read({ t: 'upload.ack', id: 'up-1', bytes: 24576 })
    expect(ack.ok && ack.message).toEqual({ t: 'upload.ack', id: 'up-1', bytes: 24576 })

    const done = read({ t: 'upload.done', id: 'up-1', path: '/p/x.jpg', bytes: 9, sha256: 'ab' })
    expect(done.ok && done.message).toEqual({
      t: 'upload.done',
      id: 'up-1',
      path: '/p/x.jpg',
      bytes: 9,
      sha256: 'ab',
    })

    const failed = read({ t: 'upload.failed', id: 'up-1', message: 'Nothing was saved.' })
    expect(failed.ok && failed.message).toEqual({
      t: 'upload.failed',
      id: 'up-1',
      message: 'Nothing was saved.',
    })
  })

  it('keeps a refusal that carries no words, because the transfer is still over', () => {
    const failed = read({ t: 'upload.failed', id: 'up-1' })
    expect(failed.ok && failed.message).toEqual({ t: 'upload.failed', id: 'up-1', message: '' })
  })

  it('refuses an acknowledgement that would run the window backwards', () => {
    expect(read({ t: 'upload.ack', id: 'up-1', bytes: -1 }).ok).toBe(false)
    expect(read({ t: 'upload.ack', id: 'up-1', bytes: 1.5 }).ok).toBe(false)
    expect(read({ t: 'upload.ack', id: '', bytes: 1 }).ok).toBe(false)
  })
})

describe('window.holds', () => {
  /**
   * The frame a device sends to say which of the host's sessions have a browser
   * window in *its* app. It addresses a verb and does nothing else — it is not a
   * grant, and a session named in it that holds no window over there simply gets
   * that device's own frames refused — so its parsing is deliberately forgiving
   * where the rest of this file is not.
   */
  it('keeps the ids it can use and drops the ones it cannot', () => {
    const parsed = parseClientMessage({
      t: 'window.holds',
      sessions: [SESSION_ID, '../../etc/passwd', 42, '', 'a-second-id'],
    })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) throw new Error('unreachable')
    expect(parsed.message).toEqual({ t: 'window.holds', sessions: [SESSION_ID, 'a-second-id'] })
  })

  it('trims a list too long to hold rather than closing the link over it', () => {
    /*
     * Unlike every size cap in this file. A person attaches windows by hand, one
     * at a time, so the real number is one or two — but the list arrives from
     * another computer and lands in a `Map` on this one, and dropping a working
     * machine over the hundred and twenty-ninth entry would be a link lost to a
     * fact nobody can act on.
     */
    const many = Array.from({ length: MAX_WINDOW_HOLDS + 50 }, (_, n) => `session-${n}`)
    const parsed = parseClientMessage({ t: 'window.holds', sessions: many })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) throw new Error('unreachable')
    if (parsed.message.t !== 'window.holds') throw new Error('unreachable')
    expect(parsed.message.sessions).toHaveLength(MAX_WINDOW_HOLDS)
  })

  it('refuses a frame with no list at all', () => {
    expect(parseClientMessage({ t: 'window.holds' }).ok).toBe(false)
    expect(parseClientMessage({ t: 'window.holds', sessions: 'all of them' }).ok).toBe(false)
  })
})

describe('sessions.mine', () => {
  /**
   * The mirror of the frame above, and the one that makes it able to say
   * anything: the sessions on the *client's* computer, so the host can offer a
   * row in its own attach menu. Same forgiveness for the same reason — a device
   * describing its own screen must not be able to lose its link over the shape
   * of one row.
   */
  const ROW = {
    id: SESSION_ID,
    title: 'terminaldeck',
    cwd: '/Users/apple/Projects/terminaldeck',
    provider: 'claude',
    status: 'idle',
    exitCode: null,
  }

  it('keeps the rows it can read and drops the ones it cannot', () => {
    const parsed = parseClientMessage({
      t: 'sessions.mine',
      sessions: [ROW, { id: '' }, 'a terminal', null, { ...ROW, id: 'second' }],
    })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) throw new Error('unreachable')
    if (parsed.message.t !== 'sessions.mine') throw new Error('unreachable')
    expect(parsed.message.sessions.map((row) => row.id)).toEqual([SESSION_ID, 'second'])
  })

  it('trims a list too long to hold rather than closing the link over it', () => {
    const many = Array.from({ length: MAX_ANNOUNCED_SESSIONS + 20 }, (_, n) => ({
      ...ROW,
      id: `session-${n}`,
    }))
    const parsed = parseClientMessage({ t: 'sessions.mine', sessions: many })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) throw new Error('unreachable')
    if (parsed.message.t !== 'sessions.mine') throw new Error('unreachable')
    expect(parsed.message.sessions).toHaveLength(MAX_ANNOUNCED_SESSIONS)
  })

  it('reads an empty list as the answer it is, rather than as nothing said', () => {
    const parsed = parseClientMessage({ t: 'sessions.mine', sessions: [] })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) throw new Error('unreachable')
    expect(parsed.message).toEqual({ t: 'sessions.mine', sessions: [] })
  })

  it('refuses a frame with no list at all, which is not the same as none', () => {
    expect(parseClientMessage({ t: 'sessions.mine' }).ok).toBe(false)
    expect(parseClientMessage({ t: 'sessions.mine', sessions: 'all of them' }).ok).toBe(false)
  })
})
/**
 * The three window frames, read the same way whichever end they arrive at.
 *
 * They travel in both directions since 2026-08-21: whichever computer holds the
 * `WebContentsView` serves, whichever holds the pty asks, and which of those a
 * given desktop is depends only on who dialled whom. That is one shape per
 * frame and one validator per frame, and this block is what stops the second
 * copy from being written later: a check that passes here and fails there is a
 * frame that crosses one way and closes the channel the other.
 */
describe('the window frames in both directions', () => {
  const CASES: Record<string, unknown>[] = [
    { t: 'window.holds', sessions: [SESSION_ID, '../../etc/passwd', 42, '', 'a-second-id'] },
    { t: 'window.holds', sessions: [] },
    { t: 'window.holds' },
    { t: 'window.holds', sessions: 'all of them' },
    { t: 'window.call', id: 'w-1', session: SESSION_ID, tool: 'browser.read', args: '{}' },
    { t: 'window.call', id: 'w-1', session: SESSION_ID, tool: '', args: '{}' },
    { t: 'window.call', id: 'w-1', session: 'a/b', tool: 'browser.read', args: '{}' },
    { t: 'window.call', id: 'w-1', session: SESSION_ID, tool: 'browser.read' },
    { t: 'window.result', id: 'w-1', ok: true, body: '{}' },
    { t: 'window.result', id: 'w-1', ok: 'yes', body: '{}' },
    { t: 'window.result', id: 'w-1', ok: true },
  ]

  it('agrees on every frame, valid or not', () => {
    for (const frame of CASES) {
      const asClient = parseClientMessage(frame)
      const asServer = parseServerMessage(JSON.stringify(frame))
      expect([frame.t, asClient.ok]).toEqual([frame.t, asServer.ok])
      if (asClient.ok && asServer.ok) {
        expect(asClient.message).toEqual(asServer.message)
      }
    }
  })

  it('agrees on the caps, which is the number that cost a link once', () => {
    /*
     * `MAX_WINDOW_RESULT_BYTES` was right in the parser and missing at the end
     * that composed the answer for one evening, and a real page outline took the
     * link between two machines down — terminals, transfers and all. A second
     * copy of these checks is a second place for that to happen, so the point of
     * this test is that there is only one.
     */
    const huge = { t: 'window.result', id: 'w-1', ok: true, body: 'x'.repeat(MAX_WINDOW_RESULT_BYTES + 1) }
    const fat = { t: 'window.call', id: 'w-1', session: SESSION_ID, tool: 'browser.read', args: 'x'.repeat(MAX_WINDOW_ARGS_BYTES + 1) }
    for (const frame of [huge, fat]) {
      expect(parseClientMessage(frame).ok).toBe(false)
      expect(parseServerMessage(JSON.stringify(frame)).ok).toBe(false)
    }
    // And the over-size refusal keeps its own close code on the direction that
    // carries one: a size refusal reported as a malformed frame would send the
    // wrong code to the one peer that could have done something about it.
    const refusal = parseClientMessage(huge)
    if (refusal.ok) throw new Error('unreachable')
    expect(refusal.code).toBe('too-large')
  })

  it('trims an over-long holdings list the same way at both ends', () => {
    const many = Array.from({ length: MAX_WINDOW_HOLDS + 50 }, (_, n) => `session-${n}`)
    for (const parsed of [
      parseClientMessage({ t: 'window.holds', sessions: many }),
      parseServerMessage(JSON.stringify({ t: 'window.holds', sessions: many })),
    ]) {
      expect(parsed.ok).toBe(true)
      if (!parsed.ok) throw new Error('unreachable')
      if (parsed.message.t !== 'window.holds') throw new Error('unreachable')
      expect(parsed.message.sessions).toHaveLength(MAX_WINDOW_HOLDS)
    }
  })

  it('offers both halves of the conversation as capabilities', () => {
    // Two strings rather than a wider reading of one. A build shipped before
    // tonight advertises `windows` and means only the old half; a frame sent on
    // the strength of that word is a machine falling off the network.
    expect(CAPABILITIES).toContain('windows')
    expect(CAPABILITIES).toContain('hostwindows')
  })
})
