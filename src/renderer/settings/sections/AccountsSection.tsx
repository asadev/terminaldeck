import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { ProviderId } from '@shared/types'
import { Button, closeMenu, Group, Notice, SectionHead } from '../controls'
import { HoverNote } from '../../components/HoverNote'
import type { SectionProps } from '../settings-bridge'
import { AgentCliUpdate } from '../../components/AgentCliUpdate'
import { ProviderBadge } from '../../components/ProviderBadge'
import {
  PROVIDER_OPTIONS,
  providerOption,
  useAccountProviderRows,
  type AccountProviderRow,
} from '../../components/ProviderPicker'
import { onMenuToggle } from '../menu-room'
import { AddAccountDialog } from './AddAccountDialog'
import { agentCanStart, agentProblem, canHaveMore } from './account-agent'
import {
  accountLabel,
  accountsBridge,
  announceAccountsChanged,
  onAddAccountRequested,
  takeAddAccountRequest,
  normalizeAccountName,
  profileLoginLabel,
  renameAccount,
  useAccountHistory,
  useAccounts,
  MAX_ACCOUNT_NAME_LENGTH,
  type AccountHistoryView,
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
 * **The agent is chosen before the address.** An account is a login of one
 * specific CLI, so "add an account" has no meaning until it is known which one.
 * The list above the field is the question, and it lists every agent — including
 * the one that is refused, with the reason on the row, because a missing row is
 * indistinguishable from an oversight. Which agents can hold a second login, and
 * how each answer was measured, is in `main/provider-accounts.ts`; nothing on
 * this screen decides it.
 *
 * ## What the rows stopped saying, 2026-08-19
 *
 * Each row used to carry four lines under the name: the sign-in sentence, the
 * config directory, where its conversations live, and — after a share — where
 * any folder that could not be merged was left. Every one of them was true and
 * the four together are what he was reading when he said:
 *
 *   > "Remove big descriptions under each account (private, temporary, folder
 *   > link…). Organise properly."
 *
 * and, about the window as a whole:
 *
 *   > "Every single time you bring some card, you put something new… We want
 *   > simplicity. Let the smart people use it."
 *
 * So a row is now a name, a state, and an ⓘ. The folder and the conversation
 * location moved *into* the ⓘ rather than out of the app — see `accountNote` —
 * because they are the two facts that prove the accounts are genuinely separate
 * and nothing else on the screen can say them. The state line went terse in the
 * two cases where the name above it already carried the address, and stayed
 * verbatim in the case that matters: an account whose state could not be read
 * still prints the reason, because "not signed in" would send somebody to redo a
 * login that is perfectly fine.
 *
 * "Stop sharing history" is not on the row any more either. *"This is
 * nonsense"* — as presented, and he is right: a button that relinks a
 * conversation directory, on a row in a settings list, with the consequence a
 * confirmation away. The mechanism is untouched and is still what a new account
 * arrives in; what is gone is the control, and the ⓘ says where the
 * conversations are so the state is never a surprise.
 *
 * ## One list per agent
 *
 * *"Group accounts by provider."* `groupAccountsByProvider` does it in
 * catalogue order — Claude, then Codex, then Gemini — and an agent with no
 * accounts gets no heading, because a heading over nothing is the "control over
 * nothing" fault one step up. The agent mark moved to the heading with them: it
 * was on every row, saying the same word the heading now says once.
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

/*
 * `agentName` was here — the agent's label, handed to `ProviderBadge` so a
 * screen reader could announce the mark on every row. The mark is on the group
 * heading now, and the heading is the agent's name in words, so the badge is
 * decorative: labelling it would announce "Claude Code Claude Code", which is
 * the case `ProviderBadge` documents as worse than announcing it once.
 */

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

/* -------------------------------------------------- one shared history -- */

/**
 * The shape of a shared-history answer, and the narrowing of one, live in
 * `renderer/accounts.ts` — deliberately not here.
 *
 * The same argument the rename makes one file over. This pane is not the only
 * surface onto an account: the chip inside a session is another, and a reply
 * parsed twice is two answers to "what does a reply with no sentence in it
 * mean". `parseAccountHistory` settles it once, and settles it the careful way
 * — an unrecognised link becomes `unmanaged`, never `shared`, because `shared`
 * is a claim that a conversation survives changing account and that deleting
 * this account loses nothing.
 *
 * What belongs here is only what is about this screen: the one line a row
 * shows, and which rows get a button at all.
 */

