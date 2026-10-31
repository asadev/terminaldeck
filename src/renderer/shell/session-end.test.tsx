import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SessionEnded } from './SessionEnded'
import {
  endOfLocalSession,
  endOfMachineSession,
  endedNotice,
  freezeTerminal,
  shellGone,
  type FreezableTerminal,
  type SessionEnd,
} from './session-end'

/**
 * A session that has ended, told honestly, and told differently for each of the
 * different ways of ending.
 *
 * ## The frame these are all about
 *
 * Asad's recording of the shipped desktop app, *Session 2 on Office PC*. The
 * transcript ends with `[The connection to this server ended.]` and everything
 * under that line is still the screen of a running agent: the composer, its
 * `Try "fix typecheck errors"` placeholder, `xhigh · /effort` at the right of
 * it, and `⏵⏵ bypass permissions on (shift+tab to cycle) · ⌥ for agents` under
 * it. None of those four belong to this app — they are the CLI's last frame,
 * and an emulator has no reason of its own to stop showing one.
 *
 * What made it more than a paint fault is what happened to the keys. In
 * `ServerTerminal` the handler is `if (shellId !== null)` and the close sets
 * that to null, so a keystroke was read and dropped in silence; in
 * `RemoteTerminal` there is no guard, and `machines:input`'s `false` — its way
 * of saying *there is no link* — was discarded at the call site. Two panes, two
 * ways of losing what somebody typed with nothing on screen changing.
 */

describe('the five ways a session can be over', () => {
  it('never gives two of them the same words', () => {
    /*
     * The requirement stated as an assertion, because it is the one that a
     * later simplification would break first: *"They are not the same event and
     * should not read identically."* A machine that was switched off, a link
     * that is coming back on its own, a link somebody stopped here, a machine
     * that has not approved this desktop and a process that finished are five
     * different things to do next.
     */
    const ends: SessionEnd[] = [
      { kind: 'exited', code: 0 },
      shellGone('office-pc'),
      { kind: 'machine-away', machine: 'Office PC', why: 'It may be asleep.', retryAt: null },
      { kind: 'machine-dialling', machine: 'Office PC' },
      { kind: 'machine-stopped', machine: 'Office PC' },
      { kind: 'machine-unapproved', machine: 'Office PC' },
      { kind: 'never-opened', why: 'That server would not open a terminal.' },
    ]
    const titles = ends.map((end) => endedNotice(end).title)
    expect(new Set(titles).size, titles.join(' / ')).toBe(ends.length)
    const details = ends.map((end) => endedNotice(end).detail)
    expect(new Set(details).size).toBe(ends.length)
  })

  it('says whether the work is still alive over there, which is the first question', () => {
    /*
     * The difference that decides whether somebody panics. A paired desktop
     * keeps its sessions across a dropped link — that is what a session on a
     * machine *is* — so a link failure has lost nothing. A shell on a server has
     * no such thing behind it: `server-sessions.ts` states it outright, *"the
     * moment nothing here is holding it there is nothing there either"*, and a
     * process that has exited is gone by definition.
     */
    expect(endedNotice({ kind: 'machine-away', machine: 'PC', why: null, retryAt: null }).alive).toBe(true)
    expect(endedNotice({ kind: 'machine-dialling', machine: 'PC' }).alive).toBe(true)
    expect(endedNotice({ kind: 'machine-stopped', machine: 'PC' }).alive).toBe(true)
    expect(endedNotice(shellGone('box')).alive).toBe(false)
    expect(endedNotice({ kind: 'exited', code: 0 }).alive).toBe(false)
  })

  it('offers no button where nothing is being asked of anybody', () => {
    /*
     * A link that is already redialling itself is not waiting on a person, and a
     * button that repeats what is happening anyway is a button that does
     * nothing — the shape of control this window's brief singles out. The same
     * end with the backoff already fired *is* worth a press, and gets one.
     */
    expect(endedNotice({ kind: 'machine-dialling', machine: 'PC' }).action).toBeNull()
    expect(
      endedNotice({ kind: 'machine-away', machine: 'PC', why: null, retryAt: Date.now() + 4000 }).action,
    ).toBeNull()
    expect(endedNotice({ kind: 'machine-away', machine: 'PC', why: null, retryAt: null }).action).not.toBeNull()
  })

  it('names the server in the press, so it is plain which machine it acts on', () => {
    const notice = endedNotice(shellGone('terminaldeck-server'))
    expect(notice.action?.label).toContain('terminaldeck-server')
  })

  it('claims no cause for a closed SSH channel, because there is none to read', () => {
    /*
     * `servers:shell:closed` carries `{ shellId }`. Typing `exit`, the agent
     * quitting, sshd restarting and the whole connection dying all arrive as one
     * channel close with one payload, so any sentence naming one of them is a
     * guess printed as a fact — the thing `ServerSession.status` already refuses
     * to do about exit codes. What the notice does instead is name both and
     * offer the press that settles it.
     *
     * The line the terminal itself writes was changed for the same reason: it
     * used to read *"The connection to this server ended"*, which reported a
     * connection-level event nobody had observed.
     */
    const notice = endedNotice(shellGone('box'))
    expect(notice.detail).toContain('either')
    expect(notice.detail).toContain('cannot tell which')
  })
})

