import { profileLoginLabel } from '../../accounts'
import { ProviderBadge } from '../../components/ProviderBadge'
import { Notice } from '../controls'
import { useMachineAccount, type MachineAccount } from '../../machines/machine-account'
import type { MachineWithLink } from '../../machines/useMachines'

/**
 * One linked device's logins, on the Coding AI pane.
 *
 * ## Why this is here at all
 *
 * The scope switch had two buttons — this machine, and servers — while the rail
 * six inches to its left was listing a paired PC with a live session on it:
 *
 *   > *"And maybe we can also see the other linked device. Whatever new comes
 *   > here, so we can manage next to them, each of them."*
 *
 * So a device is a scope, and choosing it shows **that machine's** accounts.
 * Not this Mac's, filtered — the far machine's own list, read from the far
 * machine, which is the property the whole account model turns on:
 *
 *   > *"So when I am inside the remote, it will show the accounts, whatever the
 *   > accounts are logged in in the actual place wherever this session is right
 *   > now."*
 *
 * ## What this pane cannot do yet, and says so
 *
 * Two things, and neither is hidden behind a control that looks alive.
 *
 * **A machine's logins are readable only through a session on it.** The wire
 * verb is `account.read` and it carries a session id — `protocol.ts` refuses one
 * without: *"account.read without a session id"*. That is not an oversight of
 * this pane's, it is the shape of the frame, and until the far end grows a
 * session-less read there is nothing to ask when nothing is running over there.
 * A machine with a session gets its real list; a machine without one gets the
 * sentence saying which, rather than an empty box that reads like a machine with
 * no accounts.
 *
 * **Nothing here signs anything in or out.** He asked for it —
 *
 *   > *"So we can click and manage what accounts are there, what we want to
 *   > login, logout, things, access."*
 *
 * — and the protocol carries exactly two account verbs, `account.read` and
 * `account.switch`, both about one session. There is no sign-in, no sign-out and
 * no access grant to call, so this draws none: a **Sign out** that could only
 * apologise is the shape of defect this app keeps being reviewed for.
 */
export function DeviceAccounts({ device }: { device: MachineWithLink }) {
  const link = device.link
  const online = link?.state === 'online'
  /*
   * The first session on that machine, which is the only handle a read has.
   *
   * Any session will do: `account.read` answers with the machine's whole
   * profile list and which login *that* session is on, so the list half is the
   * same whichever one is asked. The tick is about the session, and this pane
   * says so rather than presenting it as a machine-wide default — which is a
   * different fact, and one nothing on the wire reports.
   */
  const session = online ? (link?.sessions[0] ?? null) : null
  const state = useMachineAccount(session ? device.machine.id : null, session?.id ?? null)

  if (!online) {
    return (
      <p className="settings-prose">
        {device.machine.name} is not connected, and its logins are kept on it rather than
        here.
      </p>
    )
  }

  if (!session) {
    return (
      <p className="settings-prose">
        {device.machine.name}’s logins are read through a session running on it, and it has
        none open. Start one from the sidebar and they are listed here.
      </p>
    )
  }

  if (!state.loaded) {
    return <p className="settings-prose">Asking {device.machine.name}…</p>
  }

  if (state.accounts.length === 0) {
    /*
     * Both halves, because this end genuinely cannot tell them apart:
     * `useMachineAccount` sets `loaded` on a good answer, on a reply it could
     * not read and on a round trip that never came back, and leaves the list
     * empty in all three. "That machine has no accounts" is a claim about
     * somebody's PC, and two of those three cases would make it a false one.
     */
    return (
      <p className="settings-prose">
        Nothing came back from {device.machine.name}. That is either no logins over there, or
        a read that did not arrive.
      </p>
    )
  }

  return (
    <>
      {/* The one thing this pane can act on is not on this pane, and saying so
          once is what stops somebody hunting for a button that is not here. It
          is a `Notice` rather than prose because it is a limit of the build
          rather than a description of the screen. */}
      <Notice tone="info">
        Signing in and out happens on {device.machine.name} itself — this build can read that
        machine’s logins and which one a session is running as, and nothing more.
      </Notice>

      <div className="settings-account-group">
        <h5 className="settings-account-group-title">On {device.machine.name}</h5>
        <ul className="settings-profiles">
          {state.accounts.map((account) => (
            <DeviceRow
              key={account.id}
              account={account}
              running={state.current?.id === account.id}
              session={session.title}
            />
          ))}
        </ul>
      </div>
    </>
  )
}

/**
 * One login on the far machine.
 *
 * Deliberately not the local row's component. That one carries a rename, a
 * remove, a default and a sign-in state read from an agent's own CLI, and not
 * one of those five facts crosses the wire — `AccountWire` is an id, a name, an
 * agent and a colour. A shared row would have to draw four blanks, and a blank
 * where a state goes reads as a state that failed to load.
 */
function DeviceRow({
  account,
  running,
  session,
}: {
  account: MachineAccount
  running: boolean
  session: string
}) {
  return (
    <li className="settings-profile">
      <span
        className="settings-profile-dot"
        style={account.color ? { background: `var(${account.color})` } : undefined}
        aria-hidden="true"
      />
      <span className="settings-profile-main">
        <span className="settings-profile-name">
          <ProviderBadge provider={account.provider} />
          {/* Never `account.name`, which is what the chip's own menu prints and
              is why f_0015 is five rows of "Default" and "Default (Codex CLI)":
              those are keys `profiles.ts` mints on the far machine, identical on
              every install of this app, and they name nobody.

              `profileLoginLabel` with no sign-in view, because there is none to
              have — the wire's account record is an id, a name, an agent and a
              colour, and no agent over there has been asked who it is logged in
              as. So the rung reached is the install's, which is true of a
              machine that is his: it is his own Claude Code install, on his own
              PC, under a heading that names the PC. */}
          {profileLoginLabel(account, undefined)}
          {/* Which session, by name. "Running now" alone would read as a claim
              about the machine, and the machine may have five sessions on five
              logins — this is the one that was asked. */}
          {running && <span className="settings-badge">{session}</span>}
        </span>
      </span>
    </li>
  )
}
