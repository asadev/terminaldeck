import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { AccessKeys } from './access-keys'
import { AI_APPS_CHANGED_CHANNEL, internetBase, registerAiAppsIpc, type AiAppsIpcDeps } from './ai-apps-ipc'

/**
 * The settings page's channels, against a fake `ipcMain` and a real key store.
 *
 * Two properties are the point: only the app's own window may use any of them,
 * because every one of them changes who can reach this machine; and the key
 * crosses exactly once, in the answer to the create that made it.
 */

type Handler = (event: { sender: Electron.WebContents }, ...args: unknown[]) => unknown

let dir = ''
const OWN = { id: 1 } as unknown as Electron.WebContents
const OTHER = { id: 2 } as unknown as Electron.WebContents

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-ai-apps-ipc-'))
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

function rig(overrides: Partial<AiAppsIpcDeps> = {}): {
  call(channel: string, sender: Electron.WebContents, ...args: unknown[]): unknown
  keys: AccessKeys
  pushed: string[]
} {
  const handlers = new Map<string, Handler>()
  const keys = new AccessKeys({ dir: join(dir, 'remote') })
  const pushed: string[] = []
  registerAiAppsIpc(
    { handle: (channel, listener) => void handlers.set(channel, listener) },
    {
      keys,
      isApprover: (contents) => contents === OWN,
      port: () => 47821,
      movedFrom: () => null,
      relay: () => ({ url: 'wss://relay.example', hostId: 'K7QZ2M4HXN9PRT3VWB6CJD8FGA', connected: true, reason: null }),
      folders: () => ['/work/api'],
      broadcast: (channel) => void pushed.push(channel),
      ...overrides,
    },
  )
  return {
    call: (channel, sender, ...args) => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler({ sender }, ...args)
    },
    keys,
    pushed,
  }
}

describe('the AI apps channels', () => {
  it('refuses every channel to any window that is not the app’s own', () => {
    const { call } = rig()
    for (const channel of [
      'ai-apps:state',
      'ai-apps:create',
      'ai-apps:rename',
      'ai-apps:level',
      'ai-apps:ask-first',
      'ai-apps:folders',
      'ai-apps:revoke',
      'ai-apps:internet',
    ]) {
      expect(() => call(channel, OTHER, 'x', 'y'), channel).toThrow(/only the app’s own window/)
    }
  })

  it('hands the key back once, in the create answer, and never in the state', () => {
    const { call } = rig()
    const made = call('ai-apps:create', OWN, { name: 'ChatGPT', level: 'full' }) as {
      ok: boolean
      key: string
      id: string
      state: { keys: Array<{ id: string }> }
    }
    expect(made.ok).toBe(true)
    expect(made.key.startsWith('ak_')).toBe(true)
    expect(made.state.keys.map((key) => key.id)).toEqual([made.id])
    expect(JSON.stringify(call('ai-apps:state', OWN))).not.toContain(made.key)
  })

  it('answers a refusal with a sentence, not a thrown error', () => {
    const { call } = rig()
    const refused = call('ai-apps:create', OWN, { name: '', level: 'look' }) as { ok: boolean; message: string }
    expect(refused).toMatchObject({ ok: false })
    expect(refused.message).toMatch(/name/)
    expect(call('ai-apps:revoke', OWN, 'nope')).toMatchObject({ ok: false })
  })

  it('changes, revokes and switches, and tells the window each time', () => {
    const { call, keys, pushed } = rig()
    const made = call('ai-apps:create', OWN, { name: 'A', level: 'look' }) as { id: string }
    expect(call('ai-apps:level', OWN, made.id, 'work')).toMatchObject({ ok: true })
    expect(keys.get(made.id)?.level).toBe('work')
    expect(call('ai-apps:internet', OWN, true)).toMatchObject({ ok: true, state: { internet: { on: true } } })
    expect(call('ai-apps:revoke', OWN, made.id)).toMatchObject({ ok: true })
    expect(keys.get(made.id)).toBeNull()
    expect(pushed.filter((channel) => channel === AI_APPS_CHANGED_CHANNEL).length).toBeGreaterThanOrEqual(4)
  })

  it('gives the page both addresses, built from the live link', () => {
    const { call } = rig()
    const state = call('ai-apps:state', OWN) as { internet: { base: string; relayHost: string }; local: { url: string } }
    expect(state.internet.base).toBe('https://relay.example/mcp/K7QZ2M4HXN9PRT3VWB6CJD8FGA')
    expect(state.internet.relayHost).toBe('relay.example')
    expect(state.local.url).toBe('http://127.0.0.1:47821/mcp')
  })
})

describe('the internet address', () => {
  it('turns the relay’s WebSocket address into the HTTPS one, keeping a path prefix', () => {
    expect(internetBase('wss://relay.example', 'HOST')).toBe('https://relay.example/mcp/HOST')
    expect(internetBase('wss://proxy.example/relay/', 'HOST')).toBe('https://proxy.example/relay/mcp/HOST')
    expect(internetBase('ws://127.0.0.1:9000', 'HOST')).toBe('http://127.0.0.1:9000/mcp/HOST')
    expect(internetBase('wss://relay.example', '')).toBeNull()
    expect(internetBase('not a url', 'HOST')).toBeNull()
  })
})