describe('reading the end off a paired machine', () => {
  const link = (over: Partial<Parameters<typeof endOfMachineSession>[1] & object>) => ({
    state: 'online' as const,
    reason: null,
    retryAt: null,
    ...over,
  })

  it('is null while the link is up and the session is running', () => {
    expect(endOfMachineSession('PC', link({}), { exitCode: null })).toBeNull()
  })

  it('reads the process ending off the record, once the record can be trusted', () => {
    expect(endOfMachineSession('PC', link({}), { exitCode: 137 })).toEqual({ kind: 'exited', code: 137 })
  })

  it('asks the link before the session, because a dropped link empties the list', () => {
    /*
     * `guest.ts` clears `sessions` on every drop — *"a list that is a snapshot
     * from the moment a link came up is a picker"* — so a pane whose machine has
     * gone has no session record to read at all. Answering "the process exited"
     * from that absence would be the app inventing a death for a session that is
     * almost certainly still running.
     */
    const gone = endOfMachineSession('Office PC', link({ state: 'error', reason: 'It may be asleep.' }), null)
    expect(gone).toEqual({
      kind: 'machine-away',
      machine: 'Office PC',
      why: 'It may be asleep.',
      retryAt: null,
    })
  })

  it('tells a link somebody stopped from a link that fell over', () => {
    /*
     * Both of these are `guest.ts`'s own and the difference is exactly what it
     * publishes: `disconnect()` sets `offline` with no reason and no retry;
     * `drop()` sets `error` with the sentence it was given and `schedule()` puts
     * a time on it. One is a state somebody chose and the other is a failure, and
     * a screen that drew them alike would put an apology over the first.
     */
    expect(endOfMachineSession('PC', link({ state: 'offline' }), null)).toEqual({
      kind: 'machine-stopped',
      machine: 'PC',
    })
    const at = Date.now() + 8000
    expect(endOfMachineSession('PC', link({ state: 'error', reason: 'dropped', retryAt: at }), null)).toEqual({
      kind: 'machine-away',
      machine: 'PC',
      why: 'dropped',
      retryAt: at,
    })
  })

  it('keeps a refusal out of the error state, so nobody is sent to the wrong screen', () => {
    // `drop` decides this one deliberately rather than printing it as an error:
    // a machine that has never let this desktop in is a pairing waiting on a
    // human, not a fault.
    expect(endOfMachineSession('PC', link({ state: 'awaiting-approval' }), null)).toEqual({
      kind: 'machine-unapproved',
      machine: 'PC',
    })
  })

  it('freezes through a redial as well, because a keystroke then is still lost', () => {
    // `connecting` is not an ending in spirit. It is one in effect: `input`
    // answers false while there is no channel, so a key pressed during a redial
    // goes nowhere exactly as one pressed after a drop does.
    expect(endOfMachineSession('PC', link({ state: 'connecting' }), null)).toEqual({
      kind: 'machine-dialling',
      machine: 'PC',
    })
  })

  it('treats a machine with no link at all as one that is not connected', () => {
    expect(endOfMachineSession('PC', null, null)).toEqual({ kind: 'machine-stopped', machine: 'PC' })
  })
})

