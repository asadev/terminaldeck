import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { CdpEvent } from '../main/browser-cdp-pipe'
import type { CdpTransport } from '../main/browser-driven-cdp'
import { resetForTests, windowsOf } from '../main/browser-binding'
import { BrowserDrive } from '../main/browser-driver'
import { createHeadlessBrowserControl } from '../main/browser-headless-control'
import {
  HeadlessDriveHost,
  type HeadlessBrowserHandle,
  type LaunchBrowser,
} from '../main/browser-headless-host'
import {
  startDeckControlServer,
  stopDeckControlServer,
  type DeckControlEndpoint,
} from '../main/deck-control/server'
import { createSessionTools, type SessionTools } from '../main/deck-control/session-tools'

/**
 * A session **on the server** driving the server's own browser, end to end.
 *
 * ## What was actually missing, and what this pins
 *
 * Wave-2 gave a headless host a real Chromium and a browser-verb `DeckControl`
 * over it, and wired the *cross-machine* half: a phone that dialled in drives a
 * window the server holds. A session running on the server itself got nothing,
 * and `src/headless/host.ts` said so in the one place that mattered — the hook
 * answer every session reads at the top of every turn carried *"this app's
 * control endpoint is not running here"*, which was true and was a dead end.
 *
 * It is now running. This file drives the whole path a session takes, with
 * nothing stubbed except the browser process:
 *
 *  1. the pieces `host.ts` assembles — `HeadlessDriveHost`, `BrowserDrive`,
 *     `createHeadlessBrowserControl`, the MCP endpoint over it;
 *  2. `createSessionTools`, which mints one token and one config file per
 *     launch — the same object `host-core.ts` composes `--mcp-config` from;
 *  3. a **real MCP client** from the SDK the Claude CLI itself uses, dialling
 *     the real loopback socket with the token out of that file;
 *  4. `browser_open` over that connection, landing as a `Target.createTarget`
 *     on a fake CDP channel and as a `B1` in the binding store.
 *
 * The fake is the browser and only the browser. Everything between the config
 * file and Chromium's wire is the shipping code — which is the property that
 * was missing before: every layer had a passing test and no test crossed all of
 * them, so a build where the endpoint was never started passed everything.
 *
 * ## What it cannot prove
 *
 * That a real Chromium answers `Target.createTarget` the way `FakeTransport`
 * does, and that the CLI on a real server reads the file we wrote. Both are the
 * live lane's, on real hardware. What is provable without a browser in the room
 * is that the flags are composed, the token authenticates, the grant is the
 * narrow one, and the verb reaches the drive.
 */

/* ------------------------------------------------------------ fake browser -- */

interface Recorded {
  method: string
  params: Record<string, unknown>
}

/**
 * A CDP channel that answers the target lifecycle and records every command.
 *
 * Deliberately the same shape as `browser-headless-host.test.ts`'s, and
 * deliberately a second copy rather than an export from it: a fake shared
 * between two files is a fake that grows a flag for one of them, and the thing
 * this file is about is what arrives on the wire, not how convincingly it is
 * answered.
 */
class FakeTransport implements CdpTransport {
  readonly sent: Recorded[] = []
  private seq = 0

  async command(command: { method: string; params?: unknown }): Promise<unknown> {
    this.sent.push({ method: command.method, params: (command.params ?? {}) as Record<string, unknown> })
    switch (command.method) {
      case 'Target.createTarget':
        return { targetId: `target-${++this.seq}` }
      case 'Target.createBrowserContext':
        return { browserContextId: `ctx-${++this.seq}` }
      case 'Target.attachToTarget':
        return { sessionId: `session-${++this.seq}` }
      default:
        return {}
    }
  }

  on(_sessionId: string | undefined, _listener: (event: CdpEvent) => void): () => void {
    return () => {}
  }

  onClose(_listener: (error?: Error) => void): () => void {
    return () => {}
  }

  last(method: string): Recorded | undefined {
    return [...this.sent].reverse().find((entry) => entry.method === method)
  }
}

/* -------------------------------------------------------------------- rig -- */

let dir = ''
let transport: FakeTransport
let endpoint: DeckControlEndpoint
let tools: SessionTools

