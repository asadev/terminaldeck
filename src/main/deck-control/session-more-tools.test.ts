import { describe, expect, it } from 'vitest'
import { contextFor, fakeClock, fakeSurface, session, toolNamed } from './sessions-lane.fixture'
import {
  SETTLE_MS,
  sessionMoreTools,
  trimInsights,
  type HeldView,
  type SessionMoreDeps,
  type SessionSearchInput,
} from './session-more-tools'
import type { ToolSpec } from './catalogue'

function held(key: string): HeldView {
  return { key, cwd: '/work/api', provider: 'claude', profileId: null, reason: 'it could not be started', at: 1, lastSeenAt: 1 }
}

function depsWith(overrides: Partial<SessionMoreDeps> = {}): {
  deps: SessionMoreDeps
  calls: string[]
  searches: SessionSearchInput[]
  heldList: HeldView[]
} {
  const calls: string[] = []
  const searches: SessionSearchInput[] = []
  const heldList = [held('k1'), held('k2')]
  const deps: SessionMoreDeps = {
    rename: (id, title) => {
      calls.push(`rename ${id} ${title}`)
      return title === '' ? 'api' : title
    },
    held: {
      list: () => heldList,
      retry: async (key) => {
        calls.push(`retry ${key}`)
        return heldList.filter((entry) => entry.key !== key)
      },
      forget: (key) => {
        calls.push(`forget ${key}`)
        return heldList.filter((entry) => entry.key !== key)
      },
    },
    account: {
      show: async (id) => ({ kind: 'known', profileName: `account of ${id}` }),
      limits: () => ({ limits: [] }),
      plan: async (sessionId, profileId) => ({
        sessionId,
        refusal: null,
        from: null,
        to: { id: profileId, name: 'Work', provider: 'claude' },
        conversation: 'follows',
        resume: true,
      }),
      switchNow: async (sessionId, profileId) => {
        calls.push(`switch ${sessionId} ${profileId}`)
        return session({ id: `${sessionId}-as-${profileId}` })
      },
      later: async (sessionId, profileId) => ({ sessionId, profileId, note: 'later' }),
      cancel: () => true,
      armed: () => [],
      accounts: () => [
        { id: 'system:claude', name: 'Personal', provider: 'claude' },
        { id: 'p-work', name: 'Work', provider: 'claude' },
        { id: 'p-codex', name: 'Codex work', provider: 'codex' },
      ],
    },
    search: async (request) => {
      searches.push(request)
      return { ok: true, hits: [{ snippet: 'x' }] }
    },
    insights: async () => ({ requests: 3, timeline: [1, 2, 3], contextSeries: [1], heaviest: [1, 2, 3, 4, 5, 6, 7], compactions: [1, 2] }),
    ...overrides,
  }
  return { deps, calls, searches, heldList }
}

function tools(deps: SessionMoreDeps): ToolSpec[] {
  return sessionMoreTools(deps)
}

/* ------------------------------------------------------------------ wait -- */

