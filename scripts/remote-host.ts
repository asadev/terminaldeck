/**
 * The desktop's remote endpoint, run as a plain Node process, plus a relay.
 *
 * This exists to answer one question honestly: does the localhost feature work
 * between a real phone client and the **real** desktop code, or only in unit
 * tests? So nothing here is a stand-in for the thing under test.
 * `createRemoteServer`, `createRemoteEndpoint`, `RemoteAuth`, the tunnel hub,
 * `createRelayClient` and the relay itself are all imported and run as they
 * ship. What is faked is exactly one thing, and it is the part this is not
 * about: the terminal sessions, because `PtyManager` needs Electron and a phone
 * looking at a dev server does not need a shell.
 *
 * It is deliberately not `ios/Harness/host-standin.ts`, which reimplements the
 * host side of the relay envelope in order to test the *phone's* crypto against
 * known-good pieces. This one has the opposite job — every byte on the desktop
 * side is production code — so the two are not the same program and merging them
 * would weaken both.
 *
 *   scripts/remote-host.sh [--relay-port 8787] [--approve-after 4000]
 *
 * It prints a pairing URI and writes it to `.harness/.remote-host/pairing.txt`:
 *
 *   xcrun simctl openurl booted "$(cat .harness/.remote-host/pairing.txt)"
 *
 * A control server on the next port up stands in for the human at the Mac,
 * because approving a device is deliberately something software does not do for
 * itself:
 *
 *   curl 127.0.0.1:8788/state      host id, devices, live connections, tunnels
 *   curl 127.0.0.1:8788/approve    be the human
 *   curl 127.0.0.1:8788/pair       mint another code
 *   curl '127.0.0.1:8788/stop-tunnel?connection=<id>&tunnel=<id>'
 *
 * `/stop-tunnel` is the Mac's Stop button, reachable from a script. It goes
 * through `server.stopTunnel`, which is the same call the desktop panel makes.
 */

import { createServer } from 'node:http'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { resolve } from 'node:path'
import { RemoteAuth } from '../src/main/remote/device-auth'
import { loadHostIdentity } from '../src/main/remote/host-identity'
import { createRelayClient } from '../src/main/remote/relay-client'
import { scanDevPorts } from '../src/main/dev-ports'
import { PtyManager } from '../src/main/pty-manager'
import { detectProviders, loginPath, PROVIDERS } from '../src/main/providers'
import { SessionFanout } from '../src/main/remote/session-fanout'
import { remoteSessionCreator } from '../src/main/remote/session-create'
import {
  authenticatorFor,
  createRemoteServer,
  pairingDesk,
  type SessionAccess,
} from '../src/main/remote/server'
import { createRelayServer } from '../relay/src/rendezvous'

const args = process.argv.slice(2)
const flag = (name: string, fallback: string): string => {
  const at = args.indexOf(`--${name}`)
  return at === -1 || at + 1 >= args.length ? fallback : args[at + 1]
}

// An external relay to use instead of spinning up a local one. Without it this
// process is entirely self-contained, which is what it was built for; with it,
// the host registers with the deployed relay exactly as a user's desktop does,
// so the wss:// path and the real certificate are on the wire.
//
//   scripts/remote-host.sh --relay-url wss://relay.terminaldeck.dev
const RELAY_URL = flag('relay-url', '')
const RELAY_PORT = Number(flag('relay-port', '8787'))
const CONTROL_PORT = RELAY_PORT + 1
const APPROVE_AFTER = Number(flag('approve-after', '4000'))
const REPO = process.env.TD_REPO_DIR ?? resolve(import.meta.dirname ?? '.', '..')
const STORAGE = resolve(REPO, '.harness/.remote-host')
/**
 * Where a file sent from the phone lands here.
 *
 * Not the real downloads folder. This process is started and killed by scripts
 * dozens of times a night, and a harness that fills somebody's Downloads with
 * test photos is a harness people stop running. `--fresh` clears it with the
 * rest of the harness state.
 */
const UPLOADS = resolve(STORAGE, 'uploads')

