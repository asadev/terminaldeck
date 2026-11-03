import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
// Types only, so this is erased at build time and does not load the module
// before `vi.mock` has replaced Electron underneath it. The values come from the
// dynamic import below.
import type { CommandResult, CommandRunner } from './lid-awake'

/**
 * The rules this module must not break.
 *
 * Two of them carry the whole feature, and both are about refusing to claim
 * something that has not been checked:
 *
 *  1. **The switch reports the operating system, not the request.** A `pmset`
 *     that exits 0 and leaves the setting untouched has to come back `failed`.
 *     Every other outcome in this file is derived from a second read for the
 *     same reason.
 *  2. **It attaches at launch, not at first click.** `disablesleep` outlives the
 *     app, so the ordinary case is launching onto a machine that is already
 *     being held awake — and if nothing ran until somebody opened Settings, the
 *     app would be sitting on a battery drain it had no opinion about. That is
 *     the "wired to a button, never wired to boot" bug this project keeps
 *     paying for, so it is asserted rather than trusted.
 *
 * The parser cases are not invented. They are the literal output of `pmset -g`,
 * `pmset -g batt` and `ioreg` on the Mac this was written on, which had
 * `SleepDisabled 1` set before a line of this was typed — so the "on" path is
 * checked against a machine that really was in that state.
 */

let batteryPower = false
const notifications: Array<{ title: string; body: string }> = []
const blockersStarted: number[] = []
const blockersStopped: number[] = []

vi.mock('electron', () => ({
  powerMonitor: {
    get onBatteryPower() {
      return batteryPower
    },
    on: () => {},
    off: () => {},
  },
  powerSaveBlocker: {
    start: () => {
      const id = blockersStarted.length + 1
      blockersStarted.push(id)
      return id
    },
    stop: (id: number) => blockersStopped.push(id),
    isStarted: (id: number) => blockersStarted.includes(id) && !blockersStopped.includes(id),
  },
  Notification: class {
    static isSupported = () => true
    constructor(private readonly options: { title: string; body: string }) {}
    show() {
      notifications.push({ title: this.options.title, body: this.options.body })
    }
  },
}))

// The real one reads and rewrites settings.json. Nothing here is testing that.
const stored: Record<string, number> = {}
vi.mock('./settings-extra', () => ({
  storedValue: (key: string) => stored[key],
  patchStoredSettings: (patch: Record<string, number>) => Object.assign(stored, patch),
}))

const {
  appleScriptLiteral,
  BATTERY_POLL_MS,
  isAuthorizationCancelled,
  LidAwakeController,
  LID_AWAKE_GET,
  LID_AWAKE_SET,
  LID_AWAKE_STATE,
  LID_DO_NOTHING,
  LID_SLEEP,
  lowBatteryWarning,
  parseBattery,
  parseIoregSleepDisabled,
  parseLidActionIndexes,
  parseSleepDisabled,
  pmsetScript,
  PREVIOUS_AC_KEY,
  PREVIOUS_DC_KEY,
  readLidAwake,
  registerLidAwakeIpc,
  runCommand,
  setLidAwake,
} = await import('./lid-awake')

/* --------------------------------------------------------------- fixtures -- */

/** Verbatim `pmset -g` from a Mac that was being held awake. */
const PMSET_ON = `System-wide power settings:
 SleepDisabled\t\t1
Currently in use:
 standby              0
 Sleep On Power Button 1
 hibernatefile        /var/vm/sleepimage
 powernap             1
 disksleep            10
 sleep                0 (sleep prevented by caffeinate, Claude, powerd)
 hibernatemode        0
 displaysleep         0
 womp                 1
`

/** The same machine after `pmset -a disablesleep 0`: the key stays, the value flips. */
const PMSET_OFF = PMSET_ON.replace('SleepDisabled\t\t1', 'SleepDisabled\t\t0')

/** A Mac that has never been told either way prints no such line at all. */
const PMSET_NEVER_SET = PMSET_ON.split('\n')
  .filter((line) => !line.includes('SleepDisabled'))
  .join('\n')

const BATT_AC = `Now drawing from 'AC Power'
 -InternalBattery-0 (id=23920739)\t100%; charged; 0:00 remaining present: true
`

const BATT_LOW = `Now drawing from 'Battery Power'
 -InternalBattery-0 (id=23920739)\t14%; discharging; 1:02 remaining present: true
`

/** A desktop: one line, no battery, and therefore no lid to talk about. */
const BATT_DESKTOP = `Now drawing from 'AC Power'\n`

const POWERCFG_SLEEPING = `
Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
  Subgroup GUID: 4f971e89-eebd-4455-a8de-9e59040e7347  (Power buttons and lid)
    Power Setting GUID: 5ca83367-6e45-459f-a27b-476b1d01c936  (Lid close action)
      Current AC Power Setting Index: 0x00000001
      Current DC Power Setting Index: 0x00000001
`

