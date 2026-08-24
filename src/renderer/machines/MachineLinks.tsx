import { useEffect, useRef, useState } from 'react'
import { Button, Group, Notice } from '../settings/controls'
import { thisMachine, type UiPlatform } from '../platform'
import { useAppSettings } from '../settings/useAppSettings'
import { numberSetting, stringSetting } from '../settings/settings-schema'
import { RemoteTerminal } from './RemoteTerminal'
import type { SessionEnd } from '../shell/session-end'
import type { CodeEntryState } from './CodeEntry'
import {
  STATE_LABEL,
  asPairResult,
  asView,
  machineNoun,
  type Machine,
  type MachineLinkState,
  type MachinesBridge,
  type MachinesView,
  type RemotePort,
  type RemoteSession,
} from './types'
import { normaliseCode } from '../../shared/short-code'
import './machines.css'

/**
 * The other half of Remote: the machines *this* one can reach.
 *
 * ## Why this is not a page any more
 *
 * It was. There was a **Machines** row in the sidebar and a **Remote** section
 * in Settings, and between them they answered one question twice — which devices
 * are paired with this machine. Both listed devices, both showed a pairing code
 * minted by the *same* desk in the main process, and both had their own idea of
 * when pairing was possible. Asad, looking at the two of them: they "should be
 * one". They are one now, and this file is the part of it that faces outward.
 *
 * The organising idea is that a phone and a second laptop are the same kind of
 * thing. What is genuinely different — and what is kept here rather than
 * flattened into the device roster — is the *direction*: everything in
 * `RemoteSection` is about something reaching this machine, and everything here
 * is about this machine reaching something else. That difference is real, it has
 * its own controls (Connect, a terminal, Disconnect, Forget), and collapsing it
 * would have lost a feature rather than merged one.
 *
 * ## The card has two buttons, and it used to have three
 *
 * **New session** is gone from this row. Asad, reviewing the machines page on
 * 2026-08-19: *"we don't need this new session thing here. Just disconnect and
 * forget thing is good enough for us."*
 *
 * It is a removal rather than a loss, and that is worth being precise about,
 * because the argument for putting it here was a good one. Starting a session on
 * a paired machine is still one press away and always was — the rail draws a
 * machine group with the same ＋ a project group has, labelled *"New session on
 * «machine»"*, and it lands on exactly the call this row had been rewritten to
 * make: `openNewSessionDialog(null, machineId)`. Two buttons doing the identical
 * thing, both on screen at once while the Machines panel is open — and the rail's
 * is the one that stays there while you are looking at the session it started.
 *
 * Two suites hold that half up, and they hold different halves of it, which is
 * why both are named rather than one: `shell/machine-group.test.tsx` renders the
 * rail and finds the control (by that accessible name, against its
 * `DESKTOP-DDGMNCV` fixture), and `shell/new-session-route.test.ts` reads the one
 * line in `Sidebar.tsx` and the one in `App.tsx` that decide where the press
 * lands — because markup cannot say what a button does. Both were checked before
 * this row's button was taken out, not after.
 *
 * What this card is left with is what a *card* is for: the two things you can
 * only do from a list of machines — stop talking to one, and forget it.
 *
 * Everything that existed solely to explain the button went with it: the offer
 * gate that decided whether the far machine could honour a press, and the note
 * that said so when it could not. A row does not get to keep an explanation of a
 * control it no longer draws.
 *
 * ## The terminal this page used to draw
 *
 * It drew one. A machine's card lists the sessions running on it, and pressing
 * a row opened that session's terminal **here**, in a `.machines-pane` under a
 * head with a title, a folder and a Close — and nothing else. No controls, no
 * model, no effort, no usage, no connectors, no account, no Terminal/Chat
 * switch, no Split. The window has all of those over the same session, reached
 * by clicking the same session in the rail.
 *
 * Two doors onto one session, and the one that opened onto less was the one
 * somebody reaches by going to look at the machine it is running on. That is
 * the thing Asad has asked to stop happening for as long as there have been
 * remote sessions: *"every time I tell you I want exactly same identical view
 * of every type of session inside, including remote session, including local
 * session"*. `shell/session-view-parity.test.ts` made the window's view one
 * view across all three kinds of session; this panel was the surface that pass
 * could not reach from `App.tsx`, and it is the last of the drift.
 *
 * So the press leaves rather than the row: {@link MachineActions.open} now asks
 * the window to show that session in its own view — `session-view-context.ts`
 * carries how, and why it is a context — and `machines/one-session-view.test.ts`
 * pins that this file grows no terminal of its own again.
 *
 * {@link MachineSessionPane} is still here, and still exported, because it is
 * still the component that mounts a far machine's terminal; what changed is who
 * mounts it. `App.tsx` does, once, in the list of panes it keeps mounted for the
 * whole life of the window — deliberately, because unmounting one detaches from
 * the far machine and is answered with the entire scrollback replayed on the way
 * back. A copy in this panel was a second mount of the same session that came
 * and went with a Close button.
 *
 * ## Pure, all of it now
 *
 * `MachineLinks` and every row under it take what they draw, and since the pane
 * left there is no longer an exception to carve out. That matters for the reason
 * `RemoteSection` and `DeviceFolders` give for the same shape: this repository's
 * test environment has no DOM and `renderToStaticMarkup` never runs an effect, so
 * a list that read its own machines would be testable in exactly one state, the
 * empty one.
 */

