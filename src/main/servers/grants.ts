/**
 * Whether the copilot may act on one server, and for how much longer.
 *
 * `SERVERS-DESIGN.md` §6.2 in one sentence: **the tier cannot be static,
 * because the answer depends on which server.** Everything else in this file is
 * that sentence made checkable.
 *
 * ## Why a grant exists at all rather than a settings toggle
 *
 * Full control of a production server driven by an agent is the largest blast
 * radius in this product — not the largest so far, the largest there is. The
 * copilot can already start sessions and write settings on *this* machine, and
 * every one of those is recoverable by the person sitting at it. A server is
 * somebody's live website, reached from a machine they are not sitting at, and
 * the person who notices first may be a customer.
 *
 * A toggle in Settings would be answered once, in a calm moment, about a thing
 * that was not in front of the person — which is the shape of every permission
 * anybody regrets. So the grant is asked for **on that server's own page**, it
 * names **that server**, and it runs out.
 *
 * ## The four properties, and what each one refuses
 *
 * 1. **Per server, never global.** {@link ServerGrants.grant} takes one id and
 *    the record is keyed on it. There is deliberately no `grantAll`. The blast
 *    radius of the grant is the blast radius of one machine, and "all my
 *    servers" is a sentence nobody can hold in their head at the moment they
 *    approve it.
 *
 * 2. **Local only. A guest never gets one, under any circumstances.** A paired
 *    phone or a relayed caller cannot be granted this and cannot ride in on a
 *    grant somebody else gave. The folder-grant work landed exactly this rule
 *    one level down — `folder-grants.ts` decides which folders a *device* may
 *    start a session in, and the reason it exists is that a remote caller's
 *    effect had quietly become wider than its own frames allowed. `surface.ts`
 *    states the general form: *"a tool's effect for a remote caller may never
 *    exceed what that device's own protocol frames already permit."* There is
 *    no server frame in the remote protocol at all, so the permitted effect is
 *    nothing, and this is where that nothing is enforced.
 *
 * 3. **It expires.** An agent permission that outlives the reason it was given
 *    is one nobody remembers granting. {@link DEFAULT_GRANT_MS} is an hour;
 *    §9 of the design document leaves the exact number to Asad and says why an
 *    hour is the safe guess — a grant that has to be re-given every ten minutes
 *    gets given carelessly, which is the failure mode `consent.ts` is written
 *    against.
 *
 * 4. **It dies with the app.** Nothing here is written to disk, and that is a
 *    decision rather than an omission. A grant is a *this-afternoon* answer to
 *    a *this-afternoon* question; a persisted one would silently survive a
 *    restart, a crash, a machine being carried somewhere else and — worst — an
 *    update, and be discovered by the person only when something had already
 *    happened. The cost is that a relaunch asks again, which is the direction
 *    to fail in.
 *
 * ## What a grant does *not* cover
 *
 * The `act` tier and nothing else. Never zone three: not the terminal (there is
 * no tool for it — §6.1), not the sign-in, not the host key, not Forget. Those
 * are things a person does with their own hands, and this object has no opinion
 * about them because it is never asked.
 */

/** How long a grant lasts when nobody says otherwise. See property 3 above. */
export const DEFAULT_GRANT_MS = 60 * 60 * 1000

/**
 * The longest a grant may be asked for.
 *
 * Here so that a caller which has gone wrong — or a future settings field —
 * cannot turn "for the next hour" into "until this machine is next rebooted".
 * Four hours is past any single sitting and well short of a working day.
 */
export const MAX_GRANT_MS = 4 * 60 * 60 * 1000

/**
 * The most servers that may hold a live grant at once.
 *
 * Not a security boundary — each grant is already independent — but a bound on
 * a map that is otherwise driven by a caller. Sixty-four matches `MAX_DEVICES`
 * in the trust store, for the same reason: a thing that cannot be added cannot
 * be granted anything.
 */
export const MAX_LIVE_GRANTS = 64

/** A live grant, as the server's own page draws it. */
export interface GrantState {
  serverId: string
  /** Epoch ms. Past this the grant is gone and the tier is back to `alter`. */
  expiresAt: number
  /** Epoch ms, for the sentence *"granted at 14:20"*. */
  grantedAt: number
}

/**
 * Why a grant was refused, when the reason is a rule rather than a fault.
 *
 * A closed set for the same reason `RefusalReason` in `surface.ts` is one:
 * these strings decide what a person is told, and "this caller may never hold
 * one" and "you already hold too many" are different answers with different
 * fixes. Free text would collapse them the first time somebody phrased one as
 * the other.
 */
export type GrantRefusal = 'not-local' | 'unknown-server' | 'too-many'

export class GrantRefused extends Error {
  constructor(
    readonly reason: GrantRefusal,
    message: string,
  ) {
    super(message)
    this.name = 'GrantRefused'
  }
}

