import { describe, expect, it } from 'vitest'
import { byDay, completionFor, dayHeading, visitHost, visitLabel } from './history-view'
import type { HistoryVisit } from './accounts-bridge'

function visit(over: Partial<HistoryVisit> = {}): HistoryVisit {
  return {
    profileId: 'default',
    url: 'https://example.com/',
    title: 'Example',
    visitedAt: 0,
    visits: 1,
    ...over,
  }
}

/** A fixed local noon, so a test cannot be a different day in another timezone. */
function at(day: number, hour = 12, minute = 0): number {
  return new Date(2026, 7, day, hour, minute, 0, 0).getTime()
}

describe('what a row says', () => {
  it('is the page’s own title', () => {
    expect(visitLabel(visit({ title: 'Besar Restaurant Bluewaters' }))).toBe(
      'Besar Restaurant Bluewaters',
    )
  })

  it('is the address when the page never announced one — never a placeholder', () => {
    expect(visitLabel(visit({ title: '', url: 'http://localhost:3000/' }))).toBe(
      'http://localhost:3000/',
    )
    expect(visitLabel(visit({ title: '   ' }))).toBe('https://example.com/')
  })

  it('drops www from the host, which is four characters of nothing', () => {
    expect(visitHost('https://www.google.com/search?q=prawns')).toBe('google.com')
    expect(visitHost('http://localhost:3000/x')).toBe('localhost:3000')
  })

  it('prints an unparseable address rather than nothing', () => {
    expect(visitHost('not a url')).toBe('not a url')
  })
})

describe('where the days break', () => {
  it('names today and yesterday, and dates the rest', () => {
    const now = at(21, 9)
    expect(dayHeading(at(21, 8), now)).toBe('Today')
    expect(dayHeading(at(20, 23), now)).toBe('Yesterday')
    expect(dayHeading(at(19, 10), now)).not.toMatch(/Today|Yesterday/)
  })

  it('breaks at local midnight, not on a rolling day', () => {
    // 23:50 and 00:10 are eighty minutes apart and belong under two headings.
    const now = at(21, 9)
    expect(dayHeading(at(20, 23, 50), now)).toBe('Yesterday')
    expect(dayHeading(at(21, 0, 10), now)).toBe('Today')
  })

  it('groups a list into sections, newest first', () => {
    const now = at(21, 18)
    const days = byDay(
      [
        visit({ url: 'https://a.test/', visitedAt: at(19, 10) }),
        visit({ url: 'https://b.test/', visitedAt: at(21, 9) }),
        visit({ url: 'https://c.test/', visitedAt: at(21, 17) }),
      ],
      now,
    )
    expect(days.map((section) => section.heading)[0]).toBe('Today')
    expect(days[0].visits.map((item) => item.url)).toEqual(['https://c.test/', 'https://b.test/'])
    expect(days).toHaveLength(2)
  })

  it('is empty for an empty list rather than drawing a heading with nothing under it', () => {
    expect(byDay([], at(21))).toEqual([])
  })
})

describe('what the address bar fills in', () => {
  it('completes the way a person types — no scheme, no www', () => {
    expect(completionFor('git', 'https://github.com/asadev')).toBe('github.com/asadev')
    expect(completionFor('goo', 'https://www.google.com/')).toBe('google.com')
  })

  it('keeps the characters that were actually typed', () => {
    // The person's own capitals are not rewritten under their cursor.
    expect(completionFor('GitH', 'https://github.com/asadev')).toBe('GitHub.com/asadev')
  })

  it('completes the whole address for somebody who did type the scheme', () => {
    expect(completionFor('https://git', 'https://github.com/asadev')).toBe(
      'https://github.com/asadev',
    )
  })

  it('refuses to complete a search', () => {
    // A space means a question, and a question is not an address.
    expect(completionFor('how do I', 'https://how-to.test/')).toBeNull()
  })

  it('refuses when there is nothing to add, or nothing typed', () => {
    expect(completionFor('github.com', 'https://github.com')).toBeNull()
    expect(completionFor('', 'https://github.com/')).toBeNull()
    expect(completionFor('   ', 'https://github.com/')).toBeNull()
  })

  it('refuses a candidate that does not start with what was typed', () => {
    expect(completionFor('zzz', 'https://github.com/')).toBeNull()
  })

  it('keeps a real path, and drops only a bare host’s trailing slash', () => {
    expect(completionFor('local', 'http://localhost:3000/')).toBe('localhost:3000')
    expect(completionFor('local', 'http://localhost:3000/app')).toBe('localhost:3000/app')
  })
})
