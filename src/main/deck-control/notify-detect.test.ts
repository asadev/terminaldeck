import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { tiersFor } from './access-keys'
import type { ActionRow } from './action-log'
import { keyRig, type KeyRig } from './key-door.fixture'
import { SETTLE_MS, NotifyDetector } from './notify-detect'
import { NotificationHub, type HubClock, type NotificationEvent } from './notify-hub'
import { notifyTools } from './notify-tools'
import { openStandaloneDeckControlServer, type StandaloneDeckControlServer } from './server'
import type { Caller } from './surface'

/**
 * Whose notification is whose, through the real dispatcher.
 *
 * Two AI apps on two keys, each with its own sessions, interleaved — and one of
 * them allowed into the other's session for one turn. Every rule from the
 * owner's brief is asked here against `DeckControl`'s own record of who started
 * what and its own action log rows for who sent what:
 *
 *  - a session's turns and its exit go to the app that started it;
 *  - a turn another app triggered goes to THAT app, and the starter hears
 *    nothing about it;
 *  - the copilot's turns, and the copilot's own sessions, notify nobody;
 *  - one app's list, wait and ack cannot see the other's.
 *
 * Statuses are fed the way `src/main/index.ts` feeds them — `noteStatus` from
 * the same `onStatus` that colours the sidebar — on a clock the test moves.
 */

class ManualClock implements HubClock {
  at = 5_000_000
  private seq = 0
  private readonly timers = new Map<number, { due: number; run: () => void }>()
  now(): number {
    return this.at
  }
  setTimeout(run: () => void, ms: number): unknown {
    const id = (this.seq += 1)
    this.timers.set(id, { due: this.at + ms, run })
    return id
  }
  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number)
  }
  advance(ms: number): void {
    const target = this.at + ms
    for (;;) {
      const next = [...this.timers.entries()].filter(([, t]) => t.due <= target).sort((a, b) => a[1].due - b[1].due)[0]
      if (!next) break
      this.at = next[1].due
      this.timers.delete(next[0])
      next[1].run()
    }
    this.at = target
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

let dir = ''
let rig: KeyRig
let hub: NotificationHub
let detector: NotifyDetector
let clock: ManualClock
let server: StandaloneDeckControlServer | null = null

function caller(id: string, name: string, level: 'work' | 'full' = 'work'): Caller {
  return { kind: 'key', keyId: id, keyName: name, tiers: tiersFor(level), askFirst: false }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-notify-detect-'))
  clock = new ManualClock()
  // The hub and the detector are built before the rig so the rig's row listener
  // can reach the detector — the same order `deck-control/index.ts` uses.
  let detectorRef: NotifyDetector | null = null
  let hubRef: NotificationHub | null = null
  rig = keyRig(dir, {
    approver: false,
    extraTools: notifyTools({ hub: () => hubRef }),
    onRow: (row: ActionRow) => detectorRef?.noteRow(row),
  })
  hub = new NotificationHub({ dir: null, settings: (keyId) => rig.keys.notifySettings(keyId), clock })
  hubRef = hub
  detector = new NotifyDetector({
    surface: rig.app.surface,
    starterOf: (sessionId) => rig.control.starterOf(sessionId),
    enqueue: (keyId, event) => hub.enqueue(keyId, event),
    clock,
  })
  detectorRef = detector
})

afterEach(async () => {
  await server?.stop()
  server = null
  detector.stop()
  hub.stop()
  rig.door.stop()
  rmSync(dir, { recursive: true, force: true })
})

async function start(who: Caller | undefined, cwd: string): Promise<string> {
  const result = await rig.control.call('sessions.start', { cwd }, who === undefined ? {} : { caller: who })
  expect(result.ok, result.error ?? '').toBe(true)
  return (result.value as { session: { id: string } }).session.id
}

/** One whole turn, the way the hooks report it. */
async function turn(sessionId: string): Promise<void> {
  detector.noteStatus(sessionId, 'working')
  detector.noteStatus(sessionId, 'completed')
  await settle()
}

function types(keyId: string): Array<[string, NotificationEvent['type']]> {
  return hub.list(keyId).map((n) => [n.sessionId, n.type])
}

