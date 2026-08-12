import { describe, expect, it } from 'vitest'
import {
  composeAgentContext,
  computeSelector,
  cssString,
  escapeIdent,
  parseCapture,
  sanitizeLine,
  type ElementCapture,
  type ElementDescriptor,
} from './selector'

/**
 * The descriptors here are written the way the guest reports them: index 0 is
 * the clicked element, each entry after it is its parent.
 */
function el(tag: string, extra: Partial<ElementDescriptor> = {}): ElementDescriptor {
  return { tag, nthOfType: 1, ofTypeCount: 1, ...extra }
}

const BODY = el('body')
const HTML = el('html')

describe('escapeIdent', () => {
  it('leaves ordinary identifiers alone', () => {
    expect(escapeIdent('cta-primary')).toBe('cta-primary')
    expect(escapeIdent('save_button2')).toBe('save_button2')
  })

  it('hex-escapes a leading digit, which is legal in an id but not in a selector', () => {
    expect(escapeIdent('3col')).toBe('\\33 col')
  })

  it('escapes a digit after a leading hyphen', () => {
    expect(escapeIdent('-1st')).toBe('-\\31 st')
  })

  it('escapes a lone hyphen', () => {
    expect(escapeIdent('-')).toBe('\\-')
  })

  it('escapes selector punctuation so injected syntax cannot break out', () => {
    expect(escapeIdent('a.b#c[d]')).toBe('a\\.b\\#c\\[d\\]')
    expect(escapeIdent('a b')).toBe('a\\ b')
    expect(escapeIdent('x"]:hover')).toBe('x\\"\\]\\:hover')
  })

  it('keeps non-ASCII as-is, since CSS identifiers allow it', () => {
    expect(escapeIdent('café')).toBe('café')
  })
})

describe('cssString', () => {
  it('quotes and escapes', () => {
    expect(cssString('hello')).toBe('"hello"')
    expect(cssString('say "hi"')).toBe('"say \\"hi\\""')
    expect(cssString('back\\slash')).toBe('"back\\\\slash"')
  })

  it('refuses values holding control characters rather than guessing an escape', () => {
    expect(cssString('two\nlines')).toBeNull()
  })
})

describe('computeSelector', () => {
  it('prefers a unique id', () => {
    const path = [el('button', { id: 'cta', idUnique: true }), el('div'), BODY, HTML]
    expect(computeSelector(path)).toBe('#cta')
  })

  it('ignores a duplicated id — the case a naive #id gets wrong', () => {
    // React lists routinely render the same id many times over. `#row` would
    // match the wrong node, so the path wins instead.
    const path = [
      el('button', { id: 'row', idUnique: false, nthOfType: 3, ofTypeCount: 5 }),
      el('li', { nthOfType: 3, ofTypeCount: 5 }),
      el('ul'),
      BODY,
      HTML,
    ]
    expect(computeSelector(path)).toBe(
      'body > ul > li:nth-of-type(3) > button:nth-of-type(3)',
    )
  })

  it('falls back to a unique test hook when the id is not unique', () => {
    const path = [
      el('button', {
        id: 'row',
        idUnique: false,
        testAttr: 'data-testid',
        testValue: 'row-delete',
        testUnique: true,
      }),
      BODY,
      HTML,
    ]
    expect(computeSelector(path)).toBe('[data-testid="row-delete"]')
  })

  it('escapes an id that needs it', () => {
    const path = [el('div', { id: '3col', idUnique: true }), BODY]
    expect(computeSelector(path)).toBe('#\\33 col')
  })

  it('anchors at the nearest unique ancestor id rather than walking to body', () => {
    const path = [
      el('span', { nthOfType: 2, ofTypeCount: 3 }),
      el('p'),
      el('section', { id: 'pricing', idUnique: true }),
      el('main'),
      BODY,
      HTML,
    ]
    expect(computeSelector(path)).toBe('#pricing > p > span:nth-of-type(2)')
  })

  it('anchors at a unique ancestor test hook', () => {
    const path = [
      el('svg'),
      el('button', { testAttr: 'data-cy', testValue: 'close', testUnique: true }),
      BODY,
    ]
    expect(computeSelector(path)).toBe('[data-cy="close"] > svg')
  })

  it('anchors at body so the path cannot match at another depth', () => {
    // Without the body anchor, `div > span` matches every such pair in the
    // document — that is a guess, not a selector.
    const path = [el('span'), el('div', { nthOfType: 2, ofTypeCount: 4 }), BODY, HTML]
    expect(computeSelector(path)).toBe('body > div:nth-of-type(2) > span')
  })

  it('never emits an <html> segment', () => {
    expect(computeSelector([el('div'), HTML])).toBe('div')
  })

  it('adds :nth-of-type only when siblings of that type exist', () => {
    const path = [el('td', { nthOfType: 2, ofTypeCount: 2 }), el('tr'), BODY]
    expect(computeSelector(path)).toBe('body > tr > td:nth-of-type(2)')
  })

  it('preserves SVG camelCase tag names', () => {
    const path = [el('clipPath'), el('svg'), BODY]
    expect(computeSelector(path)).toBe('body > svg > clipPath')
  })

  it('replaces a bogus tag with the universal selector instead of emitting garbage', () => {
    const path = [el('a[href]:hover'), BODY]
    expect(computeSelector(path)).toBe('body > *')
  })

  it('rejects a test attribute the page invented', () => {
    const path = [
      el('button', { testAttr: 'onclick', testValue: 'alert(1)', testUnique: true }),
      BODY,
    ]
    expect(computeSelector(path)).toBe('body > button')
  })

  it('ignores an id containing control characters', () => {
    const path = [el('div', { id: 'a\nb', idUnique: true }), BODY]
    expect(computeSelector(path)).toBe('body > div')
  })

  it('returns an empty string for an empty path', () => {
    expect(computeSelector([])).toBe('')
  })

  it('stops at the depth cap on a pathological chain', () => {
    const deep = Array.from({ length: 500 }, () => el('div'))
    const selector = computeSelector(deep)
    expect(selector.split(' > ')).toHaveLength(64)
  })
})

