/**
 * What the window knows about a server.
 *
 * ## Why this file exists at all
 *
 * Mirrors of the types in `src/main/servers/`, restated rather than imported
 * because the renderer tsconfig cannot see `src/main` — the same arrangement
 * `machines/types.ts` already lives with, and the same one `CLAUDE.md` asks for:
 * a feature's types stay in its own module and cross the bridge as `unknown`,
 * because duplicating them into `shared/types.ts` lets the two sides drift while
 * both keep compiling.
 *
 * ## Two things are deliberately not here
 *
 * **No credential of any kind.** Not a password, not a private key, not a key
 * passphrase. `machines/types.ts` states the rule for paired devices — *"a
 * screen that held one would be a screenshot away from publishing it"* — and it
 * holds identically for a server. What the window learns is *which kind* of
 * sign-in is stored, never what it is. The one secret-shaped string that does
 * cross is the host key fingerprint, which is public by design and is the thing
 * a person may actually want to compare against another tool.
 *
 * **No consequence sentence.** Every string describing what an action will do is
 * composed in the main process, beside the code that performs it, and arrives on
 * `ActionPreview.sentence`. A client that wrote its own would be describing an
 * action it did not implement, and the first time the two drifted somebody would
 * approve one thing having read another. So this screen asks for the preview and
 * renders it; it never builds one.
 *
 * ## Everything here is optional on purpose
 *
 * The narrowing below reads what arrived and never insists on a shape. That is
 * not defensive habit — it is the only honest way to mirror a record whose whole
 * point is that a fact may be missing. A field that is absent means *nobody
 * asked*; a `Fact` in hand is always one of its three states. Collapsing those
 * two is how a screen starts saying "none" about a question it never put.
 *
 * ## The vocabulary
 *
 * A **machine** is anything on the far end of a wire. A **device** is one of
 * your own — it runs this app on the far end, and you sit at it. A **server**
 * does not run this app and nobody sits at it. Inside a server there are
 * **sites**, **apps** and **databases**, and everything else is drawn under a
 * heading rather than given a fourth noun.
 *
 * Note the older word still in the code around this folder: `machine` in
 * `machines/types.ts`, `machines.json` and every `*Machine*` channel means what
 * this file calls a *device*. The word was promoted to the umbrella in copy
 * only — renaming the stored file would drop everybody's pairings at their next
 * launch, silently, and they would have to re-pair from two keyboards to find
 * out why.
 */

/* ------------------------------------------------------------- the facts -- */

/**
 * One thing the app believes about a server, and the grounds for believing it.
 *
 * The third state is the whole point. `no` and `cannot` look the same on a
 * screen that only models presence — both draw an empty card — and they mean
 * completely different things to the person reading it. "There is no web server
 * here" is a fact about their server. "This account is not allowed to ask" is a
 * fact about their sign-in, and the fix is different.
 *
 * Measured on four real machines before any of this was written: an ordinary
 * account on a box that does have a container runtime answers *"present, no
 * permission"*, and a container with neither tool installed cannot count what is
 * listening at all. A two-state model reports the first as "no containers" and
 * the second as "0 listening", and both are lies about somebody's server.
 */
export type Fact<T> =
  | { known: 'yes'; value: T; measuredAt: number; how: string }
  | { known: 'no'; measuredAt: number; how: string }
  | { known: 'cannot'; measuredAt: number; why: string }

/** How much of something is in use, in kilobytes. */
export interface Amount {
  usedKb: number
  totalKb: number
}

/** What this sign-in can do as the machine's administrator. */
export type Privilege = 'yes' | 'sudo-nopasswd' | 'sudo-password' | 'no'

/**
 * How a server starts and stops what it keeps running — detected, never assumed.
 *
 * `container-none` is a real answer and not a failure: a container has no init
 * system at all, and plenty of somebody's real servers are exactly that.
 */
export type InitSystem = 'systemd' | 'openrc' | 'launchd' | 'sysvinit' | 'container-none'

export type ContainerRuntime = 'docker' | 'podman'

/**
 * Everything one round trip to a server established, as this screen reads it.
 *
 * Every field is optional, and the reason is worth stating because it looks like
 * timidity and is not: this mirror is deliberately **tolerant of a narrower
 * record than the full one**. The classifier and the action layer each take the
 * slice of facts they need, so a view assembled by one of them carries three
 * facts and a view assembled from the probe carries twenty. A mirror that
 * demanded all twenty would render nothing at all rather than the three it was
 * given.
 */
export interface ServerFacts {
  os?: Fact<string>
  kernel?: Fact<string>
  arch?: Fact<string>
  /** The server's own name for itself, which is not the address we dialled. */
  hostname?: Fact<string>
  /** The account we signed in as. */
  user?: Fact<string>
  privilege?: Fact<Privilege>
  init?: Fact<InitSystem>
  containerRuntime?: Fact<ContainerRuntime>
  /** The name of the tool this server installs software with. */
  packageManager?: Fact<string>
  /** The name of the web server program that is installed, if one is. */
  webServer?: Fact<string>
  cpus?: Fact<number>
  disk?: Fact<Amount>
  memory?: Fact<Amount>
  /** One-minute load average, only ever shown interpreted against `cpus`. */
  load?: Fact<number>
  uptimeSeconds?: Fact<number>
  /** How many things are accepting connections. Zone three's business. */
  listeners?: Fact<number>
  /**
   * The coding assistants installed **for this sign-in**, not for the machine.
   *
   * Per-account rather than per-machine, and that is measured rather than
   * pedantic: the test box has three home folders on it, each with its own
   * settings. A line saying an assistant is "on this server" would be true of
   * the machine and wrong for the person reading it.
   *
   * An empty list is a real answer — every place an installer puts one was
   * looked in — which is what lets the page offer to put one there. `cannot` is
   * the answer that offers nothing.
   */
  agents?: Fact<AgentOnServer[]>
}

/**
 * One coding assistant found on a server, as this screen reads it.
 *
 * An empty `version` is not missing data: it means the program is there and
 * would not start, which is a different thing to offer somebody than an empty
 * server. `signedIn` has three states for the same reason every other fact does.
 */
