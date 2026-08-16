import { useCallback, useId, useState, type FormEvent } from 'react'
import type { ProviderId } from '@shared/types'
import { Button, Explain, Group, Notice, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'
import { ProviderBadge } from '../../components/ProviderBadge'
import {
  AccountProviderList,
  chosenAccountProvider,
  providerOption,
  useAccountProviderRows,
  type AccountProviderRow,
} from '../../components/ProviderPicker'
import {
  accountsBridge,
  normalizeAccountName,
  renameAccount,
  useAccounts,
  MAX_ACCOUNT_NAME_LENGTH,
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
 * touches a credential. The Sign in button opens a session *on that account's
 * own agent* and the agent's own login flow takes over inside it. That session
 * used to be started on whatever the default coding tool was, which meant a
 * Codex account was signed in by a Claude session — Claude's login screen, for
 * an account Claude has no business writing to. It is the whole of the report
 * this pass came from:
 *
 *   > "If I add any new account it just redirects me to claude only, not to the
 *   > other ones I want to connect."
 *
 * **The agent is chosen before the name.** An account is a login of one specific
 * CLI, so "add an account" has no meaning until it is known which one. The list
 * above the name field is the question, and it lists every agent — including the
 * one that is refused, with the reason on the row, because a missing row is
 * indistinguishable from an oversight. Which agents can hold a second login, and
 * how each answer was measured, is in `main/provider-accounts.ts`; nothing on
 * this screen decides it.
 */

/**
 * The cap, and the trim-and-compare behind a rename, both live in `accounts.ts`
 * now. The account chip inside a session renames too (NEXT-UPDATE item 2), and
 * a rename that behaves differently depending on which of the two you reached
 * for is worse than one of them not existing.
 */
const MAX_NAME_LENGTH = MAX_ACCOUNT_NAME_LENGTH

/**
 * The agent's name for a screen reader, or undefined when there is no mark to
 * announce.
 *
 * `undefined` is what puts `ProviderBadge` into its decorative mode, and that
 * is the right mode for an account whose agent the main process did not name:
 * the badge draws nothing, so announcing something would describe a shape that
 * is not on screen.
 */
function agentName(provider: ProviderId | null): string | undefined {
  return provider === null ? undefined : providerOption(provider)?.label
}

/* ----------------------------------------------------------------- view -- */

export interface AccountsViewProps {
  snapshot: AccountsSnapshot
  signIn: Readonly<Record<string, SignInView>>
  loading: boolean
  error: string | null
  /** False when this window has no accounts bridge at all. */
  available: boolean
  busy: boolean
  /**
   * The agents an account can be added for, refused ones included.
   *
   * Passed in rather than fetched here for the same reason everything else on
   * this view is: the interesting states — every agent uninstalled, the refused
   * row, an answer that never arrived — are states, and a view that takes them
   * can be rendered in a test with no bridge and no DOM.
   */
  providerRows: readonly AccountProviderRow[]
  /** Null when nothing in this window can start a session — no Sign in button. */
  onSignIn: ((account: AccountView) => void) | null
  onCheck(): void
  onCreate(name: string, provider: ProviderId): void
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
  providerRows,
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
  /**
   * The agent row that was clicked, which is not the same as the agent that
   * will be used — see `chosenAccountProvider`. Held as "what was clicked" so
   * an agent going missing corrects the answer instead of freezing it.
   */
  const [clicked, setClicked] = useState<ProviderId | null>(null)
  const formId = useId()

  const chosen = chosenAccountProvider(providerRows, clicked)

  const create = (event: FormEvent) => {
    event.preventDefault()
    const name = draft.trim()
    // No agent means no account: a login has to be a login *of* something, and
    // `createProfile` in the main process refuses a provider it cannot isolate
    // with its own sentence rather than quietly making a Claude account.
    if (name === '' || !chosen) return
    setDraft('')
    onCreate(name, chosen.id)
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

      {/*
        The scope sentence in the middle is what replaced a headed block called
        "Claude only, and why" at the foot of this pane. That block was written
        when Claude was the only agent that could hold a second login; it is now
        wrong about Codex, and it was never the right place for the Gemini
        answer — which belongs on the Gemini row, next to the control it
        explains, and is there. One line, not a paragraph, and it says what you
        get rather than how it works: nobody needs to know what a config
        directory is to decide which account to sign in as.
      */}
      <Explain title="One app, several logins">
        An account is a separate login for one agent — its own history, its own transcripts, and
        two can run side by side. Claude and Codex can hold several; Gemini keeps one per machine.
        Pick which one a session uses from the account button beside the folder.
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
                      const name = normalizeAccountName(editing.name, account.name)
                      setRenaming(null)
                      if (name !== null) onRename(account, name)
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
                      {/* Which agent this is a login of, in the one list that
                          now holds accounts of more than one. The name cannot
                          answer it — "Work" is a word somebody typed, and the
                          same word is a legal name on every agent here. Labelled
                          rather than `aria-hidden`, unlike the copy of this mark
                          in the Add list: there the agent's name is the next
                          thing on the row, and here nothing else on the row says
                          it. */}
                      <ProviderBadge provider={account.provider} label={agentName(account.provider)} />
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
        {/* The question the app never asked. Before this list, every account
            made here was a Claude account whatever the person adding it had in
            mind — see the module note. */}
        <p className="settings-prose">Which agent is this a login for?</p>
        <AccountProviderList
          group={`${formId}-agent`}
          rows={providerRows}
          selected={chosen?.id ?? null}
          onSelect={setClicked}
        />

        <form className="settings-inline-form settings-add-account" onSubmit={create}>
          <input
            className="settings-input wide"
            value={draft}
            // Not a plausible word like "Work": a single word sitting in an
            // empty field reads as a value somebody already typed, and a person
            // who leaves it alone expecting an account called Work gets nothing.
            // It does name the chosen agent, which is the cheapest possible
            // confirmation that the row above was actually taken.
            placeholder={chosen ? `Name this ${chosen.label} account` : 'Name this account'}
            maxLength={MAX_NAME_LENGTH}
            aria-label="Name for the new account"
            onChange={(event) => setDraft(event.target.value)}
          />
          <Button type="submit" tone="primary" disabled={busy || draft.trim() === '' || !chosen}>
            Add
          </Button>
        </form>

        {/* Every agent listed, none of them able to take one — which on this
            machine means none of them is installed. Said once, here, rather
            than left for somebody to infer from an Add button that never
            enables. */}
        {providerRows.length > 0 && !chosen && (
          <Notice tone="warn">
            No agent on this machine can hold a second login. Install Claude Code or the Codex CLI
            and this list will offer them.
          </Notice>
        )}

        <Explain title="Signing in happens in the terminal">
          A new account starts signed out. Press Sign in and a session opens on that agent, where
          it asks you to log in as it would in your own terminal — this app never sees a password
          or a token.
        </Explain>
      </Group>
    </>
  )
}

/* ------------------------------------------------------------ requests -- */

/**
 * Add an account of a named agent.
 *
 * A function rather than a closure inside the section for one reason: it is the
 * line the whole report turns on, and there is no DOM in this project to press
 * the button with. Written here it can be handed a spy and asked what it sent —
 * and it fails loudly if the options object is ever dropped again, which is
 * precisely the shape of the original defect. `preload/index.ts` had exactly
 * this signature with the second argument missing, so `profiles:create` fell
 * back to Claude for every account ever made through this screen.
 *
 * Returns undefined when the window has no create method, which the caller
 * treats as "nothing happened" — the same way every other action here does.
 */
export function createAccount(
  bridge: Partial<AccountsBridge> | null,
  name: string,
  provider: ProviderId,
): Promise<unknown> | undefined {
  return bridge?.createProfile?.(name, { provider })
}

/**
 * What Sign in asks the window to start.
 *
 * The agent goes with the account because an account is a login of one specific
 * CLI. Without it the session opened on whatever the default coding tool was,
 * so signing a Codex account in showed Claude's login screen — and
 * `resolveProfileId`, correctly, declined to run a Codex account under a Claude
 * session, so the account was dropped on the way past as well.
 *
 * The field is omitted rather than set to null for an account whose agent is
 * unknown: absent means "resolve it", which is the only honest request this
 * window can make about an account it cannot name an agent for.
 */
export function signInRequest(account: AccountView): {
  profileId: string
  provider?: ProviderId
} {
  return {
    profileId: account.id,
    ...(account.provider === null ? {} : { provider: account.provider }),
  }
}

/* -------------------------------------------------------------- section -- */

export function AccountsSection({ startSession }: SectionProps) {
  const accounts = useAccounts()
  /*
   * Always on, because this pane is only mounted while it is the one on screen
   * — `SettingsPanel` renders the selected section and nothing else — so
   * "mounted" and "being looked at" are the same thing here. The dialogs that
   * share this hook pass their own `open` instead.
   */
  const providerRows = useAccountProviderRows(true)
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
      providerRows={providerRows}
      /* No callback, no button: this window cannot start a session from a
         settings pane rendered on its own, and a Sign in button that did
         nothing would be worse than not offering one.

         The account's own agent goes with it, and that is the fix rather than
         a refinement: the session used to be started on the default coding
         tool, so pressing Sign in beside a Codex account opened Claude, and
         `resolveProfileId` — correctly — declined to run a Codex account under
         a Claude session and fell back to the machine's own Claude login. The
         login screen that appeared was the wrong agent's, for an account it
         could not have written to anyway. `signInRequest` builds the request,
         so what is sent can be asserted in a test — there is no DOM here to
         press the button in. */
      onSignIn={startSession ? (account) => startSession(signInRequest(account)) : null}
      onCheck={() => accounts.check(true)}
      onCreate={(name, provider) =>
        run(createAccount(bridge, name, provider), 'Could not add that account.')
      }
      /* Through `renameAccount` rather than straight at the bridge, so this
         screen and the account chip inside a session are the same rename. */
      onRename={(account, name) => {
        setBusy(true)
        setFailure(null)
        void renameAccount(bridge, account, name).then((problem) => {
          setBusy(false)
          if (problem) setFailure(problem)
          else accounts.reload()
        })
      }}
      onRemove={(account) =>
        run(bridge?.deleteProfile?.(account.id), 'Could not remove that account.')
      }
      onMakeDefault={(account) =>
        run(bridge?.setDefaultProfile?.(account.id), 'Could not change the default account.')
      }
    />
  )
}
