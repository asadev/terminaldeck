import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

/**
 * The Add-account dialog, actually drawn.
 *
 * Two of the things this dialog exists to do are invisible to a logic test,
 * because they are about what a person sees on first paint:
 *
 *  1. **Gemini is on screen, disabled, with its reason next to it.** The whole
 *     risk of refusing an agent is that the refusal looks like an oversight —
 *     Gemini has a config-directory variable, so somebody will reasonably
 *     assume the app forgot it. A logic test can assert `canAdd === false`; it
 *     cannot assert that the sentence explaining why is rendered.
 *  2. **The mark is beside each agent's name.** That is the request this whole
 *     change came from, and a badge that renders nothing renders nothing very
 *     quietly.
 *
 * ## Its own file, and the harness
 *
 * `ProviderPicker.test.ts` is a `.ts` and cannot hold JSX, and
 * `dialog-render.test.tsx` belongs to the session dialogs. So this sits beside
 * the component it renders. There is no DOM in this project's setup, so it
 * renders through `react-dom/server` exactly as those two do: `Modal` portals
 * into `document.body`, which neither exists nor survives SSR, so the portal is
 * swapped for a passthrough and `document` is stubbed to the one property that
 * call site reads.
 *
 * Effects do not run under SSR, which is the point rather than a limitation:
 * what is asserted below is the first paint, *before* `detectProviders` or
 * `profiles:account-providers` has answered. That is precisely the moment the
 * catalogue's own copy of "which agents can hold an account" is doing the work,
 * and precisely the moment a wrong copy would let somebody click Gemini.
 */

vi.mock('react-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-dom')>()
  return { ...actual, createPortal: (node: ReactNode) => node }
})

// The stubbed portal ignores its container, so this only has to exist.
;(globalThis as { document?: unknown }).document = { body: {} }

const { AccountProviderPicker } = await import('./ProviderPicker')

const markup = (): string =>
  renderToStaticMarkup(
    <AccountProviderPicker
      open
      onClose={() => undefined}
      onPick={() => undefined}
    />,
  )

describe('the first paint of the Add-account dialog', () => {
  it('asks which agent, before asking anything else', () => {
    const html = markup()
    expect(html).toContain('Add an account')
    expect(html).toContain('Which agent is this a login for?')
  })

  it('shows every agent that can hold an account', () => {
    const html = markup()
    expect(html).toContain('Claude Code')
    expect(html).toContain('Codex CLI')
  })

  it('shows Gemini disabled, with the reason beside it', () => {
    const html = markup()
    expect(html).toContain('Gemini CLI')
    expect(html).toContain('one login per machine')
    // Disabled and marked as such, not merely styled: the radio itself has to
    // refuse, or a keyboard user reaches it with an arrow key. Matched on the
    // whole `<input>` rather than on an attribute order React does not promise.
    expect(html).toMatch(/<input[^>]*disabled[^>]*value="gemini"/)
    expect(html).toMatch(/<input[^>]*value="claude"(?![^>]*disabled)/)
    expect(html).toContain('One login only')
  })

  it('leaves the shell out, because there is nothing to explain', () => {
    expect(markup()).not.toContain('value="shell"')
  })

  it('draws a mark beside each agent', () => {
    // Four rows would share one shape if the badge fell back to a placeholder,
    // so the count is what is checked rather than the presence of any svg.
    const html = markup()
    const badges = html.match(/class="provider-badge"/g) ?? []
    expect(badges).toHaveLength(3)
    expect(html).toContain('data-provider="claude"')
    expect(html).toContain('data-provider="codex"')
    expect(html).toContain('data-provider="gemini"')
  })
})
