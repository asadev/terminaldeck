/**
 * The rules the phone's "This server" section reads and applies the two
 * server-owned settings with.
 *
 * Only the pure half is exercised, and that is why the pure half exists as
 * exported functions rather than as expressions inside a DOM builder — the same
 * split, for the same reason, as `session-controls.test.ts` beside it: vitest
 * runs in this repo with no DOM at all, so a rule that lives inside `render()` is
 * a rule nothing can ask a question of.
 *
 * The fixtures go through the wire for real. Every inbound frame here is a JSON
 * string handed to `decodeServerMessage` — the one reader this client has — so
 * what the assertions see is what a phone would see after the shared parser has
 * had its say; every outbound frame is checked with `parseClientMessage`, the
 * reader on the far end, so the section cannot send a shape a host would refuse.
 */

import { describe, expect, it } from 'vitest'
import { decodeServerMessage } from './protocol-client'
import {
  parseClientMessage,
  SERVER_SETTINGS,
  type ServerMessage,
  type ServerSettingWire,
} from '../../src/main/remote/protocol'
import { mergeRows, providerLabel } from './server-settings'

/** Through the real parser, so the shape asserted is the shape received. */
function arrived(frame: Record<string, unknown>): ServerMessage {
  const decoded = decodeServerMessage(JSON.stringify(frame))
  if (!decoded.ok) throw new Error(decoded.reason)
  return decoded.message
}

/* ----------------------------------------------------------- vocabulary -- */

describe('providerLabel names the builtins and passes anything else through', () => {
  it('uses the desktop’s own words for the four builtins', () => {
    expect(providerLabel('claude')).toBe('Claude Code')
    expect(providerLabel('codex')).toBe('Codex CLI')
    expect(providerLabel('gemini')).toBe('Gemini CLI')
    expect(providerLabel('shell')).toBe('Plain shell')
  })

  it('shows a custom agent’s id rather than guessing a label', () => {
    expect(providerLabel('custom:my-agent')).toBe('custom:my-agent')
    expect(providerLabel('something-new')).toBe('something-new')
  })
})

/* ------------------------------------------------------------ the merge -- */

describe('mergeRows keeps the allowlist order and replaces by key', () => {
  const provider: ServerSettingWire = {
    key: 'agents.defaultProvider',
    value: 'claude',
    options: ['claude', 'codex', 'gemini', 'shell'],
  }
  const restore: ServerSettingWire = { key: 'general.restoreSessions', value: 'true' }

  it('takes a whole state as the new set', () => {
    expect(mergeRows(null, [provider, restore]).map((row) => row.key)).toEqual([...SERVER_SETTINGS])
  })

  it('replaces one row without disturbing the other, and keeps SERVER_SETTINGS order', () => {
    const merged = mergeRows([restore, provider], [{ key: 'agents.defaultProvider', value: 'codex' }])
    // Order is the allowlist's, not the arrival order.
    expect(merged.map((row) => row.key)).toEqual([...SERVER_SETTINGS])
    expect(merged.find((row) => row.key === 'agents.defaultProvider')?.value).toBe('codex')
    expect(merged.find((row) => row.key === 'general.restoreSessions')?.value).toBe('true')
  })
})

/* --------------------------------------------------- the frames it sends -- */

describe('every frame the section sends is one the far end accepts', () => {
  it('reads with just a request id', () => {
    expect(parseClientMessage({ t: 'settings.read', rid: 'set-1' }).ok).toBe(true)
  })

  it('applies each server setting with the value its control composes', () => {
    // The picker sends a provider id; the toggle sends a boolean word. Both are
    // the values the section actually puts on the wire.
    expect(parseClientMessage({ t: 'settings.apply', rid: 'set-2', key: 'agents.defaultProvider', value: 'codex' }).ok).toBe(true)
    expect(parseClientMessage({ t: 'settings.apply', rid: 'set-3', key: 'general.restoreSessions', value: 'true' }).ok).toBe(true)
    expect(parseClientMessage({ t: 'settings.apply', rid: 'set-4', key: 'general.restoreSessions', value: 'false' }).ok).toBe(true)
    // A custom agent id, the other thing the picker can carry.
    expect(parseClientMessage({ t: 'settings.apply', rid: 'set-5', key: 'agents.defaultProvider', value: 'custom:mine' }).ok).toBe(true)
  })
})

/* --------------------------------------------------- the frames it reads -- */

describe('the section reads the three settings frames off the real wire', () => {
  it('takes a settings.state with the chooser’s options', () => {
    const message = arrived({
      t: 'settings.state',
      rid: 'set-1',
      settings: [
        { key: 'agents.defaultProvider', value: 'claude', options: ['claude', 'codex', 'gemini', 'shell'] },
        { key: 'general.restoreSessions', value: 'true' },
      ],
    })
    expect(message.t).toBe('settings.state')
    if (message.t === 'settings.state') {
      const merged = mergeRows(null, message.settings)
      expect(merged.find((row) => row.key === 'agents.defaultProvider')?.options).toEqual([
        'claude',
        'codex',
        'gemini',
        'shell',
      ])
    }
  })

  it('takes a settings.applied and its re-read row', () => {
    const message = arrived({
      t: 'settings.applied',
      rid: 'set-2',
      ok: true,
      message: 'Default coding tool set to Codex CLI.',
      setting: { key: 'agents.defaultProvider', value: 'codex' },
    })
    expect(message.t).toBe('settings.applied')
    if (message.t === 'settings.applied') {
      expect(message.ok).toBe(true)
      expect(message.setting.value).toBe('codex')
    }
  })

  it('takes an unsolicited settings.changed', () => {
    const message = arrived({
      t: 'settings.changed',
      settings: [{ key: 'general.restoreSessions', value: 'false' }],
    })
    expect(message.t).toBe('settings.changed')
    if (message.t === 'settings.changed') {
      expect(mergeRows([{ key: 'general.restoreSessions', value: 'true' }], message.settings)[0].value).toBe('false')
    }
  })

  it('never sees a remote.* row — the parser drops it before this client can', () => {
    // Defence in depth reaches the phone too: even if a host sent one, no row
    // naming a key this machine does not own is drawn.
    const message = arrived({
      t: 'settings.state',
      rid: 'set-1',
      settings: [
        { key: 'remote.enabled', value: 'true' },
        { key: 'agents.defaultProvider', value: 'codex' },
      ],
    })
    if (message.t === 'settings.state') {
      expect(message.settings).toHaveLength(1)
      expect(message.settings[0].key).toBe('agents.defaultProvider')
    }
  })
})
