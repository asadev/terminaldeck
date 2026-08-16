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
