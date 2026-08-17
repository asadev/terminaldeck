/**
 * The demo host's policy, and the fence around the switch that turns it on.
 *
 * Two kinds of test live here and the second kind is the important one. The
 * first exercises what public-host mode *does* — approve, grant one folder, end
 * itself. The second asserts what nothing else may do: the desktop and the
 * ordinary headless daemon must not be able to reach this mode, because the
 * thing it switches off is the second of the two gates in `device-auth.ts` and a
 * host that entered it through configuration drift would be a remote shell
 * vulnerability rather than a demo.
 */

import { mkdtempSync, readdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it, vi } from 'vitest'
import { RemoteAuth, type Device } from '../main/remote/device-auth'
import { CAPABILITIES, CAPABILITY } from '../main/remote/protocol'
import { authenticatorFor, pairingDesk } from '../main/remote/server'
import {
  createPublicHost,
  PUBLIC_HOST_DEFAULTS,
  PUBLIC_HOST_OFFER,
  type PublicHostConfig,
} from './public-host'
import { configFromEnv } from './demo'

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = join(HERE, '..')

const CONFIG: PublicHostConfig = {
  playground: '/home/visitor/playground',
  lifetimeMs: 20_000,
  arrivalMs: 5_000,
  graceMs: 1_000,
}

const device = (patch: Partial<Device> = {}): Device => ({
  id: 'dev-1',
  name: 'Reviewer iPhone',
  addedAt: 0,
  lastSeenAt: null,
  approved: false,
  revoked: false,
  status: 'pending',
  fingerprint: 'AAAA-BBBB',
  ...patch,
})

function harness(config: PublicHostConfig = CONFIG) {
  const approved: string[] = []
  const granted: Array<{ id: string; folders: string[] }> = []
  const ended: string[] = []
  const host = createPublicHost({
    config,
    approve: (id) => {
      approved.push(id)
      return true
    },
    grant: (id, folders) => granted.push({ id, folders }),
    end: (reason) => ended.push(reason),
  })
  return { host, approved, granted, ended }
}

/* --------------------------------------------------------------- the trade -- */

describe('a device that redeems a code the demo host just minted', () => {
  it('is approved and given the playground and nothing else', () => {
    const { host, approved, granted } = harness()
    host.paired(device())
    expect(approved).toEqual(['dev-1'])
    // Exactly the playground. Leaving the list unwritten would fall back to
    // "this host's projects, then its home directory" — which on the demo box is
    // the host's own home, its state directory and its control token included.
    expect(granted).toEqual([{ id: 'dev-1', folders: ['/home/visitor/playground'] }])
  })

  it('is given the folder list even when the approval did not take', () => {
    // `approveDevice` answers false for a device that is already approved or has
    // been revoked. Neither is a reason to leave a device on the fallback list.
    const granted: Array<{ id: string; folders: string[] }> = []
    const host = createPublicHost({
      config: CONFIG,
      approve: () => false,
      grant: (id, folders) => granted.push({ id, folders }),
      end: () => undefined,
    })
    host.paired(device())
    expect(granted).toEqual([{ id: 'dev-1', folders: ['/home/visitor/playground'] }])
  })
})