/**
 * The three agents this app can set up, as the renderer names them.
 *
 * Declared here rather than imported from `main/servers/facts.ts` for the reason
 * every other type in this file is: the renderer keeps its own narrowed copy of
 * what crosses the bridge, so that a change on the other side arrives as a
 * type error here rather than as a screen quietly drawing nothing.
 *
 * The order is the order the rows are drawn in, and it is the far end's order —
 * `SETUP_AGENTS` in `servers/setup.ts` — so the two cannot disagree about which
 * agent is first on a screen whose whole point is that none of them is special.
 */
export type AgentId = 'claude' | 'codex' | 'gemini'

export const AGENT_IDS: readonly AgentId[] = ['claude', 'codex', 'gemini']

export interface AgentOnServer {
  id: string
  path: string
  version: string
  signedIn: 'yes' | 'no' | 'unknown'
  /** The address it is signed in as. Shown, and written nowhere. */
  account: string | null
}

/* ------------------------------------------------------------- the cards -- */

/**
 * The three nouns, and the remainder.
 *
 * There is no fourth noun on purpose. The temptation is to add "service" for
 * whatever will not classify, and it must be resisted: "service" is a word a
 * non-technical person does not own, and once it exists every ambiguous case
 * gets filed under it until it is the largest group on the page. `other` is a
 * heading, not a noun — the rows under it are named by whatever the server
 * called them.
 */
export type CardKind = 'site' | 'app' | 'database' | 'other'

/** One site, app, database or unclassified thing found on a server. */
export interface ServerCard {
  id: string
  kind: CardKind
  /** The person's own name for it, as the server itself names it. */
  name: string
  /**
   * One line naming what was actually found — *"Served by nginx"*, *"Running in
   * a container"*.
   *
   * Naming a thing we measured is honesty and the person is entitled to it.
   * Naming a thing we assumed is the bug this whole area is arranged against,
   * which is why this string is written where the measuring happens.
   */
  detail: string
  /**
   * Whether it is running, and **null is a real answer**: we found it and could
   * not tell whether it is up. A screen that drew that as "stopped" would send
   * somebody to restart a thing that is running perfectly well.
   */
  running: boolean | null
  /** A real address a browser can open, from the server's own configuration. */
  url: string | null
}

/**
 * The three classes an action can be, and there is no fourth.
 *
 * Safe changes nothing. Reversible has a named button that puts it back. Kept
 * records the way back *before* it acts and refuses if it could not. Because
 * there is no fourth, nothing irreversible can be expressed at all — which is a
 * stronger guarantee than a frightening dialog, since a run of harmless
 * confirmations has already trained somebody to press yes by the time the
 * frightening one arrives.
 */
export type ActionClass = 'safe' | 'reversible' | 'kept'

/**
 * What a person is shown before they press: what will happen, to what, and for
 * how long.
 *
 * Every string on it is written where the action is implemented. This screen
 * asks for one of these per offered action when a page opens — which costs
 * nothing, because it is answered from the facts already in hand — and then has
 * the real sentence in its pocket before anybody presses anything.
 */
export interface ActionPreview {
  actionId: string
  klass: ActionClass
  /** The button's own word. */
  label: string
  /** The person's name for the thing this happens to. */
  target: string
  /** The consequence sentence. The one string all three surfaces render. */
  sentence: string
  /** The button that puts it back, when the class has one. */
  wayBack: string | null
  /** What will be written down first, for the `kept` class. */
  keeps: string | null
}

/**
 * An action somebody might look for and will not find, with the reason.
 *
 * Every button on a card is either a real action or absent — never greyed
 * hopefully. But an absence with no explanation reads as a missing feature, so
 * the reason is written on the card. The clearest case is a database whose kind
 * we could not recognise: dumping it with the wrong tool produces a file that
 * looks like a backup and is not one, which is worse than no button by a wide
 * margin, and nobody can know that from a missing button alone.
 */
export interface AbsentAction {
  actionId: string
  because: string
}

/** What came back from actually pressing one. */
export interface ActionOutcome {
  /** One sentence, past tense. Written where the work happened. */
  done: string
  /** The button that undoes this, when there is one. */
  wayBack: { actionId: string; label: string } | null
}

/** One server, measured. */
export interface ServerView {
  cards: ServerCard[]
  facts: ServerFacts
  /** cardId → the actions its facts support, in the order a card draws them. */
  offered: Record<string, string[]>
  /** cardId → the actions that are not there, each with its sentence. */
  absent: Record<string, AbsentAction[]>
  /** The checks that ran, in plain words. */
  how: string[]
  /** Questions that could not be asked, with the reason. Never drawn as a zero. */
  cannot: Array<{ what: string; why: string }>
  measuredAt: number
}

/* ------------------------------------------------------------ the server -- */

/** Which kind of sign-in is stored — never any of it. */
export type CredentialKind = 'password' | 'key' | 'none'

/** One server, as the list draws it. */
export interface Server {
  id: string
  name: string
  address: string
  username: string
  /** Absent when the list did not say. Never the credential itself. */
  credential?: CredentialKind
  /**
   * The identity this server answered with, as a fingerprint.
   *
   * Public by design, and byte-identical to what every other tool prints for
   * the same server — which is the entire value of showing it. A person asked
   * whether they recognise one can go and check it somewhere else.
   */
  fingerprint?: string
}

/**
 * Where one server's page stands, held by the window rather than pushed.
 *
 * There is one of these per server the person has opened during this launch,
 * and none at all for one they have not. Nothing refreshes it on a timer: it is
 * written when a page opens, when the refresh is pressed, and when an action
 * changes something.
 */
export interface ServerState {
  id: string
  link: 'connecting' | 'ready' | 'failed'
  /** The sentence the main process wrote about the failure. */
  problem?: string
  /**
   * True when the failure was the server answering as somebody else.
   *
   * A different case from every other failure, because it is the one where
   * there is nothing to try again and nothing to fix from here. The page
   * becomes the warning and stops.
   */
  identityChanged?: boolean
  /** Both fingerprints, when they differ. Shown side by side. */
  identity?: { expected: string; offered: string }
  view?: ServerView
  /** cardId → what each of its offered actions would do. */
  previews?: Record<string, ActionPreview[]>
  /** The copilot's permission for this one server, or null when there is none. */
  grant?: GrantState | null
}

/** The copilot's per-server permission. */
export interface GrantState {
  serverId: string
  expiresAt: number
  grantedAt: number
}