const POWERCFG_HELD = POWERCFG_SLEEPING.replace(/0x00000001/g, '0x00000000')

/* ---------------------------------------------------------------- runners -- */

interface Call {
  file: string
  args: string[]
}

/**
 * A fake command runner built from a table of substring → result.
 *
 * Matching on a substring of the joined argv rather than on an exact command
 * keeps these tests readable, and every call is recorded so a test can assert
 * what was *not* run — which is how "turning it off must restore the previous
 * value" is checked at all.
 */
function runner(
  table: Array<[match: string, result: Partial<CommandResult>]>,
): CommandRunner & { calls: Call[] } {
  const calls: Call[] = []
  const fake = (file: string, args: readonly string[]): Promise<CommandResult> => {
    calls.push({ file, args: [...args] })
    const line = `${file} ${args.join(' ')}`
    for (const [match, result] of table) {
      if (line.includes(match)) {
        return Promise.resolve({ code: 0, stdout: '', stderr: '', ...result })
      }
    }
    return Promise.resolve({ code: -1, stdout: '', stderr: `nothing faked for: ${line}` })
  }
  return Object.assign(fake, { calls })
}

/** A runner whose answers change between calls, for the read-back assertions. */
function scriptedDarwin(states: string[], batt = BATT_AC): CommandRunner & { calls: Call[] } {
  const calls: Call[] = []
  let index = 0
  const fake = (file: string, args: readonly string[]): Promise<CommandResult> => {
    calls.push({ file, args: [...args] })
    if (args.includes('batt')) return Promise.resolve({ code: 0, stdout: batt, stderr: '' })
    if (file.endsWith('pmset')) {
      const stdout = states[Math.min(index, states.length - 1)]
      index += 1
      return Promise.resolve({ code: 0, stdout, stderr: '' })
    }
    return Promise.resolve({ code: 0, stdout: '', stderr: '' })
  }
  return Object.assign(fake, { calls })
}

/* ---------------------------------------------------------------- parsing -- */

describe('parseSleepDisabled', () => {
  it('reads the line a held-open Mac actually prints', () => {
    expect(parseSleepDisabled(PMSET_ON)).toBe(true)
  })

  it('reads it as off when the key is there and set to zero', () => {
    expect(parseSleepDisabled(PMSET_OFF)).toBe(false)
  })

  it('answers null — not false — when the key is absent', () => {
    // The important one. "Absent" and "off" are different situations: a macOS
    // that renamed the key would look exactly like a machine that had never set
    // it, and answering false there would draw an off switch on a Mac that is
    // being held awake. `readLidAwake` gets a second opinion instead.
    expect(parseSleepDisabled(PMSET_NEVER_SET)).toBeNull()
  })

  it('is not fooled by the idle sleep timer on the same screen', () => {
    // `sleep 0` sits three lines below and means the idle timer, not the lid.
    // A machine can print `sleep 0` and still sleep the moment it is closed.
    expect(parseSleepDisabled(PMSET_NEVER_SET)).toBeNull()
    expect(PMSET_NEVER_SET).toContain('sleep                0')
  })
})

describe('parseIoregSleepDisabled', () => {
  it('reads the kernel property verbatim', () => {
    expect(parseIoregSleepDisabled('      "SleepDisabled" = Yes')).toBe(true)
    expect(parseIoregSleepDisabled('      "SleepDisabled" = No')).toBe(false)
    expect(parseIoregSleepDisabled('nothing of the sort')).toBeNull()
  })
})

describe('parseBattery', () => {
  it('reads a charged laptop on mains', () => {
    expect(parseBattery(BATT_AC)).toEqual({ present: true, discharging: false, percent: 100 })
  })

  it('reads a laptop running itself down', () => {
    expect(parseBattery(BATT_LOW)).toEqual({ present: true, discharging: true, percent: 14 })
  })

  it('knows a desktop has no battery, and therefore no lid', () => {
    const reading = parseBattery(BATT_DESKTOP)
    expect(reading.present).toBe(false)
    expect(reading.discharging).toBe(false)
  })
})

describe('parseLidActionIndexes', () => {
  it('reads both power sources out of powercfg', () => {
    expect(parseLidActionIndexes(POWERCFG_SLEEPING)).toEqual({ ac: LID_SLEEP, dc: LID_SLEEP })
    expect(parseLidActionIndexes(POWERCFG_HELD)).toEqual({
      ac: LID_DO_NOTHING,
      dc: LID_DO_NOTHING,
    })
  })

  it('answers null per source rather than guessing at a missing one', () => {
    expect(parseLidActionIndexes('nothing here')).toEqual({ ac: null, dc: null })
  })
})

/* ------------------------------------------------------------- the reading -- */

