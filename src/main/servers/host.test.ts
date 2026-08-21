import { describe, expect, it } from 'vitest'
import {
  HOST_PROBE,
  ServerHosts,
  hostConsequence,
  hostLine,
  reachLine,
  readHostProbe,
  removeConsequence,
  removeScript,
  serviceScript,
  usableNode,
  whyNotHost,
  type HostDeps,
  type HostLook,
  type HostRunResult,
  type HostShell,
  type HostState,
} from './host'

/**
 * Putting the headless host on a server, exercised where it is most likely to
 * be quietly wrong.
 *
 * Four properties are worth a test each and the rest is arithmetic:
 *
 *  1. **Nothing is offered on a guess.** A server with no compiler, or musl, or
 *     no room, is told so *before* a button, not two minutes into an install
 *     that has already copied a package onto it.
 *  2. **The probe is parsed against what a real machine actually said.** The
 *     fixtures below are verbatim output from a Hetzner box on 2026-08-21 — one
 *     bare, one after the install, one with the host running — because the
 *     interesting failures here are all "the server said something slightly
 *     different from what was imagined."
 *  3. **The way back removes what was added and nothing else.** Never the data
 *     folder unless it was asked for, never a path outside `$HOME`.
 *  4. **Every step is reported.** The whole feature exists because *"a long
 *     silent operation on somebody's server is the worst version of this"*, so a
 *     flow that did the work and said nothing would be the bug.
 *
 * Everything here runs against a plain object. There is no `ssh2` within reach,
 * which is the whole reason the flow takes its transport as a dependency.
 */

/** Stopping a run, on the wire. Named so the assertion reads. */
const CTRL_C = '\u0003'

/* -------------------------------------------------------------- fixtures -- */

/**
 * Verbatim, from `terminaldeck-server` before anything was installed on it:
 * Ubuntu 24.04, root, Node 18 with **no npm at all**, and no compiler.
 *
 * That combination is not a contrived worst case — it is what a rented Linux
 * server looks like on day one, and it is the machine this whole feature was
 * built against.
 */
const BARE = [
  'os\tLinux',
  'arch\tx86_64',
  'libc\tgnu',
  'node\tv18.19.1',
  'npm\t',
  'tools\t make gcc g++',
  'fetch\tcurl',
  'hash\tsha256sum',
  'tar\tyes',
  'home_free_kb\t33209852',
  'state_dir\t/root/.local/share/terminaldeck',
  'systemd_user\tyes',
  'command\t',
  '',
].join('\n')

/**
 * Verbatim, from the same box after the installer ran as an ordinary user with
 * no Node: the private runtime supplied its own npm, and `status` answered
 * *"not running"* because nothing had started the daemon yet.
 */
const INSTALLED_STOPPED = [
  'os\tLinux',
  'arch\tx86_64',
  'libc\tgnu',
  'node\tv18.19.1',
  'npm\t/home/td-scratch/.terminaldeck/runtime/bin/npm',
  'tools\t',
  'fetch\tcurl',
  'hash\tsha256sum',
  'tar\tyes',
  'home_free_kb\t32439968',
  'state_dir\t/home/td-scratch/.local/share/terminaldeck',
  'command\t/home/td-scratch/.local/bin/terminaldeck',
  'version\t0.9.1',
  '--- status ---',
  'Terminal Deck host: not running.',
  '',
  '  state  /home/td-scratch/.local/share/terminaldeck',
  '',
  'Start it with "terminaldeck-host", or run "terminaldeck pair", which starts it for you.',
  '',
].join('\n')

/** Verbatim, the same box a moment later, with the daemon up and on the relay. */
const RUNNING = [
  'os\tLinux',
  'arch\tx86_64',
  'libc\tgnu',
  'node\tv18.19.1',
  'npm\t/home/td-scratch/.terminaldeck/runtime/bin/npm',
  'tools\t',
  'fetch\tcurl',
  'hash\tsha256sum',
  'tar\tyes',
  'home_free_kb\t32439968',
  'state_dir\t/home/td-scratch/.local/share/terminaldeck',
  'state\tyes',
  'systemd_user\tyes',
  'unit\tactive',
  'linger\tyes',
  'command\t/home/td-scratch/.local/bin/terminaldeck',
  'version\t0.9.1',
  '--- status ---',
  'Terminal Deck host 0.9.1 — running, idle',
  '  pid 139188, up 5s',
  '  state  /home/td-scratch/.local/share/terminaldeck',
  '',
  'Relay',
  '  connected      wss://relay.terminaldeck.dev',
  '  host id        P5PCNBABHBBVFDBZZ2ECELNAZ7',
  '  fingerprint    A3PL-DGAB-3N6W-RK3Y-V4VS-MMHP',
  '',
].join('\n')

