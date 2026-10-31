import { describe, expect, it } from 'vitest'
import { LOCAL_DETAIL_FNS, type LocalDetailFn } from '../../shared/crm/detail-contract'
import { caller, localDetailActions, localFieldActions, localProjectActions, searchTagsLocally, uploadOf, windowDetailBridge } from './local-actions'

/** The popup's calls: every one goes to the one channel, by name, with the CRM function's own arguments. */

type Call = { fn: LocalDetailFn; args: unknown[] }

function recorder(reply: unknown = { ok: true }): { calls: Call[]; bridge: (fn: LocalDetailFn, args: unknown[]) => Promise<unknown> } {
  const calls: Call[] = []
  return { calls, bridge: async (fn, args) => (calls.push({ fn, args }), reply) }
}

const file = (name: string, text: string): File => new File([text], name, { type: 'text/plain' })

describe('the local DetailActions', () => {
  it('sends every function by its own name, with its arguments in order', async () => {
    const { calls, bridge } = recorder()
    const actions = localDetailActions(bridge) as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>
    const sample: Record<string, unknown[]> = {
      setTaskStatus: ['local:a', 'Done'],
      updateTask: ['local:a', { title: 'New', priority: 'High' }],
      addTaskSubtask: ['local:a', 'Write it'],
      setTaskSubtaskDone: ['local:a', 's1', true],
      addTaskDependency: ['local:a', 'local:b', 'blocks'],
      addTaskTimeEntry: ['local:a', { seconds: 600, date: '2026-10-01', note: null, billable: false }],
      addTaskCommentWith: ['local:a', 'Hi @Builder', { parentId: 'c1', assigneeUserId: null, scheduledFor: null }],
      toggleCommentReaction: ['local:a', 'c1', '👍'],
      setLabelColor: ['web', 'red'],
    }
    const names = Object.keys(actions).filter((name) => name !== 'uploadTaskFile')
    for (const name of names) await actions[name](...(sample[name] ?? ['local:a', 'x']))
    expect(calls.map((call) => call.fn)).toEqual(names)
    for (const name of Object.keys(sample)) expect(calls.find((call) => call.fn === name)?.args).toEqual(sample[name])
    // Every function the CRM's panel calls is a function the channel answers.
    for (const name of names) expect(LOCAL_DETAIL_FNS as readonly string[]).toContain(name)
  })

  it('fills the optional arguments the CRM leaves out, so the main process always sees the whole list', async () => {
    const { calls, bridge } = recorder()
    const actions = localDetailActions(bridge)
    await actions.addChecklist('local:a')
    await actions.saveRoutine?.('local:a', null)
    await actions.setReminder?.('local:a', '2026-10-09T08:00:00.000Z')
    expect(calls).toEqual([
      { fn: 'addChecklist', args: ['local:a', null] },
      { fn: 'saveRoutine', args: ['local:a', null, null] },
      { fn: 'setReminder', args: ['local:a', '2026-10-09T08:00:00.000Z', null] },
    ])
  })

  it('carries a dropped or pasted file as its name, type and bytes', async () => {
    const { calls, bridge } = recorder({ ok: true, attachment: { id: 'f1' } })
    const result = await localDetailActions(bridge).uploadTaskFile('local:a', file('notes.txt', 'hello'))
    expect(result).toEqual({ ok: true, attachment: { id: 'f1' } })
    expect(calls[0].fn).toBe('uploadTaskFile')
    const [taskId, upload] = calls[0].args as [string, { name: string; type: string; bytes: Uint8Array }]
    expect(taskId).toBe('local:a')
    expect(upload.name).toBe('notes.txt')
    expect(upload.type).toBe('text/plain')
    expect(new TextDecoder().decode(upload.bytes)).toBe('hello')
    expect(await uploadOf(file('a.md', 'x'))).toMatchObject({ name: 'a.md' })
  })

  it('answers a failure as a sentence, never a rejection — and says so when there is no bridge at all', async () => {
    const thrown = caller(async () => {
      throw new Error('the main process went away')
    })
    expect(await thrown('fetchTaskDetailBundle', ['local:a'])).toEqual({ ok: false, error: 'the main process went away' })
    expect(await caller(async () => undefined)('listTaskComments', ['local:a'])).toEqual({ ok: false, error: 'Terminal Deck did not answer that.' })
    expect(await localDetailActions(null).setTaskStatus('local:a', 'Done')).toEqual({ ok: false, error: 'This build cannot change tasks.' })
  })

  it('finds the bridge on window.deck, called through its host', async () => {
    const host = {
      seen: [] as unknown[],
      tasksLocalDetail(fn: string, args: unknown[]) {
        this.seen.push([fn, args])
        return Promise.resolve({ ok: true })
      },
    }
    const global = globalThis as unknown as { deck?: unknown }
    const was = global.deck
    global.deck = host
    try {
      const bridge = windowDetailBridge()
      expect(bridge).not.toBeNull()
      await bridge?.('searchTags', ['task', 'pl'])
      expect(host.seen).toEqual([['searchTags', ['task', 'pl']]])
    } finally {
      global.deck = was
    }
    expect(windowDetailBridge()).toBeNull()
  })
})

describe('the local field actions, search and project folder', () => {
  it('send the CRM field calls by name', async () => {
    const { calls, bridge } = recorder()
    const fields = localFieldActions(bridge)
    await fields.listTaskFields('local:a')
    await fields.createTaskField('local:a', { label: 'Votes', kind: 'voting' })
    await fields.toggleTaskFieldVote('f1')
    await fields.pressTaskFieldButton('f2')
    await fields.reorderTaskFields('local:a', ['f2', 'f1'])
    await fields.uploadTaskFile('local:a', file('x.txt', 'x'))
    expect(calls.map((call) => call.fn)).toEqual(['listTaskFields', 'createTaskField', 'toggleTaskFieldVote', 'pressTaskFieldButton', 'reorderTaskFields', 'uploadTaskFile'])
    expect(calls[1].args).toEqual(['local:a', { label: 'Votes', kind: 'voting' }])
  })

  it('searches and sets the folder through the same channel', async () => {
    const { calls, bridge } = recorder({ ok: true, hits: [] })
    await searchTagsLocally('person', 'Bu', bridge)
    await localProjectActions(bridge).setTaskProject('local:a', '/work/app')
    await localProjectActions(bridge).chooseTaskProject('local:a')
    expect(calls).toEqual([
      { fn: 'searchTags', args: ['person', 'Bu'] },
      { fn: 'setTaskProject', args: ['local:a', '/work/app'] },
      { fn: 'chooseTaskProject', args: ['local:a'] },
    ])
  })
})
