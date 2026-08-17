import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  PROVIDERS,
  detectProviders,
  loginPath,
  providersFor,
  resetLoginPathCache,
  resolvedProvidersFor,
} from './providers'
import { resetAgentBinaryCache } from './agent-binaries'

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
    // `stdout` is widened to a Buffer because one caller genuinely asks for
    // one: the in-distro probe passes `encoding: 'buffer'` so it can decode
    // UTF-16LE by hand. Widening the fake is honest; casting a Buffer to a
    // string here would hide the very difference being exercised.
  ): Promise<{ stdout: string | Buffer; stderr: string }> => {
    calls.ran.push({ file, args })
    if (file === '/bin/zsh') return { stdout: '/opt/homebrew/bin:/usr/bin\n', stderr: '' }
    if (file === 'which') return { stdout: `/opt/homebrew/bin/${args[0]}\n`, stderr: '' }
    if (file === 'where.exe') return { stdout: `C:\\npm\\${args[0]}.cmd\r\n`, stderr: '' }
    // The in-distro probe. A Buffer rather than a string because that is what
    // the real call asks for — `wsl.exe` writes UTF-16LE for its own messages,
    // so the module decodes by hand — and because the answer is deliberately
    // *not* the whole table: this fake distro has Claude Code and Codex and no
    // Gemini, which is the only way the assertions below can tell a real read
    // from a hardcoded "everything is installed".
    //
    // The noise line is the point of the marker. Output comes back through an
    // interactive login shell, and a login shell prints whatever the user's
    // .bashrc prints.
    if (file === 'wsl.exe') {
      return {
        stdout: Buffer.from(
          'Welcome to Ubuntu 24.04 LTS\nagent-found:claude\nagent-found:codex\n',
          'utf8',
        ),
        stderr: '',
      }
    }
    return { stdout: '', stderr: '' }
  }
  return { execFile }
})

beforeEach(() => {
  calls.ran = []
  resetLoginPathCache()
  // `detectProviders` now runs each agent once to prove it starts, and that
  // answer is memoised for twenty seconds. Without this, the second test to ask
  // gets the first one's answer and finds `calls.ran` empty.
  resetAgentBinaryCache()
})

afterEach(() => {
  resetLoginPathCache()
  resetAgentBinaryCache()
})

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

  /**
   * Finding it is not enough — it has to start.
   *
   * The whole reason this function changed. `which codex` resolves on a machine
   * where the npm launcher's vendored binary is missing, so a lookup-only answer
   * reported Codex installed, the picker offered it, a PTY opened, and the user
   * read a Node `ENOENT` stack trace in a session they then had to close by
   * hand. Five times, in one recording.
   */
  it('runs each agent once, so a found-but-unstartable binary is not "installed"', async () => {
    await detectProviders('darwin')
    const versions = calls.ran.filter((call) => call.args[0] === '--version')
    expect(versions.map((call) => call.file).sort()).toEqual(['claude', 'codex', 'gemini'])
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
    // The *lookups* are all `where.exe`; the runnability probe then spawns what
    // the lookup found, which is the point of it.
    expect(
      calls.ran
        .filter((call) => call.args[0] !== '--version')
        .every((call) => call.file === 'where.exe'),
    ).toBe(true)
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
    expect(
      calls.ran
        .filter((call) => call.args[0] !== '--version')
        .map((call) => call.args[0])
        .sort(),
    ).toEqual(['claude', 'codex', 'gemini'])
    // Nor is it probed: a login shell has no `--version` and no need of one.
    expect(calls.ran.filter((call) => call.file === shell)).toEqual([])
  })

  /**
   * The spawn table points at whatever actually runs.
   *
   * `providersFor` stays pure and keeps answering `codex`; this is the version a
   * session start uses. On a healthy machine — which the mock is, since every
   * spawn resolves — the two are identical, and asserting that is the pin: a
   * change that started rewriting `spawn.command` unconditionally would break it
   * here rather than on somebody's machine.
   */
  it('resolves a spawn table that matches the pure one when nothing is broken', async () => {
    const resolved = await resolvedProvidersFor('darwin', { SHELL: '/bin/zsh' })
    expect(resolved.codex.spawn.command).toBe('codex')
    expect(resolved.claude.spawn).toEqual(providersFor('darwin', { SHELL: '/bin/zsh' }).claude.spawn)
  })

  /**
   * Inside WSL the command is a `wsl.exe` line whose payload the distribution's
   * own login shell resolves, so substituting a host path into it would name a
   * file that side cannot see.
   */
  it('leaves a WSL launch line alone', async () => {
    const target = { distro: 'Ubuntu', cwd: '/home/asad/proj' }
    const resolved = await resolvedProvidersFor('win32', { COMSPEC: 'cmd.exe' }, target)
    expect(resolved.codex.spawn.command).toBe('wsl.exe')
  })
})

/* ================================================================== wsl == */

/**
 * The Windows-inside-Linux table.
 *
 * Every assertion below is pinned from a Mac, which is the only way it can be
 * pinned at all: `wsl.exe` does not exist here and CI is macOS-only by policy.
 * That is exactly the situation the `cmd.exe` table above is in, and the reason
 * both are written this way — the alternative is a branch whose first reader is
 * a user, which is how the `PATH`/`Path` class of bug ships.
 */
