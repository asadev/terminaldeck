import { describe, expect, it, vi } from 'vitest'
import { fakeContext, tool } from './agents-area.fixture'
import { usageTools, type UsageToolDeps } from './usage-tools'

function deps(overrides: Partial<UsageToolDeps> = {}): UsageToolDeps {
  return {
    read: async (sessionId) => ({ sessionId, readings: [] }),
    context: async () => ({ percent: 40 }),
    refresh: async () => ({ refreshed: true }),
    projectCost: async (path) => ({ path, tokens: 100 }),
    transcripts: async () => [
      { path: '/store/api/a.jsonl', sessionId: 'a', modifiedAt: 2 },
      { path: '/store/api/b.jsonl', sessionId: 'b', modifiedAt: 1 },
    ],
    sessionCost: async (path) => ({ path, tokens: 7 }),
    ...overrides,
  }
}

describe('usage', () => {
  it('reads a session’s limits and its context window together', async () => {
    const { context } = fakeContext()
    const out = await tool(usageTools(deps()), 'usage.read').run({ sessionId: 'theirs-1' }, context)
    expect(out.value).toEqual({ sessionId: 'theirs-1', limits: { sessionId: 'theirs-1', readings: [] }, contextWindow: { percent: 40 } })
  })

  it('reads every login’s limits when no session is named', async () => {
    const read = vi.fn<UsageToolDeps['read']>(deps().read)
    const { context } = fakeContext()
    await tool(usageTools(deps({ read })), 'usage.read').run({}, context)
    expect(read).toHaveBeenCalledWith(null)
  })

  it('reads one session’s cost only from the folder it was asked about', async () => {
    const sessionCost = vi.fn<UsageToolDeps['sessionCost']>(deps().sessionCost)
    const { context } = fakeContext()
    const spec = tool(usageTools(deps({ sessionCost })), 'usage.cost')
    await spec.run({ projectPath: '/work/api', transcriptPath: '/store/api/a.jsonl' }, context)
    expect(sessionCost).toHaveBeenCalledWith('/store/api/a.jsonl')
    await expect(spec.run({ projectPath: '/work/api', transcriptPath: '/store/other/z.jsonl' }, context)).rejects.toThrow(
      /not one of \/work\/api’s transcripts/,
    )
  })

  it('caps the list of transcripts and says how many there were', async () => {
    const { context } = fakeContext()
    const out = await tool(usageTools(deps()), 'usage.cost').run({ projectPath: '/work/api', limit: 1 }, context)
    expect(out.value).toMatchObject({ transcripts: [{ sessionId: 'a' }], totalTranscripts: 2, project: { tokens: 100 } })
  })
})
