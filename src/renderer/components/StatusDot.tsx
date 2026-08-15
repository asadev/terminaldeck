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
 */
const LABELS: Record<SessionStatus, string> = {
  idle: 'Idle',
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
