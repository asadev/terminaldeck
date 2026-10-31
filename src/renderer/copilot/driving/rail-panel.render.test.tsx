import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { Sidebar } from '../../shell/Sidebar'
import { StoreProvider } from '../../state/store'
import type { WorkspaceTab } from '../../shell/workspace-tabs'
import { resetFrontPageForTests, setFrontPage } from '../../browser/front-page'
import { foldRailPanel, resetRailPanelForTests, setRailDrive } from './rail-panel'

/**
 * The panel in the rail's own column, as markup.
 *
 * Three claims that only a rendered rail can make, and all three are things
 * Asad watched go wrong on 2026-08-21:
 *
 *  1. **It replaces the rail's list rather than covering it.** That is a
 *     position in the tree, and a position is a thing a static render can be
 *     asked about — with the panel up there must be no "Open" heading and no
 *     session row underneath it to stick out beside it.
 *  2. **It starts at the Commander row.** Everything above that row — the
 *     gutter the traffic lights sit over, New session — is still in the markup.
 *  3. **Folded, the Commander row says where it went**, and the row is what
 *     brings it back.
 *
 * `react-dom/server`, like the rest of this window's tests — this project has no
 * DOM in its test setup, deliberately, so effects do not run and the panel is
 * rendered from the stores alone. That is enough for all three: every one of
 * them is a decision made during render.
 */

const noop = (): void => {}
const projects = [{ path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' }]

const tabs: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Fix the parser', projectPath: projects[0].path, closable: true },
]

function render(): string {
  return renderToStaticMarkup(
    <StoreProvider>
      <Sidebar
        width={264}
        projects={projects}
        tabs={tabs}
        activeTabId={null}
        activePanel={null}
        storage={null}
        copilot={{ stage: 'ready', state: null, name: 'Commander' }}
        onSelectTab={noop}
        onCloseTab={noop}
        onSelectPanel={noop}
        onNewSession={noop}
        onNewBrowserTab={noop}
        onOpenProject={noop}
        onCloseProject={noop}
        onOpenSettings={noop}
        onOpenAlerts={noop}
        onToggleCollapsed={noop}
        onPeekStart={noop}
        onPeekEnd={noop}
        onStartResize={noop}
      />
    </StoreProvider>,
  )
}

/** A drive on the page the window is showing — the one state that draws it. */
function driving(): void {
  setRailDrive({ state: 'agent', tabId: 'view-1', step: '', url: 'https://example.com/projects' })
  setFrontPage('b1', { tabId: 'b1', viewId: 'view-1' })
}

afterEach(() => {
  resetRailPanelForTests()
  resetFrontPageForTests()
})

describe('the rail with nothing driving', () => {
  it('is the rail', () => {
    const html = render()
    expect(html).toContain('>Open</h2>')
    expect(html).toContain('Fix the parser')
    expect(html).not.toContain('copilot-rail')
  })
})

describe('the rail while a driven page is in front', () => {
  it('draws the panel instead of the list, not over it', () => {
    /*
     * *"this should actually replace with this instead of coming in front of it
     * somehow."* The old panel was a fixed overlay at a token 264px over a rail
     * whose real width is a saved number, and f_0038–f_0047 caught the
     * consequence: a broken sliver of the rail — a globe, a ＋, a stray "AAAA"
     * label, the bell — showing beside it. Nothing of the list is rendered at
     * all now, so there is nothing left to stick out.
     */
    driving()
    const html = render()
    expect(html).toContain('copilot-rail')
    expect(html).not.toContain('>Open</h2>')
    expect(html).not.toContain('Fix the parser')
  })

  it('leaves the header above it alone', () => {
    /*
     * *"It will be starting from the first pill of commander, not from the top
     * with the top header also should not be covering it."* The old panel was
     * `top: 0` with a titlebar-sized pad, so its first line landed exactly where
     * New session sits and New session was in none of the frames.
     */
    driving()
    const html = render()
    const panel = html.indexOf('copilot-rail')
    expect(html.indexOf('sidebar-gutter')).toBeLessThan(panel)
    expect(html.indexOf('>New session</span>')).toBeLessThan(panel)
  })

  it('carries the control that folds it away', () => {
    driving()
    expect(render()).toContain('Fold this into the Commander row')
  })
})

describe('the rail once the panel is folded', () => {
  it('is the whole rail again, with the panel parked on the Commander row', () => {
    /*
     * *"If we collapse, it folds inside here… It should close inside the this
     * commander's pill."* The old put-away recorded a tab id and the panel
     * simply vanished — nothing on screen said where it had gone or how to get
     * it back.
     */
    driving()
    foldRailPanel()
    const html = render()
    expect(html).not.toContain('copilot-rail')
    expect(html).toContain('>Open</h2>')
    expect(html).toContain('data-copilot-parked')
    expect(html).toContain('Commander’s panel is folded in here')
  })

  it('says nothing about a fold on a page that could not undo it', () => {
    /*
     * *"But if I am not on the browser window, it will not open, only on the
     * browser window."* On any other screen the Commander row is what it has
     * always been — the way to open the copilot's window — because a row that
     * sometimes navigates and sometimes summons a panel, with nothing saying
     * which, is worse than two rows.
     */
    driving()
    foldRailPanel()
    setFrontPage('b1', null)
    const html = render()
    expect(html).not.toContain('data-copilot-parked')
    expect(html).toContain('>Open</h2>')
  })
})
