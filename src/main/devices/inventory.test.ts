import { mkdirSync, mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { locateEngine, engineCandidates } from './engine'
import { plainRuntime, readEngineDevice, stateWords } from './inventory'

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
