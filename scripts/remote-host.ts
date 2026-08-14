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
 *   scripts/remote-host.sh [--relay-port 8787] [--approve-after 4000] [--name b]
 *
 * `--name` is what makes two of these a *pair of machines* rather than one
 * machine started twice — see `NAME` below. A second host is:
 *
 *   scripts/remote-host.sh --name b --relay-port 8797
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
 *   curl 127.0.0.1:8788/uploads    what files have landed, with digests
 *   curl '127.0.0.1:8788/scrollback?session=<id>'  what a session's PTY holds
 *   curl '127.0.0.1:8788/input?session=<id>'       what the phone typed into it
 *   curl '127.0.0.1:8788/stop-tunnel?connection=<id>&tunnel=<id>'
 *
 * `/stop-tunnel` is the Mac's Stop button, reachable from a script. It goes
 * through `server.stopTunnel`, which is the same call the desktop panel makes.
 *
 * ## `/pair` is not optional after the first minute
 *
 * A pairing token is worth **60 seconds** and one redemption, and the *pairing
 * desk* is only open while one is live — so a code printed at startup does not
 * merely expire, it closes the door the sealed handshake comes through. The
 * refusal that follows reads as a crypto failure and is not one. Mint a code
 * immediately before using it.
 *
 * Minting also **replaces** the live token rather than adding to it, which is
 * why nothing here re-mints on a timer: that would invalidate the code somebody
 * is halfway through typing. This was tried, and it is how the two-host UI test
 * came to fail with "that pairing code is not right" against a code it had just
 * been handed.
 */

