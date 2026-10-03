/**
 * ChatGPT's MCP Events through the relay: the internet road, end to end.
 *
 * The real relay on a loopback port, this Mac's real relay link, the real key
 * door with `McpEvents` behind it, and the 2026-07-28 protocol spoken to the
 * relay's secret link exactly as ChatGPT speaks it — `_meta` envelope,
 * `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`.
 *
 * The relay forwards a fixed set of headers and the 2026 standard headers are
 * not among them, so they never reach this Mac; it rebuilds them from the body
 * (`mcp-serve.ts`). This test is the proof that a 2026 request survives that
 * road, and that the relay itself needed no change to carry it.
 *
 * The callback receiver is a real HTTP server on 127.0.0.1, reached through a
 * poster that stands in for the public-internet one (which refuses 127.0.0.1).
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { createServer, type Server as HttpServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRelayServer, type RelayServer } from '../../../relay/src/rendezvous'
import type { ActionRow } from '../deck-control/action-log'
import { keyRig, type KeyRig } from '../deck-control/key-door.fixture'
import { McpEvents } from '../deck-control/mcp-events'
import type { CallbackPost } from '../deck-control/mcp-events-callback'
import { NotifyDetector } from '../deck-control/notify-detect'
import { NotificationHub, REAL_CLOCK } from '../deck-control/notify-hub'
import { notifyTools } from '../deck-control/notify-tools'
import { verifyWebhook } from '../deck-control/notify-webhook'
import { loadHostIdentity } from './host-identity'
import { createRelayClient, type RelayLink } from './relay-client'
import { RelayMcpSwitchboard } from './relay-mcp'

const PROTOCOL = '2026-07-28'
const SECRET = `whsec_${Buffer.alloc(32, 5).toString('base64')}`

let dir = ''
let relay: RelayServer | null = null
let link: RelayLink | null = null
let rig: KeyRig
let hub: NotificationHub
let events: McpEvents
let detector: NotifyDetector
let receiver: HttpServer | null = null
let receiverUrl = ''
let received: Array<{ headers: Record<string, string>; body: string }> = []
let nextId = 1

const localPost: CallbackPost = async (url, headers, body) => {
  const response = await fetch(`${receiverUrl}${new URL(url).pathname}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body,
  })
  return { status: response.status, body: await response.text() }
}

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-mcp-events-relay-'))
  received = []
  receiver = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8')
      received.push({ headers: Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)])), body })
      const parsed = JSON.parse(body) as { type?: string; challenge?: string }
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(parsed.type === 'verification' ? JSON.stringify({ challenge: parsed.challenge }) : '{}')
    })
  })
  await new Promise<void>((resolve) => receiver?.listen(0, '127.0.0.1', resolve))
  receiverUrl = `http://127.0.0.1:${(receiver.address() as AddressInfo).port}`
})

afterEach(async () => {
  link?.stop()
  link = null
  detector?.stop()
  events?.stop()
  hub?.stop()
  rig?.door.stop()
  await relay?.close()
  relay = null
  await new Promise<void>((resolve) => (receiver ? receiver.close(() => resolve()) : resolve()))
  receiver = null
  rmSync(dir, { recursive: true, force: true })
})

async function waitFor(predicate: () => boolean, label: string, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

async function boot(): Promise<{ port: number; hostId: string }> {
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
    enqueue: (keyId, event) => {
      if (!hub.enqueue(keyId, event)) return false
      events.offer(keyId, event)
      return true
    },
    clock: REAL_CLOCK,
  })
  detectorRef = detector

  relay = createRelayServer({ heartbeatMs: 60_000 })
  await new Promise<void>((resolve) => relay?.server.listen(0, '127.0.0.1', resolve))
  const port = (relay.server.address() as AddressInfo).port
  const board = new RelayMcpSwitchboard()
  board.install(rig.door)
  const identity = loadHostIdentity(join(dir, 'identity'))
  link = createRelayClient({
    url: `ws://127.0.0.1:${port}`,
    identity,
    isKnownDevice: () => false,
    baseBackoffMs: 20,
    maxBackoffMs: 100,
    watchdogMs: 0,
    mcp: board,
  })
  link.start(() => false)
  await waitFor(() => link?.state().connected === true, 'the link')
  return { port, hostId: identity.hostId }
}

describe('MCP Events through the relay', () => {
  it('discovers, subscribes and receives a signed push over the secret link, with the relay unchanged', async () => {
    const { port, hostId } = await boot()
    rig.keys.setInternet(true)
    const a = rig.key('work', { name: 'ChatGPT' })
    await new Promise((resolve) => setTimeout(resolve, 30))
    const secretLink = `http://127.0.0.1:${port}/mcp/${hostId}/${a.key}`

    const call = async (method: string, params: Record<string, unknown> = {}) => {
      const headers: Record<string, string> = {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        'mcp-protocol-version': PROTOCOL,
        'mcp-method': method,
      }
      if (method === 'tools/call') headers['mcp-name'] = String(params.name)
      const response = await fetch(secretLink, {
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
      return (await response.json()) as { result?: Record<string, unknown>; error?: { code: number; message: string } }
    }

    const discover = await call('server/discover')
    expect(discover.error).toBeUndefined()
    expect(discover.result?.capabilities).toMatchObject({ events: {} })

    const started = await call('tools/call', { name: 'sessions_start', arguments: { cwd: '/work/api' } })
    expect(started.error).toBeUndefined()
    const sessionId = (started.result?.structuredContent as { session: { id: string } }).session.id

    const subscribed = await call('events/subscribe', {
      name: 'session.turn_finished',
      arguments: { sessionId },
      delivery: { mode: 'webhook', url: 'https://callbacks.example.com/chatgpt', secret: SECRET },
      cursor: null,
    })
    expect(subscribed.error).toBeUndefined()
    expect(events.subscriptions(a.id)).toMatchObject([{ host: 'callbacks.example.com', sessionId }])

    detector.noteStatus(sessionId, 'working')
    detector.noteStatus(sessionId, 'completed')
    await waitFor(() => received.length === 2, 'the push')

    const push = received[1]
    expect(JSON.parse(push.body)).toMatchObject({ name: 'session.turn_finished', data: { sessionId, type: 'finished' } })
    expect(verifyWebhook(SECRET, push.headers, push.body)).toEqual({ ok: true })
    expect(push.headers['x-mcp-subscription-id']).toBe(subscribed.result?.id)

    // Internet reach off: the secret link closes, and so do the pushes it set up.
    rig.keys.setInternet(false)
    detector.noteStatus(sessionId, 'working')
    detector.noteStatus(sessionId, 'completed')
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(received).toHaveLength(2)
  }, 15_000)
})
