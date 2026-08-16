/**
 * The Linux plan, asked the questions that can be answered without a Linux box.
 *
 * Everything here runs on the Mac this is written on and in CI, which is
 * macOS-only by policy — so nothing in this file may depend on the machine. The
 * escapes are in `linux-escapes.test.ts`, which needs a real kernel and says so.
 *
 * The split matters more than it usually does, because the two halves catch
 * different things. This one catches "the plan is wrong" — a cover that would
 * hide `/usr/local/bin`, a keep that was never emitted, an ordering that puts a
 * cover before the thing it would swallow. That last one is not hypothetical:
 * the first version of `linuxCovers` emitted `/home` and `/home/asad/work`
 * both, the second mount failed with "mount point does not exist" because by
 * then it did not, and every session on a machine where folders live where
 * folders normally live was refused.
 */

import { describe, expect, it } from 'vitest'
import {
  LINUX_CONFINE_SCRIPT,
  linuxCommand,
  linuxCovers,
  linuxKeeps,
  linuxShellLine,
  linuxSpec,
  readProofReport,
  resolvKeep,
  stagePath,
  unsharePath,
  type LinuxMachine,
} from './linux'
import type { ConfinementPlan } from './plan'

/**
 * A machine that exists only in this file.
 *
 * `exists` answers for a fixed set, so a test on a Mac can describe a WSL box —
 * including the one detail that broke a session there, `/etc/resolv.conf` being
 * a symlink into `/mnt/wsl`.
 */
function machine(options: { has?: string[]; links?: Record<string, string>; uid?: number } = {}): LinuxMachine {
  const has = new Set(options.has ?? ['/home', '/tmp', '/var/tmp', '/mnt', '/run/user/1000', '/run/WSL'])
  const links = options.links ?? {}
  return {
    exists: (path) => has.has(path),
    real: (path) => links[path] ?? path,
    uid: options.uid ?? 1000,
  }
}

function planOf(over: Partial<ConfinementPlan> = {}): ConfinementPlan {
  return {
    folder: '/home/asad/work/app',
    accountHome: '/home/asad',
    home: '/home/asad/.config/deck/device-home/abc',
    writable: ['/home/asad/work/app', '/home/asad/.config/deck/device-home/abc'],
    readable: ['/usr', '/bin'],
    readableFiles: [],
    ...over,
  }
}

describe('what a session is not allowed to see', () => {
  it('covers the whole of /home, not just this account', () => {
    // Measured on the machine this was built for: `ls /home` lists three
    // accounts. Covering only `/home/asad` would leave the other two readable,
    // and a home directory that belongs to somebody else is exactly the thing
    // a folder grant must not reach.
    expect(linuxCovers(planOf(), machine())).toContain('/home')
  })

  it('covers the scratch directories and the Windows drives', () => {
    const covers = linuxCovers(planOf(), machine())
    expect(covers).toContain('/tmp')
    expect(covers).toContain('/var/tmp')
    expect(covers).toContain('/mnt')
  })

  it('covers the runtime directory and the interop sockets', () => {
    // `/run/WSL` is the load-bearing one: measured, a Windows binary inside the
    // granted folder still ran with WSL_INTEROP unset, and stopped the moment
    // this directory was covered.
    const covers = linuxCovers(planOf(), machine())
    expect(covers).toContain('/run/user/1000')
    expect(covers).toContain('/run/WSL')
  })

  it('leaves out what is not there, because a mount on a missing target fails', () => {
    const bare = machine({ has: ['/home', '/tmp'] })
    const covers = linuxCovers(planOf(), bare)
    expect(covers).toEqual(['/tmp', '/home'])
  })

  it('asks for no runtime directory when it cannot know the uid', () => {
    // `process.getuid` does not exist on Windows, and the Windows build is
    // exactly what computes a Linux plan for a session inside WSL. `/run/user/-1`
    // would be a mount target that never exists.
    const covers = linuxCovers(planOf(), machine({ uid: -1 }))
    expect(covers.some((dir) => dir.startsWith('/run/user'))).toBe(false)
  })

  it('collapses a cover that another cover already hides', () => {
    // The bug this exists to stop, measured: `/home` went on first and
    // `/home/asad/work` then failed with "mount point does not exist", refusing
    // every session whose folder is under the home directory.
    const covers = linuxCovers(planOf(), machine())
    expect(covers.filter((dir) => dir.startsWith('/home'))).toEqual(['/home'])
  })

  it('covers the neighbours of a folder granted outside the home', () => {
    const plan = planOf({ folder: '/srv/app', writable: ['/srv/app'] })
    const covers = linuxCovers(plan, machine({ has: ['/home', '/tmp', '/srv'] }))
    // A grant on /srv/app must not expose /srv/other.
    expect(covers).toContain('/srv')
  })

  it('refuses to cover a system tree, whatever the folder is', () => {
    // Covering `/usr/local` would take `/usr/local/bin` and `/usr/local/lib`
    // with it, and the session would lose the tools rather than the secrets.
    const plan = planOf({ folder: '/usr/local/src/app', writable: ['/usr/local/src/app'] })
    const covers = linuxCovers(plan, machine({ has: ['/home', '/tmp', '/usr/local/src'] }))
    expect(covers).not.toContain('/usr/local')
    expect(covers).not.toContain('/usr')
  })

  it('covers the account home itself when its parent cannot be covered', () => {
    const plan = planOf({ accountHome: '/root', folder: '/root/app', writable: ['/root/app'] })
    const covers = linuxCovers(plan, machine({ has: ['/root', '/tmp'] }))
    expect(covers).toContain('/root')
    expect(covers).not.toContain('/')
  })
})

