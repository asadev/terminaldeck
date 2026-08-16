/**
 * The Windows confinement, pinned from a Mac.
 *
 * Every assertion here is about a decision that was made on the strength of a
 * measurement on a real Windows 11 machine, and the comment on each one names
 * the measurement rather than restating the code. What a suite on this side can
 * do is stop those decisions being undone by somebody tidying up — the ancestor
 * grant looks like an over-broad rule until you know that removing
 * `FILE_LIST_DIRECTORY` breaks every git command, and the shape of the proof
 * looks like belt-and-braces until you know that a boundary so tight nothing
 * runs would otherwise pass a negative-only check.
 *
 * What it cannot do is prove the boundary. That took a Windows box, and it is
 * written down in `CONFINEMENT.md`.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { capabilitySid } from './tools'
import {
  LAUNCHER_NAME,
  WINDOWS_GRANT_NOTE,
  WINDOWS_SETUP_NEEDED,
  WINDOWS_TOOL_LAUNCH,
  WINDOWS_UNCONFINED_REASON,
  ancestorsOf,
  appContainerArgs,
  containerName,
  launcherPath,
  planAncestors,
  proveAppContainer,
  sessionAncestors,
  releaseArgs,
  windowsConfinedEnv,
  type AppContainerLaunch,
  type LauncherRunner,
  type ProbeFiles,
} from './appcontainer'
import type { ConfinementPlan } from './plan'

const plan: ConfinementPlan = {
  folder: 'C:\\Users\\Imza\\Projects\\app',
  accountHome: 'C:\\Users\\Imza',
  home: 'C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc',
  writable: ['C:\\Users\\Imza\\Projects\\app', 'C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc'],
  readable: ['C:\\Program Files\\nodejs'],
  readableFiles: ['C:\\Users\\Imza\\AppData\\Roaming\\td\\guest-git\\askpass.cmd'],
}

/**
 * The one-time grant as it stands on a machine that has been set up: the three
 * directories that actually hold tools on the machine this was measured on, and
 * the ancestors an unprivileged process cannot write for itself.
 */
const tools = {
  capability: capabilitySid(),
  read: [
    'C:\\Program Files\\nodejs',
    'C:\\Program Files\\Git\\cmd',
    'C:\\Users\\Imza\\AppData\\Roaming\\npm',
  ],
  ancestors: [
    'C:\\',
    'C:\\Users',
    'C:\\Users\\Imza',
    'C:\\Program Files\\Git',
    'C:\\Users\\Imza\\AppData',
    'C:\\Users\\Imza\\AppData\\Roaming',
  ],
  probe: 'C:\\Program Files\\nodejs\\node.exe',
}

const launch: AppContainerLaunch = { container: containerName('device-abc'), plan, tools }

/** A `ProbeFiles` that touches no filesystem, so the proof is testable here. */
function fakeFiles(): ProbeFiles & { written: Map<string, string>; removed: string[] } {
  const written = new Map<string, string>()
  const removed: string[] = []
  return {
    written,
    removed,
    write(path, contents) {
      written.set(path, contents)
    },
    remove(path) {
      removed.push(path)
    },
  }
}

describe('ancestorsOf', () => {
  it('walks from the drive root down to the folder, excluding it', () => {
    expect(ancestorsOf('C:\\Users\\Imza\\Projects\\app')).toEqual([
      'C:\\',
      'C:\\Users',
      'C:\\Users\\Imza',
      'C:\\Users\\Imza\\Projects',
    ])
  })

  it('answers with the root alone for a folder directly on it', () => {
    expect(ancestorsOf('D:\\work')).toEqual(['D:\\'])
  })

  it('answers with nothing for the root itself', () => {
    // Not an error case. A grant on `C:\` is a grant on everything, which the
    // plan layer refuses long before this; an empty chain here just means there
    // is nothing above it to make passable.
    expect(ancestorsOf('C:\\')).toEqual([])
  })

  it('answers with nothing for a UNC path', () => {
    // `\\server\share` has no ancestor an ACL can be written on from this
    // machine, and an AppContainer has no network-share capability unless one
    // is granted. `appContainerArgs` turns this into a refusal rather than a
    // command that would confine a session to a folder it cannot open.
    expect(ancestorsOf('\\\\server\\share\\project')).toEqual([])
  })
})

