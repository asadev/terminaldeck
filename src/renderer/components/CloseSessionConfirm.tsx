import { useCallback, useEffect, useState } from 'react'
import type { ProviderId, SessionStatus } from '@shared/types'
import { Modal } from './Modal'
import { PROVIDER_OPTIONS } from './ProviderPicker'
import './CloseSessionConfirm.css'

/**
 * Confirming a close.
 *
 * ## It asks every time now, and that is a decision he made
 *
 * Asad, 2026-08-17, on closing from the side panel: *"Always ask."* Stated
 * plainly, about anything, and it reverses what is written below.
 *
 * What was here before asked about exactly two states — `working` and `input` —
 * on the argument that a dialog on every close trains the muscle memory that
 * dismisses it. That argument is sound and it lost to a better one: his audience
 * is *"mostly non-technical vibe coders"*, ending a session is irreversible, and
 * a person who does not yet know what `working` means cannot use a safeguard
 * that only appears in states they cannot see. The escape hatch is the point —
 * "don't ask again" is one tick away, and since this pass it says where to turn
 * itself back on, which is the half he found missing.
 *
 * ## The states still mean different things, and the dialog still says so
 *
 * {@link RISKY_STATUSES} did not go; it stopped deciding *whether* to appear and
 * now decides *what is at stake*, which is what it was always describing. Read
 * from `session-activity.ts`, which is what produces them — and one does not
 * mean what its name suggests:
 *
 * - `working`  — a spinner is on screen, output is still streaming. Something to lose.
 * - `input`    — the agent asked a question and is blocked on the answer. Something to lose.
 * - `waiting`  — **an empty prompt**. The CLI is ready for you and doing
 *                nothing. Despite the name this is the resting state of every
 *                healthy session.
 * - `idle`     — nothing recognisable on screen.
 * - `completed`— finished.
 * - `exited`   — the process is already gone.
 *
 * The last four are asked about too, in their own words: closing them still ends
 * a terminal with its scrollback, its shell history and whatever is half-typed
 * in it, which is a small loss rather than no loss.
 */

/** The two states where closing costs real work. See the module note. */
export const RISKY_STATUSES: ReadonlySet<SessionStatus> = new Set<SessionStatus>([
  'working',
  'input',
])

/**
 * Setting id holding whether this dialog is shown at all.
 *
 * This is the id declared in settings-schema.ts, NOT a key of its own. Two
 * agents briefly stored this one setting in two places — the Settings window
 * wrote `general.confirmCloseWorking` while this dialog read
 * `confirmCloseSession` — so turning the option off in Settings changed
 * nothing here. Anything user-visible lives in the schema, once.
 */
export const CONFIRM_CLOSE_KEY = 'general.confirmCloseWorking'

/**
 * Should closing this session be confirmed?
 *
 * The caller's gate, not the dialog's: a component that decides for itself
 * whether to appear can only refuse by rendering nothing, which leaves the user
 * having clicked close with no session closed and no dialog to explain it. That
 * is not hypothetical — this file used to hold a second copy of the rule as a
 * `return null` backstop inside the component, and the moment the caller's rule
 * widened, the backstop would have turned every calm close into a ✕ that did
 * nothing at all.
 *
 * `status` is still taken, and is still what the dialog's wording is built from
 * — see {@link closeWarning}. It no longer decides whether to ask: *"Always
 * ask."* The one thing that can switch this off is the person, by ticking the
 * box in the dialog, and Settings → General turns it back on.
 */
export function needsCloseConfirm(_status: SessionStatus, confirmEnabled: boolean): boolean {
  /*
   * `_status` is still in the signature, deliberately, and it is not vestigial.
   *
   * Every caller already has the status in hand and passes it, and the moment it
   * is dropped from here it stops being obvious that this is the place where a
   * per-status rule would go if one ever comes back. Underscored because the
   * body genuinely does not read it any more, which `noUnusedParameters` is
   * right to insist be said out loud rather than left looking used.
   */
  return confirmEnabled
}

/**
 * Read the setting out of a preferences blob.
 *
 * Defaults to asking. A missing key is what every existing install has — the
 * preference was added with this dialog — and the safe reading of "unknown" is
 * the one that cannot silently kill a working agent.
 */
