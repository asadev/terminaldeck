import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import {
  APPLIANCE_DISTROS,
  IN_DISTRO_TIMEOUT_MS,
  LOGIN_SHELL_SCRIPT,
  WSL_CHOOSE_CHANNEL,
  WSL_STATUS_CHANNEL,
  WslLink,
  chooseDistro,
  decodeWslOutput,
  isApplianceDistro,
  isLinuxPath,
  linuxPathFromUnc,
  parseDistroTable,
  parseNameList,
  readWsl,
  registerWslIpc,
  shellCommandLine,
  shellQuote,
  windowsFallbackCwd,
  wslEnvBridge,
  wslLaunch,
  wslUncPath,
  type WslExec,
  type WslRun,
  type WslStore,
} from './wsl'

/**
 * Every Windows answer in this file is pinned from a Mac, and that is the whole
 * reason the file exists.
 *
 * `wsl.exe` cannot be run here — CI is macOS-only by policy — so the choice is
 * between shipping this untested and testing the *shape* against output taken
 * from a real Windows machine. The second is what `providers.test.ts` already
 * does for the `cmd.exe` table, and the bug it is guarding against is the one
 * that shipped last time: a Windows branch nothing could reach, whose first
 * reader was a user.
 *
 * The fixtures below are the genuine article in two respects that matter more
 * than they look: they are **UTF-16LE with a byte-order mark**, because that is
 * what `wsl.exe` writes, and one of them is localised, because the STATE column
 * is translated and anchoring on the word "Running" works on exactly one
 * machine.
 */

/** What `wsl.exe` actually puts on the pipe: UTF-16LE, with a BOM. */
function wslBytes(text: string): Buffer {
  return Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')])
}

const LIST_OUTPUT = [
  '  NAME                   STATE           VERSION',
  '* Ubuntu                 Running         2',
  '  Debian                 Stopped         2',
  '  docker-desktop         Stopped         2',
  '',
].join('\r\n')

/** The same table on a German Windows, where the state is two words. */
const GERMAN_LIST = [
  '  NAME                   STATUS            VERSION',
  '* Ubuntu                 Wird ausgeführt   2',
  '  Debian                 Beendet           2',
  '',
].join('\r\n')

const ok = (stdout: Buffer, stderr = Buffer.alloc(0)): WslRun => ({
  ok: true,
  stdout,
  stderr,
  code: 0,
})

const failed = (code: number | string, stderr: Buffer): WslRun => ({
  ok: false,
  stdout: Buffer.alloc(0),
  stderr,
  code,
})

/** An exec that answers from a table keyed on the joined argument list. */
function fakeExec(answers: Record<string, WslRun>, seen: string[][] = []): WslExec {
  return async (args) => {
    seen.push([...args])
    return answers[args.join(' ')] ?? failed(1, wslBytes('unexpected call'))
  }
}

/**
 * Register the channels against an ordinary object and hand back what they are.
 *
 * No cast: `registerWslIpc` asks for the one method it uses rather than the
 * whole of Electron's `IpcMain`, which is what lets a plain object stand in — and
 * what keeps the channel names in this file the same strings the preload calls,
 * rather than a mock's idea of them.
 */
type Handler = (event: unknown, ...args: unknown[]) => unknown
function fakeIpc(link: WslLink): Map<string, Handler> {
  const handlers = new Map<string, Handler>()
  registerWslIpc(
    {
      handle: (channel, listener) => {
        handlers.set(channel, listener)
      },
    },
    link,
  )
  return handlers
}

/* ============================================================== decoding == */

