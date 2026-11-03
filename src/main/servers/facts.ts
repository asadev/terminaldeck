/**
 * What this app believes about one server, and the grounds for believing it.
 *
 * ## Why every fact has three states and not two
 *
 * This module exists because of one rule, set in his words while looking at a
 * design that had been drawn around what this Mac happened to have:
 *
 *   > *"Make sure we don't design it as per our design, it's gonna be used for
 *   > all so they might have different settings, we need something common."*
 *
 * A two-state model — we found it, we didn't — collapses two completely
 * different answers onto the same empty card. *"There is no web server on this
 * computer"* is a fact about their server. *"This sign-in is not allowed to
 * ask"* is a fact about their account, and the thing to do about it is
 * different. On a screen that models only presence, both draw a blank, and the
 * blank reads as the first one.
 *
 * That is not a hypothetical. Running the probe in `probe.sh.ts` against four
 * different machines produced three answers that a two-state model would have
 * turned into lies:
 *
 *   - an ordinary account on a box that *does* run containers answered
 *     `present-no-permission`, which a two-state model records as "no
 *     containers" — on a machine whose containers are the whole point of it;
 *   - a Debian container with no `ss` and no `netstat` answered `unknown` for
 *     what is listening, which a two-state model records as "0 listening",
 *     which is a claim nobody measured;
 *   - a container answered `container-none` for its init system, which a
 *     two-state model records as "no services", when the truth is that the
 *     question does not apply to that machine at all.
 *
 * So: {@link Fact} is `yes`, `no`, or **`cannot`**. `cannot` is not an error and
 * it is not a failure of the probe — it is the honest answer for a server that
 * does not work the way the question assumes, and it is the state that lets the
 * rest of this feature be built for somebody else's machine rather than for
 * this one.
 *
 * ## What each field is for
 *
 * `how` names the check that actually ran, in words a person can read — *"asked
 * what is listening"*. It is shown behind the detail disclosure on a card
 * rather than hidden, for two audiences: somebody who wonders why the app
 * thinks something is entitled to know, and whoever has to debug a wrong card
 * on a stranger's server six months from now with nothing else to go on.
 *
 * `why` on `cannot` is shown **in place of** the value. Never draw a blank, a
 * zero or a dash where a `cannot` lives; a dash reads as zero, and that is the
 * exact moment a card starts lying.
 *
 * `measuredAt` is on all three, because this feature never polls — it shows the
 * age of what it last measured instead. See the connection lifetime in
 * `connection.ts`.
 *
 * ## There is no fourth state, and no `undefined`
 *
 * A fact that has not been gathered yet is *absent from the record*, and the
 * card renders its own loading state. A `Fact` in hand is always one of the
 * three. This matters more than it looks: an `undefined` fourth state would be
 * indistinguishable from `no` at every call site that forgets to check, which
 * is the two-state collapse again wearing a different hat.
 *
 * ## No Electron here, on purpose
 *
 * Nothing in this file imports anything. It is the vocabulary the connection,
 * the probe, the classifier and the copilot tools all share, so it has to be
 * loadable from a test with no app object anywhere near it — the same rule
 * `remote/machines/store.ts` follows.
 */

/* ------------------------------------------------------------- the type -- */

/**
 * One thing the app believes about a server, and the grounds for believing it.
 *
 * See the header for why the third state exists. In short: `no` is a fact about
 * the server, `cannot` is a fact about our ability to ask, and a screen that
 * cannot tell them apart will state the first when it means the second.
 */
export type Fact<T> =
  | { known: 'yes'; value: T; measuredAt: number; how: string }
  | { known: 'no'; measuredAt: number; how: string }
  | { known: 'cannot'; measuredAt: number; why: string }

/** A fact we measured, with the value it came back with. */
export function factYes<T>(value: T, measuredAt: number, how: string): Fact<T> {
  return { known: 'yes', value, measuredAt, how }
}

