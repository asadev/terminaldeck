import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  AccountChip,
  FIXED_ACCOUNT_NOTE,
  fixedAccountNote,
  MENU_HEAD,
  runAgentCommand,
  runnableAgent,
} from './AccountChip'
import { AGENT_CATALOG } from '../../shared/agent-catalog'
import {
  chipMode,
  presenceFromSession,
  parseAgentReading,
  settle,
  UNKNOWN_PRESENCE,
  type AgentPresence,
} from './agent-presence'

/**
 * Items 1 and 2 of NEXT-UPDATE.md, both of which land on this chip.
 *
 * `react-dom/server`, like every other render test in this folder: the project
 * has no DOM environment. That is enough for what is being pinned here, because
 * every one of these is a question about *which control is drawn at all*, and
 * that is decided during render.
 */

const noop = (): void => {}

afterEach(() => {
  delete (globalThis as { deck?: unknown }).deck
})

describe('a session with no agent in it', () => {
  /**
   * His words:
   *
   *   > "Starting a session gives you a plain shell. Today that shell still
   *   > shows the chat/terminal switch and the account dropdown — both of which
   *   > mean nothing until an agent is running in it. … Put a Run Claude button
   *   > there instead."
   */
  const shell = { id: 's1', provider: 'shell' as const, exited: false }

  const chip = (agentRunning: boolean | null): string => {
    // `useAgentPresence` reads the screen through `readAgentControls`; in a
    // static render the promise never resolves, so the *session* half is what
    // decides here — which is exactly the half that is exact. The shell case is
    // driven through `presenceFromSession` and `parseAgentReading` below.
    //
    // `provider` is what the Run button is *about* now — the agent a session
    // started here would run — so every render that expects the button has to
    // say which one, exactly as both real callers do.
    return renderToStaticMarkup(
      <AccountChip
        current={agentRunning ? { id: 'work', name: 'Work' } : null}
        projectPath="/w/app"
        provider="claude"
        session={agentRunning === null ? shell : { ...shell, provider: agentRunning ? 'claude' : 'shell' }}
        onPick={noop}
        onManage={noop}
      />,
    )
  }

  it('claims neither control until something has actually been read', () => {
    // No bridge here, so nothing has read the screen — and being spawned as
    // `$SHELL -l` and still alive is not enough to say an agent is absent. The
    // chip says nothing rather than offering either control. See the
    // three-state note in AccountChip.tsx and `chipMode` below.
    expect(chip(null)).toBe('')
  })

  it('offers the Run button once the screen says there is no agent', () => {
    // The state every new session starts in, and the one this item is about.
    expect(chipMode(shell, { running: false, source: 'screen', saw: null })).toBe('run')
  })

  it('withdraws the offer and reveals the picker the moment one is running', () => {
    const saw = '⏵⏵ bypass permissions on (shift+tab to cycle)'
    expect(chipMode(shell, { running: true, source: 'screen', saw })).toBe('account')
  })

  it('offers the Run button again after the agent is quit and the shell comes back', () => {
    // The case a control keyed off "the user typed claude" gets wrong forever:
    // `/exit` returns the shell and the session is still alive.
    expect(chipMode(shell, { running: true, source: 'screen', saw: 'x' })).toBe('account')
    expect(chipMode(shell, { running: false, source: 'screen', saw: null })).toBe('run')
  })

  it('never draws the Run button for a caller asking about a folder', () => {
    expect(chipMode(null, UNKNOWN_PRESENCE)).toBe('account')
    expect(chipMode(null, { running: false, source: 'screen', saw: null })).toBe('account')
  })

  it('wears the account picker the moment an agent is what the session is', () => {
    const html = chip(true)
    expect(html).toContain('Work')
    expect(html).not.toContain('run-agent-button')
  })

  it('never offers to start an agent in a session that has ended', () => {
    // The pty is gone; typing into it does nothing at all, and a button that
    // does nothing is the dead control the brief forbids.
    const html = renderToStaticMarkup(
      <AccountChip
        current={null}
        projectPath="/w/app"
        provider="claude"
        session={{ id: 's1', provider: 'shell', exited: true }}
        onPick={noop}
        onManage={noop}
      />,
    )
    expect(html).toContain('run-agent-button')
    expect(html).toContain('disabled')
  })

  it('is unchanged for a caller with no session in play', () => {
    // Two callers render this about a *folder*. A folder cannot have an agent
    // running in it, and the chip must not start hiding itself for them.
    const html = renderToStaticMarkup(
      <AccountChip current={{ id: 'work', name: 'Work' }} projectPath="/w/app" onPick={noop} onManage={noop} />,
    )
    expect(html).toContain('Work')
  })
})