/* ------------------------------------------------------------- adding one -- */

/**
 * What the add form collects: three things anybody can answer.
 *
 * Nothing configured in advance, no file to prepare first, no tool to install,
 * no agent to start. Everything else has a sensible answer without being asked
 * — and where the sensible answer can be wrong, there is somewhere to say so
 * and it is empty until somebody needs it. See {@link AddServerDraft.port}.
 */
export interface AddServerDraft {
  address: string
  username: string
  /**
   * Which port the server listens on. **Absent means 22**, which is what
   * `store.ts` fills in — `DEFAULT_PORT`, applied through `validPort` on the
   * way into the stored row, so the number never has to be defaulted twice.
   *
   * Absent rather than 22 on purpose. A form that always sends a number cannot
   * be told apart from a person who typed one, and the two want different
   * things the day the default changes: an explicit 22 is a decision to keep,
   * and an empty field is a decision not to have made one.
   *
   * `src/main/servers/ipc.ts` has carried `port?: number` on its own copy of
   * this draft since the channel was written, and `store.add` has always taken
   * it. This side is the half that never sent it, which is the whole reason a
   * server on any other port could not be added at all.
   */
  port?: number
  method: 'password' | 'key'
  password?: string
  key?: string
  /** Supplied only after the key turns out to be locked. */
  passphrase?: string
  /** Empty means "use the address". */
  name?: string
  /** False keeps the sign-in for this session and writes nothing to disk. */
  remember: boolean
}

/**
 * Why an attempt to add a server did not finish.
 *
 * `needs-passphrase` is the one that is not a failure: a locked key is normal,
 * and the only thing missing is a question nobody has asked yet. That is why
 * this is a union rather than a boolean — the form grows a field instead of
 * printing a refusal.
 */
export type AddServerFailure =
  | 'needs-passphrase'
  | 'bad-passphrase'
  | 'key-unreadable'
  | 'sign-in-refused'
  | 'no-such-address'
  | 'no-answer'
  | 'not-a-server'
  | 'said-nothing'
  | 'nothing-in-common'
  | 'unknown'

export type AddServerResult =
  | { ok: true; id: string }
  | { ok: false; reason: AddServerFailure; message: string }

/** Bytes from one shell, on their way to a terminal. */
export interface ShellOutput {
  shellId: string
  data: string
}

/* ------------------------------------------------------------ the bridge -- */

/**
 * The slice of the preload bridge this area needs.
 *
 * Named `*Bridge` on purpose: `src/preload/contract.test.ts` reads every
 * interface with that in its name and fails the build if the preload has
 * stopped exposing one of these methods. That check exists because this seam
 * has broken three times here without a single type error — a panel calling
 * `browserClaim` against a preload exposing `browserViewClaim` renders its "not
 * wired into this build" state and looks like an unfinished feature.
 *
 * Which means: **until the preload exposes these, that test is red, and it is
 * right to be.** This interface is the renderer's half of the contract, and the
 * failure names precisely which methods the other half still owes.
 *
 * Two shapes only, so a stub can mirror it without guessing: `on*` returns an
 * unsubscribe function, everything else returns a promise.
 */
