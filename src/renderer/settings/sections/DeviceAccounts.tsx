import { useState } from 'react'
import { profileLoginLabel } from '../../accounts'
import { ProviderBadge } from '../../components/ProviderBadge'
import { Button, Notice } from '../controls'
import { hasSignOut, signOutNote } from '../../../shared/agent-catalog'
import {
  signInMachineLogin,
  signInOf,
  signOutMachineLogin,
  useMachineAccount,
  useMachineLogins,
  type MachineAccount,
} from '../../machines/machine-account'
import type { MachineWithLink } from '../../machines/useMachines'

/**
 * One linked device's logins, on the Coding AI pane — read from that device, and
 * managed there.
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
 * ## What changed on 2026-08-21, and what it replaced
 *
 * This pane used to carry two apologies, and both were true when they were
 * written. The first: *"a machine's logins are readable only through a session
 * on it"* — because `account.read` carries a session id and the wire refuses one
 * without, so a machine with nothing running had no readable logins at all,
 * which is exactly when somebody opens a settings pane to look at it. The
 * second: *"nothing here signs anything in or out"*, because the protocol
 * carried two account verbs and both were about one session.
 *
 * `CAPABILITY.logins` is the answer to both halves that could be answered. It
 * carries the machine's list with no session in the question, and a sign-in that
 * opens a terminal over there for the person to finish an interactive login in —
 * which is what signing in *is* for every agent this app ships with, and what
 * this app's own Accounts pane does at this desk.
 *
 * ## Sign out, which is here now
 *
 * It arrived on 2026-08-26, in the same change as the local one and off the same
 * missing piece: `agent-catalog.ts` gained `signOutArgs`, the measured logout
 * command `signInArgs` never had a counterpart for. So a signed-in row of an
 * agent that has one carries a **Sign out** beside its Sign in, and the press
 * runs that machine's own logout over there and re-reads its probe — never a
 * dead button, because `hasSignOut` decides whether it is drawn. The one agent
 * with no logout command (Gemini) shows its reason on the row instead, which is
 * §4.1: a control that cannot act is absent, not disabled hopefully.
 *
 * ## The session read is kept, and is now the fallback
 *
 * A machine running a build older than `logins` — or one this desktop is a
 * *guest* on — answers nothing to the machine-scoped read. Rather than a blank
 * pane, this falls back to what it could always do: read the logins through a
 * session running over there. Two paths, one list, and the pane says which of
 * them it is on only when it is on the narrow one.
 */
