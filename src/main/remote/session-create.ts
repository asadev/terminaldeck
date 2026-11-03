/**
 * The policy behind `create`: which folder a phone may start a session in.
 *
 * Split out of `index.ts` because it is the only part of starting a session
 * from a phone that is a *decision*. The rest — resolving the login shell's
 * PATH, probing which agent CLIs are installed, applying the profile, spawning
 * the PTY — is the desktop's existing `session:create` path and is used
 * unchanged; a phone-created session is the same object, made the same way, or
 * it is a second implementation that will drift from the first.
 *
 * ## What the rule is
 *
 * A device may name a folder **only if this desktop is offering that folder to
 * that device**. The list is per device and comes from `folder-grants.ts`: the
 * folders a person chose for this phone, or — when nobody has chosen for it —
 * the desktop's own projects and running sessions, which is what every device
 * used to get. Two things follow, and both matter more than the rule sounds:
 *
 *  - The phone has an honest source for the value. The same array is sent to it
 *    on connect, so a folder picker built from it cannot offer a choice that
 *    fails.
 *  - Naming one grants nothing new. The device could already attach to a
 *    session in that folder and type into it, which is strictly more access
 *    than starting a fresh shell there.
 *
 * A path that is not on the list is **refused**, never quietly replaced with the
 * default. "New Session" that silently starts somewhere else is worse than one
 * that does not start: the user types a command into what they think is their
 * project and it lands in their home directory.
 *
 * Naming no folder at all is the common case and is not a refusal — it means
 * "wherever you would have started one", which is the first folder on that
 * device's list. An **empty** list is the one case where naming nothing is
 * still refused: it means a person removed every folder from this device, and
 * inventing a destination for it would undo the only thing they said.
 *
 * ## The request has to say who is asking
 *
 * `CreateRequest.deviceId` is required rather than optional, and that is the
 * whole shape of the bug it closes. The connection has always known which
 * device it is — `hello` proved it — and the request travelled down here
 * without it, so this file could only ever answer "may *a* phone start a
 * session here", never "may *this* phone". A required field means the compiler
 * asks the question at every call site instead of a reviewer having to.
 *
 * ## And it has to say *what* is being started
 *
 * `create` grew a `provider` field, and this file is where the name on it
 * becomes an agent. The reason it grew one is worth keeping: the
 * desktop-to-desktop client had been sending `provider` since it was written,
 * `parseClientMessage` had never listed the field, and a parser drops what it
 * does not list without a word. Measured on a real Windows PC — a request for
 * `shell` produced a `claude` session, and no layer had anything to report,
 * because from each layer's own point of view nothing had gone wrong.
 *
 * The rule here is the same one the folder rule already follows, applied to a
 * second field: **a name this desktop cannot honour is refused with a sentence,
 * never replaced with a different one.** Naming nothing is not a refusal and
 * means "whatever you would have started", which is what every older client
 * sends. What this file does *not* do is guarantee the agent is installed — the
 * spawn falls back to a plain shell when the CLI is missing, exactly as the
 * desktop's own button does, and the `created` frame reports the provider the
 * session actually got so the far end can show the truth rather than the request.
 *
 * ## What this file decides, and what it no longer has to apologise for
 *
 * It decides where a session **starts**, and which agent it starts. What happens
 * after that is `src/main/confine/`, and the answer differs per platform: macOS
 * holds the session with seatbelt, Linux with a user namespace, and Windows with
 * an AppContainer once an administrator has granted it one thing, once. That
 * paragraph used to end *"on Windows and Linux it is not, because no mechanism
 * there has been measured"*, which was true when it was written and stopped
 * being true as each of the other two mechanisms landed — the same drift the
 * refusal below now exists to stop, one layer up.
 *
 * This file still makes no claim either way, and that is the point: it does not
 * decide whether a boundary exists, it only has to know that the spawn it calls
 * can refuse for a *third* reason, and that the refusal deserves its own
 * sentence **carrying the reason the machine measured**. A refusal that keeps
 * the reason to itself is how a session that could not be held became, on a
 * server, a message about a folder that was perfectly fine.
 */

