import { execFile, spawn } from 'node:child_process'
import { existsSync, readdirSync } from 'node:fs'
import { readdir, readFile } from 'node:fs/promises'
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
 * ## When the engine is slow
 *
 * Under heavy load — another session's Xcode builds holding a ten-core Mac at
 * a load average near 1,000 — the engine's `devices` answer came back three
 * times in a row with the Android emulator and **no iOS Simulators at all**,
 * and the page, which only asked again on focus, showed none until he clicked
 * back into the window. So the list has a second source: CoreSimulator's own
 * record of every simulator, one `device.plist` per device under
 * `~/Library/Developer/CoreSimulator/Devices`, which carries the name, the
 * runtime and the state and is only ever *read* here. A slow engine answer is
 * waited for {@link ENGINE_WAIT_MS} and no longer; when it is late, fails, or
 * leaves out every iOS device, the simulators come from that record instead —
 * each on top of the engine's last word about it where there is one — and say
 * `checking`, rather than vanishing. A late answer is not thrown away: the
 * next listing uses it instead of starting the engine a second time.
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
  /**
   * The engine did not confirm this row this time — it was slow, or left the
   * device out — so it comes from the simulator's own record on disk or from
   * the last list, and is being checked again.
   */
  checking?: boolean
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

/* ------------------------------------------------ the record on disk -- */

/** One simulator as CoreSimulator records it in its `device.plist`. */
export interface DiskSimulator {
  udid: string
  name: string
  /** `com.apple.CoreSimulator.SimRuntime.iOS-27-0`. */
  runtime: string
  state: DeviceState
}

/** Where CoreSimulator keeps one folder per simulator. */
export function simulatorsFolder(): string {
  return join(homedir(), 'Library', 'Developer', 'CoreSimulator', 'Devices')
}

const XML_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }

/**
 * A `device.plist`, read for the five keys this needs.
 *
 * Xcode writes them as XML: a flat dictionary of strings, an integer state, a
 * date and two booleans. Read with a pattern per key rather than a plist
 * library, because that is all there is; anything unexpected — a binary plist,
 * a missing UDID, a deleted device — is no simulator rather than a wrong one.
 * The state is CoreSimulator's own: 1 shut down, 2 booting, 3 booted.
 */
export function readDevicePlist(xml: string): DiskSimulator | null {
  if (!xml.trimStart().startsWith('<?xml') && !xml.trimStart().startsWith('<plist')) return null
  const text = (key: string): string => {
    const match = new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(xml)
    return match ? match[1].replace(/&(amp|lt|gt|quot|apos);/g, (_all, name: string) => XML_ENTITIES[name] ?? '') : ''
  }
  const deleted = new RegExp('<key>isDeleted</key>\\s*<true\\s*/>').test(xml)
  const udid = text('UDID')
  if (deleted || !/^[0-9A-Fa-f-]{36}$/.test(udid)) return null
  const stateMatch = /<key>state<\/key>\s*<integer>(-?\d+)<\/integer>/.exec(xml)
  const code = stateMatch ? Number(stateMatch[1]) : NaN
  const state: DeviceState = code === 3 ? 'ready' : code === 2 ? 'booting' : code === 1 ? 'shutdown' : 'unknown'
  return { udid: udid.toUpperCase(), name: text('name') || udid, runtime: text('runtime'), state }
}

/** Every simulator in the record on disk. Read-only, and quiet: an unreadable folder or file is skipped. */
export async function readDiskSimulators(folder: string = simulatorsFolder()): Promise<DiskSimulator[]> {
  let names: string[]
  try {
    names = await readdir(folder)
  } catch {
    return []
  }
  const found = await Promise.all(
    names
      .filter((name) => /^[0-9A-Fa-f-]{36}$/.test(name))
      .map(async (name) => {
        try {
          return readDevicePlist(await readFile(join(folder, name, 'device.plist'), 'utf8'))
        } catch {
          return null
        }
      }),
  )
  return found.filter((sim): sim is DiskSimulator => sim !== null)
}

/**
 * What the engine says every iOS Simulator can do — buttons, keys, text,
 * rotation — read off its answer on this Mac on 2026-10-03, for a simulator
 * known only from disk. Opening the device asks the engine for its real
 * details anyway; this only has to be right enough for a row.
 */
const IOS_SIMULATOR_INPUT = {
  buttons: ['home', 'lock', 'volume-up', 'volume-down', 'action'],
  keys: ['delete', 'return', 'enter', 'tab', 'escape', 'arrow-up', 'arrow-down', 'arrow-left', 'arrow-right', 'select-all'],
  text: 'unicode',
  canRotate: true,
}

/** A simulator's row from the record on disk, over the engine's last row for it when there is one. */
export function diskEntry(sim: DiskSimulator, lastFromEngine?: DeviceEntry): DeviceEntry {
  const state = sim.state
  return {
    ...IOS_SIMULATOR_INPUT,
    ...(lastFromEngine ? { buttons: lastFromEngine.buttons, keys: lastFromEngine.keys, text: lastFromEngine.text, canRotate: lastFromEngine.canRotate } : {}),
    id: `ios:${sim.udid}`,
    platform: 'ios',
    kind: 'simulator',
    state,
    available: state === 'ready',
    name: sim.name,
    runtime: plainRuntime(sim.runtime) || lastFromEngine?.runtime || '',
    canBoot: state === 'shutdown',
    canShutDown: state === 'ready' || state === 'booting',
    note: '',
    checking: true,
  }
}

