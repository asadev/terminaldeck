/**
 * What this machine answers when *another* machine asks whose login one of its
 * sessions is on — and what it does when that machine asks for a different one.
 *
 * ## The complaint this is the far half of
 *
 * Asad, 2026-08-20, on a session running on his PC:
 *
 *   > *"on the remote sessions, I don't have any of these features. We had this
 *   > before, but I don't have it now. I want it exactly like the local ones."*
 *
 * and, a minute later:
 *
 *   > *"Then also bring the account selection here for the remote sessions too."*
 *
 * The account chip was withheld over a remote session, and the note where it
 * should have been said why: *"which account an agent on another machine was
 * spawned under is not a fact any frame on the wire carries"*. That was true and
 * is the whole of what this file changes. `CAPABILITY.account` carries the
 * question there and the answer back, and `session-account.ts` — the module that
 * refuses to *guess* a session's login — is what answers it, so a chip drawn
 * over a session on his PC names what that PC established rather than what this
 * Mac would have assumed.
 *
 * ## Why it is its own file, beside `usage-serve.ts`
 *
 * The same reason that one is: it exists only because there is a wire. It
 * reaches the functions this machine's own window reaches — `listProfiles` for
 * the list, `readSignIn` for who each login actually is, `sessionAccount` for
 * the running session's login, and the shell's own switch for the change — so a
 * remote chip and a local chip are two callers of one mechanism rather than two
 * implementations of one feature. Nothing about what an account *is* is worked
 * out here.
 *
 * ## The one thing that is genuinely different from `controls`
 *
 * A control types a slash command and the session survives it. A switch **stops
 * the process and starts another** under a different configuration directory, so
 * the session it produces has a new id — which is why {@link AccountServeOptions}
 * asks the shell for the switch instead of composing one out of `startSession`
 * and a kill. There is exactly one implementation of "run this session as
 * somebody else" on this machine and it is the one the window at this desk
 * presses; a second one written here is how one of the two comes to skip the
 * conversation guard that `session-switch.ts` exists to enforce.
 */

import type { ProviderId, SessionMeta } from '../../shared/types'
import { listProfiles, type Profile } from '../profiles'
import { readSignIn, type SignInReport } from '../profiles-signin'
import { sessionAccount } from '../session-account'
import type { AccountWire } from './protocol'
import type { RemoteAccountAccess } from './server'

export interface AccountServeOptions {
  /**
   * Ask this machine's own agent CLIs who each login is — the seam, so a unit
   * test does not spawn `claude auth status` three times.
   *
   * Defaults to `readSignIn`, which is the same function this machine's own
   * Accounts screen calls, memoised for thirty seconds inside itself. That
   * sharing is the point: a chip a metre away and a chip on another continent
   * are two readers of one probe, so they cannot come to disagree about who is
   * signed in here.
   */
  readSignIn?: (profile: Profile) => Promise<SignInReport>
  /**
   * The session, as this machine's own list holds it. Null when nothing here has
   * that id.
   *
   * The same lookup `usage-serve.ts` is given and for the same reason: "which
   * session is this" having two answers on one machine is how one session's
   * facts land on another's chip.
   */
  describeSession(sessionId: string): Pick<SessionMeta, 'id' | 'provider'> | null
  /**
   * Run that session as another of this machine's logins — the operation the
   * window at this desk performs from its own account chip.
   *
   * Handed in rather than built, because it is a session-lifecycle operation
   * that lives in the shell: it starts a replacement, waits to see whether the
   * agent survived its first seconds, and only then ends the session it
   * replaced. Its absence is what stops this machine advertising the capability
   * at all — see `SessionAccess.account`.
   */
  switchAccount(
    sessionId: string,
    accountId: string,
  ): Promise<{ ok: boolean; message: string; session: string | null }>
}

/**
 * The account seam a paired machine reaches, built over this machine's own
 * readers and this machine's own switch.
 */
