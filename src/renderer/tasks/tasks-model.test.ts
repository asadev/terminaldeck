import { describe, expect, it } from 'vitest'
import {
  DEFAULT_CRM_STATUSES,
  agentPayload,
  connectionDraftOf,
  connectionPatch,
  draftOf,
  keptOpenMinutes,
  processLabel,
  resolveTasksBridge,
  saveAgent,
  showMirror,
  slugFor,
  toTasksResult,
  toTasksState,
  type AgentProfile,
  type TasksState,
} from './tasks-model'

const EMPTY = { agents: [], connections: [], keys: [], tasks: [], trash: [], outbox: { pending: 0, undelivered: 0 }, localStatuses: ['To-Do'] }

const BUILDER: AgentProfile = {
  id: 'builder',
  name: 'Builder',
  role: 'builder',
  provider: 'codex',
  account: null,
  model: null,
  effort: null,
  instructions: null,
  toolsPreferred: [],
  toolsAvoided: [],
  skills: [],
  maxConcurrent: 2,
  maxRunMinutes: 60,
  keepAliveMinutes: 30,
  verifyCommand: 'npm test',
}

describe('reading what main answers', () => {
  it('reads a state and refuses something that is not one', () => {
    expect(toTasksState(EMPTY)).toEqual(EMPTY)
    expect(toTasksState(null)).toBeNull()
    expect(toTasksState({ agents: [] })).toBeNull()
  })

  it('never guesses a connection into being on', () => {
    const state = toTasksState({ ...EMPTY, connections: [{ keyId: 'k1', enabled: 'yes' }] })
    expect(state?.connections[0].enabled).toBe(false)
    // A connection with no statuses read gets the default CRM statuses, not an empty list.
    expect(state?.connections[0].statuses).toEqual(DEFAULT_CRM_STATUSES)
  })

  it('keeps the CRM status exactly as stored and the process state as its own thing', () => {
    const state = toTasksState({
      ...EMPTY,
      tasks: [{ id: 'k1:42', title: 'Fix login', agent: 'Builder', crmStatus: 'Working on it', process: 'running', keepOpenUntil: null }],
    })
    expect(state?.tasks[0].crmStatus).toBe('Working on it')
    expect(processLabel(state!.tasks[0].process)).toBe('Running')
    expect(processLabel('exited')).toBe('Finished')
    expect(processLabel('queued')).toBe('Queued')
  })

  it('carries a secret only on a success, and a plain sentence on a refusal', () => {
    expect(toTasksResult({ ok: true, state: EMPTY, secret: 'whsec_abc' }).secret).toBe('whsec_abc')
    expect(toTasksResult({ ok: false, message: 'No.', state: EMPTY, secret: 'whsec_abc' })).toMatchObject({
      ok: false,
      message: 'No.',
      secret: null,
    })
    expect(toTasksResult(undefined).message).toMatch(/did not go through/)
  })
})

describe('the mirror', () => {
  it('shows only with a task or a connection', () => {
    expect(showMirror(null)).toBe(false)
    expect(showMirror(EMPTY as TasksState)).toBe(false)
    expect(showMirror(toTasksState({ ...EMPTY, connections: [{ keyId: 'k1' }] }))).toBe(true)
    expect(showMirror(toTasksState({ ...EMPTY, tasks: [{ id: 't' }] }))).toBe(true)
  })

  it('counts kept-open minutes up, and stops once the time has passed', () => {
    expect(keptOpenMinutes(null, 0)).toBeNull()
    expect(keptOpenMinutes(1_000, 2_000)).toBeNull()
    expect(keptOpenMinutes(12 * 60_000, 0)).toBe(12)
    expect(keptOpenMinutes(90_000, 0)).toBe(2)
    expect(keptOpenMinutes(10_000, 0)).toBe(1)
  })
})