describe('reading what wsl.exe wrote', () => {
  it('decodes UTF-16LE, which is what every other command in this app is not', () => {
    // The failure being guarded: read as utf8 this is `U\0b\0u\0n\0t\0u\0`,
    // which splits into lines cleanly, matches no pattern, and reports a machine
    // with four distributions as having none.
    expect(decodeWslOutput(wslBytes('Ubuntu\r\n'))).toBe('Ubuntu\r\n')
  })

  it('decodes UTF-16LE that arrived without a byte-order mark', () => {
    expect(decodeWslOutput(Buffer.from('Ubuntu\r\n', 'utf16le'))).toBe('Ubuntu\r\n')
  })

  it('leaves plain UTF-8 alone, because some wsl.exe output is', () => {
    // Passthrough from a Linux process is UTF-8. Decoding *that* as UTF-16
    // produces the same unusable mush in the other direction.
    expect(decodeWslOutput(Buffer.from('/home/asad/.nvm/bin/claude\n', 'utf8'))).toBe(
      '/home/asad/.nvm/bin/claude\n',
    )
  })

  it('keeps non-ASCII UTF-8 intact rather than sniffing it as UTF-16', () => {
    expect(decodeWslOutput(Buffer.from('gestoppt — läuft\n', 'utf8'))).toBe('gestoppt — läuft\n')
  })

  it('says nothing about an empty buffer instead of guessing', () => {
    expect(decodeWslOutput(Buffer.alloc(0))).toBe('')
  })
})

/* =============================================================== parsing == */

describe('the distribution table', () => {
  it('reads names, versions and the default marker', () => {
    const rows = parseDistroTable(LIST_OUTPUT)
    expect(rows.map((row) => row.name)).toEqual(['Ubuntu', 'Debian', 'docker-desktop'])
    expect(rows[0].isDefault).toBe(true)
    expect(rows[1].isDefault).toBe(false)
    expect(rows[0].version).toBe(2)
  })

  it('reads a machine whose Windows is not in English', () => {
    // Real German output. `Wird ausgeführt` is *two words*, so "the state is one
    // token" — the obvious rule — reads this row as a distribution called
    // "Ubuntu Wird". The columns are measured from the header instead, and the
    // header's own words are never looked at.
    const rows = parseDistroTable(GERMAN_LIST)
    expect(rows.map((row) => row.name)).toEqual(['Ubuntu', 'Debian'])
    expect(rows[0].isDefault).toBe(true)
    expect(rows[0].state).toBe('Wird ausgeführt')
  })

  it('keeps a distribution name that contains spaces', () => {
    // An imported distro can be called anything; the state and the version
    // never can, which is why the columns are read from the right.
    const rows = parseDistroTable('  NAME  STATE  VERSION\n* Ubuntu 22.04 LTS   Running   2\n')
    expect(rows[0].name).toBe('Ubuntu 22.04 LTS')
    expect(rows[0].version).toBe(2)
  })

  it('ignores blank lines and stray NULs left by a bad decode', () => {
    expect(parseDistroTable('\r\n\r\n')).toEqual([])
  })

  it('reads a -q listing as plain names', () => {
    expect(parseNameList('Ubuntu\r\nDebian\r\n\r\n')).toEqual(['Ubuntu', 'Debian'])
  })
})

describe('appliance distributions', () => {
  it('knows Docker Desktop’s are not places to work', () => {
    // Installing Docker Desktop registers these, and on a machine with nothing
    // else Docker's is the one wsl.exe marks default — so adopting it would run
    // every session inside a container appliance with no home directory.
    expect(isApplianceDistro('docker-desktop')).toBe(true)
    expect(isApplianceDistro('Docker-Desktop-Data')).toBe(true)
    expect(isApplianceDistro('Ubuntu')).toBe(false)
    expect(APPLIANCE_DISTROS).toContain('docker-desktop')
  })
})

/* ================================================================= probe == */