import { posix, win32 } from 'node:path'
import { BRAND } from '../../shared/brand'
import type { ProviderId, SessionMeta } from '../../shared/types'
import { AgentUnavailableError } from '../agent-unavailable'
import { ConfinementUnavailableError } from '../confine'
import { currentPlatform, isWindows, machineNoun, type Platform } from '../platform/host'
import type { CreateOutcome, CreateRequest } from './server'

/**
 * The path rules for the platform being asked about, rather than for the one
 * running the test.
 *
 * `node:path` is whichever implementation the current OS uses, which is right
 * in production and useless here: on a Mac `isAbsolute('C:\\Users\\Asad')` is
 * false and `normalize` leaves backslashes alone, so every Windows case in the
 * suite would be answered by the POSIX parser and pass or fail for a reason
 * that has nothing to do with Windows. `platform/tailscale.ts` reaches for
 * `win32.join` for exactly this reason. Selecting the implementation is what
 * makes the Windows answer pinnable from the machine this is written on — and
 * on Windows itself it selects the same code `node:path` would have been.
 */
function rules(platform: Platform): typeof posix {
  return isWindows(platform) ? win32 : posix
}

/**
 * A terminal a phone has not measured yet.
 *
 * Only reached when the client sent no size — every shipping client sends one,
 * because the size travels with the request precisely so the first screen is
 * the right shape. 80×24 is the size a PTY gets when nobody says otherwise, so
 * a session started this way looks like one started from a shell script rather
 * than like one started at a size somebody invented.
 */
const DEFAULT_COLS = 80
const DEFAULT_ROWS = 24

/**
 * Every agent id, written once and checked by the compiler.
 *
 * `satisfies Record<ProviderId, ProviderId>` is doing real work: it is an error
 * for this object to name something that is not a provider *and* an error for it
 * to leave one out. So a fifth agent added to `ProviderId` fails to compile here
 * until it is listed, rather than being silently unstartable from a phone — which
 * is the same class of silent drop this whole change exists to close, one layer
 * up.
 *
 * A list rather than a read of `PROVIDERS`' keys because `Object.keys` answers
 * `string[]`, and turning that back into a `ProviderId` needs a cast. A cast is
 * a defect: it would type-check just as happily on the day the wire starts
 * carrying a name the table has never had.
 */
const PROVIDER_IDS = {
  claude: 'claude',
  codex: 'codex',
  gemini: 'gemini',
  shell: 'shell',
} as const satisfies Record<ProviderId, ProviderId>

/**
 * Turn the name a client asked for into an agent this desktop has, or into
 * nothing at all.
 *
 * Returns `null` rather than throwing, and — the part that matters — rather than
 * falling back to a default. The fallback *was* the bug: a `shell` request
 * reached this machine carrying nothing at all, the desktop filled the hole with
 * its own default agent, and a person on a real Windows PC watched Claude start
 * when they had asked for a shell. Nothing logged it, because from here nothing
 * had gone wrong. A name this desktop cannot start is something the person can
 * act on the moment they are told, and cannot act on at all when the machine
 * quietly picks something else.
 */
export function knownProvider(name: string): ProviderId | null {
  for (const id of Object.values(PROVIDER_IDS)) {
    if (id === name) return id
  }
  return null
}

/** The agent ids this desktop will start, for a sentence that has to list them. */
export function providerNames(): string[] {
  return Object.values(PROVIDER_IDS)
}

