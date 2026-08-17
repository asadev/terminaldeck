/**
 * The alter-tier gate: a real question, put to a real person, that defaults to
 * no.
 *
 * ## What "real" has to mean here
 *
 * A permission prompt that auto-approves when the UI is not ready is worse than
 * no prompt at all, because it *reads* as protection. Everything below is
 * arranged so that the only path to `granted: true` is a human answering yes,
 * and every other path — no window, a window that never answers, a window that
 * closes mid-question, a shutdown, too many questions at once — resolves to a
 * refusal with a reason attached.
 *
 * There is deliberately no "allow always", no remembered decision and no
 * bypass. Those are product features that can be added later on purpose, with
 * their own storage and their own audit rows. Adding them now, as a convenience
 * inside the mechanism, is how a gate quietly becomes a formality.
 *
 * ## The question a routine raises, and the answer for now
 *
 * A routine cannot answer a dialog, so an alter-tier call from one is refused
 * outright — `not-permitted-unattended`, in `control.ts`. That is correct and it
 * is also a real limit: a person who writes *"every morning, stop any session
 * that has been idle twelve hours"* has stated the decision plainly, in advance,
 * in writing, and the app answers by refusing to do it. The obvious repair is to
 * let a routine carry a **pre-authorisation**: at authoring time, with the person
 * looking at the routine they are creating, they consent once to a named action
 * that routine may take unattended.
 *
 * That is genuinely different from the "allow always" refused above. Allow-always
 * is unscoped in what, when and who; it is answered in the middle of being
 * interrupted, which is the worst moment a person is ever asked anything. A
 * pre-authorisation is scoped to one routine, decided while composing that
 * routine rather than while being blocked by it, and revoked by changing the
 * routine. It is closer to a `sudoers` line than to a checkbox on a dialog.
 *
 * **The recommendation is still: not yet, and not in the routine file.** Three
 * things have to be true before it is worth building, and none of them is today.
 *
 *  1. *Nothing is actually blocked by its absence.* The alter tier currently
 *     holds `settings.write` and stopping a session the copilot did not start —
 *     neither of which any of the default routines wants to do unattended. Every
 *     routine worth shipping is read-plus-act: report the blocked agent, read the
 *     tail, summarise the diff. A grant mechanism whose first user does not exist
 *     yet is a mechanism designed against a guess.
 *  2. *Consent has to be an act, not a file edit.* If the grant is a line in the
 *     routine's own Markdown — `allow: sessions.stop` — then whoever can write
 *     that file can grant it, and the value of being able to write a routine file
 *     goes up sharply the moment one can carry permissions. That is the hole that
 *     was just closed by moving the folder outside the copilot's boundary, put
 *     back one level up. The grant must live in its own store, be written only by
 *     a confirmed action, and be keyed to a hash of the routine's triggers,
 *     folder and prompt so that editing the routine revokes it.
 *  3. *The unit has to be an argument shape, not a tool.* "May call
 *     `sessions.stop`" authorises stopping anything, which is not what anyone
 *     means. "May stop a session this routine itself started" is the useful
 *     grant, and it is a predicate over arguments. `control.ts` already reads
 *     arguments to decide a tier — but only ever *upwards*, by design, so a
 *     mistake costs a dialog rather than losing one. A downward move is new
 *     machinery and has to be a small closed set of predicates written in code,
 *     never a string out of a file.
 *
 * And there is a cheaper thing to build first that may remove the need entirely:
 * let the routine **report and offer**. A morning digest that ends "three
 * sessions look stuck — stop them?" with one button gets most of the value, needs
 * none of this, and puts the decision in front of a person who is awake. Build
 * that, and see whether anybody still wants the grant.
 *
 * If it is ever built, the constraints are the ones this file already states,
 * plus: every use writes its own action-log row naming the grant it spent, so
 * "allowed by a standing grant" never reads the same as "allowed by the person";
 * grants expire and are listed in Settings with one-click revoke; and a grant is
 * never obtainable from a paired device, matching the rule that `alter` is not
 * remotely grantable at all.
 *
 * ## Why the broker does not know what a window is
 *
 * Delivery is a callback. The broker holds the pending questions, the clock and
 * the refusal rules; `index.ts` owns the fact that the answer comes from a
 * particular `WebContents` and that no other sender may answer. Keeping those
 * apart is what lets the default-deny behaviour be tested without Electron —
 * which matters, because the whole point of this file is behaviour under
 * conditions the app is not in.
 *
 * ## The three ways a question dies unanswered
 *
 * `timeout` is the ordinary one: the person stepped away. `approver-gone` is
 * the window closing, and it is resolved *immediately* rather than left to time
 * out — a question nobody can see must not hold a tool call open for two
 * minutes. `shutting-down` is quit, and it fires before the app tears anything
 * down so an in-flight alter call cannot land halfway through a teardown.
 */

