import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { ActionLog } from '../deck-control/action-log'
import { browserTools } from '../deck-control/browser-tools'
import { browserNetworkTool } from '../deck-control/browser-network-tool'
import { ConsentBroker, WINDOW_SURFACE } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { Caller, DeckSurface } from '../deck-control/surface'
import {
  createNativeBrowserDriver,
  nativeBrowserTools,
  NATIVE_BROWSER_COMMAND,
  NATIVE_BROWSER_VERBS,
  NO_NATIVE_BROWSER,
} from './native-browser'

/**
 * The agents' browser tools in the native shell, against a fake native browser:
 * every command it is pushed is recorded, and it answers the way the test says.
 */

interface Command {
  id: string
  verb: string
  args: Record<string, unknown>
  session: { sessionId: string; machineId: string } | null
}

function rig(options: { listening?: boolean; answer?: (command: Command) => unknown; timeoutMs?: number } = {}) {
  const commands: Command[] = []
  const asked: string[] = []
  // The person, clicking Allow on every question — and counting them.
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      asked.push(request.tool)
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  const driver = createNativeBrowserDriver({
    push: (channel, args) => {
      if (options.listening === false) return false
      expect(channel).toBe(NATIVE_BROWSER_COMMAND)
      const command = args[0] as Command
      commands.push(command)
      const answer = options.answer
      if (answer !== undefined) queueMicrotask(() => driver.settle(command.id, answer(command)))
      return true
    },
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: () => options.timeoutMs as number }),
  })
  const drive = {} as BrowserDrive
  const deck = new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir }),
    consent: broker,
    extraTools: nativeBrowserTools([...browserTools(drive), browserNetworkTool(drive)], driver),
  })
  return { deck, driver, commands, asked }
}

let dir = ''
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-native-browser-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the agents’ browser tools in the native shell', () => {
  it('push a command and return the native browser’s answer', async () => {
    const { deck, commands } = rig({ answer: () => ({ value: { url: 'https://example.com/', title: 'Example' }, summary: { url: 'https://example.com/' } }) })
    const result = await deck.call('browser_open', { url: 'https://example.com' })
    expect(result.ok).toBe(true)
    expect(result.value).toEqual({ url: 'https://example.com/', title: 'Example' })
    expect(commands).toEqual([{ id: expect.any(String), verb: 'browser_open', args: { url: 'https://example.com' }, session: null }])
  })

  it('say who is calling, so a session can only drive its own windows', async () => {
    const session: Caller = { kind: 'session', sessionId: 's1', machineId: '', tiers: { read: true, act: true, alter: true } } as Caller
    const { deck, commands } = rig({ answer: () => ({ value: { outline: '…' } }) })
    const result = await deck.call('browser_read', { window: 'B1' }, { caller: session })
    expect(result.ok).toBe(true)
    expect(commands[0].session).toEqual({ sessionId: 's1', machineId: '' })
    expect(commands[0].args).toEqual({ window: 'B1' })
  })

  it('refuse plainly when no native window is there to answer', async () => {
    const { deck } = rig({ listening: false })
    const result = await deck.call('browser_read', {})
    expect(result.ok).toBe(false)
    expect(result.error).toBe(NO_NATIVE_BROWSER)
  })

  it('refuse plainly when the native browser does not answer in time', async () => {
    const { deck, driver } = rig({ timeoutMs: 20 })
    const result = await deck.call('browser_screenshot', {})
    expect(result.ok).toBe(false)
    expect(result.error).toMatch(/did not answer browser_screenshot within/)
    expect(driver.waiting()).toBe(0)
  })

  it('pass the native browser’s own refusal on in its words', async () => {
    const { deck } = rig({ answer: () => ({ error: 'That session has no window called B7.' }) })
    const result = await deck.call('browser_close', { sessionId: 's1', window: 'B7' })
    expect(result.ok).toBe(false)
    expect(result.error).toBe('That session has no window called B7.')
  })

  it('still refuse a paired device and an unattended run, before anything is pushed', async () => {
    const remote: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: true, alter: true } }
    const { deck, commands } = rig({ answer: () => ({ value: null }) })
    expect((await deck.call('browser_open', { url: 'https://x.test' }, { caller: remote })).refusal).toBe('not-granted')
    expect((await deck.call('browser_read', {}, { attended: false })).refusal).toBe('not-permitted-unattended')
    expect(commands).toEqual([])
  })

  it('put the first change on a public website to the person, once', async () => {
    const { deck, asked } = rig({
      answer: (command) => ({ value: command.verb === 'browser_open' ? { url: 'https://shop.example.com/cart' } : { done: true } }),
    })
    // Before the page is known, a step is asked about.
    await deck.call('browser_step', { verb: 'click', selector: '#a' })
    expect(asked).toEqual(['browser.step'])
    await deck.call('browser_open', { url: 'https://shop.example.com/cart' })
    await deck.call('browser_step', { verb: 'click', selector: '#buy' })
    expect(asked).toEqual(['browser.step', 'browser.step'])
    // Allowed once for that site on that window; the next click is not asked again.
    await deck.call('browser_step', { verb: 'click', selector: '#buy' })
    expect(asked).toEqual(['browser.step', 'browser.step'])
  })

  it('do not ask about the person’s own machine', async () => {
    const { deck, asked } = rig({
      answer: (command) => ({ value: command.verb === 'browser_open' ? { url: 'http://localhost:3000/' } : { done: true } }),
    })
    await deck.call('browser_open', { url: 'http://localhost:3000' })
    const result = await deck.call('browser_step', { verb: 'click', selector: '#go' })
    expect(result.ok).toBe(true)
    expect(result.row.tier).toBe('act')
    expect(asked).toEqual([])
  })

  it('are exactly the six verbs, under the names agents already know', () => {
    const { driver } = rig()
    const tools = nativeBrowserTools([...browserTools({} as BrowserDrive), browserNetworkTool({} as BrowserDrive)], driver)
    expect(tools.map((tool) => tool.wire).sort()).toEqual([...NATIVE_BROWSER_VERBS].sort())
    const original = browserTools({} as BrowserDrive).find((tool) => tool.wire === 'browser_open')
    const native = tools.find((tool) => tool.wire === 'browser_open')
    expect(native?.inputSchema).toEqual(original?.inputSchema)
    expect(native?.description).toBe(original?.description)
    expect(native?.tier).toBe(original?.tier)
  })

  it('ignore an answer nobody is waiting for', () => {
    const { driver } = rig()
    expect(driver.settle('nobody', { value: 1 })).toBe(false)
    expect(driver.settle(42, { value: 1 })).toBe(false)
  })
})
