#!/usr/bin/env node
/**
 * A stand-in Mac, so the Android client can be driven against something real.
 *
 * ## What is real in here and what is not
 *
 * **Real:** the relay (`relay/src/rendezvous.ts`, run unmodified, in process), the sealed channel
 * (`src/shared/sealed.ts`, run unmodified, as the responder), the sealed-handshake framing
 * (`src/shared/relay-wire.ts`, run unmodified), the WebSocket framing (`src/shared/ws-frame.ts`),
 * the JSON protocol from `src/main/remote/protocol.ts`, and the sessions — those are real ptys
 * running a real shell through `node-pty`.
 *
 * `relay-wire.ts` is on that list because it once was not. This host used to pass a guest's first
 * payload straight to `respondToHandshake` and answer with a bare `reply`, skipping the version
 * byte — the same byte the Android client was skipping. Two wrongs that match make a green test and
 * a client that cannot reach a real Mac. A stand-in that disagrees with the product is worse than
 * no stand-in, because it manufactures confidence, so every byte of framing here now comes from the
 * desktop's own functions rather than from a second reading of the spec.
 *
 * **Not real:** the trust store. `src/main/remote/device-auth.ts` keeps scrypt hashes, rate limits
 * and revocation; this keeps a JSON file and a SHA-256. It is a test double for the half of the
 * desktop that has not been wired to the relay yet, and it exists so the phone's pairing, approval
 * and reconnect paths can be exercised end to end instead of described.
 *
 * Nothing here ships. It lives under `android/tools` because it is Android's verification rig.
 *
 * ## The pairing contract this implements
 *
 * `sealed.ts` refuses a handshake from a device it does not know, and the pairing token that would
 * vouch for the device travels *inside* the sealed channel — so a brand-new device cannot get in
 * unless something opens the door for it. What opens it is a pairing window: while a pairing token
 * is live, an unknown static key is admitted to the handshake, and the `hello` that follows must
 * carry the token or the connection is refused and the key is forgotten. That is the same shape
 * `authenticatorFor` in `server.ts` already has for the tailnet, one layer lower.
 *
 * Approval is deliberately a second step, and it is a human at this terminal pressing `a`.
 *
 * Usage:
 *   node android/tools/dev-host.cjs [--port 8787] [--relay ws://10.0.2.2:8787]
 *
 * Keys: p = new pairing code · a = approve every waiting device · l = list · r = revoke all · q = quit
 */

const { execFileSync } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const http = require('node:http')
const path = require('node:path')

const ANDROID = path.resolve(__dirname, '..')
const REPO = path.resolve(ANDROID, '..')
const GEN = path.join(ANDROID, 'tools/.gen')
const IDENTITY = path.join(GEN, 'dev-host-identity.json')

/* ------------------------------------------------------------------ build -- */

function bundle(entry, out) {
  execFileSync(
    path.join(REPO, 'node_modules/.bin/esbuild'),
    [path.join(REPO, entry), '--bundle', '--platform=node', '--format=cjs', '--target=node22', `--outfile=${out}`],
    { stdio: ['ignore', 'ignore', 'inherit'] },
  )
  return require(out)
}

fs.mkdirSync(GEN, { recursive: true })
const sealed = bundle('src/shared/sealed.ts', path.join(GEN, 'sealed.cjs'))
const relayWire = bundle('src/shared/relay-wire.ts', path.join(GEN, 'relay-wire.cjs'))
const wsFrame = bundle('src/shared/ws-frame.ts', path.join(GEN, 'ws-frame.cjs'))
const rendezvous = bundle('relay/src/rendezvous.ts', path.join(GEN, 'rendezvous.cjs'))
/**
 * The wire language itself, imported rather than restated.
 *
 * This file used to carry its own copy of the version number, its own `chunkOutput`, its own
 * capability list and its own hand-rolled `switch` over `message.t` — and that is exactly how it
 * came to advertise `session.create` and answer `{"t":"new"}`, a shape no real desktop has ever
 * spoken. A stand-in that shares a bug with the client it is standing in for hides the bug: the
 * 81-vs-80 byte error in the sealed envelope survived a day that way.
 *
 * So the parser, the constants and the file-upload desk are the product's own. What remains local
 * is only what this process genuinely does differently from a Mac — a flat session map instead of
 * `PtyManager`, and a keyboard instead of a human approving devices.
 */
