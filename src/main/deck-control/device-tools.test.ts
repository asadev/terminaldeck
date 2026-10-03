import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { AnnotationRound } from '../../shared/annotate'
import type { DeviceNode } from '../../shared/device-tree'
import type { DeviceEntry } from '../devices/inventory'
import type { DeviceDetails, Orientation, TreeAnswer } from '../devices/session'
import { ActionLog } from './action-log'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import {
  DEFAULT_TREE_NODES,
  DEVICE_BUTTONS,
  DEVICE_ID,
  DEVICE_KEYS,
  DEVICE_MODIFIERS,
  deviceTools,
  directionPath,
  MAX_CANDIDATES,
  MAX_HOLD_MS,
  MAX_ROUNDS,
  MAX_TREE_NODES,
  type DeviceToolDeps,
} from './device-tools'
import { ALL_TIERS as ALL, type Caller, type DeckSurface } from './surface'

/**
 * The `devices.*` surface, driven with no engine and no Electron.
 *
 * Everything that touches a real phone — the engine, `simctl`, `adb` — is on
 * the far side of the deps, and `manager.ts` owns it. What is tested here is the
 * layer a model meets: that a call shaped wrong is refused before anything is
 * tapped, that a tap by name presses exactly one thing or nothing, that a
 * password typed into a phone never reaches the log, and that every answer
 * says plainly when it is empty and why.
 */

/* ------------------------------------------------------------------ fakes -- */

interface Call {
  name: string
  args: unknown[]
}

interface Fake extends DeviceToolDeps {
  calls: Call[]
  devices: DeviceEntry[]
  details: DeviceDetails
  screen: DeviceNode
  stored: AnnotationRound[]
  reason: string | null
  bootAnswer: { ok: true; id: string } | { ok: false; message: string }
  shutAnswer: { ok: true } | { ok: false; message: string }
  engineTruncated: boolean
  source: string
  fallback: string
}

function entry(over: Partial<DeviceEntry> = {}): DeviceEntry {
  return {
    id: 'ios:AAAA-1111',
    platform: 'ios',
    kind: 'simulator',
    state: 'ready',
    available: true,
    name: 'iPhone 17 Pro',
    runtime: 'iOS 27.0',
    canBoot: false,
    canShutDown: true,
    buttons: ['home', 'lock', 'volume-up', 'volume-down', 'action'],
    keys: ['return', 'delete', 'tab'],
    text: 'unicode',
    canRotate: true,
    note: '',
    ...over,
  }
}

function details(over: Partial<DeviceDetails> = {}): DeviceDetails {
  return {
    id: 'ios:AAAA-1111',
    name: 'iPhone 17 Pro',
    platform: 'ios',
    kind: 'simulator',
    pointWidth: 402,
    pointHeight: 874,
    buttons: ['home', 'lock', 'volume-up', 'volume-down', 'action'],
    keys: ['return', 'delete', 'tab'],
    text: 'unicode',
    canRotate: true,
    rawTouch: true,
    ...over,
  }
}

function frame(x: number, y: number, width: number, height: number): DeviceNode['frame'] {
  return { normalized: { x, y, width, height } }
}

/** A small checkout screen: a window, a group, a heading, a field, two buttons, a hidden sheet. */
function checkoutScreen(): DeviceNode {
  return {
    ref: 'r0',
    role: 'AXApplication',
    frame: frame(0, 0, 1, 1),
    children: [
      {
        ref: 'r1',
        role: 'AXGroup',
        frame: frame(0, 0, 1, 1),
        children: [
          { ref: 'r2', role: 'AXStaticText', label: 'Checkout', value: 'Checkout', frame: frame(0.1, 0.05, 0.8, 0.05) },
          {
            ref: 'r3',
            role: 'AXTextField',
            label: 'Password',
            identifier: 'password-field',
            valueRedacted: true,
            focused: true,
            frame: frame(0.1, 0.2, 0.8, 0.06),
          },
          {
            ref: 'r4',
            role: 'AXButton',
            label: 'Pay',
            identifier: 'pay-button',
            frame: frame(0.1, 0.8, 0.8, 0.08),
            // The text inside the button answers to the same name, at the same
            // centre: one place on the glass, not two.
            children: [{ ref: 'r5', role: 'AXStaticText', label: 'Pay', frame: frame(0.4, 0.82, 0.2, 0.04) }],
          },
          { ref: 'r6', role: 'AXButton', label: 'Cancel', enabled: false, frame: frame(0.1, 0.9, 0.3, 0.06) },
          // An unnamed icon button: no words, and still worth a row.
          { ref: 'r7', role: 'AXButton', frame: frame(0.9, 0.05, 0.08, 0.05) },
          {
            ref: 'r8',
            role: 'AXGroup',
            hidden: true,
            frame: frame(0, 0.5, 1, 0.5),
            children: [{ ref: 'r9', role: 'AXButton', label: 'Secret menu', frame: frame(0.1, 0.6, 0.3, 0.06) }],
          },
        ],
      },
    ],
  }
}

