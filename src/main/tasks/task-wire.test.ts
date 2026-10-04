import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { keyRig, type KeyRig } from '../deck-control/key-door.fixture'
import type { HubClock } from '../deck-control/notify-hub'
import { verifyWebhook } from '../deck-control/notify-webhook'
import { openStandaloneDeckControlServer, type StandaloneDeckControlServer } from '../deck-control/server'
import type { ToolContext } from '../deck-control/catalogue'
import { TaskApi } from './task-api'
import { folderAllowed, DEFAULT_CRM_STATUSES, TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { taskHttpHandler } from './task-http'
import { OUTBOX_FILE, TaskOutbox, type TaskEvent } from './task-outbox'
import { TaskStore } from './task-store'
import { taskTools } from './task-tools'

/**
 * The pieces around the engine: the settings that start safe, the outbox that
 * delivers each event once, and the two roads in — web requests on this Mac
 * and MCP tools — each refusing anybody without the right key.
 */

class ManualClock implements HubClock {
  at = 1_800_000_000_000
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

const SECRET = `whsec_${Buffer.alloc(32, 5).toString('base64')}`
let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-task-wire-'))
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

describe('settings', () => {
  it('starts every connection off, with nobody allowed, no folders, the default CRM statuses, and the secret shown once', () => {
    const config = new TaskConfig({ dir })
    const made = config.saveConnection('key-1', {})
    expect(made.view).toMatchObject({ enabled: false, allowedSenders: [], folders: [], hasEventsSecret: true })
    expect(made.view.statuses).toEqual(DEFAULT_CRM_STATUSES)
    expect(made.secret).toMatch(/^whsec_/)
    expect(config.saveConnection('key-1', { enabled: true }).secret).toBeNull()
    expect(JSON.stringify(config.connections())).not.toContain(made.secret)
    expect(statSync(join(dir, TASK_CONFIG_FILE)).mode & 0o777).toBe(0o600)
    // Kept across a restart.
    expect(new TaskConfig({ dir }).connection('key-1')?.enabled).toBe(true)
  })

  it('keeps the CRM’s statuses exactly as spelt, and refuses a mapping to one it does not have', () => {
    const config = new TaskConfig({ dir: null })
    expect(() => config.saveConnection('k', { statuses: { ...DEFAULT_CRM_STATUSES, onStarted: 'Doing' } })).toThrow(/has to be one of/)
    const custom = config.saveConnection('k', {
      statuses: { statuses: ['Open', 'Doing', 'Closed'], initial: 'Open', completed: 'Closed', onStarted: 'Doing', onVerified: 'Closed', onBlocked: null },
    })
    expect(custom.view.statuses.onBlocked).toBeNull()
  })

  it('refuses an identity for a missing agent, and forgets identities of an agent removed', () => {
    const config = new TaskConfig({ dir: null })
    expect(() => config.saveConnection('k', { identities: { 'u-x': 'ghost' } })).toThrow(/does not exist/)
    config.saveAgent({ id: 'builder', name: 'Builder' })
    config.saveConnection('k', { identities: { 'u-b': 'builder' } })
    config.removeAgent('builder')
    expect(config.connection('k')?.identities).toEqual({})
  })

  it('keeps an agent’s instructions, tools, skills and effort, and refuses an effort the sessions do not have', () => {
    const config = new TaskConfig({ dir })
    const saved = config.saveAgent({
      id: 'reviewer',
      name: 'Reviewer',
      effort: 'xhigh',
      instructions: 'Read the diff first.',
      toolsPreferred: ['Read', 'Read', 'Grep'],
      toolsAvoided: ['Bash'],
      skills: ['code-review'],
    })
    expect(saved).toMatchObject({ effort: 'xhigh', toolsPreferred: ['Read', 'Grep'], toolsAvoided: ['Bash'], skills: ['code-review'] })
    expect(new TaskConfig({ dir }).agent('reviewer')).toMatchObject({ instructions: 'Read the diff first.', skills: ['code-review'] })
    expect(() => config.saveAgent({ id: 'x', name: 'X', effort: 'turbo' })).toThrow(/effort has to be one of/)
    expect(() => config.saveAgent({ id: 'x', name: 'X', skills: Array.from({ length: 21 }, (_, n) => `s${n}`) })).toThrow(/at most 20/)
    // An agent saved before these fields existed reads with none of them.
    expect(config.saveAgent({ id: 'plain', name: 'Plain' })).toMatchObject({ effort: null, instructions: null, toolsPreferred: [], skills: [] })
  })

  it('allows a folder or what is inside it, never a sibling sharing a prefix or a way out', () => {
    const connection = { folders: ['/work/app'] }
    expect(folderAllowed(connection, '/work/app')).toBe(true)
    expect(folderAllowed(connection, '/work/app/src')).toBe(true)
    expect(folderAllowed(connection, '/work/app2')).toBe(false)
    expect(folderAllowed(connection, '/work/app/../secrets')).toBe(false)
  })
})

describe('the outbox', () => {
  function rig(statuses: number[], clock = new ManualClock()) {
    const got: Array<{ headers: Record<string, string>; body: string }> = []
    const ids: string[] = []
    const outbox = new TaskOutbox({
      dir,
      target: () => ({ url: 'https://crm.example.com/events', secret: SECRET }),
      clock,
      post: async (_url, headers, body) => {
        got.push({ headers, body })
        const status = statuses.length > 1 ? (statuses.shift() as number) : statuses[0]
        return { status, body: JSON.stringify({ externalCommentId: 'crm-c-9' }) }
      },
      onCommentId: (_keyId, id) => ids.push(id),
    })
    return { outbox, got, ids, clock }
  }
  const body = {
    type: 'task.comment' as const,
    externalTaskId: 't',
    originExternalTaskId: 't',
    externalThreadId: null,
    actor: 'u-builder',
    comment: { kind: 'progress' as const, body: 'Started.', inReplyTo: null },
  }

  it('signs each event, keeps its id through every retry, and stops after 5 s, 30 s and 2 min', async () => {
    const { outbox, got, clock } = rig([503])
    const event = outbox.send('k', body, 0)
    await settle()
    for (const step of [5_000, 30_000, 120_000]) {
      clock.advance(step)
      await settle()
    }
    expect(got).toHaveLength(4)
    for (const post of got) {
      expect(post.headers['webhook-id']).toBe(event.eventId)
      expect(verifyWebhook(SECRET, post.headers, post.body, Math.floor(clock.now() / 1000))).toEqual({ ok: true })
    }
    expect(outbox.list()[0]).toMatchObject({ state: 'undelivered', attempts: 4 })
    expect(outbox.armed()).toBe(false)
    outbox.stop()
  })

  it('does not retry a refusal, and remembers the comment id the CRM gives back', async () => {
    const refused = rig([400])
    refused.outbox.send('k', body, 0)
    await settle()
    refused.clock.advance(200_000)
    expect(refused.got).toHaveLength(1)
    expect(refused.outbox.list()[0].state).toBe('undelivered')
    refused.outbox.stop()

    const taken = rig([200])
    taken.outbox.send('k', body, 1)
    await settle()
    expect(taken.ids).toEqual(['crm-c-9'])
    taken.outbox.stop()
  })

  it('keeps what is owed across a restart, 0600, and posts it with the same id', async () => {
    const first = rig([503])
    const event = first.outbox.send('k', body, 0)
    await settle()
    first.outbox.stop()
    expect(statSync(join(dir, OUTBOX_FILE)).mode & 0o777).toBe(0o600)
    const second = rig([200], first.clock)
    first.clock.advance(5_000)
    await settle()
    expect((JSON.parse(second.got[0].body) as TaskEvent).eventId).toBe(event.eventId)
    second.outbox.stop()
  })
})

describe('the two roads in', () => {
  let rig: KeyRig
  let server: StandaloneDeckControlServer | null = null
  let api: TaskApi
  let crmKey: { key: string; id: string }

  beforeEach(() => {
    rig = keyRig(dir)
    crmKey = rig.key('work', { name: 'Example CRM' })
    const config = new TaskConfig({ dir: null })
    config.saveAgent({ id: 'builder', name: 'Builder' })
    config.saveConnection(crmKey.id, {
      enabled: true,
      identities: { 'u-builder': 'builder' },
      allowedSenders: ['u-asad'],
      folders: ['/work'],
    })
    const engine = { accept: async () => undefined, reply: async () => undefined, cancel: async () => undefined, reassign: async () => undefined }
    api = new TaskApi({ config, store: new TaskStore({ dir: null }), engine })
  })

  afterEach(async () => {
    await server?.stop()
    server = null
    rig.door.stop()
  })

  it('serves the task routes on this Mac to a valid key only, and never to a browser', async () => {
    server = await openStandaloneDeckControlServer({
      control: rig.control,
      keys: rig.door,
      tasks: taskHttpHandler({ api: () => api, keyOf: (header) => rig.keys.match(header?.replace(/^Bearer /, ''))?.id ?? null }),
    })
    const base = new URL(server.endpoint.url).origin
    const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
      fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) })
    const task = { eventId: 'e1', externalTaskId: 'T-1', title: 'Fix it', project: '/work/app', assignee: 'u-builder', requestedBy: 'u-asad' }

    expect((await post('/tasks', task)).status).toBe(403)
    expect((await post('/tasks', task, { authorization: 'Bearer ak_wrong' })).status).toBe(403)
    const made = await post('/tasks', task, { authorization: `Bearer ${crmKey.key}` })
    expect(made.status).toBe(200)
    expect(await made.json()).toMatchObject({ outcome: 'accepted', task: { externalTaskId: 'T-1' } })
    const read = await fetch(`${base}/tasks/T-1`, { headers: { authorization: `Bearer ${crmKey.key}` } })
    expect(await read.json()).toMatchObject({ task: { externalTaskId: 'T-1', crmStatus: 'To-Do' } })
    const dot = await post('/tasks', { ...task, eventId: 'e2', externalTaskId: 'T-2', assignee: 'u-dot' }, { authorization: `Bearer ${crmKey.key}` })
    expect(dot.status).toBe(409)
    expect(await dot.json()).toMatchObject({ error: { code: 'not_mine' } })
    const browser = await post('/tasks', task, { authorization: `Bearer ${crmKey.key}`, origin: 'https://evil.example' })
    expect(browser.status).toBe(403)
  })

  it('offers one CRM tool to a key, hides Hoot’s tools from it entirely, and runs the CRM tool through the same door', async () => {
    const store = new TaskStore({ dir: null })
    const tools = taskTools({ api: () => api, engine: () => null, store: () => store, config: () => null })
    const asKey = { caller: { kind: 'key', keyId: crmKey.id } } as unknown as ToolContext
    const asHoot = { caller: { kind: 'local' } } as unknown as ToolContext
    expect(() => tools.find((tool) => tool.wire === 'tasks_verify')!.precheck?.({ task: 'x', verified: true }, asKey)).toThrow(/Hoot’s own tool/)
    expect(() => tools.find((tool) => tool.wire === 'crm_task')!.precheck?.({ op: 'get' }, asHoot)).toThrow(/CRM connected with an access key/)

    // A real rig with the task tools in it, over a real MCP connection on the CRM's key.
    rig.door.stop()
    rig = keyRig(dir, { extraTools: taskTools({ api: () => api, engine: () => null, store: () => store, config: () => null }) })
    const key = rig.key('work', { name: 'Example CRM' })
    const config = new TaskConfig({ dir: null })
    config.saveAgent({ id: 'builder', name: 'Builder' })
    config.saveConnection(key.id, { enabled: true, identities: { 'u-builder': 'builder' }, allowedSenders: ['u-asad'], folders: ['/work'] })
    api = new TaskApi({
      config,
      store,
      engine: { accept: async () => undefined, reply: async () => undefined, cancel: async () => undefined, reassign: async () => undefined },
    })
    server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
    const client = new Client({ name: 'example-crm', version: '1' }, { capabilities: {} })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(server.endpoint.url), { requestInit: { headers: { Authorization: `Bearer ${key.key}` } } }),
    )
    try {
      const listed = (await client.listTools()).tools
      const everything = JSON.stringify(listed)
      // Hoot's tools are not listed, not even as an index line.
      for (const name of ['tasks_list', 'tasks_get', 'tasks_delegate', 'tasks_comment', 'tasks_verify', 'tasks_set_status']) {
        expect(everything).not.toContain(name)
      }
      // The CRM's one tool sits behind the index, and runs through tools_run.
      expect(everything).toContain('crm_task')
      const made = (await client.callTool({
        name: 'tools_run',
        arguments: {
          name: 'crm_task',
          arguments: { op: 'create', eventId: 'm1', externalTaskId: 'M-1', title: 'Fix it', project: '/work/app', assignee: 'u-builder', requestedBy: 'u-asad' },
        },
      })) as { isError?: boolean; structuredContent?: Record<string, unknown> }
      expect(made.isError ?? false).toBe(false)
      expect(store.get(key.id, 'M-1')).not.toBeNull()
      const refused = (await client.callTool({
        name: 'tools_run',
        arguments: { name: 'crm_task', arguments: { op: 'create', eventId: 'm2', externalTaskId: 'M-2', title: 'x', project: '/work/app', assignee: 'u-builder', requestedBy: 'u-employee' } },
      })) as { isError?: boolean; content?: Array<{ text?: string }> }
      expect(refused.isError).toBe(true)
      expect(JSON.stringify(refused.content)).toContain('not_allowed')
      const hootTool = (await client.callTool({ name: 'tools_run', arguments: { name: 'tasks_verify', arguments: { task: 'x', verified: true } } })) as {
        isError?: boolean
      }
      expect(hootTool.isError).toBe(true)
    } finally {
      await client.close()
    }
  })
})
