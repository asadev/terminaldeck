import { describe, expect, it, vi } from 'vitest'
import { fakeContext, tool } from './agents-area.fixture'
import { hookTools, type HookToolDeps } from './hook-tools'

const CLAUDE = { id: 'claude', label: 'Claude Code', state: 'complete', message: 'Installed.' }

function deps(overrides: Partial<HookToolDeps> = {}): HookToolDeps {
  return {
    providers: ['claude', 'codex', 'gemini'],
    status: () => [CLAUDE],
    server: () => ({ address: '/state/hook/hook.sock', running: true, error: null }),
    offer: () => ({ show: false, answered: 'accepted', eligible: [], followUps: [] }),
    install: () => ({ ok: true, message: 'Installed.', status: CLAUDE }),
    remove: () => ({ ok: true, message: 'Removed.', status: { ...CLAUDE, state: 'none' } }),
    sync: () => [CLAUDE],
    acceptOffer: () => [{ ok: true, message: 'Installed.', status: CLAUDE }],
    declineOffer: () => undefined,
    ...overrides,
  }
}

describe('hooks', () => {
  it('reads the agents, the listener and the first-run offer in one answer', async () => {
    const { context } = fakeContext()
    const out = await tool(hookTools(deps()), 'hooks.status').run({}, context)
    expect(out.value).toMatchObject({ agents: [CLAUDE], listener: { running: true }, offer: { show: false } })
  })

  it('installs into one agent, or into every eligible one with "all"', async () => {
    const install = vi.fn<HookToolDeps['install']>(deps().install)
    const acceptOffer = vi.fn<HookToolDeps['acceptOffer']>(deps().acceptOffer)
    const { context } = fakeContext()
    const spec = tool(hookTools(deps({ install, acceptOffer })), 'hooks.install')
    await spec.run({ agent: 'codex' }, context)
    await spec.run({ agent: 'all' }, context)
    expect(install).toHaveBeenCalledWith('codex')
    expect(acceptOffer).toHaveBeenCalledTimes(1)
  })

  it('takes an agent from the closed set and nothing else — no path, no command', () => {
    const { context } = fakeContext()
    const tools = hookTools(deps())
    expect(() => tool(tools, 'hooks.install').precheck?.({ agent: '/etc/passwd' }, context)).toThrow(/agent must be one of/)
    // "all" is the offer's one press, and it is an install — never a remove.
    expect(() => tool(tools, 'hooks.remove').precheck?.({ agent: 'all' }, context)).toThrow(/agent must be one of/)
  })

  it('reports a write the module refused as a refusal with its sentence', async () => {
    const { context } = fakeContext()
    const spec = tool(hookTools(deps({ remove: () => ({ ok: false, message: 'settings.json is not valid JSON', status: CLAUDE }) })), 'hooks.remove')
    await expect(spec.run({ agent: 'claude' }, context)).rejects.toThrow(/not valid JSON/)
  })

  it('confirms every write into an agent’s settings, and not the decline', () => {
    const tools = hookTools(deps())
    expect(['hooks.install', 'hooks.remove', 'hooks.sync'].map((id) => tool(tools, id).tier)).toEqual(['alter', 'alter', 'alter'])
    expect(tool(tools, 'hooks.decline_offer').tier).toBe('act')
  })
})
