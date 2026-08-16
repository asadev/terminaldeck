import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ModeSwitch } from './ModeSwitch'
import { FolderChip, folderLabel } from './FolderChip'
import { AccountChip } from './AccountChip'
import { WindowToolbar } from './WindowToolbar'
import { Sidebar } from './Sidebar'
import { PANELS } from './panels'
import { placeMenu } from './chip-menu'
import { accountsWorthShowing, type WorkspaceTab } from './workspace-tabs'

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

describe('AccountChip', () => {
  /**
   * The other half of the same line: the folder chip says *where* a session
   * runs, this says *who* it runs as. Both were asked for together — "I can
   * choose any of my logged in account and the folder and I can start a new
   * session" — and the promise this one must not break is the same one the
   * folder chip keeps: it starts a session, it does not switch the running one.
   *
   * There is no bridge in a test process, so the list is empty here and the
   * chip renders its closed state. That is deliberately the case worth pinning
   * — an account name on the button before anything has been read would be a
   * name the app invented.
   */
  const html = renderToStaticMarkup(
    <AccountChip
      current={{ id: 'work', name: 'Work' }}
      projectPath={projects[0].path}
      onPick={noop}
      onManage={noop}
    />,
  )

  it('names the account the session on screen is actually running as', () => {
    expect(html).toContain('Work')
  })

  it('is closed until it is asked for', () => {
    expect(html).toContain('aria-expanded="false"')
    expect(html).not.toContain('folder-menu')
  })

  it('says what the button does without implying the session will change', () => {
    // A process's environment cannot be rewritten after it starts, so the
    // account of a running session is fixed for its life. Copy that suggested
    // otherwise would be promising a switch that can only be done by killing a
    // session that may have work in it.
    expect(html).toContain('start one under a different account')
    for (const lie of ['Switch this session', 'Change account of', 'Move this session']) {
      expect(html).not.toContain(lie)
    }
  })

  it('says nothing about an account when there is no session and nothing loaded', () => {
    const empty = renderToStaticMarkup(
      <AccountChip current={null} projectPath={null} onPick={noop} onManage={noop} />,
    )
    // The neutral word, not a guessed name — the list has not been read yet.
    expect(empty).toContain('>Account<')
  })

  /**
   * An account is a `CLAUDE_CONFIG_DIR` handed to the agent at spawn, so it
   * means nothing to an agent that does not read one. With the default coding
   * tool set to Plain shell — a setting, not an edge case — this menu used to
   * offer the accounts anyway: the click started a session, `host-core.ts`
   * correctly declined to label it, and the chip snapped back to the default
   * account's name having said nothing at all.
   *
   * The closed button is all a static render can see, so that is what these
   * pin: the tooltip is the chip's one line of explanation before the menu is
   * ever opened, and it has to change with the agent.
   */
  it('explains itself on the button when the agent has no login to isolate', () => {
    for (const [provider, expected] of [
      // "A shell has no login to sign in to", not the older "no login to
      // isolate". The copy pass replaced the mechanism (isolating a config
      // directory) with the consequence, which is the standard the whole
      // settings sweep was edited to. The assertion follows the shipped copy
      // rather than the copy being reverted to satisfy it.
      ['shell', 'no login to sign in to'],
      // Gemini is the interesting one, and its sentence is not "only apply to
      // Claude" any more because that was never the real reason. `GEMINI_CLI_HOME`
      // exists and moves settings — what it does not move is the OAuth token,
      // which goes to the OS keychain under two constants that never read the
      // home. So two "accounts" address one keychain item and `setPassword`
      // overwrites: signing into a second would not share the first login, it
      // would destroy it. That is why it is refused rather than offered.
      ['gemini', 'a second account cannot be pointed at'],
      // `codex` is deliberately NOT in this list any more — see the test below.
    ] as const) {
      const blocked = renderToStaticMarkup(
        <AccountChip
          current={null}
          projectPath={projects[0].path}
          provider={provider}
          onPick={noop}
          onManage={noop}
        />,
      )
      expect(blocked, provider).toContain(expected)
      // The promise it must not still be making while the choice cannot land.
      expect(blocked, provider).not.toContain('Choose which account a new session here uses')
    }
  })

  /*
   * It is two agents now, not one, and that is the point of this test.
   *
   * Codex was refused accounts here on the grounds that it "ships as a shim
   * around a native binary that is not present on this machine" — true of the
   * npm package, whose vendored directory holds `rg` and nothing else, so
   * `codex --version` throws ENOENT. That got read as "the mechanism does not
   * exist". It does: `CODEX_HOME` moves the login, verified against the real
   * CLI — one binary, three homes, one "Logged in using ChatGPT" and two "Not
   * logged in" — and the credential is a plain `auth.json` inside it, so it
   * moves with the directory by construction rather than by policy.
   *
   * So this asserts the pair, and a wrong answer for either is a real
   * regression: dropping Claude breaks the feature, and dropping Codex silently
   * returns Asad to the thing he asked to have fixed — every "add an account"
   * sending him to a Claude login when he wanted ChatGPT.
   */
  it('keeps the ordinary invitation for the agents whose login can be isolated', () => {
    for (const provider of ['claude', 'codex'] as const) {
      const invited = renderToStaticMarkup(
        <AccountChip
          current={null}
          projectPath={projects[0].path}
          provider={provider}
          onPick={noop}
          onManage={noop}
        />,
      )
      expect(invited, provider).toContain('Choose which account a new session here uses')
      expect(invited, provider).not.toContain('no login to sign in to')
      expect(invited, provider).not.toContain('cannot be pointed at')
    }
  })
})

