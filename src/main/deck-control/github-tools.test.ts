import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ToolContext, ToolSpec } from './catalogue'
import type { ChannelCall } from './channel-tap'
import { gitHubTools, SIGN_IN_WAIT_MS, withoutCode, type GitHubChannels } from './github-tools'
import { ALL_TIERS, type Caller, type DeckSurface } from './surface'

const LOCAL: Caller = { kind: 'local', tiers: ALL_TIERS }

let calls: unknown[][] = []
let answers: Partial<Record<keyof GitHubChannels, (...args: unknown[]) => unknown>> = {}
let tools: ToolSpec[] = []

const tool = (id: string): ToolSpec => tools.find((spec) => spec.id === id) as ToolSpec

const surface = {
  listProjects: () => [{ path: '/work/site', lastOpenedAt: 1 }],
  listSessions: () => [{ cwd: '/work/api' }],
} as unknown as DeckSurface

const context = (): ToolContext =>
  ({ surface, callId: 'row', caller: LOCAL, attended: true, startedByCopilot: () => false, noteStarted: () => undefined, now: () => 0 }) as ToolContext

beforeEach(() => {
  calls = []
  answers = {
    'github:repo': () => ({ owner: 'asadev', name: 'site' }),
    'github:overview': () => ({ pulls: [] }),
    'github:refresh': () => ({ pulls: [{ number: 7 }] }),
    'github:clear-cache': () => undefined,
    'github:auth-status': () => ({ connected: false, pending: { userCode: 'WXYZ-1234', verificationUri: 'https://github.com/login/device' } }),
    'github:auth-connect': () => ({ userCode: 'WXYZ-1234', verificationUri: 'https://github.com/login/device', expiresAt: 9 }),
  }
  const call = (async (channel: keyof GitHubChannels, ...args: unknown[]) => {
    calls.push([channel, ...args])
    const answer = answers[channel]
    if (answer === undefined) throw new Error(`the test did not expect ${channel}`)
    return answer(...args)
  }) as ChannelCall<GitHubChannels>
  tools = gitHubTools({ call })
})

afterEach(() => vi.useRealTimers())

describe('github.look', () => {
  it('answers for a folder this app has open, and only those', () => {
    expect(() => tool('github.look').precheck?.({ folder: '/work/site' }, context())).not.toThrow()
    expect(() => tool('github.look').precheck?.({ folder: '/work/api' }, context())).not.toThrow()
    expect(() => tool('github.look').precheck?.({ folder: '/Users/someone/secret-repo' }, context())).toThrow(/not a folder this app has open/)
  })

  it('clears the cache before a refresh, so the refresh is not answered by it', async () => {
    await tool('github.look').run({ folder: '/work/site', refresh: true }, context())
    const order = calls.map((row) => row[0])
    expect(order.indexOf('github:clear-cache')).toBeLessThan(order.indexOf('github:refresh'))
    expect(order).not.toContain('github:overview')
  })

  it('never hands a waiting sign-in code to a read', async () => {
    const out = await tool('github.look').run({ folder: '/work/site' }, context())
    expect(JSON.stringify(out)).not.toContain('WXYZ-1234')
  })
})

describe('github.connect', () => {
  it('returns the code to the call that started the sign-in, and not to the record', async () => {
    const out = await tool('github.connect').run({ do: 'connect' }, context())
    expect(JSON.stringify(out.value)).toContain('WXYZ-1234')
    expect(JSON.stringify(out.summary)).not.toContain('WXYZ-1234')
    expect(tool('github.connect').tier).toBe('alter')
  })

  it('lets go of a wait at its ceiling without cancelling the sign-in', async () => {
    vi.useFakeTimers()
    answers['github:auth-await'] = () => new Promise(() => undefined)
    const pending = tool('github.connect').run({ do: 'wait' }, context())
    await vi.advanceTimersByTimeAsync(SIGN_IN_WAIT_MS + 1)
    expect((await pending).value).toEqual(expect.objectContaining({ finished: false }))
    expect(calls.some((row) => row[0] === 'github:auth-cancel')).toBe(false)
  })
})

describe('the code scrub', () => {
  it('leaves a state with nothing waiting alone', () => {
    const state = { connected: true, pending: null }
    expect(withoutCode(state)).toBe(state)
  })
})
