/**
 * The one-time grant, pinned from a Mac.
 *
 * The value that matters most here is a SID. It is computed rather than looked
 * up, because the same number has to be written into an ACL by an elevated run
 * of the launcher and put into a token by an unprivileged one, and the two must
 * agree — so the first test compares this implementation against the answer
 * Windows' own `DeriveCapabilitySidsFromName` gave on the machine everything
 * else here was measured on. Nothing else in this file can be right if that one
 * is wrong.
 */

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  GRANT_RECORD,
  TOOLS_CAPABILITY,
  capabilitySid,
  elevatedGrantCommand,
  establishToolGrant,
  establishArgs,
  grantIsComplete,
  grantShortfall,
  installWindowsTools,
  readGrantRecord,
  resetWindowsTools,
  toolGrant,
  toolProbe,
  windowsConfinementReady,
  windowsToolDirs,
  windowsToolsFor,
  withdrawArgs,
  withdrawToolGrant,
  writeGrantRecord,
  type ToolLookup,
} from './tools'

/**
 * The SID Windows itself derived for {@link TOOLS_CAPABILITY}, on
 * `DESKTOP-DDGMNCV`, Windows 11 Pro 26200, through
 * `DeriveCapabilitySidsFromName` by P/Invoke.
 *
 * Written down rather than recomputed, which is the whole point: a test that
 * derived the expected value the same way the implementation does would pass
 * for any derivation at all, including a wrong one.
 */
const MEASURED_SID =
  'S-1-15-3-1024-2903970903-3332091749-2496909251-2529716095-1516878088-2465616563-3028488617-2738278047'

/** A `ToolLookup` over a fixed set of paths, so no test touches a filesystem. */
function lookupOf(paths: readonly string[]): ToolLookup {
  const set = new Set(paths.map((path) => path.toLowerCase()))
  return { exists: (path) => set.has(path.toLowerCase()) }
}

const PATH_ON_THAT_MACHINE = [
  'C:\\Program Files\\Microsoft\\jdk-17.0.19.10-hotspot\\bin',
  'C:\\WINDOWS\\system32',
  'C:\\WINDOWS',
  'C:\\Program Files\\dotnet\\',
  'C:\\Program Files\\Git\\cmd',
  'C:\\Program Files\\nodejs\\',
  'C:\\Users\\Imza\\AppData\\Local\\Microsoft\\WindowsApps',
  'C:\\Users\\Imza\\AppData\\Roaming\\npm',
].join(';')

const INSTALLED = lookupOf([
  'C:\\Program Files\\nodejs\\node.exe',
  'C:\\Program Files\\Git\\cmd\\git.exe',
  'C:\\Users\\Imza\\AppData\\Roaming\\npm\\claude.cmd',
  'C:\\WINDOWS\\system32\\node.exe',
])

describe('capabilitySid', () => {
  it('answers exactly what Windows answered for the same name', () => {
    expect(capabilitySid(TOOLS_CAPABILITY)).toBe(MEASURED_SID)
  })

  it('is stable, because an ACE written last month has to still apply', () => {
    // The grant outlives the process that made it, the app version that made it
    // and any per-install state. A name that varied would mean every update
    // silently un-granting the machine.
    expect(capabilitySid(TOOLS_CAPABILITY)).toBe(capabilitySid(TOOLS_CAPABILITY))
    expect(capabilitySid('something-else')).not.toBe(capabilitySid(TOOLS_CAPABILITY))
  })

  it('uppercases the name, which is what the derivation is defined over', () => {
    expect(capabilitySid(TOOLS_CAPABILITY.toUpperCase())).toBe(capabilitySid(TOOLS_CAPABILITY))
  })

  it('keeps the name ASCII, so JavaScript and Windows uppercase it the same way', () => {
    // Windows uses the invariant culture and `toUpperCase` does not. For ASCII
    // the two agree; for a name with, say, a dotted i in it they would not, and
    // the app would compute a SID that no ACE on the machine names.
    expect(TOOLS_CAPABILITY).toMatch(/^[\x20-\x7e]+$/)
  })

  it('is a capability SID, which the launcher refuses to accept anything else as', () => {
    // `tdconfine` checks the same thing in C, because a SID that is not a
    // capability would land in the token as an enabled group and grant every ACE
    // on the machine that names it. This is the same fact asserted on the side
    // that produces the value.
    expect(capabilitySid()).toMatch(/^S-1-15-3-/)
  })
})

