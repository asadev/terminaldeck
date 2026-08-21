import { mkdtempSync, readFileSync, statSync } from 'node:fs'
import { tmpdir, platform } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { attach, resetForTests } from '../browser-binding'
import { browserNetworkTool } from './browser-network-tool'
import { browserTools } from './browser-tools'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { createSessionTools, ELSEWHERE_TOOLS, SESSION_TOOLS, type SessionTools } from './session-tools'
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

/**
 * The same dial, from the config **text** rather than from a file on this
 * computer.
 *
 * A shell on a server has its config file on somebody else's machine, so there
 * is nothing here to read — what this side holds is the text it composed and
 * handed to a script over the connection. Dialling with it proves the token in
 * that text is the one the endpoint honours, which is the whole of what crosses.
 */
async function dialText(configText: string): Promise<Client> {
  const config = JSON.parse(configText) as {
    mcpServers: Record<string, { url: string; headers: Record<string, string> }>
  }
  const server = config.mcpServers['deck-control']
  const client = new Client({ name: 'test-server-shell', version: '0.0.0' }, { capabilities: {} })
  await client.connect(
    /*
     * The token out of the far end's file, against the endpoint's own address.
     *
     * The URL in that file names a port on the **server's** loopback, and what
     * makes that port this socket is `servers/window-reach.ts` — a listener over
     * there whose every connection is handed back down the SSH link and dialled
     * here. That transport has its own tests; what this file is proving is that
     * the token which travels with it is one this endpoint honours, and that
     * what it can reach through it is exactly the six verbs.
     */
    new StreamableHTTPClientTransport(new URL(endpoint.url), {
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

  it('indexes the tools it may call but is not shown in full, and only those', async () => {
    /*
     * Progressive disclosure, from a session's seat.
     *
     * Eight of the fourteen tools on `SESSION_TOOLS` carry an `index` — the
     * workers, the harvest, the asset checks, the store's door — so what a
     * session pays for them is one line each inside `tools_describe` rather
     * than eight schemas in every turn of its context. This endpoint contributes
     * one of them, `browser.network`, so that the index here is a real one.
     *
     * The half that matters more than the saving is the last assertion: the
     * index is built from **this caller's** filtered list, so a tool a session
     * may not call cannot appear in it. An index line naming `sessions_send`
     * would be the same leak as listing it, spelled differently.
     */
    const own = new DeckControl({
      surface: {} as DeckSurface,
      log: new ActionLog({ dir: join(dir, 'log2') }),
      consent: new ConsentBroker({ ask: () => false, timeoutMs: 10 }),
      extraTools: [...browserTools(fakeDrive()), browserNetworkTool(fakeDrive())],
    })
    await stopDeckControlServer()
    const point = await startDeckControlServer({ control: own })
    const mine = createSessionTools(point, { dir: join(dir, 'sessions2') })
    const prepared = mine.prepare()
    prepared?.started('s1')
    const client = await dial(configOf(prepared?.args ?? []))

    const listed = (await client.listTools()).tools
    expect(listed.map((tool) => tool.name).sort()).toEqual([
      'browser_close',
      'browser_handover',
      'browser_open',
      'browser_read',
      'browser_screenshot',
      'browser_step',
      'tools_describe',
    ])
    const meta = listed.find((tool) => tool.name === 'tools_describe')
    expect(meta?.description).toContain('browser_network —')
    expect(meta?.description).not.toContain('sessions_')

    // And the schema it did not send is one call away, in the shape it would
    // have been advertised in.
    const fetched = await client.callTool({
      name: 'tools_describe',
      arguments: { tools: ['browser_network'] },
    })
    const answer = fetched.structuredContent as { tools: { name: string }[] }
    expect(answer.tools[0]?.name).toBe('browser_network')

    // While a tool it may not call answers as a tool that does not exist —
    // through the meta-tool as much as through a call. This is the door the
    // whole feature had to not open.
    const probed = await client.callTool({
      name: 'tools_describe',
      arguments: { tools: ['sessions_send', 'sessions_teleport'] },
    })
    expect(probed.structuredContent).toEqual({
      tools: [],
      unknown: ['no tool called sessions_send', 'no tool called sessions_teleport'],
    })

    await client.close()
    mine.stop()
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

describe('a session on a server, which this process never spawned', () => {
  /**
   * The cell of *"from any session from any device to any device's browser in
   * one app"* that was left over.
   *
   * A shell on a server is an SSH pty. Nothing hands it tools, `startSession`
   * never runs there, and the browser window attached to it is a
   * `WebContentsView` in **this** app. What closes it is the rule the local
   * build already uses — let the session reach the `deck-control` of the machine
   * that owns the window — with SSH instead of a spawn. Everything below is this
   * file's half of that: a token, a caller carrying the *server* where a machine
   * id goes, and a grant that is asked on every call.
   */
  /** The address the far end sees: its own loopback, on a port it chose. */
  const OVER_THERE = 'http://127.0.0.1:40404/mcp'

  it('composes the file for an address only the far end can name', () => {
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    const written = prepared?.configFor(OVER_THERE) ?? ''
    expect(written).toContain(OVER_THERE)
    // Not this endpoint's own URL, which names a port on this Mac and would be
    // an address nothing on that server can reach.
    expect(written).not.toContain(endpoint.url)
    expect(written).toContain('Bearer ')
  })

  it('reaches the windows attached to that shell, under the server’s own key', async () => {
    // The binding map keys a window `<machineId>\0<sessionId>`, with the server
    // standing in for the machine — `browser-binding.ts`, and `serverOfShell` in
    // `servers/ipc.ts`. A caller that wrote the empty string here would be
    // asking about a window on this computer.
    attach({
      sessionId: 'srv-1 shell-9',
      machineId: 'srv-1',
      browserTabId: 'browser:7',
      viewId: 'view-7',
    })
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const client = await dialText(prepared?.configFor(OVER_THERE) ?? '')

    const read = await client.callTool({ name: 'browser_read', arguments: {} })

    expect(read.isError).toBeFalsy()
    await client.close()
  })

  it('holds exactly the same six verbs and no more', async () => {
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const client = await dialText(prepared?.configFor(OVER_THERE) ?? '')

    const names = (await client.listTools()).tools.map((tool) => tool.name).sort()

    expect(names).toEqual([
      'browser_close',
      'browser_handover',
      'browser_open',
      'browser_read',
      'browser_screenshot',
      'browser_step',
    ])
    // The one that must not travel with them. A session on somebody's server
    // that could name `sessions_send` would be *"driving other sessions"*, which
    // is the copilot's alone.
    expect(names).not.toContain('sessions_send')
    await client.close()
  })

  it('cannot find the tools whose answers would be files on this computer', async () => {
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const client = await dialText(prepared?.configFor(OVER_THERE) ?? '')

    const refused = await client.callTool({ name: 'browser_network', arguments: { window: 'B1' } })

    /*
     * Not refused with an explanation — **unknown**, in the words an invented
     * name gets. `browser.network` arms a page to write background responses
     * into a folder on this Mac and `assets.*` are how those files are read back
     * out; every one of them answers a path an agent on somebody's Linux box
     * cannot open. A tool it can see and cannot use is a tool it will spend a
     * turn working around.
     */
    expect(refused.isError).toBe(true)
    expect(JSON.stringify(refused.content)).toContain('no tool called')
    await client.close()
  })

  it('is the session grant minus exactly that family, and nothing else', () => {
    for (const name of ['browser_network', 'assets_fetch', 'assets_ledger', 'assets_coverage']) {
      expect(SESSION_TOOLS.has(name)).toBe(true)
      expect(ELSEWHERE_TOOLS.has(name)).toBe(false)
    }
    // The six, the workers, the store's door and the index all stay: what makes
    // the family above different is that its answers are files, not that it is
    // less trusted.
    for (const name of ['browser_open', 'browser_read', 'browser_step', 'browser_workers', 'browser_extract', 'tools_describe']) {
      expect(ELSEWHERE_TOOLS.has(name)).toBe(true)
    }
    // And nothing was let in that a session in this window does not hold.
    for (const name of ELSEWHERE_TOOLS) expect(SESSION_TOOLS.has(name)).toBe(true)
  })

  it('refuses the one verb whose answer would be a file on the wrong computer', async () => {
    attach({
      sessionId: 'srv-1 shell-9',
      machineId: 'srv-1',
      browserTabId: 'browser:7',
      viewId: 'view-7',
    })
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const client = await dialText(prepared?.configFor(OVER_THERE) ?? '')

    const shot = await client.callTool({ name: 'browser_screenshot', arguments: {} })

    /*
     * The PNG is written into this Mac's copilot folder and the path names a
     * file on the wrong computer. An agent handed it goes looking, does not find
     * it, and reports it missing to somebody looking straight at it on their own
     * screen — a tool reporting success while handing back nothing usable, which
     * is the dead control this round is about wearing a green tick.
     *
     * `remote/machines/window-serve.ts` refuses the identical call at the other
     * end of the relay, and the sentence is the same one.
     */
    expect(shot.isError).toBe(true)
    expect(JSON.stringify(shot.content)).toContain('browser.read')
    await client.close()
  })

  it('refuses on the very next call when the switch goes off, without reconnecting', async () => {
    attach({
      sessionId: 'srv-1 shell-9',
      machineId: 'srv-1',
      browserTabId: 'browser:7',
      viewId: 'view-7',
    })
    let allowed = true
    const prepared = tools.prepareElsewhere({ allowed: () => allowed })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const client = await dialText(prepared?.configFor(OVER_THERE) ?? '')
    expect((await client.callTool({ name: 'browser_read', arguments: {} })).isError).toBeFalsy()

    allowed = false

    // Asked per call, never captured: a person unticking this must land on the
    // next tool call rather than on the next terminal they open.
    const refused = await client.callTool({ name: 'browser_read', arguments: {} })
    expect(refused.isError).toBe(true)
    await client.close()
  })

  it('stops working entirely once the token is given back', async () => {
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const text = prepared?.configFor(OVER_THERE) ?? ''
    await (await dialText(text)).close()

    prepared?.drop()

    // Off the table, so the socket refuses before a tool name is read — which is
    // a transport error rather than a tool error. This is what unticking the
    // switch does to a terminal that is already open.
    await expect(dialText(text)).rejects.toThrow()
  })

  it('answers null when there is no endpoint to point at', () => {
    const none = createSessionTools({ ...endpoint, url: '' }, { dir: join(dir, 'nowhere') })
    // A terminal must open whether or not this app can give it the verbs. It is
    // told so instead — see `WHY_NOT.endpoint` in `servers/window-drive.ts`.
    expect(none.prepareElsewhere({ allowed: () => true })).toBeNull()
  })

  it('is released by the same session id every other session is', async () => {
    const prepared = tools.prepareElsewhere({ allowed: () => true })
    prepared?.started('srv-1 shell-9', 'srv-1')
    const text = prepared?.configFor(OVER_THERE) ?? ''
    await (await dialText(text)).close()

    tools.release('srv-1 shell-9')

    await expect(dialText(text)).rejects.toThrow()
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

  /*
   * The guard behind the paragraph in `session-tools.ts` about saved passwords.
   *
   * A comment saying "there must never be a tool that reads a password" is
   * kept true by somebody reading it. This is the version a test keeps true:
   * every future addition to either list is matched against the words such a
   * tool would inevitably be spelled with, and a `browser.logins` returning
   * nothing but hostnames turns the build red rather than shipping.
   *
   * It is a name check and it is honest about being one — nobody is going to
   * smuggle a credential reader in under the name `browser.step`. Its job is
   * the *accidental* addition, which is how this kind of surface actually
   * grows: somebody wants an agent to know which sites have logins, it sounds
   * like metadata, and it is a map of where a person has accounts.
   */
  it('has no tool that reads, fills or enumerates a saved password', () => {
    const forbidden = /password|passwd|login|credential|secret|keychain|autofill/i
    for (const name of [...SESSION_TOOLS, ...ELSEWHERE_TOOLS]) {
      expect(
        forbidden.test(name),
        `${name} names a credential surface — see the saved-password section in session-tools.ts before adding it`,
      ).toBe(false)
    }
    // And the shapes somebody would actually reach for.
    for (const id of [
      'browser.logins',
      'browser_logins',
      'browser.password',
      'browser_password',
      'browser.fill',
      'browser_fill',
      'browser.autofill',
      'browser_autofill',
      'browser.lift',
      'browser_lift',
    ]) {
      expect(SESSION_TOOLS.has(id)).toBe(false)
      expect(ELSEWHERE_TOOLS.has(id)).toBe(false)
    }
  })

  /*
   * `ELSEWHERE_TOOLS` is a subtraction from `SESSION_TOOLS`, so nothing can
   * appear on it that is not on the other — but the subtraction is the kind of
   * derivation the file's own rule warns about, and this is what stops it
   * silently widening if it ever becomes a second literal.
   */
  it('never grants a session on another computer more than one in this window', () => {
    for (const name of ELSEWHERE_TOOLS) expect(SESSION_TOOLS.has(name)).toBe(true)
  })
})
