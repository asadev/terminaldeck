import { describe, expect, it } from 'vitest'
import {
  acceptsRendition,
  applyRule,
  chooseRendition,
  readRenditionRules,
  renditionCandidates,
  type RenditionProbe,
  type RenditionRule,
} from './browser-asset-rendition'

/**
 * Upgrading a URL to the big copy, and the fallback that must never be lost.
 *
 * Asad captured 62,000 images at 498 pixels while the 1920-pixel original was
 * one word away in the URL. The feature that fixes that is a guess about a
 * stranger's URL scheme, so most of what is asserted here is what happens when
 * the guess is **wrong** — because a rewrite that turns a small image into no
 * image is worse than the problem it was solving.
 */

const PATH_RULE: RenditionRule = { id: 'path-size', match: '/498/', replace: '/1920/' }
const QUERY_RULE: RenditionRule = { id: 'query-width', match: '([?&]w=)\\d+', replace: '$11920' }

/** A probe table: URL → what the server says. Anything absent is a failed request. */
function probing(table: Record<string, RenditionProbe>): {
  probe: (url: string) => Promise<RenditionProbe | null>
  asked: string[]
} {
  const asked: string[] = []
  return {
    asked,
    probe: async (url: string) => {
      asked.push(url)
      return table[url] ?? null
    },
  }
}

const ok = (bytes: number | null, contentType = 'image/jpeg'): RenditionProbe => ({
  status: 200,
  bytes,
  contentType,
})

describe('rules', () => {
  it('refuses a rule with no id, because a bad rule has to be nameable', () => {
    expect(() => readRenditionRules([{ match: 'a', replace: 'b' }])).toThrow(/id/)
  })

  it('refuses an expression that does not compile, at the door rather than mid-run', () => {
    expect(() => readRenditionRules([{ id: 'bad', match: '([', replace: 'x' }])).toThrow(/valid expression/)
  })

  it('refuses two rules with the same id', () => {
    expect(() =>
      readRenditionRules([PATH_RULE, { ...PATH_RULE, replace: '/2560/' }]),
    ).toThrow(/two rules are called/)
  })

  it('reads a good set and keeps the caller’s order', () => {
    expect(readRenditionRules([PATH_RULE, QUERY_RULE]).map((rule) => rule.id)).toEqual([
      'path-size',
      'query-width',
    ])
  })

  it('leaves a URL alone when the rule does not match it', () => {
    expect(applyRule('https://x.test/a/1920/b.jpg', PATH_RULE)).toBe('https://x.test/a/1920/b.jpg')
  })
})

describe('candidates', () => {
  it('always ends with the original, even when a rule matched', () => {
    const list = renditionCandidates('https://x.test/i/498/a.jpg', [PATH_RULE])
    expect(list.map((entry) => entry.url)).toEqual([
      'https://x.test/i/1920/a.jpg',
      'https://x.test/i/498/a.jpg',
    ])
    expect(list[list.length - 1].ruleId).toBe('')
  })

  it('is just the original when no rule matches, rather than empty', () => {
    expect(renditionCandidates('https://x.test/a.jpg', [PATH_RULE])).toEqual([
      { url: 'https://x.test/a.jpg', ruleId: '' },
    ])
  })

  it('tries every rule applied together first, for a URL that states the size twice', () => {
    // The case one rule cannot express: a server handed a path saying 1920 and a
    // query saying 498 resolves the contradiction by serving the small one.
    const list = renditionCandidates('https://x.test/i/498/a.jpg?w=498', [PATH_RULE, QUERY_RULE])
    expect(list[0]).toEqual({ url: 'https://x.test/i/1920/a.jpg?w=1920', ruleId: 'path-size+query-width' })
    expect(list[list.length - 1].ruleId).toBe('')
  })

  it('does not pay for a rule that happens to reproduce the original', () => {
    const list = renditionCandidates('https://x.test/i/1920/a.jpg', [
      { id: 'noop', match: '/1920/', replace: '/1920/' },
    ])
    expect(list).toHaveLength(1)
  })
})

describe('what counts as an upgrade', () => {
  it('refuses a page served where a file was asked for', () => {
    const verdict = acceptsRendition({
      candidateUrl: 'https://x.test/i/1920/a.jpg',
      probe: ok(4_000, 'text/html'),
      originalProbe: ok(20_000),
    })
    expect(verdict.ok).toBe(false)
    expect(verdict.reason).toContain('page rather than the file')
  })

  it('has no opinion about content type when the URL does not claim to be a file', () => {
    // A signed CDN route with no extension. Guessing here would refuse every
    // upgrade on a whole class of site.
    const verdict = acceptsRendition({
      candidateUrl: 'https://x.test/image/123?size=large',
      probe: ok(90_000, 'text/html'),
      originalProbe: ok(20_000),
    })
    expect(verdict.ok).toBe(true)
  })

  it('refuses an upgrade that is no bigger than the original — the 498px preview again', () => {
    const verdict = acceptsRendition({
      candidateUrl: 'https://x.test/i/1920/a.jpg',
      probe: ok(20_000),
      originalProbe: ok(20_000),
    })
    expect(verdict.ok).toBe(false)
    expect(verdict.reason).toContain('not a bigger copy')
    expect(verdict.comparedBytes).toBe(true)
  })

  it('says plainly when the lengths could not be compared rather than implying they were', () => {
    const verdict = acceptsRendition({
      candidateUrl: 'https://x.test/i/1920/a.jpg',
      probe: ok(null),
      originalProbe: ok(20_000),
    })
    expect(verdict.ok).toBe(true)
    expect(verdict.comparedBytes).toBe(false)
  })

  it('refuses an empty answer and one under minBytes', () => {
    expect(
      acceptsRendition({ candidateUrl: 'https://x.test/a.jpg', probe: ok(0), options: { requireLarger: false } })
        .ok,
    ).toBe(false)
    expect(
      acceptsRendition({
        candidateUrl: 'https://x.test/a.jpg',
        probe: ok(200),
        options: { minBytes: 1_000, requireLarger: false },
      }).reason,
    ).toContain('below the 1000')
  })
})