/**
 * The one line under a row that says where that account's conversations are.
 *
 * Short on purpose: the consequences are long, and they belong in the
 * confirmation a person reads with their finger over the button, not in a list
 * they are scanning. The four cases are four different situations and none of
 * them collapses into another — in particular `elsewhere` is not a broken
 * `shared`. Somebody pointed that folder at a location of their own, on purpose,
 * outside this app; `shareProjects` refuses to replace it and this says so
 * rather than offering a button that would only ever fail.
 */
export function historyLine(history: AccountHistoryView): string {
  switch (history.link) {
    case 'shared':
      return `Conversations are kept in ${history.root}, shared with your own install.`
    case 'elsewhere':
      return `Its conversations folder is a link to ${history.target ?? 'somewhere else'}, which was set up outside this app and is left exactly as it is.`
    case 'separate':
      return history.ownProjects > 0
        ? `Keeps its own conversations — ${history.ownProjects} folder${history.ownProjects === 1 ? '' : 's'} of them, which no other account can read.`
        : 'Keeps its own conversations, which no other account can read.'
    default:
      return 'Keeps its own conversations. Nothing has been written yet.'
  }
}

/**
 * Everything a row used to print under its name, in the one place a reader can
 * ask for it.
 *
 * Two facts and no more: which directory makes this account a separate login,
 * and where its conversations are. Both were lines on the row and both are
 * worth keeping — the directory is the only proof on screen that two accounts
 * of one agent are not one account listed twice, and the conversation location
 * is a real consequence of adding an account that `ACCOUNT-MODEL.md` requires
 * the screen to state rather than let somebody discover.
 *
 * What changed is that they are no longer *standing* text. `HoverNote` keeps
 * the string in the document for a screen reader and costs the pane no height,
 * which is the trade every long half of an explanation in this window makes.
 */
export function accountNote(account: AccountView, history: AccountHistoryView | null): string {
  const where = `Its own folder is ${account.configDir}.`
  return history ? `${where} ${historyLine(history)}` : where
}

/**
 * The one line under a name that says whether this account can start a session.
 *
 * Terse for the two answers the name above has already half-given: a row headed
 * with an address does not need "Signed in as <that same address> · max" under
 * it, and a row with a Sign in button beside it does not need "Open a session
 * with this account to log in".
 *
 * Verbatim for the rest, and that is the load-bearing half. An old CLI, a
 * missing binary or a timeout all produce `unknown`, and the agent's own reason
 * is the only thing on screen that separates "we could not ask" from "you are
 * logged out" — shortening it to a word is exactly how somebody is sent to redo
 * a login that was fine.
 */
export function accountStateLine(state: SignInView | undefined): string {
  if (!state) return 'Checking with the agent…'
  if (state.state === 'signed-in') return 'Signed in'
  if (state.state === 'signed-out') return 'Not signed in'
  return state.detail
}

/** One agent's logins, under that agent's name. */
export interface AccountGroup {
  provider: ProviderId | null
  label: string
  accounts: AccountView[]
}

/**
 * Catalogue order, spelled once.
 *
 * Not alphabetical and not the order the accounts happen to be filed in: the
 * list of agents in the New-session picker, the Add-account popup and the
 * installed list on the pane above are all in this order, and a fourth order
 * here would be the same three agents in a fourth arrangement on one screen.
 */
const PROVIDER_ORDER: readonly string[] = PROVIDER_OPTIONS.map((option) => option.id)

/**
 * The accounts, gathered under the agent each one is a login of.
 *
 * *"Group accounts by provider — all Claude accounts together, then Codex, then
 * Gemini."* The list was flat, which is readable at two accounts and stops
 * being readable at six, because the only thing distinguishing a Claude row
 * from a Codex row was a 14px mark at the far left.
 *
 * A pure function so the ordering can be asserted without a render, and because
 * the interesting cases are the ones a screenshot never shows: an agent this
 * build does not know, and an account whose provider the main process did not
 * name. Neither is dropped — an unknown id keeps its own heading and an unnamed
 * one lands under "Other agents", after everything the catalogue knows about.
 */
