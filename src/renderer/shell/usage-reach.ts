/**
 * Whose account and whose conversation the usage bar is a reading of, and what
 * to do when the answer is "not this computer's".
 *
 * ## The defect this exists to end
 *
 * `SessionControls` learned to route its *controls* to whichever machine a
 * session is actually on — `controls-target.ts` is that router — and the usage
 * bar beside them was left mounted over every session unchanged. It has two
 * figures on it and both of them are read from this laptop:
 *
 *  - the **plan limits**, which are the subscription of the login signed in
 *    *here*, and
 *  - the **context window**, which is read out of a transcript file on *this*
 *    disk, found by a session id this machine's own agent wrote.
 *
 * Over a session running on his PC, the first is a different account's usage and
 * the second is a lookup for an id this disk has never seen. So the bar over a
 * remote session was reporting one true number about the wrong computer and one
 * blank, and it was drawn identically to the bar over a local session, with
 * nothing anywhere saying which of the two you were looking at. A number
 * presented as being about the thing on screen when it is about something else
 * is the one class of mistake this feature was nearly cancelled twice for.
 *
 * ## Withholding is the fallback here, not the goal
 *
 * The standing rule is that the app's shape must not change between local and
 * remote — *"shape of the application should not be changing for local and
 * remote devices"*, argued in full at the top of `src/main/localhost-reach.ts`.
 * Read strictly that would say: make the figure *true* over a remote session
 * rather than absent. It can be made true, and the way is known — a paired
 * machine is by definition a machine running this app, so it has its own
 * `usage-probe.ts` and its own `context-window.ts` and could answer for its own
 * account exactly the way `controls.read` already has it answer for its own
 * screen. {@link WIRE_VERSION_NEEDS} is the list of what that costs, kept here
 * so the next person does not have to rediscover it.
 *
 * That now exists, so the machine case is no longer a withholding at all: the
 * figures travel, and the bar over a session on his PC is a reading of his PC.
 * What is left of the original decision is its shape — a module that answers
 * *which computer*, once, for both hooks and the view, rather than an `if` in a
 * component — and the rule it was written under, which still binds whatever this
 * grows into: when there is no figure, the sentence saying why has to reach the
 * screen, and it has to be there *before* anybody presses anything.
 *
 * ## The server case is not the same case
 *
 * A paired machine is running this app. A server is not — it is an SSH channel
 * with a pty on the end of it, which is why `controls-target.ts` reaches one
 * through `servers:controls:*` and drives this machine's own screen readers over
 * the far end's bytes. Controls can work that way because the answer is *on the
 * screen*. Neither usage figure is: a plan limit is an account's, and this app
 * has no account on somebody's server; a context window is a transcript file,
 * and that file is on the far side of the SSH channel with nothing on this wire
 * that carries it. So the server branch is not waiting on the wire work below —
 * it is a genuine, permanent nothing, and it says so in its own words.
 */

import type { ControlsTarget } from './controls-target'

