import { execFile, spawn } from 'node:child_process'
import { existsSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { Engine } from './engine'

/**
 * Which phones and simulators this Mac has, and starting or stopping one.
 *
 * ## What is listed
 *
 * Everything the device engine can see — every iOS Simulator Xcode has
 * created, booted or not, every Android emulator that is running and every
 * Android phone plugged in over USB — plus the Android emulators that exist
 * but are not running, which the engine cannot see because it only asks adb.
 * Those come from the Android SDK's own `emulator -list-avds`, so a stranger
 * with Android Studio and nothing else sees the same list Android Studio shows.
 *
 * ## Starting and stopping
 *
 * The engine looks at devices; it never boots or shuts one down. So those two
 * are done here with the platforms' own tools: `xcrun simctl` for iOS, the
 * SDK's `emulator` and `adb` for Android. A phone on a cable has neither —
 * nobody wants an app on their computer powering their phone off — and its row
 * says so by not offering it.
 */

export type DevicePlatform = 'ios' | 'android'
export type DeviceKind = 'simulator' | 'emulator' | 'physical'
export type DeviceState = 'ready' | 'booting' | 'offline' | 'unauthorized' | 'shutdown' | 'unknown'

export interface DeviceEntry {
  /** `ios:<udid>`, `android:<serial>`, or `avd:<name>` for an emulator that is not running. */
  id: string
  platform: DevicePlatform
  kind: DeviceKind
  state: DeviceState
  /** Ready to show and drive right now. */
  available: boolean
  name: string
  /** `iOS 27.0`, `Android 16`, or empty. */
  runtime: string
  canBoot: boolean
  canShutDown: boolean
  /** Hardware buttons the engine can press on it. */
  buttons: string[]
  /** Named keys it can send. Empty on Android today. */
  keys: string[]
  /** `unicode`, `ascii` or `none`. */
  text: string
  canRotate: boolean
  /** A sentence for a row that cannot be used, e.g. an unauthorised phone. */
  note: string
}

/** `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`. */
export function plainRuntime(runtime: string): string {
  const ios = /SimRuntime\.([A-Za-z]+)-(\d+)-(\d+)/.exec(runtime)
  if (ios) return `${ios[1]} ${ios[2]}.${ios[3]}`
  return runtime
}

/** Text a model or a page can read for a state. */
export function stateWords(state: DeviceState): string {
  switch (state) {
    case 'ready':
      return 'running'
    case 'booting':
      return 'starting'
    case 'shutdown':
      return 'off'
    case 'unauthorized':
      return 'waiting for you to allow this computer on the phone'
    case 'offline':
      return 'not answering'
    default:
      return 'unknown'
  }
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : []
}

/**
 * One row of the engine's `devices` answer, read defensively.
 *
 * The output of another program, so nothing in it is trusted to be the type it
 * should be; a row missing its id is dropped rather than shown with a blank.
 */
export function readEngineDevice(raw: unknown): DeviceEntry | null {
  if (typeof raw !== 'object' || raw === null) return null
  const row = raw as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  const platform = row.platform === 'ios' || row.platform === 'android' ? row.platform : null
  if (id === '' || platform === null) return null
  const kind: DeviceKind =
    row.kind === 'simulator' || row.kind === 'emulator' || row.kind === 'physical' ? row.kind : 'physical'
  const states: readonly DeviceState[] = ['ready', 'booting', 'offline', 'unauthorized', 'shutdown', 'unknown']
  const state = states.find((s) => s === row.state) ?? 'unknown'
  const caps = (typeof row.capabilities === 'object' && row.capabilities !== null ? row.capabilities : {}) as Record<
    string,
    unknown
  >
  const input = (typeof caps.input === 'object' && caps.input !== null ? caps.input : {}) as Record<string, unknown>
  const virtual = kind !== 'physical'
  const note =
    state === 'unauthorized'
      ? 'Unlock the phone and allow this computer when it asks.'
      : state === 'offline'
      ? 'Reconnect the cable, or restart the emulator.'
      : ''
  return {
    id,
    platform,
    kind,
    state,
    available: row.available === true,
    name: typeof row.name === 'string' && row.name !== '' ? row.name : id,
    runtime: plainRuntime(typeof row.runtime === 'string' ? row.runtime : ''),
    canBoot: virtual && state === 'shutdown',
    canShutDown: virtual && (state === 'ready' || state === 'booting'),
    buttons: asStrings(input.buttons),
    keys: asStrings(input.keys),
    text: typeof input.text === 'string' ? input.text : 'none',
    canRotate: caps.orientation === true,
    note,
  }
}

/** Run a program and collect what it printed, bounded in time. */
export function run(
  file: string,
  args: string[],
  timeoutMs: number,
  env?: Record<string, string>,
): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    execFile(
      file,
      args,
      { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, ...(env ?? {}) } },
      (error, stdout, stderr) => resolve({ ok: error === null, stdout: String(stdout), stderr: String(stderr) }),
    )
  })
}