import { randomUUID } from 'node:crypto'
import type { RefusalReason, Tier } from './surface'

/* -------------------------------------------------------------- constants -- */

/**
 * How long a question stays on screen before it is refused.
 *
 * Two minutes. Long enough to read a dialog, notice what it is asking and think
 * about it; short enough that a copilot call does not hang for the rest of the
 * afternoon because somebody went to lunch. The tool call is genuinely blocked
 * for this whole window — that is the point — so the MCP client's own call
 * timeout has to be longer than this, which is why `server.ts` states the
 * relationship rather than leaving the two numbers to drift.
 */
export const DEFAULT_CONSENT_TIMEOUT_MS = 120_000

/**
 * How many questions may be outstanding at once.
 *
 * Three. Not a resource limit — it is an anti-fatigue limit. An agent in a loop
 * can emit alter calls as fast as the transport allows, and a person facing a
 * stack of forty identical dialogs will clear them by reflex, which is exactly
 * the state in which a permission system stops working. Past the cap the extra
 * calls are refused outright with `too-many-pending`, which is loud, logged,
 * and cannot be mistaken for approval.
 */
export const DEFAULT_MAX_PENDING = 3

/* ------------------------------------------------------------------ types -- */

/** The question, as it reaches a window and as it is written to the log. */
export interface ConsentRequest {
  id: string
  /** Canonical tool id, e.g. `settings.write`. */
  tool: string
  tier: Tier
  /** One sentence naming what will happen if this is approved. */
  summary: string
  /** The arguments, already scrubbed for display. */
  args: Record<string, unknown>
  requestedAt: number
  /** When this question refuses itself. Lets a dialog show a countdown. */
  expiresAt: number
}

export interface ConsentGranted {
  granted: true
  by: string
  at: number
}

export interface ConsentDenied {
  granted: false
  reason: RefusalReason
  by: string | null
  at: number
}

export type ConsentOutcome = ConsentGranted | ConsentDenied

export interface ConsentBrokerOptions {
  /** Deliver the question. Return false when there is nobody to deliver it to. */
  ask(request: ConsentRequest): boolean
  /** Told when a question stops being live, so a dialog can dismiss itself. */
  settled?(id: string, outcome: ConsentOutcome): void
  timeoutMs?: number
  maxPending?: number
  now?: () => number
}

interface Pending {
  request: ConsentRequest
  resolve(outcome: ConsentOutcome): void
  timer: ReturnType<typeof setTimeout> | null
}

/* ----------------------------------------------------------------- broker -- */

export class ConsentBroker {
  private readonly pending = new Map<string, Pending>()
  private readonly timeoutMs: number
  private readonly maxPending: number
  private readonly now: () => number
  private stopped = false

  constructor(private readonly options: ConsentBrokerOptions) {
    // `Math.max(…, 1)`: a zero or negative timeout would make `setTimeout` fire
    // on the next tick, refusing every question before it could be drawn — a
    // configuration mistake that would look exactly like a working gate that
    // nobody can ever pass.
    this.timeoutMs = Math.max(Math.trunc(options.timeoutMs ?? DEFAULT_CONSENT_TIMEOUT_MS), 1)
    this.maxPending = Math.max(Math.trunc(options.maxPending ?? DEFAULT_MAX_PENDING), 1)
    this.now = options.now ?? Date.now
  }

  /** Questions currently on screen, for a window that opened mid-flight. */
  list(): ConsentRequest[] {
    return [...this.pending.values()].map((entry) => entry.request)
  }

