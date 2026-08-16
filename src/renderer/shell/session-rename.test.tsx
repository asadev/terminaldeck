import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar } from './Sidebar'
import { StoreProvider } from '../state/store'
import type { WorkspaceTab } from './workspace-tabs'

/**
 * The rename, as far as a static render can see it.
 *
 * Reported walking the app: **"a session's name cannot be edited."** The rule
 * behind the fix — that a name somebody typed is never overwritten by one the
 * app derived — is pinned in `state/store.test.ts`, where it can be driven
 * directly. What is left for here is the half that lives in markup: that the
 * affordance is on the row at all, that it is on the right rows, and that it
 * carries a name a person can read or hear.
 *
 * `react-dom/server`, like the rest of this window's tests — this project has
 * no DOM in its test setup. So the *field* cannot be opened here: it appears on
 * a click, and there is nothing to click. `Sidebar.tsx` holds the field's own
 * reasoning; what a test can hold is that the way in exists.
 */

const noop = (): void => {}

const projects = [{ path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' }]

const tabs: WorkspaceTab[] = [
  {
    id: 's1',
    kind: 'session',
    label: 'Fix the parser',
    projectPath: projects[0].path,
    closable: true,
  },
  { id: 'b1', kind: 'browser', label: 'localhost:3000', closable: true },
]

function render(inStore: boolean): string {
  const rail = (
    <Sidebar
      width={264}
      projects={projects}
      tabs={tabs}
      activeTabId={null}
      activePanel={null}
      onSelectTab={noop}
      onCloseTab={noop}
      onSelectPanel={noop}
      onNewSession={noop}
      onNewBrowserTab={noop}
      onOpenProject={noop}
      onCloseProject={noop}
      onOpenSettings={noop}
      onToggleCollapsed={noop}
      onPeekStart={noop}
      onPeekEnd={noop}
      onStartResize={noop}
    />
  )
  return renderToStaticMarkup(inStore ? <StoreProvider>{rail}</StoreProvider> : rail)
}

describe('renaming a session from the rail', () => {
  const html = render(true)

  it('offers a rename on the session row', () => {
    expect(html, 'the session row has no way into a rename').toContain(
      'aria-label="Rename Fix the parser"',
    )
  })

  it('gives it a name rather than leaving a bare glyph', () => {
    // The rail's actions are icons, so the accessible name is the only name
    // they have — and it says which row it belongs to, because three sessions
    // in one project produce three of these buttons.
    const rename = /<button[^>]*class="sb-row-action sb-rename"[^>]*>/.exec(html)?.[0] ?? ''
    expect(rename).not.toBe('')
    expect(rename).toMatch(/aria-label="Rename [^"]+"/)
    expect(rename).toMatch(/title="Rename [^"]+"/)
  })

  it('does not offer one on a browser tab', () => {
    /*
     * A browser tab is named by the page it is showing, and the next navigation
     * would overwrite anything typed here. Offering a rename that the app
     * intends to undo is worse than not offering one — it is the same failure
     * as the auto-titler eating a session's name, just with the app's own
     * behaviour as the culprit rather than a missing flag.
     */
    expect(html).toContain('aria-label="Close localhost:3000"')
    expect(html).not.toContain('aria-label="Rename localhost:3000"')
  })

  it('sits beside the close button rather than replacing it', () => {
    // Renaming must not cost the row its close. Both are hover-only actions on
    // the same row, and the order is rename-then-close so the destructive one
    // stays furthest from the label.
    expect(html.indexOf('sb-rename')).toBeGreaterThan(0)
    expect(html.indexOf('sb-rename')).toBeLessThan(html.indexOf('sb-close'))
  })
})

describe('outside a session list', () => {
  it('draws no rename at all rather than a dead one', () => {
    /*
     * The rail renders on its own in `.harness/` and in the tests next door,
     * where there is no store to write a name into. A button that highlights on
     * hover and does nothing is the one thing this window is not allowed to
     * have, so the affordance is absent instead — see `useSessionRename`.
     */
    const alone = render(false)
    expect(alone).toContain('aria-label="Close Fix the parser"')
    expect(alone).not.toContain('sb-rename')
  })
})
