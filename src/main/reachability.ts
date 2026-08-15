/**
 * Whether a phone in another country will find this host where it left it — and
 * what, on *this* machine, is worth doing about it.
 *
 * ## Why this is not one toggle
 *
 * The desktop has "keep this machine awake with the lid closed", which is one
 * mechanism because the desktop runs on exactly two kinds of computer. The
 * headless build runs on a Linux server that is already always on, on a laptop
 * that suspends, and inside WSL — which is not a computer at all but a
 * distribution Windows switches off when the last terminal window closes.
 *
 * `HEADLESS.md` is explicit about the failure to avoid: **a toggle that is inert
 * on a server is worse than no toggle, because it implies a protection that is
 * not being provided.** So this module answers a different question per host and
 * is allowed to answer "nothing to do" — which is not a missing feature, it is
 * the true answer on the machine most of these will run on.
 *
 * ## The WSL case, which is the one that will actually bite
 *
 * Close every WSL terminal and Windows shuts the distribution down after an idle
 * timeout, taking this process and every session in it. A phone paired to it
 * then finds nothing there, and *that looks exactly like the app being broken*.
 * It has to be said on screen, before somebody relies on it from abroad, which
 * is why `status` prints this and why the sentences below are written to be read
 * by a person rather than parsed by a panel.
 *
 * ## Everything is a parameter, because none of it can be read here
 *
 * The same argument `platform/host.ts` makes: this repository is written, tested
 * and CI-built on macOS, so a branch that reads `/proc/version` inline is a
 * branch nothing in the suite can reach and whose first user finds the bug.
 * {@link readHostFacts} does the reading, once, and {@link describeReachability}
 * is pure — so `reachability.test.ts` pins a Linux server, a Linux laptop, a WSL
 * distro with systemd and one without, side by side, on one macOS run.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { BRAND } from '../shared/brand'
import { currentPlatform, type Env, type Platform } from './platform/host'

/** What kind of thing this process is running inside. */
export type HostKind = 'wsl' | 'linux-server' | 'linux-laptop' | 'macos' | 'windows'

export interface HostFacts {
  platform: Platform
  /** True when this Linux is a WSL distribution rather than a machine. */
  wsl: boolean
  /** The distribution's name, when WSL told us one. */
  distro: string | null
  /** True when a battery exists, which is what separates a laptop from a server. */
  battery: boolean
  /** True when systemd is PID 1 — under WSL that means `systemd=true` is set. */
  systemd: boolean
  /** The user the process runs as, for the command lines printed below. */
  user: string | null
}

export interface Reachability {
  kind: HostKind
  /** One line, printed first. Says whether anything is at risk. */
  headline: string
  /**
   * The paragraphs under it. Empty only when there is genuinely nothing to say,
   * which never happens today — even "nothing to do" earns a sentence saying
   * why, or the reader assumes the check did not run.
   */
  detail: string[]
  /**
   * Commands to run, in order, or an empty list.
   *
   * Printed verbatim. A step a person has to translate is a step they get wrong,
   * and half of these are one-time `sudo` edits they will not remember.
   */
  steps: string[]
  /**
   * True when this host will stop being reachable without somebody doing the
   * steps. The only field a machine should branch on; everything else is copy.
   */
  atRisk: boolean
}

/* ------------------------------------------------------------------ facts -- */

/**
 * Read the machine, once. The only impure function here, and it touches nothing
 * that can fail loudly: every read is guarded, because a host that cannot answer
 * one of these questions must still start.
 */
export function readHostFacts(
  platform: Platform = currentPlatform(),
  env: Env = process.env,
  rootWindowsPath: () => string | null = wslRootWindowsPath,
): HostFacts {
  if (platform !== 'linux') {
    return { platform, wsl: false, distro: null, battery: false, systemd: false, user: userFrom(env) }
  }

  // Two independent signals, because either can be absent. `WSL_DISTRO_NAME` is
  // set by `wsl.exe` for an interactive shell and is *not* set for a process
  // systemd starts inside the distro — which is exactly the arrangement this
  // module is trying to talk somebody into. `/proc/version` carries "microsoft"
  // in every WSL2 kernel and is there however the process was started.
  const named = env.WSL_DISTRO_NAME
  const kernel = readText('/proc/version')?.toLowerCase() ?? ''
  const wsl = (named !== undefined && named !== '') || kernel.includes('microsoft')

  return {
    platform,
    wsl,
    /*
     * The name, from the environment when it is there and from the filesystem
     * when it is not.
     *
     * The second half is not belt-and-braces. `WSL_DISTRO_NAME` is missing in
     * precisely the arrangement this module exists to recommend — a host systemd
     * started inside the distribution — so on Asad's Ubuntu the advice below
     * printed `wsl.exe -d <your distro> …` as the one step it also calls "not
     * optional". A placeholder inside a command somebody is meant to paste is
     * worse than no command.
     */
    distro: named !== undefined && named !== '' ? named : wsl ? rootWindowsPath() : null,
    // A file rather than a glob: `/sys/class/power_supply` exists on servers too
    // and is empty there, so its *contents* are the signal. `BAT0` is the usual
    // name and `BAT1` the second battery some laptops carry.
    battery: existsSync('/sys/class/power_supply/BAT0') || existsSync('/sys/class/power_supply/BAT1'),
    // The directory systemd creates when it is PID 1. Under WSL it exists only
    // when `/etc/wsl.conf` says `systemd=true`, which is the whole question.
    systemd: existsSync('/run/systemd/system'),
    user: userFrom(env),
  }
}

