/**
 * Keeping this machine awake with the lid shut.
 *
 * ## The measurement this whole module is built around
 *
 * Electron's `powerSaveBlocker` does **not** do this, and believing that it does
 * is the trap. `prevent-app-suspension` maps to an IOKit assertion on macOS
 * (`PreventUserIdleSystemSleep`) and to `SetThreadExecutionState(ES_SYSTEM_REQUIRED)`
 * on Windows, and both of those block *idle* sleep — the sleep that happens
 * because nobody touched the keyboard. Closing the lid is not idle sleep. It is
 * a separate path, and on macOS the only thing that stops it is the system-wide
 * `disablesleep` switch, which is root-only:
 *
 *     sudo pmset -a disablesleep 1
 *
 * So an app that holds a power-save blocker and tells the user "your machine
 * will stay awake with the lid closed" is the exact failure this codebase keeps
 * writing modules to prevent: every layer reporting success while the thing the
 * user asked for does not happen. The blocker is still taken here — idle sleep
 * is a second, real way to lose a running agent — but it is never what the
 * switch reports on. See `readLidAwake`.
 *
 * ## Reading the truth instead of remembering it
 *
 * `disablesleep` is a **system** setting. It is not ours, it outlives this
 * process, and `sudo pmset`, another app, or a previous install of this one can
 * change it while we are not looking. A stored boolean would therefore be a
 * cached copy of somebody else's fact — the copy that rots, because nothing
 * fails when it lies. Every read here goes to the OS. Measured on the machine
 * this was written on, macOS 27:
 *
 *     $ pmset -g
 *     System-wide power settings:
 *      SleepDisabled          1          ← the lid switch
 *     Currently in use:
 *      sleep                  0 (sleep prevented by caffeinate, Claude, powerd)
 *      Sleep On Power Button  1
 *
 * Two traps live in that output. `sleep 0` is the **idle** timer and says
 * nothing about the lid — a machine can show `sleep 0` and still sleep the
 * instant it is closed. And `Sleep On Power Button` is a *different key* that we
 * never touch, which is what keeps Asad's requirement intact: pressing the power
 * button still locks the way it always did, because nothing here writes that
 * setting.
 *
 * ## Why AppleScript, and not sudo
 *
 * The privileged call goes through
 *
 *     osascript -e 'do shell script "…" with administrator privileges'
 *
 * which is macOS's own authorisation flow: AppleScript hands the request to the
 * Security Server, macOS draws the password sheet, and the password is typed
 * into the OS. **This process never sees it, never stores it and never pipes
 * it.** That is the entire reason for choosing it over spawning `sudo` and
 * feeding a password down a pipe, which would put the user's admin credential
 * inside an Electron app's memory.
 *
 * Two alternatives were considered and rejected, and the reasons are worth
 * keeping because they will be proposed again:
 *
 *   - **An `SMJobBless` privileged helper.** The textbook answer, and the only
 *     one that can change this setting with no prompt at all afterwards. It also
 *     means shipping a second signed executable, a launchd job, and a helper
 *     whose code-signing requirement has to match the app's — it cannot work at
 *     all under `electron-vite dev`, so the feature would be untestable in
 *     development. Far too much machinery for one boolean.
 *   - **Writing a `/etc/sudoers.d` rule** so later calls need no password. It
 *     genuinely would make on *and* off promptless forever. It is also a
 *     permanent grant of root for a shell command, installed by a text editor's
 *     worth of syntax, where a malformed file breaks `sudo` for the entire
 *     machine. A settings toggle does not get to make that trade.
 *
 * ## The prompt, and how often it appears
 *
 * Asad's decision: *"when somebody clicks to turn it on this feature with the
 * toggle it will give a popup so he will type the password and then this feature
 * will be activated that's it I think it's never needed again."*
 *
 * That is exactly what happens, and the reason is structural rather than
 * remembered: `disablesleep` stays 1 in the system's own power preferences until
 * something sets it back. Closing and opening the lid, quitting the app,
 * restarting it — none of them ask again, because none of them change the
 * setting. What *does* ask again is turning it **off**, because macOS guards the
 * write in both directions and there is no such thing as a half-privileged
 * `pmset`. The UI says so before the first prompt rather than surprising anyone
 * with the second.
 *
 * ## Windows
 *
 * No administrator prompt, and a different mechanism: the lid-close *action*
 * is a per-power-scheme setting, so we set it to "do nothing" for both AC and
 * battery through `powercfg`, and hold the wake lock with the power-save blocker
 * (which is `SetThreadExecutionState` underneath). Because `powercfg` hands back
 * the old indexes before we overwrite them, Windows is the platform where
 * "turn it off" can restore *precisely* what was there rather than a sensible
 * default — so the old values are written down before the change and used on the
 * way back out.
 *
 * Wiring:
 *
 *     import { registerLidAwakeIpc } from './lid-awake'
 *     const lid = registerLidAwakeIpc(ipcMain, { broadcast: send })
 *     // and, at quit:
 *     lid.stop()
 */

