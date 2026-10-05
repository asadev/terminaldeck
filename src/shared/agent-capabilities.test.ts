import { describe, expect, it } from 'vitest'
import {
  AGENT_FAMILIES,
  AGENT_SETTINGS,
  CAPABILITIES,
  agentLabel,
  capabilityFor,
  enforces,
  familiesEnforcing,
  familyOf,
  type AgentFamily,
  type Support,
} from './agent-capabilities'

/** The table as a grid of answers, so a changed cell reads as one line of a diff. */
function row(family: AgentFamily): Record<string, Support> {
  return Object.fromEntries(AGENT_SETTINGS.map((setting) => [setting, CAPABILITIES[family][setting].support]))
}

describe('the capability table', () => {
  it('answers every setting for every kind of agent, and says how and on what evidence', () => {
    for (const family of AGENT_FAMILIES) {
      for (const setting of AGENT_SETTINGS) {
        const cell = CAPABILITIES[family][setting]
        expect(['enforced', 'advisory', 'unsupported']).toContain(cell.support)
        expect(cell.how.trim(), `${family}.${setting} says how`).not.toBe('')
        expect(cell.evidence.trim(), `${family}.${setting} says why`).not.toBe('')
      }
    }
  })

  it('Claude Code: everything it has a flag for is enforced; a skill subset is advice', () => {
    expect(row('claude')).toEqual({
      model: 'enforced',
      effort: 'enforced',
      instructions: 'enforced',
      toolAdvice: 'advisory',
      blockedTools: 'enforced',
      skillsOff: 'enforced',
      skillSelection: 'advisory',
      mcpConfig: 'enforced',
      resumeById: 'enforced',
    })
    expect(CAPABILITIES.claude.instructions.evidence).toContain('--append-system-prompt-file')
    expect(CAPABILITIES.claude.blockedTools.evidence).toContain('--disallowedTools')
    expect(CAPABILITIES.claude.skillsOff.evidence).toContain('--disable-slash-commands')
    // The investigation is written down, not just its answer.
    expect(CAPABILITIES.claude.skillSelection.evidence).toContain('--add-dir')
  })

  it('Codex: instructions and resume are enforced; tools cannot be blocked, and model and effort are not set yet', () => {
    expect(row('codex')).toEqual({
      model: 'unsupported',
      effort: 'unsupported',
      instructions: 'enforced',
      toolAdvice: 'advisory',
      blockedTools: 'unsupported',
      skillsOff: 'unsupported',
      skillSelection: 'advisory',
      mcpConfig: 'unsupported',
      resumeById: 'enforced',
    })
    expect(CAPABILITIES.codex.instructions.evidence).toContain('developer_instructions')
    // Where the CLI has a mechanism this build does not use, it is named.
    expect(CAPABILITIES.codex.model.evidence).toContain('--model')
  })

  it('Gemini: not installed here, so nothing is claimed as enforced', () => {
    expect(Object.values(row('gemini'))).not.toContain('enforced')
    expect(row('gemini')).toMatchObject({ instructions: 'advisory', blockedTools: 'unsupported', resumeById: 'unsupported' })
    for (const setting of AGENT_SETTINGS) {
      const cell = CAPABILITIES.gemini[setting]
      if (cell.support === 'unsupported' && setting !== 'effort' && setting !== 'resumeById' && setting !== 'skillsOff') {
        expect(cell.evidence, `gemini.${setting}`).toMatch(/unverified/i)
      }
    }
  })

  it('a shell takes nothing, and an added agent only reads its brief', () => {
    expect(new Set(Object.values(row('shell')))).toEqual(new Set(['unsupported']))
    expect(row('custom')).toMatchObject({ instructions: 'advisory', toolAdvice: 'advisory', blockedTools: 'unsupported', model: 'unsupported' })
  })

  it('names who can keep an enforced limit', () => {
    expect(familiesEnforcing('blockedTools')).toEqual(['claude'])
    expect(familiesEnforcing('instructions')).toEqual(['claude', 'codex'])
  })
})

describe('reading the table for a provider', () => {
  it('maps provider ids onto rows, an added agent onto its own', () => {
    expect(familyOf('claude')).toBe('claude')
    expect(familyOf(null)).toBe('claude')
    expect(familyOf('codex')).toBe('codex')
    expect(familyOf('custom:aider')).toBe('custom')
  })

  it('reads the app default as Claude Code for limits, but never promises it instructions at the start', () => {
    expect(enforces(null, 'blockedTools')).toBe(true)
    expect(enforces(null, 'model')).toBe(true)
    expect(capabilityFor(null, 'instructions').support).toBe('advisory')
    expect(capabilityFor(null, 'instructions').how).toContain('Choose Claude Code or Codex')
    expect(enforces('claude', 'instructions')).toBe(true)
  })

  it('names an agent for a sentence', () => {
    expect(agentLabel('codex')).toBe('Codex CLI')
    expect(agentLabel('custom:aider')).toBe('An added agent')
  })
})
