/**
 * **The handover, end to end, against a real host with a real browser in it.**
 *
 * The host half of this feature was tested at the wire and the phone half
 * against frame shapes, and until this ran nothing had carried one agent's
 * request through one host to one phone screen and back. That is what this
 * drives.
 *
 *     ios/Harness/live-handover.sh
 *
 * ## What is real here and what is not
 *
 * Real: `out/headless/host.mjs` — the product's own host, the same
 * `createHostCore`, `registerRemoteIpc`, `BrowserDrive`, `PageCast` and
 * `deck-control` the window build links, launching a **real Chromium** and
 * serving a **real login page**. Real: the relay (`relay/src/rendezvous.ts`,
 * this repository's own, on loopback). Real: the agent — a `Client` from the
 * MCP SDK the Claude CLI itself uses, dialling the loopback endpoint with the
 * token out of the config file the host minted for *this session's launch*.
 * Real: the second watcher — the product's own `pairWithCode` and
 * `dialMachine`, a second device on the same wire.
 *
 * Not real: nobody types at the Mac. The device is approved through
 * `remote:device:approve`, which is the same control command the CLI's `pair`
 * sends when a person presses Enter. That is the one human step this stands in
 * for, and `live-desktop.ts` makes the same trade for the same reason.
 *
 * ## Why the rendezvous slot goes to the public relay and nothing else does
 *
 * The phone has no relay setting: `RendezvousLookup.defaultRelay` in
 * `Rendezvous.swift` is `wss://relay.terminaldeck.dev` and nothing overrides
 * it. So six digits are always *looked up* there. What the lookup answers with
 * is an **offer**, and the offer names the relay the phone then dials — which
 * here is `ws://127.0.0.1`, this process's own.
 *
 * `ios/Harness/host-standin.ts` settled this argument already, in the same
 * words: what goes onto the public relay is a slot named by six digits that
 * expire in a minute, holding an address that is useless to anybody who is not
 * on this Mac. Every byte of the session that follows — the page, the frames,
 * the keystrokes, the handover — stays on loopback.
 *
 * The host itself is pointed at the loopback relay with `TERMINALDECK_RELAY_URL`,
 * so its own beacon lands there; this process publishes the *same* code's slot
 * at the public relay as well, through the product's own `startBeacon`.
 *
 * ## How it is sequenced, and why through files
 *
 * The phone and this process take turns, and neither can call the other. So
 * they leave notes: the test writes `<proof>/steps/<name>` when it has reached
 * a stage, this writes `<proof>/cues/<name>` when it has done its part. It is
 * the mechanism `live-localhost.sh` already uses for the pairing hand-off,
 * generalised to nine stages. A simulator process is a plain macOS process, so
 * both ends read and write the same host paths.
 *
 * Everything this observes goes into `<proof>/evidence.jsonl` as it happens —
 * the agent's refusals included, which is the half of the claim a screenshot
 * cannot carry.
 */

import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync, appendFileSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { createRelayServer } from '../../relay/src/rendezvous'
import { callControl, readDaemonRecord, type ControlResponse, type DaemonRecord } from '../../src/headless/control'
import { startBeacon } from '../../src/main/remote/machines/rendezvous'
import { pairWithCode } from '../../src/main/remote/machines/pair'
import { dialMachine, type GuestChannel } from '../../src/main/remote/machines/dial'
import { CAPABILITY, PROTOCOL_VERSION, parseServerMessage, type ServerMessage } from '../../src/main/remote/protocol'
import type { Device } from '../../src/main/remote/device-auth'
import type { DeviceFolderGrant } from '../../src/main/remote/folder-grants'
import type { PairingToken } from '../../src/main/remote/device-auth'
import type { HostStatus } from '../../src/headless/host'

/* ------------------------------------------------------------- arguments -- */

const argv = process.argv.slice(2)
const flag = (name: string, fallback: string): string => {
  const at = argv.indexOf(`--${name}`)
  return at === -1 || at + 1 >= argv.length ? fallback : argv[at + 1]
}