describe('sessions.wait', () => {
  it('waits for a working session to come back to its prompt, then hands over its answer', async () => {
    const { state, surface } = fakeSurface()
    const clock = fakeClock()
    state.statuses.set('s1', { status: 'working', at: clock.now() })
    state.transcripts.set('/work/api', [
      { path: '/t/a.jsonl', sessionId: 'c1', createdAt: 1_000, modifiedAt: 2_000, bytes: 1_000 },
    ])
    let looks = 0
    const { deps } = depsWith({
      sleep: async (ms) => {
        await clock.sleep(ms)
        looks += 1
        // Two looks working, then the turn ends and an answer appears.
        if (looks === 2) {
          state.statuses.set('s1', { status: 'waiting', at: clock.now() })
          state.messages.set('/t/a.jsonl', [
            { id: 'you:1', role: 'you', at: 9_000, text: 'fix it', truncated: false },
            { id: 'agent:1', role: 'agent', at: clock.now(), text: 'Fixed: the test was wrong.', truncated: false },
          ])
        }
      },
    })
    const context = contextFor(surface, { now: clock.now })
    const output = await toolNamed(tools(deps), 'sessions.wait').run({ sessionId: 's1', after: 9_500 }, context)
    const value = output.value as { outcome: string; answer: { text: string; afterSend: boolean }; screen: unknown }
    expect(value.outcome).toBe('finished')
    expect(value.answer).toMatchObject({ text: 'Fixed: the test was wrong.', afterSend: true })
    // A finished agent's screen is its reply drawn twice; it is not sent.
    expect(value.screen).toBeNull()
  })

  it('does not call a brief idle flicker between tool calls the end of the turn', async () => {
    const { state, surface } = fakeSurface()
    const clock = fakeClock()
    state.statuses.set('s1', { status: 'working', at: clock.now() })
    let looks = 0
    const { deps } = depsWith({
      sleep: async (ms) => {
        await clock.sleep(ms)
        looks += 1
        // Quiet for one look only — shorter than SETTLE_MS — then working again.
        if (looks === 1) state.statuses.set('s1', { status: 'idle', at: clock.now() })
        if (looks === 2) state.statuses.set('s1', { status: 'working', at: clock.now() })
      },
    })
    const output = await toolNamed(tools(deps), 'sessions.wait').run(
      { sessionId: 's1', timeoutSeconds: 3 },
      contextFor(surface, { now: clock.now }),
    )
    expect((output.value as { outcome: string }).outcome).toBe('timed-out')
  })

  it('returns at once, with the screen, when the session is stopped on a question', async () => {
    const { state, surface } = fakeSurface()
    state.statuses.set('s1', { status: 'input', at: 1 })
    state.screens.set('s1', 'Do you want to run npm test?\n❯ 1. Yes\n  2. No\n\n\n')
    const clock = fakeClock()
    const { deps } = depsWith({ sleep: clock.sleep })
    const output = await toolNamed(tools(deps), 'sessions.wait').run({ sessionId: 's1' }, contextFor(surface, { now: clock.now }))
    const value = output.value as { outcome: string; attention: string; screen: string; waitedMs: number }
    expect(value.outcome).toBe('blocked')
    expect(value.attention).toBe('blocked')
    // Trailing blank rows trimmed: the question is what matters.
    expect(value.screen).toBe('Do you want to run npm test?\n❯ 1. Yes\n  2. No')
    expect(value.waitedMs).toBe(0)
  })

  it('gives up at the timeout and says so, rather than reporting a quiet session as finished', async () => {
    /*
     * A session sitting at an empty prompt that was never asked anything has
     * not answered. `waiting` is an empty prompt, not "done" — attention.ts.
     */
    const { state, surface } = fakeSurface()
    state.statuses.set('s1', { status: 'waiting', at: 1 })
    const clock = fakeClock()
    const { deps } = depsWith({ sleep: clock.sleep })
    const output = await toolNamed(tools(deps), 'sessions.wait').run(
      { sessionId: 's1', timeoutSeconds: 2 },
      contextFor(surface, { now: clock.now }),
    )
    const value = output.value as { outcome: string; waitedMs: number }
    expect(value.outcome).toBe('timed-out')
    expect(value.waitedMs).toBeGreaterThanOrEqual(2_000)
  })

  it('counts an answer that landed before the wait began, when told when the message was sent', async () => {
    const { state, surface } = fakeSurface()
    state.statuses.set('s1', { status: 'waiting', at: 9_000 })
    state.transcripts.set('/work/api', [{ path: '/t/a.jsonl', sessionId: 'c1', createdAt: 1_000, modifiedAt: 9_000, bytes: 1 }])
    state.messages.set('/t/a.jsonl', [{ id: 'agent:1', role: 'agent', at: 9_200, text: 'done', truncated: false }])
    const clock = fakeClock(10_000)
    const { deps } = depsWith({ sleep: clock.sleep })
    const output = await toolNamed(tools(deps), 'sessions.wait').run(
      { sessionId: 's1', after: 9_100 },
      contextFor(surface, { now: clock.now }),
    )
    expect((output.value as { outcome: string }).outcome).toBe('finished')
  })

  it('takes a completed status written after the send as a finished turn', async () => {
    const { state, surface } = fakeSurface()
    state.statuses.set('s1', { status: 'completed', at: 10_500 })
    const clock = fakeClock(11_000)
    const { deps } = depsWith({ sleep: clock.sleep })
    const output = await toolNamed(tools(deps), 'sessions.wait').run(
      { sessionId: 's1', after: 10_000 },
      contextFor(surface, { now: clock.now }),
    )
    expect((output.value as { outcome: string }).outcome).toBe('finished')
  })

  it('says the session exited, or was stopped, instead of waiting on nothing', async () => {
    const { state, surface } = fakeSurface()
    state.sessions = [session({ id: 's1', exitCode: 0 })]
    const clock = fakeClock()
    const { deps } = depsWith({ sleep: clock.sleep })
    const wait = toolNamed(tools(deps), 'sessions.wait')
    expect(((await wait.run({ sessionId: 's1' }, contextFor(surface, { now: clock.now }))).value as { outcome: string }).outcome).toBe('exited')

    state.sessions = [session({ id: 's1' })]
    state.statuses.set('s1', { status: 'working', at: 1 })
    const vanish = depsWith({
      sleep: async (ms) => {
        await clock.sleep(ms)
        state.sessions = []
      },
    })
    const gone = await toolNamed(tools(vanish.deps), 'sessions.wait').run({ sessionId: 's1' }, contextFor(surface, { now: clock.now }))
    expect((gone.value as { outcome: string }).outcome).toBe('stopped')
  })

  it('caps the timeout under the server’s own request deadline', async () => {
    const { state, surface } = fakeSurface()
    state.statuses.set('s1', { status: 'waiting', at: 1 })
    const clock = fakeClock()
    const { deps } = depsWith({ sleep: clock.sleep })
    const output = await toolNamed(tools(deps), 'sessions.wait').run(
      { sessionId: 's1', timeoutSeconds: 100_000 },
      contextFor(surface, { now: clock.now }),
    )
    expect((output.value as { waitedMs: number }).waitedMs).toBeLessThanOrEqual(240_000 + 250)
  })

  it('settles for SETTLE_MS, so the constant the description promises is the one that runs', () => {
    expect(SETTLE_MS).toBeGreaterThanOrEqual(500)
  })
})

