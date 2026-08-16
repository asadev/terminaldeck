/**
 * The one-time grant: the part of Windows confinement that needs an
 * administrator, asked for once instead of once per session.
 *
 * ## Why there has to be one at all
 *
 * A confined Windows session is an AppContainer, and an AppContainer reaches a
 * file only through an ACE naming a SID it carries. Three of the things every
 * session needs are on directories the person running Terminal Deck **cannot
 * rewrite the permissions of**, which is not a guess — it is `AccessCheck`
 * asked for `WRITE_DAC` with a real non-elevated token (medium integrity,
 * Administrators deny-only) on `DESKTOP-DDGMNCV`:
 *
 *     C:\                      NO       C:\Users\<user>      YES
 *     C:\Users                 NO       C:\Program Files     NO
 *
 * `C:\` and `C:\Users` are on the path to every granted folder under a user
 * profile, and without list access on them a confined session cannot resolve an
 * absolute path at all: `cmd` answers `Access is denied` for a command given by
 * full path — measured, with the same command working the moment the two ACEs
 * are there — and git dies at `unable to get current working directory`.
 * `C:\Program Files` is where `node` and `git` are.
 *
 * So a session that ACL'd its own way in would need an administrator **every
 * time it started**. That was rejected on sight, and rightly: a permission
 * prompt per session is not a security feature anybody keeps switched on, and
 * the ACL sweep it implies had already perturbed the inheritance flag on
 * `C:\Program Files\nodejs` once.
 *
 * ## What makes a one-time grant possible: the trustee is not the container
 *
 * The per-session ACEs name a **container SID**, one per device, which comes and
 * goes with the session. A one-time grant cannot name any of those — a device
 * paired next month would not be covered.
 *
 * It names a **capability SID** instead. A capability SID is derived from a name
 * by a documented, deterministic hash, so it is the same value on every machine
 * and after every reinstall, and — this is the part that makes it work — a
 * process created in an AppContainer can be handed that capability at creation
 * time, whereupon an ACE naming it applies. Measured on the real machine, with
 * one directory granted read+execute to the capability SID and nothing else
 * changed:
 *
 *     capability in the token, ACE present   → the file is read, the image runs
 *     capability absent,       ACE present   → Access is denied
 *     capability in the token, no ACE        → Access is denied
 *
 * `DeriveCapabilitySidsFromName` on Windows and {@link capabilitySid} here
 * answer the same string, byte for byte; the test pins the value that machine
 * produced so a change to the derivation cannot pass unnoticed.
 *
 * ## Why a capability rather than ALL APPLICATION PACKAGES
 *
 * `ALL APPLICATION PACKAGES` (`S-1-15-2-1`) would also work, and is what Windows
 * itself uses to make `System32` reachable from a sandbox. It was rejected
 * because it is *every* AppContainer on the machine: granting it read on the npm
 * prefix — which lives inside the user's own home directory — would hand every
 * store app on the machine a directory it has no business in. A capability SID
 * derived from a name only this app uses is reachable by a process that asks for
 * that capability by name, which in practice is this launcher and nothing else.
 * The difference costs nothing and narrows the grant from "every sandbox on this
 * PC" to "sessions this app starts".
 *
 * ## The record is not the truth, and must never be treated as it
 *
 * {@link readGrantRecord} says what was granted and when. It is a note about a
 * past action, not a measurement of the present: the ACEs can be removed by
 * hand, by a repair install, or by a tool that rewrites a directory's
 * permissions, and nothing tells this app about it. So the record decides
 * whether to *offer* the elevation and whether a plan's ancestors are already
 * covered — and the per-session probe in `appcontainer.ts` is what decides
 * whether a session may claim to be confined. If those two ever disagree, the
 * probe wins, because the probe ran on this machine a moment ago.
 */

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, win32 } from 'node:path'
import { ancestorsOf, LAUNCHER_NAME as LAUNCHER } from './appcontainer'
import { within } from './plan'

/* ------------------------------------------------------------ the capability -- */

/**
 * The name the tool capability is derived from.
 *
 * Fixed, and never generated per install: the whole point is that an ACE written
 * by one version of this app is honoured by the next one, and by a reinstall.
 * ASCII only, because Windows derives the SID from the name uppercased with the
 * invariant culture and `String.prototype.toUpperCase` is not that function for
 * every alphabet — for ASCII the two agree, which the test states as an
 * assertion rather than leaving as a hope.
 */