export interface ServersBridge {
  /** `servers:list` */
  listServers(): Promise<unknown>
  /** `servers:look` — connect if needed, measure once, answer the whole view. */
  lookAtServer(id: string): Promise<unknown>
  /** `servers:close` — hang up. Called when the page closes. */
  closeServer(id: string): Promise<unknown>
  /** `servers:preview` — what an action would do, without doing it. */
  previewServerAction(id: string, cardId: string, actionId: string): Promise<unknown>
  /** `servers:act` */
  actOnServer(id: string, cardId: string, actionId: string): Promise<unknown>
  /** `servers:logs` — a bounded window, newest last. */
  readServerLogs(id: string, cardId: string, lines: number): Promise<unknown>
  /** `servers:grant` — let the copilot act on this one server, for a while. */
  grantServerCopilot(id: string, forMs: number): Promise<unknown>
  /** `servers:revoke` */
  revokeServerCopilot(id: string): Promise<unknown>
  /** `servers:grant-state` */
  serverGrantState(id: string): Promise<unknown>
  /**
   * `servers:shell:open` — answers the id of the one shell it opened.
   *
   * `startIn` is the folder it should open in. Left off means wherever the
   * sign-in lands, which is what every terminal this app opened before the
   * folder picker existed did, and is still what a press that chose no folder
   * gets.
   */
  openServerShell(id: string, cols: number, rows: number, startIn?: string): Promise<unknown>
  /** `servers:shell:write` — by shell id, not by server id. */
  writeToServerShell(shellId: string, data: string): Promise<unknown>
  /** `servers:shell:resize` — columns first, then rows, everywhere. */
  resizeServerShell(shellId: string, cols: number, rows: number): Promise<unknown>
  /** `servers:shell:close` */
  closeServerShell(shellId: string): Promise<unknown>
  /**
   * `servers:chat:load` / `servers:chat:tail` / `servers:chat:close` — the
   * conversation the agent in that shell is writing, read from that server.
   *
   * Keyed on the shell, never on a path. Which transcript belongs to a terminal
   * is decided in the main process out of the moment the shell was opened
   * against each transcript's own first line — see `servers/chat.ts` — so this
   * side holds a handle for the session and never names a file on somebody
   * else's disk.
   *
   * Optional, and **not** in `BRIDGE_METHODS` below, for the reason that list
   * exists: a preload older than these channels must lose the chat view for a
   * server terminal, not the whole servers area. Absent means the mode switch
   * refuses chat with the sentence it always had, which is a smaller screen
   * rather than a broken one.
   */
  loadServerChat?(shellId: string): Promise<unknown>
  tailServerChat?(shellId: string): Promise<unknown>
  closeServerChat?(shellId: string): Promise<unknown>
  /**
   * `servers:shell:account` — which login the coding agent in that server
   * account's home is signed in as.
   *
   * Not the session's account and not a menu. Nothing on the SSH side records
   * which login a shell's agent is on, so the bar states the fact that does
   * exist and states it as what it is. Optional for the same reason the three
   * above are.
   */
  serverShellAccount?(shellId: string): Promise<unknown>
  /**
   * `servers:folder` — what is inside one folder, over SFTP.
   *
   * Optional, and it is **not** in `BRIDGE_METHODS` below, for the reason that
   * list exists at all: a preload older than this channel would otherwise make
   * `resolveServersBridge` answer null and take the whole servers area away
   * over a folder picker. Absent means the picker offers no list and the path
   * is typed, which is the same fallback a server with no SFTP subsystem gets.
   */
  listServerFolder?(id: string, path: string): Promise<unknown>
  /**
   * `servers:start-in` — the folder this server starts a session in by default.
   *
   * Optional for the same reason `listServerFolder` is, and out of
   * `BRIDGE_METHODS` for the same reason: a preload older than this channel
   * must lose the default folder, not the whole servers area. Absent means the
   * picker draws no default and offers no way to set one, which is the screen
   * this app had the day before yesterday.
   *
   * It reads a stored preference and asks the server nothing, which is what
   * lets the picker call it while it is merely on screen.
   */
  serverStartIn?(id: string): Promise<unknown>
  /** `servers:start-in:set` — remember that folder, or clear it with null. */
  setServerStartIn?(id: string, path: string | null): Promise<unknown>
  /** `servers:keys` — the private keys already on this computer, by name. */
  serverKeys?(): Promise<unknown>
  /** `servers:key-pick` — a native panel, for a key that is not in `~/.ssh`. */
  pickServerKey?(): Promise<unknown>
  /** `servers:key-read` — the bytes of one key this process itself offered. */
  readServerKey?(path: string): Promise<unknown>
  /** `servers:shell:output` */
  onServerShellOutput(cb: (chunk: unknown) => void): () => void
  /** `servers:shell:closed` */
  onServerShellClosed(cb: (chunk: unknown) => void): () => void
  /** `servers:add` */
  addServer(draft: unknown): Promise<unknown>
  /** `servers:forget` */
  forgetServer(id: string): Promise<unknown>
  /** `servers:rename` */
  renameServer(id: string, name: string): Promise<unknown>
  /**
   * `servers:setup:look` — what this server has, and what putting one there
   * would cost.
   *
   * All seven of these are optional and **none of them is in `BRIDGE_METHODS`**,
   * for exactly the reason that list exists: a preload older than these channels
   * would otherwise make `resolveServersBridge` answer null and take the whole
   * servers area away over a setup panel. Absent means the page draws the line
   * saying what is installed and offers no buttons, which is a smaller screen
   * rather than a broken one.
   */
  serverSetup?(id: string): Promise<unknown>
  /** `servers:setup:state` — where a setup already in flight has got to. */
  serverSetupState?(id: string, agentId: string): Promise<unknown>
  /** `servers:setup:install` — typed into the terminal named by `shellId`. */
  installOnServer?(id: string, agentId: string, shellId: string): Promise<unknown>
  /** `servers:setup:signin` — same terminal, and it follows an install on its own. */
  signInOnServer?(id: string, agentId: string, shellId: string): Promise<unknown>
  /** `servers:setup:cancel` — stop it and leave nothing behind on the server. */
  cancelServerSetup?(id: string): Promise<unknown>
  /** `servers:setup:remove` — the way back, and only for what this app installed. */
  removeServerSetup?(id: string, agentId: string): Promise<unknown>
  /** `servers:setup:changed` — pushed, because a sixty-second install is not a press. */
  onServerSetup?(cb: (state: unknown) => void): () => void
  /**
   * `servers:host:look` — the headless host on that server, and what putting
   * one there would cost.
   *
   * Optional and out of `BRIDGE_METHODS` for the same reason the setup channels
   * are: a preload older than these would otherwise take the whole servers area
   * away over one panel. Absent means the page draws no host section at all,
   * which is a smaller screen rather than a broken one.
   */
  serverHost?(id: string): Promise<unknown>
  /** `servers:host:state` — where an install already in flight has got to. */
  serverHostState?(id: string): Promise<unknown>
  /** `servers:host:install` — run in the terminal named by `shellId`. */
  installHostOnServer?(id: string, shellId: string): Promise<unknown>
  /** `servers:host:pair` — a code out of a host that is already installed. */
  pairHostOnServer?(id: string, shellId: string): Promise<unknown>
  /** `servers:host:remove` — the way back, and it says what it leaves. */
  removeHostFromServer?(id: string, alsoData: boolean): Promise<unknown>
  /** `servers:host:cancel` — stop what this app started in that terminal. */
  cancelServerHost?(id: string): Promise<unknown>
  /** `servers:host:changed` — pushed, because a two-minute install is not a press. */
  onServerHost?(cb: (state: unknown) => void): () => void
}

const BRIDGE_METHODS = [
  'listServers',
  'lookAtServer',
  'closeServer',
  'previewServerAction',
  'actOnServer',
  'readServerLogs',
  'grantServerCopilot',
  'revokeServerCopilot',
  'serverGrantState',
  'openServerShell',
  'writeToServerShell',
  'resizeServerShell',
  'closeServerShell',
  'onServerShellOutput',
  'onServerShellClosed',
  'addServer',
  'forgetServer',
  'renameServer',
] as const

/**
 * The bridge, or null when this build does not carry it.
 *
 * Read defensively rather than assumed, so an app whose preload is older than
 * this panel says "not in this build" once instead of throwing inside an effect
 * and leaving a blank page with a stack trace in a console nobody opens.
 *
 * It reads `window.deck` as a plain record rather than as `DeckApi`, and that is
 * deliberate: `DeckApi` is the *declared* surface, and the whole question this
 * function answers is whether the running preload matches it. Asking the type
 * would be asking the wrong witness.
 */
export function resolveServersBridge(supplied?: ServersBridge): ServersBridge | null {
  if (supplied) return supplied
  const deck = deckObject()
  if (deck === null) return null
  for (const method of BRIDGE_METHODS) {
    if (typeof deck[method] !== 'function') return null
  }
  return deck as unknown as ServersBridge
}

/** Which methods a partly-wired build is missing, for a sentence that names them. */
export function missingServerMethods(): string[] {
  const deck = deckObject()
  if (deck === null) return [...BRIDGE_METHODS]
  return BRIDGE_METHODS.filter((method) => typeof deck[method] !== 'function')
}

