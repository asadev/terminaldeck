/**
 * The dispatcher: the one path a copilot tool call can take.
 *
 * Six steps, in this order, and the order is the design:
 *
 *  1. **Find the tool.** An unknown name is an error, not a silent no-op.
 *  2. **Check the arguments** against the schema the tool advertised, then
 *     against its own precheck. The schema is a hint to a language model *and*
 *     a boundary here — the two used to be different documents, which is how a
 *     `browser_step` carrying `text` instead of `value` typed nothing and
 *     reported success. See `schema.ts`.
 *  3. **Decide the tier**, taking the higher of the catalogue's declared tier
 *     and whatever the tool's own escalation rule says about *these* arguments.
 *  4. **Spend from a budget**, so a loop cannot become a bill or a flood of
 *     dialogs.
 *  5. **Ask a human, if the tier says so**, and refuse unless one says yes.
 *  6. **Run it.**
 *
 * And then, whatever happened at any of those steps, exactly one row is written
 * to `log/actions.jsonl`. The append is in a `finally`, so the shortest path to
 * "acted without leaving a record" runs through a process crash.
 *
 * ## Why the gate lives here and not in the transport
 *
 * `server.ts` is HTTP and JSON-RPC and nothing else. If the tier check sat
 * there, a second way in — a future in-process copilot, a routine engine
 * calling the same tools without a socket — would arrive with no gate on it and
 * nobody would notice until it had already shipped. Everything that wants to
 * call a deck-control tool calls {@link DeckControl.call}, and there is no
 * lower door.
 *
 * ## What "the copilot's own session" means, and its honest limit
 *
 * `sessions.send` and `sessions.stop` are ordinary actions against a session
 * the copilot started and confirmed actions against one it did not. The set of
 * ids it started is held in memory, for this run only. That is deliberate and
 * it fails in the safe direction: after a restart the copilot's own sessions
 * are no longer recognised as its own, so acting on them asks first. The
 * opposite mistake — a persisted list that outlives the sessions and gets
 * matched against a recycled id — would silently *widen* what may be done
 * without asking, and there is no version of that worth having for the
 * convenience it buys.
 *
 * `COPILOT-DESIGN.md` puts an `origin: 'copilot'` field on session metadata in
 * phase 3. When that lands this set becomes a cache of it rather than the truth.
 */

import { randomUUID } from 'node:crypto'
import type { ActionLog, ActionOutcome, ActionRow, ConfirmationRecord } from './action-log'
import { scrubArgs } from './action-log'
import {
  BadArgument,
  buildCatalogue,
  catalogueCost,
  type CatalogueCost,
  type ToolContext,
  type ToolSpec,
} from './catalogue'
import { WINDOW_SURFACE, deviceSurface, type ConsentBroker } from './consent'
import { checkToolArgs } from './schema'
import {
  LOCAL_CALLER,
  Refused,
  TIER_RANK,
  type Caller,
  type DeckSurface,
  type RefusalReason,
  type Tier,
} from './surface'

/* --------------------------------------------------------------- budgets -- */

export interface Budget {
  /** How many calls may be made inside `windowMs`. */
  limit: number
  windowMs: number
}

export interface Budgets {
  /**
   * Everything, including reads.
   *
   * Reads are cheap for the copilot and not cheap for this process:
   * `alerts.list` parses forty transcripts and shells out to git. A model in a
   * retry loop can emit these faster than the main process can answer them, and
   * the main process is also the thing drawing the window.
   */
  all: Budget
  /**
   * Act and alter together.
   *
   * Anything that changes state. Thirty in five minutes is far more than a
   * conversation produces and far less than a loop does.
   */
  changes: Budget
  /**
   * Starting sessions, specifically.
   *
   * This is the tool that spends money without a dialog in front of it, so it
   * gets the tightest budget in the file. Five sessions in ten minutes is more
   * than anybody asks for on purpose.
   */
  sessionStarts: Budget
}

export const DEFAULT_BUDGETS: Budgets = {
  all: { limit: 240, windowMs: 60_000 },
  changes: { limit: 30, windowMs: 300_000 },
  sessionStarts: { limit: 5, windowMs: 600_000 },
}

/**
 * A plain sliding window over timestamps.
 *
 * Not a token bucket: a bucket refills smoothly and lets a caller sustain the
 * average forever, which is precisely the runaway-loop shape being guarded
 * against. A window says "thirty in the last five minutes" and means it.
 */
class Window {
  private readonly hits: number[] = []

  constructor(private readonly budget: Budget) {}