describe('planAncestors', () => {
  const ancestors = planAncestors(plan)

  it('covers the folder and the device home, not only the granted folder', () => {
    // A session that can reach its folder but not its own home is a session
    // whose shell cannot read its startup files, and the device home lives
    // under the app's storage rather than under the project.
    expect(ancestors).toContain('C:\\Users\\Imza\\AppData\\Roaming\\td')
    expect(ancestors).toContain('C:\\Users\\Imza')
  })

  it('does not walk the readable list, because nothing grants it per session', () => {
    // `plan.readable` on Windows is `toolRoots()`'s walk of the session's PATH —
    // eighteen directories on the machine this was measured on, including the
    // JDK and two NVIDIA folders. The one-time grant in `tools.ts` covers the
    // three that hold tools; this list covers none of them, so walking their
    // ancestors would ask an unprivileged session to write an ACE on
    // `C:\Program Files`, which not even an administrator can write — its owner
    // is TrustedInstaller and the launcher was refused with 0x00000005.
    expect(ancestors).not.toContain('C:\\Program Files')
  })

  it('names each directory once however many plan entries are under it', () => {
    expect(ancestors.filter((dir) => dir === 'C:\\Users\\Imza')).toHaveLength(1)
    expect(new Set(ancestors).size).toBe(ancestors.length)
  })

  it('leaves out directories the plan already grants outright', () => {
    // A plan directory has a stronger grant. Leaving it in would put a second
    // ACE for the same SID on the same path: two things to revoke, and one more
    // way for a teardown to be half done.
    const inner: ConfinementPlan = {
      ...plan,
      writable: ['C:\\Users\\Imza\\Projects', 'C:\\Users\\Imza\\Projects\\app'],
      readable: [],
      readableFiles: [],
    }
    expect(planAncestors(inner)).not.toContain('C:\\Users\\Imza\\Projects')
    expect(planAncestors(inner)).toContain('C:\\Users\\Imza')
  })

  it('includes the account home, which is the cost this mechanism has', () => {
    // Stated as a test rather than only as prose, because it is the one place a
    // Windows session is weaker than a macOS one and a future change that
    // quietly dropped it would be a change to the boundary. See the comment on
    // GRANT_ANCESTOR in native/win-confine/tdconfine.c: without list access on
    // every ancestor, `GetLongPathNameW` fails and every git command dies.
    expect(ancestors).toContain('C:\\Users\\Imza')
  })
})

describe('containerName', () => {
  it('is the same for the same device and different for another', () => {
    expect(containerName('device-abc')).toBe(containerName('device-abc'))
    expect(containerName('device-abc')).not.toBe(containerName('device-abd'))
  })

  it('fits what Windows accepts for an AppContainer name', () => {
    // 64 characters is the documented limit and most punctuation is rejected. A
    // device key is an opaque identifier this module has no business making
    // assumptions about, so it is hashed rather than sanitised.
    const name = containerName('a device key with spaces, punctuation/and\\slashes')
    expect(name.length).toBeLessThanOrEqual(64)
    expect(name).toMatch(/^[A-Za-z0-9.-]+$/)
  })
})

