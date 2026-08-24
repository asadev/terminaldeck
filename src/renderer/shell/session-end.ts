/**
 * A session that is over, and which of the several different overs it is.
 *
 * ## The screen this exists because of
 *
 * From Asad's recording of the shipped desktop app, *Session 2 on Office PC*.
 * The transcript ends with
 *
 *     [The connection to this server ended.]
 *
 * and **underneath that line the session is still drawn as a live one**: the
 * agent's composer, its placeholder — `Try "fix typecheck errors"` — its
 * `xhigh · /effort` chip at the right of it, and its own footer along the
 * bottom, `⏵⏵ bypass permissions on (shift+tab to cycle) · ⌥ for agents`. All
 * four of those belong to the CLI, not to this app: they are the last frame it
 * painted before its pty went away, and a terminal emulator has no reason of
 * its own to stop showing the last frame it was given. So the screen goes on
 * inviting somebody to type into a composer that is a photograph.
 *
 * What happened when they did is the part that made it worth a lane rather
 * than a paint job. `ServerTerminal`'s keyboard handler is
 * `if (shellId !== null) …`, and the close sets `shellId` to null — so every
 * keystroke after the end was **read, matched no branch, and discarded**, with
 * nothing on screen changing. `RemoteTerminal`'s has no guard at all: it hands
 * the bytes to `machines:input`, which answers `false` when there is no link,
 * and that answer was thrown away at the call site. Two terminals, two ways of
 * losing what somebody typed in silence.
 *
 * ## Why the vocabulary is a type and not a boolean
 *
 * Because "this session is over" is four or five genuinely different events
 * that a person has to act on differently, and the app can tell most of them
 * apart:
 *
 *  - The **program in it finished**. Nothing is coming back; open another one.
 *  - The far machine **went away** — asleep, switched off, off the network.
 *    The session is very likely still there and will be again.
 *  - The link **dropped and is being redialled**. Nothing is lost and nothing
 *    is asked of anybody; it comes back on its own, at a time this can name.
 *  - The link was **stopped on purpose**, here. Nothing is wrong; press
 *    connect when you want it back.
 *  - The far machine is **waiting for somebody to approve** this desktop.
 *
 * A boolean flattens all five into "disabled", which is the state the lane
 * brief names as the wrong answer: *"rather than simply disabling controls with
 * no explanation."*
 *
 * ## What is deliberately **not** distinguished
 *
 * A shell on a server closes and this app learns exactly one fact: the channel
 * closed. `servers:shell:closed` carries `{ shellId }` and nothing else, and
 * the reason genuinely is not knowable on this side — `exit` typed at the
 * prompt, the agent quitting, sshd restarting and the whole connection going
 * all arrive as the same channel close, in the same order, with the same
 * payload. `ServerSession.status` already refuses to invent an exit code for
 * the same reason (*"There is no exit code on that channel and none is invented
 * here"*), and this file keeps that bargain: {@link shellGone} says what is
 * known, and the action it offers — open another terminal there — is the press
 * that *finds out*, because it either works or fails with the server's own
 * sentence on the screen the person is already looking at.
 */

/**
 * Why a session's screen is a photograph.
 *
 * Every member carries the words its notice needs, so that no surface has to
 * look anything else up: the pane is drawn from one of these, and so is the
 * bar above it, which is what stops the two disagreeing about what happened.
 */
export type SessionEnd =
  /** The process in the session finished. `code` is null when nothing said. */
  | { kind: 'exited'; code: number | null }
  /** A shell on a server: the channel closed and the reason is not knowable. */
  | { kind: 'shell-gone'; server: string }
  /** That machine is not answering. It is being redialled unless `retryAt` is null. */
  | { kind: 'machine-away'; machine: string; why: string | null; retryAt: number | null }
  /** Dialling it right now. */
  | { kind: 'machine-dialling'; machine: string }
  /** The link was stopped from here, on purpose. */
  | { kind: 'machine-stopped'; machine: string }
  /** That machine has not let this desktop in yet. */
  | { kind: 'machine-unapproved'; machine: string }
  /** It never opened at all, and the far end said why. */
  | { kind: 'never-opened'; why: string }

/**
 * The one press a notice offers, or none.
 *
 * An id rather than a handler, because this module is pure and the handler
 * belongs to whichever pane is drawing the notice — `reopen` means a different
 * call on a server than it does on a paired desktop, and both are one line at
 * the call site. `null` where there is nothing to press: a machine that is
 * redialling itself is not asking anybody for anything, and a button that
 * repeats what is already happening is a button that does nothing.
 */