  /** True when there was room and the hit was taken. */
  take(now: number): boolean {
    const cutoff = now - this.budget.windowMs
    while (this.hits.length > 0 && this.hits[0] <= cutoff) this.hits.shift()
    if (this.hits.length >= this.budget.limit) return false
    this.hits.push(now)
    return true
  }
}

/* ----------------------------------------------------------------- result -- */

/**
 * Who is calling, as far as the gate needs to know.
 *
 * An object rather than the bare `AbortSignal` it replaced. Three things now
 * travel with a call — whether the caller can be interrupted, whether it hung
 * up, and which tiers it was granted — and three positional arguments is how one
 * of them ends up in the wrong slot, silently, with the permissive value.
 */
export interface CallOptions {
  /** Aborted when the caller hangs up. Cancels a confirmation in flight. */
  signal?: AbortSignal
  /**
   * Is there a person who could answer a confirmation for this call?
   *
   * Defaults to true, which is the honest answer for the only caller that
   * exists: `server.ts` serving the pinned copilot session, which a person is
   * looking at. False means *nobody is at the machine* — a routine at 03:00 —
   * and every alter-tier call is refused immediately with
   * `not-permitted-unattended` rather than put to a broker that can only time
   * out. See that reason in `surface.ts` for the failure it comes from.
   *
   * A defaulted boolean rather than a required one, and the default is the
   * permissive value, so it is worth saying why that is not a footgun: no caller
   * is expected to pass this by hand. The unattended path is reached through
   * {@link DeckControl.unattended}, which hands out a caller that cannot say
   * anything else — the routine engine holds that object and never holds this
   * class, so there is no site at which somebody could forget.
   */
  attended?: boolean
  /**
   * Whose call this is, and which tiers they were granted.
   *
   * Defaults to {@link LOCAL_CALLER} — the copilot session on this machine,
   * which may reach all three tiers and is held by the confirmation gate exactly
   * as before. Anything arriving from off this machine must construct its own,
   * and constructing one means having answered "was this device granted `act`?"
   * before the call rather than after it.
   *
   * Two tiers of defence, deliberately. The transport decides whether to build a
   * caller at all; this decides what that caller may do. `COPILOT-CAPABILITIES.md`
   * item 5 is the argument for the second one — a surface that is granted whole
   * is a surface where "my phone can ask a question" and "my phone can stop my
   * work" are one switch.
   */
  caller?: Caller
}

/**
 * A narrowed door onto {@link DeckControl.call}, with the caller's nature baked
 * in.
 *
 * The routine engine takes one of these rather than a `DeckControl`. That is the
 * difference between "the runner must remember to pass `attended: false`" — a
 * contract in a comment, which is the kind this repository has watched decay —
 * and a runner that could not pass anything else if it tried.
 */
export interface ToolCaller {
  call(name: string, args: unknown, signal?: AbortSignal): Promise<CallResult>
}

export interface CallResult {
  ok: boolean
  /** The tool's value on success, otherwise null. */
  value: unknown
  /** The sentence the model sees when `ok` is false. */
  error: string | null
  /** Set when a rule stopped the call rather than a fault. */
  refusal: RefusalReason | null
  /** The row that was written. Handed back so a UI can show it without a re-read. */
  row: ActionRow
}

/* ---------------------------------------------------------------- control -- */

export interface DeckControlOptions {
  surface: DeckSurface
  log: ActionLog
  consent: ConsentBroker
  /**
   * Tools contributed by another feature, held to the same rules.
   *
   * The module comment above claims there is no lower door than
   * {@link DeckControl.call}. A closed catalogue would make that claim false
   * for the next feature that wants to give the copilot a capability — it would
   * have to stand up its own tier check, its own confirmation and its own log,
   * and the second copy is the one that gets the ordering wrong. (The first
   * copy got it wrong too: see the `precheck` comment below.)
   *
   * A contributed tool is not special. It declares a tier, it can escalate, it
   * is prechecked, budgeted, gated and logged exactly like the eleven in
   * `catalogue.ts`. What it may not do is collide with them; `DeckControl`
   * refuses a duplicate id rather than letting one shadow the other.
   *
   * `tour.play` is the first thing that passes it — `deck-control/index.ts`
   * builds a `TourStage` and hands `tourTool(stage)` in here rather than adding
   * a fifteenth entry to `catalogue.ts`, because the tool is a closure over that
   * stage and a catalogue built by a parameterless function has nowhere to put
   * one. The routine engine is the obvious next caller: `RoutineApi` already
   * annotates each of its methods with the tier it wants, and it should reach
   * the copilot through here rather than beside it.
   */
  extraTools?: readonly ToolSpec[]
  budgets?: Partial<Budgets>
  now?: () => number
  /**
   * Is the copilot driving the screen right now?
   *
   * A function rather than a boolean because it is asked per call and the answer
   * changes several times a minute while a tour plays. Absent means "this
   * assembly has no driving mode", which answers no — a host with no window to
   * drive cannot be mid-tour.
   *
   * See the gate in {@link DeckControl.call} for why this exists at all. The
   * short version: while driving, the person's model of cause and effect is
   * suspended, so a change made in that window is one they cannot attribute.
   */
  driving?(): boolean
  /** Called with every row as it is written, for the Activity pane. */
  onRow?(row: ActionRow): void
}