/* -------------------------------------------------------------------------- */
/* What the view is handed                                                     */
/* -------------------------------------------------------------------------- */

/** Every press on this half of the screen. */
export interface MachineActions {
  /** The pairing code being typed in, digit by digit. */
  type(next: string): void
  /** Redeem what has been typed, and remember the machine behind it. */
  pair(): void
  connect(machine: Machine): void
  disconnect(machine: Machine): void
  forget(machine: Machine): void
  /*
   * There was a `newSession` here, and its absence is the change rather than an
   * oversight — see the header. It asked the window for the new-session dialog
   * pointed at that machine, and it was optional because that dialog is the
   * window's and a page drawn outside one has nowhere for the press to land.
   *
   * Both halves of that are still true of the rail's ＋, which is where the
   * press lives now. What is not true any more is that this row needs a way to
   * make it: a card in a list of machines is not where somebody starts work, and
   * the button that was here duplicated one that is on screen at the same time.
   *
   * It is written down rather than deleted because the *shape* is the part worth
   * keeping — the next action on this list that needs the window around it must
   * be optional for the same reason, and must be absent rather than dead when it
   * is not there. `new-session-context.ts` still carries the whole argument.
   */
  /**
   * Show that session — in the window's one session view, not here.
   *
   * Optional, and absent rather than dead when the window is not there: the
   * press has to travel up to `App.tsx` through a context, and a page rendered
   * outside a window gets `null` from it. A session row with no `open` draws its
   * title, its folder and its status as plain text instead of as a button that
   * swallows the press. `session-view-context.ts` carries that rule and why it
   * is the one this file follows rather than a no-op default.
   *
   * It used to mean something else, and the difference is the whole point: it
   * set this panel's own `open` state, and the panel drew the terminal itself.
   * See the header.
   */
  open?(machineId: string, sessionId: string): void
  /*
   * A `close()` stood here, and it went with the terminal that needed closing.
   *
   * It emptied this panel's `open` state, which is what the Close button over
   * the embedded pane pressed and what a second press on an already-open session
   * row pressed. Neither control exists now: a row opens the session in the
   * window, and what closes a session on a far machine is the ✕ on its pill or
   * on its rail row, which is a real close on the far machine rather than a
   * pane being put away. `App.tsx`'s `closeTab` carries that argument.
   */
  /** Open `http://localhost:<port>/` **on that machine**, in its own browser. */
  openPort(machine: Machine, port: number): void
  /** Ask that machine again what is listening on it. */
  refreshPorts(machine: Machine): void
  /**
   * Say whether sessions on that machine may act on browser windows here.
   *
   * Optional for the reason the removed `newSession` was, and the shape is worth
   * keeping for the same reason: the press needs a bridge method that a build
   * older than this round does not have, and a press that lands nowhere is the
   * one thing a control on this card may not do. Absent means the switch is not
   * drawn.
   */
  setDrivesWindows?(machine: Machine, allowed: boolean): void
}

/** The machines half of the merged section, as one bundle. */
export interface MachinesHalf {
  /**
   * Whether this build's preload carries the machine channels at all.
   *
   * False is a broken build rather than a setting, and it is said on screen: a
   * window running against an older preload used to render an entry field and a
   * list that could never fill, which reads as a feature that does not work
   * rather than one that is not there.
   */
  wired: boolean
  view: MachinesView
  /** The first read has not landed. Only the list waits on it. */
  reading: boolean
  /**
   * Why the read failed, in a sentence. Null while it has not.
   *
   * The list used to have two states, reading and read, and a read that never
   * came back therefore had no state at all — it stayed on "Reading the
   * machines this desktop knows…" for the rest of the session. The caller now
   * puts a deadline on the read, and a deadline needs somewhere to land: it is
   * this. Printing "No other machine yet" instead would be a claim, and a read
   * that did not answer is no evidence for one.
   */
  error?: string | null
  /** Ask for the list again, for the button beside {@link error}. */
  retry?: () => void
  entry: CodeEntryState
  /*
   * An `open` and a `pane` were here — which session this panel had a terminal
   * open for, and the terminal itself, handed in as a node because it needs a
   * DOM this repository's tests do not have.
   *
   * Both are gone with the second in-session view. Nothing on this half needs to
   * know which session the window happens to be showing: the row is a way *in*,
   * and the thing that says what is on screen is the window's own rail and
   * strip, which highlight it. A copy of that answer here would be a second
   * place for it to be wrong.
   */
  actions: MachineActions
}

/* -------------------------------------------------------------------------- */
/* Words                                                                       */
/* -------------------------------------------------------------------------- */

