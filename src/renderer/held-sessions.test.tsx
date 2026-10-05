import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { heldAgentName, readHeldSessions, type HeldSessionView } from './held-sessions'
import { Sidebar } from './shell/Sidebar'

/**
 * The sessions that did not come back, and the fact that a person can see them.
 *
 * This half is the one that was missing, and its absence is why the bug took a
 * day to find. When four of Asad's sessions failed to restart on 2026-08-16 the
 * app wrote a warning to a log nobody had opened, replaced them with something
 * else, and drew a window that looked completely normal. He found out because
 * the agent he had been talking to was a bare terminal with no memory — the
 * symptom three steps from the cause.
 *
 * So: the narrower is total, because a channel that goes missing must cost the
 * rows and not the window; and the rail draws one compact row per held session
 * that opens it when pressed, with the reason in its tooltip. `react-dom/server`, like every render
 * test in this project — there is no DOM in the test setup, deliberately.
 */

const noop = (): void => {}

const projects = [{ path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' }]

const held: HeldSessionView[] = [
  {
    key: 'held-1',
    cwd: '/Users/apple/Projects/terminaldeck',
    provider: 'claude',
    reason: 'it could not be started again: File not found',
    pick: false,
    tabKey: 'tab-1',
    at: 1_700_000_000_000,
  },
  {
    key: 'held-2',
    cwd: '/home/asad/ClaudeKiwi',
    provider: 'claude',
    reason: 'the folder it ran in is no longer on this machine',
    pick: false,
    at: 1_700_000_000_000,
  },
  {
    key: 'held-3',
    cwd: '/Users/apple/Projects/terminaldeck',
    provider: 'claude',
    reason: 'no conversation was saved for this tab — open it to choose one',
    pick: true,
    at: 1_700_000_000_000,
  },
]

function rail(over: Partial<Parameters<typeof Sidebar>[0]> = {}): string {
  return renderToStaticMarkup(
    <Sidebar
      width={264}
      projects={projects}
      tabs={[]}
      activeTabId={null}
      activePanel={null}
      held={held}
      onRetryHeld={noop}
      onForgetHeld={noop}
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
    />,
  )
}

/** The first held row's markup, and nothing around it. */
function heldItem(markup: string): string {
  const from = markup.slice(markup.indexOf('<li class="sb-held"'))
  return from.slice(0, from.indexOf('</li>'))
}

describe('reading the held list off the bridge', () => {
  it('keeps every field a row needs', () => {
    expect(
      readHeldSessions([
        { key: 'held-1', cwd: '/p', provider: 'claude', reason: 'no', at: 12 },
      ]),
    ).toEqual([{ key: 'held-1', cwd: '/p', provider: 'claude', reason: 'no', pick: false, at: 12 }])
    expect(
      readHeldSessions([
        { key: 'held-2', cwd: '/p', provider: 'claude', reason: 'no', pick: true, tabKey: 'tab-9', at: 12 },
      ]),
    ).toEqual([{ key: 'held-2', cwd: '/p', provider: 'claude', reason: 'no', pick: true, tabKey: 'tab-9', at: 12 }])
  })

  it('drops an entry with no key, folder or reason rather than drawing a blank', () => {
    // Those three are what the row *is*: something to retry with, somewhere to
    // sit, and something to say. A row missing any of them is a row that tells a
    // person their session is gone and nothing else.
    expect(readHeldSessions([{ cwd: '/p', reason: 'no' }])).toEqual([])
    expect(readHeldSessions([{ key: 'k', reason: 'no' }])).toEqual([])
    expect(readHeldSessions([{ key: 'k', cwd: '/p' }])).toEqual([])
    expect(readHeldSessions([{ key: '', cwd: '/p', reason: 'no' }])).toEqual([])
  })

  it('still draws a row whose agent or time is missing', () => {
    // An unknown agent and an unknown time is still a row saying a session did
    // not come back, which is the fact worth having on screen.
    expect(readHeldSessions([{ key: 'k', cwd: '/p', reason: 'no' }])).toEqual([
      { key: 'k', cwd: '/p', reason: 'no', provider: 'shell', pick: false, at: 0 },
    ])
  })

  it('answers with no rows for anything that is not a list', () => {
    /*
     * Total on purpose. This runs against whatever comes back over the bridge,
     * and a channel that has gone missing — a renamed handler, an older main
     * process after a partial update — must cost the rows and not the window.
     */
    for (const bad of [null, undefined, 'rows', 42, { rows: [] }]) {
      expect(readHeldSessions(bad)).toEqual([])
    }
    expect(readHeldSessions([null, 7, 'x'])).toEqual([])
  })
})

describe('naming the agent on a row', () => {
  it('uses the name a person chose it by', () => {
    // "Claude Code did not start" is a sentence somebody can act on. "claude did
    // not start" is a sentence about a string.
    expect(heldAgentName('claude')).toBe('Claude Code')
  })

  it('falls back to an added agent’s own id, minus the prefix', () => {
    expect(heldAgentName('custom:grok')).toBe('grok')
  })

  it('says whatever it was given for an id it has never heard of', () => {
    // An agent removed in another window, or a session restored from a machine
    // that had one — which is one of the ways a row gets here in the first place.
    expect(heldAgentName('mystery')).toBe('mystery')
  })
})

describe('the rail draws them', () => {
  const html = rail()

  it('puts a row under the project the session belonged to', () => {
    expect(html).toContain('sb-held')
    // Inside the project's own session list, so it sits where that session's row
    // was — which is the whole promise the rail is making here.
    const sessions = html.slice(html.indexOf('sb-sessions'))
    expect(sessions.slice(0, sessions.indexOf('</ul>'))).toContain('sb-held')
  })

  it('says what did not start, in words rather than an id', () => {
    expect(html).toContain('Claude Code')
  })

  it('is one line — the name and a status mark — with why it was kept in the tooltip', () => {
    // Each row used to be the name plus five wrapped lines and a retry button,
    // about 120px apiece. Now it is the height of every other session row.
    expect(html).not.toContain('sb-held-why')
    expect(html).not.toContain('sb-held-retry')
    const row = heldItem(html)
    expect(row).not.toMatch(/<p[\s>]/) // no paragraph under the name
    expect(row.match(/<button/g)).toHaveLength(2) // the row itself, and stop keeping it
    expect(row).toContain('sb-held-mark')
    expect(html).toContain('title="Claude Code — Not reopened: it could not be started again: File not found"')
  })

  it('says a row with no usable conversation opens on the list to choose one', () => {
    expect(html).toContain('Not reopened — open it to choose the conversation')
  })

  it('names the folder only where no heading above it does, ahead of the agent', () => {
    // Folder first, so the rail's ellipsis eats the agent's name and not the
    // folder that tells this row from the others.
    expect(html).toContain('<span class="sb-label">ClaudeKiwi · Claude Code</span>')
    expect(html).not.toContain('terminaldeck · Claude Code')
  })

  it('opens when the row is pressed, and still offers to stop keeping it', () => {
    const row = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={[]}
        activeTabId={null}
        activePanel={null}
        held={[held[1]]}
        onRetryHeld={noop}
        onForgetHeld={noop}
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
    const item = heldItem(row)
    const main = item.slice(item.indexOf('class="sb-row-main sb-held-open"'))
    expect(main.slice(0, main.indexOf('</button>'))).toContain('aria-label="Open Claude Code in /home/asad/ClaudeKiwi.')
    expect(row).toContain('Stop keeping Claude Code in /home/asad/ClaudeKiwi')
  })

  it('says a row is already opening, and cannot be pressed twice', () => {
    /*
     * Not cosmetic. A retry spawns a session; two of them spawn two, in one
     * folder, on one agent — and `planRestore` then has to decide which of the
     * pair continues the conversation, so the duplicate does not merely waste a
     * process, it demotes the real one to a fresh start.
     */
    const opening = rail({ heldRetrying: ['held-1'] })
    expect(opening).toContain('Opening…')
    expect(opening).toContain('disabled=""')
    expect(opening).toContain('aria-busy="true"')
  })

  it('draws nothing at all when nothing is being held', () => {
    // The ordinary case, which is every launch where everything came back.
    expect(rail({ held: [] })).not.toContain('sb-held')
  })

  it('does not say "Nothing open yet." over a list of failures', () => {
    /*
     * A launch where every session failed to come back leaves no projects and no
     * tabs. Without this the rail would print its empty state directly above
     * four rows saying the sessions did not start — the window contradicting
     * itself in one glance, in the exact situation where somebody is trying to
     * work out what happened.
     */
    const empty = rail({ projects: [] })
    expect(empty).not.toContain('Nothing open yet.')
    expect(empty).toContain('sb-held')
  })
})
