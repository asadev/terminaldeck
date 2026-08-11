import type { SessionStatus } from '@shared/types'

const LABELS: Record<SessionStatus, string> = {
  idle: 'Idle',
  working: 'Working',
  waiting: 'Waiting',
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