const RELAY_PORT = Number(flag('relay-port', '8877'))
const PAGE_PORT = Number(flag('page-port', '8879'))
const STATE = flag('state', '')
const PROOF = flag('proof', '')
const FOLDER = flag('folder', '')
/** Where the six digits are looked up. See the header; not where the session runs. */
const RENDEZVOUS = flag('rendezvous', 'wss://relay.terminaldeck.dev')

if (STATE === '' || PROOF === '') {
  process.stderr.write('usage: live-handover --state <dir> --proof <dir> [--folder <dir>]\n')
  process.exit(2)
}

const RELAY_URL = `ws://127.0.0.1:${RELAY_PORT}`
const PAGE_URL = `http://127.0.0.1:${PAGE_PORT}/login`

const STEPS = join(PROOF, 'steps')
const CUES = join(PROOF, 'cues')
mkdirSync(STEPS, { recursive: true })
mkdirSync(CUES, { recursive: true })

const stamp = (): string => new Date().toISOString().slice(11, 23)
const log = (line: string): void => {
  process.stdout.write(`${stamp()}  ${line}\n`)
}

/** Everything observed, as it happens. The file is the deliverable. */
function note(what: string, detail: Record<string, unknown> = {}): void {
  const row = { at: new Date().toISOString(), what, ...detail }
  appendFileSync(join(PROOF, 'evidence.jsonl'), `${JSON.stringify(row)}\n`)
  log(`${what} ${JSON.stringify(detail)}`)
}

/* ------------------------------------------------------- the turn-taking -- */

const cue = (name: string, detail: Record<string, unknown> = {}): void => {
  writeFileSync(join(CUES, name), JSON.stringify(detail))
  log(`cue → ${name}`)
}

async function step(name: string, timeoutMs = 300_000): Promise<string> {
  const at = join(STEPS, name)
  const deadline = Date.now() + timeoutMs
  log(`waiting for the phone to say “${name}”…`)
  for (;;) {
    if (existsSync(at)) {
      const body = readFileSync(at, 'utf8')
      log(`phone said “${name}” ${body}`)
      return body
    }
    if (Date.now() > deadline) throw new Error(`the phone never said "${name}"`)
    await sleep(300)
  }
}

const sleep = (ms: number): Promise<void> => new Promise((done) => setTimeout(done, ms))

/* ------------------------------------------------------------ the marker -- */

/**
 * What the person types into the page.
 *
 * Lower-case letters and digits only: it goes through the phone's system
 * keyboard into `insertText`, and a marker that needed a shift or a symbol
 * would be testing XCTest's typing rather than the handover. Minted per run so
 * a hit on the page server cannot be last night's.
 */
const MARKER = `td${randomBytes(4).toString('hex')}`
writeFileSync(join(PROOF, 'marker.txt'), MARKER)

/* ------------------------------------------------------------- the page -- */

/**
 * A login wall, served from this process, opened in the host's own Chromium.
 *
 * The field is deliberately enormous. A tap on the phone lands on the cast at
 * page coordinates, and a form laid out for a desktop would need the test to
 * aim — which would make a missed tap look like a broken handover.
 *
 * Everything typed into it is posted straight back here, so *the page*, not the
 * app and not the test, is what says the keystrokes arrived.
 */
const typed: Array<{ at: string; field: string; value: string }> = []