const wire = bundle('src/main/remote/protocol.ts', path.join(GEN, 'protocol.cjs'))
const uploads = bundle('src/main/remote/uploads.ts', path.join(GEN, 'uploads.cjs'))
const pty = require(path.join(REPO, 'node_modules/node-pty'))

/* --------------------------------------------------------------- options -- */

const argv = process.argv.slice(2)
function option(name, fallback) {
  const at = argv.indexOf(`--${name}`)
  return at === -1 ? fallback : argv[at + 1]
}
const PORT = Number(option('port', '8787'))
/** What goes in the pairing code. `10.0.2.2` is the host machine as seen from an AVD. */
const RELAY_URL = option('relay', `ws://10.0.2.2:${PORT}`)

const PROTOCOL_VERSION = wire.PROTOCOL_VERSION
const OUTPUT_CHUNK_BYTES = wire.OUTPUT_CHUNK_BYTES
/**
 * Where a file sent from the phone lands here.
 *
 * Under `tools/.gen` rather than the real downloads folder: this process is started and killed a
 * dozen times an evening and a harness that fills somebody's Downloads with test photos is a
 * harness people stop running.
 */
const UPLOAD_DIR = path.join(GEN, 'uploads')
const SCROLLBACK_BYTES = 96 * 1024
const PAIRING_TTL_MS = 5 * 60_000

/* -------------------------------------------------------------- identity -- */

/**
 * The Mac's two long-lived secrets: the relay name and the static key.
 *
 * Persisted so a restart does not silently invalidate a paired phone — which is exactly the bug
 * this rig exists to catch in the client, and would be indistinguishable from it if the host
 * reinvented itself every run.
 */
function loadIdentity() {
  if (fs.existsSync(IDENTITY)) {
    const raw = JSON.parse(fs.readFileSync(IDENTITY, 'utf8'))
    return {
      hostSecret: Buffer.from(raw.hostSecret, 'hex'),
      static: {
        publicKey: Buffer.from(raw.staticPublic, 'hex'),
        privateKey: Buffer.from(raw.staticPrivate, 'hex'),
      },
      devices: raw.devices ?? [],
    }
  }
  const hostSecret = crypto.randomBytes(32)
  const identity = { hostSecret, static: sealed.generateStatic(), devices: [] }
  saveIdentity(identity)
  return identity
}

function saveIdentity(identity) {
  fs.writeFileSync(
    IDENTITY,
    JSON.stringify(
      {
        hostSecret: identity.hostSecret.toString('hex'),
        staticPublic: identity.static.publicKey.toString('hex'),
        staticPrivate: identity.static.privateKey.toString('hex'),
        devices: identity.devices,
      },
      null,
      2,
    ),
    { mode: 0o600 },
  )
}

const identity = loadIdentity()
const hostId = rendezvous.hostIdFor(identity.hostSecret)

const digestOf = (value) => crypto.createHash('sha256').update(value).digest('hex')

let pairing = null // { token, expiresAt }

function newPairingCode() {
  const token = crypto.randomBytes(32).toString('base64url')
  pairing = { token, expiresAt: Date.now() + PAIRING_TTL_MS }
  return token
}

function pairingOpen() {
  if (!pairing) return false
  if (Date.now() >= pairing.expiresAt) {
    pairing = null
    return false
  }
  return true
}

function deviceByKey(publicKey) {
  const hex = publicKey.toString('hex')
  return identity.devices.find((device) => device.publicKey === hex) ?? null
}

function pairingCodeText() {
  if (!pairingOpen()) return null
  const params = new URLSearchParams({
    h: hostId,
    k: identity.static.publicKey.toString('base64url'),
    t: pairing.token,
    r: RELAY_URL,
  })
  return `terminaldeck://pair#${params.toString()}`
}

/* -------------------------------------------------------------- sessions -- */

const sessions = new Map()
let sessionCounter = 0