describe('windowsToolDirs', () => {
  const dirs = windowsToolDirs({ path: PATH_ON_THAT_MACHINE, lookup: INSTALLED })

  it('finds the directories that actually hold the tools', () => {
    expect(dirs).toEqual([
      'C:\\Program Files\\nodejs',
      'C:\\Program Files\\Git\\cmd',
      'C:\\Users\\Imza\\AppData\\Roaming\\npm',
    ])
  })

  it('leaves the rest of the PATH alone', () => {
    // The real PATH on that machine names eighteen directories: the JDK, dotnet,
    // two NVIDIA folders, VS Code, GitHub Desktop. Granting all of them would be
    // a permanent, machine-wide permission change over hundreds of thousands of
    // files so that a sandbox nobody asked to run java in could run java.
    expect(dirs).not.toContain('C:\\Program Files\\Microsoft\\jdk-17.0.19.10-hotspot\\bin')
    expect(dirs).not.toContain('C:\\Program Files\\dotnet')
  })

  it('never names anything inside the Windows directory', () => {
    // Measured: a confined session runs `cmd.exe` and `whoami.exe` out of
    // System32 with no grant at all, because Windows puts an ALL APPLICATION
    // PACKAGES ACE there itself for store apps. Granting it again would rewrite
    // the operating system's permissions to buy nothing.
    expect(dirs.some((dir) => dir.toLowerCase().startsWith('c:\\windows'))).toBe(false)
  })

  it('takes the first hit, the way cmd resolves a name', () => {
    const twice = windowsToolDirs({
      path: 'C:\\first;C:\\second',
      tools: ['node'],
      lookup: lookupOf(['C:\\first\\node.exe', 'C:\\second\\node.exe']),
    })
    expect(twice).toEqual(['C:\\first'])
  })

  it('drops a PATH entry that is not a drive-rooted path', () => {
    // A PATH on a real machine contains relative entries, empty entries and the
    // occasional `%SOMETHING%` that never got expanded. None of them is a
    // directory an ACL can be written on.
    const messy = windowsToolDirs({
      path: ';.;%NOPE%\\bin;C:\\Program Files\\nodejs',
      tools: ['node'],
      lookup: INSTALLED,
    })
    expect(messy).toEqual(['C:\\Program Files\\nodejs'])
  })
})

describe('toolGrant', () => {
  const grant = toolGrant({
    dirs: windowsToolDirs({ path: PATH_ON_THAT_MACHINE, lookup: INSTALLED }),
    accountHome: 'C:\\Users\\Imza',
  })

  it('grants read and execute on the tool directories and nothing else', () => {
    expect(grant.read).toEqual([
      'C:\\Program Files\\nodejs',
      'C:\\Program Files\\Git\\cmd',
      'C:\\Users\\Imza\\AppData\\Roaming\\npm',
    ])
  })

  it('covers the two ancestors an unprivileged process cannot write', () => {
    // The measurement this whole module exists for: AccessCheck for WRITE_DAC
    // with a real filtered token answered NO for both, and a confined session
    // that cannot list them cannot resolve an absolute path — `cmd` answers
    // `Access is denied` for a command given by full path.
    expect(grant.ancestors).toContain('C:\\')
    expect(grant.ancestors).toContain('C:\\Users')
  })

  it('covers the account home, which is where every granted folder lives', () => {
    expect(grant.ancestors).toContain('C:\\Users\\Imza')
  })

  it('never names Program Files, which nobody can write', () => {
    // Its owner is NT SERVICE\TrustedInstaller and an elevated run of the
    // launcher was refused with 0x00000005. It turns out not to be needed:
    // SeChangeNotifyPrivilege covers traverse, so the ACE on
    // `C:\Program Files\nodejs` itself is what the open needs — measured, a
    // confined session ran `node -v` with no ACE on `C:\Program Files` at all.
    expect(grant.ancestors).not.toContain('C:\\Program Files')
    expect(grant.read).not.toContain('C:\\Program Files')
  })

  it('never names the Windows directory either', () => {
    expect(grant.ancestors.some((dir) => dir.toLowerCase().startsWith('c:\\windows'))).toBe(false)
  })

  it('does not put a weaker ACE on something it already grants outright', () => {
    const nested = toolGrant({
      dirs: ['C:\\tools', 'C:\\tools\\bin'],
      accountHome: 'C:\\Users\\Imza',
    })
    expect(nested.ancestors).not.toContain('C:\\tools')
  })
})

