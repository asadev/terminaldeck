import { describe, expect, it } from 'vitest'
import {
  describeReachability,
  distroFromRootPath,
  hostKind,
  readHostFacts,
  type HostFacts,
} from './reachability'

const base: HostFacts = {
  platform: 'linux',
  wsl: false,
  distro: null,
  battery: false,
  systemd: true,
  user: 'asad',
}

const facts = (patch: Partial<HostFacts>): HostFacts => ({ ...base, ...patch })

describe('hostKind', () => {
  it('separates the four hosts this build actually runs on', () => {
    expect(hostKind(facts({ wsl: true, distro: 'Ubuntu' }))).toBe('wsl')
    expect(hostKind(facts({ battery: false }))).toBe('linux-server')
    expect(hostKind(facts({ battery: true }))).toBe('linux-laptop')
    expect(hostKind(facts({ platform: 'darwin' }))).toBe('macos')
    expect(hostKind(facts({ platform: 'win32' }))).toBe('windows')
  })

  it('calls a WSL distribution WSL even when it has a battery underneath it', () => {
    // A laptop running WSL reports the laptop's battery through /sys. The thing
    // that will stop this host is Windows shutting the distro down, not sleep.
    expect(hostKind(facts({ wsl: true, battery: true }))).toBe('wsl')
  })
})

describe('readHostFacts', () => {
  it('detects WSL from the environment variable a login shell carries', () => {
    const read = readHostFacts('linux', { WSL_DISTRO_NAME: 'Ubuntu' })
    expect(read.wsl).toBe(true)
    expect(read.distro).toBe('Ubuntu')
  })

  it('prefers the variable, and never consults the fallback off Linux', () => {
    // The variable wins when a login shell set it, so the fallback is not run at
    // all — and off Linux nothing is run and nothing is named, whatever a
    // `wslpath` on this machine might have said.
    expect(readHostFacts('linux', { WSL_DISTRO_NAME: 'Ubuntu' }, () => 'Wrong').distro).toBe('Ubuntu')
    expect(readHostFacts('darwin', {}, () => 'Ubuntu-24.04').distro).toBeNull()
  })

  it('asks nothing of Linux when the platform is not Linux', () => {
    // Running the real reader on this Mac must not report a WSL distro or a
    // battery, whatever /sys happens to hold.
    const read = readHostFacts('darwin', { USER: 'asad' })
    expect(read).toEqual({
      platform: 'darwin',
      wsl: false,
      distro: null,
      battery: false,
      systemd: false,
      user: 'asad',
    })
  })
})

/*
 * The parsing is pinned on its own because the reader that feeds it cannot run
 * here: `wslpath` exists only inside a WSL distribution, and this repository is
 * written and tested on a Mac. The string below is the literal answer
 * `wslpath -w /` gave on Asad's Ubuntu.
 */
describe('distroFromRootPath', () => {
  it('reads the registration name out of the root path, old spelling and new', () => {
    expect(distroFromRootPath('\\\\wsl.localhost\\Ubuntu-24.04\\')).toBe('Ubuntu-24.04')
    expect(distroFromRootPath('\\\\wsl$\\Ubuntu\\')).toBe('Ubuntu')
    // A trailing newline is what execFileSync hands back.
    expect(distroFromRootPath('\\\\wsl.localhost\\Debian\\\n')).toBe('Debian')
  })

  it('answers nothing rather than guessing at a path of another shape', () => {
    // A wrong name here becomes a Task Scheduler entry for a distribution that
    // does not exist, which fails silently until the next Windows restart.
    expect(distroFromRootPath('/')).toBeNull()
    expect(distroFromRootPath('C:\\Users\\asad')).toBeNull()
    expect(distroFromRootPath('')).toBeNull()
    expect(distroFromRootPath('\\\\wsl.localhost\\Ubuntu\\home\\asad')).toBeNull()
  })
})

describe('WSL', () => {
  it('says plainly that a phone finding nothing is not the app being broken', () => {
    const advice = describeReachability(facts({ wsl: true, distro: 'Ubuntu', systemd: false }))
    expect(advice.atRisk).toBe(true)
    expect(advice.detail.join(' ')).toContain('looks exactly like the app being broken')
  })

  it('tells a distribution without systemd to turn it on first', () => {
    const advice = describeReachability(facts({ wsl: true, distro: 'Ubuntu', systemd: false }))
    expect(advice.headline).toContain('systemd is not running')
    expect(advice.steps.join('\n')).toContain('systemd=true')
    expect(advice.steps.join('\n')).toContain('wsl.exe --shutdown')
  })

  it('still calls a distribution with systemd at risk, because Windows decides', () => {
    // The failure this catches is the tempting one: systemd is up, so it looks
    // covered — and Windows still shuts the distro down when the last terminal
    // closes, which systemd inside it cannot do anything about.
    const advice = describeReachability(facts({ wsl: true, distro: 'Ubuntu', systemd: true }))
    expect(advice.atRisk).toBe(true)
    expect(advice.steps.join('\n')).toContain('wsl.exe -d Ubuntu -u asad')
  })

  it('names the linger step, without which a user service dies with the last shell', () => {
    const advice = describeReachability(facts({ wsl: true, distro: 'Ubuntu', systemd: true }))
    expect(advice.steps.join('\n')).toContain('enable-linger asad')
  })

  it('mentions keeping the code on the Linux side of the boundary', () => {
    const advice = describeReachability(facts({ wsl: true, distro: 'Ubuntu', systemd: true }))
    expect(advice.detail.join(' ')).toContain('/mnt/c')
  })
})

describe('Linux', () => {
  it('offers a server no toggle at all, and says why', () => {
    const advice = describeReachability(facts({ battery: false }))
    expect(advice.atRisk).toBe(false)
    expect(advice.headline).toContain('Nothing to do')
    expect(advice.detail.join(' ')).toContain('implies a protection that is not being provided')
  })

  it('gives a server with no systemd no steps rather than steps that will not work', () => {
    const advice = describeReachability(facts({ battery: false, systemd: false }))
    expect(advice.steps).toEqual([])
  })

  it('is honest that a suspended laptop cannot be woken over the relay', () => {
    const advice = describeReachability(facts({ battery: true }))
    expect(advice.atRisk).toBe(true)
    expect(advice.detail.join(' ')).toContain('cannot be woken over the relay')
    expect(advice.steps.join('\n')).toContain('systemd-inhibit')
  })
})

describe('macOS and Windows', () => {
  it('points at the desktop build rather than reimplementing half of it', () => {
    for (const platform of ['darwin', 'win32'] as const) {
      const advice = describeReachability(facts({ platform }))
      expect(advice.steps).toEqual([])
      expect(advice.atRisk).toBe(false)
      expect(advice.detail.join(' ')).toContain('desktop build')
    }
  })

  it('calls the machine what its owner calls it', () => {
    expect(describeReachability(facts({ platform: 'darwin' })).headline).toContain('Mac')
    expect(describeReachability(facts({ platform: 'win32' })).headline).toContain('PC')
  })
})
