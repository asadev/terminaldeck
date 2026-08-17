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
    newestTranscript: async () => null,
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
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
  it('lists every tool with a schema and a read-only hint', async () => {
    const client = await connect()
    const { tools } = await client.listTools()

    expect(tools.map((tool) => tool.name).sort()).toEqual([
      'alerts_list',
      'git_status',
      'log_note',
      'projects_list',
      'sessions_get',
      'sessions_list',
      'sessions_send',
      'sessions_start',
      'sessions_stop',
      'sessions_transcript',
      'settings_read',
      'settings_write',
    ])

    const write = tools.find((tool) => tool.name === 'settings_write')
    expect(write?.annotations?.readOnlyHint).toBe(false)
    expect(write?.annotations?.destructiveHint).toBe(true)
    expect(tools.find((tool) => tool.name === 'sessions_list')?.annotations?.readOnlyHint).toBe(true)

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
    expect(String((result.content as Array<{ text: string }>)[0].text)).toContain('no live session')

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