/**
 * Tools that may not run while a tour is playing.
 *
 * Named rather than derived from the tier, and the difference matters. `read` is
 * fine while driving — answering "what is that session doing" changes nothing
 * about the screen — and it is not the tier that makes a call dangerous here, it
 * is whether the person could tell afterwards that it happened.
 *
 * The argument for this being a mechanism and not a sentence in an instruction
 * file: **while driving, the user's model of cause and effect is suspended.**
 * Things are moving that they did not do. Anything the copilot changes in that
 * window is a change they cannot attribute — they will not know whether the
 * session that just went quiet did so because of the tour, because of the
 * copilot, or on its own. `COPILOT-CAPABILITIES.md` §3.2 item 9 says the same
 * about delegation in general, and gives the same reason for enforcing it in
 * tool policy: the prose version was tried twice and broken both times.
 *
 * Matched by prefix as well as by exact id, so a `routines.*` tool added later
 * is covered on the day it lands rather than on the day somebody remembers this
 * list. `tour.play` itself is on it: two tours on one screen is not a state a
 * person can watch, and the stage refuses it anyway — this is the outer of the
 * two, so the refusal reads as a rule rather than as a race.
 */
export const NOT_WHILE_DRIVING: readonly string[] = [
  'sessions.send',
  'sessions.start',
  'sessions.stop',
  'settings.write',
  'tour.play',
  'routines.',
]

export function refusedWhileDriving(toolId: string): boolean {
  return NOT_WHILE_DRIVING.some((entry) =>
    entry.endsWith('.') ? toolId.startsWith(entry) : toolId === entry,
  )
}

export class DeckControl {
  private readonly specs: Map<string, ToolSpec>
  private readonly catalogue: ToolSpec[]
  private readonly started = new Set<string>()
  private readonly windows: { all: Window; changes: Window; sessionStarts: Window }
  private readonly now: () => number

  constructor(private readonly options: DeckControlOptions) {
    this.catalogue = [...buildCatalogue(), ...(options.extraTools ?? [])]
    this.specs = new Map()
    for (const spec of this.catalogue) {
      // A contributed tool that reused a built-in's name would shadow it
      // silently, and the shadowed one might be the stricter of the two.
      if (this.specs.has(spec.id) || this.specs.has(spec.wire)) {
        throw new Error(`deck-control: two tools are called ${spec.id}`)
      }
      // Both spellings resolve to the same tool: the wire name is what a client
      // calls, the dotted id is what a person or a log entry names. Registering
      // both means a hand-written call in a test or a routine file does not
      // have to know which form it is holding.
      this.specs.set(spec.wire, spec)
      this.specs.set(spec.id, spec)
    }
    const budgets: Budgets = {
      all: options.budgets?.all ?? DEFAULT_BUDGETS.all,
      changes: options.budgets?.changes ?? DEFAULT_BUDGETS.changes,
      sessionStarts: options.budgets?.sessionStarts ?? DEFAULT_BUDGETS.sessionStarts,
    }
    this.windows = {
      all: new Window(budgets.all),
      changes: new Window(budgets.changes),
      sessionStarts: new Window(budgets.sessionStarts),
    }
    this.now = options.now ?? Date.now
  }

  /** The catalogue, for `tools/list`. */
  tools(): readonly ToolSpec[] {
    return this.catalogue
  }

  /** Sessions this run's copilot started. Exposed for the status channel. */
  copilotSessions(): string[] {
    return [...this.started]
  }