import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import { mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
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
/**
 * Which harness host this is, and therefore whose state directory it uses.
 *
 * There is a name here at all because of multi-host: proving a phone holds two
 * machines at once needs two of these running, and everything that makes a host
 * *a* host lives in this directory — `host-identity.ts` derives the host id from
 * the key it finds here, `RemoteAuth` keeps its device list here, and `mint`
 * writes the pairing URI here. Two processes sharing it are not two machines.
 * They are one machine's identity, opened twice, racing each other's writes: the
 * phone would pair with a second host id it had already paired with, the second
 * record would land on top of the first, and the run would reproduce exactly the
 * bug multi-host exists to prevent — while proving nothing about the code.
 *
 * Defaulted so every existing invocation, script and note keeps working
 * unchanged; `--name b` is the whole of the second host.
 */
const NAME = flag('name', '')
const STORAGE = resolve(REPO, NAME === '' ? '.harness/.remote-host' : `.harness/.remote-host-${NAME}`)
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

/**
 * Everything a phone has typed into each session, as it arrived here.
 *
 * The half a phone cannot prove, and the half a *screen* cannot prove either.
 * `/scrollback` is what the shell echoed, which sounds like the same thing and
 * is not: a shell's line editor repaints, and when the input is wider than the
 * terminal `zle` shows a moving *window* into it — the whole line is never on
 * screen at once, and no rendering width reconstructs it. Checking a literal
 * against the echo therefore fails for text that unquestionably arrived, which
 * is the worst kind of test: it reports the transport broken when the shell is
 * merely doing its job.
 *
 * So this records the bytes at the point the desktop hands them to the PTY —
 * after the sealed channel, after the relay, after `server.ts` has authorised
 * them for this session. Nothing about the shell can flatter or hide it.
 *
 * Harness-only, on loopback, and deliberately not part of the protocol. Bounded
 * because this process runs for hours and a phone can type a lot.
 */
const INPUT_LOG_LIMIT = 64 * 1024
const inputLog = new Map<string, string>()

function recordInput(id: string, data: string): void {
  const so_far = inputLog.get(id) ?? ''
  const next = so_far + data
  inputLog.set(id, next.length > INPUT_LOG_LIMIT ? next.slice(-INPUT_LOG_LIMIT) : next)
}

const fanout = new SessionFanout({
  list: () => ptys.list(),
  write: (id, data) => {
    recordInput(id, data)
    return ptys.write(id, data)
  },
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
/**
 * The relay this process is running, when it is running one.
 *
 * Declared out here rather than inside the branch so `shutdown` can close it. It was scoped to the
 * `if` for a few minutes and the symptom was not a compile error — `--relay-url` made `relay`
 * genuinely absent, so TypeScript was right to allow neither reading — it was a `ReferenceError`
 * thrown out of the SIGINT handler, which killed the harness on its way down and left the port
 * held. Null when an external relay was named.
 */
let relay: ReturnType<typeof createRelayServer> | null = null
if (relayUrl === '') {
  relay = createRelayServer({ heartbeatMs: 15_000 })
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
    /**
     * What has landed here, with a digest of each file.
     *
     * The half of a file transfer a phone cannot prove. The phone can show a bar
     * reaching the end and a path on screen and still be wrong about both, so a
     * scripted check asks *this* side what it actually has — and asks for the
     * SHA-256 rather than the size, because a truncated file has a plausible size
     * and a wrong digest.
     */
    case '/uploads': {
      let names: string[] = []
      try {
        names = readdirSync(UPLOADS)
      } catch {
        // Nothing has been sent yet, so the folder does not exist. That is an
        // empty list, not an error — it is the answer to the question asked.
      }
      return answer(
        names.map((name) => {
          const path = resolve(UPLOADS, name)
          return {
            name,
            path,
            bytes: statSync(path).size,
            sha256: createHash('sha256').update(readFileSync(path)).digest('hex'),
          }
        }),
      )
    }
    case '/ports':
      return void scanDevPorts(true).then((ports) => answer(ports))
    /**
     * What a session's terminal actually has on it.
     *
     * The half a phone cannot prove. A phone showing a line in its terminal is
     * good evidence — nothing echoes locally, so those characters came back from
     * this machine — but it is still the phone's word for it, and the claim being
     * checked is *the line reached the agent's PTY on the Mac*. This answers that
     * from the PTY's own scrollback, through `PtyManager`, which is the app's.
     *
     * Read-only, and a harness endpoint on loopback: it writes nothing and it is
     * not part of the product's protocol.
     */
    case '/scrollback': {
      const wanted = url.searchParams.get('session') ?? ''
      const rows = ptys
        .list()
        .filter((session) => wanted === '' || session.id === wanted)
        .map((session) => ({
          id: session.id,
          title: session.title,
          cwd: session.cwd,
          // `ptys`, not `sessions`: `SessionAccess` is the phone-facing surface
          // and has no scrollback on it — the emulator does. Reading it off the
          // wrong object threw out of an HTTP handler and took the whole host
          // down mid-test, which is a good argument for the harness never
          // reaching for anything it has not been handed.
          text: ptys.scrollback(session.id),
        }))
      return answer(rows)
    }
    /**
     * What the phone typed, as the desktop delivered it to the PTY.
     *
     * Use this rather than `/scrollback` to assert on a literal. See the comment
     * on `inputLog`: the echo is the shell's rendering of the input, not the
     * input, and for anything wider than the terminal the two genuinely differ.
     */
    case '/input': {
      const wanted = url.searchParams.get('session') ?? ''
      const rows = [...inputLog.entries()]
        .filter(([id]) => wanted === '' || id === wanted)
        .map(([id, text]) => ({ id, bytes: Buffer.byteLength(text), text }))
      return answer(rows)
    }
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
      response.end('state | ports | uploads | scrollback | input | pair | approve | stop-tunnel | quit\n')
  }
})
control.listen(CONTROL_PORT, '127.0.0.1')

log(`host id      ${identity.hostId}`)
log(`key          ${identity.fingerprint}`)
log(`control      http://127.0.0.1:${CONTROL_PORT}/state`)
log(`pair with    ${mint()}`)

const shutdown = (): void => {
  void server.stop().then(() => relay?.close()).then(() => process.exit(0))
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
