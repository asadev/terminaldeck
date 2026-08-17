/**
 * "Which of these needs me?" — derived once, here, instead of by the model.
 *
 * `sessions.list` used to hand back {@link SessionStatus} raw, and that made the
 * copilot's single most valuable job — fleet triage — a reasoning problem rather
 * than a lookup. Six enum values, none of which mean what their English names
 * suggest, and the mapping is not obvious even to somebody who has read this
 * repository:
 *
 *  - `waiting` does **not** mean "waiting for you". It means an *empty prompt is
 *    on screen*. `session-activity.ts` matches `^\s*❯\s*$` for Claude and
 *    `^.*[%$#]\s*$` for a shell, so a backgrounded `zsh` that nobody has typed
 *    into for six hours is `waiting` — and so is a brand-new agent session that
 *    has never been asked anything. Neither needs a human. `alerts.ts` says the
 *    same thing in its own words, and it is the reason `blockedAlerts()` skips
 *    every status except `input`: *"a session parked at a ready prompt is just a
 *    session you are not using, and alerting on that would fire on every open
 *    tab."*
 *  - `input` is the one that means a person is being blocked on. A question is
 *    on the screen and the agent will sit there until it is answered, spending
 *    nothing and doing nothing.
 *  - `idle` means the classifier recognised nothing at all. Quiet, not calm.
 *
 * So `attention` is not a rename of any single status. It is the answer to a
 * different question — *is a human the thing this session is stopped on?* — and
 * two statuses that read as opposites (`waiting`, `idle`) give the same answer
 * to it while two that read as similar (`waiting`, `input`) do not.
 *
 * Four buckets, which are the four sentences a triage answer is made of:
 *
 * | `attention` | Means                                            | From                  |
 * |-------------|--------------------------------------------------|-----------------------|
 * | `blocked`   | Stopped until a person answers something.        | `input`               |
 * | `running`   | Working. Leave it alone.                         | `working`             |
 * | `quiet`     | Not working, not asking. Went quiet unfinished.  | `waiting`, `idle`     |
 * | `done`      | Over — the turn ended or the process is gone.    | `completed`, `exited` |
 *
 * ## Why the reason is carried and not left implicit
 *
 * `quiet` covers two genuinely different situations — an empty prompt, and a
 * screen the classifier could make nothing of — and `done` covers a clean exit
 * and a crash. Collapsing those into one word and letting the model infer the
 * rest from the raw status would put the interpretation problem back exactly
 * where this module exists to take it from. The reason names the observation;
 * the bucket names the consequence.
 *
 * ## `statusSource`, and the part that is not yet true
 *
 * A status is either a fact or an inference, and a triage answer that cannot
 * tell them apart is worth less than one that can. Today there are exactly two
 * sources and both are reported:
 *
 *  - `exit-code` — the process is gone. Not a guess.
 *  - `screen` — `ActivityTracker` fed the output to a headless emulator, waited
 *    for it to settle, and matched patterns against the viewport. A good
 *    inference, and still an inference: it reads what a person would see.
 *
 * `hooks.ts` defines `EVENT_STATUS`, which maps each provider's lifecycle
 * events to a status — a `PermissionRequest` from Claude is a *fact* that the
 * session is blocked, not a regex against a screen. It is not wired into the
 * live status map: `registerHookServer` is called in `src/main/index.ts` with no
 * `onEvent` listener, so `EVENT_STATUS` has no reader anywhere in this
 * repository. There is therefore no `hook` source to report, and inventing one
 * would be a claim about provenance that is false.
 *
 * When that is wired, this file gains a third value and the rule from
 * `COPILOT-CAPABILITIES.md` §2.1 with it: when a hook and the screen disagree,
 * the hook wins. `attention.test.ts` pins the two sources that exist so the day
 * a third appears is a day somebody edits this comment.
 */

import type { SessionStatus } from '../../shared/types'

/** What a person has to do about this session, if anything. */
export type Attention = 'blocked' | 'running' | 'quiet' | 'done'

/** The observation behind the bucket. One per distinguishable situation. */
export type AttentionReason =
  /** A question is on the screen and nothing will happen until it is answered. */
  | 'question-unanswered'
  /** Output is still arriving. */
  | 'output-streaming'
  /** An empty prompt. Ready for a person, but not asking for one. */
  | 'prompt-ready'
  /** The screen matched nothing the classifier knows. Quiet, and unexplained. */
  | 'no-output'
  /** The agent reported its turn finished; the CLI is still running. */
  | 'turn-finished'
  /** The process exited, and exited cleanly. */
  | 'process-exited'
  /** The process exited with a non-zero code. */
  | 'process-failed'

