import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { MAX_REMOVED, WorkspaceStore, type WorkspaceRecord } from './workspace-store'

const made: string[] = []

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-workspace-store-'))
  made.push(dir)
  return dir
}

afterEach(() => {
  for (const dir of made.splice(0)) {
    try {
      chmodSync(dir, 0o700)
    } catch {
      /* already writable */
    }
    rmSync(dir, { recursive: true, force: true })
  }
})

function record(taskId: string, change: Partial<WorkspaceRecord> = {}): WorkspaceRecord {
  return {
    taskId,
    repo: '/work/app',
    path: `/data/workspaces/k/${taskId}`,
    branch: `td/x-${taskId}`,
    project: '/work/app',
    base: 'abc123',
    createdAt: 1,
    state: 'active',
    reason: null,
    updatedAt: 1,
    ...change,
  }
}

describe('the workspace records', () => {
  it('are written as one whole file and read back after a restart', () => {
    const dir = tempDir()
    const file = join(dir, 'workspaces', 'workspaces.json')
    const store = new WorkspaceStore(file)
    store.put(record('local:a'))
    store.refuse({ taskId: 'local:b', project: '/plain', reason: '/plain is not a git repository', at: 2 })

    const again = new WorkspaceStore(file)
    expect(again.get('local:a')).toEqual(record('local:a'))
    expect(again.refusal('local:b')?.reason).toBe('/plain is not a git repository')
    // Through a temporary file and a rename: nothing half-written is left beside it.
    expect(readdirSync(join(dir, 'workspaces'))).toEqual(['workspaces.json'])
    expect(JSON.parse(readFileSync(file, 'utf8')).v).toBe(1)
  })

  it('keep the last whole file when a save cannot be made', () => {
    if (process.platform === 'win32') return // folder modes do not refuse writes there
    const dir = tempDir()
    const file = join(dir, 'workspaces.json')
    const store = new WorkspaceStore(file)
    store.put(record('local:a'))
    const before = readFileSync(file, 'utf8')
    chmodSync(dir, 0o500)
    expect(() => store.put(record('local:b'))).toThrow()
    chmodSync(dir, 0o700)
    expect(readFileSync(file, 'utf8')).toBe(before)
    expect(new WorkspaceStore(file).get('local:a')).not.toBeNull()
  })

  it('move an unreadable file aside rather than write over it', () => {
    const dir = tempDir()
    const file = join(dir, 'workspaces.json')
    writeFileSync(file, '{ not json')
    const store = new WorkspaceStore(file)
    expect(store.all()).toEqual([])
    expect(existsSync(file)).toBe(false)
    const aside = readdirSync(dir).filter((name) => name.startsWith('workspaces.json.unreadable-'))
    expect(aside).toHaveLength(1)
    expect(readFileSync(join(dir, aside[0]), 'utf8')).toBe('{ not json')
  })

  it('drop a malformed record and keep the rest', () => {
    const dir = tempDir()
    const file = join(dir, 'workspaces.json')
    mkdirSync(dir, { recursive: true })
    writeFileSync(file, JSON.stringify({ v: 1, workspaces: [record('local:a'), { taskId: 'local:b' }, { ...record('local:c'), state: 'lost' }], refused: [null] }))
    expect(new WorkspaceStore(file).all().map((one) => one.taskId)).toEqual(['local:a'])
  })

  it('clear a task’s refusal once it has a workspace', () => {
    const store = new WorkspaceStore(join(tempDir(), 'workspaces.json'))
    store.refuse({ taskId: 'local:a', project: '/work/app', reason: 'no commits', at: 1 })
    store.put(record('local:a'))
    expect(store.refusal('local:a')).toBeNull()
  })

  it('hand out copies, so a caller cannot change a record without saving it', () => {
    const store = new WorkspaceStore(join(tempDir(), 'workspaces.json'))
    store.put(record('local:a'))
    const got = store.get('local:a')
    if (got !== null) got.state = 'removed'
    expect(store.get('local:a')?.state).toBe('active')
  })

  it('keep only the newest removed records, and never drop a live one to make room', () => {
    const store = new WorkspaceStore(join(tempDir(), 'workspaces.json'))
    store.put(record('local:live', { updatedAt: 0 }))
    for (let i = 0; i <= MAX_REMOVED; i++) store.put(record(`local:r${i}`, { state: 'removed', updatedAt: i + 1 }))
    const all = store.all()
    expect(all.filter((one) => one.state === 'removed')).toHaveLength(MAX_REMOVED)
    expect(store.get('local:r0')).toBeNull()
    expect(store.get('local:live')).not.toBeNull()
  })
})
