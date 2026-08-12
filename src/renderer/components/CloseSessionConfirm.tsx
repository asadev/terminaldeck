import { useCallback, useEffect, useState } from 'react'
import type { ProviderId, SessionStatus } from '@shared/types'
import { Modal } from './Modal'
import { PROVIDER_OPTIONS } from './ProviderPicker'
import './CloseSessionConfirm.css'

/**
 * Confirming a close that would throw something away.
 *
 * ⌘W is one keystroke from ⌘Q and sits next to the tab it kills, so the cost of
 * never asking is an agent stopped mid-edit. The cost of always asking is
 * worse: a dialog on every close trains the muscle memory that dismisses it,
 * and then it is not a safeguard at all. So this asks about exactly two states
 * and never about the rest.
 *
 * ## Which states are worth asking about
 *
 * Read from `session-activity.ts`, which is what actually produces them — and
 * one of them does not mean what its name suggests:
 *
 * - `working`  — a spinner is on screen, output is still streaming. Asking.
 * - `input`    — the agent asked a question and is blocked on the answer. Asking.
 * - `waiting`  — **an empty prompt**. The CLI is ready for you and doing
 *                nothing. Despite the name this is the resting state of every
 *                healthy session, so confirming on it would fire on almost
 *                every close and teach the user to click through.
 * - `idle`     — nothing recognisable on screen. Nothing to lose.
 * - `completed`— finished. Nothing to lose.
 * - `exited`   — the process is already gone. There is nothing left to close.
 */

/** The two states where closing costs something. See the module note. */
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
 * having clicked close with no session closed and no dialog to explain it.
 */
export function needsCloseConfirm(status: SessionStatus, confirmEnabled: boolean): boolean {
  if (!confirmEnabled) return false
  return RISKY_STATUSES.has(status)
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

/** What is actually at stake, in the words of the state it is in. */
export function closeWarning(status: SessionStatus): CloseWarning {
  if (status === 'input') {
    return {
      headline: 'This session asked you something.',
      detail:
        'It is blocked until it gets an answer. Closing now discards the question and whatever it was about to do.',
    }
  }
  return {
    headline: 'This session is still working.',
    detail:
      'Closing stops the agent part-way through. Anything it has not already written to disk goes with it.',
  }
}

/** Can this agent be picked up again afterwards? Mirrors the resume catalogue. */
export function canResumeProvider(provider: ProviderId | undefined): boolean {
  if (!provider) return false
  return PROVIDER_OPTIONS.find((option) => option.id === provider)?.canResume === true
}

interface Props {
  open: boolean
  /** The session's tab label, so the dialog names what it is about to close. */
  title: string
  status: SessionStatus
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

  // The caller gates on `needsCloseConfirm`; this is the backstop. Rendering a
  // "you will lose work" dialog over a session that exited ten minutes ago is
  // the fastest way to make every future one of these get clicked through.
  if (!RISKY_STATUSES.has(status)) return null

  const warning = closeWarning(status)

  return (
    <Modal
      open={open}
      title="Close this session?"
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
            {busy ? 'Closing…' : 'Close session'}
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
            {/* No claim about where to undo it: the Preferences row that turns
                this back on is listed as required wiring for this feature, and
                promising a control that is not there yet is the one thing a
                confirm dialog cannot afford to do. */}
            <span className="close-confirm-detail">
              Busy sessions close immediately from then on.
            </span>
          </span>
        </label>
      </div>
    </Modal>
  )
}