describe('appContainerArgs', () => {
  const args = appContainerArgs(launch, 'C:\\Program Files\\nodejs\\node.exe', ['--version'])

  it('puts the command after the separator so a path is never read as a flag', () => {
    const separator = args.indexOf('--')
    expect(separator).toBeGreaterThan(0)
    expect(args.slice(separator + 1)).toEqual([
      'C:\\Program Files\\nodejs\\node.exe',
      '--version',
    ])
  })

  it('asks for the internet and nothing else', () => {
    // An AppContainer with no capability has no network at all, and an agent
    // CLI with no network cannot reach the API it exists to call. What is
    // deliberately absent: internetClientServer, which would let the session
    // accept inbound connections, and privateNetworkClientServer, which would
    // let it reach the rest of the network.
    expect(args.filter((arg) => arg === '--capability')).toHaveLength(1)
    expect(args[args.indexOf('--capability') + 1]).toBe('internet-client')
  })

  it('separates the kinds of grant, because they are different rights', () => {
    expect(pairs(args, '--write')).toEqual(plan.writable)
    expect(pairs(args, '--file')).toEqual(plan.readableFiles)
    expect(pairs(args, '--ancestor')).toEqual(sessionAncestors(launch))
  })

  it('grants no directory read access for the life of the session', () => {
    // The tool directories are the one-time grant's business, and they are not
    // in a session's argument vector at all. Two reasons, both measured: an
    // unprivileged process cannot write an ACE inside `C:\Program Files`, and
    // an inheritable ACE on a tool tree has to be propagated to every file
    // under it — thousands of security descriptors rewritten at the start of
    // every session, and rewritten again when it ends.
    expect(args).not.toContain('--read')
  })

  it('carries the tool capability, which is what makes the tools reachable', () => {
    // Measured on the real machine: with this SID in the token and the one-time
    // ACEs in place, a confined shell runs `node -v`. With the ACEs in place and
    // this argument removed, the same shell answers `'node' is not recognized as
    // an internal or external command`.
    expect(args[args.indexOf('--capability-sid') + 1]).toBe(capabilitySid())
  })

  it('asks for a desktop of its own on the station the app is already on', () => {
    // Not a window station of its own, which is the stronger isolation and needs
    // an administrator: `CreateWindowStationW` answers ERROR_ACCESS_DENIED for a
    // non-elevated token, measured in the user's own interactive session. Asking
    // for it would mean every session refusing to start on a machine nobody runs
    // Terminal Deck elevated on, which is all of them.
    expect(args[args.indexOf('--station') + 1]).toBe('shared')
  })

  it('leaves out the ancestors the one-time grant already covers', () => {
    // `C:\` and `C:\Users` are in the grant because an unprivileged process
    // cannot write their ACLs — measured with AccessCheck for WRITE_DAC against
    // a real filtered token. A session that listed them here would be refused by
    // the launcher at 0x00000005 having done nothing wrong.
    const emitted = pairs(args, '--ancestor')
    expect(emitted).not.toContain('C:\\')
    expect(emitted).not.toContain('C:\\Users')
    // And the one below the home directory, which the user owns, is still ours.
    expect(emitted).toContain('C:\\Users\\Imza\\Projects')
  })

  it('starts the session in the granted folder', () => {
    expect(args[args.indexOf('--cwd') + 1]).toBe(plan.folder)
  })

  it('refuses a folder on a network share rather than confining it badly', () => {
    const share: ConfinementPlan = {
      folder: '\\\\server\\share\\project',
      accountHome: '\\\\server\\home',
      home: '\\\\server\\home\\device-home',
      writable: ['\\\\server\\share\\project'],
      readable: [],
      readableFiles: [],
    }
    expect(() =>
      appContainerArgs({ container: launch.container, plan: share, tools }, 'cmd.exe', []),
    ).toThrow(/not on a Windows drive/)
  })

  it('refuses a folder inside WSL, which no Windows mechanism can hold', () => {
    // `wsl.exe` is refused outright inside an AppContainer, measured with the
    // window station already granted. A Linux folder has to go to the namespace
    // mechanism through `confineWslLine`, and a launcher handed a `wsl.exe`
    // command line cannot detect the mistake for itself.
    const linux: ConfinementPlan = {
      folder: '/home/asad/work',
      accountHome: '/home/asad',
      home: '/home/asad/.config/deck/device-home/abc',
      writable: ['/home/asad/work'],
      readable: [],
      readableFiles: [],
    }
    expect(() =>
      appContainerArgs({ container: launch.container, plan: linux, tools }, 'cmd.exe', []),
    ).toThrow(/WSL/)
  })

  it('drops the macOS system roots that plan.ts puts in every plan', () => {
    // `sessionPlan` prepends MACOS_SYSTEM_READ_ROOTS to the readable list on
    // every platform, because until now nothing on Windows read a plan. Passing
    // `/usr` to the launcher would ask it to ACL a directory that has never
    // existed on the machine, `GetNamedSecurityInfoW` would fail, and a session
    // that is perfectly confinable would be refused with a nonsense reason.
    const leaked: ConfinementPlan = {
      ...plan,
      readable: ['/System', '/usr', '/bin', 'C:\\Program Files\\nodejs'],
      readableFiles: ['/System/Library/thing', ...plan.readableFiles],
    }
    const built = appContainerArgs({ container: launch.container, plan: leaked, tools }, 'cmd.exe', [])
    expect(built.join(' ')).not.toContain('/usr')
    expect(built.join(' ')).not.toContain('/System')
  })
})

