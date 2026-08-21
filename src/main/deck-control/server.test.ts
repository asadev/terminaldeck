import { mkdtempSync, rmSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { ConsentBroker, type ConsentRequest } from './consent'
import { DeckControl } from './control'
import {
  currentEndpoint,
  MCP_PATH,
  startDeckControlServer,
  stopDeckControlServer,
  type DeckControlEndpoint,
} from './server'
import type { DeckSurface, SessionView } from './surface'
import type { SessionMeta } from '../../shared/types'

/**
 * The transport, exercised for real.
 *
 * A real loopback socket, a real MCP client from the SDK the copilot's CLI
 * uses, real JSON-RPC over the wire. Nothing here is stubbed except the app
 * itself — which is the point: this file answers "can the copilot reach these
 * tools, and does the gate hold when it does", and both questions are about the
 * bytes rather than about the app.
 *
 * The test that matters most is at the bottom: an alter-tier call arriving over
 * HTTP with no window registered to confirm it comes back as a tool error and
 * changes nothing. That is the same refusal `control.test.ts` proves in
 * isolation, verified again through every layer the copilot actually goes
 * through, because a gate that only holds when it is called directly is not a
 * gate.
 */

/* ------------------------------------------------------------------- fake -- */

interface Fake {
  surface: DeckSurface
  settings: Record<string, string | number | boolean>
  typed: Array<{ id: string; data: string }>
}

const SESSION: SessionMeta = {
  id: 'session-1',
  cwd: '/work/api',
  title: 'api',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_000,
}

function fake(): Fake {
  const state: Fake = { surface: {} as DeckSurface, settings: { 'appearance.density': 'comfortable' }, typed: [] }
  state.surface = {
    listSessions: () => [SESSION],
    sessionStatus: () => ({ status: 'working', at: 2_000 }),
    startSession: async () => SESSION,
    writeToSession: (id, data) => {
      state.typed.push({ id, data })
    },
    killSession: () => undefined,
    sessionScreen: async () => '',
    sessionScrollback: () => '',
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1 }],
    gitStatus: async (cwd) => ({ repo: true, cwd }),
    alerts: async () => ({ alerts: [] }),
    readSettings: () => ({ settings: { ...state.settings }, preferences: {} }),
    writeSettings: (patch) => {
      for (const [key, value] of Object.entries(patch)) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          state.settings[key] = value
        }
      }
      return { ...state.settings }
    },
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/tmp/settings.last-good.json', at: 0 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    /*
     * The five reads the fleet capabilities added, answered inertly.
     *
     * This fake exists to exercise the dispatcher, not the reports, so every
     * one of these returns the empty answer its real counterpart returns for a
     * folder with no repository and a session with no transcript. The report
     * tools have their own tests with their own fixtures.
     */
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: 'not a repository',
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
    // `<userData>` and the copilot's folder inside it. Distinct from every
    // project path in these fixtures, which is what `sessions.start`'s refusal
    // to run inside the app's own storage needs in order to mean anything.
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
  }
  return state
}

/* ------------------------------------------------------------------- rig -- */

let dir = ''
let endpoint: DeckControlEndpoint
let state: Fake
let asked: ConsentRequest[]
/** null: no window is registered. true/false: a window that answers that way. */
let answer: boolean | null

async function boot(): Promise<void> {
  state = fake()
  asked = []
  const log = new ActionLog({ dir })
  const consent = new ConsentBroker({
    ask: (request) => {
      if (answer === null) return false
      asked.push(request)
      const decision = answer
      queueMicrotask(() => consent.respond(request.id, decision, 'window'))
      return true
    },
    timeoutMs: 200,
  })
  const control = new DeckControl({ surface: state.surface, log, consent })
  endpoint = await startDeckControlServer({ control })
}

/** A real MCP client, dialling the real socket with the real token. */
async function connect(token = endpoint.token): Promise<Client> {
  const client = new Client({ name: 'test-copilot', version: '0.0.0' }, { capabilities: {} })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(endpoint.url), {
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    }),
  )
  return client
}

