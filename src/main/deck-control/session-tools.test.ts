import { mkdtempSync, readFileSync, statSync } from 'node:fs'
import { tmpdir, platform } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { attach, resetForTests } from '../browser-binding'
import { browserTools } from './browser-tools'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { createSessionTools, SESSION_TOOLS, type SessionTools } from './session-tools'
import { startDeckControlServer, stopDeckControlServer, type DeckControlEndpoint } from './server'
import type { DeckSurface } from './surface'
import type { BrowserDrive } from '../browser-driver'

/**
 * The two halves of one page of the 2026-08-21 review, proved together.
 *
 * > *"driving other browsers should be for all of the sessions, regardless of
 * > even they are Commander, they are not Commander, they are from remote
 * > channel, they are from server."*
 *
 * > *"Driving tool is only for commanders, and it should not be with for the
 * > other sessions, and they should not be able to find it also."*
 *
 * They are tested in one file because they are one mechanism — a positive list
 * on the token — and because a change that loosened one would be a change that
 * loosened the other. The transport is real: a real loopback socket, the real
 * MCP client the CLIs use, and the token read back out of the file a session
 * would actually be launched with.
 */

function fakeDrive(): BrowserDrive {
  return {
    origin: () => 'http://localhost:3000',
    originGranted: () => true,
    knownSecret: () => false,
    noteOriginGranted: () => undefined,
    open: async () => ({ url: 'http://localhost:3000/', title: 'Dev', settled: true, created: true }),
    outline: async () => ({
      url: 'http://localhost:3000/',
      title: 'Dev',
      text: 'hello',
      textTruncated: false,
      elements: [],
      matched: 0,
      truncated: false,
    }),
    textAt: async () => ({ found: true, secret: false, text: 'hello', truncated: false }),
    waitFor: async () => ({ found: true, count: 1 }),
    act: async () => ({ verb: 'click', selector: '#a', label: 'a', url: 'http://localhost:3000/' }),
    screenshot: async () => ({ path: '/tmp/x.png', width: 1, height: 1, masked: 0 }),
    handover: async () => ({ outcome: 'resumed' as const, waitedMs: 1, url: '', title: '' }),
    close: async () => true,
  } as unknown as BrowserDrive
}

let dir = ''
let endpoint: DeckControlEndpoint
let tools: SessionTools

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'deck-session-tools-'))
  resetForTests()
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  const control = new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: join(dir, 'log') }),
    consent: broker,
    extraTools: browserTools(fakeDrive()),
  })
  endpoint = await startDeckControlServer({ control })
  tools = createSessionTools(endpoint, { dir: join(dir, 'sessions') })
})

afterEach(async () => {
  tools.stop()
  await stopDeckControlServer()
})

/** A session's own MCP client, dialling with the token out of its own config. */
async function dial(configPath: string): Promise<Client> {
  const config = JSON.parse(readFileSync(configPath, 'utf8')) as {
    mcpServers: Record<string, { url: string; headers: Record<string, string> }>
  }
  const server = config.mcpServers['deck-control']
  const client = new Client({ name: 'test-session', version: '0.0.0' }, { capabilities: {} })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(server.url), {
      requestInit: { headers: { Authorization: server.headers.Authorization } },
    }),
  )
  return client
}

/** The path out of the `--mcp-config <path>` pair a launch is given. */
function configOf(args: readonly string[]): string {
  const at = args.indexOf('--mcp-config')
  expect(at).toBeGreaterThanOrEqual(0)
  return args[at + 1]
}

describe('what a session is launched with', () => {
  it('adds the config without taking the person’s own MCP servers away', () => {
    const prepared = tools.prepare()
    expect(prepared).not.toBeNull()
    // `--strict-mcp-config` is the copilot's, deliberately. An ordinary session
    // is somebody's own workspace and this app does not get to empty it.
    expect(prepared?.args).not.toContain('--strict-mcp-config')
    expect(prepared?.args[0]).toBe('--mcp-config')
  })

  it('writes the token where only this account can read it', () => {
    const prepared = tools.prepare()
    const file = configOf(prepared?.args ?? [])
    const written = readFileSync(file, 'utf8')
    expect(written).toContain(endpoint.url)
    expect(written).toContain('Bearer ')
    // Windows decides this with an ACL rather than a mode; `secret-file.ts` owns
    // that difference and `remote/secret-file.test.ts` is where it is proved.
    if (platform() !== 'win32') expect(statSync(file).mode & 0o077).toBe(0)
  })

  it('answers null when there is no endpoint to point at', () => {
    const none = createSessionTools({ ...endpoint, url: '' }, { dir: join(dir, 'none') })
    // A launch must not fail over a feature that is merely absent — the session
    // starts exactly as it did before, with no argument added.
    expect(none.prepare()).toBeNull()
  })
})