describe('a local session', () => {
  it('is over exactly when it has an exit code, and not before', () => {
    expect(endOfLocalSession(null)).toBeNull()
    expect(endOfLocalSession(0)).toEqual({ kind: 'exited', code: 0 })
    expect(endOfLocalSession(1)).toEqual({ kind: 'exited', code: 1 })
  })

  it('says the status only when there was a failing one', () => {
    // A clean finish is a finish; printing `status 0` beside it is noise that
    // reads like a diagnostic.
    expect(endedNotice({ kind: 'exited', code: 0 }).detail).not.toContain('status')
    expect(endedNotice({ kind: 'exited', code: 137 }).detail).toContain('status 137')
  })
})

describe('taking the keyboard away', () => {
  const terminal = (): FreezableTerminal & { blurred: number } => ({
    options: {},
    blurred: 0,
    blur() {
      this.blurred += 1
    },
  })

  it('stops the emulator reading rather than dropping what it read', () => {
    /*
     * The distinction the whole lane turns on. A guard inside `onData` leaves
     * xterm focused, blinking a cursor over the frozen composer and calling the
     * handler on every key — every perceivable signal still saying the keyboard
     * is connected — and only the last step, invisibly, throws the keystroke
     * away. `disableStdin` is the option that stops there being a keystroke.
     */
    const term = terminal()
    freezeTerminal(term, true)
    expect(term.options.disableStdin).toBe(true)
    expect(term.blurred).toBe(1)
  })

  it('takes the cursor with it, because an outline over a composer says “type here”', () => {
    // `cursorBlink: false` alone is not enough: an unfocused xterm draws an
    // outlined block, and that mark sitting in the middle of the dead composer
    // is the invitation this is removing.
    const term = terminal()
    freezeTerminal(term, true)
    expect(term.options.cursorBlink).toBe(false)
    expect(term.options.cursorInactiveStyle).toBe('none')
  })

  it('gives all of it back, because a dropped link comes back', () => {
    /*
     * The half that has to be reversible. A link redials on its own and the pane
     * is deliberately kept through it — *"a pane thrown away during those
     * seconds is exactly the reload this list exists to remove"* — so a freeze
     * that could only be undone by rebuilding the terminal would cost the whole
     * scrollback for four seconds of wifi.
     */
    const term = terminal()
    freezeTerminal(term, true)
    freezeTerminal(term, false)
    expect(term.options.disableStdin).toBe(false)
    expect(term.options.cursorBlink).toBe(true)
    expect(term.options.cursorInactiveStyle).toBe('outline')
  })
})

describe('the card drawn over the frozen frame', () => {
  it('says what happened and what to do, in that order', () => {
    const html = renderToStaticMarkup(<SessionEnded end={shellGone('office-pc')} onAct={() => {}} />)
    expect(html).toContain('This terminal has ended')
    expect(html).toContain('Open another terminal on office-pc')
    expect(html.indexOf('This terminal has ended')).toBeLessThan(html.indexOf('Open another terminal'))
  })

  it('draws the sentence with no button rather than a dead one', () => {
    /*
     * The rule the account chip states next door and this follows: a control
     * that cannot act is removed, not shown inert. A pane with nowhere to send
     * the press still has everything worth saying.
     */
    const html = renderToStaticMarkup(<SessionEnded end={shellGone('office-pc')} onAct={null} />)
    expect(html).toContain('This terminal has ended')
    expect(html).not.toContain('<button')
  })

  it('marks the two kinds apart before a word is read', () => {
    // The stripe down the left. Something still running over there, or nothing.
    const alive = renderToStaticMarkup(
      <SessionEnded end={{ kind: 'machine-dialling', machine: 'PC' }} onAct={null} />,
    )
    const over = renderToStaticMarkup(<SessionEnded end={{ kind: 'exited', code: 0 }} onAct={null} />)
    expect(alive).toContain('data-alive="true"')
    expect(over).not.toContain('data-alive')
  })

  it('is announced, because it appears without anybody pressing anything', () => {
    // A session ends on its own schedule. A person who is not looking at this
    // pane at that instant gets nothing at all without this.
    const html = renderToStaticMarkup(<SessionEnded end={{ kind: 'exited', code: 0 }} onAct={null} />)
    expect(html).toContain('role="status"')
    expect(html).toContain('aria-live="polite"')
  })
})
