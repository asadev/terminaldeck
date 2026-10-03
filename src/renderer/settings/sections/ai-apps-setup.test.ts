import { describe, expect, it } from 'vitest'
import {
  APPS,
  CHANNEL_SERVER,
  IDLE_SENTENCE,
  LEVELS,
  SERVER_KEY,
  deliveryLine,
  ago,
  secretLink,
  setupFor,
  toAiAppsResult,
  toAiAppsState,
  usedLine,
  type SetupContext,
} from './ai-apps-setup'

/**
 * The setup the "Connect an AI app" page hands out, read as text.
 *
 * Every snippet here is something a person pastes into another program and
 * then forgets about, so a wrong one fails silently, somewhere else, later. The
 * checks are the ones that program would make: does it parse, is the key where
 * that program looks for it, is the address the right one for where it runs.
 */

const KEY = 'ak_Zq3vR8mX1pT6wK0nB4yH7cL2sD9fJ5gEaQ7uW1xY3zV'
const BASE = 'https://relay.example/mcp/K7QZ2M4HXN9PRT3VWB6CJD8FGA'
const LOCAL = 'http://127.0.0.1:47821/mcp'

function context(overrides: Partial<SetupContext> = {}): SetupContext {
  return { key: KEY, name: 'My app', internetBase: BASE, localUrl: LOCAL, where: 'this-mac', ...overrides }
}