/** A session's folder, shortened to its last two segments for a row. */
export function shortPath(cwd: string): string {
  const parts = cwd.split(/[\\/]/).filter((part) => part !== '')
  if (parts.length <= 2) return cwd
  return `…/${parts.slice(-2).join('/')}`
}

/*
 * `newSessionOffer` stood here: three answers about whether the far machine
 * could honour a **New session** press — not connected, running a build with no
 * `create`, or sharing no folder with this device — of which only the first was
 * a button and the other two were sentences printed under the row.
 *
 * It went with the button. Every one of those three facts was *only* ever read
 * to decide whether to draw it or what to say instead, so keeping the function
 * would have kept three sentences about a control that is not on the card.
 *
 * ## One of the three was not only a sentence, and is now owed elsewhere
 *
 * `link.state` survives on the row as its own label, and the empty-folder case
 * is asked again where it belongs — and answered, which was checked rather than
 * assumed: picking a machine in `NewSessionDialog` sets the folder to
 * `row.folders[0] ?? null`, a null path makes `resolveStart` return
 * `{ ok: false, code: 'no-project' }`, and the dialog draws that as a disabled
 * Start under *"Choose a project folder to run the session in."* A machine
 * sharing nothing cannot be got past the Folder step.
 *
 * The `create` capability is the one with nowhere left to be read. A first
 * draft of this note claimed the rail's ＋ "makes its own decision from the same
 * link", and that is **false** — measured, not guessed:
 * `grep -rn "includes('create')" src/renderer` now returns nothing at all, and
 * the rail's machine rows are built in `App.tsx` with `canClose:
 * row.link?.capabilities.includes('close') === true` and no `create` sibling, so
 * the ＋ is drawn on every machine heading whatever build is answering. Press it
 * against a PC on an older build and `App.tsx` awaits `machines.startSession`,
 * which sends `createMachineSession`, sees no session appear, times out and
 * returns `null` — and the caller's `if (sessionId === null) return` closes the
 * dialog saying nothing.
 *
 * The sentence that used to say it out loud — *"That machine is running a build
 * that cannot start a session from here."* — exists nowhere in the app now
 * (`grep -rn "cannot start a session from here" src/`: no hits). Taking the
 * button off this card was right and asked for; taking the app's only statement
 * of that fact with it was a side effect, and the fix belongs to whoever owns
 * the rail and the dialog, not to this file. Written down here because this is
 * where the check used to live and where somebody will come looking for it.
 */

/** The link for a machine, or the resting state of one nothing has dialled. */
export function linkFor(view: MachinesView, id: string): MachineLinkState {
  return (
    view.links.find((link) => link.id === id) ?? {
      id,
      state: 'offline',
      reason: null,
      sessions: [],
      folders: null,
      capabilities: [],
      ports: [],
      copilot: null,
      hostPlatform: '',
      hostVersion: '',
      hostKind: null,
      retryAt: null,
    }
  )
}

/* -------------------------------------------------------------------------- */
/* The list                                                                    */
/* -------------------------------------------------------------------------- */

export function MachineLinks({ half, platform }: { half: MachinesHalf; platform?: UiPlatform }) {
  const { view, actions } = half

  return (
    <Group title="Machines you can reach">
      {/*
        No paragraph under the heading.

        There was one, defining what a paired machine is and how pairing works,
        above a list of the reader's own paired machines. *"We don't need to
        give the statements. We want simplicity. Let the smart people use it."*
        The code field is directly above this and the list is directly below it;
        neither needs introducing.
      */}
      {!half.wired ? (
        <Notice tone="warn">
          This window is running against an older preload, so it cannot reach the machines this
          desktop is paired with. Restarting the app usually fixes it.
        </Notice>
      ) : half.reading ? (
        // The list waits, and nothing above it does. A whole section that says
        // "Reading…" for a moment is a section whose first frame is one nobody
        // can start a pairing on — including, on a cold window, the code
        // somebody has walked over to type.
        //
        // "for a moment" is now true rather than hoped for: the caller reads
        // under a deadline, so this line always resolves into a list, an empty
        // list or the notice below it.
        <p className="settings-prose">Reading the machines this desktop knows…</p>
      ) : half.error != null ? (
        <Notice tone="warn">
          {half.error}{' '}
          {half.retry && <Button onClick={half.retry}>Try again</Button>}
        </Notice>
      ) : view.machines.length === 0 ? (
        // Four words. The instruction that used to follow them — "type its code
        // above and its sessions appear here" — described the field it is
        // sitting under.
        <p className="settings-prose">No other machine yet.</p>
      ) : (
        <ul className="machines-list">
          {view.machines.map((machine) => (
            <MachineRow
              key={machine.id}
              machine={machine}
              link={linkFor(view, machine.id)}
              platform={platform}
              actions={actions}
            />
          ))}
        </ul>
      )}
      {/*
        No terminal under the list.

        There was one, and taking it out is the change this file exists to
        record — see the header. A session row now opens the session in the
        window's own view, which is the view it has always had for a local one.
      */}
    </Group>
  )
}