if (args.includes('--fresh')) rmSync(STORAGE, { recursive: true, force: true })
mkdirSync(STORAGE, { recursive: true })

const log = (line: string): void => process.stdout.write(`${new Date().toISOString().slice(11, 19)}  ${line}\n`)

/* ------------------------------------------------------------- sessions -- */

/**
 * Real terminals, through the real `PtyManager`.
 *
 * This used to be a stub, on the grounds that "PtyManager needs Electron". It
 * does not: it imports `node-pty` and `@xterm/headless` and nothing from
 * Electron, and `ios/Harness/run.sh` has been spawning real PTYs from plain
 * Node for weeks. The stub was costing the one thing this script exists for —
 * a phone talking to the *real* desktop code — on the half of the protocol
 * that matters most, and a phone that could only ever be shown an empty list
 * could not exercise attach, replay, input, resize or `create` at all.
 *
 * `SessionFanout` and `remoteSessionCreator` are the app's own, so the folder
 * rule a phone meets here is the folder rule it meets on a Mac.
 *
 * One thing is genuinely not the app's: agent **profiles**. `profiles.ts`
 * imports `electron` for `app.getPath`, so a session started here runs with no
 * redirected config directory — the default login for whichever CLI it starts.
 * That is a real difference and it is named rather than papered over.
 */
const ptys = new PtyManager(
  (id, data) => fanout.noteData(id, data),
  (id, exitCode) => fanout.noteExit(id, exitCode),
  (id, status) => fanout.noteStatus(id, status),
)

/**
 * The folders a phone may name here.
 *
 * On a Mac this is the desktop's project list; this process has no store, so it
 * is the repository plus whatever is already running — which is the same rule
 * (*a folder this host is already offering*), sourced from what this host has.
 */
const PROJECTS = [REPO, resolve(REPO, 'ios'), resolve(REPO, 'pwa')]

const fanout = new SessionFanout({
  list: () => ptys.list(),
  write: (id, data) => ptys.write(id, data),
  resize: (id, cols, rows) => ptys.resize(id, cols, rows),
  scrollback: (id) => ptys.scrollback(id),
  create: remoteSessionCreator({
    folders: () => [...PROJECTS, ...ptys.list().map((session) => session.cwd)],
    home: () => homedir(),
    spawn: async (input) => {
      const path = await loginPath()
      const available = await detectProviders()
      // Same fallback as the app: never spawn a binary that is not there.
      // TD_FORCE_SHELL exists so a scripted check can assert on a literal
      // marker: with an agent CLI installed the default lands in its TUI, where
      // typed text goes into a prompt box rather than to a shell that echoes it.
      const provider =
        process.env.TD_FORCE_SHELL === '1' ? 'shell' : available.claude ? 'claude' : 'shell'
      const spec = PROVIDERS[provider]
      // `spec.spawn`, not `spec.bin` — identical on macOS, and on Windows the
      // difference between a session and a bare "File not found:". See the
      // note in `providers.ts`.
      const meta = ptys.create(input, {
        provider,
        command: spec.spawn.command,
        args: spec.spawn.args,
        path,
      })
      log(`started      ${meta.id} (${meta.provider}) in ${meta.cwd}`)
      return meta
    },
  }),
})

const sessions: SessionAccess = fanout

/* ------------------------------------------------------------------ run -- */

let relayUrl = RELAY_URL
if (relayUrl === '') {
  const relay = createRelayServer({ heartbeatMs: 15_000 })
  await new Promise<void>((settle) => relay.server.listen(RELAY_PORT, '127.0.0.1', () => settle()))
  relayUrl = `ws://127.0.0.1:${RELAY_PORT}`
  log(`relay        ${relayUrl} (local, this process)`)
} else {
  log(`relay        ${relayUrl} (external)`)
}

const auth = new RemoteAuth(STORAGE)
const desk = pairingDesk(auth)
const identity = loadHostIdentity(STORAGE)

const link = createRelayClient({
  url: relayUrl,
  identity,
  isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
})