/** Where the Android SDK is, the same places Android Studio puts it. */
export function androidSdk(env: NodeJS.ProcessEnv = process.env): string | null {
  const candidates = [env.ANDROID_HOME, env.ANDROID_SDK_ROOT, join(homedir(), 'Library', 'Android', 'sdk')]
  return candidates.find((path): path is string => typeof path === 'string' && path !== '' && existsSync(path)) ?? null
}

function emulatorBinary(): string | null {
  const sdk = androidSdk()
  const path = sdk ? join(sdk, 'emulator', 'emulator') : ''
  return path && existsSync(path) ? path : null
}

export function adbBinary(): string | null {
  const sdk = androidSdk()
  const path = sdk ? join(sdk, 'platform-tools', 'adb') : ''
  return path && existsSync(path) ? path : null
}

/** Emulators that exist on disk, by name. Read off the folder when the tool is missing. */
async function listAvds(): Promise<string[]> {
  const emulator = emulatorBinary()
  if (emulator) {
    const out = await run(emulator, ['-list-avds'], 10_000)
    if (out.ok) {
      return out.stdout
        .split('\n')
        .map((line) => line.trim())
        // The tool prints its own warnings on stdout on some versions, all of
        // which contain a space or a bracket and no AVD name can.
        .filter((line) => /^[A-Za-z0-9._-]+$/.test(line))
    }
  }
  const folder = join(homedir(), '.android', 'avd')
  if (!existsSync(folder)) return []
  return readdirSync(folder)
    .filter((name) => name.endsWith('.ini'))
    .map((name) => name.slice(0, -4))
}

/** Which AVD a running emulator is, by asking it. */
async function avdNameOf(serial: string): Promise<string> {
  const adb = adbBinary()
  if (!adb) return ''
  const out = await run(adb, ['-s', serial, 'emu', 'avd', 'name'], 5_000)
  return out.ok ? (out.stdout.split('\n')[0] ?? '').trim() : ''
}

export async function listDevices(engine: Engine): Promise<DeviceEntry[]> {
  const out = await run(engine.core, ['devices'], 20_000, engine.env)
  let rows: unknown = []
  try {
    rows = out.ok ? JSON.parse(out.stdout) : []
  } catch {
    rows = []
  }
  const devices = (Array.isArray(rows) ? rows : []).map(readEngineDevice).filter((d): d is DeviceEntry => d !== null)

  // Emulators that exist but are not running, which adb — and therefore the
  // engine — has never heard of.
  const running = new Set<string>()
  for (const device of devices) {
    if (device.platform !== 'android' || device.kind !== 'emulator') continue
    const serial = device.id.replace(/^android:/, '')
    const avd = await avdNameOf(serial)
    if (avd !== '') {
      running.add(avd)
      if (device.name === serial) device.name = avd.replace(/_/g, ' ')
    }
  }
  for (const avd of await listAvds()) {
    if (running.has(avd)) continue
    devices.push({
      id: `avd:${avd}`,
      platform: 'android',
      kind: 'emulator',
      state: 'shutdown',
      available: false,
      name: avd.replace(/_/g, ' '),
      runtime: '',
      canBoot: true,
      canShutDown: false,
      buttons: [],
      keys: [],
      text: 'none',
      canRotate: false,
      note: '',
    })
  }

  // Running first, then by platform and name, so what can be used is on top.
  const rank = (d: DeviceEntry): number => (d.available ? 0 : d.state === 'booting' ? 1 : 2)
  return devices.sort(
    (a, b) => rank(a) - rank(b) || a.platform.localeCompare(b.platform) || a.name.localeCompare(b.name),
  )
}

