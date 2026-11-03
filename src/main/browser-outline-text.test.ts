import { describe, expect, it } from 'vitest'
import { OUTLINE_SCRIPT } from './browser-drive-script'
import { DEFAULT_OUTLINE_TEXT_CHARS, MAX_OUTLINE_TEXT_CHARS } from './browser-driver'

/**
 * `browser.read` has to return what the page *says*, not only what it offers.
 *
 * The tool is described as "what is on the page". Until 2026-08-18 the outline
 * carried the url, the title and a list of controls, and no text at all — so on
 * `example.com` the entire honest answer was "there is a link called Learn
 * more", and on a form the copilot spent four calls guessing selectors
 * (`#result`, `p`, `body`, `p:last-of-type`) to find one sentence it had never
 * been shown. Watched, in words, both times.
 *
 * The script runs in a page and cannot be executed here, so this pins its
 * shape: that it reads the *rendered* text rather than `textContent`, that the
 * bound is applied and reported, and that the two constants the tool advertises
 * agree with the one it passes. A page-side behaviour test belongs with the
 * driver's own harness; what this catches is the change that quietly removes
 * the field again, which is the failure this repository keeps having.
 */
describe('the outline carries the page’s own words', () => {
  it('returns text and says whether it was cut', () => {
    expect(OUTLINE_SCRIPT).toContain('text:')
    expect(OUTLINE_SCRIPT).toContain('textTruncated:')
  })

  it('reads the body’s innerText, never its textContent', () => {
    // `body.textContent` would return every <script> and <style> body and every
    // hidden template on the page: enormous, and a description of the document
    // rather than of what anybody can see. The preamble's `line()` helper keeps
    // `textContent` as a per-element fallback and that is a different question
    // — hence the narrow assertion here rather than a ban on the word.
    expect(OUTLINE_SCRIPT).toContain('body.innerText')
    expect(OUTLINE_SCRIPT).not.toContain('body.textContent')
  })

  it('bounds the text by an argument rather than by a number baked into the page script', () => {
    // The bound has to be the caller's, or `textChars` on the tool is a control
    // that cannot act — the exact thing this audit was called to find.
    expect(OUTLINE_SCRIPT).toContain('args.textLimit')
    expect(OUTLINE_SCRIPT).toContain('slice(0, textLimit)')
  })

  it('keeps the head of the document, not the tail', () => {
    // The top of a page is its heading and its lede; the bottom is the footer.
    expect(OUTLINE_SCRIPT).not.toContain('slice(-textLimit)')
  })

  it('advertises a default inside its own ceiling', () => {
    expect(DEFAULT_OUTLINE_TEXT_CHARS).toBeLessThan(MAX_OUTLINE_TEXT_CHARS)
    // Roughly a thousand tokens — what `COPILOT-CAPABILITIES.md` §6 concludes a
    // whole-document overview is worth paying for.
    expect(DEFAULT_OUTLINE_TEXT_CHARS).toBeLessThanOrEqual(8_000)
  })
})