export interface SessionStarter {
  /**
   * Folders this desktop will start a session in **for this device**, most
   * relevant first, and the first of them is where a request that names nothing
   * lands.
   *
   * Called per request rather than captured once, and the device id is passed
   * every time rather than resolved once per connection. Both are the same
   * point: grants are edited from the settings panel while a phone is
   * connected, projects are opened and closed, and sessions come and go. A list
   * snapshotted at startup would refuse a folder the user granted five minutes
   * ago — and, worse in the other direction, would keep honouring a folder that
   * was taken away until the phone reconnected.
   *
   * Empty is a real answer and means this device may start nothing. See
   * `folder-grants.ts` for why that is not flattened into "anywhere".
   */
  folders(deviceId: string): string[]
  /**
   * Is this one of the owner's own machines, for which the list above is a set
   * of suggestions rather than a ceiling?
   *
   * **Optional, and absent means "enforce the list"** — which is what every
   * caller written before device kinds existed wants, and what `remote-host.ts`
   * and the tests still supply. A host that knows about kinds answers it from
   * `device-reach.ts`.
   *
   * The asymmetry is the point of the two kinds. A guest may name only what was
   * chosen for it, because somebody chose. One of your own may name any folder
   * on the machine, because *"it's you at another keyboard"* and a second laptop
   * that could only open the projects that happened to be open at the desk would
   * be worse than the ssh it replaces. The picker still shows the suggestions
   * first; this only decides whether naming something else is a refusal.
   *
   * What it does **not** do is skip any other check. The path must still be
   * absolute, the spawn still refuses a state directory, and on macOS the
   * session is still held inside whatever folder it started in.
   */
  unrestricted?(deviceId: string): boolean
  /**
   * Start it for real. Throws exactly as `PtyManager.create` throws.
   *
   * `deviceId` travels with it for the same reason it travels on the request —
   * see the header — and for a second one that only appeared once credentials
   * were involved. The session about to be spawned inherits this machine's git
   * login unless it is given one of its own, and "of its own" is *per device*:
   * which folder its global config lives in, and whose phone answers when git
   * asks for a password. A spawn that did not know whose session it was starting
   * could only give every remote session the same isolation, or none.
   */
  /**
   * `provider` is absent when the client named none, and absent means "the one
   * this desktop would have started" — the host's own default preference, which
   * is what every client shipped before the field existed gets and what the
   * desktop's own button does. When it is present it has already been checked
   * against {@link knownProvider}, which is why it is a `ProviderId` here and a
   * bare `string` on the request: the narrowing is the check, and a starter
   * cannot be handed a name nobody looked at.
   */
  spawn(input: {
    cwd: string
    cols: number
    rows: number
    deviceId: string
    provider?: ProviderId
  }): Promise<SessionMeta>
}

/**
 * One directory, written two ways.
 *
 * `normalize` resolves `.` and `..` and collapses repeated separators, and
 * deliberately does *not* drop a trailing one: `/a/b/` stays `/a/b/`. That is
 * correct for a general path and wrong here, because a project stored with a
 * trailing slash and the same folder as a session's `cwd` without one are the
 * same directory, and a refusal over that is a refusal nobody can act on. The
 * root itself keeps its separator, since `''` is not a path.
 *
 * ## And on Windows, written two ways again
 *
 * NTFS is case-insensitive. `C:\Users\Asad\proj` and `c:\users\asad\proj` are
 * one directory, and both spellings really do turn up: the drive letter alone
 * arrives capitalised from some APIs and lower-cased from others, and a folder
 * a user typed once is stored however they typed it. Comparing them with `===`
 * makes the allowlist reject a folder that is *visibly on the list the phone is
 * showing* — and the refusal it produces says "Open it on the Mac first" about
 * a folder that is already open. That is the worst kind of failure this file
 * can have: the rule looks broken rather than strict.
 *
 * Folded on Windows only. A POSIX filesystem genuinely distinguishes `Proj`
 * from `proj`, and folding there would let a phone name a *different* directory
 * than the one the desktop offered, which is the exact hole the allowlist
 * exists to close.
 */
export function sameFolder(a: string, b: string, platform: Platform = currentPlatform()): boolean {
  const { normalize, sep } = rules(platform)
  const left = trimEnd(normalize(a), sep)
  const right = trimEnd(normalize(b), sep)
  if (!isWindows(platform)) return left === right
  return left.toLowerCase() === right.toLowerCase()
}

