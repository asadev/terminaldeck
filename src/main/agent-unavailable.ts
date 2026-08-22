/**
 * The one throw that says "the agent you asked for is not installed here".
 *
 * ## Why this is a file of its own
 *
 * The class was declared in `host-core.ts`, which is the right place for the
 * *decision* — `startSession` is what probes the machine and refuses rather than
 * quietly opening a shell instead, and the long comment there is the argument
 * for that refusal. It was the wrong place for the *type*, because the other end
 * of a throw is a `catch`, and the file holding the only `catch` that matters —
 * `remote/session-create.ts` — cannot import `host-core.ts`: host-core imports
 * *it* (`remoteSessionStart`), so the import would close a cycle.
 *
 * That is not a theoretical tidiness point. Measured on a rented Ubuntu server
 * on 2026-08-22, against a host installed from `install-headless.sh` and driven
 * from the browser client over the live relay: pressing New session on a machine
 * with no `claude` on it threw this error, `session-create.ts` could not name the
 * type, so it fell into the generic branch and the phone was told **"This
 * machine could not start a session there. The folder may have moved."** The
 * folder was fine. The only true account of what happened went to `console.error`
 * — which on a headless host is `/dev/null`, because the daemon detaches with its
 * stdio closed. A person in that position has been sent to look at the one thing
 * that is not broken, with no way to find out otherwise.
 *
 * A leaf module fixes that with no cycle and no behaviour change anywhere else:
 * `host-core.ts` re-exports the class, so every existing importer is untouched,
 * and the two files that need to agree about this error now import the same
 * declaration rather than one of them guessing from `error.name`.
 *
 * Nothing else belongs here. It imports one type and nothing at run time, which
 * is what lets both the desktop and the headless bundle take it without dragging
 * anything behind it.
 */

import type { ProviderId } from '../shared/types'

/**
 * Thrown when the agent a session asked for cannot be started on this machine.
 *
 * `provider` is the id that was asked for, kept beside the sentence because a
 * caller that wants to offer a remedy — "install it", "pick another" — needs the
 * name and must not have to parse it back out of English.
 */
export class AgentUnavailableError extends Error {
  readonly provider: ProviderId

  constructor(provider: ProviderId, label: string, insideWsl: boolean) {
    super(
      `${label} could not be found ${insideWsl ? 'inside the WSL distribution' : 'on this machine'}, ` +
        `so this session was not started.`,
    )
    this.name = 'AgentUnavailableError'
    this.provider = provider
  }
}