function fakeDeps(over: Partial<DeviceToolDeps> = {}): Fake {
  const calls: Call[] = []
  const note = (name: string, ...args: unknown[]): void => {
    calls.push({ name, args })
  }
  const deps: Fake = {
    calls,
    devices: [
      entry(),
      entry({
        id: 'avd:Pixel_9',
        platform: 'android',
        kind: 'emulator',
        state: 'shutdown',
        available: false,
        name: 'Pixel 9',
        runtime: '',
        canBoot: true,
        canShutDown: false,
        buttons: [],
        keys: [],
        text: 'none',
        canRotate: false,
      }),
      entry({
        id: 'android:R58M123',
        platform: 'android',
        kind: 'physical',
        state: 'unauthorized',
        available: false,
        name: 'Galaxy S25',
        note: 'Unlock the phone and allow this computer when it asks.',
      }),
    ],
    details: details(),
    screen: checkoutScreen(),
    stored: [],
    reason: null,
    bootAnswer: { ok: true, id: 'android:emulator-5554' },
    shutAnswer: { ok: true },
    engineTruncated: false,
    source: 'core-simulator-ax',
    fallback: '',
    unavailable: () => deps.reason,
    list: async () => {
      note('list')
      return deps.devices
    },
    boot: async (id) => {
      note('boot', id)
      return deps.bootAnswer
    },
    shutDown: async (id) => {
      note('shutDown', id)
      return deps.shutAnswer
    },
    open: async (id) => {
      note('open', id)
      return { ...deps.details, id }
    },
    screenshot: async (id) => {
      note('screenshot', id)
      return { path: '/Users/someone/Pictures/App/iPhone-17-Pro-20261003-142233.png', width: 1206, height: 2622 }
    },
    tap: async (id, x, y, holdMs) => note('tap', id, x, y, holdMs),
    swipe: async (id, from, to, durationMs) => note('swipe', id, from, to, durationMs),
    type: async (id, text) => note('type', id, text),
    key: async (id, key, modifiers) => note('key', id, key, modifiers),
    button: async (id, button) => note('button', id, button),
    rotate: async (id, to) => {
      note('rotate', id, to)
      return (to ?? 'landscape-left') as Orientation
    },
    tree: async (id, scope): Promise<TreeAnswer> => {
      note('tree', id, scope)
      return {
        tree: {
          source: deps.source,
          capturedAt: '2026-10-03T10:00:00.000Z',
          root: deps.screen,
          nodeCount: 10,
          truncated: deps.engineTruncated,
        },
        foreground: { app: 'com.example.Shop', screen: '' },
        fallback: deps.fallback,
      }
    },
    rounds: () => deps.stored,
    ...over,
  }
  return deps
}

function approving(): ConsentBroker {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return broker
}

function control(deps: DeviceToolDeps, logDir: string): DeckControl {
  return new DeckControl({
    // The device tools never reach the surface — they talk to their deps — so
    // an empty one is honest here. A tool that started using it would fail
    // loudly on its first call.
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: deviceTools(deps),
  })
}

function names(deps: Fake): string[] {
  return deps.calls.map((call) => call.name)
}

const IOS = 'ios:AAAA-1111'

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-device-tools-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/* -------------------------------------------------------------- the list -- */

describe('the catalogue these tools add', () => {
  const tools = deviceTools(fakeDeps())

  it('is eleven tools at the tiers a person would expect', () => {
    expect(Object.fromEntries(tools.map((tool) => [tool.id, tool.tier]))).toEqual({
      'devices.list': 'read',
      'devices.open': 'act',
      'devices.shutdown': 'act',
      'devices.screenshot': 'read',
      'devices.tap': 'act',
      'devices.swipe': 'act',
      'devices.type': 'act',
      'devices.button': 'act',
      'devices.tree': 'read',
      'devices.find': 'read',
      'devices.annotations': 'read',
    })
  })

  it('spends from the device input budget for fingers on the glass, and only for those', () => {
    // Starting and stopping a device stay on the shared change budget; they
    // are not part of tapping through an app. See `Budgets.deviceInput`.
    const spending = Object.fromEntries(tools.map((tool) => [tool.id, tool.spends ?? 'changes']))
    expect(spending).toMatchObject({
      'devices.tap': 'device-input',
      'devices.swipe': 'device-input',
      'devices.type': 'device-input',
      'devices.button': 'device-input',
      'devices.open': 'changes',
      'devices.shutdown': 'changes',
    })
  })

  it('spells every wire name as the dotted id with underscores', () => {
    for (const tool of tools) {
      expect(tool.wire).toBe(tool.id.replace(/\./g, '_'))
      expect(tool.wire).toMatch(/^[a-zA-Z0-9_-]{1,64}$/)
    }
  })

  it('holds every one behind tools.describe, each with a line a model can choose by', () => {
    /*
     * Eleven tools, and the standing catalogue does not grow by one of them:
     * each costs a line in the meta-tool's index. The same rules
     * `describe-tool.test.ts` holds every index line to.
     */
    for (const tool of tools) {
      const line = tool.index ?? ''
      expect(line.length, `${tool.id}'s index line is too short to choose by`).toBeGreaterThan(60)
      expect(line.length, `${tool.id}'s index line is a description, not a line`).toBeLessThan(200)
      expect(line, `${tool.id}'s index line is just its title`).not.toBe(tool.title)
      expect(line.trim(), `${tool.id}'s index line is not a sentence`).toMatch(/\.$/)
    }
  })

  it('says the coordinates are fractions wherever a position is taken', () => {
    for (const id of ['devices.list', 'devices.tap', 'devices.swipe', 'devices.tree']) {
      const tool = tools.find((one) => one.id === id)
      expect(tool?.description, id).toMatch(/fractions of the screen/)
    }
  })

  it('sits beside the built-in tools without colliding with one', () => {
    // `DeckControl` refuses a duplicate id at construction.
    expect(() => control(fakeDeps(), dir)).not.toThrow()
  })
})