/**
 * A room nothing is wrong with, for the tests that are about something else.
 *
 * Written out rather than taken from `RUNNING`, and the difference is real:
 * that box reports `node v18` even after the installer put a Node 22 beside it,
 * because the probe *appends* the private runtime to PATH rather than putting it
 * in front — deliberately, so this app never shadows a machine's own `node`.
 * A fixture that inherited that would be testing a re-install, not a machine
 * that already has a good Node.
 */
const GOOD = { ...readHostProbe(RUNNING).room, node: 'v22.23.2', npm: '/usr/bin/npm' }

/* ----------------------------------------------------------- the fixtures -- */

describe('reading what a server said', () => {
  it('reads a bare rented server the way it actually answered', () => {
    const { host, room } = readHostProbe(BARE)
    expect(host.command).toBe('')
    expect(room.node).toBe('v18.19.1')
    expect(room.npm).toBe('')
    expect(room.missingTools).toEqual(['make', 'gcc', 'g++'])
    expect(room.downloader).toBe('curl')
    expect(room.canHash).toBe(true)
    expect(room.canUnpack).toBe(true)
    expect(room.systemdUser).toBe(true)
    expect(room.homeFreeKb).toBe(33_209_852)
  })

  /*
   * The verdict this exists for. `status` exits 0 whether or not the host is
   * running — deliberately, so a health check does not report a failure for a
   * machine that is switched off — so the exit status says nothing and the
   * words are the only evidence there is.
   */
  it('believes the host when it says it is not running', () => {
    expect(readHostProbe(INSTALLED_STOPPED).host.running).toBe('no')
  })

  it('believes it when it says it is', () => {
    const { host } = readHostProbe(RUNNING)
    expect(host.running).toBe('yes')
    expect(host.version).toBe('0.9.1')
    expect(host.unit).toBe('active')
    expect(host.linger).toBe(true)
    // Verbatim, because the pane prints it verbatim: a paste of that panel into
    // a bug report has to be what the person saw.
    expect(host.status).toContain('fingerprint    A3PL-DGAB-3N6W-RK3Y-V4VS-MMHP')
  })

  /*
   * The third state, and it is not "no". A host that is there and would not say
   * anything is a different thing to be told than a host that answered.
   */
  it('says it does not know when there is a command and no answer', () => {
    const { host } = readHostProbe(['command\t/home/me/.local/bin/terminaldeck', ''].join('\n'))
    expect(host.running).toBe('unknown')
  })

  /*
   * Measured: `systemctl --user is-active` answers "inactive" about a unit that
   * does not exist, so a server with no unit of ours and a server whose unit is
   * merely stopped answered identically. The probe now asks about the unit
   * *file*, and this is the claim that keeps it that way.
   */
  it('reports no unit at all rather than an inactive one', () => {
    expect(readHostProbe(BARE).host.unit).toBe('')
    expect(HOST_PROBE).toContain('.config/systemd/user/terminaldeck.service')
  })
})

/* ------------------------------------------------------- what is refused -- */

describe('what is refused before a button is drawn', () => {
  it('refuses a machine with no compiler, and names the packages', () => {
    const why = whyNotHost(readHostProbe(BARE).room)
    expect(why).not.toBeNull()
    expect(why).toContain('make, gcc, g++')
    expect(why).toContain('apt-get install -y make gcc g++')
  })

  it('refuses musl, because Node publishes no build for it', () => {
    const why = whyNotHost({ ...GOOD, libc: 'musl' })
    expect(why).toContain('musl')
    expect(why).toContain('apk add')
  })

  it('refuses a machine with no Node and nothing to fetch one with', () => {
    const why = whyNotHost({ ...GOOD, node: '', npm: '', downloader: '' })
    expect(why).toContain('curl or wget')
  })

  it('refuses a machine with no room, and says how much it has', () => {
    const why = whyNotHost({ ...GOOD, homeFreeKb: 50 * 1024 })
    expect(why).toContain('50 MB free')
  })

  it('refuses Windows rather than pretending', () => {
    expect(whyNotHost({ ...GOOD, os: 'mingw64_nt' })).toContain('Linux and macOS')
  })

  /*
   * A machine with no Node is **not** refused when it has the three things the
   * installer needs to supply one. That is the whole point of the runtime
   * fetch, and a check that refused here would have made this feature useless
   * on exactly the machine it was built for.
   */
  it('allows a machine with no Node that can fetch one', () => {
    expect(whyNotHost({ ...GOOD, node: 'v18.19.1', npm: '' })).toBeNull()
  })

  it('allows a machine that already has a good Node', () => {
    expect(whyNotHost(GOOD)).toBeNull()
  })

  it('counts Node and npm as one question', () => {
    expect(usableNode({ node: 'v22.23.2', npm: '/usr/bin/npm' })).toBe(true)
    expect(usableNode({ node: 'v22.23.2', npm: '' })).toBe(false)
    expect(usableNode({ node: 'v18.19.1', npm: '/usr/bin/npm' })).toBe(false)
    expect(usableNode({ node: '', npm: '/usr/bin/npm' })).toBe(false)
  })
})

