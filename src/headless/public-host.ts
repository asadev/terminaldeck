/**
 * Public-host mode — the one assembly that lets a stranger in, and the fence
 * around it.
 *
 * App Review is the reason this exists. `APPSTORE.md` §6 works the whole
 * argument through; the short version is that Terminal Deck is a client for a
 * computer you own, an App Review engineer in Cupertino owns no computer running
 * it, and Guideline 2.1 says an app behind a paired device must ship working
 * access in App Review Information. So there is a demo machine, and a page that
 * mints a real pairing link when somebody taps it.
 *
 * ## What is *not* relaxed, and this list is the point
 *
 * `PAIRING_TTL_MS` is still sixty seconds. Pairing tokens are still single-use.
 * Five wrong answers still kill a code. The Noise handshake, the credential, the
 * device key binding, the rate limiter — none of them is touched, and nothing in
 * `device-auth.ts` knows this file exists. A demo that had to weaken the trust
 * store would have been the wrong demo.
 *
 * ## The one thing that *is* traded, said plainly
 *
 * Redeeming a code creates a device in `pending`, and a human at the machine
 * approves it. `device-auth.ts` calls that "two gates, not one", and it is right.
 * There is no human at the demo box, so **the broker's allocation stands in for
 * the human**: a visitor asked for a machine, the broker started one for them
 * alone and asked it for a code, and the device that redeems that code inside
 * its minute is that visitor. That is a genuinely weaker second gate than a
 * person looking at a screen, and it is defensible for exactly one reason —
 * the thing being unlocked is a container with a README in it that is destroyed
 * when they leave. It would not be defensible on a machine anybody owns, which
 * is why {@link createPublicHost} is reachable from `demo.ts` and from nowhere
 * else, and why `public-host.test.ts` asserts that the desktop and the ordinary
 * headless daemon cannot reach it.
 *
 * ## What it takes away
 *
 * A host advertises what it will serve — `create`, `localhost`, `upload`,
 * `credential`. This one advertises `create` and nothing else. `localhost` is a
 * byte pipe to whatever is listening on the box's loopback, `upload` is a way to
 * fill a disk, and `credential` is a proxy for credentials the demo must not
 * hold.
 *
 * ## Two of those three are enforced. The third is only unadvertised.
 *
 * Said exactly, because an earlier version of this paragraph claimed "the
 * narrowing is true twice: once in the advertisement and once in there being
 * nothing behind it" for all three, and that is true of two of them:
 *
 *  - **`upload`** — the demo host is built with no uploads directory, so
 *    `upload.begin` is refused by `server.ts` with *"Files cannot be sent from a
 *    phone here."* Enforced.
 *  - **`credential`** — built with no credential proxy at all (`host.ts` passes
 *    `credentials` only when this mode is *off*), so the verbs answer nothing.
 *    Enforced.
 *  - **`localhost`** — **not** enforced. `server.ts` routes `ports`,
 *    `tunnel.open`, `tunnel.close` and `net.*` straight to the tunnel hub
 *    without consulting the offer, so a client that simply sends the verb it was
 *    never offered is served. `PUBLIC_HOST_OFFER` keeps the capability out of
 *    the `welcome`, and that is all it does — an ordinary phone draws no button,
 *    and a hostile one does not need the button.
 *
 * That gap is worth nothing *on this box*, and the reason is worth writing down
 * so nobody relaxes anything on the strength of it. A visitor already has a
 * shell inside the container, and `demo-shell` unshares the mount and pid
 * namespaces but **not** the network one — measured: their shell reads the same
 * `/proc/net/tcp` the host process does. So a tunnel to `127.0.0.1` reaches
 * exactly what `exec 3<>/dev/tcp/127.0.0.1/…` already reaches from their own
 * prompt, and `tunnel.ts` will only dial a port something is already serving.
 * The fence that matters here is the container and the egress rules, neither of
 * which the tunnel hub can cross.
 *
 * It is still an enforcement gap rather than a design, and the fix belongs in
 * `server.ts` beside the `create` and `upload` refusals — not here, because a
 * host that narrows its offer should be narrowing what it *serves*, on every
 * host, not only on this one.
 *
 * ## What it does not pretend to be
 *
 * `confinementKind()` answers `'none'` on Linux and this file does not argue
 * with it. The fence is the container the session runs in and the fact that the
 * machine is worth nothing — an ordinary mechanism, measurable with ordinary
 * tools, placed *outside* the product. `CONFINEMENT.md` rule 1 forbids shipping
 * an unmeasured boundary to make something look good, and a demo is precisely
 * the thing that would tempt somebody to.
 */

import type { Device } from '../main/remote/device-auth'
import { CAPABILITY } from '../main/remote/protocol'