const server = createRemoteServer({
  sessions,
  auth: authenticatorFor(auth, desk),
  webRoot: resolve(REPO, 'pwa/dist'),
  certDir: STORAGE,
  // Files sent from a phone. Under the harness directory rather than the real
  // downloads folder, because this process is run over and over by a script and
  // filling somebody's Downloads with test photos is not what a harness is for.
  // Passing it at all is what makes this host advertise the `upload` capability,
  // which is the thing the phone gates its Send File button on.
  uploadsDir: UPLOADS,
  relay: link,
  // No Tailscale in this process. The relay is the only way in, which is also
  // the path the phone client uses in the field.
  readTailnet: async () => ({
    ready: false,
    reason: 'This host runs the relay path only.',
    address: '',
    address6: null,
    dnsName: '',
    magicDns: false,
  }),
  onConnections: (connections) => {
    for (const connection of connections) {
      const tunnels = connection.tunnels.map((t) => `:${t.port} (${t.streams} streams)`).join(', ')
      log(`phone        ${connection.deviceName} — ${tunnels === '' ? 'no tunnels' : tunnels}`)
    }
  },
})

const status = await server.start()
if (!status.running) {
  log(`could not start: ${status.reason ?? 'no reason given'}`)
  process.exit(1)
}

function pairingUri(token: string): string {
  const params = new URLSearchParams({
    v: '1',
    r: relayUrl,
    h: identity.hostId,
    k: identity.keys.publicKey.toString('base64url'),
    t: token,
  })
  return `terminaldeck://pair?${params.toString()}`
}

function mint(): string {
  const uri = pairingUri(desk.create().token)
  writeFileSync(resolve(STORAGE, 'pairing.txt'), `${uri}\n`)
  return uri
}

/**
 * Approve whatever has paired, after a delay.
 *
 * The product requires a human at the Mac and this is a script, so the human is
 * a `setTimeout`. Polled rather than driven by an event because `RemoteAuth`
 * exposes no "a device appeared" callback, and adding one for a test harness
 * would be the harness dictating the shape of the thing it tests.
 */
setInterval(() => {
  for (const device of auth.listDevices()) {
    if (device.approved) continue
    if (Date.now() - device.pairedAt < APPROVE_AFTER) continue
    auth.approveDevice(device.id)
    log(`approved     ${device.name}`)
  }
}, 500).unref()

const control = createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://control.invalid')
  const answer = (body: unknown): void => {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(`${JSON.stringify(body, null, 2)}\n`)
  }

  switch (url.pathname) {
    case '/state':
      return answer({
        hostId: identity.hostId,
        fingerprint: identity.fingerprint,
        relay: server.status().relay,
        devices: auth.listDevices().map((device) => ({ id: device.id, name: device.name, approved: device.approved })),
        connections: server.connections(),
      })
    case '/ports':
      return void scanDevPorts(true).then((ports) => answer(ports))
    case '/pair':
      return answer({ uri: mint() })
    case '/approve': {
      const approved = auth.listDevices().filter((device) => !device.approved).map((device) => device.id)
      for (const id of approved) auth.approveDevice(id)
      return answer({ approved })
    }
    case '/stop-tunnel': {
      const connection = url.searchParams.get('connection') ?? ''
      const tunnel = url.searchParams.get('tunnel') ?? ''
      return answer({ stopped: server.stopTunnel(connection, tunnel) })
    }
    case '/quit':
      answer({ bye: true })
      setTimeout(() => process.exit(0), 50)
      return
    default:
      response.writeHead(404, { 'content-type': 'text/plain' })
      response.end('state | ports | pair | approve | stop-tunnel | quit\n')
  }
})
control.listen(CONTROL_PORT, '127.0.0.1')

log(`host id      ${identity.hostId}`)
log(`key          ${identity.fingerprint}`)
log(`control      http://127.0.0.1:${CONTROL_PORT}/state`)
log(`pair with    ${mint()}`)

const shutdown = (): void => {
  void server.stop().then(() => relay.close()).then(() => process.exit(0))
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
