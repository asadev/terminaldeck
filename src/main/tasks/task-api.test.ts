import { beforeEach, describe, expect, it } from 'vitest'
import { TaskApi } from './task-api'
import { TaskConfig } from './task-config'
import type { TaskRecord } from './task-store'
import { TaskStore } from './task-store'

/**
 * The CRM's side of the door: who may give work, whose work it is, once each,
 * and no loops — against a recording engine, so only the API's own rules are
 * asked here.
 */

const KEY = 'key-1'

let config: TaskConfig
let store: TaskStore
let api: TaskApi
let accepted: string[]
let replies: Array<[string, string]>
let cancelled: string[]
let reassigned: string[]
let n = 0

beforeEach(() => {
  config = new TaskConfig({ dir: null })
  config.saveAgent({ id: 'builder', name: 'Builder' })
  config.saveConnection(KEY, {
    enabled: true,
    hootIdentity: 'u-hoot',
    identities: { 'u-builder': 'builder' },
    allowedSenders: ['u-asad'],
    folders: ['/work'],
  })
  store = new TaskStore({ dir: null })
  accepted = []
  replies = []
  cancelled = []
  reassigned = []
  api = new TaskApi({
    config,
    store,
    engine: {
      accept: async (task: TaskRecord) => {
        accepted.push(task.externalTaskId)
      },
      reply: async (task: TaskRecord, text: string) => {
        replies.push([task.externalTaskId, text])
      },
      cancel: async (task: TaskRecord) => {
        cancelled.push(task.externalTaskId)
        task.stopped = true
      },
      reassign: async (task: TaskRecord) => {
        reassigned.push(task.externalTaskId)
      },
    },
  })
})

function create(over: Record<string, unknown> = {}) {
  n += 1
  return api.create(KEY, {
    eventId: `e-${n}`,
    externalTaskId: `t-${n}`,
    title: 'Fix the login bug',
    instructions: 'It throws on an empty password.',
    project: '/work/app',
    assignee: 'u-builder',
    requestedBy: 'u-asad',
    ...over,
  })
}

describe('who may give work', () => {
  it('refuses everything while the connection is off', async () => {
    config.saveConnection(KEY, { enabled: false })
    expect(await create()).toMatchObject({ ok: false, code: 'disabled' })
    expect(api.read(KEY, { externalTaskId: 'x' })).toMatchObject({ ok: false, code: 'disabled' })
  })

  it('accepts only the allowed CRM user, enforced here whatever the CRM shows', async () => {
    expect(await create({ requestedBy: 'u-employee' })).toMatchObject({ ok: false, code: 'not_allowed' })
    expect(await create({ requestedBy: 'u-hoot' })).toMatchObject({ ok: false, code: 'not_allowed' })
    expect(accepted).toEqual([])
    expect(await create()).toMatchObject({ ok: true, value: { outcome: 'accepted' } })
  })

  it('refuses work for anybody who is not Hoot or a mapped agent — Dot included', async () => {
    expect(await create({ assignee: 'u-dot' })).toMatchObject({ ok: false, code: 'not_mine' })
  })

  it('refuses a folder outside the allowed ones, judged after resolving it', async () => {
    expect(await create({ project: '/work/../etc' })).toMatchObject({ ok: false, code: 'folder_not_allowed' })
    expect(await create({ project: '/workshop' })).toMatchObject({ ok: false, code: 'folder_not_allowed' })
    expect(await create({ project: 'work/app' })).toMatchObject({ ok: false, code: 'folder_not_allowed' })
  })

  it('takes a child task from Hoot only under a Hoot task an allowed user gave, up to the hand-off limit', async () => {
    await create({ externalTaskId: 'root', assignee: 'u-hoot' })
    const child = await create({ externalTaskId: 'c1', parentExternalTaskId: 'root', requestedBy: 'u-hoot', project: undefined })
    expect(child).toMatchObject({ ok: true })
    expect(store.get(KEY, 'c1')).toMatchObject({ hops: 1, project: '/work/app', originExternalTaskId: 'root' })
    // Under an agent's task, Hoot is not a sender.
    expect(await create({ parentExternalTaskId: 'c1', requestedBy: 'u-hoot' })).toMatchObject({ ok: false, code: 'not_allowed' })

    config.saveConnection(KEY, { maxHops: 1 })
    await create({ externalTaskId: 'mid', parentExternalTaskId: 'root', assignee: 'u-hoot', requestedBy: 'u-asad' })
    expect(await create({ parentExternalTaskId: 'mid', requestedBy: 'u-asad' })).toMatchObject({ ok: false, code: 'too_many_hops' })
  })
})

describe('once each', () => {
  it('answers a repeated event id the same way, and starts nothing twice', async () => {
    const first = await api.create(KEY, { eventId: 'same', externalTaskId: 'A', title: 'x', project: '/work/app', assignee: 'u-builder', requestedBy: 'u-asad' })
    const again = await api.create(KEY, { eventId: 'same', externalTaskId: 'A', title: 'x', project: '/work/app', assignee: 'u-builder', requestedBy: 'u-asad' })
    expect(first.ok && again.ok).toBe(true)
    expect(again).toMatchObject({ ok: true, value: { duplicate: true, outcome: 'accepted' } })
    // The same task under a new event id is the same task.
    await api.create(KEY, { eventId: 'other', externalTaskId: 'A', title: 'x', project: '/work/app', assignee: 'u-builder', requestedBy: 'u-asad' })
    expect(accepted).toEqual(['A'])
    expect(store.all()).toHaveLength(1)
  })

  it('does not remember a refusal, so the same request goes through once the setting is fixed', async () => {
    expect(await api.create(KEY, { eventId: 'r', externalTaskId: 'R', title: 'x', project: '/other', assignee: 'u-builder', requestedBy: 'u-asad' })).toMatchObject({ ok: false })
    config.saveConnection(KEY, { folders: ['/work', '/other'] })
    expect(await api.create(KEY, { eventId: 'r', externalTaskId: 'R', title: 'x', project: '/other', assignee: 'u-builder', requestedBy: 'u-asad' })).toMatchObject({ ok: true })
  })
})

