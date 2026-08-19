/**
 * Who reaches the copilot: one of his own devices, and nobody else.
 *
 * ## The decision, in his words
 *
 * Asad, 2026-08-19:
 *
 * > *"Instead of giving mobile app separate connection for copilot, just make it
 * > like — if we are connecting as my device, copilot automatically comes. If we
 * > connect as guest then copilot don't come. That's all we need to do, instead
 * > of two different connections."*
 *
 * So the second act of authorisation is gone, and this file is what is left of
 * it: **the kind decided when a device was approved is the whole answer.** There
 * is no copilot code, no copilot credential, no `copilot-link.json`, and no
 * state in which a device is paired and the copilot says *connect me first*.
 *
 * ## What this replaced, and why that argument does not survive
 *
 * `copilot-link.ts` — deleted with this file's arrival — held a separate
 * connection per device: its own six-digit code minted at this keyboard, its own
 * scrypt credential, its own record, its own rate limiter. It existed to answer
 * one objection, which `COPILOT-REMOTE.md` §4 made at length and which was
 * right:
 *
 * > *The `alter` tier's entire safety property is that a human at the machine
 * > says yes. A dialog answered by the party being confirmed is a ceremony.*
 *
 * The reply, then, was that the second factor could not be *geography* — a
 * person who walks away from an unlocked Mac has taken their geography with them
 * — but that it could be **an authorisation the requesting party did not already
 * hold**. That reasoning is still correct. What was wrong was the belief that a
 * second code was the only thing that could supply it.
 *
 * Pairing a device as **My device** already is that authorisation, and it has
 * every property the copilot code was minted to have:
 *
 *  - it is minted at this keyboard, by a person who can see the screen;
 *  - it is typed at the other end, so holding the device is not enough;
 *  - and it **cannot be changed afterwards**. `device-kind.ts` writes a kind
 *    once and deliberately exposes no method that overwrites one, so a guest
 *    cannot be promoted by a tap. Changing what a device is means pairing it
 *    again — the same two acts, by the same two people.
 *
 * The copilot code proved that same fact a second time, and the price was a
 * screen, a credential, a file, a rate limiter and a whole class of states where
 * a device was paired, trusted, sitting there, and refused. That is the class of
 * defect this codebase keeps finding under a different name: **the mechanism
 * written, the connection absent.**
 *
 * ## What it costs, said plainly
 *
 * One of his own devices reaches the copilot the moment it is approved. The
 * approval screen is therefore where the whole decision is made, and its wording
 * has to carry that weight — which it already does, in his words, because he
 * wrote both sentences:
 *
 * > **My device** — Full access. It's you at another keyboard.
 * > **Guest** — You choose what they can reach. The copilot is never shared.
 *
 * A person choosing *My device* is told they are handing over full access. There
 * is no longer a second screen in which to notice it, and pretending otherwise
 * by keeping a code nobody understood was not a safeguard, it was a delay.
 *
 * ## Fail closed, in the same direction as the kind itself
 *
 * Everything here answers *no* for a device it cannot place. `device-kind.ts`
 * already resolves an unknown device, an unparseable record and an unreadable
 * file to `guest`; this file adds nothing to that and simply asks. A guest gets
 * {@link NO_TIERS} and, one layer up in `server.ts`, no `copilot` key in its
 * welcome at all — absent rather than false, because an advertised capability
 * a device may not use invites the ask, and the answer to the ask is always no.
 *
 * ## Read per call, never cached
 *
 * `remoteCopilotCaller` re-reads this on **every tool call**, which is the same
 * discipline the store it replaced had and matters more now than it did then:
 * revoking a device is the only way to take the copilot away, and it has to land
 * on the next call rather than the next reconnect.
 */

import { NO_TIERS, type TierGrant } from '../deck-control/surface'

/**
 * Everything one of his own devices may do, which is everything.
 *
 * A frozen literal rather than a computed spread of `TIERS`, so that a fourth
 * tier added to `deck-control` next year does **not** become remotely grantable
 * by existing. Somebody has to come here and write it down, having decided that
 * a phone may do it — which is the property the old `REMOTE_GRANTABLE_TIERS`
 * ceiling existed to give, kept while the file around it went away.
 */
export const FULL_TIERS: TierGrant = Object.freeze({ read: true, act: true, alter: true })

/** One device that reaches the copilot, for the settings panel to list. */
export interface CopilotReach {
  deviceId: string
  tiers: TierGrant
}

export interface CopilotAccessDeps {
  /**
   * The kind decided when this device was approved. `device-kind.ts`.
   *
   * A callback rather than a snapshot, for the reason `server.ts` gives about
   * the same question: a device can be approved while another one is connected,
   * and a roster read at construction is answering about a house that has since
   * changed.
   */
  isMine(deviceId: string): boolean
}

export class CopilotAccess {
  constructor(private readonly deps: CopilotAccessDeps) {}

  /**
   * What this device may do, read now.
   *
   * **This is the function the whole feature rests on** — it is called per tool
   * call through `remoteCopilotCaller`, and it is the only thing standing
   * between a paired phone and a tool that can rewrite this machine.
   */
  granted(deviceId: string): TierGrant {
    if (typeof deviceId !== 'string' || deviceId === '') return NO_TIERS
    return this.mine(deviceId) ? FULL_TIERS : NO_TIERS
  }

  /**
   * Does this device reach the copilot at all?
   *
   * Identical to "is it one of his" by construction, and kept as its own name
   * because `server.ts` and every client read it as an answer about the
   * *copilot* rather than about the device roster. A client that drew its
   * Copilot tab off a device-kind field would be reproducing this rule on the
   * far side of a wire, which is where the two eventually disagree.
   */
  linked(deviceId: string): boolean {
    return typeof deviceId === 'string' && deviceId !== '' && this.mine(deviceId)
  }

  /**
   * Which of a roster of paired devices reach the copilot.
   *
   * The roster is passed in rather than held, because the device list lives in
   * `RemoteAuth` inside `server.ts` and a second reference to it here would be a
   * second answer to *which devices exist* — the shape this codebase has had to
   * unpick twice already. Nothing is stored: this is a filter over what the
   * caller already has.
   */
  list(devices: readonly string[]): CopilotReach[] {
    return devices.filter((deviceId) => this.linked(deviceId)).map((deviceId) => ({ deviceId, tiers: FULL_TIERS }))
  }

  /**
   * Ask the kind store, and treat a throw as a guest.
   *
   * The store reads a file. A file can be missing, truncated or unreadable, and
   * a throw crossing this line would land in whichever call site asked —
   * including one deciding whether to dispatch a tool. `device-kind.ts` already
   * fails closed for every case it can see; this closes the one it cannot.
   */
  private mine(deviceId: string): boolean {
    try {
      return this.deps.isMine(deviceId)
    } catch {
      return false
    }
  }
}

/**
 * The caller a remote copilot run acts as, rebuilt on every tool call.
 *
 * It re-reads access on every call — that is the point, and it is why every run
 * registers `() => remoteCopilotCaller(access, deviceId)` rather than a
 * snapshot. Revoking a device in Settings lands on the *next tool call*.
 */
export function remoteCopilotCaller(
  access: Pick<CopilotAccess, 'granted'>,
  deviceId: string,
): { kind: 'remote'; deviceId: string; tiers: TierGrant } {
  return { kind: 'remote', deviceId, tiers: access.granted(deviceId) }
}