describe('the vocabulary it shares with the Simulators page', () => {
  /*
   * `ipc.ts` imports Electron, so its sets are restated in `device-tools.ts`
   * rather than imported. This reads the page's file as text and fails the day
   * the two disagree about what an id looks like or which keys exist.
   */
  const source = readFileSync(join(__dirname, '../devices/ipc.ts'), 'utf8')

  function setIn(name: string): string[] {
    const match = new RegExp(`const ${name} = new Set\\(\\[([^\\]]*)\\]`).exec(source)
    expect(match, `${name} not found in ipc.ts`).not.toBeNull()
    return [...(match?.[1] ?? '').matchAll(/'([^']+)'/g)].map((one) => one[1]).sort()
  }

  it('checks a device id with exactly the page’s pattern', () => {
    expect(source).toContain(`const ID = /${DEVICE_ID.source}/`)
  })

  it('knows the same buttons, keys and modifiers', () => {
    expect(setIn('BUTTONS')).toEqual([...DEVICE_BUTTONS].sort())
    expect(setIn('KEYS')).toEqual([...DEVICE_KEYS].sort())
    expect(setIn('MODIFIERS')).toEqual([...DEVICE_MODIFIERS].sort())
  })
})

/* ------------------------------------------------------- refusing first -- */

const ENGINE_TOOLS: [string, Record<string, unknown>][] = [
  ['devices_open', { deviceId: IOS }],
  ['devices_shutdown', { deviceId: IOS }],
  ['devices_screenshot', { deviceId: IOS }],
  ['devices_tap', { deviceId: IOS, x: 0.5, y: 0.5 }],
  ['devices_swipe', { deviceId: IOS, direction: 'up' }],
  ['devices_type', { deviceId: IOS, text: 'hello' }],
  ['devices_button', { deviceId: IOS, button: 'home' }],
  ['devices_tree', { deviceId: IOS }],
  ['devices_find', { deviceId: IOS, name: 'Pay' }],
]

describe('a computer that cannot run the engine', () => {
  const SENTENCE = 'Simulators need a Mac with Apple silicon.'

  it.each(ENGINE_TOOLS)('refuses %s with the engine’s own sentence, before touching anything', async (tool, args) => {
    const deps = fakeDeps()
    deps.reason = SENTENCE
    const result = await control(deps, dir).call(tool, args)
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain(SENTENCE)
    // A fact about the computer, said so the model stops rather than loops.
    expect(result.error).toContain('do not retry')
    expect(deps.calls).toEqual([])
  })

  it('answers devices.list as empty, with the reason, rather than refusing the first reach', async () => {
    const deps = fakeDeps()
    deps.reason = SENTENCE
    const result = await control(deps, dir).call('devices_list', {})
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ available: false, devices: [], empty: true })
    expect((result.value as { emptyReason: string }).emptyReason).toContain(SENTENCE)
    expect(names(deps)).toEqual([])
  })

  it('still reads annotations, because a browser round needs no engine', async () => {
    const deps = fakeDeps()
    deps.reason = SENTENCE
    deps.stored = [round('r1', 'browser')]
    const result = await control(deps, dir).call('devices_annotations', {})
    expect(result.ok).toBe(true)
    expect((result.value as { rounds: unknown[] }).rounds).toHaveLength(1)
  })
})

describe('a device id that is not one', () => {
  it.each(ENGINE_TOOLS)('refuses %s with a bad id and sends the caller to devices.list', async (tool, args) => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call(tool, { ...args, deviceId: 'iPhone 17; rm -rf ~' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('Call devices.list first')
    expect(deps.calls).toEqual([])
  })

  it('names the missing argument when there is no id at all', async () => {
    const result = await control(fakeDeps(), dir).call('devices_tap', { x: 0.5, y: 0.5 })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('deviceId is required')
  })
})

/* ----------------------------------------------------------- devices.list -- */

describe('devices.list', () => {
  it('lists every device with its state in words and what it accepts', async () => {
    const result = await control(fakeDeps(), dir).call('devices_list', {})
    expect(result.ok).toBe(true)
    const value = result.value as { devices: Record<string, unknown>[]; usable: number; empty: boolean }
    expect(value.empty).toBe(false)
    expect(value.usable).toBe(1)
    expect(value.devices.map((row) => row.id)).toEqual(['ios:AAAA-1111', 'avd:Pixel_9', 'android:R58M123'])
    expect(value.devices[0]).toMatchObject({
      name: 'iPhone 17 Pro',
      platform: 'ios',
      kind: 'simulator',
      state: 'running',
      usable: true,
      runtime: 'iOS 27.0',
      buttons: ['home', 'lock', 'volume-up', 'volume-down', 'action'],
      text: 'unicode',
    })
    expect(value.devices[1]).toMatchObject({ state: 'off', canStart: true })
    expect(value.devices[2]).toMatchObject({
      state: 'waiting for you to allow this computer on the phone',
      note: 'Unlock the phone and allow this computer when it asks.',
    })
  })

  it('says what to install when there is nothing to list', async () => {
    const deps = fakeDeps()
    deps.devices = []
    const result = await control(deps, dir).call('devices_list', {})
    expect(result.value).toMatchObject({ devices: [], empty: true })
    const reason = (result.value as { emptyReason: string }).emptyReason
    expect(reason).toContain('Xcode')
    expect(reason).toContain('Android Studio')
  })
})

/* ----------------------------------------------------------- devices.open -- */

describe('devices.open', () => {
  it('opens a running simulator without starting it', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_open', { deviceId: IOS })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ id: IOS, started: false, device: { name: 'iPhone 17 Pro' } })
    expect(names(deps)).toEqual(['list', 'open'])
  })

  it('starts an emulator that is off and hands back the id it runs under', async () => {
    /*
     * `avd:<name>` names an emulator only while it is off. Once it runs, every
     * other call must use `android:emulator-<port>`, and a model that kept the
     * old id would be refused on its very next tap — so the answer says so.
     */
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_open', { deviceId: 'avd:Pixel_9' })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ id: 'android:emulator-5554', started: true })
    expect((result.value as { note: string }).note).toContain('Use that id for every call from here on')
    expect(deps.calls).toEqual([
      { name: 'list', args: [] },
      { name: 'boot', args: ['avd:Pixel_9'] },
      { name: 'open', args: ['android:emulator-5554'] },
    ])
  })

  it('refuses an id that is not on this computer now', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_open', { deviceId: 'ios:GONE' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('Call devices.list')
    expect(names(deps)).toEqual(['list'])
  })

  it('refuses a phone that has not allowed this computer, with what to do about it', async () => {
    const result = await control(fakeDeps(), dir).call('devices_open', { deviceId: 'android:R58M123' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('Unlock the phone')
  })

  it('reports a device that would not start as a fault, in the platform’s words', async () => {
    const deps = fakeDeps()
    deps.bootAnswer = { ok: false, message: 'The emulator did not start.' }
    const result = await control(deps, dir).call('devices_open', { deviceId: 'avd:Pixel_9' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBeNull()
    expect(result.error).toBe('The emulator did not start.')
    expect(names(deps)).not.toContain('open')
  })
})

/* ------------------------------------------------------- devices.shutdown -- */

describe('devices.shutdown', () => {
  it('shuts down a simulator', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_shutdown', { deviceId: IOS })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ id: IOS, shutDown: true, empty: false })
    expect(deps.calls).toEqual([{ name: 'shutDown', args: [IOS] }])
  })

  it('never powers down a phone on a cable, and says why before trying', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_shutdown', { deviceId: 'android:R58M123' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('turned off on the phone itself')
    expect(deps.calls).toEqual([])
  })

  it('shuts down an Android emulator by its running id', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_shutdown', { deviceId: 'android:emulator-5554' })
    expect(result.ok).toBe(true)
    expect(names(deps)).toEqual(['shutDown'])
  })

  it('answers an emulator that is already off as empty rather than pretending it did something', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_shutdown', { deviceId: 'avd:Pixel_9' })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ alreadyOff: true, empty: true })
    expect(deps.calls).toEqual([])
  })

  it('reports a shutdown that failed as a fault', async () => {
    const deps = fakeDeps()
    deps.shutAnswer = { ok: false, message: 'The simulator would not shut down.' }
    const result = await control(deps, dir).call('devices_shutdown', { deviceId: IOS })
    expect(result.ok).toBe(false)
    expect(result.error).toBe('The simulator would not shut down.')
  })
})