/**
 * A bare HTTP request, for the checks that happen before MCP is reached.
 *
 * `node:http` rather than `fetch`, and not by preference: `Host` is a forbidden
 * header name in the Fetch standard, so undici silently drops an override and
 * the DNS-rebinding test would pass against a header it never actually sent.
 * A hand-rolled request is also the only way to send a GET with no body, which
 * is the other case below.
 */
function raw(
  init: { path?: string; method?: string; headers?: Record<string, string>; body?: string | null } = {},
): Promise<{ status: number; headers: Record<string, string | string[] | undefined>; body: string }> {
  const body = init.body === null ? null : (init.body ?? JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }))
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      {
        host: '127.0.0.1',
        port: endpoint.port,
        path: init.path ?? MCP_PATH,
        method: init.method ?? 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json, text/event-stream',
          ...(body === null ? {} : { 'content-length': Buffer.byteLength(body) }),
          ...init.headers,
        },
      },
      (response) => {
        let text = ''
        response.setEncoding('utf8')
        response.on('data', (chunk: string) => {
          text += chunk
        })
        response.on('end', () =>
          resolve({ status: response.statusCode ?? 0, headers: response.headers, body: text }),
        )
      },
    )
    request.on('error', reject)
    if (body !== null) request.write(body)
    request.end()
  })
}

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'deck-control-server-'))
  answer = null
  await boot()
})

afterEach(async () => {
  await stopDeckControlServer()
  rmSync(dir, { recursive: true, force: true })
})

/* ---------------------------------------------------------------- the door -- */

describe('who may reach the endpoint', () => {
  it('listens on loopback and hands back a usable URL', () => {
    expect(endpoint.url).toBe(`http://127.0.0.1:${endpoint.port}${MCP_PATH}`)
    expect(endpoint.port).toBeGreaterThan(0)
    expect(currentEndpoint()).toEqual(endpoint)
  })

  it('mints a fresh token on every start', async () => {
    const first = endpoint.token
    await stopDeckControlServer()
    await boot()
    // A config file left behind by a previous run must authenticate nothing.
    expect(endpoint.token).not.toBe(first)
    expect(first).toHaveLength(64)
  })

  it('refuses a request with no token', async () => {
    expect((await raw()).status).toBe(403)
  })

  it('refuses a request with the wrong token', async () => {
    const response = await raw({ headers: { Authorization: 'Bearer ' + 'f'.repeat(64) } })
    expect(response.status).toBe(403)
  })

  it('never answers 401, so no client starts an OAuth dance', async () => {
    const response = await raw()
    // A 401 with `WWW-Authenticate` is how an MCP client is told to go and
    // authorise. There is no authorisation server here and never will be;
    // sending somebody's browser somewhere would be worse than a flat refusal.
    expect(response.status).not.toBe(401)
    expect(response.headers['www-authenticate']).toBeUndefined()
  })

  it('refuses anything that arrives with an Origin, token or not', async () => {
    const response = await raw({
      headers: { Authorization: `Bearer ${endpoint.token}`, Origin: 'https://evil.example' },
    })
    // No legitimate client of this endpoint is a browser, and every browser
    // sends one. So the allowlist is empty and the rule is "has one, refused".
    expect(response.status).toBe(403)
  })

  it('refuses a rebound Host', async () => {
    const response = await raw({
      headers: { Authorization: `Bearer ${endpoint.token}`, Host: 'attacker.example' },
    })
    expect(response.status).toBe(403)
  })

  it('refuses a rebound Host that carries this socket’s own port', async () => {
    // The literal is the whole defence. A name is refused whatever port it
    // spells, including the right one.
    const response = await raw({
      headers: { Authorization: `Bearer ${endpoint.token}`, Host: `attacker.example:${endpoint.port}` },
    })
    expect(response.status).toBe(403)
  })

  it('takes a loopback Host whose port is the far end’s', async () => {
    /*
     * A session on a **server**, arriving through the port that machine opened
     * for it (`servers/window-reach.ts`).
     *
     * Its CLI addresses `http://127.0.0.1:<that server's port>/mcp`, so the
     * `Host` it sends carries a number this socket has never heard of — a
     * loopback literal on a machine where that is as true as it is here,
     * arriving on a connection only a process on that server could have made.
     * Pinning the number turned that into a 403 and would have left the whole
     * feature answering nothing while looking wired.
     */
    const response = await raw({
      headers: { Authorization: `Bearer ${endpoint.token}`, Host: '127.0.0.1:40404' },
    })
    expect(response.status).toBe(200)
  })

  it('serves one path and nothing else', async () => {
    const response = await raw({
      path: '/anything-else',
      headers: { Authorization: `Bearer ${endpoint.token}` },
    })
    expect(response.status).toBe(404)
  })

  it('refuses GET, because there is no stream to resume', async () => {
    const response = await raw({
      method: 'GET',
      headers: { Authorization: `Bearer ${endpoint.token}` },
      body: null,
    })
    expect(response.status).toBe(405)
  })

  it('refuses a body that is not JSON', async () => {
    const response = await raw({
      headers: { Authorization: `Bearer ${endpoint.token}` },
      body: 'not json at all',
    })
    expect(response.status).toBe(400)
  })
})