export const TOOLS_CAPABILITY = 'terminaldeck-confined-tools'

/**
 * The capability SID for a name, computed the way Windows computes it.
 *
 * SHA-256 of the name uppercased, encoded UTF-16LE; the digest read as eight
 * little-endian 32-bit numbers; those as the sub-authorities after
 * `S-1-15-3-1024`. This is not reverse-engineering for its own sake — the same
 * value has to be written into an ACL by an elevated run of the launcher and put
 * into a token by an unprivileged one, and a value the app cannot compute would
 * have to be passed between them through something that can be lost.
 *
 * Checked against `DeriveCapabilitySidsFromName` on Windows 11 26200: identical.
 */
export function capabilitySid(name: string = TOOLS_CAPABILITY): string {
  const digest = createHash('sha256').update(Buffer.from(name.toUpperCase(), 'utf16le')).digest()
  const parts: number[] = []
  for (let index = 0; index < 8; index++) parts.push(digest.readUInt32LE(index * 4))
  return `S-1-15-3-1024-${parts.join('-')}`
}

/* -------------------------------------------------------------- the tool set -- */

/**
 * The executables a confined Windows session has to be able to start.
 *
 * `node` first because it is the one that is not optional: on Windows every
 * session — including one running an agent rather than a shell — is
 * `cmd.exe /c <cli>`, `providers.ts` says so, and every agent CLI installed by
 * npm is a `.cmd` shim whose first act is to run `node.exe`. A session without
 * node is not a session with fewer tools, it is a tab that dies.
 *
 * `git` because a coding session without it is not one, and because git is the
 * tool that forced the ancestor rule in the first place.
 *
 * The agent CLIs by their own names, resolved through the same extension list
 * `cmd` uses, so the directory holding the shim is granted whether it came from
 * npm, from a winget install, or from somewhere else entirely.
 *
 * What is deliberately *not* here: everything else on the `PATH`. A confined
 * session's `PATH` on a real machine names eighteen directories — the JDK,
 * dotnet, two NVIDIA directories, VS Code, GitHub Desktop — and granting all of
 * them would be a permanent, machine-wide permission change over hundreds of
 * thousands of files to make `java` work inside a sandbox nobody asked to run
 * java in. The grant is the tools this app needs to do the job the session was
 * started for; anything else is a directory the session cannot read, which is
 * what a boundary is.
 */
export const WINDOWS_TOOLS: readonly string[] = ['node', 'git', 'claude', 'codex', 'gemini']

/** The extensions `cmd` will try for a bare name, in the order it tries them. */
const EXTENSIONS: readonly string[] = ['.exe', '.cmd', '.bat']

/** How {@link windowsToolDirs} asks the filesystem. Injected so tests need none. */
export interface ToolLookup {
  exists(path: string): boolean
}

const realLookup: ToolLookup = { exists: (path) => existsSync(path) }

/**
 * The directories holding the tools, found on the session's own `PATH`.
 *
 * The first hit wins, exactly as `cmd` resolves it, so a tool installed twice is
 * granted where it will actually be run from rather than everywhere it exists.
 *
 * Anything inside the Windows directory is dropped, and that is a measurement
 * rather than an optimisation: `System32` already carries an `ALL APPLICATION
 * PACKAGES` ACE that Windows puts there for store apps, and a confined session
 * runs `cmd.exe`, `whoami.exe` and the rest from it with no grant of ours at
 * all. Granting it again would be a permanent ACL change over the operating
 * system to buy nothing.
 */
export function windowsToolDirs(input: {
  path: string
  tools?: readonly string[]
  systemRoot?: string
  lookup?: ToolLookup
}): string[] {
  const lookup = input.lookup ?? realLookup
  const systemRoot = input.systemRoot ?? 'C:\\Windows'
  const entries = input.path
    .split(';')
    .map((entry) => entry.trim())
    .filter((entry) => entry !== '' && /^[A-Za-z]:[\\/]/.test(entry))
    .map((entry) => win32.normalize(entry).replace(/[\\/]+$/, ''))

  const found: string[] = []
  const seen = new Set<string>()
  for (const tool of input.tools ?? WINDOWS_TOOLS) {
    for (const entry of entries) {
      if (within(entry, systemRoot, 'win32')) continue
      const hit = EXTENSIONS.some((extension) => lookup.exists(win32.join(entry, tool + extension)))
      if (!hit) continue
      const key = entry.toLowerCase()
      if (!seen.has(key)) {
        seen.add(key)
        found.push(entry)
      }
      break
    }
  }
  return found
}

