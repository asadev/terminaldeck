import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  MAX_SERVER_SETTING_VALUE_LENGTH,
  parseClientMessage,
  parseServerMessage,
  SERVER_SETTINGS,
  serverSettingWire,
} from './protocol'
import { createServerSettingsAccess } from '../host-core'
import { installPaths, nodePaths, resetPaths } from '../platform/paths'
import { store } from '../store'

/**
 * The `settings` capability's own tests, kept out of `protocol.test.ts` so the
 * one shared file grows only fixtures.
 *
 * The invariant these are the far half of is structural, not a rule a reviewer
 * has to keep enforcing: `SERVER_SETTINGS` is a closed allowlist, so a
 * `settings.apply` naming any other key — `remote.enabled` above all — is
 * refused *at the parser* and never reaches a handler. So the interesting
 * assertions here are about what the parser will not build, and about the store
 * side refusing the same key a second time under it.
 */

/* ---------------------------------------------------------- the parser in -- */

describe('parseClientMessage admits only the two settings this machine owns', () => {
  it('parses the two named keys', () => {
    for (const key of SERVER_SETTINGS) {
      const result = parseClientMessage({ t: 'settings.apply', rid: 'set-1', key, value: 'true' })
      expect(result.ok, `${key} should parse`).toBe(true)
    }
  })

  it('parses a settings.read with a request id and refuses one without', () => {
    expect(parseClientMessage({ t: 'settings.read', rid: 'set-r' }).ok).toBe(true)
    expect(parseClientMessage({ t: 'settings.read' }).ok).toBe(false)
  })

  /*
   * The fuzz the invariant is stated against: the remote and advanced keys the
   * copilot's own `settings.write` can be refused for, plus a spread of the
   * device-local schema ids that live on the wire's *other* side (a theme, a
   * density, a browser toggle) and a few near-misses of the two real keys. Every
   * one must come back `bad-message`, and — the second half of the rule — the
   * reason must never echo the key it refused, so a refusal cannot become a
   * confirmation that `remote.enabled` is a thing this machine has.
   */
  const FORBIDDEN = [
    'remote.enabled',
    'remote.disabled',
    'remote.autostart',
    'remote.',
    'remote.anything.at.all',
    'advanced.debugMode',
    'advanced.ipcTrace',
    'advanced.',
    'theme',
    'density',
    'notifications.enabled',
    'browser.startUrl',
    'browser.persistSession',
    'general.autoNameSessions',
    'general.confirmCloseWorking',
    'general.copyOnSelect',
    // Near-misses of the two real keys — a case flip, a suffix, a prefix.
    'agents.defaultprovider',
    'agents.defaultProviderX',
    'Agents.defaultProvider',
    'general.restoreSession',
    'general.restoreSessionsX',
    // Structural junk the parser must also refuse.
    '__proto__',
    '',
    'agents.defaultProvider.evil',
  ]

  it('refuses every other key as bad-message, and never echoes the key', () => {
    for (const key of FORBIDDEN) {
      const result = parseClientMessage({ t: 'settings.apply', rid: 'set-2', key, value: 'x' })
      expect(result.ok, `${key} must be refused`).toBe(false)
      // The empty string is a member of every string, so the echo check is only
      // meaningful for a key with characters in it.
      if (!result.ok && key !== '') {
        expect(result.reason, `reason for ${key} must not echo it`).not.toContain(key)
      }
    }
  })

  it('refuses a value that is missing, over-long, or carries a control byte', () => {
    const key = SERVER_SETTINGS[0]
    expect(parseClientMessage({ t: 'settings.apply', rid: 'r', key }).ok).toBe(false)
    expect(parseClientMessage({ t: 'settings.apply', rid: 'r', key, value: '' }).ok).toBe(false)
    expect(
      parseClientMessage({ t: 'settings.apply', rid: 'r', key, value: 'a'.repeat(MAX_SERVER_SETTING_VALUE_LENGTH + 1) }).ok,
    ).toBe(false)
    // A carriage return could carry a second line into a store write.
    expect(parseClientMessage({ t: 'settings.apply', rid: 'r', key, value: 'claude\rrm -rf' }).ok).toBe(false)
  })

  it('carries a provider id and a boolean word through untouched', () => {
    const provider = parseClientMessage({
      t: 'settings.apply',
      rid: 'r',
      key: 'agents.defaultProvider',
      value: 'custom:my-agent',
    })
    expect(provider.ok).toBe(true)
    if (provider.ok && provider.message.t === 'settings.apply') {
      expect(provider.message.key).toBe('agents.defaultProvider')
      expect(provider.message.value).toBe('custom:my-agent')
    }
  })
})

