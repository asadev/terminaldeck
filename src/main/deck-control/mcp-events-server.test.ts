import { mkdtempSync, rmSync } from 'node:fs'
import { createServer, type Server as HttpServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ActionRow } from './action-log'
import { keyRig, type KeyRig } from './key-door.fixture'
import type { CallbackPost } from './mcp-events-callback'
import { McpEvents, SUBSCRIPTION_HEADER } from './mcp-events'
import { NotifyDetector } from './notify-detect'
import { NotificationHub, REAL_CLOCK } from './notify-hub'
import { notifyTools } from './notify-tools'
import { verifyWebhook } from './notify-webhook'
import { openStandaloneDeckControlServer, type StandaloneDeckControlServer } from './server'

/**
 * ChatGPT's MCP Events, end to end on this Mac: the 2026-07-28 protocol in, a
 * signed push out.
 *
 * The real loopback server, the real key door, a real `DeckControl` with the
 * notification tools, the real detector and queue, and `McpEvents`. The client
 * is played with raw HTTP in exactly the shape the 2026-07-28 revision puts on
 * the wire — the `_meta` envelope, `MCP-Protocol-Version`, `Mcp-Method`,
 * `Mcp-Name` — because that is what ChatGPT sends and the test should show it.
 * The receiver is a real HTTP server on 127.0.0.1; the only liberty taken is
 * the poster, which carries a delivery addressed to a public https callback to
 * that receiver instead (the real poster refuses 127.0.0.1 — see
 * `mcp-events-callback.test.ts`).
 */

const PROTOCOL = '2026-07-28'
const CALLBACK = 'https://callbacks.example.com/mcp/events'
const SECRET = `whsec_${Buffer.alloc(32, 3).toString('base64')}`

interface Received {
  headers: Record<string, string>
  body: string
}

let dir = ''
let rig: KeyRig
let hub: NotificationHub
let events: McpEvents
let detector: NotifyDetector
let server: StandaloneDeckControlServer | null = null
let receiver: HttpServer | null = null
let received: Received[] = []
let receiverUrl = ''
let nextId = 1

/** Carries a post for the public callback to the receiver on 127.0.0.1. */
const localPost: CallbackPost = async (url, headers, body) => {
  const target = new URL(url)
  const response = await fetch(`${receiverUrl}${target.pathname}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body,
  })
  return { status: response.status, body: await response.text() }
}

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-mcp-events-server-'))
  received = []
  receiver = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8')
      const headers = Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)]))
      received.push({ headers, body })
      const parsed = JSON.parse(body) as { type?: string; challenge?: string }
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(parsed.type === 'verification' ? JSON.stringify({ challenge: parsed.challenge }) : '{}')
    })
  })
  await new Promise<void>((resolve) => receiver?.listen(0, '127.0.0.1', resolve))
  receiverUrl = `http://127.0.0.1:${(receiver.address() as AddressInfo).port}`

  let detectorRef: NotifyDetector | null = null
  let hubRef: NotificationHub | null = null
  let eventsRef: McpEvents | null = null
  rig = keyRig(dir, {
    extraTools: notifyTools({ hub: () => hubRef }),
    onRow: (row: ActionRow) => detectorRef?.noteRow(row),
    events: () => eventsRef,
  })
  hub = new NotificationHub({ dir: null, settings: (keyId) => rig.keys.notifySettings(keyId), clock: REAL_CLOCK })
  hubRef = hub
  events = new McpEvents({
    dir: null,
    access: { mode: (keyId) => rig.keys.notifySettings(keyId)?.mode ?? null, internet: () => rig.keys.internet() },
    post: localPost,
    onDelivered: (keyId, eventId) => hub.deliveredBy(keyId, eventId, 'event'),
  })
  eventsRef = events
  detector = new NotifyDetector({
    surface: rig.app.surface,
    starterOf: (sessionId) => rig.control.starterOf(sessionId),
    // The same order `deck-control/index.ts` uses: queued first, then pushed.
    enqueue: (keyId, event) => {
      if (!hub.enqueue(keyId, event)) return false
      events.offer(keyId, event)
      return true
    },
    clock: REAL_CLOCK,
  })
  detectorRef = detector
  server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
})

