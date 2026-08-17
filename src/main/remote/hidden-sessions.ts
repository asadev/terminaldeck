/**
 * Session ids that are not the network's business, beyond the copilot's own.
 *
 * ## Why this is a module and not an argument
 *
 * `SessionFanout` takes a `hidden` predicate, and `host-core.ts` answers it with
 * `isCopilotSession(id)` — a module-level singleton check, because the copilot
 * at the desk is a singleton. That closed the hole §0.1 of `COPILOT-REMOTE.md`
 * calls blocking: a paired phone could `list`, find the row whose folder is
 * `<userData>/copilot`, `attach`, and type into the Claude CLI holding
 * `deck-control` — past the per-device grant, past every tier, every budget and
 * every confirmation dialog, because none of those sit between a pty and its
 * keyboard.
 *
 * Per-device copilot runs are the same hole with more instances. Each is a
 * Claude CLI in the same folder with the same tools, and a phone that could
 * attach to *its own* run's pty would hold `alter` no matter what its grant
 * said, because it could simply type. `COPILOT-REMOTE.md` §5.3 states it as a
 * rule: the phone gets parsed `ChatMessage`s, never bytes.
 *
 * So the answer has to grow, and the question is where from. Three shapes were
 * possible and this is the least bad:
 *
 *  - **A predicate injected into `createHostCore`.** Correct, and it makes the
 *    two shells — the Electron one and the headless one — each responsible for
 *    remembering to pass it. `host-core.ts` says why that is the wrong direction
 *    in the comment right above the predicate: *"a rule a shell had to remember
 *    to install is a rule the other shell forgets."*
 *  - **A field on `copilot-session.ts`.** That module is the copilot at the
 *    desk. Runs belong to the relay, not to it, and putting them there would
 *    make one module answer for two features that are deployed separately.
 *  - **This.** One place, written by whoever owns a hidden pty, read by the one
 *    predicate. It costs a `Set.has` on a host that has never started a run.
 *
 * ## Fail closed, and why the register is not the owner
 *
 * Nothing here removes an id on its own. A run manager registers on spawn and
 * releases on stop, and if it ever failed to release, the cost is one pty that
 * a phone cannot reach — which is the direction this rule must fail in. The
 * opposite arrangement, where an id ages out or is re-derived from a live list,
 * would mean a race between a spawn and a `list` could expose a keyboard.
 */

/**
 * The ids, and nothing about what they are.
 *
 * Deliberately not a map to a reason or an owner. The one question anybody may
 * ask this module is *may the network see this session*, and a richer structure
 * would invite a second question with a subtler answer — "hidden from listing
 * but attachable", say, which is precisely the distinction §0.1 warns is not a
 * distinction at all: an unlisted id is recoverable from `originRunId`, from an
 * alert, from a transcript path.
 */
const hidden = new Set<string>()

/** This pty is not reachable over the relay, by any verb, from now on. */
export function hideSession(sessionId: string): void {
  if (sessionId !== '') hidden.add(sessionId)
}

/** Its process is gone; the id may be reused by something ordinary. */
export function releaseSession(sessionId: string): void {
  hidden.delete(sessionId)
}

/** The question `SessionFanout` asks. */
export function isHiddenSession(sessionId: string): boolean {
  return hidden.has(sessionId)
}

/** Forget everything. For tests, and for nothing else. */
export function resetHiddenSessions(): void {
  hidden.clear()
}