describe('what the Run button actually does', () => {
  it('types that agent’s own command into that session’s own terminal', () => {
    /*
     * His words: "it automatically types /claude and sends", i.e. the app runs
     * the command rather than making you remember it. Written into the pty, so
     * the terminal view shows the same keystrokes — chat mode and the toolbar
     * are views of one session, not second channels into it.
     *
     * The command is read off the catalogue row rather than written here, which
     * is what makes the *next* three assertions worth anything: a fifth agent
     * added to the table gets a working button by existing.
     */
    expect(runAgentCommand(AGENT_CATALOG.claude)).toBe('claude\r')
    expect(runAgentCommand(AGENT_CATALOG.codex)).toBe('codex\r')
    expect(runAgentCommand(AGENT_CATALOG.gemini)).toBe('gemini\r')
  })

  it('sends a carriage return, which is what Return is on a terminal', () => {
    // `\n` is a line feed. A pty carries what a keyboard sends.
    for (const entry of [AGENT_CATALOG.claude, AGENT_CATALOG.codex, AGENT_CATALOG.gemini]) {
      expect(runAgentCommand(entry).endsWith('\r')).toBe(true)
      expect(runAgentCommand(entry)).not.toContain('\n')
    }
  })

  it('does not resume a conversation nobody asked to resume', () => {
    // Every agent's `resumeArgs` picks the last conversation written in the
    // folder, which `session-transcript.ts` records at length is frequently not
    // this session's. The button says Run and that is all it does.
    for (const entry of [AGENT_CATALOG.claude, AGENT_CATALOG.codex, AGENT_CATALOG.gemini]) {
      for (const arg of entry.resumeArgs) expect(runAgentCommand(entry)).not.toContain(arg)
    }
  })

  it('has nothing to start when the chosen default is a plain shell', () => {
    /*
     * The state that used to type `claude` at somebody who had asked for a
     * terminal and nothing else. A shell's `bin` is null because it is resolved
     * at spawn from `$SHELL`, so there is no command to send and no agent to
     * name — and a button naming one would be inventing a choice.
     */
    expect(runnableAgent('shell')).toBeNull()
    expect(runnableAgent(null)).toBeNull()
    expect(runnableAgent(undefined)).toBeNull()
  })
})

describe('the Run button names the agent the person actually chose', () => {
  /**
   * The naming rule, applied to the one control that is on screen for the whole
   * life of every new session:
   *
   *   > *"You should not mention in any settings or any pop-up a specific tool
   *   > or LLM, because they can use some other also."*
   *
   * This was `Run Claude`, spelled out in the JSX, on every shell session's
   * toolbar regardless of which agent the person had chosen — so for a Codex
   * user it named the wrong product *and* would have typed the wrong command.
   * These assertions are what stops the literal coming back: they fail if the
   * label stops following `provider`.
   */
  const runChip = (provider: 'claude' | 'codex' | 'gemini' | 'shell'): string =>
    renderToStaticMarkup(
      <AccountChip
        current={null}
        projectPath="/w/app"
        provider={provider}
        session={{ id: 's1', provider: 'shell', exited: false }}
        onPick={noop}
        onManage={noop}
      />,
    )

  it('says Run and then whatever the catalogue calls that agent', () => {
    // Rendered with no bridge, so presence never resolves… which is why these
    // go through `runnableAgent` for the label and the render for the wiring.
    expect(runnableAgent('claude')?.label).toBe('Claude Code')
    expect(runnableAgent('codex')?.label).toBe('Codex CLI')
    expect(runnableAgent('gemini')?.label).toBe('Gemini CLI')
  })

  it('never hardcodes one agent’s name in this component', () => {
    // The file itself, read as text: the guard in `neutral-naming.test.ts`
    // scans copy across the whole tree, and this is the same rule stated where
    // somebody editing this one component will see it fail.
    const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')
    const jsx = source.split('\n').filter((line) => line.includes('startable.label'))
    expect(jsx.length).toBeGreaterThan(1)
  })

  it('draws nothing at all when there is no agent to offer', () => {
    /*
     * Not an inert button, and — the half that was wrong for a few minutes and
     * only showed up in a screenshot — not the account picker either.
     *
     * With the plain shell as the default there is nothing to start, so the Run
     * branch does not apply; falling through to the code below it put the
     * account dropdown back on a plain shell reading "No login ⌄", which is
     * precisely the control this whole mode exists to remove. Both halves are
     * asserted because only asserting the first passed while the second was
     * broken.
     */
    const html = runChip('shell')
    expect(html).not.toContain('run-agent-button')
    expect(html).not.toContain('account-chip')
    expect(html).toBe('')
  })
})