/* ------------------------------------------------------------------ tools -- */

describe('the tool surface as a client sees it', () => {
  it('lists every advertised tool with a schema and a read-only hint', async () => {
    const client = await connect()
    const { tools } = await client.listTools()

    /*
     * Four of the fourteen built-ins are no longer here, and that is the
     * feature. `sessions.get`, `git.status`, `settings.write` and `log.note`
     * carry an `index`, so what crosses to the model is one line each inside
     * `tools_describe`'s description rather than four schemas — see
     * `describe-tool.ts` for the argument about each of them. They are still
     * callable; the test below calls one.
     */
    expect(tools.map((tool) => tool.name).sort()).toEqual([
      'alerts_list',
      'git_diff',
      'projects_list',
      'sessions_list',
      'sessions_result',
      'sessions_send',
      'sessions_start',
      'sessions_stop',
      'sessions_transcript',
      'settings_read',
      'tools_describe',
    ])

    const describe = tools.find((tool) => tool.name === 'tools_describe')
    // The index, in the one place a model will actually read it.
    expect(describe?.description).toContain('settings_write —')
    expect(describe?.description).toContain('log_note —')
    expect(describe?.annotations?.readOnlyHint).toBe(true)
    expect(tools.find((tool) => tool.name === 'sessions_list')?.annotations?.readOnlyHint).toBe(true)
    expect(tools.find((tool) => tool.name === 'sessions_start')?.annotations?.readOnlyHint).toBe(
      false,
    )

    await client.close()
  })

  it('hands over the schema of a tool it did not advertise, and that tool still runs', async () => {
    const client = await connect()
    const described = await client.callTool({
      name: 'tools_describe',
      arguments: { tools: ['settings_write'] },
    })
    const answer = described.structuredContent as {
      tools: { name: string; inputSchema: unknown; annotations: { destructiveHint: boolean } }[]
    }
    expect(answer.tools[0]?.name).toBe('settings_write')
    // The same shape `tools/list` would have advertised, annotations and all,
    // so a model that fetches late is not told less than one that was told early.
    expect(answer.tools[0]?.inputSchema).toMatchObject({ type: 'object' })
    expect(answer.tools[0]?.annotations.destructiveHint).toBe(true)

    // Disclosure is not a gate: the tool a listing did not mention is callable
    // by exactly the caller who could have called it before.
    const called = await client.callTool({ name: 'settings_read', arguments: {} })
    expect(called.isError).toBeFalsy()

    await client.close()
  })

  it('answers a read call with both text and structured content', async () => {
    const client = await connect()
    const result = await client.callTool({ name: 'sessions_list', arguments: {} })

    expect(result.isError).toBeFalsy()
    const sessions = (result.structuredContent as { sessions: SessionView[] }).sessions
    expect(sessions[0]).toMatchObject({ id: 'session-1', status: 'working', startedByCopilot: false })
    // The text block is what a model actually reads; a client that ignored
    // `structuredContent` must still get the answer.
    const [content] = result.content as Array<{ type: string; text: string }>
    expect(JSON.parse(content.text)).toMatchObject({ count: 1 })

    await client.close()
  })

  it('returns a tool error rather than a protocol error for a bad argument', async () => {
    const client = await connect()
    const result = await client.callTool({ name: 'sessions_get', arguments: { sessionId: 'nope' } })

    // The distinction matters to the model: a tool error is something it can
    // read and respond to, a protocol error is something it can only retry.
    expect(result.isError).toBe(true)
    // The sentence names the two ways a session id goes missing — never one of
    // this app's, or stopped and dropped — because the model's next move
    // differs between them. See `requireSession`.
    const said = String((result.content as Array<{ text: string }>)[0].text)
    expect(said).toContain('not holding a session with id nope')
    expect(said).toContain('sessions.list')

    await client.close()
  })

  it('reports an unknown tool without falling over', async () => {
    const client = await connect()
    const result = await client.callTool({ name: 'sessions_delete_everything', arguments: {} })
    expect(result.isError).toBe(true)
    await client.close()
  })

  it('handles two calls in a row on one connection', async () => {
    // The server builds a fresh MCP server per POST. If that were leaking or
    // mis-wired, the second call on the same client is where it would show.
    const client = await connect()
    expect((await client.callTool({ name: 'projects_list', arguments: {} })).isError).toBeFalsy()
    expect((await client.callTool({ name: 'projects_list', arguments: {} })).isError).toBeFalsy()
    await client.close()
  })
})