describe('comments, and no loops', () => {
  async function comment(over: Record<string, unknown>) {
    n += 1
    return api.comment(KEY, { eventId: `ce-${n}`, externalTaskId: 't-task', externalCommentId: `cc-${n}`, author: 'u-asad', body: 'Please also add a test.', ...over })
  }

  beforeEach(async () => {
    await create({ externalTaskId: 't-task' })
  })

  it('ignores every comment by our own identities, whatever it mentions', async () => {
    expect(await comment({ author: 'u-builder', mentions: ['u-hoot'] })).toMatchObject({ ok: true, value: { outcome: 'ignored_own_agent' } })
    expect(await comment({ author: 'u-hoot', mentions: ['u-builder'] })).toMatchObject({ ok: true, value: { outcome: 'ignored_own_agent' } })
    store.markOurs(KEY, 'crm-comment-we-posted')
    expect(await comment({ author: 'u-asad', externalCommentId: 'crm-comment-we-posted', mentions: ['u-builder'] })).toMatchObject({
      ok: true,
      value: { outcome: 'ignored_own_agent' },
    })
    expect(replies).toEqual([])
  })

  it('passes on only what an allowed user addressed to the agent', async () => {
    expect(await comment({ author: 'u-employee', mentions: ['u-builder'] })).toMatchObject({ value: { outcome: 'ignored_not_allowed' } })
    expect(await comment({})).toMatchObject({ value: { outcome: 'ignored_not_addressed' } })
    expect(await comment({ mentions: ['u-builder'] })).toMatchObject({ value: { outcome: 'answered' } })
    store.markOurs(KEY, 'our-question')
    expect(await comment({ inReplyTo: 'our-question' })).toMatchObject({ value: { outcome: 'answered' } })
    expect(replies).toHaveLength(2)
  })

  it('passes a comment on once, even when the CRM sends it again under a new event id', async () => {
    await comment({ externalCommentId: 'twice', mentions: ['u-builder'] })
    await comment({ externalCommentId: 'twice', mentions: ['u-builder'] })
    expect(replies).toHaveLength(1)
  })
})

describe('the CRM stays the task master', () => {
  beforeEach(async () => {
    await create({ externalTaskId: 'm' })
  })

  it('tells the board when a CRM status change is recorded', async () => {
    let told = 0
    const watched = new TaskApi({
      config,
      store,
      engine: { accept: async () => undefined, reply: async () => undefined, cancel: async () => undefined, reassign: async () => undefined },
      onChange: () => {
        told += 1
      },
    })
    await watched.status(KEY, { eventId: 'w1', externalTaskId: 'm', status: 'In Progress', changedBy: 'u-asad' })
    expect(told).toBe(1)
    // A repeat changes nothing, so it tells nobody.
    await watched.status(KEY, { eventId: 'w1', externalTaskId: 'm', status: 'In Progress', changedBy: 'u-asad' })
    expect(told).toBe(1)
  })

  it('records a status change and never acts on it', async () => {
    expect(await api.status(KEY, { eventId: 's1', externalTaskId: 'm', status: 'In Progress', changedBy: 'u-asad' })).toMatchObject({
      value: { outcome: 'recorded' },
    })
    expect(store.get(KEY, 'm')?.crmStatus).toBe('In Progress')
    expect(await api.status(KEY, { eventId: 's2', externalTaskId: 'm', status: 'Done', changedBy: 'u-builder' })).toMatchObject({
      value: { outcome: 'ignored_own_agent' },
    })
    expect(await api.status(KEY, { eventId: 's3', externalTaskId: 'm', status: 'Cancelled' })).toMatchObject({ ok: false, code: 'bad_request' })
    expect([...cancelled, ...replies.map(([id]) => id), ...reassigned]).toEqual([])
  })

  it('stops the work when the task is assigned to somebody who is not ours, and cancels on request', async () => {
    expect(await api.assign(KEY, { eventId: 'a1', externalTaskId: 'm', assignee: 'u-dot', requestedBy: 'u-asad' })).toMatchObject({
      value: { outcome: 'released' },
    })
    expect(cancelled).toEqual(['m'])
    expect(await api.assign(KEY, { eventId: 'a2', externalTaskId: 'm', assignee: 'u-hoot', requestedBy: 'u-employee' })).toMatchObject({
      ok: false,
      code: 'not_allowed',
    })
    await create({ externalTaskId: 'k' })
    expect(await api.cancel(KEY, { eventId: 'x1', externalTaskId: 'k', requestedBy: 'u-asad' })).toMatchObject({ value: { outcome: 'cancelled' } })
  })

  it('reads a task and its result by the CRM’s own id', async () => {
    expect(api.read(KEY, { externalTaskId: 'm' })).toMatchObject({
      ok: true,
      value: { task: { externalTaskId: 'm', agent: 'Builder', crmStatus: 'To-Do', process: 'queued', finished: false } },
    })
    expect(api.result(KEY, { externalTaskId: 'm' })).toMatchObject({ ok: true, value: { finished: false, answer: null } })
    expect(api.read(KEY, { externalTaskId: 'nope' })).toMatchObject({ ok: false, code: 'not_found' })
  })
})