/**
 * A fact we asked about and that genuinely is not there.
 *
 * Reserve this for questions where absence is itself an answer about the
 * server — *no container runtime is installed*, *no web server is installed*.
 * When the honest answer is "we could not find out", it is {@link factCannot},
 * however tempting the shorter word is.
 */
export function factNo<T>(measuredAt: number, how: string): Fact<T> {
  return { known: 'no', measuredAt, how }
}

/**
 * A fact we could not establish, with the sentence shown in place of a value.
 *
 * `why` is read by a person, so it says what happened to *them* — "this sign-in
 * is not allowed to ask this server about its containers" — rather than naming
 * the command that exited non-zero.
 */
export function factCannot<T>(measuredAt: number, why: string): Fact<T> {
  return { known: 'cannot', measuredAt, why }
}

/**
 * The value if we have one, otherwise `undefined`.
 *
 * Deliberately narrow: it collapses `no` and `cannot` together, which is
 * exactly the mistake this module is arranged against, so it is only for the
 * places that genuinely treat both the same — counting how many cards exist,
 * for instance. Anything a person *reads* must branch on `known` itself, and
 * `renderer/` has no business calling this at all.
 */
export function valueOf<T>(fact: Fact<T> | undefined): T | undefined {
  return fact !== undefined && fact.known === 'yes' ? fact.value : undefined
}

/* ------------------------------------------------------- what we ask for -- */

/**
 * How a server starts and stops the things it keeps running.
 *
 * `container-none` is a *value*, not a failure: a container has no init system
 * and that is a true and complete answer about it, so it is `yes` with this
 * value rather than `cannot`. A server whose init system we did not recognise
 * is `cannot`, because there almost certainly is one and we simply do not know
 * it — and the difference decides whether the page offers a Restart button or
 * says plainly that it will not guess.
 */
export type InitSystem = 'systemd' | 'openrc' | 'launchd' | 'sysvinit' | 'container-none'

/** A container runtime we know how to talk to. */
export type ContainerRuntime = 'docker' | 'podman'

/**
 * What this sign-in can do as the machine's administrator.
 *
 * `sudo-password` is the one to be careful with, and the care is structural
 * rather than a comment. Measured on the test box: an ordinary account with the
 * tool installed but **no entry in the sudoers file at all** answers exactly the
 * same as an account that merely needs to type a password. There is no offline
 * check that separates them, so nothing may treat `sudo-password` as a
 * permission. It is an unknown wearing a permission's clothes: offer the
 * action, catch the refusal, and say *"this sign-in isn't allowed to do that on
 * this server"* — which is true either way.
 */
export type Privilege = 'yes' | 'sudo-nopasswd' | 'sudo-password' | 'no'

/** Whether the server currently has this thing running. */
export type RunState = 'running' | 'stopped' | 'failed' | 'unknown'

/**
 * One thing the server is set up to keep running, as the server describes it.
 *
 * `name` is the server's own name for it and is never translated — a card shows
 * a person's words, but the detail line under it names what was actually found,
 * and this is that.
 *
 * `addedHere` is a genuine, checkable fact rather than a guess about
 * importance: on a systemd machine it means the unit's own file sits in
 * `/etc/systemd/system`, which is where an administrator's own additions live,
 * as opposed to the directory the operating system's packages write into. It is
 * here because without it the middle zone of a freshly installed Linux server
 * is eighty rows of the operating system talking to itself, and rule 1 says the
 * reader knows nothing about servers. What it is **not** is a claim that
 * anything else is unimportant — a web server installed from a package sits in
 * the operating system's directory and is obviously the point of the machine.
 * It is one input to classification, not a filter.
 */
export interface ServiceFact {
  name: string
  state: RunState
  /** The server's own one-line description, or `''` when it gave none. */
  description: string
  addedHere: boolean
}

/** One container, as its runtime describes it. */
export interface ContainerFact {
  name: string
  image: string
  state: RunState
  /** The runtime's own status line, e.g. `Up 3 hours`. Shown, never parsed for meaning. */
  status: string
  /** The runtime's own port mapping string, unparsed. */
  ports: string
}