  private context(callId: string, caller: Caller, attended: boolean): ToolContext {
    return {
      surface: this.options.surface,
      /*
       * Passed down, not kept private, and only one tool reads it: `tour.play`.
       *
       * The dispatcher's own use of `attended` is the alter-tier refusal below —
       * "there is nobody who could answer a dialog". A tool can need the same
       * fact for a different reason, and driving does: it needs somebody to
       * *watch*, not somebody to approve. See `ToolContext.attended`.
       */
      attended,
      /*
       * Handed down rather than kept to this class, and the split is stated on
       * `ToolContext.caller`: the *tier* is checked here and nowhere else, and
       * a tool whose **effect** widens for a remote caller narrows itself.
       *
       * The first and so far only one is `sessions.start`, whose folder rule and
       * whose spawn are both wider for a phone than that phone's own `create`
       * frame. Before this field existed there was no way for it to know, so the
       * gate said "this device holds `act`" and the tool then did something the
       * device could not have done directly.
       */
      caller,
      // The id of the row this call will write, so a tool that creates
      // something durable can point that thing back at the turn that made it.
      // `sessions.start` is the only user today; see `ToolContext.callId`.
      callId,
      startedByCopilot: (id) => this.started.has(id),
      noteStarted: (id) => {
        this.started.add(id)
      },
      // The same clock the budget windows use, so a test that freezes time
      // freezes the "blocked for 40 minutes" a session view reports as well.
      now: this.now,
    }
  }

  /**
   * What this catalogue costs the copilot in context, every turn.
   *
   * Measured over the assembled list — built-ins plus anything contributed
   * through `extraTools` — because the contributed half is the growth path
   * nobody is watching. Exposed rather than kept private so the status channel
   * can show it: a budget nobody can read is a budget that is discovered when it
   * has already been spent. See {@link MAX_CATALOGUE_TOKENS}.
   */
  cost(): CatalogueCost {
    return catalogueCost(this.catalogue)
  }

  /**
   * Run one tool call, all the way through.
   *
   * Never rejects. Every failure — a bad name, a bad argument, a refusal, a
   * handler that threw — comes back as a `CallResult` with `ok: false`, because
   * the caller's job is to turn this into an MCP result and a thrown exception
   * there is a protocol error rather than a tool error. The distinction matters
   * to the model on the other end: a tool error is something it can read and
   * respond to, a protocol error is something it can only retry.
   */
  /**
   * A caller for a run with nobody watching it.
   *
   * Handed to the routine engine at assembly. Every call through it is marked
   * unattended, so an alter-tier tool reached from a routine is refused at the
   * boundary instead of waiting on a dialog nobody will see. Everything else —
   * the budgets, the prechecks, the action log — is identical, because an
   * unattended run is not a lesser caller, it is a caller that cannot be asked.
   */
  unattended(): ToolCaller {
    return {
      call: (name, args, signal) =>
        this.call(name, args, { attended: false, ...(signal === undefined ? {} : { signal }) }),
    }
  }

