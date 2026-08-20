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
 *   curl '127.0.0.1:8788/start?cwd=<dir>'          start a session from this side
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
import { homedir, hostname } from 'node:os'
import { resolve } from 'node:path'
import { RemoteAuth } from '../src/main/remote/device-auth'
import { loadHostIdentity } from '../src/main/remote/host-identity'
import { createRelayClient } from '../src/main/remote/relay-client'
import { scanDevPorts } from '../src/main/dev-ports'
import { PtyManager } from '../src/main/pty-manager'
import { detectProviders, loginPath, PROVIDERS } from '../src/main/providers'
import { CopilotAccess } from '../src/main/remote/copilot-access'
import { CopilotRuns, type CopilotChatUpdate } from '../src/main/remote/copilot-runs'
import { asDeviceKind, DeviceKinds, type DeviceKind } from '../src/main/remote/device-kind'
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
/**
 * What this harness approves a device *as*, and therefore whether it gets the
 * copilot.
 *
 * Since 2026-08-19 the two are one question: a device approved as **my device**
 * reaches the copilot automatically and a **guest** never does, with no second
 * connection and no second code (`copilot-access.ts`). So a harness that could
 * only approve — which is what this was — could not put a phone on either side
 * of the only rule the feature has, and the client's whole Copilot tab was
 * unreachable from here.
 *
 *   scripts/remote-host.sh --kind guest    # prove the tab is absent
 *
 * Defaulted to `mine` because that is what a person approving their own phone
 * picks, and because every existing invocation of this script predates the
 * question.
 */
const KIND: DeviceKind = asDeviceKind(flag('kind', 'mine')) ?? 'mine'
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
  (id, data) => {
    fanout.noteData(id, data)
    // And the copilot's conversation, when this session is one. See `chatEcho`.
    chatEcho(id, data)
  },
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
  /*
   * Ending a session, which this host has to do for real.
   *
   * Supplying the method is what makes this process advertise the `close`
   * capability, so a client draws its Close button and the whole path can be
   * exercised without Electron — the same reason `uploadsDir` and `openUrl` are
   * above. It is a genuine `kill` rather than a boolean, for the same reason
   * this file is not a stand-in for the code under test: a host that reported a
   * close it had not performed would let a Close button be "verified" against a
   * row that quietly stayed alive.
   *
   * The membership test is here rather than in `PtyManager` because `kill`
   * returns void, and the difference between "gone" and "there was no such
   * session" is what the device is told.
   */
  close: (id) => {
    if (!ptys.list().some((session) => session.id === id)) return false
    ptys.kill(id)
    log(`closed       ${id}`)
    return true
  },
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

/* ------------------------------------------------------------- copilot -- */

/**
 * The copilot, as a paired device reaches it — and the kind store that decides
 * whether it may.
 *
 * This half of the harness did not exist, and its absence was not neutral. With
 * no `copilot` passed to `createRemoteServer` the welcome carries no `copilot`
 * key at all, which is the *guest* shape on the wire — so every phone that has
 * ever been driven against this script saw a client with no Copilot tab, and a
 * client with no Copilot tab is indistinguishable from a client whose copilot is
 * broken. The one screen this repository keeps shipping defects on was the one
 * screen the harness could not reach.
 *
 * What is real here: `DeviceKinds`, `CopilotAccess` and `CopilotRuns` are the
 * app's own, so the rule a phone meets — *my device gets it, a guest never* — is
 * enforced by the same three files that enforce it on a Mac, including the
 * `copilot.hello` path and the per-frame tier gate in `server.ts`.
 *
 * What is a stand-in, named rather than glossed: there is no `deck-control` and
 * no Claude CLI in this process, so a *run* here is a plain shell, its "chat" is
 * whatever that shell printed, and `desk()` reports the copilot at the machine
 * as stopped because there is no machine to pin one at. Those are the parts a
 * phone cannot tell apart from the real thing anyway — it sees frames — and
 * everything that decides *whether a frame is served* is production code.
 */
const kinds = new DeviceKinds(STORAGE)

