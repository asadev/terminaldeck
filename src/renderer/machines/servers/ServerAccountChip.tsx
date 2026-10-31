import { createPortal } from 'react-dom'
import { AGENT_CATALOG } from '../../../shared/agent-catalog'
import { ProviderBadge } from '../../components/ProviderBadge'
import { HoverNote } from '../../components/HoverNote'
import { isProviderId } from '../../preferences'
import { useChipMenu } from '../../shell/chip-menu'
import { agentLabel, signInLine, type ServerSignIn } from './server-signin'
import '../../shell/AccountChip.css'

/**
 * The account slot over a terminal on a server — a control now, not a word.
 *
 * ## What stood here, and what he said about it
 *
 * A `<span>` with a tooltip. The words were right — which coding logins the
 * account this shell signed in as holds — and the shape was the complaint:
 *
 *   > *"when I am inside the server, I cannot even change the accounts."*
 *
 * The old comment argued that an account *chip* here would be "a menu with
 * nothing to act on". That was true only of the verb it considered. A menu that
 * pretended to switch *this* terminal's agent would indeed be a lie — nothing
 * on the SSH side can replace a process this app never started — but there are
 * two verbs that are entirely real: **start a new terminal on this server with
 * one of its signed-in agents running**, and **go to where the sign-ins are
 * changed**. Those are what the rows do, and the menu says so before any row
 * is pressed.
 *
 * ## The same honest model as the local chip, stated the same way
 *
 * The local chip has exactly this situation over an agent somebody typed into
 * a shell: it cannot restart that session as another login, so its menu keeps
 * its rows, says what a press really does through `fixedAccountNote`'s ⓘ dot,
 * and picking a row opens a new session. This menu reuses that pattern — one
 * `HoverNote` on the heading, `SERVER_ACCOUNT_NOTE` below — rather than
 * inventing a second way of saying "picking here starts a new one".
 *
 * ## What is shared and what is not
 *
 * The stylesheet, wholly — same `account-chip`, same `folder-chip-button`,
 * same `folder-menu` and `account-menu-item` — so this is the same chip to
 * look at and press as the one over a local session or a paired machine's.
 * The *component* is its own for the reason `MachineAccountChip` is: almost
 * everything `AccountChip` does (probe sign-ins by spawning CLIs, rename
 * accounts on disk, arm deferred switches) is a local operation on local
 * files, and a "server" flag threaded through it would be a component whose
 * every branch asks which computer it is on.
 *
 * ## The words on the chip do not change
 *
 * The button's label and tooltip are `signInLine`'s, unchanged — the four
 * sentences that replaced the four blank states are still the four sentences.
 * What changed is that the slot can now be pressed, and pressing it is never a
 * dead end: whatever the state of the far machine, the menu carries at least
 * the row that opens Settings → Coding AI → Servers, which is where a login
 * is signed in or changed.
 */

const CHEVRON = 'M6.5 9.5 10 13l3.5-3.5'

/**
 * The one word this menu is titled with — the word the local chip and the
 * paired-machine chip both settled on. A different heading here would read as
 * a different feature rather than the same one, one kind of machine over.
 */
const MENU_HEAD = 'Account'

/**
 * Why picking a row will not change the terminal in front of you, and what it
 * does instead — `FIXED_ACCOUNT_NOTE`'s pattern, for the server case.
 *
 * One sentence per fact, in the order somebody needs them: whose login this
 * is, why this terminal keeps it, what a row press really does, and where the
 * login itself is changed.
 */
export const SERVER_ACCOUNT_NOTE =
  'These are the coding logins of the account this shell signed in as. This app did not start ' +
  'what is running in this terminal, so nothing here can restart it as somebody else — picking ' +
  'a login opens a new terminal on this server with that agent running, and this one keeps what ' +
  'it has. The logins themselves are changed by signing in, under Manage sign-ins below.'

/**
 * What typing a row's promise takes: the agent's own command.
 *
 * Through the catalogue for the three agents this build knows, so the word
 * typed on the server is the same word every other surface uses. An id the
 * catalogue has never met — a newer far end — is typed as it arrived, which is
 * the same honest fallback `agentLabel` makes for the label: `codex` at a
 * prompt is strictly more useful than a refusal to try.
 */