/* ------------------------------------------------------------------ keys -- */

describe('sessions.keys', () => {
  it('presses each named key as its own write', async () => {
    const { state, surface } = fakeSurface()
    const clock = fakeClock()
    const { deps } = depsWith({ sleep: clock.sleep })
    const output = await toolNamed(tools(deps), 'sessions.keys').run(
      { sessionId: 's1', keys: ['down', '2', 'Enter'] },
      contextFor(surface, { now: clock.now }),
    )
    expect(state.typed.map((entry) => entry.data)).toEqual(['\x1b[B', '2', '\r'])
    expect((output.value as { pressed: string[] }).pressed).toEqual(['Down', '“2”', 'Enter'])
  })

  it('is ordinary in a session the copilot started and confirmed in the person’s own', () => {
    const { surface } = fakeSurface()
    const keys = toolNamed(tools(depsWith().deps), 'sessions.keys')
    expect(keys.escalate?.({ sessionId: 's1', keys: ['ctrl-c'] }, contextFor(surface, { own: ['s1'] }))).toBe('act')
    expect(keys.escalate?.({ sessionId: 's1', keys: ['ctrl-c'] }, contextFor(surface))).toBe('alter')
  })

  it('refuses a key it does not know before anybody is asked about it', () => {
    const { surface } = fakeSurface()
    const keys = toolNamed(tools(depsWith().deps), 'sessions.keys')
    expect(() => keys.precheck?.({ sessionId: 's1', keys: ['\x1b[2J'] }, contextFor(surface))).toThrow(/no key called/)
  })

  it('will not press keys in a session that has exited', async () => {
    const { state, surface } = fakeSurface()
    state.sessions = [session({ id: 's1', exitCode: 1 })]
    await expect(
      toolNamed(tools(depsWith().deps), 'sessions.keys').run({ sessionId: 's1', keys: ['enter'] }, contextFor(surface)),
    ).rejects.toThrow(/already exited/)
    expect(state.typed).toEqual([])
  })
})

/* ---------------------------------------------------------------- screen -- */

describe('sessions.screen', () => {
  it('returns what the terminal shows, without the empty rows under it', async () => {
    const { state, surface } = fakeSurface()
    state.screens.set('s1', '$ npm test\n  12 passing\n$ \n\n\n\n')
    const output = await toolNamed(tools(depsWith().deps), 'sessions.screen').run({ sessionId: 's1' }, contextFor(surface))
    expect((output.value as { screen: string }).screen).toBe('$ npm test\n  12 passing\n$')
  })
})

/* ---------------------------------------------------------------- rename -- */

