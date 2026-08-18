import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  PROVIDERS,
  detectProviders,
  loginPath,
  markedNames,
  providersFor,
  resetLoginPathCache,
  resolvedProvidersFor,
  withLaunchArgs,
} from './providers'
import { resetAgentBinaryCache } from './agent-binaries'
// The two resolvers the Windows branch of the table now goes through. Asserted
// against rather than restated as literals: a literal Windows path in a test is
// green on the platform the feature does not run on and red on the one it does.
import { windowsShellPath, wslExePath } from './wsl'

/**
 * `execFile` is replaced wholesale so the two platforms' *commands* can be
 * compared without either of them running. `promisify` prefers a function's
 * custom promisified form, so the mock carries one — without it `promisify`
 * wraps the mock callback-style and resolves with stdout alone, and every
 * `{ stdout }` destructure in the module under test throws.
 */
const calls = vi.hoisted(() => ({
  ran: [] as Array<{ file: string; args: string[] }>,
  /**
   * Make the in-distro probe fail the way a real one does.
   *
   * Measured on `DESKTOP-DDGMNCV`: the probe printed `agent-found:claude` and
   * `execFile` still rejected, because a login shell exits with the status of
   * its last command and the last command is `command -v` for the last name in
   * the list. On a machine with Claude Code and no Gemini that is every probe.
   * `stdout` on the rejection is where the answer actually was.
   */
  wslFails: false,
}))

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
    //
    // `endsWith`, not `===`: the command is resolved to an absolute path when
    // one can be found, so on a Windows runner this is
    // `C:\Windows\System32\wsl.exe` and an exact match would silently make every
    // in-distro assertion below meaningless on the one platform they are about.
    if (file.endsWith('wsl.exe')) {
      const stdout = Buffer.from(
        'Welcome to Ubuntu 24.04 LTS\nagent-found:claude\nagent-found:codex\n',
        'utf8',
      )
      if (calls.wslFails) {
        // Shaped like a real `execFile` rejection: the output it managed to
        // produce is hung on the error object, which is the whole point.
        throw Object.assign(new Error('Command failed: wsl.exe …'), { code: 1, stdout, stderr: '' })
      }
      return { stdout, stderr: '' }
    }
    return { stdout: '', stderr: '' }
  }
  return { execFile }
})