/**
 * What a public host advertises: `create`, alone.
 *
 * A ceiling handed to `registerRemoteIpc`, which intersects it with what this
 * build can actually serve — so it can only ever remove, never promise.
 */
export const PUBLIC_HOST_OFFER: readonly string[] = [CAPABILITY.create]

export interface PublicHostConfig {
  /**
   * The one folder a visitor may start a session in.
   *
   * Granted explicitly to each device as it is approved rather than left to the
   * fallback, which is "this host's projects, then its home directory". The
   * fallback is right for a machine somebody owns and wrong here: a stranger
   * should be offered one folder because one folder is what they were given, not
   * because the host happens to have nothing else open today.
   */
  playground: string
  /**
   * How long one visitor may hold this host before it ends itself.
   *
   * A hard ceiling, armed at start and never extended. An abandoned tab must not
   * hold one of four slots until somebody notices.
   */
  lifetimeMs: number
  /**
   * How long to wait for the first device before giving the slot back.
   *
   * The common failure is somebody opening the review page, reading it, and
   * never tapping — the pairing link dies in sixty seconds and the container
   * would otherwise sit there for the full lifetime holding a slot for a visitor
   * who never arrived.
   */
  arrivalMs: number
  /**
   * How long after the last device detaches before this host ends.
   *
   * Not zero, and the reason is a phone: a screen lock, a lift, a walk between
   * two wifi networks all drop the socket for a few seconds and the client
   * reconnects on its own. Ending on the first detach would make the demo feel
   * broken in exactly the situation the product is *for*.
   */
  graceMs: number
}

export const PUBLIC_HOST_DEFAULTS: PublicHostConfig = {
  playground: '/home/visitor/playground',
  lifetimeMs: 20 * 60_000,
  arrivalMs: 5 * 60_000,
  graceMs: 90_000,
}

export interface PublicHostDeps {
  config: PublicHostConfig
  /**
   * Approve the device that just redeemed. True when it took.
   *
   * Injected rather than reached for, because the trust store is built by
   * `registerRemoteIpc` and this policy is decided before it exists — and
   * because a test has to be able to watch this being called without a relay,
   * a socket or a device on the far side of one.
   */
  approve(deviceId: string): boolean
  /** Give the device exactly the playground and nothing else. */
  grant(deviceId: string, folders: string[]): void
  /**
   * End this host, with the reason.
   *
   * The demo runs one visitor per container under `docker run --rm`, so ending
   * the process *is* the reset: the filesystem, the state directory, the trust
   * store, whatever they left in `~/.bashrc` and any process they backgrounded
   * all go with it. A cleanup script would be a thing that runs on the machine
   * the stranger is standing on; this is not.
   */
  end(reason: string): void
  /** Somewhere for the operator-facing notes to go. */
  log?(message: string, detail?: Record<string, unknown>): void
  /** Seams. A test may not wait twenty real minutes. */
  now?(): number
  setTimer?(fn: () => void, ms: number): NodeJS.Timeout
  clearTimer?(timer: NodeJS.Timeout): void
}

export interface PublicHost {
  /**
   * A device redeemed a code. Approve it, grant it the playground, and say so.
   *
   * This is the whole of the trade described at the top of this file, and it is
   * four lines long on purpose: a policy that can be read in one sitting is a
   * policy somebody can audit.
   */
  paired(device: Device): void
  /**
   * How many devices are attached right now.
   *
   * Driven by `REMOTE_CONNECTIONS_CHANNEL`, which fires on authenticate, attach,
   * detach and leave — the events the rest of this build already runs on. There
   * is no timer asking whether anybody is still here, because there does not
   * need to be one.
   */
  attached(count: number): void
  /** Arm the arrival and lifetime deadlines. Called once, at start. */
  begin(): void
  /** Stop every deadline. Called on the way out so a test leaves no handles. */
  dispose(): void
  /** The sentence `status` prints, so an operator is never guessing. */
  sentence(): string
  /** What a visitor is told, in their own session, before they type anything. */
  motd(): string
}

/**
 * Build the policy.
 *
 * Nothing here dials, listens, reads a file or looks at `process.env`. It is a
 * decision object: the assembly in `demo.ts` supplies the machine, this supplies
 * the rules, and `public-host.test.ts` exercises the rules with no machine at
 * all.
 */