export type EndActionId = 'reopen' | 'connect' | 'redial'

export interface EndedNotice {
  /** The headline over the frozen screen. A few words, no punctuation. */
  title: string
  /** One sentence: what happened, and what it means for the work that was in it. */
  detail: string
  /** The press, or null when there is nothing honest to offer. */
  action: { id: EndActionId; label: string } | null
  /**
   * Is the session itself still alive somewhere?
   *
   * The single most useful fact on this card and the one people ask first. True
   * where the far end keeps sessions across a dropped link — a paired desktop
   * running this app — and false where the session **was** the connection, which
   * is every shell on a server and every process that has exited.
   */
  alive: boolean
  /**
   * When the app will dial again by itself, as an epoch millisecond, or null.
   *
   * Carried rather than folded into `detail` so a surface can count down without
   * re-deriving it, and so a notice that is merely waiting draws no button.
   */
  retryAt: number | null
}

/** What the person is looking at, for every end this app can observe. */
export function endedNotice(end: SessionEnd): EndedNotice {
  switch (end.kind) {
    case 'exited':
      return {
        title: 'This session has ended',
        detail:
          end.code === null || end.code === 0
            ? 'The program running here finished. What it printed is still above — nothing typed now goes anywhere.'
            : `The program running here exited with status ${end.code}. What it printed is still above — nothing typed now goes anywhere.`,
        action: { id: 'reopen', label: 'Start another session here' },
        alive: false,
        retryAt: null,
      }
    case 'shell-gone':
      return {
        title: 'This terminal has ended',
        /*
         * Three sentences and the middle one is the honest part. The app knows
         * the channel closed and nothing else — see the header — so rather than
         * naming a cause it names the two it cannot tell apart and offers the
         * press that settles it.
         */
        detail:
          `The shell on ${end.server} closed. That is either the shell itself ending or ${end.server} ` +
          'dropping the connection, and this app cannot tell which from here. Opening another terminal on it will say.',
        action: { id: 'reopen', label: `Open another terminal on ${end.server}` },
        alive: false,
        retryAt: null,
      }
    case 'machine-away':
      return {
        title: `${end.machine} is not answering`,
        detail:
          (end.why ?? 'That machine stopped answering.') +
          ' The session is still running over there — this window just has no way to reach it. ' +
          (end.retryAt === null
            ? 'It will reconnect on its own when that machine comes back.'
            : 'It is being dialled again.'),
        action: end.retryAt === null ? { id: 'redial', label: 'Try it now' } : null,
        alive: true,
        retryAt: end.retryAt,
      }
    case 'machine-dialling':
      return {
        title: `Reconnecting to ${end.machine}`,
        detail:
          'The link dropped and is being dialled again. Nothing was lost — the session is still running over there, ' +
          'and its screen comes back with the link.',
        action: null,
        alive: true,
        retryAt: null,
      }
    case 'machine-stopped':
      return {
        title: `Disconnected from ${end.machine}`,
        detail:
          'This link was stopped from here, so nothing is being dialled. The session is still running over there ' +
          'and comes back with its screen when you connect again.',
        action: { id: 'connect', label: `Connect to ${end.machine}` },
        alive: true,
        retryAt: null,
      }
    case 'machine-unapproved':
      return {
        title: `${end.machine} has not let this computer in`,
        detail:
          'That machine answered and refused. Somebody has to approve this desktop over there — until they do, ' +
          'nothing typed here reaches it.',
        action: null,
        alive: true,
        retryAt: null,
      }
    case 'never-opened':
      return {
        title: 'This session never started',
        detail: end.why,
        action: { id: 'reopen', label: 'Try again' },
        alive: false,
        retryAt: null,
      }
  }
}

/**
 * A local session's end, from the one fact the record carries.
 *
 * Null while it is running, which is what every caller wants to hand straight
 * to a pane: *"draw the notice or do not"*, with no second condition at the
 * call site to get wrong.
 */
export function endOfLocalSession(exitCode: number | null): SessionEnd | null {
  return exitCode === null ? null : { kind: 'exited', code: exitCode }
}

/** The shape of a paired machine's link, as much of it as this reads. */
export interface MachineLinkFacts {
  state: 'offline' | 'connecting' | 'awaiting-approval' | 'online' | 'error'
  reason: string | null
  retryAt: number | null
}

/** One session on a paired machine, as much of it as this reads. */
export interface MachineSessionFacts {
  exitCode: number | null
}