describe('reading the machine', () => {
  const listArgs = '-l -v'
  const runningArgs = '-l --running -q'

  it('lists what is installed and which of it is awake', async () => {
    const reading = await readWsl(
      fakeExec({
        [listArgs]: ok(wslBytes(LIST_OUTPUT)),
        [runningArgs]: ok(wslBytes('Ubuntu\r\n')),
      }),
    )
    expect(reading.state).toBe('ready')
    expect(reading.distros.map((entry) => entry.name)).toEqual(['Ubuntu', 'Debian'])
    expect(reading.distros[0].running).toBe(true)
    expect(reading.distros[1].running).toBe(false)
  })

  it('never decides "running" from the STATE column', async () => {
    // Same machine, German Windows. The English word is nowhere on the screen
    // and the answer must not change, because `--running` prints names and names
    // are not translated.
    const reading = await readWsl(
      fakeExec({
        [listArgs]: ok(wslBytes(GERMAN_LIST)),
        [runningArgs]: ok(wslBytes('Ubuntu\r\n')),
      }),
    )
    expect(reading.distros[0].running).toBe(true)
    expect(reading.distros[1].running).toBe(false)
  })

  it('says "absent" when there is no wsl.exe at all', async () => {
    const reading = await readWsl(
      fakeExec({ [listArgs]: failed('ENOENT', Buffer.alloc(0)), [runningArgs]: failed('ENOENT', Buffer.alloc(0)) }),
    )
    expect(reading).toEqual({ state: 'absent', distros: [], detail: null })
  })

  it('says "no distros" when WSL is installed with nothing in it, and quotes Windows', async () => {
    const said = 'Windows Subsystem for Linux has no installed distributions.'
    const reading = await readWsl(
      fakeExec({
        [listArgs]: failed(1, wslBytes(said)),
        [runningArgs]: failed(1, wslBytes(said)),
      }),
    )
    expect(reading.state).toBe('no-distros')
    // Its own sentence, not one invented here: the real messages name the actual
    // problem ("the Virtual Machine Platform feature is not enabled") and a
    // summary would throw away the only accurate thing on the screen.
    expect(reading.detail).toBe(said)
  })

  it('treats a machine with only Docker’s distributions as having none', async () => {
    const dockerOnly = [
      '  NAME                   STATE           VERSION',
      '* docker-desktop         Running         2',
      '  docker-desktop-data    Running         2',
    ].join('\r\n')
    const reading = await readWsl(
      fakeExec({
        [listArgs]: ok(wslBytes(dockerOnly)),
        [runningArgs]: ok(wslBytes('docker-desktop\r\n')),
      }),
    )
    expect(reading.state).toBe('no-distros')
    expect(reading.distros).toEqual([])
  })

  it('still lists distributions when the running check fails', async () => {
    // Not knowing what is awake costs a line of copy. Refusing to list anything
    // over it would cost the whole feature.
    const reading = await readWsl(
      fakeExec({
        [listArgs]: ok(wslBytes(LIST_OUTPUT)),
        [runningArgs]: failed(1, wslBytes('nope')),
      }),
    )
    expect(reading.state).toBe('ready')
    expect(reading.distros.every((entry) => !entry.running)).toBe(true)
  })

  it('does not report the column header as something Windows said', async () => {
    const reading = await readWsl(
      fakeExec({
        [listArgs]: ok(wslBytes(LIST_OUTPUT)),
        [runningArgs]: ok(wslBytes('')),
      }),
    )
    expect(reading.detail).toBeNull()
  })

  it('starts nothing: only the two list commands are ever run', async () => {
    const seen: string[][] = []
    await readWsl(
      fakeExec({ [listArgs]: ok(wslBytes(LIST_OUTPUT)), [runningArgs]: ok(wslBytes('')) }, seen),
    )
    // `-l` reads a registry list. Anything with `-d` in it would boot a virtual
    // machine, and this runs at launch.
    expect(seen.every((args) => !args.includes('-d'))).toBe(true)
  })
})

describe('which distribution a session uses', () => {
  const installed = [
    { name: 'Ubuntu', version: 2, running: true, isDefault: true },
    { name: 'Debian', version: 2, running: false, isDefault: false },
  ]

  it('honours the stored choice', () => {
    expect(chooseDistro(installed, 'Debian')).toBe('Debian')
  })

  it('ignores a stored choice that is no longer installed', () => {
    // Otherwise every session fails with wsl.exe's own "there is no distribution
    // with the supplied name", naming one the settings pane never showed.
    expect(chooseDistro(installed, 'Fedora')).toBe('Ubuntu')
  })

  it('falls back to the machine’s own default, then to the first', () => {
    expect(chooseDistro(installed, null)).toBe('Ubuntu')
    expect(chooseDistro([installed[1]], null)).toBe('Debian')
  })

  it('answers null when nothing is installed, which means "let wsl.exe decide"', () => {
    expect(chooseDistro([], null)).toBeNull()
  })
})