/* ----------------------------------------------------- devices.screenshot -- */

describe('devices.screenshot', () => {
  it('answers the path and size, never the image', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_screenshot', { deviceId: IOS })
    expect(result.ok).toBe(true)
    expect(result.value).toEqual({
      deviceId: IOS,
      path: '/Users/someone/Pictures/App/iPhone-17-Pro-20261003-142233.png',
      width: 1206,
      height: 2622,
    })
  })

  it('refuses a session on another computer, and points it at the tree rather than at a browser', async () => {
    /*
     * The decision is `browser-tools.ts`'s and is shared; the advice is not,
     * because "use browser.read" sent about a phone would send a model off to
     * read a web page.
     */
    const elsewhere: Caller = { kind: 'session', sessionId: 's1', machineId: 'server-1', tiers: ALL }
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_screenshot', { deviceId: IOS }, { caller: elsewhere })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('Use devices.tree')
    expect(result.error).not.toContain('browser.read')
    expect(deps.calls).toEqual([])
  })

  it('saves the picture for a caller reaching in from elsewhere, and says the path is not theirs to open', async () => {
    const phone: Caller = { kind: 'remote', deviceId: 'd1', tiers: ALL }
    const result = await control(fakeDeps(), dir).call('devices_screenshot', { deviceId: IOS }, { caller: phone })
    expect(result.ok).toBe(true)
    expect((result.value as { note: string }).note).toContain('not a file you can open')
  })
})

/* ------------------------------------------------------------ devices.tap -- */

describe('devices.tap at a position', () => {
  it('taps the point it was given', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, x: 0.25, y: 0.75 })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ tapped: { x: 0.25, y: 0.75 }, longPress: false, element: null })
    expect(deps.calls).toEqual([{ name: 'tap', args: [IOS, 0.25, 0.75, undefined] }])
  })

  it('refuses pixels rather than clamping them onto the edge of the screen', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, x: 540, y: 0.5 })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('looks like pixels')
    expect(deps.calls).toEqual([])
  })

  it('refuses half a position', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, x: 0.5 })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('both x and y')
    expect(deps.calls).toEqual([])
  })

  it('refuses a position and a name together, because they could disagree', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, x: 0.5, y: 0.5, name: 'Pay' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('not both')
    expect(deps.calls).toEqual([])
  })

  it('refuses a tap that says nowhere', async () => {
    const result = await control(fakeDeps(), dir).call('devices_tap', { deviceId: IOS })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('Say where to tap')
  })

  it('makes a long press of a hold, and caps the hold', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, x: 0.5, y: 0.5, holdMs: 60_000 })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ longPress: true, holdMs: MAX_HOLD_MS })
    expect(deps.calls[0].args).toEqual([IOS, 0.5, 0.5, MAX_HOLD_MS])
    expect(result.row.detail).toContain('Long-press')
  })
})

