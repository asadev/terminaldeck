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
      /*
       * `close` is withheld even though `create` is not, and the pair is the
       * clearest statement of what this list is for.
       *
       * A visitor to the demo box is given a shell so they can see the product
       * work. Ending a session is the one verb on this wire that destroys
       * somebody else's work in progress, and the box is a *shared* machine in
       * the only sense that matters here: the broker allocates it, the owner's
       * own tooling runs on it, and there is no human at the screen to notice a
       * session going away. Starting something is additive and bounded by the
       * container; ending something is not either of those.
       */
      CAPABILITY.close,
      /*
       * `rename` sits with `close` and not with `create`, though it destroys
       * nothing. It is a write to somebody else's row — the demo box is shared
       * in the sense that matters, and a visitor who could relabel every
       * session on it could make the owner's own list lie to the owner.
       */
      CAPABILITY.rename,
      CAPABILITY.upload,
      CAPABILITY.credential,
      /*
       * `github` is withheld for the same reason `settings` and `logins` are: it
       * signs the *machine* into a GitHub account, and the demo box is a shared
       * machine handed to a stranger for the App Store review. A visitor who
       * could press Connect would point the box's git at their own account, or
       * read whose it is already on. The public assembly also passes no
       * `hostGitHub`, so it could not advertise it even if this list let it —
       * withheld twice, the belt-and-braces `copilot` gets.
       */
      CAPABILITY.github,
      /*
       * `host.control` is withheld for the same reason `github` above it is: it
       * restarts and stops the *machine's* host, and the demo box is a shared
       * machine handed to a stranger for the App Store review. A visitor who
       * could press Restart would take the box down under everyone on it. The
       * public assembly also passes no `hostLifecycle`, so it could not
       * advertise it even if this list let it — withheld twice.
       */
      CAPABILITY.hostControl,
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
      // A routine is a prompt this machine runs with this machine's tools in
      // this machine's folders. Starting one from a stranger's shell is the
      // copilot's own refusal, one capability along.
      CAPABILITY.routines,
      /*
       * And its **files**, which is `copilot` one notch sharper still.
       *
       * What this surface carries is the copilot's own instructions, the tool
       * contract it was handed, and the name and description of every fact it
       * has ever written down about the owner's machines. There is no version of
       * a demo box on which a stranger reads that.
       *
       * Withheld twice over like `copilot` itself, and by the same two
       * mechanisms: the offer list is the decision, and the demo assembly
       * constructs neither a run manager nor a files seam — and `serves` in
       * `server.ts` requires **both** before it advertises this name, precisely
       * because these frames ride the copilot's own connection ceremony.
       */
      CAPABILITY.copilotFiles,
      /*
       * `web` is withheld for the same reason and by the same two mechanisms.
       *
       * It opens a page **on the host's screen**, in a tab of that machine's own
       * browser. On a box handed to a stranger for an App Store review, that is
       * a way to put an arbitrary website in front of whoever is watching it —
       * and there is no folder grant, no confinement and no session boundary
       * that has anything to say about a window.
       *
       * Twice over, again: the demo assembly passes no `openUrl`, and
       * `server.ts` reads the capability off that function rather than off a
       * constant, so a demo host could not advertise it even if this list were
       * wrong. The headless daemon is in the same position for a duller reason
       * — it has no window at all.
       */
      CAPABILITY.web,
      /*
       * `controls` is withheld, and it is the one on this list that is closest
       * to being harmless — which is exactly why the reason has to be written
       * down rather than assumed.
       *
       * It reads a session's model and effort off that session's screen, and
       * `controls.apply` **types a slash command into the pty**. On a box handed
       * to a stranger for an App Store review, the first half is a way to read
       * the owner's account configuration off a screen a guest was never shown,
       * and the second is a keystroke into a session — bounded by the same
       * `visible` rule `input` is, but bounded by nothing else. The demo needs a
       * terminal that works; it does not need a model picker.
       *
       * Withheld by the offer list alone here, not twice over: the demo assembly
       * builds its session layer from the same `SessionFanout` a desktop does,
       * so the object behind this capability genuinely exists on that box. That
       * makes this line load-bearing rather than belt-and-braces, and it is the
       * whole reason `options.offer` is checked first in `server.ts`.
       */
      CAPABILITY.controls,
      /*
       * `usage` is withheld for the same reason as `controls`, and it is a
       * sharper version of it: what it reports is not a session's configuration
       * but **the owner's own subscription**.
       *
       * Two of its three readings are what that machine has spent against its
       * plan and how full a conversation's context window is; the third boots
       * the owner's agent CLI on that box to go and fetch a fresh figure. On a
       * machine handed to a stranger for an App Store review, the first is
       * somebody's account statement and the third is a stranger causing a 725
       * MB process to start on hardware they do not own. The demo needs a
       * terminal that works; it does not need to say what the owner's plan has
       * left in it.
       *
       * Load-bearing rather than belt-and-braces, exactly like `controls` above
       * and for the same mechanical reason: the demo builds its session layer
       * through `createHostCore`, so the object behind this capability genuinely
       * exists on that box and it is this list that stops it being advertised.
       */
      CAPABILITY.usage,
      /*
       * `send` is withheld, and it is the one on this list whose absence needs
       * the least argument and the most explicitness.
       *
       * It types into a session **without attaching to it** — the verb exists so
       * that a surface with something to say and nothing to read does not have
       * to take a handle away from a terminal pane that is using it. On a box
       * handed to a stranger for an App Store review there is no such surface:
       * the visitor has a phone client, which attaches to the session it is
       * looking at and types with `input`. What the capability would add there
       * is a way to write into a session with no subscription to it, which is
       * the one property that makes it *harder* to notice from the far end, for
       * a caller that does not exist on that box.
       *
       * Withheld by the offer list alone, like `controls` and `usage`: the demo
       * builds a real session layer, so `SessionAccess.write` is genuinely there
       * — it is a required member of that interface and `server.ts` therefore
       * applies no gate of its own. This line is the whole of the decision.
       */
      CAPABILITY.send,
      /*
       * `account` is withheld, and it is the strongest case on this list.
       *
       * It names **the owner's logins** — every account on that machine, by the
       * address each one signed in as — and `account.switch` ends a running agent
       * and starts another under a different configuration directory. On a box
       * handed to a stranger for an App Store review, the first is a list of
       * somebody's email addresses handed to a visitor, and the second is a
       * visitor restarting a process on hardware they do not own, under a login
       * they were never shown.
       *
       * Withheld twice over, and worth knowing which half is doing the work. The
       * demo assembly passes no `switchAccount` to `createHostCore`, so the seam
       * behind this capability does not exist on that box and `server.ts` reads
       * the advertisement off the seam — a demo host could not offer it even if
       * this list were wrong. This line is the decision; that absence is what
       * makes the decision unable to be undone by accident.
       */
      CAPABILITY.account,
      /*
       * `logins` is the same decision one step further, and the step matters.
       *
       * That one is a stranger reading a session's login and moving that session
       * onto another. This is a stranger reading **every login the box has** with
       * no session in the question, and asking it to open a terminal running an
       * agent's own sign-in flow — on hardware they do not own. Withheld three
       * times over on the demo box: this list, the absent `signInAccount` seam,
       * and `ownDevice`, which no visitor could ever satisfy.
       */
      CAPABILITY.logins,
      /*
       * `devices` is withheld on the demo box: it lists every device signed
       * in to this host and lets one be revoked. A stranger handed a throwaway
       * shell must never enumerate the owner's real devices, let alone cut one
       * off. Sign-in on the demo box is off (public-host serves no enroll), so
       * there is no roster a guest could have any business reading.
       */
      CAPABILITY.devices,
      /*
       * `settings` is withheld: it changes the two settings this machine owns
       * — the default agent and whether sessions restore. On a box handed to a
       * stranger for review, letting a guest rewrite the host's own behaviour
       * is exactly the class of act this list exists to keep off the wire.
       */
      CAPABILITY.settings,
      /*
       * `windows` is withheld, and on this box it is the least defensible one to
       * get wrong.
       *
       * It lets a session on one machine drive a browser window in the app on
       * another — read the page, click it, type into it. On a demo box handed to
       * a stranger for an App Store review, the window it would reach is the
       * *owner's*, carrying the owner's logins, and the guest-door rule in
       * `window-owner.ts` is the only thing standing between the two. That rule
       * is right and this list is not a second copy of it: this is the decision
       * that the demo host never enters that conversation at all.
       *
       * Twice over, like `copilot` and `web`: the demo assembly wires no window
       * ask desk, and `server.ts` reads this capability off that object rather
       * than off a constant, so a demo host could not advertise it even if this
       * list were wrong.
       */
      CAPABILITY.windows,
      /*
       * And `hostwindows`, which is the same conversation with the ends swapped
       * and is withheld for a sharper version of the same reason.
       *
       * `windows` above is this box asking a visitor's app to act on a browser
       * *the visitor is looking at*. This one is a **visitor's session asking
       * this box to act on a browser here** — and on a demo machine "here" is the
       * owner's own screen, carrying the owner's logins. It is the direction
       * where the browser being reached belongs to the person who did not ask.
       *
       * Twice over, like `windows`: the demo assembly wires no window server, and
       * `server.ts` reads this capability off that function rather than off a
       * constant, so a demo host could not advertise it even if this list were
       * wrong. Three times, really — `WindowGrants` defaults closed and no demo
       * visitor has ever been ticked — but the offer list is the decision.
       */
      CAPABILITY.hostWindows,
      /*
       * `watch` is withheld: it streams a live picture of this machine's own
       * browser and takes input back into it. On a box handed to a stranger
       * for review, casting the owner's signed-in pages — or letting a guest
       * drive them — is the sharpest form of the act every entry here refuses.
       * The demo box serves no screencast anyway (no options.screencast), so
       * this is load-bearing and belt-and-braces at once.
       */
      CAPABILITY.watch,
      /*
       * The five 0.10.3 added, and every one of them is withheld for the same
       * reason with a different noun in it: **they read the machine itself
       * rather than a session on it.**
       *
       * `folders.pick` walks the box's filesystem — every directory name under
       * the account, whether or not anything was granted, which is the whole
       * point of a picker and is exactly wrong on a machine handed to a
       * stranger. `files` reads file *contents* out of a granted folder and
       * `git` reads the diff, so between them they are the owner's source code.
       * `panels` is the desktop's own Artifacts, Store, AI-readiness and MCP
       * lists — the owner's installed servers and their configuration.
       *
       * `browser.profiles` is the sharpest of the five and is closest to
       * `copilot`: a profile is a signed-in cookie jar belonging to whoever sits
       * at that machine, the list names them, and `browser.profile.clear` empties
       * one. A guest on a demo box does not get to enumerate somebody's browser
       * identities, let alone sign them out of everything.
       *
       * All five are also owner-only at the second gate — `server.ts` strips
       * them from a device claimed as a guest — so this line is belt-and-braces
       * for a phone that paired with six digits. It is *not* belt-and-braces for
       * the demo box, whose visitors are enrolled as their own owners inside a
       * throwaway container: there, the offer list is the only thing standing in
       * front of them.
       */
      CAPABILITY.folderPick,
      CAPABILITY.files,
      CAPABILITY.git,
      CAPABILITY.panels,
      CAPABILITY.browserProfiles,
      /*
       * And driving that browser, which is the strongest verb on this wire and
       * is withheld **twice over**.
       *
       * A window bound to a session can be told to navigate anywhere, be
       * photographed, and have every click on it recorded — and the binding
       * store hands its output to a session that is running commands. On a box
       * handed to a stranger for an App Store review, that is a remote browser
       * with the owner's cookies in it and a keystroke channel into a shell.
       *
       * Twice over because `host.ts` builds no `machineBrowser` at all when
       * `publicHost` is set, and `advertised` reads that object's presence to
       * decide — so a demo host could not advertise this even if the list here
       * were wrong. Both hold on purpose: the offer list is the decision, and
       * the absent object is what stops the advertisement outliving it.
       */
      CAPABILITY.browserControl,
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
