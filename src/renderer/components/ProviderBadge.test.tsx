import { readFileSync } from 'node:fs'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ProviderBadge, hasProviderMark } from './ProviderBadge'

/**
 * The provider mark, actually rendered.
 *
 * A badge is all output, so a pure-logic test of it would be a test of nothing.
 * `react-dom/server` is what the other rendered tests in this folder use — there
 * is no DOM in this project's setup — and it is enough here because the badge
 * has no state, no effects and no bridge.
 *
 * What is worth pinning is not the path data. It is the four properties that
 * make this shippable in this app: nothing is fetched, the colour comes from
 * the text around it, an unknown agent draws nothing, and a mark that sits
 * beside its own name does not get announced twice.
 */

const html = (node: Parameters<typeof renderToStaticMarkup>[0]): string =>
  renderToStaticMarkup(node)

describe('what gets drawn', () => {
  it('draws a different mark for each agent', () => {
    const marks = (['claude', 'codex', 'gemini', 'shell'] as const).map((id) =>
      html(<ProviderBadge provider={id} />),
    )
    // Distinct, and distinct in the geometry rather than only in an attribute:
    // a badge that drew one shape with four labels would answer "which agent"
    // wrongly for three of them.
    const geometry = marks.map((markup) => markup.replace(/data-provider="[a-z]+"/, ''))
    expect(new Set(geometry).size).toBe(4)
  })

  it('draws nothing at all for an agent this build does not know', () => {
    /*
     * A session restored from a newer version, or a `list` frame from a desktop
     * running ahead of this one, can name an agent that did not exist when this
     * build shipped. Drawing a placeholder there would be a claim about which
     * service an account belongs to, and a wrong one — so the badge is absent
     * and the name beside it stands alone.
     */
    expect(html(<ProviderBadge provider="nosuchagent" />)).toBe('')
    expect(html(<ProviderBadge provider={null} />)).toBe('')
    expect(html(<ProviderBadge provider={undefined} />)).toBe('')
    expect(hasProviderMark('nosuchagent')).toBe(false)
    expect(hasProviderMark('claude')).toBe(true)
  })
})

describe('why this is safe to ship in this app', () => {
  it('fetches nothing, so the CSP has nothing to block and offline is unaffected', () => {
    for (const id of ['claude', 'codex', 'gemini', 'shell'] as const) {
      const markup = html(<ProviderBadge provider={id} />)
      expect(markup).not.toMatch(/https?:/)
      expect(markup).not.toMatch(/<image/)
      expect(markup).not.toMatch(/url\(/)
    }
  })

  it('takes its colour from the text it sits beside, so both themes are free', () => {
    /*
     * The house rule is that a colour must never be defined only inside
     * `[data-theme='dark']`. This satisfies it by defining no colour at all:
     * `currentColor` is whatever the surrounding label already resolved to, in
     * either theme, including on an accent-tinted row.
     */
    const markup = html(<ProviderBadge provider="gemini" />)
    expect(markup).toContain('currentColor')
    expect(markup).not.toMatch(/#[0-9a-fA-F]{3,8}/)
    expect(markup).not.toMatch(/rgb\(/)
  })
})

describe('what a screen reader hears', () => {
  it('is silent beside a label that already names the agent', () => {
    // The Add-account row draws the mark next to the words "Claude Code".
    // Announcing it would read the agent twice.
    const markup = html(<ProviderBadge provider="claude" />)
    expect(markup).toContain('aria-hidden="true"')
    expect(markup).not.toContain('<title>')
  })

  it('names the agent when it is the only thing there', () => {
    // The session toolbar shows the mark beside an account *name*, which says
    // nothing about which agent it is. There, the mark is the label.
    const markup = html(<ProviderBadge provider="codex" label="Codex CLI" />)
    expect(markup).toContain('<title>Codex CLI</title>')
    expect(markup).toContain('aria-label="Codex CLI"')
    expect(markup).not.toContain('aria-hidden')
  })
})

describe('sizing', () => {
  it('renders at the control metric by default and honours an override', () => {
    expect(html(<ProviderBadge provider="shell" />)).toContain('width="14"')
    expect(html(<ProviderBadge provider="shell" size={20} />)).toContain('width="20"')
    // One viewBox for every mark, so four different drawings sit at the same
    // optical weight beside 13px type whatever size they are rendered at.
    expect(html(<ProviderBadge provider="shell" size={20} />)).toContain('viewBox="0 0 16 16"')
  })
})

/* ------------------------------------------------------------ brand colour */

/**
 * The marks wear their own colours, and the colours live in one file.
 *
 * They were monochrome. Asad asked for *real provider logos in their real
 * colours*, and the reason he is right is that colour is what makes a mark
 * identify a service at 14px — a grey burst, a grey sparkle and a grey hexagon
 * are three grey shapes.
 *
 * The interesting constraint is *where* the values may live. `tokens.test.ts`
 * forbids `#d97757` in the token sheet, because that is Anthropic's brand
 * orange and this product used to wear it as its own accent. Identifying Claude
 * with it and being painted in it are different acts, and only the first one is
 * allowed — so the colour belongs to this component and nowhere else.
 */
describe('the brand colours', () => {
  const css = readFileSync(new URL('./ProviderBadge.css', import.meta.url), 'utf8')
  const tokens = readFileSync(
    new URL('../styles/tokens.css', import.meta.url),
    'utf8',
  )

  it('paints Claude in Anthropic’s clay and Gemini in Google’s blue', () => {
    expect(css).toMatch(/\[data-provider='claude'\][^}]*color:\s*#d97757/)
    expect(css).toMatch(/\[data-provider='gemini'\][^}]*color:\s*#4285f4/)
  })

  it('leaves Codex monochrome, because monochrome is what OpenAI’s mark is', () => {
    // Not an omission. Painting it something would be less accurate than
    // `currentColor`, which resolves to black on paper and white on the dark
    // chrome — exactly the two forms that mark ships in.
    expect(css).not.toContain("[data-provider='codex']")
    expect(html(<ProviderBadge provider="codex" />)).toContain('currentColor')
  })

  it('does not smuggle a brand colour into the app’s palette', () => {
    // The product must not wear Anthropic's orange. A mark identifying Claude
    // may; `tokens.css` may not, and `tokens.test.ts` enforces the other half
    // of this from the palette's side.
    expect(tokens.toLowerCase()).not.toMatch(/^\s*--[a-z-]+:\s*#d97757/m)
  })

  it('keeps the markup free of hex, so both themes stay one definition', () => {
    // The colour is applied by the stylesheet, not baked into the SVG, which is
    // what lets a mark on an accent-tinted row still inherit sensibly.
    expect(html(<ProviderBadge provider="claude" />)).not.toMatch(/#[0-9a-fA-F]{3,8}/)
  })
})