import { execFile } from 'node:child_process'
import { join } from 'node:path'
import {
  Notification,
  powerMonitor,
  powerSaveBlocker,
  type IpcMain,
  type IpcMainInvokeEvent,
} from 'electron'
import { patchStoredSettings, storedValue } from './settings-extra'

/* ------------------------------------------------------------- running -- */

export interface CommandResult {
  /** The process's exit code, or -1 when it never ran or was killed. */
  code: number
  stdout: string
  stderr: string
}

export interface CommandRunner {
  (file: string, args: readonly string[], options?: { timeoutMs?: number }): Promise<CommandResult>
}

/**
 * `execFile`, reshaped so it cannot throw.
 *
 * Every caller here wants the same three things whether the command succeeded or
 * failed, and Node makes that unnecessarily easy to get wrong: on a non-zero
 * exit **and on a timeout** it rejects, and the output is hidden on properties
 * of the rejection object rather than being handed back. That has already cost
 * this project real debugging time elsewhere — a `timeout` on an `execFile` turned
 * a Tailscale authorisation prompt into a silent fifteen-second hang, because the
 * stdout explaining what it wanted was sitting on the error nobody unpacked.
 *
 * So the error is unpacked here, once, and the rest of this file reads a plain
 * result. A command that cannot be spawned at all — `powercfg` missing, `pmset`
 * gone — comes back as code -1 with the reason in `stderr`, which every caller
 * already has to handle because a non-zero exit lands in the same branch.
 */
export const runCommand: CommandRunner = (file, args, options = {}) =>
  new Promise((resolve) => {
    execFile(
      file,
      [...args],
      { timeout: options.timeoutMs, maxBuffer: 1024 * 1024 },
      (error, stdout, stderr) => {
        if (!error) {
          resolve({ code: 0, stdout, stderr })
          return
        }
        const withOutput = error as NodeJS.ErrnoException & { code?: number | string }
        const code = typeof withOutput.code === 'number' ? withOutput.code : -1
        resolve({
          code,
          stdout: stdout || '',
          stderr: stderr || error.message,
        })
      },
    )
  })

/* --------------------------------------------------------------- shapes -- */

export interface BatteryReading {
  /** Does this machine have an internal battery? A desktop has no lid either. */
  present: boolean
  /** True when the machine is running off that battery right now. */
  discharging: boolean
  /** 0–100, or null when the level could not be read on this platform. */
  percent: number | null
}

export interface LidAwakeState {
  /** Can this platform hold the lid open at all? */
  supported: boolean
  /**
   * What the OS says right now — never what this app last asked for.
   *
   * Meaningless unless `known` is true.
   */
  on: boolean
  /** False when the OS could not be asked. The UI must not draw a state then. */
  known: boolean
  platform: NodeJS.Platform
  /** Does changing this put the OS's own password dialog on screen? */
  needsAuthorization: boolean
  /** True when it was already on before this app launched — someone else's doing. */
  preexisting: boolean
  battery: BatteryReading | null
  /** Why `known` or `supported` is false. Null when there is nothing to explain. */
  detail: string | null
  /** A live risk worth putting in front of the user, or null. */
  warning: string | null
}

export type LidAwakeOutcome =
  /** The OS agrees the setting is now what was asked for. */
  | 'changed'
  /** It was already in that state; nothing was written. */
  | 'unchanged'
  /** The user dismissed the authorisation dialog. Not a failure. */
  | 'cancelled'
  /** The command ran and the OS did not end up in the requested state. */
  | 'failed'
  | 'unsupported'

export interface LidAwakeResult {
  outcome: LidAwakeOutcome
  /** Re-read from the OS after the write. Never inferred from an exit code. */
  state: LidAwakeState
  message: string
}

/* ------------------------------------------------------------- parsing -- */

/**
 * Whether `pmset -g` says the lid switch is on.
 *
 * Three answers, and the third is the point. `true` and `false` are the two
 * states of the `SleepDisabled` line; `null` means the line was not there at
 * all, which is genuinely ambiguous — a Mac that has never been told either way
 * has no `SleepDisabled` key in its `SystemPowerSettings` dictionary and prints
 * nothing, and so does a future macOS that renamed it. `readLidAwake` resolves
 * that ambiguity with a second opinion rather than guessing here, because
 * guessing "off" would eventually draw an off switch on a machine that is being
 * held awake.
 *
 * Only ever one line can match: `SleepDisabled` appears in the "System-wide
 * power settings" block and nowhere else in the output.
 */
export function parseSleepDisabled(stdout: string): boolean | null {
  const match = /^\s*SleepDisabled\s+(\S+)\s*$/m.exec(stdout)
  if (!match) return null
  const value = match[1].toLowerCase()
  return value === '1' || value === 'true' || value === 'yes'
}