describe('releaseArgs', () => {
  it('names the same paths the grant did, so a sweep cannot miss one', () => {
    // The launcher revokes on every exit route it controls; being killed
    // outright is not one of them. This is what the app runs afterwards, and if
    // it named fewer paths than the grant it would leave the difference behind.
    const granted = appContainerArgs(launch, 'cmd.exe', [])
    for (const flag of ['--write', '--read', '--file', '--ancestor']) {
      expect(pairs(releaseArgs(launch), flag)).toEqual(pairs(granted, flag))
    }
  })

  it('carries the release flag and no command', () => {
    expect(releaseArgs(launch)).toContain('--release')
    expect(releaseArgs(launch)).not.toContain('--')
  })
})

describe('windowsConfinedEnv', () => {
  const env = windowsConfinedEnv('C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc')

  it('redirects every variable Windows programs actually read for a home', () => {
    // Setting only HOME leaves most of a session pointed at the owner's home,
    // which is outside the boundary. Measured: git reported `warning: unable to
    // access 'C:/Users/Imza/.gitconfig': Permission denied` three times and
    // then `fatal: unknown error occurred while reading the configuration
    // files`. The boundary was working perfectly and the session was unusable.
    expect(env.HOME).toBe('C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc')
    expect(env.USERPROFILE).toBe(env.HOME)
    expect(env.HOMEDRIVE).toBe('C:')
    expect(env.HOMEPATH).toBe('\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc')
  })

  it('redirects the two temp variables Windows reads, not TMPDIR', () => {
    // `confinedEnv` in plan.ts sets TMPDIR, which is the POSIX spelling and is
    // read by almost nothing on Windows. The default TEMP is under the owner's
    // home, so a session without these has no writable temp at all.
    expect(env.TEMP).toBe('C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc\\tmp')
    expect(env.TMP).toBe(env.TEMP)
  })

  it('redirects the two application-data directories', () => {
    expect(env.APPDATA).toContain('device-home\\abc\\AppData\\Roaming')
    expect(env.LOCALAPPDATA).toContain('device-home\\abc\\AppData\\Local')
  })
})