describe('readLidAwake', () => {
  it('reports what pmset says, on and off', async () => {
    const on = await readLidAwake({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
    })
    expect(on).toMatchObject({ supported: true, known: true, on: true, needsAuthorization: true })

    const off = await readLidAwake({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_OFF }],
      ]),
    })
    expect(off).toMatchObject({ known: true, on: false })
  })

  it('asks the kernel when pmset does not mention the setting', async () => {
    const run = runner([
      ['pmset -g batt', { stdout: BATT_AC }],
      ['pmset -g', { stdout: PMSET_NEVER_SET }],
      ['ioreg', { stdout: '      "SleepDisabled" = No' }],
    ])
    const state = await readLidAwake({ platform: 'darwin', run })
    expect(state).toMatchObject({ known: true, on: false })
    expect(run.calls.some((call) => call.file.endsWith('ioreg'))).toBe(true)
  })

  it('refuses to claim a state when pmset and the kernel disagree', async () => {
    // pmset printed nothing and the kernel says the machine is held awake. That
    // is a contradiction, and the only honest answer is that the app cannot say
    // — never a confident "off" on a machine that is running the battery down.
    const state = await readLidAwake({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_NEVER_SET }],
        ['ioreg', { stdout: '      "SleepDisabled" = Yes' }],
      ]),
    })
    expect(state.known).toBe(false)
    expect(state.detail).toBeTruthy()
  })

  it('is unknown, not off, when pmset cannot be run at all', async () => {
    const state = await readLidAwake({
      platform: 'darwin',
      run: runner([['pmset', { code: -1, stderr: 'spawn ENOENT' }]]),
    })
    expect(state.known).toBe(false)
    expect(state.detail).toContain('ENOENT')
  })

  it('needs no authorisation on Windows, and reads both lid actions', async () => {
    const held = await readLidAwake({
      platform: 'win32',
      run: runner([['/query', { stdout: POWERCFG_HELD }]]),
    })
    expect(held).toMatchObject({ supported: true, known: true, on: true, needsAuthorization: false })

    const sleeping = await readLidAwake({
      platform: 'win32',
      run: runner([['/query', { stdout: POWERCFG_SLEEPING }]]),
    })
    expect(sleeping.on).toBe(false)
  })

  it('does not call a laptop held open when only its mains action was changed', async () => {
    // AC "do nothing", DC "sleep": works until it is unplugged, which is the
    // moment nobody is watching. The switch must not read as on.
    const mixed = POWERCFG_SLEEPING.replace(
      'Current AC Power Setting Index: 0x00000001',
      'Current AC Power Setting Index: 0x00000000',
    )
    const state = await readLidAwake({
      platform: 'win32',
      run: runner([['/query', { stdout: mixed }]]),
    })
    expect(state.on).toBe(false)
  })

  it('says so plainly on a platform this is not wired for', async () => {
    const state = await readLidAwake({ platform: 'linux', run: runner([]) })
    expect(state.supported).toBe(false)
    expect(state.detail).toBeTruthy()
  })
})

/* -------------------------------------------------------------- the script -- */

describe('the privileged call', () => {
  it('asks macOS for authorisation rather than shelling out to sudo', () => {
    const script = pmsetScript(true)
    expect(script).toContain('with administrator privileges')
    expect(script).toContain('/usr/bin/pmset -a disablesleep 1')
    // No password may ever appear in a command this process builds. `sudo -S`,
    // an askpass helper or an interpolated secret would all show up here.
    expect(script).not.toMatch(/sudo|password/i)
    expect(pmsetScript(false)).toContain('/usr/bin/pmset -a disablesleep 0')
  })

  it('touches only disablesleep, so the power button still behaves', () => {
    // Asad's requirement: pressing the power button to lock must be unaffected.
    // `Sleep On Power Button` is a separate pmset key, and the guarantee is
    // simply that nothing here writes it.
    for (const script of [pmsetScript(true), pmsetScript(false)]) {
      expect(script).not.toMatch(/powerbutton|Sleep On Power Button|displaysleep/i)
    }
  })

  it('escapes an AppleScript literal properly', () => {
    expect(appleScriptLiteral('plain')).toBe('"plain"')
    expect(appleScriptLiteral('say "hi"')).toBe('"say \\"hi\\""')
    expect(appleScriptLiteral('back\\slash')).toBe('"back\\\\slash"')
  })

  it('tells a dismissed password sheet apart from a real failure', () => {
    const cancelled: CommandResult = {
      code: 1,
      stdout: '',
      stderr: 'execution error: User canceled. (-128)',
    }
    expect(isAuthorizationCancelled(cancelled)).toBe(true)
    expect(isAuthorizationCancelled({ code: 1, stdout: '', stderr: 'command not found' })).toBe(false)
  })
})

/* --------------------------------------------------------------- the write -- */