beforeEach(() => {
  calls.ran = []
  calls.wslFails = false
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
    /*
     * `windowsShellPath({})`, not the literal `'cmd.exe'`, and for the reason
     * the comment further down this file already spells out about `COMSPEC`:
     * the fallback resolves `%SystemRoot%\System32\cmd.exe` when that file is
     * there, so a literal is green on a Mac and red on Windows over a fact about
     * the runner rather than about the code. What matters is that the fallback
     * still names the command processor, and that it is what the table uses.
     */
    expect(providersFor('win32', {}).shell.bin).toBe(windowsShellPath({}))
    expect(providersFor('win32', {}).shell.bin.endsWith('cmd.exe')).toBe(true)
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
    //
    // `wslExePath(env)`, not the literal `'wsl.exe'`. The command is resolved to
    // an absolute path wherever one can be found, so a literal here is an
    // assertion that only holds on a host with no `System32\wsl.exe` — i.e. on
    // every machine except the one the feature runs on. `wsl.test.ts` pins the
    // resolution itself; what this pins is that the table goes through it.
    expect(wsl.claude.spawn.command).toBe(wslExePath(env))
    expect(wsl.claude.spawn.command.endsWith('wsl.exe')).toBe(true)
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
    expect(wsl.shell.spawn.command).toBe(wslExePath(env))
    expect(wsl.shell.spawn.args[wsl.shell.spawn.args.length - 1]).toBe('')
    expect(wsl.shell.bin).not.toBe(env.COMSPEC)
  })

  it('keeps `bin` the name and `spawn.command` the path, which are not the same string', () => {
    /*
     * The one place these two were quietly identical, and the reason a WSL
     * session could not be restarted after a reboot.
     *
     * `bin` answers "what opens a shell on this machine" — the name a person
     * would type, and what a lookup would use. `spawn.command` is handed to a
     * pty, and there a *relative* name is resolved by node-pty against the app's
     * own working directory first: `get_shell_path` returns an empty string when
     * that directory contains a file of the same name, and `conpty.cc` reports
     * the empty string as "File not found: " with nothing after the colon.
     * `C:\Windows\System32` holds `wsl.exe` and is the working directory of any
     * launch that did not choose one. `wsl.ts`'s `wslExePath` carries the
     * measurement taken on `DESKTOP-DDGMNCV`.
     */
    expect(wsl.shell.bin).toBe('wsl.exe')
    expect(wsl.shell.spawn.command).toBe(wslExePath(env))
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
    // `endsWith`: the command is an absolute path wherever one resolves.
    expect(calls.ran.every((call) => call.file.endsWith('wsl.exe'))).toBe(true)
  })

  it('believes what the probe printed even when the probe exited non-zero', async () => {
    /*
     * The defect this pins was measured on `DESKTOP-DDGMNCV` on 2026-08-17, by
     * running this module's own command line by hand against the machine's own
     * Ubuntu-24.04:
     *
     *     stdout: "agent-found:claude\n"
     *     err:    { message: 'Command failed: …', code: 1, killed: false }
     *
     * The probe **found Claude Code** and the app reported the distribution as
     * having none, because `execFile` rejects on a non-zero exit and the `catch`
     * threw the answer away with the error.
     *
     * And the status had nothing to do with the question. A login shell exits
     * with the status of its last command; the last command is `command -v` for
     * the last name in the list; so whenever the last agent asked about is not
     * installed — Claude Code and no Gemini, which is his machine and the
     * ordinary case — the whole probe was discarded. Every WSL session on that
     * PC then fell to the shell fallback, which is how a day's conversations
     * became bare terminals.
     */
    calls.wslFails = true
    const found = await detectProviders('win32', target)
    expect(found).toEqual({ claude: true, codex: true, gemini: false, shell: true })
  })

  it('stops the question reporting the last name’s status as its own', async () => {
    // The other half, and the one that keeps the ordinary case ordinary: the
    // script ends deterministically rather than with whatever `command -v` said
    // about the last agent in the list.
    await detectProviders('win32', target)
    const inner = calls.ran[0].args[calls.ran[0].args.length - 1]
    expect(inner.trimEnd().endsWith('exit 0')).toBe(true)
  })

  it('answers "none" when there is genuinely nothing to read', async () => {
    // A distro that is missing, refuses to start, or times out before printing
    // anything. The rejection carries no stdout, and inventing agents from an
    // empty answer is the opposite mistake.
    expect(markedNames(undefined)).toEqual(new Set())
    expect(markedNames(Buffer.alloc(0))).toEqual(new Set())
    expect(markedNames(Buffer.from('Welcome to Ubuntu 24.04 LTS\n', 'utf8'))).toEqual(new Set())
  })

  it('reads the UTF-16LE wsl.exe writes for its own messages', async () => {
    // `wsl.exe` writes its own output as UTF-16LE with a BOM; reading that as
    // utf8 is how a working distro reports nothing installed.
    const utf16 = Buffer.from('﻿agent-found:claude\r\n', 'utf16le')
    expect(markedNames(utf16)).toEqual(new Set(['claude']))
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

/**
 * Flags a particular launch adds, on all three launch shapes.
 *
 * One caller: the copilot, spawned with `--mcp-config <file>
 * --strict-mcp-config`, which is the only way a Claude CLI process can be given
 * the `deck-control` tools at all. Before this existed there was nowhere on the
 * spawn path to put a flag, so the copilot had none of this app's tools and
 * every claim about tiers and confirmations described a gate that was not in the
 * path.
 *
 * The WSL case is the reason this is a function rather than a spread at the call
 * site, and it is the case nobody here can run: inside a distribution
 * `spawn.args` is a `wsl.exe` invocation whose last element is a quoted shell
 * command *line*, so appending to it hands the flags to the login shell as
 * positional parameters and the CLI never sees them. It would have worked on
 * this machine, worked in CI, and been wrong only for the person whose projects
 * live in Ubuntu.
 */
describe('extra launch arguments', () => {
  const MCP = ['--mcp-config', '/state/copilot/deck-control.json', '--strict-mcp-config']

  it('appends them to the agent’s own arguments on a POSIX spawn', () => {
    const mac = providersFor('darwin', { SHELL: '/bin/zsh' })
    const withTools = withLaunchArgs(mac.claude, MCP, 'darwin', { SHELL: '/bin/zsh' })
    expect(withTools.spawn.command).toBe('claude')
    expect(withTools.spawn.args).toEqual(MCP)
    expect(withTools.spawn.resumeArgs).toEqual(['--continue', ...MCP])
  })

  it('puts them after the CLI on the Windows command processor, not after cmd', () => {
    const env = { COMSPEC: 'C:\\Windows\\system32\\cmd.exe' }
    const win = providersFor('win32', env)
    const withTools = withLaunchArgs(win.claude, MCP, 'win32', env)
    expect(withTools.spawn.command).toBe(env.COMSPEC)
    expect(withTools.spawn.args).toEqual(['/c', 'claude', ...MCP])
  })

  it('folds them into the shell command line inside a distribution', () => {
    const env = { COMSPEC: 'C:\\Windows\\system32\\cmd.exe', USERPROFILE: 'C:\\Users\\Asad' }
    const target = { distro: 'Ubuntu', cwd: '/home/asad/proj' }
    const withTools = withLaunchArgs(providersFor('win32', env, target).claude, MCP, 'win32', env, target)
    const args = withTools.spawn.args
    // The flags are *inside* the quoted command the login shell runs — the last
    // element — rather than trailing after it, where `sh -lc '<cmd>' --flag`
    // would make them the shell's positional parameters.
    expect(args[args.length - 1]).toBe(
      "exec claude --mcp-config /state/copilot/deck-control.json --strict-mcp-config",
    )
    expect(withTools.spawn.command).toBe('wsl.exe')
    // The Windows-side working directory survives the rebuild; without it
    // node-pty resolves the Linux path to `C:\home\asad\proj` and the tab dies.
    expect(withTools.spawn.hostCwd).toBe('C:\\Users\\Asad')
  })

  it('leaves an empty resume list empty rather than inventing a resume flag', () => {
    // `startSession` reads a zero-length `resumeArgs` as "this agent cannot
    // continue a conversation" and falls back to the start arguments. Filling
    // it in here would make a resume silently start a fresh session.
    const mac = providersFor('darwin', { SHELL: '/bin/zsh' })
    expect(withLaunchArgs(mac.gemini, MCP, 'darwin', { SHELL: '/bin/zsh' }).spawn.resumeArgs).toEqual([])
  })

  it('hands back the very same spec when there is nothing to add', () => {
    // The ordinary case — every session that is not the copilot — must not pay
    // for this, and must not get a rebuilt spec that could differ in any field.
    const mac = providersFor('darwin', { SHELL: '/bin/zsh' })
    expect(withLaunchArgs(mac.claude, [], 'darwin', { SHELL: '/bin/zsh' })).toBe(mac.claude)
  })

  it('keeps a command that was resolved to a working copy of the CLI', async () => {
    /*
     * `resolvedProvidersFor` points `spawn.command` at an absolute path when the
     * bare name on PATH will not execute — the npm `@openai/codex` launcher
     * failing to spawn its own missing native binary, which cost a recording.
     * Rebuilding the spec from `bin` here would quietly undo that.
     */
    const resolved = await resolvedProvidersFor('darwin', { SHELL: '/bin/zsh' })
    const pointed = { ...resolved.claude, spawn: { ...resolved.claude.spawn, command: '/opt/claude/bin/claude' } }
    const withTools = withLaunchArgs(pointed, MCP, 'darwin', { SHELL: '/bin/zsh' })
    expect(withTools.spawn.command).toBe('/opt/claude/bin/claude')
  })
})