export function agentCommand(agentId: string): string {
  if (isProviderId(agentId)) return AGENT_CATALOG[agentId].bin ?? agentId
  return agentId
}

/**
 * The sentence for a menu with no login rows, or null when there are rows.
 *
 * `signInLine` has already decided which of the four states this is; what the
 * menu adds is only the part that will not fit on the chip, so the row somebody
 * reads before "Manage sign-ins" explains why that is the only press there is.
 * Pure, so the four sentences can be pinned without a DOM.
 */
export function menuStateLine(signIn: ServerSignIn, serverName: string): string | null {
  if (signIn.known === 'cannot') return signIn.why
  if (signIn.agents === 0) {
    return `No coding agent is installed on ${serverName === '' ? 'this server' : serverName}.`
  }
  if (signIn.logins.length === 0) return 'A coding agent is installed there and none of them has a login.'
  return null
}

export interface ServerAccountChipProps {
  /** The probe's answer for this shell's server. See `useServerSignIn`. */
  signIn: ServerSignIn
  /** The server's name, for the sentences — already on this bar, two chips left. */
  serverName: string
  /** Open a new terminal on this server with that agent's command typed into it. */
  onStartAgent(agentId: string): void
  /** Go to where sign-ins are changed: Settings → Coding AI → Servers. */
  onManage(): void
}

export function ServerAccountChip({ signIn, serverName, onStartAgent, onManage }: ServerAccountChipProps) {
  const words = signInLine(signIn, serverName)
  const logins = signIn.known === 'yes' ? signIn.logins : []
  // Remeasured on the row count, for the reason `useChipMenu` states: rows
  // arriving after the menu opened change its height and leave it placed for
  // the height it used to have.
  const menu = useChipMenu(logins.length + 1)

  const stateLine = menuStateLine(signIn, serverName)

  return (
    <div className="account-chip" ref={menu.hostRef}>
      <button
        type="button"
        className="folder-chip-button account-chip-button"
        aria-haspopup="menu"
        aria-expanded={menu.open}
        title={words.title}
        onClick={menu.toggle}
      >
        <span className="account-chip-name">{words.line}</span>
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
            aria-label={MENU_HEAD}
            style={{ left: menu.at.left, top: menu.at.top }}
          >
            <p className="folder-menu-head">
              {MENU_HEAD}
              {/* The mode, said before a row is read — the same ⓘ the local
                  chip carries when picking cannot mean switching. */}
              <HoverNote label="What picking a login does here">{SERVER_ACCOUNT_NOTE}</HoverNote>
            </p>
            {stateLine !== null && (
              <p className="folder-menu-item account-menu-item is-inert">
                <span className="account-menu-line">
                  <span className="folder-menu-name">{stateLine}</span>
                </span>
              </p>
            )}
            {logins.map((login) => (
              <div key={login.agentId} className="account-menu-row">
                <button
                  type="button"
                  role="menuitem"
                  className="folder-menu-item account-menu-item"
                  onClick={() => menu.choose(() => onStartAgent(login.agentId))}
                >
                  <span className="account-menu-line">
                    <ProviderBadge
                      provider={isProviderId(login.agentId) ? login.agentId : null}
                      label={agentLabel(login.agentId)}
                    />
                    {/* The verb first, because it is the whole promise of the
                        press; the address second, because it is whose login the
                        new terminal's agent will hold. */}
                    <span className="folder-menu-name">
                      {`New terminal running ${agentLabel(login.agentId)}`}
                      {login.account === null ? '' : ` — ${login.account}`}
                    </span>
                  </span>
                </button>
              </div>
            ))}
            <div className="account-menu-row">
              <button
                type="button"
                role="menuitem"
                className="folder-menu-item account-menu-item"
                onClick={() => menu.choose(onManage)}
              >
                <span className="account-menu-line">
                  <span className="folder-menu-name">Manage sign-ins in Settings</span>
                </span>
              </button>
            </div>
          </div>,
          document.body,
        )}
    </div>
  )
}