/* --------------------------------------------------------- the parser out -- */

describe('parseServerMessage reads the three settings frames', () => {
  it('round-trips a settings.state, the chooser carrying its options', () => {
    const raw = JSON.stringify({
      t: 'settings.state',
      rid: 'set-1',
      settings: [
        { key: 'agents.defaultProvider', value: 'claude', options: ['claude', 'codex', 'gemini', 'shell'] },
        { key: 'general.restoreSessions', value: 'true' },
      ],
    })
    const result = parseServerMessage(raw)
    expect(result.ok).toBe(true)
    if (result.ok && result.message.t === 'settings.state') {
      expect(result.message.settings).toHaveLength(2)
      expect(result.message.settings[0].options).toEqual(['claude', 'codex', 'gemini', 'shell'])
    }
  })

  it('drops a row naming a key this machine does not own', () => {
    // The defence in depth: even if a host sent one, no `remote.*` row is drawn.
    const raw = JSON.stringify({
      t: 'settings.state',
      rid: 'set-1',
      settings: [
        { key: 'remote.enabled', value: 'true' },
        { key: 'agents.defaultProvider', value: 'codex' },
        { key: 'advanced.debugMode', value: 'true' },
      ],
    })
    const result = parseServerMessage(raw)
    expect(result.ok).toBe(true)
    if (result.ok && result.message.t === 'settings.state') {
      expect(result.message.settings).toHaveLength(1)
      expect(result.message.settings[0].key).toBe('agents.defaultProvider')
    }
  })

  it('round-trips a settings.applied and refuses one with no legible setting', () => {
    const good = parseServerMessage(
      JSON.stringify({
        t: 'settings.applied',
        rid: 'set-2',
        ok: true,
        message: 'Default coding tool set to Codex CLI.',
        setting: { key: 'agents.defaultProvider', value: 'codex' },
      }),
    )
    expect(good.ok).toBe(true)
    if (good.ok && good.message.t === 'settings.applied') {
      expect(good.message.ok).toBe(true)
      expect(good.message.setting.value).toBe('codex')
    }
    // A `setting` naming a key this machine does not own reads as null, and the
    // whole frame is refused — there is nothing a pane could settle on.
    const bad = parseServerMessage(
      JSON.stringify({ t: 'settings.applied', rid: 'set-2', ok: true, message: 'x', setting: { key: 'remote.enabled', value: 'true' } }),
    )
    expect(bad.ok).toBe(false)
  })

  it('round-trips a settings.changed and drops its junk rows', () => {
    const result = parseServerMessage(
      JSON.stringify({
        t: 'settings.changed',
        settings: [{ key: 'general.restoreSessions', value: 'false' }, { key: 'remote.enabled', value: 'true' }, 7, null],
      }),
    )
    expect(result.ok).toBe(true)
    if (result.ok && result.message.t === 'settings.changed') {
      expect(result.message.settings).toHaveLength(1)
      expect(result.message.settings[0].key).toBe('general.restoreSessions')
    }
  })

  it('serverSettingWire clips the options list and refuses a non-string key', () => {
    expect(serverSettingWire(null)).toBeNull()
    expect(serverSettingWire({ key: 'remote.enabled', value: 'true' })).toBeNull()
    const wire = serverSettingWire({
      key: 'agents.defaultProvider',
      value: 'claude',
      options: Array.from({ length: 500 }, (_, i) => `p${i}`),
    })
    expect(wire).not.toBeNull()
    expect(wire?.options?.length).toBeLessThanOrEqual(64)
  })
})

