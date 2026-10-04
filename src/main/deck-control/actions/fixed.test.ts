import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { fixedTools, type FixedToolDeps } from '../fixed-tools'
import { FIXED_CHANNELS, fixedCoverage } from './fixed'
import { COVERAGE_AREAS } from './index'

/**
 * The Stays Fixed table on its own terms, while the preload has not caught up.
 *
 * `actions.test.ts` checks every table against the preload, and reports these
 * channels as stale until `WIRING-staysfixed.md` is applied. This checks what
 * can be checked without it: every channel the handlers register is listed,
 * every entry names a tool that exists, and the table is part of the joined set.
 */
describe('the Stays Fixed actions', () => {
  const handlers = readFileSync(join(__dirname, '../../staysfixed/ipc.ts'), 'utf8')
  const registered = [...handlers.matchAll(/ipcMain\.handle\('([^']+)'/g)].map((match) => match[1])

  it('lists every channel the page’s handlers register, and nothing else', () => {
    expect([...FIXED_CHANNELS].sort()).toEqual([...registered].sort())
  })

  it('points every channel at a tool that exists', () => {
    const ids = new Set(fixedTools({} as FixedToolDeps).map((spec) => spec.id))
    const missing = Object.entries(fixedCoverage).flatMap(([channel, entry]) => {
      if (entry === null || 'skip' in entry) return [`${channel}: not a tool`]
      const tools = typeof entry.tool === 'string' ? [entry.tool] : entry.tool
      return tools.filter((id) => !ids.has(id)).map((id) => `${channel} → ${id}`)
    })
    expect(missing).toEqual([])
  })

  it('is one of the areas the coverage tool and actions.test.ts read', () => {
    expect(COVERAGE_AREAS.fixed).toBe(fixedCoverage)
  })
})
