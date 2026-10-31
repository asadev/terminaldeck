import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  allVisits,
  cleanTitle,
  clearHistory,
  forgetVisit,
  historyFor,
  MAX_ENTRIES,
  noteVisit,
  readVisits,
  rememberVisit,
  resetHistoryForTests,
  scoreVisit,
  suggestFor,
  typedForms,
  visitableUrl,
  type Visit,
} from './browser-history'

/**
 * The store behind *"history, save passwords and all of this"*, held at the
 * level it can be held at in a test run with no Electron and no DOM: the rules
 * about what is remembered, whose it is, and what the address bar offers.
 *
 * The `app`-facing half — the file, the delay, the IPC — is exercised where it
 * runs. What is pinned here is every judgement a future edit could quietly
 * reverse: an Isolated tab recording nothing, one profile never seeing another's
 * rows, and the ranking that decides which suggestion gets completed inline.
 */

function visit(over: Partial<Visit> = {}): Visit {
  return {
    profileId: 'default',
    url: 'https://example.com/',
    title: 'Example',
    visitedAt: 1000,
    visits: 1,
    ...over,
  }
}

describe('what counts as a place', () => {
  it('keeps http and https, because a dev server is plain http', () => {
    expect(visitableUrl('https://example.com/a')).toBe('https://example.com/a')
    expect(visitableUrl('http://localhost:3000/')).toBe('http://localhost:3000/')
  })

  it('refuses everything that is not a page somebody could go back to', () => {
    expect(visitableUrl('about:blank')).toBeNull()
    expect(visitableUrl('data:text/html,<p>hi')).toBeNull()
    expect(visitableUrl('file:///Users/apple/notes.md')).toBeNull()
    expect(visitableUrl('')).toBeNull()
    expect(visitableUrl(null)).toBeNull()
  })

  it('refuses an address too long to be one', () => {
    expect(visitableUrl(`https://example.com/${'a'.repeat(4000)}`)).toBeNull()
  })

  it('flattens a title rather than letting it break a row', () => {
    expect(cleanTitle('Two\nlines')).toBe('Two lines')
    expect(cleanTitle(undefined)).toBe('')
    expect(cleanTitle('x'.repeat(500))).toHaveLength(300)
  })
})

describe('a stored file is read defensively', () => {
  it('drops a row with no profile, because it would show up in every list', () => {
    const list = readVisits({
      entries: [
        { url: 'https://a.test/', profileId: 'default', visitedAt: 5 },
        { url: 'https://b.test/' },
      ],
    })
    expect(list.map((item) => item.url)).toEqual(['https://a.test/'])
  })

  it('survives a file that is not a history at all', () => {
    expect(readVisits(null)).toEqual([])
    expect(readVisits('nonsense')).toEqual([])
    expect(readVisits({ entries: 'nope' })).toEqual([])
  })
})

describe('one row per address', () => {
  it('counts a second visit instead of adding a second row', () => {
    const first = noteVisit([], {
      profileId: 'default',
      url: 'https://a.test/',
      title: 'A',
      visitedAt: 10,
    })
    const second = noteVisit(first, {
      profileId: 'default',
      url: 'https://a.test/',
      title: 'A',
      visitedAt: 20,
    })
    expect(second).toHaveLength(1)
    expect(second[0].visits).toBe(2)
    expect(second[0].visitedAt).toBe(20)
  })

  it('does not blank a title that arrived after the navigation', () => {
    // `did-navigate` fires with no title; `page-title-updated` brings it. A
    // later visit recorded from a redirect must not undo that.
    const withTitle = noteVisit(
      [visit({ url: 'https://a.test/', title: 'Real title' })],
      { profileId: 'default', url: 'https://a.test/', title: '', visitedAt: 50 },
    )
    expect(withTitle[0].title).toBe('Real title')
  })

  it('keeps the same address in two profiles as two rows', () => {
    const shared = noteVisit(
      [visit({ profileId: 'work', url: 'https://a.test/' })],
      { profileId: 'default', url: 'https://a.test/', title: 'A', visitedAt: 60 },
    )
    expect(shared).toHaveLength(2)
  })

  it('drops the oldest when it is full, not the newest', () => {
    const full: Visit[] = Array.from({ length: MAX_ENTRIES }, (_unused, index) =>
      visit({ url: `https://site${index}.test/`, visitedAt: index + 1 }),
    )
    const next = noteVisit(full, {
      profileId: 'default',
      url: 'https://new.test/',
      title: 'New',
      visitedAt: 999999,
    })
    expect(next).toHaveLength(MAX_ENTRIES)
    expect(next.some((item) => item.url === 'https://new.test/')).toBe(true)
    expect(next.some((item) => item.url === 'https://site0.test/')).toBe(false)
  })
})

