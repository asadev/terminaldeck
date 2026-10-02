import { describe, expect, it, vi } from 'vitest'
import { fakeContext, tool } from './agents-area.fixture'
import { appTools, type AppToolDeps, type UpdateControllerLike } from './app-tools'

function controller(phase: string): UpdateControllerLike {
  return {
    state: () => ({ phase }),
    check: async () => ({ phase: 'available', version: '0.17.0' }),
    download: async () => ({ phase: 'ready', version: '0.17.0' }),
    installNow: async () => ({ phase: 'ready', version: '0.17.0' }),
  }
}

function deps(overrides: Partial<AppToolDeps> = {}): AppToolDeps {
  return {
    about: () => ({ version: '0.16.0' }),
    brand: () => ({ name: 'Deck', tagline: 'agents' }),
    paths: () => [{ key: 'logs', label: 'Logs', purpose: '', path: '/state/logs', kind: 'folder', exists: true }],
    logStatus: () => ({ bytes: 10 }),
    openPath: async (key) => ({ opened: true, path: `/state/${key}`, message: 'Opened.' }),
    openLogFolder: async () => '',
    diagnostics: async ({ text }) => (text ? 'report' : { app: {} }),
    recentLog: (lines) => ({ file: '/state/log.txt', lines: Array.from({ length: Math.min(lines, 3) }, (_, i) => `line ${i}`) }),
    recentCalls: () => [{ channel: 'prefs:get', ms: 1, ok: true }],
    clearLog: () => undefined,
    clearCalls: () => undefined,
    clearBrowserData: async () => ({ cleared: true, message: 'Gone.' }),
    updates: () => controller('idle'),
    ...overrides,
  }
}

describe('settings.reset', () => {
  it('resets everything a model may touch and leaves every protected key exactly as it was', async () => {
    const { context, record } = fakeContext()
    const out = await tool(appTools(deps()), 'settings.reset').run({}, context)
    expect(out.value).toMatchObject({
      reset: ['appearance.density', 'editor.font'],
      kept: ['remote.enabled', 'advanced.debugMode'],
      snapshot: '/state/settings.last-good.json',
    })
    expect(record.settings).toEqual({ 'remote.enabled': true, 'advanced.debugMode': false })
  })

  it('saves the way back before it writes', async () => {
    const { context, record } = fakeContext()
    await tool(appTools(deps()), 'settings.reset').run({}, context)
    expect(record.trace).toEqual(['snapshot', 'write:appearance.density,editor.font'])
  })

  it('names in the dialog exactly the keys that will change', () => {
    const { context } = fakeContext()
    expect(tool(appTools(deps()), 'settings.reset').summary({}, context)).toBe(
      'Reset 2 settings to defaults: appearance.density, editor.font',
    )
  })
})

describe('updates', () => {
  it('reports the last answer, or asks the server when told to', async () => {
    const { context } = fakeContext()
    const spec = tool(appTools(deps()), 'updates.status')
    await expect(spec.run({}, context)).resolves.toMatchObject({ value: { phase: 'idle' } })
    await expect(spec.run({ check: true }, context)).resolves.toMatchObject({ value: { phase: 'available' } })
  })

  it('installs only a downloaded update, and says the connection will drop', async () => {
    const installNow = vi.fn(async () => ({ phase: 'ready' }))
    const { context } = fakeContext()
    const idle = tool(appTools(deps({ updates: () => ({ ...controller('idle'), installNow }) })), 'updates.install')
    await expect(idle.run({}, context)).rejects.toThrow(/no downloaded update/)
    expect(installNow).not.toHaveBeenCalled()
    expect(idle.description).toMatch(/connection drops and comes back/)
    expect(idle.tier).toBe('alter')

    const ready = tool(appTools(deps({ updates: () => ({ ...controller('ready'), installNow }) })), 'updates.install')
    await ready.run({}, context)
    expect(installNow).toHaveBeenCalledTimes(1)
  })

  it('says so when there is no updater at all', async () => {
    const { context } = fakeContext()
    await expect(tool(appTools(deps({ updates: () => null })), 'updates.status').run({}, context)).rejects.toThrow(/no updater/)
  })
})

describe('logs and places', () => {
  it('reads either the app log or the internal call record', async () => {
    const { context } = fakeContext()
    const spec = tool(appTools(deps()), 'app.log')
    await expect(spec.run({ lines: 2 }, context)).resolves.toMatchObject({ value: { source: 'app', lines: ['line 0', 'line 1'] } })
    await expect(spec.run({ source: 'calls' }, context)).resolves.toMatchObject({ value: { source: 'calls' } })
  })

  it('clears the one it is told to', async () => {
    const clearLog = vi.fn()
    const clearCalls = vi.fn()
    const { context } = fakeContext()
    await tool(appTools(deps({ clearLog, clearCalls })), 'app.clear_log').run({ source: 'calls' }, context)
    expect(clearCalls).toHaveBeenCalled()
    expect(clearLog).not.toHaveBeenCalled()
  })

  it('reveals the log folder by its own route, and a place by key', async () => {
    const openLogFolder = vi.fn(async () => '')
    const openPath = vi.fn(deps().openPath)
    const { context } = fakeContext()
    const spec = tool(appTools(deps({ openLogFolder, openPath })), 'app.reveal')
    await spec.run({ place: 'logs' }, context)
    await spec.run({ place: 'settings' }, context)
    expect(openLogFolder).toHaveBeenCalledTimes(1)
    expect(openPath).toHaveBeenCalledWith('settings')
  })
})
