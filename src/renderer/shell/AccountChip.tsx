import { createPortal } from 'react-dom'
import type { ProviderId } from '@shared/types'
import { useChipMenu } from './chip-menu'
import { isolationNotice } from '../components/ProfilePicker'
import { accountForFolder, signInLabel, useAccounts, type AccountView } from '../accounts'

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
  /** Start a session in `projectPath` under this account. */
  onPick(accountId: string): void
  /** Open the Accounts screen — add one, rename one, sign one in. */
  onManage(): void
}

const CHEVRON = 'M6.5 9.5 10 13l3.5-3.5'

export function AccountChip({ current, projectPath, provider, onPick, onManage }: Props) {
  const menu = useChipMenu(null)
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

  return (
    <div className="account-chip" ref={menu.hostRef}>
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
               */
              return blocked ? (
                <p key={account.id} className="folder-menu-item account-menu-item is-inert">
                  {line}
                </p>
              ) : (
                <button
                  key={account.id}
                  type="button"
                  role="menuitem"
                  className="folder-menu-item account-menu-item"
                  data-current={account.id === currentId || undefined}
                  onClick={() => menu.choose(() => onPick(account.id))}
                >
                  {line}
                </button>
              )
            })}

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
