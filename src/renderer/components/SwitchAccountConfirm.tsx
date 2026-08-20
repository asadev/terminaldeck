import { HoverNote } from './HoverNote'
import { Modal } from './Modal'
import {
  switchConversationNote,
  SWITCH_KEEPS,
  type SwitchNames,
  type SwitchPlanView,
} from '../session-switch'
import './SwitchAccountConfirm.css'

/**
 * "Run this session as somebody else?" — asked before anything is stopped.
 *
 * ## Why there is a dialog here at all
 *
 * The house rule is that a confirmation on every action trains the muscle that
 * dismisses it — `CloseSessionConfirm` says so at length and asks about exactly
 * two states because of it. This one asks every time, and the difference is what
 * the dialog is *for*. That one is a safeguard: it exists to stop a click you
 * did not mean. This one is a **description**: it exists because the thing about
 * to happen cannot be worked out from the control that starts it.
 *
 * The complaint underneath the whole feature is that:
 *
 *   > *"when I change account from the dropdown it starts a new session with
 *   > that account, instead of changing it in the same session."*
 *
 * The fix is to change it in the same session — and a person picking an account
 * from a menu still has no way to know that doing so stops a running agent, nor
 * that the conversation on screen does not travel with them. Neither of those is
 * guessable and both are irreversible in the moment. So this is not "are you
 * sure": it is the paragraph the menu could not hold, with a Cancel beside it.
 *
 * ## Everything on it is read, not composed
 *
 * The refusal is the main process's own sentence. The conversation line comes
 * from a plan that has looked at the target account's transcript store on disk.
 * Nothing here softens either: in particular, when the switch is going to
 * continue the *other* account's conversation in this folder, this says so in
 * those words, because that is the single most surprising thing it can do and
 * discovering it afterwards is indistinguishable from a bug.
 *
 * ## The failure state stays on screen
 *
 * A switch that could not start has left the session running — the main process
 * starts the replacement before it stops anything, precisely so that a failure
 * costs nothing — so a failure here is a sentence to read rather than a loss to
 * report. The sheet holds it, with Cancel now reading Close, instead of vanishing
 * and leaving somebody in front of a session that did not change with no account
 * of why.
 */

interface Props {
  open: boolean
  /** The session's tab label — what is being switched. */
  title: string
  /** What to call the two accounts. Off the identity ladder, never the slug. */
  names: SwitchNames
  /** What the main process says would happen. Null while it is still being asked. */
  plan: SwitchPlanView | null
  /** True while the plan is being fetched, or while the switch is running. */
  busy: boolean
  /** Why it could not be done, in the main process's own words. */
  problem: string | null
  onCancel(): void
  onConfirm(): void
  /**
   * Arm it for the next message instead of doing it now.
   *
   * Optional, and absent rather than disabled on a build whose bridge cannot
   * defer: a button that is present and refuses is worse than one that is not
   * there, because it reads as a feature that is broken rather than as one this
   * build does not have.
   */
  onDefer?(): void
  /** Whether this build can defer at all. Decides the button's existence. */
  canDefer?: boolean
}

export function SwitchAccountConfirm({
  open,
  title,
  names,
  plan,
  busy,
  problem,
  onCancel,
  onConfirm,
  onDefer,
  canDefer = false,
}: Props) {
  /*
   * Three states, and the button is only offered in one of them.
   *
   * A plan that has not arrived cannot be described, and a plan carrying a
   * refusal describes something that is not going to happen — offering a Switch
   * button beside either would be a control that either does nothing or does
   * something nobody has read a description of, which is the failure this whole
   * sheet exists to remove.
   */
  const refusal = plan?.refusal ?? null
  const canSwitch = plan !== null && refusal === null

  return (
    <Modal
      open={open}
      title={`Run this session as ${names.to}?`}
      description={title}
      onClose={onCancel}
      footer={
        <>
          <button type="button" className="modal-btn" onClick={onCancel}>
            {/* "Close" once there is nothing left to cancel — a refusal, or a
                failure that has already happened. Calling it Cancel there
                implies the switch is still pending and could be stopped. */}
            {canSwitch && problem === null ? 'Cancel' : 'Close'}
          </button>
          {/*
            The deferred switch, and it is deliberately the *left* of the two
            rather than the primary.

            It is the one Asad described as the default — "the running agent
            will keep running on the previous one… when we give another command
            it will be changed" — but it is also the one whose effect is not
            immediate, and a primary button that appears to do nothing is the
            complaint this sheet was built out of. So the visibly-immediate act
            keeps the primary slot and this sits beside it, saying in the label
            exactly when it will happen.
          */}
          {canSwitch && problem === null && canDefer && onDefer && (
            <button type="button" className="modal-btn" disabled={busy} onClick={onDefer}>
              Switch at my next message
            </button>
          )}
          {canSwitch && problem === null && (
            <button
              type="button"
              className="modal-btn primary"
              disabled={busy}
              onClick={onConfirm}
            >
              {busy ? 'Switching…' : 'Switch now'}
            </button>
          )}
        </>
      }
    >
      <div className="switch-confirm">
        {plan === null && problem === null && (
          <p className="switch-confirm-detail">
            {/* Said rather than spun. Working out what a switch would do means
                reading the other account's transcript store, which is a disk
                read and is occasionally a slow one on a network volume. */}
            {busy ? 'Working out what this would do…' : 'Nothing could be worked out about this switch.'}
          </p>
        )}

        {refusal !== null && (
          <p className="switch-confirm-headline" role="alert">
            {refusal}
          </p>
        )}

        {canSwitch && (
          <>
            {/*
              Which two accounts, and nothing else.

              Three paragraphs used to stand here — what a switch keeps, what
              becomes of the conversation, and what the second button means —
              and they were the thing he singled out:

                > *"here you have a very long description… Remove this full
                > shit. I don't want any kind of long descriptions anywhere.
                > Just if somewhere it's very required, give the i icon like
                > other ones, information icon in the settings, same way."*

              The paragraph about what a switch keeps was written when a switch
              lost the conversation and had to say so in advance. It does not
              lose it any more — both accounts are put on one conversation
              history before this sheet is drawn — so the paragraph is not only
              long, it is describing a cost that no longer exists. It lives
              behind the dot now, which is the affordance he named.

              The title says where he is going; this says where he is. Two
              names and an arrow, because that is information rather than prose.
            */}
            <p className="switch-confirm-headline">
              {names.from} → {names.to}
              <HoverNote label="What switching does">{SWITCH_KEEPS}</HoverNote>
            </p>
            {/*
              And the one sentence that is not a description: the conversation
              is *not* coming with him.

              Silent when it does come, which is now the ordinary case — a line
              saying everything is fine is exactly the statement he asked to be
              rid of. It stays for the cases the app cannot fix on his behalf:
              an account whose folder somebody chose themselves, an agent whose
              history this app cannot read, another tab already on the
              conversation. Those are losses, and a loss he was not warned about
              is the fault this sheet exists for.
            */}
            {plan.conversation !== 'follows' && (
              <p className="switch-confirm-detail" role="alert">
                {switchConversationNote(plan, names)}
              </p>
            )}
          </>
        )}

        {problem !== null && (
          <p className="switch-confirm-problem" role="alert">
            {problem}
            {/* The one fact that turns a failure into a non-event, and it is
                only true because of the order the main process does things in.
                Worth stating outright: somebody who has just read "could not"
                will otherwise go looking for what they lost. */}
            <span className="switch-confirm-detail"> This session is still running as it was.</span>
          </p>
        )}
      </div>
    </Modal>
  )
}
