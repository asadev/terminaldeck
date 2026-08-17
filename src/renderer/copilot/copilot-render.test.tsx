import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import { panelSpec } from '../shell/panels'
import type { Copilot } from './useCopilot'
import type { CopilotStage, CopilotStateView } from './copilot-model'

/**
 * The copilot's surfaces, actually rendered.
 *
 * Three claims here cannot be checked by a pure-logic test, because all three
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
const { CopilotView } = await import('./CopilotView')
const { CopilotConsent } = await import('./CopilotConsent')

const noop = (): void => {}
const spec = panelSpec('copilot')

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
  confined: true,
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
    refresh: noop,
    ...over,
  }
}

/* ------------------------------------------------------------ the entry -- */

describe('the pinned sidebar entry', () => {
  const html = renderToStaticMarkup(
    <CopilotEntry spec={spec} stage="ready" state={state()} active={false} onOpen={noop} />,
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
    const quiet = renderToStaticMarkup(
      <CopilotEntry spec={spec} active={false} onOpen={noop} />,
    )
    expect(quiet).toContain('>Copilot</span>')
    expect(quiet).not.toContain('status-dot')
    expect(quiet).toContain(spec.blurb)
  })
})

/* ------------------------------------------------------------- the view -- */

describe('the first run', () => {
  const html = renderToStaticMarkup(
    <CopilotView copilot={copilot('first-run')} activity={{ deckControlActivity: async () => [] }} />,
  )

  it('says why it is signed out, in the words that make it not a bug', () => {
    expect(html).toContain('sign itself in')
    expect(html).toContain('keychain')
    expect(html).toContain('boundary working')
  })

  it('tells the reader what to actually do', () => {
    expect(html).toContain('prints a URL')
    expect(html).toContain('paste the code back')
  })

  it('opens on the terminal, which is the only pane a login can happen in', () => {
    expect(html).toContain('data-shown="true"')
    // And points at it as "below", because that is where it is on this pane. A
    // sentence pointing at something not on the screen is a small lie that
    // makes a reader doubt the rest of the paragraph — which is the paragraph
    // explaining why a signed-out assistant is not a broken one.
    expect(html).toContain('Its terminal is below')
  })
})

describe('the running copilot', () => {
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('ready', { signIn: { state: 'signed-in', account: 'a@b.c', plan: 'Max' } })}
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('names the account rather than claiming a bare "signed in"', () => {
    expect(html).toContain('a@b.c')
  })

  it('offers both views of the one session', () => {
    expect(html).toContain('>Chat</button>')
    expect(html).toContain('>Terminal</button>')
  })

  it('offers to stop it, since a singleton nobody can switch off is a fault', () => {
    expect(html).toContain('>Stop</button>')
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

describe('a machine that cannot hold it', () => {
  const html = renderToStaticMarkup(
    <CopilotView
      copilot={copilot('unavailable', {
        state: state({ status: 'unavailable', sessionId: null, problem: 'No folder boundary here.' }),
      })}
      activity={{ deckControlActivity: async () => [] }}
    />,
  )

  it('says why instead of drawing a button that would be refused', () => {
    expect(html).toContain('No folder boundary here.')
    expect(html).not.toContain('Start it</button>')
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
