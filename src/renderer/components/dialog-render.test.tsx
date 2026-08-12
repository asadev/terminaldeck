import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

/**
 * The session dialogs, actually rendered.
 *
 * Two of the rules these components exist to enforce are invisible to a
 * pure-logic test, because they are about what appears on screen:
 *
 *   1. `CloseSessionConfirm` must render *nothing at all* for a session that is
 *      idle, completed or already exited. A confirm dialog that appears when
 *      there is nothing to lose is the fastest way to train the user to click
 *      through the one that matters.
 *   2. `JoinRemoteDialog`'s action must be unpressable, and must say why. The
 *      transport does not exist; a button that looks live would send someone
 *      debugging their own network for a feature nobody has written.
 *
 * ## The harness
 *
 * There is no DOM in this project's test setup and no jsdom in its
 * dependencies, so these render through `react-dom/server`, as `AlertsPanel`
 * already does. `Modal` portals into `document.body`, which neither exists nor
 * survives SSR, so the portal is swapped for a passthrough and `document` is
 * stubbed to the one property that call site reads. Effects do not run under
 * SSR, which is why no bridge is needed: everything below is the first paint,
 * before any IPC has answered.
 */

vi.mock('react-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-dom')>()
  return { ...actual, createPortal: (node: ReactNode) => node }
})

// The stubbed portal ignores its container, so this only has to exist.
;(globalThis as { document?: unknown }).document = { body: {} }

const { NewSessionDialog } = await import('./NewSessionDialog')
const { CloseSessionConfirm } = await import('./CloseSessionConfirm')
const { JoinRemoteDialog } = await import('./JoinRemoteDialog')

const noop = (): void => {}

describe('NewSessionDialog', () => {
  const html = renderToStaticMarkup(
    <NewSessionDialog open projectPath="/Users/apple/Projects/pawl" onClose={noop} onStart={noop} />,
  )

  it('paints before any bridge has answered', () => {
    expect(html).toContain('New session')
  })

  it('lists every agent, including ones that may not be installed', () => {
    for (const label of ['Claude Code', 'Codex CLI', 'Gemini CLI', 'Shell']) {
      expect(html).toContain(label)
    }
  })

  it('preselects the agent the resolver chose, not one that was clicked', () => {
    // Nothing has been clicked and detection has not answered — the checked
    // radio is entirely the work of `resolveStart`.
    expect(html).toMatch(/<input type="radio"[^>]*checked=""[^>]*value="claude"/)
  })

  it('defaults to a fresh conversation', () => {
    expect(html).toContain('Start fresh')
    expect(html).toContain('Continue the last conversation')
  })

  it('warns that a multi-line prompt will be flattened before it is sent', () => {
    expect(html).toContain('Line breaks become spaces')
  })

  it('offers to remember the choice for the project', () => {
    expect(html).toContain('Remember these choices for this project')
  })

  // `sessionEnv()` in main/profiles.ts is what would redirect a config
  // directory, and nothing in this build calls it — `CreateSessionInput` has no
  // field to carry a profile at all. The Login row may say which login is
  // *wanted*; it must not state which one the session runs under, which is the
  // claim someone would rely on before committing from a work repository.
  it('does not claim the chosen login is the one the session runs under', () => {
    for (const claim of [
      'account and history this session uses',
      'this session uses',
      'will run as',
    ]) {
      expect(html).not.toContain(claim)
    }
  })
})

describe('CloseSessionConfirm', () => {
  function render(status: 'idle' | 'working' | 'waiting' | 'input' | 'completed' | 'exited'): string {
    return renderToStaticMarkup(
      <CloseSessionConfirm
        open
        title="Fix the login redirect"
        status={status}
        provider="claude"
        onCancel={noop}
        onConfirm={noop}
      />,
    )
  }

  it('renders nothing for a session with nothing to lose', () => {
    // `waiting` is an empty prompt in this codebase — see the component note.
    for (const status of ['idle', 'waiting', 'completed', 'exited'] as const) {
      expect(render(status)).toBe('')
    }
  })

  it('warns about a session that is mid-task', () => {
    const html = render('working')
    expect(html).toContain('still working')
    expect(html).toContain('Fix the login redirect')
  })

  it('warns about a session blocked on a question', () => {
    expect(render('input')).toContain('asked you something')
  })

  it('offers the opt-out without promising where to undo it', () => {
    const html = render('working')
    expect(html).toContain('ask again')
    // The Preferences row that turns this back on is not built yet, and this
    // dialog must not claim otherwise.
    expect(html).not.toContain('Preferences')
  })

  it('leads with the safe action', () => {
    expect(render('working').indexOf('Keep it open')).toBeLessThan(
      render('working').indexOf('Close session'),
    )
  })
})

describe('JoinRemoteDialog', () => {
  const html = renderToStaticMarkup(<JoinRemoteDialog open onClose={noop} />)

  it('says plainly that remote sessions do not work yet', () => {
    expect(html).toContain('Remote sessions are not available yet')
  })

  it('cannot be submitted', () => {
    expect(html).toMatch(/class="modal-btn join-submit" disabled=""/)
  })

  it('still explains the format it expects', () => {
    expect(html).toContain('Session code')
    expect(html).toContain('PIN')
  })

  it('shows no sign of a connection being attempted', () => {
    for (const lie of ['Connecting', 'connecting', 'Could not reach', 'Retry']) {
      expect(html).not.toContain(lie)
    }
  })
})
