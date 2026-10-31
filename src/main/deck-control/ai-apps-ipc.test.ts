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

describe('the notification channels', () => {
  it('refuse any window but the app’s own', async () => {
    const { call } = rig()
    for (const channel of ['ai-apps:notify', 'ai-apps:notify-secret', 'ai-apps:events-stop']) {
      expect(() => call(channel, OTHER, 'x', {}), channel).toThrow(/only the app’s own window/)
    }
    // The test is async, so its refusal arrives as a rejected promise.
    await expect(Promise.resolve().then(() => call('ai-apps:notify-test', OTHER, 'x'))).rejects.toThrow(/only the app’s own window/)
  })

  it('hand the webhook secret back once, on the answer that minted it, and never in the state', () => {
    const { call } = rig()
    const made = call('ai-apps:create', OWN, { name: 'A', level: 'work' }) as { id: string }
    const set = call('ai-apps:notify', OWN, made.id, { mode: 'webhook', url: 'https://hooks.example.com/x' }) as {
      ok: boolean
      secret: string
      state: { keys: Array<{ notify: unknown }> }
    }
    expect(set.ok).toBe(true)
    expect(set.secret).toMatch(/^whsec_/)
    expect(JSON.stringify(set.state)).not.toContain(set.secret)
    expect(set.state.keys[0].notify).toEqual({ mode: 'webhook', url: 'https://hooks.example.com/x', hasSecret: true })
    const again = call('ai-apps:notify', OWN, made.id, { mode: 'webhook' }) as { secret: string | null }
    expect(again.secret).toBeNull()
    const rotated = call('ai-apps:notify-secret', OWN, made.id) as { secret: string }
    expect(rotated.secret).not.toBe(set.secret)
  })

  it('refuse an address the Mac may not post to, in a sentence', () => {
    const { call } = rig()
    const made = call('ai-apps:create', OWN, { name: 'A', level: 'work' }) as { id: string }
    const refused = call('ai-apps:notify', OWN, made.id, { mode: 'webhook', url: 'http://hooks.example.com/x' }) as {
      ok: boolean
      message: string
    }
    expect(refused).toMatchObject({ ok: false })
    expect(refused.message).toMatch(/https/)
  })

  it('report each key’s last delivery and the channel bridge, and run the test through the queue', async () => {
    const tested: string[] = []
    const { call } = rig({
      notify: {
        lastDelivery: () => ({ state: 'delivered', at: 5, via: 'webhook', error: null, outstanding: 0 }),
        test: async (keyId) => {
          tested.push(keyId)
          return { ok: true, message: 'Delivered: the address answered 204.' }
        },
      },
      channelBridge: () => '/data/notify-channel.mjs',
    })
    const made = call('ai-apps:create', OWN, { name: 'A', level: 'work' }) as { id: string }
    const state = call('ai-apps:state', OWN) as { delivery: Record<string, unknown>; channelBridge: string }
    expect(state.delivery[made.id]).toMatchObject({ state: 'delivered', via: 'webhook' })
    expect(state.channelBridge).toBe('/data/notify-channel.mjs')
    const result = (await call('ai-apps:notify-test', OWN, made.id)) as { ok: boolean; message: string }
    expect(result).toMatchObject({ ok: true, message: 'Delivered: the address answered 204.' })
    expect(tested).toEqual([made.id])
  })

  it('show each key’s push subscriptions, never a secret, and let the owner stop one', () => {
    const stopped: Array<[string, string]> = []
    const live = new Set<string>()
    let keyId = ''
    const { call } = rig({
      notify: {
        lastDelivery: () => null,
        test: async () => ({ ok: true, message: '' }),
        subscriptions: () =>
          [...live].map((id) => ({
            id,
            keyId,
            event: 'session.turn_finished',
            host: 'callbacks.chatgpt.com',
            sessionId: null,
            refreshBefore: 9_000,
            lastDelivery: null,
          })),
        stopSubscription: (keyId, id) => {
          stopped.push([keyId, id])
          return live.delete(id)
        },
      },
    })
    const made = call('ai-apps:create', OWN, { name: 'ChatGPT', level: 'work' }) as { id: string }
    keyId = made.id
    live.add('sub_1')
    const state = call('ai-apps:state', OWN) as { subscriptions: Record<string, Array<Record<string, unknown>>> }
    expect(state.subscriptions[made.id]).toEqual([
      expect.objectContaining({ id: 'sub_1', event: 'session.turn_finished', host: 'callbacks.chatgpt.com' }),
    ])
    expect(JSON.stringify(state)).not.toMatch(/whsec_/)
    const first = call('ai-apps:events-stop', OWN, made.id, 'sub_1') as { ok: boolean; state: { subscriptions: object } }
    expect(first.ok).toBe(true)
    expect(first.state.subscriptions).toEqual({})
    const again = call('ai-apps:events-stop', OWN, made.id, 'sub_1') as { ok: boolean; message: string }
    expect(again).toMatchObject({ ok: false, message: 'That subscription had already ended.' })
    expect(stopped).toEqual([
      [made.id, 'sub_1'],
      [made.id, 'sub_1'],
    ])
  })
})