/* ---------------------------------------------------------- the sentences -- */

describe('the sentences, which are written here and never in the renderer', () => {
  it('says what the install will do about Node, both ways', () => {
    expect(hostConsequence('box', GOOD)).toContain('uses the Node v22')
    expect(hostConsequence('box', { ...GOOD, node: 'v18.19.1', npm: '' })).toContain(
      'checked against the checksum',
    )
  })

  it('never claims a host is running when it would not say', () => {
    const host = readHostProbe(['command\t/home/me/.local/bin/x', 'version\t0.9.1', ''].join('\n')).host
    expect(hostLine(host)).toContain('would not say')
  })

  /*
   * The question nobody thinks to ask until a phone in another country finds
   * nothing there. All three answers name what would change them.
   */
  it('says whether it will still be there tomorrow', () => {
    const base = readHostProbe(RUNNING).host
    expect(reachLine({ ...base, unit: '' })).toContain('will not come back')
    expect(reachLine({ ...base, linger: false })).toContain('enable-linger')
    expect(reachLine(base)).toContain('keeps running when you log out')
    expect(reachLine({ ...base, command: '' })).toBeNull()
  })

  it('says what removing it leaves, differently for each answer', () => {
    const host = readHostProbe(RUNNING).host
    expect(removeConsequence(host, false)).toContain('What it stored stays')
    expect(removeConsequence(host, false)).toContain(host.dataDir)
    expect(removeConsequence(host, true)).toContain('will need pairing again')
  })
})

/* ------------------------------------------------------------ the scripts -- */

describe('the scripts run on the server', () => {
  /*
   * The measured trap: when the installer supplies its own Node it writes a
   * launcher for the CLI **only**, so a unit pointing at
   * `~/.local/bin/terminaldeck-host` would name a file that is not there.
   */
  it('starts the daemon and not the command-line tool', () => {
    const unit = serviceScript('/home/me/.local/bin/terminaldeck')
    expect(unit).toContain('ExecStart=$host')
    expect(unit).toContain('host="$rt/bin/terminaldeck-host"')
    expect(unit).toContain('host="$bin/terminaldeck-host"')
    expect(unit).toContain('grep -q terminaldeck-launcher')
  })

  it('asks for lingering without sudo, and reads the answer back', () => {
    const unit = serviceScript('/home/me/.local/bin/terminaldeck')
    expect(unit).not.toContain('sudo')
    expect(unit).toContain('loginctl enable-linger')
    expect(unit).toContain('printf "linger %s\\n"')
  })

  it('leaves the data folder alone unless it was asked for', () => {
    const keep = removeScript('/home/me/.local/bin/terminaldeck', '/home/me/.local/share/terminaldeck', false)
    expect(keep).not.toContain('.local/share/terminaldeck')
    const wipe = removeScript('/home/me/.local/bin/terminaldeck', '/home/me/.local/share/terminaldeck', true)
    expect(wipe).toContain('rm -rf "$dd"')
  })

  it('refuses to remove anything outside the account’s own home', () => {
    const script = removeScript('/usr/bin/terminaldeck', '/var/lib/terminaldeck', true)
    expect(script).toContain('case "$b" in "$HOME"/*) ;; *) echo "not ours to remove" >&2; exit 1 ;; esac')
    expect(script).toContain('case "$dd" in "$HOME"/*)')
  })

  it('quotes a home directory with a space in it', () => {
    expect(removeScript("/home/my name/.local/bin/terminaldeck", '/x', false)).toContain(
      "b='/home/my name/.local/bin/terminaldeck'",
    )
  })
})

/* -------------------------------------------------------------- the flow -- */