/**
 * One thing accepting connections, and who owns it.
 *
 * `unit` is the join that makes the middle zone possible: it comes from reading
 * the owning process's own cgroup line, which names the service or container
 * the process belongs to. Without it, "something called `node` is on port 8787"
 * cannot become "your website is running"; with it, the port belongs to a named
 * thing that also has a Restart button.
 *
 * `program` and `pid` are empty strings when the server would not say — which
 * is the ordinary case for an ordinary account looking at another account's
 * process, and is a per-row unknown rather than a failure of the whole list.
 */
export interface ListenerFact {
  /** As the server printed it: `0.0.0.0`, `*`, `[::]`, `127.0.0.1`. */
  address: string
  port: number
  program: string
  pid: number | null
  /** The owning service or container, from the process's cgroup, or `''`. */
  unit: string
}

/** The coding agents this app knows how to look for. Claude Code is the only one it can set up. */
export type AgentId = 'claude' | 'codex' | 'gemini'

/**
 * One coding agent found on a server, and whether it will actually run.
 *
 * `path` is absolute and is carried through every later step rather than being
 * re-resolved, because PATH is exactly what could not be trusted to find it in
 * the first place — see the `#agents` section of `probe.sh.ts` for the two
 * layouts that proved it.
 *
 * `version` is `''` when the binary is there and would not answer, which is a
 * genuinely different situation from being absent: something is installed and
 * broken, and the offer a person needs is to install it again rather than to
 * install it for the first time.
 *
 * `signedIn` is `'unknown'` for every agent but Claude Code, because asking is
 * the one thing that has been measured, and for Claude Code itself whenever the
 * question could not be put. `account` is the address it answered with, shown on
 * screen and written nowhere — not to `servers.json`, not to the copilot's log.
 */
export interface AgentFact {
  id: AgentId
  path: string
  version: string
  signedIn: 'yes' | 'no' | 'unknown'
  account: string | null
}

/**
 * What installing an agent into this account's own home would need, before
 * anybody is offered a button for it.
 *
 * All three come free with the rest of the probe, and each one turns a failure
 * that would otherwise happen sixty seconds into a download into a sentence
 * said beforehand: the installer needs `curl` or `wget` and there is no third
 * way, it is killed by the kernel at around 512 MB of available memory, and it
 * writes about 320 MB into the account's home.
 *
 * `downloader` is `''` when the server has neither, which is a fact about the
 * server and the one case where the honest answer is to say so and offer
 * nothing — installing a downloader in order to install an agent is exactly the
 * general provisioning this feature is not.
 */
export interface AgentInstallRoom {
  /** `curl`, `wget`, or `''` when this server has neither. */
  downloader: string
  /**
   * The path to `npm`, or `''` when this server has none.
   *
   * Two of the three agents are npm packages and the third is not, so this is
   * the fact that decides which rows can be offered on a given machine. It is
   * read off the same widened PATH the agent search uses, because a server with
   * Node under `nvm` has an `npm` that a non-interactive `command -v` cannot
   * see — the same blind spot that made the agent search widen in the first
   * place.
   */
  npm: string
  /** Memory available now, in kilobytes, or null when the server would not say. */
  memoryAvailableKb: number | null
  /** Free space in the account's own home, in kilobytes, or null. */
  homeFreeKb: number | null
}

/** How much of the root filesystem is used. Kilobytes, as the server reports them. */
export interface DiskFact {
  usedKb: number
  totalKb: number
}

/** Memory, in kilobytes, as the server reports them. */
export interface MemoryFact {
  totalKb: number
  freeKb: number
}

/**
 * Everything one probe round trip established about one server.
 *
 * Every field is a {@link Fact}, including the ones that "obviously" always
 * work: `os` is `cannot` on a machine that answers nothing recognisable, and a
 * caller that assumed a string there would print `undefined` on somebody's
 * screen.
 *
 * This is the whole seam between the connection layer and everything above it.
 * The classifier reads this and never re-runs the probe; the copilot's
 * `servers.facts` tool returns this; the renderer is handed a narrowed copy of
 * it. Adding a card kind means adding a fact here, not a second round trip
 * somewhere else.
 */
