import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { TaskConfig } from '../tasks/task-config'
import { limitsOfAgent, stackOf } from '../tasks/task-engine'

/**
 * What a task agent's settings become: options on its start, or lines in its
 * brief — per coding agent, as `shared/agent-capabilities.ts` says.
 */

let dir = ''
let config: TaskConfig

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-agent-briefing-'))
  config = new TaskConfig({ dir })
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the start’s options', () => {
  it('a Claude Code agent with an instructions file and blocked tools starts with all three', () => {
    const agent = config.saveAgent({
      id: 'builder',
      name: 'Builder',
      provider: 'claude',
      instructions: 'Work on a branch.',
      blockedTools: ['WebFetch', 'mcp__deck-control'],
      skillsOff: true,
    })
    expect(limitsOfAgent(agent)).toEqual({
      sessionLimits: { deniedTools: ['WebFetch', 'mcp__deck-control'], noSkills: true, agentInstructions: 'builder' },
    })
  })

  it('a Codex agent is started with its instructions, and nothing else it cannot keep', () => {
    const agent = config.saveAgent({ id: 'coder', name: 'Coder', provider: 'codex', instructions: 'Small diffs.' })
    expect(limitsOfAgent(agent)).toEqual({ sessionLimits: { agentInstructions: 'coder' } })
  })

  it('the app default and Gemini keep instructions in the brief, so nothing is added to the start', () => {
    for (const provider of [null, 'gemini']) {
      const agent = config.saveAgent({ id: 'any', name: 'Any', provider, instructions: 'Be careful.' })
      expect(limitsOfAgent(agent), String(provider)).toBeUndefined()
      expect(stackOf(agent)).toContain('Be careful.')
    }
  })

  it('an agent with nothing enforced starts exactly as before', () => {
    expect(limitsOfAgent(config.saveAgent({ id: 'plain', name: 'Plain', provider: 'claude', toolsAvoided: ['WebFetch'] }))).toBeUndefined()
    // Instructions with no file behind them — settings kept in memory — are not promised at the start.
    const memory = new TaskConfig({ dir: null })
    expect(limitsOfAgent(memory.saveAgent({ id: 'builder', name: 'Builder', provider: 'claude', instructions: 'x' }))).toBeUndefined()
  })
})

describe('limits a coding agent cannot keep', () => {
  it('are refused when the agent is saved, for every agent but Claude Code', () => {
    for (const provider of ['codex', 'gemini', 'custom:aider']) {
      expect(() => config.saveAgent({ id: 'x', name: 'X', provider, blockedTools: ['Bash'] }), provider).toThrow(/Only Claude Code/)
      expect(() => config.saveAgent({ id: 'x', name: 'X', provider, skillsOff: true }), provider).toThrow(/Only Claude Code/)
    }
    // The app default may be Claude Code; the start is refused if it is not.
    expect(config.saveAgent({ id: 'x', name: 'X', provider: null, blockedTools: ['Bash'] }).blockedTools).toEqual(['Bash'])
  })

  it('a model or effort an agent cannot be given is refused at save, never saved to be dropped', () => {
    expect(() => config.saveAgent({ id: 'x', name: 'X', provider: 'codex', model: 'gpt-5' })).toThrow('Codex CLI cannot be given a model by this app. Clear it, or choose Claude Code.')
    expect(() => config.saveAgent({ id: 'x', name: 'X', provider: 'gemini', effort: 'high' })).toThrow(/cannot be given an effort level/)
    expect(config.saveAgent({ id: 'x', name: 'X', provider: 'claude', model: 'opus', effort: 'high' })).toMatchObject({ model: 'opus', effort: 'high' })
  })
})

describe('the brief', () => {
  it('repeats the instructions even when they were given at the start, for a resumed conversation', () => {
    const agent = config.saveAgent({ id: 'builder', name: 'Builder', provider: 'claude', instructions: 'Work on a branch.' })
    expect(agent.instructionsFile).not.toBeNull()
    expect(stackOf(agent)).toContain('Work on a branch.')
  })

  it('says a skill choice is a request, and names none when every skill is off', () => {
    const asked = config.saveAgent({ id: 'a', name: 'A', provider: 'claude', skills: ['frontend-design'] })
    expect(stackOf(asked)).toContain('Use these skills when they fit: frontend-design. That is a request, not a limit')
    const off = config.saveAgent({ id: 'b', name: 'B', provider: 'claude', skills: ['frontend-design'], skillsOff: true })
    expect(stackOf(off)).not.toContain('frontend-design')
    expect(stackOf(off)).toContain('Skills are switched off for you.')
  })

  it('a shell is given nothing it would only be told, and told nothing', () => {
    expect(() => config.saveAgent({ id: 's', name: 'S', provider: 'shell', instructions: 'x' })).toThrow(/cannot be given instructions/)
    expect(() => config.saveAgent({ id: 's', name: 'S', provider: 'shell', toolsPreferred: ['Read'] })).toThrow(/tools to prefer or avoid/)
    expect(stackOf(config.saveAgent({ id: 's', name: 'S', provider: 'shell' }))).toBe('')
  })
})