  async call(name: string, rawArgs: unknown, options: CallOptions = {}): Promise<CallResult> {
    const { signal } = options
    const attended = options.attended !== false
    const caller = options.caller ?? LOCAL_CALLER
    const startedAt = this.now()
    const id = randomUUID()
    const args: Record<string, unknown> =
      typeof rawArgs === 'object' && rawArgs !== null && !Array.isArray(rawArgs)
        ? (rawArgs as Record<string, unknown>)
        : {}
    /*
     * What gets written down, and what a person is shown in a dialog.
     *
     * A `let` rather than a `const` because the tool's own {@link
     * ToolSpec.redactArgs} runs over it once the tool is known, a few lines
     * below — and `record` is a closure over this binding rather than over its
     * value, so a call that never resolves to a tool still logs the key-name
     * pass and nothing is left un-scrubbed on any path.
     */
    let scrubbed = scrubArgs(args)

    /*
     * Compose the row, write it, hand back the result.
     *
     * A closure rather than a method because every one of the eight exits below
     * shares the same seven captured values, and repeating them at each exit is
     * how one of them ends up with the wrong `tier` a year from now. There is no
     * `return` from this function that does not go through here — that is the
     * property the audit log depends on.
     */
    const record = (input: {
      tool: string
      tier: Tier
      baseTier?: Tier
      summary: string
      outcome: ActionOutcome
      confirmed: ConfirmationRecord
      result: Record<string, unknown> | null
      error: string | null
      refusal: RefusalReason | null
      value: unknown
    }): CallResult => {
      const sessionId = typeof args.sessionId === 'string' ? args.sessionId : undefined
      const written = this.options.log.record({
        at: new Date(startedAt).toISOString(),
        action: `tool.${input.tool}`,
        detail: detailFor(input.summary, input.outcome, input.confirmed, input.error),
        ...(sessionId === undefined ? {} : { sessionId }),
        id,
        tool: input.tool,
        tier: input.tier,
        ...(input.baseTier === undefined ? {} : { baseTier: input.baseTier }),
        args: scrubbed,
        outcome: input.outcome,
        confirmed: input.confirmed,
        // Recorded on every row, not only remote ones. "Which of these did my
        // phone do" is unanswerable from a log where local calls are unmarked
        // and remote ones are marked, because a row written before the field
        // existed looks exactly like a local one.
        caller: { kind: caller.kind, ...(caller.deviceId === undefined ? {} : { deviceId: caller.deviceId }) },
        ms: this.now() - startedAt,
        result: input.result,
        error: input.error,
      })
      try {
        this.options.onRow?.(written)
      } catch (error) {
        // The Activity pane is a listener, not a participant. A window that
        // threw while being told about a row must not change what the tool
        // returned, and must not stop the row being written — it already has.
        console.error('[deck-control] an activity subscriber threw:', error)
      }
      return {
        ok: input.outcome === 'ok',
        value: input.value,
        error: input.error,
        refusal: input.refusal,
        row: written,
      }
    }

    const spec = this.specs.get(name)
    if (!spec) {
      return record({
        tool: name,
        tier: 'read',
        summary: `Call ${name}`,
        outcome: 'error',
        confirmed: unconfirmed(false),
        result: null,
        error: `there is no tool called ${name}`,
        refusal: null,
        value: null,
      })
    }

    const context = this.context(id, caller, attended)

    /*
     * The tool's own redaction, then the key-name pass, in that order.
     *
     * `scrubArgs` matches key *names* — `token`, `password`, `cookie` — which
     * is right for a tool whose secrets are named like secrets and useless for
     * one whose argument is called `value` and happens to be what somebody
     * typed into a website. `browser.step` is the first of those; see
     * {@link ToolSpec.redactArgs}.
     *
     * Wrapped, because this is the last thing between an argument and a file on
     * disk. A tool whose redaction threw would otherwise take the whole call
     * down *before* the row was written, which is the one failure mode an audit
     * log may not have — so a throw here falls back to the un-redacted
     * key-name pass and says so loudly, rather than losing the row.
     */
    if (spec.redactArgs) {
      try {
        scrubbed = scrubArgs(spec.redactArgs(args))
      } catch (error) {
        console.error(`[deck-control] ${spec.id}'s redactArgs threw; logging the plain scrub:`, error)
      }
    }

    /*
     * The sentence a person reads, built once and reused.
     *
     * It is the confirmation dialog's text when there is a dialog, and the
     * `detail` column of the log always. Built here rather than only inside the
     * gate so that a read call is described in the log with the same words a
     * write would be — "Read the transcript of session …" beats "sessions.
     * transcript ok" for anybody scrolling the Activity pane.
     */
    let summary: string
    try {
      summary = spec.summary(args, context)
    } catch {
      // A summary that cannot be built means arguments the tool will reject
      // anyway; the handler below produces the real error.
      summary = `Run ${spec.id}`
    }

    /*
     * The tier, decided before anything else runs.
     *
     * `escalate` reads the arguments, so a tool whose danger depends on its
     * target — every `sessions.*` write does — states that here rather than
     * discovering it halfway through its own handler, by which point the
     * decision would be after the action for at least one code path.
     *
     * `Math.max` over the ranks: an escalation can raise the tier and can never
     * lower it, so a mistake in a rule costs an unnecessary dialog rather than
     * a missing one.
     */
    let tier: Tier = spec.tier
    try {
      const escalated = spec.escalate?.(args, context)
      if (escalated && TIER_RANK[escalated] > TIER_RANK[tier]) tier = escalated
    } catch (error) {
      // An escalation rule that throws is looking at arguments it does not
      // understand. Treat that as the most dangerous reading of them rather
      // than as no reading at all.
      console.error('[deck-control] an escalation rule threw; assuming alter:', error)
      tier = 'alter'
    }

    const common = {
      tool: spec.id,
      tier,
      summary,
      ...(spec.tier === tier ? {} : { baseTier: spec.tier }),
    }

    /* --- was this caller ever granted this tier? -------------------------- */
    /*
     * First, ahead of everything including the global budget, because it is the
     * only check whose answer cannot change: a device that was never granted
     * `act` is not going to be granted it by waiting, by retrying, or by asking
     * a person — grants are edited on the desktop, in Settings, by hand.
     * Spending a budget slot or drawing a dialog for it would both be work done
     * on behalf of a call that was decided before it arrived.
     *
     * Checked against the tier *after* escalation, which is the load-bearing
     * detail. `sessions.send` declares `act` and escalates to `alter` when the
     * target is not the copilot's own session — so a device holding only `act`
     * can type into what the copilot started and cannot type into what the
     * person is working in. That is precisely the distinction OpenClaw's
     * GHSA-943q-mwmv-hhvh lost by gating on the tool name.
     */
    if (!caller.tiers[tier]) {
      return record({
        ...common,
        outcome: 'refused',
        confirmed: unconfirmed(false, 'not-granted'),
        result: null,
        error: notGrantedSentence(caller, spec.id, tier),
        refusal: 'not-granted',
        value: null,
      })
    }

    /* --- is a tour on the screen right now? ------------------------------- */
    /*
     * Second, straight after the grant and ahead of the budgets, and the
     * position is the same argument the grant's is: this call could never have
     * happened, so it must not spend one of the five session starts the copilot
     * gets in ten minutes. Unlike the grant, the answer *does* change — the gate
     * is lifted the frame the tour stops — which is exactly why the sentence
     * below says to wait rather than to give up.
     *
     * Ahead of the precheck too, deliberately. A refused-while-driving call has
     * not been examined and does not need to be: whatever its arguments are, it
     * is not happening now.
     */
    if (refusedWhileDriving(spec.id) && this.options.driving?.() === true) {
      return record({
        ...common,
        outcome: 'refused',
        confirmed: unconfirmed(tier === 'alter', 'not-permitted-while-driving'),
        result: null,
        error: refusalSentence('not-permitted-while-driving', spec.id),
        refusal: 'not-permitted-while-driving',
        value: null,
      })
    }

    /* --- budgets ---------------------------------------------------------- */
    const overBudget = (message: string): CallResult =>
      record({
        ...common,
        outcome: 'refused',
        confirmed: unconfirmed(tier === 'alter', 'rate-limited'),
        result: null,
        error: message,
        refusal: 'rate-limited',
        value: null,
      })

    if (!this.windows.all.take(startedAt)) {
      return overBudget('too many tool calls in the last minute; slow down and try again')
    }

    /* --- rules that no answer can unlock ---------------------------------- */
    /*
     * Before the change budgets and before the gate, and both orderings matter.
     *
     * Before the gate, because a rule the person is asked about is not a rule.
     * The first version of this ran the protected-settings check inside the
     * handler, and a call to write `remote.enabled` put a dialog on screen that
     * looked exactly like every other one — and refused it *after* somebody had
     * clicked Allow. `control.test.ts` caught that and now pins it.
     *
     * Before the change budgets, because a call that could never have happened
     * should not consume one of the five sessions the copilot may start in ten
     * minutes. The global budget above still throttles the attempt itself.
     */
    try {
      /*
       * The schema the model was handed, enforced before anything reads an
       * argument.
       *
       * Ahead of the precheck rather than inside each one, because the schema
       * is already the document that says which arguments a tool takes — it
       * crossed to the model, which is why the model believed it — and a
       * `precheck` re-stating a fraction of it is how twenty tools come to
       * enforce nineteen different subsets of their own documentation.
       *
       * The call this was written for reported success at doing nothing:
       * `browser_step` takes `value` and was passed `text`, and every layer
       * ignored the argument it did not know until the driver typed the empty
       * string it was left with. See `schema.ts`.
       */
      checkToolArgs(spec, args)
      spec.precheck?.(args, context)
    } catch (error) {
      if (error instanceof Refused) {
        return record({
          ...common,
          outcome: 'refused',
          confirmed: unconfirmed(tier === 'alter', error.reason),
          result: null,
          error: error.message,
          refusal: error.reason,
          value: null,
        })
      }
      return record({
        ...common,
        outcome: 'error',
        confirmed: unconfirmed(tier === 'alter'),
        result: null,
        error: error instanceof Error ? error.message : String(error),
        refusal: null,
        value: null,
      })
    }

    /*
     * Nobody is here to answer, so do not ask.
     *
     * Placed after the precheck and before the change budgets, and both
     * positions are arguments.
     *
     * *After the precheck*, because the two refusals say different things and
     * the more permanent one is more useful. `settings.write` on `remote.enabled`
     * is refused for everybody forever; telling a routine it was refused for
     * being unattended would suggest the same call works in the morning, and it
     * does not.
     *
     * *Before the change budgets*, for exactly the reason the precheck is: a
     * call that could not have happened must not spend one of the five session
     * starts the copilot gets in ten minutes. A routine that tries an alter tool
     * on every run would otherwise exhaust the budget for the person too.
     *
     * And before the gate, because that is the whole point — the alternative is
     * a question that can only time out, holding one of three pending slots for
     * two minutes while a person sleeps.
     */
    if (tier === 'alter' && !attended) {
      return record({
        ...common,
        outcome: 'refused',
        confirmed: unconfirmed(true, 'not-permitted-unattended'),
        result: null,
        error: refusalSentence('not-permitted-unattended', spec.id),
        refusal: 'not-permitted-unattended',
        value: null,
      })
    }

    if (tier !== 'read' && !this.windows.changes.take(startedAt)) {
      return overBudget('too many changes in the last few minutes; ask the person to act instead')
    }
    if (spec.id === 'sessions.start' && !this.windows.sessionStarts.take(startedAt)) {
      return overBudget('too many sessions started recently; each one costs money, so this is capped')
    }

    /* --- the gate --------------------------------------------------------- */
    let confirmed: ConfirmationRecord = unconfirmed(false)
    if (tier === 'alter') {
      const outcome = await this.options.consent.request({
        tool: spec.id,
        tier,
        summary,
        args: scrubbed,
        ...(signal === undefined ? {} : { signal }),
        /*
         * Which surface may answer this, besides the desktop.
         *
         * Composed here because this is the only place that holds both the
         * caller and the question. A remote caller's own copilot connection may
         * answer its own run's question and no other device's —
         * `ConsentRequest.origin` carries the rule and `consent.ts` enforces it.
         *
         * Note what this is *not*: it is not a second tier check. The tier check
         * ran above and this call would not have been reached without `alter`.
         * This decides who gets a dialog, not who is allowed to act.
         */
        origin:
          caller.kind === 'remote' && caller.deviceId !== undefined
            ? deviceSurface(caller.deviceId)
            : WINDOW_SURFACE,
      })
      if (!outcome.granted) {
        return record({
          ...common,
          outcome: 'refused',
          confirmed: {
            required: true,
            granted: false,
            by: outcome.by,
            at: outcome.at,
            reason: outcome.reason,
          },
          result: null,
          error: refusalSentence(outcome.reason, spec.id),
          refusal: outcome.reason,
          value: null,
        })
      }
      confirmed = { required: true, granted: true, by: outcome.by, at: outcome.at, reason: null }
    }

    /* --- run -------------------------------------------------------------- */
    try {
      const output = await spec.run(args, context)
      return record({
        ...common,
        outcome: 'ok',
        confirmed,
        result: output.summary,
        error: null,
        refusal: null,
        value: output.value,
      })
    } catch (error) {
      /*
       * A `Refused` thrown from inside a handler is a rule, not a fault.
       *
       * Two tools do this: `settings.write` for a protected key, and anything
       * naming a folder this app does not have open. Both are decisions the
       * handler is best placed to make — it is the one holding the argument —
       * and both have to reach the log as refusals rather than as errors, so
       * that "the copilot was told no" and "the copilot broke" stay different
       * rows.
       */
      if (error instanceof Refused) {
        return record({
          ...common,
          outcome: 'refused',
          confirmed,
          result: null,
          error: error.message,
          refusal: error.reason,
          value: null,
        })
      }
      const message =
        error instanceof BadArgument
          ? error.message
          : error instanceof Error
            ? error.message
            : String(error)
      return record({
        ...common,
        outcome: 'error',
        confirmed,
        result: null,
        error: message,
        refusal: null,
        value: null,
      })
    }
  }
}