describe('a profile only ever sees its own', () => {
  const list = [
    visit({ profileId: 'default', url: 'https://mine.test/', visitedAt: 30 }),
    visit({ profileId: 'work', url: 'https://theirs.test/', visitedAt: 40 }),
  ]

  it('lists one profile and not the other', () => {
    expect(historyFor(list, 'default').map((item) => item.url)).toEqual(['https://mine.test/'])
    expect(historyFor(list, 'work').map((item) => item.url)).toEqual(['https://theirs.test/'])
  })

  it('answers nothing for the Isolated tab’s empty id', () => {
    expect(historyFor(list, '')).toEqual([])
    expect(suggestFor(list, '', 'mine')).toEqual([])
  })

  it('searches the title as well as the address', () => {
    const found = historyFor(
      [visit({ url: 'https://x.test/9f2', title: 'Besar Restaurant Bluewaters' })],
      'default',
      'bluewaters',
    )
    expect(found).toHaveLength(1)
  })

  it('puts the most recent first', () => {
    const both = [
      visit({ url: 'https://old.test/', visitedAt: 1 }),
      visit({ url: 'https://new.test/', visitedAt: 2 }),
    ]
    expect(historyFor(both, 'default')[0].url).toBe('https://new.test/')
  })
})

describe('what the address bar offers', () => {
  it('matches the way a person types — no scheme, no www', () => {
    expect(typedForms('https://www.google.com/search')).toEqual([
      'https://www.google.com/search',
      'www.google.com/search',
      'google.com/search',
    ])
    expect(scoreVisit(visit({ url: 'https://www.google.com/' }), 'goo')).toBe(4)
    expect(scoreVisit(visit({ url: 'https://www.google.com/' }), 'htt')).toBe(3)
  })

  it('ranks a prefix of the address above a word in a title', () => {
    const list = [
      visit({ url: 'https://beta.test/', title: 'Nothing to do with it', visits: 1, visitedAt: 1 }),
      visit({ url: 'https://x.test/', title: 'A page about betamax', visits: 50, visitedAt: 99 }),
    ]
    expect(suggestFor(list, 'default', 'bet')[0].url).toBe('https://beta.test/')
  })

  it('prefers the place gone back to often over the one seen once, recently', () => {
    const list = [
      visit({ url: 'https://deck.test/', visits: 20, visitedAt: 10 }),
      visit({ url: 'https://deck.other/', visits: 1, visitedAt: 100 }),
    ]
    expect(suggestFor(list, 'default', 'deck')[0].url).toBe('https://deck.test/')
  })

  it('offers a search that has been run before, from a word inside its title', () => {
    // f_0096: Chrome's own drop-down under his cursor, with earlier searches on
    // it. Here they are ordinary visits — the search ran, so the results page
    // was landed on and titled.
    const list = [visit({ url: 'https://www.google.com/search?q=prawns', title: 'prawns - Google Search' })]
    expect(suggestFor(list, 'default', 'praw')).toHaveLength(1)
  })

  it('offers nothing at all for an empty bar', () => {
    expect(suggestFor([visit()], 'default', '   ')).toEqual([])
  })

  it('never offers more than it was asked for', () => {
    const many = Array.from({ length: 40 }, (_unused, index) =>
      visit({ url: `https://deck${index}.test/` }),
    )
    expect(suggestFor(many, 'default', 'deck', 5)).toHaveLength(5)
  })
})

describe('what is never written down', () => {
  let dir = ''

  beforeEach(() => {
    resetHistoryForTests()
    dir = mkdtempSync(join(tmpdir(), 'terminaldeck-history-'))
  })

  afterEach(() => {
    // The store writes on a short delay; dropping the timer stops a write
    // landing in a directory this test has already removed.
    resetHistoryForTests()
    rmSync(dir, { recursive: true, force: true })
  })

  it('keeps a page that was landed on, once, with its title', () => {
    expect(rememberVisit(dir, { profileId: 'default', url: 'https://a.test/', title: 'A' })).toBe(
      true,
    )
    const kept = allVisits(dir)
    expect(kept).toHaveLength(1)
    expect(kept[0].title).toBe('A')
  })

  it('refuses a tab with no profile — which is what an Isolated tab is', () => {
    /*
     * An isolated tab's partition is in memory and dies with the tab
     * (`browser-isolation.ts`), and its `profileId` is the empty string: the same
     * marker that stops a saved login ever being offered to it. A tab that throws
     * its cookies away and keeps a permanent record of where it went would be a
     * private mode that is not one.
     */
    expect(rememberVisit(dir, { profileId: '', url: 'https://a.test/' })).toBe(false)
    expect(allVisits(dir)).toEqual([])
  })

  it('refuses a page that is not a place', () => {
    expect(rememberVisit(dir, { profileId: 'default', url: 'about:blank' })).toBe(false)
    expect(rememberVisit(dir, { profileId: 'default', url: '' })).toBe(false)
    expect(allVisits(dir)).toEqual([])
  })

  it('forgets one row without touching the rest', () => {
    rememberVisit(dir, { profileId: 'default', url: 'https://a.test/' })
    rememberVisit(dir, { profileId: 'default', url: 'https://b.test/' })
    expect(forgetVisit(dir, 'default', 'https://a.test/').map((item) => item.url)).toEqual([
      'https://b.test/',
    ])
  })

  it('empties one profile and leaves the other alone', () => {
    rememberVisit(dir, { profileId: 'default', url: 'https://a.test/' })
    rememberVisit(dir, { profileId: 'work', url: 'https://b.test/' })
    const left = clearHistory(dir, 'default')
    expect(left.map((item) => item.profileId)).toEqual(['work'])
  })
})