/**
 * An executable inside the granted directories for the per-session probe to
 * start from *inside* the container, or `null` if the grant names none.
 *
 * `node` first and `git` second, because those are the two the probe can run
 * with `-v` and because node is the one every Windows session needs. This is
 * not "check the grant is intact" theatre: without the ACEs, the measured
 * failure is `'node' is not recognized as an internal or external command`,
 * printed by a shell that started perfectly well inside a boundary that held.
 * A proof that only tested the boundary would call that session confined, and
 * it would be right, and the session would be useless.
 */
export function toolProbe(read: readonly string[], lookup: ToolLookup = realLookup): string | null {
  for (const tool of ['node.exe', 'git.exe']) {
    for (const dir of read) {
      const candidate = win32.join(dir, tool)
      if (lookup.exists(candidate)) return candidate
    }
  }
  return null
}

/* ------------------------------------------------------------------ the grant -- */

/** What the one-time grant puts on the machine, as two lists of directories. */
export interface ToolGrant {
  /** Read and execute, inherited downwards. The tool directories themselves. */
  readonly read: readonly string[]
  /** List and traverse, not inherited. Everything on the way to them. */
  readonly ancestors: readonly string[]
}

/**
 * Directories no grant of this app's may ever name.
 *
 * `C:\Program Files` is here because of what it *is*, not because of what it
 * costs: its owner is `NT SERVICE\TrustedInstaller` and its DACL gives even a
 * full administrator no `WRITE_DAC` — measured, the launcher answered
 * `0x00000005` from an elevated shell. Granting it would mean taking ownership
 * of `Program Files`, which is a change to the machine that no terminal
 * emulator is entitled to make. It stays off the list, and the measurement
 * below is why that is survivable: a confined session runs
 * `C:\Program Files\nodejs\node.exe` **without** list access on
 * `C:\Program Files`, because the ACE on the tool directory itself is what the
 * open needs and traverse is covered by the `SeChangeNotifyPrivilege` every
 * token has.
 *
 * `C:\Windows` and its children are here for the reason `windowsToolDirs`
 * gives: already reachable, and not ours to change.
 */
const UNWRITABLE: readonly string[] = ['C:\\Program Files', 'C:\\Program Files (x86)']

/**
 * Directories that are already reachable from inside a container, with
 * everything under them.
 *
 * Measured rather than assumed: a confined session runs `cmd.exe`, `whoami.exe`
 * and `where.exe` out of `System32` with no grant of this app's at all, because
 * Windows puts an `ALL APPLICATION PACKAGES` ACE there itself for store apps.
 * Granting it again would rewrite the operating system's permissions to buy
 * nothing.
 */
const ALREADY_REACHABLE: readonly string[] = ['C:\\Windows']

/**
 * Is this a directory the grant must not name?
 *
 * The two lists are compared differently, and the difference is the bug this
 * function had when it was one list: `C:\Program Files` cannot be written, but
 * `C:\Program Files\nodejs` **can** and is exactly what has to be granted — the
 * installer that put node there left an ACL an administrator can edit. So the
 * unwritable list matches the directory itself and not its children, while the
 * already-reachable list matches everything underneath.
 */
function forbidden(path: string): boolean {
  const canonical = path.toLowerCase().replace(/[\\/]+$/, '')
  if (UNWRITABLE.some((root) => root.toLowerCase() === canonical)) return true
  return ALREADY_REACHABLE.some((root) => within(path, root, 'win32'))
}

/**
 * The full one-time grant for this machine.
 *
 * The tool directories get read and execute. Everything on the way down to them
 * — and on the way down to the account's home directory, which is where granted
 * folders and the app's own per-device homes live — gets list and traverse, and
 * only that.
 *
 * The account home is in the ancestor list on purpose and it is the single most
 * important line in this file to understand before changing it. A confined
 * session can list the *names* of the entries in the user's home directory. It
 * cannot open any of them. That is not a convenience: with traverse-only, every
 * git command dies, because git-for-windows resolves its own working directory
 * with `GetLongPathNameW`, which enumerates each component. `CONFINEMENT.md`
 * carries the full measurement, including why git's own fallback cannot work
 * inside an AppContainer either.
 */