describe('devices.tap by name', () => {
  it('taps the centre of the one element that matches, read fresh', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, identifier: 'password-field' })
    expect(result.ok).toBe(true)
    expect(deps.calls).toEqual([
      { name: 'tree', args: [IOS, 'visible'] },
      { name: 'tap', args: [IOS, 0.5, 0.23, undefined] },
    ])
    expect(result.value).toMatchObject({
      tapped: { x: 0.5, y: 0.23 },
      element: { role: 'text field', name: 'Password', identifier: 'password-field', secret: true },
    })
  })

  it('counts a button and the text inside it as one place, and names the button', async () => {
    /*
     * Both answer to "Pay" and both centres are the same point. Refusing that
     * as ambiguous would refuse over a difference that does not exist on the
     * glass; tapping either is the same tap.
     */
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, name: 'pay' })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ tapped: { x: 0.5, y: 0.84 }, element: { role: 'button', identifier: 'pay-button' } })
  })

  it('taps nothing when several different elements match, and lists them with their centres', async () => {
    const deps = fakeDeps()
    const many: DeviceNode[] = Array.from({ length: 8 }, (_, index) => ({
      ref: `b${index}`,
      role: 'AXButton',
      label: 'Delete',
      identifier: `delete-${index}`,
      frame: frame(0.8, 0.1 * index, 0.15, 0.05),
    }))
    deps.screen = { ref: 'root', role: 'AXApplication', frame: frame(0, 0, 1, 1), children: many }
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, name: 'Delete' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('8 different elements')
    expect(result.error).toContain('Nothing was tapped')
    expect(result.error).toContain('delete-0')
    expect(result.error).toContain(`delete-${MAX_CANDIDATES - 1}`)
    expect(result.error).not.toContain(`delete-${MAX_CANDIDATES}`)
    expect(result.error).toContain('at x 0.875, y 0.025')
    expect(names(deps)).toEqual(['tree'])
  })

  it('taps nothing when nothing matches, and offers the near misses', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, name: 'Canc' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('Nothing on the screen matches')
    expect(result.error).toContain('Close: button "Cancel"')
    expect(names(deps)).toEqual(['tree'])
  })

  it('will not tap something hidden, even by its exact name', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tap', { deviceId: IOS, name: 'Secret menu' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('hidden or scrolled away')
    expect(names(deps)).toEqual(['tree'])
  })
})

/* ---------------------------------------------------------- devices.swipe -- */

describe('devices.swipe', () => {
  it('reads a direction as the way the finger travels, a quarter in from every edge', () => {
    expect(directionPath('up')).toEqual({ from: { x: 0.5, y: 0.75 }, to: { x: 0.5, y: 0.25 } })
    expect(directionPath('down')).toEqual({ from: { x: 0.5, y: 0.25 }, to: { x: 0.5, y: 0.75 } })
    expect(directionPath('left')).toEqual({ from: { x: 0.75, y: 0.5 }, to: { x: 0.25, y: 0.5 } })
    expect(directionPath('right')).toEqual({ from: { x: 0.25, y: 0.5 }, to: { x: 0.75, y: 0.5 } })
  })

  it('sends a direction as that path, at the default speed', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_swipe', { deviceId: IOS, direction: 'up' })
    expect(result.ok).toBe(true)
    expect(deps.calls).toEqual([{ name: 'swipe', args: [IOS, { x: 0.5, y: 0.75 }, { x: 0.5, y: 0.25 }, 300] }])
    expect(result.row.detail).toContain('Swipe up')
  })

  it('sends two points as given, and keeps the duration inside the page’s bounds', async () => {
    const deps = fakeDeps()
    await control(deps, dir).call('devices_swipe', {
      deviceId: IOS,
      from: { x: 0.1, y: 0.5 },
      to: { x: 0.9, y: 0.5 },
      durationMs: 10,
    })
    expect(deps.calls).toEqual([{ name: 'swipe', args: [IOS, { x: 0.1, y: 0.5 }, { x: 0.9, y: 0.5 }, 50] }])
  })

  it('refuses a direction and points together', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_swipe', {
      deviceId: IOS,
      direction: 'up',
      from: { x: 0.1, y: 0.5 },
      to: { x: 0.9, y: 0.5 },
    })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('not both')
    expect(deps.calls).toEqual([])
  })

  it('refuses a swipe with one end, and a point in pixels', async () => {
    const deck = control(fakeDeps(), dir)
    const half = await deck.call('devices_swipe', { deviceId: IOS, from: { x: 0.1, y: 0.5 } })
    expect(half.ok).toBe(false)
    expect(half.error).toContain('Say how to swipe')
    const pixels = await deck.call('devices_swipe', { deviceId: IOS, from: { x: 100, y: 0.5 }, to: { x: 0.9, y: 0.5 } })
    expect(pixels.ok).toBe(false)
    expect(pixels.error).toContain('from.x')
  })
})

/* ----------------------------------------------------------- devices.type -- */