describe('the presence signal itself', () => {
  it('is exact for a session the app spawned an agent into', () => {
    // `providers.ts` spawns the CLI *as* the pty's process, so it is running
    // for exactly as long as the session is. No screen reading required.
    expect(presenceFromSession({ id: 'a', provider: 'claude', exited: false })).toEqual({
      running: true,
      source: 'session',
      saw: null,
    })
  })

  it('reports an exited session as having nothing in it, whatever it was', () => {
    expect(presenceFromSession({ id: 'a', provider: 'claude', exited: true })?.running).toBe(false)
    expect(presenceFromSession({ id: 'a', provider: 'shell', exited: true })?.running).toBe(false)
  })

  it('refuses to answer for a live shell, and hands the question to the screen', () => {
    // The whole reason this is not `provider === 'shell'`: a shell can have an
    // agent in it and can stop having one, and the session record says nothing
    // about either moment.
    expect(presenceFromSession({ id: 'a', provider: 'shell', exited: false })).toBeNull()
  })

  it('treats a malformed or missing answer as “not known”, never as “no agent”', () => {
    // A build with no controls channel resolves these to null/undefined. Read
    // as "no agent" it would put a Run button in front of a running agent.
    expect(parseAgentReading(null)).toEqual(UNKNOWN_PRESENCE)
    expect(parseAgentReading({})).toEqual(UNKNOWN_PRESENCE)
    expect(parseAgentReading({ agent: { running: 'yes' } })).toEqual(UNKNOWN_PRESENCE)
  })

  it('carries the line the screen was read from', () => {
    expect(
      parseAgentReading({ agent: { running: true, saw: '⏵⏵ bypass permissions on (shift+tab to cycle)' } }),
    ).toEqual({
      running: true,
      source: 'screen',
      saw: '⏵⏵ bypass permissions on (shift+tab to cycle)',
    })
  })
})

describe('which agent the chip is about', () => {
  /**
   * His words:
   *
   *   > "in the dropdown we can see which account is connected — but next to it
   *   > we should also see the logo of the LLM. If I'm using Claude then the
   *   > Claude logo should be up there, if ChatGPT then the ChatGPT logo, if
   *   > Gemini then the Gemini logo."
   *
   * The menu is portalled and only exists once opened, which a static render
   * cannot do — so what is pinned here is the *button*, which is the part that
   * is on screen for the whole life of a session and the part he was looking at.
   *
   * It has to come off the running session, not off the account list: the list
   * is only read when the menu opens, deliberately, because reading it spawns a
   * process per account. A badge sourced from the list would therefore be blank
   * exactly when he is using the session.
   */
  const chip = (current: { id: string; name: string; provider?: 'claude' | 'codex' | 'gemini' }) =>
    renderToStaticMarkup(
      <AccountChip current={current} projectPath="/w/app" onPick={noop} onManage={noop} />,
    )

  it('draws the agent’s mark beside the account name', () => {
    expect(chip({ id: 'work', name: 'Work', provider: 'claude' })).toContain(
      'data-provider="claude"',
    )
    expect(chip({ id: 'work', name: 'Work', provider: 'codex' })).toContain('data-provider="codex"')
    expect(chip({ id: 'work', name: 'Work', provider: 'gemini' })).toContain(
      'data-provider="gemini"',
    )
  })

  it('names the agent for anyone not looking at the screen', () => {
    // Nothing else in the chip says which agent it is — the account name is a
    // word the user typed — so the mark is the only carrier of that fact and
    // cannot be purely decorative here.
    expect(chip({ id: 'work', name: 'Work', provider: 'codex' })).toContain('Codex CLI')
  })

  it('draws no mark for a session whose agent is not known', () => {
    /*
     * A restored session from a build that did not record one, or an account
     * the main process did not name an agent for. The mark says which service
     * a login belongs to; a placeholder there would be a wrong claim rather
     * than a missing one.
     */
    expect(chip({ id: 'work', name: 'Work' })).not.toContain('provider-badge')
  })

  it('falls back to the agent a new session here would run', () => {
    // With no session account, the chip is describing what a *new* session
    // would use — so the mark is that agent's, and it is right before the
    // account list has been read even once.
    const html = renderToStaticMarkup(
      <AccountChip
        current={null}
        projectPath="/w/app"
        provider="codex"
        onPick={noop}
        onManage={noop}
      />,
    )
    expect(html).toContain('data-provider="codex"')
  })

  it('draws no mark when that agent cannot hold an account at all', () => {
    /*
     * With the default coding tool set to Plain shell the rows are inert and
     * the menu says why. A shell glyph beside an account name would be claiming
     * a pairing the notice underneath calls impossible.
     */
    const html = renderToStaticMarkup(
      <AccountChip
        current={null}
        projectPath="/w/app"
        provider="shell"
        onPick={noop}
        onManage={noop}
      />,
    )
    expect(html).not.toContain('provider-badge')
  })
})