describe('the whole trade, against the real trust store', () => {
  /*
   * The unit tests above watch the policy call `approve`. This watches what
   * `approve` *does*, through the objects that actually run in a demo container:
   * a real `RemoteAuth` on a real file, a real `PairingDesk`, and the real
   * `authenticatorFor` that decides whether a device gets in.
   *
   * It exists because the interesting claim in this whole feature is one
   * sentence long — "a device that redeems a code this host just minted is let
   * in, and one that does not is not" — and a test that stubbed the trust store
   * could assert it while the wiring underneath was cut. That is the failure
   * this repository keeps re-finding.
   */
  const harnessed = async () => {
    const dir = mkdtempSync(join(tmpdir(), 'td-public-host-'))
    const auth = new RemoteAuth(dir)
    // `startBeacon` replaced: a unit test may not publish a rendezvous slot at
    // the live relay, and the beacon is not what is under test here. These tests
    // mint with `create`, which never publishes, so it is never called — the
    // stub is there so that a future `show` cannot quietly dial out.
    const desk = pairingDesk(auth, Date.now, () => null)
    const policy = createPublicHost({
      config: CONFIG,
      approve: (id) => auth.approveDevice(id),
      grant: () => undefined,
      end: () => undefined,
    })
    const authenticator = authenticatorFor(auth, desk, (device) => policy.paired(device))
    return { dir, auth, desk, authenticator }
  }

  const device = { name: 'Reviewer iPhone', platform: 'ios' as const }

  it('lets in a device that redeemed the code this host minted', async () => {
    const { auth, desk, authenticator } = await harnessed()
    const token = desk.create().token

    // First contact: the code is spent, a credential comes back, and the
    // connection is still refused — that is the product's behaviour and it does
    // not change here. What changes is what the roster says afterwards.
    const paired = await authenticator.authenticate(token, device, '1.2.3.4')
    expect(paired.ok).toBe(false)
    expect(paired.credential).toBeTruthy()

    const roster = auth.listDevices()
    expect(roster).toHaveLength(1)
    expect(roster[0].approved).toBe(true)

    // Second contact, with the credential it was given: now it is in. On a host
    // anybody owns this would still be refused until a human pressed Approve.
    const back = await authenticator.authenticate(paired.credential as string, device, '1.2.3.4')
    expect(back.ok).toBe(true)
  })

  it('refuses a code this host did not mint, demo or not', async () => {
    const { auth, authenticator } = await harnessed()
    const guessed = await authenticator.authenticate('AAAA-BBBB', device, '1.2.3.4')
    expect(guessed.ok).toBe(false)
    expect(guessed.credential).toBeFalsy()
    // And nothing was created, so there is nothing to have been approved.
    expect(auth.listDevices()).toEqual([])
  })

  it('refuses the same code twice, so a shoulder-surfer gets nothing', async () => {
    // Single use is the property auto-approval leans on hardest: the broker
    // allocated this container for one visitor, and the code is how that visitor
    // is recognised. A second redemption would be a second stranger.
    const { auth, desk, authenticator } = await harnessed()
    const token = desk.create().token
    await authenticator.authenticate(token, device, '1.2.3.4')
    const again = await authenticator.authenticate(token, device, '5.6.7.8')
    expect(again.ok).toBe(false)
    expect(again.credential).toBeFalsy()
    expect(auth.listDevices()).toHaveLength(1)
  })
})

/* ----------------------------------------------------------- the lifecycle -- */

describe('the demo host ending itself', () => {
  it('gives its slot back when nobody ever arrives', () => {
    vi.useFakeTimers()
    try {
      const { host, ended } = harness()
      host.begin()
      vi.advanceTimersByTime(CONFIG.arrivalMs + 1)
      expect(ended).toEqual(['nobody paired with this machine, so its slot goes back'])
    } finally {
      vi.useRealTimers()
    }
  })

  it('does not give its slot back when somebody did arrive', () => {
    vi.useFakeTimers()
    try {
      const { host, ended } = harness()
      host.begin()
      host.attached(1)
      vi.advanceTimersByTime(CONFIG.arrivalMs + 1)
      expect(ended).toEqual([])
      host.dispose()
    } finally {
      vi.useRealTimers()
    }
  })

  it('waits out the grace period before ending, so a phone can come back', () => {
    /*
     * The failure this prevents is the one that would make the demo look
     * broken in exactly the situation the product is for: a screen lock, a
     * lift, or walking between two wifi networks drops the socket for a few
     * seconds and the client reconnects on its own.
     */
    vi.useFakeTimers()
    try {
      const { host, ended } = harness()
      host.begin()
      host.attached(1)
      host.attached(0)
      vi.advanceTimersByTime(CONFIG.graceMs - 1)
      expect(ended).toEqual([])
      host.attached(1)
      vi.advanceTimersByTime(CONFIG.graceMs * 5)
      expect(ended).toEqual([])
      host.dispose()
    } finally {
      vi.useRealTimers()
    }
  })

  it('ends after the grace period when the visitor really has gone', () => {
    vi.useFakeTimers()
    try {
      const { host, ended } = harness()
      host.begin()
      host.attached(1)
      host.attached(0)
      vi.advanceTimersByTime(CONFIG.graceMs + 1)
      expect(ended).toEqual(['the visitor left'])
    } finally {
      vi.useRealTimers()
    }
  })

  it('ends at the hard limit however busy the visitor is', () => {
    vi.useFakeTimers()
    try {
      const { host, ended } = harness()
      host.begin()
      host.attached(1)
      vi.advanceTimersByTime(CONFIG.lifetimeMs + 1)
      expect(ended).toEqual(['this machine reached its twenty-minute limit'])
    } finally {
      vi.useRealTimers()
    }
  })

  it('ends once, however many deadlines expire together', () => {
    // The lifetime cap and a grace period can land in the same tick, and on the
    // demo box `end` is what stops the process.
    vi.useFakeTimers()
    try {
      const { host, ended } = harness({ ...CONFIG, lifetimeMs: 2_000, graceMs: 2_000 })
      host.begin()
      host.attached(1)
      host.attached(0)
      vi.advanceTimersByTime(10_000)
      expect(ended).toHaveLength(1)
    } finally {
      vi.useRealTimers()
    }
  })
})