describe('setLidAwake', () => {
  it('reports the OS, not the exit code', async () => {
    // The test this module exists for. `osascript` exits 0 and the setting does
    // not move — an app that trusted the exit code would now be telling someone
    // their laptop will keep working in a bag, and it will not.
    const result = await setLidAwake(true, {
      platform: 'darwin',
      run: scriptedDarwin([PMSET_OFF, PMSET_OFF, PMSET_OFF]),
    })
    expect(result.outcome).toBe('failed')
    expect(result.state.on).toBe(false)
  })

  it('reports changed only once the OS agrees', async () => {
    const result = await setLidAwake(true, {
      platform: 'darwin',
      // before → after → the read inside `finish`
      run: scriptedDarwin([PMSET_OFF, PMSET_ON, PMSET_ON]),
    })
    expect(result.outcome).toBe('changed')
    expect(result.state.on).toBe(true)
  })

  it('writes nothing when it is already in the state asked for', async () => {
    const run = scriptedDarwin([PMSET_ON])
    const result = await setLidAwake(true, { platform: 'darwin', run })
    expect(result.outcome).toBe('unchanged')
    expect(run.calls.some((call) => call.file.endsWith('osascript'))).toBe(false)
  })

  it('calls a dismissed prompt cancelled, and leaves the state alone', async () => {
    const calls: Call[] = []
    const run: CommandRunner = (file, args) => {
      calls.push({ file, args: [...args] })
      if (args.includes('batt')) return Promise.resolve({ code: 0, stdout: BATT_AC, stderr: '' })
      if (file.endsWith('osascript')) {
        return Promise.resolve({ code: 1, stdout: '', stderr: 'execution error: User canceled. (-128)' })
      }
      return Promise.resolve({ code: 0, stdout: PMSET_OFF, stderr: '' })
    }
    const result = await setLidAwake(true, { platform: 'darwin', run })
    expect(result.outcome).toBe('cancelled')
    expect(result.state.on).toBe(false)
    expect(result.message).not.toMatch(/fail|error/i)
  })

  it('does nothing at all on a platform it does not support', async () => {
    const run = runner([])
    const result = await setLidAwake(true, { platform: 'linux', run })
    expect(result.outcome).toBe('unsupported')
    expect(run.calls).toEqual([])
  })

  describe('on Windows', () => {
    it('records the previous lid actions before overwriting them', async () => {
      const written: Record<string, number> = {}
      let query = POWERCFG_SLEEPING
      const run: CommandRunner = (_file, args) => {
        const line = args.join(' ')
        if (line.includes('/query')) return Promise.resolve({ code: 0, stdout: query, stderr: '' })
        if (line.includes('setacvalueindex') || line.includes('setdcvalueindex')) {
          query = POWERCFG_HELD
        }
        return Promise.resolve({ code: 0, stdout: '', stderr: '' })
      }
      const result = await setLidAwake(true, {
        platform: 'win32',
        run,
        readPrevious: () => null,
        writePrevious: (patch) => Object.assign(written, patch),
      })
      expect(result.outcome).toBe('changed')
      expect(written).toEqual({ [PREVIOUS_AC_KEY]: LID_SLEEP, [PREVIOUS_DC_KEY]: LID_SLEEP })
    })

    it('restores exactly what was there, not a guess', async () => {
      // Hibernate on battery, sleep on mains — an unusual pair, and precisely
      // the kind that a "restore to the default" implementation would silently
      // flatten. `powercfg` is asked for the exact indexes it was given.
      let query = POWERCFG_HELD
      const applied: string[] = []
      const run: CommandRunner = (_file, args) => {
        const line = args.join(' ')
        if (line.includes('/query')) return Promise.resolve({ code: 0, stdout: query, stderr: '' })
        if (line.includes('valueindex')) {
          applied.push(line)
          query = POWERCFG_SLEEPING
        }
        return Promise.resolve({ code: 0, stdout: '', stderr: '' })
      }
      const result = await setLidAwake(false, {
        platform: 'win32',
        run,
        readPrevious: (key) => (key === PREVIOUS_AC_KEY ? 1 : 2),
        writePrevious: () => {
          throw new Error('turning it off must not overwrite the remembered value')
        },
      })
      expect(result.outcome).toBe('changed')
      expect(applied).toEqual([
        '/setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1',
        '/setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 2',
      ])
    })

    it('falls back to sleep, and re-activates the scheme so the change takes', async () => {
      let query = POWERCFG_HELD
      const calls: string[] = []
      const run: CommandRunner = (_file, args) => {
        const line = args.join(' ')
        calls.push(line)
        if (line.includes('/query')) return Promise.resolve({ code: 0, stdout: query, stderr: '' })
        if (line.includes('valueindex')) query = POWERCFG_SLEEPING
        return Promise.resolve({ code: 0, stdout: '', stderr: '' })
      }
      await setLidAwake(false, { platform: 'win32', run, readPrevious: () => null })
      expect(calls).toContain('/setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1')
      // Without /setactive the edit is stored and never applied, which looks
      // exactly like the write having failed.
      expect(calls).toContain('/setactive SCHEME_CURRENT')
    })
  })
})

