import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AccountProviderList, buildAccountProviderRows, chosenAccountProvider } from './ProviderPicker'

/**
 * The Add-account agent list, actually drawn.
 *
 * Two of the things this list exists to do are invisible to a logic test,
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
 * ## First paint, deliberately
 *
 * The rows are built from `buildAccountProviderRows(null)` — the catalogue with
 * nothing detected and nothing yet heard from the main process, which is
 * exactly the state the Accounts pane draws in before either IPC answers. That
 * is the moment the renderer's own copy of "which agents can hold an account"
 * is doing all the work, and precisely the moment a wrong copy would let
 * somebody click Gemini. `ProviderPicker.test.ts` pins that copy against the
 * main process's table; this pins what it puts on screen.
 *
 * `renderToStaticMarkup` like every render test in this project — there is no
 * DOM in the setup, and this list needs none: it portals nowhere and its
 * selection is computed rather than settled by an effect.
 */

const ROWS = buildAccountProviderRows(null)

const markup = (): string =>
  renderToStaticMarkup(
    <AccountProviderList
      group="agent"
      rows={ROWS}
      selected={chosenAccountProvider(ROWS, null)?.id ?? null}
      onSelect={() => undefined}
    />,
  )

describe('the first paint of the Add-account agent list', () => {
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
    // Three rows would share one shape if the badge fell back to a placeholder,
    // so the count is what is checked rather than the presence of any svg.
    const html = markup()
    const badges = html.match(/class="provider-badge"/g) ?? []
    expect(badges).toHaveLength(3)
    expect(html).toContain('data-provider="claude"')
    expect(html).toContain('data-provider="codex"')
    expect(html).toContain('data-provider="gemini"')
  })

  it('arrives with an addable agent already selected', () => {
    /*
     * The one that is only true because the selection is computed rather than
     * stored. An effect does not run under SSR and does not run before the
     * first paint in a browser either, so a selection settled by one would
     * leave this render — the render a person actually sees first — with no
     * row chosen and Add disabled over a list that looks ready.
     */
    expect(markup()).toMatch(/<input[^>]*checked[^>]*value="claude"/)
  })
})
