import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ModeSwitch } from './ModeSwitch'
import { FolderTitle, folderLabel } from './FolderChip'
import { AccountChip } from './AccountChip'
import { WindowToolbar } from './WindowToolbar'
import { Sidebar } from './Sidebar'
import { PANELS } from './panels'
import { placeMenu } from './chip-menu'
import {
  ACCOUNT_NEEDS_RAIL,
  accountsWorthShowing,
  machineTabId,
  tabIdentities,
  tabQualifiers,
  type WorkspaceTab,
} from './workspace-tabs'

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
 *   3. The folder is a title and not a control, and it says why. A pty has one
 *      working directory for its whole life, so a menu there could only ever
 *      offer to start a *different* session — and a chevron that implies
 *      otherwise is the app promising something it cannot do.
 *   4. A name is never cut down to make room for a caption beside it. That is
 *      how the rail came to print `S…`.
 *
 * `react-dom/server`, like every other render test here: this project has no
 * DOM in its test setup, deliberately.
 */

const noop = (): void => {}

const projects = [
  { path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' },
  { path: '/Users/apple/Projects/science-locus', name: 'science-locus' },
]

/**
 * One icon button, where there were three words and then two icons.
 *
 * Rule 1 above — *every control in the top-right is a word* — is the one thing
 * this no longer keeps, and the exception is deliberate rather than a
 * regression: Asad asked for it in as many words (*"total two buttons may be two
 * icons may be only"*), and what the rule was actually protecting against is a
 * glyph whose meaning is nowhere on screen. So what is pinned instead is that
 * the button carries a sentence naming both the state it is in and what a press
 * does — which is the whole safety of an icon-only toggle.
 *
 * The **second** of those two icons was the Terminal/Chat toggle, and it went
 * on 2026-08-26 with chat mode itself. What is asserted below is that it is
 * gone rather than hidden: one button, one glyph, and no sentence anywhere in
 * the markup offering a session drawn as a conversation.
 */
describe('ModeSwitch', () => {
  const html = renderToStaticMarkup(<ModeSwitch mode="terminal" onChange={noop} />)

  it('is one button and one glyph, and says nothing about chat', () => {
    expect(html.match(/<button/g)).toHaveLength(1)
    expect(html.match(/<svg/g)).toHaveLength(1)
    for (const label of ['>Terminal<', '>Chat<', '>Split<']) expect(html).not.toContain(label)
    // The removal, asserted where it would show first: the bubble's own path
    // data, which is the only thing about the old toggle that could not be
    // renamed away.
    expect(html).not.toContain('M20.5 13.8a')
    expect(html.toLowerCase()).not.toContain('chat')
  })

  it('names the state it is in and what a press does', () => {
    expect(html).toContain('aria-label="Split — show two sessions side by side"')
    expect(html).toContain('title="Split — show two sessions side by side"')
  })

  it('keeps the pressed state, because split really is on or off', () => {
    expect(html.match(/aria-pressed/g)).toHaveLength(1)
    expect(html).toContain('aria-pressed="false"')
    expect(renderToStaticMarkup(<ModeSwitch mode="split" onChange={noop} />)).toContain(
      'aria-pressed="true"',
    )
  })

  it('offers the way out of a split, which the pill never did', () => {
    // The old control left its Split segment inert once split, so the only exit
    // was a segment for a mode you might not want.
    const split = renderToStaticMarkup(<ModeSwitch mode="split" onChange={noop} />)
    expect(split).toContain('Split — press to show one session on its own again')
  })
})

describe('FolderTitle', () => {
  const html = renderToStaticMarkup(<FolderTitle path={projects[0].path} />)

  it('shows the folder rather than the whole path', () => {
    expect(html).toContain('terminaldeck')
    expect(html).not.toContain('>/Users/apple/Projects/terminaldeck<')
  })

  it('carries the full path where there is room for it', () => {
    // The line is one word wide and two projects called `web` is not an unusual
    // thing to have open, so the tooltip is the disambiguator.
    expect(html).toContain('title="/Users/apple/Projects/terminaldeck')
  })

  it('sets the path in the mono face, because a path is data', () => {
    // The rule is `.folder-title` in shell.css. What is pinned here is that the
    // element keeps the hook — there is a bare `mono` class in the dashboard's
    // stylesheet and it is scoped to that file, so borrowing the name here
    // would have styled nothing at all.
    expect(html).toContain('class="folder-title"')
  })

  it('is not a control at all any more', () => {
    /*
     * The whole of the change he asked for: *"just title is good enough for us
     * to know which folder we are in right now. That's it. Dropdown will be
     * only for the accounts."* A dropdown here could only ever have offered to
     * start a *different* session, because a pty has one working directory for
     * its whole life — so it was a chevron promising something the app cannot
     * do, in the one place a person would look for it.
     */
    expect(html).not.toContain('<button')
    expect(html).not.toContain('aria-haspopup')
    expect(html).not.toContain('folder-menu')
  })

  it('says why there is no dropdown, rather than leaving it a mystery', () => {
    // The fact, in the one place somebody goes looking for the control that is
    // not there. It is a statement about how sessions work, not an apology.
    expect(html).toContain('keeps this folder for its whole life')
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
      // "A plain shell has no account to sign in to", which has now moved into
      // `shared/agent-catalog.ts` and lost the word "login" on the way — the
      // copy pass replaced the mechanism (isolating a config directory) with the
      // consequence, and then replaced "login" with the plainer "account". The
      // assertion follows the shipped copy rather than the copy being reverted
      // to satisfy it, which is the rule this line has already survived twice.
      ['shell', 'no account to sign in to'],
      // Gemini is the interesting one, and its sentence is not "only apply to
      // Claude" any more because that was never the real reason. `GEMINI_CLI_HOME`
      // exists and moves settings — what it does not move is the OAuth token,
      // which goes to the OS keychain under two constants that never read the
      // home. So two "accounts" address one keychain item and `setPassword`
      // overwrites: signing into a second would not share the first login, it
      // would destroy it. That is why it is refused rather than offered.
      ['gemini', 'would replace the first rather than sit beside it'],
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
      expect(invited, provider).not.toContain('no account to sign in to')
      expect(invited, provider).not.toContain('would replace the first')
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
  const session = (
    id: string,
    account?: { id: string; name: string; provider: 'claude' },
  ): WorkspaceTab => ({
    id,
    kind: 'session',
    label: id,
    projectPath: '/w/app',
    closable: true,
    ...(account ? { account } : {}),
  })
  const work = { id: 'work', name: 'Work', provider: 'claude' } as const
  const home = { id: 'home', name: 'Home', provider: 'claude' } as const

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

  /**
   * The name wins. The chip is what gives.
   *
   * From the frames of the 2026-08-16 recording: a rail reading
   * `Session 1, Session 2, Sess…, Session 4, Session 5`, and deeper in, a name
   * cut to the single character **`S…`** — because the account caption held a
   * fixed width and the name was the only flexible thing on the line. A row
   * whose name is one character has stopped identifying anything, while the
   * account it made room for is a fact the tooltip still carries.
   */
  it('drops the account rather than the name once the rail is too narrow', () => {
    const two = [session('a', work), session('b', home)]
    expect(accountsWorthShowing(two, ACCOUNT_NEEDS_RAIL)).toBe(true)
    expect(accountsWorthShowing(two, ACCOUNT_NEEDS_RAIL - 1)).toBe(false)
    // A rail at the app's own narrow cap is well under it, which is the case
    // that produced `S…`.
    expect(accountsWorthShowing(two, 148)).toBe(false)
  })

  it('assumes there is room when nobody says how wide the rail is', () => {
    // The default keeps every caller that does not measure — the harness, a
    // test — on the behaviour it had.
    expect(accountsWorthShowing([session('a', work), session('b', home)])).toBe(true)
  })
})

describe('tabIdentities', () => {
  /**
   * *"Two tabs both labelled Session 1."*
   *
   * Both halves were individually right: `sessionLabel` numbers a session
   * within its project, which is correct in the sidebar because the project's
   * name is the heading three pixels above the row. The strip has no headings —
   * it is one flat row — so the two arrive in it with nothing left to tell them
   * apart, and the window is asking the user to guess.
   */
  const inProject = (id: string, path: string, label = ''): WorkspaceTab => ({
    id,
    kind: 'session',
    label,
    projectPath: path,
    closable: true,
  })

  it('leaves a name that is already unique completely alone', () => {
    const tabs = [inProject('a', '/w/app', 'Fix the parser'), inProject('b', '/w/site', 'Ship it')]
    const ids = tabIdentities(tabs)
    expect(ids.get('a')).toEqual({ label: 'Fix the parser', qualifier: null })
    expect(ids.get('b')).toEqual({ label: 'Ship it', qualifier: null })
  })

  it('qualifies the exact pair he saw, and by the thing that differs', () => {
    const tabs = [inProject('a', '/w/app'), inProject('b', '/w/site')]
    const ids = tabIdentities(tabs)
    expect(ids.get('a')).toEqual({ label: 'Session 1', qualifier: 'app' })
    expect(ids.get('b')).toEqual({ label: 'Session 1', qualifier: 'site' })
  })

  it('qualifies only the tabs that collide, not every tab in the row', () => {
    // A qualifier on every tab is noise on every tab — the same argument
    // `accountsWorthShowing` makes about accounts.
    const tabs = [
      inProject('a', '/w/app'),
      inProject('b', '/w/site'),
      inProject('c', '/w/app', 'Fix the parser'),
    ]
    const ids = tabIdentities(tabs)
    expect(ids.get('a')?.qualifier).toBe('app')
    expect(ids.get('b')?.qualifier).toBe('site')
    expect(ids.get('c')?.qualifier).toBeNull()
  })

  it('falls back to the session id when even the project cannot separate them', () => {
    /*
     * Two agents given the same task write the same sentence. Reported from the
     * rail: `Update Claude Code terminal to new…` twice, in one folder, on one
     * account — nothing on screen told them apart.
     *
     * The project is the same for both, so it is not printed at all: a
     * qualifier both rows share leaves them exactly as identical as it found
     * them, and the pass meant to be the last resort was left doing all the
     * work. What is printed instead is the head of each session's own id — a
     * fact about the session rather than about the list, which is the whole
     * difference from the ordinal this replaces. Close the first of the two and
     * the second's label does not silently become the first's.
     *
     * Four characters of it, not eight: `distinguishingIdLength` cuts the head
     * to the shortest length that still separates the run, because on a 264px
     * rail the other four characters were being paid for by the session's name.
     */
    const tabs = [
      inProject('7f3c9a21-0000-4000-8000-000000000001', '/w/app', 'Fix the parser'),
      inProject('b4e1d508-0000-4000-8000-000000000002', '/w/app', 'Fix the parser'),
    ]
    const ids = tabIdentities(tabs)
    expect(ids.get(tabs[0].id)).toEqual({ label: 'Fix the parser', qualifier: '7f3c' })
    expect(ids.get(tabs[1].id)).toEqual({ label: 'Fix the parser', qualifier: 'b4e1' })
  })

  /**
   * The length is asked, not assumed.
   *
   * Two sessions whose ids agree for their first five characters. Cut blindly
   * to four, both rows would read `7f3c` and the qualifier — the one thing on
   * those rows whose entire job is to separate them — would have left them
   * exactly as identical as it found them while looking like it had answered.
   *
   * Both rows lengthen, not just the pair that collided, because these sit in a
   * column at the ends of rows cut to the same width and one row wearing six
   * characters beside another wearing four reads as a value that varies rather
   * than as an identifier.
   */
  it('lengthens the id when four characters of it would collide', () => {
    const tabs = [
      inProject('7f3c9a21-0000-4000-8000-000000000001', '/w/app', 'Fix the parser'),
      inProject('7f3c9b40-0000-4000-8000-000000000002', '/w/app', 'Fix the parser'),
    ]
    const ids = tabIdentities(tabs)
    expect(ids.get(tabs[0].id)?.qualifier).toBe('7f3c9a')
    expect(ids.get(tabs[1].id)?.qualifier).toBe('7f3c9b')
  })

  /**
   * And it is asked of the rows that print one, not of every row in the run.
   *
   * The third tab here has a name of its own and so never reaches this rung. It
   * shares four characters with the first, and if it were counted the pair that
   * *is* ambiguous would be given six characters each to separate them from an
   * id nobody can see — a wider column bought with the name's pixels to answer
   * a question the screen never asks.
   */
  it('sizes the id against the rows drawing one, not against the whole run', () => {
    const tabs = [
      inProject('7f3c9a21-0000-4000-8000-000000000001', '/w/app', 'Fix the parser'),
      inProject('b4e1d508-0000-4000-8000-000000000002', '/w/app', 'Fix the parser'),
      inProject('7f3cd0e7-0000-4000-8000-000000000003', '/w/app', 'Rename the columns'),
    ]
    const ids = tabIdentities(tabs)
    expect(ids.get(tabs[0].id)?.qualifier).toBe('7f3c')
    expect(ids.get(tabs[1].id)?.qualifier).toBe('b4e1')
    expect(ids.get(tabs[2].id)?.qualifier).toBeNull()
  })

  it('keeps the project as the qualifier when the project is what differs', () => {
    // Three tabs, one name: two in one folder and one in another. The folder
    // separates the third and cannot separate the first two, so it is printed
    // on all three and the pair that is still ambiguous takes its id as well.
    // The alternative — dropping the folder because it did not finish the job —
    // would qualify a tab by an id when a folder name was available and true.
    const tabs = [
      inProject('7f3c9a21-0000-4000-8000-000000000001', '/w/app', 'Fix the parser'),
      inProject('b4e1d508-0000-4000-8000-000000000002', '/w/app', 'Fix the parser'),
      inProject('c9a70b64-0000-4000-8000-000000000003', '/w/site', 'Fix the parser'),
    ]
    const ids = tabIdentities(tabs)
    expect(ids.get(tabs[0].id)?.qualifier).toBe('app · 7f3c')
    expect(ids.get(tabs[1].id)?.qualifier).toBe('app · b4e1')
    expect(ids.get(tabs[2].id)?.qualifier).toBe('site')
  })

  it('numbers a session against every sibling, not just the ones on the strip', () => {
    /*
     * The number in "Session 3" counts siblings in a folder. If it were counted
     * over the drawn subset instead, promoting the second of three sessions
     * would relabel it "Session 1" up top while the rail still called it
     * "Session 2" — the two halves of the window disagreeing about a name,
     * which is the whole class of defect this change is closing.
     */
    const all = [inProject('a', '/w/app'), inProject('b', '/w/app'), inProject('c', '/w/app')]
    expect(tabIdentities([all[2]], all).get('c')?.label).toBe('Session 3')
  })

  it('says nothing about the folder a session does not have', () => {
    /*
     * An orphaned session — its project closed out from under it — has no
     * folder to be qualified by. It is left bare beside its qualified twin
     * rather than given an empty qualifier or a number: "Session 1" against
     * "Session 1 app" is already two different things on screen, and an empty
     * qualifier reads as a value that failed to load.
     */
    const orphan: WorkspaceTab = { id: 'x', kind: 'session', label: 'Session 1', closable: true }
    const ids = tabIdentities([orphan, inProject('a', '/w/app')])
    expect(ids.get('x')).toEqual({ label: 'Session 1', qualifier: null })
    expect(ids.get('a')?.qualifier).toBe('app')
  })

  /**
   * The account is a rung too — but only where the caller is drawing it.
   *
   * The rail prints the account beside the name, so two rows it separates need
   * nothing further and an id on them would be a second answer to a question
   * already answered. The strip prints no account, and below
   * `ACCOUNT_NEEDS_RAIL` neither does the rail — and a fact that is not on
   * screen has never told anybody anything apart.
   */
  it('leaves a pair the account already separates alone, where the account is shown', () => {
    const withAccount = (id: string, account: string): WorkspaceTab => ({
      ...inProject(id, '/w/app', 'Fix the parser'),
      account: { id: account, name: account, provider: 'claude' },
    })
    const tabs = [withAccount('7f3c9a21-aaaa', 'work'), withAccount('b4e1d508-bbbb', 'home')]
    const labels = tabs.map(() => 'Fix the parser')

    expect(tabQualifiers(tabs, labels, { accountsShown: true })).toEqual([null, null])
    // And with the column gone, the id is needed again.
    expect(tabQualifiers(tabs, labels)).toEqual(['7f3c', 'b4e1'])
  })

  /**
   * Five sessions on one paired machine, which is where this rung was printing
   * the wrong identifier entirely.
   *
   * A remote tab's id is `machine <ULID> <n>` and `shortSessionId` cuts at the
   * first hyphen — a ULID has none — so every row under one machine heading got
   * the same twenty-six-character machine id as its qualifier. It is in his
   * recording: three rows under DESKTOP-DDGMNCV reading `machine XPUSZ55CRJPKSVQ`,
   * naming the computer whose heading is three pixels above them. What separates
   * them is the far machine's own session id.
   */
  it('qualifies a remote row with the far machine’s session id, not the machine’s', () => {
    const onMachine = (session: string): WorkspaceTab => ({
      ...inProject(machineTabId('Q5JE8FAG53PML2W3VU9V3QTZ2U', session), '/w/app', 'terminaldeck'),
      machine: { id: 'Q5JE8FAG53PML2W3VU9V3QTZ2U', name: 'MacBookPro' },
    })
    const tabs = [onMachine('1'), onMachine('2'), onMachine('3')]
    const labels = tabs.map(() => 'terminaldeck')
    const qualifiers = tabQualifiers(tabs, labels)

    expect(qualifiers).toEqual(['1', '2', '3'])
    for (const qualifier of qualifiers) expect(qualifier).not.toContain('Q5JE8FAG53')
  })

  it('still separates a pair on one account, whether or not the column is drawn', () => {
    const sameAccount = (id: string): WorkspaceTab => ({
      ...inProject(id, '/w/app', 'Fix the parser'),
      account: { id: 'work', name: 'Work', provider: 'claude' },
    })
    const tabs = [sameAccount('7f3c9a21-aaaa'), sameAccount('b4e1d508-bbbb')]
    const labels = tabs.map(() => 'Fix the parser')
    expect(tabQualifiers(tabs, labels, { accountsShown: true })).toEqual(['7f3c', 'b4e1'])
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
    // The switch's own glyph and nothing beyond it. This counted zero `<svg>`
    // while the switch was three words and two while it still carried a
    // Terminal/Chat toggle; the four glyph buttons this toolbar was cleared of
    // are what the count is actually guarding against.
    expect(actions.match(/<svg/g)).toHaveLength(1)
    expect(actions).not.toContain('<button type="button" class="toolbar-')
  })

  /**
   * There is exactly one control in the window that brings a pinned-away rail
   * back, and which bar draws it depends on which bar is the top one.
   *
   * The strip took the top band on 2026-08-17, and with it the traffic lights,
   * the window drag and this button. Leaving a copy here as well is not a
   * cosmetic duplicate: they are 48px apart in the same corner, both say "Show
   * sidebar", and the lower one is the one you would reach for and the upper one
   * is the one the pointer arrives at first.
   */
  const underStrip = renderToStaticMarkup(
    <WindowToolbar
      title="Wire up split panes"
      sidebarHidden
      underStrip
      onRevealSidebar={noop}
      onEdgeEnter={noop}
    >
      <ModeSwitch mode="terminal" onChange={noop} />
    </WindowToolbar>,
  )

  it('gives the reveal button up to the strip when there is one', () => {
    expect(underStrip).not.toContain('Show sidebar')
  })

  it('says so in the markup, because the room it holds is decided in CSS', () => {
    // `.toolbar[data-sidebar-collapsed]:not([data-under-strip])` is what keeps
    // 118px of traffic-light reserve out of a bar that has nothing above it.
    expect(underStrip).toContain('data-under-strip="true"')
    expect(hidden).not.toContain('data-under-strip')
  })

  it('still names the session, because that is the half that is still its job', () => {
    expect(underStrip).toContain('Wire up split panes')
    expect(underStrip).toContain('mode-switch')
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
      onOpenAlerts={noop}
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
        onOpenAlerts={noop}
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

  it('puts Alerts on the Settings line as a glyph, not a row', () => {
    /*
     * *"For the alerts icon, let's not keep it a complete separate pill. Let's
     * make it a small icon next to the settings pill… if we click on it, it just
     * opens the notifications."*
     *
     * Two things have to be true at once and they pull against each other: the
     * row is gone, and the control is still there — exactly one of it, at the
     * end of the Settings line, with its name in `aria-label` because a glyph
     * has no room for text.
     */
    const foot = /class="sidebar-foot">([\s\S]*?)<div\s+class="sidebar-resize"/.exec(html)?.[1] ?? ''
    expect(foot, 'the foot was not found — has the sidebar changed shape?').not.toBe('')
    expect(foot).toContain('class="sidebar-settings"')
    expect(foot).toContain('aria-label="Alerts"')
    // A glyph, so no label text beside it — and after Settings on the line,
    // which is what "next to the settings pill" means.
    expect(foot).not.toContain('>Alerts</span>')
    expect(foot.indexOf('Settings')).toBeLessThan(foot.indexOf('aria-label="Alerts"'))
  })

  it('does not draw the bell as a place you can be', () => {
    /*
     * The second half of *"and notifications should be a pop-up just like
     * settings, not a full page."*
     *
     * A rail control is drawn `active` and carries `aria-current` when the view
     * it names is filling the window. The bell opens a sheet over the window,
     * so there is no such state to be in — and neither has the gear one pixel
     * to its left, which has opened a dialog since it was written. A bell that
     * marked itself current would be the rail claiming a navigation that never
     * happened, which is the mistake this whole change is undoing.
     *
     * Scoped to the Settings line rather than to the whole rail, because
     * `aria-current` is exactly right on the panel rows above and this must not
     * be read as a rule against it.
     */
    const line = /class="sidebar-settings">([\s\S]*?)<\/div>/.exec(html)?.[1] ?? ''
    expect(line, 'the Settings line was not found — has the foot changed shape?').not.toBe('')
    expect(line).toContain('aria-label="Alerts"')
    expect(line, 'a dialog is not somewhere you are').not.toContain('aria-current')
    expect(line, 'nor is it somewhere you can be active in').not.toContain('sb-icon active')
  })

  it('takes the bell away with the feature, rather than leaving a dead one', () => {
    /*
     * The gating the page used to get for free by being a `PanelId`: the rail
     * filtered uninstalled views out of `panels`, so Alerts simply had no row.
     * It is a control now, asked about one level up in `App.tsx`, and this is
     * the half of that the rail is responsible for.
     */
    const off = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={[]}
        tabs={[]}
        activeTabId={null}
        activePanel={null}
        alerts={false}
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
      />,
    )
    expect(off).not.toContain('Alerts')
    // And Settings is still there, holding the line on its own — the two are
    // separate controls, not one with a decoration on the end.
    expect(off).toContain('Settings')
  })

  it('keeps the unread count on the glyph, in a mark and in words', () => {
    /*
     * The row it replaced carried a numeric badge. A 30px glyph has nowhere to
     * put one, so the number moves into the accessible name and what is left on
     * screen is a dot — but *something* has to be left, or a notification list
     * whose only mark is inside itself is a list nobody opens.
     */
    const withAlerts = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={[]}
        tabs={[]}
        activeTabId={null}
        activePanel={null}
        alertCount={3}
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
      />,
    )
    expect(withAlerts).toContain('aria-label="Alerts (3)"')
    expect(withAlerts).toContain('class="sb-icon-dot"')
    // And nothing at all when there is nothing waiting: a dot that is always
    // lit is a dot that says nothing.
    expect(html).not.toContain('sb-icon-dot')
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
            account: { id: 'work', name: 'Work', provider: 'claude' },
            closable: true,
          },
          {
            id: 's2',
            kind: 'session',
            label: 'Fix the parser',
            projectPath: projects[0].path,
            account: { id: 'home', name: 'Home', provider: 'claude' },
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
        onOpenAlerts={noop}
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

  it('keeps the name whole on a narrow rail and drops the account instead', () => {
    /*
     * `S…`. That is what the rail printed in his recording, and this is the
     * exact arrangement that produced it: two accounts in play, so every row
     * wanted a caption, on a rail with no room for one. The name is what the
     * row exists to carry, so the caption is what goes — and the fact is not
     * lost, it moves into the tooltip, which the assertion below insists on.
     */
    const twoOnANarrowRail = renderToStaticMarkup(
      <Sidebar
        width={168}
        projects={projects}
        tabs={[
          {
            id: 's1',
            kind: 'session',
            label: 'Fix the parser',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work', provider: 'claude' },
            closable: true,
          },
          {
            id: 's2',
            kind: 'session',
            label: 'Ship the release',
            projectPath: projects[0].path,
            account: { id: 'home', name: 'Home', provider: 'claude' },
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
        onOpenAlerts={noop}
        onToggleCollapsed={noop}
        onPeekStart={noop}
        onPeekEnd={noop}
        onStartResize={noop}
      />,
    )
    expect(twoOnANarrowRail).not.toContain('sb-account')
    expect(twoOnANarrowRail).toContain('>Fix the parser<')
    expect(twoOnANarrowRail).toContain('signed in as Work')
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
            account: { id: 'work', name: 'Work', provider: 'claude' },
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
        onOpenAlerts={noop}
        onToggleCollapsed={noop}
        onPeekStart={noop}
        onPeekEnd={noop}
        onStartResize={noop}
      />,
    )
    expect(oneAccount).not.toContain('sb-account')
  })

  /**
   * The word he objected to, off the rail.
   *
   *   > "Inside the terminal page it is still showing selected account as
   *   > Default and not showing the email ID."
   *
   * Every screenshot of the sidebar showed rows reading `Default` — the key
   * `profiles.ts` mints for the machine's own install — while the chip forty
   * pixels above the same session read `app.imatch.ae@gmail.com`. One account,
   * two names, one frame.
   *
   * A static render resolves no promises and this window has no bridge, so
   * nothing has been read about any login here. That is the worst case and the
   * point of testing it: it is the state in which falling back to the record's
   * own name is most tempting, and the rail must still not do it.
   */
  it('never prints the profile key on a row, even before anything is read', () => {
    const rail = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={[
          {
            id: 's1',
            kind: 'session',
            label: 'Fix the parser',
            projectPath: projects[0].path,
            account: { id: 'system', name: 'Default', provider: 'claude' },
            closable: true,
          },
          {
            id: 's2',
            kind: 'session',
            label: 'Ship the release',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work', provider: 'claude' },
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
        onOpenAlerts={noop}
        onToggleCollapsed={noop}
        onPeekStart={noop}
        onPeekEnd={noop}
        onStartResize={noop}
      />,
    )
    expect(rail).not.toContain('Default')
    // The chosen name still fits the column and still identifies a login.
    expect(rail).toContain('class="sb-account">Work<')
    // With nothing read and no name anybody chose, the column says nothing at
    // all rather than an abbreviation that identifies nothing — and the fact
    // moves into the row's tooltip, which is where it goes on a narrow rail too.
    expect(rail).toContain('on your own Claude Code install')
    expect(rail).toContain('signed in as Work')
  })

  /**
   * Two rows that were the same row twice.
   *
   * Read live off the rail: `Update Claude Code terminal to new…` twice, in one
   * folder, both on the same account — same visible name, same account caption,
   * nothing to tell them apart. The folder cannot separate them (it is the
   * heading directly above both), and neither can the account, so what is left
   * is the head of each session's own id.
   */
  it('separates two rows whose name and account are identical', () => {
    const twins = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={[
          {
            id: '7f3c9a21-0000-4000-8000-000000000001',
            kind: 'session',
            label: 'Update Claude Code terminal',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work', provider: 'claude' },
            closable: true,
          },
          {
            id: 'b4e1d508-0000-4000-8000-000000000002',
            kind: 'session',
            label: 'Update Claude Code terminal',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work', provider: 'claude' },
            closable: true,
          },
          {
            id: 'c9a70b64-0000-4000-8000-000000000003',
            kind: 'session',
            label: 'Ship the release',
            projectPath: projects[0].path,
            account: { id: 'work', name: 'Work', provider: 'claude' },
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
        onOpenAlerts={noop}
        onToggleCollapsed={noop}
        onPeekStart={noop}
        onPeekEnd={noop}
        onStartResize={noop}
      />,
    )
    expect(twins).toContain('class="sb-qualifier">7f3c<')
    expect(twins).toContain('class="sb-qualifier">b4e1<')
    // And on nothing else. A qualifier on every row is noise on every row — the
    // same argument `accountsWorthShowing` makes about the account itself.
    expect(twins.match(/class="sb-qualifier"/g)).toHaveLength(2)
  })

  it('renders every panel exactly once, wherever it belongs', () => {
    /*
     * The trap this catches: the rail draws its views in two loops — the
     * labelled runs, and the `foot` group the scrolling list deliberately skips
     * — so moving a view between them means moving it between loops. Getting
     * that wrong draws it twice, or not at all, and the "not at all" version
     * still passes `reachable.test.ts`, because the panel does have a case in
     * `PanelView`; it just has no control anybody can click. Machines made that
     * exact crossing on 2026-08-19, out of the foot and into Integrations,
     * which is the move this loop is here for.
     *
     * There used to be a third group, `icon`, and this sweep matched on
     * `aria-label` as well as on the label text to cover the one member it had.
     * Both are gone: Alerts is a dialog rather than a view, so it is not in
     * `PANELS` at all and the loop below would sweep past it silently. That is
     * the vacuous version of this test, and the test underneath is what stops
     * it being one — every control on the rail is still counted, this loop
     * counts the views and that one counts the bell.
     */
    for (const panel of PANELS) {
      const hits = html.match(new RegExp(`>${panel.label}</span>`, 'g')) ?? []
      expect(hits, `${panel.id} appears ${hits.length} times in the sidebar`).toHaveLength(1)
    }
  })

  it('renders the bell exactly once, and it is not one of the panels', () => {
    /*
     * The other half of the sweep above, kept as a test of its own rather than
     * folded into the loop, because the two are now different claims: that one
     * is about a list, and this one is about a control that is deliberately not
     * in the list. Both failure modes are still covered — drawn twice (a loop
     * and a hand-written button both claiming it) and drawn not at all (moved
     * out of `PANELS` and nothing put in its place, which is exactly what this
     * change could have shipped).
     */
    const named = html.match(/aria-label="Alerts(?: \(\d+\))?"/g) ?? []
    expect(named, `the bell appears ${named.length} times in the sidebar`).toHaveLength(1)
    expect(
      PANELS.some((panel) => panel.label === 'Alerts'),
      'Alerts is back in PANELS, which gives it a page again — see the note on PanelId',
    ).toBe(false)
  })
})