/* ------------------------------------------------------------------- row -- */

/**
 * What to call the shell at the other end, in one word beside its version.
 *
 * `headless` is a `server` here because that is what a person installed and what
 * they call it — the wire keeps the raw kind for the same reason `hostPlatform`
 * keeps the raw platform, and the noun is the panel's to choose. Kept to the two
 * links that `MachineLinkState.hostKind` narrows to; null never reaches this,
 * the caller guards it.
 */
function hostKindNoun(kind: 'desktop' | 'headless'): string {
  return kind === 'headless' ? 'server' : 'desktop'
}

export function MachineRow({
  machine,
  link,
  actions,
  platform,
}: {
  machine: Machine
  link: MachineLinkState
  actions: MachineActions
  platform?: UiPlatform
}) {
  const [confirming, setConfirming] = useState(false)
  const noun = machineNoun(link.hostPlatform === '' ? machine.platform : link.hostPlatform)

  return (
    <li className="machines-row" data-state={link.state}>
      <div className="machines-row-head">
        <span className="machines-dot" aria-hidden="true" />
        <span className="machines-name">{machine.name}</span>
        <span className="machines-kind">{noun}</span>
        <span className="machines-state">{STATE_LABEL[link.state]}</span>
      </div>

      {/*
        What build the machine at the other end is running, and whether it is a
        desktop or a headless server, off its last `welcome`. Shown only once it
        has said so — a machine that never connected, or one on a build from
        before the field, carries an empty version and gets no line rather than a
        guessed number. It is display text: there is no update verb on this wire,
        and replacing a host stays on the SSH and desktop plane this window
        already is.
      */}
      {link.hostVersion !== '' && (
        <p className="machines-version">
          version {link.hostVersion}
          {link.hostKind !== null && ` · ${hostKindNoun(link.hostKind)}`}
        </p>
      )}

      {/*
        The far machine's sentence, except for the one state where it is written
        for the wrong reader. `authenticatorFor` says "Approve it in the desktop
        app, then reconnect" — perfect for a phone, and nonsense on a desktop
        that *is* the app, three feet from the machine that has to do the
        approving. So this state gets an instruction that names the machine the
        person has to walk to, and every other state keeps the far end's own
        words, because it knows why it said no and this end does not.
      */}
      {link.state === 'awaiting-approval' ? (
        <p className="machines-reason">
          Approve {thisMachine(platform)} on {machine.name}, under Remote. It will connect by
          itself once you have.
        </p>
      ) : (
        link.reason !== null && <p className="machines-reason">{link.reason}</p>
      )}

      <p className="machines-key" title="Compare this with the same six groups on that machine">
        {machine.fingerprint}
      </p>

      {link.state === 'online' && link.sessions.length === 0 && (
        <p className="machines-note">Nothing is running on that {noun} right now.</p>
      )}

      {link.sessions.length > 0 && (
        <ul className="machines-sessions">
          {link.sessions.map((session) => (
            <SessionRow
              key={session.id}
              session={session}
              /* Null when there is no window to show it in, so the row draws no
                 button at all rather than one that does nothing. See
                 `MachineActions.open`. */
              onOpen={
                actions.open === undefined
                  ? null
                  : () => actions.open?.(machine.id, session.id)
              }
            />
          ))}
        </ul>
      )}

      {link.state === 'online' && link.capabilities.includes('localhost') && (
        <RemotePorts
          machine={machine}
          link={link}
          noun={noun}
          onOpen={(port) => actions.openPort(machine, port)}
          onRefresh={() => actions.refreshPorts(machine)}
        />
      )}

      <DriveWindows machine={machine} link={link} noun={noun} actions={actions} />

      <div className="machines-actions settings-chips">
        {/*
          Two buttons, and both of them are about this end's relationship with
          that machine rather than about starting work on it. A **New session**
          stood first in this row until 2026-08-19 — *"we don't need this new
          session thing here. Just disconnect and forget thing is good enough for
          us."* The header says where that press lives now and why the pair that
          is left is the right pair.
        */}
        {link.state === 'online' || link.state === 'connecting' ? (
          <Button onClick={() => actions.disconnect(machine)}>Disconnect</Button>
        ) : (
          <Button onClick={() => actions.connect(machine)}>Connect</Button>
        )}
        {confirming ? (
          <>
            <span className="machines-confirm">
              Forget this {noun}? You would pair it again from scratch.
            </span>
            <Button
              tone="danger"
              onClick={() => {
                setConfirming(false)
                actions.forget(machine)
              }}
            >
              Forget
            </Button>
            <Button onClick={() => setConfirming(false)}>Keep</Button>
          </>
        ) : (
          <Button onClick={() => setConfirming(true)}>Forget</Button>
        )}
      </div>

      {/*
        Two sentences used to close this row, and both of them explained why
        **New session** was not on it — one for a far machine that could not
        serve one, one for a copy of this page with no window around it to open
        the dialog in. Neither has anything left to explain, and a note about a
        control nobody can see is the wall of text this review was about.
      */}
    </li>
  )
}