export function toolGrant(input: {
  dirs: readonly string[]
  accountHome: string
  /**
   * Granted folders whose ancestor chains also have to be covered.
   *
   * Absent for the common case, where every granted folder is under the
   * account's home and the chain down to it is already in the list. It matters
   * for a folder on a second drive: `D:\` is a drive root, an unprivileged
   * process cannot write its ACL, and without this the session would be refused
   * by the launcher with `could not grant D:\ (0x00000005)` — correct, and
   * unhelpful. Passing the folder here puts `D:\` in the prompt instead.
   */
  folders?: readonly string[]
}): ToolGrant {
  const read: string[] = []
  const readSeen = new Set<string>()
  for (const dir of input.dirs) {
    if (forbidden(dir)) continue
    const key = dir.toLowerCase()
    if (readSeen.has(key)) continue
    readSeen.add(key)
    read.push(dir)
  }

  /*
   * Whose chains have to be listable, and whose directory itself does.
   *
   * The tool directories and the granted folders contribute their *ancestors*
   * only — a granted folder's own ACE is per-session and per-device, and putting
   * it here would hand every device a permanent grant on one device's folder.
   * The account home contributes its ancestors **and itself**, because it is the
   * directory every granted folder sits under and a session that cannot list it
   * cannot resolve a path through it. That is the one entry in this list that a
   * reader should stop at, and `CONFINEMENT.md` states its cost: a confined
   * session can see the names of the entries in the owner's home directory,
   * though it can open none of them.
   */
  const ancestors: string[] = []
  const seen = new Set<string>()
  const chains = [
    ...read.map((dir) => ancestorsOf(dir)),
    [...ancestorsOf(input.accountHome), input.accountHome],
    ...(input.folders ?? []).map((folder) => ancestorsOf(folder)),
  ]
  for (const chain of chains) {
    for (const ancestor of chain) {
      const key = ancestor.toLowerCase()
      if (seen.has(key)) continue
      seen.add(key)
      if (forbidden(ancestor)) continue
      // An ancestor that is itself inside a directory being granted read and
      // execute needs no second, weaker ACE: two ACEs for one SID on one path is
      // two things to withdraw and one more way for the undo to be half done.
      if (read.some((root) => within(ancestor, root, 'win32'))) continue
      ancestors.push(ancestor)
    }
  }
  return { read, ancestors }
}

/** The launcher arguments that write the grant. Elevated. */
export function establishArgs(grant: ToolGrant, sid: string = capabilitySid()): string[] {
  return ['--establish', '--capability-sid', sid, ...pathArgs(grant)]
}

/** The launcher arguments that take it away again. Elevated. */
export function withdrawArgs(grant: ToolGrant, sid: string = capabilitySid()): string[] {
  return ['--withdraw', '--capability-sid', sid, ...pathArgs(grant)]
}

function pathArgs(grant: ToolGrant): string[] {
  const argv: string[] = []
  for (const dir of grant.read) argv.push('--read', dir)
  for (const dir of grant.ancestors) argv.push('--ancestor', dir)
  return argv
}

/* -------------------------------------------------------------- the elevation -- */

/**
 * One argument, as a PowerShell single-quoted string.
 *
 * A directory called `C:\Users\O'Brien\Projects` is a real thing on a real
 * machine, and an unescaped one would end the string early and turn the rest of
 * a path into PowerShell code — inside a command line that is about to be run as
 * administrator. Doubling the quote is PowerShell's own escape and there is no
 * other metacharacter inside single quotes.
 */