describe('placeMenu', () => {
  const viewport = { width: 1200, height: 800 }

  it('hangs the menu under its button', () => {
    const at = placeMenu({ left: 100, top: 40, bottom: 58 }, { width: 300, height: 200 }, viewport)
    expect(at.top).toBe(58 + 8)
    expect(at.left).toBe(96)
  })

  it('keeps a menu near the right edge inside the window', () => {
    const at = placeMenu({ left: 1150, top: 40, bottom: 58 }, { width: 300, height: 200 }, viewport)
    expect(at.left + 300).toBeLessThanOrEqual(viewport.width)
  })

  it('flips above only when there is genuinely no room below', () => {
    // A menu that flips on a window one pixel too short is worse than one that
    // is a little tight at the bottom.
    const tight = placeMenu({ left: 20, top: 700, bottom: 718 }, { width: 300, height: 300 }, viewport)
    expect(tight.top).toBeLessThan(700)
    const roomy = placeMenu({ left: 20, top: 40, bottom: 58 }, { width: 300, height: 300 }, viewport)
    expect(roomy.top).toBe(66)
  })
})

describe('accountsWorthShowing', () => {
  const session = (id: string, account?: { id: string; name: string }): WorkspaceTab => ({
    id,
    kind: 'session',
    label: id,
    projectPath: '/w/app',
    closable: true,
    ...(account ? { account } : {}),
  })
  const work = { id: 'work', name: 'Work' }
  const home = { id: 'home', name: 'Home' }

  it('stays quiet while every session is on the same account', () => {
    // A label that appears on every row carries no information, and this is the
    // ordinary install.
    expect(accountsWorthShowing([session('a', work), session('b', work)])).toBe(false)
  })

  it('speaks up the moment two accounts are in play', () => {
    // Two sessions in one folder under two logins are otherwise the same row
    // twice, which is exactly what a person must not have to guess about.
    expect(accountsWorthShowing([session('a', work), session('b', home)])).toBe(true)
  })

  it('does not count a session that has no account', () => {
    // A plain shell tab is not a disagreement about accounts; letting it flip
    // every row into carrying a name would make the label mean "you opened a
    // shell".
    expect(accountsWorthShowing([session('a', work), session('b')])).toBe(false)
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

  it('tells two sessions in one folder apart by their account', () => {
    /*
     * The case this exists for: the same folder, the same status dot, the same
     * derived title — and two different logins. Without the account on the row
     * the two are the same row twice, and picking the wrong one is the mistake
     * the whole feature exists to prevent.
     */
    const twoAccounts = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={[
          {
            id: 's1',
            kind: 'session',
            label: 'Fix the parser',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work' },
            closable: true,
          },
          {
            id: 's2',
            kind: 'session',
            label: 'Fix the parser',
            projectPath: projects[0].path,
            account: { id: 'home', name: 'Home' },
            closable: true,
          },
        ]}
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
      />,
    )
    expect(twoAccounts).toContain('class="sb-account">Work<')
    expect(twoAccounts).toContain('class="sb-account">Home<')
    expect(twoAccounts).toContain('signed in as Work')
  })

  it('says nothing about accounts while there is only one', () => {
    const oneAccount = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={[
          {
            id: 's1',
            kind: 'session',
            label: 'Fix the parser',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work' },
            closable: true,
          },
        ]}
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
      />,
    )
    expect(oneAccount).not.toContain('sb-account')
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