/* ----------------------------------------------------------- the list -- */

/** How long a listing waits for the engine before answering from the record on disk. */
export const ENGINE_WAIT_MS = 5_000

/** A late engine answer older than this is stale, and the engine is asked again. */
const LATE_ANSWER_KEEP_MS = 15_000

/** Where a listing's facts come from. The real ones are {@link engineSources}; tests pass fakes. */
export interface InventorySources {
  /** The engine's `devices` rows, or null when it failed or timed out. */
  engineDevices(): Promise<unknown[] | null>
  diskSimulators(): Promise<DiskSimulator[]>
  /** Android emulators that exist on disk, by AVD name. */
  avds(): Promise<string[]>
  /** Which AVD a running emulator is. Empty when it cannot say. */
  avdNameOf(serial: string): Promise<string>
}

export function engineSources(engine: Engine): InventorySources {
  return {
    engineDevices: async () => {
      const out = await run(engine.core, ['devices'], 20_000, engine.env)
      if (!out.ok) return null
      try {
        const rows: unknown = JSON.parse(out.stdout)
        return Array.isArray(rows) ? rows : null
      } catch {
        return null
      }
    },
    diskSimulators: () => readDiskSimulators(),
    avds: listAvds,
    avdNameOf,
  }
}

interface EngineCall {
  promise: Promise<unknown[] | null>
  settledAt: number | null
}

/**
 * The device list, from the engine and from the simulators' own record, merged
 * so that no device disappears because one source was slow. One per process
 * (the manager holds it); it remembers the engine's last word about each
 * device and any answer still on its way.
 */
export class DeviceInventory {
  private call: EngineCall | null = null
  private readonly lastIos = new Map<string, DeviceEntry>()
  private lastAndroid: DeviceEntry[] = []
  /** AVD names of the emulators in {@link lastAndroid}, so an off-list AVD is not listed twice. */
  private lastRunningAvds = new Set<string>()

  constructor(
    private readonly sources: InventorySources,
    private readonly waitMs: number = ENGINE_WAIT_MS,
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** A device was started or stopped: an answer from before that is no use. */
  forgetPending(): void {
    if (this.call?.settledAt !== null) this.call = null
  }

  /** The engine's answer: the one still on its way if there is one, else a new ask. Null if it is not back in time. */
  private async engineRows(): Promise<{ rows: unknown[] | null; late: boolean }> {
    if (this.call && this.call.settledAt !== null && this.now() - this.call.settledAt > LATE_ANSWER_KEEP_MS) this.call = null
    if (!this.call) {
      const call: EngineCall = { promise: Promise.resolve(null), settledAt: null }
      call.promise = this.sources
        .engineDevices()
        .catch(() => null)
        .then((rows) => {
          call.settledAt = this.now()
          return rows
        })
      this.call = call
    }
    const call = this.call
    let timer: ReturnType<typeof setTimeout> | undefined
    const late = new Promise<'late'>((resolve) => {
      timer = setTimeout(() => resolve('late'), this.waitMs)
    })
    const outcome = await Promise.race([call.promise, late])
    if (timer) clearTimeout(timer)
    if (outcome === 'late') return { rows: null, late: true }
    if (this.call === call) this.call = null
    return { rows: outcome, late: false }
  }

  async list(): Promise<DeviceEntry[]> {
    const [engine, disk] = await Promise.all([this.engineRows(), this.sources.diskSimulators().catch(() => [])])
    const fromEngine = (engine.rows ?? []).map(readEngineDevice).filter((d): d is DeviceEntry => d !== null)
    const engineIos = fromEngine.filter((d) => d.platform === 'ios')
    const engineAndroid = fromEngine.filter((d) => d.platform === 'android')
    const answered = engine.rows !== null

    // iOS: the engine's word when it gave one; otherwise the record on disk,
    // over the engine's last word about each device, marked as being checked.
    let ios: DeviceEntry[]
    if (answered && engineIos.length > 0) {
      ios = engineIos
      for (const entry of engineIos) this.lastIos.set(entry.id, entry)
    } else {
      ios = disk.map((sim) => diskEntry(sim, this.lastIos.get(`ios:${sim.udid}`)))
    }

    // Android: the engine is the only source for what is running. When it did
    // not answer, what was running a moment ago is still shown, being checked.
    let android: DeviceEntry[]
    const running = new Set<string>()
    if (answered) {
      android = engineAndroid
      for (const device of android) {
        if (device.kind !== 'emulator') continue
        const serial = device.id.replace(/^android:/, '')
        const avd = await this.sources.avdNameOf(serial)
        if (avd !== '') {
          running.add(avd)
          if (device.name === serial) device.name = avd.replace(/_/g, ' ')
        }
      }
      // A copy: the rows for emulators that are off are added to `android` below.
      this.lastAndroid = [...android]
      this.lastRunningAvds = new Set(running)
    } else {
      android = this.lastAndroid.map((entry) => ({ ...entry, checking: true }))
      for (const avd of this.lastRunningAvds) running.add(avd)
    }

    // Emulators that exist but are not running, which adb — and therefore the
    // engine — has never heard of. Without an answer from the engine, "not
    // running" is a guess, and the row says it is being checked.
    for (const avd of await this.sources.avds()) {
      if (running.has(avd)) continue
      android.push({
        ...(answered ? {} : { checking: true }),
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
    return [...ios, ...android].sort(
      (a, b) => rank(a) - rank(b) || a.platform.localeCompare(b.platform) || a.name.localeCompare(b.name),
    )
  }
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