function readText(file: string): string | null {
  try {
    return readFileSync(file, 'utf8')
  } catch {
    return null
  }
}

/**
 * The distribution's name, pulled out of the Windows path of its own root.
 *
 * `wslpath -w /` answers `\\wsl.localhost\Ubuntu-24.04\` — older builds say
 * `\\wsl$\…` — and that middle component is the registration name, the exact
 * string `wsl.exe -d` wants. It is the only source available to a process
 * systemd started: `WSL_DISTRO_NAME` is not in its environment, `/proc/1/environ`
 * does not carry it either (checked on the real machine), and `/etc/os-release`
 * says "Ubuntu" where the registration is "Ubuntu-24.04".
 *
 * Exported and pure so the parsing can be pinned on a Mac, which is where this
 * repository is written and tested and where `wslpath` does not exist.
 */
export function distroFromRootPath(windowsPath: string): string | null {
  const match = /^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\?$/i.exec(windowsPath.trim())
  return match === null ? null : match[1]
}

/**
 * Ask `wslpath`, and treat every way it can fail as "no name".
 *
 * Guarded like every other read here: a host that cannot answer this question
 * must still start, and off WSL the binary is simply not there. The timeout is
 * because this runs on the launch path — `wslpath` crosses into Windows through
 * interop, and interop wedged is a thing that happens.
 */
function wslRootWindowsPath(): string | null {
  try {
    return distroFromRootPath(
      execFileSync('wslpath', ['-w', '/'], { encoding: 'utf8', timeout: 3000 }),
    )
  } catch {
    return null
  }
}

function userFrom(env: Env): string | null {
  const name = env.USER ?? env.USERNAME ?? env.LOGNAME
  return name !== undefined && name !== '' ? name : null
}

export function hostKind(facts: HostFacts): HostKind {
  if (facts.wsl) return 'wsl'
  if (facts.platform === 'darwin') return 'macos'
  if (facts.platform === 'win32') return 'windows'
  return facts.battery ? 'linux-laptop' : 'linux-server'
}

/* ------------------------------------------------------------------ advice -- */

/** The service name, everywhere it is written. One string, four uses. */
export const SERVICE_NAME = `${BRAND.id}.service`

/** The daemon's own command, as installed. Printed inside the steps. */
export const HOST_COMMAND = `${BRAND.id}-host`

