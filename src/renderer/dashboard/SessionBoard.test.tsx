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
    expect(markup).not.toContain('Requests')
  })

  it('reports tokens and requests, and no money at all', () => {
    // The card used to carry a "Spent" figure between these two. It is gone
    // with every other price in the app — see the bottom of `src/main/cost.ts`.
    const markup = render([
      session({
        id: 'a',
        status: 'working',
        work: {
          transcriptPath: '/t/a.jsonl',
          requests: 4,
          tokens: 41_800,
          contextPercent: null,
          lastActivityAt: 0,
        },
      }),
    ])
    expect(markup).toContain('41.8k')
    expect(markup).toContain('Requests')
    expect(markup).not.toContain('Spent')
    expect(markup).not.toMatch(/[$]/)
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
        account: { id: 'school', name: 'School' },
      }),
    ])
    expect(markup).toContain('science-locus')
    expect(markup).toContain('Claude Code')
    expect(markup).toContain('School')
  })

  it('never prints the profile key where the account goes', () => {
    /*
     * `Claude Code · Default · started 25m ago`, on two cards at once, while
     * the chip inside each of those sessions read the address. "Default" is
     * the key `profiles.ts` mints for the machine's own install — it is not a
     * name anybody gave that login, and it is identical on every install.
     *
     * Nothing here has asked the agent who is signed in, so this reaches
     * `profileLoginLabel`'s third rung, which says which install it is. That
     * is a true sentence about a real thing and it is different per agent,
     * which the slug is not.
     */
    const markup = render([
      session({ id: 'a', status: 'working', account: { id: 'system', name: 'Default' } }),
    ])
    expect(markup).not.toContain('Default')
    expect(markup).toContain('Your own Claude Code install')
  })

  it('titles the card with the session, not with the folder it runs in', () => {
    /*
     * Eight cards, one project, and every heading read `terminaldeck` — with
     * the same word repeated as the folder chip directly above each heading.
     * A session is titled after its folder until the agent writes a real title,
     * and this page printed that placeholder as the card's name, so the one
     * screen whose job is "which one do I need to go into" could not answer it.
     *
     * `sessionLabel` is the rail's rule, applied here: numbered within the
     * project, in the order the list arrives — which is the store's order and
     * therefore the sidebar's, so the two halves of the window cannot end up
     * calling one session by two numbers.
     */
    const markup = render([
      session({ id: 'a', title: 'terminaldeck' }),
      session({ id: 'b', title: 'terminaldeck' }),
      session({ id: 'c', title: 'Wire up the relay' }),
    ])
    expect(markup).toContain('>Session 1<')
    expect(markup).toContain('>Session 2<')
    expect(markup).toContain('>Wire up the relay<')
    // The folder is still on the card — as the chip it always was, and only
    // there. It is no longer also the heading four pixels under it.
    expect(markup).not.toContain('>terminaldeck</h3>')
    expect(markup.match(/>terminaldeck<\/span>/g)).toHaveLength(3)
  })

  it('separates two cards that agree on every other thing they show', () => {
    /*
     * Everything else a card can be told apart by is already on it — the folder
     * is the chip in its corner, the account is in its meta line — so the only
     * pair left is two agents given one task in one folder on one login, which
     * write the same sentence. Seen exactly that way on the rail and on this
     * page. The id is the same eight characters the rail prints, so a card and
     * a row can be matched by eye.
     */
    const account = { id: 'system', name: 'Default' }
    const markup = render([
      session({ id: '7f3c9a21-6d40-4a1e-9d2b-1a5f0c3e7b81', title: 'Fix the parser', account }),
      session({ id: 'b4e1d508-2c77-4f93-8a10-9e6b2d4c5a03', title: 'Fix the parser', account }),
      session({ id: 'c9a70b64-0000-4000-8000-000000000003', title: 'Ship the release', account }),
    ])
    expect(markup).toContain('>7f3c9a21<')
    expect(markup).toContain('>b4e1d508<')
    // And on nothing else: an id on a card whose name is already unique is a
    // hex string to read for no reason.
    expect(markup.match(/board-title-id/g)).toHaveLength(2)
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
