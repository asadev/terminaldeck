import { describe, expect, it } from 'vitest'
import {
  GRANTS,
  MAX_RECIPE_BYTES,
  MAX_SELECTOR_CHARS,
  originWords,
  parseRecipe,
  recipeAllowsUrl,
} from './browser-store-recipe'

/**
 * The parser is the store's front door, so every refusal it can produce is
 * named here.
 *
 * A validator is only worth anything if the *refusals* are tested. A test suite
 * that feeds it good recipes proves it can say yes, which was never in doubt —
 * the question is whether it says no to the eleven shapes below, and in
 * particular whether it says no to a key it has never heard of. That last one is
 * the whole positive-list argument: a validator that ignores what it does not
 * recognise accepts next year's dangerous field today.
 */

const GOOD = {
  id: 'demo',
  name: 'Demo',
  summary: 'A recipe for the tests.',
  version: '1.0.0',
  grants: ['page-read'],
  origins: ['example.com'],
  fields: [{ name: 'headline', selector: 'h1', op: 'text' }],
}

function parse(patch: Record<string, unknown>, id = 'demo') {
  return parseRecipe(JSON.stringify({ ...GOOD, ...patch }), id)
}

describe('a recipe that is well formed', () => {
  it('parses, and keeps exactly what it declared', () => {
    const result = parse({})
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.recipe.id).toBe('demo')
    expect(result.recipe.grants).toEqual(['page-read'])
    expect(result.recipe.origins).toEqual(['example.com'])
    expect(result.recipe.fields[0]).toEqual({ name: 'headline', selector: 'h1', op: 'text' })
    // Absent, not invented. A recipe with no total must not gain one.
    expect(result.recipe.stated).toBeNull()
    expect(result.recipe.rows).toBeNull()
    expect(result.recipe.next).toBeNull()
  })

  it('takes rows, a stated total and a next link', () => {
    const result = parse({
      rows: { selector: 'tr', fields: [{ name: 'cells', selector: 'td', op: 'text', all: true }] },
      stated: { name: 'total', selector: '.count', op: 'number' },
      next: 'a.next',
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.recipe.rows?.fields[0].all).toBe(true)
    expect(result.recipe.stated?.op).toBe('number')
    expect(result.recipe.next).toBe('a.next')
  })
})

describe('what it refuses, and what it says', () => {
  it('refuses a key it has never heard of, and names it', () => {
    const result = parseRecipe(JSON.stringify({ ...GOOD, execute: 'rm -rf /' }), 'demo')
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('execute')
  })

  it('refuses an unknown key inside a field too', () => {
    const result = parse({ fields: [{ name: 'a', selector: 'h1', op: 'text', script: 'x' }] })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('script')
  })

  it('refuses a grant this build cannot enforce, and lists what it can', () => {
    const result = parse({ grants: ['network'] })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('network')
    expect(result.why).toContain(GRANTS[0])
  })

  it('refuses an op that is not in the closed set', () => {
    const result = parse({ fields: [{ name: 'a', selector: 'h1', op: 'eval' }] })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('op must be one of')
  })

  it('refuses a recipe whose id is not the one it was offered as', () => {
    const result = parse({}, 'something-else')
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('something-else')
  })

  it('refuses an origin that is not a host', () => {
    expect(parse({ origins: ['http://example.com/path'] }).ok).toBe(false)
    expect(parse({ origins: [''] }).ok).toBe(false)
    expect(parse({ origins: [] }).ok).toBe(false)
  })

  it('refuses a selector longer than a selector may be', () => {
    const result = parse({
      fields: [{ name: 'a', selector: 'x'.repeat(MAX_SELECTOR_CHARS + 1), op: 'text' }],
    })
    expect(result.ok).toBe(false)
  })

  it('refuses an empty selector for an op that needs an element', () => {
    expect(parse({ fields: [{ name: 'a', selector: '', op: 'image' }] }).ok).toBe(false)
    // …and allows it for the ops that mean "the document".
    expect(parse({ fields: [{ name: 'a', selector: '', op: 'data' }] }).ok).toBe(true)
  })

  it('refuses an attribute op with no attribute, and an attribute on anything else', () => {
    expect(parse({ fields: [{ name: 'a', selector: 'img', op: 'attribute' }] }).ok).toBe(false)
    expect(
      parse({ fields: [{ name: 'a', selector: 'img', op: 'text', attribute: 'src' }] }).ok,
    ).toBe(false)
  })

  it('refuses two fields with the same name', () => {
    const result = parse({
      fields: [
        { name: 'a', selector: 'h1', op: 'text' },
        { name: 'a', selector: 'h2', op: 'text' },
      ],
    })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('twice')
  })

  it('refuses a stated total that is not a number', () => {
    const result = parse({ stated: { name: 'total', selector: '.c', op: 'text' } })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('the total the page claims')
  })

  it('refuses bytes past the ceiling before it parses them', () => {
    // A megabyte of well-formed JSON is still refused, and it is refused for
    // being large rather than for being wrong.
    const huge = JSON.stringify({ ...GOOD, name: 'x'.repeat(MAX_RECIPE_BYTES) })
    const result = parseRecipe(huge, 'demo')
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('bytes or fewer')
  })

  it('never throws, whatever it is handed', () => {
    for (const bytes of ['', 'null', '[]', '{', '"a string"', '0']) {
      expect(() => parseRecipe(bytes, 'demo')).not.toThrow()
      expect(parseRecipe(bytes, 'demo').ok).toBe(false)
    }
  })
})

describe('where a recipe may run', () => {
  it('runs anywhere on a star', () => {
    expect(recipeAllowsUrl({ origins: ['*'] }, 'https://anything.example')).toBe(true)
  })

  it('refuses a page outside its own hosts', () => {
    const recipe = { origins: ['portal.example'] }
    expect(recipeAllowsUrl(recipe, 'https://portal.example/list')).toBe(true)
    expect(recipeAllowsUrl(recipe, 'https://bank.example/accounts')).toBe(false)
  })

  it('a wildcard label covers the bare host as well as its subdomains', () => {
    const recipe = { origins: ['*.portal.example'] }
    expect(recipeAllowsUrl(recipe, 'https://www.portal.example/')).toBe(true)
    expect(recipeAllowsUrl(recipe, 'https://portal.example/')).toBe(true)
    // …and does not cover a host that merely ends in the same letters.
    expect(recipeAllowsUrl(recipe, 'https://evilportal.example/')).toBe(false)
  })

  it('refuses anything that is not http or https, and anything unparseable', () => {
    expect(recipeAllowsUrl({ origins: ['example.com'] }, 'file:///etc/passwd')).toBe(false)
    expect(recipeAllowsUrl({ origins: ['example.com'] }, 'not a url')).toBe(false)
  })

  it('says where it runs in words a person reads', () => {
    expect(originWords(['*'])).toBe('any page')
    expect(originWords(['a.example', 'b.example'])).toBe('a.example, b.example')
  })
})
