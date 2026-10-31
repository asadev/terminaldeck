import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { PROBE_SCRIPT, parseProbe } from './probe.sh'
import { valueOf } from './facts'

/**
 * The probe reader, driven by output three real machines actually produced.
 *
 * Every fixture in `probe-fixtures/` was captured by running the exact script
 * in `PROBE_SCRIPT` — not a paraphrase of it — on a machine over the public
 * internet, and each was chosen because it answers a question differently from
 * the others:
 *
 *   - `ubuntu-administrator.txt` — a real Hetzner box, signed in as the
 *     administrator. Everything answerable is answered.
 *   - `ubuntu-ordinary-account.txt` — the *same machine*, same moment, signed in
 *     as an ordinary account that is not in the sudoers file. Containers become
 *     `present-no-permission`; every listening port loses the name of what owns
 *     it while keeping the port itself.
 *   - `container-nothing-installed.txt` — a Debian container with no init
 *     system, no `ss`, no `netstat` and no web server. Four different honest
 *     answers, none of which is zero.
 *
 * The two Ubuntu fixtures being the same machine is the whole point of having
 * both: every difference between them is caused by *who signed in*, not by what
 * is installed, which is precisely the distinction a two-state model cannot
 * make.
 */

const fixture = (name: string): string =>
  readFileSync(resolve(__dirname, 'probe-fixtures', `${name}.txt`), 'utf8')

const ADMINISTRATOR = fixture('ubuntu-administrator')
const ORDINARY = fixture('ubuntu-ordinary-account')
const CONTAINER = fixture('container-nothing-installed')

const read = (raw: string) => parseProbe(raw, 'server-1', 1_000)