/* ---------------------------------------------------------------- helpers -- */

function unconfirmed(required: boolean, reason: RefusalReason | null = null): ConfirmationRecord {
  return { required, granted: false, by: null, at: null, reason }
}

/**
 * The one line a person reads in the Activity pane.
 *
 * The tool's own sentence, then what became of it. `— allowed by the person` is
 * spelled out rather than left to a boolean column, because the single most
 * important thing this file has to communicate at a glance is which rows a
 * human said yes to.
 *
 * **And *where* they said it.** A confirmation answered on a paired device is
 * not the same event as one answered at this machine, and the two must never
 * read the same in a log somebody is scanning for the row they do not recognise.
 * `confirmed.by` already carries `device:<id>`; this turns it into the one word
 * that changes what a person concludes. The id itself is deliberately not in the
 * sentence — it is in the row, where a pane can resolve it to a device name, and
 * an opaque identifier in a log line is noise rather than information.
 */
function detailFor(
  summary: string,
  outcome: ActionOutcome,
  confirmed: ConfirmationRecord,
  error: string | null,
): string {
  if (outcome === 'ok') {
    if (!confirmed.granted) return `${summary} — done`
    return confirmed.by?.startsWith('device:') === true
      ? `${summary} — allowed on a connected device`
      : `${summary} — allowed by the person`
  }
  if (outcome === 'refused') {
    return `${summary} — refused${confirmed.reason ? ` (${confirmed.reason})` : ''}`
  }
  return `${summary} — failed${error ? `: ${error}` : ''}`
}