/**
 * Is `child` the same folder as `parent`, or somewhere inside it?
 *
 * The containment half of the comparison above, written here rather than in
 * `device-reach.ts` for the reason that file's header gives about there being
 * one implementation of "are these the same directory": a second normaliser
 * would answer the trailing-slash and the Windows-casing questions its own way,
 * and the two would disagree about a real folder on somebody's machine long
 * before anybody noticed.
 *
 * The separator test is what makes it containment rather than a prefix match.
 * `startsWith` alone says `/home/asad/work-notes` is inside `/home/asad/work`,
 * which is a different directory that merely begins with the same letters —
 * exactly the mistake that turns "I shared one project" into "I shared the one
 * next to it too". Comparing `parent + sep` costs nothing and cannot make it.
 *
 * The root is the one folder that is its own prefix with a separator already on
 * it, so `/` covers `/etc` without a doubled slash; that falls out of trimming
 * the parent before the test rather than needing a case.
 */
export function withinFolder(
  parent: string,
  child: string,
  platform: Platform = currentPlatform(),
): boolean {
  if (sameFolder(parent, child, platform)) return true
  const { normalize, sep } = rules(platform)
  const fold = (path: string): string => (isWindows(platform) ? path.toLowerCase() : path)
  const top = fold(trimEnd(normalize(parent), sep))
  const inner = fold(trimEnd(normalize(child), sep))
  // A relative path can never be inside an absolute one, and comparing them
  // would let `projects/..` — which normalises to `.` — win or lose for a reason
  // that has nothing to do with what anybody meant.
  if (!isAbsoluteFolder(parent, platform) || !isAbsoluteFolder(child, platform)) return false
  const boundary = top.endsWith(sep) || top.endsWith('/') ? top : `${top}${sep}`
  return inner.startsWith(boundary)
}

/**
 * Is this a path the rule above can compare at all?
 *
 * Exported for the same reason {@link sameFolder} is: `folder-grants.ts` stores
 * the list this file checks against, and a store that accepted a relative path
 * would be putting a row in the panel that can never match anything — a folder
 * visibly granted and permanently refused. The two questions have to be asked
 * with one implementation or the stored list and the enforced list are two
 * different sets that look like one.
 */
export function isAbsoluteFolder(path: string, platform: Platform = currentPlatform()): boolean {
  return rules(platform).isAbsolute(path)
}

function trimEnd(path: string, sep: string): string {
  let end = path.length
  while (end > 1 && (path[end - 1] === sep || path[end - 1] === '/')) end -= 1
  return path.slice(0, end)
}

/**
 * Where a person is supposed to go and look, on the machine that refused.
 *
 * The sentence this replaces was *"Check it on the machine itself"*, and on the
 * machine this whole feature exists for it names nowhere. A rented Linux box has
 * no screen, no window and no Settings pane; there is nothing to check *on* it
 * in the sense that sentence means, and somebody reading it on a phone in
 * another country is being told to do something that does not exist. The
 * headless host has one command that prints exactly this state — `HEADLESS.md`
 * puts it in as many words, *"`terminaldeck status` must say which of these is
 * true"* — so naming it is the difference between a refusal and a remedy.
 *
 * Linux is read as the headless host rather than as a Linux desktop because
 * there is no Linux GUI build: `platform/paths.ts` says so where it reconciles
 * the two shells' data directories, and `platform.ts` in the renderer says it
 * again where it refuses to give Linux a machine noun. If one ever ships, this
 * is a third place that has to move, and the failure would be a sentence naming
 * a command instead of a window — visible, and not dangerous, which is the
 * right way round for a guess about somebody else's computer.
 *
 * "That machine" rather than `here`'s "This machine", for the reason the agent
 * refusal below gives: the sentence is read on the client, where "this" is the
 * thing in your hand.
 */