/**
 * Approve, having first written down what the device is.
 *
 * The order is the app's (`remote:device:approve`) and it is the property rather
 * than a tidiness preference: `RemoteAuth.verify` starts answering yes the
 * moment the approval lands, so a kind written afterwards leaves an instant in
 * which a device is admitted as a guest and told, correctly, that it has no
 * copilot.
 */
function approve(id: string): void {
  kinds.claim(id, KIND)
  auth.approveDevice(id)
}

const copilotAccess = new CopilotAccess({ isMine: (deviceId) => kinds.kindOf(deviceId) === 'mine' })

/** Where a harness run's config files would go. Under the harness state, never a real copilot folder. */
const COPILOT_ROOT = resolve(STORAGE, 'copilot')
mkdirSync(COPILOT_ROOT, { recursive: true })

/**
 * A run's output, turned into the one chat bubble a phone can read.
 *
 * The real path is `chat-transcript.ts` reading a Claude CLI's JSONL. There is
 * no CLI here, so this is the honest minimum: the bytes the shell printed, with
 * escape sequences dropped, pushed under one growing message id — which is
 * exactly the shape `mergeChat` on the client is built for, so the client code
 * under test is the same code either way.
 */
const chatSinks = new Map<string, { onUpdate: (update: CopilotChatUpdate) => void; text: string }>()