/**
 * What a caller is told when it reached for a tier it does not hold.
 *
 * Names the tier rather than the tool, and says the tools it *can* still use,
 * because the useful next move for a model here is not "try again" — it is
 * "answer the question with what you are allowed to read". A refusal that reads
 * like a transient failure produces a retry loop; one that reads like a
 * boundary produces a sentence to the user.
 *
 * The device id is deliberately not in the text. It is in the action log, where
 * the person who can act on it will see it, and putting it in a model-visible
 * string only invites the model to quote an opaque identifier at somebody.
 */
function notGrantedSentence(caller: Caller, tool: string, tier: Tier): string {
  const allowed = (['read', 'act', 'alter'] as const).filter((entry) => caller.tiers[entry])
  const has =
    allowed.length === 0
      ? 'It has not been given any copilot access at all.'
      : `It has ${allowed.join(' and ')} access only.`
  return (
    `${tool} needs ${tier} access and this device does not have it. ${has} ` +
    'Nothing was changed. This cannot be granted from here — it is a switch on the desktop, in Settings, ' +
    'so do not retry: answer with what you can already see, and say what you would need permission for.'
  )
}

/**
 * What the model is told when the gate refused it.
 *
 * Each reason gets its own sentence, because the right next move differs: a
 * decline means stop asking, a timeout means the person is away, and
 * `no-approver` means the app has no window open and the copilot should say so
 * rather than retrying into a wall.
 */