function loginPage(): string {
  return `<!doctype html>
<meta charset="utf-8">
<title>Sign in — Northwind Billing</title>
<style>
  html, body { margin: 0; height: 100%; }
  body { font: 16px -apple-system, system-ui, sans-serif; background: #10131a; color: #e7ecf5; }
  /*
   * The account field sits **exactly** at the middle of the viewport, and every
   * other thing on the page is pinned away from it.
   *
   * A tap on the phone lands at the middle of the canvas, which is the middle of
   * this viewport — so this is what makes "tap the field" a thing a test can do
   * without aiming. A form laid out the ordinary way would put the middle of the
   * page between two controls and a missed tap would read as a broken handover.
   */
  #wrap { position: absolute; inset: 0; }
  h1 { position: absolute; top: 24px; left: 40px; font-size: 40px; margin: 0; }
  p.lede { position: absolute; top: 84px; left: 40px; font-size: 22px; color: #8e9bb3; margin: 0; }
  label.top { position: absolute; top: 50%; left: 40px; transform: translateY(-150px);
              font-size: 24px; color: #8e9bb3; }
  #user { position: absolute; top: 50%; left: 10%; width: 80%; transform: translateY(-50%);
          box-sizing: border-box; font-size: 40px; padding: 34px 20px; border-radius: 14px;
          border: 2px solid #2b3345; background: #171c26; color: #fff; }
  #pass { position: absolute; top: 50%; left: 10%; width: 80%; transform: translateY(90px);
          box-sizing: border-box; font-size: 32px; padding: 22px 20px; border-radius: 14px;
          border: 2px solid #2b3345; background: #171c26; color: #fff; }
  #go { position: absolute; bottom: 120px; left: 10%; font-size: 30px; padding: 20px 34px;
        border-radius: 14px; border: 0; background: #3b82f6; color: #fff; }
  #echo { position: absolute; bottom: 30px; left: 10%; width: 80%; font-size: 30px;
          color: #6ee7a8; word-break: break-all; }
</style>
<form id="wrap" action="/signin" method="post">
  <h1>Sign in</h1>
  <p class="lede">Northwind Billing needs the account this workspace is billed to.</p>
  <label class="top" for="user">Account</label>
  <input id="user" name="user" autocomplete="off" autocapitalize="off" spellcheck="false">
  <input id="pass" name="pass" type="password" placeholder="Password" autocomplete="off">
  <button id="go" type="submit">Continue</button>
  <div id="echo">this page has been given nothing</div>
</form>
<script>
  const echo = document.getElementById('echo')
  for (const id of ['user', 'pass']) {
    document.getElementById(id).addEventListener('input', (event) => {
      const value = event.target.value
      if (id === 'user') echo.textContent = value === '' ? 'this page has been given nothing' : value
      // Straight back to the server that served this page: the third party in
      // the room, and the only witness that is neither the app nor the test.
      fetch('/typed?field=' + id + '&value=' + encodeURIComponent(value)).catch(() => {})
    })
  }
</script>`
}

function welcomePage(user: string): string {
  return `<!doctype html>
<meta charset="utf-8">
<title>Signed in — Northwind Billing</title>
<style>
  body { font: 16px -apple-system, system-ui, sans-serif; margin: 0; background: #0e1a12; color: #dff5e6; }
  main { max-width: 900px; margin: 0 auto; padding: 60px 32px; }
  h1 { font-size: 46px; margin: 0 0 20px; }
  #who { font-size: 34px; color: #6ee7a8; }
</style>
<main>
  <h1 id="title">Signed in</h1>
  <p>The agent may carry on.</p>
  <div id="who">${user.replace(/[<&>]/g, '')}</div>
</main>`
}

let signedInAs = ''

function servePage(request: IncomingMessage, response: ServerResponse): void {
  const url = new URL(request.url ?? '/', `http://127.0.0.1:${PAGE_PORT}`)
  if (url.pathname === '/typed') {
    const field = url.searchParams.get('field') ?? ''
    const value = url.searchParams.get('value') ?? ''
    typed.push({ at: new Date().toISOString(), field, value })
    response.writeHead(204, { 'access-control-allow-origin': '*' })
    response.end()
    return
  }
  if (url.pathname === '/signin') {
    let body = ''
    request.on('data', (chunk) => {
      body += String(chunk)
      if (body.length > 4096) request.destroy()
    })
    request.on('end', () => {
      signedInAs = new URLSearchParams(body).get('user') ?? ''
      note('the page was submitted', { user: signedInAs })
      response.writeHead(303, { location: '/welcome' })
      response.end()
    })
    return
  }
  if (url.pathname === '/welcome') {
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
    response.end(welcomePage(signedInAs))
    return
  }
  response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
  response.end(loginPage())
}

/* ------------------------------------------------------------ the daemon -- */

function record(): DaemonRecord {
  const found = readDaemonRecord(STATE)
  if (found === null) throw new Error(`no host record in ${STATE}`)
  return found
}

async function ask(cmd: string, ...args: unknown[]): Promise<unknown> {
  const answer: ControlResponse = await callControl({
    socket: record().socket,
    token: record().token,
    cmd,
    args: args.map((arg) => JSON.stringify(arg)),
  })
  if (!answer.ok) throw new Error(`${cmd}: ${answer.error}`)
  return answer.value
}