/**
 * The one grant on this card, and the only setting here that is not a label.
 *
 * ## What it is for
 *
 * A browser window is a page in **this** app, holding this account's signed-in
 * mail, bank and source control. A session on the machine this card is about can
 * now act on one — that is the whole of what Asad asked for after 0.9.1:
 *
 * > *"i need full capability for all sessions to drive browsers the ones they
 * > open or the ones we connect to the session"*
 *
 * — and windows are still their own axis, beside folders, sessions and coding
 * logins, because attaching a window and driving one are different acts. What
 * changed is where the yes comes from.
 *
 * ## Why it starts on, and what the tick is for
 *
 * T30: *"the connection IS the authorization."* Every machine on this page is
 * one the person paired with their own hands — they read the code off its
 * screen and typed it here — and that act is the allowing, the same reading
 * `Machine.drivesWindows` makes at the store. So the tick is the **off**-switch
 * for one machine: unticking it keeps that machine's sessions out of the
 * browser here, and what a ticked machine reaches is still bounded window by
 * window by what the person attaches. The closed default lives on for the peer
 * nobody here vouched for — a device approved as a guest, in Settings →
 * Remote.
 *
 * ## Why it is drawn while the machine is offline, and what it says when it is on
 *
 * The grant is stored here and outlives every connection, so hiding the switch
 * with the link would mean a machine could only be trusted while it happened to
 * be awake. What *is* conditional is the sentence under it: when that machine is
 * connected and has not said it speaks this at all, the tick would be stored and
 * never used, and the honest thing is to say which end is behind. It is a
 * statement about the far machine, not an instruction, so it is one line.
 */
export function DriveWindows({
  machine,
  link,
  noun,
  actions,
}: {
  machine: Machine
  link: MachineLinkState
  noun: string
  actions: MachineActions
}) {
  const set = actions.setDrivesWindows
  // Not drawn rather than drawn dead. See {@link MachineActions.setDrivesWindows}.
  if (set === undefined) return null
  const on = machine.drivesWindows === true
  /*
   * Only while it is online. A machine that is not connected has published no
   * capability list — the link clears it on the way down, deliberately, because
   * a list from a connection that is over describes a machine that may have been
   * updated since — so "it did not say it speaks this" would be a claim about
   * silence.
   */
  const mute = on && link.state === 'online' && !link.capabilities.includes('windows')
  return (
    <div className="machines-grant">
      <label className="machines-grant-row">
        <input
          type="checkbox"
          checked={on}
          onChange={(event) => set(machine, event.currentTarget.checked)}
        />
        <span>Let its sessions act on browser windows here</span>
      </label>
      {mute && (
        <p className="machines-note">
          That {noun} is running a build that cannot ask, so nothing will use this yet.
        </p>
      )}
    </div>
  )
}

/**
 * One session on that machine, as a way into the window's view of it.
 *
 * It was a *toggle* — `aria-pressed`, pressed again to close — because pressing
 * it opened a terminal in this panel and pressing it again put that terminal
 * away. Neither half of that is true now: the press hands the session to the
 * window, which is where every other route to a session lands, and a second
 * press on a session already on screen would have nothing to undo. So it is a
 * plain button, and it says so.
 *
 * `onOpen` is nullable rather than defaulted, and the row genuinely changes
 * shape: with no window to open the session in there is no button here, only the
 * three facts it would have carried. A `<button>` with a no-op handler would
 * look identical, keep its hover and its focus ring, and do nothing — which is
 * the one thing a control in this app may not do.
 */
export function SessionRow({
  session,
  onOpen,
}: {
  session: RemoteSession
  onOpen: (() => void) | null
}) {
  const facts = (
    <>
      <span className="machines-session-title">{session.title}</span>
      <span className="machines-session-path">{shortPath(session.cwd)}</span>
      <span className="machines-session-status">{session.status}</span>
    </>
  )
  return (
    <li className="machines-session">
      {onOpen === null ? (
        <span className="machines-session-line">{facts}</span>
      ) : (
        <button type="button" className="machines-session-open" onClick={onOpen}>
          {facts}
        </button>
      )}
    </li>
  )
}

/**
 * That machine's icon, in eleven pixels.
 *
 * He asked for it in those words — *"remote localhost should list the remote
 * machine's ports with the machine's icon"* — and the reason is a real
 * confusion rather than decoration. This desktop has its own localhost list, on
 * the browser's start page, and the rows look identical: a number, a process
 * name, an Open. Without something on the row saying *which computer*, a person
 * looking at `3000 · node` has no way to know whether pressing it reaches the
 * thing they are running here or the thing running in the next room.
 *
 * Drawn rather than imported because there is no icon set in this codebase and
 * a downloaded one would drag a licence in — see the ground rule at the top of
 * CLAUDE.md. Three shapes, and each is the machine's own silhouette: a laptop
 * for a Mac, a window pane for a PC, a plain screen for anything else.
 * `currentColor` throughout, so it takes the row's ink in both themes rather
 * than carrying a colour of its own.
 */
