import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { tiersFor } from './access-keys'
import type { ActionRow } from './action-log'
import { keyRig, type KeyRig } from './key-door.fixture'
import { ANSWER_LAG_MS, ANSWER_LAG_RETRIES, SETTLE_MS, NotifyDetector } from './notify-detect'
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
/**
 * The newest thing each session's agent said, as its transcript would show it.
 * A session not in here has said one thing; `null` means nothing yet, the way a
 * Claude Code session that has only drawn its banner has no transcript.
 */
let answers: Map<string, { at: number; text: string } | null>
let said = 0

/** The agent says something new in this session. */
function say(sessionId: string, text = `answer ${(said += 1)}`): void {
  answers.set(sessionId, { at: clock.now() + said, text })
}

function newDetector(target: NotificationHub): NotifyDetector {
  return new NotifyDetector({
    surface: rig.app.surface,
    starterOf: (sessionId) => rig.control.starterOf(sessionId),
    enqueue: (keyId, event, turn) => target.enqueue(keyId, event, turn),
    clock,
    answer: async (meta) => {
      const answer = answers.has(meta.id) ? answers.get(meta.id) : { at: clock.now(), text: `the first answer in ${meta.id}` }
      return answer === null || answer === undefined ? null : { ...answer, truncated: false }
    },
  })
}