async function waitForHost(timeoutMs = 120_000): Promise<HostStatus> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      const status = (await ask('status')) as HostStatus
      if (status.remote.relay?.connected === true && status.remote.relay.hostId !== '') return status
    } catch {
      // Not up yet. The record appears before the socket answers.
    }
    if (Date.now() > deadline) throw new Error('the host never reached the loopback relay')
    await sleep(500)
  }
}

/* ------------------------------------------------------------- the phone -- */

/**
 * Mint a code, publish its slot where the phone will look, and write it down.
 *
 * Two beacons for one code, and only one of them is this process's doing: the
 * host publishes its own at the relay it is connected to (loopback), and this
 * adds the public one so six digits can be looked up at all. See the header.
 */
async function mintCode(status: HostStatus): Promise<{ code: string; stop(): void }> {
  const answer = (await ask('machines:code')) as
    | { ok: true; code: PairingToken }
    | { ok: false; message: string }
  if (!answer.ok) throw new Error(answer.message)
  const relay = status.remote.relay
  if (relay === null) throw new Error('the host has no relay state to publish')

  const beacon = startBeacon({
    code: answer.code.token,
    offer: {
      // The address the phone will dial after the lookup: this Mac's loopback.
      relayUrl: RELAY_URL,
      hostId: relay.hostId,
      publicKey: Buffer.from(relay.publicKey, 'base64url').toString('base64'),
      name: 'handover proof',
      platform: 'darwin',
    },
    relayUrl: RENDEZVOUS,
  })
  if (beacon === null) throw new Error('could not publish the rendezvous slot')
  const claimed = await beacon.ready()
  note('a pairing code is live', { rendezvous: RENDEZVOUS, dials: RELAY_URL, claimed })
  writeFileSync(join(PROOF, 'pair-code.txt'), answer.code.token)
  return { code: answer.code.token, stop: () => beacon.stop() }
}

/** Be the person at the Mac. The same command the CLI's `pair` sends. */
async function approveWhateverPairs(timeoutMs = 240_000): Promise<Device> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const devices = (await ask('remote:devices')) as Device[]
    const waiting = devices.find((device) => !device.approved && !device.revoked)
    if (waiting) {
      const answered = await ask('remote:device:approve', waiting.id, 'mine', [])
      const roster = Array.isArray(answered)
        ? (answered as Device[])
        : ((answered as { devices?: Device[] } | null)?.devices ?? [])
      const now = roster.find((row) => row.id === waiting.id)
      if (now && !now.approved) throw new Error(`the host refused to approve ${waiting.id}`)
      note('a device was approved', { id: waiting.id, name: waiting.name })
      return waiting
    }
    if (Date.now() > deadline) throw new Error('nothing paired before the wait ran out')
    await sleep(400)
  }
}

async function grantFolder(): Promise<void> {
  if (FOLDER === '') return
  const devices = ((await ask('remote:devices')) as Device[]).filter((d) => d.approved && !d.revoked)
  for (const device of devices) {
    const grants = (await ask('remote:folders')) as DeviceFolderGrant[]
    const current = grants.find((row) => row.deviceId === device.id)?.folders ?? []
    if (current.includes(FOLDER)) continue
    await ask('remote:folders:set', device.id, [...current, FOLDER])
    note('a folder was granted', { device: device.id, folder: FOLDER })
  }
}

/* ------------------------------------------------------------- the agent -- */

/**
 * The config file the host minted for the session the phone just started.
 *
 * `createSessionTools` clears its directory at boot and writes one folder per
 * launch, so with one session started there is one file — and it is *the* file,
 * the one that session's own CLI was pointed at, holding the token bound to its
 * session id. Nothing here invents a credential.
 */