describe('devices.type', () => {
  const SENTINEL = 'correct-horse-battery-staple-7731'

  it('types the text, then presses the key', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_type', {
      deviceId: IOS,
      text: 'hello',
      key: 'return',
    })
    expect(result.ok).toBe(true)
    expect(deps.calls).toEqual([
      { name: 'open', args: [IOS] },
      { name: 'type', args: [IOS, 'hello'] },
      { name: 'key', args: [IOS, 'return', []] },
    ])
    expect(result.value).toMatchObject({ typedCharacters: 5, pressed: 'return' })
  })

  it('keeps the typed text out of the action log, and writes its length instead', async () => {
    /*
     * The field with focus may be a password. `scrubArgs` redacts by key name
     * and nothing called `text` matches it, so without `redactArgs` this exact
     * call would land in `actions.jsonl` verbatim.
     */
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_type', { deviceId: IOS, text: SENTINEL })
    expect(result.ok).toBe(true)
    // The device was really sent it — redaction is about the record, not the act.
    expect(deps.calls).toContainEqual({ name: 'type', args: [IOS, SENTINEL] })
    const written = readFileSync(join(dir, 'actions.jsonl'), 'utf8')
    expect(written).not.toContain(SENTINEL)
    expect(written).toContain(`[${SENTINEL.length} characters]`)
  })

  it('keeps the typed text out of the sentence a person reads and out of the result', async () => {
    const result = await control(fakeDeps(), dir).call('devices_type', { deviceId: IOS, text: SENTINEL })
    expect(result.row.detail).not.toContain(SENTINEL)
    expect(result.row.detail).toContain(`${SENTINEL.length} characters`)
    expect(JSON.stringify(result.value)).not.toContain(SENTINEL)
    expect(JSON.stringify(result.row)).not.toContain(SENTINEL)
  })

  it('refuses modifiers with no key to hold them on, and an empty call', async () => {
    const deps = fakeDeps()
    const deck = control(deps, dir)
    const mods = await deck.call('devices_type', { deviceId: IOS, text: 'a', modifiers: ['command'] })
    expect(mods.ok).toBe(false)
    expect(mods.error).toContain('need a key')
    const nothing = await deck.call('devices_type', { deviceId: IOS })
    expect(nothing.ok).toBe(false)
    expect(nothing.error).toContain('text to type, a key to press')
    expect(deps.calls).toEqual([])
  })

  it('refuses a key the page does not know, from the schema', async () => {
    const result = await control(fakeDeps(), dir).call('devices_type', { deviceId: IOS, key: 'f13' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('key must be one of')
  })

  it('refuses text longer than the page would type', async () => {
    const result = await control(fakeDeps(), dir).call('devices_type', { deviceId: IOS, text: 'x'.repeat(2_001) })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('Send it in parts')
  })

  it('refuses what the device cannot take, and types nothing', async () => {
    const ascii = fakeDeps()
    ascii.details = details({ text: 'ascii' })
    const accented = await control(ascii, dir).call('devices_type', { deviceId: IOS, text: 'café' })
    expect(accented.ok).toBe(false)
    expect(accented.error).toContain('plain ASCII')
    expect(names(ascii)).toEqual(['open'])

    const none = fakeDeps()
    none.details = details({ text: 'none' })
    const typed = await control(none, dir).call('devices_type', { deviceId: IOS, text: 'hi' })
    expect(typed.ok).toBe(false)
    expect(typed.error).toContain('does not accept typed text')

    const keys = fakeDeps()
    const escape = await control(keys, dir).call('devices_type', { deviceId: IOS, key: 'escape' })
    expect(escape.ok).toBe(false)
    expect(escape.error).toContain('It takes: return, delete, tab')
    expect(names(keys)).toEqual(['open'])
  })
})

/* --------------------------------------------------------- devices.button -- */

describe('devices.button', () => {
  it('presses a button the device has', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_button', { deviceId: IOS, button: 'home' })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ pressed: 'home' })
    expect(deps.calls).toEqual([
      { name: 'open', args: [IOS] },
      { name: 'button', args: [IOS, 'home'] },
    ])
  })

  it('refuses a button the device does not have, and presses nothing', async () => {
    // An iPhone has no back button. Pressing one would be an engine error at
    // best and a different button at worst.
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_button', { deviceId: IOS, button: 'back' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('has no back button')
    expect(result.error).toContain('It has: home, lock')
    expect(names(deps)).toEqual(['open'])
  })

  it('presses any listed button on a device that never said which it has', async () => {
    const deps = fakeDeps()
    deps.details = details({ buttons: [] })
    const result = await control(deps, dir).call('devices_button', { deviceId: IOS, button: 'back' })
    expect(result.ok).toBe(true)
    expect(names(deps)).toEqual(['open', 'button'])
  })

  it('refuses a button that is not a button at all, from the schema', async () => {
    const result = await control(fakeDeps(), dir).call('devices_button', { deviceId: IOS, button: 'power' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('button must be one of')
  })

  it('turns the device to the orientation asked for', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_button', { deviceId: IOS, rotate: 'landscape-right' })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ orientation: 'landscape-right' })
    expect(deps.calls).toContainEqual({ name: 'rotate', args: [IOS, 'landscape-right'] })
  })

  it('refuses to turn a device that does not turn', async () => {
    const deps = fakeDeps()
    deps.details = details({ canRotate: false })
    const result = await control(deps, dir).call('devices_button', { deviceId: IOS, rotate: 'portrait' })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('does not turn')
    expect(names(deps)).toEqual(['open'])
  })

  it('refuses a button and a rotation together, and neither', async () => {
    const deck = control(fakeDeps(), dir)
    const both = await deck.call('devices_button', { deviceId: IOS, button: 'home', rotate: 'portrait' })
    expect(both.ok).toBe(false)
    expect(both.error).toContain('not both')
    const neither = await deck.call('devices_button', { deviceId: IOS })
    expect(neither.ok).toBe(false)
    expect(neither.error).toContain('Give a button')
  })
})

/* ----------------------------------------------------------- devices.tree -- */

interface TreeValue {
  source: string
  foreground: { app: string; screen: string }
  elements: Record<string, unknown>[]
  shown: number
  total: number
  truncated: boolean
  note?: string
  empty: boolean
  emptyReason: string
}

