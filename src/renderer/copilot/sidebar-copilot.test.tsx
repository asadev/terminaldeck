import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar } from '../shell/Sidebar'
import { StoreProvider } from '../state/store'
import type { WorkspaceTab } from '../shell/workspace-tabs'

/**
 * The rail, with the copilot in it.
 *
 * Two claims that only a rendered rail can make:
 *
 *  1. **The pinned row is above the session list, not inside it.** In markup
 *     that is a position, and a position is a thing a static render can be
 *     asked about — the Copilot row's index in the string has to be lower than
 *     the "Open" heading's and lower than any session row's.
 *  2. **A session the copilot started is not in your project's run.** This is
 *     the one that would fail silently if the grouping were undone: the row
 *     would still be drawn, still be clickable, still be correct in every
 *     respect except that nobody could tell it apart from a session they
 *     started themselves.
 *
 * `react-dom/server`, like the rest of this window's tests — this project has
 * no DOM in its test setup, deliberately.
 */

const noop = (): void => {}
const projects = [{ path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' }]

const tabs: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Fix the parser', projectPath: projects[0].path, closable: true },
  {
    id: 's2',
    kind: 'session',
    label: 'Review the diff',
    projectPath: projects[0].path,
    origin: 'copilot',
    originRunId: 'turn-9',
    closable: true,
  },
  {
    id: 's3',
    kind: 'session',
    label: 'Overnight sweep',
    projectPath: projects[0].path,
    origin: 'copilot',
    closable: true,
  },
]

function render(over: Partial<Parameters<typeof Sidebar>[0]> = {}): string {
  return renderToStaticMarkup(
    <StoreProvider>
      <Sidebar
        width={264}
        projects={projects}
        tabs={tabs}
        activeTabId={null}
        activePanel={null}
        storage={null}
        copilot={{ stage: 'ready', state: null }}
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
        {...over}
      />
    </StoreProvider>,
  )
}

describe('the pinned entry', () => {
  const html = render()

  it('is above the views and above what you have open', () => {
    const copilot = html.indexOf('>Copilot</span>')
    expect(copilot).toBeGreaterThan(-1)
    expect(copilot).toBeLessThan(html.indexOf('>Overview</span>'))
    expect(copilot).toBeLessThan(html.indexOf('>Open</h2>'))
    expect(copilot).toBeLessThan(html.indexOf('Fix the parser'))
  })

  it('is drawn even with no copilot described, and claims nothing then', () => {
    const quiet = render({ copilot: null })
    expect(quiet).toContain('>Copilot</span>')
    // No dot, because nothing has been read. The row still navigates.
    expect(quiet.slice(0, quiet.indexOf('>Overview</span>'))).not.toContain('status-dot')
  })
})

describe('sessions the copilot started', () => {
  const html = render()

  it('are under their own heading', () => {
    expect(html).toContain('>Copilot sessions</h2>')
  })

  it('are not in the project run with the sessions you started', () => {
    const open = html.indexOf('>Open</h2>')
    const group = html.indexOf('>Copilot sessions</h2>')
    expect(group).toBeGreaterThan(open)
    // "Fix the parser" is yours and sits in the project run; both copilot
    // sessions are past the heading.
    expect(html.indexOf('Fix the parser')).toBeLessThan(group)
    expect(html.indexOf('Review the diff')).toBeGreaterThan(group)
    expect(html.indexOf('Overnight sweep')).toBeGreaterThan(group)
  })

  it('offer "why does this exist" only where there is a turn to open', () => {
    const withLink = render({ onOpenCopilot: noop })
    expect(withLink).toContain('Why Review the diff exists')
    // The restored one carries its origin and no run id, so no button — a
    // control that lands nowhere is worse than an absent one.
    expect(withLink).not.toContain('Why Overnight sweep exists')
  })

  it('draws no heading when the copilot has started nothing', () => {
    expect(render({ tabs: [tabs[0]] })).not.toContain('Copilot sessions')
  })

  it('numbers a session still wearing its folder name instead of printing the folder', () => {
    /*
     * The group is one flat run that can span folders, so it has no single
     * heading for a folder name to be redundant with — and without a folder
     * name per row, `sessionLabel` decides the untitled session's own folder
     * name is worth showing. The rail then read **terminaldeck** while the
     * copilot's page, which numbers the same session, read **Session 1**. One
     * session, two names, twenty pixels apart. Found by looking at it.
     */
    const untitled: WorkspaceTab = {
      id: 's9',
      kind: 'session',
      label: 'terminaldeck',
      projectPath: projects[0].path,
      origin: 'copilot',
      closable: true,
    }
    const html = render({ tabs: [untitled] })
    const group = html.indexOf('>Copilot sessions</h2>')
    expect(html.slice(group)).toContain('>Session 1</span>')
    expect(html.slice(group)).not.toContain('>terminaldeck</span>')
  })
})