/**
 * The same fact out of the kernel's own registry, used only as a tie-breaker.
 *
 *     $ ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled
 *           "SleepDisabled" = Yes
 *
 * This is IOPMrootDomain's live property rather than a preferences file, so it
 * cannot disagree with reality — but `pmset` stays the primary read, because it
 * is the documented interface and the one a user can check by hand.
 */
export function parseIoregSleepDisabled(stdout: string): boolean | null {
  const match = /"SleepDisabled"\s*=\s*(\w+)/.exec(stdout)
  if (!match) return null
  const value = match[1].toLowerCase()
  return value === 'yes' || value === 'true' || value === '1'
}

/**
 * `pmset -g batt`, which answers two questions in three lines:
 *
 *     Now drawing from 'AC Power'
 *      -InternalBattery-0 (id=23920739)	100%; charged; 0:00 remaining present: true
 *
 * A machine with no battery prints only the first line — which is how a desktop
 * Mac is recognised, and therefore how the copy avoids talking about a lid that
 * does not exist.
 */
export function parseBattery(stdout: string): BatteryReading {
  const drawing = /Now drawing from '([^']+)'/.exec(stdout)
  const percent = /(\d{1,3})%/.exec(stdout)
  const present = /present:\s*true/i.test(stdout)
  return {
    present,
    // Only the words macOS actually uses. Anything unrecognised reads as "not
    // discharging", which under-warns rather than crying wolf on a plugged-in
    // machine — and the percentage is shown beside it either way.
    discharging: present && /battery power/i.test(drawing?.[1] ?? ''),
    percent: percent ? Math.min(100, Number(percent[1])) : null,
  }
}

/** What Windows does when the lid closes. The indexes `powercfg` speaks in. */
export const LID_DO_NOTHING = 0
export const LID_SLEEP = 1

export interface LidActionIndexes {
  /** On mains power, or null when the query did not report it. */
  ac: number | null
  /** On battery, or null. A desktop reports no DC setting. */
  dc: number | null
}

/**
 * `powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION`, whose useful part is:
 *
 *     Current AC Power Setting Index: 0x00000000
 *     Current DC Power Setting Index: 0x00000001
 *
 * Both are parsed, and both have to be "do nothing" before the switch is allowed
 * to read as on: a laptop whose AC action is "do nothing" and whose battery
 * action is "sleep" keeps working with the lid shut right up until it is
 * unplugged, which is the moment the user is least able to notice.
 */
export function parseLidActionIndexes(stdout: string): LidActionIndexes {
  const read = (source: 'AC' | 'DC'): number | null => {
    const match = new RegExp(`Current ${source} Power Setting Index:\\s*(0x[0-9a-fA-F]+|\\d+)`).exec(stdout)
    if (!match) return null
    const value = Number(match[1])
    return Number.isFinite(value) ? value : null
  }
  return { ac: read('AC'), dc: read('DC') }
}

/* ------------------------------------------------------------ the battery -- */

/**
 * Below this, a machine held awake with its lid shut is worth interrupting for.
 *
 * Twenty rather than ten: the user has to *open the lid* to act on the warning,
 * and by the time it is urgent it may be too late to be useful.
 */
export const LOW_BATTERY_PERCENT = 20

/**
 * The sentence to put in front of the user, or null when there is nothing to
 * say.
 *
 * Pure, and exported, because the wording *is* the safety feature here — this is
 * the only thing standing between "close the lid and keep working" and a machine
 * that quietly runs itself flat in a bag. A test can read a sentence; it cannot
 * read a screenshot.
 *
 * ## Why the lock is not simply dropped at 20%
 *
 * The obvious design is to turn the setting off automatically when the battery
 * gets low. It was rejected for two reasons, and both are worth stating plainly
 * rather than being discovered later:
 *
 *  1. **It cannot be done silently on macOS.** Turning it off is the same
 *     privileged write as turning it on, so it would put a password dialog on
 *     screen — in front of a machine whose lid is *closed*. A prompt nobody can
 *     see is not a safety mechanism; it is a hang.
 *  2. **A silent drop is the worse failure.** The user closed the lid precisely
 *     because they wanted work to keep running. An app that quietly lets the
 *     machine sleep mid-run, having promised not to, has broken the one promise
 *     it made. Losing an hour of agent work to a "helpful" release is a worse
 *     outcome than a flat battery the user was warned about twice.
 *
 * So the decision is: **warn, loudly and early, and never drop the lock without
 * being asked.** The warning goes out as a desktop notification (which macOS
 * queues and shows the moment the lid opens) and sits in the settings pane, and
 * turning it off stays one click away.
 *
 * The backstop is the OS's own: macOS and Windows both force a sleep or
 * hibernate at a critically low battery to protect unsaved state, and neither
 * asks this setting's permission first. That is a fact about the platform rather
 * than anything this app arranges, so the copy does not lean on it.
 */