describe('the script that is shipped is the script that was measured', () => {
  it('is POSIX sh, with none of the constructs a minimal server lacks', () => {
    // `bash` is absent from Alpine and from the smallest containers. Each of
    // these is a bash-ism that would fail there with a syntax error, which is
    // the worst possible failure because it takes the whole probe down rather
    // than one question.
    expect(PROBE_SCRIPT).not.toMatch(/\[\[/)
    expect(PROBE_SCRIPT).not.toMatch(/\blocal\s/)
    expect(PROBE_SCRIPT).not.toMatch(/\bdeclare\s/)
    expect(PROBE_SCRIPT).not.toMatch(/<\(/)
    expect(PROBE_SCRIPT).not.toMatch(/\$'/)
  })

  it('ends with the marker that proves it was not cut off', () => {
    expect(PROBE_SCRIPT.trimEnd().endsWith("printf '#end ok\\n'")).toBe(true)
  })

  it('never assumes a tool is there before using it', () => {
    // Every one of these produced a wrong answer somewhere until it was
    // guarded: `systemctl` is absent in a container, `ss` is absent in Debian
    // slim, `docker` is absent on most servers.
    for (const tool of ['systemctl', 'ss', 'netstat', 'docker', 'podman', 'nginx']) {
      const uses = PROBE_SCRIPT.includes(tool)
      const guards =
        PROBE_SCRIPT.includes(`have ${tool}`) ||
        PROBE_SCRIPT.includes(`have "$${tool}"`) ||
        PROBE_SCRIPT.includes(`"$INIT"`) ||
        PROBE_SCRIPT.includes(`"$CTR"`)
      expect(uses && guards).toBe(true)
    }
  })
})

describe('an administrator on a full server', () => {
  const facts = read(ADMINISTRATOR)

  it('reads what the machine is', () => {
    expect(facts.os).toMatchObject({ known: 'yes', value: 'Ubuntu 24.04.4 LTS' })
    expect(facts.init).toMatchObject({ known: 'yes', value: 'systemd' })
    expect(facts.containerRuntime).toMatchObject({ known: 'yes', value: 'docker' })
    expect(facts.packageManager).toMatchObject({ known: 'yes', value: 'apt-get' })
    expect(facts.webServer).toMatchObject({ known: 'yes', value: 'caddy' })
    expect(facts.privilege).toMatchObject({ known: 'yes', value: 'yes' })
  })

  it('names what owns each listening port, which is what makes a card possible', () => {
    const listeners = valueOf(facts.listeners) ?? []
    const web = listeners.find((one) => one.port === 443)
    expect(web?.unit).toBe('caddy.service')
    // The port a person's own program is on, joined to the thing that restarts
    // it. Without this join a card can only say "something called node".
    const broker = listeners.find((one) => one.port === 8787)
    expect(broker?.unit).toBe('terminaldeck-demo-broker.service')
  })

  it('tells apart what somebody added from what the system shipped', () => {
    const services = valueOf(facts.services) ?? []
    const added = services.filter((one) => one.addedHere).map((one) => one.name)
    expect(added).toContain('terminaldeck-demo-broker.service')
    // Installed from a package, so it lives in the system's own directory. It
    // is still obviously the point of the machine — which is why `addedHere` is
    // one input to classification and never a filter on its own.
    expect(added).not.toContain('caddy.service')
  })

  it('reads the addresses out of the web server, rather than guessing one', () => {
    expect(valueOf(facts.siteNames)).toEqual(['178-105-239-176.sslip.io'])
  })

  it('reports a failed service as failed rather than as merely stopped', () => {
    const services = valueOf(facts.services) ?? []
    expect(services.find((one) => one.name === 'cloud-init-hotplugd.service')?.state).toBe('failed')
    expect(services.find((one) => one.name === 'caddy.service')?.state).toBe('running')
  })
})

describe('the same machine, an ordinary account', () => {
  const facts = read(ORDINARY)

  it('says it was not allowed to ask, rather than saying there are none', () => {
    // The failure this exists to prevent: this machine runs containers. An
    // account that cannot ask about them must not produce a page that says
    // there are none.
    expect(facts.containerRuntime.known).toBe('cannot')
    expect(facts.containerRuntime).toMatchObject({
      why: 'This sign-in is not allowed to ask this server about its containers.',
    })
  })

  it('does not treat the presence of the tool as a permission', () => {
    // Measured: an account with the tool installed and no entry in the sudoers
    // file is indistinguishable from one that merely needs to type a password.
    // So this is an unknown, and nothing may promise an action will work on it.
    expect(facts.privilege).toMatchObject({ known: 'yes', value: 'sudo-password' })
  })

  it('keeps the ports it can see and drops only the names it cannot', () => {
    const listeners = valueOf(facts.listeners) ?? []
    expect(listeners.length).toBeGreaterThan(0)
    expect(listeners.map((one) => one.port)).toContain(443)
    // A per-row unknown, not a failure of the whole list — which is what a
    // stricter reader would have turned it into.
    expect(listeners.every((one) => one.unit === '')).toBe(true)
    expect(facts.listeners.known).toBe('yes')
  })

  it('still finds the same machine underneath', () => {
    expect(facts.os).toMatchObject({ known: 'yes', value: 'Ubuntu 24.04.4 LTS' })
    expect(valueOf(facts.siteNames)).toEqual(['178-105-239-176.sslip.io'])
  })
})

describe('a container with none of the things this looks for', () => {
  const facts = read(CONTAINER)

  it('says there is nothing that keeps programs running, and why', () => {
    expect(facts.init).toMatchObject({ known: 'yes', value: 'container-none' })
    expect(facts.services.known).toBe('cannot')
  })

  it('says it has no way to look at what is listening, rather than saying nothing is', () => {
    // The trap: `wc -l` of an absent command is 0, and a two-state model
    // records "0 listening" on a machine where nobody counted.
    expect(facts.listeners.known).toBe('cannot')
    expect(facts.listeners).toMatchObject({
      why: 'This server has no tool installed for listing what is listening.',
    })
  })

  it('separates "no container runtime" from "not allowed to ask"', () => {
    expect(facts.containerRuntime.known).toBe('no')
    expect(facts.webServer.known).toBe('no')
  })

  it('still reads the things a container does know about itself', () => {
    expect(facts.os).toMatchObject({ known: 'yes', value: 'Debian GNU/Linux 12 (bookworm)' })
    expect(facts.packageManager).toMatchObject({ known: 'yes', value: 'apt-get' })
  })
})

describe('output that is not from a healthy run', () => {
  it('ignores anything the server printed that was not asked for', () => {
    // Login banners, MOTDs and "stdin: is not a tty" all arrive on real
    // servers. Refusing to parse because of one is refusing to work on a
    // machine that is fine.
    const noisy = `Welcome to Ubuntu!\nstdin: is not a tty\n${ADMINISTRATOR}`
    expect(read(noisy).os).toMatchObject({ known: 'yes', value: 'Ubuntu 24.04.4 LTS' })
  })

  it('says a section was cut off rather than reporting it empty', () => {
    const cut = ADMINISTRATOR.slice(0, ADMINISTRATOR.indexOf('#listeners'))
    const facts = read(cut)
    expect(facts.listeners.known).toBe('cannot')
    expect(facts.listeners).toMatchObject({
      why: 'The server stopped answering before it finished this check.',
    })
    // What did arrive is still good.
    expect(facts.os.known).toBe('yes')
  })

  it('turns an empty answer into cannot, never into no', () => {
    const facts = read('os=\nkernel=\ncpus=\n#end ok\n')
    expect(facts.os.known).toBe('cannot')
    expect(facts.kernel.known).toBe('cannot')
    expect(facts.cpus.known).toBe('cannot')
  })

  it('refuses a number that is not one', () => {
    expect(read('cpus=lots\n#end ok\n').cpus.known).toBe('cannot')
  })
})

describe('init systems this machine has never run', () => {
  // These two dialects cannot be exercised against the test box, so they are
  // pinned against the shape their own tools print. Getting them wrong would
  // show every service on an Alpine or a BSD server as "unknown", which reads
  // as broken rather than as unsupported.
  it('reads OpenRC states', () => {
    const facts = read(
      ['init=openrc', '#services ok', 'nginx\tstarted\tstarted\t', 'crond\tstopped\tstopped\t', 'x\tcrashed\tcrashed\t', '#end ok'].join('\n'),
    )
    const services = valueOf(facts.services) ?? []
    expect(services.map((one) => one.state)).toEqual(['running', 'stopped', 'failed'])
  })

  it('reads SysV states', () => {
    const facts = read(
      ['init=sysvinit', '#services ok', 'nginx\t+\t+\t', 'cron\t-\t-\t', 'x\t?\t?\t', '#end ok'].join('\n'),
    )
    const services = valueOf(facts.services) ?? []
    expect(services.map((one) => one.state)).toEqual(['running', 'stopped', 'unknown'])
  })

  it('offers no services at all when it cannot tell how the server runs things', () => {
    const facts = read('init=weird\n#end ok\n')
    expect(facts.init.known).toBe('cannot')
    expect(facts.services.known).toBe('cannot')
  })
})

/**
 * The blind spot that would have made this feature offer to install over
 * somebody's working install.
 *
 * Measured, twice, on a real box before any of this was written. The PATH a
 * non-interactive `sh -s` inherits there is
 * `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:…` — and
 * `~/.local/bin` is not in it. `~/.local/bin/claude` is exactly where the
 * official installer puts it, so a bare `command -v claude` answers "not found"
 * about a machine carrying a working, signed-in 2.1.235.
 *
 * The other half is why the obvious repair does not work either: the Ubuntu
 * default `.bashrc` — the one on his own box — opens with
 * `case $- in *i*) ;; *) return;; esac`, which returns before any version
 * manager's block runs, so `$SHELL -lc` cannot see an nvm install. Neither
 * strategy is sufficient alone; the script takes the union of both.
 *
 * This is pinned here rather than left to a comment because the widened PATH
 * list looks like superstition to anybody who has not seen it fail, and the
 * tidying that deletes it produces a wizard that installs 320 MB over a working
 * install and calls it setup.
 */
describe('an agent installed where the exec PATH cannot see it', () => {
  const facts = read(fixture('ubuntu-agent-in-local-bin'))

  it('finds it, with the absolute path that is carried onwards', () => {
    const agents = valueOf(facts.agents) ?? []
    expect(agents.map((one) => one.id)).toEqual(['claude'])
    expect(agents[0]?.path).toBe('/home/asad/.local/bin/claude')
    expect(agents[0]?.version).toBe('2.1.235')
  })

  it('never relies on PATH afterwards, because PATH is what could not find it', () => {
    // The installer says so itself, in as many words: "Native installation
    // exists but ~/.local/bin is not in your PATH." Everything downstream runs
    // the absolute path or it runs nothing.
    expect(PROBE_SCRIPT).toContain('$HOME/.local/bin')
    expect(PROBE_SCRIPT).toContain('.nvm')
  })

  it('takes the union of a widened PATH and the login shell, not one of them', () => {
    expect(PROBE_SCRIPT).toContain('command -v claude; command -v codex; command -v gemini')
    expect(PROBE_SCRIPT).toMatch(/PATH="\$AW" command -v/)
  })

  it('reads whether it is signed in, and who as', () => {
    const agents = valueOf(facts.agents) ?? []
    expect(agents[0]?.signedIn).toBe('yes')
    expect(agents[0]?.account).toBe('asad@example.com')
  })

  it('says what an install would need, so nothing is offered on a guess', () => {
    const room = valueOf(facts.agentInstall)
    expect(room?.downloader).toBe('curl')
    expect(room?.memoryAvailableKb).toBe(6_412_188)
    expect(room?.homeFreeKb).toBe(417_238_528)
  })
})

describe('a server with no agent on it at all', () => {
  const facts = read(fixture('ubuntu-nothing-installed'))

  it('says so as an answer, rather than as a failure to look', () => {
    // An empty list here is a measurement: every place an installer puts one
    // was looked in, and the login shell was asked as well. That is `yes` with
    // nothing in it, and it is what lets the page offer a first install.
    expect(facts.agents.known).toBe('yes')
    expect(valueOf(facts.agents)).toEqual([])
  })

  it('names the two reasons this particular server could not be set up', () => {
    const room = valueOf(facts.agentInstall)
    // Neither downloader, which is the one case where the honest thing is to
    // stop: installing a downloader in order to install an agent is the general
    // provisioning this feature deliberately is not.
    expect(room?.downloader).toBe('')
    // And not enough memory — the installer is killed by the kernel at around
    // this figure, and saying so beforehand costs nothing.
    expect(room?.memoryAvailableKb).toBeLessThan(512 * 1024)
  })
})

describe('an agent that is there and will not run', () => {
  it('is a different answer from an agent that is not there', () => {
    // A root-owned npm global whose node was removed, and a dangling symlink,
    // both satisfy `command -v` and both fail to start. The row arrives with no
    // version, and the offer a person needs then is to install it again — not
    // to install it for the first time, and not nothing at all.
    const facts = read(
      ['#agents ok', 'claude\t/usr/bin/claude\t\tunknown\t', '#end ok'].join('\n'),
    )
    const agents = valueOf(facts.agents) ?? []
    expect(agents).toHaveLength(1)
    expect(agents[0]?.version).toBe('')
    expect(agents[0]?.signedIn).toBe('unknown')
    expect(agents[0]?.account).toBeNull()
  })

  it('drops a row for something it was not looking for', () => {
    const facts = read(['#agents ok', 'copilot\t/usr/bin/copilot\t1.0\tunknown\t', '#end ok'].join('\n'))
    expect(valueOf(facts.agents)).toEqual([])
  })

  it('is cannot, never an empty list, when the section never arrived', () => {
    // The failure this whole third state exists for: a probe that was cut off
    // must not produce a page offering to install over an install nobody looked
    // for.
    const facts = read('os=Ubuntu\n#services ok\n')
    expect(facts.agents.known).toBe('cannot')
    expect(facts.agentInstall.known).toBe('cannot')
  })
})
