/**
 * Which bearer token means which caller.
 *
 * ## Why the caller is carried by the token and by nothing else
 *
 * `deck-control` is one loopback socket serving several agents at once: the
 * copilot the person is talking to at the desk, a routine firing at 03:00, and —
 * once remote copilot access exists — one Claude CLI run per paired device that
 * has been granted `act`. They reach the same tools over the same port, and they
 * must not have the same powers.
 *
 * Which of them is asking is therefore a security property, and a security
 * property has to be carried by something the caller cannot choose for itself.
 * `server.ts` settled that for the first split — attended versus unattended —
 * and the argument generalises unchanged:
 *
 * > The alternative — a header the caller sets — was rejected for the obvious
 * > reason: an unattended caller that wanted the attended path would simply not
 * > send it, and a flag a caller can drop is not a boundary.
 *
 * So it is the *token*. Each one is 32 random bytes, minted by this process,
 * written into exactly one MCP config file through `remote/secret-file.ts`, and
 * handed to exactly one agent. A run that somehow read another run's config file
 * would be a run that had read another agent's private directory, which is a
 * different and much louder problem than an impersonation.
 *
 * ## The entry stores a device id, never a grant
 *
 * {@link TokenGrant.caller} is a **function**, and that is the single most
 * load-bearing decision in this file. Storing the tiers a device held when its
 * run started would freeze them there: a person unticking "Ask it to work" in
 * Settings would be editing a store that the live run no longer consults, and
 * the grant would not actually change anything until the phone reconnected — a
 * permission control that changes nothing, which is the exact defect
 * `reachable.test.ts` warns about in its `copilot-access.ts` entry.
 *
 * Calling `grants.granted(deviceId)` per request is what makes an untick land on
 * the *next tool call*. It is the same property `folders()` has for `create`, and
 * it is why `remoteCopilotCaller` exists as one function rather than as a
 * hand-assembled `Caller`.
 *
 * ## Comparison is constant-time and has no early exit
 *
 * `server.ts` already ran both of its two comparisons whichever matched, and
 * said why: short-circuiting would make "this is the attended token" measurably
 * faster to discover than "this is the other one". With a handful of tokens the
 * argument is the same and the stakes are slightly higher — the extra entries
 * are per-device, so a timing difference would leak *which device* a guess was
 * close to. Every entry is compared, every time, and the loop below deliberately
 * does not `break`.
 *
 * A handful is genuinely a handful: two fixed tokens plus at most one run per
 * paired device, and `MAX_DEVICES` in the trust store is 64. Sixty-six
 * constant-time comparisons of 64 bytes is microseconds against a tool call that
 * is about to read a transcript off a disk.
 */

import { timingSafeEqual } from 'node:crypto'
import type { Caller } from './surface'