export function MachineGlyph({ platform, label }: { platform: string; label: string }) {
  const kind = /^win/i.test(platform) ? 'windows' : /^darwin|mac/i.test(platform) ? 'mac' : 'other'
  return (
    <svg
      className="machines-glyph"
      viewBox="0 0 16 16"
      width="13"
      height="13"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
      strokeLinejoin="round"
      role="img"
      aria-label={label}
    >
      {kind === 'windows' ? (
        <>
          <rect x="2" y="3" width="12" height="10" rx="1.2" />
          <path d="M8 3v10M2 8h12" />
        </>
      ) : (
        <>
          <rect x="2.5" y="3" width="11" height="7.5" rx="1.2" />
          {/* The lid's base, which is what makes the Mac read as a laptop. The
              plain screen leaves it off rather than drawing a different machine
              for a platform this app has no build for. */}
          {kind === 'mac' ? <path d="M1 13h14" strokeLinecap="round" /> : <path d="M6 13h4" strokeLinecap="round" />}
        </>
      )}
    </svg>
  )
}

/** `3000 · node`, or `3000 · unknown process` when the far end could not name it. */
export function portLabel(port: RemotePort): string {
  if (port.process === '' || port.guessed) return `${port.port} · unknown process`
  return `${port.port} · ${port.process}`
}

/**
 * What that machine is serving, and the one thing this desktop can do about it.
 *
 * ## Why Open means "open it there"
 *
 * A tunnel would bring the page here, and this end opens no listener — the
 * desktop's guest link is a socket to one machine, not a proxy. What it can do
 * is drive: ask that machine to put the page on **its own** screen, which is
 * the same verb the phone has been sending since the web client needed it and
 * which nothing on this side had ever sent. That is what made machine-to-machine
 * localhost one-way, and it is the smaller promise this transport can actually
 * keep.
 *
 * ## Why there is a Refresh and it is not a poll
 *
 * The link asks once per connection and pushes the answer, so this list is
 * already there when the row is drawn. What a push cannot cover is the person
 * who has just started a dev server over there: nothing on the far machine
 * watches its own process table, so the only honest options are a timer against
 * somebody else's computer or a button. It is a button.
 */
