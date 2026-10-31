import { describe, expect, it } from 'vitest'
import type { CreateSessionInput } from '../../shared/types'
import { buildCatalogue } from './catalogue'
import { contextFor, fakeSurface, toolNamed } from './sessions-lane.fixture'

/**
 * `sessions.start` with an account — "run it as my work login".
 *
 * The start path does not refuse an id it does not know; `resolveProfileId`
 * quietly falls back to the default. So the tool checks first, and these pin
 * that a wrong name is refused with the real names rather than started as
 * somebody else.
 */

function withAccounts(): { started: CreateSessionInput[]; surface: ReturnType<typeof fakeSurface>['surface'] } {
  const { surface } = fakeSurface()
  const started: CreateSessionInput[] = []
  surface.accounts = () => [
    { id: 'system:claude', name: 'Personal', provider: 'claude' },
    { id: 'p-work', name: 'Work', provider: 'claude' },
    { id: 'p-codex', name: 'Side', provider: 'codex' },
  ]
  const start = surface.startSession
  surface.startSession = async (input) => {
    started.push(input)
    return start(input)
  }
  return { started, surface }
}

describe('starting a session as a chosen account', () => {
  it('starts as the account named, by name, and an account decides the agent', async () => {
    const { started, surface } = withAccounts()
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    await tool.run({ cwd: '/work/web', account: 'side' }, contextFor(surface))
    expect(started[0]).toMatchObject({ profileId: 'p-codex', provider: 'codex' })
  })

  it('refuses a name that is not an account, before anything starts, naming the real ones', () => {
    const { started, surface } = withAccounts()
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    expect(() => tool.precheck?.({ cwd: '/work/web', account: 'Holiday' }, contextFor(surface))).toThrow(
      /Personal \(claude\), Work \(claude\), Side \(codex\)/,
    )
    expect(started).toEqual([])
  })

  it('refuses an account of a different agent than the one asked for', () => {
    const { surface } = withAccounts()
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    expect(() => tool.precheck?.({ cwd: '/work/web', account: 'Work', provider: 'codex' }, contextFor(surface))).toThrow(
      /claude login/,
    )
  })

  it('says so on a host that cannot choose, rather than ignoring the argument', () => {
    const { surface } = fakeSurface()
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    expect(() => tool.precheck?.({ cwd: '/work/web', account: 'Work' }, contextFor(surface))).toThrow(/cannot choose an account/)
  })

  it('names the account in the sentence a person reads', () => {
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    expect(tool.summary({ cwd: '/work/web', provider: 'claude', account: 'Work' }, contextFor(fakeSurface().surface))).toBe(
      'Start a claude session as Work in /work/web',
    )
  })
})

describe('limits a start can carry', () => {
  it('passes blocked tools and skills off from the call options, and nothing when none are given', async () => {
    const { started, surface } = withAccounts()
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    await tool.run({ cwd: '/work/web', provider: 'claude' }, { ...contextFor(surface), sessionLimits: { deniedTools: ['WebFetch', 'WebFetch'], noSkills: true } })
    await tool.run({ cwd: '/work/api', provider: 'claude' }, contextFor(surface))
    expect(started[0]).toMatchObject({ deniedTools: ['WebFetch'], noSkills: true })
    expect(started[1]).not.toHaveProperty('deniedTools')
    expect(started[1]).not.toHaveProperty('noSkills')
  })

  it('never reads them from the arguments, and refuses anything that is not a tool name', async () => {
    const { started, surface } = withAccounts()
    const tool = toolNamed(buildCatalogue(), 'sessions.start')
    expect(Object.keys((tool.inputSchema as { properties: object }).properties)).not.toContain('blockTools')
    await expect(tool.run({ cwd: '/work/web' }, { ...contextFor(surface), sessionLimits: { deniedTools: ['--allowedTools'] } })).rejects.toThrow(/not a tool name/)
    expect(started).toEqual([])
  })
})