describe('what has to survive being covered', () => {
  const has = ['/home', '/tmp', '/var/tmp', '/mnt', '/run/user/1000', '/run/WSL']

  it('keeps the granted folder and the device home, writable', () => {
    const plan = planOf()
    const m = machine({ has: [...has, ...plan.writable] })
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps).toContainEqual({ path: '/home/asad/work/app', mode: 'rw' })
    expect(keeps).toContainEqual({ path: '/home/asad/.config/deck/device-home/abc', mode: 'rw' })
  })

  it('says nothing about a directory no cover would have hidden', () => {
    // `/usr` needs no rule because nothing hides it. Emitting one anyway would
    // add a mount for every entry on the PATH, for nothing.
    const plan = planOf()
    const m = machine({ has: [...has, ...plan.writable, '/usr', '/bin'] })
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps.map((keep) => keep.path)).not.toContain('/usr')
  })

  it('keeps a tool root under the home directory, read-only', () => {
    // The nvm case: `node` lives under the account's home, which is covered, so
    // without this the session has no node at all.
    const nvm = '/home/asad/.nvm/versions/node/v22'
    const plan = planOf({ readable: ['/usr', nvm] })
    const m = machine({ has: [...has, ...plan.writable, nvm] })
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps).toContainEqual({ path: nvm, mode: 'ro' })
  })

  it('keeps the credential helper as a file, so its folder stays closed', () => {
    const helper = '/home/asad/.config/deck/guest-git/askpass.sh'
    const plan = planOf({ readableFiles: [helper] })
    const m = machine({ has: [...has, ...plan.writable, helper] })
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps).toContainEqual({ path: helper, mode: 'file' })
  })

  it('drops a keep that is no longer on disk', () => {
    const plan = planOf()
    const m = machine({ has: [...has, '/home/asad/work/app'] })
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps.map((keep) => keep.path)).toEqual(['/home/asad/work/app'])
  })

  it('restores a directory named twice as writable rather than read-only', () => {
    const plan = planOf({ readable: ['/home/asad/work/app'] })
    const m = machine({ has: [...has, ...plan.writable] })
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps.filter((keep) => keep.path === '/home/asad/work/app')).toEqual([
      { path: '/home/asad/work/app', mode: 'rw' },
    ])
  })

  it('keeps resolv.conf when the distribution hides it inside /mnt', () => {
    // Measured, and it broke the session rather than the boundary: on WSL
    // `/etc/resolv.conf` is a symlink to `/mnt/wsl/resolv.conf`, so covering
    // `/mnt` left `curl` answering 000 and `git ls-remote` refusing to connect.
    const plan = planOf()
    const m = machine({
      has: [...has, ...plan.writable, '/mnt/wsl/resolv.conf'],
      links: { '/etc/resolv.conf': '/mnt/wsl/resolv.conf' },
    })
    expect(resolvKeep(m)).toBe('/mnt/wsl/resolv.conf')
    const keeps = linuxKeeps(plan, linuxCovers(plan, m), m)
    expect(keeps).toContainEqual({ path: '/mnt/wsl/resolv.conf', mode: 'file' })
  })

  it('says nothing about resolv.conf on a distribution that keeps it in /etc', () => {
    expect(resolvKeep(machine())).toBeNull()
  })
})

describe('the words the script reads', () => {
  const plan = planOf()
  const m = machine({ has: ['/home', '/tmp', '/mnt', ...plan.writable] })
  const stage = stagePath('abc123')
  const spec = linuxSpec(plan, m, stage)

  it('names the staging directory first, because everything else needs it', () => {
    expect(spec[0]).toBe(`S:${stage}`)
  })

  it('names the directory to enter, which is what closes the relative-path escape', () => {
    expect(spec[1]).toBe('D:/home/asad/work/app')
  })

  it('covers the tree the staging directory lives in last', () => {
    // /tmp holds the staging area, so it cannot be covered until the staged
    // copies have been bound into place and unmounted.
    expect(spec).toContain('L:/tmp')
    expect(spec).toContain('C:/home')
    expect(spec.filter((word) => word.startsWith('L:'))).toEqual(['L:/tmp'])
  })

  it('puts every cover before every keep', () => {
    const lastCover = spec.map((w) => w[0]).lastIndexOf('C')
    const firstKeep = spec.findIndex((word) => word.startsWith('W:') || word.startsWith('R:'))
    expect(lastCover).toBeLessThan(firstKeep)
  })
})