  /**
   * Ask, and wait.
   *
   * The returned promise is what the tool call blocks on, and it resolves
   * exactly once by every route. There is no rejection path: a refusal is an
   * outcome the caller has to record, not an exception it might forget to
   * catch.
   */
  async request(input: {
    tool: string
    tier: Tier
    summary: string
    args: Record<string, unknown>
    /** Aborted when the caller hangs up. Closes the question rather than the deal. */
    signal?: AbortSignal
  }): Promise<ConsentOutcome> {
    const at = this.now()
    if (this.stopped) return { granted: false, reason: 'shutting-down', by: null, at }
    if (input.signal?.aborted === true) {
      return { granted: false, reason: 'caller-gone', by: null, at }
    }
    if (this.pending.size >= this.maxPending) {
      return { granted: false, reason: 'too-many-pending', by: null, at }
    }

    const request: ConsentRequest = {
      id: randomUUID(),
      tool: input.tool,
      tier: input.tier,
      summary: input.summary,
      args: input.args,
      requestedAt: at,
      expiresAt: at + this.timeoutMs,
    }

    /*
     * Registered *before* delivery, and that ordering is load-bearing.
     *
     * `ask` runs synchronously and can answer synchronously in principle — a
     * test harness does, and so would any future in-process approver. If the
     * entry were added after the call, that answer would arrive for an id the
     * map has never heard of, be dropped, and the question would then sit until
     * it timed out. Registering first makes an immediate answer work and costs
     * nothing, because a failed delivery is undone on the next line.
     */
    let settle: ((outcome: ConsentOutcome) => void) | null = null
    const answer = new Promise<ConsentOutcome>((resolve) => {
      settle = resolve
    })
    const entry: Pending = {
      request,
      resolve: (outcome) => settle?.(outcome),
      timer: null,
    }
    this.pending.set(request.id, entry)

    let delivered = false
    try {
      delivered = this.options.ask(request) === true
    } catch (error) {
      // A delivery callback that throws is a broken approver, which is the same
      // situation as no approver: nobody saw the question.
      console.error('[deck-control] could not deliver a consent request:', error)
      delivered = false
    }

    if (!delivered) {
      this.pending.delete(request.id)
      return { granted: false, reason: 'no-approver', by: null, at: this.now() }
    }

    entry.timer = setTimeout(() => {
      this.finish(request.id, { granted: false, reason: 'timeout', by: null, at: this.now() })
    }, this.timeoutMs)
    // Vitest keeps the event loop alive for a pending timer, so a suite that
    // exercised a long timeout would hang after its assertions passed.
    entry.timer.unref?.()

    /*
     * The caller hanging up closes the question.
     *
     * `once: true` and no explicit removal: the listener is on a signal that
     * belongs to a single tool call and is discarded with it, so there is
     * nothing to leak. Registered after the timer so that an already-aborted
     * signal — checked at the top — cannot reach here with a live entry behind
     * it.
     */
    input.signal?.addEventListener(
      'abort',
      () => {
        this.finish(request.id, { granted: false, reason: 'caller-gone', by: null, at: this.now() })
      },
      { once: true },
    )

    return answer
  }

  /**
   * A person answered.
   *
   * Returns false when the id is unknown — already timed out, already answered,
   * or never existed. The caller reports that back so a stale dialog can tell
   * the user their answer arrived too late, rather than silently appearing to
   * have worked.
   *
   * Verifying that the *sender* is allowed to answer is not done here: the
   * broker has no notion of a window. `index.ts` checks it before calling, and
   * that check is the one that matters — anything else in the process could
   * call this method, and anything else in the process could equally well call
   * the tool directly.
   */
  respond(id: string, approved: boolean, by: string): boolean {
    const entry = this.pending.get(id)
    if (!entry) return false
    const at = this.now()
    this.finish(
      id,
      approved ? { granted: true, by, at } : { granted: false, reason: 'declined', by, at },
    )
    return true
  }

  /**
   * The window that was being asked has gone.
   *
   * Every outstanding question is refused at once. Waiting for the timeout
   * instead would block a tool call for two minutes on an answer that can no
   * longer arrive, and — worse — would leave a window that reopened in the
   * meantime able to answer a question it never saw asked.
   */
  approverGone(): void {
    for (const id of [...this.pending.keys()]) {
      this.finish(id, { granted: false, reason: 'approver-gone', by: null, at: this.now() })
    }
  }

  /** Quit. Everything outstanding is refused and nothing new is accepted. */
  stop(): void {
    this.stopped = true
    for (const id of [...this.pending.keys()]) {
      this.finish(id, { granted: false, reason: 'shutting-down', by: null, at: this.now() })
    }
  }

  private finish(id: string, outcome: ConsentOutcome): void {
    const entry = this.pending.get(id)
    if (!entry) return
    this.pending.delete(id)
    if (entry.timer) clearTimeout(entry.timer)
    entry.resolve(outcome)
    try {
      this.options.settled?.(id, outcome)
    } catch (error) {
      // Telling the UI a question closed must never fail the call that was
      // waiting on it — by this point the answer has already been delivered.
      console.error('[deck-control] a consent subscriber threw:', error)
    }
  }
}