/* ================================================================= paths == */

describe('telling the two filesystems apart', () => {
  it('calls a leading slash Linux and everything else Windows', () => {
    expect(isLinuxPath('/home/asad/proj')).toBe(true)
    expect(isLinuxPath('/mnt/c/Users/Asad')).toBe(true)
    expect(isLinuxPath('C:\\Users\\Asad\\proj')).toBe(false)
    expect(isLinuxPath('\\\\wsl.localhost\\Ubuntu\\home')).toBe(false)
  })

  it('translates the UNC path Explorer’s folder dialog hands back', () => {
    // This is what makes the ordinary picker usable: the distro is in Explorer's
    // sidebar, so a person browsing to their project returns a UNC path — which
    // cmd.exe refuses as a working directory, and which would route the session
    // to the wrong side of the boundary if it were stored.
    expect(linuxPathFromUnc('\\\\wsl.localhost\\Ubuntu\\home\\asad\\proj')).toEqual({
      distro: 'Ubuntu',
      path: '/home/asad/proj',
    })
  })

  it('accepts the older wsl$ spelling and a forward-slash one', () => {
    expect(linuxPathFromUnc('\\\\wsl$\\Debian\\srv\\app')).toEqual({
      distro: 'Debian',
      path: '/srv/app',
    })
    expect(linuxPathFromUnc('//wsl.localhost/Ubuntu/home/asad')?.path).toBe('/home/asad')
  })

  it('reads the distribution root as /', () => {
    expect(linuxPathFromUnc('\\\\wsl.localhost\\Ubuntu')).toEqual({ distro: 'Ubuntu', path: '/' })
  })

  it('leaves an ordinary Windows path alone', () => {
    expect(linuxPathFromUnc('C:\\Users\\Asad\\proj')).toBeNull()
    expect(linuxPathFromUnc('\\\\fileserver\\share\\proj')).toBeNull()
  })

  it('builds the path a Windows API can stat, and round-trips it', () => {
    const unc = wslUncPath('Ubuntu', '/home/asad/proj')
    expect(unc).toBe('\\\\wsl.localhost\\Ubuntu\\home\\asad\\proj')
    expect(linuxPathFromUnc(unc)).toEqual({ distro: 'Ubuntu', path: '/home/asad/proj' })
  })

  it('starts the Windows process somewhere that exists', () => {
    // node-pty runs path.resolve() on the cwd it is given, and
    // path.win32.resolve('/home/asad/proj') is C:\home\asad\proj — a directory
    // that is not there, so the tab dies before printing anything.
    expect(windowsFallbackCwd({ USERPROFILE: 'C:\\Users\\Asad' })).toBe('C:\\Users\\Asad')
    expect(windowsFallbackCwd({ SystemRoot: 'C:\\Windows' })).toBe('C:\\Windows')
    expect(windowsFallbackCwd({})).not.toBe('')
  })
})

/* =============================================================== launching == */