describe('devices.tree', () => {
  it('lists what is on the screen, in reading order, with nothing a model would not act on', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_tree', { deviceId: IOS })
    expect(result.ok).toBe(true)
    const value = result.value as TreeValue
    expect(value.source).toBe('accessibility')
    expect(value.foreground).toEqual({ app: 'com.example.Shop', screen: '' })
    expect(deps.calls).toEqual([{ name: 'tree', args: [IOS, 'visible'] }])
    // The application and the anonymous group are scaffolding; the hidden
    // sheet is not on the screen, and nor is anything inside it.
    expect(value.elements).toEqual([
      { depth: 0, role: 'static text', name: 'Checkout', frame: { x: 0.1, y: 0.05, width: 0.8, height: 0.05 }, centre: { x: 0.5, y: 0.075 } },
      {
        depth: 0,
        role: 'text field',
        name: 'Password',
        identifier: 'password-field',
        secret: true,
        focused: true,
        frame: { x: 0.1, y: 0.2, width: 0.8, height: 0.06 },
        centre: { x: 0.5, y: 0.23 },
      },
      {
        depth: 0,
        role: 'button',
        name: 'Pay',
        identifier: 'pay-button',
        frame: { x: 0.1, y: 0.8, width: 0.8, height: 0.08 },
        centre: { x: 0.5, y: 0.84 },
      },
      { depth: 1, role: 'static text', name: 'Pay', frame: { x: 0.4, y: 0.82, width: 0.2, height: 0.04 }, centre: { x: 0.5, y: 0.84 } },
      {
        depth: 0,
        role: 'button',
        name: 'Cancel',
        enabled: false,
        frame: { x: 0.1, y: 0.9, width: 0.3, height: 0.06 },
        centre: { x: 0.25, y: 0.93 },
      },
      // An icon with no label: no name, and exactly what a centre is for.
      { depth: 0, role: 'button', frame: { x: 0.9, y: 0.05, width: 0.08, height: 0.05 }, centre: { x: 0.94, y: 0.075 } },
    ])
    expect(value).toMatchObject({ shown: 6, total: 6, truncated: false, empty: false })
    expect(JSON.stringify(value)).not.toContain('Secret menu')
    expect(JSON.stringify(value)).not.toContain('"ref"')
  })

  it('never hands back a password field’s value', async () => {
    const deps = fakeDeps()
    deps.screen = {
      ref: 'r',
      role: 'AXTextField',
      label: 'PIN',
      // `session.ts` deletes the value when the engine marks it redacted; this
      // checks the tool does not lean on that.
      value: '4821',
      valueRedacted: true,
      frame: frame(0.1, 0.1, 0.5, 0.1),
    }
    const result = await control(deps, dir).call('devices_tree', { deviceId: IOS })
    expect(JSON.stringify(result.value)).not.toContain('4821')
    expect((result.value as TreeValue).elements[0]).toMatchObject({ secret: true })
  })

  it('is bounded, and says how much it left out', async () => {
    const deps = fakeDeps()
    deps.screen = {
      ref: 'root',
      role: 'AXApplication',
      frame: frame(0, 0, 1, 1),
      children: Array.from({ length: 500 }, (_, index) => ({
        ref: `n${index}`,
        role: 'AXStaticText',
        label: `Row ${index}`,
        frame: frame(0, index / 500, 1, 1 / 500),
      })),
    }
    const deck = control(deps, dir)
    const first = (await deck.call('devices_tree', { deviceId: IOS })).value as TreeValue
    expect(first.elements).toHaveLength(DEFAULT_TREE_NODES)
    expect(first).toMatchObject({ shown: DEFAULT_TREE_NODES, total: 500, truncated: true })
    expect(first.note).toContain(`Showing ${DEFAULT_TREE_NODES} of 500`)

    const most = (await deck.call('devices_tree', { deviceId: IOS, limit: 10_000 })).value as TreeValue
    expect(most.elements).toHaveLength(MAX_TREE_NODES)

    const few = (await deck.call('devices_tree', { deviceId: IOS, limit: 3 })).value as TreeValue
    expect(few.elements.map((row) => row.name)).toEqual(['Row 0', 'Row 1', 'Row 2'])
  })

  it('says when the device itself stopped reading early', async () => {
    const deps = fakeDeps()
    deps.engineTruncated = true
    const value = (await control(deps, dir).call('devices_tree', { deviceId: IOS })).value as TreeValue
    expect(value.truncated).toBe(true)
    expect(value.note).toContain('stopped reading the screen early')
  })

  it('names the component and source file a React Native app reports', async () => {
    const deps = fakeDeps()
    deps.source = 'react-native-fiber'
    deps.screen = {
      ref: 'r',
      role: 'button',
      label: 'Buy now',
      testID: 'buy',
      component: 'BuyButton',
      sourceLocation: { file: 'src/screens/Product.tsx', line: 42, column: 7 },
      frame: frame(0.1, 0.8, 0.8, 0.1),
    }
    const value = (await control(deps, dir).call('devices_tree', { deviceId: IOS, scope: 'interactive' })).value as TreeValue
    expect(value.source).toBe('react-native-fiber')
    expect(value.elements[0]).toMatchObject({
      name: 'Buy now',
      identifier: 'buy',
      component: 'BuyButton',
      source: 'src/screens/Product.tsx:42:7',
    })
    expect(deps.calls).toEqual([{ name: 'tree', args: [IOS, 'interactive'] }])
  })

  it('passes on why the React Native tree was not used', async () => {
    const deps = fakeDeps()
    deps.fallback = 'Metro answered but the app is not connected to it.'
    const value = (await control(deps, dir).call('devices_tree', { deviceId: IOS })).value as TreeValue
    expect(value.note).toContain('Metro answered but the app is not connected to it.')
  })

  it('says a screen with nothing to list is empty, and what to do instead', async () => {
    const deps = fakeDeps()
    deps.screen = { ref: 'r', role: 'AXApplication', frame: frame(0, 0, 1, 1) }
    const value = (await control(deps, dir).call('devices_tree', { deviceId: IOS })).value as TreeValue
    expect(value.empty).toBe(true)
    expect(value.emptyReason).toContain('devices.screenshot')
  })
})

/* ----------------------------------------------------------- devices.find -- */