interface Box {
  scripts: string[]
  typed: string[]
  put: Array<{ local: string; name: string }>
  states: HostState[]
  shell: HostShell
  deps: HostDeps
}

/**
 * A server that answers, with the replies keyed on the shape of the script
 * rather than on call order.
 *
 * A test that counted calls would break the moment a step was added and would
 * say nothing about what broke — which is the argument `setup.test.ts` already
 * makes for its own fake box.
 */
function box(over: { after?: string; carriesPackage?: boolean; installExit?: number } = {}): Box {
  const scripts: string[] = []
  const typed: string[] = []
  const put: Array<{ local: string; name: string }> = []
  const states: HostState[] = []
  const listeners: Array<(chunk: string) => void> = []

  const shell: HostShell = {
    onData: (listener) => {
      listeners.push(listener)
      return () => {
        const at = listeners.indexOf(listener)
        if (at >= 0) listeners.splice(at, 1)
      }
    },
    write: (data) => {
      typed.push(data)
      // The far end echoes, then answers. Deferred so the caller has attached
      // its listener, which is what a real shell's round trip does anyway.
      queueMicrotask(() => {
        const say = (text: string): void => {
          for (const listener of [...listeners]) listener(text)
        }
        if (data.includes('install.sh')) say(`__terminaldeck_host ${over.installExit ?? 0}\n`)
        else if (data.includes('pair --kind mine')) say('\n  Pairing code   904021\n  Valid for      60 seconds\n')
      })
    },
  }

  const deps: HostDeps = {
    runScript: (_serverId, script): Promise<HostRunResult> => {
      scripts.push(script)
      if (script.includes('--- status ---')) {
        // What the server says *after* the install. Answered by shape rather
        // than by call order, so adding a step does not silently change which
        // fixture a test is reading.
        return Promise.resolve({ code: 0, stdout: over.after ?? RUNNING, stderr: '' })
      }
      if (script.includes('enable --now')) {
        return Promise.resolve({ code: 0, stdout: 'linger yes\n', stderr: '' })
      }
      return Promise.resolve({ code: 0, stdout: '', stderr: '' })
    },
    putFile: (_serverId, local, name) => {
      put.push({ local, name })
      return Promise.resolve(`/home/me/Terminal Deck/${name}`)
    },
    hostPackage: () =>
      over.carriesPackage === false
        ? null
        : { tarball: '/here/terminaldeck-host.tgz', installer: '/here/install.sh', version: '0.9.1' },
    broadcast: (next) => {
      states.push(next)
    },
  }

  return { scripts, typed, put, states, shell, deps }
}

/** A look with nothing wrong with it, for the flow tests. */
function goodLook(): HostLook {
  return { ...readHostProbe(RUNNING), room: GOOD }
}