describe('the launcher arguments', () => {
  const grant = toolGrant({ dirs: ['C:\\Program Files\\nodejs'], accountHome: 'C:\\Users\\Imza' })

  it('establish and withdraw name exactly the same paths', () => {
    // If they ever differed, the undo would leave the difference behind — a
    // permanent ACE for a capability nobody can see, on somebody's home
    // directory, with nothing left that knows it is there.
    const establish = establishArgs(grant).filter((arg) => !arg.startsWith('--establish'))
    const withdraw = withdrawArgs(grant).filter((arg) => !arg.startsWith('--withdraw'))
    expect(establish).toEqual(withdraw)
  })

  it('asks for read and list, never for write', () => {
    // The launcher refuses `--write` in this mode as well. A permanent ACE that
    // lets a container write somewhere is not a thing this feature creates.
    expect(establishArgs(grant)).not.toContain('--write')
  })

  it('carries the capability SID that the token will hold', () => {
    expect(establishArgs(grant)[establishArgs(grant).indexOf('--capability-sid') + 1]).toBe(
      capabilitySid(),
    )
  })
})

describe('elevatedGrantCommand', () => {
  it('goes through Start-Process -Verb RunAs, which is the only way to elevate', () => {
    // `child_process` starts a process with the token it already has, so nothing
    // it spawns can be elevated. This reaches ShellExecuteEx(runas), which is
    // what puts Windows' own consent dialog on screen.
    const command = elevatedGrantCommand('C:\\app\\tdconfine.exe', ['--establish'])
    expect(command.command).toBe('powershell.exe')
    expect(command.args.join(' ')).toContain('-Verb RunAs')
    expect(command.args.join(' ')).toContain('-Wait')
  })

  it('reports the exit code rather than only that a prompt appeared', () => {
    const command = elevatedGrantCommand('C:\\app\\tdconfine.exe', ['--establish'])
    expect(command.args.join(' ')).toContain('exit $p.ExitCode')
  })

  it('escapes a quote in a path instead of ending the string early', () => {
    // `C:\Users\O'Brien\Projects` is a real directory name, and this command
    // line is about to run as administrator. An unescaped quote would turn the
    // rest of a path into PowerShell.
    const command = elevatedGrantCommand("C:\\Users\\O'Brien\\td.exe", ["C:\\a'b"])
    expect(command.args.join(' ')).toContain("'C:\\Users\\O''Brien\\td.exe'")
    expect(command.args.join(' ')).toContain("'C:\\a''b'")
  })
})

describe('the record', () => {
  const dirs: string[] = []
  const scratch = (): string => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-tools-'))
    dirs.push(dir)
    return dir
  }
  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
    resetWindowsTools()
  })

  const grant = toolGrant({ dirs: ['C:\\Program Files\\nodejs'], accountHome: 'C:\\Users\\Imza' })

  it('survives a round trip', () => {
    const file = join(scratch(), GRANT_RECORD)
    writeGrantRecord(file, {
      capability: capabilitySid(),
      read: grant.read,
      ancestors: grant.ancestors,
      established: '2026-08-16T05:00:00.000Z',
    })
    expect(readGrantRecord(file)?.read).toEqual(grant.read)
  })

  it('reads a missing or corrupt file as no grant at all', () => {
    // The direction that matters. Treating an unreadable record as a grant would
    // be a session claiming a boundary on the strength of a broken file; treating
    // it as absent costs one administrator prompt.
    const dir = scratch()
    expect(readGrantRecord(join(dir, GRANT_RECORD))).toBeNull()
    writeFileSync(join(dir, GRANT_RECORD), '{ not json')
    expect(readGrantRecord(join(dir, GRANT_RECORD))).toBeNull()
  })

  it('rejects a record naming a different capability', () => {
    // It can only be another build's. Honouring it would mean skipping ancestors
    // whose ACEs name a SID this session does not carry — a session that starts
    // and cannot resolve a path.
    const file = join(scratch(), GRANT_RECORD)
    writeGrantRecord(file, {
      capability: 'S-1-15-3-1024-1-2-3-4-5-6-7-8',
      read: grant.read,
      ancestors: grant.ancestors,
      established: '2026-08-16T05:00:00.000Z',
    })
    expect(readGrantRecord(file)).toBeNull()
  })

  it('is not readable by another account on the machine', () => {
    const file = join(scratch(), GRANT_RECORD)
    writeGrantRecord(file, {
      capability: capabilitySid(),
      read: [],
      ancestors: [],
      established: '2026-08-16T05:00:00.000Z',
    })
    expect(readGrantRecord(file)).not.toBeNull()
  })
})

