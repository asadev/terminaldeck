import { useCallback, useEffect, useState } from 'react'
import type { ProviderId, SessionStatus } from '@shared/types'
import { useSessionBinding } from '../browser/binding-view'
import { HoverNote } from './HoverNote'
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
 * The nouns, per subject, in one table — and every one of them names the thing
 * that actually goes away.
 *
 * They named the *container* until tonight: `project`, `machine`, `terminals`.
 * That was the right instinct answering the wrong question. The one thing a
 * person has to know at this dialog is *what else does this take with it*, and
 * the container is precisely what it does **not** take: a project's folder is
 * still on disk afterwards, a machine is still paired, and a server — somebody's
 * website — is still running exactly as it was. The sessions are what end.
 *
 * Naming them is also what lets the verb be his. *"Close might be confusing for
 * the people — they just think okay it will be just close, soft close or
 * something. But delete, they know that click it will go away completely… for
 * the sessions instead of saying close just say delete."* The old note here
 * argued that the group headings had to keep the word Close, because `Delete
 * this machine?` describes something that does not happen — and that was true of
 * the sentence it was written about. It stops being true the moment the sentence
 * is about the sessions, which is the half that genuinely is deleted.
 *
 * A server keeps a noun of its own because a shell on somebody's box is not what
 * this app calls a session anywhere else, and a dialog is the last place to
 * start teaching a new word for it.
 */
const GROUP_NOUN: Record<CloseSubject, string> = {
  session: 'sessions',
  project: 'sessions',
  machine: 'sessions',
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
      headline: `This deletes ${count} sessions on that machine.`,
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
   * their website, which is exactly what a destroying verb beside a server's
   * name suggests to a person who does not know better — and *delete* suggests
   * it harder than *close* did, which is the price of the clearer word. The same
   * argument the *Forget this server* control is written around one file over.
   * So the detail says what is left running, in the second clause, where it will
   * be read, and the verb is never given the server as its object.
   */
  if (subject === 'server' && count > 1) {
    return {
      headline: `This deletes ${count} terminals on that server.`,
      detail:
        'Each of them stops where it is, and anything half-typed goes with it. Nothing else on the server is touched — whatever it was running before, it is still running now.',
    }
  }
  if (subject === 'server') {
    return {
      headline: 'This deletes the terminal on that server.',
      detail:
        'Whatever is running inside it stops, and the terminal goes with its scrollback. Nothing else on the server is touched — it keeps running exactly as it was, and you can open another terminal whenever you like.',
    }
  }
  if (count > 1) {
    return {
      headline: `This deletes ${count} sessions in that project.`,
      detail:
        'Every one of them stops where it is. Anything they have not already written to disk goes with them.',
    }
  }
  if (status === 'input') {
    return {
      headline: 'This session asked you something.',
      detail:
        'It is blocked until it gets an answer. Deleting it now discards the question and whatever it was about to do.',
    }
  }
  if (status === 'working') {
    return {
      headline: 'This session is still working.',
      detail:
        'Deleting it stops the agent part-way through. Anything it has not already written to disk goes with it.',
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
      detail: 'Deleting takes the row out of the sidebar. Its scrollback goes with it.',
    }
  }
  return {
    // The word the button uses, in the sentence that says what it costs.
    headline: 'Deleting this session ends it.',
    detail:
      'The agent stops and the terminal goes, with its scrollback and anything half-typed in it. It cannot be reopened where it left off.',
  }
}

/**
 * `B1 and B2 stay open, detached.` — or nothing at all.
 *
 * Its own component so the hook is only called when there is a session id to
 * call it with, and so the dialog's body stays a list of lines rather than a
 * list of lines with a conditional hook in the middle of it.
 */