export function lowBatteryWarning(battery: BatteryReading | null, hasLid: boolean): string | null {
  if (!battery || !battery.present || !battery.discharging) return null
  const where = hasLid ? 'with the lid shut' : 'awake'
  if (battery.percent === null) {
    return `This machine is running on battery and is being kept ${where}. Nothing will let it sleep to save power.`
  }
  if (battery.percent > LOW_BATTERY_PERCENT) {
    return `On battery at ${battery.percent}%, and being kept ${where} — it will drain faster than usual.`
  }
  return `Battery is at ${battery.percent}% and this machine is being kept ${where}. Plug it in, or turn this off.`
}

/* ---------------------------------------------------------------- paths -- */

const PMSET = '/usr/bin/pmset'
const OSASCRIPT = '/usr/bin/osascript'
const IOREG = '/usr/sbin/ioreg'

/**
 * `powercfg` by absolute path rather than by name.
 *
 * `execFile` without a shell still searches `PATH`, and `PATH` on Windows
 * routinely contains directories a user can write to. This command is about to
 * be handed the machine's power configuration; it should be the one in
 * System32 and no other.
 */
function powercfgPath(): string {
  return join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'powercfg.exe')
}

/** How long a plain read is given before it is treated as unanswerable. */
const READ_TIMEOUT_MS = 5000

/**
 * How long the authorisation call is given: five minutes.
 *
 * Deliberately enormous, because the clock is running while a **human being
 * finds their password**. A conventional 10- or 30-second timeout would kill
 * `osascript` with the macOS password sheet still on screen, and the user would
 * watch their own dialog vanish mid-typing and get "the command timed out" for
 * an answer.
 */
const AUTH_TIMEOUT_MS = 5 * 60 * 1000

/* ---------------------------------------------------------- windows memory -- */

/**
 * Where the pre-change lid actions are kept between runs.
 *
 * Not the state — the state is always read from the OS — but the *previous*
 * state, which the OS can no longer tell us once it has been overwritten. This
 * is the only way "turn it off" can restore what was actually there rather than
 * a guess, across an app restart. Stored beside the app's other non-schema keys
 * (`remote.enabled` sets the precedent) rather than in the settings schema,
 * because it is not a preference: nobody chooses it and nothing should show it.
 */
export const PREVIOUS_AC_KEY = 'power.lidAwake.previousAc'
export const PREVIOUS_DC_KEY = 'power.lidAwake.previousDc'

