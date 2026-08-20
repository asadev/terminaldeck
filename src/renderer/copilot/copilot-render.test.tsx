import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import { COPILOT_BLURB } from './identity'
import type { Copilot } from './useCopilot'
import type { CopilotStage, CopilotStateView } from './copilot-model'

/**
 * The copilot's surfaces, actually rendered.
 *
 * Five claims here cannot be checked by a pure-logic test, because all five
 * are about what is on the screen:
 *
 *  1. **The pinned row is a singleton.** No ✕ that ends it, no ＋ that starts a
 *     second. The rail's ✕ is the one control in this window that irreversibly
 *     ends a session; a second glyph like it, a few pixels away, meaning
 *     something else, is precisely the confusion the rail already carries a
 *     paragraph about avoiding.
 *  2. **The first run explains itself.** A person meeting a signed-out copilot
 *     has to be told why before they can act, and the words have to be on the
 *     screen rather than in a comment.
 *  3. **The empty state is a developer's.** No inbox, no calendar, no digest —
 *     *"most probably for developers, to get things done for development."*
 *  4. **The window is a window.** Since 2026-08-17 the copilot has the chrome
 *     every session has, which means this component must *not* draw a second
 *     one: no state line, no private Terminal/Chat switch, no Stop of its own.
 *     Those are the toolbar's now, and a copy left behind here would be the
 *     same fact stated twice, forty pixels apart. Asad asked for the window
 *     because the page had made its terminal *"a small box inside the copilot
 *     page"*, so what is pinned is that everything above the pane is
 *     conditional.
 *  5. **It can be started over.** The bar's one extra control said Stop until
 *     2026-08-20, and stopping took away the tab the button was drawn on —
 *     *"I don't understand what is the purpose of stop button."* It says
 *     Restart now, which is the act somebody standing in front of it wants,
 *     and it leaves the window where it is.
 *
 * ## The harness
 *
 * There is no DOM in this project's test setup and no jsdom in its
 * dependencies, so these render through `react-dom/server`, as
 * `dialog-render.test.tsx` already does. `Modal` portals into `document.body`,
 * which SSR has neither of, so the portal is swapped for a passthrough and
 * `document` stubbed to the one property that call site reads. Effects do not
 * run under SSR, which is what makes this the *first paint* — before any IPC
 * has answered, which is the frame these components have to be right in.
 */

vi.mock('react-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-dom')>()
  return { ...actual, createPortal: (node: ReactNode) => node }
})

;(globalThis as { document?: unknown }).document = { body: {} }

const { CopilotEntry } = await import('./CopilotEntry')
const { CopilotRestart } = await import('./CopilotRestart')
const { CopilotMachines } = await import('./CopilotMachines')
const { CopilotView } = await import('./CopilotView')
const { CopilotConsent } = await import('./CopilotConsent')

const noop = (): void => {}

const state = (over: Partial<CopilotStateView> = {}): CopilotStateView => ({
  status: 'running',
  sessionId: 'copilot-session',
  paths: {
    root: '/u/copilot',
    instructions: '/u/copilot/CLAUDE.md',
    memory: '/u/copilot/memory',
    log: '/u/copilot-log',
    actions: '/u/copilot-log/actions.jsonl',
  },
  startedAt: 1,
  problem: null,
  recordsHeld: true,
  ...over,
})

function copilot(stage: CopilotStage, over: Partial<Copilot> = {}): Copilot {
  return {
    state: state(),
    signIn: null,
    stage,
    loading: false,
    ensure: noop,
    stop: noop,
    restart: noop,
    refresh: noop,
    ...over,
  }
}

/* ------------------------------------------------------------ the entry -- */

describe('the pinned sidebar entry', () => {
  const html = renderToStaticMarkup(
    <CopilotEntry stage="ready" state={state()} active={false} onOpen={noop} />,
  )

  it('names itself', () => {
    expect(html).toContain('>Copilot</span>')
  })

  it('offers no way to end it and no way to start a second', () => {
    // A singleton does not behave like a session row. `aria-label="Close` is
    // how every closable row in the rail spells its ✕.
    expect(html).not.toContain('aria-label="Close')
    expect(html).not.toContain('New session')
  })

  it('says its condition in words, not only in a colour', () => {
    expect(html).toContain('aria-label="Ready"')
  })

  it('makes no claim when the window has not asked', () => {
    const quiet = renderToStaticMarkup(<CopilotEntry active={false} onOpen={noop} />)
    expect(quiet).toContain('>Copilot</span>')
    expect(quiet).not.toContain('status-dot')
    expect(quiet).toContain(COPILOT_BLURB)
  })
})