afterEach(async () => {
  await server?.stop()
  server = null
  detector.stop()
  events.stop()
  hub.stop()
  rig.door.stop()
  await new Promise<void>((resolve) => (receiver ? receiver.close(() => resolve()) : resolve()))
  receiver = null
  rmSync(dir, { recursive: true, force: true })
})

/** One 2026-07-28 request, as ChatGPT sends it. */
async function modern(
  credential: string,
  method: string,
  params: Record<string, unknown> = {},
): Promise<{ status: number; body: { result?: Record<string, unknown>; error?: { code: number; message: string } } }> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${credential}`,
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    'mcp-protocol-version': PROTOCOL,
    'mcp-method': method,
  }
  if (method === 'tools/call') headers['mcp-name'] = String(params.name)
  const response = await fetch(server?.endpoint.url ?? '', {
    method: 'POST',
    headers,
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: nextId++,
      method,
      params: {
        ...params,
        _meta: {
          'io.modelcontextprotocol/protocolVersion': PROTOCOL,
          'io.modelcontextprotocol/clientCapabilities': {},
          'io.modelcontextprotocol/clientInfo': { name: 'openai-mcp', version: '2.0.0' },
        },
      },
    }),
  })
  return { status: response.status, body: (await response.json()) as never }
}

async function waitFor(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 3000
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

describe('the 2026-07-28 era on this server', () => {
  it('answers server/discover for a key with the events capability, and the instructions', async () => {
    const a = rig.key('work', { name: 'ChatGPT' })
    const { status, body } = await modern(a.key, 'server/discover')
    expect(status).toBe(200)
    expect(body.result?.supportedVersions).toContain(PROTOCOL)
    expect(body.result?.capabilities).toMatchObject({ tools: {}, events: {} })
    expect(String(body.result?.instructions)).toMatch(/notifications_wait/)
    // A 2026-era client names itself on every request, not in an initialize.
    expect(rig.keys.get(a.id)?.lastApp).toBe('openai-mcp 2.0.0')
  })

  it('lists the same tools to a key in both eras', async () => {
    const a = rig.key('work', { name: 'ChatGPT' })
    const modernTools = ((await modern(a.key, 'tools/list')).body.result?.tools as Array<{ name: string }>).map((t) => t.name)
    const client = new Client({ name: 'claude-ai', version: '1' }, { capabilities: {} })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(server?.endpoint.url ?? ''), {
        requestInit: { headers: { Authorization: `Bearer ${a.key}` } },
      }),
    )
    try {
      const legacyTools = (await client.listTools()).tools.map((t) => t.name)
      expect(modernTools).toEqual(legacyTools)
      expect(modernTools).toContain('notifications_wait')
      // The 2025 era is not shown the events capability: nothing there could use it.
      expect(client.getServerCapabilities()).not.toHaveProperty('events')
    } finally {
      await client.close()
    }
  })

  it('answers the old era in plain JSON, byte-shape unchanged', async () => {
    const a = rig.key('work', { name: 'Cursor' })
    const response = await fetch(server?.endpoint.url ?? '', {
      method: 'POST',
      headers: { authorization: `Bearer ${a.key}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'cursor', version: '1' } },
      }),
    })
    expect(response.status).toBe(200)
    expect(response.headers.get('content-type')).toMatch(/^application\/json/)
    const body = (await response.json()) as { result: { protocolVersion: string; capabilities: Record<string, unknown> } }
    expect(body.result.protocolVersion).toBe('2025-06-18')
    expect(body.result.capabilities).toEqual({ tools: {} })
  })

  it('offers no events to the copilot’s own token', async () => {
    const token = server?.endpoint.token ?? ''
    const discover = await modern(token, 'server/discover')
    expect(discover.body.result?.capabilities).not.toHaveProperty('events')
    const list = await modern(token, 'events/list')
    expect(list.body.error?.code).toBe(-32601)
  })

  it('refuses subscriptions/listen at once instead of holding a stream open', async () => {
    const a = rig.key('work')
    const { body } = await modern(a.key, 'subscriptions/listen', { notifications: { toolsListChanged: true } })
    expect(body.error?.code).toBe(-32601)
  })
})

