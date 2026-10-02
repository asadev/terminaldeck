import { describe, expect, it } from 'vitest'
import { COVERAGE_AREAS } from './actions'
import { UI_COMMANDS, UI_GESTURES } from './actions/ui'
import { coverageRows, coverageTool, matchingRows, MAX_COVERAGE_ROWS } from './coverage-tool'
import { contextFor, fakeSurface } from './sessions-lane.fixture'

/**
 * `tools.coverage` answers from the very table the coverage tests check — so the
 * thing proven in CI and the thing a model is told cannot be two lists.
 */

const context = (): ReturnType<typeof contextFor> => contextFor(fakeSurface().surface)

describe('tools.coverage', () => {
  it('carries every row of every table, the window’s included', () => {
    const expected =
      Object.values(COVERAGE_AREAS).reduce((sum, table) => sum + Object.keys(table).length, 0) +
      Object.keys(UI_COMMANDS).length +
      Object.keys(UI_GESTURES).length
    expect(coverageRows()).toHaveLength(expected)
  })

  it('answers the counts when asked nothing, without dumping the table', async () => {
    const output = await coverageTool().run({}, context())
    const value = output.value as { counts: Record<string, { actions: number; withTool: number }>; rows?: unknown }
    // `devices` is the Simulators page's channels, added with Annotate in 0.16.0.
    expect(Object.keys(value.counts)).toEqual(['sessions', 'machines', 'agents', 'browser', 'devices', 'window'])
    expect(value.counts.sessions.actions).toBe(Object.keys(COVERAGE_AREAS.sessions).length)
    expect(value.rows).toBeUndefined()
  })

  it('finds a row by plain words, in the action, the tool or the reason', () => {
    const rows = coverageRows()
    expect(matchingRows(rows, 'held retry').some((row) => row.action === 'session:held-retry')).toBe(true)
    // A skip is found by its reason, which is the sentence the model passes on.
    const answering = matchingRows(rows, 'approve its own request')
    expect(answering.map((row) => row.action)).toContain('deck-control:consent-respond')
    expect(answering.every((row) => row.skip !== undefined)).toBe(true)
  })

  it('lists only the actions with no tool when asked, each with its reason', async () => {
    const output = await coverageTool().run({ skippedOnly: true, area: 'sessions' }, context())
    const value = output.value as { rows: Array<{ skip?: string; tools?: string[] }>; matched: number }
    expect(value.matched).toBeGreaterThan(0)
    expect(value.rows.every((row) => typeof row.skip === 'string' && row.tools === undefined)).toBe(true)
  })

  it('caps the rows, and says when there were more', async () => {
    const output = await coverageTool().run({ area: 'browser', query: 'browser' }, context())
    const value = output.value as { rows: unknown[]; matched: number; note?: string }
    expect(value.rows.length).toBeLessThanOrEqual(MAX_COVERAGE_ROWS)
    if (value.matched > MAX_COVERAGE_ROWS) expect(value.note).toMatch(/narrow/)
  })

  it('is a read, held behind tools.describe', () => {
    const tool = coverageTool()
    expect(tool.tier).toBe('read')
    expect(tool.index).toBeTruthy()
  })
})