function deckObject(): Record<string, unknown> | null {
  if (typeof window === 'undefined') return null
  const deck: unknown = (window as unknown as { deck?: unknown }).deck
  return isRecord(deck) ? deck : null
}

/* ------------------------------------------------------------- narrowing -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function whole(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * One fact, or `undefined` when it was never gathered.
 *
 * `undefined` is the fourth thing a `Fact` may never be, and it is expressed by
 * the field's absence rather than by a fourth state — so a caller holding a
 * `Fact` has exactly three cases to think about, and a caller asking whether we
 * ever put the question does that separately. Anything unreadable becomes
 * absent rather than being folded into `no`: we did not learn that there is
 * nothing there, we learned nothing.
 */
export function asFact<T>(value: unknown, read: (raw: unknown) => T | null): Fact<T> | undefined {
  if (!isRecord(value)) return undefined
  const measuredAt = whole(value.measuredAt) ?? 0
  if (value.known === 'yes') {
    const inner = read(value.value)
    if (inner === null) return undefined
    return { known: 'yes', value: inner, measuredAt, how: text(value.how) }
  }
  if (value.known === 'no') return { known: 'no', measuredAt, how: text(value.how) }
  if (value.known === 'cannot') return { known: 'cannot', measuredAt, why: text(value.why) }
  return undefined
}

function readText(raw: unknown): string | null {
  const value = text(raw)
  return value === '' ? null : value
}

function readNumber(raw: unknown): number | null {
  return whole(raw)
}

/**
 * A used-and-total pair, from either of the two shapes a server reports.
 *
 * Disk arrives as used-and-total and memory arrives as total-and-free, because
 * that is what the two measurements natively are. Both become the same pair
 * here rather than at the two places that draw them, so nothing on a screen has
 * to remember which is which.
 *
 * A total of zero is refused. A percentage of nothing is `NaN` or `Infinity` on
 * somebody's screen, and neither is a number anybody can act on.
 */
function readAmount(raw: unknown): Amount | null {
  if (!isRecord(raw)) return null
  const totalKb = whole(raw.totalKb)
  if (totalKb === null || totalKb <= 0) return null
  const usedKb = whole(raw.usedKb)
  if (usedKb !== null) return { usedKb, totalKb }
  const freeKb = whole(raw.freeKb)
  if (freeKb === null) return null
  return { usedKb: Math.max(0, totalKb - freeKb), totalKb }
}

/** How many rows a list-shaped fact has — or the number, when it arrived as one. */
function readCount(raw: unknown): number | null {
  if (Array.isArray(raw)) return raw.length
  return whole(raw)
}

function oneOf<T extends string>(known: readonly T[]): (raw: unknown) => T | null {
  return (raw) => known.find((value) => value === raw) ?? null
}

const PRIVILEGES: readonly Privilege[] = ['yes', 'sudo-nopasswd', 'sudo-password', 'no']
const INITS: readonly InitSystem[] = ['systemd', 'openrc', 'launchd', 'sysvinit', 'container-none']
const RUNTIMES: readonly ContainerRuntime[] = ['docker', 'podman']

/**
 * The facts, from whichever record arrived.
 *
 * Two names are read for three of these, and the reason is a genuine collision
 * rather than tolerance for its own sake. The probe's record calls this
 * sign-in's power `privilege` and the action layer's slice calls it `root`;
 * `containerRuntime` names the runtime while `containers` names the containers
 * *found*, and one slice uses the shorter word for the former. Reading both
 * spellings here is one small function; reading them at every call site is a
 * bug waiting for whichever call site is written last.
 */
export function asFacts(value: unknown): ServerFacts {
  if (!isRecord(value)) return {}
  // `containers` is the collision: an array of what was found in one record and
  // the name of the runtime in the other. The value decides which, because the
  // two cannot be confused — one is a list and the other is a word.
  const runtime = Array.isArray(
    isRecord(value.containers) && 'value' in value.containers ? value.containers.value : null,
  )
    ? undefined
    : asFact(value.containers, oneOf(RUNTIMES))
  return {
    os: asFact(value.os, readText),
    kernel: asFact(value.kernel, readText),
    arch: asFact(value.arch, readText),
    hostname: asFact(value.hostname, readText),
    user: asFact(value.user, readText),
    privilege: asFact(value.privilege, oneOf(PRIVILEGES)) ?? asFact(value.root, oneOf(PRIVILEGES)),
    init: asFact(value.init, oneOf(INITS)),
    containerRuntime: asFact(value.containerRuntime, oneOf(RUNTIMES)) ?? runtime,
    packageManager: asFact(value.packageManager, readText) ?? asFact(value.packages, readText),
    webServer: asFact(value.webServer, readText) ?? asFact(value.web, readText),
    cpus: asFact(value.cpus, readNumber),
    disk: asFact(value.disk, readAmount),
    memory: asFact(value.memory, readAmount),
    load: asFact(value.load1, readNumber) ?? asFact(value.load, readNumber),
    uptimeSeconds: asFact(value.uptimeSeconds, readNumber) ?? asFact(value.uptime, readNumber),
    listeners: asFact(value.listeners, readCount),
    agents: asFact(value.agents, readAgents),
  }
}

/**
 * The agent rows, dropping any that could not be read rather than the whole list.
 *
 * A row with no path cannot be acted on and a row with no id cannot be named, so
 * those two go; everything else is carried through as the far end said it,
 * including an empty version — which is the answer that means *installed and
 * will not start*.
 */
function readAgents(raw: unknown): AgentOnServer[] | null {
  if (!Array.isArray(raw)) return null
  const out: AgentOnServer[] = []
  for (const entry of raw) {
    if (!isRecord(entry)) continue
    const id = text(entry.id)
    const path = text(entry.path)
    if (id === '' || path === '') continue
    const signedIn = entry.signedIn
    out.push({
      id,
      path,
      version: text(entry.version),
      signedIn: signedIn === 'yes' ? 'yes' : signedIn === 'no' ? 'no' : 'unknown',
      account: readText(entry.account),
    })
  }
  return out
}

const CARD_KINDS: readonly CardKind[] = ['site', 'app', 'database', 'other']

