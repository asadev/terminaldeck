/**
 * A task agent's settings, split the way its coding agent can keep them: what
 * goes on the start (`limitsFor`) and what goes in the brief (`stackText`).
 *
 * Both read `shared/agent-capabilities.ts` and nothing else decides. A setting
 * the agent's program applies goes on the start; one it cannot is written in
 * the brief as a request and said to be one; one with no honest way to apply
 * it never reaches here, because saving it was refused
 * (`task-config.ts`'s `cleanAgent` and `checkSupported`).
 *
 * `task-engine.ts`'s `limitsOfAgent` and `stackOf` are these two.
 */

import { capabilityFor, enforces } from '../../shared/agent-capabilities'
import type { SessionLimits } from '../deck-control/control'
import type { AgentProfile } from '../tasks/task-config'

/**
 * The owner's enforced settings, as the start's options. Undefined when there
 * are none, so an agent without them is started exactly as before.
 *
 * Blocked tools and skills-off are passed whatever the provider: a start on an
 * agent that cannot keep them is refused at the spawn, never run without them.
 * The instructions file only when it exists and the provider takes one — with
 * the app's default agent it is unknown which, so they stay in the brief.
 */
export function limitsFor(agent: AgentProfile): { sessionLimits: SessionLimits } | undefined {
  const instructionsAtStart = agent.instructionsFile !== null && enforces(agent.provider, 'instructions')
  if (agent.blockedTools.length === 0 && !agent.skillsOff && !instructionsAtStart) return undefined
  return {
    sessionLimits: {
      ...(agent.blockedTools.length > 0 ? { deniedTools: [...agent.blockedTools] } : {}),
      ...(agent.skillsOff ? { noSkills: true } : {}),
      ...(instructionsAtStart ? { agentInstructions: agent.id } : {}),
    },
  }
}

/**
 * The agent's own settings, as a section of its brief: standing instructions,
 * the tools it is asked to prefer or avoid, the skills to use, and what is
 * switched off for it.
 *
 * Instructions are written here even when they were also given at the start.
 * A resumed Claude Code conversation keeps the system prompt it began with, so
 * after an edit the brief is the only place the agent hears the current ones.
 */
export function stackText(agent: AgentProfile): string {
  const parts: string[] = []
  const says = (setting: 'instructions' | 'toolAdvice' | 'skillSelection'): boolean =>
    capabilityFor(agent.provider, setting).support !== 'unsupported'
  if (agent.instructions !== null && says('instructions')) parts.push(agent.instructions)
  if (says('toolAdvice')) {
    if (agent.toolsPreferred.length > 0) parts.push(`Prefer these tools: ${agent.toolsPreferred.join(', ')}.`)
    if (agent.toolsAvoided.length > 0) parts.push(`Do not use these tools: ${agent.toolsAvoided.join(', ')}.`)
    if (agent.toolsPreferred.length > 0 || agent.toolsAvoided.length > 0) {
      parts.push('These tool choices are what the owner asked for; your own permission settings still apply.')
    }
  }
  // With every skill off, naming some would contradict the line below.
  if (agent.skills.length > 0 && !agent.skillsOff && says('skillSelection')) {
    parts.push(`Use these skills when they fit: ${agent.skills.join(', ')}. That is a request, not a limit: other skills stay available.`)
  }
  if (agent.blockedTools.length > 0) parts.push(`These tools are switched off for you: ${agent.blockedTools.join(', ')}.`)
  if (agent.skillsOff) parts.push('Skills are switched off for you.')
  return parts.length === 0 ? '' : `\n\n## How you work (${agent.name}, ${agent.role})\n\n${parts.join('\n\n')}`
}