export function groupAccountsByProvider(accounts: readonly AccountView[]): AccountGroup[] {
  const groups: AccountGroup[] = []
  for (const account of accounts) {
    let group = groups.find((entry) => entry.provider === account.provider)
    if (!group) {
      group = {
        provider: account.provider,
        label:
          account.provider === null
            ? 'Other agents'
            : (providerOption(account.provider)?.label ?? account.provider),
        accounts: [],
      }
      groups.push(group)
    }
    group.accounts.push(account)
  }
  // Anything the catalogue has never heard of sorts after everything it has,
  // and `sort` is stable, so those keep the order the accounts came in.
  const rank = (group: AccountGroup): number => {
    const at = group.provider === null ? -1 : PROVIDER_ORDER.indexOf(group.provider)
    return at === -1 ? PROVIDER_ORDER.length : at
  }
  return groups.sort((a, b) => rank(a) - rank(b))
}

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
  /**
   * The agent the popup opens on, when something outside this pane named one.
   *
   * The Add-agent menu names one; the session chip and this pane's own button
   * do not. See `askForAddAccount`.
   */
  addingProvider?: ProviderId | null
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
  /**
   * The one control at the foot of the list, handed in from the pane above.
   *
   * It is **Add agent** — a disclosure of every agent, where an installed one
   * opens this pane's own Add-account popup already pointed at it. What it
   * replaces is a primary button called *Add account* that stood here, one row
   * below a button called *Sign in*, which is the pair the recorded review
   * collided with twice: *"why do we have see sign in here separately, add
   * account here separately?"*
   *
   * A node rather than a flag because `AgentsSection` owns the probe the menu is
   * built from, and this file cannot import from it — that module imports this
   * one. Absent draws nothing at all, which is what this view is rendered as on
   * its own in a test.
   */
  addAgent?: ReactNode
  /*
   * `onCheck` was here, behind a "Check again" button in the foot with a line
   * of help under it saying what it asked. The read runs when the pane opens —
   * `useAccounts` probes on mount — so the button re-ran work that had finished
   * a second earlier, and the pane's one primary action was sitting beside it
   * competing for the eye. *"Don't put any single statement in anywhere."* The
   * sentence went with the button; the probe was never the button's.
   */
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
  /**
   * Where each account's conversations live, by account id, as the main process
   * last read it off the disk.
   *
   * A map with a missing entry rather than a per-row loading flag, because an
   * account this window could not ask about and an account whose answer has not
   * arrived yet want the same treatment: draw nothing about its history. The
   * section re-reads the entry after every act, which is what makes "shared" on
   * screen a fact rather than the memory of a button press.
   */
  history?: Readonly<Record<string, AccountHistoryView>>
  /*
   * `moves`, `onShareHistory` and `onUnshareHistory` were here.
   *
   * They drew the Share / Stop sharing button on every row, the confirmation
   * under it, and the amber line recording what a share had left behind. The
   * mechanism is untouched — `shareAccountHistory` is still what every new
   * account is put through in `signInToNewAccount`, and the main process's
   * `shared-projects` module has not moved — but the *control* is off this
   * pane, on his word: *"this is nonsense"*, of a button that relinks a
   * conversation directory from a settings list. Where an account's
   * conversations are is still said, once, behind the row's ⓘ.
   */
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
  addingProvider = null,
  snapshot,
  signIn,
  loading,
  error,
  available,
  busy,
  providerRows,
  onSignIn,
  onSignInNew,
  onRename,
  onRemove,
  onMakeDefault,
  addAgent,
  history = {},
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
  /** Which agent the popup opens on, when the request named one. */
  const [addingFor, setAddingFor] = useState<ProviderId | null>(addingProvider)

  /*
   * The one door, opened from wherever somebody asked for it.
   *
   * Three things used to lead here and only one of them arrived: this pane's
   * **Add account**, a row's **Sign in**, and — from inside a session — an item
   * called *Add or sign in to an account…* which opened this settings pane
   * rather than the popup, dropping somebody in front of the two buttons they
   * had just complained were the same thing. That item is called **Add account**
   * now and it opens this, and so does every installed row of the Add-agent
   * menu, with its own agent already chosen.
   *
   * Both halves are needed and they are not the same half. The listener catches
   * a request made while this pane is already on screen — the Add-agent menu is
   * six inches above this list. The read-on-mount catches the other order: the
   * chip fires the request and *then* opens the settings window, so this
   * component does not exist yet when the event goes past. `takeAddAccountRequest`
   * consumes what it reads, so returning to Settings later does not spring the
   * popup on somebody who came in for something else.
   */
  useEffect(() => {
    const open = (provider: ProviderId | null | undefined): void => {
      if (provider === undefined) return
      setAddingFor(provider)
      setAdding(true)
    }
    open(takeAddAccountRequest())
    return onAddAccountRequested(() => open(takeAddAccountRequest()))
  }, [])

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
  const groups = groupAccountsByProvider(accounts)

  /**
   * One account, as a row.
   *
   * A named function rather than an inline map body, because the list is drawn
   * once per agent now: writing it in the loop would put a hundred lines of row
   * inside two nested maps, and the grouping is the outer one.
   */
  function accountRow(account: AccountView) {
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
    /*
     * Undefined until the state channel has answered for this row — and
     * for an `unmanaged` account it answers `unmanaged` forever, because
     * an account pointed at a directory somebody already had is not one
     * this app may relink. Both draw nothing.
     */
    const known = history[account.id]
    const rowHistory = known && known.link !== 'unmanaged' ? known : null

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
                {/* The agent's mark was here, once per row, saying the
                    same thing for every row under one heading. It is on
                    the heading now — see `groupAccountsByProvider`. */}
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
                  from the presence of a directory — and cut to a word
                  wherever the name above has already carried the address.
                  The ⓘ beside it holds the two facts the row used to
                  print underneath: which folder makes this account
                  separate, and where its conversations are. */}
              <span className="settings-account-state" data-state={state?.state ?? 'unknown'}>
                <span className="settings-account-mark" aria-hidden="true" />
                <span>{accountStateLine(state)}</span>
                <HoverNote label={profileLoginLabel(account, state)}>
                  {accountNote(account, rowHistory)}
                </HoverNote>
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

              {/* The config directory and the conversation location were
                  two more lines here. Both are behind the ⓘ above — see
                  `accountNote`, and the header on this file for why four
                  lines under a name is the thing that had to go. */}
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
                below says what is wrong and what to type instead.

                It is the *only* button on this pane now. Two blue buttons
                stood one above the other — a row's Sign in and the pane's
                **Add account** — and read as the same control offered
                twice: *"why do we have see sign in here separately, add
                account here separately?"* The one at the foot is gone (see
                `addAgent`), so this is what a person presses to sign a
                login in, and there is nothing beside it saying the same
                thing in different words. */}
            {onSignIn &&
              state &&
              state.state !== 'signed-in' &&
              state.state !== 'unsupported' &&
              agentCanStart(providerRows, account.provider) && (
                <Button disabled={busy} onClick={() => onSignIn(account)}>
                  Sign in
                </Button>
              )}

            {/*
              The other three, behind one dot, anchored to the row.

                > *"Stop sharing history. What is this nonsense? A lot of
                > buttons used by default. This is a lot to give."*

              Half of that was acted on — Share / Stop sharing history is
              gone — and half was not: the strip went from five buttons to
              four, on a line of its own under the name, so with two Claude
              accounts listed it was not obvious which account **Remove**
              would delete. Now the row carries at most one button and this,
              and this opens *inside the row*, which is what makes its
              subject unambiguous.

              A `<details>` rather than a floating menu, for the reason
              `AddAgentMenu` gives at length: this window is asserted through
              `renderToStaticMarkup`, which runs no effects and has no DOM to
              click in, so a portalled menu is a menu no test can read. It is
              also keyboard-operable and dismissable with no JavaScript.

              Rename and Remove are only ever offered on an account this app
              made. `Use by default` is only offered where there is more than
              one login to choose between — Gemini keeps one per machine, so
              there it would be a choice between an account and itself — and
              the whole dot disappears when it would hold nothing.

              `onToggle` is where it opens. This panel is absolutely positioned
              inside `.settings-panel`, which scrolls and is followed by the
              sheet's footer, so on the last row of the list it drew a grey
              sliver with every item under the footer — measured on 2026-08-20
              at 1280×900 as `{y: 757.8, h: 98, bottom: 855.8}` against a pane
              whose bottom edge is 786. `menu-room.ts` measures the row against
              whatever is clipping it and flips the panel above the dot when
              that is the side with the room.
            */}
            {(!account.system || (!isDefault && canHaveMore(providerRows, account.provider))) && (
              <details className="settings-rowmenu" onToggle={onMenuToggle}>
                <summary aria-label={`More for ${profileLoginLabel(account, state)}`}>
                  <span aria-hidden="true">⋯</span>
                </summary>
                <div className="settings-rowmenu-items">
                  {!isDefault && canHaveMore(providerRows, account.provider) && (
                    <button
                      type="button"
                      disabled={busy}
                      onClick={(event) => {
                        closeMenu(event)
                        onMakeDefault(account)
                      }}
                    >
                      Use by default
                    </button>
                  )}
                  {/* Share / Stop sharing history was the fourth button on
                      this row, behind a confirmation. *"This is nonsense"* —
                      of a control that relinks a conversation directory from
                      a settings list, on a row a person is scanning for their
                      own address. The plumbing is untouched; where the
                      conversations are is said behind the ⓘ above, so nothing
                      about this row is a surprise. */}
                  {!account.system && (
                    <>
                      {/* `closeMenu` on every one of these: a `<details>` has
                          no idea a button inside it did something, so Remove
                          used to leave the menu standing open on top of the
                          confirmation it had just raised. */}
                      <button
                        type="button"
                        disabled={busy}
                        onClick={(event) => {
                          closeMenu(event)
                          setRenaming({ id: account.id, name: account.name })
                        }}
                      >
                        Rename
                      </button>
                      <button
                        type="button"
                        className="danger"
                        disabled={busy}
                        onClick={(event) => {
                          closeMenu(event)
                          setConfirmRemove(account.id)
                        }}
                      >
                        Remove
                      </button>
                    </>
                  )}
                </div>
              </details>
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
            {/* What deleting this account would actually cost, which is
                a different answer depending on where its conversations
                live: a sharing account owns none of them, because its
                `projects/` is a link and removing a link removes a link.
                The rule this satisfies is explicit — never offer to
                delete a directory holding transcripts without saying what
                is lost — and `describeDelete` in the main process is the
                only thing that has counted them.

                Absent for an `unmanaged` account rather than substituted,
                and that is not a gap. `shareState` answers `unmanaged`
                without ever looking inside the directory, so its count is
                zero because nothing counted rather than because there is
                nothing there — printing the sentence built from it would
                promise a Codex account with a year of history that it has
                none. */}
            {rowHistory && <span>{rowHistory.remove}</span>}
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
  }

  return (
    <Group title={head ? undefined : title}>
      {head && <SectionHead title={title} blurb="One app, several agent logins." />}

      {/*
        The headed paragraph that was here is gone.

        It had already been cut twice — from "Claude only, and why", to three
        sentences, to one line and an ⓘ — and one line was still one line too
        many: *"don't put any single statement in anywhere… we want simplicity.
        Let the smart people use it."* Nothing it said is unreachable. Which
        agents can hold a second login is on the agent's own row in the
        Add-account popup, where it is the answer to a question somebody is in
        the middle of asking, and where a session's account is chosen is the
        button beside the folder that does it.
      */}

      {error && <Notice tone="error">{error}</Notice>}

      {/*
        The measured reason a sign-in is about to fail, on the screen somebody
        is standing on when it does. It draws nothing when every agent CLI on
        this machine is current — see `AgentCliUpdate` for the loop it closes.
      */}
      <AgentCliUpdate />

      {/*
        One list per agent, and no heading over an agent with nothing under it.

        The mark that used to sit on every row is on the heading instead: it was
        answering "which agent is this" once per account, which is the question
        the heading now answers once per group.
      */}
      {groups.map((group) => (
        <div key={group.label} className="settings-account-group">
          <h5 className="settings-account-group-title">
            <ProviderBadge provider={group.provider} />
            {group.label}
          </h5>
          <ul className="settings-profiles">{group.accounts.map(accountRow)}</ul>
        </div>
      ))}

      {accounts.length === 0 && !loading && (
        <p className="settings-prose">No accounts yet.</p>
      )}

      {/*
        One control, and it is the whole of this pane's foot.

        It used to be a primary button called **Add account**, and it is now the
        **Add agent** disclosure handed down from the pane above — see the
        `addAgent` prop. The change is not cosmetic and it is not a rename: the
        button was the second of two doors to one act, standing a row below the
        **Sign in** on every signed-out account, and he walked into the pair of
        them twice in one recording before saying so.

          > *"And why do we have see sign in here separately, add account here
          > separately? … Let's try from here, add of sign in. It's also taking
          > me same place."*

        So the row's Sign in survives — it is a row's act, on a specific login,
        and it is the only thing on this pane that can be pressed — and the
        pane's own act is the drop-down he asked for by name. Both still open
        the *same* popup, which is the point: one place an account is added,
        reachable from wherever somebody happened to be looking for it.

        Everything that used to sit under this line — a heading, the agent
        question, the list, a name field, its own Sign in button, three notices
        and an ⓘ — is inside that popup, which carries the sign-in steps and
        nothing else. And "Check again" is not here either: it re-ran a probe
        that runs when the pane opens, with a line of help under it describing
        that probe.
      */}
      {addAgent !== undefined && addAgent !== null && (
        <div className="settings-account-foot">{addAgent}</div>
      )}

      <AddAccountDialog
        open={adding}
        provider={addingFor}
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

  /*
   * Shared history from the first moment, and before the session starts.
   *
   * A second account exists because the first one ran out, which means it is
   * reached in the middle of a piece of work — and an account with a history of
   * its own drops that work on the floor at exactly that moment. Option C in
   * `ACCOUNT-MODEL.md` is the settled answer, so it is the state a new account
   * arrives in rather than a switch somebody has to find afterwards. The row's
   * own button is the way back out, and it is offered on every row.
   *
   * Before `start`, because sharing relinks `projects/`: a session opened first
   * would write its first conversation into the directory that is about to stop
   * being read.
   *
   * A refusal is not a failure of anything. `shareProjects` throws for an
   * account this app may not relink — a login of an agent whose history has a
   * different shape, or a directory the person pointed at themselves — and
   * those accounts are perfectly good accounts that simply keep their own
   * conversations. Turning that into an error would refuse to add an account
   * over a preference.
   */
  try {
    await bridge?.shareAccountHistory?.(id)
  } catch {
    // Nothing to say: the row will read "keeps its own conversations", which is
    // both true and the whole of the answer.
  }

  try {
    /*
     * Before the session, not after: `start` closes the settings window, so
     * anything after it lands while this pane is unmounting. The account chip
     * inside every open session reads its list on mount and never again — an
     * account added here was invisible there until the renderer was reloaded,
     * measured twice on 2026-08-20 — and this is what tells it to read again.
     */
    announceAccountsChanged()
    await start({ profileId: id, provider })
    return { ok: true, error: null }
  } catch (cause) {
    // The account was made a moment ago and has never been used, so removing it
    // cannot take anything away from anybody. `deleteFiles` is deliberately not
    // passed: `deleteProfile` keeps the directory unless asked, and an empty
    // directory is cheaper to leave than a wrong delete is to undo.
    await bridge?.deleteProfile?.(id).catch(() => undefined)
    // And unsay it, so no list is left showing an account that was rolled back.
    announceAccountsChanged()
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

export function AccountsSection({
  startSession,
  head,
  addAgent,
}: SectionProps & { head?: boolean; addAgent?: ReactNode }) {
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
          // Remove and Use-by-default land here. Every other list of accounts in
          // the window — the chip in each open session — reads again too.
          announceAccountsChanged()
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

  /**
   * Where each account's conversations live, and the two acts that move them.
   *
   * `useAccountHistory` rather than a read of its own, and rather than a field
   * on `useAccounts`: it fans one `lstat` out per account, files each answer
   * under the id it asked about, leaves an account it could not read simply
   * absent — which every reader here draws as nothing at all — and, crucially,
   * re-reads the row after either act instead of believing the reply. That last
   * property is the honesty rule of this feature, and it belongs in one place
   * because the account chip in a session is a second surface onto the same
   * accounts.
   */
  const ids = useMemo(
    () => accounts.snapshot.accounts.map((account) => account.id),
    [accounts.snapshot.accounts],
  )
  const histories = useAccountHistory(ids)

  /*
   * `changeHistory` was here — the one write this pane made into
   * `shared-projects`, behind the Share / Stop sharing button on every row.
   * The button is gone (see the header) and so is the call, but nothing under
   * it moved: `useAccountHistory().set` is still the one way to change the
   * sharing, and `signInToNewAccount` still puts every new account through
   * `shareAccountHistory` on the way in. What this pane does with the hook now
   * is read it, for the line behind each row's ⓘ.
   */

  return (
    <AccountsView
      head={head}
      addAgent={addAgent}
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
          else {
            accounts.reload()
            announceAccountsChanged()
          }
        })
      }}
      onRemove={(account) =>
        run(bridge?.deleteProfile?.(account.id), 'Could not remove that account.')
      }
      onMakeDefault={(account) =>
        run(bridge?.setDefaultProfile?.(account.id), 'Could not change the default account.')
      }
      history={histories.known}
    />
  )
}