describe('sanitizeLine', () => {
  it('flattens newlines, which would otherwise submit the agent prompt early', () => {
    expect(sanitizeLine('first\nsecond', 100)).toBe('first second')
    expect(sanitizeLine('a\r\nb', 100)).toBe('a b')
  })

  it('strips terminal escape sequences', () => {
    expect(sanitizeLine('\u001b]0;pwned\u0007hello', 100)).toBe(']0;pwned hello')
    expect(sanitizeLine('\u001b[2Jwiped', 100)).toBe('[2Jwiped')
  })

  it('strips bidi overrides that would make text read differently than it acts', () => {
    expect(sanitizeLine('safe\u202edegrofnu', 100)).toBe('safedegrofnu')
  })

  it('clamps and marks truncation', () => {
    expect(sanitizeLine('abcdefghij', 4)).toBe('abcd…')
  })

  it('returns an empty string for non-strings', () => {
    expect(sanitizeLine(undefined, 10)).toBe('')
    expect(sanitizeLine({ toString: () => 'nope' }, 10)).toBe('')
  })

  it('does not scan a hostile string end to end', () => {
    // The page picks this length and this runs on the main process, which is
    // the app's UI thread. Collapsing 16M alternating spaces before clamping
    // took ~1s per message, and the guest can send messages in a loop.
    const huge = ' a'.repeat(8 * 1024 * 1024)
    const started = Date.now()
    const line = sanitizeLine(huge, 150)
    expect(Date.now() - started).toBeLessThan(250)
    expect(line.length).toBeLessThanOrEqual(151)
    expect(line.endsWith('…')).toBe(true)
  })
})