function chatEcho(sessionId: string, data: string): void {
  const sink = chatSinks.get(sessionId)
  if (!sink) return
  // eslint-disable-next-line no-control-regex
  sink.text += data.replace(/\u001b\[[0-9;?]*[a-zA-Z]/g, '').replace(/\r/g, '')
  sink.onUpdate({
    messages: [{ id: `${sessionId}-out`, role: 'agent', text: sink.text.slice(-4000), at: Date.now() }],
    reset: false,
  })
}

const copilot = new CopilotRuns({
  links: copilotAccess,
  // No `deck-control` in this process, so nothing can be confirmed here and a
  // phone is told there is nothing waiting — which is the truth, not a stub.
  consent: () => null,
  callers: { set: () => undefined, delete: () => false },
  // A URL rather than null, because null is the app's way of saying *the
  // copilot's tools are not running* and would leave every Start button on the
  // phone refusing with a sentence about a machine this harness is standing in
  // for. The address is this process's own control port; nothing dials it.
  endpoint: () => ({ url: `http://127.0.0.1:${CONTROL_PORT}/harness-tools` }),
  copilotRoot: () => COPILOT_ROOT,
  spawn: async (request) => {
    const spec = PROVIDERS.shell
    const meta = ptys.create(
      { cwd: request.cwd },
      { provider: 'shell', command: spec.spawn.command, args: spec.spawn.args, path: await loginPath() },
    )
    log(`copilot run  ${meta.id} for ${request.deviceId}`)
    return meta.id
  },
  isAlive: (id) => ptys.list().some((session) => session.id === id && session.exitCode === null),
  stop: (id) => ptys.kill(id),
  say: (id, text) => ptys.write(id, `${text}\n`),
  interrupt: (id) => ptys.write(id, '\u0003'),
  desk: () => ({
    status: 'stopped',
    profile: null,
    signedIn: null,
    available: true,
    reason: null,
  }),
  cost: () => ({ tools: 0, turnTokens: 0 }),
  sessions: () =>
    ptys.list().map((session) => ({
      id: session.id,
      title: session.title,
      cwd: session.cwd,
      provider: session.provider,
      status: session.exitCode === null ? 'running' : 'exited',
      startedAt: session.createdAt,
      originRunId: null,
    })),
  log: () => ({ rows: [], more: false }),
  chat: (sessionId, onUpdate) => {
    chatSinks.set(sessionId, { onUpdate, text: '' })
    return () => void chatSinks.delete(sessionId)
  },
})

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
  /*
   * "Open it on the machine", for a host with no machine to open it on.
   *
   * Supplying this is what makes the harness advertise the `web` capability, so
   * the web client draws its Open button and the whole path can be exercised
   * without Electron. It logs and answers true rather than pretending to open
   * anything: this process has no window, and the one thing it must not do is
   * report an open that did not happen — so what it reports is exactly what
   * happened, which is that a device asked and this host wrote it down.
   */
  openUrl: (url: string): boolean => {
    log(`web.open     ${url}`)
    return true
  },
  // The copilot layer, and who it is shared with. Passing the first is what
  // makes this host advertise the `copilot` capability at all; the second is
  // what filters the welcome per device, so a guest is sent no `copilot` key.
  copilot,
  copilotEligible: (deviceId) => kinds.kindOf(deviceId) === 'mine',
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

/**
 * Mint a code, and **publish it** so six digits alone can find this host.
 *
 * `desk.create()` was enough while the only client that pairs with this harness
 * was iOS, which is handed the whole `terminaldeck://pair?…` URI and never needs
 * to look anything up. The web client has no such door: it is six digits typed
 * into a field, looked up at the relay's rendezvous, which is exactly what
 * `desk.show(offer)` claims a slot for and `desk.create()` does not.
 *
 * So a harness that only ever called `create` could not be paired with from a
 * browser at all, and the symptom was a client that said "Connecting…" against a
 * host whose device list stayed empty — a lookup that found nothing, reported by
 * neither side, because neither side was wrong.
 *
 * Awaited, because `show` returns once the slot is claimed and a code handed out
 * before that is a code the relay does not know yet.
 */
async function mint(): Promise<string> {
  const shown = await desk.show({
    relayUrl,
    hostId: identity.hostId,
    publicKey: identity.keys.publicKey.toString('base64'),
    name: hostname(),
    platform: process.platform,
  })
  const uri = pairingUri(shown.code.token)
  writeFileSync(resolve(STORAGE, 'pairing.txt'), `${uri}\n`)
  if (!shown.findable) log('pair         the relay did not take the code; only the URI will work')
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
    approve(device.id)
    log(`approved     ${device.name} as ${KIND}`)
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
    /**
     * What each device was approved as, and what that buys it.
     *
     * The copilot is not a separate connection any more, so this is the only
     * thing a run can read to explain a Copilot tab that is there or missing.
     */
    case '/kinds':
      return answer(
        auth.listDevices().map((device) => ({
          id: device.id,
          name: device.name,
          approved: device.approved,
          kind: kinds.kindOf(device.id),
          copilot: copilotAccess.linked(device.id),
        })),
      )
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
    /**
     * Start a session here, from this side.
     *
     * The desk's own `create`, reached without a phone. It is here for one test
     * and the reason is worth writing down: proving that a keystroke lands on the
     * machine whose session is on screen **and on no other** needs a session on
     * each of two machines, and getting there through the phone's New Session
     * button makes the proof depend on the create path as well as on the routing
     * path. When those are tangled, a create that quietly does nothing reads as a
     * routing failure — which is exactly what happened, and it cost an hour of
     * looking at the wrong half.
     *
     * So the setup is done from here and the phone is asked only the question
     * being tested. Creating a session *from* the phone is still covered, by
     * `InspectUITests`, which needs one and makes one.
     */
    case '/start': {
      const start = sessions.create
      if (!start) return answer({ error: 'this host cannot start sessions' })
      const cwd = url.searchParams.get('cwd') ?? REPO
      return void start
        .call(sessions, { cwd })
        .then((outcome) => answer(outcome))
        .catch((error: unknown) => answer({ ok: false, error: String(error) }))
    }
    case '/pair':
      return void mint().then((uri) => answer({ uri }))
    case '/approve': {
      const approved = auth.listDevices().filter((device) => !device.approved).map((device) => device.id)
      for (const id of approved) approve(id)
      return answer({ approved, kind: KIND })
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
      response.end(
        'state | kinds | ports | uploads | scrollback | input | start | pair | approve | stop-tunnel | quit\n',
      )
  }
})
control.listen(CONTROL_PORT, '127.0.0.1')

log(`host id      ${identity.hostId}`)
log(`key          ${identity.fingerprint}`)
log(`control      http://127.0.0.1:${CONTROL_PORT}/state`)
log(`pair with    ${await mint()}`)

const shutdown = (): void => {
  void server.stop().then(() => relay?.close()).then(() => process.exit(0))
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