function AttachedWindowsLine({ sessionId, machineId }: { sessionId?: string; machineId: string }) {
  const binding = useSessionBinding(sessionId ?? '', machineId)
  if (!sessionId || !binding || binding.windows.length === 0) return null
  const slots = binding.windows.map((window) => `B${window.n}`)
  const named =
    slots.length === 1 ? slots[0] : `${slots.slice(0, -1).join(', ')} and ${slots[slots.length - 1]}`
  return (
    <p className="close-confirm-detail">
      {named} {slots.length === 1 ? 'stays' : 'stay'} open, detached.
    </p>
  )
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
  /**
   * The session being deleted, so the dialog can name the windows it lets go of.
   *
   * Asad pressed ✕ on a session that had browser windows attached and nothing
   * happened that he could see: *"it shows no message until we detach the
   * browser… but otherwise we will not even know that it is the reason."* An
   * attached window is not a reason to refuse — it never was, and nothing in
   * this app refuses on it — but a person who thinks it might be needs the
   * answer where the press happens rather than afterwards.
   *
   * So the dialog says what becomes of them, in one line, and then the delete
   * goes through. Absent for a project, a machine or a server, where the sentence
   * would be about a set rather than about a session.
   */
  sessionId?: string
  /** Empty for a session on this computer. */
  sessionMachineId?: string
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
  sessionId,
  sessionMachineId = '',
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
   * "Delete these sessions?" — and never the name of the thing they are in.
   *
   * One sentence for all four subjects now, where the server used to be a
   * special case. It stopped being one when the other three stopped naming their
   * container: a project, a machine and a server are all still there afterwards,
   * so none of them may be the object of this verb, and the exception collapsed
   * into the rule. Which project, machine or server is still on screen, in
   * `description` just below, where it identifies without being what is deleted.
   */
  const groupTitle = `Delete these ${noun}?`
  /*
   * Everything this dialog knows that is not the headline, as one paragraph
   * behind one dot.
   *
   * The resume fact used to be a fourth line on screen of its own. It is joined
   * here rather than given a second `ⓘ`, because two dots a centimetre apart,
   * each holding a sentence about the same press, is the thing he was looking at
   * in a different costume. One dot, one paragraph, one hover.
   */
  const detail = canResumeProvider(provider)
    ? `${warning.detail} The conversation itself is kept — a new session in this folder can continue it.`
    : warning.detail

  return (
    <Modal
      open={open}
      /*
       * One verb, said the same way in three places.
       *
       * The rail's ⋯ menu says `Delete`, this asks `Delete this session?` and
       * the button below says `Delete`. Before this pass the menu entry read
       * `Close Session 1 — ends the session` and the dialog said `Close this
       * session?`, which Asad read off the screen as the same thing written
       * twice: *"Close session one and end session, both are the same thing,
       * two times. So only give the delete button here. It should call only
       * delete. It should give the warning also, warning should also use the
       * word delete."*
       *
       * The group titles say it too now — *"don't give the button as close in
       * drop downs, in three dots, everywhere"* — which they could not while
       * they named the project or the machine, because `Delete this machine?`
       * is a sentence about something that does not happen. They name the
       * sessions instead; see `GROUP_NOUN`.
       */
      title={group ? groupTitle : 'Delete this session?'}
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
              ? 'Deleting…'
              : group
                ? `Delete ${noun}`
                : 'Delete'}
          </button>
        </>
      }
    >
      <div className="close-confirm">
        {/*
          The warning, in one line, with the rest of it behind the dot.

          Asad, in the same minute of the same recording as the button he
          specified below: *"here you have a very long description… Remove this
          full shit. I don't want any kind of long descriptions anywhere. Just
          if somewhere it's very required, give the i icon like other ones,
          information icon in the settings, same way."*

          So `warning.headline` is what is on screen — it is the sentence that
          uses the word `Delete`, which is the half he asked to keep — and
          `warning.detail` moved behind the same `ⓘ` the Settings panes use. The
          detail is not deleted: what it says (a terminal, its scrollback and
          anything half-typed goes) is true, is occasionally the thing somebody
          needs, and is worth exactly one hover. `HoverNote` also keeps it in the
          document for a screen reader, so nothing that could be read before this
          became unreadable.
        */}
        <p className="close-confirm-headline">
          {warning.headline}
          <HoverNote label={warning.headline}>{detail}</HoverNote>
        </p>

        {/*
          The windows this lets go of, and what happens to them.

          One line, not a paragraph — *"don't put any single statement in
          anywhere… smart people knows how it works"* — and it is here only when
          there is something to say. `B1, B2` is the vocabulary he already uses
          out loud and the one the agent was given, so the sentence needs no
          explanation of what a `B` is.

          This one stayed on screen while the sentence above it went behind a
          dot, and the difference is who it is about: everything else on this
          dialog describes the session being deleted, which is the thing he
          pressed delete on and already knows about. This names **other windows**
          — ones that stay open, that he did not act on, and that he cannot see
          from here. A fact about something else on screen is not a description
          of the button.
        */}
        <AttachedWindowsLine sessionId={sessionId} machineId={sessionMachineId} />

        <div className="close-confirm-suppress-row">
          <label className="close-confirm-suppress">
            <input
              type="checkbox"
              checked={suppress}
              onChange={(event) => setSuppress(event.target.checked)}
            />
            <span className="close-confirm-suppress-label">Don’t ask again</span>
          </label>
          {/*
          Where to turn it back on — behind the dot, and outside the `<label>`.

          Asad, 2026-08-17: *"'Don't ask again' is a one-way door — once ticked
          there is no way to turn it back on. That has to exist."* It does exist,
          in Settings → General, and this is the only place that says so; what
          changed this round is that it says so in a hover instead of in a second
          line of grey text under the tick, which is precisely the shape of thing
          he told us to stop drawing.

          Outside the `<label>` deliberately. `HoverNote`'s dot is a real
          `<button>`, and a button inside a label is a click that toggles the
          checkbox as well as opening the note — so reading why the tick is safe
          would have ticked it.
        */}
          <HoverNote label="Don’t ask again">
            Sessions go straight away from then on. Settings → General turns this back on.
          </HoverNote>
        </div>
      </div>
    </Modal>
  )
}