describe('the wsl.exe command line', () => {
  const env = { USERPROFILE: 'C:\\Users\\Asad' }

  it('names the distribution, the Linux directory, and the login shell', () => {
    const launch = wslLaunch({ distro: 'Ubuntu', cwd: '/home/asad/proj', inner: 'exec claude', env })
    expect(launch.command).toBe('wsl.exe')
    expect(launch.args).toEqual([
      '-d',
      'Ubuntu',
      '--cd',
      '/home/asad/proj',
      '-e',
      'sh',
      '-c',
      LOGIN_SHELL_SCRIPT,
      'wsl-login',
      'exec claude',
    ])
  })

  it('never puts the Linux directory where node-pty would resolve it', () => {
    // The Linux path travels in --cd; the *process* starts in a Windows folder.
    const launch = wslLaunch({ distro: 'Ubuntu', cwd: '/home/asad/proj', inner: '', env })
    expect(launch.hostCwd).toBe('C:\\Users\\Asad')
    expect(launch.hostCwd.startsWith('/')).toBe(false)
  })

  it('omits -d when nobody has chosen, letting wsl.exe use its own default', () => {
    // This is what makes a session work before the probe has come back and
    // before anyone has opened settings.
    const launch = wslLaunch({ distro: null, cwd: '/home/asad', inner: '', env })
    expect(launch.args.slice(0, 3)).toEqual(['--cd', '/home/asad', '-e'])
  })

  it('never hands --cd a Windows path', () => {
    // wsl.exe would translate it, which is the crossing this module exists to
    // avoid — the session would run against /mnt/c over a slow boundary.
    const launch = wslLaunch({ distro: 'Ubuntu', cwd: 'C:\\Users\\Asad', inner: '', env })
    expect(launch.args).not.toContain('--cd')
  })

  it('runs a bare login shell for an empty command', () => {
    const launch = wslLaunch({ distro: 'Ubuntu', cwd: '/home/asad', inner: '', env })
    expect(launch.args[launch.args.length - 1]).toBe('')
  })

  it('goes through an interactive login shell, which is the whole point', () => {
    // `wsl.exe -d Ubuntu -- claude` does not work for an nvm install: nvm is set
    // up in ~/.bashrc, and ~/.bashrc returns immediately for a non-interactive
    // shell. Only -lic reads it. This is the same deficit providers.ts already
    // documents for GUI apps on macOS, one boundary further in.
    expect(LOGIN_SHELL_SCRIPT).toContain('-lic')
    expect(LOGIN_SHELL_SCRIPT).toContain('getent passwd')
    // Never hard-codes bash: Alpine ships none, and $SHELL is not reliably set
    // for a command wsl.exe launches.
    expect(LOGIN_SHELL_SCRIPT).toContain('/bin/sh')
  })

  it('execs the command instead of handing a command line to a second shell', () => {
    // `--` passes the remaining command line on to the distribution's default
    // shell, which parses everything a second time — and the bootstrap contains
    // `$(id -un)`, which that outer shell would expand instead of leaving for
    // the login shell. `-e` execs, so every element arrives as its own argv
    // entry exactly as written. A tidy-up back to `--` is a quoting bug that
    // would only show up on a machine none of us has.
    const launch = wslLaunch({ distro: 'Ubuntu', cwd: '/home/asad', inner: '', env: {} })
    expect(launch.args).toContain('-e')
    expect(launch.args).not.toContain('--')
    expect(LOGIN_SHELL_SCRIPT).toContain('$(id -un)')
  })

  it('allows long enough for a sleeping distribution to boot', () => {
    // A stopped WSL2 distribution is a virtual machine, and the first command
    // into one waits for it to start. A tight timeout here does not fail
    // loudly — it reports "Claude Code is not installed", and the session
    // silently becomes a plain shell, which is the exact downgrade this whole
    // module exists to stop.
    expect(IN_DISTRO_TIMEOUT_MS).toBeGreaterThanOrEqual(20_000)
  })

  it('passes the command as an argument rather than pasting it into the script', () => {
    // What keeps the quoting one level deep. The script is a constant with no
    // user data in it; the command is a separate argv entry wsl.exe hands across
    // whole.
    expect(LOGIN_SHELL_SCRIPT).toContain('"$1"')
  })
})

describe('quoting for the shell on the far side', () => {
  it('leaves ordinary arguments unquoted', () => {
    expect(shellQuote('--continue')).toBe('--continue')
    expect(shellCommandLine(['exec', 'claude', '--continue'])).toBe('exec claude --continue')
  })

  it('quotes anything with a space or a metacharacter', () => {
    expect(shellQuote('my project')).toBe("'my project'")
    expect(shellQuote('a;rm -rf /')).toBe("'a;rm -rf /'")
    expect(shellQuote('$(whoami)')).toBe("'$(whoami)'")
  })

  it('survives a single quote, which is the one character quoting cannot nest', () => {
    expect(shellQuote("it's")).toBe(`'it'\\''s'`)
  })

  it('quotes the empty string rather than dropping it', () => {
    expect(shellQuote('')).toBe("''")
  })
})

/* =================================================================== env == */

