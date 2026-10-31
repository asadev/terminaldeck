import { describe, expect, it } from 'vitest'
import { imageSizeScript, readSizeHint, type SizeHint } from './browser-capture-script'

/**
 * The size probe, run against a DOM small enough to hold in one's head.
 *
 * There is no jsdom in this repository and adding one to test a hundred lines
 * of string would be a poor trade — but the script *is* real logic, and the
 * riskiest part of it is a `srcset` parser. A parser that silently returns zero
 * is a page whose every placeholder is 1×1, which is the failure this whole
 * feature exists to prevent, arriving quietly.
 *
 * So the fake below implements exactly the four things the script touches:
 * `querySelectorAll` for the three selectors it asks for, `getAttribute`,
 * `getBoundingClientRect` and `getComputedStyle`. Everything else it uses —
 * `URL`, `parseInt`, `Array.prototype.slice` — is the language.
 */

interface FakeElement {
  tag: string
  attrs?: Record<string, string>
  rect?: { width: number; height: number }
  aspectRatio?: string
  currentSrc?: string
}

function run(elements: FakeElement[], url: string, baseURI = 'https://x.example/page'): unknown {
  const nodes = elements.map((element) => ({
    ...element,
    attrs: element.attrs ?? {},
  }))

  const matches = (node: (typeof nodes)[number], selector: string): boolean => {
    if (selector === 'img') return node.tag === 'img'
    if (selector === 'source[srcset],source[data-srcset]') {
      return node.tag === 'source' && ('srcset' in node.attrs || 'data-srcset' in node.attrs)
    }
    if (selector === '[data-src],[data-srcset]') {
      return 'data-src' in node.attrs || 'data-srcset' in node.attrs
    }
    throw new Error(`the script asked for a selector this fake does not implement: ${selector}`)
  }

  const Document = {
    prototype: {
      querySelectorAll(this: unknown, selector: string) {
        return nodes.filter((node) => matches(node, selector))
      },
      querySelector(this: unknown, selector: string) {
        return nodes.find((node) => matches(node, selector)) ?? null
      },
    },
  }
  const Element = {
    prototype: {
      getAttribute(this: (typeof nodes)[number], name: string) {
        return Object.hasOwn(this.attrs, name) ? this.attrs[name] : null
      },
      getBoundingClientRect(this: (typeof nodes)[number]) {
        return { x: 0, y: 0, width: this.rect?.width ?? 0, height: this.rect?.height ?? 0 }
      },
    },
  }
  const documentStub = { baseURI }
  const windowStub = {
    getComputedStyle(node: (typeof nodes)[number]) {
      return { aspectRatio: node.aspectRatio ?? 'auto' }
    },
  }

  // The script is an expression, so it is evaluated with the four globals it
  // reads handed in as parameters.
  const evaluate = new Function(
    'Document',
    'Element',
    'document',
    'window',
    `return ${imageSizeScript(url)}`,
  ) as (d: unknown, e: unknown, doc: unknown, win: unknown) => unknown
  return evaluate(Document, Element, documentStub, windowStub)
}

function sized(elements: FakeElement[], url: string, baseURI?: string): SizeHint | null {
  return readSizeHint(run(elements, url, baseURI))
}

