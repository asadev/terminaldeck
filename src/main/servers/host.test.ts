import { describe, expect, it } from 'vitest'
import {
  HOST_PROBE,
  ServerHosts,
  channelsOf,
  hostConsequence,
  hostIdOf,
  hostLine,
  reachLine,
  readHostProbe,
  relayState,
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
  type LinkOutcome,
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
 * Verbatim, from **his office PC** at 00:46 on 2026-08-22 — the measurement this
 * lane exists for.
 *
 * A host that had been up for two hours, connected to the relay, with a device
 * of his approved in its own list, and `channels 0`: nothing was connected to
 * it. The panel over it said *"This computer is linked to it … sessions,
 * folders and the terminal work there the way they do for any other machine."*
 *
 * Kept here in the host's own words rather than trimmed to the line under test,
 * because the whole point is that this app was already looking at this text and
 * not reading it.
 */
const NOBODY_ATTACHED = [
  'os\tLinux',
  'arch\tx86_64',
  'libc\tgnu',
  'node\tv18.19.1',
  'npm\t/home/asad/.terminaldeck/runtime/bin/npm',
  'tools\t',
  'fetch\tcurl',
  'hash\tsha256sum',
  'tar\tyes',
  'home_free_kb\t32439968',
  'state_dir\t/home/asad/.local/share/terminaldeck',
  'state\tyes',
  'systemd_user\tyes',
  'command\t/home/asad/.local/bin/terminaldeck',
  'version\t0.9.1',
  '--- status ---',
  'Terminal Deck host 0.9.1 — running, idle',
  '  pid 145995, up 2h',
  '  state  /home/asad/.local/share/terminaldeck',
  '',
  'Relay',
  '  connected      wss://relay.terminaldeck.dev',
  '  host id        KZ2J9AWGK8BWGQUEZDYKW5RS22',
  '  fingerprint    NW76-TCC7-DKFD-AGVD-MBGK-W28U',
  '  channels       0',
  '',
].join('\n')

/**
 * The same box in the state a freshly installed host is in for its first
 * seconds: running, and not on the relay yet.
 *
 * The failure this explains is real and is not an expired code — a host that has
 * not connected published no rendezvous, so the code it printed was unfindable
 * from the moment it was printed, and "try again" is the wrong advice.
 */
const OFF_RELAY = RUNNING.replace(
  '  connected      wss://relay.terminaldeck.dev',
  '  not connected  dialling',
).replace('  host id        P5PCNBABHBBVFDBZZ2ECELNAZ7\n', '')

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

  it('does not tell him nothing can run a session on a server he has been using', () => {
    /*
     * He caught this one on screen: "why is it lying". The line read "Nothing on
     * this server can run a session for you yet." beside a server he had been
     * opening sessions on for weeks — every one of them an SSH shell this app
     * holds. The missing thing is the host, which is a smaller and different
     * claim, and the offer has to be worth something on top of what he already
     * has rather than pretending he has nothing.
     */
    const none = hostLine({ ...readHostProbe(RUNNING).host, command: '' })
    expect(none).not.toContain('Nothing on this server')
    expect(none.toLowerCase()).toContain('ssh')

    const said = hostConsequence('box', GOOD)
    expect(said, 'the offer must not sell him a session on box, which he can already open').toContain(
      'SSH shell this app holds open',
    )
    expect(said).toContain('keep running')
    expect(said, 'a headless host has no copilot and he will look for it').toContain('no Copilot')
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
  /** Which machine the flow waited on before saying it was linked. */
  waitedFor: string[]
  /** Every code this app handed to the Machines list, in order. */
  redeemed: string[]
  shell: HostShell
  deps: HostDeps
}

/**
 * The fingerprint of the guest key *this* desktop would have paired with.
 *
 * The whole of the check `ServerHosts.link` makes in place of a person's eyes:
 * the host prints the fingerprint of whatever redeemed the code, and this is
 * what the redemption said it dialled with. Two fixtures, so a test can make
 * them differ.
 */
/**
 * The id the redemption answers with, which is that host's own id at the relay.
 *
 * Carried back so the flow can wait for *that* machine's link to start carrying
 * before it says it is linked — see {@link HostDeps.whenReaching}.
 */
const THAT_MACHINE = 'P5PCNBABHBBVFDBZZ2ECELNAZ7'

const OURS = 'A3PL-DGAB-3N6W-RK3Y-V4VS-MMHP'
const SOMEBODY_ELSE = 'ZZZZ-DGAB-3N6W-RK3Y-V4VS-MMHP'

/**
 * A server that answers, with the replies keyed on the shape of the script
 * rather than on call order.
 *
 * A test that counted calls would break the moment a step was added and would
 * say nothing about what broke — which is the argument `setup.test.ts` already
 * makes for its own fake box.
 */
function box(
  over: {
    after?: string
    carriesPackage?: boolean
    installExit?: number
    /** What redeeming the code answers. Ok with {@link OURS} unless a test says otherwise. */
    link?: LinkOutcome
    /**
     * What redeeming answers on each successive try, for the retry tests.
     *
     * A list rather than one answer, because the property being exercised is
     * that a *first* miss is not the end — and a fake that gave the same reply
     * every time could only ever prove the loop runs, never that it stops.
     */
    links?: LinkOutcome[]
    /** The codes `pair` prints, one per run. One fresh code per try is the rule. */
    codes?: string[]
    /** The fingerprint the *host* prints for the device that turned up. */
    hostShows?: string
    /** A build with no Machines list at all, which must fall back to showing the code. */
    canLink?: false
    /** The host refuses the approval after `y`, which is a failure this must report. */
    approves?: false
    /** Run inside the redemption, before it answers — where a Stop has no wait to wake. */
    whileRedeeming?: () => void
    /** How many probes answer "not on the relay yet" before the real fixture. */
    offRelayFor?: number
    /** The relay wait's own ceiling. Zero everywhere but the test that exercises it. */
    relayWaitMs?: number
    /**
     * Whether this computer's link to the machine actually came up.
     *
     * Absent means the flow is not asked to wait at all, which is what a build
     * with no machine channels does — see {@link HostDeps.whenReaching}.
     */
    reaches?: boolean
  } = {},
): Box {
  const scripts: string[] = []
  const typed: string[] = []
  const put: Array<{ local: string; name: string }> = []
  const states: HostState[] = []
  const redeemed: string[] = []
  const listeners: Array<(chunk: string) => void> = []

  const say = (text: string): void => {
    for (const listener of [...listeners]) listener(text)
  }

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
        if (data.includes('install.sh')) say(`__terminaldeck_host ${over.installExit ?? 0}\n`)
        else if (data.includes('pair --kind mine')) {
          // A fresh code per run, exactly as a real host mints one: the run that
          // printed the last one has been interrupted and cannot be asked again.
          const code = over.codes?.[minted] ?? over.codes?.at(-1) ?? '904021'
          minted += 1
          say(`\n  Pairing code   ${code}\n  Valid for      60 seconds\n`)
        }
        // `renderApproved` and `renderNotApproved`, in the words `cli.ts` prints
        // them in — the two things that can follow the approval question.
        else if (data.trim() === 'y') {
          say(
            over.approves === false
              ? '\n  This Mac was NOT approved.\n'
              : '\n  Approved as your own device. This Mac can reach this host now.\n',
          )
        }
      })
    },
  }

  let probes = 0
  let minted = 0
  let redemptions = 0
  const waitedFor: string[] = []
  const deps: HostDeps = {
    /*
     * Zero unless a test says otherwise, so nothing here waits on a real clock.
     * The wait itself is exercised deliberately, once, with `offRelayFor`.
     */
    relayWaitMs: over.relayWaitMs ?? 0,
    runScript: (_serverId, script): Promise<HostRunResult> => {
      scripts.push(script)
      if (script.includes('--- status ---')) {
        probes += 1
        // A host that has started and not finished dialling the relay, for as
        // many probes as the test asked for. This is the race the wait exists
        // for: a code minted here was never published.
        if (over.offRelayFor !== undefined && probes <= over.offRelayFor) {
          return Promise.resolve({ code: 0, stdout: OFF_RELAY, stderr: '' })
        }
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
    /*
     * `MachinesIpc.linkWithCode`, as this module sees it.
     *
     * The important half is the timing: a real host prints the new device the
     * instant something redeems its code, which is *before* the redemption
     * returns here. Queued the same way, so the flow is exercised against the
     * race it was built for rather than against a convenient ordering.
     */
    linkThisComputer:
      over.canLink === false
        ? undefined
        : (code: string): Promise<LinkOutcome> => {
            redeemed.push(code)
            over.whileRedeeming?.()
            const answer: LinkOutcome =
              over.links?.[redemptions] ??
              over.link ?? { ok: true, machineId: THAT_MACHINE, machineName: 'office-pc', deviceFingerprint: OURS }
            redemptions += 1
            if (answer.ok) {
              queueMicrotask(() =>
                say(
                  `\n  New device     This Mac\n  Fingerprint    ${over.hostShows ?? OURS}\n\n` +
                    '  Check that fingerprint against the one the device is showing.\n\n' +
                    '  Approve it? [y/N] ',
                ),
              )
            }
            return Promise.resolve(answer)
          },
    ...(over.reaches === undefined
      ? {}
      : {
          whenReaching: (machineId: string): Promise<boolean> => {
            waitedFor.push(machineId)
            return Promise.resolve(over.reaches === true)
          },
        }),
    broadcast: (next) => {
      states.push(next)
    },
  }

  return { scripts, typed, put, states, redeemed, waitedFor, shell, deps }
}

/** A look with nothing wrong with it, for the flow tests. */
function goodLook(): HostLook {
  return { ...readHostProbe(RUNNING), room: GOOD }
}

describe('installing it', () => {
  it('reports every step, in order, and ends linked to this computer', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const final = await hosts.install('s1', it_.shell, goodLook(), 'box')

    expect(it_.states.map((s) => s.step)).toEqual([
      'checking',
      'uploading',
      'installing',
      'service',
      // Twice, and the second one is the honest half of the last step: the far
      // end has approved this computer and the channel has not come up yet.
      'pairing',
      'pairing',
      'done',
    ])
    expect(it_.states.map((one) => one.line)).toContain('Approved. Waiting for this computer to reach it.')
    expect(final.line).toContain('linked to this computer')
    // Each finished step is a sentence somebody can come back to. Five of
    // them: what the machine had, what was copied, what was installed, how it
    // was made to start, and that this computer is linked to it.
    expect(final.done).toHaveLength(5)
    expect(final.done[1]).toContain('Copied the package to')
    expect(final.done[3]).toContain('keeps running when you log out')
    expect(final.done[4]).toContain('linked to this computer as office-pc')
  })

  /*
   * Approved is not connected, and the gap between them is a second and a half.
   *
   * The first dial goes out while this device is still pending at the far end
   * and is refused; the approval lands a moment later and the channel comes up
   * after that. An install that announced a link at the `y` would have made the
   * panel behind it — which now asks that host how many channels it has open —
   * accuse a perfectly good install of not being connected.
   */
  it('waits for the channel to come up before saying it is linked', async () => {
    const it_ = box({ reaches: true })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('done')
    expect(final.line).toBe('It is running, and linked to this computer.')
    expect(final.detail).toBe('')
    // The machine it waited on is the one it just paired with, by that host's
    // own id — never "some link came up".
    expect(it_.waitedFor).toEqual([THAT_MACHINE])
  })

  /*
   * And when it does not come up, the last thing on screen says so. This is the
   * rule the whole round is built on: never a panel that looks finished over a
   * host nothing is reaching. The install is **not** reported as a failure —
   * the host is there, running, and approved this computer — but the sentence
   * is honest and the press is named.
   */
  it('says the channel never came up rather than claiming a link', async () => {
    const it_ = box({ reaches: false })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('done')
    expect(final.line).toContain('has not reached it yet')
    expect(final.detail).toContain('Link this computer')
    // The work that did happen is still on the list. A panel that swallowed it
    // would send somebody to reinstall a host that is fine.
    expect(final.done.some((one) => one.includes('approved as your own device'))).toBe(true)
  })

  /*
   * The bug, stated as a property.
   *
   * The install used to end holding a code, the panel drew it beside a button,
   * and by the time anybody read the panel the code had expired — codes last a
   * minute. `state.code` is broadcast to every window, so this is also the rule
   * that keeps a live secret off a screen: the code exists for the millisecond
   * between being printed and being spent, and never leaves this process.
   */
  it('never puts the code it spends on any state a window can read', async () => {
    const it_ = box()
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.code).toBeNull()
    expect(it_.states.every((one) => one.code === null)).toBe(true)
    // And it really was spent, by this app, in the same run that minted it.
    expect(it_.redeemed).toEqual(['904021'])
  })

  /*
   * The check that replaces a person comparing two screens, and it is stricter
   * than they are. A fingerprint that is not this computer's means something
   * else redeemed the code — so the answer to `Approve it? [y/N]` is `n`, and
   * the run fails saying so rather than approving a stranger.
   */
  it('refuses the approval when the host shows a fingerprint that is not ours', async () => {
    const it_ = box({ hostShows: SOMEBODY_ELSE })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(final.line).toContain('Something other than this computer')
    expect(final.detail).toContain(SOMEBODY_ELSE)
    expect(it_.typed).toContain('n\n')
    expect(it_.typed).not.toContain('y\n')
  })

  it('reports a host that will not approve, rather than claiming it linked', async () => {
    const it_ = box({ approves: false })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(final.line).toContain('did not approve')
  })

  /*
   * A refusal has two causes with nothing in common, and the remedy differs: a
   * host that is not on the relay published no rendezvous at all, so trying
   * again fails identically. The verdict is read from that host's own `status`
   * rather than guessed.
   */
  it('says which of the two things went wrong when nothing answered the code', async () => {
    const it_ = box({ link: { ok: false, message: 'Nothing answered for that code at the relay.' } })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(final.detail).toContain('Nothing answered for that code')
    expect(final.detail).toContain('connected to the relay')
    // And the command waiting for a device that is not coming was stopped,
    // rather than left standing at the relay under a panel saying this failed.
    expect(it_.typed).toContain(CTRL_C)
  })

  it('names the relay when that is what is missing', async () => {
    const it_ = box({
      after: OFF_RELAY,
      link: { ok: false, message: 'Nothing answered for that code at the relay.' },
    })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.detail).toContain('nothing at the relay to answer')
  })

  /*
   * The race the install creates, and the whole reason there is a wait at all:
   * the step before this starts the daemon, and a daemon that has not finished
   * dialling the relay mints a code that was never published. Measured one layer
   * over — `remote/server.ts` records the demo host failing exactly this way.
   *
   * Two probes answer "not connected" and the third is up; the run must wait for
   * the third rather than asking for a code nothing could answer.
   */
  it('waits for the host to reach the relay before asking it for a code', async () => {
    const it_ = box({ offRelayFor: 2, relayWaitMs: 400 })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('done')
    expect(final.line).toContain('linked to this computer')
    expect(it_.redeemed).toEqual(['904021'])
  })

  /*
   * And it is a courtesy, not a gate. A host that never reaches the relay still
   * gets its code asked for, and the sentence the person reads is written by the
   * step that actually failed — never by the wait guessing ahead of it.
   */
  it('asks for a code anyway when the relay never comes up', async () => {
    const it_ = box({
      after: OFF_RELAY,
      relayWaitMs: 120,
      codes: ['904021', '111111', '222222'],
      link: { ok: false, message: 'Nothing answered for that code at the relay.' },
    })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    // Three fresh codes, because a miss is retried — and then it stops, which
    // is the other half of the property: a host that is genuinely not on the
    // relay must not be asked forever.
    expect(it_.redeemed).toEqual(['904021', '111111', '222222'])
    expect(final.detail).toContain('nothing at the relay to answer')
  })

  /*
   * The failure this was measured against, as a property.
   *
   * His office PC: the install ran, the host came up, the relay said connected,
   * and two hours later that host was still sitting there with nothing linked to
   * it. One code was minted, one code went unanswered, and the app handed the
   * retry back to him as a sentence. A miss at the relay is a timing accident —
   * the rendezvous behind a code is published a beat after the code exists — so
   * the second code is the app's job, not his.
   */
  it('mints another code when the first one is not answered, and links on it', async () => {
    const it_ = box({
      codes: ['904021', '551180'],
      links: [
        { ok: false, message: 'Nothing answered for that code at the relay.' },
        { ok: true, machineId: THAT_MACHINE, machineName: 'office-pc', deviceFingerprint: OURS },
      ],
    })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('done')
    expect(final.line).toContain('linked to this computer')
    // Two codes, and the second is a different one: a code cannot be re-offered,
    // and a tape read from the start would have handed back the spent one.
    expect(it_.redeemed).toEqual(['904021', '551180'])
    // And the run standing at the relay for a device that was not coming was
    // stopped before the next was asked for, or the second `pair` would have
    // been typed at a prompt.
    expect(it_.typed).toContain(CTRL_C)
  })

  /*
   * And it stops, saying so, in words naming the button underneath it. A retry
   * loop with no end is a machine hammering somebody's server; a failure with no
   * next step is the thing this whole round is against.
   */
  it('gives up after three codes and names the press that tries again', async () => {
    const it_ = box({
      codes: ['904021', '551180', '773301'],
      link: { ok: false, message: 'Nothing answered for that code at the relay.' },
    })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(it_.redeemed).toEqual(['904021', '551180', '773301'])
    expect(final.line).toContain('could not be linked to this computer')
    expect(final.detail).toContain('3 times')
    expect(final.detail).toContain('Link this computer')
    // The steps that did work stay on screen: the host really is installed and
    // running over there, and a panel that read like a failed install would send
    // somebody to undo work that is fine.
    expect(final.done.some((one) => one.includes('Installed'))).toBe(true)
  })

  /*
   * Everything else the far end can say is an *answer*, and an answer is not
   * retried. A host showing somebody else's fingerprint has told this app
   * something; asking it again with a fresh code would be a loop that pairs a
   * stranger three times over.
   */
  it('does not retry a host that answered, only one that did not', async () => {
    const it_ = box({ hostShows: SOMEBODY_ELSE })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('failed')
    expect(it_.redeemed).toHaveLength(1)
  })

  /*
   * A build with no Machines list cannot redeem anything, so it does the honest
   * thing instead of a half-step: it shows the code, exactly as the phone path
   * does. Never a link that reports work it did not do.
   */
  it('shows the code instead when this build cannot redeem one', async () => {
    const it_ = box({ canLink: false })
    const final = await new ServerHosts(it_.deps).install('s1', it_.shell, goodLook(), 'box')
    expect(final.step).toBe('done')
    expect(final.code).toBe('904021')
    expect(it_.redeemed).toEqual([])
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

describe('a code for a phone', () => {
  it('reads the code out of the terminal exactly as it was printed', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    const final = await hosts.pairDevice('s1', it_.shell, '/home/me/.local/bin/terminaldeck')
    expect(final.code).toBe('904021')
    expect(it_.typed[0]).toBe(`'/home/me/.local/bin/terminaldeck' pair --kind mine\n`)
  })

  /*
   * The half that does **not** change, and must not. A phone has no SSH channel
   * to this app, so this app has never met it and holds no key of its own to
   * compare — the fingerprint above that prompt is the only part of pairing a
   * person can actually check, and answering it here would delete the check
   * while appearing to perform it. `ServerHosts.link` answers its own because it
   * has something to compare against; this one has nothing.
   */
  it('never answers the fingerprint question, and never redeems the code itself', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    await hosts.pairDevice('s1', it_.shell, '/home/me/.local/bin/terminaldeck')
    expect(it_.typed.some((one) => one.trim() === 'y')).toBe(false)
    expect(it_.redeemed).toEqual([])
  })
})