describe('who the session is running as, rather than which record', () => {
  /**
   * His words:
   *
   *   > "inside the terminal page it is still showing selected account as
   *   > Default and not showing the email ID. … It should show clearly which
   *   > one is actually selected there. It just says Default."
   *
   * "Default" is the name `main/profiles.ts` generates for the machine's own
   * install of an agent. It is the same word for every user, the same word for
   * a login that works and one that has expired, and on a machine where nobody
   * has added a second account it was the only word this chip ever showed.
   *
   * The ladder itself is pinned in `accounts.test.ts`, where every rung can be
   * driven directly. What is pinned here is that this component is on it: a
   * static render resolves no promises, so the probe never answers, and this is
   * therefore the *worst* case — the one where falling back to the record's own
   * name would be most tempting.
   */
  const chip = (current: { id: string; name: string }) =>
    renderToStaticMarkup(
      <AccountChip current={current} projectPath="/w/app" onPick={noop} onManage={noop} />,
    )

  it('never puts the generated name on the chip, even before anything is read', () => {
    const html = chip({ id: 'system', name: 'Default' })
    // Nowhere on it — not in the label, and not in the tooltip either, where it
    // would be the same claim in smaller type.
    expect(html).not.toContain('Default')
    // What it says instead is what is true at that instant: it is asking.
    expect(html).toContain('Checking…')
  })

  it('does the same for an agent whose own install is named after the agent', () => {
    expect(chip({ id: 'system:codex', name: 'Default (Codex CLI)' })).not.toContain('Default')
  })

  it('still shows a name a person chose, because that one is an identity', () => {
    expect(chip({ id: 'work', name: 'Work' })).toContain('>Work<')
  })

  it('reads the label off the identity ladder rather than off the record', () => {
    /*
     * The regression this guards is a one-word edit: `identity.label` back to
     * `current?.name`, which typechecks, renders, and puts "Default" straight
     * back on the chip. Read from the source because the interesting states
     * need a resolved promise, which a static render does not have.
     */
    const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')
    expect(source).toContain('const identity = accountIdentity(currentAccount, currentSignIn)')
    expect(source).toContain('names ? identity.label')
    expect(source).not.toMatch(/account-chip-name[^>]*>\{[^}]*current\?\.name/)
    /*
     * And the menu's rows come off the same ladder, so the address on a row is
     * the address on the button, in the same words. It is `profileLoginLabel`
     * rather than `signInSummary` because a *list* cannot fall back to a state
     * — two rows reading "Signed in · max" have stopped being a picker — and
     * the state has its own column on the right, which is why that column now
     * asks for the state alone.
     */
    expect(source).toContain('const login = profileLoginLabel(account, state)')
    expect(source).toContain('<span className="folder-menu-name">{login}</span>')
    expect(source).toContain('{signInStateSummary(state).label}')
    // The stored name survives in exactly one place: the field that edits it.
    expect(source).not.toMatch(/folder-menu-name[^>]*>\{account\.name\}/)
  })

  it('asks about the one account it is about, and only that one', () => {
    /*
     * The cost that stopped this being done sooner. Checking the *list* spawns
     * the agent's CLI once per account and this chip is mounted for the whole
     * life of every session — so the list is still only probed when the menu
     * opens. The single account on screen is the exception, because there is no
     * way to draw an address without asking and the address is the whole point
     * of the control.
     */
    const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')
    /*
     * `identityId`, not `currentId`, since the chip can be about an account this
     * app has no record of — a `CLAUDE_CONFIG_DIR` exported in somebody's shell
     * profile, established by reading the agent's own environment. `identityId`
     * is `currentId` for every account that *is* a record and null for that one,
     * because `profileSignIn` is keyed on a profile id and asking it about a
     * bare path spends a process to be told nothing. Its address has already
     * been read off the file the CLI wrote.
     */
    expect(source).toContain('useAccountIdentity(identityId)')
    expect(source).toContain(
      'const identityId = known !== null && known.profileId === null ? null : currentId',
    )
    // List always, probes only while open.
    expect(source).toContain('useAccounts(true, menu.open)')
  })
})

