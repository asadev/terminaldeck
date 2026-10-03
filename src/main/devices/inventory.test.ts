import { mkdirSync, mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { locateEngine, engineCandidates } from './engine'
import {
  DeviceInventory,
  plainRuntime,
  readDevicePlist,
  readDiskSimulators,
  readEngineDevice,
  stateWords,
  type DiskSimulator,
  type InventorySources,
} from './inventory'

/** One row of `simview-core devices`, verbatim from this Mac on 2026-10-03. */
const IOS_ROW = {
  available: true,
  capabilities: {
    accessibility: true,
    androidContext: false,
    capture: { h264: true, mjpeg: true, screenshot: true },
    input: {
      buttons: ['home', 'lock', 'volume-up', 'volume-down', 'action'],
      keys: ['delete', 'return', 'enter', 'tab', 'escape', 'arrow-up', 'arrow-down', 'arrow-left', 'arrow-right', 'select-all'],
      multiTouch: true,
      rawTouch: true,
      text: 'unicode',
      touch: true,
    },
    orientation: true,
    uikitProbe: true,
  },
  id: 'ios:427403DD-17A1-46DD-897E-1ABEF8851785',
  kind: 'simulator',
  metadata: { simulatorState: 'Booted' },
  name: 'td-annotate-test',
  platform: 'ios',
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
  state: 'ready',
  udid: '427403DD-17A1-46DD-897E-1ABEF8851785',
}

describe('reading the engine’s device list', () => {
  it('reads a running simulator', () => {
    const entry = readEngineDevice(IOS_ROW)
    expect(entry).toMatchObject({
      id: 'ios:427403DD-17A1-46DD-897E-1ABEF8851785',
      platform: 'ios',
      kind: 'simulator',
      state: 'ready',
      available: true,
      name: 'td-annotate-test',
      runtime: 'iOS 27.0',
      canBoot: false,
      canShutDown: true,
      text: 'unicode',
      canRotate: true,
    })
    expect(entry?.buttons).toContain('home')
  })

  it('offers to start a simulator that is off', () => {
    const entry = readEngineDevice({ ...IOS_ROW, state: 'shutdown', available: false })
    expect(entry?.canBoot).toBe(true)
    expect(entry?.canShutDown).toBe(false)
  })

  it('never offers to start or stop a phone, and says what an unauthorised one needs', () => {
    const entry = readEngineDevice({
      id: 'android:R5CT20',
      platform: 'android',
      kind: 'physical',
      state: 'unauthorized',
      available: false,
      name: 'Galaxy',
      runtime: '',
      capabilities: { input: { buttons: [], text: 'ascii' } },
      serial: 'R5CT20',
    })
    expect(entry?.canBoot).toBe(false)
    expect(entry?.canShutDown).toBe(false)
    expect(entry?.note).toMatch(/allow this computer/)
  })

  it('drops a row with no id or an unknown platform rather than showing a blank', () => {
    expect(readEngineDevice({ ...IOS_ROW, id: '' })).toBeNull()
    expect(readEngineDevice({ ...IOS_ROW, platform: 'windows-phone' })).toBeNull()
    expect(readEngineDevice('nonsense')).toBeNull()
  })

  it('says runtimes and states in words', () => {
    expect(plainRuntime('com.apple.CoreSimulator.SimRuntime.iOS-26-5')).toBe('iOS 26.5')
    expect(plainRuntime('Android 16')).toBe('Android 16')
    expect(stateWords('shutdown')).toBe('off')
  })
})

describe('finding the engine', () => {
  const root = mkdtempSync(join(tmpdir(), 'td-engine-'))
  afterAll(() => rmSync(root, { recursive: true, force: true }))

  it('refuses anything that is not an Apple-silicon Mac, in a sentence', () => {
    expect(locateEngine({ resourcesPath: null, appPath: root, platform: 'win32', arch: 'x64' })).toEqual({
      ok: false,
      reason: 'Simulators open on a Mac. This computer is not one.',
    })
    expect(locateEngine({ resourcesPath: null, appPath: root, platform: 'darwin', arch: 'x64' })).toMatchObject({ ok: false })
  })

  it('looks in the unpacked archive first, the way a packaged app holds it', () => {
    const list = engineCandidates('/Applications/X.app/Contents/Resources', '/Applications/X.app/Contents/Resources/app.asar', '/tmp')
    expect(list[0]).toBe('/Applications/X.app/Contents/Resources/app.asar.unpacked/node_modules/@toolingtools/simview/bin')
    expect(list).toContain('/tmp/node_modules/@toolingtools/simview/bin')
  })

  it('finds an executable engine and names its own files for it', () => {
    const bin = join(root, 'node_modules', '@toolingtools', 'simview', 'bin')
    mkdirSync(join(bin, 'xctest-provider'), { recursive: true })
    writeFileSync(join(bin, 'simview-core'), '#!/bin/sh\n')
    chmodSync(join(bin, 'simview-core'), 0o755)
    writeFileSync(join(bin, 'simview-android-agent.jar'), '')
    writeFileSync(join(bin, 'xctest-provider', 'SimViewXCTestProvider.xctestrun'), '')
    const found = locateEngine({ resourcesPath: null, appPath: root, cwd: root, platform: 'darwin', arch: 'arm64' })
    expect(found.ok).toBe(true)
    if (!found.ok) return
    expect(found.core).toBe(join(bin, 'simview-core'))
    expect(found.env.SIMVIEW_ANDROID_AGENT_PATH).toBe(join(bin, 'simview-android-agent.jar'))
    expect(found.env.SIMVIEW_XCTEST_PROVIDER_XCTESTRUN).toBe(join(bin, 'xctest-provider', 'SimViewXCTestProvider.xctestrun'))
  })

  it('says the app is missing its engine when nothing is there', () => {
    const empty = mkdtempSync(join(tmpdir(), 'td-engine-empty-'))
    expect(locateEngine({ resourcesPath: null, appPath: empty, cwd: empty, platform: 'darwin', arch: 'arm64' })).toMatchObject({
      ok: false,
      reason: expect.stringMatching(/missing its simulator engine/),
    })
    rmSync(empty, { recursive: true, force: true })
  })
})

/** A `device.plist` as Xcode writes it, verbatim in shape from this Mac on 2026-10-04. */
function plist(udid: string, name: string, state: number, deleted = false): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UDID</key>
	<string>${udid}</string>
	<key>deviceType</key>
	<string>com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro</string>
	<key>isDeleted</key>
	<${deleted ? 'true' : 'false'}/>
	<key>isEphemeral</key>
	<false/>
	<key>lastUsedAt</key>
	<date>2026-10-03T11:36:18Z</date>
	<key>name</key>
	<string>${name}</string>
	<key>runtime</key>
	<string>com.apple.CoreSimulator.SimRuntime.iOS-27-0</string>
	<key>runtimePolicy</key>
	<string>System</string>
	<key>state</key>
	<integer>${state}</integer>
</dict>
</plist>
`
}

const A = 'CD9C5A1C-ADD5-4E46-AF81-EAAADDCE9402'
const B = 'AE0835B7-3AC6-467D-AB49-EF48CE064D22'

const folders: string[] = []
afterAll(() => {
  for (const folder of folders) rmSync(folder, { recursive: true, force: true })
})

describe('the simulators’ own record on disk', () => {
  it('reads the name, runtime and state of a booted and a shut-down simulator', () => {
    expect(readDevicePlist(plist(A, 'iPhone 18 Pro', 3))).toEqual({
      udid: A,
      name: 'iPhone 18 Pro',
      runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
      state: 'ready',
    })
    expect(readDevicePlist(plist(B, 'iPhone 17 Pro', 1))?.state).toBe('shutdown')
    expect(readDevicePlist(plist(B, 'iPhone 17 Pro', 2))?.state).toBe('booting')
  })

  it('reads a name with an ampersand in it as the name', () => {
    expect(readDevicePlist(plist(A, 'Tom &amp; Jerry', 1))?.name).toBe('Tom & Jerry')
  })

  it('is no simulator for a deleted one, a binary plist, or a file with no UDID', () => {
    expect(readDevicePlist(plist(A, 'Gone', 1, true))).toBeNull()
    expect(readDevicePlist('bplist00\u0000\u0001')).toBeNull()
    expect(readDevicePlist(plist('not-a-udid', 'Odd', 1))).toBeNull()
  })

  it('reads every simulator folder, and skips what is not one', async () => {
    const root = mkdtempSync(join(tmpdir(), 'td-coresim-'))
    folders.push(root)
    for (const [udid, name, state] of [[A, 'iPhone 18 Pro', 3], [B, 'iPhone 17 Pro', 1]] as const) {
      mkdirSync(join(root, udid))
      writeFileSync(join(root, udid, 'device.plist'), plist(udid, name, state))
    }
    writeFileSync(join(root, 'device_set.plist'), '<?xml version="1.0"?><plist></plist>')
    mkdirSync(join(root, '11111111-2222-3333-4444-555555555555'))
    const sims = await readDiskSimulators(root)
    expect(sims.map((sim) => sim.name).sort()).toEqual(['iPhone 17 Pro', 'iPhone 18 Pro'])
    expect(await readDiskSimulators(join(root, 'missing'))).toEqual([])
  })
})

/** Sources a test controls: the engine answers when told to, the disk says what it is given. */
function sources(over: Partial<InventorySources> & { disk?: DiskSimulator[] } = {}): InventorySources & { asks: number } {
  const made = {
    asks: 0,
    engineDevices: async (): Promise<unknown[] | null> => [],
    diskSimulators: async () => over.disk ?? [],
    avds: async () => [] as string[],
    avdNameOf: async () => '',
    ...over,
  }
  const engine = made.engineDevices
  made.engineDevices = () => {
    made.asks += 1
    return engine()
  }
  return made
}

const DISK: DiskSimulator[] = [
  { udid: A, name: 'iPhone 18 Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', state: 'ready' },
  { udid: B, name: 'iPhone 17 Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5', state: 'shutdown' },
]
const IOS_A = { ...IOS_ROW, id: `ios:${A}`, udid: A, name: 'iPhone 18 Pro' }
const EMULATOR_ROW = {
  id: 'android:emulator-5554',
  platform: 'android',
  kind: 'emulator',
  state: 'ready',
  available: true,
  name: 'emulator-5554',
  runtime: 'Android 16 (API 36)',
  capabilities: { input: { buttons: ['back', 'home'], text: 'ascii' } },
}

describe('the device list when the engine is slow', () => {
  it('takes the engine’s word when it answers with the simulators', async () => {
    const inventory = new DeviceInventory(sources({ engineDevices: async () => [IOS_A], disk: DISK }), 50)
    const list = await inventory.list()
    expect(list.map((d) => d.id)).toEqual([`ios:${A}`])
    expect(list[0]?.checking).toBeUndefined()
  })

  it('shows every simulator from disk, being checked, when the engine leaves them all out', async () => {
    // What happened at a load average near 1,000: Android only, three times running.
    let rows: unknown[] = [IOS_A, EMULATOR_ROW]
    const inventory = new DeviceInventory(
      sources({ engineDevices: async () => rows, disk: DISK, avdNameOf: async () => 'IMATCH_Pixel8' }),
      50,
    )
    await inventory.list()
    rows = [EMULATOR_ROW]
    const list = await inventory.list()
    const a = list.find((d) => d.id === `ios:${A}`)
    const b = list.find((d) => d.id === `ios:${B}`)
    expect(a).toMatchObject({ name: 'iPhone 18 Pro', state: 'ready', available: true, checking: true, runtime: 'iOS 27.0' })
    // What the engine said it can do is kept from its last answer.
    expect(a?.buttons).toEqual(IOS_ROW.capabilities.input.buttons)
    expect(b).toMatchObject({ state: 'shutdown', canBoot: true, available: false, checking: true })
    expect(list.find((d) => d.id === 'android:emulator-5554')).toMatchObject({ name: 'IMATCH Pixel8' })
  })

  it('answers from disk in time when the engine is late, and keeps what was running a moment ago', async () => {
    let release: (rows: unknown[]) => void = () => undefined
    let slow = false
    const src = sources({
      engineDevices: () => (slow ? new Promise<unknown[]>((resolve) => { release = resolve }) : Promise.resolve([IOS_A, EMULATOR_ROW])),
      disk: DISK,
      avds: async () => ['IMATCH_Pixel8', 'ASAD_Pixel8'],
      avdNameOf: async () => 'IMATCH_Pixel8',
    })
    const inventory = new DeviceInventory(src, 30)
    await inventory.list()
    slow = true
    const started = Date.now()
    const list = await inventory.list()
    expect(Date.now() - started).toBeLessThan(1_000)
    expect(list.filter((d) => d.platform === 'ios').every((d) => d.checking === true)).toBe(true)
    // The running emulator is still there, being checked, and not listed a second time as an AVD that is off.
    expect(list.find((d) => d.id === 'android:emulator-5554')).toMatchObject({ checking: true })
    expect(list.filter((d) => d.id.startsWith('avd:')).map((d) => d.id)).toEqual(['avd:ASAD_Pixel8'])
    expect(list.find((d) => d.id === 'avd:ASAD_Pixel8')).toMatchObject({ canBoot: true, checking: true })

    // The late answer is used by the next listing instead of asking the engine again.
    expect(src.asks).toBe(2)
    release([IOS_A, EMULATOR_ROW])
    const next = await inventory.list()
    expect(src.asks).toBe(2)
    expect(next.find((d) => d.id === `ios:${A}`)?.checking).toBeUndefined()
  })

  it('treats an engine that failed like one that is late', async () => {
    const inventory = new DeviceInventory(sources({ engineDevices: async () => null, disk: DISK }), 50)
    const list = await inventory.list()
    expect(list.map((d) => d.id).sort()).toEqual([`ios:${B}`, `ios:${A}`])
    expect(list.every((d) => d.checking === true)).toBe(true)
  })
})