/* ------------------------------------------------------------- the warning -- */

describe('lowBatteryWarning', () => {
  it('says nothing while the machine is plugged in', () => {
    expect(lowBatteryWarning({ present: true, discharging: false, percent: 4 }, true)).toBeNull()
    expect(lowBatteryWarning(null, true)).toBeNull()
  })

  it('mentions the drain while there is still plenty left', () => {
    const warning = lowBatteryWarning({ present: true, discharging: true, percent: 80 }, true)
    expect(warning).toContain('80%')
    expect(warning).toContain('lid')
  })

  it('turns urgent below the threshold and says what to do', () => {
    const warning = lowBatteryWarning({ present: true, discharging: true, percent: 12 }, true)
    expect(warning).toContain('12%')
    expect(warning).toMatch(/plug it in|turn this off/i)
  })

  it('talks about a lid only on a machine that has one', () => {
    const warning = lowBatteryWarning({ present: true, discharging: true, percent: 12 }, false)
    expect(warning).not.toContain('lid')
  })
})

/* ---------------------------------------------------------- the controller -- */

interface FakeSchedule {
  armed: number
  cancelled: number
  fire(): void
}

function fakeSchedule(): {
  schedule: (callback: () => void, everyMs: number) => { cancel(): void }
  state: FakeSchedule
} {
  let job: (() => void) | null = null
  const state: FakeSchedule = {
    armed: 0,
    cancelled: 0,
    fire: () => job?.(),
  }
  return {
    schedule: (callback) => {
      state.armed += 1
      job = callback
      return {
        cancel: () => {
          state.cancelled += 1
          job = null
        },
      }
    },
    state,
  }
}