export function parseConfirmClose(raw: unknown): boolean {
  if (typeof raw !== 'object' || raw === null) return true
  const value = (raw as Record<string, unknown>)[CONFIRM_CLOSE_KEY]
  return typeof value === 'boolean' ? value : true
}

/**
 * The slice of the bridge this dialog writes through — the settings store,
 * which is where every schema-declared setting lives.
 */
interface PreferenceBridge {
  getSettings(): Promise<unknown>
  setSettings(patch: Record<string, unknown>): Promise<unknown>
}

function preferenceBridge(): PreferenceBridge | null {
  const api = (globalThis as { deck?: Partial<PreferenceBridge> }).deck
  if (!api || typeof api.getSettings !== 'function' || typeof api.setSettings !== 'function') {
    return null
  }
  return api as PreferenceBridge
}

/** Whether this dialog should appear at all. Defaults to yes on any failure. */
export async function readConfirmClose(): Promise<boolean> {
  const bridge = preferenceBridge()
  if (!bridge) return true
  try {
    return parseConfirmClose(await bridge.getSettings())
  } catch {
    return true
  }
}

export async function writeConfirmClose(enabled: boolean): Promise<void> {
  const bridge = preferenceBridge()
  if (!bridge) return
  try {
    await bridge.setSettings({ [CONFIRM_CLOSE_KEY]: enabled })
  } catch {
    // The close still happens. A setting that failed to save is a nuisance
    // next launch; blocking the close on it would be a bug now.
  }
}

export interface CloseWarning {
  headline: string
  detail: string
}

/**
 * What is being closed, which decides the nouns rather than the behaviour.
 *
 * Three subjects because there are three things in this window whose close ends
 * more than itself, and the sentence has to name the right one. A machine group
 * arrived on 2026-08-18 and is genuinely a third case rather than a project by
 * another name: closing a project takes its folder off the rail *and* kills its
 * sessions, and closing a machine ends its sessions and leaves the machine
 * paired — *"it should not disconnect the remote account. It will just close all
 * of the sessions from that PC."* Telling somebody they are about to close a
 * project when they pressed ✕ on a computer is the kind of wrong that makes a
 * confirmation stop being read.
 */
export type CloseSubject = 'session' | 'project' | 'machine' | 'server'

/**
 * The nouns, per subject, in one table.
 *
 * A fourth subject arrived with terminals on servers, and it is genuinely a
 * fourth case rather than a machine by another name. The one question a person
 * has at this dialog is *what else does this take with it*, and the answers are
 * different: a project's close takes its folder off the rail, a machine's leaves
 * it paired, and a server's leaves a live machine — somebody's website — running
 * exactly as it was. Telling them they are about to close a *server* would be
 * the worst sentence on this screen, which is why the group heading below says
 * terminals and not the thing they are running on.
 */
const GROUP_NOUN: Record<CloseSubject, string> = {
  session: 'project',
  project: 'project',
  machine: 'machine',
  server: 'terminals',
}

/**
 * What is actually at stake, in the words of the state it is in.
 *
 * `count` is how many sessions are going at once. Closing a project takes every
 * session in it with it — silently, until now — and "this session is still
 * working" is the wrong sentence for four of them. `subject` says which kind of
 * thing those sessions belong to; it is only ever read when there is more than
 * one, because a single session's warning is about the session.
 *
 * The machine sentence names the machine's own limit as well as the loss, and
 * that is deliberate. The one question a person actually has at this dialog is
 * *"does this unpair my PC"*, and answering it in the confirmation is cheaper
 * than answering it afterwards by watching whether the machine came back.
 */