function asCard(value: unknown): ServerCard | null {
  if (!isRecord(value)) return null
  const id = text(value.id)
  const name = text(value.name)
  // A card with no id cannot be acted on and one with no name cannot be told
  // apart from the card beside it. Both are dropped rather than drawn.
  if (id === '' || name === '') return null
  return {
    id,
    kind: CARD_KINDS.find((known) => known === value.kind) ?? 'other',
    name,
    detail: text(value.detail),
    running: typeof value.running === 'boolean' ? value.running : null,
    url: readText(value.url),
  }
}

const CLASSES: readonly ActionClass[] = ['safe', 'reversible', 'kept']

export function asPreview(value: unknown): ActionPreview | null {
  if (!isRecord(value)) return null
  const actionId = text(value.actionId)
  const label = text(value.label)
  const klass = CLASSES.find((known) => known === value.klass)
  /*
   * A class outside the three is dropped rather than drawn.
   *
   * The three are the whole safety model: nothing changes, one press puts it
   * back, or the way back was recorded first. Anything else is an action with
   * no way back, which is the thing this version does not ship — and a drawn
   * button is a promise that it does.
   */
  if (actionId === '' || label === '' || klass === undefined) return null
  return {
    actionId,
    klass,
    label,
    target: text(value.target),
    sentence: text(value.sentence),
    wayBack: readText(value.wayBack),
    keeps: readText(value.keeps),
  }
}

function asAbsent(value: unknown): AbsentAction | null {
  if (!isRecord(value)) return null
  const actionId = text(value.actionId)
  const because = text(value.because)
  // An absence with no reason is just an absence, and drawing an empty line for
  // one would be a sentence that says nothing.
  if (actionId === '' || because === '') return null
  return { actionId, because }
}

function asStringList(value: unknown): string[] {
  return Array.isArray(value) ? value.map(text).filter((entry) => entry !== '') : []
}

function asKeyedLists(value: unknown): Record<string, string[]> {
  if (!isRecord(value)) return {}
  const out: Record<string, string[]> = {}
  for (const [key, raw] of Object.entries(value)) out[key] = asStringList(raw)
  return out
}

function asKeyedAbsent(value: unknown): Record<string, AbsentAction[]> {
  if (!isRecord(value)) return {}
  const out: Record<string, AbsentAction[]> = {}
  for (const [key, raw] of Object.entries(value)) {
    out[key] = Array.isArray(raw)
      ? raw.map(asAbsent).filter((entry): entry is AbsentAction => entry !== null)
      : []
  }
  return out
}

/* --------------------------------------------------------------- setting up -- */

/** Where one server's setup has got to. Six steps, and no seventh. */
export type SetupStep = 'idle' | 'installing' | 'installed' | 'signing-in' | 'done' | 'failed'

/**
 * The setup's own state, as the main process pushes it.
 *
 * Every readable string on it was written on the other side, beside the code
 * that does the work — §4.3 — and this screen renders them. It composes none,
 * which is the same rule the action previews follow and for the same reason: a
 * screen that wrote its own would be describing work it does not do.
 */
export interface SetupState {
  serverId: string
  /** Which of the three rows this push is about. */
  agentId: AgentId
  step: SetupStep
  /** The one line under the terminal. */
  line: string
  /** The server's own words, when something failed. */
  detail: string
  /**
   * The sign-in has fallen back to being finished by hand.
   *
   * No address comes with it, deliberately: the one that works for a person
   * doing it themselves is the one already printed in the terminal, three lines
   * above the prompt it goes with.
   */
  byHand: boolean
  /** True when this app is the thing that installed it, which is what makes a way back honest. */
  weInstalled: boolean
  version: string | null
}

/**
 * One agent's row: what this server has of it, and whether that can be changed.
 *
 * Three of these arrive on every look, in a fixed order, whether or not the
 * server has any of them — see {@link SetupOffer}.
 */
export interface SetupRow {
  agentId: AgentId
  /** The agent's own name, read off the far end rather than spelled here. */
  label: string
  installed: AgentOnServer | null
  canInstall: boolean
  /** Why not, in the server's own terms. Null when there is nothing in the way. */
  why: string | null
  /** The consequence sentence, written where the install is implemented. */
  consequence: string
  state: SetupState
}

/**
 * What one server would need in order to be set up, for each agent it could run.
 *
 * A list rather than a single row since 2026-08-20. The one-row version showed
 * everybody the same agent whatever they use, which he overruled: *"Maybe some
 * users are only using Codex, they never use Claude."* An empty list is a far
 * end too old to answer this, and the panel draws nothing for it.
 */
export interface SetupOffer {
  rows: readonly SetupRow[]
}

const SETUP_STEPS: readonly SetupStep[] = [
  'idle',
  'installing',
  'installed',
  'signing-in',
  'done',
  'failed',
]

export function asSetupState(value: unknown): SetupState | null {
  if (!isRecord(value)) return null
  const serverId = text(value.serverId)
  if (serverId === '') return null
  const agentId = AGENT_IDS.find((known) => known === value.agentId)
  if (agentId === undefined) return null
  return {
    serverId,
    agentId,
    step: SETUP_STEPS.find((known) => known === value.step) ?? 'idle',
    line: text(value.line),
    detail: text(value.detail),
    byHand: value.byHand === true,
    weInstalled: value.weInstalled === true,
    version: readText(value.version),
  }
}

export function asSetupOffer(value: unknown): SetupOffer | null {
  if (!isRecord(value) || !Array.isArray(value.rows)) return null
  const rows: SetupRow[] = []
  for (const raw of value.rows) {
    if (!isRecord(raw)) continue
    const state = asSetupState(raw.state)
    const agentId = AGENT_IDS.find((known) => known === raw.agentId)
    // A row with no name on it cannot be drawn and cannot be acted on, so it is
    // dropped rather than guessed at. The pane below shows the two that arrived.
    if (state === null || agentId === undefined) continue
    const installed = readAgents([raw.installed])
    rows.push({
      agentId,
      label: text(raw.label),
      installed: installed !== null && installed.length > 0 ? installed[0] : null,
      // A button is drawn only when the far end said yes. Anything unreadable is
      // a no, which draws no button — never a hopeful one.
      canInstall: raw.canInstall === true,
      why: readText(raw.why),
      consequence: text(raw.consequence),
      state,
    })
  }
  return { rows }
}

/* ------------------------------------------------ the host on that server -- */

