import { mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { InstructionsFiles, instructionsDir, instructionsPath, MAX_INSTRUCTIONS_FILE_CHARS, readInstructions, writeInstructions } from './agent-instructions'
import { TaskConfig, TASK_CONFIG_FILE } from '../tasks/task-config'

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-agent-instructions-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

describe('an agent’s instructions file', () => {
  it('is written whole and read back, under the remote folder, named by the agent id', () => {
    const dir = instructionsDir(root)
    expect(dir).toBe(join(root, 'agent-instructions'))
    writeInstructions(dir, 'builder', 'Work on a branch.\nRun the tests.')
    expect(readFileSync(join(dir, 'builder.md'), 'utf8')).toBe('Work on a branch.\nRun the tests.\n')
    expect(readInstructions(dir, 'builder')).toBe('Work on a branch.\nRun the tests.\n')
    if (process.platform !== 'win32') expect(statSync(join(dir, 'builder.md')).mode & 0o777).toBe(0o600)
  })

  it('is removed by blank text, and reads as none when missing', () => {
    const dir = instructionsDir(root)
    writeInstructions(dir, 'builder', 'x')
    writeInstructions(dir, 'builder', '   ')
    expect(readInstructions(dir, 'builder')).toBeNull()
    expect(readInstructions(dir, 'nobody')).toBeNull()
  })

  it('is never named by anything but an agent id', () => {
    const dir = instructionsDir(root)
    for (const bad of ['../escape', 'a/b', '', 'UPPER', '-lead']) {
      expect(() => instructionsPath(dir, bad)).toThrow(/not an agent id/)
    }
  })

  it('refuses more than the longest it launches with', () => {
    expect(() => writeInstructions(instructionsDir(root), 'builder', 'x'.repeat(MAX_INSTRUCTIONS_FILE_CHARS + 1))).toThrow(/longer than/)
  })

  it('picks up an edit made in another editor', () => {
    const files = new InstructionsFiles(instructionsDir(root))
    files.write('builder', 'First.')
    expect(files.read('builder')).toBe('First.\n')
    writeFileSync(files.path('builder'), 'Second, from an editor.\n')
    // Same second on a coarse clock: the size differs, and that is enough.
    expect(files.read('builder')).toBe('Second, from an editor.\n')
    writeFileSync(files.path('builder'), 'Third, same size .....\n')
    utimesSync(files.path('builder'), new Date(), new Date(Date.now() + 5_000))
    expect(files.read('builder')).toBe('Third, same size .....\n')
  })
})

describe('the task settings keep instructions in that file', () => {
  const remote = (): string => join(root, 'remote')

  it('round-trips through a save, a restart and an outside edit', () => {
    const config = new TaskConfig({ dir: remote() })
    const saved = config.saveAgent({ id: 'builder', name: 'Builder', provider: 'claude', instructions: 'Work on a branch.' })
    const file = join(remote(), 'agent-instructions', 'builder.md')
    expect(saved).toMatchObject({ instructions: 'Work on a branch.', instructionsFile: file })
    // The settings file holds no copy to drift from it.
    const stored = JSON.parse(readFileSync(join(remote(), TASK_CONFIG_FILE), 'utf8')) as { agents: Array<Record<string, unknown>> }
    expect(stored.agents[0].instructions).toBeNull()
    expect(stored.agents[0]).not.toHaveProperty('instructionsFile')

    writeFileSync(file, 'Work on a branch. Keep commits small.\n')
    const again = new TaskConfig({ dir: remote() })
    expect(again.agent('builder')).toMatchObject({ instructions: 'Work on a branch. Keep commits small.', instructionsFile: file })

    again.saveAgent({ ...again.agent('builder'), instructions: null })
    expect(again.agent('builder')).toMatchObject({ instructions: null, instructionsFile: null })
    expect(() => statSync(file)).toThrow()
  })

  it('moves instructions saved before files existed into one, keeping everything else', () => {
    const dir = remote()
    new TaskConfig({ dir }).saveConnection('k1', { name: 'CRM' })
    const stored = JSON.parse(readFileSync(join(dir, TASK_CONFIG_FILE), 'utf8')) as Record<string, unknown>
    writeFileSync(
      join(dir, TASK_CONFIG_FILE),
      JSON.stringify({ ...stored, agents: [{ id: 'old', name: 'Old', instructions: 'From before.', maxConcurrent: 1 }] }),
    )
    const config = new TaskConfig({ dir })
    expect(config.agent('old')).toMatchObject({ instructions: 'From before.', status: 'active', statusAt: null })
    expect(readFileSync(join(dir, 'agent-instructions', 'old.md'), 'utf8')).toBe('From before.\n')
    const rewritten = JSON.parse(readFileSync(join(dir, TASK_CONFIG_FILE), 'utf8')) as { agents: Array<{ instructions: unknown }>; connections: unknown[] }
    expect(rewritten.agents[0].instructions).toBeNull()
    expect(rewritten.connections).toHaveLength(1)
  })

  it('removes the file with the agent, so a new one with that id starts blank', () => {
    const config = new TaskConfig({ dir: remote() })
    config.saveAgent({ id: 'builder', name: 'Builder', instructions: 'Old words.' })
    config.removeAgent('builder')
    expect(config.saveAgent({ id: 'builder', name: 'Builder' }).instructions).toBeNull()
  })

  it('kept in memory, has no file and says so', () => {
    const config = new TaskConfig({ dir: null })
    expect(config.saveAgent({ id: 'builder', name: 'Builder', instructions: 'In memory.' })).toMatchObject({
      instructions: 'In memory.',
      instructionsFile: null,
    })
  })
})
