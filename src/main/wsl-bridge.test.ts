import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './deck-control/action-log'
import { ConsentBroker } from './deck-control/consent'
import { DeckControl } from './deck-control/control'
import { startDeckControlServer, stopDeckControlServer } from './deck-control/server'
import { createSessionTools, TOKEN_FILE, type SessionTools } from './deck-control/session-tools'
import type { DeckSurface } from './deck-control/surface'
import {
  startedAsWslBridge,
  WSL_BRIDGE_ENV,
  WSL_BRIDGE_FILE,
  WSL_BRIDGE_PROBE,
  WSL_BRIDGE_SOURCE,
  writeWslBridge,
} from './wsl-bridge'

/**
 * The bridge that deletes the `.wslconfig` edit.
 *
 * ## What is provable on a Mac and what is not
 *
 * Everything except WSL itself, which is the same division `wsl-reach.test.ts`
 * draws and for the same reason. The one step no machine here can perform is
 * *binfmt_misc executing a Windows PE from a Linux process*. Every other link in
 * the chain is exercised for real below: the script this app writes, started as
 * a child process with pipes, speaking newline-delimited JSON-RPC on one side
 * and plain HTTP to a **live** `deck-control` endpoint on the other, with a
 * token this app minted and a config file this app wrote.
 *
 * That division matters because of what the untestable step actually is. Inside
 * the distribution the bridge is started by the CLI with its stdin and stdout as
 * pipes; here it is started by this test with its stdin and stdout as pipes.
 * The parent differs. Nothing else does — which is why the probe in
 * `wsl-reach.ts` runs this same program, with this same argument, on the real
 * machine before a single session is told it has verbs.
 *
 * ## Why the handshake is driven by hand rather than by an MCP client
 *
 * Because the thing under test is the framing. A client library would hide
 * exactly the mistakes this file exists to catch — a missing `accept` header
 * turning into a 406, a response written without its newline, a refusal
 * swallowed into silence — behind its own retries and its own parser.
 */

const posix = process.platform !== 'win32'

/* ------------------------------------------------------------ the constant -- */

describe('the script this app writes', () => {
  it('carries nothing a template literal would eat', () => {
    /*
     * It lives in a template literal in `wsl-bridge.ts`. A backtick inside it
     * would end the string early and a dollar before a brace would start an
     * interpolation, and either mistake produces a file that is still written,
     * still named in a config, and still broken on somebody else's machine.
     */
    expect(WSL_BRIDGE_SOURCE).not.toContain('`')
    expect(WSL_BRIDGE_SOURCE).not.toContain('${')
  })

  it('says nothing on stdout but the protocol', () => {
    // stdout is a framed channel here. Every diagnostic in the script goes
    // through `note`, which writes to stderr; a `console.log` added later would
    // corrupt a session rather than log to it.
    expect(WSL_BRIDGE_SOURCE).not.toContain('console.log')
    expect(WSL_BRIDGE_SOURCE).toContain('process.stderr.write')
  })

  it('is what the probe in the distribution actually runs', () => {
    // The two spellings live in two files — the argument here, the shell line in
    // `wsl-reach.ts` — and nothing but this assertion keeps them together.
    expect(WSL_BRIDGE_PROBE).toBe('--probe')
    expect(WSL_BRIDGE_ENV).toEqual({ ELECTRON_RUN_AS_NODE: '1', WSLENV: 'ELECTRON_RUN_AS_NODE' })
  })
})

/* -------------------------------------------------------------- the driver -- */

/** One live bridge, and a way to read whole JSON-RPC lines out of it. */
class Bridge {
  private readonly child: ChildProcessWithoutNullStreams
  private buffered = ''
  private readonly seen: unknown[] = []
  private waiting: (() => void) | null = null
  readonly stderr: string[] = []

  constructor(command: string, args: readonly string[]) {
    this.child = spawn(command, [...args], { stdio: ['pipe', 'pipe', 'pipe'] })
    this.child.stdout.setEncoding('utf8')
    this.child.stdout.on('data', (chunk: string) => {
      this.buffered += chunk
      for (;;) {
        const cut = this.buffered.indexOf('\n')
        if (cut < 0) break
        const line = this.buffered.slice(0, cut).trim()
        this.buffered = this.buffered.slice(cut + 1)
        if (line !== '') this.seen.push(JSON.parse(line))
      }
      this.waiting?.()
    })
    this.child.stderr.setEncoding('utf8')
    this.child.stderr.on('data', (chunk: string) => this.stderr.push(chunk))
  }

  send(message: unknown): void {
    this.child.stdin.write(`${JSON.stringify(message)}\n`)
  }

  /** The next `count` messages, or a rejection that says what was seen instead. */
  async take(count: number, ms = 10_000): Promise<any[]> {
    if (this.seen.length < count) {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(
          () =>
            reject(
              new Error(
                `the bridge answered ${this.seen.length} of ${count} messages in ${ms}ms; stderr: ${this.stderr.join('')}`,
              ),
            ),
          ms,
        )
        this.waiting = (): void => {
          if (this.seen.length < count) return
          clearTimeout(timer)
          this.waiting = null
          resolve()
        }
      })
    }
    return this.seen.slice(0, count) as any[]
  }

  stop(): void {
    this.child.kill()
  }
}