describe('grantShortfall', () => {
  const needed = toolGrant({
    dirs: ['C:\\Program Files\\nodejs', 'C:\\Program Files\\Git\\cmd'],
    accountHome: 'C:\\Users\\Imza',
  })

  it('is everything when nothing has been granted', () => {
    expect(grantShortfall(null, needed)).toEqual(needed)
    expect(grantIsComplete(null, needed)).toBe(false)
  })

  it('is nothing when the record already covers it', () => {
    const record = {
      capability: capabilitySid(),
      read: needed.read,
      ancestors: needed.ancestors,
      established: '2026-08-16T05:00:00.000Z',
    }
    expect(grantIsComplete(record, needed)).toBe(true)
  })

  it('names only what is missing, because that is what the prompt has to say', () => {
    // "Terminal Deck wants to change permissions" with no list is a prompt
    // nobody can consent to meaningfully.
    const record = {
      capability: capabilitySid(),
      read: ['C:\\Program Files\\nodejs'],
      ancestors: needed.ancestors,
      established: '2026-08-16T05:00:00.000Z',
    }
    expect(grantShortfall(record, needed).read).toEqual(['C:\\Program Files\\Git\\cmd'])
  })

  it('compares paths the way the filesystem does, not the way a string does', () => {
    const record = {
      capability: capabilitySid(),
      read: needed.read.map((dir) => dir.toUpperCase()),
      ancestors: needed.ancestors.map((dir) => dir.toUpperCase()),
      established: '2026-08-16T05:00:00.000Z',
    }
    expect(grantIsComplete(record, needed)).toBe(true)
  })

  it('counts a directory granted read as covering the ancestor rule too', () => {
    const record = {
      capability: capabilitySid(),
      read: [...needed.read, 'C:\\Users\\Imza'],
      ancestors: needed.ancestors.filter((dir) => dir !== 'C:\\Users\\Imza'),
      established: '2026-08-16T05:00:00.000Z',
    }
    expect(grantIsComplete(record, needed)).toBe(true)
  })
})

