/**
 * What a host holds open when nobody is looking at it.
 *
 * ## The requirement, in Asad's words
 *
 * Keep it *"running a little bit with all the necessary things whatever we can
 * reach out to"*, and *"once we reach out to a session or start a new session it
 * may wakes it up"*. So: with no device attached the process holds exactly one
 * thing — the relay connection — and everything else stops. On the first attach
 * it all comes back.
 *
 * ## Why there is no timer in this file, and there must never be one
 *
 * Attach and detach are events that already exist. `server.ts` fires
 * `onConnections` whenever a device authenticates, attaches, detaches or leaves,
 * and that callback is the only thing that drives this controller. A timer that
 * woke up to ask "is anybody attached yet?" would be the standing rule broken in
 * the one file written to honour it — *events, not polling* — and it would burn
 * a wakeup every interval on a machine whose entire job right now is to be
 * cheap. The one heartbeat that survives is the WebSocket ping/pong inside the
 * relay link, because a NAT silently drops an idle connection and the socket
 * dies without it. One heartbeat layer, not two.
 *
 * ## Why the parts are registered rather than known
 *
 * This controller must not import the things it puts to sleep. A module that
 * knew about the port scanner, the activity trackers and the relay would be a
 * module that has to be edited every time a shell gains a part — and the two
 * shells do not have the same parts. The desktop has file watchers, transcript
 * tailing and cost polling; the headless build has never had any of those, and
 * `status` says so out loud rather than claiming to have switched off something
 * it never started. A list nobody can read is indistinguishable from a bug.
 *
 * ## Held-when-idle is a property of the part, not a special case
 *
 * The relay connection registers with `heldWhenIdle: true` and is therefore
 * never asked to sleep. So does a tailnet listener, when there is one: it is a
 * second way in, and a way in that closed itself while idle would be a host that
 * cannot be woken. Everything else sleeps. Making that a flag on the part rather
 * than a name this file checks for is what stops "the relay" being spelled two
 * ways in two places.
 */

/** A part of the host that is only worth running while somebody is attached. */
export interface Idleable {
  /**
   * What `status` prints. A sentence fragment naming the thing, not a class
   * name: a person reading `status` is deciding whether their phone can reach
   * this machine, not reading a stack trace.
   */
  readonly name: string
  /**
   * True for the ways in. Never asked to sleep, always listed as held.
   *
   * A part that answers true and then stops itself for its own reasons is
   * lying to `status`, which is worse than not registering at all.
   */
  readonly heldWhenIdle?: boolean
  /** Stop doing work. Called once per transition, never twice in a row. */
  sleep(): void
  /** Start again. Called once per transition, and never before the first sleep. */
  wake(): void
}

export type IdleMode = 'idle' | 'awake'

export interface IdleReport {
  mode: IdleMode
  /** How many devices are attached right now. Zero is what idle means. */
  attached: number
  /** Named parts running now — everything when awake, the ways in when idle. */
  holding: string[]
  /** Named parts currently stopped. Empty when awake. */
  stopped: string[]
}

/**
 * The one thing that decides whether this host is doing work.
 *
 * Starts **idle**, deliberately. A host that woke on launch and only idled once
 * something had attached and left would spend every reboot awake until a phone
 * happened to visit — which on a server that nobody attaches to for a week is
 * the feature never happening at all. Registering a part while idle therefore
 * sleeps it immediately, so a part added late lands in the same state as the
 * rest rather than being the one thing still running.
 */
export class IdleController {
  private readonly parts: Idleable[] = []
  private count = 0

  /**
   * `attached` is a count rather than a boolean because that is what the event
   * carries — `onConnections` hands over the whole list — and because `status`
   * prints it. Deriving a boolean here and printing "attached: yes" would throw
   * away the number a person actually wants when they are wondering whether the
   * phone in their pocket is the connection they are looking at.
   */
  constructor(attached = 0) {
    this.count = Math.max(0, attached)
  }

  /**
   * Add a part, and put it in the state everything else is already in.
   *
   * The immediate `sleep()` while idle is the load-bearing half. Without it a
   * part registered during boot — which is when all of them are registered —
   * would run until the first attach *and detach*, i.e. exactly the state this
   * class exists to avoid, and it would look correct in every test that attaches
   * before asserting.
   */
  register(part: Idleable): void {
    this.parts.push(part)
    if (part.heldWhenIdle !== true && this.mode() === 'idle') part.sleep()
  }

  mode(): IdleMode {
    return this.count === 0 ? 'idle' : 'awake'
  }

  /**
   * A device attached, detached or went away. The only thing that changes mode.
   *
   * Idempotent for a repeated count: `onConnections` fires for changes that do
   * not cross zero — a phone attaching to a second session while another is
   * already connected — and waking an already-awake part is how a subsystem
   * ends up with two of whatever it started.
   */
  attached(count: number): IdleMode {
    const next = Math.max(0, count)
    const before = this.mode()
    this.count = next
    const after = this.mode()
    if (before === after) return after

    for (const part of this.parts) {
      if (part.heldWhenIdle === true) continue
      if (after === 'awake') part.wake()
      else part.sleep()
    }
    return after
  }

  /**
   * What is running, for `status`.
   *
   * An idle mode nobody can observe is indistinguishable from a bug, which is
   * the whole reason this method exists rather than the mode alone.
   */
  report(): IdleReport {
    const mode = this.mode()
    const held: string[] = []
    const stopped: string[] = []
    for (const part of this.parts) {
      if (mode === 'awake' || part.heldWhenIdle === true) held.push(part.name)
      else stopped.push(part.name)
    }
    return { mode, attached: this.count, holding: held, stopped }
  }
}