function createSession(title, command, args, cwd, size = {}) {
  const id = `dev-${(sessionCounter += 1)}-${crypto.randomBytes(3).toString('hex')}`
  const child = pty.spawn(command, args, {
    name: 'xterm-256color',
    // The phone's viewport travels with `create`, so the first screen is drawn at the size it will
    // be read at rather than arriving at 80x24 and reflowing.
    cols: size.cols || 80,
    rows: size.rows || 24,
    cwd,
    env: { ...process.env, TERM: 'xterm-256color', TERMINALDECK: '1' },
  })
  const session = {
    id,
    title,
    cwd,
    provider: 'shell',
    status: 'running',
    exitCode: null,
    pty: child,
    scrollback: '',
  }
  child.onData((data) => {
    session.scrollback = (session.scrollback + data).slice(-SCROLLBACK_BYTES)
    for (const client of clients) if (client.attached.has(id)) sendJson(client, { t: 'output', id, data })
  })
  child.onExit(({ exitCode }) => {
    session.status = 'exited'
    session.exitCode = exitCode
    for (const client of clients) {
      if (client.attached.has(id)) sendJson(client, { t: 'exit', id, exitCode })
      sendJson(client, { t: 'status', id, status: 'exited' })
    }
    announce()
  })
  sessions.set(id, session)
  announce()
  return session
}

function listSessions() {
  return [...sessions.values()].map((session) => ({
    id: session.id,
    title: session.title,
    cwd: session.cwd,
    provider: session.provider,
    status: session.status,
    exitCode: session.exitCode,
  }))
}

function announce() {
  for (const client of clients) if (client.deviceId) sendJson(client, { t: 'sessions', sessions: listSessions() })
}

/* -------------------------------------------------------------- protocol -- */

const clients = new Set()

/** The product's own, so a phone meets the same chunking here as on a Mac. */
const chunkOutput = (data) => wire.chunkOutput(data, OUTPUT_CHUNK_BYTES)

function sendJson(client, message) {
  if (!client.channel) return
  try {
    client.send(client.channel.send(Buffer.from(JSON.stringify(message), 'utf8')))
  } catch (error) {
    log(`send failed: ${error.message}`)
  }
}

function refuse(client, code, message) {
  sendJson(client, { t: 'error', code, message })
  client.close()
}

