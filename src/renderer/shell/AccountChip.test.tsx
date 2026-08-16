import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AccountChip, RUN_AGENT_COMMAND } from './AccountChip'
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
    return renderToStaticMarkup(
      <AccountChip
        current={agentRunning ? { id: 'work', name: 'Work' } : null}
        projectPath="/w/app"
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

  it('offers Run Claude once the screen says there is no agent', () => {
    // The state every new session starts in, and the one this item is about.
    expect(chipMode(shell, { running: false, source: 'screen', saw: null })).toBe('run')
  })

  it('withdraws the offer and reveals the picker the moment one is running', () => {
    const saw = '⏵⏵ bypass permissions on (shift+tab to cycle)'
    expect(chipMode(shell, { running: true, source: 'screen', saw })).toBe('account')
  })

  it('offers Run Claude again after the agent is quit and the shell comes back', () => {
    // The case a control keyed off "the user typed claude" gets wrong forever:
    // `/exit` returns the shell and the session is still alive.
    expect(chipMode(shell, { running: true, source: 'screen', saw: 'x' })).toBe('account')
    expect(chipMode(shell, { running: false, source: 'screen', saw: null })).toBe('run')
  })

  it('never draws Run Claude for a caller asking about a folder', () => {
    expect(chipMode(null, UNKNOWN_PRESENCE)).toBe('account')
    expect(chipMode(null, { running: false, source: 'screen', saw: null })).toBe('account')
  })

  it('wears the account picker the moment an agent is what the session is', () => {
    const html = chip(true)
    expect(html).toContain('Work')
    expect(html).not.toContain('Run Claude')
  })

  it('never offers to start an agent in a session that has ended', () => {
    // The pty is gone; typing into it does nothing at all, and a button that
    // does nothing is the dead control the brief forbids.
    const html = renderToStaticMarkup(
      <AccountChip
        current={null}
        projectPath="/w/app"
        session={{ id: 's1', provider: 'shell', exited: true }}
        onPick={noop}
        onManage={noop}
      />,
    )
    expect(html).toContain('Run Claude')
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

describe('what Run Claude actually does', () => {
  it('types the command into that session’s own terminal', () => {
    /*
     * His words: "it automatically types /claude and sends", i.e. the app runs
     * the command rather than making you remember it. Written into the pty, so
     * the terminal view shows the same keystrokes — chat mode and the toolbar
     * are views of one session, not second channels into it.
     */
    expect(RUN_AGENT_COMMAND).toBe('claude\r')
  })

  it('sends a carriage return, which is what Return is on a terminal', () => {
    // `\n` is a line feed. A pty carries what a keyboard sends.
    expect(RUN_AGENT_COMMAND.endsWith('\r')).toBe(true)
    expect(RUN_AGENT_COMMAND).not.toContain('\n')
  })

  it('does not resume a conversation nobody asked to resume', () => {
    // `--continue` picks the last conversation written in the folder, which
    // `session-transcript.ts` records at length is frequently not this
    // session's. The button says Run Claude and that is all it does.
    expect(RUN_AGENT_COMMAND).not.toContain('--continue')
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
    // as "no agent" it would put a Run Claude button in front of a running one.
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