describe('sessions.rename', () => {
  it('renames through the app’s own rename, and an empty title goes back to the folder name', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const rename = toolNamed(tools(deps), 'sessions.rename')
    expect((await rename.run({ sessionId: 's1', title: '  Fix login  ' }, contextFor(surface))).value).toEqual({
      sessionId: 's1',
      title: 'Fix login',
    })
    expect((await rename.run({ sessionId: 's1', title: '' }, contextFor(surface))).value).toMatchObject({ title: 'api' })
    expect(calls).toEqual(['rename s1 Fix login', 'rename s1 '])
  })

  it('refuses a title that is not one line', () => {
    const { surface } = fakeSurface()
    const rename = toolNamed(tools(depsWith().deps), 'sessions.rename')
    expect(() => rename.precheck?.({ sessionId: 's1', title: 'two\nlines' }, contextFor(surface))).toThrow(/one line/)
    expect(() => rename.precheck?.({ sessionId: 's1', title: 'x'.repeat(121) }, contextFor(surface))).toThrow(/120/)
  })
})

/* ------------------------------------------------------------------ held -- */

describe('sessions.held', () => {
  it('reads freely, retries as ordinary work, and forgets only with a confirmation', () => {
    const { surface } = fakeSurface()
    const tool = toolNamed(tools(depsWith().deps), 'sessions.held')
    expect(tool.escalate?.({ action: 'list' }, contextFor(surface))).toBe('read')
    expect(tool.escalate?.({ action: 'retry', key: 'k1' }, contextFor(surface))).toBe('act')
    expect(tool.escalate?.({ action: 'forget', key: 'k1' }, contextFor(surface))).toBe('alter')
  })

  it('answers a retry with the session that started', async () => {
    const { state, surface } = fakeSurface()
    const { deps, calls } = depsWith({
      held: {
        list: () => [held('k1')],
        retry: async () => {
          state.sessions = [...state.sessions, session({ id: 'back-1' })]
          return []
        },
        forget: () => [],
      },
    })
    const output = await toolNamed(tools(deps), 'sessions.held').run({ action: 'retry', key: 'k1' }, contextFor(surface))
    const value = output.value as { cameBack: boolean; started: Array<{ id: string }> }
    expect(value.cameBack).toBe(true)
    expect(value.started.map((one) => one.id)).toEqual(['back-1'])
    expect(calls).toEqual([])
  })

  it('says why, in the row’s own words, when a retry did not bring it back', async () => {
    const { surface } = fakeSurface()
    const still = { ...held('k1'), reason: 'it could not be started again: claude is not installed' }
    const { deps } = depsWith({ held: { list: () => [held('k1')], retry: async () => [still], forget: () => [] } })
    const output = await toolNamed(tools(deps), 'sessions.held').run({ action: 'retry', key: 'k1' }, contextFor(surface))
    expect(output.value).toMatchObject({ cameBack: false, reason: still.reason })
  })

  it('refuses a key nothing is held under', async () => {
    const { surface } = fakeSurface()
    await expect(
      toolNamed(tools(depsWith().deps), 'sessions.held').run({ action: 'forget', key: 'nope' }, contextFor(surface)),
    ).rejects.toThrow(/nothing is being held/)
  })
})

/* --------------------------------------------------------------- account -- */

describe('sessions.account', () => {
  it('switches by account name, and the replacement stays the copilot’s own', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const context = contextFor(surface, { own: ['s1'] })
    const output = await toolNamed(tools(deps), 'sessions.account').run(
      { action: 'switch', sessionId: 's1', account: 'work' },
      context,
    )
    expect(calls).toEqual(['switch s1 p-work'])
    const replacement = (output.value as { session: { id: string } }).session.id
    expect(context.startedByCopilot(replacement)).toBe(true)
  })

  it('does not hand the person’s session to the copilot by switching it', async () => {
    const { surface } = fakeSurface()
    const context = contextFor(surface)
    const output = await toolNamed(tools(depsWith().deps), 'sessions.account').run(
      { action: 'switch', sessionId: 's1', account: 'Work' },
      context,
    )
    expect(context.startedByCopilot((output.value as { session: { id: string } }).session.id)).toBe(false)
  })

  it('refuses an account that does not exist, naming the ones that do', async () => {
    const { surface } = fakeSurface()
    await expect(
      toolNamed(tools(depsWith().deps), 'sessions.account').run(
        { action: 'plan', sessionId: 's1', account: 'Holiday' },
        contextFor(surface),
      ),
    ).rejects.toThrow(/Personal \(claude\), Work \(claude\)/)
  })

  it('refuses an account of a different agent than the session runs', async () => {
    const { surface } = fakeSurface()
    await expect(
      toolNamed(tools(depsWith().deps), 'sessions.account').run(
        { action: 'switch', sessionId: 's1', account: 'Codex work' },
        contextFor(surface),
      ),
    ).rejects.toThrow(/codex login/)
  })

  it('confirms a switch and arming one; reads and cancelling are not', () => {
    const { surface } = fakeSurface()
    const tool = toolNamed(tools(depsWith().deps), 'sessions.account')
    const tier = (action: string): unknown => tool.escalate?.({ action, sessionId: 's1' }, contextFor(surface))
    expect([tier('show'), tier('plan'), tier('armed'), tier('cancel'), tier('later'), tier('switch')]).toEqual([
      'read',
      'read',
      'read',
      'act',
      'alter',
      'alter',
    ])
  })

  it('shows the account and its plan limits together', async () => {
    const { surface } = fakeSurface()
    const output = await toolNamed(tools(depsWith().deps), 'sessions.account').run(
      { action: 'show', sessionId: 's2' },
      contextFor(surface),
    )
    expect(output.value).toEqual({ sessionId: 's2', account: { kind: 'known', profileName: 'account of s2' }, limits: { limits: [] } })
  })
})

