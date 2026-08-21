import { describe, expect, it } from 'vitest'
import { withArgs } from './browser-drive-script'
import {
  DEFAULT_EXTRACT_LIMIT,
  EXTRACT_SCRIPT,
  LAZY_ATTRIBUTES,
  MAX_CANDIDATE_URL_CHARS,
  MAX_EXTRACT_LIMIT,
  MAX_EXTRACT_TEXT_CHARS,
  planFor,
  SRCSET_SEPARATOR,
} from './browser-store-script'
import { parseRecipe, type Recipe } from './browser-store-recipe'

/**
 * The claim this whole feature rests on, tested rather than asserted in a
 * comment: **a recipe is data, and nothing a recipe contains can become code.**
 *
 * `browser-store-recipe.ts` argues for it, `browser-store-script.ts` implements
 * it, and here it is checked the only way it can be checked without a browser:
 *
 *  1. the script carries exactly one substitution point;
 *  2. what is substituted is a JSON literal that round-trips back to the object
 *     it came from, whatever hostile text the recipe contained;
 *  3. the whole assembled string **compiles as JavaScript**, which is what
 *     catches an escaping bug in a template literal — the one class of mistake
 *     that would turn a selector into a statement;
 *  4. the script contains no evaluation of its own.
 *
 * There is no jsdom in this repository, so what the script *does* to a page is
 * not exercised here. That is stated rather than papered over: the behaviour is
 * verified by running it, and the structure — which is where a security property
 * lives — is verified here.
 */

function recipe(over: Partial<Recipe> = {}): Recipe {
  const parsed = parseRecipe(
    JSON.stringify({
      id: 'demo',
      name: 'Demo',
      summary: 'A recipe for the tests.',
      version: '1.0.0',
      grants: ['page-read'],
      origins: ['*'],
      fields: [{ name: 'headline', selector: 'h1', op: 'text' }],
    }),
    'demo',
  )
  if (!parsed.ok) throw new Error(parsed.why)
  return { ...parsed.recipe, ...over }
}

/** The JSON literal that replaced the token, read back out of the script. */
function substituted(script: string): unknown {
  const start = script.indexOf('var args = ') + 'var args = '.length
  const end = script.indexOf(' || {};', start)
  expect(end).toBeGreaterThan(start)
  return JSON.parse(script.slice(start, end))
}

