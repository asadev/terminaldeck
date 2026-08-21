import { describe, expect, it } from 'vitest'
import {
  actionFor,
  cdpResourceType,
  cheapBodyFor,
  cheapHeaders,
  describeRules,
  interceptedKinds,
  kindOfResourceType,
  readFetchRules,
  RESOURCE_KINDS,
  RULE_ACTIONS,
} from './browser-fetch-rules'

describe('three answers, not two', () => {
  it('offers fulfill alongside allow and block, because two is what lost the images', () => {
    expect([...RULE_ACTIONS]).toEqual(['allow', 'block', 'fulfill'])
  })

  it('cannot name the page’s own document, at any spelling', () => {
    // A rule that could empty the page somebody came to read is not a rule
    // anybody wants, so `document` is absent from the vocabulary rather than
    // defaulted to allow. `browser-cdp.ts` refuses it again at the channel.
    expect([...RESOURCE_KINDS]).not.toContain('document')
    expect(kindOfResourceType('Document')).toBeNull()
    expect(readFetchRules({ document: 'block' })).toMatchObject({
      rules: {},
      unknownKinds: ['document'],
    })
  })

  it('reads Chromium’s spelling of a kind, whatever case it arrives in', () => {
    expect(kindOfResourceType('Image')).toBe('image')
    expect(kindOfResourceType('XHR')).toBe('xhr')
    expect(kindOfResourceType('Stylesheet')).toBe('stylesheet')
    // Types no rule can name are continued untouched rather than guessed at.
    for (const type of ['WebSocket', 'Ping', 'Preflight', 'Other', '', null, 7]) {
      expect(kindOfResourceType(type)).toBeNull()
    }
  })

  it('maps every kind back to a resource type Chromium knows', () => {
    expect(RESOURCE_KINDS.map(cdpResourceType)).toEqual([
      'Image',
      'Media',
      'Font',
      'Stylesheet',
      'Script',
      'XHR',
      'Fetch',
    ])
  })

  it('leaves alone anything no rule mentions', () => {
    expect(actionFor('image', {})).toBe('allow')
    expect(actionFor(null, { image: 'block' })).toBe('allow')
    expect(actionFor('image', { image: 'fulfill' })).toBe('fulfill')
  })

  it('intercepts only the kinds a rule actually changes', () => {
    // The narrowing that keeps this cheap: `Fetch.enable` with no patterns
    // pauses every request in the page, including the document.
    expect(interceptedKinds({ image: 'fulfill', script: 'allow', xhr: 'block' })).toEqual([
      'image',
      'xhr',
    ])
    expect(interceptedKinds({})).toEqual([])
    expect(interceptedKinds({ font: 'allow' })).toEqual([])
  })
})

describe('reading a rules object off a tool call', () => {
  it('takes the ordinary shape', () => {
    const read = readFetchRules({ image: 'fulfill', font: 'block', script: 'allow' })
    expect(read.rules).toEqual({ image: 'fulfill', font: 'block', script: 'allow' })
    expect(read.unknownKinds).toEqual([])
    expect(read.badActions).toEqual([])
  })

  /*
   * The near-miss is the whole reason this returns lists instead of dropping
   * what it does not understand. `images: 'fulfill'` is the shape right and one
   * word wrong — the same mistake `schema.ts` was written for — and the cost of
   * silently ignoring it is a page that behaves completely normally while the
   * caller believes it is being harvested cheaply.
   */
  it('names a kind it does not know rather than dropping it', () => {
    const read = readFetchRules({ images: 'fulfill', stylesheets: 'block' })
    expect(read.rules).toEqual({})
    expect(read.unknownKinds).toEqual(['images', 'stylesheets'])
  })

  it('names an action it does not know rather than dropping it', () => {
    const read = readFetchRules({ image: 'abort', font: 7 })
    expect(read.rules).toEqual({})
    expect(read.badActions).toEqual(['image: abort', 'font: number'])
  })

  it('is unbothered by something that is not an object at all', () => {
    for (const raw of [null, undefined, 'image', 42, ['image']]) {
      expect(readFetchRules(raw)).toEqual({ rules: {}, unknownKinds: [], badActions: [] })
    }
  })

  it('says what it is doing, for the dialog and the log', () => {
    expect(describeRules({})).toBe('none')
    expect(describeRules({ xhr: 'allow', image: 'fulfill' })).toBe('image: fulfill, xhr: allow')
  })
})

describe('what a cheap answer actually is', () => {
  it('parses as the thing it claims to be, for every kind', () => {
    expect(cheapBodyFor('stylesheet').mimeType).toBe('text/css')
    expect(cheapBodyFor('script').body.toString('utf8')).toContain('/*')
    expect(JSON.parse(cheapBodyFor('xhr').body.toString('utf8'))).toEqual({})
    expect(JSON.parse(cheapBodyFor('fetch').body.toString('utf8'))).toEqual({})
    // A font and a media file have no valid empty form; failing to decode is
    // the intended outcome and the cheapest way to reach it.
    expect(cheapBodyFor('font').body.length).toBe(0)
    expect(cheapBodyFor('media').body.length).toBe(0)
  })

  it('never lets a placeholder become the cached answer', () => {
    /*
     * The trap this closes is 62,000 previews in a new disguise: a placeholder
     * written into the HTTP cache would still be there on the run that wanted
     * the real image.
     */
    const headers = cheapHeaders('image/png', 71)
    expect(headers).toContainEqual({ name: 'cache-control', value: 'no-store' })
    expect(headers).toContainEqual({ name: 'content-type', value: 'image/png' })
    expect(headers).toContainEqual({ name: 'content-length', value: '71' })
  })

  it('carries nothing that could write into his session', () => {
    const names = cheapHeaders('text/css', 0).map((header) => header.name)
    expect(names).not.toContain('set-cookie')
    expect(names).not.toContain('location')
  })
})

describe('the word this action used to be called', () => {
  it('still reads `cheap`, and stores `fulfill`', () => {
    // The rename is a rename of the *vocabulary*, not a break: a recipe on disk
    // or a caller written against an older build says `cheap`, and refusing it
    // would turn a working call into an error nobody asked for. Nothing this
    // process emits says `cheap` any more.
    const read = readFetchRules({ image: 'cheap', script: 'CHEAP' })
    expect(read.rules).toEqual({ image: 'fulfill', script: 'fulfill' })
    expect(read.badActions).toEqual([])
    expect(describeRules(read.rules)).toBe('image: fulfill, script: fulfill')
  })

  it('does not accept any other near-miss, which is the whole of the mercy', () => {
    expect(readFetchRules({ image: 'abort' }).badActions).toEqual(['image: abort'])
  })
})