describe('two apps, two keys, interleaved', () => {
  it('tells each app about its own sessions and nothing about the other’s', async () => {
    const a = rig.key('work', { name: 'App A' })
    const b = rig.key('work', { name: 'App B' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    const sB = await start(caller(b.id, 'App B'), '/work/site')

    detector.noteStatus(sA, 'working')
    detector.noteStatus(sB, 'working')
    detector.noteStatus(sB, 'input')
    detector.noteStatus(sA, 'completed')
    await settle()

    expect(types(a.id)).toEqual([[sA, 'finished']])
    expect(types(b.id)).toEqual([[sB, 'needs-input']])
    const question = hub.list(b.id)[0]
    expect(question.suggestedTool).toBe('sessions_keys')
    expect(question.note).toMatch(/sessions_keys/)

    detector.noteExit(sA, 1)
    await settle()
    expect(types(a.id)).toEqual([
      [sA, 'finished'],
      [sA, 'exited'],
    ])
    expect(hub.list(a.id)[1]).toMatchObject({ crashed: true, exitCode: 1, suggestedTool: 'sessions_result' })
    expect(types(b.id)).toEqual([[sB, 'needs-input']])
  })

  it('tells the app that triggered a turn, never the session’s starter', async () => {
    const a = rig.key('work', { name: 'App A' })
    const b = rig.key('full', { name: 'App B', askFirst: false })
    const sA = await start(caller(a.id, 'App A'), '/work/api')

    // B is let into A's session for one message (Full control, not asking).
    const sent = await rig.control.call('sessions.send', { sessionId: sA, text: 'hello' }, { caller: caller(b.id, 'App B', 'full') })
    expect(sent.ok, sent.error ?? '').toBe(true)
    await turn(sA)
    expect(types(b.id)).toEqual([[sA, 'finished']])
    expect(types(a.id)).toEqual([])

    // The next turn has no known trigger, so it is the starter's again.
    await turn(sA)
    expect(types(a.id)).toEqual([[sA, 'finished']])
    expect(types(b.id)).toHaveLength(1)
  })

  it('notifies nobody for the copilot’s turns or the copilot’s sessions', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    const sC = await start(undefined, '/work/site')

    // The copilot's own session: its turns and its exit are nobody's news.
    const own = await rig.control.call('sessions.send', { sessionId: sC, text: 'from the copilot' })
    expect(own.ok).toBe(true)
    await turn(sC)
    detector.noteExit(sC, 0)
    // A turn the copilot (or the person) triggered in the app's session — the
    // row the dispatcher writes when the owner allows it — is not the app's.
    detector.noteRow({ ...own.row, sessionId: sA })
    await turn(sA)
    await settle()
    expect(hub.size()).toBe(0)
  })

  it('turns one finished turn read off a flickering screen into one notification', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'waiting')
    clock.advance(SETTLE_MS / 2)
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'waiting')
    clock.advance(SETTLE_MS)
    await settle()
    expect(types(a.id)).toEqual([[sA, 'finished']])
  })

  it('keeps an app set to off out of it entirely', async () => {
    const a = rig.key('work', { name: 'App A' })
    rig.keys.setNotify(a.id, { mode: 'off' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    await turn(sA)
    expect(hub.size()).toBe(0)
  })
})

describe('the tools, over a real MCP connection, each key blind to the other', () => {
  async function connect(key: string): Promise<Client> {
    if (!server) server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
    const client = new Client({ name: 'outside-app', version: '1' }, { capabilities: {} })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(server.endpoint.url), {
        requestInit: { headers: { Authorization: `Bearer ${key}` } },
      }),
    )
    return client
  }

  /** Until a long-poll is parked in the hub — it crossed a real socket to get there. */
  async function parked(): Promise<void> {
    const waiters = (hub as unknown as { waiters: Set<unknown> }).waiters
    for (let i = 0; i < 200 && waiters.size === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 5))
  }

  function value(result: unknown): Record<string, unknown> {
    return (result as { structuredContent: Record<string, unknown> }).structuredContent
  }

  it('lists notifications_wait to an app, waits, acks, and refuses another key’s ids as unknown', async () => {
    const a = rig.key('work', { name: 'App A' })
    const b = rig.key('work', { name: 'App B' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    const clientA = await connect(a.key)
    const clientB = await connect(b.key)
    try {
      const names = (await clientA.listTools()).tools.map((tool) => tool.name)
      expect(names).toContain('notifications_wait')
      expect(names).not.toContain('app_where')
      expect(names.length).toBeLessThanOrEqual(20)
      // The server's own instructions say the same sentence the setup snippets do.
      expect(clientA.getInstructions()).toMatch(/call notifications_wait instead of polling sessions_wait/)

      const waiting = clientA.callTool({ name: 'notifications_wait', arguments: { timeoutSeconds: 5 } })
      await parked()
      await turn(sA)
      const got = value(await waiting)
      const notifications = got.notifications as NotificationEvent[]
      expect(notifications.map((n) => [n.sessionId, n.type])).toEqual([[sA, 'finished']])
      const id = notifications[0].id

      // B cannot see it, and acking it from B changes nothing.
      const listB = value(await clientB.callTool({ name: 'tools_run', arguments: { name: 'notifications_list' } }))
      expect(listB.notifications).toEqual([])
      const ackB = value(
        await clientB.callTool({ name: 'tools_run', arguments: { name: 'notifications_ack', arguments: { ids: [id, 'never'] } } }),
      )
      expect(ackB).toEqual({ acked: [], alreadyGone: [id, 'never'] })
      expect(hub.size(a.id)).toBe(1)

      // A acks it on its next wait, which then times out with nothing — on the
      // test's clock, which is the hub's.
      const nextCall = clientA.callTool({ name: 'notifications_wait', arguments: { timeoutSeconds: 1, ack: [id] } })
      await parked()
      clock.advance(1_000)
      const next = value(await nextCall)
      expect(next).toMatchObject({ notifications: [], timedOut: true, outstanding: 0 })
    } finally {
      await clientA.close()
      await clientB.close()
    }
  })

  it('is not listed to the copilot, and refuses it', async () => {
    if (!server) server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
    const client = new Client({ name: 'copilot', version: '1' }, { capabilities: {} })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(server.endpoint.url), {
        requestInit: { headers: { Authorization: `Bearer ${server.endpoint.token}` } },
      }),
    )
    try {
      const names = (await client.listTools()).tools.map((tool) => tool.name)
      expect(names.some((name) => name.startsWith('notifications_'))).toBe(false)
      const refused = await client.callTool({ name: 'notifications_wait', arguments: {} })
      expect(refused.isError).toBe(true)
    } finally {
      await client.close()
    }
  })
})