describe('LidAwakeController', () => {
  it('holds the idle blocker at launch when the machine is already held awake', async () => {
    // Nobody clicked anything. `disablesleep` survived a restart, the app came
    // up, and the app's own runtime has to agree with the machine it launched
    // onto — otherwise idle sleep is still free to take a running session down.
    blockersStarted.length = 0
    blockersStopped.length = 0
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
    })
    const state = await controller.refresh({ initial: true })
    expect(state.on).toBe(true)
    expect(state.preexisting).toBe(true)
    expect(blockersStarted.length).toBe(1)
    controller.stop()
    expect(blockersStopped.length).toBe(1)
  })

  /*
   * The reported fault, as a test.
   *
   * This case used to assert the opposite — "does not take a blocker on a
   * machine that is not held awake" — and that assertion *was* the bug. The
   * privileged lid setting needs an administrator password, so `SleepDisabled 0`
   * is the state of every machine on first run and of every machine where the
   * password sheet was dismissed. On all of those the app held nothing at all
   * and an idle timer was free to sleep a Mac with a phone attached to a running
   * agent: *"after a few seconds I can get disconnected."*
   *
   * The two locks are independent. `powerSaveBlocker` is free, unprivileged,
   * blocks only idle system sleep, and is the app's own; the lid setting is the
   * privileged one on top. Giving out the free one only to people who already
   * have the expensive one is backwards, so the free one is now unconditional.
   */
  it('holds the idle blocker even when the privileged lid setting is off', async () => {
    blockersStarted.length = 0
    blockersStopped.length = 0
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_OFF }],
      ]),
    })
    const state = await controller.refresh({ initial: true })
    expect(state.on).toBe(false)
    expect(state.idleBlocked).toBe(true)
    expect(blockersStarted.length).toBe(1)
    expect(blockersStopped.length).toBe(0)
    controller.stop()
    expect(blockersStopped.length).toBe(1)
  })

  it('takes the blocker before the machine has been read at all', async () => {
    /*
     * Ordering, not just eventual state. Reading the machine spawns `pmset`,
     * which is not instant, and on a platform this module does not support at
     * all it never answers "on" — so a blocker that waited for a read would
     * leave a window at every launch, and forever on Linux. Nothing about
     * blocking idle sleep needs the machine's answer.
     */
    blockersStarted.length = 0
    blockersStopped.length = 0
    let answered = false
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: () =>
        new Promise((resolve) =>
          setImmediate(() => {
            answered = true
            resolve({ code: 0, stdout: PMSET_OFF, stderr: '' })
          }),
        ),
    })
    controller.start()
    expect(answered).toBe(false)
    expect(blockersStarted.length).toBe(1)
    controller.stop()
  })

  it('keeps the blocker when the machine stops answering', async () => {
    /*
     * The quiet half of the same fault. `pmset` is given five seconds, and five
     * seconds is not much on a machine running several agents at once — which is
     * the machine this app is for. A single slow read used to come back
     * `known: false`, fall into the `else` branch and *release* a wake lock that
     * was correctly held, then cancel the only timer that would have re-read it.
     * The lock was gone for the rest of the run, with nothing on screen and
     * nothing in the log.
     */
    blockersStarted.length = 0
    blockersStopped.length = 0
    let attempt = 0
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: (file, args) => {
        if (args.includes('batt')) return Promise.resolve({ code: 0, stdout: BATT_AC, stderr: '' })
        attempt += 1
        return attempt === 1
          ? Promise.resolve({ code: 0, stdout: PMSET_ON, stderr: '' })
          : Promise.resolve({ code: -1, stdout: '', stderr: `${file} timed out` })
      },
    })
    await controller.refresh({ initial: true })
    expect(blockersStarted.length).toBe(1)

    const afterFailure = await controller.refresh()
    expect(afterFailure.known).toBe(false)
    expect(afterFailure.idleBlocked).toBe(true)
    expect(blockersStopped.length).toBe(0)
    controller.stop()
    expect(blockersStopped.length).toBe(1)
  })

  it('does not retire the low-battery warning because a read failed', async () => {
    /*
     * The same "unreadable is not a no" rule, on the other mechanism it broke.
     * A laptop being held awake on battery with 14% left is exactly the moment
     * the warning matters, and a `pmset` that times out told the controller the
     * machine was no longer held awake — which silently retired the warning and
     * cancelled the watch.
     */
    let attempt = 0
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: (_file, args) => {
        if (args.includes('batt')) return Promise.resolve({ code: 0, stdout: BATT_LOW, stderr: '' })
        attempt += 1
        return attempt === 1
          ? Promise.resolve({ code: 0, stdout: PMSET_ON, stderr: '' })
          : Promise.resolve({ code: -1, stdout: '', stderr: 'pmset timed out' })
      },
      schedule: () => ({ cancel: () => {} }),
    })
    const first = await controller.refresh({ initial: true })
    expect(first.warning).toMatch(/14%/)

    const second = await controller.refresh()
    expect(second.known).toBe(false)
    expect(second.warning).toMatch(/14%/)
    controller.stop()
  })

  it('does not record a blocker the platform refused, and takes it on the next read', async () => {
    /*
     * "Started but never acquired". `powerSaveBlocker.start` hands back an
     * integer whether or not the assertion was granted, so recording it
     * unconditionally made `hold()`'s early return fire forever against a lock
     * that did not exist — the app reporting success from the side that was not
     * doing the work.
     */
    let granted = false
    const started: number[] = []
    const stopped: number[] = []
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
      power: {
        startBlocker: () => {
          started.push(started.length + 1)
          return started.length
        },
        stopBlocker: (id) => void stopped.push(id),
        isBlockerStarted: () => granted,
        onBatteryPower: () => false,
        onPowerSourceChange: () => () => {},
        notify: () => {},
      },
    })

    const refused = await controller.refresh({ initial: true })
    expect(started).toHaveLength(1)
    expect(refused.idleBlocked).toBe(false)

    granted = true
    const taken = await controller.refresh()
    expect(started).toHaveLength(2)
    expect(taken.idleBlocked).toBe(true)

    // And once it is genuinely held, no further attempt is made.
    await controller.refresh()
    expect(started).toHaveLength(2)
    controller.stop()
    expect(stopped).toEqual([2])
  })

  it('pushes every state it reads to the renderer', async () => {
    const pushed: Array<{ channel: string; payload: unknown }> = []
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
      broadcast: (channel, payload) => pushed.push({ channel, payload }),
    })
    await controller.refresh()
    expect(pushed).toHaveLength(1)
    expect(pushed[0].channel).toBe(LID_AWAKE_STATE)
    controller.stop()
  })

  it('watches the battery only while it is being run down with the lock held', async () => {
    const { schedule, state } = fakeSchedule()
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_AC }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
      schedule,
    })
    await controller.refresh({ initial: true })
    // Held awake, but on mains: nothing to watch, so nothing is armed. A timer
    // with no consumer is pure cost, and this one would be waking a machine that
    // is being kept awake to save the power it is trying not to waste.
    expect(state.armed).toBe(0)
    controller.stop()

    const discharging = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_LOW }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
      schedule,
    })
    await discharging.refresh({ initial: true })
    expect(state.armed).toBe(1)
    discharging.stop()
    expect(state.cancelled).toBe(1)
  })

  it('warns once per discharge rather than once per read', async () => {
    notifications.length = 0
    const controller = new LidAwakeController({
      platform: 'darwin',
      run: runner([
        ['pmset -g batt', { stdout: BATT_LOW }],
        ['pmset -g', { stdout: PMSET_ON }],
      ]),
      schedule: () => ({ cancel: () => {} }),
    })
    await controller.refresh({ initial: true })
    await controller.refresh()
    await controller.refresh()
    expect(notifications).toHaveLength(1)
    expect(notifications[0].body).toContain('14%')
    controller.stop()
  })

  it('never turns the setting off by itself, however low the battery goes', async () => {
    // The decision, asserted. Dropping the lock would need a password sheet in
    // front of a closed lid, and a silent drop breaks the one promise the switch
    // made. It warns; it does not act.
    const run = runner([
      ['pmset -g batt', { stdout: BATT_LOW }],
      ['pmset -g', { stdout: PMSET_ON }],
    ])
    const controller = new LidAwakeController({
      platform: 'darwin',
      run,
      schedule: () => ({ cancel: () => {} }),
    })
    await controller.refresh({ initial: true })
    expect(run.calls.some((call) => call.file.endsWith('osascript'))).toBe(false)
    controller.stop()
  })

  it('polls no faster than a laptop with its lid shut needs', () => {
    expect(BATTERY_POLL_MS).toBeGreaterThanOrEqual(60_000)
  })
})

