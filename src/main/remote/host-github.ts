/**
 * The machine's own GitHub login, as a phone drives and reads it.
 *
 * `github-auth.ts` already holds the login and runs the device flow — it was
 * built for the desktop panel and speaks in `GitHubAuthState`, a folder-shaped
 * thing carrying an open project's repository, its branch and the account's
 * whole repository list. A phone driving the machine asks a smaller question,
 * and this is the seam that answers it: *is this machine signed in, as whom,
 * and if not what do I press.* It maps the authenticator's state down to
 * {@link GitHubHostWire} and nothing folder-shaped survives the trip.
 *
 * It is the same object on a desktop and on a headless server, because the
 * authenticator is — Asad's rule, 2026-08-27: *"for headless also we give the
 * option to connect GitHub there."* Over the wire is the whole of how a server's
 * GitHub gets connected, since a server has no panel of its own.
 *
 * ## The change hook, and why a phone hears about a sign-in it did not press
 *
 * A device-flow sign-in a phone starts finishes minutes later, in a background
 * poll on the host, long after the `github.connect` that began it was answered.
 * `github-auth.ts` fires its `onAuthChanged` when that poll stores the token —
 * and on a disconnect, and on a sign-in one of the owner's other devices ran —
 * so {@link GitHubHostAccess.emitChanged} is wired to it in `host-core.ts`, and
 * `server.ts` turns each one into a `github.changed` push. Events, not a phone
 * polling `github.read`.
 */

import type { GitHubAuthenticator, GitHubAuthState } from '../github-auth'
import type { GitHubHostWire } from './protocol'

export interface GitHubHostAccess {
  /** The machine's login as the wire carries it. Never throws. */
  read(): Promise<GitHubHostWire>
  /** Start the device flow; the returned state carries the code in `pending`. */
  connect(): Promise<GitHubHostWire>
  /** Stop waiting on a sign-in in flight. */
  cancel(): Promise<GitHubHostWire>
  /** Sign the machine out. */
  disconnect(): Promise<GitHubHostWire>
  /**
   * Hear about a login change — a flow that completed, a disconnect, a sign-in
   * from another of the owner's devices. Returns its own unsubscribe.
   */
  onChanged(listener: () => void): () => void
  /** Fire the change listeners. Wired to the authenticator's `onAuthChanged`. */
  emitChanged(): void
}

/**
 * Fold a `GitHubAuthState` (plus the last flow failure) down to the wire shape.
 *
 * Exported so the mapping is a pure function a test can pin, rather than a step
 * hidden inside `read()` that a test can only reach through a fake
 * authenticator. It takes the flow failure as an argument for the same reason
 * the desktop's `withFlowReason` is a wrapper and not a field: it is a fact
 * about the *last attempt*, which outlives the state object and has to be
 * folded in from outside.
 */
export function githubHostWire(state: GitHubAuthState, flowFailure: string | null): GitHubHostWire {
  // A refused-consent reason is shown the same way the desktop shows it: a
  // person who pressed Connect and walked away should read why, not a bare "not
  // signed in". `state.failure` wins when the read itself produced one; the last
  // flow's reason fills the gap when the read is simply "nothing connected".
  const failure = state.connected ? null : (state.failure?.message ?? flowFailure)
  return {
    connected: state.connected,
    login: state.identity?.login ?? null,
    name: state.identity?.name ?? null,
    avatarUrl: state.identity?.avatarUrl ?? null,
    source: state.source,
    appConfigured: state.appConfigured,
    installUrl: state.installUrl,
    pending: state.pending
      ? {
          userCode: state.pending.userCode,
          verificationUri: state.pending.verificationUri,
          expiresAt: state.pending.expiresAt,
        }
      : null,
    failure: failure ?? null,
    disconnect: state.disconnect,
  }
}

export function createGitHubHostAccess(auth: GitHubAuthenticator): GitHubHostAccess {
  const listeners = new Set<() => void>()

  // No cwd on any of these: the wire login is a property of the account, not of
  // a folder — the folder-shaped fields the panel needs are exactly what this
  // seam drops. `status()` with no cwd populates the account and the pending
  // sign-in and leaves repo/branch/access null, which is all the wire wants.
  const wire = (state: GitHubAuthState): GitHubHostWire =>
    githubHostWire(state, auth.flowFailure()?.message ?? null)

  return {
    async read() {
      return wire(await auth.status())
    },
    async connect() {
      // The prompt `connect()` returns lands in `this.flow`, and `status()`
      // re-reads that live at return time — so the whole status, with the code
      // in `pending` or the reason in `failure`, is the one truthful thing to
      // send back rather than a shape assembled from the return value.
      await auth.connect()
      return wire(await auth.status())
    },
    async cancel() {
      return wire(await auth.cancelConnect())
    },
    async disconnect() {
      return wire(await auth.disconnect())
    },
    onChanged(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    emitChanged() {
      for (const listener of listeners) {
        try {
          listener()
        } catch {
          // A listener that throws is a bug in the listener, not a reason to
          // drop the change for every other one — the server's push and the
          // desktop's cache-clear are independent readers of one event.
        }
      }
    },
  }
}