/* ------------------------------------------------------------- the view -- */

describe('a signed-out account', () => {
  // `mode="terminal"`, because that is what a first run actually opens on:
  // `defaultPane` says so and `App.tsx` seeds it into the window's own
  // `sessionView`. The pane is a prop now rather than this component's own
  // state — there is one mode switch in the window and it is the toolbar's.
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('first-run')}
      mode="terminal"
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('says it is an ordinary account rather than a login of the copilot’s own', () => {
    /*
     * This block used to assert the opposite paragraph — a keychain closed to a
     * sandboxed process, a login the copilot keeps inside its own boundary, "the
     * boundary working, not a fault". All of that was true of a jailed copilot,
     * and it was the single largest cost of jailing it: it started signed out on
     * every machine, every time.
     *
     * Now this state means what it means for any other session: that account is
     * signed out. The pinned words are the ones that stop a person hunting for a
     * copilot-specific login that does not exist.
     */
    expect(html).toContain('runs as one of your accounts')
    expect(html).toContain('no login of its own')
    expect(html).toContain('Settings → Accounts')
    expect(html).not.toContain('keychain')
    expect(html).not.toContain('boundary working')
  })

  it('tells the reader what to actually do', () => {
    expect(html).toContain('/login')
    expect(html).toContain('paste the code back')
  })

  it('points at the pane the login can actually happen in', () => {
    /*
     * The window opens on the terminal for a first run — `defaultPane` decides
     * that and `App.tsx` seeds it into the same `sessionView` every session's
     * mode lives in — so this component is *told* which pane is in front and has
     * to describe the right one. A sentence pointing at something not on the
     * screen is a small lie that makes a reader doubt the rest of the paragraph,
     * which is the paragraph explaining why a signed-out assistant is not a
     * broken one.
     */
    expect(html).toContain('data-shown="true"')
    expect(html).toContain('Its terminal is below')
    // And the other way round, where the terminal is one press away rather than
    // below — the press being the window's own mode switch, not a control this
    // component draws any more.
    const onChat = renderToStaticMarkup(
      <CopilotView
        copilot={copilot('first-run')}
        mode="chat"
        activity={{ deckControlActivity: async () => [] }}
      />,
    )
    expect(onChat).toContain('press Terminal in the bar above')
    expect(onChat).not.toContain('Its terminal is below')
  })
})

describe('the running copilot', () => {
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('ready', { signIn: { state: 'signed-in', account: 'a@b.c', plan: 'Max' } })}
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('draws its pane and no chrome of its own', () => {
    /*
     * The whole of the 2026-08-17 change, seen from the markup. A running,
     * signed-in copilot with no tour behind it has nothing to say above its
     * conversation — so the record strip has no children at all and
     * `.cp-strip:empty` takes it out of the layout, which is what makes this a
     * window rather than *"a small box inside the copilot page"*.
     *
     * Every one of the four things asserted absent here was drawn by this
     * component's own bar until that day, and every one of them is the window's
     * now: the account is on the account chip, the two pane buttons are the mode
     * switch, and Stop is the chip beside it.
     */
    expect(html).toContain('cp-strip scroll-fade"></div>')
    expect(html).not.toContain('cp-bar')
    expect(html).not.toContain('a@b.c')
    expect(html).not.toContain('>Chat</button>')
    expect(html).not.toContain('>Terminal</button>')
    expect(html).not.toContain('>Stop</button>')
  })

  it('still has something above the pane when there is something to say', () => {
    // The strip is absent, not deleted. A first run fills it, which is the case
    // it exists for.
    const signedOut = renderToStaticMarkup(
      <CopilotView
        copilot={copilot('first-run')}
        activity={{ deckControlActivity: async () => [] }}
      />,
    )
    expect(signedOut).not.toContain('cp-strip scroll-fade"></div>')
    expect(signedOut).toContain('cp-notice')
  })
})