export interface ServerFacts {
  serverId: string
  /** When the round trip that produced all of this completed. */
  measuredAt: number
  os: Fact<string>
  kernel: Fact<string>
  arch: Fact<string>
  /** The server's own name for itself, which is not the address we dialled. */
  hostname: Fact<string>
  /** The account we signed in as. */
  user: Fact<string>
  privilege: Fact<Privilege>
  init: Fact<InitSystem>
  containerRuntime: Fact<ContainerRuntime>
  /** The name of the tool this server installs software with. */
  packageManager: Fact<string>
  /** The name of the web server program that is installed, if one is. */
  webServer: Fact<string>
  cpus: Fact<number>
  disk: Fact<DiskFact>
  memory: Fact<MemoryFact>
  /** One-minute load average. */
  load1: Fact<number>
  uptimeSeconds: Fact<number>
  services: Fact<ServiceFact[]>
  containers: Fact<ContainerFact[]>
  listeners: Fact<ListenerFact[]>
  /**
   * The web addresses the server's own web server configuration names.
   *
   * This is the only honest source of a URL we can put behind an Open button:
   * it is what the machine itself says it answers to. Guessing one from a
   * listening port would produce `http://<the address we dialled>:8787`, which
   * is frequently a private port behind the reverse proxy and reaches nothing.
   */
  siteNames: Fact<string[]>
  /**
   * The coding agents installed for **this account**, not for this machine.
   *
   * Per-account is the whole shape of it, and it was measured rather than
   * assumed: the test box carries three separate homes, each with its own
   * `~/.claude`. A page that reported an agent as "installed on this server"
   * would be right about the machine and wrong about the person looking at it.
   *
   * An empty list is a real answer — we looked in every place an installer puts
   * one and in the login shell's own idea of PATH, and there is none — so it is
   * `yes` with `[]` rather than `no`, and `cannot` only when the question could
   * not be put at all.
   */
  agents: Fact<AgentFact[]>
  /** Whether this account could install one, and what it would cost. */
  agentInstall: Fact<AgentInstallRoom>
}

/* --------------------------------------------------- the container trap --- */

/**
 * The sentence shown wherever a container's resource numbers would have been.
 *
 * Exported because it is asserted by a test and shown on a card, and those two
 * must be the same string.
 */
export const CONTAINER_NUMBERS_WHY =
  'This is running inside a container, so these numbers would be the host ' +
  "computer's rather than this one's."

/**
 * The four facts a container reports about a different computer.
 *
 * Measured, and this is why the rule is structural rather than a note: an
 * Alpine container on the test box reported 39 GB of disk and an uptime of
 * 232,603 seconds. Both are the Hetzner machine's. A card reading "Disk 16%
 * full" there is not merely imprecise — it is a true statement about a computer
 * the person is not looking at.
 *
 * `/proc/meminfo`, `/proc/loadavg`, `/proc/uptime` and `df` are all inherited
 * from the host in the ordinary container configuration, so all four are forced
 * to `cannot` when there is no init system. Reading the cgroup limits to get
 * the container's real figures is a reasonable second version; inventing them
 * in the first is exactly the failure this model exists to prevent.
 */
export const CONTAINER_INHERITED_FACTS = ['disk', 'memory', 'load1', 'uptimeSeconds'] as const

export type ContainerInheritedFact = (typeof CONTAINER_INHERITED_FACTS)[number]

/**
 * True when this server's numbers would be somebody else's.
 *
 * A single predicate rather than a comparison written out at four call sites,
 * because the fifth call site is the one that forgets.
 */
export function numbersBelongToTheHost(facts: Pick<ServerFacts, 'init'>): boolean {
  return facts.init.known === 'yes' && facts.init.value === 'container-none'
}