describe('linking this computer', () => {
  /*
   * The security argument, as behaviour: no code is shown, and the code that
   * exists is spent by this app over the same connection it was printed on.
   * `ServerHosts.link` carries the full argument for why that is stronger than
   * six digits retyped, not weaker.
   */
  it('spends the code itself and shows nobody anything', async () => {
    const it_ = box()
    const final = await new ServerHosts(it_.deps).link(
      's1',
      it_.shell,
      '/home/me/.local/bin/terminaldeck',
    )
    expect(final.step).toBe('done')
    expect(final.code).toBeNull()
    expect(it_.redeemed).toEqual(['904021'])
    expect(it_.typed[0]).toBe(`'/home/me/.local/bin/terminaldeck' pair --kind mine\n`)
    expect(it_.typed).toContain('y\n')
  })

  /*
   * Stop is a thing the person did, and the line under the terminal has to say
   * so. Left to itself this said "It did not print a pairing code", which reads
   * as a fault on their server for something they pressed.
   */
  it('says it was stopped, rather than blaming the server for going quiet', async () => {
    const it_ = box()
    const hosts = new ServerHosts(it_.deps)
    // A terminal that answers nothing, which is what one closed out from under
    // a run looks like from here.
    const deaf: HostShell = { onData: () => () => undefined, write: () => undefined }
    const started = hosts.link('s1', deaf, '/home/me/.local/bin/terminaldeck')
    await hosts.cancel('s1')
    const final = await started
    expect(final.step).toBe('failed')
    expect(final.line).toContain('Stopped before')
    expect(it_.redeemed).toEqual([])
  })

  /*
   * The one gap no `giveUp` reaches: while the redemption is in flight nothing
   * is waiting on the terminal, so a Stop pressed then lands with no wait to
   * wake. Left unguarded this sat out a forty-five second ceiling and then
   * blamed the server for not printing a device — after the person had taken the
   * terminal away.
   */
  it('answers a Stop pressed while the code is being redeemed', async () => {
    let hosts: ServerHosts | null = null
    const it_ = box({ whileRedeeming: () => void hosts?.cancel('s1') })
    hosts = new ServerHosts(it_.deps)
    const final = await hosts.link('s1', it_.shell, '/home/me/.local/bin/terminaldeck')
    expect(final.step).toBe('failed')
    expect(final.line).toContain('Stopped while linking')
    // And it says what it left behind, which is a real paired-and-unapproved
    // device on that server rather than nothing.
    expect(final.detail).toContain('nothing approved it')
  })

  /*
   * Nothing here takes a machine as an argument. The code is minted by that
   * host, on that connection, and read back off the same one — so this can only
   * ever link the machine whose terminal the caller handed in, which is the
   * whole of why it is not a general "link without a code" door.
   */
  it('can only ever act on the terminal it was handed', async () => {
    const it_ = box()
    await new ServerHosts(it_.deps).link('s1', it_.shell, '/home/me/.local/bin/terminaldeck')
    // Every write went to that shell, and the code came off it.
    expect(it_.typed.length).toBeGreaterThan(0)
    expect(it_.redeemed).toEqual(['904021'])
  })
})

