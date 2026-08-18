import { useCallback, useEffect, useId, useRef, useState, type FormEvent } from 'react'
import { createPortal } from 'react-dom'
import type { ProviderId } from '@shared/types'
import {
  AccountProviderList,
  chosenAccountProvider,
  type AccountProviderRow,
} from '../../components/ProviderPicker'
import { MAX_ACCOUNT_NAME_LENGTH } from '../../accounts'
import { agentProblem } from './account-agent'
import './AddAccountDialog.css'

/**
 * Add account — the sign-in steps, and nothing else.
 *
 * ## What it replaced
 *
 * From the recorded review of 2026-08-17:
 *
 *   > *"'Add' and 'Sign in' should be one thing, called **Add account**. It must
 *   > open a small popup with only the sign-in steps — not the whole Agents
 *   > page. It is confusing. Just give me the login, sign-in steps."*
 *
 * Before this there was a block at the foot of the Accounts pane — a heading, a
 * question, a list of agents, a name field, a button, three conditional notices
 * and an ⓘ — sitting under a list of existing accounts, under a list of
 * installed agents, under two default pickers, on a page that also carries the
 * whole of Setup. Every one of those parts was correct and the sum of them was
 * the complaint: to add a login you read a page. Now the page carries one
 * button, and the steps are the only thing in the popup.
 *
 * ## Why this is not a `Modal`
 *
 * `Modal` binds Escape on `window` in the bubble phase, and the Settings sheet
 * this opens from is itself a `Modal`. Listeners on one target fire in the order
 * they were added, so the sheet's listener — added first — runs first, and no
 * amount of `stopPropagation` from a dialog opened later reaches backwards in
 * time. Escape would dismiss this popup *and* throw away the settings window
 * behind it.
 *
 * `ShortcutsPopover` in this same window solved that already, and this takes the
 * same shape: the key is caught on `document` in the **capture** phase, which
 * runs before the event reaches any window-level bubble listener, and stopped
 * there. One Escape closes this; a second closes Settings.
 *
 * The panel is portalled to `<body>` rather than rendered in place, because the
 * pane it opens from is inside a scrolling column — an absolutely positioned
 * layer there scrolls away from under the person using it.
 *
 * ## What the steps actually are
 *
 * Three, numbered, because a numbered list is what somebody who has never done
 * this before can follow, and this app's audience is *"mostly non-technical vibe
 * coders"*. The third step is not a control: it says what will happen when the
 * button is pressed, which is that a terminal opens and the agent asks for the
 * login itself. Nobody should be hunting this screen for a password field that
 * cannot exist — this app never sees a credential.
 */

export interface AddAccountDialogProps {
  open: boolean
  /** The agents an account can be added for, refused ones included. */
  providerRows: readonly AccountProviderRow[]
  /** True while a create-and-sign-in is in flight. */
  busy: boolean
  /**
   * Make the account and start its sign-in, as one action.
   *
   * Null when this window cannot open a session, in which case the dialog says
   * so and refuses rather than creating an account that has no way to be signed
   * into.
   */
  onSignIn: ((name: string, provider: ProviderId) => void) | null
  onClose(): void
}

/**
 * The popup, portalled and dismissable.
 *
 * Split from {@link AddAccountSteps} for exactly the reason `SettingsWindow`
 * splits `SettingsPanel` out of the `Modal` around it: `createPortal` throws
 * under `renderToStaticMarkup`, which is the only rendering this project's
 * tests do, so a component that portals is a component whose contents cannot be
 * asserted. Everything worth pinning is in the panel.
 */
export function AddAccountDialog(props: AddAccountDialogProps) {
  if (!props.open) return null
  return createPortal(
    <div className="add-account-layer">
      {/* Catches the click that means "somewhere else". Barely tinted: this
          sits over a sheet that already has a scrim, and a second full-strength
          dim would read as the app going two steps away. */}
      <button
        type="button"
        className="add-account-scrim"
        aria-label="Close"
        onClick={props.onClose}
      />
      <AddAccountSteps {...props} />
    </div>,
    document.body,
  )
}