/**
 * A session on a paired desktop, read off the link **and** the session.
 *
 * ## Why the link is asked first
 *
 * Because a link that is down makes the session record stale rather than
 * wrong, and the two failures do not read alike. `guest.ts` empties the session
 * list on every drop — *"a list that is a snapshot from the moment a link came
 * up is a picker"* — so a pane whose link has gone has no session record to
 * consult at all, and the honest sentence is about the machine, not about a
 * process nobody here can see.
 *
 * ## The four states this separates, and what tells them apart
 *
 * All four are `guest.ts`'s own, published on its `MachineLinkState`:
 *
 *  - `'offline'` with **no reason and no retry** is `disconnect()` — this link
 *    was stopped from here on purpose. Nothing is wrong and nothing is being
 *    dialled.
 *  - `'error'` with a **retry time** is `drop()` followed by `schedule()`: a
 *    link that fell over and is coming back by itself.
 *  - `'error'` with **no retry time** is the same drop with the backoff already
 *    fired, so the press is worth offering.
 *  - `'awaiting-approval'` is a refusal from a machine that has never let this
 *    one in, which `drop` decides deliberately rather than printing as an error
 *    — *"printing that as an error would send somebody to the wrong screen."*
 *
 * `'connecting'` is the fifth and it is not an end at all in spirit, but the
 * pane is frozen through it for the same practical reason the others are:
 * `machines:input` answers `false` while there is no channel, so a keystroke
 * during a redial is a keystroke thrown away.
 */
export function endOfMachineSession(
  machine: string,
  link: MachineLinkFacts | null,
  session: MachineSessionFacts | null,
): SessionEnd | null {
  if (link === null) return { kind: 'machine-stopped', machine }
  switch (link.state) {
    case 'offline':
      return { kind: 'machine-stopped', machine }
    case 'connecting':
      return { kind: 'machine-dialling', machine }
    case 'awaiting-approval':
      return { kind: 'machine-unapproved', machine }
    case 'error':
      return { kind: 'machine-away', machine, why: link.reason, retryAt: link.retryAt }
    case 'online':
      // The link is up, so the session record is current and it is the answer.
      if (session === null || session.exitCode === null) return null
      return { kind: 'exited', code: session.exitCode }
  }
}

/**
 * A shell on a server that has closed.
 *
 * A function rather than a literal at the call site so that the one thing this
 * app is entitled to say about a closed SSH channel is spelled in one place.
 */
export function shellGone(server: string): SessionEnd {
  return { kind: 'shell-gone', server }
}

/**
 * A terminal, as much of one as freezing it needs.
 *
 * `@xterm/xterm`'s `Terminal`, narrowed to the four options this touches, so
 * that {@link freezeTerminal} can be exercised in a process with no DOM — which
 * is every test in this project.
 */
export interface FreezableTerminal {
  options: {
    disableStdin?: boolean
    cursorBlink?: boolean
    cursorStyle?: 'block' | 'underline' | 'bar'
    cursorInactiveStyle?: 'outline' | 'block' | 'bar' | 'underline' | 'none'
  }
  blur?(): void
}

/**
 * Take the keyboard away from a dead screen — and give it back if it revives.
 *
 * ## Why `disableStdin` rather than a guard in the handler
 *
 * A guard is what both terminals already had, and it is the defect. xterm still
 * takes the focus, still draws and blinks a cursor, still shows a text caret
 * over the composer in the frozen frame, and still calls `onData` — the
 * keystroke simply reaches a branch that drops it. Everything a person can
 * perceive says the keyboard is connected. `disableStdin` is the option that
 * makes the emulator itself stop reading, so there is no keystroke to drop and
 * nothing left claiming otherwise.
 *
 * The cursor goes with it, for the same reason and separately: `cursorBlink`
 * off is not enough on its own, because an unfocused xterm draws an outlined
 * cursor block by default and an outline over a composer is exactly the mark
 * that says *type here*. `cursorInactiveStyle: 'none'` is what removes it.
 *
 * ## Why it is reversible
 *
 * A dropped link comes back. `endOfMachineSession` reports `machine-dialling`
 * while it is being redialled and null again the moment it is up, and a pane
 * that could only be frozen would need its terminal rebuilt to be usable again
 * — which is the whole scrollback lost over a few seconds of network. Every
 * option here is restored rather than merely unset.
 */
export function freezeTerminal(term: FreezableTerminal, frozen: boolean): void {
  term.options.disableStdin = frozen
  term.options.cursorBlink = !frozen
  term.options.cursorInactiveStyle = frozen ? 'none' : 'outline'
  if (frozen) term.blur?.()
}