/* ------------------------------------------------------------- the wiring -- */

describe('the wiring', () => {
  it('registers both channels and reads the machine without being asked', async () => {
    // No cast: `registerLidAwakeIpc` asks for the one method it uses, so an
    // object with that method is the real parameter type rather than something
    // pretending to be one.
    const handlers = new Map<string, unknown>()
    const controller = registerLidAwakeIpc(
      { handle: (channel, listener) => void handlers.set(channel, listener) },
      {
        platform: 'darwin',
        run: runner([
          ['pmset -g batt', { stdout: BATT_AC }],
          ['pmset -g', { stdout: PMSET_ON }],
        ]),
      },
    )
    expect([...handlers.keys()].sort()).toEqual([LID_AWAKE_GET, LID_AWAKE_SET].sort())

    // `start()` fires the first read without any caller. Awaiting a turn of the
    // microtask queue is enough because the fake runner resolves immediately.
    await new Promise((done) => setImmediate(done))
    expect(controller.state?.on).toBe(true)
    controller.stop()
  })

  it('is attached at launch by the main process, not by a settings pane', () => {
    /*
     * The assertion that matters most in this file, and the reason it is a
     * string match rather than a mock: the failure being guarded against is a
     * whole feature that works perfectly when a button is pressed and is never
     * reached at boot. Only `src/main/index.ts` can make this one true, so only
     * `src/main/index.ts` is asked.
     */
    const index = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    expect(index).toContain('registerLidAwakeIpc(ipcMain')
    // And let go of again, so the wake lock does not outlive the process that
    // took it.
    expect(index).toMatch(/lidAwake\??\.stop\(\)/)
  })
})

/* --------------------------------------------------- the machine right here -- */

/**
 * The one thing every test above cannot prove.
 *
 * Everything else in this file is a fixture — text that was true of one Mac on
 * one day, pasted in. That checks the parser against a *memory* of the OS, and a
 * memory is exactly the kind of copy this module was written to avoid: the day
 * `pmset` reformats a column or renames a key, all forty of those tests keep
 * passing while the app on a real machine starts drawing an off switch over a
 * laptop that is being held awake.
 *
 * So this block asks the operating system running the test. It is deliberately
 * *not* an assertion about a value — this machine's setting can be on or off and
 * either is correct — but about **agreement between two independent sources**:
 * `readLidAwake` reaches its answer through `pmset -g`, and the check below
 * reaches its own through `ioreg`, which is a different command reading a
 * different surface (IOPMrootDomain's live property rather than a preferences
 * file) in a different format. If the parser has gone blind to the real output,
 * the two stop agreeing.
 *
 * Skipped off macOS rather than deleted, so it documents the boundary instead of
 * failing on a CI box that has no `pmset`.
 */
const onARealMac = process.platform === 'darwin' ? describe : describe.skip