export function createAccountServe(options: AccountServeOptions): RemoteAccountAccess {
  const probe = options.readSignIn ?? ((profile: Profile) => readSignIn(profile))
  return {
    read: async (sessionId) => {
      /*
       * Every login, and **who each one is** — not just what it is called.
       *
       * The list used to be names alone, which meant the chip over a remote
       * session had nothing to print for the machine's own install but the key
       * `systemProfileId` generates for it. Asad, 2026-08-21, on a session whose
       * terminal three lines below the chip read *"Welcome back Sherzod
       * Davlatov"*:
       *
       *   > *"It is saying default, so never default. Whatever is actual account
       *   > should be visible here, never default."*
       *
       * In parallel because they are independent processes and a person has a
       * handful of accounts; each one is memoised for thirty seconds inside
       * `readSignIn`, so the second read — the one that happens when somebody
       * opens the menu — spawns nothing at all. `readSignIn` never rejects, and
       * the `catch` is for the seam rather than for it: a probe that threw would
       * otherwise take the whole answer down and leave the chip with no list.
       */
      const accounts = await Promise.all(
        listProfiles().map(async (profile) => toWire(profile, await probe(profile).catch(() => null))),
      )
      const session = options.describeSession(sessionId)
      if (session === null) return { current: null, accounts }
      /*
       * The established login, never the resolved one.
       *
       * `sessionAccount` answers from this app's own spawn record where it
       * started the session and from the agent process's own environment where
       * it did not, and it answers `withheld` rather than falling back to the
       * machine's default — which is the fix `session-account.ts` was written
       * for, reported by Asad about a *local* session showing the wrong name.
       * Sending the resolved default over the wire instead would put that same
       * defect back on a screen a metre further away, where it is harder to
       * catch.
       */
      const answer = await sessionAccount(sessionId).catch(() => null)
      if (answer === null || answer.kind !== 'known' || answer.profileId === null) {
        return { current: null, accounts }
      }
      const profileId = answer.profileId
      /*
       * Matched against the list rather than composed from the answer, so the
       * row that gets a tick is a row that is *in* the menu. A `current` naming
       * an account the list does not carry — a profile deleted a moment ago — is
       * a chip with a name on it and nothing selected, which reads as the
       * selection being lost.
       */
      const known = accounts.find((row) => row.id === profileId)
      if (known !== undefined) return { current: known, accounts }
      return {
        current: {
          id: profileId,
          name: answer.profileName ?? profileId,
          provider: answer.provider,
          color: null,
          system: false,
          // No `signIn`: this is a profile the list does not carry, so nothing
          // here has probed it, and absent is what "not reported" means on this
          // wire. Composing an "unknown" state would be this machine claiming to
          // have asked a question it never put.
        },
        accounts,
      }
    },
    switch: (sessionId, accountId) => options.switchAccount(sessionId, accountId),
  }
}

/**
 * One of this machine's logins, as the wire carries it.
 *
 * `color` travels as the custom-property *name* `Profile.color` already holds,
 * never as a colour value: the palette is one stylesheet on the drawing side,
 * and a machine sending `#c96` would be a second palette arriving over a wire.
 */
function toWire(profile: Profile, signIn: SignInReport | null): AccountWire {
  return {
    id: profile.id,
    name: profile.name,
    provider: profile.provider as ProviderId,
    color: profile.color === '' ? null : profile.color,
    system: profile.system,
    /*
     * Four fields of the report and not the fifth.
     *
     * `command` stays here: it is a command line for a shell on *this* machine,
     * and the window reading it is on another one — so it could only be offered
     * to somebody who cannot run it, and it is the one field of the report that
     * names paths on this disk.
     *
     * Spread, so a probe that could not be made leaves the key off entirely.
     * Absent means *this machine did not say*, which the drawing side tells apart
     * from all four states — see `AccountWire.signIn`.
     */
    ...(signIn === null
      ? {}
      : {
          signIn: {
            state: signIn.state,
            account: signIn.account,
            plan: signIn.plan,
            detail: signIn.detail,
          },
        }),
  }
}