describe('a session finishing, pushed to the app that started it', () => {
  it('subscribes, verifies the callback, and posts the signed event — to that app only', async () => {
    const a = rig.key('work', { name: 'ChatGPT' })
    const b = rig.key('work', { name: 'Another ChatGPT' })

    const listed = await modern(a.key, 'events/list')
    expect((listed.body.result?.events as Array<{ name: string }>).map((e) => e.name)).toContain('session.turn_finished')

    const started = await modern(a.key, 'tools/call', { name: 'sessions_start', arguments: { cwd: '/work/api' } })
    expect(started.body.error).toBeUndefined()
    const sessionId = ((started.body.result?.structuredContent as { session: { id: string } }) ?? { session: { id: '' } }).session.id
    expect(sessionId).not.toBe('')

    const subscribed = await modern(a.key, 'events/subscribe', {
      name: 'session.turn_finished',
      arguments: {},
      delivery: { mode: 'webhook', url: CALLBACK, secret: SECRET },
      cursor: null,
      ttlMs: 3_600_000,
    })
    expect(subscribed.body.error).toBeUndefined()
    const subscriptionId = String(subscribed.body.result?.id)
    expect(subscribed.body.result).toMatchObject({ cursor: null, truncated: false })
    // The other app subscribes to the same kind of news, at its own callback.
    const other = await modern(b.key, 'events/subscribe', {
      name: 'session.turn_finished',
      delivery: { mode: 'webhook', url: 'https://callbacks.example.com/other', secret: SECRET },
    })
    expect(other.body.error).toBeUndefined()
    expect(received.map((r) => (JSON.parse(r.body) as { type?: string }).type)).toEqual(['verification', 'verification'])

    detector.noteStatus(sessionId, 'working')
    detector.noteStatus(sessionId, 'completed')
    await waitFor(() => received.length === 3, 'the push')

    const push = received[2]
    const payload = JSON.parse(push.body) as { eventId: string; name: string; data: { sessionId: string; type: string } }
    expect(payload.name).toBe('session.turn_finished')
    expect(payload.data).toMatchObject({ sessionId, type: 'finished' })
    expect(push.headers['webhook-id']).toBe(payload.eventId)
    expect(push.headers[SUBSCRIPTION_HEADER.toLowerCase()]).toBe(subscriptionId)
    expect(verifyWebhook(SECRET, push.headers, push.body)).toEqual({ ok: true })

    // The queue counts it delivered, by the push.
    await waitFor(() => hub.list(a.id)[0]?.delivery === 'delivered', 'the queue to hear')
    expect(hub.list(a.id)[0]).toMatchObject({ id: payload.eventId, via: 'event' })
    // And the other app heard nothing about a session that is not its own.
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(received).toHaveLength(3)
    expect(hub.list(b.id)).toEqual([])

    // Unsubscribing is idempotent and stops it.
    const params = { name: 'session.turn_finished', arguments: {}, delivery: { url: CALLBACK } }
    expect((await modern(a.key, 'events/unsubscribe', params)).body.result).toMatchObject({})
    expect((await modern(a.key, 'events/unsubscribe', params)).body.error).toBeUndefined()
    expect(events.subscriptions(a.id)).toEqual([])
  })

  it('tells an app whose notifications are off why it cannot subscribe', async () => {
    const a = rig.key('work', { name: 'ChatGPT' })
    rig.keys.setNotify(a.id, { mode: 'off' })
    const refused = await modern(a.key, 'events/subscribe', {
      name: 'session.turn_finished',
      delivery: { mode: 'webhook', url: CALLBACK, secret: SECRET },
    })
    expect(refused.body.error?.code).toBe(-32012)
    expect(refused.body.error?.message).toMatch(/switched notifications off/)
    expect(received).toEqual([])
  })
})