function sessionConfig(timeoutMs = 60_000): Promise<{ url: string; token: string }> {
  const dir = join(STATE, 'session-tools')
  const deadline = Date.now() + timeoutMs
  return (async () => {
    for (;;) {
      if (existsSync(dir)) {
        const launches = readdirSync(dir)
        for (const launch of launches) {
          const file = join(dir, launch, 'deck-control.json')
          if (!existsSync(file)) continue
          const config = JSON.parse(readFileSync(file, 'utf8')) as {
            mcpServers: Record<string, { url: string; headers: Record<string, string> }>
          }
          const server = Object.values(config.mcpServers)[0]
          const bearer = /^Bearer (.+)$/.exec(server?.headers?.Authorization ?? '')
          if (server && bearer) {
            note('the session was launched with browser verbs', { file })
            return { url: server.url, token: bearer[1] }
          }
        }
      }
      if (Date.now() > deadline) {
        throw new Error(
          `no session-tools config appeared under ${dir}. The session was launched without ` +
            '`--mcp-config`, so there is no agent to be.',
        )
      }
      await sleep(400)
    }
  })()
}

async function connectAgent(): Promise<Client> {
  const { url, token } = await sessionConfig()
  const client = new Client({ name: 'handover-proof', version: '0.0.0' }, { capabilities: {} })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(url), {
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    }),
  )
  return client
}

interface ToolAnswer {
  isError: boolean
  text: string
  value: unknown
}

async function callTool(client: Client, name: string, args: Record<string, unknown>): Promise<ToolAnswer> {
  const result = await client.callTool({ name, arguments: args })
  const text = JSON.stringify(result.content)
  let value: unknown = null
  try {
    const first = (result.content as Array<{ type: string; text?: string }>)[0]
    if (first?.type === 'text' && first.text) value = JSON.parse(first.text)
  } catch {
    value = null
  }
  return { isError: result.isError === true, text, value }
}

/* ---------------------------------------------------- the second watcher -- */

/**
 * A **second device** on the same wire, so `taken` is a fact rather than a
 * story.
 *
 * Not a second simulator: what has to be proved from here is what the *host*
 * says to a second connection and what it refuses it, and the phone's side of
 * that — the sentence with no button under it — is what the phone photographs
 * when this one takes the page first.
 *
 * Every byte of it is the product's: `pairWithCode` and `dialMachine` are the
 * machine-to-machine client, the frames are built from `protocol.ts`'s own
 * constants and read back through `parseServerMessage`.
 */
class SecondWatcher {
  private channel: GuestChannel | null = null
  private rid = 0
  readonly seen: ServerMessage[] = []
  private handlers: Array<(message: ServerMessage) => boolean> = []

  async join(status: HostStatus): Promise<void> {
    const minted = await mintCode(status)
    const paired = await pairWithCode({ code: minted.code, relayUrl: RELAY_URL, codeFrom: 'supplied' })
    minted.stop()
    if (!paired.ok) throw new Error(`the second watcher could not pair: ${paired.message}`)
    await approveWhateverPairs(60_000)

    const relay = status.remote.relay
    if (relay === null) throw new Error('no relay state')
    this.channel = await dialMachine({
      relayUrl: RELAY_URL,
      hostId: relay.hostId,
      hostPublicKey: Buffer.from(paired.offer.publicKey, 'base64'),
      guestKeys: paired.guestKeys,
      handlers: {
        message: (text) => {
          const parsed = parseServerMessage(text)
          if (!parsed.ok) return
          this.seen.push(parsed.message)
          this.handlers = this.handlers.filter((handler) => !handler(parsed.message))
        },
        closed: () => {
          this.channel = null
        },
      },
    })
    this.send({
      t: 'hello',
      protocol: PROTOCOL_VERSION,
      token: paired.credential,
      device: { name: 'second watcher', platform: 'darwin' },
      capabilities: [CAPABILITY.watch],
    })
    const welcome = await this.expect((message) => message.t === 'welcome', 20_000)
    note('the second watcher is on the wire', {
      capabilities: (welcome as { capabilities?: string[] }).capabilities ?? [],
    })
  }

  send(frame: unknown): void {
    this.channel?.send(JSON.stringify(frame))
  }