export function RemotePorts({
  machine,
  link,
  noun,
  onOpen,
  onRefresh,
}: {
  machine: Machine
  link: MachineLinkState
  noun: string
  onOpen(port: number): void
  onRefresh(): void
}) {
  // A machine with no window to open a page in never advertises `web`, and
  // neither does one that treats this device as a guest. Both arrive the same
  // way and the button is simply absent — never disabled, which is a control
  // that still invites the ask.
  const canOpen = link.capabilities.includes('web')
  const label = `on ${machine.name}`
  return (
    <div className="machines-ports">
      <div className="machines-ports-head">
        <MachineGlyph platform={link.hostPlatform === '' ? machine.platform : link.hostPlatform} label={label} />
        <span className="machines-ports-title">Localhost on {machine.name}</span>
        <button type="button" className="machines-ports-refresh" onClick={onRefresh}>
          Refresh
        </button>
      </div>

      {link.ports.length === 0 ? (
        <p className="machines-note">Nothing is listening on that {noun} right now.</p>
      ) : (
        <ul className="machines-portlist">
          {link.ports.map((port) => (
            <li key={port.port} className="machines-port">
              {/* The icon is on every row and not only on the heading, which is
                  the whole point of it: a row is what gets read, and a row that
                  borrowed its identity from a heading four rows up is a row that
                  reads as local. */}
              <MachineGlyph
                platform={link.hostPlatform === '' ? machine.platform : link.hostPlatform}
                label={label}
              />
              <span className="machines-port-label">{portLabel(port)}</span>
              {canOpen && (
                <button
                  type="button"
                  className="machines-port-open"
                  title={`Open localhost:${String(port.port)} in the browser on ${machine.name}`}
                  onClick={() => onOpen(port.port)}
                >
                  Open there
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {/*
        Nothing where the refusal used to be written out.

        Two sentences explained that the far machine would not open a page for
        this one and what to do about it. The button is simply not on the rows —
        which is the same fact, drawn rather than narrated — and this menu spent
        the week having exactly this shape of paragraph removed from it.
      */}
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* The terminal                                                                */
/* -------------------------------------------------------------------------- */

/**
 * One session on another machine, live.
 *
 * Mounted only while a session is open, and it holds the subscription to
 * `machines:output` itself. The panel this came from kept a map of every open
 * terminal's writer and one subscription for all of them, which was the right
 * shape when it thought it might show several — it never has: one session is
 * open at a time, and the map was one indirection standing between a chunk of
 * bytes and the terminal it belongs to.
 *
 * The filter is not optional. Every machine's output arrives on one channel, so
 * a pane that wrote whatever it was handed would paint another machine's session
 * into this one the moment two links were both busy.
 */
export function MachineSessionPane({
  machineId,
  sessionId,
  bridge,
  end = null,
}: {
  machineId: string
  sessionId: string
  bridge: MachinesBridge
  /**
   * Why this session's screen has stopped being one, or null while it is.
   *
   * Passed straight through to the terminal, which is where the argument for it
   * is written. The window reads it — `endOfMachineSession` needs the *link*,
   * and this pane holds one session id and nothing else — so the pane, the bar
   * above it and the rail row all say one thing about one event.
   */
  end?: SessionEnd | null
}) {
  /*
   * Read here rather than threaded down from the section.
   *
   * The hook is one read at launch plus whatever the settings window pushes, so
   * asking for it costs nothing — and the alternative is the bug this repository
   * has already shipped twice: a font size in Settings that reaches a preview
   * and no terminal.
   */
  const { values: settings } = useAppSettings()
  const fontSize = numberSetting(settings, 'appearance.terminalFontSize')
  const fontFamily = stringSetting(settings, 'appearance.terminalFontFamily')

  /**
   * The terminal's writer, held in a ref so that `subscribe` never changes.
   *
   * `RemoteTerminal` rebuilds its xterm whenever `subscribe` is a new function —
   * it is in the effect's dependencies, and it has to be, because a stale
   * subscription would deliver bytes to a disposed terminal. A `subscribe`
   * rebuilt on every render would therefore tear the terminal down and put it up
   * again on every keystroke, which is the whole session's scrollback lost each
   * time the font size setting is read.
   */
  const sink = useRef<((data: string, replay: boolean) => void) | null>(null)
  const subscribe = useRef((handler: (data: string, replay: boolean) => void) => {
    sink.current = handler
    return () => {
      if (sink.current === handler) sink.current = null
    }
  }).current

  useEffect(() => {
    return bridge.onMachineOutput((chunk) => {
      const output = chunk as {
        machineId?: unknown
        sessionId?: unknown
        data?: unknown
        replay?: unknown
      }
      if (output?.machineId !== machineId || output?.sessionId !== sessionId) return
      // The flag is carried the last step rather than dropped here. It is how
      // the terminal knows the far machine has finished replaying its
      // scrollback, which is what stops the history being watched — see
      // `RemoteTerminal` and `terminal-backfill.ts`.
      if (typeof output.data === 'string') sink.current?.(output.data, output.replay === true)
    })
  }, [bridge, machineId, sessionId])

  return (
    <RemoteTerminal
      machineId={machineId}
      sessionId={sessionId}
      bridge={bridge}
      subscribe={subscribe}
      fontSize={fontSize}
      fontFamily={fontFamily}
      end={end}
    />
  )
}

/* -------------------------------------------------------------------------- */
/* The actions                                                                 */
/* -------------------------------------------------------------------------- */

export interface MachineActionDeps {
  /** Null when this build has no machine channels; every action then refuses. */
  bridge: MachinesBridge | null
  /** What is in the entry boxes right now. */
  digits: string
  setDigits(next: string): void
  setView(view: MachinesView): void
  setPairing(busy: boolean): void
  setError(message: string | null): void
  /**
   * Ask the window to show a session on a far machine — or null, if there is no
   * window around this page.
   *
   * A `setOpen` stood here instead, writing this panel's own "which session has
   * a terminal open below the list" state. That terminal is gone; the header
   * says why, and `session-view-context.ts` says how the press gets to the
   * window now.
   *
   * Null is not a convenience for tests. It is what a page rendered outside a
   * window genuinely has, and it is carried all the way down: with no way to
   * show a session, {@link MachineActions.open} is *absent* from the object this
   * function returns and the row draws no button. A no-op here would have made
   * that impossible to distinguish from a working one.
   */
  showSession: ((machineId: string, sessionId: string) => void) | null
  /** False once the section has gone, so nothing writes to a dead component. */
  isAlive(): boolean
  /*
   * `openNewSession` was here — the window's `openNewSessionDialog(null,
   * machineId)`, passed down as `null` when there is no window, so that one
   * representation of "there is nothing to press this into" reached the row.
   *
   * The card no longer draws that button (see the header), so nothing on this
   * side has a use for the opener, and `RemoteSection` stopped reading the
   * context in the same change.
   *
   * An earlier draft of this note said the context stays "because the rail's ＋
   * is wired through `App.tsx`", and that is **wrong** — checked, not assumed:
   * `App.tsx` passes the rail a plain prop,
   * `onNewMachineSession={(machineId) => openNewSessionDialog(null, machineId)}`,
   * and has never reached the ＋ through `MachineSessions`. The context was only
   * ever for this page, because this page is the one `PanelView` draws without
   * per-view props. With this row's use of it gone there is no call site left
   * anywhere: `grep -rn useMachineSessionOpener src/renderer` finds the hook's
   * own definition, and otherwise only notes like this one recording that it
   * went. So `new-session-context.ts` and the `MachineSessions.Provider` still
   * mounted at `App.tsx` are dead, and removing them is owed to whoever owns
   * `App.tsx` rather than done from here — deleting the module from this side
   * would break the import that mounts the provider. `new-session-context.ts`
   * says the same at its head, so a reader arriving from either side learns it.
   */
}

/**
 * Every press on this half, as a plain function of its dependencies.
 *
 * Split out of the component for the reason `remoteActions` is: there is no DOM
 * in this repository's test environment, so anything left inside a `useState`
 * closure is reachable by nothing but a person clicking it in a packaged build —
 * and what is behind these is a shell on somebody else's computer. Pulled out
 * here, the ones that matter are pinned: that pairing sends the *canonical* code
 * rather than whatever was typed, that a refusal is printed in the far machine's
 * own words, and that the list on screen comes from the answer rather than from
 * the fact that a call returned.
 */
export function machineActions(deps: MachineActionDeps): MachineActions {
  const { bridge, setView, setPairing, setError, showSession, isAlive } = deps

  const reread = async (): Promise<void> => {
    if (!bridge) return
    const view = asView(await bridge.listMachines())
    if (isAlive()) setView(view)
  }

  /** Do it, then draw the view that came back — never the one that was asked for. */
  const settle = (answer: Promise<unknown>): void => {
    void answer.then((next) => {
      if (isAlive()) setView(asView(next))
    })
  }

  return {
    type: (next) => {
      deps.setDigits(next)
      // The error belonged to the code that was there a moment ago. Leaving it
      // under a field somebody is retyping reads as a complaint about what they
      // are typing now.
      setError(null)
    },
    pair: () => {
      if (!bridge) return
      const canonical = normaliseCode(deps.digits)
      if (canonical === null) {
        // Unreachable through the button, which is disabled until the code is
        // whole — and said out loud anyway, because a press that does nothing
        // at all is the one thing this screen may not do.
        setError('That is not a whole code yet.')
        return
      }
      setPairing(true)
      setError(null)
      void bridge
        .pairMachine(canonical)
        .then(async (answer) => {
          const result = asPairResult(answer)
          if (!result.ok) {
            if (isAlive()) setError(result.message)
            return
          }
          if (isAlive()) deps.setDigits('')
          await reread()
        })
        .catch((error: unknown) => {
          if (isAlive()) setError(error instanceof Error ? error.message : String(error))
        })
        .finally(() => {
          if (isAlive()) setPairing(false)
        })
    },
    connect: (machine) => {
      if (bridge) settle(bridge.connectMachine(machine.id))
    },
    disconnect: (machine) => {
      if (bridge) settle(bridge.disconnectMachine(machine.id))
    },
    forget: (machine) => {
      if (bridge) settle(bridge.forgetMachine(machine.id))
    },
    /*
     * A `newSession` was built here and is not any more.
     *
     * Its history is worth one paragraph, because the thing it *replaced* must
     * not come back with it if the button ever does. It began as
     * `bridge.createMachineSession(machine.id, link.folders?.[0] ?? '')` — one
     * press, and a session was running on somebody else's computer under
     * whichever agent that machine defaults to, in whichever folder happened to
     * be first in the list it advertised. That was rewritten to call the
     * window's `openNewSessionDialog(null, machineId)` so the person answered
     * those questions. Now the press itself has gone from this card and lives
     * only on the rail's machine heading, which makes the same call.
     *
     * So: nothing here talks to a far machine to start a session, and nothing
     * here ever should again. The dialog's Start is what does that.
     */
    /*
     * Spread rather than written as a property, so that "there is no window"
     * comes out as a *missing* method rather than one that is present and
     * refuses. `MachineRow` reads `actions.open === undefined` and draws the
     * session as text; a present-but-inert `open` would have drawn a button.
     */
    ...(showSession === null ? {} : { open: showSession }),
    openPort: (machine, port) => {
      // The address is composed here from a row that is on screen, so nothing
      // arbitrary is ever sent — and the far machine checks it anyway, through
      // the same gate an untrusted link goes through. A second, weaker check
      // written on this side would be the one somebody later mistook for the
      // real one.
      if (bridge) void bridge.openOnMachine(machine.id, `http://localhost:${String(port)}/`)
    },
    /*
     * The grant, written where every other machine setting is written: in the
     * main process, against the one store. Nothing is drawn from this promise —
     * the handler answers the whole view and `settle` redraws from it — so the
     * switch shows what was *stored* rather than what was pressed. A tick that
     * moved before the store agreed would be a control reporting its own
     * intention.
     */
    setDrivesWindows: (machine, allowed) => {
      const set = bridge?.setMachineDrivesWindows
      if (bridge && set) settle(set.call(bridge, machine.id, allowed))
    },
    refreshPorts: (machine) => {
      // Nothing is drawn from the answer: the far machine replies with a `ports`
      // frame, the link publishes it, and the whole view arrives on
      // `machines:state`. Redrawing from this promise would be a second path to
      // the same list and the two would disagree the first time one was slow.
      if (bridge) void bridge.refreshMachinePorts(machine.id)
    },
  }
}