describe('which machine’s copilot', () => {
  const here = { id: '', name: 'this Mac', reach: 'ready' as const, open: true }
  const pc = { id: 'm1', name: 'office-pc', reach: 'ready' as const, open: true }

  it('draws nothing at all with one machine', () => {
    // A switch with one position is a label, and a label saying the name of the
    // computer you are sitting at is exactly the standing sentence this app has
    // spent a week deleting. The New Session dialog draws no Where step for the
    // same person for the same reason.
    expect(renderToStaticMarkup(<CopilotMachines machines={[here]} chosen="" onChoose={noop} />)).toBe('')
  })

  it('draws a row each once there are two, and marks the one you are on', () => {
    const html = renderToStaticMarkup(
      <CopilotMachines machines={[here, pc]} chosen="m1" onChoose={noop} />,
    )
    expect(html).toContain('this Mac')
    expect(html).toContain('office-pc')
    expect(html).toContain('aria-checked="true"')
  })

  it('keeps a machine it cannot reach, disabled, with the remedy on hover', () => {
    /*
     * *"We always need a truth."* A machine that paired this computer as a guest
     * is one he can see in the rail two inches away, and leaving it out would be
     * the switch quietly showing a subset — the failure this project keeps
     * finding. The reason is on hover rather than on the page, which is his
     * standing rule about sentences explaining states most people never see.
     */
    const html = renderToStaticMarkup(
      <CopilotMachines
        machines={[here, { ...pc, reach: 'refused' as const }]}
        chosen=""
        onChoose={noop}
      />,
    )
    expect(html).toContain('disabled')
    expect(html).toContain('Pair it again as your own')
    expect(html).not.toContain('guest devices do not')
  })

  /**
   * A server, on the switch that used to be silent about servers.
   *
   * *"So here icon not still choose the local connected server, by the way, I
   * think. Maybe server is not connected, I don't know."* — he could not tell
   * *not connected* from *not shown*, because it was the second one. It is drawn
   * now, and it cannot be pressed: a server does not run this app, so there is no
   * copilot over there. The move is on that server's own page, which is where
   * `SERVERS-DESIGN.md` §6.2 puts it.
   */
  it('lists a server, unpressable, and points at the page the grant lives on', () => {
    const html = renderToStaticMarkup(
      <CopilotMachines
        machines={[here, { id: 'server s1', name: 'web-01', reach: 'server' as const, open: false }]}
        chosen=""
        onChoose={noop}
      />,
    )
    expect(html).toContain('web-01')
    expect(html).toContain('disabled')
    expect(html).toContain('is a server')
    expect(html).toContain('on the server')
  })

  it('says wait, not re-pair, about a machine that is merely offline', () => {
    // Two different remedies. Telling somebody to pair a sleeping PC again would
    // send them to the wrong keyboard for the wrong reason.
    const html = renderToStaticMarkup(
      <CopilotMachines
        machines={[here, { ...pc, reach: 'unreachable' as const }]}
        chosen=""
        onChoose={noop}
      />,
    )
    expect(html).toContain('is not connected')
    expect(html).not.toContain('guest')
  })
})

describe('starting it over', () => {
  it('says Restart, not Stop', () => {
    /*
     * The word is the whole fix. Stop's only visible effect was this window
     * going away — the copilot's tab is derived from its pty — so the control
     * erased the thing it was drawn on and said nothing about the pinned row
     * that brings it back. Restart is what a person in this bar is asking for.
     */
    const html = renderToStaticMarkup(
      <CopilotRestart
        copilot={copilot('ready', {
          signIn: { state: 'signed-in', account: 'a@b.c', plan: 'Max' },
        })}
      />,
    )
    expect(html).toContain('>Restart</button>')
    expect(html).not.toContain('>Stop</button>')
    // And what it costs, on the control itself: one conversation, and nothing
    // on disk. A button whose obvious reading is "destroy" has to say which.
    expect(html).toContain('starts a fresh one')
    expect(html).toContain('untouched')
    // Naming the account, because "signed in" with no login is the half-fact
    // this app keeps taking back out.
    expect(html).toContain('a@b.c')
  })

  it('is absent rather than greyed while nothing is running', () => {
    // There is nothing to restart, and a disabled control would teach that the
    // app could do it if only something were different.
    expect(
      renderToStaticMarkup(
        <CopilotRestart copilot={copilot('stopped', { state: state({ status: 'stopped' }) })} />,
      ),
    ).toBe('')
  })
})