/** How the status was arrived at. See the header: there is deliberately no `hook`. */
export type StatusSource = 'exit-code' | 'screen'

export interface AttentionInput {
  status: SessionStatus
  /**
   * When the session entered {@link status}, in epoch ms, or **null** when
   * nothing knows.
   *
   * Null is not hypothetical and it is not rare — it is every exited session.
   * `src/main/index.ts` removes a session from the live-status map in its
   * `onExit` handler, and `pty-manager.ts` calls that immediately after the
   * tracker's `markExited()`, so the "exited at" timestamp is written and then
   * deleted in the same turn. The caller can therefore say *that* a session is
   * over and cannot say *when* it ended.
   *
   * The alternative was to fall back to `createdAt`, which is what the view did
   * before this field existed. For `statusSince` that is defensible; for a
   * number a model will put in a sentence it is not, because "finished six hours
   * ago" about a session that died a minute ago is worse than saying nothing.
   */
  statusSince: number | null
  exitCode: number | null
  now: number
}

export interface AttentionView {
  attention: Attention
  attentionReason: AttentionReason
  /**
   * How long it has been in this state, in milliseconds, or null when unknown.
   *
   * Measured from the last *status* change, which is not quite the same thing:
   * two consecutive statuses that map to one bucket (`idle` → `waiting`, both
   * `quiet`) restart the clock. That under-reports and never over-reports, which
   * is the safe direction for a number a model will put in a sentence — and it
   * is exact for the case that matters, because `blocked` has exactly one status
   * behind it, so "blocked for 40 minutes" is the truth rather than a floor.
   *
   * Null when {@link AttentionInput.statusSince} is, which in practice means an
   * exited session. Clamped at zero otherwise: a `statusSince` in the future is
   * a clock that moved, not a session that has been waiting for negative time.
   */
  attentionForMs: number | null
  statusSource: StatusSource
}

/**
 * The status a session should be reported as, given what the tracker last said.
 *
 * `exited` beats a stale classification: a tracker's last word before the
 * process died would otherwise leave a dead session reading as `working`, and
 * "how is that session doing" is exactly the question being asked here. Lifted
 * out of `viewOf` so that this file owns the whole of "what state is it in",
 * rather than half of it living in the catalogue.
 */
export function statusOf(exitCode: number | null, live: SessionStatus | null | undefined): SessionStatus {
  if (exitCode !== null) return 'exited'
  return live ?? 'idle'
}

export function attentionOf(input: AttentionInput): AttentionView {
  const statusSource: StatusSource = input.exitCode !== null ? 'exit-code' : 'screen'
  const attentionForMs = input.statusSince === null ? null : Math.max(0, input.now - input.statusSince)

  const [attention, attentionReason] = bucket(input)
  return { attention, attentionReason, attentionForMs, statusSource }
}

function bucket(input: AttentionInput): [Attention, AttentionReason] {
  switch (input.status) {
    case 'input':
      return ['blocked', 'question-unanswered']
    case 'working':
      return ['running', 'output-streaming']
    case 'waiting':
      return ['quiet', 'prompt-ready']
    case 'idle':
      return ['quiet', 'no-output']
    case 'completed':
      return ['done', 'turn-finished']
    case 'exited':
      // A non-zero exit is still `done` rather than `blocked`: the session is
      // over, and nothing a person does will un-end it. The reason is what
      // makes it worth mentioning first in a triage answer.
      return ['done', input.exitCode !== null && input.exitCode !== 0 ? 'process-failed' : 'process-exited']
  }
}

/**
 * Triage order: the sessions a person should look at first.
 *
 * Blocked before done before quiet before running, and inside a bucket the one
 * that has been there longest. The ordering is a claim about attention and not
 * about importance — `running` is last because a working session is the one
 * case where the right action is to do nothing.
 *
 * Exposed as a comparator rather than applied inside `sessions.list`, because a
 * caller filtering by folder still wants the same order and a caller asking for
 * one session does not want an order at all.
 */
export const ATTENTION_ORDER: Readonly<Record<Attention, number>> = {
  blocked: 0,
  done: 1,
  quiet: 2,
  running: 3,
}

export function byAttention(a: AttentionView, b: AttentionView): number {
  const rank = ATTENTION_ORDER[a.attention] - ATTENTION_ORDER[b.attention]
  // An unknown duration sorts last within its bucket rather than first. "We do
  // not know how long" is not a claim of urgency, and treating it as a large
  // number would put every exited session above a session blocked for an hour.
  return rank !== 0 ? rank : (b.attentionForMs ?? -1) - (a.attentionForMs ?? -1)
}
