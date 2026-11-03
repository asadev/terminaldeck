/**
 * The button that was missing, and the whole reason Windows shipped unconfined.
 *
 * ## What this closes
 *
 * Everything needed to hold a Windows session inside its folder was built and
 * measured against real Windows 11 hardware: the launcher (`native/win-confine`),
 * the ACL grant, `plannedToolGrant`, `establishToolGrant`, `withdrawToolGrant`,
 * the record on disk, and the per-session probe. `CONFINEMENT.md` said what was
 * left in four words — **"What is missing is the button."**
 *
 * Nothing in the shipped UI called `establishToolGrant`, so
 * `windowsConfinementReady()` answered false on every Windows machine forever,
 * `confinementKind('win32')` answered `'none'`, and a session started from a
 * paired phone ran as the full user account: able to read `~/.ssh`, the owner's
 * `.gitconfig` and every project on the disk. The identical session on macOS is
 * held by seatbelt to the one granted folder. There was even a test asserting
 * that nothing called it, whose message said *"That is the feature arriving,
 * not a regression."*
 *
 * This is the feature arriving.
 *
 * ## Three channels, and why it is three rather than one
 *
 * A permission change gets **described before it is performed**, which is the
 * rule `plannedToolGrant` was split out for: *"a screen that describes a
 * permission change by running it is not a screen anybody should ship."* So
 * `state` answers what the grant would cover and whether it has happened,
 * `grant` performs it, and `withdraw` undoes it. The panel renders the answer
 * rather than its own request, the same rule the folder and device channels
 * follow — nothing on that screen may claim an outcome it has not read back.
 *
 * ## It is registered on every platform, and answers honestly on each
 *
 * Not `if (process.platform === 'win32')` around the registration. A channel
 * that exists on one platform and is missing on another gives the window two
 * different failures to tell apart — "this build is too old" and "this is a
 * Mac" — when only one of them is true and neither is interesting. It registers
 * everywhere and `state` says which machine this is, which is the same shape
 * `remote:copilot` uses for a host with no copilot.
 *
 * macOS needs no grant at all: seatbelt confines a process with no prior
 * permission from anybody, which is exactly why the Windows half needed a
 * button and the macOS half never has. Linux needs no grant either, for a
 * different reason — an unprivileged user namespace is something the kernel
 * hands out to an ordinary account — but unlike seatbelt it can be switched off
 * by the machine's owner, so {@link ConfineState.confining} asks the two
 * switches rather than asserting the platform. See `linux.ts`'s
 * {@link usernsRefusal}.
 */

import type { InvokeRegistrar } from '../ipc-seam'
import { currentPlatform, type Platform } from '../platform/host'
import {
  establishToolGrant,
  plannedToolGrant,
  windowsConfinementReady,
  windowsToolsInstall,
  withdrawToolGrant,
  type GrantResult,
} from './tools'
import { WINDOWS_GRANT_NOTE } from './appcontainer'
import { readUsernsSwitches, usernsRefusal } from './linux'

/** What a screen needs in order to describe the grant before anybody presses. */
export interface ConfineState {
  /** Which machine this is, so the window does not have to guess from a UA. */
  platform: Platform
  /**
   * Whether sessions started from a device are held inside their folder *now*.
   *
   * On macOS this is true with nothing granted — seatbelt needs no permission.
   * On Windows it is the record on disk, which is what the one-time grant
   * writes. On Linux it is the two kernel switches, read from this machine:
   * nothing has to be granted, but a kernel with unprivileged user namespaces
   * switched off will refuse every session, and answering `true` there would be
   * this panel promising a boundary the first session is about to fail to build.
   */
  confining: boolean
  /**
   * Whether this machine could be asked. False on a Windows build with no
   * launcher — a development checkout before `build.ps1` has run — where a
   * button would be a control that cannot act.
   */
  canGrant: boolean
  /** The folders the grant would cover, so the prompt can name them. */
  folders: readonly string[]
  /**
   * The one thing about this machine's boundary a person would not guess.
   *
   * On Windows, what the one-time grant actually covers. On Linux, why the
   * kernel is refusing, when it is — because {@link confining} answering `false`
   * with nothing beside it is the same shape of failure this subsystem keeps
   * paying for: the side that knows the reason not being the side that reports
   * it. Empty when there is nothing a reader would not already know.
   */
  note: string
}