export function closeWarning(
  status: SessionStatus,
  count = 1,
  subject: CloseSubject = 'project',
): CloseWarning {
  if (subject === 'machine' && count > 1) {
    return {
      headline: `Closing this machine closes ${count} sessions on it.`,
      detail:
        'Every one of them stops where it is, on that machine, and anything they have not written to disk goes with them. The machine itself stays connected — New session brings it straight back.',
    }
  }
  if (subject === 'machine') {
    return {
      headline: 'This ends the session on that machine.',
      detail:
        'The agent stops there and its terminal goes, with its scrollback. The machine itself stays connected.',
    }
  }
  /*
   * A server, and the sentence is written around the fear rather than the act.
   *
   * Somebody pressing ✕ on a row that belongs to a live server is not worried
   * about losing a scrollback. They are worried that they have just stopped
   * their website, which is exactly what the word "close" beside a server's name
   * suggests to a person who does not know better — the same argument the
   * *Forget this server* control is written around one file over. So the detail
   * says what is left running, in the second clause, where it will be read.
   */
  if (subject === 'server' && count > 1) {
    return {
      headline: `This closes ${count} terminals on that server.`,
      detail:
        'Each of them stops where it is, and anything half-typed goes with it. Nothing else on the server is touched — whatever it was running before, it is still running now.',
    }
  }
  if (subject === 'server') {
    return {
      headline: 'This closes the terminal on that server.',
      detail:
        'Whatever is running inside it stops, and the terminal goes with its scrollback. Nothing else on the server is touched — it keeps running exactly as it was, and you can open another terminal whenever you like.',
    }
  }
  if (count > 1) {
    return {
      headline: `Closing this project closes ${count} sessions.`,
      detail:
        'Every one of them stops where it is. Anything they have not already written to disk goes with them.',
    }
  }
  if (status === 'input') {
    return {
      headline: 'This session asked you something.',
      detail:
        'It is blocked until it gets an answer. Closing now discards the question and whatever it was about to do.',
    }
  }
  if (status === 'working') {
    return {
      headline: 'This session is still working.',
      detail:
        'Closing stops the agent part-way through. Anything it has not already written to disk goes with it.',
    }
  }
  /*
   * The calm states, which are now asked about too — see the module note.
   *
   * They need words of their own rather than the "still working" sentence,
   * because the whole reason this dialog only appeared twice before was that
   * telling somebody they are about to lose work when they are not is how a
   * confirmation becomes a thing you click through without reading. A session
   * that has already exited is the sharpest case: there is no process left, and
   * saying so is what stops the dialog from crying wolf on the one press where
   * it genuinely does not matter.
   */
  if (status === 'exited') {
    return {
      headline: 'This session has already ended.',
      detail: 'Closing takes the row out of the sidebar. Its scrollback goes with it.',
    }
  }
  return {
    headline: 'This ends the session.',
    detail:
      'The agent stops and the terminal goes, with its scrollback and anything half-typed in it. It cannot be reopened where it left off.',
  }
}

/** Can this agent be picked up again afterwards? Mirrors the resume catalogue. */
export function canResumeProvider(provider: ProviderId | undefined): boolean {
  if (!provider) return false
  return PROVIDER_OPTIONS.find((option) => option.id === provider)?.canResume === true
}

interface Props {
  open: boolean
  /** The session's tab label, or the project's name — what is being closed. */
  title: string
  status: SessionStatus
  /**
   * How many sessions this close ends.
   *
   * More than one means a project is being closed, which takes every session in
   * it. That path used to bypass this dialog completely: `removeProject` killed
   * running agents with no confirmation at all, with the confirm switch on.
   */
  count?: number
  /**
   * What kind of thing is being closed — which decides the nouns, not the act.
   *
   * Defaults to `'project'`, which is what every caller meant before there was a
   * third subject: with `count` at 1 nothing reads it at all, and with `count`
   * above 1 the only thing that could produce that was a project.
   */
  subject?: CloseSubject
  /** Used only to say honestly whether the conversation can be resumed. */
  provider?: ProviderId
  onCancel(): void
  onConfirm(): void | Promise<void>
  /** Fired when "don't ask again" was ticked, so a cached flag can follow it. */
  onConfirmSettingChange?(enabled: boolean): void
}