  expect(match: (message: ServerMessage) => boolean, timeoutMs = 15_000): Promise<ServerMessage> {
    const already = this.seen.find(match)
    if (already) return Promise.resolve(already)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('the second watcher waited and nothing matched')), timeoutMs)
      this.handlers.push((message) => {
        if (!match(message)) return false
        clearTimeout(timer)
        resolve(message)
        return true
      })
    })
  }

  /** The surface list, and the row whose page is the login wall. */
  async surfaceFor(url: string): Promise<string> {
    const deadline = Date.now() + 30_000
    for (;;) {
      this.rid += 1
      this.send({ t: 'browser.surfaces', rid: `sw-${this.rid}` })
      const rows = (await this.expect((message) => message.t === 'browser.surfaces.rows', 10_000)) as {
        surfaces: Array<{ window: string; url: string }>
      }
      const found = rows.surfaces.find((row) => row.url.startsWith(url))
      if (found) return found.window
      // Not there yet, and the list is pushed as well as answered — so drop what
      // has been seen and ask again rather than matching a stale answer.
      this.seen.length = 0
      if (Date.now() > deadline) throw new Error(`no surface is showing ${url}`)
      await sleep(1000)
    }
  }

  close(): void {
    this.channel?.close()
    this.channel = null
  }
}

/* ---------------------------------------------------------------- the run -- */