describe('installing it', () => {
  it('reports every step, in order, and ends holding a pairing code', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const final = await hosts.install('s1', it_.shell, goodLook(), 'box')

    expect(it_.states.map((s) => s.step)).toEqual([
      'checking',
      'uploading',
      'installing',
      'service',
      'pairing',
      'done',
    ])
    expect(final.code).toBe('904021')
    // Each finished step is a sentence somebody can come back to. Five of
    // them: what the machine had, what was copied, what was installed, how it
    // was made to start, and that it printed a code.
    expect(final.done).toHaveLength(5)
    expect(final.done[1]).toContain('Copied the package to')
    expect(final.done[3]).toContain('keeps running when you log out')
    expect(final.done[4]).toContain('pairing code')
  })

  it('copies the installer before the package', async () => {
    const it_ = box()
    await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(it_.put.map((one) => one.name)).toEqual(['install.sh', 'terminaldeck-0.9.1.tgz'])
  })

  it('hands the installer the tarball it just copied, and quotes the folder', async () => {
    const it_ = box()
    await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    const line = it_.typed.find((one) => one.includes('install.sh')) ?? ''
    expect(line).toContain(`TERMINALDECK_PACKAGE='/home/me/Terminal Deck/terminaldeck-0.9.1.tgz'`)
    expect(line).toContain(`sh '/home/me/Terminal Deck/install.sh'`)
  })

  /*
   * The refusal arrives before anything is copied. That ordering is the whole
   * value of the check: a button that uploaded a package and then printed the
   * installer's refusal is the hopeful control §4.1 forbids.
   */
  it('refuses a machine that cannot take it, and copies nothing', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const final = await hosts.install('s1', it_.shell, readHostProbe(BARE), 'box')
    expect(final.step).toBe('failed')
    expect(final.line).toContain('make, gcc, g++')
    expect(it_.put).toHaveLength(0)
    expect(it_.typed).toHaveLength(0)
  })

  it('refuses when this build carries no package, and copies nothing', async () => {
    const it_ = box({ carriesPackage: false })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(it_.put).toHaveLength(0)
  })

  it('refuses when the install finished and left no command behind', async () => {
    const it_ = box({ after: BARE })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(final.line).toContain('no terminaldeck command')
  })

  it('says the install failed rather than going on to pair with nothing', async () => {
    const it_ = box({ installExit: 1 })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(final.detail).toContain('ended with 1')
    expect(it_.typed.some((one) => one.includes('pair'))).toBe(false)
  })

  /*
   * No systemd user manager is not a failed install. A container has no init by
   * design, and a host running now is what somebody pressed the button for — so
   * it is started directly and the cost is *stated* rather than hidden.
   */
  it('starts it directly when there is no systemd, and says what that costs', async () => {
    const it_ = box()
    const look = goodLook()
    const final = await new ServerHosts(it_.deps).install(
      's1',
      it_.shell,
      { ...look, room: { ...look.room, systemdUser: false } },
      'box',
    )
    expect(final.done[3]).toContain('will not come back on its own after a reboot')
    expect(it_.scripts.some((one) => one.includes('nohup'))).toBe(true)
  })

  /*
   * Cancelling is Ctrl-C in the terminal the person is watching, which is how
   * they would stop it themselves — the same honest kill `setup.ts` uses.
   */
  it('stops what it started with the key the person would press', async () => {
    const it_ = box({ installExit: 1 })
    const hosts = new ServerHosts(it_.deps)
    const started = hosts.install('s1', it_.shell, goodLook(), 'box')
    await hosts.cancel('s1')
    await started
    // Ctrl-C in the terminal the person is watching, and nothing else. The
    // other writes are the lines this app typed, which all end in a newline.
    expect(it_.typed.every((one) => one === CTRL_C || one.endsWith('\n'))).toBe(true)
  })

  /*
   * The line under the terminal must stop claiming the install is running the
   * moment somebody presses Stop. Before `giveUp` existed it kept saying
   * "Installing on box." for the twelve minutes the ceiling allows, because the
   * wait was still sitting on a shell that had already been taken away.
   */
  it('says it was stopped, rather than sitting on the ceiling', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    // A shell that never answers, which is what a terminal that has been closed
    // out from under a run looks like from here.
    const deaf: HostShell = { onData: () => () => undefined, write: () => undefined }
    const started = hosts.install('s1', deaf, goodLook(), 'box')
    // Pressed while it is installing, which is when a person would press it —
    // not before the run has reached the wait, where there is nothing to stop.
    while (hosts.stateOf('s1').step !== 'installing') await Promise.resolve()
    await hosts.cancel('s1')
    const final = await started
    expect(final.step).toBe('failed')
    expect(final.line).toContain('Stopped before')
  })
})

describe('pairing', () => {
  it('reads the code out of the terminal exactly as it was printed', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const final = await hosts.pair('s1', it_.shell, '/home/me/.local/bin/terminaldeck')
    expect(final.code).toBe('904021')
    expect(it_.typed[0]).toBe(`'/home/me/.local/bin/terminaldeck' pair --kind mine\n`)
  })

  /*
   * `--kind mine` is passed and the `Approve it? [y/N]` question is *not*
   * answered. The fingerprint above that prompt is the only part of pairing a
   * person can actually check, and answering it here would delete the check
   * while appearing to perform it.
   */
  it('never answers the fingerprint question', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    await hosts.pair('s1', it_.shell, '/home/me/.local/bin/terminaldeck')
    expect(it_.typed.some((one) => one.trim() === 'y')).toBe(false)
  })
})

describe('removing it', () => {
  it('says what it left behind, in the answer that was given', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const host = readHostProbe(RUNNING).host

    const kept = await hosts.uninstall('s1', host, false)
    expect(kept.step).toBe('idle')
    expect(kept.done[1]).toContain('was left alone')

    const wiped = await hosts.uninstall('s1', host, true)
    expect(wiped.done[1]).toContain('will need pairing again')
  })

  it('refuses when there is nothing of ours there', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const final = await hosts.uninstall('s1', readHostProbe(BARE).host, false)
    expect(final.step).toBe('failed')
    expect(it_.scripts.some((one) => one.includes('rm -rf'))).toBe(false)
  })
})