function lookOn(platform: Platform): string {
  return platform === 'linux'
    ? `Run "${BRAND.id} status" on that ${machineNoun(platform)} to see why.`
    : `Settings → Remote on that ${machineNoun(platform)} says what it can hold.`
}

/*
 * **The measured reason is not on the wire, and that is deliberate.**
 *
 * It was, for an afternoon. The complaint that put it there is real and stands:
 * `ConfinementUnavailableError.detail` is the only account of what happened
 * anywhere, and the only thing receiving it was `console.error`, which a
 * detached daemon has pointed at `/dev/null`.
 *
 * But those strings cannot be sent to a phone, and the reason is structural
 * rather than a matter of wording. Most end in `tail(error)`, which appends the
 * mechanism's own stderr — `unshare: Operation not permitted` — and several
 * *begin* by naming the program, as `sandbox-exec would not run a command with
 * this profile` does. Truncating at the colon was tried and fails on the second
 * shape; rephrasing the sentence does nothing about what is appended after it.
 * `session-create.test.ts` has asserted since long before this that the wire
 * sentence names no program, and it is right to: nobody holding a phone can act
 * on a program name or a profile.
 *
 * So the split is by *destination* rather than by string surgery. The **log**
 * gets `detail`, whole. The **phone** gets `lookOn`, which names the place that
 * holds it — `terminaldeck status` on a server, the Remote panel on a desktop.
 * That is the fix the original complaint actually wanted: the reason stops
 * going nowhere, without ending up somewhere it cannot be used.
 */

/**
 * The `SessionAccess.create` a real desktop hands to the remote server.
 *
 * Returns a refusal rather than throwing, for the same reason
 * `parseClientMessage` does: the caller answers a refusal by sending a sentence
 * to a phone, and an exception on a socket's data path is how a main process
 * dies.
 */