function caller(id: string, name: string, level: 'work' | 'full' = 'work'): Caller {
  return { kind: 'key', keyId: id, keyName: name, tiers: tiersFor(level), askFirst: false }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-notify-detect-'))
  clock = new ManualClock()
  answers = new Map()
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
  detector = newDetector(hub)
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

/** One whole turn, the way the hooks report it, ending on something new. */
async function turn(sessionId: string): Promise<void> {
  say(sessionId)
  detector.noteStatus(sessionId, 'working')
  detector.noteStatus(sessionId, 'completed')
  await settle()
}

/** Every re-read of a transcript that has not caught up, on the test's clock. */
async function waitOutLag(): Promise<void> {
  for (let i = 0; i <= ANSWER_LAG_RETRIES; i += 1) {
    await settle()
    clock.advance(ANSWER_LAG_MS)
  }
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

  it('tells one answer once, however often the screen redraws after it', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    const sent = await rig.control.call('sessions.send', { sessionId: sA, text: 'reply OK' }, { caller: caller(a.id, 'App A') })
    expect(sent.ok, sent.error ?? '').toBe(true)
    say(sA, 'DOT_PUSH_TEST_OK')
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'idle')
    clock.advance(SETTLE_MS)
    await settle()
    expect(hub.list(a.id).map((n) => n.answer?.text)).toEqual(['DOT_PUSH_TEST_OK'])

    // The redraws seen in his queue: 7 s, 17 min, an hour and six hours later,
    // a hook's `completed` among them, the answer unchanged — and one acked.
    hub.ack(a.id, [hub.list(a.id)[0].id])
    for (const gap of [7_000, 17 * 60_000, 60 * 60_000, 6 * 60 * 60_000]) {
      clock.advance(gap)
      detector.noteStatus(sA, 'working')
      detector.noteStatus(sA, gap === 7_000 ? 'completed' : 'idle')
      clock.advance(SETTLE_MS)
      await settle()
    }
    expect(hub.size(a.id)).toBe(0)

    // Something new said is a new turn.
    await turn(sA)
    expect(hub.size(a.id)).toBe(1)
  })

  it('does not count a Claude Code session starting up as a finished turn', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    // No transcript yet; the banner reads as working then calm, four times over.
    answers.set(sA, null)
    for (let i = 0; i < 4; i += 1) {
      detector.noteStatus(sA, 'working')
      detector.noteStatus(sA, 'idle')
      clock.advance(SETTLE_MS + 6_500)
      await settle()
    }
    expect(hub.size(a.id)).toBe(0)

    // The app's first message is a turn: told, with the answer.
    const sent = await rig.control.call('sessions.send', { sessionId: sA, text: 'hello' }, { caller: caller(a.id, 'App A') })
    expect(sent.ok, sent.error ?? '').toBe(true)
    await turn(sA)
    expect(types(a.id)).toEqual([[sA, 'finished']])
    expect(hub.list(a.id)[0].answer).toBeDefined()
  })

  it('still tells a turn an app sent when no transcript can be found, from the screen, once', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    answers.set(sA, null)
    const sent = await rig.control.call('sessions.send', { sessionId: sA, text: 'hello' }, { caller: caller(a.id, 'App A') })
    expect(sent.ok, sent.error ?? '').toBe(true)
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'completed')
    await waitOutLag()
    expect(hub.list(a.id)).toHaveLength(1)
    expect(hub.list(a.id)[0]).toMatchObject({ type: 'finished', suggestedTool: 'sessions_screen' })
    // The redraw after it has no sender and no transcript: nothing.
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'completed')
    await waitOutLag()
    expect(hub.size(a.id)).toBe(1)
  })

  it('does not count a session resumed on an older answer as a finished turn', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    say(sA, 'said yesterday, and never told')
    clock.advance(24 * 60 * 60_000)
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'idle')
    clock.advance(SETTLE_MS)
    await settle()
    expect(hub.size(a.id)).toBe(0)
  })

  it('reads the transcript again when the hook that ends a turn beats the answer to it', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    say(sA, 'the answer before')
    clock.advance(60_000)
    const sent = await rig.control.call('sessions.send', { sessionId: sA, text: 'go on' }, { caller: caller(a.id, 'App A') })
    expect(sent.ok, sent.error ?? '').toBe(true)
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'completed')
    await settle()
    // The transcript still ends on the last turn's answer: not told yet, and not told wrong.
    expect(hub.size(a.id)).toBe(0)
    say(sA, 'the late answer')
    clock.advance(ANSWER_LAG_MS)
    await settle()
    expect(hub.list(a.id).map((n) => n.answer?.text)).toEqual(['the late answer'])
  })

  it('tells a turn an app sent from the screen when its answer never reaches the transcript', async () => {
    const a = rig.key('work', { name: 'App A' })
    const sA = await start(caller(a.id, 'App A'), '/work/api')
    say(sA, 'the answer before')
    clock.advance(60_000)
    const sent = await rig.control.call('sessions.send', { sessionId: sA, text: 'go on' }, { caller: caller(a.id, 'App A') })
    expect(sent.ok, sent.error ?? '').toBe(true)
    detector.noteStatus(sA, 'working')
    detector.noteStatus(sA, 'completed')
    for (let i = 0; i < ANSWER_LAG_RETRIES; i += 1) {
      await settle()
      expect(hub.size(a.id)).toBe(0)
      clock.advance(ANSWER_LAG_MS)
    }
    await settle()
    expect(hub.list(a.id)).toHaveLength(1)
    expect(hub.list(a.id)[0]).toMatchObject({ type: 'finished', suggestedTool: 'sessions_screen' })
  })

  it('remembers what it told across a restart, acknowledged or not', async () => {
    const disk = mkdtempSync(join(tmpdir(), 'td-notify-turns-'))
    try {
      const a = rig.key('work', { name: 'App A' })
      const sA = await start(caller(a.id, 'App A'), '/work/api')
      const first = new NotificationHub({ dir: disk, settings: (keyId) => rig.keys.notifySettings(keyId), clock })
      const before = newDetector(first)
      say(sA, 'the answer before the restart')
      before.noteStatus(sA, 'working')
      before.noteStatus(sA, 'completed')
      await settle()
      expect(first.size(a.id)).toBe(1)
      first.ack(a.id, [first.list(a.id)[0].id])
      before.stop()
      first.stop()

      // The app comes back; the session redraws on the same last answer.
      const second = new NotificationHub({ dir: disk, settings: (keyId) => rig.keys.notifySettings(keyId), clock })
      const after = newDetector(second)
      after.noteStatus(sA, 'working')
      after.noteStatus(sA, 'idle')
      clock.advance(SETTLE_MS)
      await settle()
      expect(second.size(a.id)).toBe(0)
      after.stop()
      second.stop()
    } finally {
      rmSync(disk, { recursive: true, force: true })
    }
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
