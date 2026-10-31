import { describe, expect, it, vi } from 'vitest'
import {
  liveSessionCounts,
  newSessionCommands,
  newSessionMessage,
  publishNewSessionCommands,
  readSpawnRequest,
  type NativeNewSessionHandlers,
} from './native-new-session'
import { START_MEMORY_KEY } from './session-start'

function memoryStorage(initial: Record<string, string> = {}): Storage {
  const data = new Map(Object.entries(initial))
  return {
    get length() {
      return data.size
    },
    clear: () => data.clear(),
    getItem: (key) => data.get(key) ?? null,
    key: (index) => [...data.keys()][index] ?? null,
    removeItem: (key) => void data.delete(key),
    setItem: (key, value) => void data.set(key, value),
  }
}

function handlers(): NativeNewSessionHandlers & { calls: unknown[][] } {
  const calls: unknown[][] = []
  return {
    calls,
    start: (...args) => void calls.push(['start', ...args]),
    startOnServer: (...args) => void calls.push(['server', ...args]),
    removeProject: (...args) => void calls.push(['remove', ...args]),
    close: () => void calls.push(['close']),
  }
}

const REQUEST = { cwd: '/p', provider: 'claude', resume: false, profileId: null, cols: 100, rows: 30, firstPrompt: '', title: null }

describe('native New session dialog, page side', () => {
  it('hands the native window the context and the remembered choices', () => {
    const store = memoryStorage({ [START_MEMORY_KEY]: '{"/p":{"provider":"codex"}}' })
    const message = newSessionMessage(
      3,
      { projectPath: '/p', machineId: null, machines: [], hereName: 'Mac', servers: [], liveSessions: { '/p': 2 } },
      store,
    )
    expect(message).toMatchObject({ type: 'new-session', seq: 3, projectPath: '/p', hereName: 'Mac', liveSessions: { '/p': 2 } })
    expect(message.memory).toBe('{"/p":{"provider":"codex"}}')
  })

  it('runs Start with the same request, and keeps the remembered choices where the page dialog keeps them', () => {
    const h = handlers()
    const store = memoryStorage()
    const commands = newSessionCommands(() => h, () => store)
    expect(commands.run('start', { request: REQUEST, machineId: '', memory: '{"/p":{}}' })).toBe(true)
    expect(h.calls).toEqual([['start', REQUEST, null]])
    expect(store.getItem(START_MEMORY_KEY)).toBe('{"/p":{}}')
    expect(commands.run('start', { request: REQUEST, machineId: 'm1' })).toBe(true)
    expect(h.calls[1]).toEqual(['start', REQUEST, 'm1'])
  })

  it('refuses a request it cannot read rather than guessing', () => {
    const h = handlers()
    const commands = newSessionCommands(() => h)
    expect(commands.run('start', { request: { ...REQUEST, cwd: ' ' } })).toBe(false)
    expect(commands.run('start', { request: { ...REQUEST, provider: 'vim' } })).toBe(false)
    expect(commands.run('start', null)).toBe(false)
    expect(h.calls).toEqual([])
    expect(readSpawnRequest({ ...REQUEST, provider: 'custom:aider', cols: -1 })).toMatchObject({ provider: 'custom:aider', cols: 100 })
  })

  it('opens a server terminal, removes a folder, closes', () => {
    const h = handlers()
    const commands = newSessionCommands(() => h)
    expect(commands.run('server', { serverId: 's1', serverName: 'Box', path: '' })).toBe(true)
    expect(commands.run('server', { serverName: 'Box' })).toBe(false)
    expect(commands.run('remove-project', '/p')).toBe(true)
    expect(commands.run('remove-project', '')).toBe(false)
    expect(commands.run('close')).toBe(true)
    expect(commands.run('nope')).toBe(false)
    expect(h.calls).toEqual([['server', 's1', 'Box', null], ['remove', '/p'], ['close']])
    expect(newSessionCommands(() => null).run('close')).toBe(false)
  })

  it('installs itself only in the native shell', () => {
    const plain: { tdNewSession?: unknown } = {}
    publishNewSessionCommands(() => null, plain)
    expect(plain.tdNewSession).toBeUndefined()
    const native = { document: { documentElement: { dataset: { shell: 'native' } } }, tdNewSession: undefined as unknown }
    const undo = publishNewSessionCommands(() => null, native)
    expect(native.tdNewSession).toBeDefined()
    undo()
    expect(native.tdNewSession).toBeUndefined()
  })

  it('counts the sessions in each folder', () => {
    expect(liveSessionCounts([{ projectPath: '/a' }, { projectPath: '/a' }, { projectPath: '/b' }, { projectPath: '' }])).toEqual({ '/a': 2, '/b': 1 })
    vi.restoreAllMocks()
  })
})