describe('the provider table inside a distribution', () => {
  const target = { distro: 'Ubuntu', cwd: '/home/asad/proj' }
  const env = { COMSPEC: 'C:\\Windows\\system32\\cmd.exe', USERPROFILE: 'C:\\Users\\Asad' }
  const wsl = providersFor('win32', env, target)

  it('launches wsl.exe, not cmd.exe', () => {
    // The reported bug in one assertion: cmd.exe cannot see a `claude` installed
    // inside Ubuntu, and cannot take the folder as a working directory either.
    expect(wsl.claude.spawn.command).toBe('wsl.exe')
    expect(wsl.claude.spawn.args.slice(0, 5)).toEqual([
      '-d',
      'Ubuntu',
      '--cd',
      '/home/asad/proj',
      '-e',
    ])
  })

  it('runs the agent through the distribution’s own login shell', () => {
    // `wsl.exe -d Ubuntu -- claude` finds nothing when claude came from nvm:
    // nvm is set up in ~/.bashrc and ~/.bashrc returns immediately for a
    // non-interactive shell. The last argument is the command that shell runs.
    const args = wsl.claude.spawn.args
    expect(args).toContain('sh')
    expect(args[args.length - 1]).toBe('exec claude')
    expect(wsl.claude.spawn.resumeArgs[wsl.claude.spawn.resumeArgs.length - 1]).toBe(
      'exec claude --continue',
    )
  })

  it('starts the Windows process somewhere Windows has', () => {
    // node-pty resolves the cwd it is given: path.win32.resolve of a Linux path
    // is C:\home\asad\proj, which does not exist, and the tab dies silently.
    expect(wsl.claude.spawn.hostCwd).toBe('C:\\Users\\Asad')
    expect(wsl.shell.spawn.hostCwd).toBe('C:\\Users\\Asad')
  })

  it('keeps `bin` the CLI’s own name, which is the same on both sides', () => {
    expect(wsl.claude.bin).toBe('claude')
    expect(wsl.codex.bin).toBe('codex')
  })

  it('leaves an empty resume list empty rather than half-built', () => {
    // Same rule as the cmd.exe branch: a resume that silently starts a fresh
    // session is worse than no resume at all.
    expect(wsl.gemini.spawn.resumeArgs).toEqual([])
  })

  it('gives the shell tab the distribution’s login shell, not cmd.exe', () => {
    expect(wsl.shell.spawn.command).toBe('wsl.exe')
    expect(wsl.shell.spawn.args[wsl.shell.spawn.args.length - 1]).toBe('')
    expect(wsl.shell.bin).not.toBe(env.COMSPEC)
  })

  it('omits -d when nobody has chosen a distribution', () => {
    // What makes a session work before the probe has answered and before anybody
    // has opened settings: wsl.exe uses the machine's own default.
    const unchosen = providersFor('win32', env, { distro: null, cwd: '/home/asad' })
    expect(unchosen.claude.spawn.args.slice(0, 3)).toEqual(['--cd', '/home/asad', '-e'])
  })

  it('ignores a WSL target on a platform that has no wsl.exe', () => {
    // Honouring one on macOS would build a table that cannot spawn at all.
    const mac = providersFor('darwin', { SHELL: '/bin/zsh' }, target)
    expect(mac.claude.spawn).toEqual({ command: 'claude', args: [], resumeArgs: ['--continue'] })
    expect(mac.claude.spawn.hostCwd).toBeUndefined()
  })
})

describe('detecting agents inside a distribution', () => {
  const target = { distro: 'Ubuntu', cwd: '/home/asad/proj' }

  it('asks the distribution, not Windows', async () => {
    // The whole bug: `where.exe claude` on a machine where claude lives in
    // Ubuntu answers "not found", every agent is reported missing, and every
    // session quietly becomes a cmd.exe shell.
    const found = await detectProviders('win32', target)
    expect(found).toEqual({ claude: true, codex: true, gemini: false, shell: true })
    expect(calls.ran.every((call) => call.file === 'wsl.exe')).toBe(true)
  })

  it('spends one round trip on the whole table, not one per agent', async () => {
    // Each call has to start a login shell inside the distro, and a sleeping
    // distro has to boot a virtual machine first. Three of those is three times
    // the largest cost on the New Session path.
    await detectProviders('win32', target)
    expect(calls.ran.length).toBe(1)
  })

  it('reads only its own marked lines, so a chatty .bashrc cannot answer for it', async () => {
    // The fake distro prints a welcome banner first. Taking the first non-empty
    // line — which is what the Windows and macOS paths do with `where`/`which` —
    // would read somebody's motd as the location of Claude Code.
    const found = await detectProviders('win32', target)
    expect(found.gemini).toBe(false)
  })

  it('asks about the folder’s side only when there is a target', async () => {
    // No target means the Windows question, unchanged — every *lookup* through
    // `where.exe`, and nothing through `wsl.exe`. The runnability probe then
    // spawns what the lookup found, which is a different call and not one this
    // case is about.
    await detectProviders('win32')
    expect(
      calls.ran
        .filter((call) => call.args[0] !== '--version')
        .every((call) => call.file === 'where.exe'),
    ).toBe(true)
    expect(calls.ran.some((call) => call.file === 'wsl.exe')).toBe(false)
  })

  it('never claims the shell is missing', async () => {
    // wsl.exe resolves the user's login shell on the far side; a distribution
    // without one is not a distribution.
    expect((await detectProviders('win32', target)).shell).toBe(true)
  })
})

describe('the probe command itself', () => {
  it('carries no raw line break across the command line', async () => {
    // The whole probe travels as one Windows command-line argument. A real
    // newline inside one survives by accident rather than by design; the two
    // characters `\n` are what `printf` turns into a line break on the far side,
    // which is where the line break belongs.
    await detectProviders('win32', { distro: 'Ubuntu', cwd: '/home/asad' })
    const inner = calls.ran[0].args[calls.ran[0].args.length - 1]
    expect(inner).not.toContain('\n')
    expect(inner).toContain('\\n')
    // And it asks about every agent in one loop rather than three lookups.
    expect(inner).toContain('for n in claude codex gemini')
  })
})
