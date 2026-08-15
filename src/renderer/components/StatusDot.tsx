import type { SessionStatus } from '@shared/types'

/*
 * The word a person reads on hover, which is not always the word the type uses.
 *
 * `waiting` is reached the moment a session starts and every time it comes back
 * to a prompt — a `/bin/zsh -l` sitting at `apple@host %` is in it from its
 * first frame. Calling that "Waiting" reads as *blocked on something*, which is
 * the opposite of what it means: the session is waiting on **you**, which is
 * simply what a prompt is. "Ready" is the same fact said the way a person would
 * say it, and it is the reason the dot beside it carries no colour.
 *
 * `idle` says the same word, on purpose. It is `classify`'s fallback — the
 * screen matched no prompt it knows and no question it knows — and to the
 * person reading the sidebar that is the identical situation: nothing is
 * happening and it is your turn. Two near-synonyms, "Idle" and "Ready", told
 * nobody anything they could act on, and the two dots beside them had *inverted
 * fills*: "Ready" was an open ring and "Idle" a solid dot, so the state that
 * sounds emptier was drawn the more emphatic of the two, against every
 * convention where a filled mark means something is going on. Verified live: a
 * shell genuinely sitting at a `read` prompt classifies as `idle`, and "Ready"
 * is the truer of the two words for it.
 */
const LABELS: Record<SessionStatus, string> = {
  idle: 'Ready',
  working: 'Working',
  waiting: 'Ready',
  input: 'Needs input',
  completed: 'Completed',
  exited: 'Exited',
}

/** Colour-coded session state. Colour alone never carries the meaning — the
 *  title attribute names the state for screen readers and on hover. */
export function StatusDot({ status }: { status: SessionStatus }) {
  return (
    <span
      className="status-dot"
      data-status={status}
      title={LABELS[status]}
      role="img"
      aria-label={LABELS[status]}
    />
  )
}