describe('devices.find', () => {
  it('finds by name and gives the centre to tap', async () => {
    const result = await control(fakeDeps(), dir).call('devices_find', { deviceId: IOS, name: 'cancel' })
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({
      count: 1,
      truncated: false,
      empty: false,
      matches: [{ role: 'button', name: 'Cancel', enabled: false, centre: { x: 0.25, y: 0.93 } }],
    })
  })

  it('matches whole names unless asked for part of one', async () => {
    const deck = control(fakeDeps(), dir)
    const whole = await deck.call('devices_find', { deviceId: IOS, name: 'Check' })
    expect(whole.value).toMatchObject({ count: 0, empty: true })
    expect((whole.value as { emptyReason: string }).emptyReason).toContain('partial: true')
    const part = await deck.call('devices_find', { deviceId: IOS, name: 'Check', partial: true })
    expect(part.value).toMatchObject({ count: 1, matches: [{ name: 'Checkout' }] })
  })

  it('finds by role in plain words, and leaves hidden elements out', async () => {
    const result = await control(fakeDeps(), dir).call('devices_find', { deviceId: IOS, role: 'button' })
    const matches = (result.value as { matches: { name?: string }[] }).matches
    expect(matches.map((match) => match.name)).toEqual(['Pay', 'Cancel', undefined])
  })

  it('refuses a find with nothing to look for', async () => {
    const deps = fakeDeps()
    const result = await control(deps, dir).call('devices_find', { deviceId: IOS })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('name, an identifier or a role')
    expect(deps.calls).toEqual([])
  })

  it('reads the scope it was asked for', async () => {
    const deps = fakeDeps()
    await control(deps, dir).call('devices_find', { deviceId: IOS, name: 'Pay', scope: 'full' })
    expect(deps.calls).toEqual([{ name: 'tree', args: [IOS, 'full'] }])
  })
})

/* ---------------------------------------------------- devices.annotations -- */

function round(id: string, kind: 'device' | 'browser', at = 1_790_000_000_000): AnnotationRound {
  return {
    id,
    createdAt: at,
    where:
      kind === 'device'
        ? { kind, place: 'iOS Simulator', name: 'iPhone 17 Pro', deviceId: IOS, app: 'com.example.Shop' }
        : { kind, place: 'browser page', name: 'Shop', url: 'https://shop.example.com/cart' },
    frame: { width: 1206, height: 2622 },
    annotations: [
      {
        id: 'a1',
        n: 1,
        rect: { x: 0.1, y: 0.8, width: 0.8, height: 0.08 },
        element: { role: 'button', name: 'Pay', identifier: 'pay-button' },
      },
      // A marker on blank space is still a marker the note can point at.
      { id: 'a2', n: 2, rect: { x: 0, y: 0, width: 0.1, height: 0.1 }, element: null },
    ],
    note: 'Make #1 green and put #2 on the left.',
    picture: { path: `/Users/someone/Pictures/App/${id}-annotated.png`, width: 1206, height: 2622 },
  }
}

describe('devices.annotations', () => {
  it('says plainly when nobody has annotated anything', async () => {
    const result = await control(fakeDeps(), dir).call('devices_annotations', {})
    expect(result.ok).toBe(true)
    expect(result.value).toMatchObject({ rounds: [], total: 0, empty: true })
    expect((result.value as { emptyReason: string }).emptyReason).toContain(
      'nobody has annotated anything since the app started',
    )
  })

  it('hands back the newest round: its one note, then every numbered marker and what it is on', async () => {
    const deps = fakeDeps()
    deps.stored = [round('newest', 'device'), round('older', 'browser')]
    const result = await control(deps, dir).call('devices_annotations', {})
    const value = result.value as { rounds: Record<string, unknown>[]; total: number }
    expect(value.total).toBe(2)
    expect(value.rounds).toHaveLength(1)
    expect(value.rounds[0]).toMatchObject({
      id: 'newest',
      where: { kind: 'device', deviceId: IOS, app: 'com.example.Shop' },
      picture: { path: '/Users/someone/Pictures/App/newest-annotated.png' },
      sentTo: null,
      note: 'Make #1 green and put #2 on the left.',
      markers: [
        {
          n: 1,
          element: { role: 'button', name: 'Pay', identifier: 'pay-button' },
          described: 'button "Pay" (id pay-button)',
        },
        { n: 2, element: null, described: 'blank space' },
      ],
    })
    // One note for the round, never one per marker.
    for (const marker of value.rounds[0].markers as Record<string, unknown>[]) expect(marker.note).toBeUndefined()
  })

  it('narrows by kind, and says what the other kind holds when the narrowing leaves nothing', async () => {
    const deps = fakeDeps()
    deps.stored = [round('d1', 'device'), round('b1', 'browser'), round('d2', 'device')]
    const deck = control(deps, dir)
    const browser = (await deck.call('devices_annotations', { kind: 'browser', count: 5 })).value as {
      rounds: { id: string }[]
    }
    expect(browser.rounds.map((one) => one.id)).toEqual(['b1'])

    deps.stored = [round('d1', 'device')]
    const none = (await deck.call('devices_annotations', { kind: 'browser' })).value as {
      empty: boolean
      emptyReason: string
    }
    expect(none.empty).toBe(true)
    expect(none.emptyReason).toContain('1 round on device screens')
  })

  it('reads at most ten rounds however many are asked for', async () => {
    const deps = fakeDeps()
    deps.stored = Array.from({ length: 15 }, (_, index) => round(`r${index}`, 'device'))
    const value = (await control(deps, dir).call('devices_annotations', { count: 50 })).value as {
      rounds: unknown[]
    }
    expect(value.rounds).toHaveLength(MAX_ROUNDS)
  })
})