describe('the command', () => {
  const plan = planOf()
  const m = machine({ has: ['/home', '/tmp', '/usr/bin/unshare', ...plan.writable] })

  it('asks for every namespace the boundary needs', () => {
    const launch = linuxCommand(plan, '/bin/zsh', ['-l'], m, stagePath('abc'))
    // `--map-root-user` and not `--map-current-user`: measured, a non-root euid
    // loses every capability at the exec and cannot mount at all.
    expect(launch.args).toContain('--map-root-user')
    expect(launch.args).toContain('--propagation=private')
    // The PID namespace is not decoration: without it a confined session killed
    // a process of the account's outside the boundary.
    expect(launch.args).toContain('--pid')
    expect(launch.args).toContain('--fork')
    expect(launch.args).toContain('--mount-proc')
  })

  it('ends with the command it was given, after the separator', () => {
    const launch = linuxCommand(plan, '/bin/zsh', ['-l'], m, stagePath('abc'))
    const at = launch.args.indexOf('--')
    expect(launch.args.slice(at)).toEqual(['--', '/bin/zsh', '-l'])
  })

  it('uses the absolute unshare when it can see one, and the bare name otherwise', () => {
    expect(unsharePath(m)).toBe('/usr/bin/unshare')
    // The Windows build computing a plan for a session inside WSL cannot stat a
    // file on the other side of the boundary; the login shell over there looks
    // it up on the PATH.
    expect(unsharePath(machine({ has: [] }))).toBe('unshare')
  })

  it('quotes a folder with a space when it has to become a shell line', () => {
    const spaced = planOf({
      folder: '/home/asad/my work',
      writable: ['/home/asad/my work'],
    })
    const line = linuxShellLine(spaced, '/bin/sh', ['-c', 'echo hi'], machine({ has: ['/home', '/tmp', '/home/asad/my work'] }), stagePath('abc'))
    expect(line.startsWith('exec ')).toBe(true)
    expect(line).toContain(`'D:/home/asad/my work'`)
    // And the command's own arguments survive it.
    expect(line).toContain(`'echo hi'`)
  })
})

describe('the script itself', () => {
  it('carries no half-built template', () => {
    // A `${…}` that JavaScript filled in would be a shell script with a plan
    // baked into it, which is the thing this design refuses: everything varies
    // through arguments so that a folder name cannot change what runs.
    expect(LINUX_CONFINE_SCRIPT).not.toContain('undefined')
    expect(LINUX_CONFINE_SCRIPT).not.toContain('[object')
  })

  it('stops at the first failure, because a cover that quietly failed is a leak', () => {
    expect(LINUX_CONFINE_SCRIPT).toContain('set -eu')
  })

  it('never removes anything recursively', () => {
    // The cleanup runs next to bind mounts of the account's home directory. A
    // recursive remove that followed one of those would delete the very thing
    // the boundary exists to protect, so the only removals in here are `rmdir`
    // and `rm -f`, neither of which can descend.
    expect(LINUX_CONFINE_SCRIPT).not.toMatch(/rm\s+-[a-z]*r/)
  })

  it('drops the capabilities that make the whole thing more than decoration', () => {
    // Measured before this file existed: without the bounding set dropped, a
    // shell inside simply ran `umount /home` and read the canary.
    expect(LINUX_CONFINE_SCRIPT).toContain('--bounding-set=-all')
    expect(LINUX_CONFINE_SCRIPT).toContain('--inh-caps=-all')
    expect(LINUX_CONFINE_SCRIPT).toContain('--no-new-privs')
  })

  it('shuts the two doors that are not filesystem paths', () => {
    expect(LINUX_CONFINE_SCRIPT).toContain('unset WSL_INTEROP')
    // Descriptors 3 to 9 — every one a POSIX shell can name. An inherited
    // descriptor on a directory outside the boundary was a measured escape.
    expect(LINUX_CONFINE_SCRIPT).toContain('exec 3<&- 4<&- 5<&- 6<&- 7<&- 8<&- 9<&-')
  })

  it('enters the granted folder, which is the escape that would have shipped', () => {
    expect(LINUX_CONFINE_SCRIPT).toContain('cd "$td_cwd"')
  })
})

describe('the proof report', () => {
  it('reads back what the probe printed', () => {
    const report = readProofReport(
      ['td-token abc', 'td-home ', 'td-tmp ', 'td-interop none', 'td-runwsl ', 'td-uid 0'].join('\n'),
    )
    expect(report).toEqual({ token: 'abc', home: '', tmp: '', interop: 'none', runwsl: '', uid: '0' })
  })

  it('answers empty for a line that never arrived, rather than undefined', () => {
    // The proof compares these to secrets. An `undefined` leaking into that
    // comparison would read as "the canary did not come back", which is the
    // answer that means the boundary held.
    expect(readProofReport('').home).toBe('')
    expect(readProofReport('nonsense').token).toBe('')
  })
})