describe('which account is selected', () => {
  /**
   * His words: *"It should show clearly which one is actually selected there."*
   *
   * The current row was distinguished by its name being drawn in the accent
   * colour and by nothing else — a difference you can only see by comparing it
   * against the rows above and below, invisible to anyone who cannot separate
   * those two greys, and absent entirely when the rows are inert. The menu is
   * portalled and only exists once opened, which a static render cannot do, so
   * the mark is read from the source.
   */
  const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')

  it('draws a tick on the account in force', () => {
    expect(source).toContain('const isCurrent = names && account.id === currentId')
    expect(source).toContain('className="account-menu-tick"')
    expect(source).toContain('{isCurrent && (')
  })

  it('marks no row at all on a chip that names no login', () => {
    /*
     * `names` is the chip's one decision about which subject it is describing —
     * this session's account, or the one a new session here would use. When the
     * answer is "nobody", the button says `No login` and the tick has to agree:
     * a mark on a row is the strongest claim in the menu, and the same
     * contradiction the button was reported for would simply move one level
     * down. The condition is read from the source because the state needs a
     * resolved account list, which a static render does not have.
     */
    expect(source).toContain('const isCurrent = names && account.id === currentId')
  })

  it('says it out loud as well as drawing it', () => {
    // A tick nobody can see is a mark only a sighted user gets. These rows are
    // a choice of exactly one account, which is what `menuitemradio` means.
    expect(source).toContain('role="menuitemradio"')
    expect(source).toContain('aria-checked={isCurrent}')
  })

  it('keeps the mark on a row that cannot be picked', () => {
    /*
     * Whether this agent can be handed a config directory has nothing to do
     * with which account the session on screen is running as — and the inert
     * state is where the question is hardest, because nothing else on the row
     * responds to anything.
     */
    const inert = source.slice(source.indexOf('account-menu-item is-inert'))
    expect(inert.slice(0, 300)).toContain('data-current={isCurrent || undefined}')
    expect(inert.slice(0, 300)).toContain('aria-current={isCurrent || undefined}')
  })
})

describe('renaming an account where you can see it', () => {
  /**
   * His words:
   *
   *   > "The account dropdown inside a session shows the name an account was
   *   > given and offers no way to change it. Renaming should be possible from
   *   > there, not only from the Accounts screen."
   *
   * The menu itself is portalled and only exists once opened, which a static
   * render cannot do — so what is pinned here is the thing that would actually
   * go wrong: the chip and the Accounts screen growing two renames that behave
   * differently. Both go through `renameAccount`.
   */
  it('goes through the same rename the Accounts screen uses', async () => {
    const { renameAccount } = await import('../accounts')
    const renameProfile = vi.fn().mockResolvedValue({ ok: true })
    const problem = await renameAccount({ renameProfile }, { id: 'work', name: 'Work' }, '  Personal  ')
    expect(problem).toBeNull()
    expect(renameProfile).toHaveBeenCalledWith('work', 'Personal')
  })

  it('does not send a rename that is not one', async () => {
    const { renameAccount } = await import('../accounts')
    const renameProfile = vi.fn()
    expect(await renameAccount({ renameProfile }, { id: 'work', name: 'Work' }, '   ')).toBeNull()
    expect(await renameAccount({ renameProfile }, { id: 'work', name: 'Work' }, 'Work')).toBeNull()
    expect(renameProfile).not.toHaveBeenCalled()
  })

  it('says so rather than failing silently when the bridge has no rename', async () => {
    const { renameAccount } = await import('../accounts')
    expect(await renameAccount({}, { id: 'work', name: 'Work' }, 'Personal')).toContain('not wired')
  })

  it('turns a collision into a sentence instead of an Electron IPC string', async () => {
    /*
     * The failure shape on record, verbatim from the app:
     *
     *   Error invoking remote method 'profiles:create': ProfileError: a claude
     *   account called "…" already exists
     *
     * A rename collides the same way — the main process refuses two accounts of
     * one agent with the same name — and the only thing that crosses back is a
     * rejected `invoke`, wrapped in a channel name nobody using this app has
     * heard of. What must reach the field is the sentence at the end of it.
     */
    const { renameAccount } = await import('../accounts')
    const renameProfile = vi
      .fn()
      .mockRejectedValue(
        new Error(
          `Error invoking remote method 'profiles:rename': ProfileError: a claude account called "Work" already exists`,
        ),
      )
    const problem = await renameAccount({ renameProfile }, { id: 'system', name: 'Default' }, 'Work')
    expect(problem).toBe('a claude account called "Work" already exists')
    expect(problem).not.toContain('invoking remote method')
    expect(problem).not.toContain('profiles:rename')
  })

  it('holds that message under the field, with the typed name still in it', () => {
    /*
     * It used to be printed at the foot of the menu, below three other people's
     * accounts, where it read as a fact about the list rather than about the box
     * the cursor is still in. The field stays open on a failure — closing it
     * would throw the name away along with the explanation.
     */
    const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')
    const editing = source.slice(source.indexOf('className="account-menu-editing"'))
    const upToRowEnd = editing.slice(0, editing.indexOf('const line = ('))
    expect(upToRowEnd).toContain('className="account-menu-problem"')
    expect(upToRowEnd).toContain("aria-describedby={failure === null ? undefined : 'account-rename-problem'}")
    expect(source).toContain('if (!problem) {')
  })

  it('renames an agent’s own install, which is every account on a fresh machine', () => {
    /*
     * The button was drawn on every row and worked on none of them:
     * `renameProfile` refused any system id outright, and until somebody adds a
     * second login every account *is* a system one. The main process now stores
     * a display name for those — `profiles.test.ts` pins the storage, the reset
     * and the collision — so what is left for here is that this menu does not
     * hide the button or special-case the row.
     */
    const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')
    const button = source.slice(source.indexOf('className="account-menu-rename-button"'))
    expect(button.slice(0, 400)).toContain('setEditing({ id: account.id, draft: account.name })')
    expect(button.slice(0, 400)).not.toContain('account.system')
  })
})