describe('the environment that crosses the boundary', () => {
  it('names each variable, because WSL copies nothing it is not told to', () => {
    const value = wslEnvBridge({}, { plain: ['DECK_SESSION', 'TERM'], paths: ['CLAUDE_CONFIG_DIR'] })
    expect(value).toBe('DECK_SESSION/u:TERM/u:CLAUDE_CONFIG_DIR/up')
  })

  it('marks a config directory as a path so WSL rewrites C:\\ into /mnt/c', () => {
    // Without /p the agent inside the distro is pointed at a directory that does
    // not exist there, and two "separate" profiles quietly share one login.
    expect(wslEnvBridge({}, { paths: ['CLAUDE_CONFIG_DIR'] })).toBe('CLAUDE_CONFIG_DIR/up')
  })

  it('extends an existing WSLENV rather than replacing it', () => {
    // It is a user-facing Windows variable; something else may already rely on it.
    expect(wslEnvBridge({ WSLENV: 'MY_TOOL/p' }, { plain: ['TERM'] })).toBe('MY_TOOL/p:TERM/u')
  })

  it('does not name the same variable twice', () => {
    expect(wslEnvBridge({ WSLENV: 'TERM/u' }, { plain: ['TERM'] })).toBe('TERM/u')
  })

  it('is empty when there is nothing to carry', () => {
    expect(wslEnvBridge({}, {})).toBe('')
  })
})

/* ================================================================== link == */

function memoryStore(initial: string | null = null): WslStore & { value: string | null } {
  return {
    value: initial,
    read(): string | null {
      return this.value
    },
    write(distro: string | null): void {
      this.value = distro
    },
  }
}

const READY = {
  '-l -v': ok(wslBytes(LIST_OUTPUT)),
  '-l --running -q': ok(wslBytes('Ubuntu\r\n')),
}

