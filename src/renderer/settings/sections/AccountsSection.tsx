import { useCallback, useState, type FormEvent } from 'react'
import { Button, Explain, Group, Notice, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'
import {
  accountsBridge,
  useAccounts,
  type AccountView,
  type AccountsSnapshot,
  type AccountsBridge,
  type SignInView,
} from '../../accounts'

/**
 * Accounts — more than one agent login in one app.
 *
 * This screen exists because the engine behind it did not: `src/main/profiles.ts`
 * has been giving each account its own config directory for a while, and the
 * only ways to reach it were a settings pane called "Profiles" and a command in
 * the palette. Asad's words, which is the whole brief:
 *
 *   > "I don't see any kind of feature that I can use to have multiple accounts
 *   > in one application so I can actually set up multiple accounts and I can
 *   > choose the session and account when I start a new session."
 *
 * Three rules shape what is on screen.
 *
 * **Signed in is read, never assumed.** The line under each name comes from
 * running the agent's own `auth status` under that account's config directory —
 * see `profiles-signin.ts`, which also records the exact commands and their
 * output on the machine this was written on. An account whose state could not
 * be read says so; it does not get a tick and it does not get a cross.
 *
 * **Signing in happens in the terminal, and the screen says so.** This app never
 * touches a credential. The Sign in button opens a session under that account
 * and the agent's own login flow takes over inside it.
 *
 * **Only Claude.** `CLAUDE_CONFIG_DIR` is the one variable verified to move a
 * login. Naming a wrong one for another agent would not fail loudly — it would
 * silently *share* one login between two accounts, which is the exact failure
 * this feature exists to prevent. The note at the foot says that plainly rather
 * than leaving a person to discover it.
 */

const MAX_NAME_LENGTH = 60

/* ----------------------------------------------------------------- view -- */

export interface AccountsViewProps {
  snapshot: AccountsSnapshot
  signIn: Readonly<Record<string, SignInView>>
  loading: boolean
  error: string | null
  /** False when this window has no accounts bridge at all. */
  available: boolean
  busy: boolean
  /** Null when nothing in this window can start a session — no Sign in button. */
  onSignIn: ((account: AccountView) => void) | null
  onCheck(): void
  onCreate(name: string): void
  onRename(account: AccountView, name: string): void
  onRemove(account: AccountView): void
  onMakeDefault(account: AccountView): void
}

/**
 * Everything this screen draws, with nothing to fetch.
 *
 * Split from the section for the same reason `PowerSection` splits its view:
 * the interesting cases here are a failed sign-in read and an account that has
 * never been used, and both are states rather than interactions. A view that
 * takes them as props can be rendered in a test without a bridge, a DOM or a
 * spawned process.
 */
export function AccountsView({
  snapshot,
  signIn,
  loading,
  error,
  available,
  busy,
  onSignIn,
  onCheck,
  onCreate,
  onRename,
  onRemove,
  onMakeDefault,
}: AccountsViewProps) {
  const meta = sectionMeta('profiles')
  const [draft, setDraft] = useState('')
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null)
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null)

  const create = (event: FormEvent) => {
    event.preventDefault()
    const name = draft.trim()
    if (name === '') return
    setDraft('')
    onCreate(name)
  }

  if (!available) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <Notice tone="warn">
          Accounts are not wired into this window, so nothing here can be read or changed.
        </Notice>
      </>
    )
  }

  const accounts = snapshot.accounts

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <Explain title="One app, several logins">
        An account is a separate login for the agent. Claude Code keeps everything about who you
        are in one config directory, and each account here points it at a different one — so two
        accounts are two logins, with their own history and their own transcripts, and they can be
        running side by side in two tabs. Pick which one a session uses from the account button
        beside the folder, before you type anything.
      </Explain>

      {error && <Notice tone="error">{error}</Notice>}

      <ul className="settings-profiles">
        {accounts.map((account) => {
          const state = signIn[account.id]
          const isDefault =
            account.id === snapshot.defaultId || (account.system && snapshot.defaultId === null)
          // Held as the value rather than a boolean so the form below narrows
          // without an assertion.
          const editing = renaming?.id === account.id ? renaming : null

          return (
            <li key={account.id} className="settings-profile">
              <span
                className="settings-profile-dot"
                style={{ background: `var(${account.color})` }}
                aria-hidden="true"
              />

              <span className="settings-profile-main">
                {editing ? (
                  <form
                    className="settings-inline-form"
                    onSubmit={(event) => {
                      event.preventDefault()
                      const name = editing.name.trim()
                      setRenaming(null)
                      if (name && name !== account.name) onRename(account, name)
                    }}
                  >
                    <input
                      className="settings-input"
                      value={editing.name}
                      maxLength={MAX_NAME_LENGTH}
                      autoFocus
                      aria-label={`New name for ${account.name}`}
                      onChange={(event) => setRenaming({ id: account.id, name: event.target.value })}
                    />
                    <Button type="submit" tone="primary">
                      Save
                    </Button>
                    <Button onClick={() => setRenaming(null)}>Cancel</Button>
                  </form>
                ) : (
                  <>
                    <span className="settings-profile-name">
                      {account.name}
                      {/* A badge is a comparison, so it needs something to
                          compare with: on a fresh install there is one account
                          and it is *called* Default, and the badge printed the
                          word twice, eight pixels apart. */}
                      {isDefault && accounts.length > 1 && (
                        <span className="settings-badge">Default</span>
                      )}
                      {account.system && (
                        <span className="settings-badge quiet">Your own install</span>
                      )}
                    </span>

                    {/* The one line that answers "can this account start a
                        session right now". Read from the agent, never inferred
                        from the presence of a directory. */}
                    <span className="settings-account-state" data-state={state?.state ?? 'unknown'}>
                      <span className="settings-account-mark" aria-hidden="true" />
                      <span>{state ? state.detail : 'Checking with the agent…'}</span>
                    </span>

                    <span className="settings-profile-path" title={account.configDir}>
                      {account.configDir}
                    </span>
                  </>
                )}
              </span>

              {!editing && (
                <span className="settings-profile-actions">
                  {/* Offered when the agent said no, and when it could not be
                      asked — both are cases where signing in is the next thing
                      to try. Never offered against a verified "signed in",
                      where it would only start a session nobody asked for. */}
                  {onSignIn && state && state.state !== 'signed-in' && state.state !== 'unsupported' && (
                    <Button tone="primary" disabled={busy} onClick={() => onSignIn(account)}>
                      Sign in
                    </Button>
                  )}
                  {!isDefault && (
                    <Button disabled={busy} onClick={() => onMakeDefault(account)}>
                      Use by default
                    </Button>
                  )}
                  {!account.system && (
                    <>
                      <Button
                        disabled={busy}
                        onClick={() => setRenaming({ id: account.id, name: account.name })}
                      >
                        Rename
                      </Button>
                      <Button tone="danger" disabled={busy} onClick={() => setConfirmRemove(account.id)}>
                        Remove
                      </Button>
                    </>
                  )}
                </span>
              )}

              {confirmRemove === account.id && (
                <div className="settings-confirm">
                  <span>
                    Remove “{account.name}” from the list? Its folder stays on disk and its login
                    stays in your keychain — adding it again at the same place signs straight back
                    in.
                  </span>
                  <Button
                    tone="danger"
                    disabled={busy}
                    onClick={() => {
                      setConfirmRemove(null)
                      onRemove(account)
                    }}
                  >
                    Remove
                  </Button>
                  <Button onClick={() => setConfirmRemove(null)}>Keep it</Button>
                </div>
              )}
            </li>
          )
        })}
      </ul>

      {accounts.length === 0 && !loading && (
        <p className="settings-prose">No accounts yet.</p>
      )}

      <div className="settings-account-foot">
        <Button disabled={busy || accounts.length === 0} onClick={onCheck}>
          Check again
        </Button>
        <span className="settings-help">
          Asks the agent, once per account, which of them are signed in.
        </span>
      </div>

      <Group title="Add an account">
        <form className="settings-inline-form" onSubmit={create}>
          <input
            className="settings-input wide"
            value={draft}
            // Not a plausible word like "Work": a single word sitting in an
            // empty field reads as a value somebody already typed, and a person
            // who leaves it alone expecting an account called Work gets nothing.
            placeholder="Name this account"
            maxLength={MAX_NAME_LENGTH}
            aria-label="Name for the new account"
            onChange={(event) => setDraft(event.target.value)}
          />
          <Button type="submit" tone="primary" disabled={busy || draft.trim() === ''}>
            Add
          </Button>
        </form>
        <Explain title="Signing in happens in the terminal">
          A new account starts signed out. Press Sign in and a session opens under it, where the
          agent asks you to log in exactly as it would in your own terminal — this app never sees
          or stores a password or a token. Come back here afterwards and the line under the name
          will name the account you signed in as.
        </Explain>
        <Explain title="Claude only, and why">
          Separate accounts work by pointing the agent at a different config directory, and
          Claude’s is the only one that has been verified to do that here. Codex and Gemini sign in
          their own way; a session on either of them uses whichever login this machine already has,
          and nothing on this screen changes that. Naming the wrong variable for an agent would not
          fail loudly — it would quietly share one login between two accounts, which is the mistake
          this feature exists to prevent.
        </Explain>
      </Group>
    </>
  )
}