describe('establishToolGrant', () => {
  const dirs: string[] = []
  const scratch = (): string => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-establish-'))
    dirs.push(dir)
    writeFileSync(join(dir, 'tdconfine.exe'), 'not really an exe')
    installWindowsTools({ launcher: join(dir, 'tdconfine.exe'), recordFile: join(dir, GRANT_RECORD) })
    return dir
  }
  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
    resetWindowsTools()
  })

  const ask = { path: PATH_ON_THAT_MACHINE, accountHome: 'C:\\Users\\Imza', lookup: INSTALLED }

  it('asks for the prompt once and writes the record when it worked', async () => {
    const dir = scratch()
    let calls = 0
    const result = await establishToolGrant({
      ...ask,
      run: async () => {
        calls++
        return { code: 0, stderr: '' }
      },
      now: () => new Date('2026-08-16T05:00:00.000Z'),
    })
    expect(result.ok).toBe(true)
    expect(calls).toBe(1)
    expect(readGrantRecord(join(dir, GRANT_RECORD))?.established).toBe('2026-08-16T05:00:00.000Z')
  })

  it('writes no record when the prompt was declined', async () => {
    // The failure that must not leave the app believing the machine is set up.
    // A record without the ACEs is a `confinementKind` of 'appcontainer' on a
    // machine where every session would refuse to start.
    const dir = scratch()
    const result = await establishToolGrant({
      ...ask,
      run: async () => ({ code: 1, stderr: 'Start-Process : The operation was canceled by the user' }),
    })
    expect(result.ok).toBe(false)
    expect(result.detail).toContain('canceled by the user')
    expect(readGrantRecord(join(dir, GRANT_RECORD))).toBeNull()
  })

  it('reports the launcher own words when a directory could not be granted', async () => {
    scratch()
    const result = await establishToolGrant({
      ...ask,
      run: async () => ({ code: 122, stderr: 'tdconfine: could not grant C:\\ (0x00000005)\n' }),
    })
    expect(result.detail).toContain('could not grant C:\\')
  })

  it('refuses to prompt when there is nothing on the machine worth granting', async () => {
    // A PATH with no node, no git and no agent CLI. Granting the ancestors alone
    // would be a permission change that buys nothing, and a prompt for it is one
    // nobody can act on.
    scratch()
    let calls = 0
    const result = await establishToolGrant({
      path: 'C:\\WINDOWS\\system32',
      accountHome: 'C:\\Users\\Imza',
      lookup: lookupOf([]),
      run: async () => {
        calls++
        return { code: 0, stderr: '' }
      },
    })
    expect(result.ok).toBe(false)
    expect(result.prompted).toBe(false)
    expect(calls).toBe(0)
  })

  it('covers a granted folder on another drive, which is the case that needs it', async () => {
    // `D:\` is a drive root; an unprivileged process cannot write its ACL. Left
    // out of the grant, the launcher refuses the session with `could not grant
    // D:\ (0x00000005)` — correct, and unhelpful.
    scratch()
    let args: readonly string[] = []
    await establishToolGrant({
      ...ask,
      folders: ['D:\\work\\app'],
      run: async (_command, passed) => {
        args = passed
        return { code: 0, stderr: '' }
      },
    })
    expect(args.join(' ')).toContain("'D:\\'")
    expect(args.join(' ')).toContain("'D:\\work'")
  })
})

describe('withdrawToolGrant', () => {
  const dirs: string[] = []
  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
    resetWindowsTools()
  })

  const setUp = (): string => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-withdraw-'))
    dirs.push(dir)
    writeFileSync(join(dir, 'tdconfine.exe'), 'not really an exe')
    writeGrantRecord(join(dir, GRANT_RECORD), {
      capability: capabilitySid(),
      read: ['C:\\Program Files\\nodejs'],
      ancestors: ['C:\\', 'C:\\Users'],
      established: '2026-08-16T05:00:00.000Z',
    })
    installWindowsTools({ launcher: join(dir, 'tdconfine.exe'), recordFile: join(dir, GRANT_RECORD) })
    return dir
  }

  it('takes back exactly what was granted, not what would be granted today', async () => {
    // The tools may have moved since. The ACEs that have to come off are the
    // ones that went on.
    setUp()
    let args: readonly string[] = []
    const result = await withdrawToolGrant({
      run: async (_command, passed) => {
        args = passed
        return { code: 0, stderr: '' }
      },
    })
    expect(result.ok).toBe(true)
    expect(args.join(' ')).toContain('--withdraw')
    expect(args.join(' ')).toContain("'C:\\Program Files\\nodejs'")
  })

  it('keeps the record when the removal failed', async () => {
    // A record removed first would leave a machine carrying a permission that
    // nothing in the app knows how to withdraw.
    const dir = setUp()
    const result = await withdrawToolGrant({ run: async () => ({ code: 1, stderr: 'nope' }) })
    expect(result.ok).toBe(false)
    expect(readGrantRecord(join(dir, GRANT_RECORD))).not.toBeNull()
  })

  it('removes the record once the permissions are gone', async () => {
    const dir = setUp()
    await withdrawToolGrant({ run: async () => ({ code: 0, stderr: '' }) })
    expect(readGrantRecord(join(dir, GRANT_RECORD))).toBeNull()
  })

  it('does nothing at all when there was no grant', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-withdraw-'))
    dirs.push(dir)
    installWindowsTools({ launcher: join(dir, 'tdconfine.exe'), recordFile: join(dir, GRANT_RECORD) })
    let calls = 0
    const result = await withdrawToolGrant({
      run: async () => {
        calls++
        return { code: 0, stderr: '' }
      },
    })
    expect(result.ok).toBe(true)
    expect(calls).toBe(0)
  })
})