describe('the link the app talks to', () => {
  it('routes a Linux folder into WSL and leaves a Windows folder alone', async () => {
    const link = new WslLink({ platform: 'win32', store: memoryStore(), exec: fakeExec(READY) })
    await link.refresh()
    expect(link.targetFor('/home/asad/proj')).toEqual({ distro: 'Ubuntu', cwd: '/home/asad/proj' })
    expect(link.targetFor('C:\\Users\\Asad\\proj')).toBeNull()
  })

  it('answers before the probe has come back, because it has to', async () => {
    // A New Session fired in the first second after launch must not spawn
    // cmd.exe with C:\home\asad\proj and die. A Linux folder can only run in
    // WSL, so the answer does not depend on what the probe found — and a null
    // distribution is exactly right, because wsl.exe reads it as "use default".
    const link = new WslLink({ platform: 'win32', store: memoryStore(), exec: fakeExec(READY) })
    expect(link.targetFor('/home/asad/proj')).toEqual({ distro: null, cwd: '/home/asad/proj' })
  })

  it('is inert off Windows, whatever the folder looks like', async () => {
    const link = new WslLink({ platform: 'darwin', store: memoryStore(), exec: fakeExec(READY) })
    await link.refresh()
    expect(link.supported).toBe(false)
    expect(link.targetFor('/Users/apple/proj')).toBeNull()
    expect(link.defaultTarget()).toBeNull()
    expect(link.snapshot().supported).toBe(false)
  })

  it('keeps one choice for the machine rather than asking per session', async () => {
    const store = memoryStore()
    const link = new WslLink({ platform: 'win32', store, exec: fakeExec(READY) })
    await link.refresh()

    link.choose('Debian')
    expect(store.value).toBe('Debian')
    // Every folder, one distribution. Not a per-session picker.
    expect(link.targetFor('/home/asad/a')?.distro).toBe('Debian')
    expect(link.targetFor('/srv/b')?.distro).toBe('Debian')
  })

  it('refuses to store a distribution the machine does not have', async () => {
    // A stored name that is not installed fails at spawn time, in a terminal,
    // naming something the settings pane never showed.
    const store = memoryStore()
    const link = new WslLink({ platform: 'win32', store, exec: fakeExec(READY) })
    await link.refresh()
    link.choose('Fedora')
    expect(store.value).toBeNull()
  })

  it('clears the choice back to the machine’s own default', async () => {
    const store = memoryStore('Debian')
    const link = new WslLink({ platform: 'win32', store, exec: fakeExec(READY) })
    await link.refresh()
    link.choose(null)
    expect(store.value).toBeNull()
    expect(link.active()).toBe('Ubuntu')
  })

  it('shares one reading between concurrent callers', async () => {
    const seen: string[][] = []
    const link = new WslLink({ platform: 'win32', store: memoryStore(), exec: fakeExec(READY, seen) })
    await Promise.all([link.refresh(), link.refresh(), link.refresh()])
    // Two commands, once — not six.
    expect(seen.length).toBe(2)
  })

  it('asks a running distribution for its home directory, once', async () => {
    const seen: string[][] = []
    const link = new WslLink({
      platform: 'win32',
      store: memoryStore(),
      exec: fakeExec(
        {
          ...READY,
          '-d Ubuntu -- sh -c printf %s "$HOME"': ok(Buffer.from('/home/asad', 'utf8')),
        },
        seen,
      ),
    })
    await link.refresh()
    expect(await link.resolveHome()).toBe('/home/asad')
    expect(await link.resolveHome()).toBe('/home/asad')
    expect(seen.filter((args) => args.includes('-d')).length).toBe(1)
    expect(link.home()).toBe('/home/asad')
  })

  it('will not boot a stopped distribution just to fill in a default folder', async () => {
    // Starting a WSL2 distribution means starting a virtual machine. Spending a
    // user's memory on a value only needed when an ungranted phone asks for a
    // folder list is this app deciding for them.
    const seen: string[][] = []
    const link = new WslLink({
      platform: 'win32',
      store: memoryStore('Debian'),
      exec: fakeExec(READY, seen),
    })
    await link.refresh()
    expect(await link.resolveHome()).toBeNull()
    expect(seen.some((args) => args.includes('-d'))).toBe(false)
    // And the caller is told it does not know, rather than being handed a guess.
    expect(link.home()).toBeNull()
  })

  it('survives a probe that throws outright', async () => {
    const link = new WslLink({
      platform: 'win32',
      store: memoryStore(),
      exec: () => Promise.reject(new Error('access denied')),
    })
    const console_ = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await link.refresh()
    console_.mockRestore()
    expect(link.snapshot().state).toBe('absent')
    // Still routes a Linux folder, because there is no other way to run one.
    expect(link.targetFor('/home/asad')).toEqual({ distro: null, cwd: '/home/asad' })
  })

  it('answers a question with no folder about the distribution, on a ready machine', async () => {
    // The renderer asks "which agents are installed" with nothing to go on. On a
    // machine whose work is in Linux, answering about the Windows PATH would
    // grey out an agent that is installed and working.
    const link = new WslLink({ platform: 'win32', store: memoryStore(), exec: fakeExec(READY) })
    expect(link.defaultTarget()).toBeNull()
    await link.refresh()
    expect(link.defaultTarget()).toEqual({ distro: 'Ubuntu', cwd: null })
  })

  it('does not claim a distribution on a machine that has none', async () => {
    const link = new WslLink({
      platform: 'win32',
      store: memoryStore(),
      exec: fakeExec({
        '-l -v': failed(1, wslBytes('Windows Subsystem for Linux has no installed distributions.')),
        '-l --running -q': failed(1, Buffer.alloc(0)),
      }),
    })
    await link.refresh()
    expect(link.defaultTarget()).toBeNull()
    expect(link.active()).toBeNull()
    expect(link.snapshot().state).toBe('no-distros')
  })

  it('describes itself in one object for the settings pane', async () => {
    const link = new WslLink({ platform: 'win32', store: memoryStore('Debian'), exec: fakeExec(READY) })
    expect(link.snapshot().read).toBe(false)
    await link.refresh()
    expect(link.snapshot()).toMatchObject({
      supported: true,
      state: 'ready',
      chosen: 'Debian',
      active: 'Debian',
      read: true,
    })
    expect(link.snapshot().distros.map((entry) => entry.name)).toEqual(['Ubuntu', 'Debian'])
  })
})