/**
 * What the wire version would need, written down at the moment it was decided
 * against rather than after somebody has already started guessing.
 *
 * Every item is the `controls` capability's own shape, because that lane solved
 * the identical problem three weeks of arguing ago and the answer must not be
 * reinvented differently:
 *
 *  1. **A `usage` capability in `src/main/remote/protocol.ts`**, negotiated in
 *     `hello`/`welcome` beside `controls`, with one `rid`-correlated frame pair
 *     — `usage.read` carrying which of the two figures is wanted, and
 *     `usage.reading` carrying the answer or an `unavailableReason`. Both
 *     directions parsed defensively and totally, the way `parseControls` is: a
 *     malformed frame must produce "nothing was read", never a plausible number.
 *  2. **A `SessionAccess.usage` seam in `src/main/remote/server.ts`**, gated on
 *     `mayTouch` exactly as `controlsServe` is, so a device that may not attach
 *     to a session cannot read what that session's account has spent.
 *  3. **`readUsage` on the machine link in `src/main/remote/machines/guest.ts`**,
 *     plus `machines:usage:read` in that folder's `ipc.ts` and a preload method,
 *     so the renderer reaches it the way it reaches `readMachineControls`.
 *  4. **A router beside `controls-target.ts`** turning this module's `withheld`
 *     into a fetch for the machine case, leaving the server case exactly as it
 *     is here.
 *
 * And the one constraint that decides the design rather than decorating it:
 * **a plan figure may only ever be asked for on demand.** Getting one boots a
 * whole agent CLI on the far machine — 725 MB peak, about three seconds,
 * measured on this Mac — which is affordable when a person opens the dropdown to
 * read it and is not affordable on mount, on attach, or on any timer. The
 * context figure is a bounded file read over there, 2–17 ms, so it may be asked
 * for on the same events the local one is re-read on. Anything that puts the
 * first of those two on the second's schedule must not ship.
 *
 * ## Built, 2026-08-19
 *
 * All four landed, and the list above is left standing as the *argument* rather
 * than rewritten as a description, because the argument is what the next person
 * changing any of it needs. Where each went:
 *
 *  1. `CAPABILITY.usage` in `src/main/remote/protocol.ts`, negotiated beside
 *     `controls`, with one `rid`-correlated `usage.read` / `usage.reading` pair
 *     and a `want` on the frame.
 *  2. `SessionAccess.usage` in `src/main/remote/server.ts`, gated on the same
 *     `mayTouch` as `controlsServe`, refusing hidden sessions in
 *     `session-fanout.ts` alongside `controls`, and served over this machine's
 *     own readers by `remote/usage-serve.ts`.
 *  3. `readUsage` on the machine link in `machines/guest.ts`, plus
 *     `machines:usage:read` in that folder's `ipc.ts` and `readMachineUsage` in
 *     the preload.
 *  4. `usage-target.ts`, beside `controls-target.ts`, which turns the `machine`
 *     case below into a fetch and leaves the server case exactly as it is.
 *
 * The constraint held, and this is where to check that it still does: the wire's
 * three `want`s are three separate methods on the host seam, so the 725 MB one
 * cannot be reached by a caller that meant a cheap one. The remote bridge's
 * `watchUsage` — the call every mount makes — asks for what the far machine
 * already holds. Only `refreshUsage` asks it to go and look, `useUsageBar` calls
 * that only from `check`, and `UsageBar.tsx` calls `check` only on opening the
 * panel and on the retry button inside it.
 */
export const WIRE_VERSION_NEEDS = 4

/**
 * Where the bar's figures would have to come from, and whether this build can
 * get them.
 *
 * Deliberately two states and not a boolean. The reason travels with the
 * refusal because it is the whole of what the reader gets in place of a number,
 * and a boolean would have every call site inventing its own wording for a
 * distinction — a machine that could answer versus a server that never can —
 * that they would then word differently.
 */
export type UsageReach =
  /** The session is on this computer, so this computer's readings are its own. */
  | { kind: 'here' }
  /**
   * The readings belong to a paired machine, and that machine can be asked for
   * them.
   *
   * Not a withholding any more. `CAPABILITY.usage` carries the question there
   * and the answer back, so the bar over a session on his PC shows *that*
   * machine's plan limits and *that* session's context window — which is what
   * the standing rule wanted all along. `usage-target.ts` is the router that
   * does the asking; this only says which computer.
   */
  | { kind: 'machine'; machineId: string }
  /** They are somebody else's readings, and this is what to say instead. */
  | { kind: 'withheld'; reason: string }

/**
 * The one place that decides, from the same `target` the controls beside it are
 * routed by.
 *
 * `undefined` means this computer — the value every mount of the bar carried
 * before remote sessions had controls at all — so the local path is untouched by
 * construction rather than by care.
 */
export function usageReach(target: ControlsTarget | undefined): UsageReach {
  if (target === undefined) return { kind: 'here' }
  if (target.kind === 'machine') return { kind: 'machine', machineId: target.machineId }
  return {
    kind: 'withheld',
    reason:
      'This session is a terminal on a server, which is not running this app. There is no account signed in there to have limits and no transcript here to read a context window from, so nothing is shown rather than this computer’s own figures.',
  }
}

/**
 * The sentence, or null when there is none — which is the shape every consumer
 * of this actually wants.
 *
 * A helper rather than a `reach.kind === 'withheld' ? reach.reason : null` at
 * four call sites, because the two hooks and the view all have to agree about
 * when the bar is withholding, and three copies of one ternary is three chances
 * for one of them to keep fetching after the other two stopped drawing.
 */
export function withheldReason(reach: UsageReach): string | null {
  return reach.kind === 'withheld' ? reach.reason : null
}