export function CloseSessionConfirm({
  open,
  title,
  status,
  count = 1,
  subject = 'project',
  provider,
  onCancel,
  onConfirm,
  onConfirmSettingChange,
}: Props) {
  const [suppress, setSuppress] = useState(false)
  const [busy, setBusy] = useState(false)

  // This component is rendered by a workspace that keeps it mounted, so its
  // state outlives the session it was asked about. Without this, ticking
  // "don't ask again" and then clicking "Keep it open" leaves the tick armed:
  // the next confirm, about a different session, would silently disable the
  // dialog for good on a click the user made about something else.
  useEffect(() => {
    if (!open) return
    setSuppress(false)
    setBusy(false)
  }, [open])

  const confirm = useCallback(async () => {
    if (busy) return
    setBusy(true)
    try {
      // The setting is written first so a slow close cannot leave the tick
      // looking accepted while nothing was saved — but its failure is
      // swallowed, never allowed to stop the close the user actually asked for.
      if (suppress) {
        await writeConfirmClose(false)
        // Inside the try: this is the caller's callback, and a throw from it
        // used to skip the `finally` below — leaving `busy` stuck true, the
        // only enabled action disabled, and the dialog wedged on "Closing…"
        // with the session neither closed nor closable.
        onConfirmSettingChange?.(false)
      }
      await onConfirm()
    } finally {
      setBusy(false)
    }
  }, [busy, onConfirm, onConfirmSettingChange, suppress])

  /*
   * There is no `if (!RISKY_STATUSES.has(status)) return null` here any more,
   * and its absence is load-bearing rather than tidying.
   *
   * It was a second copy of the caller's rule, kept as a backstop against a
   * "you will lose work" dialog appearing over a session that exited ten minutes
   * ago. The caller's rule is now *"Always ask"*, and a component that refuses to
   * render is a component that can only refuse **silently**: the press would set
   * a pending close, draw nothing, and leave a ✕ that does nothing — which is
   * the exact complaint this session was sent to fix, reintroduced by the fix
   * for a different one. What the backstop was protecting is real and is handled
   * where it belongs: `closeWarning` says something true for every state instead
   * of one alarming sentence for all of them.
   */
  const warning = closeWarning(status, count, subject)
  /*
   * Whether this dialog is about one thing or a group of them.
   *
   * `count > 1` and not `subject !== 'session'`, because the two questions are
   * different and this one is about the wording of the buttons. A machine with
   * exactly one session running on it is closing one session and says so; the
   * plural sentence would be counting to one.
   */
  const group = count > 1
  const noun = GROUP_NOUN[subject]
  /*
   * "Close these terminals?" and not "Close this server?".
   *
   * The other three subjects name the container because closing it is what the
   * press does — a project, a machine's group. A server's container is a machine
   * that is still running, and putting its name after the word Close in the
   * largest type on the dialog is the one thing this screen must not do. The
   * name is still on screen, in `description` just below, where it identifies
   * which server without being the object of the verb.
   */
  const groupTitle = subject === 'server' ? 'Close these terminals?' : `Close this ${noun}?`

  return (
    <Modal
      open={open}
      title={group ? groupTitle : 'Close this session?'}
      description={title}
      onClose={onCancel}
      footer={
        <>
          <button type="button" className="modal-btn" onClick={onCancel}>
            Keep it open
          </button>
          <button
            type="button"
            className="modal-btn danger"
            disabled={busy}
            onClick={() => void confirm()}
          >
            {busy
              ? 'Closing…'
              : group
                ? subject === 'server'
                  ? 'Close terminals'
                  : `Close ${noun}`
                : 'Close session'}
          </button>
        </>
      }
    >
      <div className="close-confirm">
        <p className="close-confirm-headline">{warning.headline}</p>
        <p className="close-confirm-detail">{warning.detail}</p>

        {canResumeProvider(provider) && (
          <p className="close-confirm-detail">
            The conversation itself is kept — a new session in this folder can continue it.
          </p>
        )}

        <label className="close-confirm-suppress">
          <input
            type="checkbox"
            checked={suppress}
            onChange={(event) => setSuppress(event.target.checked)}
          />
          <span className="close-confirm-suppress-text">
            <span className="close-confirm-suppress-label">Don’t ask again</span>
            {/*
              Where to turn it back on, said here, on the control that turns it
              off.

              Asad, 2026-08-17: *"'Don't ask again' is a one-way door — once
              ticked there is no way to turn it back on. That has to exist."*
              It did exist by then — Settings → General carries the switch — but
              nothing in this dialog said so, and the comment that used to sit
              here explains why: the row was still unbuilt when this was written,
              and *"promising a control that is not there yet is the one thing a
              confirm dialog cannot afford to do."* The row was built and this
              sentence was never updated, so from where he was sitting the door
              was one-way.

              It names the place rather than offering a button. A link out of a
              confirmation is a second decision in front of the first one, and
              the person is mid-close; a sentence they can act on afterwards is
              what a one-way door actually needs.
            */}
            <span className="close-confirm-detail">
              Sessions close straight away from then on. Settings → General turns this back on.
            </span>
          </span>
        </label>
      </div>
    </Modal>
  )
}