/* =================================================================== ipc == */

describe('the channels', () => {
  it('answers status from the reading it already has, and re-reads on demand', async () => {
    const seen: string[][] = []
    const link = new WslLink({ platform: 'win32', store: memoryStore(), exec: fakeExec(READY, seen) })
    const handlers = fakeIpc(link)

    // Counted over the *listing* commands only: a status call may also ask a
    // running distribution for its home directory, which is a different question.
    const listings = (): number => seen.filter((args) => args[0] === '-l').length

    await handlers.get(WSL_STATUS_CHANNEL)?.(null)
    expect(listings()).toBe(2)
    // No force: the launch reading stands, and opening the pane costs nothing.
    await handlers.get(WSL_STATUS_CHANNEL)?.(null)
    expect(listings()).toBe(2)
    // Refresh.
    await handlers.get(WSL_STATUS_CHANNEL)?.(null, true)
    expect(listings()).toBe(4)
  })

  it('records a choice through its channel', async () => {
    const store = memoryStore()
    const link = new WslLink({ platform: 'win32', store, exec: fakeExec(READY) })
    const handlers = fakeIpc(link)

    await handlers.get(WSL_STATUS_CHANNEL)?.(null)
    const snapshot = await handlers.get(WSL_CHOOSE_CHANNEL)?.(null, 'Debian')
    expect(store.value).toBe('Debian')
    expect(snapshot).toMatchObject({ chosen: 'Debian', active: 'Debian' })
  })

  it('reads anything that is not a distribution name as "no choice"', async () => {
    const store = memoryStore('Debian')
    const link = new WslLink({ platform: 'win32', store, exec: fakeExec(READY) })
    const handlers = fakeIpc(link)

    await handlers.get(WSL_CHOOSE_CHANNEL)?.(null, { evil: true })
    expect(store.value).toBeNull()
  })
})

/* ================================================================= boot === */

describe('wired at launch, not to a button', () => {
  /*
   * The assertion this repository cares about most, and the reason it is a
   * string match rather than a mock: the failure being guarded against is a
   * feature that works perfectly when somebody opens a settings pane and is
   * never reached at boot. Only `src/main/index.ts` can make it true.
   *
   * Three things break if the reading is deferred: restore-on-launch runs before
   * any window paints and has to know which side each remembered folder is on; a
   * phone can ask for a folder list seconds after launch; and a stored
   * distribution that has since been unregistered has to be noticed before a
   * session tries to use it.
   */
  const index = readFileSync(join(__dirname, 'index.ts'), 'utf8')

  it('reads the machine from whenReady', () => {
    expect(index).toContain('wsl.refresh()')
    const ready = index.slice(index.indexOf('app.whenReady()'))
    expect(ready).toContain('wsl.refresh()')
  })

  it('registers its channels', () => {
    expect(index).toContain('registerWslIpc(ipcMain')
  })

  it('routes every new session through the folder’s own side of the boundary', () => {
    // startSession has to ask, or the whole module is a settings pane that
    // changes nothing.
    const start = index.slice(index.indexOf('async function startSession'))
    expect(start).toContain('wslTargetFor(input.cwd)')
    // The provider probe has to be aimed at the same side the session runs on.
    expect(start).toContain('detectProviders(currentPlatform(), target)')
    // And the Windows-side working directory has to reach the pty.
    expect(start).toContain('hostCwd: spec.spawn.hostCwd')
  })

  it('stores a folder picked inside a distribution as its Linux path', () => {
    expect(index).toContain('linuxPathFromUnc(picked)')
  })

  it('asks about a WSL folder’s existence in a way Windows can answer', () => {
    // existsSync('/home/asad/proj') is false on Windows however real the folder
    // is, so restore-on-launch would drop every WSL session as "folder gone".
    expect(index).toContain('folderExists: (cwd) => folderExists(statablePath(cwd))')
    expect(index).toContain('existsSync(statablePath(session.cwd))')
  })

  it('offers a phone the distribution’s home rather than the Windows one', () => {
    expect(index).toContain('wsl.home() ?? app.getPath(\'home\')')
  })
})