/* ---------------------------------------------------------------- what it says -- */

describe('what the demo host tells people about itself', () => {
  it('says in status that it approves anything and where that ends', () => {
    const { host } = harness()
    const sentence = host.sentence()
    expect(sentence).toContain('PUBLIC DEMO HOST')
    expect(sentence).toContain('approves any device')
    expect(sentence).toContain('/home/visitor/playground')
    expect(sentence).toContain('Never run this on a machine you care about')
  })

  it('warns the visitor that the firewall is deliberate, not a fault', () => {
    // A reviewer who types `git clone`, watches it fail and reads that as a
    // broken app is a rejection we wrote ourselves.
    const motd = harness().host.motd()
    expect(motd).toContain('real Linux machine')
    expect(motd).toContain('firewalled')
    expect(motd).toMatch(/git.*npm.*curl/)
    expect(motd).toContain('destroyed when you disconnect')
  })

  it('fits on a phone, which is the only screen that will ever read it', () => {
    /*
     * Measured, not chosen. On a clean simulator paired to the live demo box, an
     * iPhone 17 in portrait answered `stty size` with **26 54**. The motd was
     * written in lines of up to 74 characters, so the reviewer's first screen
     * broke every long line mid-word — `running the r` / `eal Terminal Deck
     * host.` — which reads as a broken app rather than as a greeting.
     *
     * Fifty-four is the *widest* phone in the range: a smaller handset, larger
     * dynamic type or a split view all take columns away. Forty-four leaves ten
     * columns of margin.
     *
     * This assertion exists because the natural way to edit a motd is to improve
     * a sentence in an editor eighty columns wide and never see it on a phone.
     * The three `toContain` checks above guard the *meaning*; this one guards the
     * shape, and the shape is the half that was actually wrong.
     */
    const PHONE_COLUMNS = 44
    const tooWide = harness()
      .host.motd()
      .split('\n')
      .filter((line) => line.length > PHONE_COLUMNS)
    expect(tooWide).toEqual([])
  })

  it('still fits when the lifetime is a three-digit number of minutes', () => {
    // The one interpolated value in the text. A demo box started with a longer
    // cap must not push its own line past the ceiling above — which is the sort
    // of thing that is only ever noticed on the reviewer's screen.
    const { host } = harness({ ...CONFIG, lifetimeMs: 999 * 60_000 })
    const widest = Math.max(...host.motd().split('\n').map((line) => line.length))
    expect(widest).toBeLessThanOrEqual(44)
  })
})

/* ------------------------------------------------------------- the narrowing -- */

describe('what a public host offers', () => {
  it('is `create` and nothing else', () => {
    expect(PUBLIC_HOST_OFFER).toEqual([CAPABILITY.create])
  })

  it('leaves out every capability this build knows how to serve', () => {
    // Written as a difference rather than as a list, so that a capability added
    // to `CAPABILITIES` later is off by default on the demo host and somebody
    // has to come here to change that on purpose.
    const withheld = CAPABILITIES.filter((name) => !PUBLIC_HOST_OFFER.includes(name))
    expect(withheld).toEqual([
      CAPABILITY.localhost,
      CAPABILITY.upload,
      CAPABILITY.credential,
      // `devserver` joined this list the day it was built, and it is exactly the
      // kind of capability this test exists to catch. It reads a `package.json`
      // and then *runs a command out of it* — on a box that is handed to
      // strangers for the App Store review, whose whole design is that a guest
      // gets a throwaway container and nothing else. The demo needs a terminal;
      // it does not need to start anybody's dev server.
      CAPABILITY.devserver,
      /*
       * `copilot` is the sharpest instance of this rule yet, and it is withheld
       * twice over.
       *
       * The demo box hands a shell to a stranger who has never met the owner.
       * The copilot is the opposite of that by the owner's own words, which are
       * the reason the whole feature is a per-device grant rather than a
       * setting: *"we usually might not give this copilot to others… we don't
       * want to give this copilot to others to see how we use it. This will be
       * only ours."*
       *
       * Twice over because the demo assembly constructs no run manager at all,
       * and `server.ts` reads the capability off that object rather than off a
       * constant — so a demo host would not advertise it even if this list were
       * wrong. Both hold on purpose: the offer list is the decision, and the
       * absent object is what makes the advertisement unable to outlive the
       * thing it advertises.
       */
      CAPABILITY.copilot,
    ])
  })
})

/* ------------------------------------------------------------------ the fence -- */