function psLiteral(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

/**
 * The command that asks Windows for one administrator prompt and runs the grant.
 *
 * Through PowerShell's `Start-Process -Verb RunAs` because that is the only way
 * to reach `ShellExecuteEx(runas)` from Node: `child_process` starts a process
 * with the token it already has, so nothing it spawns can be elevated. The
 * prompt is Windows' own consent dialog naming this launcher.
 *
 * `-Wait -PassThru` and `exit $p.ExitCode` so the caller learns whether the
 * grant actually happened rather than only that a prompt appeared. A user who
 * declines the prompt makes `Start-Process` throw, which leaves PowerShell
 * exiting non-zero — declined and failed are the same answer here, and the
 * honest thing to report is that the grant was not made.
 */
export function elevatedGrantCommand(
  launcher: string,
  args: readonly string[],
): { command: string; args: string[] } {
  const list = args.map(psLiteral).join(',')
  return {
    command: 'powershell.exe',
    args: [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      `$p = Start-Process -FilePath ${psLiteral(launcher)} -ArgumentList ${list} ` +
        `-Verb RunAs -Wait -PassThru -WindowStyle Hidden; exit $p.ExitCode`,
    ],
  }
}

/* ---------------------------------------------------------------- doing it once -- */

/** How the grant is run. Injected so no test elevates anything. */
export interface ElevationRunner {
  (command: string, args: readonly string[]): Promise<{ code: number | null; stderr: string }>
}

const realElevation: ElevationRunner = async (command, args) => {
  const { execFile } = await import('node:child_process')
  return new Promise((resolve) => {
    execFile(
      command,
      [...args],
      { timeout: 300_000, windowsHide: true, encoding: 'utf8' },
      (error, _stdout, stderr) => {
        const code = (error as { code?: unknown } | null)?.code
        resolve({
          code: error === null ? 0 : typeof code === 'number' ? code : null,
          stderr: typeof stderr === 'string' ? stderr : '',
        })
      },
    )
  })
}

/**
 * What the grant would cover on this machine, without doing anything.
 *
 * Separate from {@link establishToolGrant} because the prompt has to be able to
 * say what it is about *before* anybody clicks, and because a screen that
 * describes a permission change by running it is not a screen anybody should
 * ship.
 */
export function plannedToolGrant(input: {
  path: string
  accountHome: string
  folders?: readonly string[]
  lookup?: ToolLookup
}): ToolGrant {
  return toolGrant({
    dirs: windowsToolDirs({ path: input.path, ...(input.lookup ? { lookup: input.lookup } : {}) }),
    accountHome: input.accountHome,
    ...(input.folders ? { folders: input.folders } : {}),
  })
}

export interface GrantResult {
  ok: boolean
  /** What went wrong. Empty when it worked. */
  detail: string
  /** What the machine is meant to have once this returns. */
  grant: ToolGrant
  /** Whether this call actually asked for the administrator prompt. */
  prompted: boolean
}

/**
 * Do the one-time grant, once, with one prompt — or find that there is nothing
 * to do.
 *
 * The whole shape of this function is the rule it exists to keep: **never a
 * silent elevation, never a per-session one.** It is called by something the
 * person clicked, it asks Windows for consent exactly once, and it writes the
 * record only if the launcher exited zero. There is no retry loop, because a
 * loop around a consent dialog is how a prompt becomes a nuisance somebody
 * clicks through without reading.
 *
 * Re-granting what is already granted is deliberate rather than wasteful.
 * `SetEntriesInAclW` merges, so a second run is idempotent, and running the full
 * grant rather than only the shortfall is what repairs a machine where an ACE
 * was removed behind the app's back — which the record cannot detect and the
 * per-session probe can only report.
 */
export async function establishToolGrant(input: {
  path: string
  accountHome: string
  folders?: readonly string[]
  install?: WindowsToolsInstall | null
  lookup?: ToolLookup
  run?: ElevationRunner
  now?: () => Date
}): Promise<GrantResult> {
  const grant = plannedToolGrant(input)
  const install = input.install ?? installed
  if (install === null) {
    return { ok: false, detail: 'the app has not said where the launcher is', grant, prompted: false }
  }
  if (grant.read.length === 0) {
    // Nothing on the PATH holds node, git or an agent CLI. Granting the
    // ancestors alone would be a permission change that buys nothing, and a
    // prompt for it would be a prompt nobody can act on.
    return {
      ok: false,
      detail: 'none of the folders on this machine hold node, git or an agent CLI',
      grant,
      prompted: false,
    }
  }
  const run = input.run ?? realElevation
  const elevated = elevatedGrantCommand(install.launcher, establishArgs(grant))
  const ran = await run(elevated.command, elevated.args)
  if (ran.code !== 0) {
    return {
      ok: false,
      // The two cases that reach here are "the prompt was declined" and "a
      // directory could not be granted", and they are not worth guessing
      // between: `Start-Process` throws for the first and the launcher prints a
      // `tdconfine:` line for the second, so whatever came back is the more
      // specific of the two.
      detail: firstLine(ran.stderr) ?? 'the permission was not granted',
      grant,
      prompted: true,
    }
  }
  writeGrantRecord(install.recordFile, {
    capability: capabilitySid(),
    read: grant.read,
    ancestors: grant.ancestors,
    established: (input.now ?? (() => new Date()))().toISOString(),
  })
  return { ok: true, detail: '', grant, prompted: true }
}

/**
 * Take it back.
 *
 * Every permission this app can add to somebody's machine has to be removable
 * from inside it, or the honest thing to tell them would be "run `icacls`". It
 * withdraws exactly what the record says was granted rather than what this
 * machine would need today — the tools may have moved since, and the ACEs that
 * have to come off are the ones that went on.
 */
export async function withdrawToolGrant(input: {
  install?: WindowsToolsInstall | null
  run?: ElevationRunner
}): Promise<{ ok: boolean; detail: string }> {
  const install = input.install ?? installed
  if (install === null) return { ok: false, detail: 'the app has not said where the launcher is' }
  const record = readGrantRecord(install.recordFile)
  if (record === null) return { ok: true, detail: '' }
  const run = input.run ?? realElevation
  const elevated = elevatedGrantCommand(
    install.launcher,
    withdrawArgs({ read: record.read, ancestors: record.ancestors }, record.capability),
  )
  const ran = await run(elevated.command, elevated.args)
  if (ran.code !== 0) {
    return { ok: false, detail: firstLine(ran.stderr) ?? 'the permission was not removed' }
  }
  // Only after the ACEs are gone. A record removed first would leave a machine
  // carrying a permission that nothing in the app knows how to withdraw.
  rmSync(install.recordFile, { force: true })
  return { ok: true, detail: '' }
}

function firstLine(text: string): string | null {
  const line = text
    .split('\n')
    .map((entry) => entry.trim())
    .find((entry) => entry !== '')
  return line ?? null
}

/* ----------------------------------------------------------------- the record -- */

export interface ToolGrantRecord {
  /** The capability the ACEs name. Recorded so a changed name is visible. */
  capability: string
  /** Directories granted read and execute. */
  read: readonly string[]
  /** Directories granted list and traverse. */
  ancestors: readonly string[]
  /** When, ISO 8601. For the settings row that has to say something truthful. */
  established: string
}

/**
 * The record, or `null` when there is not one this app can believe.
 *
 * A file that cannot be parsed is treated as an absent grant rather than as an
 * error. The consequence of getting that wrong in the other direction is a
 * session claiming a boundary on the strength of a corrupt file, and the
 * consequence of getting it wrong this way is one extra administrator prompt.
 */
export function readGrantRecord(file: string): ToolGrantRecord | null {
  let text: string
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    return null
  }
  try {
    const parsed: unknown = JSON.parse(text)
    if (typeof parsed !== 'object' || parsed === null) return null
    const record = parsed as Partial<ToolGrantRecord>
    if (typeof record.capability !== 'string' || record.capability === '') return null
    if (!Array.isArray(record.read) || !Array.isArray(record.ancestors)) return null
    if (typeof record.established !== 'string') return null
    // A record naming a different capability is not this app's grant. The name
    // is fixed, so this can only be an older or newer build's, and honouring it
    // would mean skipping ancestors whose ACEs name a SID this session does not
    // carry — a session that starts and cannot resolve a path.
    if (record.capability !== capabilitySid()) return null
    return {
      capability: record.capability,
      read: record.read.filter((entry): entry is string => typeof entry === 'string'),
      ancestors: record.ancestors.filter((entry): entry is string => typeof entry === 'string'),
      established: record.established,
    }
  } catch {
    return null
  }
}