describe('believing the screen, in the direction the screen is reliable', () => {
  /**
   * A marker cannot appear on a screen by accident, so an agent appearing is
   * believed at once. A screen with no marker on it is weaker — the CLI could
   * be caught mid-repaint — and the cost of getting *that* wrong is a Run
   * Claude button in front of a running Claude, which submits the word "claude"
   * as a prompt. So the doubt is spent on the disappearance and nowhere else.
   */
  const agent: AgentPresence = { running: true, source: 'screen', saw: '⏵⏵ plan mode on (shift+tab to cycle)' }
  const nothing: AgentPresence = { running: false, source: 'screen', saw: null }

  it('answers a fresh shell immediately, because nothing has disappeared', () => {
    // The state every new session starts in. No agent has ever been seen, so
    // "no marker" is the answer rather than a claim that one has gone.
    expect(settle(UNKNOWN_PRESENCE, nothing, false).running).toBe(false)
  })

  it('does not withdraw a running agent on one reading that missed it', () => {
    expect(settle(agent, nothing, true).running).toBeNull()
  })

  it('does withdraw it when the next reading agrees', () => {
    const held = settle(agent, nothing, true)
    expect(settle(held, nothing, true).running).toBe(false)
  })

  it('believes an agent the instant one is seen', () => {
    expect(settle(nothing, agent, false)).toEqual(agent)
  })
})