describe('reading a host status', () => {
  it('reads the relay block a host prints, in each of its shapes', () => {
    expect(relayState(readHostProbe(RUNNING).host.status)).toBe('connected')
    expect(relayState(readHostProbe(OFF_RELAY).host.status)).toBe('not-connected')
    expect(relayState('Relay\n  off — this host is not dialling out.')).toBe('off')
    // A host too old to print a Relay block at all says nothing rather than
    // being read as one of the three.
    expect(relayState('Terminal Deck host 0.9.1 — running, idle')).toBe('unknown')
  })

  it('reads the host id, which is what joins a server to a machine row', () => {
    expect(hostIdOf(readHostProbe(RUNNING).host.status)).toBe('P5PCNBABHBBVFDBZZ2ECELNAZ7')
    // Printed only when the relay is connected, and absent is not an empty
    // string that could match a row.
    expect(hostIdOf(readHostProbe(OFF_RELAY).host.status)).toBe('')
  })

  /*
   * The number this app was printing and not reading. Zero is the one answer
   * worth acting on: whatever else may be true, if nothing at all is connected
   * to that host then this computer is not.
   */
  it('reads how many clients that host says are connected to it', () => {
    expect(channelsOf(readHostProbe(NOBODY_ATTACHED).host.status)).toBe(0)
    expect(channelsOf('Relay\n  connected      wss://x\n  channels       3')).toBe(3)
  })

  /*
   * And absent is not zero. A host whose relay is off prints no channel line at
   * all, and reading that silence as "nothing is connected" would turn a host
   * that is deliberately not dialling out into a broken link on the panel.
   */
  it('says it does not know rather than zero when there is no channel line', () => {
    expect(channelsOf(readHostProbe(OFF_RELAY).host.status)).toBeNull()
    expect(channelsOf('Relay\n  off — this host is not dialling out.')).toBeNull()
    expect(channelsOf('')).toBeNull()
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