describe('proveAppContainer', () => {
  const probeDir = plan.writable[1] as string

  /**
   * What the real `cmd` would print for a run where everything worked: the
   * canary inside the boundary, nothing from the one outside it, and the token
   * that only gets echoed when the tool exited zero.
   */
  const wentWell = (files: ReturnType<typeof fakeFiles>, args: readonly string[]): string => {
    const inside = [...files.written.values()][0] ?? ''
    const script = args[args.length - 1] ?? ''
    const token = /echo ([0-9a-f]{24})/.exec(script)?.[1] ?? ''
    return `${inside}\n${token}\n`
  }

  it('passes when the canary, the refusal and the tool all answer', async () => {
    const files = fakeFiles()
    const runner: LauncherRunner = async (_command, args) => ({
      stdout: wentWell(files, args),
      stderr: '',
      code: 1,
    })
    const proof = await proveAppContainer(launch, 'tdconfine.exe', probeDir, runner, files)
    expect(proof).toEqual({ ok: true, detail: '' })
  })

  it('fails when the boundary holds but the tools are out of reach', async () => {
    // The failure the one-time grant exists for, and the reason the proof is not
    // two checks. Measured on the real machine: without the grant a confined
    // shell starts perfectly, reads its own folder, is refused the owner's home
    // — and answers `'node' is not recognized as an internal or external
    // command`. Every boundary check passes. The session is a terminal with
    // nothing in it, and calling that confined would be true and useless.
    const files = fakeFiles()
    const runner: LauncherRunner = async () => ({
      stdout: [...files.written.values()][0] ?? '',
      stderr: '',
      code: 1,
    })
    const proof = await proveAppContainer(launch, 'tdconfine.exe', probeDir, runner, files)
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/could not start C:\\Program Files\\nodejs\\node\.exe/)
  })

  it('asks the tool for its version rather than reading an error message', async () => {
    // The probe echoes a token only if the tool exited zero. Matching on the
    // tool's output would mean parsing a version string; matching on the failure
    // would mean matching `Access is denied`, which on the machine this was
    // measured on prints in Russian, because that is the account's display
    // language. An exit code is the same in every language.
    const files = fakeFiles()
    let script = ''
    const runner: LauncherRunner = async (_command, args) => {
      script = args[args.length - 1] ?? ''
      return { stdout: wentWell(files, args), stderr: '', code: 1 }
    }
    await proveAppContainer(launch, 'tdconfine.exe', probeDir, runner, files)
    expect(script).toContain('"C:\\Program Files\\nodejs\\node.exe" -v >nul 2>&1 && echo ')
  })

  it('skips the tool check when the grant names no tool, rather than inventing one', async () => {
    // A machine with neither node nor git installed. There is nothing to check,
    // and a proof that failed here would refuse a session that is confined,
    // works, and simply has no tools to run.
    const files = fakeFiles()
    const bare = { ...launch, tools: { ...tools, probe: null } }
    const runner: LauncherRunner = async () => ({
      stdout: [...files.written.values()][0] ?? '',
      stderr: '',
      code: 1,
    })
    expect(await proveAppContainer(bare, 'tdconfine.exe', probeDir, runner, files)).toEqual({
      ok: true,
      detail: '',
    })
  })

  it('fails when the outside canary comes back', async () => {
    const files = fakeFiles()
    const runner: LauncherRunner = async () => ({
      stdout: [...files.written.values()].join('\n'),
      stderr: '',
      code: 0,
    })
    const proof = await proveAppContainer(launch, 'tdconfine.exe', probeDir, runner, files)
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/readable from inside the container/)
  })

  it('fails when nothing ran at all, rather than reading that as a boundary', async () => {
    // The failure this half exists for. A plan under which nothing starts would
    // pass a negative-only check by failing at everything, which is the exact
    // shape of false confidence this project has shipped before in another
    // subsystem.
    const files = fakeFiles()
    const runner: LauncherRunner = async () => ({
      stdout: '',
      stderr: 'tdconfine: could not create a window station (0x00000005)\n',
      code: 123,
    })
    const proof = await proveAppContainer(launch, 'tdconfine.exe', probeDir, runner, files)
    expect(proof.ok).toBe(false)
    expect(proof.detail).toContain('could not create a window station')
  })

  it('refuses when the canary would land inside the boundary it is testing', async () => {
    // Reached when the grant covers the account's home directory. Refusing is
    // the honest answer: there is nothing left for the session to be held
    // inside, and the check that was supposed to notice cannot.
    const wide: ConfinementPlan = { ...plan, writable: ['C:\\Users\\Imza'] }
    const files = fakeFiles()
    const runner: LauncherRunner = async () => ({ stdout: '', stderr: '', code: 0 })
    const proof = await proveAppContainer(
      { container: launch.container, plan: wide, tools },
      'tdconfine.exe',
      'C:\\Users\\Imza',
      runner,
      files,
    )
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/could not fail/)
  })

  it('removes both canaries even when the run failed', async () => {
    const files = fakeFiles()
    const runner: LauncherRunner = async () => {
      throw new Error('the launcher is not there')
    }
    const proof = await proveAppContainer(launch, 'tdconfine.exe', probeDir, runner, files)
    expect(proof.ok).toBe(false)
    expect(files.removed).toHaveLength(2)
  })
})

