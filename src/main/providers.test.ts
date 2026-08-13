import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PROVIDERS, detectProviders, loginPath, providersFor, resetLoginPathCache } from './providers'

/**
 * `execFile` is replaced wholesale so the two platforms' *commands* can be
 * compared without either of them running. `promisify` prefers a function's
 * custom promisified form, so the mock carries one — without it `promisify`
 * wraps the mock callback-style and resolves with stdout alone, and every
 * `{ stdout }` destructure in the module under test throws.
 */
const calls = vi.hoisted(() => ({ ran: [] as Array<{ file: string; args: string[] }> }))

vi.mock('node:child_process', () => {
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
    args: string[],
  ): Promise<{ stdout: string; stderr: string }> => {
    calls.ran.push({ file, args })
    if (file === '/bin/zsh') return { stdout: '/opt/homebrew/bin:/usr/bin\n', stderr: '' }
    if (file === 'which') return { stdout: `/opt/homebrew/bin/${args[0]}\n`, stderr: '' }
    if (file === 'where.exe') return { stdout: `C:\\npm\\${args[0]}.cmd\r\n`, stderr: '' }
    return { stdout: '', stderr: '' }
  }
  return { execFile }
})

beforeEach(() => {
  calls.ran = []
  resetLoginPathCache()
})

afterEach(() => resetLoginPathCache())

describe('the provider table per platform', () => {
  const mac = providersFor('darwin', { SHELL: '/bin/zsh' })
  const win = providersFor('win32', { COMSPEC: 'C:\\Windows\\system32\\cmd.exe' })

  it('is unchanged on macOS', () => {
    expect(mac.claude.bin).toBe('claude')
    expect(mac.claude.resumeArgs).toEqual(['--continue'])
    expect(mac.shell.bin).toBe('/bin/zsh')
    expect(mac.shell.args).toEqual(['-l'])
    // Nothing wraps anything: the spawn is the binary itself.
    expect(mac.claude.spawn).toEqual({ command: 'claude', args: [], resumeArgs: ['--continue'] })
  })

  it('keeps `bin` the CLI’s own name on Windows', () => {
    // `prerequisites.ts` and `alerts.ts` look this up on PATH to answer "is it
    // installed". Replacing it with cmd.exe there would report every agent as
    // installed on every machine, which is a lie those panels exist to avoid.
    expect(win.claude.bin).toBe('claude')
    expect(win.codex.bin).toBe('codex')
    expect(win.gemini.bin).toBe('gemini')
  })

  it('spawns Windows agents through the command processor', () => {
    // An npm-installed `claude` on Windows is a .cmd shim, and node-pty hands
    // the command straight to CreateProcess, which will not run a batch file.
    expect(win.claude.spawn).toEqual({
      command: 'C:\\Windows\\system32\\cmd.exe',
      args: ['/c', 'claude'],
      resumeArgs: ['/c', 'claude', '--continue'],
    })
    expect(win.codex.spawn.resumeArgs).toEqual(['/c', 'codex', 'resume', '--last'])
  })

  it('leaves an empty resume list empty rather than half-built', () => {
    // gemini has no verified resume flag. `['/c','gemini']` here would silently
    // become "start a fresh session" wearing a resume label; `[]` is what the
    // caller already reads as "there is no resume path".
    expect(win.gemini.spawn.resumeArgs).toEqual([])
    expect(mac.gemini.resumeArgs).toEqual([])
  })

  it('gives Windows a shell it actually has', () => {
    // $SHELL is unset there and `-l` is not a flag cmd.exe knows.
    expect(win.shell.bin).toBe('C:\\Windows\\system32\\cmd.exe')
    expect(win.shell.args).toEqual([])
    expect(win.shell.spawn).toEqual({
      command: 'C:\\Windows\\system32\\cmd.exe',
      args: [],
      resumeArgs: [],
    })
  })

  it('falls back to cmd.exe when COMSPEC is missing', () => {
    expect(providersFor('win32', {}).shell.bin).toBe('cmd.exe')
  })

  it('exports the table for the platform this process is on', () => {
    expect(Object.keys(PROVIDERS).sort()).toEqual(['claude', 'codex', 'gemini', 'shell'])
  })
})

describe('the PATH a spawned CLI gets', () => {
  // $SHELL is pinned because the module reads it to decide which shell to ask,
  // and the mock answers for /bin/zsh. Left to the host this passes on a zsh
  // machine and fails on a bash one — which is exactly what it did: green
  // locally, red on the CI runner, where SHELL is bash and the call fell
  // through to the runner's own PATH.
  const realShell = process.env.SHELL
  beforeEach(() => {
    process.env.SHELL = '/bin/zsh'
  })
  afterEach(() => {
    if (realShell === undefined) delete process.env.SHELL
    else process.env.SHELL = realShell
  })

  it('asks the login shell on macOS', async () => {
    expect(await loginPath('darwin')).toBe('/opt/homebrew/bin:/usr/bin')
    expect(calls.ran).toEqual([{ file: '/bin/zsh', args: ['-lic', 'echo -n "$PATH"'] }])
  })

  it('spawns nothing on Windows and takes the environment’s own PATH', async () => {
    const answer = await loginPath('win32')
    expect(calls.ran).toEqual([])
    expect(answer).toBe(process.env.PATH ?? '')
  })
})

describe('detecting which agent CLIs are installed', () => {
  it('uses which on macOS', async () => {
    expect(await detectProviders('darwin')).toEqual({
      claude: true,
      codex: true,
      gemini: true,
      shell: true,
    })
    expect(calls.ran.filter((call) => call.file === 'which').map((call) => call.args[0]).sort()).toEqual([
      'claude',
      'codex',
      'gemini',
    ])
  })

  it('uses where.exe on Windows', async () => {
    // `which` is not a program there, so the macOS spelling reports every agent
    // as missing and quietly drops every session into a plain shell.
    expect(await detectProviders('win32')).toEqual({
      claude: true,
      codex: true,
      gemini: true,
      shell: true,
    })
    expect(calls.ran.every((call) => call.file === 'where.exe')).toBe(true)
  })

  it('never looks up the shell, which is always there', async () => {
    // The shell binary of the *Windows* table, which is what makes this assert
    // anything: looking up this Mac's `/bin/zsh` would satisfy a check written
    // against cmd.exe no matter what the code did.
    //
    // The environment is pinned for the same reason `$SHELL` is pinned above.
    // Reading `process.env` here took COMSPEC off the host, so the value was
    // `cmd.exe` on a Mac (nothing to read) and `C:\WINDOWS\system32\cmd.exe` on
    // Windows — green here, red there, over a fact about the runner rather than
    // about the code.
    const shell = providersFor('win32', { COMSPEC: 'C:\\Windows\\system32\\cmd.exe' }).shell.bin
    expect(shell).toBe('C:\\Windows\\system32\\cmd.exe')
    await detectProviders('win32')
    expect(calls.ran.map((call) => call.args[0])).not.toContain(shell)
    expect(calls.ran.map((call) => call.args[0]).sort()).toEqual(['claude', 'codex', 'gemini'])
  })
})
