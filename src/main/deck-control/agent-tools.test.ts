import { describe, expect, it, vi } from 'vitest'
import type { ApplyRequest } from '../agent-controls'
import { agentTools, CONTROL_VALUES, type AgentToolDeps } from './agent-tools'
import { fakeContext, tierOf, tool } from './agents-area.fixture'

const UNKNOWN = { value: null, label: null, source: null }

function deps(overrides: Partial<AgentToolDeps> = {}): AgentToolDeps {
  return {
    detect: async () => ({ claude: true, codex: false, gemini: false, 'custom:aider': true }),
    added: () => [
      { id: 'custom:aider', label: 'Aider', description: '', command: 'aider', args: [], resumeArgs: [], addedAt: 1 },
    ],
    add: async () => ({ ok: false, problems: { command: '`nope` is not on your PATH.' } }),
    remove: (id) => id === 'custom:aider',
    readControls: async () => ({
      model: { value: 'opus', label: 'Opus', source: 'screen' },
      effort: UNKNOWN,
      fast: UNKNOWN,
      permission: UNKNOWN,
      live: true,
      agent: { running: true, evidence: 'screen', saw: 'Claude Code' },
      gate: { canType: true, reason: null },
    }),
    models: async () => ({ models: [], message: null }),
    apply: async () => ({ ok: true, message: 'Set model to Sonnet', reading: UNKNOWN }),
    ...overrides,
  }
}

describe('agents.list', () => {
  it('says which built-in agents are installed, and lists the added ones', async () => {
    const { context } = fakeContext()
    const out = await tool(agentTools(deps()), 'agents.list').run({}, context)
    const value = out.value as { builtIn: Array<{ id: string; installed: boolean }>; added: Array<{ id: string; installed: boolean }> }
    expect(value.builtIn.find((one) => one.id === 'claude')?.installed).toBe(true)
    expect(value.builtIn.find((one) => one.id === 'codex')?.installed).toBe(false)
    // The shell has no binary to look up and is never reported missing.
    expect(value.builtIn.find((one) => one.id === 'shell')?.installed).toBe(true)
    expect(value.added).toEqual([expect.objectContaining({ id: 'custom:aider', installed: true })])
  })
})

describe('agents.add and agents.remove', () => {
  it('refuses with the store’s own sentence when the command is not installed', async () => {
    const { context } = fakeContext()
    await expect(
      tool(agentTools(deps()), 'agents.add').run({ label: 'Nope', command: 'nope' }, context),
    ).rejects.toThrow(/not on your PATH/)
  })

  it('passes the form’s five fields to the store', async () => {
    const add = vi.fn<AgentToolDeps['add']>(async (draft) => ({
      ok: true,
      agent: { id: 'custom:x', label: draft.label, description: '', command: draft.command, args: [], resumeArgs: [], addedAt: 1, resolvedPath: '/bin/x' },
    }))
    const { context } = fakeContext()
    await tool(agentTools(deps({ add })), 'agents.add').run({ label: 'X', command: 'x', args: '--fast' }, context)
    expect(add).toHaveBeenCalledWith({ label: 'X', command: 'x', args: '--fast', resumeArgs: '', description: '' })
  })

  it('refuses to remove a built-in agent', async () => {
    const { context } = fakeContext()
    await expect(tool(agentTools(deps()), 'agents.remove').run({ agentId: 'claude' }, context)).rejects.toThrow(
      /Only agents added by hand/,
    )
  })
})

describe('the controls of a running session', () => {
  it('reads them with the session’s own folder and agent, and says what each accepts', async () => {
    const readControls = vi.fn<AgentToolDeps['readControls']>(deps().readControls)
    const { context } = fakeContext()
    const out = await tool(agentTools(deps({ readControls })), 'agents.controls').run({ sessionId: 'theirs-1' }, context)
    expect(readControls).toHaveBeenCalledWith('theirs-1', '/work/web', 'claude')
    expect((out.value as { accepts: unknown }).accepts).toEqual(CONTROL_VALUES)
  })

  it('refuses a session id the app is not holding', async () => {
    const { context } = fakeContext()
    await expect(tool(agentTools(deps()), 'agents.controls').run({ sessionId: 'gone' }, context)).rejects.toThrow(
      /not holding a session/,
    )
  })

  it('asks the person before typing into a session they started, and not one the copilot started', () => {
    const { context } = fakeContext()
    const tools = agentTools(deps())
    for (const id of ['agents.models', 'agents.set_control']) {
      expect(tierOf(tool(tools, id), { sessionId: 'mine-1', control: 'model', value: 'sonnet' }, context), id).toBe('act')
      expect(tierOf(tool(tools, id), { sessionId: 'theirs-1', control: 'model', value: 'sonnet' }, context), id).toBe('alter')
    }
  })

  it('always asks for the permission mode, because one of them turns the agent’s prompts off', () => {
    const { context } = fakeContext()
    const spec = tool(agentTools(deps()), 'agents.set_control')
    expect(tierOf(spec, { sessionId: 'mine-1', control: 'permission', value: 'bypass' }, context)).toBe('alter')
  })

  it('applies through applyControl with the session’s folder and agent', async () => {
    const apply = vi.fn<AgentToolDeps['apply']>(deps().apply)
    const { context } = fakeContext()
    await tool(agentTools(deps({ apply })), 'agents.set_control').run(
      { sessionId: 'mine-1', control: 'effort', value: 'high' },
      context,
    )
    expect(apply).toHaveBeenCalledWith<[ApplyRequest]>({
      sessionId: 'mine-1',
      cwd: '/work/api',
      control: 'effort',
      value: 'high',
      provider: 'claude',
    })
  })

  it('refuses a control that is not one of the four before anything is typed', () => {
    const { context } = fakeContext()
    expect(() =>
      tool(agentTools(deps()), 'agents.set_control').precheck?.({ sessionId: 'mine-1', control: 'theme', value: 'x' }, context),
    ).toThrow(/control must be one of/)
  })
})
