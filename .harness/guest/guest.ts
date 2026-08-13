/**
 * A real relay guest, run from the Mac against the Windows host.
 *
 * There is no scriptable guest in the repo — `ios/Harness/host-standin.ts` and
 * `android/tools/dev-host.cjs` are both *host* stand-ins for testing the phones,
 * and the PWA builds its socket from `window.location.host`, so it only ever
 * talks to whoever served it and never to a relay. So this is the phone: it
 * uses the product's own `sealed.ts` initiator and the constants in
 * `relay-wire.ts`, and nothing about the desktop side is stubbed.
 *
 *   node guest.mjs "<pairing uri>"
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { startHandshake, finishHandshake, generateStatic } from '../../src/shared/sealed'
import {
  RELAY_GUEST_PATH,
  HANDSHAKE_REPLY_BYTES,
  readSealedHandshake,
  withSealedVersion,
} from '../../src/shared/relay-wire'
import { PROTOCOL_VERSION } from '../../src/main/remote/protocol'

const uri = process.argv[2]
if (!uri) throw new Error('pass the pairing URI')
const params = new URLSearchParams(uri.slice(uri.indexOf('?') + 1))
const relay = params.get('r')!
const hostId = params.get('h')!
const hostKey = Buffer.from(params.get('k')!, 'base64url')
const token = params.get('t')!

const url = `${relay}${RELAY_GUEST_PATH}?host=${encodeURIComponent(hostId)}`
console.log(`[guest] dialling ${url}`)

// The device key has to survive a restart: the host answers the first
// connection with "Paired. Approve this device on the Mac, then reconnect", and
// a guest that generated a fresh key each run would come back as a stranger
// every time and never get past it.
const KEYFILE = new URL('./device-key.json', import.meta.url).pathname
const CREDFILE = new URL('./credential.txt', import.meta.url).pathname
let device: ReturnType<typeof generateStatic>
if (existsSync(KEYFILE)) {
  const saved = JSON.parse(readFileSync(KEYFILE, 'utf8'))
  device = {
    publicKey: Buffer.from(saved.publicKey, 'base64'),
    privateKey: Buffer.from(saved.privateKey, 'base64'),
  }
  console.log('[guest] reusing saved device key')
} else {
  device = generateStatic()
  writeFileSync(
    KEYFILE,
    JSON.stringify({
      publicKey: device.publicKey.toString('base64'),
      privateKey: device.privateKey.toString('base64'),
    }),
  )
  console.log('[guest] generated a new device key')
}
const started = startHandshake(device, hostKey)

const ws = new WebSocket(url)
ws.binaryType = 'arraybuffer'

let transport: ReturnType<typeof finishHandshake> | null = null
const seen: string[] = []
let sessionId = ''
let output = ''

const send = (msg: unknown): void => {
  ws.send(transport!.send(Buffer.from(JSON.stringify(msg), 'utf8')))
}

const done = (code: number): void => {
  console.log('\n---- TRANSCRIPT ----')
  console.log(output)
  console.log('---- RESULT ----')
  console.log('messages seen        :', seen.join(', '))
  console.log('session id           :', sessionId || '(none)')
  const proof = /terminal-deck-remote-proof/.test(output)
  const winPath = /C:\\/i.test(output)
  console.log('marker echoed back   :', proof)
  console.log('Windows path in output:', winPath)
  process.exit(code === 0 && proof ? 0 : 1)
}

ws.onopen = () => {
  console.log('[guest] socket open, sending Noise IK message 1')
  ws.send(withSealedVersion(started.message))
}

ws.onerror = (e: unknown) => {
  console.log('[guest] socket error', String(e))
}

ws.onclose = (e: CloseEvent) => {
  console.log(`[guest] closed code=${e.code} reason=${e.reason}`)
  if (!transport) process.exit(1)
}

ws.onmessage = (event: MessageEvent) => {
  const frame = Buffer.from(event.data as ArrayBuffer)
  if (!transport) {
    const opened = readSealedHandshake(frame, HANDSHAKE_REPLY_BYTES)
    if (!opened.ok) {
      console.log('[guest] bad handshake reply:', opened.reason)
      process.exit(1)
    }
    transport = finishHandshake(started.pending, opened.message)
    console.log('[guest] sealed channel established')
    const credential = existsSync(CREDFILE) ? readFileSync(CREDFILE, 'utf8').trim() : ''
    console.log(credential === '' ? '[guest] hello with the pairing token' : '[guest] hello with the stored credential')
    send({
      t: 'hello',
      protocol: PROTOCOL_VERSION,
      token: credential === '' ? token : credential,
      device: { name: 'claude-guest', platform: 'node' },
    })
    return
  }

  const msg = JSON.parse(transport.receive(frame).toString('utf8'))
  if (msg.t !== 'output') seen.push(msg.t)

  switch (msg.t) {
    case 'welcome':
      console.log(`[guest] welcome — capabilities: ${(msg.capabilities ?? []).join(',') || 'none'}`)
      console.log(`[guest] existing sessions: ${msg.sessions.length}`)
      // A pairing token is spent on first use and the server hands back a
      // long-lived credential in its place. A guest that keeps replaying the
      // pairing token re-pairs on every connection and is told to go and get
      // approved, forever — which is exactly what happened before this.
      if (typeof msg.token === 'string' && msg.token !== '') {
        writeFileSync(CREDFILE, msg.token)
        console.log('[guest] stored the credential handed back by the host')
      }
      // Start a fresh one rather than attaching to whatever is there: this has
      // to prove a shell runs on the Windows box, not that a list is non-empty.
      send({ t: 'create', cols: 100, rows: 30 })
      break
    case 'created':
    case 'session':
      sessionId = msg.session?.id ?? msg.id
      console.log(`[guest] session created: ${sessionId} cwd=${msg.session?.cwd}`)
      send({ t: 'attach', id: sessionId, cols: 100, rows: 30 })
      break
    case 'attached':
      console.log(`[guest] attached to ${msg.id}`)
      setTimeout(() => send({ t: 'input', id: sessionId, data: 'echo terminal-deck-remote-proof\r' }), 1500)
      setTimeout(() => send({ t: 'input', id: sessionId, data: 'cd\r' }), 3500)
      setTimeout(() => done(0), 9000)
      break
    case 'output':
      output += msg.data
      break
    case 'error':
      console.log(`[guest] ERROR ${msg.code}: ${msg.message}`)
      break
    default:
      break
  }
}

setTimeout(() => {
  console.log('[guest] timed out')
  done(1)
}, 45_000)
