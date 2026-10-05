/**
 * Whether a task agent is taking work: active, paused, or archived.
 *
 *  - **active** — can be handed work.
 *  - **paused** — kept as it is and listed, but takes no new work. What it is
 *    already running carries on; a pause is "no more", not "stop".
 *  - **archived** — out of the way: kept whole on disk (its settings, its
 *    instructions file, the CRM identities that name it) and hidden from every
 *    place an agent is picked, until it is restored.
 *
 * Removing an agent is a different, final thing (`TaskConfig.removeAgent`).
 *
 * A status changes only through {@link applyLifecycle}, never by saving the
 * agent's form: a save carries what the form shows, and a form opened before
 * an archive must not quietly bring the agent back.
 */

export type AgentStatus = 'active' | 'paused' | 'archived'

export const AGENT_STATUSES: readonly AgentStatus[] = ['active', 'paused', 'archived']

export type LifecycleAction = 'pause' | 'resume' | 'archive' | 'restore'

export const LIFECYCLE_ACTIONS: readonly LifecycleAction[] = ['pause', 'resume', 'archive', 'restore']

export interface AgentLifecycle {
  status: AgentStatus
  /** When it last changed status. Null for an agent that has only ever been active. */
  statusAt: number | null
}

export const ACTIVE: AgentLifecycle = Object.freeze({ status: 'active', statusAt: null }) as AgentLifecycle

/** A stored lifecycle, checked. Absent fields read as active — every agent saved before this existed. */
export function lifecycleOf(raw: { status?: unknown; statusAt?: unknown }): AgentLifecycle | string {
  const status = raw.status ?? 'active'
  if (typeof status !== 'string' || !AGENT_STATUSES.includes(status as AgentStatus)) {
    return `The agent status has to be one of: ${AGENT_STATUSES.join(', ')}.`
  }
  const at = raw.statusAt ?? null
  if (at !== null && (typeof at !== 'number' || !Number.isFinite(at) || at < 0)) return 'The status time has to be a time.'
  if (status !== 'active' && at === null) return `${status === 'paused' ? 'A paused' : 'An archived'} agent has to say when it was ${status}.`
  return { status: status as AgentStatus, statusAt: at as number | null }
}

/** The status one action leads to, or the sentence saying why it cannot. */
export function applyLifecycle(
  current: AgentLifecycle,
  action: unknown,
  now: number,
  name: string,
): AgentLifecycle | string {
  const to: Record<LifecycleAction, { from: readonly AgentStatus[]; to: AgentStatus; refuse: string }> = {
    pause: { from: ['active'], to: 'paused', refuse: current.status === 'archived' ? `${name} is archived. Restore it first.` : `${name} is already paused.` },
    resume: { from: ['paused'], to: 'active', refuse: current.status === 'archived' ? `${name} is archived. Restore it instead.` : `${name} is not paused.` },
    archive: { from: ['active', 'paused'], to: 'archived', refuse: `${name} is already archived.` },
    restore: { from: ['archived'], to: 'active', refuse: `${name} is not archived.` },
  }
  if (typeof action !== 'string' || !LIFECYCLE_ACTIONS.includes(action as LifecycleAction)) {
    return `That is not something an agent can do: ${String(action)}.`
  }
  const step = to[action as LifecycleAction]
  if (!step.from.includes(current.status)) return step.refuse
  return { status: step.to, statusAt: now }
}

/**
 * May this agent be handed new work? For the task engine, at the moment it
 * would start one — a CRM assignment, a delegation from Hoot, a local task.
 */
export function canDelegateTo(agent: { status: AgentStatus }): boolean {
  return agent.status === 'active'
}

/** Why it may not, as the task is told; null when it may. */
export function delegationRefusal(agent: { name: string; status: AgentStatus }): string | null {
  if (agent.status === 'paused') return `${agent.name} is paused, so it is not taking new work. Resume it in Settings → Tasks, or give this to another agent.`
  if (agent.status === 'archived') return `${agent.name} is archived, so it is not taking work. Restore it in Settings → Tasks, or give this to another agent.`
  return null
}

/** Is it offered where an agent is picked? Archived ones are not; paused ones are, and say so. */
export function isPickable(agent: { status: AgentStatus }): boolean {
  return agent.status !== 'archived'
}