export function remoteSessionCreator(
  starter: SessionStarter,
  // Passed in rather than read inline, like everything else that branches on
  // the platform in this codebase — `platform/host.ts` says why at length. It
  // is what lets one test on a Mac pin the Windows case-folding answer.
  platform: Platform = currentPlatform(),
): (request: CreateRequest) => Promise<CreateOutcome> {
  const here = `This ${machineNoun(platform)}`
  return async (request: CreateRequest): Promise<CreateOutcome> => {
    const offered = starter.folders(request.deviceId)
    // Absent is false: a starter that has never heard of device kinds enforces
    // the list, which is what every caller predating them already relies on.
    const anywhere = starter.unrestricted?.(request.deviceId) === true
    const named = request.cwd
    let cwd: string

    if (named === undefined) {
      // Where this device would have started one: the first folder on its own
      // list. Nothing is invented when that list is empty, because an empty list
      // is a person's answer rather than a gap — see the header.
      const first = offered[0]
      if (first === undefined) {
        return {
          ok: false,
          code: 'unauthorized',
          // Two refusals with two remedies, because they are two different
          // situations to the person holding the phone. This one is "nothing
          // has been shared with you", which no amount of retrying changes and
          // which is fixed at the keyboard the folders live on.
          message: `${here} has no folders chosen for this device. Choose one in its remote access settings.`,
        }
      }
      cwd = first
    } else {
      // Absolute first: `normalize('projects/..')` is `'.'`, which would then be
      // compared against a list of absolute paths and lose for the wrong
      // reason. Refusing here says the true thing.
      // One of the owner's own machines may name a folder that is not on the
      // suggestion list — see `SessionStarter.unrestricted`. Absolute is still
      // required of it: the comparison below is against absolute paths and a
      // relative one would be resolved against this app's working directory,
      // which is not a folder anybody was thinking about.
      if (
        !isAbsoluteFolder(named, platform) ||
        (!anywhere && !offered.some((folder) => sameFolder(folder, named, platform)))
      ) {
        return {
          ok: false,
          code: 'unauthorized',
          // The folder is not echoed back. It came from the network and this
          // sentence is both sent over the wire and shown on a phone; quoting
          // attacker-chosen text into it buys nothing and costs an output
          // channel.
          //
          // "Pick one from the list it sent" rather than "open it there first",
          // which was true when every device got the same list and is not now:
          // the honest instruction for a device whose folders were chosen for
          // it is to use them, or to change them where they were chosen.
          message: `${here} is not offering that folder to this device. Pick one from the list it sent.`,
        }
      }
      cwd = named
    }

    /*
     * Which agent, and the refusal that replaces a substitution.
     *
     * `undefined` is the ordinary case and is not a refusal: a client that names
     * no agent gets the one this desktop would have started anyway. A client
     * that *does* name one and names something this desktop has never heard of
     * is refused, and refused with the list, because the alternative is the bug
     * this field exists to close — a request for `shell` answered with a Claude
     * session and nothing anywhere saying so.
     *
     * `unauthorized` rather than `unavailable`, for the same reason a folder off
     * the list is: retrying does not change the answer, and sending someone back
     * to a spinner over a name that will never be right is worse than telling
     * them what the names are. The name is echoed *from the desktop's own list*
     * and never from the request — it came off a network and this sentence is
     * both sent over the wire and drawn on a phone.
     */
    let provider: ProviderId | undefined
    if (request.provider !== undefined) {
      const known = knownProvider(request.provider)
      if (known === null) {
        return {
          ok: false,
          code: 'unauthorized',
          message: `${here} does not have an agent by that name. It can start: ${providerNames().join(', ')}.`,
        }
      }
      provider = known
    }

    try {
      const meta = await starter.spawn({
        cwd,
        cols: request.cols ?? DEFAULT_COLS,
        rows: request.rows ?? DEFAULT_ROWS,
        deviceId: request.deviceId,
        ...(provider === undefined ? {} : { provider }),
      })
      return {
        ok: true,
        session: {
          id: meta.id,
          title: meta.title,
          cwd: meta.cwd,
          provider: meta.provider,
          // Nothing has been printed yet, so there is nothing to read a status
          // off. `session-activity.ts` will say otherwise within a frame or two
          // and the phone is already listening for it.
          status: 'idle',
          exitCode: meta.exitCode,
        },
      }
    } catch (error) {
      /*
       * The boundary could not be put around the session, so there is no
       * session. This is deliberate and is the only way the wording on the grant
       * screen stays honest: it tells a person that a session from a device
       * stays inside the folder, and a session that quietly started outside one
       * would make that sentence a lie on a machine nobody was looking at.
       *
       * A separate message because the remedy is completely different from the
       * one below. Nothing about retrying, and nothing about the folder having
       * moved — the folder is fine; the machine is not able to hold a session
       * inside it right now, and that is something only the person at that
       * machine can look into.
       */
      if (error instanceof ConfinementUnavailableError) {
        /*
         * The detail goes over the wire, and the log line stays.
         *
         * It stayed in the log alone until 2026-08-24, and the branch below
         * already records what that costs — a detached daemon points stdout at
         * `/dev/null`, so on the one kind of machine this feature is for, the
         * only account of why a session was refused was destroyed at the moment
         * it was written. What reached the person holding the phone was a
         * sentence with no fact in it and an instruction to go and look at a
         * server that has nothing to look at.
         *
         * These strings are a different thing from a raw exception: each one
         * was written, by hand, at the point that measured the failure, for the
         * person who has to act on it. Where one quotes the machine it quotes
         * the useful line — `unshare: Operation not permitted` is the whole
         * diagnosis on a box with the AppArmor restriction set — and where a
         * quoted command line comes with it, it can carry the folders that were
         * in the plan. That is not a disclosure: the device named one of those
         * folders in the request this is the answer to, and the rest were sent
         * to it on connect. The same is already true of the agent refusal below,
         * which sends the error's own message for the same reason.
         *
         * The log line is kept because the two readers are different — whoever
         * is at the machine gets it with a timestamp and everything around it —
         * and because a message that has to be shortened one day should not take
         * the record with it.
         */
        // The **whole** detail here, including the mechanism's own stderr —
        // this is the half `ConfinementUnavailableError.summary` drops on its
        // way to the phone, and the half somebody standing at the machine
        // actually needs.
        console.error('[remote] refusing to start an unconfined session:', error.detail)
        return {
          ok: false,
          code: 'unavailable',
          message: `${here} could not keep a session inside that folder, so it did not start one. ${lookOn(platform)}`,
        }
      }
      /*
       * The agent is not installed on that machine, and the error already says
       * so in the words a person needs.
       *
       * This branch is worth as much as the one above it and for the same
       * reason: two failures, two remedies. Without it the throw fell into the
       * generic case below and a phone was told the *folder* may have moved —
       * measured on a rented Ubuntu server on 2026-08-22, on a host installed
       * from `install-headless.sh` and signed in to from the browser client. A
       * fresh server has no `claude` on it, a client that names no provider gets
       * the host's default, and the default is an agent; so on that machine
       * every New Session was refused with a sentence about a folder that was
       * perfectly fine. The one true account went to `console.error`, which a
       * detached daemon has pointed at `/dev/null`.
       *
       * `unauthorized`, not `unavailable`, matching the sibling refusal for a
       * provider this machine does not have at all: retrying changes nothing
       * until somebody installs something, and a client that reads
       * `unavailable` as "worth another go" would spin on a wall. The message is
       * the error's own — it names the agent by the label the person picked and
       * says where this looked, which is the whole remedy — with one sentence
       * appended saying which of the two machines to act on. "That machine"
       * rather than `here`'s "This machine": the sentence is read on the client,
       * where "this" is the thing in your hand.
       */
      if (error instanceof AgentUnavailableError) {
        console.error('[remote] the agent for this session is not installed:', error.message)
        return {
          ok: false,
          code: 'unauthorized',
          message: `${error.message} Install it on that ${machineNoun(platform)}, or choose a different one in its settings.`,
        }
      }
      // The realistic failure is a folder that was listed and has since been
      // deleted or unmounted, which is somebody else's action rather than a
      // wrong request — so it is `unavailable` and worth retrying, not a
      // refusal that sends the user to the pairing screen.
      console.error('[remote] could not start a session:', error)
      return {
        ok: false,
        code: 'unavailable',
        message: `${here} could not start a session there. The folder may have moved.`,
      }
    }
  }
}