/* ------------------------------------------------------------------- gate -- */

describe('the gate, over the wire', () => {
  it('refuses an alter call when no window can confirm it, and changes nothing', async () => {
    /*
     * The proof, end to end.
     *
     * This is the state the app is in before the copilot's confirmation dialog
     * has been built at all, and the state it returns to every time that window
     * closes. A permission gate that is open by default is worse than none,
     * because it reads as protection — so the assertion is not only that the
     * call reported an error, but that the setting is untouched afterwards.
     */
    answer = null
    const client = await connect()

    const result = await client.callTool({
      name: 'settings_write',
      arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    })

    expect(result.isError).toBe(true)
    expect(String((result.content as Array<{ text: string }>)[0].text)).toContain('no window open')
    expect(state.settings['appearance.density']).toBe('comfortable')

    await client.close()
  })

  it('refuses when the person declines, and changes nothing', async () => {
    answer = false
    const client = await connect()

    const result = await client.callTool({
      name: 'settings_write',
      arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    })

    expect(result.isError).toBe(true)
    expect(state.settings['appearance.density']).toBe('comfortable')
    await client.close()
  })

  it('goes through once the person allows it', async () => {
    answer = true
    const client = await connect()

    const result = await client.callTool({
      name: 'settings_write',
      arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    })

    expect(result.isError).toBeFalsy()
    expect(state.settings['appearance.density']).toBe('compact')
    expect(asked[0].summary).toBe('Change settings: appearance.density to "compact"')
    await client.close()
  })

  it('refuses a protected setting over the wire without asking anybody', async () => {
    answer = true
    const client = await connect()

    const result = await client.callTool({
      name: 'settings_write',
      arguments: { scope: 'settings', patch: { 'remote.enabled': true } },
    })

    expect(result.isError).toBe(true)
    expect(asked).toEqual([])
    expect(state.settings['remote.enabled']).toBeUndefined()
    await client.close()
  })

  it('will not type into a session the copilot did not start, unconfirmed', async () => {
    answer = null
    const client = await connect()

    const result = await client.callTool({
      name: 'sessions_send',
      arguments: { sessionId: 'session-1', text: 'delete the branch' },
    })

    expect(result.isError).toBe(true)
    expect(state.typed).toEqual([])
    await client.close()
  })
})

/* --------------------------------------------------- the unattended caller -- */