/** Wait for a condition, checking every `everyMs`, for at most `budgetMs`. */
async function until(check: () => Promise<boolean>, budgetMs: number, everyMs: number): Promise<boolean> {
  const deadline = Date.now() + budgetMs
  while (Date.now() < deadline) {
    if (await check()) return true
    await new Promise((resolve) => setTimeout(resolve, everyMs))
  }
  return false
}

/**
 * Start a simulator or an emulator, and answer once it is usable.
 *
 * Returns the id the device will be known by once it is running — the same for
 * iOS, and `android:<serial>` for an AVD that was `avd:<name>` while off.
 */
export async function bootDevice(id: string): Promise<{ ok: true; id: string } | { ok: false; message: string }> {
  if (id.startsWith('ios:')) {
    const udid = id.slice(4)
    const boot = await run('xcrun', ['simctl', 'boot', udid], 120_000)
    // "Unable to boot device in current state: Booted" is a success.
    if (!boot.ok && !/current state: Booted/i.test(boot.stderr)) {
      return { ok: false, message: firstLine(boot.stderr) || 'The simulator would not start.' }
    }
    const ready = await run('xcrun', ['simctl', 'bootstatus', udid, '-b'], 240_000)
    return ready.ok ? { ok: true, id } : { ok: false, message: 'The simulator started but did not finish booting.' }
  }
  if (id.startsWith('avd:')) {
    const name = id.slice(4)
    const emulator = emulatorBinary()
    const adb = adbBinary()
    if (!emulator || !adb) return { ok: false, message: 'Android Studio’s emulator is not installed on this Mac.' }
    const before = new Set(await emulatorSerials(adb))
    // Detached and unreferenced: the emulator outlives this call and, like an
    // emulator started from Android Studio, this app quitting does not stop it.
    //
    // Without a window of its own, the same way `simctl boot` starts an iOS
    // Simulator without the Simulator app: the Simulators page *is* the window.
    // A second one would open in front of whatever he was doing and show the
    // same screen twice. Android Studio, if it is open, still lists and can
    // show it, and Shut down on the page stops it.
    const child = spawn(emulator, ['-avd', name, '-no-boot-anim', '-no-window'], { detached: true, stdio: 'ignore' })
    child.unref()
    let serial = ''
    const appeared = await until(
      async () => {
        const now = await emulatorSerials(adb)
        serial = now.find((s) => !before.has(s)) ?? ''
        return serial !== ''
      },
      90_000,
      1_000,
    )
    if (!appeared) return { ok: false, message: 'The emulator did not start.' }
    const booted = await until(
      async () => (await run(adb, ['-s', serial, 'shell', 'getprop', 'sys.boot_completed'], 5_000)).stdout.trim() === '1',
      240_000,
      2_000,
    )
    return booted ? { ok: true, id: `android:${serial}` } : { ok: false, message: 'The emulator started but did not finish booting.' }
  }
  return { ok: false, message: 'That device cannot be started from here.' }
}

async function emulatorSerials(adb: string): Promise<string[]> {
  const out = await run(adb, ['devices'], 5_000)
  return out.stdout
    .split('\n')
    .map((line) => line.split(/\s+/)[0] ?? '')
    .filter((serial) => serial.startsWith('emulator-'))
}

export async function shutDownDevice(id: string): Promise<{ ok: true } | { ok: false; message: string }> {
  if (id.startsWith('ios:')) {
    const out = await run('xcrun', ['simctl', 'shutdown', id.slice(4)], 60_000)
    return out.ok || /current state: Shutdown/i.test(out.stderr)
      ? { ok: true }
      : { ok: false, message: firstLine(out.stderr) || 'The simulator would not shut down.' }
  }
  if (id.startsWith('android:emulator-')) {
    const adb = adbBinary()
    if (!adb) return { ok: false, message: 'adb is not installed on this Mac.' }
    const out = await run(adb, ['-s', id.slice(8), 'emu', 'kill'], 20_000)
    return out.ok ? { ok: true } : { ok: false, message: 'The emulator would not shut down.' }
  }
  return { ok: false, message: 'A phone on a cable is turned off on the phone itself.' }
}

function firstLine(text: string): string {
  return (text.split('\n').find((line) => line.trim() !== '') ?? '').trim().slice(0, 200)
}
