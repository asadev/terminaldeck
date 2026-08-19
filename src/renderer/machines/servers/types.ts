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
 * no agent to start. Everything else has a sensible answer without being asked.
 */
export interface AddServerDraft {
  address: string
  username: string
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
  /** `servers:shell:open` — answers the id of the one shell it opened. */
  openServerShell(id: string, cols: number, rows: number): Promise<unknown>
  /** `servers:shell:write` — by shell id, not by server id. */
  writeToServerShell(shellId: string, data: string): Promise<unknown>
  /** `servers:shell:resize` — columns first, then rows, everywhere. */
  resizeServerShell(shellId: string, cols: number, rows: number): Promise<unknown>
  /** `servers:shell:close` */
  closeServerShell(shellId: string): Promise<unknown>
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
  }
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