/* -------------------------------------------------------------- section -- */

export function AccountsSection({ startSession }: SectionProps) {
  const accounts = useAccounts()
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)

  /**
   * Every change goes back to the main process and the list is read again.
   *
   * Ids, colours and config directories are assigned there, and inventing any
   * of them here would put an account on screen that does not match the one on
   * disk.
   */
  const run = useCallback(
    (work: Promise<unknown> | undefined, failed: string) => {
      if (!work) return
      setBusy(true)
      setFailure(null)
      void work.then(
        () => {
          setBusy(false)
          accounts.reload()
        },
        (cause: unknown) => {
          setBusy(false)
          setFailure(cause instanceof Error && cause.message ? cause.message : failed)
        },
      )
    },
    [accounts],
  )

  const bridge = accountsBridge() as Partial<AccountsBridge> | null

  return (
    <AccountsView
      snapshot={accounts.snapshot}
      signIn={accounts.signIn}
      loading={accounts.loading}
      error={failure ?? accounts.error}
      available={accounts.available}
      busy={busy}
      /* No callback, no button: this window cannot start a session from a
         settings pane rendered on its own, and a Sign in button that did
         nothing would be worse than not offering one. */
      onSignIn={startSession ? (account) => startSession({ profileId: account.id }) : null}
      onCheck={() => accounts.check(true)}
      onCreate={(name) => run(bridge?.createProfile?.(name), 'Could not add that account.')}
      onRename={(account, name) =>
        run(bridge?.renameProfile?.(account.id, name), 'Could not rename that account.')
      }
      onRemove={(account) =>
        run(bridge?.deleteProfile?.(account.id), 'Could not remove that account.')
      }
      onMakeDefault={(account) =>
        run(bridge?.setDefaultProfile?.(account.id), 'Could not change the default account.')
      }
    />
  )
}
