import { useCallback, useState } from 'react'
import type { ProviderId } from '@shared/types'
import { Button, Explain, Group, Notice, SectionHead } from '../controls'
import type { SectionProps } from '../settings-bridge'
import { AgentCliUpdate } from '../../components/AgentCliUpdate'
import { ProviderBadge } from '../../components/ProviderBadge'
import { providerOption, useAccountProviderRows, type AccountProviderRow } from '../../components/ProviderPicker'
import { AddAccountDialog } from './AddAccountDialog'
import { agentCanStart, agentProblem, canHaveMore } from './account-agent'
import {
  accountLabel,
  accountsBridge,
  normalizeAccountName,
  profileLoginLabel,
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
 * The id of the account every unset default falls back to.
 *
 * `SYSTEM_PROFILE_ID` in `main/profiles.ts`, spelled here because the renderer
 * does not import the main process. It is a string already written into
 * `profiles.json` on every machine this app has ever run on, so it cannot change
 * without resetting everybody's default — which is why it is safe to name.
 */
const SYSTEM_ACCOUNT_ID = 'system'

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

/**
 * The three per-agent readings this screen makes live in `account-agent.ts`.
 *
 * They moved there when the Add-account dialog became a file of its own, which
 * needs all three: a dialog importing from this pane while this pane imports
 * the dialog is a cycle. They are re-exported here because they were tested
 * through this module before the move and the tests are about the behaviour,
 * not about which file it is typed in.
 */
export { agentCanStart, agentProblem, canHaveMore }

/* ----------------------------------------------------------------- view -- */

export interface AccountsViewProps {
  /**
   * Draw the pane's own heading.
   *
   * False when this is a group inside Agents, which is now the only place it
   * appears — Accounts stopped being a rail entry when the three agent sections
   * were merged. Kept as a flag rather than hard-coded off so the view can
   * still be rendered on its own in a test, which is where the interesting
   * states are exercised.
   */
  head?: boolean
  /**
   * Open the Add-account popup on the first render.
   *
   * For tests only, and it is a prop rather than a hook because there is no DOM
   * in this project to press the button with — the popup's contents are the
   * whole of what this change is about, so they have to be renderable.
   */
  addingInitially?: boolean
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
  /**
   * Add the account **and** start its sign-in, as one action.
   *
   * Two steps before this: press Add, watch a row appear, find the Sign in
   * button on it, press that. His words: *"right away it should actually take me
   * to sign in rather than add button. There should not be any add button. It
   * should be just sign in button and should take me to the flow of sign in
   * rather than we bring sign in button here separately. It is two steps
   * separately."*
   *
   * Null when this window cannot start a session, in which case the form says so
   * rather than creating an account that has no way to be signed in.
   */
  onSignInNew: ((name: string, provider: ProviderId) => void) | null
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
  head = true,
  addingInitially = false,
  snapshot,
  signIn,
  loading,
  error,
  available,
  busy,
  providerRows,
  onSignIn,
  onCheck,
  onSignInNew,
  onRename,
  onRemove,
  onMakeDefault,
}: AccountsViewProps) {
  /*
   * `sectionMeta('profiles')` answers with Agents now — the merge table routes
   * every old section id at the pane that absorbed it. The heading below is
   * therefore written here rather than read from the meta: when this view is
   * rendered standalone it is still *Accounts* that is on screen, whatever the
   * rail happens to call the pane it lives in.
   */
  const title = 'Accounts'
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null)
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null)
  /**
   * Whether the Add-account popup is up.
   *
   * Held here rather than in the section so that the popup and the list it adds
   * to close together, and so a render test can open it by passing `adding`.
   */
  const [adding, setAdding] = useState(addingInitially)

  if (!available) {
    return (
      <Group title={title}>
        <Notice tone="warn">
          Accounts are not wired into this window, so nothing here can be read or changed.
        </Notice>
      </Group>
    )
  }

  const accounts = snapshot.accounts

  return (
    <Group title={head ? undefined : title}>
      {head && <SectionHead title={title} blurb="One app, several agent logins." />}

      {/*
        Three sentences became one.

        This block replaced a headed paragraph called "Claude only, and why",
        which was written when Claude was the only agent that could hold a
        second login and had become wrong about Codex. Then it grew to three
        sentences of its own — what an account is, which agents can hold
        several, and where to switch between them — which is how a pane becomes
        a document one true clause at a time. What is left on screen is the
        clause somebody actually needs before they press Add; the rest is behind
        the ⓘ, where it can be read by anyone who wants it and skipped by
        everyone who does not.
      */}
      <Explain
        title="One app, several logins"
        more="An account is a separate login for one agent, with its own history and its own transcripts, and two can run side by side. Pick which one a session uses from the account button beside the folder."
      >
        Claude and Codex can hold several; Gemini keeps one per machine.
      </Explain>

      {error && <Notice tone="error">{error}</Notice>}

      {/*
        The measured reason a sign-in is about to fail, on the screen somebody
        is standing on when it does. It draws nothing when every agent CLI on
        this machine is current — see `AgentCliUpdate` for the loop it closes.
      */}
      <AgentCliUpdate />

      <ul className="settings-profiles">
        {accounts.map((account) => {
          const state = signIn[account.id]
          /*
           * One default, not one per agent.
           *
           * This was `account.system && defaultId === null`, which was right
           * while Claude's install was the only system row. There are three now
           * — Claude's, Codex's and Gemini's — so on a fresh machine all three
           * wore a "Default" badge, next to three rows already named "Default
           * (…)", which is the "printed the word twice" problem this badge has
           * had before, tripled.
           *
           * `SYSTEM_PROFILE_ID` is the id `resolveProfileId` terminates on when
           * nothing else resolves, so it is the one row for which "default with
           * nothing set" is literally true.
           */
          const isDefault =
            account.id === snapshot.defaultId ||
            (snapshot.defaultId === null && account.id === SYSTEM_ACCOUNT_ID)
          // Held as the value rather than a boolean so the form below narrows
          // without an assertion.
          const editing = renaming?.id === account.id ? renaming : null
          const rowProblem = agentProblem(providerRows, account.provider)

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
                      /* The row's own label, so what a screen reader hears is
                         what the list shows — the field holds the stored name
                         because that is the string being edited, but "New name
                         for Default" over a row headed with an address is the
                         slug leaking through the accessibility tree. */
                      aria-label={`New name for ${profileLoginLabel(account, state)}`}
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
                      {/* The login, not the key. These rows read `Default`,
                          `Default (Codex CLI)`, `Default (Gemini CLI)` — three
                          generated keys sitting one above the other, which is
                          also the shape of his complaint that the list gives no
                          way to tell which login is which. This pane probes on
                          open, so the address is usually already in hand;
                          `profileLoginLabel` prints it, and says which install
                          a row is when the agent named nobody. */}
                      {profileLoginLabel(account, state)}
                      {/* A badge is a comparison, so it needs something to
                          compare with: on a fresh install there is one account
                          and it is *called* Default, and the badge printed the
                          word twice, eight pixels apart. */}
                      {isDefault && accounts.length > 1 && (
                        <span className="settings-badge">Default</span>
                      )}
                      {/* Only when the label has not already said it. With no
                          address to show, the label *is* "Your own Claude Code
                          install", and the badge beside it would be the same
                          sentence twice on one line. */}
                      {account.system && accountLabel(state) !== null && (
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

                    {/* Why Sign in is not there. One sentence and a command —
                        never the launcher's own `Error: spawn … ENOENT`, which
                        is what this row used to print verbatim. */}
                    {rowProblem && (
                      <span className="settings-account-blocked">
                        {rowProblem.text}
                        {rowProblem.install && <code>{rowProblem.install}</code>}
                      </span>
                    )}

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
                      where it would only start a session nobody asked for.

                      And never offered when the agent will not start. That is
                      the button that opened a blank terminal and printed a Node
                      stack trace into it, five times in one recording; the row
                      below says what is wrong and what to type instead. */}
                  {onSignIn &&
                    state &&
                    state.state !== 'signed-in' &&
                    state.state !== 'unsupported' &&
                    agentCanStart(providerRows, account.provider) && (
                      <Button tone="primary" disabled={busy} onClick={() => onSignIn(account)}>
                        Sign in
                      </Button>
                    )}
                  {/* Meaningless where there is only ever one. Gemini keeps a
                      single login per machine, so "use this one by default"
                      offers a choice between it and itself. */}
                  {!isDefault && canHaveMore(providerRows, account.provider) && (
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

      {/*
        Two buttons, and the second one is the whole of this change.

        Everything that used to sit under this line — a heading, the agent
        question, the list, a name field, its own Sign in button, three notices
        and an ⓘ — is now behind **Add account**, in a popup that carries the
        sign-in steps and nothing else. His words: *"'Add' and 'Sign in' should
        be one thing, called Add account. It must open a small popup with only
        the sign-in steps — not the whole Agents page. It is confusing. Just
        give me the login, sign-in steps."*

        It is one button rather than two because it is one act. Adding an
        account without signing it in leaves a directory that no agent has ever
        written to, which is not an account in any sense a person cares about —
        `signInToNewAccount` makes both happen on one press and unmakes the
        first if the second fails.
      */}
      <div className="settings-account-foot">
        <Button tone="primary" disabled={busy} onClick={() => setAdding(true)}>
          Add account
        </Button>
        <Button disabled={busy || accounts.length === 0} onClick={onCheck}>
          Check again
        </Button>
        <span className="settings-help">
          Asks the agent, once per account, which of them are signed in.
        </span>
      </div>

      <AddAccountDialog
        open={adding}
        providerRows={providerRows}
        busy={busy}
        onSignIn={
          onSignInNew
            ? (name, provider) => {
                // Closed on the way, not after: signing in opens a terminal
                // session, and the settings window closes with it, so a popup
                // left up would be the last thing on screen before the whole
                // sheet went.
                setAdding(false)
                onSignInNew(name, provider)
              }
            : null
        }
        onClose={() => setAdding(false)}
      />
    </Group>
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

/** The id `profiles:create` answered with, or null for anything unreadable. */
export function createdAccountId(answer: unknown): string | null {
  if (typeof answer !== 'object' || answer === null) return null
  const id = (answer as { id?: unknown }).id
  return typeof id === 'string' && id !== '' ? id : null
}

/**
 * Make the account and sign it in, as one action, and leave nothing behind if it
 * fails.
 *
 * Three properties, and each one is a defect from the recording:
 *
 *  1. **One press.** Add then Sign in was two, and the state in between — an
 *     account that exists and has never been signed into — was a row a person
 *     could walk away from without noticing.
 *  2. **Nothing is created for an agent that cannot start.** The caller checks
 *     that before calling; this checks that a session could be started at all,
 *     because a window with no `start` has no business making an account.
 *  3. **A failed start takes the account with it.** If `profiles:create`
 *     succeeds and the session does not, the directory that was just made is
 *     removed again — otherwise the failed attempt leaves a row, and five failed
 *     attempts leave five, which is what the sidebar looked like by the end of
 *     the recording.
 *
 * Written as a plain function taking its bridge so a test can hand it spies and
 * assert the cleanup, which is the branch no machine reproduces on demand.
 */
export async function signInToNewAccount(
  bridge: Partial<AccountsBridge> | null,
  start: ((request: { profileId: string; provider?: ProviderId }) => unknown) | null,
  name: string,
  provider: ProviderId,
): Promise<{ ok: boolean; error: string | null }> {
  if (!start) {
    return { ok: false, error: 'This window cannot open a session, so there is nothing to sign in with.' }
  }

  let created: unknown
  try {
    created = await createAccount(bridge, name, provider)
  } catch (cause) {
    return {
      ok: false,
      error: cause instanceof Error && cause.message ? cause.message : 'Could not add that account.',
    }
  }

  const id = createdAccountId(created)
  if (id === null) return { ok: false, error: 'Could not add that account.' }

  try {
    await start({ profileId: id, provider })
    return { ok: true, error: null }
  } catch (cause) {
    // The account was made a moment ago and has never been used, so removing it
    // cannot take anything away from anybody. `deleteFiles` is deliberately not
    // passed: `deleteProfile` keeps the directory unless asked, and an empty
    // directory is cheaper to leave than a wrong delete is to undo.
    await bridge?.deleteProfile?.(id).catch(() => undefined)
    return {
      ok: false,
      error:
        cause instanceof Error && cause.message
          ? `Could not open a session to sign in: ${cause.message}`
          : 'Could not open a session to sign in, so the account was not kept.',
    }
  }
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

export function AccountsSection({ startSession, head }: SectionProps & { head?: boolean }) {
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
      head={head}
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
      /* One press: make the account, open its sign-in, and unmake it if the
         session cannot start. `signInToNewAccount` holds all three so the
         cleanup branch can be asserted without a DOM. */
      onSignInNew={
        startSession
          ? (name, provider) => {
              setBusy(true)
              setFailure(null)
              void signInToNewAccount(bridge, startSession, name, provider).then((result) => {
                setBusy(false)
                if (result.error) setFailure(result.error)
                accounts.reload()
              })
            }
          : null
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