beforeEach(async () => {
  resetForTests()
  dir = mkdtempSync(join(tmpdir(), 'td-server-session-'))
  transport = new FakeTransport()
  // Nothing to record: this file is about what reaches the wire, and the
  // browser's teardown is `browser-headless-host.test.ts`'s subject.
  const handle: HeadlessBrowserHandle = { transport, stop: () => {} }
  const launch: LaunchBrowser = async () => ({ ok: true as const, handle })

  // Exactly the four lines `src/headless/host.ts` runs, in the same order.
  const host = new HeadlessDriveHost({ userData: dir, launch })
  const drive = new BrowserDrive(host)
  const control = createHeadlessBrowserControl({ drive, logDir: join(dir, 'browser-actions') })
  endpoint = await startDeckControlServer({ control })
  tools = createSessionTools(endpoint, { dir: join(dir, 'session-tools') })
})

afterEach(async () => {
  tools.stop()
  await stopDeckControlServer()
  rmSync(dir, { recursive: true, force: true })
})

/** The token out of the file a session's CLI would be pointed at. */
function tokenFrom(file: string): string {
  const config = JSON.parse(readFileSync(file, 'utf8')) as {
    mcpServers: Record<string, { url: string; headers: Record<string, string> }>
  }
  const server = Object.values(config.mcpServers)[0]
  expect(server.url).toBe(endpoint.url)
  const bearer = /^Bearer (.+)$/.exec(server.headers.Authorization ?? '')
  expect(bearer, 'the config file carries a bearer token').not.toBeNull()
  return (bearer as RegExpExecArray)[1]
}

/** A real MCP client, dialling the real socket with a session's own token. */
async function connect(token: string): Promise<Client> {
  const client = new Client({ name: 'server-session', version: '0.0.0' }, { capabilities: {} })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(endpoint.url), {
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    }),
  )
  return client
}

/* ------------------------------------------------------------- the launch -- */

describe('a session started on the server is minted with the browser verbs', () => {
  it('hands back the flags and a config file naming this host’s endpoint', () => {
    const launch = tools.prepare()
    expect(launch, 'the endpoint is up, so there is something to point a session at').not.toBeNull()
    // `--mcp-config <file>` and nothing else. `--strict-mcp-config` is
    // deliberately absent for an ordinary session: it is the person's own
    // workspace and their own MCP servers are not this app's to remove.
    expect(launch?.args).toEqual(['--mcp-config', launch?.file])
    expect(tokenFrom(launch?.file as string)).toHaveLength(64)
  })

  it('lists the browser verbs and nothing this control cannot answer', async () => {
    const launch = tools.prepare()
    launch?.started('session-1')
    const client = await connect(tokenFrom(launch?.file as string))
    try {
      const names = (await client.listTools()).tools.map((tool) => tool.name).sort()
      /*
       * The six verbs, present.
       *
       * This is the whole claim of the lane in one assertion: a session on this
       * machine can read and act on a page, not merely open one. `open` was
       * never the missing half — the shim is a script on a PATH — and the
       * measured complaint was *"other sessions still cant see inside the
       * browser window they opened they can just open"*.
       */
      for (const verb of [
        'browser_open',
        'browser_read',
        'browser_step',
        'browser_screenshot',
        'browser_handover',
        'browser_close',
      ]) {
        expect(names, verb).toContain(verb)
      }
      /*
       * And nothing else, which matters more here than on the desktop.
       *
       * This control's non-browser surface is a proxy that throws — nothing was
       * ever meant to reach it — so a listing that advertised `sessions_list`
       * would be a tool a model would call once and get an internal error from.
       * The narrowing is `SESSION_TOOLS`, applied by `deck-control/server.ts` to
       * `tools/list` and `tools/call` alike, so a session here cannot find these
       * and cannot reach them by guessing the name either.
       */
      for (const withheld of ['sessions_list', 'sessions_send', 'settings_write', 'projects_list']) {
        expect(names, withheld).not.toContain(withheld)
      }
      const guessed = await client.callTool({ name: 'sessions_list', arguments: {} })
      expect(guessed.isError).toBe(true)
      expect(JSON.stringify(guessed.content)).toContain('no tool called sessions_list')
    } finally {
      await client.close()
    }
  })
})