describe('the engine', () => {
  it('has exactly one place arguments go in', () => {
    const token = '/*__DECK_ARGS__*/null'
    expect(EXTRACT_SCRIPT.split(token)).toHaveLength(2)
  })

  it('evaluates nothing of its own', () => {
    // No second door. `browser-cdp.ts` denies `Runtime.evaluate` precisely so
    // that a path from a string to a page's JavaScript cannot exist; a store
    // engine that reached for `Function` would have reopened it here.
    expect(EXTRACT_SCRIPT).not.toMatch(/\beval\s*\(/)
    expect(EXTRACT_SCRIPT).not.toMatch(/new\s+Function\b/)
    expect(EXTRACT_SCRIPT).not.toMatch(/\binnerHTML\b/)
    expect(EXTRACT_SCRIPT).not.toMatch(/document\.write\b/)
  })

  it('checks the secret guard before it reads any text or attribute', () => {
    const guard = EXTRACT_SCRIPT.indexOf('isSecret(el)')
    expect(guard).toBeGreaterThan(-1)
    // Every read of text or of a named attribute happens after it, inside the
    // same loop — the ordering is the guarantee, not the presence.
    expect(EXTRACT_SCRIPT.indexOf("op === 'attribute'", guard)).toBeGreaterThan(guard)
  })

  it('looks in every lazy-loading attribute, so a page that never fired its loader still answers', () => {
    for (const attribute of LAZY_ATTRIBUTES) expect(EXTRACT_SCRIPT).toContain(attribute)
  })

  it('carries its two numbers from here rather than typing them twice', () => {
    expect(EXTRACT_SCRIPT).toContain(String(MAX_CANDIDATE_URL_CHARS))
    expect(EXTRACT_SCRIPT).toContain(SRCSET_SEPARATOR.source)
  })
})

describe('splitting a srcset', () => {
  it('splits on the separator, not on a comma inside a URL', () => {
    /*
     * The second URL is a real image-CDN shape: `/w_500,h_300/` is one path
     * segment. Splitting on a bare comma cuts it in half and every candidate
     * after it is nonsense — which is the "wrong size" bug arriving as a
     * broken address rather than as a small one.
     */
    const set =
      'https://cdn.example/a.jpg 500w, https://cdn.example/w_500,h_300/b.jpg 1000w'
    expect(set.split(SRCSET_SEPARATOR)).toEqual([
      'https://cdn.example/a.jpg 500w',
      'https://cdn.example/w_500,h_300/b.jpg 1000w',
    ])
  })

  it('splits when the separator has no space after it', () => {
    expect('a.jpg 500w,b.jpg 1000w'.split(SRCSET_SEPARATOR)).toEqual(['a.jpg 500w', 'b.jpg 1000w'])
    expect('a.jpg 1x,b.jpg 2x'.split(SRCSET_SEPARATOR)).toEqual(['a.jpg 1x', 'b.jpg 2x'])
  })

  it('leaves a single entry alone', () => {
    expect('https://cdn.example/w_1,h_2/a.jpg'.split(SRCSET_SEPARATOR)).toEqual([
      'https://cdn.example/w_1,h_2/a.jpg',
    ])
  })
})

describe('a recipe cannot become code', () => {
  it('round-trips a hostile selector through the substitution unchanged', () => {
    /*
     * Every shape that would end the JSON literal early and start a statement.
     * A selector like this is refused by the parser as well — it contains `<` —
     * but the substitution must be safe for anything, because the parser is the
     * *first* line and this is the one that has to hold if the parser is ever
     * widened.
     */
    const hostile = `'); alert(1); ('` + '`${x}`' + '</script>  \\'
    const plan = planFor(recipe({ next: hostile }))
    const script = withArgs(EXTRACT_SCRIPT, plan)
    const back = substituted(script) as { next: string }
    expect(back.next).toBe(hostile)
  })

  it('compiles as JavaScript with that selector in it', () => {
    const hostile = `'); alert(1); ('` + '`${x}`' + '</script>  \\'
    const script = withArgs(EXTRACT_SCRIPT, planFor(recipe({ next: hostile })))
    /*
     * Compiled, never called. `new Function` parses its body and returns a
     * function; nothing here invokes it, and there is no page for it to touch.
     * A syntax error thrown from this line is an escaping bug in the template
     * literal, which is the only way text in a recipe could ever have become a
     * statement.
     */
    expect(() => new Function(`return ${script}`)).not.toThrow()
  })

  it('compiles with every shipped recipe substituted into it', async () => {
    const { BROWSER_TOOL_CATALOGUE } = await import('./browser-store-catalogue')
    for (const entry of BROWSER_TOOL_CATALOGUE) {
      if (entry.source.kind !== 'bundled') continue
      const parsed = parseRecipe(entry.source.text, entry.id)
      expect(parsed.ok).toBe(true)
      if (!parsed.ok) continue
      const script = withArgs(EXTRACT_SCRIPT, planFor(parsed.recipe))
      expect(() => new Function(`return ${script}`), entry.id).not.toThrow()
    }
  })
})

describe('the plan the page is handed', () => {
  it('carries the recipe and nothing else', () => {
    const plan = planFor(recipe())
    expect(Object.keys(plan).sort()).toEqual([
      'fields',
      'limit',
      'next',
      'rows',
      'stated',
      'textLimit',
    ])
  })

  it('clamps a limit rather than refusing it', () => {
    expect(planFor(recipe(), { limit: 0 }).limit).toBe(1)
    expect(planFor(recipe(), { limit: 10 ** 9 }).limit).toBe(MAX_EXTRACT_LIMIT)
    expect(planFor(recipe()).limit).toBe(DEFAULT_EXTRACT_LIMIT)
    expect(planFor(recipe(), { textLimit: 10 ** 9 }).textLimit).toBe(MAX_EXTRACT_TEXT_CHARS)
  })
})