/* ------------------------------------------------------ the store side of it -- */

describe('ServerSettingsAccess reads and writes the one store', () => {
  let dir = ''

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'td-server-settings-'))
    installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  })

  afterAll(() => {
    resetPaths()
    rmSync(dir, { recursive: true, force: true })
  })

  it('read() returns exactly the SERVER_SETTINGS rows and nothing else', () => {
    const access = createServerSettingsAccess()
    const rows = access.read()
    expect(rows.map((row) => row.key).sort()).toEqual([...SERVER_SETTINGS].sort())
    // No row can ever name a key outside the allowlist.
    for (const row of rows) {
      expect(SERVER_SETTINGS).toContain(row.key)
    }
    // The chooser carries its options; the boolean does not.
    const chooser = rows.find((row) => row.key === 'agents.defaultProvider')
    expect(chooser?.options).toBeDefined()
    expect(chooser?.options?.length).toBeGreaterThan(0)
    const toggle = rows.find((row) => row.key === 'general.restoreSessions')
    expect(toggle?.options).toBeUndefined()
    expect(toggle?.value === 'true' || toggle?.value === 'false').toBe(true)
  })

  it('applies a provider it can start and reflects it on the next read', () => {
    const access = createServerSettingsAccess()
    const before = access.read().find((row) => row.key === 'agents.defaultProvider')?.value
    const target = before === 'codex' ? 'gemini' : 'codex'
    const applied = access.apply('agents.defaultProvider', target)
    expect(applied.ok).toBe(true)
    expect(applied.setting.value).toBe(target)
    expect(store().getPreferences().defaultProvider).toBe(target)
    expect(access.read().find((row) => row.key === 'agents.defaultProvider')?.value).toBe(target)
  })

  it('refuses a provider it cannot start with a sentence, and writes nothing', () => {
    const access = createServerSettingsAccess()
    const before = store().getPreferences().defaultProvider
    const refused = access.apply('agents.defaultProvider', 'not-a-real-tool')
    expect(refused.ok).toBe(false)
    expect(refused.message.length).toBeGreaterThan(0)
    // The row it reports is the one on disk, not the one that was refused.
    expect(refused.setting.value).toBe(before)
    expect(store().getPreferences().defaultProvider).toBe(before)
  })

  it('takes the boolean as a word and refuses anything that is not on or off', () => {
    const access = createServerSettingsAccess()
    expect(access.apply('general.restoreSessions', 'false').ok).toBe(true)
    expect(store().getPreferences().restoreSessions).toBe(false)
    expect(access.apply('general.restoreSessions', 'true').ok).toBe(true)
    expect(store().getPreferences().restoreSessions).toBe(true)
    const before = store().getPreferences().restoreSessions
    expect(access.apply('general.restoreSessions', 'maybe').ok).toBe(false)
    expect(store().getPreferences().restoreSessions).toBe(before)
  })

  it('asserts allowlist membership again under the parser, and writes nothing for a stray key', () => {
    const access = createServerSettingsAccess()
    const before = store().getPreferences().defaultProvider
    // A caller reaching this in-process is not bounded by the wire; the key is
    // cast to feign the shape the parser would already have refused.
    const result = access.apply('remote.enabled' as (typeof SERVER_SETTINGS)[number], 'true')
    expect(result.ok).toBe(false)
    expect(store().getPreferences().defaultProvider).toBe(before)
  })

  it('fires onChanged on apply and on noteChanged, and stops after unsubscribe', () => {
    const access = createServerSettingsAccess()
    let fired = 0
    const off = access.onChanged(() => {
      fired += 1
    })
    access.apply('general.restoreSessions', 'false')
    expect(fired).toBe(1)
    access.noteChanged()
    expect(fired).toBe(2)
    // A refused apply does not fire — nothing changed.
    access.apply('agents.defaultProvider', 'not-a-real-tool')
    expect(fired).toBe(2)
    off()
    access.noteChanged()
    expect(fired).toBe(2)
  })
})