describe('which apps are offered', () => {
  it('offers both web apps and every agent CLI this product runs, never only one', () => {
    const ids = APPS.map((app) => app.id)
    expect(ids).toEqual(expect.arrayContaining(['claude-web', 'chatgpt', 'claude-code', 'codex', 'gemini']))
    expect(APPS.filter((app) => app.web).map((app) => app.id)).toEqual(['claude-web', 'chatgpt'])
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('names the three levels in the owner’s words, and is plain about Work', () => {
    expect(LEVELS.map((level) => level.label)).toEqual(['Look only', 'Work', 'Full control'])
    expect(LEVELS.find((level) => level.id === 'work')?.help).toMatch(/any command/)
  })
})

describe('the setup for each app', () => {
  it('gives the web apps the secret link, which carries the key as its last segment', () => {
    for (const app of ['claude-web', 'chatgpt'] as const) {
      const setup = setupFor(app, context())
      expect(setup.snippet).toBe(`${BASE}/${KEY}`)
      expect(setup.needsInternet).toBe(true)
      expect(setup.steps.join(' ')).toContain('My app')
    }
    expect(secretLink(BASE, KEY)).toBe(`${BASE}/${KEY}`)
  })

  it('says why there is no link when this Mac has no relay, rather than drawing a broken one', () => {
    const setup = setupFor('chatgpt', context({ internetBase: null }))
    expect(setup.snippet).toBeNull()
    expect(setup.missing).toMatch(/not connected to a relay/)
  })

  it('gives Claude Code a command with the key in a header', () => {
    const snippet = setupFor('claude-code', context()).snippet ?? ''
    expect(snippet).toContain(`claude mcp add --scope user --transport http ${SERVER_KEY}`)
    expect(snippet).toContain(LOCAL)
    expect(snippet).toContain(`--header "Authorization: Bearer ${KEY}"`)
    // Continued lines, so it is one command in any shell it is pasted into.
    expect(snippet.split('\n').slice(0, -1).every((line) => line.endsWith(' \\'))).toBe(true)
  })

  it('writes Cursor, Gemini CLI and the other editor JSON each in the shape that app reads', () => {
    const cursor = JSON.parse(setupFor('cursor', context()).snippet ?? '{}')
    expect(cursor.mcpServers[SERVER_KEY]).toEqual({ url: LOCAL, headers: { Authorization: `Bearer ${KEY}` } })
    const gemini = JSON.parse(setupFor('gemini', context()).snippet ?? '{}')
    expect(gemini.mcpServers[SERVER_KEY]).toEqual({ httpUrl: LOCAL, headers: { Authorization: `Bearer ${KEY}` } })
    const editor = JSON.parse(setupFor('vscode', context()).snippet ?? '{}')
    expect(editor.servers[SERVER_KEY]).toEqual({ type: 'http', url: LOCAL, headers: { Authorization: `Bearer ${KEY}` } })
  })

  it('writes Codex TOML with the key in its headers table', () => {
    const toml = setupFor('codex', context()).snippet ?? ''
    expect(toml.split('\n')).toEqual([
      `[mcp_servers.${SERVER_KEY}]`,
      `url = "${LOCAL}"`,
      `http_headers = { "Authorization" = "Bearer ${KEY}" }`,
    ])
  })

  it('points a local app at the internet address when it runs on another computer', () => {
    const elsewhere = setupFor('cursor', context({ where: 'elsewhere' }))
    expect(JSON.parse(elsewhere.snippet ?? '{}').mcpServers[SERVER_KEY].url).toBe(BASE)
    expect(elsewhere.needsInternet).toBe(true)
    // The header form, never the secret link: these apps can set a header, so
    // the key stays out of a URL that lands in their logs.
    expect(elsewhere.snippet).not.toContain(`${BASE}/${KEY}`)
  })

  it('every app’s snippet holds this key and nobody else’s', () => {
    for (const app of APPS) {
      for (const where of ['this-mac', 'elsewhere'] as const) {
        const snippet = setupFor(app.id, context({ where })).snippet
        expect(snippet, `${app.id}/${where}`).toContain(KEY)
      }
    }
  })
})

describe('reading what the main process sends', () => {
  it('draws the internet switch on only for a literal true, and asks first unless told not to', () => {
    const state = toAiAppsState({
      keys: [{ id: 'a', name: 'A', level: 'full', askFirst: 'nope' }, { id: 'b', name: 'B', level: 'root' }],
      internet: { on: 'yes' },
      local: {},
      folders: ['/x', 3],
    })
    expect(state?.internet.on).toBe(false)
    expect(state?.keys).toHaveLength(1)
    expect(state?.keys[0].askFirst).toBe(true)
    expect(state?.folders).toEqual(['/x'])
    expect(toAiAppsState(null)).toBeNull()
  })

  it('treats an answer it cannot read as a refusal, never a success', () => {
    expect(toAiAppsResult(undefined)).toMatchObject({ ok: false, key: null })
    expect(toAiAppsResult({ ok: true, key: KEY, id: 'k1', state: { keys: [] } })).toMatchObject({ ok: true, key: KEY, id: 'k1' })
  })
})

describe('the last-used line', () => {
  it('says when, by which app, and which way', () => {
    const now = 10_000_000
    expect(
      usedLine(
        { id: 'a', name: 'A', level: 'look', askFirst: true, folders: null, createdAt: 0, lastUsedAt: now - 240_000, lastApp: 'claude-ai 0.1.0', lastVia: 'internet', notify: { mode: 'wait', url: null, hasSecret: false } },
        now,
      ),
    ).toBe('Last used 4 minutes ago by claude-ai 0.1.0 over the internet')
    expect(
      usedLine({ id: 'a', name: 'A', level: 'look', askFirst: true, folders: null, createdAt: 0, lastUsedAt: null, lastApp: null, lastVia: null, notify: { mode: 'wait', url: null, hasSecret: false } }),
    ).toBe('Not used yet')
    expect(ago(now - 10_000, now)).toBe('just now')
    expect(ago(now - 26 * 3_600_000, now)).toBe('yesterday')
  })
})

describe('hearing back from sessions', () => {
  it('tells every agent that can loop to wait for news instead of watching', () => {
    for (const app of ['claude-code', 'codex', 'gemini', 'cursor', 'vscode'] as const) {
      const setup = setupFor(app, context())
      expect(setup.after, app).toBe(IDLE_SENTENCE)
    }
    expect(IDLE_SENTENCE).toMatch(/notifications_wait/)
    expect(IDLE_SENTENCE).toMatch(/instead of polling sessions_wait/)
    // The web apps cannot loop on their own, so they are not told to.
    expect(setupFor('claude-web', context()).after).toBeUndefined()
  })

  it('offers Claude Code the channel push on this Mac only, with the bridge, the key and the preview caution', () => {
    const bridge = '/Users/me/Library/Application Support/app/notify-channel.mjs'
    const here = setupFor('claude-code', context({ channelBridge: bridge }))
    expect(here.extra?.snippet).toContain(`claude mcp add --scope user ${CHANNEL_SERVER}`)
    expect(here.extra?.snippet).toContain(`NOTIFY_KEY=${KEY}`)
    expect(here.extra?.snippet).toContain(`NOTIFY_URL=${LOCAL}`)
    expect(here.extra?.snippet).toContain(`node "${bridge}"`)
    expect(here.extra?.snippet).toContain(`--dangerously-load-development-channels server:${CHANNEL_SERVER}`)
    expect(here.extra?.caution).toMatch(/preview/)
    // On another computer the bridge file is not there to start.
    expect(setupFor('claude-code', context({ channelBridge: bridge, where: 'elsewhere' })).extra).toBeUndefined()
    expect(setupFor('claude-code', context({ channelBridge: null })).extra).toBeUndefined()
    expect(setupFor('codex', context({ channelBridge: bridge })).extra).toBeUndefined()
  })

  it('reads how each key is told, drawing anything unreadable as waiting', () => {
    const state = toAiAppsState({
      keys: [
        { id: 'a', name: 'A', level: 'work', notify: { mode: 'webhook', url: 'https://h.example', hasSecret: true } },
        { id: 'b', name: 'B', level: 'work', notify: { mode: 'carrier pigeon' } },
        { id: 'c', name: 'C', level: 'work' },
      ],
      delivery: { a: { state: 'undelivered', at: 1, via: null, error: 'x', outstanding: 2 }, b: { state: 'weird', at: 1 } },
      channelBridge: '/x/notify-channel.mjs',
    })
    expect(state?.keys.map((key) => key.notify.mode)).toEqual(['webhook', 'wait', 'wait'])
    expect(state?.keys[0].notify).toEqual({ mode: 'webhook', url: 'https://h.example', hasSecret: true })
    expect(Object.keys(state?.delivery ?? {})).toEqual(['a'])
    expect(state?.channelBridge).toBe('/x/notify-channel.mjs')
  })

  it('says how the last notification went in plain words', () => {
    const now = 10_000_000
    expect(deliveryLine(undefined)).toBeNull()
    expect(deliveryLine({ state: 'delivered', at: now - 120_000, via: 'webhook', error: null, outstanding: 0 }, now)).toBe(
      'Last notification delivered 2 minutes ago by webhook',
    )
    expect(deliveryLine({ state: 'undelivered', at: now, via: null, error: null, outstanding: 1 }, now)).toMatch(
      /Not delivered after four tries .* kept until the app collects it/,
    )
    expect(deliveryLine({ state: 'failed', at: now, via: null, error: 'the webhook answered 500', outstanding: 1 }, now)).toMatch(
      /failed .* trying again: the webhook answered 500/,
    )
  })
})