function onProtocol(client, raw) {
  // The product's own parser, not a `JSON.parse` and a hopeful `switch`. Everything a phone sends
  // here meets the same narrowing it would meet on a Mac — the id shapes, the byte caps, the
  // both-or-neither size rule — so a client that passes against this host passes against the app.
  const parsed = wire.parseClientMessage(raw)
  if (!parsed.ok) return refuse(client, parsed.code, parsed.reason)
  const message = parsed.message

  if (!client.deviceId) {
    if (message.t !== 'hello') return refuse(client, 'unauthenticated', 'Say hello first.')
    return hello(client, message)
  }

  switch (message.t) {
    case 'list':
      return sendJson(client, { t: 'sessions', sessions: listSessions() })
    case 'ping':
      return sendJson(client, { t: 'pong' })
    case 'attach': {
      const session = sessions.get(message.id)
      if (!session) return sendJson(client, { t: 'error', code: 'unknown-session', message: 'no such session' })
      client.attached.add(session.id)
      if (message.cols && message.rows) resize(session, message.cols, message.rows)
      sendJson(client, { t: 'attached', id: session.id })
      for (const chunk of chunkOutput(session.scrollback)) {
        sendJson(client, { t: 'output', id: session.id, data: chunk, replay: true })
      }
      if (session.exitCode !== null) sendJson(client, { t: 'exit', id: session.id, exitCode: session.exitCode })
      return
    }
    case 'detach':
      client.attached.delete(message.id)
      return sendJson(client, { t: 'detached', id: message.id })
    case 'input': {
      const session = sessions.get(message.id)
      if (!session || session.status === 'exited') return
      if (!client.attached.has(session.id)) {
        return sendJson(client, { t: 'error', code: 'unauthorized', message: 'Attach to that session before typing into it.' })
      }
      return session.pty.write(message.data)
    }
    case 'resize': {
      const session = sessions.get(message.id)
      if (session) resize(session, message.cols, message.rows)
      return
    }
    /* ---- capability `create` -------------------------------------------------------------- */
    /**
     * Start a session, under the same folder rule a Mac applies.
     *
     * `cwd` is accepted only when this host is already offering the folder — the working directory
     * of a session it has already listed, or its own home. A path it does not offer is **refused**,
     * never quietly replaced with the default, because a New Session that silently started
     * somewhere else is a command typed into the wrong project.
     *
     * The answer is `created` carrying the whole row, not a bare `sessions` list. This host used to
     * send the list, which leaves the phone guessing which row is new — and with two sessions in
     * the same folder there is no way to guess right.
     */
    case 'create': {
      const offered = [process.env.HOME, ...[...sessions.values()].map((entry) => entry.cwd)]
      if (message.cwd !== undefined && !offered.includes(message.cwd)) {
        return sendJson(client, {
          t: 'error',
          code: 'unauthorized',
          message: 'This Mac will not start a session in that folder. Open it on the Mac first.',
        })
      }
      let session
      try {
        session = createSession(
          'shell',
          process.env.SHELL || '/bin/zsh',
          ['-il'],
          message.cwd || process.env.HOME,
          { cols: message.cols, rows: message.rows },
        )
      } catch (error) {
        return sendJson(client, {
          t: 'error',
          code: 'unavailable',
          message: 'This Mac could not start a session there. The folder may have moved.',
        })
      }
      sendJson(client, {
        t: 'created',
        session: {
          id: session.id,
          title: session.title,
          cwd: session.cwd,
          provider: session.provider,
          status: session.status,
          exitCode: session.exitCode,
        },
      })
      // Everyone else hears about it as an ordinary list refresh, which is a v1 frame every client
      // back to the first one understands.
      for (const other of clients) {
        if (other !== client && other.deviceId) sendJson(other, { t: 'sessions', sessions: listSessions() })
      }
      return
    }

    /* ---- capability `upload` -------------------------------------------------------------- */
    case 'upload.begin':
    case 'upload.data':
    case 'upload.end':
    case 'upload.cancel':
      // The product's own desk, writing to a real directory. Nothing about receiving a file is
      // reimplemented here: the name sanitising, the `.part` file, the acknowledgement window and
      // the digest check are the ones a Mac uses.
      return deskFor(client).handle(message)

    default:
      return refuse(client, 'bad-message', 'unknown message type')
  }
}

/** The upload desk for one phone, made on the first `upload` verb and not before. */
function deskFor(client) {
  if (!client.uploads) {
    client.uploads = uploads.createUploadDesk({
      store: uploads.diskUploadStore(UPLOAD_DIR),
      send: (message) => sendJson(client, message),
    })
  }
  return client.uploads
}

function resize(session, cols, rows) {
  try {
    session.pty.resize(cols, rows)
  } catch {
    // A resize on a dead pty is not worth a disconnection.
  }
}

function hello(client, message) {
  if (message.protocol !== PROTOCOL_VERSION) {
    return refuse(client, 'version', `This desktop speaks protocol ${PROTOCOL_VERSION}.`)
  }
  const token = typeof message.token === 'string' ? message.token : ''
  const known = deviceByKey(client.devicePublicKey)

  // A credential is `<deviceId>.<secret>`; a pairing token is base64url with no dot. Shape, not
  // trust — guessing wrong only sends it down the other path, where it fails the same way.
  if (token.includes('.')) {
    if (!known || known.credential !== digestOf(token)) {
      return refuse(client, 'unauthenticated', 'This device is not paired with that Mac any more.')
    }
    if (!known.approved) {
      return refuse(client, 'unauthorized', 'This device is waiting to be approved. Approve it on the Mac, then reconnect.')
    }
    client.deviceId = known.id
    client.deviceName = known.name
    log(`${known.name} connected`)
    return sendJson(client, {
      t: 'welcome',
      protocol: PROTOCOL_VERSION,
      deviceId: known.id,
      deviceName: known.name,
      token: null,
      sessions: listSessions(),
      // What this host can actually do, taken from the product's own list rather than typed out.
      // `localhost` is filtered because this stand-in has no tunnel hub — advertising it would put
      // a Ports button on the phone with nothing behind it, which is the exact failure the
      // capability mechanism exists to prevent.
      capabilities: wire.CAPABILITIES.filter((name) => name !== wire.CAPABILITY.localhost),
    })
  }

  if (!pairingOpen() || token !== pairing.token) {
    return refuse(client, 'unauthenticated', 'That pairing code is not right.')
  }

  const id = crypto.randomUUID()
  const secret = crypto.randomBytes(32).toString('base64url')
  const credential = `${id}.${secret}`
  const device = {
    id,
    name: message.device?.name || 'Unnamed device',
    platform: message.device?.platform || 'unknown',
    publicKey: client.devicePublicKey.toString('hex'),
    credential: digestOf(credential),
    approved: false,
    pairedAt: Date.now(),
  }
  identity.devices = identity.devices.filter((entry) => entry.publicKey !== device.publicKey)
  identity.devices.push(device)
  saveIdentity(identity)
  pairing = null

  log(`${device.name} paired · fingerprint ${sealed.fingerprint(client.devicePublicKey)} · press "a" to approve`)

  // Paired and deliberately not admitted: the credential still has to travel, or the phone can
  // never come back. Same two frames the tailnet server sends.
  sendJson(client, {
    t: 'welcome',
    protocol: PROTOCOL_VERSION,
    deviceId: id,
    deviceName: device.name,
    token: credential,
    sessions: [],
  })
  refuse(client, 'unauthorized', 'Paired. Approve this device on the Mac, then reconnect.')
}

