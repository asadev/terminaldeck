import { useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { ProviderId } from '@shared/types'
import { useChipMenu } from './chip-menu'
import { isolationNotice } from '../components/ProfilePicker'
import { chipMode, useAgentPresence, type ChromeSession } from './agent-presence'
import {
  accountForFolder,
  accountsBridge,
  renameAccount,
  signInLabel,
  useAccounts,
  MAX_ACCOUNT_NAME_LENGTH,
  type AccountView,
} from '../accounts'
import './AccountChip.css'

/**
 * Which account a session runs as, beside the folder it runs in.
 *
 * Asad asked for both choices in one place, before anything is typed:
 *
 *   > "when I start a new session I can choose any of my logged in account and
 *   > the folder and I can start a new session"
 *
 * New session still starts immediately in the last folder — that was the
 * earlier ask and it stands. This is the other half of the same line under the
 * session's name: the folder chip says where, this says who, and both are one
 * click from the same spot.
 *
 * ## It starts a session; it does not switch the one you have
 *
 * Exactly the rule the folder chip already follows, for exactly the same
 * reason. The account is a config directory handed to the agent process at
 * spawn, and a process's environment cannot be rewritten after it starts — so
 * "run this session as someone else" can only mean killing it and starting
 * another. The app cannot tell whether that would throw away work, because
 * keystrokes go from xterm straight to the pty and the renderer never sees
 * them. So the menu says what it really does, and the running session keeps the
 * account it started with.
 *
 * ## Nothing here claims a login it has not seen
 *
 * The state beside each name is read by running the agent's own `auth status`
 * under that account's config directory when the menu opens — see
 * `profiles-signin.ts`. Until an answer arrives the row says "Checking…", and
 * an answer that could not be read says "Unknown". A tick is only ever drawn
 * for an account the agent said it was signed into.
 *
 * ## …including the login it cannot give you
 *
 * An account is a `CLAUDE_CONFIG_DIR` handed to the agent at spawn, so it only
 * means anything for an agent that reads one. `supportsProfiles` in
 * `main/profiles.ts` is the authority and it answers true for Claude alone —
 * a plain shell has no login to isolate, and Codex and Gemini sign in their own
 * way under whatever login the machine already has.
 *
 * This menu used to offer the rows regardless. With the default coding tool set
 * to Plain shell — which is a setting, not an edge case — picking an account
 * opened a session, `host-core.ts` correctly declined to label it, and the chip
 * snapped back to the default account's name. The click did nothing and said
 * nothing, which is the dead control the design brief forbids and, worse, looks
 * exactly like the app quietly sharing one login between two accounts.
 *
 * So the menu asks what a new session here would actually run and, when that
 * agent has no account to give, says so and stops offering the choice.
 * `isolationNotice` is the same sentence the new-session dialog already prints,
 * imported rather than reworded so the two surfaces cannot drift apart.
 *
 * ## Renaming happens where the name is
 *
 *   > "The account dropdown inside a session shows the name an account was
 *   > given and offers no way to change it."
 *
 * The name on a row here is the only place most people ever *see* an account,
 * and it was the one place they could not correct it — the rename lived three
 * screens away in Settings. Each row now carries a Rename button that turns it
 * into a field in place.
 *
 * It is not a second implementation. `renameAccount` in `accounts.ts` is the
 * one that both this and the Accounts screen call: it owns the trim, the length
 * cap, the "same name is not a rename" rule and the re-read of the list
 * afterwards. Growing a copy here is exactly how the two would come to disagree
 * about whether a blank name means "clear it" — and the main process will
 * happily store an account called `''`, which neither surface can then show.
 *
 * ## A shell has no account, so it is offered an agent instead
 *
 *   > "Starting a session gives you a plain shell. Today that shell still shows
 *   > the chat/terminal switch and the account dropdown — both of which mean
 *   > nothing until an agent is running in it. … Put a Run Claude button there
 *   > instead."
 *
 * An account is a `CLAUDE_CONFIG_DIR` handed to an agent, so with no agent in
 * the session there is nothing for this control to be about — the chip was
 * showing the account a *future* session would use, on a terminal that is not
 * going to use one. In that state the same slot is a Run Claude button, and it
 * does the thing the command does rather than telling you the command:
 * `claude`, typed into the session's own pty, exactly as if it had been typed
 * in the terminal view.
 *
 * The moment an agent is running the button gives way to the account chip. That
 * swap is driven by {@link useAgentPresence}, never by what was typed: `claude`
 * exits and leaves the shell behind, and a control keyed off the keystroke
 * would stay switched for the rest of the tab's life.
 *
 * While presence is *unknown* — the first few hundred milliseconds, or a build
 * with no controls channel — neither is drawn. Guessing wrong in that direction
 * is not free: pressing Run Claude at a session that already has Claude in it
 * does not start anything, it submits the word "claude" as a prompt.
 */

interface Props {
  /**
   * The account the session on screen is running as, when it has one.
   *
   * Comes off `SessionMeta`, which the main process fills in at spawn from the
   * profile it actually resolved. Null for a session with no account — a plain
   * shell, or an agent whose config directory this app cannot redirect — and
   * for those the chip shows what a *new* session here would use instead.
   */
  current: { id: string; name: string } | null
  /** The folder a session started from this menu will run in. */
  projectPath: string | null
  /**
   * The agent a session started from this menu would run.
   *
   * Used only to explain when an account cannot apply — see the module note.
   * Undefined means "not known", which is treated as "no objection": a notice
   * nobody can act on is worse than no notice.
   */
  provider?: ProviderId
  /**
   * The session this chip is sitting under, when the toolbar is showing one.
   *
   * Only used to answer "is there an agent in it" — see the module note.
   * Omitted, the chip behaves exactly as it did before that question existed:
   * it is the account picker, always. That is deliberate rather than lazy; the
   * two callers that render this without a session in play are asking about a
   * folder, and a folder cannot have an agent running in it.
   */
  session?: ChromeSession | null
  /**
   * Start Claude in `session`. Optional: without it the button types the
   * command into the session's own pty itself, which is the same thing the
   * terminal view would do with the same keystrokes.
   */
  onRunAgent?(sessionId: string): void
  /** Start a session in `projectPath` under this account. */
  onPick(accountId: string): void
  /** Open the Accounts screen — add one, rename one, sign one in. */
  onManage(): void
}

const CHEVRON = 'M6.5 9.5 10 13l3.5-3.5'

/**
 * What Run Claude types.
 *
 * The bare command, with no flags. Not `--continue`: that silently resumes
 * whichever conversation was last written in the folder, which is a different
 * thing from what the button says and — as `session-transcript.ts` records at
 * length — is frequently not this session's conversation at all.
 *
 * `\r`, not `\n`: a pty carries what a keyboard sends, and Return is carriage
 * return. The rest of this app types into sessions the same way — see
 * `sendCommand` in `main/agent-controls.ts`.
 */
export const RUN_AGENT_COMMAND = 'claude\r'

/** The row being renamed, and what has been typed into it so far. */
interface Editing {
  id: string
  draft: string
}

export function AccountChip({
  current,
  projectPath,
  provider,
  session = null,
  onRunAgent,
  onPick,
  onManage,
}: Props) {
  const agent = useAgentPresence(session)
  /** Whether the previous render drew the Run Claude button. See `revealing`. */
  const wasRun = useRef(false)
  const [editing, setEditing] = useState<Editing | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  // Escape belongs to the field while one is open — see `useChipMenu`.
  const menu = useChipMenu(null, editing !== null)
  /*
   * Non-null exactly when a new session here would run an agent that has no
   * account to be given. The rows below stop being buttons when it is set.
   */
  const blocked = isolationNotice(provider)
  // Only while the menu is open. Mounted, this chip is on screen for the whole
  // life of every session, and checking sign-in state on mount would spawn a
  // process per account every time a tab changed.
  const accounts = useAccounts(menu.open)

  const rows: readonly AccountView[] = accounts.snapshot.accounts

  /**
   * Save the name being edited, then re-read the list.
   *
   * The re-read is the reason this does not just patch the row: ids, colours
   * and config directories are the main process's to assign, and a name written
   * only into local state is a row that no longer matches the account on disk.
   */
  const save = (account: AccountView): void => {
    const typed = editing?.draft ?? ''
    setSaving(true)
    setFailure(null)
    void renameAccount(accountsBridge(), account, typed).then((problem) => {
      setSaving(false)
      setFailure(problem)
      // A failed rename keeps the field open with what was typed still in it —
      // closing it would throw the name away along with the message explaining
      // why it did not take.
      if (!problem) {
        setEditing(null)
        accounts.reload()
      }
    })
  }

  /*
   * What the button says, and which row is marked as the one in use.
   *
   * The running session's own account when it has one, because that is a fact
   * about what is on screen and stays true even if the account has since been
   * removed from the list. Otherwise the account a new session in this folder
   * *would* use, resolved the way the main process resolves it.
   *
   * The colour is looked up separately and on purpose: a session can name an
   * account that is no longer in the list, and inventing a colour for it would
   * put a coloured dot beside a name that matches no row in the menu.
   */
  const fallback = accountForFolder(accounts.snapshot, projectPath)
  const currentId = current?.id ?? fallback?.id ?? null
  const listed = currentId === null ? null : rows.find((row) => row.id === currentId) ?? null
  const label = current?.name ?? fallback?.name ?? null

  /**
   * Start Claude in this session.
   *
   * Re-checked at the moment of the press, not only at the moment the button
   * was drawn. The presence reading is a screen reading and a screen can change
   * between those two instants — an agent started from the terminal a second
   * ago, say — and the cost of being late is not a no-op: `claude` typed at a
   * running Claude is submitted as a prompt.
   */
  const runAgent = (): void => {
    if (!session || agent.running !== false) return
    if (onRunAgent) {
      onRunAgent(session.id)
      return
    }
    const deck = (globalThis as { deck?: { writeToSession?: (id: string, data: string) => void } }).deck
    deck?.writeToSession?.(session.id, RUN_AGENT_COMMAND)
  }

  /*
   * A session with no agent in it wears no agent's controls.
   *
   * Three states, not two, because `running` has three values:
   *
   *   false → the screen was read and there is no agent. Offer to start one.
   *   true  → there is one. The account picker, exactly as before.
   *   null  → nothing has been read yet. Neither, and this is the interesting
   *           one: guessing "no agent" here would put a Run Claude button in
   *           front of a running Claude, and pressing it submits the word
   *           "claude" as a prompt. Guessing "agent" would put the account
   *           picker back on a plain shell, which is the complaint itself.
   *
   * `null` resolves within a few hundred milliseconds of the session printing
   * anything, and stays for good in a build with no controls channel — where
   * showing no control at all is the honest answer, and the folder chip beside
   * it still is one.
   */
  const mode = chipMode(session, agent)
  const showRun = mode === 'run'
  const showAccount = mode === 'account'
  /*
   * Was the account picker away a moment ago?
   *
   * The swap is between two different elements, so there is nothing for a CSS
   * transition to interpolate — the picker would simply appear. He asked for
   * the pill to *expand* to reveal it, so it is animated in, and only on the
   * render where it takes the other state's place. Animating it on every mount
   * would replay the same flourish on every tab switch, which is the difference
   * between a transition and a tic.
   */
  const revealing = wasRun.current && showAccount
  wasRun.current = !showAccount

  if (!showAccount && !showRun) return null

  // `session &&` as well as `showRun`, so the branch narrows. `chipMode` only
  // answers `run` for a session, but that is a fact about another module and
  // the compiler is right not to take it on trust.
  if (showRun && session) {
    return (
      <div className="account-chip account-chip-run">
        <button
          type="button"
          className="folder-chip-button run-agent-button"
          title={
            session.exited
              ? 'This session has ended — nothing can be started in it'
              : 'Start Claude in this session. Types the command for you, in this terminal.'
          }
          disabled={session.exited}
          onClick={runAgent}
        >
          {/* The same glyph the terminal draws for a prompt — this button is
              standing in for typing at one. */}
          <span className="run-agent-glyph" aria-hidden="true">
            ❯
          </span>
          <span>Run Claude</span>
        </button>
      </div>
    )
  }

  return (
    <div
      className={revealing ? 'account-chip is-revealing' : 'account-chip'}
      ref={menu.hostRef}
    >
      <button
        type="button"
        className="folder-chip-button account-chip-button"
        aria-haspopup="menu"
        aria-expanded={menu.open}
        title={
          blocked
            ? blocked
            : current
              ? `This session is signed in as ${current.name} — start one under a different account`
              : 'Choose which account a new session here uses'
        }
        onClick={menu.toggle}
      >
        <span
          className="account-chip-dot"
          aria-hidden="true"
          style={listed ? { background: `var(${listed.color})` } : undefined}
        />
        <span className="account-chip-name">{label ?? 'Account'}</span>
        <svg
          width="14"
          height="14"
          viewBox="0 0 20 20"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={CHEVRON} />
        </svg>
      </button>

      {menu.open &&
        createPortal(
          <div
            ref={menu.menuRef}
            className="folder-menu"
            role="menu"
            aria-label="Start a session as"
            style={{ left: menu.at.left, top: menu.at.top }}
          >
            <p className="folder-menu-head">Start a session as</p>

            {/* Why the rows below cannot be picked, before they are read rather
                than after one is clicked. */}
            {blocked && <p className="account-menu-blocked">{blocked}</p>}

            {rows.map((account) => {
              const state = accounts.signIn[account.id]

              /*
               * Renaming in place, in the row the name is already on.
               *
               * A form, so Return submits without a button of its own — the
               * whole row is 300px wide and a Save button beside a field that
               * accepts Return would be the third control on one line.
               */
              if (editing?.id === account.id) {
                return (
                  <form
                    key={account.id}
                    className="folder-menu-item account-menu-item account-menu-rename"
                    onSubmit={(event) => {
                      event.preventDefault()
                      save(account)
                    }}
                  >
                    <span
                      className="account-chip-dot"
                      aria-hidden="true"
                      style={{ background: `var(${account.color})` }}
                    />
                    <input
                      className="account-menu-input"
                      value={editing.draft}
                      maxLength={MAX_ACCOUNT_NAME_LENGTH}
                      autoFocus
                      disabled={saving}
                      aria-label={`New name for ${account.name}`}
                      onChange={(event) => setEditing({ id: account.id, draft: event.target.value })}
                      onKeyDown={(event) => {
                        // The menu is holding Escape open for exactly this.
                        if (event.key !== 'Escape') return
                        event.preventDefault()
                        setEditing(null)
                        setFailure(null)
                      }}
                    />
                  </form>
                )
              }

              const line = (
                <>
                  <span className="account-menu-line">
                    <span
                      className="account-chip-dot"
                      aria-hidden="true"
                      style={{ background: `var(${account.color})` }}
                    />
                    <span className="folder-menu-name">{account.name}</span>
                  </span>
                  {/* Read, not assumed. An account the agent has not answered
                      about yet says so, and one it could not answer about says
                      that instead of a cross. */}
                  <span className="account-menu-state" data-state={state?.state ?? 'unknown'}>
                    {state ? state.account ?? signInLabel(state) : 'Checking…'}
                  </span>
                </>
              )

              /*
               * A paragraph, not a disabled button. The accounts are still worth
               * showing — they are what the Accounts screen would let you sign
               * in to — but nothing here can act on them while this agent has no
               * config directory to redirect, and a button that cannot be
               * pressed still looks like the app's answer to the question.
               *
               * Rename stays available even then. Whether this agent can be
               * given a config directory has nothing to do with whether the
               * account's *name* is right, and the name is what is on screen.
               */
              return (
                <div key={account.id} className="account-menu-row">
                  {blocked ? (
                    <p className="folder-menu-item account-menu-item is-inert">{line}</p>
                  ) : (
                    <button
                      type="button"
                      role="menuitem"
                      className="folder-menu-item account-menu-item"
                      data-current={account.id === currentId || undefined}
                      onClick={() => menu.choose(() => onPick(account.id))}
                    >
                      {line}
                    </button>
                  )}
                  <button
                    type="button"
                    className="account-menu-rename-button"
                    title={`Rename ${account.name}`}
                    aria-label={`Rename ${account.name}`}
                    onClick={() => {
                      setFailure(null)
                      setEditing({ id: account.id, draft: account.name })
                    }}
                  >
                    Rename
                  </button>
                </div>
              )
            })}

            {/* Why a rename did not take. Held next to the field rather than
                announced and dismissed, because the field is still open with
                the typed name in it. */}
            {failure && <p className="account-menu-empty">{failure}</p>}

            {rows.length === 0 && (
              <p className="account-menu-empty">
                {accounts.loading ? 'Reading your accounts…' : 'No accounts to choose from.'}
              </p>
            )}

            {accounts.error && <p className="account-menu-empty">{accounts.error}</p>}

            {/* Says what the rows above actually do. The running session keeps
                the account it started with — see the module note. The second
                sentence is only true while the rows are pickable, and printing
                it under a list that cannot be picked was the promise that made
                the silent no-op read as a bug rather than a rule. */}
            <p className="account-menu-foot">
              {blocked
                ? 'Change the default coding tool in Settings to start a session under one of these.'
                : 'Opens a new session here under that account. This one keeps the account it started with.'}
            </p>

            <button
              type="button"
              role="menuitem"
              className="folder-menu-item folder-menu-browse"
              onClick={() => menu.choose(onManage)}
            >
              Add or sign in to an account…
            </button>
          </div>,
          document.body,
        )}
    </div>
  )
}