export function writeGrantRecord(file: string, record: ToolGrantRecord): void {
  mkdirSync(win32.dirname(file), { recursive: true })
  writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 })
}

/**
 * What this machine still needs granting, given what was already granted.
 *
 * Empty means the grant covers the plan. Anything else is what the elevation
 * prompt has to be about — and the caller shows it, because "Terminal Deck wants
 * to change permissions" with no list is a prompt nobody can consent to
 * meaningfully.
 */
export function grantShortfall(record: ToolGrantRecord | null, needed: ToolGrant): ToolGrant {
  const has = (list: readonly string[], path: string): boolean =>
    list.some((entry) => entry.toLowerCase() === path.toLowerCase())
  if (record === null) return needed
  return {
    read: needed.read.filter((dir) => !has(record.read, dir)),
    // An ancestor is covered by a stronger grant too: a directory granted read
    // and execute is listable by definition.
    ancestors: needed.ancestors.filter(
      (dir) => !has(record.ancestors, dir) && !has(record.read, dir),
    ),
  }
}

/** Is there nothing left to grant? */
export function grantIsComplete(record: ToolGrantRecord | null, needed: ToolGrant): boolean {
  const short = grantShortfall(record, needed)
  return short.read.length === 0 && short.ancestors.length === 0
}