function rememberedIndex(key: string): number | null {
  const value = storedValue(key)
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/* ----------------------------------------------------------------- reads -- */

export interface ReadOptions {
  run?: CommandRunner
  platform?: NodeJS.Platform
}

const UNSUPPORTED_DETAIL =
  'Holding a machine awake through a lid close is only wired up for macOS and Windows.'

/**
 * Everything a read can answer. `preexisting` and `warning` are the two fields
 * only the controller can fill in, so they are named once here rather than being
 * re-listed by every function that produces one.
 */
export type LidAwakeReading = Omit<LidAwakeState, 'preexisting' | 'warning'>

function unsupportedReading(platform: NodeJS.Platform): LidAwakeReading {
  return {
    supported: false,
    on: false,
    known: true,
    platform,
    needsAuthorization: false,
    battery: null,
    detail: UNSUPPORTED_DETAIL,
  }
}

async function readDarwin(run: CommandRunner): Promise<LidAwakeReading> {
  const base = {
    supported: true,
    platform: 'darwin' as NodeJS.Platform,
    needsAuthorization: true,
  }

  const [settings, batt] = await Promise.all([
    run(PMSET, ['-g'], { timeoutMs: READ_TIMEOUT_MS }),
    run(PMSET, ['-g', 'batt'], { timeoutMs: READ_TIMEOUT_MS }),
  ])

  // Null, not an empty reading, when the battery command failed. A parse of ''
  // reports `present: false`, which the copy reads as "this is a desktop, it has
  // no lid" — a wrong answer with a confident tone, on a laptop.
  const battery = batt.code === 0 ? parseBattery(batt.stdout) : null

  if (settings.code !== 0) {
    return {
      ...base,
      on: false,
      known: false,
      battery,
      detail: `This Mac would not report its power settings: ${firstLine(settings.stderr) || `pmset exited ${settings.code}`}`,
    }
  }

  const stated = parseSleepDisabled(settings.stdout)
  if (stated !== null) {
    return { ...base, on: stated, known: true, battery, detail: null }
  }

  // The key was absent, which on its own means either "never set" or "this
  // output is not the shape we parse any more". Ask the kernel directly before
  // deciding; a confident "off" for a machine that is in fact being held awake
  // is the one wrong answer that matters, because it hides a running battery
  // drain behind a switch that looks harmless.
  const registry = await run(IOREG, ['-n', 'IOPMrootDomain', '-r', '-d', '1'], {
    timeoutMs: READ_TIMEOUT_MS,
  })
  if (registry.code === 0) {
    const live = parseIoregSleepDisabled(registry.stdout)
    // pmset printed no line and the registry says it is off: agreement, and the
    // ordinary state of a Mac nobody has touched.
    if (live === null || live === false) {
      return { ...base, on: false, known: true, battery, detail: null }
    }
    return {
      ...base,
      on: true,
      known: false,
      battery,
      detail:
        'This Mac is being held awake according to the kernel, but pmset did not list the setting — ' +
        'so the app cannot say whether turning it off here would work.',
    }
  }

  return {
    ...base,
    on: false,
    known: false,
    battery,
    detail: 'pmset did not list the sleep setting, and the app could not confirm it another way.',
  }
}

async function readWindows(run: CommandRunner): Promise<LidAwakeReading> {
  const base = {
    supported: true,
    platform: 'win32' as NodeJS.Platform,
    // The whole point of the Windows path: no elevation anywhere in it.
    needsAuthorization: false,
  }

  const query = await run(powercfgPath(), ['/query', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION'], {
    timeoutMs: READ_TIMEOUT_MS,
  })
  if (query.code !== 0) {
    return {
      ...base,
      on: false,
      known: false,
      battery: null,
      detail: `Windows would not report the lid-close action: ${firstLine(query.stderr) || `powercfg exited ${query.code}`}`,
    }
  }

  const indexes = parseLidActionIndexes(query.stdout)
  if (indexes.ac === null && indexes.dc === null) {
    return {
      ...base,
      supported: false,
      on: false,
      known: true,
      battery: null,
      detail: 'This machine reports no lid-close action, which usually means it has no lid.',
    }
  }

  // Battery *level* has no cheap, non-deprecated command-line source on Windows
  // — `wmic` is gone in current builds and spawning PowerShell for a number is
  // not worth it — so the level is left null and the warning falls back to "on
  // battery", which `powerMonitor` reports for free. Saying less is the honest
  // half of the trade.
  const onBattery = powerMonitor.onBatteryPower === true
  const battery: BatteryReading = {
    present: indexes.dc !== null,
    discharging: onBattery,
    percent: null,
  }

  const held =
    indexes.ac === LID_DO_NOTHING && (indexes.dc === null || indexes.dc === LID_DO_NOTHING)

  return { ...base, on: held, known: true, battery, detail: null }
}

function firstLine(text: string): string {
  return text.split('\n')[0]?.trim() ?? ''
}

/**
 * What the operating system says, right now.
 *
 * `preexisting` and `warning` are filled in by the controller, which is the only
 * thing that knows when the app launched and is the only thing that should be
 * deciding what to interrupt a user for.
 */
export async function readLidAwake(options: ReadOptions = {}): Promise<LidAwakeReading> {
  const platform = options.platform ?? process.platform
  const run = options.run ?? runCommand
  if (platform === 'darwin') return readDarwin(run)
  if (platform === 'win32') return readWindows(run)
  return unsupportedReading(platform)
}

/* ---------------------------------------------------------------- writes -- */

/**
 * An AppleScript string literal.
 *
 * The command itself is a constant, so there is nothing here a user can inject
 * into — but the escaping is done properly anyway, because the day someone adds
 * an interpolated path to that command is the day this stops being true, and a
 * quoting bug in a string that runs as root is not the place to find out.
 */
export function appleScriptLiteral(value: string): string {
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

/** The one privileged command this app ever runs, in both directions. */
export function pmsetScript(on: boolean): string {
  return `do shell script ${appleScriptLiteral(`${PMSET} -a disablesleep ${on ? 1 : 0}`)} with administrator privileges`
}

/**
 * Did the user dismiss the password sheet?
 *
 * AppleScript reports a cancelled authorisation as error -128, the same code it
 * uses for any cancelled dialog. Telling that apart from a real failure matters
 * more than it looks: "you cancelled" leaves the switch where it was and says
 * nothing alarming, while "macOS refused" sends someone hunting for a problem
 * that does not exist.
 */
export function isAuthorizationCancelled(result: CommandResult): boolean {
  return /-128\b/.test(result.stderr) || /user canceled/i.test(result.stderr)
}

export interface WriteOptions extends ReadOptions {
  /** Reads the previously stored Windows lid actions. Injected for tests. */
  readPrevious?: (key: string) => number | null
  /** Writes them. Injected for tests. */
  writePrevious?: (patch: Record<string, number>) => void
}

/**
 * Ask the OS to change it, then **ask the OS what happened**.
 *
 * The re-read at the end is the whole discipline of this file. `pmset` exiting 0
 * is not evidence that the machine will stay awake; only the machine saying
 * `SleepDisabled 1` is. Every outcome below is derived from that second read,
 * never from an exit code — which is why a command that succeeds and leaves the
 * setting untouched comes back `failed` rather than as a cheerful lie.
 */
export async function setLidAwake(on: boolean, options: WriteOptions = {}): Promise<LidAwakeResult> {
  const platform = options.platform ?? process.platform
  const run = options.run ?? runCommand
  const readPrevious = options.readPrevious ?? rememberedIndex
  const writePrevious =
    options.writePrevious ?? ((patch: Record<string, number>) => void patchStoredSettings(patch))

  const finish = async (outcome: LidAwakeOutcome, message: string): Promise<LidAwakeResult> => {
    const state = await readLidAwake({ run, platform })
    return {
      outcome,
      state: { ...state, preexisting: false, warning: null },
      message,
    }
  }

  if (platform !== 'darwin' && platform !== 'win32') {
    return finish('unsupported', UNSUPPORTED_DETAIL)
  }

  const before = await readLidAwake({ run, platform })
  if (before.known && before.on === on) {
    return finish('unchanged', on ? 'It was already on.' : 'It was already off.')
  }

  if (platform === 'darwin') {
    const result = await run(OSASCRIPT, ['-e', pmsetScript(on)], { timeoutMs: AUTH_TIMEOUT_MS })
    if (result.code !== 0) {
      if (isAuthorizationCancelled(result)) {
        return finish('cancelled', 'Nothing changed — the password prompt was dismissed.')
      }
      return finish(
        'failed',
        `macOS would not change the setting: ${firstLine(result.stderr) || `osascript exited ${result.code}`}`,
      )
    }
  } else {
    // Write down what Windows is doing *before* overwriting it. Only on the way
    // in — doing it on the way out would record the value this app just wrote.
    if (on) {
      const query = await run(
        powercfgPath(),
        ['/query', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION'],
        { timeoutMs: READ_TIMEOUT_MS },
      )
      if (query.code === 0) {
        const previous = parseLidActionIndexes(query.stdout)
        const patch: Record<string, number> = {}
        if (previous.ac !== null) patch[PREVIOUS_AC_KEY] = previous.ac
        if (previous.dc !== null) patch[PREVIOUS_DC_KEY] = previous.dc
        if (Object.keys(patch).length > 0) writePrevious(patch)
      }
    }

    const acIndex = on ? LID_DO_NOTHING : (readPrevious(PREVIOUS_AC_KEY) ?? LID_SLEEP)
    const dcIndex = on ? LID_DO_NOTHING : (readPrevious(PREVIOUS_DC_KEY) ?? LID_SLEEP)

    for (const [flag, index] of [
      ['/setacvalueindex', acIndex],
      ['/setdcvalueindex', dcIndex],
    ] as const) {
      const result = await run(
        powercfgPath(),
        [flag, 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', String(index)],
        { timeoutMs: READ_TIMEOUT_MS },
      )
      if (result.code !== 0) {
        return finish(
          'failed',
          `Windows would not change the lid-close action: ${firstLine(result.stderr) || `powercfg exited ${result.code}`}`,
        )
      }
    }
    // Without this the scheme is edited and never re-applied, so the change is
    // stored and does not take effect until the next time the scheme is
    // activated — which looks exactly like the write silently failing.
    await run(powercfgPath(), ['/setactive', 'SCHEME_CURRENT'], { timeoutMs: READ_TIMEOUT_MS })
  }

  const after = await readLidAwake({ run, platform })
  if (after.known && after.on === on) {
    return {
      outcome: 'changed',
      state: { ...after, preexisting: false, warning: null },
      message: on
        ? 'On. This machine will keep running with the lid closed.'
        : 'Off. The lid puts this machine to sleep again.',
    }
  }

  return {
    outcome: 'failed',
    state: { ...after, preexisting: false, warning: null },
    message: after.known
      ? 'The command ran and the setting did not change.'
      : (after.detail ?? 'The setting could not be read back afterwards.'),
  }
}

/* ------------------------------------------------------------ the runtime -- */

/**
 * The bits of Electron this controller touches, behind an interface so the
 * controller can be tested without an app, a window or a real battery.
 */
export interface PowerApi {
  startBlocker(): number
  stopBlocker(id: number): void
  onBatteryPower(): boolean
  /** Subscribe to mains/battery transitions. Returns an unsubscribe. */
  onPowerSourceChange(callback: (onBattery: boolean) => void): () => void
  notify(title: string, body: string): void
}

export const electronPowerApi: PowerApi = {
  // 'prevent-app-suspension', not 'prevent-display-sleep': the user asked for the
  // screen to go *off* while the work carries on. Blocking the display would
  // leave a lit screen inside a closed laptop, which is both wrong and hot.
  startBlocker: () => powerSaveBlocker.start('prevent-app-suspension'),
  stopBlocker: (id) => {
    if (powerSaveBlocker.isStarted(id)) powerSaveBlocker.stop(id)
  },
  onBatteryPower: () => powerMonitor.onBatteryPower === true,
  onPowerSourceChange: (callback) => {
    const onBattery = () => callback(true)
    const onAc = () => callback(false)
    powerMonitor.on('on-battery', onBattery)
    powerMonitor.on('on-ac', onAc)
    return () => {
      powerMonitor.off('on-battery', onBattery)
      powerMonitor.off('on-ac', onAc)
    }
  },
  notify: (title, body) => {
    if (!Notification.isSupported()) return
    new Notification({ title, body }).show()
  },
}

/**
 * How often the battery level is re-read while the lock is held on battery.
 *
 * A timer, in a codebase whose standing rule is events over timers — so the
 * justification is written down rather than assumed. `powerMonitor` announces
 * the *transition* between mains and battery and nothing else; there is no
 * event anywhere in Electron, IOKit-via-Node or the Win32 surface we have here
 * for "the battery reached 20%". This is therefore the only reading available.
 *
 * What keeps it honest is that it barely ever runs: it is armed only while the
 * lock is actually held **and** the machine is actually discharging, it is
 * disarmed the moment either stops being true, and it does not exist at all on
 * Windows, where there is no level to read. Two minutes, because the thing being
 * watched is a laptop sitting still with its lid shut — a battery does not fall
 * twenty points in two minutes, and a faster tick would only wake a machine that
 * is being kept awake to save power it is trying not to waste.
 */
export const BATTERY_POLL_MS = 2 * 60 * 1000

export interface ControllerOptions {
  run?: CommandRunner
  platform?: NodeJS.Platform
  power?: PowerApi
  /** Main → renderer push, so a settings pane that is open stays current. */
  broadcast?: (channel: string, payload: unknown) => void
  /** Injected so a test can drive the battery watch without waiting two minutes. */
  schedule?: (callback: () => void, everyMs: number) => { cancel(): void }
}

export const LID_AWAKE_GET = 'power:lid-awake:get'
export const LID_AWAKE_SET = 'power:lid-awake:set'
/**
 * The push channel, deliberately a different string from the request channel.
 *
 * Giving a request and an event the same name is how the next `handle`/`send`
 * mix-up gets written — the update module says the same thing for the same
 * reason.
 */
export const LID_AWAKE_STATE = 'power:lid-awake:state'

/**
 * Everything with a lifetime: the wake lock, the battery watch, and the one fact
 * that cannot be read from the OS — whether this was already on before we
 * started.
 *
 * ## Why this attaches at launch and not when the switch is clicked
 *
 * The bug class that has cost this project the most is a feature wired to a
 * button and never wired to boot. Here it has a specific shape: `disablesleep`
 * survives a restart, so the ordinary case is an app launching onto a machine
 * that is *already* being held awake — by yesterday's click, by the user's own
 * `sudo pmset`, by anything. If the controller only woke up when somebody opened
 * Settings, then in that ordinary case nothing would hold the idle-sleep blocker
 * and nothing would be watching the battery, and the app would be sitting on top
 * of a running drain it had no opinion about. So `start()` runs from
 * `registerLidAwakeIpc`, which runs from `registerIpc()`, which runs at launch.
 * `lid-awake.test.ts` asserts exactly that, because an assertion about a wiring
 * is the only kind that survives a refactor.
 */
export class LidAwakeController {
  private readonly run: CommandRunner
  private readonly platform: NodeJS.Platform
  private readonly power: PowerApi
  private readonly broadcast: (channel: string, payload: unknown) => void
  private readonly schedule: (callback: () => void, everyMs: number) => { cancel(): void }

  private blockerId: number | null = null
  private battery: { cancel(): void } | null = null
  private unsubscribePower: (() => void) | null = null

  /** Set once, from the first read after launch. Never written again. */
  private preexisting = false
  private warned = false
  private last: LidAwakeState | null = null

  constructor(options: ControllerOptions = {}) {
    this.run = options.run ?? runCommand
    this.platform = options.platform ?? process.platform
    this.power = options.power ?? electronPowerApi
    this.broadcast = options.broadcast ?? (() => {})
    this.schedule =
      options.schedule ??
      ((callback, everyMs) => {
        const handle = setInterval(callback, everyMs)
        // Otherwise this alone is enough to keep the Node event loop — and, on
        // some platforms, the process — from ever being idle.
        handle.unref?.()
        return { cancel: () => clearInterval(handle) }
      })
  }

  /** The last state read, or null before the first read has landed. */
  get state(): LidAwakeState | null {
    return this.last
  }

  /**
   * Read the truth, and make the app's own runtime agree with it.
   *
   * Called at launch and after every change. It never *sets* anything on the
   * system — the only thing it changes is what this process holds, which is why
   * it is safe to run unprompted.
   */
  async refresh(options: { initial?: boolean } = {}): Promise<LidAwakeState> {
    const read = await readLidAwake({ run: this.run, platform: this.platform })
    if (options.initial) this.preexisting = read.known && read.on

    const hasLid = read.battery?.present !== false
    const held = read.known && read.on
    const state: LidAwakeState = {
      ...read,
      preexisting: this.preexisting,
      warning: held ? lowBatteryWarning(read.battery, hasLid) : null,
    }

    if (held) this.hold()
    else this.release()

    this.watchBattery(held && read.battery?.discharging === true)
    this.maybeWarn(state)

    this.last = state
    this.broadcast(LID_AWAKE_STATE, state)
    return state
  }

  /**
   * Take the idle-sleep blocker alongside the system setting.
   *
   * Belt and braces, and *not* what makes the lid work — that is the system
   * setting, and nothing in this method could substitute for it. It closes the
   * second door: a machine whose lid is held open can still be sent to sleep by
   * an idle timer, and a user who asked to keep working through a closed lid did
   * not mean "unless you go to lunch".
   */
  private hold(): void {
    if (this.blockerId !== null) return
    this.blockerId = this.power.startBlocker()
  }

  private release(): void {
    if (this.blockerId === null) return
    this.power.stopBlocker(this.blockerId)
    this.blockerId = null
  }

  private watchBattery(wanted: boolean): void {
    // No level to read on Windows, so no timer to arm — the mains/battery event
    // carries everything that platform can tell us.
    const applicable = wanted && this.platform === 'darwin'
    if (applicable === (this.battery !== null)) return
    if (!applicable) {
      this.battery?.cancel()
      this.battery = null
      return
    }
    this.battery = this.schedule(() => void this.refresh(), BATTERY_POLL_MS)
  }

  /**
   * One notification per discharge, not one per read.
   *
   * The flag resets when the machine is charging again, so unplugging a second
   * time warns a second time — but a laptop that sits at 12% for an hour is
   * interrupted once. An alert that repeats is an alert that gets dismissed
   * without being read.
   */
  private maybeWarn(state: LidAwakeState): void {
    const urgent =
      state.warning !== null &&
      state.battery?.discharging === true &&
      (state.battery.percent === null || state.battery.percent <= LOW_BATTERY_PERCENT)

    if (!urgent) {
      if (state.battery?.discharging !== true) this.warned = false
      return
    }
    if (this.warned) return
    this.warned = true
    this.power.notify('This machine is being kept awake', state.warning ?? '')
  }

  /** Attach at launch. Safe to call once; a second call is ignored. */
  start(): void {
    if (this.unsubscribePower !== null) return
    // A real event, and the only one either platform offers for free: the
    // moment the plug comes out is exactly when a held-open lid starts costing
    // something, so it is worth a re-read rather than waiting for a tick.
    this.unsubscribePower = this.power.onPowerSourceChange(() => void this.refresh())
    void this.refresh({ initial: true })
  }

  /**
   * Let go of everything this process holds.
   *
   * It does **not** turn the system setting off, and that is a decision rather
   * than an omission. On macOS it could not do so without putting a password
   * dialog on screen during quit, which is a dialog nobody can answer; and
   * reverting a system-wide setting behind the user's back at quit is its own
   * surprise. Doing it on Windows only — where it is free — would leave the two
   * platforms disagreeing about what the switch means. So the setting outlives
   * the app on purpose, the settings pane says so in as many words, and the
   * state is read back from the OS at the next launch so it can never become
   * invisible.
   */
  stop(): void {
    this.release()
    this.battery?.cancel()
    this.battery = null
    this.unsubscribePower?.()
    this.unsubscribePower = null
  }

  async set(on: unknown): Promise<LidAwakeResult> {
    const result = await setLidAwake(on === true, { run: this.run, platform: this.platform })
    // The switch reports what the OS says, not what was asked for — so the
    // controller's own view is refreshed from a fresh read rather than from the
    // result it just built.
    const state = await this.refresh()
    return { ...result, state }
  }
}

/* ------------------------------------------------------------------- ipc -- */

/**
 * The half of `IpcMain` this module uses.
 *
 * Narrowed on purpose. Every other `register*Ipc` here takes the whole
 * `IpcMain`, which forces its test to build a fake and then cast it back — and
 * a cast in a test is a cast, with the same ability to hide a signature that
 * has quietly changed. Two request channels need exactly one method, so that is
 * what the parameter asks for, and the real `IpcMain` satisfies it without
 * anyone saying so.
 */
export type IpcHandlers = Pick<IpcMain, 'handle'>

export function registerLidAwakeIpc(
  ipcMain: IpcHandlers,
  options: ControllerOptions = {},
): LidAwakeController {
  const controller = new LidAwakeController(options)

  ipcMain.handle(LID_AWAKE_GET, () => controller.refresh())
  ipcMain.handle(LID_AWAKE_SET, (_event: IpcMainInvokeEvent, on: unknown) => controller.set(on))

  // At launch, not on first use. See the class comment.
  controller.start()
  return controller
}
