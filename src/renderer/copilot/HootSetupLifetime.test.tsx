import { readFileSync } from 'node:fs'
import { renderToStaticMarkup } from 'react-dom/server'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { useCopilotSetup, type CopilotSetup } from './useCopilotSetup'
import type { CopilotBridge } from '../settings/sections/copilot-bridge'

function open(read: CopilotBridge['copilotReadInstructions']): CopilotSetup {
  let result!: CopilotSetup
  function Capture() { result = useCopilotSetup({ copilotReadInstructions: read }); return null }
  renderToStaticMarkup(<Capture />)
  return result
}

const values = new Map<string, string>()
beforeEach(() => {
  values.clear()
  vi.stubGlobal('localStorage', { getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value) })
})
afterEach(() => vi.unstubAllGlobals())

describe('Hoot setup lifetime', () => {
  it('offers setup only for instructions without a completed identity block', async () => {
    const read = vi.fn().mockResolvedValue({ ok: true, text: '# Instructions\n' })
    expect(await open(read).hasRun()).toBe(false)
    expect(await open(async () => ({ ok: true, text: '## Who you are\n\nNo name chosen.' })).hasRun()).toBe(true)
  })
  it('remembers Close across a new window, without changing instructions', async () => {
    const read = vi.fn().mockResolvedValue({ ok: true, text: '' })
    const first = open(read)
    expect(await first.hasRun()).toBe(false)
    first.dismiss()
    expect(await first.hasRun()).toBe(true)
    read.mockClear()
    expect(await open(read).hasRun()).toBe(true)
    expect(read).not.toHaveBeenCalled()
  })
  it('a dismissal wins over an instructions read already in flight', async () => {
    let resolve!: (value: unknown) => void
    const read = vi.fn(() => new Promise<unknown>((done) => { resolve = done }))
    const setup = open(read)
    const pending = setup.hasRun()
    expect(read).toHaveBeenCalledTimes(1)
    setup.dismiss()
    resolve({ ok: true, text: '' })
    expect(await pending).toBe(true)
  })
  it('keeps dismissal for the window if persistent storage is unavailable', async () => {
    vi.stubGlobal('localStorage', { getItem: () => { throw Error('denied') }, setItem: () => { throw Error('denied') } })
    const setup = open(async () => ({ ok: true, text: '' }))
    setup.dismiss()
    expect(await setup.hasRun()).toBe(true)
  })
  it('offers missing instructions but does not treat an unreadable file as incomplete', async () => {
    expect(await open(async () => ({ ok: false, error: 'There are no instructions yet. Create its files first.' })).hasRun()).toBe(false)
    expect(await open(async () => ({ ok: false, error: 'Permission denied' })).hasRun()).toBe(true)
  })
  it('does not infer incomplete setup from a failed channel', async () => {
    expect(await open(async () => { throw Error('offline') }).hasRun()).toBe(true)
  })
  it('closes both page setup variants and fences late opens after navigation', () => {
    const app = readFileSync(new URL('../App.tsx', import.meta.url), 'utf8')
    for (const marker of ['const selectTab = useCallback(', 'const showPanel = useCallback(']) {
      expect(app.slice(app.indexOf(marker), app.indexOf(marker) + 160)).toContain('closeHootSetup()')
    }
    expect(app).toContain('if (request !== hootSetupRequest.current) return')
    expect(app).toContain('onClose={closeHootSetup}')
    const handler = app.slice(app.indexOf('dialogHandlers.current[NATIVE_DIALOGS.copilotSetup]'), app.indexOf("/* Hoot's permission"))
    expect(handler).toContain('closeHootSetup()')
    const native = readFileSync(new URL('../../../macos/TerminalDeckNative/Sources/TerminalDeckNative/NativeAppDialogs.swift', import.meta.url), 'utf8')
    expect(native).toContain('.onChange(of: model.currentScreen?.id)')
    expect(native).toContain('guard kind == "hoot" || kind == "copilot" else { return nil }')
    expect(native).toContain('model.answerDialog(NativeDialogName.copilotSetup, "close")')
  })
})
