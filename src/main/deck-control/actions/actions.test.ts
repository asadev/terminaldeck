import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { COVERAGE_AREAS } from './index'

/**
 * Read the channels out of the preload's source rather than importing it: the
 * preload needs Electron to load, and the thing being checked is exactly the
 * list of names it sends, which is text.
 */
function preloadChannels(): string[] {
  const source = readFileSync(join(__dirname, '../../../preload/index.ts'), 'utf8')
  const found = new Set<string>()
  for (const match of source.matchAll(/ipcRenderer\.(?:invoke|send)\('([^']+)'/g)) found.add(match[1])
  return [...found].sort()
}

describe('everything a person can do has a tool, or a reason', () => {
  const channels = preloadChannels()

  it('reads a believable number of channels', () => {
    expect(channels.length).toBeGreaterThan(300)
  })

  it('lists every channel in exactly one area', () => {
    const seen = new Map<string, string[]>()
    for (const [area, map] of Object.entries(COVERAGE_AREAS)) {
      for (const channel of Object.keys(map)) seen.set(channel, [...(seen.get(channel) ?? []), area])
    }
    const missing = channels.filter((c) => !seen.has(c))
    const twice = [...seen].filter(([, areas]) => areas.length > 1).map(([c, a]) => `${c} (${a.join(', ')})`)
    const stale = [...seen.keys()].filter((c) => !channels.includes(c))
    expect({ missing, twice, stale }).toEqual({ missing: [], twice: [], stale: [] })
  })

  it('has decided every one', () => {
    const undecided = Object.entries(COVERAGE_AREAS).flatMap(([area, map]) =>
      Object.entries(map)
        .filter(([, entry]) => entry === null)
        .map(([channel]) => `${area}: ${channel}`),
    )
    expect(undecided).toEqual([])
  })

  it('gives a real sentence for every skip and a dotted id for every tool', () => {
    const bad = Object.values(COVERAGE_AREAS).flatMap((map) =>
      Object.entries(map).flatMap(([channel, entry]) => {
        if (entry === null) return []
        if ('skip' in entry) return entry.skip.trim().length >= 20 ? [] : [`${channel}: skip too short`]
        const ids = typeof entry.tool === 'string' ? [entry.tool] : entry.tool
        return ids.every((id) => /^[a-z]+(\.[a-zA-Z_]+)+$/.test(id)) && ids.length > 0 ? [] : [`${channel}: bad tool id`]
      }),
    )
    expect(bad).toEqual([])
  })
})