describe('what that token may reach', () => {
  it('lists the browser verbs and nothing else', async () => {
    const prepared = tools.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    const names = (await client.listTools()).tools.map((tool) => tool.name).sort()

    expect(names).toEqual([
      'browser_close',
      'browser_handover',
      'browser_open',
      'browser_read',
      'browser_screenshot',
      'browser_step',
    ])
    await client.close()
  })

  it('is described as what it can reach, and not as the copilot’s whole surface', async () => {
    const prepared = tools.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    const said = client.getInstructions() ?? ''

    // A paragraph about sessions, projects, git state and settings would be a
    // description, in every one of this session's turns, of tools it does not
    // have and cannot list.
    expect(said).toContain('browser_open')
    expect(said).not.toContain('the sessions running in it')
    await client.close()
  })

  it('cannot find, and cannot call, anything that drives another session', async () => {
    const prepared = tools.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    const names = (await client.listTools()).tools.map((tool) => tool.name)
    for (const forbidden of ['sessions_list', 'sessions_start', 'sessions_send', 'report', 'brief']) {
      expect(names).not.toContain(forbidden)
    }

    // And guessing the name is refused in the words an unknown name gets, so
    // "it exists but not for you" is not learnable by trying.
    const guessed = await client.callTool({ name: 'sessions_send', arguments: { sessionId: 'x', text: 'hi' } })
    expect(guessed.isError).toBe(true)
    expect(JSON.stringify(guessed.content)).toContain('no tool called sessions_send')
    await client.close()
  })

  it('drives the window attached to its own session, with nothing else named', async () => {
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'view-1' })
    const prepared = tools.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    const read = await client.callTool({ name: 'browser_read', arguments: {} })

    expect(read.isError).toBeFalsy()
    await client.close()
  })

  it('reaches a window the person attached, not only one it opened itself', async () => {
    /*
     * *"the ones they open **or the ones we connect to the session**"*.
     *
     * `attach` is what the window's own menu calls, so this is that press. The
     * session never opened this page and has no way to name another; what it
     * holds is exactly what he handed it, and every verb has to reach it or
     * attaching is a control that does nothing. Q4's parity requirement, from
     * the caller that was added after it was written.
     */
    attach({ sessionId: 's1', browserTabId: 'browser:9', viewId: 'view-9', title: 'Docs' })
    const prepared = tools.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    for (const call of [
      { name: 'browser_read', arguments: { window: 'B1' } },
      { name: 'browser_step', arguments: { window: 'B1', verb: 'click', selector: '#go' } },
      { name: 'browser_screenshot', arguments: { window: 'B1' } },
      { name: 'browser_open', arguments: { window: 'B1', url: 'http://localhost:3000/next' } },
    ]) {
      const result = await client.callTool(call)
      expect(result.isError, `${call.name} was refused over a window the person attached`).toBeFalsy()
    }
    await client.close()
  })

  it('is refused in words it can act on, naming nothing it may not call', async () => {
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'view-1' })
    const prepared = tools.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    const refused = await client.callTool({ name: 'browser_read', arguments: { window: 'B7' } })

    const said = JSON.stringify(refused.content)
    /*
     * The refusal used to end *"sessions.list says which windows each session
     * has"*, which is the one tool this caller may neither call nor find. A
     * session that took the advice spent a turn being told there is no such
     * tool — and the sentence had meanwhile confirmed that there is.
     */
    expect(said).not.toContain('sessions.list')
    expect(said).not.toContain('sessions_list')
    // What it can act on instead: make one, or ask him for one.
    expect(said).toContain('browser.open')
    expect(said).toContain('menu')
    await client.close()
  })

  it('stops working the moment the session is gone', async () => {
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'view-1' })
    const prepared = tools.prepare()
    prepared?.started('s1')
    const file = configOf(prepared?.args ?? [])
    const client = await dial(file)
    expect((await client.callTool({ name: 'browser_read', arguments: {} })).isError).toBeFalsy()
    await client.close()

    tools.release('s1')

    // The token is off the table, so the socket refuses before a tool name is
    // even read — which is a transport error, not a tool error.
    await expect(dial(file)).rejects.toThrow()
  })
})

describe('a token nobody claims', () => {
  it('is dropped rather than left live for the run', () => {
    tools.prepare()
    expect(tools.size).toBe(1)
    // The deadline is what covers a launch that throws between the file being
    // written and the pty existing — the caller of a rejected `startSession` is
    // in no position to tidy up something it never saw.
    tools.stop()
    expect(tools.size).toBe(0)
  })
})

describe('the list itself', () => {
  it('names both spellings of every verb, so neither is a way round it', () => {
    for (const id of ['browser.open', 'browser.read', 'browser.step', 'browser.screenshot', 'browser.handover', 'browser.close']) {
      expect(SESSION_TOOLS.has(id)).toBe(true)
      expect(SESSION_TOOLS.has(id.replace('.', '_'))).toBe(true)
    }
    for (const id of ['sessions.start', 'sessions_start', 'sessions.send', 'sessions_send', 'report', 'brief']) {
      expect(SESSION_TOOLS.has(id)).toBe(false)
    }
  })
})