/* ------------------------------------------------------- against a real one -- */

describe('a session inside the distribution, talking to a live endpoint', () => {
  let dir = ''
  let url = ''
  let tools: SessionTools
  let running: Bridge | null = null

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), 'wsl-bridge-'))
    const control = new DeckControl({
      surface: {} as DeckSurface,
      log: new ActionLog({ dir: join(dir, 'log') }),
      consent: new ConsentBroker({ ask: () => false, timeoutMs: 10 }),
    })
    const endpoint = await startDeckControlServer({ control })
    url = endpoint.url
    tools = createSessionTools(endpoint, { dir: join(dir, 'session-tools') })
  })

  afterEach(async () => {
    running?.stop()
    running = null
    tools.stop()
    await stopDeckControlServer()
    rmSync(dir, { recursive: true, force: true })
  })

  /**
   * The whole of the launch, taken from the file rather than rebuilt here.
   *
   * `prepare` writes a config; this reads the same config back and starts
   * exactly what it names. So an argument order that changed, or a token that
   * went into the wrong file, fails here rather than on a Windows machine.
   */
  function launch(): { bridge: Bridge; config: any } {
    const script = tools.bridgeScript()
    expect(script, 'no bridge was written, so no distribution could ever be given one').not.toBeNull()
    const prepared = tools.prepare({
      // The Mac has no `/mnt/c`, and the point of this test is not path
      // translation — `wsl-reach.test.ts` owns that. The file is named where it
      // actually is.
      argPath: (file) => file,
      // `command` is this app's executable over there. Here it is this
      // machine's Node, which is what the distribution would be starting: the
      // executable runs the script as plain Node either way.
      reach: { kind: 'bridge', command: process.execPath, script: script ?? '' },
    })
    expect(prepared).not.toBeNull()
    prepared?.started('session-1')
    const config = JSON.parse(readFileSync(prepared?.file ?? '', 'utf8'))
    const server = config.mcpServers['deck-control']
    const bridge = new Bridge(server.command, server.args)
    running = bridge
    return { bridge, config }
  }

  it('carries a whole MCP handshake and a tool list between two transports', async () => {
    if (!posix) return
    const { bridge } = launch()
    bridge.send({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } },
    })
    const [hello] = await bridge.take(1)
    expect(hello.id).toBe(1)
    expect(hello.error, `the endpoint refused the handshake: ${JSON.stringify(hello.error)}`).toBeUndefined()
    expect(hello.result.serverInfo.name).toBe('deck-control')

    // A notification is answered with 202 and no body, and the bridge must write
    // *nothing* for it — a stray frame here desynchronises the client.
    bridge.send({ jsonrpc: '2.0', method: 'notifications/initialized' })
    bridge.send({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
    const seen = await bridge.take(2)
    expect(seen[1].id).toBe(2)
    expect(Array.isArray(seen[1].result.tools)).toBe(true)
  })

  it('carries which session this is, which is what the token is for', async () => {
    if (!posix) return
    const { bridge } = launch()
    bridge.send({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } },
    })
    await bridge.take(1)
    /*
     * The allow-list carried on this session's own token, asked through the
     * whole crossing rather than in isolation.
     *
     * `sessions.start` is the copilot's and is not on `SESSION_TOOLS`, so the
     * answer is the one an unknown name gets — which is `server.ts` reading
     * `grant.tools` off the token the bridge presented. A bridge that lost the
     * token, or presented the wrong one, could not produce this answer: it would
     * have been refused at the door with a 403 instead.
     */
    bridge.send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'sessions.start', arguments: {} } })
    const [, refused] = await bridge.take(2)
    expect(refused.result.content[0].text).toBe('no tool called sessions.start')

    /*
     * And a verb that *is* on the list gets past the allow-list into the
     * dispatcher, which answers in words of its own — this fixture has no
     * browser surface at all, so what comes back is the dispatcher's *"there is
     * no tool called …"* rather than `server.ts`'s *"no tool called …"*. The two
     * sentences differ on purpose: one is "not for you" and the other is "not
     * here", and only the second is reachable with this token.
     */
    bridge.send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'browser.read', arguments: {} } })
    const [, , reached] = await bridge.take(3)
    expect(reached.result.content[0].text).not.toBe('no tool called browser.read')
  })

  it('puts no bearer token in the file the distribution reads', () => {
    if (!posix) return
    const { config } = launch()
    const text = JSON.stringify(config)
    const token = readFileSync(join(config.mcpServers['deck-control'].args[2]), 'utf8').trim()
    expect(token.length).toBeGreaterThan(16)
    /*
     * The improvement worth keeping. On the HTTP path the config a Linux process
     * opens carries `Authorization: Bearer …`; on this one the secret stays in a
     * second file that only a Windows process reads.
     */
    expect(text).not.toContain(token)
    expect(text).not.toContain('Authorization')
    expect(config.mcpServers['deck-control'].args[2].endsWith(TOKEN_FILE)).toBe(true)
    expect(config.mcpServers['deck-control'].env).toEqual(WSL_BRIDGE_ENV)
  })

  it('answers the probe with this app’s own refusal, which is what the distribution is asked for', async () => {
    if (!posix) return
    const script = tools.bridgeScript() ?? ''
    const output = await new Promise<string>((resolve) => {
      const child = spawn(process.execPath, [script, WSL_BRIDGE_PROBE, url], { stdio: ['ignore', 'pipe', 'pipe'] })
      let text = ''
      child.stdout.setEncoding('utf8')
      child.stdout.on('data', (chunk: string) => {
        text += chunk
      })
      child.on('close', () => resolve(text))
    })
    // The same string `wsl-reach.ts` looks for, from the same `deny()`.
    expect(output).toContain('"refused"')
  })

  /* ------------------------------------------------------------- refusals -- */

  it('turns a refusal into an answer rather than into silence', async () => {
    if (!posix) return
    const script = tools.bridgeScript() ?? ''
    const wrong = join(dir, 'wrong-token')
    writeFileSync(wrong, 'not-a-token-this-app-ever-minted')
    const bridge = new Bridge(process.execPath, [script, url, wrong])
    running = bridge
    bridge.send({ jsonrpc: '2.0', id: 7, method: 'tools/list' })
    const [answer] = await bridge.take(1)
    /*
     * The failure this app has been caught by most: a control that looks wired
     * and answers nothing. A bridge that dropped a 403 would leave the CLI
     * waiting for a reply that is never coming, and the agent would go looking
     * for another way in — which is the CDP-port behaviour `session-verbs.ts`
     * was written to stop.
     */
    expect(answer.id).toBe(7)
    expect(answer.error.message).toContain('403')
  })

  it('says the app is gone rather than hanging when it is', async () => {
    if (!posix) return
    const script = tools.bridgeScript() ?? ''
    const prepared = tools.prepare({
      argPath: (file) => file,
      reach: { kind: 'bridge', command: process.execPath, script },
    })
    prepared?.started('session-2')
    const config = JSON.parse(readFileSync(prepared?.file ?? '', 'utf8'))
    const tokenFile = config.mcpServers['deck-control'].args[2]
    await stopDeckControlServer()
    const bridge = new Bridge(process.execPath, [script, url, tokenFile])
    running = bridge
    bridge.send({ jsonrpc: '2.0', id: 9, method: 'tools/list' })
    const [answer] = await bridge.take(1)
    expect(answer.id).toBe(9)
    expect(answer.error.message).toContain('Could not reach Terminal Deck')
  })
})