/** What one token authorises. */
export interface TokenGrant {
  /**
   * Is there a person who could answer a confirmation for a call on this token?
   *
   * True for the copilot at the desk and for a phone's run — see
   * `COPILOT-REMOTE.md` §4.3 for why a phone-originated turn is attended by a
   * wider margin than most desktop ones: there is demonstrably a person, they
   * sent a message seconds ago, and they are holding a device that can display a
   * prompt. It is false for exactly one caller, the routine engine, which cannot
   * be asked anything at all.
   *
   * That the flag is currently unobservable for a phone — every alter call from
   * one is refused a check earlier, at the tier — is not a reason to set it
   * false. A lie parked in the code waiting for the day a fourth tier makes it
   * matter is worse than a fact nothing reads.
   */
  attended: boolean
  /**
   * Who this is, resolved **now**.
   *
   * A function rather than a value; see the header. It must not throw — it runs
   * on the request path of a live tool call — and the implementations that read a
   * grant store return "nothing granted" for a device the store has never heard
   * of, which is the same answer a revoked device gets.
   */
  caller(): Caller
  /**
   * The only tool ids this token may see or call, or absent for the whole
   * catalogue.
   *
   * ## Why the list travels with the token
   *
   * Asad said two things on one page of the 2026-08-21 review that pull in
   * opposite directions, and both are requirements:
   *
   *   > *"driving other browsers should be for all of the sessions, regardless
   *   > of even they are Commander, they are not Commander, they are from remote
   *   > channel, they are from server."*
   *
   *   > *"Driving tool is only for commanders, and it should not be with for the
   *   > other sessions, and they should not be able to find it also."*
   *
   * So an ordinary session gets the browser verbs and must not get — or be able
   * to *discover* — `sessions.start`, `sessions.send`, `report` or `brief`. A
   * tier cannot express that: those tools sit at the same tiers the browser ones
   * do. A per-tool gate written inside each tool could, and would be twenty
   * places to keep in step, with the one that gets forgotten being the one
   * nobody is looking at.
   *
   * So it is a positive list, carried by the same thing that already carries who
   * the caller is, and enforced in the one place every token-bearing call passes
   * through — `createMcpServer` in `server.ts`, at both `tools/list` and
   * `tools/call`. Listing and calling are gated by the same set on purpose: a
   * tool that were merely hidden would still answer if its name were guessed,
   * and "should not be able to find it" is a weaker property than "cannot use
   * it", not a stronger one.
   *
   * Both ids and wire names are accepted in the set, so a caller cannot get past
   * it by spelling `sessions.send` the other way. See `sessionToolAllowList`.
   *
   * Absent means the whole catalogue, which is what the copilot, the routine
   * runner and a granted device have always had.
   */
  tools?: ReadonlySet<string>
  /**
   * Aborted when whoever this token belongs to goes away.
   *
   * Handed to `DeckControl.call`, which hands it to the consent broker, which
   * resolves an outstanding question as `caller-gone`. That reason exists for
   * precisely this and says so: *"if that timeout fires first the client stops
   * listening — and if the person then clicked Allow, the change would land while
   * the model had already been told the call failed."* The same hole, one
   * transport further out: a phone that drops its relay channel mid-call must not
   * leave a dialog on the desktop whose approval nobody is waiting for.
   *
   * Absent for the two fixed tokens. The copilot at the desk hangs up by closing
   * the HTTP request, which the SDK already turns into an abort.
   */
  signal?: AbortSignal
}

/**
 * The tokens this run has minted, and what each of them means.
 *
 * Not a module-level singleton, unlike the server it serves: it is constructed
 * with the endpoint and dies with it, so a token from a previous run cannot
 * survive into the next one even in memory. `server.ts` already regenerates its
 * two fixed tokens per start for the same reason.
 */
export class CallerTable {
  private readonly entries = new Map<string, TokenGrant>()

  /**
   * Register a token. Replacing an existing one is legal and is what a restart
   * of a device's run does.
   *
   * Refuses an empty token outright rather than storing it, because an empty
   * string compares equal to an absent header stripped of its `Bearer ` prefix,
   * and a bug that produced one would open the socket to anything.
   */
  set(token: string, grant: TokenGrant): void {
    if (typeof token !== 'string' || token.length === 0) {
      throw new Error('deck-control: refusing to register an empty token')
    }
    this.entries.set(token, grant)
  }

  /** Drop a token. Returns whether there was one — a revoke wants to know. */
  delete(token: string): boolean {
    return this.entries.delete(token)
  }

  /** How many tokens are live. For diagnostics and for the tests. */
  get size(): number {
    return this.entries.size
  }

  /**
   * What this `Authorization` header authorises, or null.
   *
   * Every entry is compared whichever one matches. See the header: an early
   * `break` would turn "how far down the table is your token" into a measurable
   * quantity, and the table is ordered by which device paired first.
   *
   * The length mismatch is handled the way `hook-server.ts` handles it and for
   * the same reason — `timingSafeEqual` throws on unequal lengths, so comparing
   * raw buffers would make "wrong length" a faster answer than "wrong bytes".
   */
  match(header: unknown): TokenGrant | null {
    if (typeof header !== 'string') return null
    const offered = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : header
    if (offered.length === 0) return null
    const a = Buffer.from(offered)
    let found: TokenGrant | null = null
    for (const [token, grant] of this.entries) {
      const b = Buffer.from(token)
      if (a.length !== b.length) {
        // Spend the same work on a length mismatch as on a byte mismatch.
        timingSafeEqual(b, b)
        continue
      }
      // No `break`, and no `||=` short-circuit either: the comparison runs for
      // every entry and the *first* match is kept. First rather than last so
      // that a duplicate token — which `set` makes impossible, but which a
      // future bulk loader could produce — resolves deterministically.
      if (timingSafeEqual(a, b) && found === null) found = grant
    }
    return found
  }
}