/* ---------------------------------------------------------------- search -- */

describe('sessions.search', () => {
  it('searches only a folder this app has open, with the hit count capped', async () => {
    const { surface } = fakeSurface()
    const { deps, searches } = depsWith()
    const search = toolNamed(tools(deps), 'sessions.search')
    expect(() => search.precheck?.({ cwd: '/etc', query: 'x' }, contextFor(surface))).toThrow(/not a folder this app has open/)
    await search.run({ cwd: '/work/api', query: 'login', maxHits: 5_000, roles: ['assistant', 'nonsense'] }, contextFor(surface))
    expect(searches[0]).toMatchObject({ cwd: '/work/api', query: 'login', maxHits: 100, roles: ['assistant'], scope: 'project' })
  })
})

/* ----------------------------------------------------------------- chats -- */

describe('past conversations', () => {
  function withChats(): ReturnType<typeof fakeSurface> {
    const built = fakeSurface()
    built.state.transcripts.set('/work/api', [
      { path: '/t/old.jsonl', sessionId: 'old', createdAt: 1, modifiedAt: 10, bytes: 5 },
      { path: '/t/new.jsonl', sessionId: 'new', createdAt: 2, modifiedAt: 20, bytes: 5 },
    ])
    built.state.messages.set('/t/new.jsonl', [{ id: 'a', role: 'agent', at: 3, text: 'hello', truncated: false }])
    built.state.messages.set('/t/old.jsonl', [{ id: 'b', role: 'agent', at: 1, text: 'older', truncated: false }])
    return built
  }

  it('lists them newest first', async () => {
    const { surface } = withChats()
    const output = await toolNamed(tools(depsWith().deps), 'chats.list').run({ cwd: '/work/api' }, contextFor(surface))
    expect((output.value as { chats: Array<{ conversationId: string }> }).chats.map((chat) => chat.conversationId)).toEqual([
      'new',
      'old',
    ])
  })

  it('reads the newest by default, and only a transcript that belongs to the folder', async () => {
    const { surface } = withChats()
    const read = toolNamed(tools(depsWith().deps), 'chats.read')
    const newest = await read.run({ cwd: '/work/api' }, contextFor(surface))
    expect((newest.value as { messages: Array<{ text: string }> }).messages[0].text).toBe('hello')
    const named = await read.run({ cwd: '/work/api', transcriptPath: '/t/old.jsonl' }, contextFor(surface))
    expect((named.value as { messages: Array<{ text: string }> }).messages[0].text).toBe('older')
    // A path to a file outside the folder's own list is refused, however it is spelled.
    await expect(read.run({ cwd: '/work/api', transcriptPath: '/Users/x/.ssh/id_rsa' }, contextFor(surface))).rejects.toThrow(
      /not one of the conversations/,
    )
  })

  it('hands back the inspector’s numbers without the charts', () => {
    expect(trimInsights({ requests: 3, timeline: [1], contextSeries: [1], heaviest: [1, 2, 3, 4, 5, 6], compactions: [1, 2] })).toEqual({
      requests: 3,
      heaviest: [1, 2, 3, 4, 5],
      compactions: 2,
    })
  })
})
