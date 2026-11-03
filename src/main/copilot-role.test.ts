import { describe, expect, it } from 'vitest'
import { assembledCatalogue } from './deck-control/assembled-catalogue.fixture'
import { hootRoleSection } from './copilot-role'

/**
 * Hoot's role is guidance, not a limit, and every tool it names is real.
 */

const section = hootRoleSection()
/** `tasks_plan`, `hoot_memory`… — the backticked tool names the section mentions. */
const named = [...section.matchAll(/`([a-z]+(?:_[a-z]+)+)`/g)].map((match) => match[1])

describe('how Hoot gets work done', () => {
  it('names only tools Hoot really has', () => {
    const tools = new Map(assembledCatalogue().map((tool) => [tool.id.replace(/\./g, '_'), tool]))
    expect(named.length).toBeGreaterThan(8)
    for (const wire of named) {
      const tool = tools.get(wire)
      expect(tool, `${wire} is named in Hoot's instructions but is not a tool`).toBeDefined()
      // Offered to Hoot: either everyone's, or the copilot's own.
      expect(tool?.audience === undefined || tool?.audience === 'copilot', `${wire} is not offered to Hoot`).toBe(true)
    }
  })

  it('leaves Hoot able to do the work itself, and says when to', () => {
    expect(section).toContain('nothing stops you')
    expect(section).toContain('Do it yourself')
    expect(section).toContain('Hand it to an agent')
    // The earlier hard rule, gone in every form it took.
    expect(section).not.toMatch(/you do not change files|you were started without|refused to you/i)
  })

  it('keeps verified results apart from claims', () => {
    expect(section).toContain('A result becomes verified only through a review that names its evidence')
    expect(section).toContain('stale or conflicting')
  })
})