/** Who is asking for the grant. Mirrors `Caller.kind` in `deck-control/surface.ts`. */
export interface GrantAsker {
  kind: 'local' | 'remote'
}

export interface ServerGrantsOptions {
  /** Injected so expiry is exercisable without waiting an hour. */
  now?: () => number
  /**
   * Does this app know this server?
   *
   * A grant on an id nothing can resolve is a row that will never expire from
   * anybody's attention, and it is also the shape of a caller inventing an id.
   * Absent means "cannot check", and a check that cannot run does not refuse —
   * the store is `store.ts`'s job and a host without one (the headless build,
   * a unit test) is not a reason to lock the feature.
   */
  knows?(serverId: string): boolean
}

/**
 * Live grants, in memory, for this launch.
 *
 * No Electron import and no filesystem, deliberately — the same rule
 * `device-auth.ts` and `folder-grants.ts` follow. The piece that decides whether
 * a dangerous call happens has to be exercisable as a plain object with a fake
 * clock, because the conditions it refuses under are conditions the app is not
 * in.
 */
export class ServerGrants {
  private readonly live = new Map<string, GrantState>()
  private readonly now: () => number
  private readonly knows: ((serverId: string) => boolean) | null

  constructor(options: ServerGrantsOptions = {}) {
    this.now = options.now ?? Date.now
    this.knows = options.knows ?? null
  }

  /**
   * Give the copilot the `act` tier on one server, for a while.
   *
   * Throws {@link GrantRefused} rather than answering false, because every
   * refusal here has a different sentence to put on a screen and a boolean
   * would force the caller to guess which.
   */
  grant(serverId: string, asker: GrantAsker, forMs: number = DEFAULT_GRANT_MS): GrantState {
    if (asker.kind !== 'local') {
      /*
       * Property 2. Note this refuses the *granting*, not merely the acting —
       * a remote caller must not be able to leave a grant behind that a later
       * local call then rides on. The two would look identical in the log.
       */
      throw new GrantRefused(
        'not-local',
        'Control of a server can only be granted by the person at this machine. A paired device cannot ' +
          'give it, and cannot receive it.',
      )
    }
    if (this.knows !== null && !this.knows(serverId)) {
      throw new GrantRefused('unknown-server', 'That server is not one this app knows about.')
    }
    this.sweep()
    if (!this.live.has(serverId) && this.live.size >= MAX_LIVE_GRANTS) {
      throw new GrantRefused(
        'too-many',
        `Too many servers are already under the copilot’s control. Take control back from one first.`,
      )
    }
    const at = this.now()
    const state: GrantState = {
      serverId,
      grantedAt: at,
      // Clamped rather than refused: a caller asking for a fortnight has made a
      // mistake, and an hour of control is a better answer to it than an error
      // that gets retried with a smaller number until one is accepted.
      expiresAt: at + Math.min(Math.max(Math.trunc(forMs), 0), MAX_GRANT_MS),
    }
    this.live.set(serverId, state)
    return state
  }

  /** Take it back. Idempotent — revoking what was never granted is not an error. */
  revoke(serverId: string): void {
    this.live.delete(serverId)
  }

  /** Take every grant back. For sign-out, shutdown, and the panic button. */
  revokeAll(): void {
    this.live.clear()
  }

  /**
   * Is this server under the copilot's control right now, for this caller?
   *
   * The caller is a parameter and not an afterthought: a remote caller is
   * answered `false` for every server whatever the map says, so property 2
   * holds at the point of *use* as well as at the point of granting. Two
   * checks for one rule is normally a smell; here the two guard different
   * events — one stops a grant existing, one stops a grant being used — and a
   * hole in either is a hole.
   */
  granted(serverId: string, asker: GrantAsker): boolean {
    if (asker.kind !== 'local') return false
    const state = this.live.get(serverId)
    if (state === undefined) return false
    if (state.expiresAt <= this.now()) {
      this.live.delete(serverId)
      return false
    }
    return true
  }

  /** The live grant for one server, for the sentence on its page. Null when there is none. */
  state(serverId: string): GrantState | null {
    const state = this.live.get(serverId)
    if (state === undefined) return null
    if (state.expiresAt <= this.now()) {
      this.live.delete(serverId)
      return null
    }
    return { ...state }
  }

  /** Every live grant, newest first. For a settings screen that lists them. */
  list(): GrantState[] {
    this.sweep()
    return [...this.live.values()].sort((a, b) => b.grantedAt - a.grantedAt).map((state) => ({ ...state }))
  }

  /** Drop everything that has run out. Called on the paths that read the map. */
  private sweep(): void {
    const at = this.now()
    for (const [id, state] of this.live) {
      if (state.expiresAt <= at) this.live.delete(id)
    }
  }
}