/** Where one server's headless-host install has got to. */
export type HostStep =
  | 'idle'
  | 'checking'
  | 'uploading'
  | 'installing'
  | 'service'
  | 'pairing'
  | 'done'
  | 'removing'
  | 'failed'

/**
 * The install's own state, as the main process pushes it.
 *
 * Same rule as {@link SetupState}: every readable string on it was written
 * beside the code that does the work, and this screen renders them unchanged.
 * `done` is the part that answers the specific complaint — a list of the steps
 * that have finished, so somebody who looked away comes back to what happened
 * rather than only to what is happening.
 */
export interface HostState {
  serverId: string
  step: HostStep
  line: string
  detail: string
  done: readonly string[]
  /** The pairing code the host printed, exactly as it printed it. */
  code: string | null
  weInstalled: boolean
}

/** Whether the host on that server is up, as far as its own status will say. */
export type HostRunning = 'yes' | 'no' | 'unknown'

/** What is on that server now. */
export interface HostOnServer {
  command: string
  version: string
  running: HostRunning
  /** The host's own status output, verbatim, or empty when there is none to ask. */
  status: string
  unit: string
  linger: boolean
  data: boolean
  dataDir: string
}

/** What it would take to put one there. Only what this screen actually reads. */
export interface HostRoom {
  os: string
  arch: string
  node: string
  npm: string
  systemdUser: boolean
}

/** What one server can say about the headless host. */
export interface HostOffer {
  host: HostOnServer
  room: HostRoom
  canInstall: boolean
  why: string | null
  /** The standing line for the section, written where the work is. */
  line: string
  /** Whether it will still be there tomorrow. Null when there is no host. */
  reach: string | null
  consequence: string
  /** The two answers to the data question, each written where the work is. */
  removes: { keepData: string; withData: string }
  state: HostState
}

const HOST_STEPS: readonly HostStep[] = [
  'idle',
  'checking',
  'uploading',
  'installing',
  'service',
  'pairing',
  'done',
  'removing',
  'failed',
]

export function asHostState(value: unknown): HostState | null {
  if (!isRecord(value)) return null
  const serverId = text(value.serverId)
  if (serverId === '') return null
  return {
    serverId,
    step: HOST_STEPS.find((known) => known === value.step) ?? 'idle',
    line: text(value.line),
    detail: text(value.detail),
    done: Array.isArray(value.done)
      ? value.done.map((entry) => text(entry)).filter((entry) => entry !== '')
      : [],
    code: readText(value.code),
    weInstalled: value.weInstalled === true,
  }
}

export function asHostOffer(value: unknown): HostOffer | null {
  if (!isRecord(value)) return null
  const host = value.host
  const room = value.room
  const state = asHostState(value.state)
  if (!isRecord(host) || !isRecord(room) || state === null) return null
  const removes = isRecord(value.removes) ? value.removes : {}
  const running = host.running
  return {
    host: {
      command: text(host.command),
      version: text(host.version),
      running: running === 'yes' ? 'yes' : running === 'no' ? 'no' : 'unknown',
      status: text(host.status),
      unit: text(host.unit),
      linger: host.linger === true,
      data: host.data === true,
      dataDir: text(host.dataDir),
    },
    room: {
      os: text(room.os),
      arch: text(room.arch),
      node: text(room.node),
      npm: text(room.npm),
      systemdUser: room.systemdUser === true,
    },
    // A button is drawn only when the far end said yes. Anything unreadable is a
    // no, which draws no button — never a hopeful one.
    canInstall: value.canInstall === true,
    why: readText(value.why),
    line: text(value.line),
    reach: readText(value.reach),
    consequence: text(value.consequence),
    removes: { keepData: text(removes.keepData), withData: text(removes.withData) },
    state,
  }
}

export function asView(value: unknown): ServerView | null {
  if (!isRecord(value)) return null
  return {
    cards: Array.isArray(value.cards)
      ? value.cards.map(asCard).filter((card): card is ServerCard => card !== null)
      : [],
    facts: asFacts(value.facts),
    offered: asKeyedLists(value.offered),
    absent: asKeyedAbsent(value.absent),
    how: asStringList(value.how),
    cannot: Array.isArray(value.cannot)
      ? value.cannot
          .map((entry) =>
            isRecord(entry) ? { what: text(entry.what), why: text(entry.why) } : null,
          )
          .filter((entry): entry is { what: string; why: string } => entry !== null && entry.why !== '')
      : [],
    measuredAt: whole(value.measuredAt) ?? 0,
  }
}

/**
 * The answer every fallible handler gives.
 *
 * A refusal carries the sentence written where the refusal happened, and this
 * side renders it rather than rewriting it. `identityChanged` is pulled out of
 * it because that one failure is not a failure to try again — it is the page
 * stopping, and it needs to be recognisable rather than merely readable.
 */
export interface Refusal {
  sentence: string
  identityChanged: boolean
  identity?: { expected: string; offered: string }
}

export function asRefusal(value: unknown): Refusal {
  if (!isRecord(value)) {
    return { sentence: 'Nothing came back from that. Nothing may have happened.', identityChanged: false }
  }
  const identity = isRecord(value.identity)
    ? { expected: text(value.identity.expected), offered: text(value.identity.offered) }
    : undefined
  return {
    sentence: text(value.sentence) || 'That did not work, and this server did not say why.',
    identityChanged: value.kind === 'identity-changed' || identity !== undefined,
    ...(identity === undefined ? {} : { identity }),
  }
}

/** True when a reply said so itself. Anything unreadable is not a success. */
export function succeeded(value: unknown): boolean {
  return isRecord(value) && value.ok === true
}

export function asOutcome(value: unknown): ActionOutcome {
  if (!isRecord(value)) return { done: 'Done.', wayBack: null }
  const wayBack = isRecord(value.wayBack)
    ? { actionId: text(value.wayBack.actionId), label: text(value.wayBack.label) }
    : null
  return {
    done: text(value.done) || 'Done.',
    wayBack: wayBack !== null && wayBack.actionId !== '' && wayBack.label !== '' ? wayBack : null,
  }
}

const CREDENTIALS: readonly CredentialKind[] = ['password', 'key', 'none']

