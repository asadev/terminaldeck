/**
 * An AI app on the internet hearing about its session through the relay.
 *
 * The real relay on a loopback port, this Mac's real relay link, the real key
 * door, a real `DeckControl` with the notification tools, and the official MCP
 * client dialling the relay's secret link — the path claude.ai and ChatGPT
 * take. The app starts a session, parks a `notifications_wait`, the session
 * finishes a turn, and the answer comes back up the relay as the wait's result.
 *
 * The relay holds a request for at most `MCP_RELAY_WAIT_MS`; the wait's own
 * ceiling sits under it (`notify-hub.test.ts` pins the gap), so a long-poll
 * through the internet always ends as an answer the agent can read.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRelayServer, type RelayServer } from '../../../relay/src/rendezvous'
import type { ActionRow } from '../deck-control/action-log'
import { keyRig, type KeyRig } from '../deck-control/key-door.fixture'
import { NotifyDetector } from '../deck-control/notify-detect'
import { NotificationHub, REAL_CLOCK, type NotificationEvent } from '../deck-control/notify-hub'
import { notifyTools } from '../deck-control/notify-tools'
import { loadHostIdentity } from './host-identity'
import { createRelayClient, type RelayLink } from './relay-client'
import { RelayMcpSwitchboard } from './relay-mcp'

let dir = ''
let relay: RelayServer | null = null
let link: RelayLink | null = null
let rig: KeyRig
let hub: NotificationHub
let detector: NotifyDetector
let said = 0
const clients: Client[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-notify-relay-'))
})

afterEach(async () => {
  for (const client of clients.splice(0)) await client.close().catch(() => undefined)
  link?.stop()
  link = null
  detector?.stop()
  hub?.stop()
  rig?.door.stop()
  await relay?.close()
  relay = null
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
  rig = keyRig(dir, {
    extraTools: notifyTools({ hub: () => hubRef }),
    onRow: (row: ActionRow) => detectorRef?.noteRow(row),
  })
  hub = new NotificationHub({ dir: null, settings: (keyId) => rig.keys.notifySettings(keyId), clock: REAL_CLOCK })
  hubRef = hub
  detector = new NotifyDetector({
    surface: rig.app.surface,
    starterOf: (sessionId) => rig.control.starterOf(sessionId),
    enqueue: (keyId, event, turn) => hub.enqueue(keyId, event, turn),
    clock: REAL_CLOCK,
    // Each turn ends on something new, as a real transcript would.
    answer: async () => ({ at: Date.now(), text: `answer ${(said += 1)}`, truncated: false }),
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

describe('a long-poll through the relay', () => {
  it('returns a session’s finished turn to the app that started it, and to nobody else', async () => {
    const { port, hostId } = await boot()
    rig.keys.setInternet(true)
    const a = rig.key('work', { name: 'Claude on the web' })
    const b = rig.key('work', { name: 'Another app' })
    await new Promise((resolve) => setTimeout(resolve, 30))

    const client = new Client({ name: 'claude-ai', version: '0.1.0' }, { capabilities: {} })
    await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp/${hostId}/${a.key}`)))
    clients.push(client)
    const other = new Client({ name: 'other', version: '1' }, { capabilities: {} })
    await other.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp/${hostId}/${b.key}`)))
    clients.push(other)

    const started = await client.callTool({ name: 'sessions_start', arguments: { cwd: '/work/api' } })
    expect(started.isError).not.toBe(true)
    const sessionId = (started.structuredContent as { session: { id: string } }).session.id

    // Both apps park a wait; only the starter's comes back with news.
    const mine = client.callTool({ name: 'notifications_wait', arguments: { timeoutSeconds: 10 } })
    const theirs = other.callTool({ name: 'notifications_wait', arguments: { timeoutSeconds: 2 } })
    await waitFor(() => (hub as unknown as { waiters: Set<unknown> }).waiters.size === 2, 'both waits to park')
    detector.noteStatus(sessionId, 'working')
    detector.noteStatus(sessionId, 'completed')

    const got = (await mine).structuredContent as { notifications: NotificationEvent[] }
    expect(got.notifications.map((n) => [n.sessionId, n.type])).toEqual([[sessionId, 'finished']])
    const nothing = (await theirs).structuredContent as { notifications: NotificationEvent[]; timedOut: boolean }
    expect(nothing).toMatchObject({ notifications: [], timedOut: true })

    // And the app acks it through the same link.
    const ack = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'notifications_ack', arguments: { ids: [got.notifications[0].id] } },
    })
    expect(ack.structuredContent).toEqual({ acked: [got.notifications[0].id], alreadyGone: [] })
  }, 15_000)
})
