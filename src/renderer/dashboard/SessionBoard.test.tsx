import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BoardBody, SessionBoard } from './SessionBoard'
import type { BoardSession } from './board'

/**
 * No DOM environment in this project's test setup, so these render to static
 * markup. That is enough for everything worth protecting here, because every
 * defect this board could have is a defect of *what it claims*: the wrong card
 * first, a duration measured from the wrong moment, a figure printed for a
 * session it could not attribute, or — the one this file exists for — a
 * progress bar.
 */

const NOW = Date.parse('2026-08-16T12:00:00.000Z')
const MINUTE = 60_000
const HERE = '/Users/apple/Projects/terminaldeck'

function session(overrides: Partial<BoardSession> & { id: string }): BoardSession {
  return {
    title: 'Untitled',
    projectPath: HERE,
    provider: 'claude',
    account: null,
    status: 'idle',
    statusSince: NOW,
    startedAt: NOW,
    work: null,
    ...overrides,
  }
}

function render(sessions: BoardSession[], onOpenSession?: (id: string) => void): string {
  return renderToStaticMarkup(
    <BoardBody sessions={sessions} now={NOW} projectPath={HERE} onOpenSession={onOpenSession} />,
  )
}

/* ------------------------------------------------------- nothing is faked -- */

/**
 * The rule this page was rewritten under, and the one thing that must not come
 * back. Asad asked to "see who is finished how much"; an agent does not report
 * progress, so any bar drawn here would be a number the app invented, on the
 * screen a person uses to decide where to spend the next hour.
 */
describe('nothing on the board is invented', () => {
  it('draws no progress bar and no percentage of a task', () => {
    const markup = render([
      session({ id: 'a', status: 'working', title: 'Rewrite the relay handshake' }),
      session({ id: 'b', status: 'input', title: 'Migrate the schema' }),
    ])
    expect(markup).not.toContain('progressbar')
    expect(markup).not.toContain('meter')
    expect(markup).not.toMatch(/\d+% (?:done|complete)/i)
  })

  it('prints no figures for a session whose transcript could not be attributed', () => {
    // `work` is null exactly when `pickSessionTranscript` could not rule a
    // transcript in as this session's. A row of zeroes there would be
    // indistinguishable from a session that genuinely spent nothing.
    const markup = render([session({ id: 'a', status: 'working', work: null })])
    expect(markup).not.toContain('Tokens')
    expect(markup).not.toContain('Spent')
  })

  it('omits the spend when nothing in the session could be priced', () => {
    const markup = render([
      session({
        id: 'a',
        status: 'working',
        work: {
          transcriptPath: '/t/a.jsonl',
          requests: 4,
          tokens: 41_800,
          costUsd: null,
          contextPercent: null,
          lastActivityAt: 0,
        },
      }),
    ])
    expect(markup).toContain('41.8k')
    expect(markup).not.toContain('Spent')
    expect(markup).not.toContain('$0.00')
  })
})

/* ------------------------------------------------------------ what it says -- */

describe('the card', () => {
  it('leads with whether the session is waiting on you, and for how long', () => {
    const markup = render([
      session({ id: 'a', status: 'input', statusSince: NOW - 12 * MINUTE, title: 'Migrate the schema' }),
    ])
    expect(markup).toContain('Needs you')
    expect(markup).toContain('Waiting on you for 12m')
    expect(markup).toContain('Migrate the schema')
  })

  it('names the folder, the agent and the account', () => {
    const markup = render([
      session({
        id: 'a',
        status: 'working',
        projectPath: '/Users/apple/Projects/science-locus',
        provider: 'claude',
        account: 'School',
      }),
    ])
    expect(markup).toContain('science-locus')
    expect(markup).toContain('Claude Code')
    expect(markup).toContain('School')
  })

  it('marks a session running in another project', () => {
    const mine = render([session({ id: 'a', status: 'working' })])
    const theirs = render([session({ id: 'a', status: 'working', projectPath: '/Users/apple/Projects/other' })])
    expect(mine).not.toContain('other project')
    expect(theirs).toContain('other project')
  })

  it('puts the blocked session first however the list arrives', () => {
    const markup = render([
      session({ id: 'working', status: 'working', title: 'Still going' }),
      session({ id: 'blocked', status: 'input', title: 'Stopped and asking' }),
    ])
    expect(markup.indexOf('Stopped and asking')).toBeLessThan(markup.indexOf('Still going'))
  })
})

/* ------------------------------------------------------------ affordances -- */

describe('a card is a door, or it is not a control', () => {
  it('is a button when there is somewhere to go', () => {
    const markup = render([session({ id: 'a', status: 'working', title: 'Go here' })], () => {})
    expect(markup).toContain('<button')
    expect(markup).toContain('Open Go here')
  })

  it('is plain text when there is not', () => {
    // A card that lifts under the pointer and then does nothing is worse than
    // one that never invited the click.
    const markup = render([session({ id: 'a', status: 'working' })])
    expect(markup).not.toContain('<button')
  })
})

/* ------------------------------------------------------------ empty board -- */

describe('with nothing running', () => {
  it('says so, and says how to start one', () => {
    const markup = render([])
    expect(markup).toContain('Nothing is running')
    expect(markup).toMatch(/Press |Start one from the sidebar/)
    // Not a spinner and not a blank page: the state is "nothing", not "loading".
    expect(markup).not.toContain('…')
  })
})

/* ------------------------------------------------------------- the shell -- */

describe('SessionBoard', () => {
  it('renders its own cards when the host supplies them', () => {
    const markup = renderToStaticMarkup(
      <SessionBoard
        projectPath={HERE}
        now={NOW}
        sessions={[session({ id: 'a', status: 'input', title: 'Answer me' })]}
      />,
    )
    expect(markup).toContain('Answer me')
    expect(markup).toContain('Needs you')
  })

  it('mounts outside a store provider without throwing', () => {
    // The harness and these tests have no `StoreProvider`; `useStore` throws
    // there by design, so the board reads the optional accessor instead.
    expect(() =>
      renderToStaticMarkup(<SessionBoard projectPath={HERE} now={NOW} />),
    ).not.toThrow()
  })
})