/* -------------------------------------------------------------- the drive -- */

describe('a verb from that session reaches the server’s own Chromium', () => {
  it('opens a page in this host’s browser and attaches it as B1', async () => {
    const launch = tools.prepare()
    // The bind that `host-core.ts` performs once the pty exists. Before it, the
    // token resolves to a caller with no tiers — asserted below.
    launch?.started('session-1')
    const client = await connect(tokenFrom(launch?.file as string))
    try {
      const result = await client.callTool({
        name: 'browser_open',
        arguments: { url: 'https://example.com/pricing' },
      })
      expect(JSON.stringify(result.content)).not.toContain('not-granted')
      expect(result.isError ?? false).toBe(false)

      // It reached the browser: a target was created in the server's Chromium
      // at the URL the session asked for.
      const created = transport.last('Target.createTarget')
      expect(created, 'the verb reached the CDP channel').toBeDefined()
      expect(created?.params.url).toBe('https://example.com/pricing')

      // And it is the session's own window, in the same store the desktop mints
      // B1 from — which is what makes `browser_read` afterwards resolvable.
      const windows = windowsOf('session-1')
      expect(windows).toHaveLength(1)
      expect(windows[0].url).toBe('https://example.com/pricing')
      expect(JSON.stringify(result.content)).toContain('B1')
    } finally {
      await client.close()
    }
  })

  it('routes a read to that same window rather than refusing it', async () => {
    /*
     * The half of the complaint that was never `open`.
     *
     * > *"other sessions still cant see inside the browser window they opened
     * > they can just open."*
     *
     * So: open, then read, and check the read *reached the page* — a
     * `Page.getFrameTree` on the CDP channel for the target this session's `B1`
     * is — rather than coming back as "you have no window by that name" or a
     * tier refusal, which is what a session with no verbs and a shim on its PATH
     * got.
     *
     * The read then fails, and the failure is the fake's: `FakeTransport`
     * answers `Page.getFrameTree` with `{}`, so there is no frame to run the
     * outline in. Faking a frame tree, an isolated world and the outline the
     * reader script returns would be this test asserting a payload it invented
     * — the DOM is the one thing a fake browser cannot honestly supply. What is
     * provable here is the routing; that a real Chromium answers is
     * `ios/Harness`-shaped work on real hardware.
     */
    const launch = tools.prepare()
    launch?.started('session-1')
    const client = await connect(tokenFrom(launch?.file as string))
    try {
      await client.callTool({ name: 'browser_open', arguments: { url: 'https://example.com/pricing' } })
      const before = transport.sent.length
      const read = await client.callTool({ name: 'browser_read', arguments: {} })
      const text = JSON.stringify(read.content)
      expect(text).not.toContain('not-granted')
      expect(text).not.toContain('no window')
      expect(text).not.toContain('no tool called')
      expect(
        transport.sent.slice(before).map((entry) => entry.method),
        'the read reached the page over CDP',
      ).toContain('Page.getFrameTree')
    } finally {
      await client.close()
    }
  })

  it('refuses a call from a launch whose session does not exist yet', async () => {
    // Minted, never bound: a CLI can call a tool in its first breath, and until
    // the pty exists there is no session for a window to belong to. The refusal
    // is a tier refusal rather than a crash, and no window is opened.
    const launch = tools.prepare()
    const client = await connect(tokenFrom(launch?.file as string))
    try {
      const result = await client.callTool({
        name: 'browser_open',
        arguments: { url: 'https://example.com/' },
      })
      expect(result.isError).toBe(true)
      expect(transport.last('Target.createTarget')).toBeUndefined()
    } finally {
      await client.close()
    }
  })

  it('stops the token the moment the session is released', async () => {
    const launch = tools.prepare()
    launch?.started('session-1')
    const token = tokenFrom(launch?.file as string)
    tools.release('session-1')
    /*
     * A dead token must not merely be refused a tool — it must not open a
     * conversation at all, which is the check that happens before any name is
     * read. `connect` performs the MCP initialise, so this asserts the door
     * rather than the dispatcher.
     */
    await expect(connect(token)).rejects.toThrow()
  })
})