export interface ConfineIpcDeps {
  /** `PATH`, for finding the folders that hold node, git and the agent CLIs. */
  path(): string
  /** This account's home directory. */
  accountHome(): string
  platform?: Platform
  /** Injected so the tests never elevate anything. */
  establish?: typeof establishToolGrant
  withdraw?: typeof withdrawToolGrant
  ready?: typeof windowsConfinementReady
  /**
   * Why this kernel would refuse every session, or `null`.
   *
   * Injected for the reason the three above are, and for one more: the files it
   * reads are `/proc/sys/kernel/*`, which do not exist on the machine this app
   * is built and tested on, so the Linux branch would otherwise have exactly one
   * observable behaviour here — the one a Mac produces by having no `/proc` at
   * all, which is the *passing* answer. A branch whose failing half cannot be
   * reached from the test suite is a branch whose first user finds the bug.
   */
  userns?: () => string | null
}

export const CONFINE_STATE = 'confine:state'
export const CONFINE_GRANT = 'confine:grant'
export const CONFINE_WITHDRAW = 'confine:withdraw'

export function registerConfineIpc(ipcMain: InvokeRegistrar, deps: ConfineIpcDeps): void {
  const platform = deps.platform ?? currentPlatform()
  const ready = deps.ready ?? windowsConfinementReady
  const establish = deps.establish ?? establishToolGrant
  const withdraw = deps.withdraw ?? withdrawToolGrant
  const userns = deps.userns ?? ((): string | null => usernsRefusal(readUsernsSwitches()))

  /**
   * What the grant would cover, asked without performing anything.
   *
   * Wrapped in a `try` because it reads the machine — `PATH` is split, every
   * candidate directory is stat'd — and a throw here would land in a settings
   * screen as a blank pane rather than as a sentence. An empty list is a real
   * answer and the panel says so: nothing on this machine's `PATH` holds the
   * tools, so there is nothing to grant and no prompt worth showing.
   */
  const planned = (): readonly string[] => {
    if (platform !== 'win32') return []
    try {
      return plannedToolGrant({ path: deps.path(), accountHome: deps.accountHome() }).read
    } catch {
      return []
    }
  }

  /*
   * Linux was excluded from this line, and it had stopped being true.
   *
   * `confinementKind` answers `'namespace'` for linux and `confineSpawn` wraps
   * every session from a device in one — measured on a real rented Linux box,
   * not read; `linux.ts` carries the table — while this function still said the
   * same `false` it says for a platform with no mechanism at all. That is the *safe* direction
   * of the two, which is why it survived, and it is still a wrong answer: a
   * panel that says nothing holds a session is how somebody decides not to hand
   * out a folder they could safely have handed out, and worse, it is the line a
   * later reader trusts instead of the module that does the work.
   *
   * It is a read of the machine rather than `platform === 'linux'`, because
   * unlike seatbelt this mechanism can be switched off from outside the app —
   * see `linux.ts`. `null` there is "neither switch is in the way", which is not
   * a promise that the session will start; the per-session proof is still what
   * decides, and it still refuses rather than downgrading.
   */
  const state = (): ConfineState => {
    // Asked once per answer rather than once per field it decides. The two
    // fields below are one statement about this machine — *is it holding
    // sessions, and if not what is in the way* — and reading the switches twice
    // is how a state eventually goes out saying "not held" with nothing beside
    // it, or the reverse.
    const blocked = platform === 'linux' ? userns() : null
    return {
      platform,
      // macOS confines with no grant; Linux with no grant but not on every
      // kernel; Windows only once the record exists.
      confining:
        platform === 'darwin' ||
        (platform === 'linux' && blocked === null) ||
        (platform === 'win32' && ready()),
      canGrant: platform === 'win32' && windowsToolsInstall() !== null,
      folders: planned(),
      note: platform === 'win32' ? WINDOWS_GRANT_NOTE : (blocked ?? ''),
    }
  }

  ipcMain.handle(CONFINE_STATE, (): ConfineState => state())

  /**
   * Perform the one-time grant, and answer with the state that followed it.
   *
   * Both halves, in that order, because the panel must not draw "held" off the
   * press: `establishToolGrant` elevates, and a person can dismiss the UAC
   * prompt. `ran.prompted` distinguishes *they said no* from *it could not
   * ask*, which are two different sentences with two different remedies, and
   * the state read afterwards is what the screen renders.
   */
  ipcMain.handle(CONFINE_GRANT, async (): Promise<{ result: GrantResult | null; state: ConfineState }> => {
    if (platform !== 'win32') return { result: null, state: state() }
    const result = await establish({ path: deps.path(), accountHome: deps.accountHome() })
    return { result, state: state() }
  })

  ipcMain.handle(CONFINE_WITHDRAW, async (): Promise<{ ok: boolean; detail: string; state: ConfineState }> => {
    if (platform !== 'win32') return { ok: true, detail: '', state: state() }
    const done = await withdraw({})
    return { ...done, state: state() }
  })
}