/* ---------------------------------------------------------------- the guard -- */

describe('an executable that came up as the app when it was asked for a bridge', () => {
  it('is recognised from its own command line', () => {
    expect(startedAsWslBridge(['C:\\Program Files\\Terminal Deck\\Terminal Deck.exe'])).toBe(false)
    expect(
      startedAsWslBridge([
        'C:\\Program Files\\Terminal Deck\\Terminal Deck.exe',
        `C:\\d\\${WSL_BRIDGE_FILE}`,
        'http://127.0.0.1:1/mcp',
        'C:\\d\\deck-control.token',
      ]),
    ).toBe(true)
    // From the second entry only: an app installed under a folder somebody
    // named after this file must still start.
    expect(startedAsWslBridge([`C:\\apps\\${WSL_BRIDGE_FILE}\\Terminal Deck.exe`])).toBe(false)
  })

  it('leaves before the single-instance lock is asked for', () => {
    const index = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    /*
     * Order is the whole of it. Requesting the lock first would fire
     * `second-instance` in the running copy and put its window on the person's
     * screen once per session — the visible half of the bug this guard exists
     * to stop.
     */
    expect(index.indexOf('startedAsWslBridge(process.argv)')).toBeGreaterThan(0)
    expect(index.indexOf('startedAsWslBridge(process.argv)')).toBeLessThan(
      index.indexOf('app.requestSingleInstanceLock()'),
    )
  })
})

/* --------------------------------------------------------------- on disk -- */

describe('where the bridge lands', () => {
  it('is written once and named where a Windows process will look', () => {
    const dir = mkdtempSync(join(tmpdir(), 'wsl-bridge-file-'))
    try {
      const file = writeWslBridge(dir)
      expect(file).toBe(join(dir, WSL_BRIDGE_FILE))
      expect(readFileSync(file ?? '', 'utf8')).toBe(WSL_BRIDGE_SOURCE)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('answers null rather than throwing when it could not be written', () => {
    // A session must not fail to start over a feature that is merely absent —
    // the caller reads null as "no bridge" and measures only the direct path.
    expect(writeWslBridge('/dev/null/not-a-directory')).toBeNull()
  })
})
