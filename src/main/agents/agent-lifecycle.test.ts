import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { applyLifecycle, canDelegateTo, delegationRefusal, isPickable, lifecycleOf } from './agent-lifecycle'
import { TaskConfig, TASK_CONFIG_FILE } from '../tasks/task-config'

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-agent-lifecycle-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('an agent’s status', () => {
  it('moves only along the four actions, with the time it moved', () => {
    const active = { status: 'active' as const, statusAt: null }
    expect(applyLifecycle(active, 'pause', 100, 'Builder')).toEqual({ status: 'paused', statusAt: 100 })
    expect(applyLifecycle({ status: 'paused', statusAt: 100 }, 'resume', 200, 'Builder')).toEqual({ status: 'active', statusAt: 200 })
    expect(applyLifecycle({ status: 'paused', statusAt: 100 }, 'archive', 300, 'Builder')).toEqual({ status: 'archived', statusAt: 300 })
    expect(applyLifecycle({ status: 'archived', statusAt: 300 }, 'restore', 400, 'Builder')).toEqual({ status: 'active', statusAt: 400 })
  })

  it('refuses a move that makes no sense, saying why', () => {
    expect(applyLifecycle({ status: 'active', statusAt: null }, 'resume', 1, 'Builder')).toBe('Builder is not paused.')
    expect(applyLifecycle({ status: 'archived', statusAt: 1 }, 'pause', 1, 'Builder')).toBe('Builder is archived. Restore it first.')
    expect(applyLifecycle({ status: 'archived', statusAt: 1 }, 'archive', 1, 'Builder')).toBe('Builder is already archived.')
    expect(applyLifecycle({ status: 'active', statusAt: null }, 'delete', 1, 'Builder')).toMatch(/not something an agent can do/)
  })

  it('reads a stored status strictly: absent is active, a paused one says when', () => {
    expect(lifecycleOf({})).toEqual({ status: 'active', statusAt: null })
    expect(lifecycleOf({ status: 'paused', statusAt: 5 })).toEqual({ status: 'paused', statusAt: 5 })
    expect(lifecycleOf({ status: 'sleeping' })).toMatch(/has to be one of/)
    expect(lifecycleOf({ status: 'paused' })).toMatch(/when it was paused/)
    expect(lifecycleOf({ status: 'active', statusAt: -1 })).toMatch(/time/)
  })
})

describe('who may be handed work', () => {
  it('only an active agent; a paused or archived one is refused with a sentence to act on', () => {
    expect(canDelegateTo({ status: 'active' })).toBe(true)
    expect(canDelegateTo({ status: 'paused' })).toBe(false)
    expect(canDelegateTo({ status: 'archived' })).toBe(false)
    expect(delegationRefusal({ name: 'Builder', status: 'active' })).toBeNull()
    expect(delegationRefusal({ name: 'Builder', status: 'paused' })).toMatch(/^Builder is paused.*Resume it/)
    expect(delegationRefusal({ name: 'Builder', status: 'archived' })).toMatch(/^Builder is archived.*Restore it/)
  })

  it('a paused agent is still offered in pickers; an archived one is not', () => {
    expect(isPickable({ status: 'paused' })).toBe(true)
    expect(isPickable({ status: 'archived' })).toBe(false)
  })
})

describe('the task settings keep the lifecycle', () => {
  it('pauses, and the paused agent is refused by canDelegateTo, across a restart', () => {
    const config = new TaskConfig({ dir })
    config.saveAgent({ id: 'builder', name: 'Builder' })
    const paused = config.setAgentStatus('builder', 'pause', 1_000)
    expect(paused).toMatchObject({ status: 'paused', statusAt: 1_000 })
    const again = new TaskConfig({ dir })
    expect(canDelegateTo(again.agent('builder')!)).toBe(false)
    expect(again.setAgentStatus('builder', 'resume', 2_000)).toMatchObject({ status: 'active', statusAt: 2_000 })
    expect(canDelegateTo(again.agent('builder')!)).toBe(true)
  })

  it('archives: hidden from pickers but kept whole — identities included — and restorable', () => {
    const config = new TaskConfig({ dir })
    config.saveAgent({ id: 'builder', name: 'Builder', instructions: 'Keep it small.' })
    config.saveAgent({ id: 'tester', name: 'Tester' })
    config.saveConnection('k1', { identities: { 'u-builder': 'builder' } })
    config.setAgentStatus('builder', 'archive', 5)

    expect(config.pickableAgents().map((agent) => agent.id)).toEqual(['tester'])
    expect(config.agents().map((agent) => agent.id)).toEqual(['builder', 'tester'])
    expect(config.agent('builder')).toMatchObject({ status: 'archived', instructions: 'Keep it small.' })
    expect(config.connection('k1')?.identities).toEqual({ 'u-builder': 'builder' })

    config.setAgentStatus('builder', 'restore', 6)
    expect(config.pickableAgents().map((agent) => agent.id)).toEqual(['builder', 'tester'])
  })

  it('never changes status through a save — a form opened before an archive cannot bring the agent back', () => {
    const config = new TaskConfig({ dir })
    const form = config.saveAgent({ id: 'builder', name: 'Builder' })
    config.setAgentStatus('builder', 'archive', 9)
    expect(config.saveAgent({ ...form, role: 'reviewer' })).toMatchObject({ status: 'archived', statusAt: 9, role: 'reviewer' })
    // And a new agent is active whatever it was sent with.
    expect(config.saveAgent({ id: 'new', name: 'New', status: 'archived', statusAt: 1 })).toMatchObject({ status: 'active', statusAt: null })
  })

  it('refuses an action on an agent that is not there, or one that makes no sense', () => {
    const config = new TaskConfig({ dir: null })
    config.saveAgent({ id: 'builder', name: 'Builder' })
    expect(() => config.setAgentStatus('ghost', 'pause')).toThrow('That agent no longer exists.')
    expect(() => config.setAgentStatus('builder', 'resume')).toThrow('Builder is not paused.')
  })

  it('keeps an agent whose stored status no longer reads, at the cost of its status', () => {
    writeFileSync(join(dir, TASK_CONFIG_FILE), JSON.stringify({ v: 1, agents: [{ id: 'odd', name: 'Odd', status: 'sleeping' }], connections: [] }))
    const config = new TaskConfig({ dir })
    expect(config.agent('odd')).toMatchObject({ status: 'active', statusAt: null })
    expect(readFileSync(join(dir, TASK_CONFIG_FILE), 'utf8')).toContain('sleeping')
  })
})
