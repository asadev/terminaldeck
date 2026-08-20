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

const { NewSessionDialog, ProjectRow } = await import('./NewSessionDialog')
const { CloseSessionConfirm } = await import('./CloseSessionConfirm')
const { JoinRemoteDialog } = await import('./JoinRemoteDialog')
const { Modal } = await import('./Modal')

const noop = (): void => {}

describe('NewSessionDialog', () => {
  const html = renderToStaticMarkup(
    <NewSessionDialog open projectPath="/Users/apple/Projects/terminaldeck" onClose={noop} onStart={noop} />,
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

  it('asks nothing about the conversation, because fresh is the only behaviour', () => {
    /*
     * *"'Continue last conversation' is agent-specific — either give a real
     * picker of previous conversations, or remove it and 'start fresh', since
     * fresh is then the only behaviour."*
     *
     * Both radios are gone. The picker cannot be built on `CreateSessionInput`,
     * which carries `resume?: boolean` and no id, and the flag it becomes means
     * "the newest one" for two of the four agents and is silently ignored by the
     * other two — see the note in the form.
     */
    expect(html).not.toContain('Start fresh')
    expect(html).not.toContain('Continue the last conversation')
    expect(html).not.toContain('Conversation')
  })

  it('asks for no first message', () => {
    // *"Remove 'first message' from the new-session dialog entirely."* The
    // textarea, its caveat and the "Tab will be titled …" preview it fed all go
    // with it — a heading with nothing under it is the same defect one line up.
    expect(html).not.toContain('First message')
    expect(html).not.toContain('Line breaks become spaces')
    expect(html).not.toContain('<textarea')
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

  /**
   * The five lines of helper prose that went.
   *
   * *"Let's give only one liner or two liner descriptions… not more than one or
   * two lines because it's being too big for them."* Each of these restated the
   * label directly above it, or covered a case the row now reports as a fact —
   * "Not signed in" on the login it applies to, rather than a standing warning
   * about logins in general. They are pinned as absences because prose is what
   * grows back, one defensible clause at a time.
   */
  it('does not restate its own labels underneath them', () => {
    for (const gone of [
      'Which Claude login this session should run as',
      'A new conversation with no prior context',
      'A login you have not used before asks you to sign in here',
      'Picks up the most recent session in this folder',
    ]) {
      expect(html).not.toContain(gone)
    }
  })

  /**
   * The Login pop-up never says "Default".
   *
   * That word is `systemProfileId`'s generated key for the machine's own
   * install, and this is the control whose whole job is saying which login a
   * session will run as — it was printing the key one line under the address
   * itself. This is the first paint, before any bridge has answered, so what is
   * on screen here is the placeholder option: with no account list, what the
   * session runs as is whatever login the agent already has, and saying so is
   * both true and not a slug.
   */
  it('never offers a login called "Default"', () => {
    expect(html).toContain('The agent’s own login')
    expect(html).not.toMatch(/>Default</)
  })

  it('is on screen while nothing else has taken the screen', () => {
    // The other half of the Browse fix — see the Modal describe below.
    expect(html).not.toContain('data-hidden')
  })

  /**
   * The **Where** list names every computer on it, this one included.
   *
   * The first row read "this Mac" while the rows under it read "Office PC" and
   * "DESKTOP-DDGMNCV" — one phrase among names, in the one list whose whole job
   * is telling three computers apart. It is the same defect the browser bar had
   * on 2026-08-21, where the phrase was on screen three times meaning three
   * different machines: *"I don't know what to trust."*
   */
  it('names this computer on the Where list, beside the machines’ own names', () => {
    const where = renderToStaticMarkup(
      <NewSessionDialog
        open
        projectPath="/Users/apple/Projects/terminaldeck"
        hereName="Asads-MacBook-Pro"
        machines={[{ id: 'mach-1', name: 'Office PC', folders: ['/home/asad'] }]}
        onClose={noop}
        onStart={noop}
      />,
    )
    expect(where).toContain('>Asads-MacBook-Pro<')
    expect(where).toContain('>Office PC<')
    expect(where).not.toContain('this Mac')
  })

  it('falls back to the phrase when the window has no name to hand it', () => {
    // A window whose machines view has not landed yet, and a build whose preload
    // predates the field. Neither may be given a made-up hostname.
    const where = renderToStaticMarkup(
      <NewSessionDialog
        open
        projectPath="/Users/apple/Projects/terminaldeck"
        machines={[{ id: 'mach-1', name: 'Office PC', folders: ['/home/asad'] }]}
        onClose={noop}
        onStart={noop}
      />,
    )
    expect(where).toMatch(/>This (Mac|PC|computer)</)
  })
})

/**
 * The folder shortlist's rows.
 *
 * Rendered directly rather than through the dialog, because the project list
 * arrives in an effect and effects do not run under `react-dom/server`: a
 * rendered dialog has no rows in it at all.
 */
describe('ProjectRow', () => {
  const project = {
    path: '/Users/apple/Tclaude/untitled folder',
    name: 'untitled folder',
    lastOpenedAt: 1,
  }

  function render(liveSessions: number, confirming = false): string {
    return renderToStaticMarkup(
      <ProjectRow
        project={project}
        radioName="p"
        selected={false}
        liveSessions={liveSessions}
        confirming={confirming}
        onSelect={noop}
        onAskRemove={noop}
        onRemove={noop}
        onKeep={noop}
      />,
    )
  }

  it('offers a way out of the list, which is the whole complaint', () => {
    /*
     * An `untitled folder` created by a stray New Folder in the picker was
     * described as "now permanent". It was not quite — the sidebar's project
     * header has a ✕ — but that is a hover-revealed glyph labelled *Close
     * project*, and this panel, where the row is actually being looked at, had
     * nothing at all.
     */
    const html = render(0)
    expect(html).toContain('Remove untitled folder from this list')
  })

  it('promises only what it does: the folder stays on disk', () => {
    expect(render(0)).toContain('the folder is not deleted')
  })

  it('asks first when removing would close something that is running', () => {
    // Removing a project kills every pty in it. Silently, from a picker, that
    // is the same loss as closing every one of those tabs by hand.
    expect(render(3, true)).toContain('Close 3 sessions?')
    expect(render(1, true)).toContain('Close 1 session?')
  })
})

describe('Modal', () => {
  function render(hidden: boolean): string {
    return renderToStaticMarkup(
      <Modal open title="New session" hidden={hidden} onClose={noop}>
        <p>body</p>
      </Modal>,
    )
  }

  /**
   * `Browse…` opens an `NSOpenPanel` as a sheet on the window — a native window
   * over every pixel the renderer draws, and smaller than a `lg` dialog, so the
   * two were on screen at once with the panel's own buttons landing across the
   * agent cards. No z-index reaches a surface that is not in the page, so the
   * dialog steps aside instead, and comes back with its answers intact.
   */
  it('can step aside for a native panel without being closed', () => {
    const html = render(true)
    expect(html).toContain('data-hidden="true"')
    // Hidden, not unmounted: everything already chosen is still there.
    expect(html).toContain('body')
  })

  it('carries no such marker the rest of the time', () => {
    expect(render(false)).not.toContain('data-hidden')
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

  it('appears for every state, and says something true about each', () => {
    /*
     * *"Always ask."* This used to be `expect(render(status)).toBe('')` for the
     * four calm states, backing a caller that skipped the dialog for them — so
     * closing a project took four idle agents with no confirmation at all.
     *
     * The reason the old rule existed is still respected, and this is where:
     * the dialog appears, and it does **not** claim work is being lost when
     * none is. A "you will lose everything" sentence over a session that exited
     * an hour ago is how a confirmation becomes a thing you click through.
     */
    for (const status of ['idle', 'waiting', 'completed'] as const) {
      const html = render(status)
      expect(html).toContain('Deleting this session ends it.')
      expect(html).not.toContain('still working')
    }
    expect(render('exited')).toContain('already ended')
  })

  it('says where to turn the confirmation back on', () => {
    // *"'Don't ask again' is a one-way door — once ticked there is no way to
    // turn it back on."* The switch existed in Settings by then; nothing in
    // this dialog said so, which from where he was sitting is the same thing.
    expect(render('working')).toContain('Settings → General')
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
    // The destructive one is second and now reads `Delete`, which is the word
    // the rail's menu and the dialog's own question use.
    expect(render('working').indexOf('Keep it open')).toBeLessThan(
      render('working').indexOf('>Delete<'),
    )
  })
})

describe('JoinRemoteDialog', () => {
  const html = renderToStaticMarkup(<JoinRemoteDialog open onClose={noop} />)

  it('says plainly that remote sessions do not work yet', () => {
    expect(html).toContain('Remote sessions are not available yet')
    // …and stops there. It used to go on to say which half of the feature had
    // been built, which is a progress report on our work rather than an answer
    // to "will this work". The half that stayed is the one the reader can act
    // on: the fields still check what you type.
    expect(html).toContain('Your code is checked below')
    expect(html).not.toContain('this screen is the part that has')
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