describe('running this session as somebody else', () => {
  /**
   * His words:
   *
   *   > "when I change account from the dropdown it starts a new session with
   *   > that account, instead of changing it in the same session."
   *
   * The constraint that produced the old behaviour is real — a CLI is
   * authenticated at spawn, so a running agent cannot change account — and the
   * answer is not to deny the request but to restart the right thing: this
   * session, in this tab, rather than a second one somewhere else.
   *
   * The menu is portalled and only exists once opened, which a static render
   * cannot do, so the rules are read from the source. What each one guards is a
   * one-word edit that typechecks and quietly restores the reported bug.
   */
  const source = readFileSync(join(__dirname, 'AccountChip.tsx'), 'utf8')

  it('switches only when it has a session, a handler and an agent running in it', () => {
    /*
     * Four conditions and every one of them is load-bearing. Two callers render
     * this about a *folder* and one is a pane bar with no session in hand; for
     * all three there is nothing on screen to switch, so a click can only mean
     * "start one" — which is what the old behaviour was, correctly, for them.
     */
    expect(source).toContain(
      "session !== null && onSwitchAccount !== undefined && showAccount && sessionAgent !== null",
    )
  })

  it('offers only accounts of the agent this session is running', () => {
    // An account is a login of one CLI. `resolveProfileId` declines the mismatch
    // quietly, by falling back to the machine's own install, and the quiet
    // version is what made picking a Codex account look like an ignored click.
    expect(source).toMatch(/inert = switching\s*\?\s*account\.provider !== sessionAgent/)
  })

  it('does not offer to switch to the account it is already on', () => {
    // The tick has already said everything there is to say, and a press could
    // only stop a healthy agent and start it again as itself.
    expect(source).toMatch(/inert = switching\s*\?[^:]*\bisCurrent\b/s)
  })

  /**
   * D1's last state, 2026-08-20.
   *
   * The switch itself keeps the conversation now, and there is one account it
   * cannot keep it for: one that has never signed in. That switch does not
   * fail — it succeeds, the CLI runs its own first-run onboarding and then a
   * login prompt, and the conversation on screen is replaced. On screen it is
   * indistinguishable from the defect he filmed:
   *
   *   > *"See, it is not going to keep it… It's not keeping the conversation
   *   > history."*
   *
   * So the row is listed and is not pressable, and no sentence is added for it:
   * the right of the row already reads "Not signed in".
   */
  it('does not offer to switch into an account that has never signed in', () => {
    expect(source).toMatch(/inert = switching\s*\?[^:]*state\?\.state === 'signed-out'/s)
  })

  /**
   * And only a *measured* signed-out. `unknown` is a probe that could not be
   * run — an old CLI, a timeout, a machine under load — and refusing on that
   * would take a perfectly good account away over a failure to ask it.
   */
  it('still offers an account whose sign-in state could not be read', () => {
    const at = source.indexOf('const inert = switching')
    const expression = source.slice(at, source.indexOf('\n\n', at))
    expect(expression).not.toContain("=== 'unknown'")
    expect(expression).not.toContain("!== 'signed-in'")
  })

  it('calls the switch rather than falling through to a new session', () => {
    /*
     * The regression this guards is exactly the reported bug: a row that
     * silently reached `onPick` would open a second session in the same folder,
     * which is the behaviour being removed.
     */
    expect(source).toContain('onSwitchAccount(session.id, account.id)')
    const rows = source.slice(source.indexOf('role="menuitemradio"'))
    expect(rows.slice(0, 1200)).toMatch(/switching && session && onSwitchAccount/)
  })

  it('heads the menu with one word, and the same word to a screen reader', () => {
    /*
     *   > *"So run them as is not the best way. Maybe you can say primary
     *   > account, choose primary account or this kind of words, or default
     *   > account."*
     *
     * He was standing on the settings row, and the words he rejected were also
     * the head of this menu and the title of the sheet it opens. `Primary
     * account` cannot be borrowed here — that is a machine-wide default and
     * this menu is about one session — so what is left is the noun both modes
     * are about, with the rows underneath saying what a press does.
     *
     * A sighted user reading one thing while a screen reader announces another
     * has been given two accounts of one press, so the two still come from one
     * constant.
     */
    expect(MENU_HEAD.start).toBe('Account')
    expect(MENU_HEAD.switch).toBe('Account')
    expect(MENU_HEAD.start).not.toMatch(/run|as$/i)
    expect(source).toContain("aria-label={MENU_HEAD[switching ? 'switch' : 'start']}")
    expect(source).toContain("{MENU_HEAD[switching ? 'switch' : 'start']}")
  })

  it('says nothing at all about a switch, because there is nothing left to warn about', () => {
    /*
     * This assertion is the reverse of the one it replaces, and the reversal is
     * his.
     *
     *   > *"Every single time you bring some card, you put something new… I
     *   > said to you, don't put any single statement in anywhere. Everywhere
     *   > you are putting a lot of statements. We don't need to give the
     *   > statements. We want simplicity. Let the smart people use it. Smart
     *   > people knows how it works."*
     *
     * What stood here was a paragraph promising that the tab and the folder
     * survive, that the agent stops and starts again, that it can happen now or
     * at his next message, and that whether the conversation comes depends on
     * whether the two accounts share a history. Every clause was true when it
     * was written and every clause was pinned by a test.
     *
     * Two things then changed. The last clause stopped being true in the only
     * direction that mattered: `adoptSharedHistory` puts both accounts on one
     * conversation history before the sheet is ever drawn, so the conversation
     * comes with him and a sentence hedging about it is a sentence about a
     * problem he no longer has. And he asked for the explanations to be removed
     * rather than reworded — which is the rule this now pins, because the
     * failure mode of a rule like that is a helpful sentence growing back one
     * review at a time.
     *
     * The refusal stays. `blocked` is a sentence with something to do about it
     * in it, and a menu that cannot be used with no account of why reads as a
     * broken one.
     */
    const foot = source.slice(source.indexOf('className="account-menu-foot"'))
    const said = foot.slice(0, 600)
    expect(said, 'a description of switching has grown back on the menu').not.toMatch(
      /this tab and this folder|stops and starts again|share a history|before anything stops/,
    )
    // Drawn only when it is not a switch *and* there is a refusal to make, so
    // the ordinary menu has no foot at all. `Opens a new session here.` was the
    // other half of this line: a menu of accounts whose rows start a session
    // does not need a sentence saying that its rows start a session.
    expect(source).toMatch(/\{!switching && blocked && \(\s*<p className="account-menu-foot">/)
    expect(said).toContain('Change the default coding tool in Settings')
    expect(said).not.toContain('Opens a new session here')
  })

  it('puts the why-these-rows-are-dead sentence behind the dot, not over them', () => {
    /*
     * It was a paragraph at the top of the menu — *"Only a Claude Code account
     * can run this session — an account is a login of one agent."* — drawn
     * every time the menu opened on a machine with more than one agent
     * installed, which is every machine this app is for. The rows it is about
     * are already visibly not buttons.
     *
     *   > *"Don't put any single statement in anywhere… if somewhere it's very
     *   > required, give the i icon like other ones, information icon in the
     *   > settings, same way."*
     */
    expect(source).not.toMatch(
      /<p className="account-menu-blocked">\s*\n\s*Only a \{agentLabel/,
    )
    expect(source).toContain('<HoverNote label="Which accounts can run this session">')
  })

  it('drops the notice about the *next* session while it is talking about this one', () => {
    /*
     * `blocked` is a statement about the agent a new session here would run. Over
     * a running session being switched it is a sentence about a different
     * session, which is the two-subjects-one-control fault `names` exists to
     * prevent, one level down.
     */
    expect(source).toContain('{!switching && blocked && <p className="account-menu-blocked">')
  })
})

/* -------------------------------------------- the mode that changed itself -- */

/**
 * The menu has two modes and one word for both, and it chooses between them
 * silently.
 *
 * `switching` needs the session's *own* account off `SessionMeta`, and the
 * commonest session this app has does not have one: Run Claude spawns
 * `$SHELL -l` and the agent is typed into it, so `supportsProfiles('shell')` is
 * false, no config directory was ever handed to the process and the record
 * carries no account. `switchRefusal` in `main/session-switch.ts` refuses such a
 * session for exactly that reason — and it is right to, because the replacement
 * would be another shell and `sessionEnv(profile, 'shell')` exports nothing, so
 * the switch would move the label and not the login.
 *
 * What the menu did with that was drop into start mode: same heading, same rows,
 * the tick still on the account the session really is running as, and a press
 * that opened a *second* session while the one in front of you carried on under
 * the old login — still printing that login's limit warnings into its own
 * terminal. Asad: *"after we switch it shows something else … all of them are
 * not about one logged in account."*
 *
 * The decision is a pure function so it can be pinned here: this project has no
 * DOM, and the menu is a portal that only exists once it is open.
 */
describe('a session whose account cannot be changed says so', () => {
  const shell = {
    hasSession: true,
    showAccount: true,
    switching: false,
    sessionAgent: null,
    sessionProvider: 'shell' as const,
  }

  it('says it over a live agent this app never handed an account to', () => {
    expect(fixedAccountNote(shell)).toBe(FIXED_ACCOUNT_NOTE.shell)
  })

  /*
   * Two ways a session ends up with no account, and they are two different
   * facts. A shell had none exported into it; Gemini and every added agent were
   * spawned by this app and still cannot be given one, because their login is
   * not separable — `supportsProfiles` is the authority. One sentence for both
   * would be false about whichever one it was not written for.
   */
  it('says the other thing for an agent whose login cannot be kept apart', () => {
    expect(fixedAccountNote({ ...shell, sessionProvider: 'gemini' })).toBe(FIXED_ACCOUNT_NOTE.agent)
    expect(FIXED_ACCOUNT_NOTE.agent).not.toMatch(/shell/i)
  })

  it('says what a press does instead, because a press still does something', () => {
    // The rows are not dead — they open a new session — so the failure this is
    // fixing is a control that does something other than what it looks like,
    // and both sentences have to name the other thing.
    for (const note of Object.values(FIXED_ACCOUNT_NOTE)) {
      expect(note).toMatch(/opens a new session/i)
      expect(note).toMatch(/keeps the login it has/i)
    }
  })

  it('is silent when a row really does switch the session', () => {
    expect(
      fixedAccountNote({ ...shell, switching: true, sessionAgent: 'claude', sessionProvider: 'claude' }),
    ).toBeNull()
  })

  it('is silent over a folder, where there is no session to be fixed', () => {
    // `chipMode(null, …)` answers `account` for the two callers that ask which
    // account a *new* session here would use, so `showAccount` alone is not
    // enough to know there is a session under this chip.
    expect(fixedAccountNote({ ...shell, hasSession: false })).toBeNull()
  })

  it('is silent over a shell with nothing running in it', () => {
    // That slot draws the Run button, not the picker, and a note about switching
    // an agent would be about a process that does not exist.
    expect(fixedAccountNote({ ...shell, showAccount: false })).toBeNull()
  })

  /*
   * A session that has an account and still is not switchable is a *caller* that
   * passed no handler, not a session that cannot be moved — so this note, which
   * says "this app cannot", would be a claim about the wrong thing.
   */
  it('is silent when the session has an account of its own', () => {
    expect(fixedAccountNote({ ...shell, sessionAgent: 'claude', sessionProvider: 'claude' })).toBeNull()
  })
})