describe('the agent form', () => {
  it('makes an id from the name, unique among the agents there are', () => {
    expect(slugFor('Code Reviewer')).toBe('code-reviewer')
    expect(slugFor('Builder', ['builder'])).toBe('builder-2')
    expect(slugFor('!!!')).toBe('agent')
  })

  it('sends numbers as numbers, blanks as nulls, and keeps an existing id', () => {
    const draft = { ...draftOf(BUILDER), name: ' Builder ', account: '  ', maxConcurrent: '3' }
    const checked = agentPayload(draft, [BUILDER])
    expect(checked).toEqual({ ok: true, payload: { ...BUILDER, account: null, maxConcurrent: 3 } })
  })

  it('says what to fix rather than sending a number out of range', () => {
    const checked = agentPayload({ ...draftOf(null), name: 'Tester', maxConcurrent: '9' }, [])
    expect(checked).toEqual({ ok: false, message: 'Tasks at once has to be a whole number from 1 to 5.' })
  })

  it('saves through the preload call and hands back a refusal as its sentence', async () => {
    const sent: unknown[] = []
    const bridge = {
      tasksAgentSave: (agent: unknown) => {
        sent.push(agent)
        return Promise.resolve({ ok: false, message: 'Another agent is already called Builder.', state: EMPTY })
      },
    }
    const result = await saveAgent(bridge, { ...draftOf(null), name: 'Builder', provider: 'gemini' }, [BUILDER])
    expect(sent).toEqual([
      {
        id: 'builder-2',
        name: 'Builder',
        role: 'general',
        provider: 'gemini',
        account: null,
        model: null,
        effort: null,
        instructions: null,
        toolsPreferred: [],
        toolsAvoided: [],
        skills: [],
        maxConcurrent: 1,
        maxRunMinutes: 60,
        keepAliveMinutes: 30,
        verifyCommand: null,
      },
    ])
    expect(result).toMatchObject({ ok: false, message: 'Another agent is already called Builder.' })
  })

  it('never reaches the bridge with a draft it cannot send', async () => {
    let called = false
    const bridge = {
      tasksAgentSave: () => {
        called = true
        return Promise.resolve({ ok: true, state: EMPTY })
      },
    }
    const result = await saveAgent(bridge, draftOf(null), [])
    expect(called).toBe(false)
    expect(result).toMatchObject({ ok: false, message: 'Give the agent a name.' })
  })
})

describe('the connection form', () => {
  const connection = toTasksState({ ...EMPTY, connections: [{ keyId: 'k1', maxHops: 3 }] })!.connections[0]

  it('starts from the default CRM statuses and sends them back as they are', () => {
    const checked = connectionPatch(connectionDraftOf(connection))
    expect(checked.ok && checked.patch.statuses).toEqual(DEFAULT_CRM_STATUSES)
  })

  it('sends lists one entry per line, without blanks or repeats', () => {
    const draft = { ...connectionDraftOf(connection), allowedSenders: 'u-1\n\n u-1 \nu-2', folders: '/Users/a/site\n' }
    const checked = connectionPatch(draft)
    expect(checked.ok && checked.patch.allowedSenders).toEqual(['u-1', 'u-2'])
    expect(checked.ok && checked.patch.folders).toEqual(['/Users/a/site'])
  })

  it('turns a status that was removed from the list into a comment only', () => {
    const draft = { ...connectionDraftOf(connection), statuses: 'To-Do\nDone' }
    const checked = connectionPatch(draft)
    expect(checked.ok && checked.patch.statuses).toEqual({
      statuses: ['To-Do', 'Done'],
      initial: 'To-Do',
      completed: 'Done',
      onStarted: null,
      onVerified: 'Done',
      onBlocked: null,
    })
  })

  it('asks for the agent an identity stands for', () => {
    const draft = { ...connectionDraftOf(connection), identities: [{ identity: 'crm-7', agentId: '' }] }
    expect(connectionPatch(draft)).toEqual({ ok: false, message: 'Choose which agent crm-7 is.' })
  })

  it('holds the hand-off limit to 1–5', () => {
    expect(connectionPatch({ ...connectionDraftOf(connection), maxHops: '6' })).toEqual({
      ok: false,
      message: 'The hand-off limit has to be a whole number from 1 to 5.',
    })
  })
})

describe('the bridge', () => {
  it('takes only the methods it names off the preload, each called through its host', async () => {
    const host = {
      calls: 0,
      tasksState(this: { calls: number }) {
        this.calls += 1
        return Promise.resolve(EMPTY)
      },
      somethingElse: () => 'not mine',
    }
    const bridge = resolveTasksBridge(host)
    expect(Object.keys(bridge)).toEqual(['tasksState'])
    await bridge.tasksState?.()
    expect(host.calls).toBe(1)
  })

  it('sends an agent’s instructions, tools, skills and effort as the main process takes them', () => {
    const draft = {
      ...draftOf(null),
      name: 'Reviewer',
      effort: 'xhigh',
      instructions: '  Read the diff first.  ',
      toolsPreferred: 'Read\n\nGrep\nRead',
      toolsAvoided: ' Bash ',
      skills: 'code-review',
    }
    expect(agentPayload(draft, [])).toMatchObject({
      ok: true,
      payload: { effort: 'xhigh', instructions: 'Read the diff first.', toolsPreferred: ['Read', 'Grep'], toolsAvoided: ['Bash'], skills: ['code-review'] },
    })
    // An effort this build does not know is left to the agent rather than sent.
    expect(agentPayload({ ...draft, effort: 'turbo' }, [])).toMatchObject({ ok: true, payload: { effort: null } })
    // Read back into the form exactly as it was saved.
    const saved = agentPayload(draft, [])
    if (!saved.ok) throw new Error(saved.message)
    expect(draftOf(saved.payload)).toMatchObject({ effort: 'xhigh', toolsPreferred: 'Read\nGrep', skills: 'code-review' })
  })
})