function refusalSentence(reason: RefusalReason, tool: string): string {
  switch (reason) {
    case 'declined':
      return `${tool} was not approved. Do not try it again unless you are asked to.`
    case 'timeout':
      return `${tool} needs the person at the keyboard to confirm it, and nobody answered. Tell them what you were trying to do and let them decide.`
    case 'no-approver':
      return `${tool} needs the person at the keyboard to confirm it, and there is no window open to ask. Nothing was changed.`
    case 'approver-gone':
      return `${tool} needs a confirmation, and the window closed before it was answered. Nothing was changed.`
    case 'shutting-down':
      return `${tool} was not run: the app is closing.`
    case 'caller-gone':
      return `${tool} was cancelled: the connection dropped while the confirmation was still on screen. Nothing was changed.`
    case 'too-many-pending':
      return `${tool} was refused because too many confirmations are already waiting. Finish those first.`
    case 'rate-limited':
      return `${tool} was refused: too many calls too quickly.`
    case 'not-permitted':
      return `${tool} is not permitted with those arguments.`
    case 'not-granted':
      // Reached only through `notGrantedSentence`, which knows the device and
      // the tier. This is the fallback for a reason that arrives here from
      // somewhere else, and it still has to say "do not retry".
      return `${tool} is not something this device has been given permission to do. Nothing was changed, and asking again will not help.`
    case 'not-permitted-unattended':
      // The one sentence in this switch written to stop a retry loop rather
      // than to describe a state. A routine's turn is finite and expensive, and
      // an agent told only "refused" will spend the rest of it trying variations
      // — which is precisely what OpenClaw's heartbeat did.
      return `${tool} needs a person to confirm it, and this run is a routine with nobody at the machine, so it cannot be confirmed at all. Do not retry it and do not look for another way to do it. Say in your report what you would have done and why, and leave the decision to them.`
    case 'not-permitted-while-driving':
      /*
       * The one refusal in this switch that means "later", and it has to say so
       * precisely or it produces the worst possible behaviour: a model that
       * retries in a loop for the whole length of a tour, spending the change
       * budget it will need the moment the tour ends.
       *
       * It also says *why* rather than only *no*, because the reason is the
       * thing that makes the rule make sense to whoever reads the transcript
       * afterwards — the person is watching the screen move, and a change made
       * underneath that is a change they cannot attribute to anything.
       */
      return `${tool} cannot run while a tour is playing on their screen. Things are moving that they did not do, so anything you changed now is a change they could not attribute to you or to the tour. Nothing was changed. Wait until the tour ends and ask again then — say what you are waiting to do, if it matters.`
  }
}
