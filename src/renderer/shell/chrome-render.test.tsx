import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ModeSwitch } from './ModeSwitch'
import { FolderChip, folderLabel } from './FolderChip'
import { WindowToolbar } from './WindowToolbar'
import { Sidebar } from './Sidebar'
import { PANELS } from './panels'

/**
 * The window chrome, actually rendered.
 *
 * What these pin is not layout — a static string cannot see a layout — but the
 * handful of promises the chrome makes in its markup, each of which was broken
 * at some point in the design this replaced:
 *
 *   1. Every control in the top-right is a *word*. The toolbar had collected
 *      four unlabelled glyph buttons, which is the thing the brief singles out
 *      as unreadable by someone who has never used the app.
 *   2. There is exactly one control that opens and closes the sidebar, and it
 *      lives beside the window buttons in both states — in the rail's gutter
 *      when the rail is out, in the toolbar when it is away. Two of them, or
 *      one that moves, is what this replaced.
 *   3. The folder chip says what it does. It starts a session somewhere; it
 *      does not move the one you are in, and the copy must not imply that it
 *      does, because the app cannot tell whether that would lose work.
 *
 * `react-dom/server`, like every other render test here: this project has no
 * DOM in its test setup, deliberately.
 */

const noop = (): void => {}

const projects = [
  { path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' },
  { path: '/Users/apple/Projects/science-locus', name: 'science-locus' },
]

describe('ModeSwitch', () => {
  const html = renderToStaticMarkup(<ModeSwitch mode="terminal" onChange={noop} />)

  it('offers the three things the window can be doing', () => {
    for (const label of ['Terminal', 'Chat', 'Split']) expect(html).toContain(`>${label}<`)
  })

  it('says which one is on', () => {
    expect(html).toContain('aria-pressed="true"')
    // One on, two off. A segmented control where nothing is pressed is a row of
    // buttons, and the shape stops meaning "the same work, shown differently".
    expect(html.match(/aria-pressed="true"/g)).toHaveLength(1)
    expect(html.match(/aria-pressed="false"/g)).toHaveLength(2)
  })

  it('has no unlabelled button in it', () => {
    // Every segment carries its own text, so none of them needs an aria-label —
    // what would fail here is a glyph creeping back in.
    for (const mode of ['terminal', 'chat', 'split'] as const) {
      expect(renderToStaticMarkup(<ModeSwitch mode={mode} onChange={noop} />)).not.toContain('<svg')
    }
  })

  it('moves the pressed segment with the mode', () => {
    const split = renderToStaticMarkup(<ModeSwitch mode="split" onChange={noop} />)
    const pressed = /<button[^>]*aria-pressed="true"[^>]*>([^<]+)</.exec(split)?.[1]
    expect(pressed).toBe('Split')
  })
})

describe('FolderChip', () => {
  const html = renderToStaticMarkup(
    <FolderChip path={projects[0].path} options={projects} onPick={noop} onBrowse={noop} />,
  )

  it('shows the folder rather than the whole path', () => {
    expect(html).toContain('terminaldeck')
    expect(html).not.toContain('>/Users/apple/Projects/terminaldeck<')
  })

  it('carries the full path where there is room for it', () => {
    // The button is one word wide and two projects called `web` is not an
    // unusual thing to have open, so the title is the disambiguator.
    expect(html).toContain('title="/Users/apple/Projects/terminaldeck')
  })

  it('sets the path in the mono face, because a path is data', () => {
    // The rule is `.folder-chip-path` in shell.css. What is pinned here is that
    // the element keeps the hook — there is a bare `mono` class in the
    // dashboard's stylesheet and it is scoped to that file, so borrowing the
    // name here would have styled nothing at all.
    expect(html).toContain('class="folder-chip-path"')
  })

  it('is closed until it is asked for', () => {
    expect(html).not.toContain('folder-menu')
    expect(html).toContain('aria-expanded="false"')
  })

  it('never claims it will move the running session', () => {
    /*
     * The honest wording, pinned. A pty has one working directory for its whole
     * life, and the renderer cannot see what has been typed into it — keystrokes
     * go from xterm straight to the process — so "nothing has been typed yet" is
     * not a fact this app has. Copy that says "move" or "change the folder"
     * would be promising something that can only be delivered by killing a
     * session that may have work in it.
     */
    for (const lie of ['Move', 'move this', 'Change folder', 'Switch this session']) {
      expect(html).not.toContain(lie)
    }
  })

  it('names the last segment of a path on either platform', () => {
    expect(folderLabel('/Users/apple/Projects/terminaldeck')).toBe('terminaldeck')
    expect(folderLabel('C:\\work\\app')).toBe('app')
    expect(folderLabel('/trailing/slash/')).toBe('slash')
  })
})

describe('WindowToolbar', () => {
  const shown = renderToStaticMarkup(
    <WindowToolbar
      title="Wire up split panes"
      sidebarHidden={false}
      onRevealSidebar={noop}
      onEdgeEnter={noop}
    >
      <ModeSwitch mode="terminal" onChange={noop} />
    </WindowToolbar>,
  )
  const hidden = renderToStaticMarkup(
    <WindowToolbar
      title="Wire up split panes"
      sidebarHidden
      onRevealSidebar={noop}
      onEdgeEnter={noop}
    >
      <ModeSwitch mode="terminal" onChange={noop} />
    </WindowToolbar>,
  )

  it('keeps no sidebar control while the rail is on screen', () => {
    // The rail's own gutter has it, beside the traffic lights. Two controls for
    // one thing is what this replaced.
    expect(shown).not.toContain('Show sidebar')
  })

  it('brings one back, and only one, once the rail is away', () => {
    expect(hidden).toContain('aria-label="Show sidebar"')
    expect(hidden.match(/aria-label="Show sidebar"/g)).toHaveLength(1)
  })

  it('reserves the traffic lights their room only when they are on it', () => {
    expect(hidden).toContain('data-sidebar-collapsed="true"')
    expect(shown).not.toContain('data-sidebar-collapsed')
  })

  it('gives the right-hand side to the mode switch and nothing else', () => {
    const actions = /<div class="toolbar-actions">([\s\S]*?)<\/header>/.exec(shown)?.[1] ?? ''
    expect(actions).toContain('mode-switch')
    expect(actions).not.toContain('<svg')
  })
})

describe('Sidebar', () => {
  const html = renderToStaticMarkup(
    <Sidebar
      width={264}
      projects={projects}
      tabs={[]}
      activeTabId={null}
      activePanel={null}
      update={<div className="upd-banner">Version 0.1.7 is available</div>}
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
    />,
  )

  it('puts the one open/close control in the gutter, with the window buttons', () => {
    expect(html).toContain('sidebar-gutter')
    expect(html).toContain('class="sidebar-arrow"')
    expect(html.match(/class="sidebar-arrow"/g)).toHaveLength(1)
  })

  it('reads as "keep this open" while it is only being peeked at', () => {
    const peeked = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={[]}
        tabs={[]}
        activeTabId={null}
        activePanel={null}
        peeking
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
      />,
    )
    expect(peeked).toContain('aria-label="Keep the sidebar open"')
    expect(peeked).toContain('data-peek="true"')
    expect(html).toContain('aria-label="Hide the sidebar"')
  })

  it('carries the update notice above Settings, at the foot', () => {
    const foot = /class="sidebar-foot">([\s\S]*?)<div\s+class="sidebar-resize"/.exec(html)?.[1] ?? ''
    expect(foot, 'the foot was not found — has the sidebar changed shape?').not.toBe('')
    expect(foot.indexOf('upd-banner')).toBeGreaterThanOrEqual(0)
    expect(foot.indexOf('upd-banner')).toBeLessThan(foot.indexOf('Settings'))
  })

  it('puts Alerts down there too, and out of the toolbar', () => {
    const foot = /class="sidebar-foot">([\s\S]*?)<div\s+class="sidebar-resize"/.exec(html)?.[1] ?? ''
    expect(foot).toContain('Alerts')
    expect(foot.indexOf('Alerts')).toBeLessThan(foot.indexOf('Settings'))
  })

  it('renders every panel exactly once, wherever it belongs', () => {
    /*
     * The trap this catches: `foot` is a group the scrolling list deliberately
     * does not render, so a view moved into it is drawn by a different loop.
     * Getting that wrong draws Alerts twice, or not at all — and the "not at
     * all" version still passes `reachable.test.ts`, because the panel does
     * have a case in `PanelView`; it just has no row anybody can click.
     */
    for (const panel of PANELS) {
      const rows = html.match(new RegExp(`>${panel.label}</span>`, 'g')) ?? []
      expect(rows, `${panel.id} appears ${rows.length} times in the sidebar`).toHaveLength(1)
    }
  })
})