function asServer(value: unknown): Server | null {
  if (!isRecord(value)) return null
  const id = text(value.id)
  const address = text(value.address)
  if (id === '' || address === '') return null
  const credential = CREDENTIALS.find((known) => known === value.credential)
  const fingerprint = isRecord(value.hostKey) ? text(value.hostKey.fingerprint) : ''
  return {
    id,
    // A server with no name of its own is called by its address, which is what
    // the person typed and therefore what they will recognise. An empty row is a
    // row nobody can tell apart from another empty row.
    name: text(value.name) || address,
    address,
    username: text(value.username),
    ...(credential === undefined ? {} : { credential }),
    ...(fingerprint === '' ? {} : { fingerprint }),
  }
}

/** The stored list, narrowed. An unreadable reply is an empty one. */
export function asServers(value: unknown): Server[] {
  if (!Array.isArray(value)) return []
  return value.map(asServer).filter((server): server is Server => server !== null)
}

/** One name inside a folder on a server. */
export interface FolderEntry {
  name: string
  /**
   * `link` is its own answer rather than resolved to what it points at.
   *
   * Resolving costs one round trip per entry — sixty on an ordinary `/etc` —
   * so a link is drawn as somewhere you may *try* to go, and if it turns out
   * not to be a folder the attempt says so. `main/servers/connection.ts` makes
   * the same argument beside the listing that produces these.
   */
  kind: 'folder' | 'link' | 'file'
}

/** One folder on a server, as the picker holds it. */
export interface Folder {
  /** Absolute, and resolved by the server. Never assembled on this side. */
  path: string
  entries: FolderEntry[]
}

/**
 * Narrow a listing off the bridge.
 *
 * Null when the reply carries no path, because a path is the one field the
 * picker cannot do without: it is what the next call up or down is made with,
 * and a picker holding an empty path would ask for the login directory again
 * on every press. An empty `entries` is a real answer — an empty folder — and
 * is not folded into null.
 */
export function asFolder(value: unknown): Folder | null {
  if (!isRecord(value)) return null
  const path = text(value.path)
  if (path === '') return null
  const entries: FolderEntry[] = []
  if (Array.isArray(value.entries)) {
    for (const entry of value.entries) {
      if (!isRecord(entry)) continue
      const name = text(entry.name)
      if (name === '') continue
      const kind = entry.kind
      entries.push({
        name,
        kind: kind === 'folder' || kind === 'link' ? kind : 'file',
      })
    }
  }
  return { path, entries }
}

export function asGrant(value: unknown): GrantState | null {
  if (!isRecord(value)) return null
  const serverId = text(value.serverId)
  const expiresAt = whole(value.expiresAt)
  if (serverId === '' || expiresAt === null) return null
  return { serverId, expiresAt, grantedAt: whole(value.grantedAt) ?? 0 }
}

const FAILURES: readonly AddServerFailure[] = [
  'needs-passphrase',
  'bad-passphrase',
  'key-unreadable',
  'sign-in-refused',
  'no-such-address',
  'no-answer',
  'not-a-server',
  'said-nothing',
  'nothing-in-common',
  'unknown',
]

/**
 * One key this computer already has, as the main process described it.
 *
 * Never the key itself. `keyfiles.ts` reads the bytes only when one is chosen,
 * and only for a path it offered — so this window holds names and never holds
 * key material it was not given deliberately.
 */
export interface KeyFileOffer {
  path: string
  name: string
  what: string
  /** Null when it could not be told, which is a third state and not a "no". */
  locked: boolean | null
}

export function asKeyOffer(value: unknown): KeyFileOffer | null {
  if (!isRecord(value)) return null
  const { path, name, what, locked } = value
  if (typeof path !== 'string' || path === '') return null
  if (typeof name !== 'string' || name === '') return null
  return {
    path,
    name,
    what: typeof what === 'string' ? what : 'A key',
    locked: typeof locked === 'boolean' ? locked : null,
  }
}

export function asKeyOffers(value: unknown): KeyFileOffer[] {
  if (!Array.isArray(value)) return []
  return value.map(asKeyOffer).filter((offer): offer is KeyFileOffer => offer !== null)
}

/** What came back from asking for one key's text. */
export type KeyTextResult = { ok: true; key: string } | { ok: false; sentence: string }

export function asKeyText(value: unknown): KeyTextResult {
  if (!isRecord(value)) return { ok: false, sentence: 'That file could not be read. Choose it again.' }
  if (value.ok === true && typeof value.key === 'string') return { ok: true, key: value.key }
  return {
    ok: false,
    sentence:
      typeof value.sentence === 'string' && value.sentence !== ''
        ? value.sentence
        : 'That file could not be read. Choose it again.',
  }
}

export function asAddResult(value: unknown): AddServerResult {
  if (!isRecord(value)) {
    return {
      ok: false,
      reason: 'unknown',
      message: 'Nothing came back from that attempt. Try it again.',
    }
  }
  if (value.ok === true) {
    const id = text(value.id)
    if (id !== '') return { ok: true, id }
  }
  // The parentheses matter: `known === value.kind ?? value.reason` parses as
  // `(known === value.kind) ?? value.reason`, which is never nullish and so
  // silently ignores the second spelling. The compiler catches it, and this
  // comment is here so the next person does not "simplify" it back.
  const stated = value.kind ?? value.reason
  return {
    ok: false,
    reason: FAILURES.find((known) => known === stated) ?? 'unknown',
    // The sentence is written where the failure is recognised. This is only the
    // floor under a build that answered with a bare reason and no words.
    message: text(value.sentence) || text(value.message) || 'That did not work, and the server did not say why.',
  }
}

/** The id of the one shell that was opened, or null when it was refused. */
export function asShellId(value: unknown): string | null {
  if (!isRecord(value) || value.ok !== true) return null
  const shellId = text(value.shellId)
  return shellId === '' ? null : shellId
}

export function asShellOutput(value: unknown): ShellOutput | null {
  if (!isRecord(value)) return null
  const shellId = text(value.shellId)
  if (shellId === '') return null
  return { shellId, data: text(value.data) }
}

/** The lines a log window came back with. An unreadable reply is no lines. */
export function asLogLines(value: unknown): string[] {
  if (!isRecord(value) || value.ok !== true) return []
  return Array.isArray(value.lines) ? value.lines.map(text) : []
}