/**
 * A routine run reaches these same tools over this same socket, and must not be
 * able to ask a sleeping person for permission.
 *
 * The whole of that distinction is carried by **which token the request bore**,
 * and the reason it is a token rather than a header is that a caller can simply
 * not send a header. These four assertions are the proof that the boundary is
 * where it is claimed to be: the transport decides, before a tool name is even
 * read, and nothing in the request body can move it.
 *
 * It exists because of a recorded failure rather than a hypothetical.
 * OpenClaw's heartbeat tried to run a script, exec needed approval, a heartbeat
 * cannot get interactive approval, and the run died with `approval-timeout` —
 * then again, then `user-denied`, each failure spending a whole turn generating
 * an apology. The fix there was to delete the command.
 */
describe('a caller nobody is watching', () => {
  it('is refused an alter call immediately, with a window standing by that would have said yes', async () => {
    // The decisive setup: a window *is* attached and *would* approve. An
    // attended caller gets the change; this one must not, and must not wait.
    answer = true
    const client = await connect(endpoint.unattendedToken)

    const result = await client.callTool({
      name: 'settings_write',
      arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    })

    expect(result.isError).toBe(true)
    // Nobody was even asked. A dialog drawn for a run at 03:00 is a dialog that
    // can only time out, and the timeout costs a turn and one of the three
    // pending slots.
    expect(asked).toEqual([])
    expect(state.settings['appearance.density']).toBe('comfortable')
    await client.close()
  })

  it('is told to report rather than to retry', async () => {
    answer = true
    const client = await connect(endpoint.unattendedToken)
    const result = await client.callTool({
      name: 'settings_write',
      arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    })
    // The refusal text matters as much as the refusal: `no-approver` means
    // "there is no window", which fixes itself when somebody opens the app, and
    // a model reading that will try again. This one never fixes itself.
    const text = String((result.content as Array<{ text: string }>)[0].text)
    expect(text).toMatch(/nobody at the machine/)
    expect(text).toMatch(/Do not retry it/)
    await client.close()
  })

  it('still gets everything it needs to look at the machine', async () => {
    const client = await connect(endpoint.unattendedToken)
    expect((await client.callTool({ name: 'projects_list', arguments: {} })).isError).toBeFalsy()
    expect((await client.callTool({ name: 'sessions_list', arguments: {} })).isError).toBeFalsy()
    // And act-tier work is fine: a routine that could not start a session could
    // not do half of what routines are for.
    expect(
      (await client.callTool({ name: 'sessions_start', arguments: { cwd: '/work/api' } })).isError,
    ).toBeFalsy()
    await client.close()
  })

  it('is a different secret from the attended one, not a spelling of it', () => {
    expect(endpoint.unattendedToken).not.toBe(endpoint.token)
    expect(endpoint.unattendedToken).toHaveLength(endpoint.token.length)
  })

  it('refuses a token that is neither', async () => {
    await expect(connect('0'.repeat(64))).rejects.toThrow()
  })
})

/* -------------------------------------------------------------- lifecycle -- */

describe('starting and stopping', () => {
  it('joins an in-flight start rather than opening a second socket', async () => {
    await stopDeckControlServer()
    const log = new ActionLog({ dir })
    const consent = new ConsentBroker({ ask: () => false })
    const control = new DeckControl({ surface: fake().surface, log, consent })

    const [first, second] = await Promise.all([
      startDeckControlServer({ control }),
      startDeckControlServer({ control }),
    ])
    // Two callers arriving before `listen` resolves would otherwise both build
    // a server, leaving the first listening on a port nobody holds.
    expect(first.port).toBe(second.port)
    endpoint = first
  })

  it('stops answering once it is stopped', async () => {
    const port = endpoint.port
    await stopDeckControlServer()
    expect(currentEndpoint()).toBeNull()

    await expect(
      fetch(`http://127.0.0.1:${port}${MCP_PATH}`, { method: 'POST', body: '{}' }),
    ).rejects.toThrow()

    // Left in a state `afterEach` can tear down twice without complaining.
    await boot()
  })
})