/* ------------------------------------------------------------- what is installed -- */

/**
 * Where the launcher and the record are on this machine.
 *
 * Module state, set once at assembly, for the same reason `installDeviceHomes`
 * is: the answer comes from parts of the app this module has no business
 * knowing about — where Electron unpacked its resources, where the app keeps its
 * storage — and the alternative is threading two strings through every function
 * between `host-core.ts` and the decision that uses them.
 */
export interface WindowsToolsInstall {
  /** Absolute path to `tdconfine.exe`, wherever this build put it. */
  launcher: string
  /** Absolute path to the grant record, in the app's own storage. */
  recordFile: string
}

/** The record's filename inside the app's storage directory. */
export const GRANT_RECORD = 'windows-confinement.json'

/**
 * Where this build put the launcher and where this install keeps its record.
 *
 * Two candidates for the launcher, tried in order, because there are two real
 * situations and neither is the other's edge case. A packaged app has it beside
 * the asar, where `extraResources` puts it — it is an executable, and
 * `CreateProcess` cannot run a file that only exists inside an archive. A
 * development checkout has it wherever `native/win-confine/build.ps1` left it,
 * and a developer who cannot try the feature is a developer who will not notice
 * when it breaks.
 *
 * Neither existing is not an error. It answers with the resources path anyway,
 * and {@link windowsConfinementReady} finds no file there and answers `false`,
 * which is how a build that ships no launcher reports itself as unconfined
 * rather than refusing every session from a device.
 */
export function windowsToolsFor(
  storageDir: string,
  resourcesDir: string | null = defaultResourcesDir(),
  exists: (path: string) => boolean = existsSync,
): WindowsToolsInstall {
  // `join`, not `win32.join`, and it makes no difference where it matters: on
  // Windows they are the same function. On a Mac it is the difference between a
  // path a test can construct and one it has to spell.
  const candidates = [
    ...(resourcesDir === null ? [] : [join(resourcesDir, LAUNCHER)]),
    join(process.cwd(), 'native', 'win-confine', LAUNCHER),
  ]
  const found = candidates.find((candidate) => exists(candidate))
  return {
    launcher: found ?? candidates[0] ?? LAUNCHER,
    recordFile: join(storageDir, GRANT_RECORD),
  }
}

/**
 * `process.resourcesPath`, without pretending this is always Electron.
 *
 * The headless host runs the same `host-core.ts` under plain Node, where the
 * property does not exist at all, and the Electron type declarations say it is a
 * `string` — so reading it directly typechecks and is `undefined` at runtime on
 * the one path that has no Electron.
 */
function defaultResourcesDir(): string | null {
  const value = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath
  return typeof value === 'string' && value !== '' ? value : null
}

let installed: WindowsToolsInstall | null = null

export function installWindowsTools(install: WindowsToolsInstall): void {
  installed = install
}

/** For tests, which must not inherit one case's install into the next. */
export function resetWindowsTools(): void {
  installed = null
}

export function windowsToolsInstall(): WindowsToolsInstall | null {
  return installed
}

/**
 * Is this machine set up to confine a Windows session at all?
 *
 * Two questions, and both have to be asked of the disk rather than of a
 * constant. The launcher is an `extraResources` file that a development
 * checkout does not have until `build.ps1` has been run, so a build without it
 * must answer "not confined" rather than refuse every session from a device.
 * The record is what says the one-time grant happened.
 *
 * What this deliberately does not do is check the ACLs. It could not do it
 * honestly — reading a Windows DACL needs the native side — and the per-session
 * probe already asks the only question that matters, on the machine, a moment
 * before the session starts.
 */
export function windowsConfinementReady(exists: (path: string) => boolean = existsSync): boolean {
  const install = installed
  if (install === null) return false
  if (!exists(install.launcher)) return false
  return readGrantRecord(install.recordFile) !== null
}