/**
 * The two halves of "a phone may start a session", built from one starter.
 *
 * `create` enforces the list and `folders` is the list, sent to the device so
 * its picker shows exactly what it may use. They are handed out together
 * because they must never be two answers: a picker offering a folder the rule
 * refuses is the failure this feature exists to end, and it is exactly what
 * happens the first time somebody assembles the advertised list from one place
 * and the enforced list from another. There is one call, `starter.folders`,
 * behind both.
 *
 * The shape is what `SessionAccess` in `server.ts` and `PtySource` in
 * `session-fanout.ts` both want, so `index.ts` spreads this straight into the
 * object it builds and cannot supply one without the other.
 */
export interface RemoteSessionStart {
  create(request: CreateRequest): Promise<CreateOutcome>
  folders(deviceId: string): string[]
  /**
   * Present exactly when the starter has an opinion, so a host that knows
   * nothing about device kinds still spreads into a `PtySource` with no such
   * key — which is how `SessionFanout` tells "this host does not do kinds" from
   * "this host says no", and the two must not look the same.
   */
  unrestricted?(deviceId: string): boolean
}

export function remoteSessionStart(
  starter: SessionStarter,
  platform: Platform = currentPlatform(),
): RemoteSessionStart {
  const anywhere = starter.unrestricted
  return {
    create: remoteSessionCreator(starter, platform),
    folders: (deviceId) => starter.folders(deviceId),
    ...(anywhere === undefined ? {} : { unrestricted: (deviceId: string) => anywhere.call(starter, deviceId) }),
  }
}
