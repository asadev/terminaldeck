import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  aclArguments,
  icaclsPath,
  protectSecretFile,
  windowsPrincipal,
  writeSecretFile,
  type AclResult,
  type AclRunner,
} from './secret-file'

/**
 * The one door every secret in this app is written through, checked on both
 * platforms from one of them.
 *
 * The Windows half is the reason this file exists. `icacls` cannot run here and
 * CI is macOS-only by policy, so the tool is injected exactly the way
 * `platform/host.ts` argues the platform itself should be — and the Windows
 * answers below are pinned on a Mac, beside the POSIX ones, on the same run.
 * "It cannot run here" is not a reason to ship it unexercised: that is precisely
 * how the PATH/Path bug reached a user.
 */

const dirs: string[] = []

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-secret-'))
  dirs.push(dir)
  return dir
}

afterEach(() => {
  vi.restoreAllMocks()
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

/** What a working `icacls` says. The prose is never parsed — see below. */
const DONE: AclResult = {
  code: 0,
  stdout: 'processed file: C:\\x\nSuccessfully processed 1 files; Failed processing 0 files.\n',
  stderr: '',
}

const DENIED: AclResult = {
  code: 5,
  stdout: 'Successfully processed 0 files; Failed processing 1 files.\n',
  stderr: 'C:\\x: Access is denied.\n',
}

interface AclCall {
  tool: string
  target: string
  args: string[]
  /** Did the *final* path exist at the moment this call was made? */
  finalExisted: boolean
}

/**
 * A stand-in for `icacls` that records what it was asked to do.
 *
 * `finalExisted` is the interesting field: it is what proves the file is locked
 * down while it is still the temp file, rather than after it has appeared under
 * the name something else might already be reading.
 */
function recorder(
  finalPath: string,
  answer: (target: string) => AclResult = () => DONE,
): { calls: AclCall[]; run: AclRunner } {
  const calls: AclCall[] = []
  const run: AclRunner = (tool, args) => {
    const target = args[0] ?? ''
    calls.push({ tool, target, args: [...args], finalExisted: existsSync(finalPath) })
    return answer(target)
  }
  return { calls, run }
}

/** A runner that fails the test if anything tries to start a process. */
const noProcesses: AclRunner = (tool, args) => {
  throw new Error(`nothing should have been spawned here, but got ${tool} ${args.join(' ')}`)
}

const WINDOWS = {
  platform: 'win32',
  env: { SystemRoot: 'C:\\Windows', USERDOMAIN: 'STUDIO' },
  account: 'asad',
} as const

describe('on POSIX, which must not change', () => {
  it('writes the file 0600 inside a 0700 folder', () => {
    const dir = join(tempDir(), 'nested')
    const file = join(dir, 'machines.json')
    writeSecretFile(dir, file, '{"version":1}', { platform: 'darwin', runAcl: noProcesses })

    expect(readFileSync(file, 'utf8')).toBe('{"version":1}')
    expect(statSync(file).mode & 0o777).toBe(0o600)
    expect(statSync(dir).mode & 0o777).toBe(0o700)
    // The rename left nothing behind: the folder holds the file and nothing else.
    expect(readdirSync(dir)).toEqual(['machines.json'])
  })

  it('starts no process at all, on a platform where the mode is the protection', () => {
    // `noProcesses` throws, so reaching the tool at all fails this. Spawning
    // `icacls` on a Mac would be a slow no-op at best and, in a sandbox that
    // refuses to fork, a credential that cannot be saved at all.
    const dir = tempDir()
    expect(() =>
      writeSecretFile(dir, join(dir, 'auth.json'), '{}', {
        platform: 'darwin',
        runAcl: noProcesses,
      }),
    ).not.toThrow()
    expect(() =>
      protectSecretFile(dir, join(dir, 'auth.json'), { platform: 'linux', runAcl: noProcesses }),
    ).not.toThrow()
  })

  it('replaces the previous contents rather than appending to them', () => {
    const dir = tempDir()
    const file = join(dir, 'host.json')
    writeSecretFile(dir, file, 'first', { platform: 'darwin' })
    writeSecretFile(dir, file, 'second', { platform: 'darwin' })
    expect(readFileSync(file, 'utf8')).toBe('second')
  })
})

describe('on Windows, where the mode means nothing', () => {
  it('locks the folder and the file to this account, and strips what was inherited', () => {
    const dir = tempDir()
    const file = join(dir, 'machines.json')
    const { calls, run } = recorder(file)

    writeSecretFile(dir, file, '{"version":1}', { ...WINDOWS, runAcl: run })

    expect(calls).toHaveLength(2)
    // The folder first, with the inheritable flags, so that anything created in
    // it afterwards — including the temp file on the next line — is born
    // protected rather than protected a moment later.
    expect(calls[0].args).toEqual([dir, '/inheritance:r', '/grant:r', 'STUDIO\\asad:(OI)(CI)(F)'])
    // Then the file, without them: `(OI)(CI)` on a file is meaningless and
    // icacls rejects it.
    expect(calls[1].args.slice(1)).toEqual(['/inheritance:r', '/grant:r', 'STUDIO\\asad:(F)'])
    expect(readFileSync(file, 'utf8')).toBe('{"version":1}')
  })

  it('locks the file before it has the name anyone would look for', () => {
    const dir = tempDir()
    const file = join(dir, 'auth.json')
    const { calls, run } = recorder(file)

    writeSecretFile(dir, file, '{"token":"ghu_x"}', { ...WINDOWS, runAcl: run })

    const fileCall = calls[1]
    // The path being locked is the temp file, and the real name does not exist
    // yet. A credential that appears at its final path and is locked down a few
    // milliseconds later is a credential that was readable for a few
    // milliseconds — and forever, if the process dies in between.
    expect(fileCall.target).not.toBe(file)
    expect(fileCall.target.startsWith(file)).toBe(true)
    expect(fileCall.finalExisted).toBe(false)
    expect(existsSync(file)).toBe(true)
  })

  it('runs the icacls in System32 rather than whatever PATH offers', () => {
    // PATH on Windows routinely contains directories the user can write to, and
    // this is a process started in order to protect a secret.
    const dir = tempDir()
    const file = join(dir, 'host.json')
    const { calls, run } = recorder(file)

    writeSecretFile(dir, file, '{}', { ...WINDOWS, runAcl: run })

    expect(calls[0].tool).toBe('C:\\Windows\\System32\\icacls.exe')
    expect(icaclsPath({})).toBe('C:\\Windows\\System32\\icacls.exe')
    expect(icaclsPath({ SystemRoot: 'D:\\Win' })).toBe('D:\\Win\\System32\\icacls.exe')
  })

  it('writes nothing when the folder cannot be locked down', () => {
    const dir = tempDir()
    const file = join(dir, 'machines.json')
    const { calls, run } = recorder(file, () => DENIED)

    expect(() => writeSecretFile(dir, file, 'secret', { ...WINDOWS, runAcl: run })).toThrow(
      /would not restrict this directory/,
    )
    // Not "written and warned": the folder is where the file would have gone,
    // and the bytes never left this process.
    expect(calls).toHaveLength(1)
    expect(readdirSync(dir)).toEqual([])
  })

  it('writes nothing, and leaves no temp file, when the file cannot be locked down', () => {
    const dir = tempDir()
    const file = join(dir, 'machines.json')
    const { run } = recorder(file, (target) => (target === dir ? DONE : DENIED))

    expect(() => writeSecretFile(dir, file, 'secret', { ...WINDOWS, runAcl: run })).toThrow(
      /would not restrict this file/,
    )
    expect(existsSync(file)).toBe(false)
    // The temp file held the whole secret. It is unlinked on the way out, or the
    // refusal would leave the very thing it refused to write sitting in the
    // folder under the name nobody thinks to look at.
    expect(readdirSync(dir)).toEqual([])
  })

  it('keeps the credential that was already there rather than half-replacing it', () => {
    const dir = tempDir()
    const file = join(dir, 'auth.json')
    writeSecretFile(dir, file, 'the old token', { ...WINDOWS, runAcl: recorder(file).run })

    const { run } = recorder(file, (target) => (target === dir ? DONE : DENIED))
    expect(() => writeSecretFile(dir, file, 'the new token', { ...WINDOWS, runAcl: run })).toThrow()
    expect(readFileSync(file, 'utf8')).toBe('the old token')
  })

  it('treats a zero exit with anything on stderr as a failure', () => {
    // icacls prints its per-file errors there and has been reported to still
    // exit 0 for some of them. Between refusing a write that would have been
    // fine and believing a protection that was never applied, only the second
    // one loses a credential.
    const dir = tempDir()
    const file = join(dir, 'host.json')
    const { run } = recorder(file, () => ({
      code: 0,
      stdout: '',
      stderr: 'C:\\x: The system cannot find the path specified.\n',
    }))

    expect(() => writeSecretFile(dir, file, '{}', { ...WINDOWS, runAcl: run })).toThrow(
      /cannot find the path/,
    )
  })

  it('does not read the success line, which is translated on most of the world’s PCs', () => {
    // A check that greps "Successfully processed 1 files" works on an English
    // install and silently stops checking anything on a German one. The exit
    // status is the same everywhere.
    const dir = tempDir()
    const file = join(dir, 'host.json')
    const { run } = recorder(file, () => ({
      code: 0,
      stdout: '1 Dateien erfolgreich verarbeitet, bei 0 Dateien ist ein Verarbeitungsfehler aufgetreten.\n',
      stderr: '',
    }))

    expect(() => writeSecretFile(dir, file, '{}', { ...WINDOWS, runAcl: run })).not.toThrow()
    expect(readFileSync(file, 'utf8')).toBe('{}')
  })

  it('names the file a person can act on, not the temp file it locked', () => {
    // The file is locked while it is still `machines.json.4242.tmp`, and that
    // path is gone by the time anyone reads the failure.
    const dir = tempDir()
    const file = join(dir, 'machines.json')
    const { run } = recorder(file, (target) => (target === dir ? DONE : DENIED))

    let message = ''
    try {
      writeSecretFile(dir, file, 'secret', { ...WINDOWS, runAcl: run })
    } catch (error) {
      message = error instanceof Error ? error.message : String(error)
    }
    expect(message).toContain(file)
    expect(message).not.toContain('.tmp')
  })

  it('says which path, which account and what the tool answered', () => {
    const dir = tempDir()
    const file = join(dir, 'machines.json')
    const { run } = recorder(file, () => DENIED)

    // The sentence is the whole remedy here: a person who cannot see the path or
    // the exit code has nothing to act on, and this one reaches them through a
    // failed sign-in or a failed pairing.
    let message = ''
    try {
      writeSecretFile(dir, file, 'secret', { ...WINDOWS, runAcl: run })
    } catch (error) {
      message = error instanceof Error ? error.message : String(error)
    }
    expect(message).toContain(dir)
    expect(message).toContain('STUDIO\\asad')
    expect(message).toContain('exited 5')
    expect(message).toContain('Access is denied')
    expect(message).toContain('every account on this PC')
    // And it must never suggest the write happened.
    expect(message).toContain('nothing was written')
  })

  it('locks the folder once per process, and every new file every time', () => {
    // A folder's ACL cannot be undone by anyone who could not also undo it a
    // second later, so re-applying it per write buys nothing — and
    // `machines.json` is rewritten on every reconnect. The file is different:
    // each write creates a new object that carries no entry of its own.
    const dir = tempDir()
    const file = join(dir, 'machines.json')
    const { calls, run } = recorder(file)

    writeSecretFile(dir, file, 'one', { ...WINDOWS, runAcl: run })
    writeSecretFile(dir, file, 'two', { ...WINDOWS, runAcl: run })
    writeSecretFile(dir, file, 'three', { ...WINDOWS, runAcl: run })

    expect(calls.filter((call) => call.target === dir)).toHaveLength(1)
    expect(calls.filter((call) => call.target !== dir)).toHaveLength(3)
  })
})

describe('the account the files are granted to', () => {
  it('is spelled with the domain the machine is logged into', () => {
    expect(windowsPrincipal('asad', { USERDOMAIN: 'STUDIO' })).toBe('STUDIO\\asad')
  })

  it('is the bare name on a machine that is not in a domain', () => {
    expect(windowsPrincipal('asad', {})).toBe('asad')
    expect(windowsPrincipal('asad', { USERDOMAIN: '   ' })).toBe('asad')
  })

  it('leaves a name that already carries a domain alone', () => {
    // Otherwise a `DOMAIN\user` handed in becomes `DOMAIN\DOMAIN\user`, which
    // resolves to nobody and fails the write.
    expect(windowsPrincipal('OFFICE\\asad', { USERDOMAIN: 'STUDIO' })).toBe('OFFICE\\asad')
  })

  it('refuses a name with a colon in it rather than granting something weaker', () => {
    // icacls reads `name:(F)` by splitting at the *first* colon, so a name
    // carrying one would quietly apply a different right to a different
    // principal. No real Windows account can contain one, so seeing one means
    // something upstream is wrong and the safe answer is to stop.
    expect(() => windowsPrincipal('asad:(R)', {})).toThrow(/not a Windows account name/)
    expect(() => windowsPrincipal('/grant', {})).toThrow(/not a Windows account name/)
    expect(() => windowsPrincipal('   ', {})).toThrow(/which account/)
  })

  it('is the only thing on the command line, and the inherited entries go', () => {
    expect(aclArguments('C:\\s\\host.json', 'STUDIO\\asad', 'file')).toEqual([
      'C:\\s\\host.json',
      '/inheritance:r',
      '/grant:r',
      'STUDIO\\asad:(F)',
    ])
    expect(aclArguments('C:\\s', 'STUDIO\\asad', 'directory')[3]).toBe('STUDIO\\asad:(OI)(CI)(F)')
  })
})

describe('repairing a file an older version already wrote', () => {
  it('locks the folder and the file that are already there', () => {
    const dir = tempDir()
    const file = join(dir, 'auth.json')
    writeSecretFile(dir, file, '{"token":"ghu_x"}', { platform: 'darwin' })

    const { calls, run } = recorder(file)
    protectSecretFile(dir, file, { ...WINDOWS, runAcl: run })

    expect(calls.map((call) => call.target)).toEqual([dir, file])
  })

  it('does nothing when there is no such file yet', () => {
    // The first write locks the folder; there is no reason to pay for a process
    // before there is a secret in it.
    const dir = tempDir()
    protectSecretFile(dir, join(dir, 'auth.json'), { ...WINDOWS, runAcl: noProcesses })
  })

  it('reports and carries on rather than refusing to read', () => {
    /*
     * The opposite decision from the write path, deliberately. Refusing a write
     * removes the exposure — the secret stays off the disk. Refusing a read
     * removes none of it: the file is already there and already exposed, and
     * throwing would only break an app that could otherwise work.
     */
    const dir = tempDir()
    const file = join(dir, 'auth.json')
    writeSecretFile(dir, file, '{"token":"ghu_x"}', { platform: 'darwin' })
    const spoken = vi.spyOn(console, 'error').mockImplementation(() => undefined)

    const { run } = recorder(file, () => DENIED)
    expect(() => protectSecretFile(dir, file, { ...WINDOWS, runAcl: run })).not.toThrow()

    expect(spoken).toHaveBeenCalledTimes(1)
    expect(String(spoken.mock.calls[0][0])).toContain(file)
    expect(String(spoken.mock.calls[0][0])).toContain('may be able to read it')
  })

  it('spawns once however often it is called', () => {
    // `readDaemonRecord` is called in a loop while a CLI waits for a host.
    const dir = tempDir()
    const file = join(dir, 'host.json')
    writeSecretFile(dir, file, '{}', { platform: 'darwin' })

    const { calls, run } = recorder(file)
    protectSecretFile(dir, file, { ...WINDOWS, runAcl: run })
    protectSecretFile(dir, file, { ...WINDOWS, runAcl: run })
    protectSecretFile(dir, file, { ...WINDOWS, runAcl: run })

    expect(calls).toHaveLength(2)
  })
})

/* ------------------------------------------------------------- one door -- */

const ROOT = resolve(__dirname, '..', '..', '..')

/**
 * Every module that puts a secret on disk, and what it keeps there.
 *
 * The list is the guard. Three of these were named in a security review — the
 * GitHub credential, the per-machine bearer credential and the daemon's control
 * token — and the first question was whether all three went through one writer
 * or whether one of them had its own copy of the dance. They do all go through
 * it, and this is what keeps that true: a per-file fix, or a per-file
 * regression, is how one of them gets missed. A new secret file is not on this
 * list, which is the honest limit of a check like this one; what it does
 * guarantee is that none of these six quietly grows a `writeFileSync`.
 */
const SECRET_WRITERS = [
  'src/main/github-auth.ts',
  'src/main/remote/machines/store.ts',
  'src/headless/control.ts',
  'src/main/remote/device-auth.ts',
  'src/main/remote/host-identity.ts',
  'src/main/remote/folder-grants.ts',
]

/** Anything that puts bytes on disk without going through the door. */
const RAW_WRITES = /\b(writeFileSync|appendFileSync|createWriteStream|openSync|writeFile)\s*\(/

describe('every secret goes through the one writer', () => {
  it('is looking at files that really are there', () => {
    for (const file of SECRET_WRITERS) {
      expect(existsSync(join(ROOT, file)), file).toBe(true)
    }
  })

  it('would notice a raw write if one appeared', () => {
    // Without this the sweep below passes just as happily when the pattern stops
    // matching anything at all — a green check guarding nothing.
    expect(RAW_WRITES.test('    writeFileSync(this.file, JSON.stringify(state))')).toBe(true)
    expect(RAW_WRITES.test('const fd = openSync(tmp, "wx", 0o600)')).toBe(true)
    expect(RAW_WRITES.test('writeSecretFile(this.dir, this.file, body)')).toBe(false)
  })

  it('finds no module writing a secret file for itself', () => {
    for (const file of SECRET_WRITERS) {
      const source = readFileSync(join(ROOT, file), 'utf8')
      expect(source, file).toContain('writeSecretFile(')
      expect(RAW_WRITES.test(source), `${file} writes a file without writeSecretFile`).toBe(false)
    }
  })

  it('has the three named files repairing what an older version left behind', () => {
    // Pinned by source because the repair is a Windows-only no-op that a test on
    // this Mac cannot otherwise observe, and because it is exactly the kind of
    // one-line wiring that gets dropped in a merge.
    for (const file of [
      'src/main/github-auth.ts',
      'src/main/remote/machines/store.ts',
      'src/headless/control.ts',
    ]) {
      expect(readFileSync(join(ROOT, file), 'utf8'), file).toContain('protectSecretFile(')
    }
  })
})