describe('the empty state', () => {
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('stopped', { state: state({ status: 'stopped', sessionId: null }) })}
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('suggests the things a developer wants and nothing an inbox would', () => {
    expect(html).toContain('which of your sessions needs you')
    expect(html).toContain('review a diff')
    expect(html).toContain('prompt')
    for (const wrong of ['inbox', 'calendar', 'email', 'meeting']) {
      expect(html.toLowerCase(), wrong).not.toContain(wrong)
    }
  })

  it('offers to start it', () => {
    expect(html).toContain('Start it')
  })
})

describe('a start that failed', () => {
  /*
   * This block used to cover a machine with no confinement mechanism, where the
   * copilot refused to start at all — every Windows machine. That refusal is
   * gone: an ordinary session needs no boundary in order to exist. What is left
   * is the ordinary failure, which still has to reach the screen as a sentence
   * rather than as a page that silently offers a button again.
   */
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('stopped', {
        state: state({
          status: 'stopped',
          sessionId: null,
          problem: 'The copilot runs on Claude Code, which is not installed on this machine.',
        }),
      })}
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('says why, and still offers the button that would retry it', () => {
    expect(html).toContain('which is not installed on this machine')
    expect(html).toContain('Start it')
  })
})

describe('the sessions it started', () => {
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('ready')}
      startedSessions={[{ id: 's2', label: 'Session 4', runId: 'turn-9' }]}
      onOpenSession={noop}
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('lists them, so the link runs forward as well as back', () => {
    expect(html).toContain('Sessions it started')
    expect(html).toContain('Session 4')
  })
})

/* ------------------------------------------------------ the confirmation -- */

describe('the consent dialog', () => {
  const question = {
    id: 'q1',
    tool: 'settings.write' as const,
    tier: 'alter' as const,
    summary: 'Change settings: appearance.theme to "dark"',
    args: { scope: 'settings', patch: { 'appearance.theme': 'dark' } },
    requestedAt: Date.now(),
    expiresAt: Date.now() + 120_000,
  }
  const html = renderToStaticMarkup(
    <CopilotConsent
      question={question}
      titles={{ 'settings.write': 'Change a setting' }}
      onAnswer={noop}
    />,
  )

  it('says what is being asked', () => {
    expect(html).toContain('Change a setting')
    expect(html).toContain('appearance.theme')
  })

  it('says who is asking', () => {
    expect(html).toContain('The copilot is asking')
  })

  it('shows every argument rather than a count of them', () => {
    expect(html).toContain('>scope</dt>')
    expect(html).toContain('>patch</dt>')
    expect(html).not.toContain('2 settings')
  })

  it('says what happens if nobody answers', () => {
    expect(html).toContain('Refused automatically')
  })

  it('names the tier and the exact tool, so the log and the dialog agree', () => {
    expect(html).toContain('>alter</span>')
    expect(html).toContain('>settings.write</span>')
  })

  it('offers exactly one way to say yes, and it is not the default', () => {
    // "Allow once" and nothing that remembers the answer: there is deliberately
    // no allow-always, because an unscoped standing grant answered in the middle
    // of an interruption is how a gate becomes a formality.
    expect(html).toContain('Allow once')
    expect(html).not.toContain('Always')
    expect(html).toContain('>Refuse</button>')
    // The refusal carries the autofocus, so a hurried Return does not approve.
    expect(html).toMatch(/autofocus[^>]*>Refuse<|>Refuse<\/button>/)
  })

  it('draws nothing when there is no question', () => {
    expect(renderToStaticMarkup(<CopilotConsent question={null} onAnswer={noop} />)).toBe('')
  })
})