/* ------------------------------------------------------------ relay wire -- */

/**
 * The host's own WebSocket client.
 *
 * Hand-rolled because the frames have to be **masked** — RFC 6455 §5.1 makes that mandatory in
 * this direction and the relay enforces it — and because the host secret travels in a header,
 * which Node's built-in `WebSocket` has no way to set.
 */
function maskedFrame(opcode, payload) {
  const mask = crypto.randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  const length = masked.length
  let header
  if (length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | length
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  header[0] = 0x80 | opcode
  return Buffer.concat([header, mask, masked])
}

function connectAsHost() {
  const key = crypto.randomBytes(16).toString('base64')
  const request = http.request({
    host: '127.0.0.1',
    port: PORT,
    path: '/v1/host',
    headers: {
      Connection: 'Upgrade',
      Upgrade: 'websocket',
      'Sec-WebSocket-Key': key,
      'Sec-WebSocket-Version': '13',
      'x-deck-host-secret': identity.hostSecret.toString('base64url'),
    },
  })

  request.on('upgrade', (_res, socket) => {
    socket.setNoDelay(true)
    const reader = new wsFrame.FrameReader(128 * 1024, 'client')
    const channels = new Map()

    const write = (payload) => socket.write(maskedFrame(wsFrame.OPCODE.binary, payload))

    socket.on('data', (chunk) => {
      const batch = reader.push(chunk)
      for (const frame of batch.frames) {
        if (frame.opcode === wsFrame.OPCODE.ping) {
          socket.write(maskedFrame(wsFrame.OPCODE.pong, frame.payload))
          continue
        }
        if (frame.opcode !== wsFrame.OPCODE.binary) continue
        const envelope = rendezvous.decodeEnvelope(frame.payload)
        if (!envelope) continue
        const key = envelope.channel.toString('hex')

        if (envelope.type === rendezvous.ENVELOPE.open) {
          const client = {
            channel: null,
            deviceId: null,
            deviceName: '',
            devicePublicKey: null,
            attached: new Set(),
            /** Made on the first `upload` verb, torn down with the channel. See `deskFor`. */
            uploads: null,
            send: (payload) => write(rendezvous.encodeEnvelope(rendezvous.ENVELOPE.data, envelope.channel, payload)),
            close: () => {
              write(rendezvous.encodeEnvelope(rendezvous.ENVELOPE.close, envelope.channel, Buffer.alloc(0)))
              channels.delete(key)
              clients.delete(client)
              // A half-written `.part` file left in the uploads folder wearing a real name is the
              // one piece of state a dropped socket must not leave behind.
              client.uploads?.closeAll()
              client.uploads = null
            },
          }
          channels.set(key, client)
          clients.add(client)
          log('guest channel opened')
          continue
        }

        const client = channels.get(key)
        if (!client) continue

        if (envelope.type === rendezvous.ENVELOPE.close) {
          channels.delete(key)
          clients.delete(client)
          client.uploads?.closeAll()
          client.uploads = null
          log('guest channel closed')
          continue
        }

        if (!client.channel) {
          // First payload on a channel is `[version][Noise IK message]` — 81 bytes — and nothing
          // else is accepted here. `readSealedHandshake` is the desktop's own function, imported
          // rather than re-read from the spec, which is the only version of this check that is
          // guaranteed to refuse exactly what a real Mac refuses.
          const opened = relayWire.readSealedHandshake(envelope.payload, relayWire.HANDSHAKE_OPEN_BYTES)
          if (!opened.ok) {
            log(
              `handshake refused: ${opened.reason} ` +
                `(${envelope.payload.length} bytes, expected ${relayWire.HANDSHAKE_OPEN_BYTES})`,
            )
            client.close()
            continue
          }
          try {
            const answered = sealed.respondToHandshake(identity.static, opened.message, (publicKey) => {
              return Boolean(deviceByKey(publicKey)) || pairingOpen()
            })
            client.channel = answered.transport
            client.devicePublicKey = answered.devicePublicKey
            client.send(relayWire.withSealedVersion(answered.reply))
            log(`handshake ok · device ${sealed.fingerprint(answered.devicePublicKey)}`)
          } catch (error) {
            log(`handshake refused: ${error.message}`)
            client.close()
          }
          continue
        }

        try {
          onProtocol(client, client.channel.receive(envelope.payload).toString('utf8'))
        } catch (error) {
          log(`frame refused: ${error.message}`)
          client.close()
        }
      }
      if (!batch.ok) socket.destroy()
    })

    socket.on('close', () => {
      log('relay connection closed; reconnecting in 1s')
      clients.clear()
      setTimeout(connectAsHost, 1000)
    })
    socket.on('error', () => socket.destroy())

    log(`claimed host id ${hostId}`)
  })

  request.on('error', (error) => {
    log(`could not reach the relay: ${error.message}`)
    setTimeout(connectAsHost, 1000)
  })
  request.end()
}

/* ------------------------------------------------------------------- cli -- */

function log(line) {
  process.stdout.write(`[host] ${line}\n`)
}

const relay = rendezvous.createRelayServer({ heartbeatMs: 15_000 })
relay.server.listen(PORT, () => {
  log(`relay listening on 0.0.0.0:${PORT} (guests: ${RELAY_URL}/v1/join?host=${hostId})`)
  connectAsHost()

  createSession('zsh · home', process.env.SHELL || '/bin/zsh', ['-il'], process.env.HOME)
  createSession('terminaldeck / android', process.env.SHELL || '/bin/zsh', ['-il'], path.join(REPO, 'android'))

  const code = newPairingCode()
  log(`fingerprint of this Mac: ${sealed.fingerprint(identity.static.publicKey)}`)
  log(`pairing code (5 min):\n\n${pairingCodeText()}\n`)
  log('keys: p = new pairing code · a = approve · l = list · r = revoke all · q = quit')
})

// Keys are read whether or not stdin is a terminal: the Android verification rig drives this
// process from a FIFO, and a control channel that only exists when a human is watching is a
// control channel that cannot be scripted.
if (process.stdin.isTTY) process.stdin.setRawMode(true)
process.stdin.resume()
process.stdin.on('data', (data) => {
  for (const key of data.toString()) {
    if (key === 'q' || key === '\u0003') process.exit(0)
    if (key === 'p') {
      newPairingCode()
      log(`pairing code (5 min):\n\n${pairingCodeText()}\n`)
    }
    if (key === 'a') {
      let approved = 0
      for (const device of identity.devices) {
        if (!device.approved) {
          device.approved = true
          approved += 1
        }
      }
      saveIdentity(identity)
      log(approved === 0 ? 'nothing waiting for approval' : `approved ${approved} device(s)`)
    }
    if (key === 'l') {
      log(`host ${hostId} · devices:`)
      for (const device of identity.devices) {
        log(`  ${device.approved ? '\u2713' : '\u00b7'} ${device.name} (${device.platform}) ${device.id}`)
      }
      log(`sessions: ${listSessions().map((s) => `${s.id}=${s.status}`).join(', ') || 'none'}`)
    }
    if (key === 'r') {
      identity.devices = []
      saveIdentity(identity)
      log('revoked every device')
    }
  }
})