onARealMac('read against the machine running this test', () => {
  it('reads this Mac without a fixture, and agrees with the kernel', async () => {
    const state = await readLidAwake()

    // Whatever this machine answers, it has to be an answer. `known: false` here
    // would mean the app is about to disable its own switch on a supported Mac.
    expect(state.supported).toBe(true)
    expect(state.known).toBe(true)
    expect(state.needsAuthorization).toBe(true)

    const registry = await runCommand('/usr/sbin/ioreg', ['-n', 'IOPMrootDomain', '-r', '-d', '1'])
    expect(registry.code).toBe(0)
    const live = parseIoregSleepDisabled(registry.stdout)
    // A Mac that has never been told either way prints no such property, and
    // `readDarwin` treats that absence as off — so null agrees with false.
    expect(state.on).toBe(live ?? false)
  })

  it('recognises this machine’s own power source and battery', async () => {
    const state = await readLidAwake()
    expect(state.battery).not.toBeNull()

    // A desktop is a legitimate answer, so the assertion is on coherence rather
    // than on hardware: a battery that is present reports a real percentage, and
    // one that is absent cannot be discharging.
    if (state.battery?.present === true) {
      expect(state.battery.percent).toBeGreaterThanOrEqual(0)
      expect(state.battery.percent).toBeLessThanOrEqual(100)
    } else {
      expect(state.battery?.discharging).toBe(false)
    }
  })

  it('leaves the power button alone — checked on the live settings, not a fixture', async () => {
    /*
     * Asad's requirement, verified against the machine rather than against a
     * string. `Sleep On Power Button` is a separate key that nothing in this
     * module writes, and this asserts it is still there and still readable next
     * to the key we do write — so a future change that reached for `pmset -a`
     * with a wider argument list would be caught here rather than by somebody
     * discovering their power button stopped locking the screen.
     */
    const settings = await runCommand('/usr/bin/pmset', ['-g'])
    expect(settings.code).toBe(0)
    expect(settings.stdout).toMatch(/Sleep On Power Button/)
    expect(pmsetScript(true)).not.toMatch(/powerbutton/i)
    expect(pmsetScript(false)).not.toMatch(/powerbutton/i)
  })
})

/* ------------------------------------------------ the console window on Windows -- */

/**
 * The one thing this module does on Windows that a Mac cannot see at all.
 *
 * `runCommand` was the only spawn helper in `src/main` that did not pass
 * `windowsHide`, and it is the one that runs a Windows *console* binary:
 * `%SystemRoot%\System32\powercfg.exe`. Without the flag every call paints a
 * black console window over whatever the user is doing and takes focus with it.
 * This file calls it on launch, on every AC/battery transition, and four times
 * in a row when the switch is flipped — `/query`, `/setdcvalueindex`,
 * `/setacvalueindex`, `/setactive` — so it is a burst of flashes, on the one
 * feature whose entire purpose is to be left running unattended overnight.
 *
 * Asserted against the source rather than by spawning, for the same reason the
 * launch-wiring test above is: no behavioural test can see a window that
 * appears on a different operating system, and the command still works either
 * way — which is exactly why it survived review. `tool-probe.test.ts` runs the
 * same scan over the files it owns and its header makes the argument at length;
 * this is that scan pointed at the one call `runCommand` makes, because the
 * generic version cannot tell this module's *own* injected `run` seam apart
 * from a real child process.
 */
describe('powercfg does not flash a console window', () => {
  /** The text between a call's parentheses, however deeply nested. */
  function callArguments(text: string, open: number): string {
    let depth = 0
    for (let i = open; i < text.length; i++) {
      if (text[i] === '(') depth++
      else if (text[i] === ')') {
        depth--
        if (depth === 0) return text.slice(open + 1, i)
      }
    }
    return text.slice(open + 1)
  }

  it('passes windowsHide on the one real child process this module starts', () => {
    const source = readFileSync(join(__dirname, 'lid-awake.ts'), 'utf8')
    // `execFile(` with a newline after it is the call inside `runCommand`; the
    // import above it is `execFile }` and does not match.
    const open = source.indexOf('execFile(')
    expect(open, 'lid-awake.ts no longer spawns anything — delete this test').toBeGreaterThan(-1)
    const args = callArguments(source, open + 'execFile'.length)
    expect(
      args,
      'On Windows a spawn without `windowsHide: true` flashes a console window over whatever ' +
        'the user is doing. powercfg.exe is a console program and this helper runs it on every read.',
    ).toContain('windowsHide: true')
  })

  /*
   * The same claim, on whichever machine is running the suite.
   *
   * This used to run `/usr/bin/pmset` unconditionally and assert it exited 0 —
   * which is a fact about macOS, not about the flag. On the Windows runner it
   * answered `-1`, because the binary is not there, and the test reported a
   * defect that did not exist. It is one of the six shapes this repository has
   * been caught by: **a test that measures the machine it happens to be on.**
   * There is an `onARealMac` gate a few lines above it in this same file; this
   * one simply predates it.
   *
   * Gating alone would have been the wrong fix, because the claim is about
   * `windowsHide` being harmless — and the platform where it is *not* a no-op
   * is the one a skip would stop checking. So each side runs a command it
   * actually has, and both assert the same thing: the helper spawns, with the
   * flag on, and comes back.
   */
  const alwaysThere =
    process.platform === 'win32'
      ? { file: 'cmd.exe', args: ['/c', 'echo', 'ok'] }
      : { file: '/bin/echo', args: ['ok'] }

  it('spawns with the flag on and comes back, on whichever machine this is', async () => {
    const answer = await runCommand(alwaysThere.file, alwaysThere.args)
    expect(answer.code, `${alwaysThere.file} did not run`).toBe(0)
    expect(answer.stdout).toContain('ok')
  })
})