describe('toolProbe', () => {
  it('picks node first, because node is what every Windows session needs', () => {
    // On Windows a session is `cmd.exe /c <cli>` and every agent CLI installed by
    // npm is a `.cmd` shim whose first act is to run node.
    expect(
      toolProbe(
        ['C:\\Program Files\\Git\\cmd', 'C:\\Program Files\\nodejs'],
        lookupOf(['C:\\Program Files\\Git\\cmd\\git.exe', 'C:\\Program Files\\nodejs\\node.exe']),
      ),
    ).toBe('C:\\Program Files\\nodejs\\node.exe')
  })

  it('falls back to git when there is no node', () => {
    expect(
      toolProbe(['C:\\Program Files\\Git\\cmd'], lookupOf(['C:\\Program Files\\Git\\cmd\\git.exe'])),
    ).toBe('C:\\Program Files\\Git\\cmd\\git.exe')
  })

  it('answers null rather than naming something that is not there', () => {
    // A probe pointed at a missing file would fail every proof on a machine with
    // no tools installed, and refuse sessions that are confined and work.
    expect(toolProbe(['C:\\empty'], lookupOf([]))).toBeNull()
  })
})

describe('windowsConfinementReady', () => {
  afterEach(resetWindowsTools)

  it('is false before anything is installed', () => {
    resetWindowsTools()
    expect(windowsConfinementReady()).toBe(false)
  })

  it('is false when the build ships no launcher', () => {
    // A development checkout that has never run build.ps1. Answering true here
    // would mean every session from a device refusing to start on a build that
    // simply does not have the feature in it.
    const dir = mkdtempSync(join(tmpdir(), 'confine-ready-'))
    try {
      writeGrantRecord(join(dir, GRANT_RECORD), {
        capability: capabilitySid(),
        read: [],
        ancestors: [],
        established: '2026-08-16T05:00:00.000Z',
      })
      installWindowsTools({ launcher: join(dir, 'nothing.exe'), recordFile: join(dir, GRANT_RECORD) })
      expect(windowsConfinementReady()).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('is false when the launcher is there and the machine has not been set up', () => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-ready-'))
    try {
      writeFileSync(join(dir, 'tdconfine.exe'), 'not really an exe')
      installWindowsTools({
        launcher: join(dir, 'tdconfine.exe'),
        recordFile: join(dir, GRANT_RECORD),
      })
      expect(windowsConfinementReady()).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('is true only when both are true', () => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-ready-'))
    try {
      writeFileSync(join(dir, 'tdconfine.exe'), 'not really an exe')
      writeGrantRecord(join(dir, GRANT_RECORD), {
        capability: capabilitySid(),
        read: [],
        ancestors: [],
        established: '2026-08-16T05:00:00.000Z',
      })
      installWindowsTools({
        launcher: join(dir, 'tdconfine.exe'),
        recordFile: join(dir, GRANT_RECORD),
      })
      expect(windowsConfinementReady()).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('windowsToolsFor', () => {
  it('prefers the launcher beside the asar, where extraResources puts it', () => {
    const shipped = join('C:\\app\\resources', 'tdconfine.exe')
    const install = windowsToolsFor('C:\\storage', 'C:\\app\\resources', (path) => path === shipped)
    expect(install.launcher).toBe(shipped)
  })

  it('finds the one a development checkout built, so the feature can be tried', () => {
    const built = join(process.cwd(), 'native', 'win-confine', 'tdconfine.exe')
    const install = windowsToolsFor('C:\\storage', 'C:\\app\\resources', (path) => path === built)
    expect(install.launcher).toBe(built)
  })

  it('answers with a path even when there is none, so the caller can say so', () => {
    const install = windowsToolsFor('C:\\storage', 'C:\\app\\resources', () => false)
    expect(install.launcher).toBe(join('C:\\app\\resources', 'tdconfine.exe'))
  })

  it('keeps the record in the app storage the caller named', () => {
    const install = windowsToolsFor('C:\\storage', null, () => false)
    expect(install.recordFile).toContain(GRANT_RECORD)
    expect(install.recordFile).toContain('storage')
  })
})