export function describeReachability(facts: HostFacts): Reachability {
  const kind = hostKind(facts)
  const user = facts.user ?? '<your user>'
  const distro = facts.distro ?? '<your distro>'
  /*
   * Say so when the name in that command is a placeholder.
   *
   * `readHostFacts` now finds it in every arrangement seen on a real machine, so
   * this should not appear — but if it ever does, a person pasting the line
   * verbatim would create a Task Scheduler entry for a distribution called
   * "<your distro>", and the failure would only show up the next time Windows
   * restarted. One line naming the command that lists it costs nothing.
   */
  const distroNote =
    facts.distro === null
      ? ['# (this host could not read its own name; "wsl.exe -l -q" on Windows lists it)']
      : []

  if (kind === 'wsl') {
    const shared = [
      'WSL is not a computer that stays on. Close every WSL terminal and Windows ' +
        'shuts this distribution down after an idle timeout, taking this process and every ' +
        'session in it. A phone paired to this host then finds nothing here, which looks ' +
        'exactly like the app being broken.',
      'Two separate things have to be true: something must start this host inside the ' +
        'distribution, and something on Windows must keep the distribution running.',
      'Keep your code in the Linux filesystem (/home/...). Reaching Windows files ' +
        'through /mnt/c, or Linux files through \\\\wsl$, crosses a slow boundary in either ' +
        'direction — and not crossing it is the whole reason to run here.',
    ]

    if (!facts.systemd) {
      return {
        kind,
        headline: 'At risk: systemd is not running in this distribution, and WSL will stop when the last terminal closes.',
        detail: [
          ...shared,
          'systemd is not PID 1 here, so nothing inside the distribution will start this ' +
            'host again after it stops — including after the distribution itself restarts.',
        ],
        steps: [
          "sudo sh -c 'printf \"[boot]\\nsystemd=true\\n\" >> /etc/wsl.conf'",
          '# then, from Windows PowerShell, so the change takes effect:',
          `wsl.exe --shutdown`,
          '# back inside the distribution, install and enable the user service:',
          `${HOST_COMMAND} --install-service`,
          `systemctl --user enable --now ${SERVICE_NAME}`,
          'sudo loginctl enable-linger ' + user,
          '# and on Windows, so the distribution starts at login (Task Scheduler,',
          '# "At log on", run whether or not the user is logged on):',
          ...distroNote,
          `wsl.exe -d ${distro} -u ${user} --exec /bin/true`,
        ],
        atRisk: true,
      }
    }

    return {
      kind,
      headline: 'Partly covered: systemd is running here, but Windows still decides whether this distribution is.',
      detail: [
        ...shared,
        'systemd is PID 1 in this distribution, so the host can be started and restarted ' +
          'from inside it. What that cannot do is bring the distribution back once Windows has ' +
          'shut it down — only Windows can, so the Task Scheduler entry below is not optional.',
        'linger is what keeps a user service running when nobody is logged in. Without it ' +
          'the service stops the moment your last shell exits, which is the same failure with a ' +
          'different cause.',
      ],
      steps: [
        `${HOST_COMMAND} --install-service`,
        `systemctl --user enable --now ${SERVICE_NAME}`,
        `sudo loginctl enable-linger ${user}`,
        '# on Windows, so the distribution starts at login (Task Scheduler,',
        '# "At log on", run whether or not the user is logged on):',
        ...distroNote,
        `wsl.exe -d ${distro} -u ${user} --exec /bin/true`,
      ],
      atRisk: true,
    }
  }

  if (kind === 'linux-server') {
    return {
      kind,
      headline: 'Nothing to do: this machine has no battery and does not suspend on its own.',
      detail: [
        'There is deliberately no switch here. A toggle that does nothing on a server is ' +
          'worse than no toggle, because it implies a protection that is not being provided.',
        facts.systemd
          ? 'systemd is running, so the only thing worth arranging is that this host starts ' +
            'with the machine and is restarted if it dies.'
          : 'systemd is not PID 1 on this machine, so whatever supervises your other services ' +
            'should supervise this one — it is a plain long-running process with no daemon of its own.',
      ],
      steps: facts.systemd
        ? [`${HOST_COMMAND} --install-service`, `systemctl --user enable --now ${SERVICE_NAME}`, `sudo loginctl enable-linger ${user}`]
        : [],
      atRisk: false,
    }
  }

  if (kind === 'linux-laptop') {
    return {
      kind,
      headline: 'At risk while nothing is attached: this machine has a battery and will suspend.',
      detail: [
        'A suspended machine cannot be woken over the relay. Nothing in this app can reach a ' +
          'computer that is asleep — only something outside it can (Wake-on-LAN, or the machine’s ' +
          'own scheduler), and pretending otherwise would be the app claiming a power it does not have.',
        'systemd-inhibit holds off idle and lid sleep for as long as the host runs. It is a ' +
          'real cost in battery, which is why it is a command you choose to run rather than ' +
          'something switched on for you.',
      ],
      steps: [
        `${HOST_COMMAND} --install-service`,
        `systemctl --user enable --now ${SERVICE_NAME}`,
        `sudo loginctl enable-linger ${user}`,
        '# to also hold off idle and lid sleep, run the host under an inhibitor:',
        `systemd-inhibit --what=idle:sleep --why="${BRAND.name} host" ${HOST_COMMAND}`,
      ],
      atRisk: true,
    }
  }

  // macOS and Windows: the desktop build already owns this, and it owns it
  // better — it can hold a wake lock and watch the battery from inside a running
  // app. Saying so is more useful than reimplementing half of it here, and it is
  // the honest answer for the machine a headless host is least likely to be on.
  return {
    kind,
    headline:
      kind === 'macos'
        ? 'Handled by the desktop build on this Mac, not here.'
        : 'Handled by the desktop build on this PC, not here.',
    detail: [
      `${BRAND.name}’s desktop build holds the wake lock and watches the battery, and it can ` +
        'do both from a window that is already running. A headless host on the same machine ' +
        'would be a second thing holding the same lock.',
      'Run the headless host here for what it is good at — a machine with no screen, or one ' +
        'you drive entirely from a phone — and leave staying-awake to the app.',
    ],
    steps: [],
    atRisk: false,
  }
}