describe('the mode cannot be entered by a host anybody owns', () => {
  const reads = (path: string): string => readFileSync(join(SRC, path), 'utf8')

  it('is not reachable from the desktop app', () => {
    const index = reads('main/index.ts')
    expect(index).not.toMatch(/public-host/)
    expect(index).not.toMatch(/headless\/demo/)
    expect(index).not.toMatch(/publicHost/)
  })

  it('is not reachable from the ordinary headless daemon', () => {
    // `daemon.ts` is what `terminaldeck-host` runs and what the systemd unit
    // starts. If it ever grows a way into this mode, a server somebody installed
    // this on could be talked into approving strangers.
    const daemon = reads('headless/daemon.ts')
    expect(daemon).not.toMatch(/public-host/)
    expect(daemon).not.toMatch(/publicHost/)
  })

  it('is not switched on by an environment variable anywhere', () => {
    /*
     * The strongest form of the rule and the reason `demo.ts` is a separate
     * program. An environment variable can be inherited by a child, set in a
     * systemd drop-in, baked into a base image or typed by mistake; a second
     * entry point cannot be arrived at by accident.
     *
     * `demo.ts` does read the environment — for the lifetime and the playground
     * path, which are knobs on a mode that is already on — and this asserts that
     * none of them is the switch itself.
     */
    // Comments stripped first, and that is not pedantry: this file's own prose
    // says the policy never looks at `process.env`, and a test that matched the
    // sentence describing the rule instead of the code obeying it would fail on
    // the documentation and pass on a violation.
    expect(code(reads('headless/host.ts'))).not.toMatch(/process\.env\.[A-Z_]*(PUBLIC|DEMO)/)
    expect(code(reads('headless/public-host.ts'))).not.toMatch(/process\.env/)
  })

  it('is turned on by exactly one file in the tree', () => {
    // A grep over the whole of `src`, deliberately: the two assertions above
    // name the files that must not do it, and this one fails when *anything*
    // else starts. `publicHost?:` — the option's declaration in `host.ts` — does
    // not match, because a type is not a caller.
    const found = walk(SRC)
      .filter((file) => /\bpublicHost:\s*\{/.test(readFileSync(file, 'utf8')))
      // Separators folded to `/` before comparing. This is a list of source
      // paths written as prose in an assertion, and on Windows the same file is
      // `headless\demo.ts` — so the check failed on the runner that builds the
      // Windows installer while passing everywhere a developer would look.
      .map((file) => file.slice(SRC.length + 1).split(sep).join('/'))
      .sort()
    expect(found).toEqual(['headless/demo.ts'])
  })
})

/* --------------------------------------------------------------- the knobs -- */

describe('the config the broker may set', () => {
  it('falls back to the defaults when nothing is set', () => {
    expect(configFromEnv({})).toEqual(PUBLIC_HOST_DEFAULTS)
  })

  it('reads minutes, because the broker thinks in slots rather than milliseconds', () => {
    const config = configFromEnv({ TERMINALDECK_DEMO_LIFETIME_MINUTES: '5' })
    expect(config.lifetimeMs).toBe(300_000)
  })

  it('refuses a value that is not a number rather than arming a timer that never fires', () => {
    // `Number('soon')` is NaN, and `setTimeout(fn, NaN)` fires immediately —
    // which on this policy means a container that ends before its visitor
    // arrives, every time, with nothing in any log to say why.
    const warn = vi.spyOn(process.stderr, 'write').mockReturnValue(true)
    try {
      expect(configFromEnv({ TERMINALDECK_DEMO_LIFETIME_MINUTES: 'soon' }).lifetimeMs).toBe(
        PUBLIC_HOST_DEFAULTS.lifetimeMs,
      )
      expect(configFromEnv({ TERMINALDECK_DEMO_ARRIVAL_MINUTES: '-3' }).arrivalMs).toBe(
        PUBLIC_HOST_DEFAULTS.arrivalMs,
      )
      expect(warn).toHaveBeenCalled()
    } finally {
      warn.mockRestore()
    }
  })

  it('refuses a playground that is not an absolute path', () => {
    expect(configFromEnv({ TERMINALDECK_DEMO_PLAYGROUND: '../..' }).playground).toBe(
      PUBLIC_HOST_DEFAULTS.playground,
    )
    expect(configFromEnv({ TERMINALDECK_DEMO_PLAYGROUND: '/srv/play' }).playground).toBe('/srv/play')
  })
})

/**
 * Source with its comments removed.
 *
 * This codebase explains itself at length, so a great deal of its prose contains
 * the exact identifiers a guard like the one above is looking for. Matching the
 * text as written would make every rule fail on its own explanation.
 */
function code(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
}

/** Every `.ts` under `src`, skipping nothing — the guard above depends on that. */
function walk(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...walk(path))
    else if (entry.name.endsWith('.ts') || entry.name.endsWith('.tsx')) out.push(path)
  }
  return out
}