describe('parseCapture', () => {
  const good = {
    v: 1,
    path: [
      { tag: 'button', id: 'buy', idUnique: true, nthOfType: 1, ofTypeCount: 1 },
      { tag: 'body', nthOfType: 1, ofTypeCount: 1 },
    ],
    text: 'Start free trial',
    attributes: { 'aria-label': 'Buy now', type: 'submit' },
  }

  it('accepts a well-formed payload', () => {
    const capture = parseCapture(good, 'http://localhost:3000/pricing')
    expect(capture).not.toBeNull()
    expect(capture?.selector).toBe('#buy')
    expect(capture?.tag).toBe('button')
    expect(capture?.label).toBe('Start free trial')
    expect(capture?.labelSource).toBe('text')
    expect(capture?.url).toBe('http://localhost:3000/pricing')
    expect(capture?.attributes).toEqual({ 'aria-label': 'Buy now', type: 'submit' })
  })

  it('falls back through label sources for an element with no text', () => {
    const capture = parseCapture(
      { ...good, text: '', attributes: { 'aria-label': 'Close dialog' } },
      'http://localhost:3000/',
    )
    expect(capture?.label).toBe('Close dialog')
    expect(capture?.labelSource).toBe('aria-label')
  })

  it('uses the url the main process supplied, not one the page could claim', () => {
    const capture = parseCapture(
      { ...good, url: 'https://bank.example.com' },
      'http://localhost:3000/',
    )
    expect(capture?.url).toBe('http://localhost:3000/')
  })

  it('drops attributes outside the whitelist', () => {
    const capture = parseCapture(
      { ...good, attributes: { onclick: 'steal()', __proto__: { polluted: true }, alt: 'ok' } },
      'http://localhost:3000/',
    )
    expect(capture?.attributes).toEqual({ alt: 'ok' })
    expect('onclick' in (capture?.attributes ?? {})).toBe(false)
  })

  it('rejects malformed payloads', () => {
    expect(parseCapture(null, 'http://x/')).toBeNull()
    expect(parseCapture('nope', 'http://x/')).toBeNull()
    expect(parseCapture({ v: 2, path: [{ tag: 'div' }] }, 'http://x/')).toBeNull()
    expect(parseCapture({ v: 1, path: [] }, 'http://x/')).toBeNull()
    expect(parseCapture({ v: 1, path: [{ nope: true }] }, 'http://x/')).toBeNull()
  })

  it('truncates at a broken link instead of splicing the chain back together', () => {
    // Dropping the middle entry and joining what is left with `>` would claim
    // the span is a direct child of body, which is a selector that matches
    // something else entirely — or nothing.
    const capture = parseCapture(
      {
        v: 1,
        path: [
          { tag: 'span', nthOfType: 1, ofTypeCount: 1 },
          { nope: true },
          { tag: 'body', nthOfType: 1, ofTypeCount: 1 },
        ],
      },
      'http://localhost:3000/',
    )
    expect(capture?.selector).toBe('span')
    expect(capture?.selector).not.toContain('body')
  })

  it('never carries the value of a password field', () => {
    // This string would otherwise be shown in the capture panel and pasted
    // into the agent's prompt, which is written to disk.
    const capture = parseCapture(
      {
        ...good,
        text: '',
        attributes: { type: 'password', value: 'hunter2', placeholder: 'Password' },
      },
      'http://localhost:3000/login',
    )
    expect(capture?.attributes.value).toBeUndefined()
    expect(capture?.attributes.type).toBe('password')
    expect(capture?.label).toBe('Password')
    expect(JSON.stringify(capture)).not.toContain('hunter2')
  })

  it('still carries an ordinary field value', () => {
    const capture = parseCapture(
      { ...good, text: '', attributes: { type: 'email', value: 'asad@example.com' } },
      'http://localhost:3000/login',
    )
    expect(capture?.attributes.value).toBe('asad@example.com')
    expect(capture?.labelSource).toBe('value')
  })

  it('survives a payload built entirely out of hostile types', () => {
    const capture = parseCapture(
      {
        v: 1,
        path: [{ tag: 'div', nthOfType: -5, ofTypeCount: Number.NaN, idUnique: 'yes' }],
        text: 12345,
        attributes: 'not-an-object',
      },
      'http://localhost:3000/',
    )
    expect(capture?.selector).toBe('div')
    expect(capture?.label).toBe('')
    expect(capture?.attributes).toEqual({})
  })
})

describe('composeAgentContext', () => {
  const capture: ElementCapture = {
    selector: '#cta-primary',
    tag: 'button',
    label: 'Start free trial',
    labelSource: 'text',
    url: 'http://localhost:3000/pricing',
    attributes: {},
  }

  it('composes one readable line', () => {
    expect(composeAgentContext(capture)).toBe(
      '[browser: on http://localhost:3000/pricing, element `#cta-primary`, <button>, text "Start free trial"]',
    )
  })

  it('puts the user instruction first', () => {
    expect(composeAgentContext(capture, 'Make this green')).toBe(
      'Make this green [browser: on http://localhost:3000/pricing, element `#cta-primary`, <button>, text "Start free trial"]',
    )
  })

  it('names the label source when it is not visible text', () => {
    const iconButton = { ...capture, label: 'Close', labelSource: 'aria-label' as const }
    expect(composeAgentContext(iconButton)).toContain('aria-label "Close"')
  })

  it('stays on one line whatever the page put in the label', () => {
    // A newline here would submit the agent prompt before the context arrived.
    const hostile = { ...capture, label: 'Buy\nrm -rf /\u001b[1m', url: 'http://x/\npwned' }
    const line = composeAgentContext(hostile, 'fix\nthis')
    expect(line).not.toMatch(/[\n\r\u001b]/)
    expect(line.startsWith('fix this ')).toBe(true)
  })

  it('omits parts it does not have', () => {
    const bare: ElementCapture = {
      selector: 'body > div',
      tag: '',
      label: '',
      labelSource: 'none',
      url: '',
      attributes: {},
    }
    expect(composeAgentContext(bare)).toBe('[browser: element `body > div`]')
  })
})