describe('choosing', () => {
  it('takes the upgrade when it answers and is bigger', async () => {
    const { probe } = probing({
      'https://x.test/i/498/a.jpg': ok(20_000),
      'https://x.test/i/1920/a.jpg': ok(400_000),
    })
    const choice = await chooseRendition({
      url: 'https://x.test/i/498/a.jpg',
      rules: [PATH_RULE],
      probe,
    })
    expect(choice.url).toBe('https://x.test/i/1920/a.jpg')
    expect(choice.upgraded).toBe(true)
    expect(choice.ruleId).toBe('path-size')
    expect(choice.fellBack).toBe(false)
  })

  it('falls back to the original when the upgrade 404s, and says which one it used', async () => {
    /*
     * The requirement, in one test. A bad guess degrades to lower quality and
     * never to nothing.
     */
    const { probe } = probing({
      'https://x.test/i/498/a.jpg': ok(20_000),
      // 1920 simply is not there.
    })
    const choice = await chooseRendition({
      url: 'https://x.test/i/498/a.jpg',
      rules: [PATH_RULE],
      probe,
    })
    expect(choice.url).toBe('https://x.test/i/498/a.jpg')
    expect(choice.upgraded).toBe(false)
    expect(choice.fellBack).toBe(true)
    expect(choice.reachable).toBe(true)
    expect(choice.attempts).toHaveLength(2)
    expect(choice.attempts[0].ok).toBe(false)
    expect(choice.line).toContain('the original URL was used')
  })

  it('records which URL was actually fetched, and why the other was refused', async () => {
    const { probe } = probing({
      'https://x.test/i/498/a.jpg': ok(20_000),
      'https://x.test/i/1920/a.jpg': { status: 404, bytes: null, contentType: 'text/html' },
    })
    const choice = await chooseRendition({ url: 'https://x.test/i/498/a.jpg', rules: [PATH_RULE], probe })
    expect(choice.attempts[0]).toMatchObject({ ruleId: 'path-size', ok: false, status: 404 })
    expect(choice.attempts[0].reason).toBe('HTTP 404')
    expect(choice.attempts[1]).toMatchObject({ ruleId: '', ok: true })
  })

  it('hands back the original to be fetched anyway when nothing answers at all', async () => {
    /*
     * A HEAD that fails is not proof that a GET will. Skipping the asset here
     * would be discarding a file that is there — which is the same class of
     * mistake, made in the other direction.
     */
    const { probe } = probing({})
    const choice = await chooseRendition({ url: 'https://x.test/i/498/a.jpg', rules: [PATH_RULE], probe })
    expect(choice.url).toBe('https://x.test/i/498/a.jpg')
    expect(choice.reachable).toBe(false)
    expect(choice.line).toContain('handed back to be fetched anyway')
  })

  it('does not probe the original as a yardstick when there is nothing to measure', async () => {
    const { probe, asked } = probing({ 'https://x.test/a.jpg': ok(20_000) })
    await chooseRendition({ url: 'https://x.test/a.jpg', rules: [], probe })
    expect(asked).toEqual(['https://x.test/a.jpg'])
  })

  it('never measures the original against itself when it is the fallback', async () => {
    // With `requireLarger` on, the original arriving as the last candidate must
    // not be refused for failing to be bigger than itself — which would leave
    // the run with no URL at all.
    const { probe } = probing({ 'https://x.test/i/498/a.jpg': ok(20_000) })
    const choice = await chooseRendition({
      url: 'https://x.test/i/498/a.jpg',
      rules: [PATH_RULE],
      probe,
      options: { requireLarger: true },
    })
    expect(choice.url).toBe('https://x.test/i/498/a.jpg')
    expect(choice.reachable).toBe(true)
  })

  it('survives a probe that throws', async () => {
    const choice = await chooseRendition({
      url: 'https://x.test/i/498/a.jpg',
      rules: [PATH_RULE],
      probe: async () => {
        throw new Error('socket hang up')
      },
    })
    expect(choice.url).toBe('https://x.test/i/498/a.jpg')
    expect(choice.reachable).toBe(false)
  })
})