describe('the wording', () => {
  it('says Windows confinement was measured, because it now has been', () => {
    // The sentence `unconfinedReason('win32')` carries today ends "has not been
    // built or measured". Measured is no longer true: every mechanism named in
    // CONFINEMENT.md was run on a real machine, and two of them are written off
    // rather than open.
    expect(WINDOWS_UNCONFINED_REASON).not.toMatch(/has not been (built or )?measured/)
    expect(WINDOWS_UNCONFINED_REASON).toMatch(/AppContainer/)
    expect(WINDOWS_UNCONFINED_REASON).toMatch(/launcher/)
    expect(WINDOWS_UNCONFINED_REASON).toMatch(/restricted tokens and job objects were measured/)
  })

  it('keeps WSL in its own sentence', () => {
    // A session in a WSL folder is a Linux process that no Windows mechanism
    // can cover, and one sentence covering two platforms is what rule 1 of
    // CONFINEMENT.md exists to stop.
    const sentences = WINDOWS_UNCONFINED_REASON.split('. ')
    expect(sentences.filter((line) => line.includes('WSL'))).toHaveLength(1)
    expect(sentences.find((line) => line.includes('WSL'))).not.toMatch(/AppContainer/)
  })

  it('tells the user about the one thing they would not guess', () => {
    expect(WINDOWS_GRANT_NOTE).toMatch(/names of the folders/)
    expect(WINDOWS_GRANT_NOTE).toMatch(/home folder/)
    expect(WINDOWS_GRANT_NOTE).toMatch(/cannot open/)
  })

  it('says what the one-time permission does, in words somebody can consent to', () => {
    // This used to check that the sentence offered two options and decided
    // neither, because the tool grant looked like a product decision. It was
    // not one: on Windows every session is `cmd.exe /c <cli>` — `providers.ts`
    // has always built it that way — so without the grant there is no working
    // confined session of any kind, terminal or agent.
    expect(WINDOWS_TOOL_LAUNCH).toMatch(/read and run/)
    expect(WINDOWS_TOOL_LAUNCH).toMatch(/never write/)
    expect(WINDOWS_TOOL_LAUNCH).toMatch(/once/)
    // The cost, in the same sentence as the benefit rather than a footnote.
    expect(WINDOWS_TOOL_LAUNCH).toMatch(/home folder/)
  })

  it('keeps the two reasons Windows can be unconfined apart', () => {
    // One is fixed by shipping a build with the launcher in it and one is fixed
    // by the person clicking a button. Running them together would tell somebody
    // a feature is missing from their copy of the app when it is one prompt away.
    expect(WINDOWS_SETUP_NEEDED).toMatch(/one-time permission/)
    expect(WINDOWS_SETUP_NEEDED).not.toMatch(/does not ship/)
    expect(WINDOWS_UNCONFINED_REASON).toMatch(/does not ship/)
    for (const sentence of [WINDOWS_SETUP_NEEDED, WINDOWS_UNCONFINED_REASON]) {
      const parts = sentence.split('. ')
      expect(parts.filter((part) => part.includes('WSL'))).toHaveLength(1)
    }
  })
})

describe('the launcher this module drives', () => {
  it('is looked for by one name', () => {
    expect(launcherPath('C:\\app\\resources')).toBe(`C:\\app\\resources\\${LAUNCHER_NAME}`)
  })

  it('exists in this repository as C that CI can compile', () => {
    // The point of the check is the pairing: a TypeScript module that builds a
    // command line for a program nobody ships is worse than no module, and the
    // way that happens is the .c file being moved or renamed while this file
    // keeps naming it.
    const dir = join(__dirname, '..', '..', '..', 'native', 'win-confine')
    const source = readFileSync(join(dir, 'tdconfine.c'), 'utf8')
    const build = readFileSync(join(dir, 'build.ps1'), 'utf8')
    expect(build).toContain('tdconfine.c')
    expect(build).toContain(LAUNCHER_NAME)
    // Every flag either module emits has to be one the launcher understands, and
    // a flag it does not understand is a refusal rather than a warning, so a
    // rename on either side would be a session that will not start. Verified on
    // the real launcher: an unknown option prints usage and exits 120.
    for (const flag of [
      '--container',
      '--station',
      '--capability',
      '--capability-sid',
      '--write',
      '--read',
      '--file',
      '--ancestor',
      '--cwd',
      '--release',
      // The one-time grant's two, which `tools.ts` emits rather than this file.
      '--establish',
      '--withdraw',
    ]) {
      expect(source).toContain(`L"${flag}"`)
    }
  })

  it('is compiled with the warnings turned into errors', () => {
    // It is security-critical code in a language with no seatbelt, and /W4 /WX
    // is the cheapest reviewer it will ever have.
    const build = readFileSync(
      join(__dirname, '..', '..', '..', 'native', 'win-confine', 'build.ps1'),
      'utf8',
    )
    expect(build).toContain('/W4 /WX')
  })
})

/** The values that followed each occurrence of a flag, in order. */
function pairs(args: readonly string[], flag: string): string[] {
  const found: string[] = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] === flag) {
      const value = args[i + 1]
      if (value !== undefined) found.push(value)
    }
    if (args[i] === '--') break
  }
  return found
}