export function AddAccountSteps({
  open,
  providerRows,
  busy,
  onSignIn,
  onClose,
}: AddAccountDialogProps) {
  const [draft, setDraft] = useState('')
  /**
   * The agent row that was clicked, which is not the same as the agent that
   * will be used — see `chosenAccountProvider`. Held as "what was clicked" so
   * an agent going missing corrects the answer instead of freezing it.
   */
  const [clicked, setClicked] = useState<ProviderId | null>(null)
  const formId = useId()
  const panelRef = useRef<HTMLDivElement>(null)
  const nameRef = useRef<HTMLInputElement>(null)

  // Read through a ref so the key listener is installed once and still calls
  // the current handler; a re-created closure would re-bind on every render.
  const close = useRef(onClose)
  close.current = onClose

  useEffect(() => {
    if (!open) return
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      // Capture phase: this is what keeps the settings sheet open behind it.
      event.stopPropagation()
      close.current()
    }
    document.addEventListener('keydown', onKeyDown, true)
    return () => document.removeEventListener('keydown', onKeyDown, true)
  }, [open])

  /*
   * A fresh dialog every time, and focus in the name field.
   *
   * Not the panel: this one is short enough that its heading is read from the
   * title anyway, and the field is the only thing anybody has to type. Clearing
   * the draft matters more than it looks — a name left over from an attempt
   * that failed would be re-submitted by somebody who opened the dialog to try
   * a different agent.
   */
  useEffect(() => {
    if (!open) return
    setDraft('')
    setClicked(null)
    nameRef.current?.focus()
  }, [open])

  const chosen = chosenAccountProvider(providerRows, clicked)
  const problem = agentProblem(providerRows, chosen?.id ?? null)

  const submit = useCallback(
    (event: FormEvent) => {
      event.preventDefault()
      const name = draft.trim()
      // No agent means no account: a login has to be a login *of* something, and
      // `createProfile` in the main process refuses a provider it cannot isolate
      // rather than quietly making one for the default agent.
      if (name === '' || !chosen || !onSignIn) return
      // And no account at all for an agent that cannot start. Creating one here
      // and letting the session die is how the 2026-08-16 recording ended with
      // five orphan rows in the sidebar and nothing cleaned up.
      if (problem) return
      onSignIn(name, chosen.id)
    },
    [chosen, draft, onSignIn, problem],
  )

  if (!open) return null

  return (
    <div
      ref={panelRef}
      className="add-account"
      role="dialog"
      aria-modal="true"
      aria-label="Add account"
    >
      <header className="add-account-head">
        <h3 className="add-account-title">Add account</h3>
        <button
          type="button"
          className="add-account-close"
          aria-label="Close"
          onClick={() => close.current()}
        >
          <span aria-hidden="true">✕</span>
        </button>
      </header>

      <form className="add-account-body" onSubmit={submit}>
        <ol className="add-account-steps">
          <li className="add-account-step">
            <p className="add-account-ask">Which agent is this a login for?</p>
            <AccountProviderList
              group={`${formId}-agent`}
              rows={providerRows}
              selected={chosen?.id ?? null}
              onSelect={setClicked}
            />
          </li>

          <li className="add-account-step">
            <p className="add-account-ask">Give it a name.</p>
            <input
              ref={nameRef}
              className="settings-input wide"
              value={draft}
              /* Not a plausible word like "Work": a single word sitting in an
                 empty field reads as a value somebody already typed, and a
                 person who leaves it alone expecting an account called Work
                 gets nothing. It does name the chosen agent, which is the
                 cheapest possible confirmation that the row above was taken. */
              placeholder={chosen ? `Name this ${chosen.label} account` : 'Name this account'}
              maxLength={MAX_ACCOUNT_NAME_LENGTH}
              aria-label="Name for the new account"
              onChange={(event) => setDraft(event.target.value)}
            />
          </li>

          <li className="add-account-step">
            <p className="add-account-ask">Sign in, in the terminal that opens.</p>
            <p className="add-account-note">
              A session starts on that agent and it asks you to log in, exactly as it would in your
              own terminal. This app never sees your password or your token.
            </p>
          </li>
        </ol>

        {/*
          The stale-CLI warning is deliberately *not* repeated here.

          It was, for one build, and looking at it settled the question: the
          popup is 440px wide and the scrim over the pane is barely a tint, so
          the same amber block appeared twice in one frame — once squeezed into
          three-word lines inside the dialog and once at full width behind it.
          `AccountsSection` carries it, directly above the account list and the
          button that opens this popup, which is both where somebody is standing
          when a sign-in fails and the last thing they read before pressing Sign
          in here.
        */}

        {/* The agent is installed nowhere this app can start it. Said here,
            before the button is pressed, rather than in a terminal
            afterwards. */}
        {problem && (
          <p className="add-account-warn" role="status">
            {problem.text}
            {problem.install && (
              <>
                {' '}
                Install it with <code>{problem.install}</code>.
              </>
            )}
          </p>
        )}

        {/* Every agent listed, none of them able to take one — which on this
            machine means none is installed. Said once, here, rather than left
            for somebody to infer from a button that never lights. */}
        {providerRows.length > 0 && !chosen && (
          <p className="add-account-warn" role="status">
            No agent on this machine can hold a second login. Install one from the list above and it
            will offer it here.
          </p>
        )}

        {/* A window with no way to open a session cannot sign anything in, and
            making the account anyway would leave exactly the orphan this
            screen exists to stop. */}
        {chosen && !onSignIn && (
          <p className="add-account-warn" role="status">
            This window cannot open a session, so there is nothing here to sign in with.
          </p>
        )}

        <footer className="add-account-foot">
          <button type="button" className="add-account-cancel" onClick={() => close.current()}>
            Cancel
          </button>
          <button
            type="submit"
            className="add-account-go"
            disabled={busy || draft.trim() === '' || !chosen || !onSignIn || problem !== null}
          >
            {busy ? 'Opening…' : 'Sign in'}
          </button>
        </footer>
      </form>
    </div>
  )
}