describe('where the expected size comes from', () => {
  it('takes the attributes an author wrote down, first', () => {
    // What a `naturalWidth` check is usually comparing against.
    expect(
      sized(
        [{ tag: 'img', attrs: { src: 'https://x.example/a.jpg', width: '800', height: '600' }, rect: { width: 10, height: 10 } }],
        'https://x.example/a.jpg',
      ),
    ).toEqual({ width: 800, height: 600, from: 'attributes', derivedHeight: false })
  })

  it('reads the width descriptor of the srcset candidate that was requested', () => {
    /*
     * The only place a responsive image states its real intrinsic width, and
     * the reason blocking images breaks `<picture>` so completely.
     */
    expect(
      sized(
        [
          {
            tag: 'img',
            attrs: { srcset: 'photo-1200.jpg 1200w, photo-600.jpg 600w' },
            rect: { width: 300, height: 200 },
          },
        ],
        'https://x.example/photo-600.jpg',
      ),
    ).toEqual({ width: 600, height: 400, from: 'srcset', derivedHeight: true })
  })

  it('falls back to the laid-out box when the page states nothing else', () => {
    expect(
      sized(
        [{ tag: 'img', attrs: { src: 'https://x.example/c.jpg' }, rect: { width: 300, height: 200 } }],
        'https://x.example/c.jpg',
      ),
    ).toEqual({ width: 300, height: 200, from: 'box', derivedHeight: false })
  })

  it('derives a missing height from a ratio the page states, and admits it derived it', () => {
    expect(
      sized(
        [{ tag: 'img', attrs: { src: 'https://x.example/d.jpg', width: '300' }, aspectRatio: '3 / 2' }],
        'https://x.example/d.jpg',
      ),
    ).toEqual({ width: 300, height: 200, from: 'attributes', derivedHeight: true })
  })

  it('squares a width with no ratio anywhere, rather than inventing an aspect quietly', () => {
    // A made-up aspect is still a placeholder that passes every
    // `naturalWidth > 1` gate, which is what it is for — and `derivedHeight`
    // is what tells the caller how many of its placeholders were guesses.
    expect(
      sized(
        [{ tag: 'img', attrs: { src: 'https://x.example/e.jpg', width: '256' } }],
        'https://x.example/e.jpg',
      ),
    ).toEqual({ width: 256, height: 256, from: 'attributes', derivedHeight: true })
  })

  it('resolves a relative attribute the way the browser did to make the request', () => {
    expect(
      sized(
        [{ tag: 'img', attrs: { src: '/img/f.jpg', width: '40', height: '30' } }],
        'https://x.example/img/f.jpg',
      ),
    ).toMatchObject({ width: 40, height: 30 })
  })

  it('finds the image behind a lazy-loading data attribute', () => {
    /*
     * The ordinary shape of the pages this feature exists for: `data-src` holds
     * the real URL and `src` holds a spacer until an observer swaps them.
     */
    expect(
      sized(
        [{ tag: 'div', attrs: { 'data-src': 'https://x.example/g.jpg', width: '120', height: '90' } }],
        'https://x.example/g.jpg',
      ),
    ).toMatchObject({ width: 120, height: 90, from: 'attributes' })
  })

  it('reads a <source> inside a <picture>', () => {
    expect(
      sized(
        [
          { tag: 'source', attrs: { srcset: 'https://x.example/h-900.webp 900w' } },
          { tag: 'img', attrs: { src: 'https://x.example/h.jpg' }, rect: { width: 10, height: 10 } },
        ],
        'https://x.example/h-900.webp',
      ),
    ).toMatchObject({ width: 900, from: 'srcset' })
  })

  it('is not fooled by a density descriptor, which states no width at all', () => {
    // `2x` says how dense, not how wide. Treating it as a width would produce a
    // two-pixel placeholder, which is a 1×1 with extra steps.
    expect(
      sized(
        [{ tag: 'img', attrs: { srcset: 'https://x.example/i.jpg 2x' }, rect: { width: 64, height: 64 } }],
        'https://x.example/i.jpg',
      ),
    ).toEqual({ width: 64, height: 64, from: 'box', derivedHeight: false })
  })

  it('says "none" for the right element that states nothing yet', () => {
    // A lazy image below the fold, not laid out, with no attributes: the
    // element is the right one and there is genuinely no size to be had.
    expect(
      readSizeHint(
        run([{ tag: 'img', attrs: { src: 'https://x.example/j.jpg' } }], 'https://x.example/j.jpg'),
      ),
    ).toEqual({ width: 1, height: 1, from: 'none', derivedHeight: false })
  })

  it('answers null for a URL no element accounts for', () => {
    // A `new Image()` preload or a CSS background. Nothing to gate on, so
    // nothing is lost by the 1×1 the caller falls back to.
    expect(run([{ tag: 'img', attrs: { src: 'https://x.example/k.jpg' } }], 'https://x.example/other.jpg')).toBeNull()
  })

  it('answers null rather than throwing when there is no URL to look for', () => {
    expect(run([], '')).toBeNull()
  })
})

describe('narrowing what the page handed back', () => {
  /*
   * This is main-process code about to size a raster from numbers a website
   * produced, so the page's answer is narrowed rather than trusted.
   * `browser-placeholder.ts` clamps as well; two checks, because the
   * consequence of one being wrong is a `Buffer.alloc` sized by a site.
   */
  it.each([
    null,
    undefined,
    'big',
    42,
    { width: 0, height: 10 },
    { width: 10, height: 0 },
    { width: -5, height: -5 },
    { width: Number.NaN, height: 3 },
    { width: Number.POSITIVE_INFINITY, height: 3 },
  ])('refuses %s', (raw) => {
    expect(readSizeHint(raw)).toBeNull()
  })

  it('truncates a fractional size and keeps an unknown source honest', () => {
    expect(readSizeHint({ width: 10.9, height: 4.2, from: 'nonsense', derivedHeight: 'yes' })).toEqual({
      width: 10,
      height: 4,
      from: 'none',
      derivedHeight: false,
    })
  })
})
