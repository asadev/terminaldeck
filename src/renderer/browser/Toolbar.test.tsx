import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Toolbar } from './Toolbar'
import { newTab, type WorkspaceTab } from './tabs'

/**
 * The Shared / Isolated switch, checked as markup.
 *
 * There is no DOM in this project's test setup, so this holds the control's
 * accessible shape rather than its behaviour — which is the half that has to be
 * right anyway. The state it reports decides whether the tab can see the
 * cookies imported from Chrome, so a switch that renders the wrong word, or
 * renders nothing at all when it cannot work, is the whole bug.
 */

function render(tab: WorkspaceTab | null, onToggleIsolation?: () => void): string {
  return renderToStaticMarkup(
    <Toolbar
      tab={tab}
      security="local"
      progress={1}
      resolution={{ kind: 'url', url: 'http://localhost:3000/', display: 'localhost:3000' }}
      focusToken={0}
      onDraft={() => {}}
      onEditing={() => {}}
      onSubmit={() => {}}
      onBack={() => {}}
      onForward={() => {}}
      onReload={() => {}}
      onStop={() => {}}
      onHome={() => {}}
      onInspect={() => {}}
      onRecord={() => {}}
      onScreenshot={() => {}}
      onDevtools={() => {}}
      devtoolsOpen={false}
      recording={false}
      deviceOpen={false}
      onToggleDevice={() => {}}
      onOpenSession={() => {}}
      onToggleIsolation={onToggleIsolation}
    />,
  )
}

describe('the isolation toggle', () => {
  it('says Shared for an ordinary tab', () => {
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).toContain('Session: Shared')
    expect(markup).toContain('>Shared<')
    expect(markup).toContain('aria-pressed="false"')
  })

  it('says Isolated for an isolated tab, and says so where a reader can find it', () => {
    const markup = render(newTab('tab-1', '', true), () => {})
    expect(markup).toContain('Session: Isolated')
    expect(markup).toContain('>Isolated<')
    expect(markup).toContain('aria-pressed="true"')
  })

  it('explains what switching costs, because it reopens the page', () => {
    const markup = render(newTab('tab-1', '', true), () => {})
    expect(markup).toMatch(/reopens the page/)
  })

  it('stays on screen and disabled when the preload has not wired it', () => {
    // Hiding it would read as "this app has no isolation", which is a different
    // and worse claim than "this build cannot do it".
    const markup = render(newTab('tab-1'))
    expect(markup).toContain('Session: Shared')
    expect(markup).toContain('not available in this build')
    expect(markup).toContain('disabled')
  })

  it('is disabled with no tab open', () => {
    expect(render(null, () => {})).toContain('disabled')
  })
})