export function DeviceAccounts({ device }: { device: MachineWithLink }) {
  const link = device.link
  const online = link?.state === 'online'
  const machineId = online ? device.machine.id : null

  /*
   * The machine's own list, with no session in the question. The right question
   * for this pane, and the one that was not expressible until tonight.
   */
  const machine = useMachineLogins(machineId)

  /*
   * The fallback, and the reason it is still here: a build over there that
   * predates `CAPABILITY.logins` answers nothing above, and reading the list
   * through a running session is what this pane could always do.
   *
   * Any session will do — `account.read` answers with the machine's whole
   * profile list plus which login *that* session is on — and it is asked for
   * only when the machine-scoped read came back unanswered, so a current build
   * costs one round trip rather than two.
   */
  const session = online ? (link?.sessions[0] ?? null) : null
  const fallbackWanted = machine.loaded && !machine.answered
  const viaSession = useMachineAccount(
    fallbackWanted && session ? device.machine.id : null,
    fallbackWanted ? (session?.id ?? null) : null,
  )

  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)

  if (!online) {
    return (
      <p className="settings-prose">
        {device.machine.name} is not connected, and its logins are kept on it rather than
        here.
      </p>
    )
  }

  if (!machine.loaded) {
    return <p className="settings-prose">Asking {device.machine.name}…</p>
  }

  const accounts = machine.answered ? machine.accounts : viaSession.accounts
  /*
   * Signing in is offered only on the machine-scoped path, because it is the
   * same capability: a machine that could not answer the list cannot be asked to
   * start a login either, and a button that is certain to be refused is not one
   * to draw.
   */
  const canSignIn = machine.answered

  if (!machine.answered) {
    if (!session) {
      return (
        <p className="settings-prose">
          {device.machine.name} is running a build that does not manage its logins from here, and
          it has no session open to read them through. Update it, or start one from the sidebar.
        </p>
      )
    }
    if (!viaSession.loaded) {
      return <p className="settings-prose">Asking {device.machine.name}…</p>
    }
  }

  if (accounts.length === 0) {
    /*
     * Both halves, because this end genuinely cannot tell them apart on the
     * fallback path: `useMachineAccount` sets `loaded` on a good answer, on a
     * reply it could not read and on a round trip that never came back, and
     * leaves the list empty in all three. "That machine has no accounts" is a
     * claim about somebody's PC, and two of those three cases would make it a
     * false one.
     */
    return (
      <p className="settings-prose">
        Nothing came back from {device.machine.name}. That is either no logins over there, or
        a read that did not arrive.
      </p>
    )
  }

  const signIn = (account: MachineAccount): void => {
    setBusy(account.id)
    setNotice(null)
    void signInMachineLogin(device.machine.id, account.id)
      .then((answer) => {
        // The far machine's own words, both ways. A sentence written here about
        // a computer this window is not on would be a guess.
        setNotice({ ok: answer.ok, text: answer.message })
        // Whether the login actually took is a question for the next read of
        // that machine's own probe — never assumed from the press.
        if (answer.ok) machine.reload()
      })
      .catch(() => setNotice({ ok: false, text: `${device.machine.name} did not answer.` }))
      .finally(() => setBusy(null))
  }

  const signOut = (account: MachineAccount): void => {
    setBusy(account.id)
    setNotice(null)
    void signOutMachineLogin(device.machine.id, account.id)
      .then((answer) => {
        // The far machine's own sentence, exactly as sign-in above — never one
        // this window wrote about a computer it is not on.
        setNotice({ ok: answer.ok, text: answer.message })
        // Re-read that machine's probe rather than believe the press: the far
        // end already settled `ok` against its own probe, and this is what puts
        // the row's state line in step with it.
        if (answer.ok) machine.reload()
      })
      .catch(() => setNotice({ ok: false, text: `${device.machine.name} did not answer.` }))
      .finally(() => setBusy(null))
  }

  return (
    <>
      {notice !== null && <Notice tone={notice.ok ? 'info' : 'error'}>{notice.text}</Notice>}
      {!machine.answered && (
        // Only on the narrow path, and only about the thing that is narrower:
        // this is a build over there that cannot be asked about itself, so the
        // list is whatever a running session could report and there is nothing
        // to press.
        <Notice tone="info">
          {device.machine.name} is running a build that does not manage its logins from here, so
          this is read through a session on it.
        </Notice>
      )}

      <div className="settings-account-group">
        <h5 className="settings-account-group-title">On {device.machine.name}</h5>
        <ul className="settings-profiles">
          {accounts.map((account) => (
            <DeviceRow
              key={account.id}
              account={account}
              running={
                machine.answered
                  ? false
                  : viaSession.current?.id === account.id && session !== null
              }
              session={session?.title ?? ''}
              busy={busy !== null}
              onSignIn={canSignIn ? () => signIn(account) : null}
              /* Same capability as sign-in — a machine that cannot be asked to
                 start a login cannot be asked to end one either — and `DeviceRow`
                 draws it only on a row that is signed in and whose agent has a
                 logout command. */
              onSignOut={canSignIn ? () => signOut(account) : null}
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
 * remove and a default, and none of those three crosses this wire — a shared row
 * would have to draw three blanks, and a blank where a control goes reads as a
 * control that failed to load.
 *
 * What *does* cross is the sign-in state, since `AccountWire.signIn` — the far
 * machine's own probe, in its own words — so the row is named by the same ladder
 * the local one uses rather than by the profile key. Never `account.name`: that
 * is what made f_0015 five rows of `Default` and `Default (Codex CLI)`, keys
 * `profiles.ts` mints on every machine, which name nobody.
 */
export function DeviceRow({
  account,
  running,
  session,
  busy,
  onSignIn,
  onSignOut = null,
}: {
  account: MachineAccount
  running: boolean
  session: string
  busy: boolean
  /** Null when that machine cannot be asked to start a login. Then nothing is drawn. */
  onSignIn: (() => void) | null
  /**
   * Null when that machine cannot be asked to end a login — the same capability
   * as sign-in. Optional so the render tests that predate it need no change;
   * absent draws no Sign out, which is the honest state where none can be run.
   */
  onSignOut?: (() => void) | null
}) {
  const state = signInOf(account)
  const provider = account.provider
  /*
   * Sign out is drawn only where it can act: the login is actually signed in,
   * and that agent has a logout command. A signed-in login whose agent has none
   * (Gemini) shows its reason below instead — §4.1, never a button that refuses.
   */
  const canSignOutHere =
    onSignOut !== null && state.state === 'signed-in' && provider !== null && hasSignOut(provider)
  const signedInNoSignOut =
    state.state === 'signed-in' && provider !== null && !hasSignOut(provider)
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
          {profileLoginLabel(account, account.signIn ?? undefined)}
          {/* Which session, by name. "Running now" alone would read as a claim
              about the machine, and the machine may have five sessions on five
              logins — this is the one that was asked. */}
          {running && session !== '' && <span className="settings-badge">{session}</span>}
        </span>
        {/* The far machine's own sentence about this login, or the one that says
            its build does not report the question. One line, and never a state
            this end invented. */}
        <span className="settings-account-state" data-state={state.state}>
          <span className="settings-account-mark" aria-hidden="true" />
          <span>{state.detail === '' ? state.state : state.detail}</span>
        </span>
        {/* Why a signed-in row of this agent has no Sign out, in the agent's own
            terms — only where the button would otherwise be the missing control.
            The reason is the same one the local pane and the servers pane show,
            read from the one catalogue. */}
        {signedInNoSignOut && provider !== null && (
          <span className="settings-account-blocked">{signOutNote(provider)}</span>
        )}
      </span>
      {/* Offered on every row rather than only on the signed-out ones, and that
          is deliberate: signing in again is how a login that has expired is
          renewed, and this end must not decide from a state it read a minute ago
          that somebody does not need to. */}
      {onSignIn !== null && (
        <Button onClick={onSignIn} disabled={busy}>
          Sign in
        </Button>
      )}
      {/* And out again, on a row that is signed in and whose agent has a logout
          command. The far machine runs it and re-reads its own probe; this end
          only asks. */}
      {canSignOutHere && onSignOut !== null && (
        <Button onClick={onSignOut} disabled={busy}>
          Sign out
        </Button>
      )}
    </li>
  )
}