async function main(): Promise<void> {
  writeFileSync(join(PROOF, 'evidence.jsonl'), '')
  note('the proof starts', { relay: RELAY_URL, page: PAGE_URL, marker: MARKER, rendezvous: RENDEZVOUS })

  const relay = createRelayServer({ heartbeatMs: 15_000 })
  await new Promise<void>((settle) => relay.server.listen(RELAY_PORT, '127.0.0.1', () => settle()))
  log(`relay        ${RELAY_URL}`)

  const pages = createServer(servePage)
  await new Promise<void>((settle) => pages.listen(PAGE_PORT, '127.0.0.1', () => settle()))
  log(`login page   ${PAGE_URL}`)
  cue('relay-up', { relay: RELAY_URL, page: PAGE_URL, marker: MARKER })

  const status = await waitForHost()
  note('the host is on the loopback relay', {
    hostId: status.remote.relay?.hostId,
    url: status.remote.relay?.url,
    version: status.version,
  })
  cue('host-up', { hostId: status.remote.relay?.hostId ?? '' })

  /* -- the phone arrives ------------------------------------------------- */

  await step('at-the-pairing-screen')
  const minted = await mintCode(status)
  cue('code', { code: minted.code })
  const device = await approveWhateverPairs()
  minted.stop()
  await grantFolder()
  cue('paired', { device: device.id })

  /* -- a session, and the agent that was launched with it ---------------- */

  await step('session-open')
  const agent = await connectAgent()
  const tools = (await agent.listTools()).tools.map((tool) => tool.name).sort()
  note('the agent’s tools', { tools })

  const opened = await callTool(agent, 'browser_open', { url: PAGE_URL })
  if (opened.isError) throw new Error(`browser_open was refused: ${opened.text}`)
  const window = (opened.value as { window?: string })?.window ?? ''
  note('the agent opened the login wall', { window, url: PAGE_URL })
  cue('page-open', { window })

  /* -- the agent hits the wall and asks for a person --------------------- */

  await step('page-visible')
  const prompt =
    'Sign in with the account this workspace is billed to. I must not handle the credentials, so the ' +
    'page is yours until you hand it back.'

  /**
   * The handover, on its own timeline.
   *
   * `browser_handover` returns after about forty-five seconds with
   * `still-waiting` — deliberately, so a blocked agent is never a hung one — so
   * this keeps asking, exactly as the tool's own description tells a model to.
   * The page stays curtained and the question stays open across the gap: the
   * slot is `human` until somebody answers it.
   */
  const asking = (async () => {
    for (let round = 1; round <= 12; round += 1) {
      const answer = await callTool(agent, 'browser_handover', { prompt })
      const value = answer.value as { resumed?: boolean; reason?: string } | null
      note('browser_handover answered', { round, isError: answer.isError, reason: value?.reason ?? '' })
      if (answer.isError || value?.reason !== 'still-waiting') return answer
    }
    throw new Error('the handover was never answered')
  })()
  asking.catch((error) => note('the handover call failed', { error: String(error) }))
  cue('asking', { prompt })

  /* -- somebody else answers first --------------------------------------- */

  await step('saw-asking')
  const second = new SecondWatcher()
  await second.join(status)
  const surface = await second.surfaceFor(PAGE_URL)
  second.send({ t: 'browser.watch', window: surface, maxWidth: 600, quality: 40 })
  const beforeTake = (await second.expect(
    (message) => message.t === 'browser.handover.state' && message.window === surface,
    20_000,
  )) as { asking: boolean; mine: boolean; taken: boolean; prompt: string }
  note('the second watcher was told the state on watching', {
    asking: beforeTake.asking,
    mine: beforeTake.mine,
    taken: beforeTake.taken,
  })
  second.seen.length = 0
  second.send({ t: 'browser.handover.take', rid: 'sw-take', window: surface })
  const afterTake = (await second.expect(
    (message) => message.t === 'browser.handover.state' && message.window === surface && message.mine,
    20_000,
  )) as { asking: boolean; mine: boolean; taken: boolean }
  note('the second watcher holds the page', afterTake as unknown as Record<string, unknown>)
  cue('taken-elsewhere', { surface })

  /* -- and lets go, so the phone can have it ----------------------------- */

  await step('saw-elsewhere')
  second.close()
  note('the second watcher’s socket is gone')
  cue('released', {})

  /* -- the phone takes it, and the agent is shut out --------------------- */

  await step('mine')
  const refusals: Record<string, string> = {}
  for (const [name, args] of [
    ['browser_read', {}],
    ['browser_step', { verb: 'type', selector: '#user', value: 'the agent should not be able to do this' }],
    ['browser_screenshot', {}],
  ] as Array<[string, Record<string, unknown>]>) {
    const answer = await callTool(agent, name, args)
    refusals[name] = `${answer.isError ? 'refused' : 'ALLOWED'}: ${answer.text.slice(0, 240)}`
    note('the agent tried something while the person holds the page', {
      tool: name,
      refused: answer.isError,
      answer: answer.text.slice(0, 240),
    })
  }
  cue('agent-refused', refusals)

  /* -- what the page was given ------------------------------------------- */

  await step('typed', 300_000)
  await sleep(1500)
  const hit = typed.filter((row) => row.field === 'user' && row.value.includes(MARKER))
  note('what the login page received', {
    marker: MARKER,
    matched: hit.length > 0,
    lastValue: typed.at(-1)?.value ?? '',
    events: typed.length,
  })
  cue('page-received', { matched: hit.length > 0, value: typed.at(-1)?.value ?? '' })

  /* -- handed back, and the agent carries on ------------------------------ */

  await step('handed-back', 180_000)
  const resumed = await asking
  note('the blocked handover resolved', { answer: resumed.text.slice(0, 400) })

  const read = await callTool(agent, 'browser_read', { selector: '#echo' })
  note('the agent read the page it was locked out of', {
    refused: read.isError,
    sawTheMarker: read.text.includes(MARKER),
    answer: read.text.slice(0, 300),
  })
  const carried = await callTool(agent, 'browser_step', { verb: 'click', selector: '#go' })
  note('the agent carried on', { refused: carried.isError, answer: carried.text.slice(0, 240) })
  await sleep(2500)
  const after = await callTool(agent, 'browser_read', {})
  note('where the page ended up', {
    refused: after.isError,
    url: (after.value as { url?: string } | null)?.url ?? '',
    signedInAs,
  })
  cue('carried-on', { signedInAs })

  writeFileSync(
    join(PROOF, 'evidence.json'),
    JSON.stringify(
      {
        marker: MARKER,
        pageEvents: typed,
        signedInAs,
        refusalsWhilePersonHeldThePage: refusals,
        handover: resumed.text,
        agentReadAfterHandBack: read.text.slice(0, 600),
        agentCarriedOn: carried.text.slice(0, 400),
      },
      null,
      2,
    ),
  )
  note('the chain is closed')

  await step('done', 600_000)
  await agent.close()
  pages.close()
  relay.server.close()
  process.exit(0)
}

main().catch((error) => {
  note('the proof stopped', { error: error instanceof Error ? error.message : String(error) })
  cue('failed', { error: String(error) })
  process.exitCode = 1
})