export function createPublicHost(deps: PublicHostDeps): PublicHost {
  const { config } = deps
  const log = deps.log ?? ((): void => undefined)
  const setTimer = deps.setTimer ?? ((fn, ms): NodeJS.Timeout => setTimeout(fn, ms))
  const clearTimer = deps.clearTimer ?? ((timer): void => clearTimeout(timer))

  let arrival: NodeJS.Timeout | null = null
  let lifetime: NodeJS.Timeout | null = null
  let grace: NodeJS.Timeout | null = null
  let everAttached = false
  let ended = false

  const stop = (timer: NodeJS.Timeout | null): null => {
    if (timer !== null) clearTimer(timer)
    return null
  }

  /**
   * End once, whatever asked.
   *
   * Two deadlines can expire in the same tick — the lifetime cap and the grace
   * period after a detach are independent — and calling `end` twice would take a
   * container down while its own teardown was running.
   */
  const finish = (reason: string): void => {
    if (ended) return
    ended = true
    arrival = stop(arrival)
    lifetime = stop(lifetime)
    grace = stop(grace)
    log('public host ending', { reason })
    deps.end(reason)
  }

  return {
    begin(): void {
      arrival = setTimer(() => {
        if (everAttached) return
        finish('nobody paired with this machine, so its slot goes back')
      }, config.arrivalMs)
      lifetime = setTimer(
        () => finish('this machine reached its twenty-minute limit'),
        config.lifetimeMs,
      )
    },

    paired(device: Device): void {
      const approved = deps.approve(device.id)
      /*
       * The grant is written whether or not the approval took, and the order is
       * approve-then-grant rather than the other way round.
       *
       * `approveDevice` answers false for a device that is already approved or
       * has been revoked, and neither is a reason to leave the folder list
       * unwritten: a device with no row falls back to "this host's projects,
       * then its home directory", which on this box would offer `/home/demo`
       * itself — the state directory, the control token and all. The list is the
       * narrower of the two answers, so it is always the one written.
       */
      deps.grant(device.id, [config.playground])
      log('a visitor paired and was let in', { device: device.name, approved })
    },

    attached(count: number): void {
      if (count > 0) {
        everAttached = true
        arrival = stop(arrival)
        grace = stop(grace)
        return
      }
      // Nobody has ever been here; the arrival deadline owns this case and
      // starting a grace period as well would end the host early for a visitor
      // who is still reading the page.
      if (!everAttached) return
      if (grace !== null) return
      grace = setTimer(() => finish('the visitor left'), config.graceMs)
    },

    dispose(): void {
      arrival = stop(arrival)
      lifetime = stop(lifetime)
      grace = stop(grace)
    },

    sentence(): string {
      return (
        'PUBLIC DEMO HOST. This host approves any device that redeems a code it just ' +
        `minted, grants it ${config.playground} and nothing else, and advertises ` +
        `${PUBLIC_HOST_OFFER.join(', ')} only. It ends itself when the visitor leaves, and ` +
        `after ${Math.round(config.lifetimeMs / 60_000)} minutes whatever happens. Never run ` +
        'this on a machine you care about.'
      )
    },

    motd(): string {
      /*
       * Written for the person on the far end, not for us, and it says the two
       * things a curious visitor will otherwise mistake for the app being
       * broken.
       *
       * The first is that this machine is not theirs and is about to be
       * destroyed. The second is the firewall: outbound traffic is denied except
       * DNS and the relay, so `git clone`, `npm install`, `curl` and `ping` all
       * fail — and a reviewer who reads a firewall as a broken app is a
       * rejection we wrote ourselves.
       *
       * ## Every line is short, and that is a measurement rather than a taste
       *
       * The first version of this was written at a desk, in lines of up to 74
       * characters. The reviewer is not at a desk. Driven on a clean simulator
       * against the live box, an iPhone 17 in portrait reported `stty size` as
       * **26 54** — fifty-four columns — so every long line here hard-wrapped
       * mid-word, and the first thing a reviewer saw was a greeting that read
       * `running the r` / `eal Terminal Deck host.` and `so gi` / `t, npm`. It
       * is not a bug in anything; it is us writing a paragraph for the wrong
       * screen, on the one screen that decides whether this app ships.
       *
       * Fifty-four is the widest phone in the range, not the narrowest — a
       * smaller handset, larger text or a split view all take columns away — so
       * the lines below are held to **44**, which leaves ten columns of margin
       * and still reads as prose rather than as a column of fragments. The
       * ceiling is asserted in `public-host.test.ts` next to the phrases the
       * text must keep, because the natural way to edit this file is to improve
       * a sentence without ever seeing it on a phone.
       */
      return [
        'This is a real Linux machine in Germany,',
        'running the real Terminal Deck host.',
        'Everything you type runs here. Nothing',
        'runs on your phone.',
        '',
        `It is yours alone for up to ${Math.round(config.lifetimeMs / 60_000)} minutes,`,
        'and it is destroyed when you disconnect.',
        'Break anything you like.',
        '',
        'Outbound internet is firewalled off here',
        'on purpose, so git, npm, curl and ping',
        'will not reach it. That is the demo',
        'being careful, not the app failing.',
        '',
      ].join('\n')
    },
  }
}
