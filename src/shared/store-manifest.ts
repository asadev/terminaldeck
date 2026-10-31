/**
 * What a community item *is*, and the parser that refuses everything else.
 *
 * ## The decision this file exists to record
 *
 * The Community department lists work written by strangers. Every other store
 * in this app lists rows typed into the app's own source before it shipped, so
 * the worst a bad row could do was be wrong. A catalogue that arrives over the
 * network is a different thing entirely, and the rule it lives under is the one
 * `browser-store-recipe.ts` already argued for its own downloads:
 *
 *   > *A store tool is a recipe: selectors and a closed set of operations over
 *   > what they match.*
 *
 * The same shape, one layer up. **A manifest names a kind, and this app's own
 * compiled code decides what running that kind means.** There is no field
 * anywhere in the grammar below that can hold a command line, a shell fragment,
 * a script body or a URL to fetch and run. An `mcp` item names a runtime out of
 * a closed list and a package; {@link composeMcpCommand} — code in this
 * repository — builds the command. A `hooks` item names an event out of the
 * list its agent actually has; `hooks.ts` writes the entry. A `skill` item names
 * a directory inside its own tree.
 *
 * That is the layer that still holds when everything else fails. If the signing
 * key were stolen tomorrow and a forged catalogue were served to every machine,
 * the worst it could ask for is a differently-named package from a registry the
 * person can read on the row — not `curl … | sh`, because there is nowhere in
 * this grammar to write it.
 *
 * ## Why unknown keys are a refusal
 *
 * `session-tools.ts` makes the argument for a positive list over a remembered
 * deny-list, and `parseRecipe` implements it: a validator that ignores what it
 * does not recognise is a validator that will happily accept next year's
 * dangerous field. Every key at every level is named here; anything else is a
 * refusal *with the key in the message*, because "the manifest is invalid" sends
 * somebody hunting through forty fields for a typo the parser already found.
 *
 * ## Why this is in `shared/` and not `renderer/`
 *
 * `remote/panels/store.ts` already writes the reason down: a daemon's import
 * graph may never contain a React component. The headless host lists community
 * items over the relay, the desktop draws them, and the site's own validator is
 * a copy of this file — three readers, one grammar, or the bug is in exactly one
 * of them and nobody can tell which.
 *
 * ## The vocabularies restated here rather than imported
 *
 * Three closed lists below — the hook events, the MCP runtimes and the price
 * words — already exist in `src/main` and `src/renderer`, and neither is a place
 * `src/shared` may import from: main pulls in `node:http` and the renderer pulls
 * in React, and this module is compiled into both. So they are written out again
 * and `store-manifest.test.ts` asserts each one still agrees with its original,
 * exactly the way `safeProfileId` in `browser-extensions.ts` restates
 * `partitionFor`'s regex and has a test hold the two together.
 */

/* ------------------------------------------------------------- the limits -- */

/**
 * How large a manifest may be, in bytes of JSON.
 *
 * The same 64 KB `parseRecipe` allows, and for the same reason: far past any
 * honest description, small enough that a hostile or corrupt response is thrown
 * away before it is parsed rather than after. Applied to the *bytes*, before
 * `JSON.parse`, because that is the only measurement that bounds the work.
 */
export const MAX_MANIFEST_BYTES = 64 * 1024

/** The file a publisher writes, at the item root or at the listed path. */
export const STORE_MANIFEST_FILE = 'terminaldeck.json'

/** The format number. A manifest from a later format is recognised, not guessed at. */
export const MANIFEST_FORMAT = 1

/* --------------------------------------------------------------- the kinds -- */

/**
 * The seven things a person can publish, and there are seven.
 *
 * A closed list in this repository's own bytes. A manifest picks one by name; a
 * kind this build does not know about is a refusal rather than a row drawn with
 * a button that does nothing.
 */
export const STORE_KINDS = [
  'skill',
  'instructions',
  'hooks',
  'mcp',
  'extension',
  'routine',
  'tool',
] as const

export type StoreKind = (typeof STORE_KINDS)[number]

/** What each kind is called on screen. Sentence case, per `DESIGN-BRIEF.md`. */
export const KIND_NAMES: Readonly<Record<StoreKind, string>> = Object.freeze({
  skill: 'Skill',
  instructions: 'Instructions',
  hooks: 'Hooks',
  mcp: 'MCP server',
  extension: 'Browser extension',
  routine: 'Routine',
  tool: 'Open-source tool',
})

/** One sentence per kind, for the shelf heading. */
export const KIND_ONE_LINE: Readonly<Record<StoreKind, string>> = Object.freeze({
  skill: 'A folder of instructions an agent reads when it needs them.',
  instructions: 'One file of standing instructions, added to what an agent already reads.',
  hooks: 'A script your agent runs at named moments in a session.',
  mcp: 'A server that gives an agent new tools.',
  extension: 'An extension for the browser inside this app.',
  routine: 'A saved job you can schedule or start by hand.',
  tool: 'A program you install yourself. This lists it and links to it.',
})

/**
 * Whether this kind ships bytes we download and pin.
 *
 * `mcp` and `tool` are false, and that is honesty rather than an omission.
 * `npx` and `uvx` fetch the package at spawn time and this app never holds those
 * bytes, so there is nothing for a digest to pin except the manifest itself —
 * the same position `mcp-catalogue.ts` already takes about its own rows. A
 * `tool` is a link to somebody else's download page and nothing more.
 */
export const KIND_HAS_ARTIFACT: Readonly<Record<StoreKind, boolean>> = Object.freeze({
  skill: true,
  instructions: true,
  hooks: true,
  mcp: false,
  extension: true,
  routine: true,
  tool: false,
})

/* ---------------------------------------------------------------- the tier -- */

/** How much of this machine an item can reach. See {@link TIER_WORDS}. */
export type StoreTier = 1 | 2 | 3

/**
 * The exact sentence each tier wears, in one place only.
 *
 * On the row, in the sheet before an install, and on the phone. Three spellings
 * of one fact is how a person learns that the words do not mean anything.
 */
export const TIER_WORDS: Readonly<Record<StoreTier, string>> = Object.freeze({
  1: 'Text only — nothing runs',
  2: 'Ships scripts the agent may run',
  3: 'Runs a program on this machine',
})

/**
 * The lowest tier a kind can ever be, whatever its files turn out to hold.
 *
 * A floor, not an answer: {@link deriveTier} reads the bytes that actually
 * arrived and may land higher. A markdown-only skill is a 1 and a skill shipping
 * a `.sh` is a 2, which is why `skill` floors at 1 rather than at the 2 the
 * first draft of the plan gave it — a floor above the honest answer would make
 * every text-only skill wear a warning it has not earned, and warnings nobody
 * has earned are the ones people stop reading.
 */
export const KIND_TIER_FLOOR: Readonly<Record<StoreKind, StoreTier>> = Object.freeze({
  skill: 1,
  instructions: 1,
  hooks: 3,
  mcp: 3,
  extension: 2,
  routine: 2,
  tool: 1,
})

/** A file in an extracted item, reduced to what the tier rule reads. */
export interface TierFile {
  /** Path inside the item, `/`-separated. */
  path: string
  bytes: number
  /** The mode `lstat` reported. The executable bit is what matters here. */
  mode: number
}

/** Anything with one of these on the end is a script, whoever wrote it. */
const SCRIPT_SUFFIXES = [
  '.sh',
  '.bash',
  '.zsh',
  '.fish',
  '.ps1',
  '.bat',
  '.cmd',
  '.py',
  '.rb',
  '.pl',
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.tsx',
] as const

/**
 * What this item can reach, worked out from the bytes rather than from the row.
 *
 * Pure — no filesystem, no network, no clock — so the indexer that builds the
 * catalogue, the site that validates a submission and the app that just
 * extracted a download all run identical code over identical inputs and get the
 * same answer. When they disagree, the app refuses and names which side
 * differed; that is the whole reason this is a function and not a field.
 */
export function deriveTier(
  kind: StoreKind,
  files: readonly TierFile[],
): { tier: StoreTier; because: string } {
  if (kind === 'hooks' || kind === 'mcp') {
    return {
      tier: 3,
      because:
        kind === 'mcp'
          ? 'an MCP server is a program your agent starts and talks to'
          : 'a hook is a script your agent runs at named moments',
    }
  }
  if (kind === 'extension') return { tier: 2, because: 'a browser extension runs inside the browser pane' }
  if (kind === 'routine') return { tier: 2, because: 'a routine drives an agent session on a schedule' }
  if (kind === 'instructions' || kind === 'tool') {
    return { tier: 1, because: kind === 'tool' ? 'nothing is installed from here' : 'it is one text file' }
  }

  for (const file of files) {
    const lower = file.path.toLowerCase()
    const suffix = SCRIPT_SUFFIXES.find((end) => lower.endsWith(end))
    if (suffix !== undefined) return { tier: 2, because: `it ships ${file.path}` }
    if ((file.mode & 0o111) !== 0) return { tier: 2, because: `${file.path} is marked runnable` }
  }
  return { tier: 1, because: 'every file in it is text' }
}

/* ------------------------------------------------------------ the delivery -- */

/**
 * Where the bytes come from, and the answer is only ever one of two places.
 *
 * `repo` — a public repository we pin to a commit and a sha256, which is every
 * installable item. `off-site` — a listing for something we do not carry: one
 * outbound button to the publisher's own page. There is no third value, because
 * a third value would be a download this app fetches and cannot vouch for.
 */
export const STORE_DELIVERIES = ['repo', 'off-site'] as const

export type StoreDelivery = (typeof STORE_DELIVERIES)[number]

/* ---------------------------------------------------------------- the cost -- */

/**
 * What using it costs, in the words both existing stores already use.
 *
 * Restated from `storefront.ts`'s `StoreCost` minus `unknown`: that fifth value
 * exists for something a person added themselves, and a publisher who cannot say
 * what their own item costs does not get to shrug on a shelf. Everything that is
 * not `free` must carry a note, which is the rule the two catalogue tests
 * already enforce on their own rows and which does not get relaxed for
 * strangers.
 */
export const STORE_COSTS = ['free', 'account', 'metered', 'paid'] as const

export type StoreCost = (typeof STORE_COSTS)[number]

/* --------------------------------------------------------------- the needs -- */

/** What has to be true of the machine before this works, from a closed list. */
export const STORE_NEEDS = ['runs-scripts', 'node', 'python', 'api-key', 'account', 'local-app'] as const

export type StoreNeed = (typeof STORE_NEEDS)[number]

/** One line per need, so a row never invents its own words for the same fact. */
export const NEED_WORDS: Readonly<Record<StoreNeed, string>> = Object.freeze({
  'runs-scripts': 'Runs scripts on this machine',
  node: 'Needs Node.js',
  python: 'Needs Python',
  'api-key': 'Needs a key you supply',
  account: 'Needs an account somewhere',
  'local-app': 'Needs another app installed',
})

/* -------------------------------------------------------------- the agents -- */

/**
 * The three agents an item can be tested against.
 *
 * A fact the publisher states, not an offer this app makes: naming one here is
 * "I ran it against this", and every screen that offers a *choice* still offers
 * all three. A fourth name is a refusal, because this build has nowhere to
 * install it.
 */
export const MANIFEST_AGENTS = ['claude', 'codex', 'gemini'] as const

export type ManifestAgent = (typeof MANIFEST_AGENTS)[number]

/**
 * The hook events each agent actually has, restated from `hooks.ts`.
 *
 * Restated rather than imported because `hooks.ts` reaches `node:http` through
 * `hook-server.ts` and this module is compiled into the renderer too.
 * `store-manifest.test.ts` imports the real table and asserts these are the same
 * lists, so a new event lands in one place and fails in the other rather than
 * drifting quietly.
 */
export const HOOK_EVENTS: Readonly<Record<ManifestAgent, readonly string[]>> = Object.freeze({
  claude: [
    'SessionStart',
    'UserPromptSubmit',
    'PreToolUse',
    'PostToolUse',
    'PostToolUseFailure',
    'PermissionRequest',
    'Notification',
    'Stop',
    'StopFailure',
    'SessionEnd',
  ],
  codex: ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'],
  gemini: [
    'SessionStart',
    'BeforeAgent',
    'BeforeTool',
    'AfterTool',
    'AfterAgent',
    'Notification',
    'SessionEnd',
  ],
})

/* ----------------------------------------------------------- the platforms -- */

export const MANIFEST_PLATFORMS = ['darwin', 'win32', 'linux'] as const

export type ManifestPlatform = (typeof MANIFEST_PLATFORMS)[number]

/* ------------------------------------------------------------ the runtimes -- */

/**
 * The two runtimes a community MCP item may name, and docker is not one.
 *
 * `RUNTIME_BINARY` in `mcp-catalogue.ts` has three, and the built-in catalogue
 * uses all three. This list has two on purpose: composing a `docker run` line
 * from a manifest means letting a stranger supply mount, network and environment
 * flags, which is the arbitrary-command surface this whole grammar exists to
 * refuse. It is refused *by name*, with that reason in the message, so a
 * publisher is told the answer instead of guessing at it.
 */
export const MCP_RUNTIMES = ['node', 'python'] as const

export type McpRuntime = (typeof MCP_RUNTIMES)[number]

/** Which binary each runtime is on a command line. Restated from `mcp-catalogue.ts`. */
export const RUNTIME_COMMAND: Readonly<Record<McpRuntime, string>> = Object.freeze({
  node: 'npx',
  python: 'uvx',
})

/** A value an MCP item needs before it can work. Mirrors `McpCatalogueInput`. */
export interface ManifestMcpInput {
  /** The environment variable's name, or the placeholder's name in the command. */
  key: string
  label: string
  /** Where to get it, or what it should look like. Shown under the field. */
  hint: string
  kind: 'secret' | 'path' | 'text'
  /** `env` becomes an environment variable; `arg` is substituted into the command. */
  into: 'env' | 'arg'
  required: boolean
}

/* ------------------------------------------------------------- the shelves -- */

/**
 * The one category vocabulary, shared by all seven kinds.
 *
 * The plan called for a shelf list per kind. This is the same thirteen ids
 * `MCP_CATEGORIES` already draws, used by every kind instead, and the reason is
 * that the department already sorts by kind: a person browsing Community sees
 * the kind first and asks *what is it about* second, and two vocabularies for
 * that second question would mean the same item filed under `code` in one shelf
 * and `dev` in another. One list also means a community MCP row and a built-in
 * MCP row answer the same filter chip, which is the drift `storefront.ts` was
 * written to stop.
 */
export const STORE_CATEGORIES = [
  'files',
  'code',
  'work',
  'data',
  'cloud',
  'web',
  'browser',
  'knowledge',
  'design',
  'business',
  'thinking',
  'messaging',
  'utility',
] as const

export type StoreCategory = (typeof STORE_CATEGORIES)[number]

/* ------------------------------------------------------------- the licences -- */

/**
 * The licences a listing may name, spelled the way SPDX spells them.
 *
 * A closed list, and a licence we cannot name is a refusal rather than an
 * "Other". The store tells a person what they may do with somebody else's work;
 * a free-text field there is a promise made out of a string nobody checked.
 */
export const STORE_LICENCES = [
  '0BSD',
  'AGPL-3.0-only',
  'AGPL-3.0-or-later',
  'Apache-2.0',
  'Artistic-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'BSL-1.0',
  'CC0-1.0',
  'CC-BY-4.0',
  'CC-BY-SA-4.0',
  'EPL-2.0',
  'GPL-2.0-only',
  'GPL-3.0-only',
  'GPL-3.0-or-later',
  'ISC',
  'LGPL-2.1-only',
  'LGPL-3.0-only',
  'MIT',
  'MPL-2.0',
  'Unlicense',
  'Zlib',
] as const

export type StoreLicence = (typeof STORE_LICENCES)[number]

/** Where a repository may live. Three hosts, because each one is a fetch we tested. */
export const REPO_HOSTS = ['github.com', 'gitlab.com', 'codeberg.org'] as const

/* -------------------------------------------------------------- the shapes -- */

export interface SkillInstall {
  kind: 'skill'
  /** The folder inside the artifact holding SKILL.md. `.` is the whole tree. */
  dir: string
}

export interface InstructionsInstall {
  kind: 'instructions'
  /** One markdown file inside the artifact. */
  file: string
}

export interface HooksInstall {
  kind: 'hooks'
  /** A path inside the item's own tree. Never an absolute path, never a `..`. */
  script: string
  /** Each one has to exist in every agent this item claims. */
  events: readonly string[]
  /** `node` only in this version. The app spawns it; the manifest never says how. */
  runtime: 'node'
}

export interface McpInstall {
  kind: 'mcp'
  runtime: McpRuntime
  /** The package name a registry resolves. Never a URL, never a path. */
  package: string
  /** Literals and `${input:KEY}` placeholders. Nothing else parses. */
  args: readonly string[]
  inputs: readonly ManifestMcpInput[]
  /** The substring that identifies this server in a command line somebody else wrote. */
  token: string
}

export interface ExtensionInstall {
  kind: 'extension'
  dir: string
  /** The hosts the extension asks for, as the row declares them. */
  reach: readonly string[]
}

export interface RoutineInstall {
  kind: 'routine'
  /** A markdown routine, in `routines/format.ts`'s shape, and never enabled. */
  file: string
}

export type InstallBlock =
  | SkillInstall
  | InstructionsInstall
  | HooksInstall
  | McpInstall
  | ExtensionInstall
  | RoutineInstall

export interface ManifestPricing {
  model: StoreCost
  /** The price reality in one sentence. Required for anything that is not free. */
  note: string | null
  /** Where to get it. Required for an off-site listing, refused otherwise. */
  url: string | null
}

export interface ManifestLinks {
  repo: string
  home: string | null
  docs: string | null
}

export interface Manifest {
  terminaldeck: 1
  publisher: string
  id: string
  kind: StoreKind
  name: string
  summary: string
  version: string
  licence: StoreLicence
  category: StoreCategory
  tags: readonly string[]
  agents: readonly ManifestAgent[]
  platforms: readonly ManifestPlatform[]
  delivery: StoreDelivery
  pricing: ManifestPricing
  /** One environment variable name this item reads, or null. */
  licenceEnv: string | null
  /**
   * A plain-text or markdown file in the item's own tree, written for AI readers.
   *
   * The publisher's own words about their own product, served by the store at
   * `/@publisher/id/llms.txt` so an assistant reading the listing page is handed
   * the description its author wrote rather than one scraped off the markup.
   * Null when they supplied none, or typed one into the publish form instead.
   */
  aiFile: string | null
  links: ManifestLinks
  needs: readonly StoreNeed[]
  /** Absent for `tool`, and for anything delivered off-site. */
  install: InstallBlock | null
}

export type ManifestParse = { ok: true; manifest: Manifest } | { ok: false; why: string }

/* ----------------------------------------------------------- the validator -- */

const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/
const VERSION = /^\d+\.\d+\.\d+$/
const ENV_NAME = /^[A-Z][A-Z0-9_]{0,63}$/
/**
 * A tag: lower-case letters, digits and hyphens.
 *
 * Exported because `store-index.ts` holds a catalogue row to the same rule. A
 * second copy of this expression is a second rule the day one of them changes.
 */
export const TAG = /^[a-z0-9][a-z0-9-]{0,23}$/
const PACKAGE = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]{0,127}(?:@[A-Za-z0-9._-]{1,64})?$/
const MCP_INPUT_KEY = /^[A-Z][A-Z0-9_]{0,63}$/
const ARG_LITERAL = /^[A-Za-z0-9._:/@=-]{1,120}$/
const ARG_PLACEHOLDER = /^\$\{input:([A-Z][A-Z0-9_]{0,63})\}$/
const HOST_REACH = /^(?:\*\.)?[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/

class Bad extends Error {}

function fail(why: string): never {
  throw new Bad(why)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Every key the publisher sent that this build does not know about, named. */
function onlyKeys(where: string, value: Record<string, unknown>, allowed: readonly string[]): void {
  const known = new Set(allowed)
  for (const key of Object.keys(value)) {
    if (!known.has(key)) fail(`${where} has a key this app does not know about: ${key}`)
  }
}

function text(where: string, value: unknown, max: number): string {
  if (typeof value !== 'string') fail(`${where} must be text`)
  const trimmed = value.trim()
  if (trimmed === '') fail(`${where} must not be empty`)
  if (trimmed.length > max) fail(`${where} must be ${max} characters or fewer`)
  if (/[\r\n]/.test(trimmed)) fail(`${where} must be a single line`)
  return trimmed
}

function optionalText(where: string, value: unknown, max: number): string | null {
  if (value === undefined || value === null) return null
  return text(where, value, max)
}

function oneOf<T extends string>(where: string, value: unknown, allowed: readonly T[]): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) {
    fail(`${where} must be one of: ${allowed.join(', ')}`)
  }
  return value as T
}

function list(where: string, value: unknown, max: number): unknown[] {
  if (!Array.isArray(value)) fail(`${where} must be a list`)
  if (value.length > max) fail(`${where} may hold at most ${max} entries`)
  return value
}

/**
 * A path inside the item's own tree, and nowhere else.
 *
 * The same refusals `browser-extension-unzip.ts` applies to an archive entry,
 * applied here to the manifest that points at one — because a path this parser
 * accepts is a path an installer will later join onto a directory in
 * `<userData>`, and the check that happens first is the one that cannot be
 * forgotten later.
 */
function insidePath(where: string, value: unknown, allowDot: boolean): string {
  const raw = text(where, value, 200)
  if (allowDot && raw === '.') return '.'
  if (raw.startsWith('/')) fail(`${where} must be a path inside the item, so it cannot start with /`)
  if (/^[A-Za-z]:/.test(raw)) fail(`${where} must be a path inside the item, so it cannot name a drive`)
  if (raw.includes('\\')) fail(`${where} must use / between folders`)
  if (raw.includes('\0')) fail(`${where} contains a character a file name cannot have`)
  if (raw.split('/').some((part) => part === '..')) fail(`${where} must not step outside the item with ..`)
  if (raw.split('/').some((part) => part === '')) fail(`${where} has an empty folder name in it`)
  return raw
}

function httpsUrl(where: string, value: unknown, hosts: readonly string[] | null): string {
  const raw = text(where, value, 300)
  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    fail(`${where} is not a web address`)
  }
  if (parsed.protocol !== 'https:') fail(`${where} must be an https address`)
  const host = parsed.hostname.toLowerCase()
  /*
   * A bare address instead of a name.
   *
   * Not a security check — the digest is what makes bytes safe — but a listing
   * check. Nobody can read `https://203.0.113.7/buy` and tell whose page it is,
   * and the one thing an off-site row has to be is legible before it is pressed.
   */
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host) || host.startsWith('[')) {
    fail(`${where} must name a domain, not a bare address`)
  }
  if (hosts !== null && !hosts.includes(host)) fail(`${where} must be on one of: ${hosts.join(', ')}`)
  return raw
}

function mcpInput(where: string, raw: unknown): ManifestMcpInput {
  if (!isRecord(raw)) fail(`${where} must be an object`)
  onlyKeys(where, raw, ['key', 'label', 'hint', 'kind', 'into', 'required'])
  const key = text(`${where}.key`, raw.key, 64)
  if (!MCP_INPUT_KEY.test(key)) {
    fail(`${where}.key must be capitals, digits and underscores, starting with a letter`)
  }
  if (typeof raw.required !== 'boolean') fail(`${where}.required must be true or false`)
  return {
    key,
    label: text(`${where}.label`, raw.label, 60),
    hint: text(`${where}.hint`, raw.hint, 200),
    kind: oneOf(`${where}.kind`, raw.kind, ['secret', 'path', 'text'] as const),
    into: oneOf(`${where}.into`, raw.into, ['env', 'arg'] as const),
    required: raw.required,
  }
}

/**
 * The command line for an MCP item, built here rather than read from anywhere.
 *
 * This is the whole of *the catalogue may travel, the authority may not*. The
 * manifest names a runtime and a package; the words `npx`, `-y` and `uvx` come
 * out of this repository's bytes. The placeholders are spelled `${KEY}` on the
 * way out because that is what `mcp-catalogue.ts` rows already use and what
 * `mcp-store.ts` substitutes — one spelling in the manifest, the house spelling
 * everywhere the command is actually run.
 */
export function composeMcpCommand(install: McpInstall): string {
  const head = install.runtime === 'node' ? `${RUNTIME_COMMAND.node} -y` : RUNTIME_COMMAND.python
  const args = install.args.map((arg) => {
    const placeholder = ARG_PLACEHOLDER.exec(arg)
    return placeholder === null ? arg : `\${${placeholder[1]}}`
  })
  return [head, install.package, ...args].join(' ').trim()
}

function skillInstall(raw: Record<string, unknown>): SkillInstall {
  onlyKeys('install', raw, ['dir'])
  return { kind: 'skill', dir: insidePath('install.dir', raw.dir, true) }
}

function instructionsInstall(raw: Record<string, unknown>): InstructionsInstall {
  onlyKeys('install', raw, ['file'])
  const file = insidePath('install.file', raw.file, false)
  if (!file.toLowerCase().endsWith('.md')) fail('install.file must be a .md file')
  return { kind: 'instructions', file }
}

function hooksInstall(raw: Record<string, unknown>, agents: readonly ManifestAgent[]): HooksInstall {
  onlyKeys('install', raw, ['script', 'events', 'runtime'])
  const script = insidePath('install.script', raw.script, false)
  const runtime = oneOf('install.runtime', raw.runtime, ['node'] as const)
  const entries = list('install.events', raw.events, 20)
  if (entries.length === 0) fail('install.events must name at least one moment to run at')
  const events: string[] = []
  for (const [index, entry] of entries.entries()) {
    const event = text(`install.events[${index}]`, entry, 40)
    for (const agent of agents) {
      if (!HOOK_EVENTS[agent].includes(event)) {
        fail(`${agent} has no hook called ${event}, and this item says it works with ${agent}`)
      }
    }
    if (!events.includes(event)) events.push(event)
  }
  return { kind: 'hooks', script, events, runtime }
}

function mcpInstall(raw: Record<string, unknown>): McpInstall {
  onlyKeys('install', raw, ['runtime', 'package', 'args', 'inputs', 'token'])
  if (raw.runtime === 'docker') {
    fail(
      'this item asks to be run with docker, which the community store does not compose. ' +
        'A docker line carries its own mounts, network and environment, and this app builds ' +
        'every command itself. It may use: ' +
        MCP_RUNTIMES.join(', '),
    )
  }
  const runtime = oneOf('install.runtime', raw.runtime, MCP_RUNTIMES)
  const pkg = text('install.package', raw.package, 140)
  if (!PACKAGE.test(pkg)) fail('install.package must be a package name, not a path or an address')

  const inputs = list('install.inputs', raw.inputs, 12).map((entry, index) =>
    mcpInput(`install.inputs[${index}]`, entry),
  )
  const keys = new Set<string>()
  for (const input of inputs) {
    if (keys.has(input.key)) fail(`install.inputs names ${input.key} twice`)
    keys.add(input.key)
  }

  const args: string[] = []
  for (const [index, entry] of list('install.args', raw.args, 20).entries()) {
    const arg = text(`install.args[${index}]`, entry, 120)
    const placeholder = ARG_PLACEHOLDER.exec(arg)
    if (placeholder !== null) {
      const named = inputs.find((input) => input.key === placeholder[1])
      if (named === undefined) fail(`install.args[${index}] uses \${input:${placeholder[1]}}, which is not declared`)
      if (named.into !== 'arg') fail(`${named.key} is filled in as an environment variable, so it cannot be an argument`)
    } else if (!ARG_LITERAL.test(arg)) {
      /*
       * The refusal that closes the grammar.
       *
       * Everything a shell would treat as punctuation is out — spaces, quotes,
       * pipes, semicolons, backticks, `$`. An argument is one word this app puts
       * on a command line it built itself, and a word with a space in it is the
       * first half of a second command.
       */
      fail(`install.args[${index}] may only be a plain word or \${input:KEY}`)
    }
    args.push(arg)
  }

  const token = text('install.token', raw.token, 140)
  const install: McpInstall = { kind: 'mcp', runtime, package: pkg, args, inputs, token }
  if (!composeMcpCommand(install).includes(token)) {
    /*
     * `mcp-catalogue.ts` writes down why this field exists: a server called
     * `github` whose command line does not contain its token is somebody else's
     * server wearing the same name. A token that is not in the command means
     * every row reports itself uninstalled forever.
     */
    fail(`install.token must appear in the command this app builds, and ${token} does not`)
  }
  return install
}

function extensionInstall(raw: Record<string, unknown>): ExtensionInstall {
  onlyKeys('install', raw, ['dir', 'reach'])
  const dir = insidePath('install.dir', raw.dir, true)
  const reach: string[] = []
  for (const [index, entry] of list('install.reach', raw.reach, 40).entries()) {
    const host = text(`install.reach[${index}]`, entry, 120).toLowerCase()
    if (host !== '*' && !HOST_REACH.test(host)) fail(`install.reach[${index}] is not a host or "*"`)
    if (!reach.includes(host)) reach.push(host)
  }
  return { kind: 'extension', dir, reach }
}

function routineInstall(raw: Record<string, unknown>): RoutineInstall {
  onlyKeys('install', raw, ['file'])
  const file = insidePath('install.file', raw.file, false)
  if (!file.toLowerCase().endsWith('.md')) fail('install.file must be a .md file')
  return { kind: 'routine', file }
}

/**
 * One install block, checked on its own.
 *
 * The catalogue carries an install block per row, already checked once by the
 * indexer that built it — and the app checks it again here, against the same
 * code, because a list that arrived over the network is exactly the thing that
 * does not get to be believed twice. Exported so `store-index.ts` reads a row's
 * block through this grammar rather than growing a second, looser one.
 */
export function readInstallBlock(
  kind: StoreKind,
  value: unknown,
  agents: readonly ManifestAgent[],
): { ok: true; install: InstallBlock } | { ok: false; why: string } {
  try {
    if (!isRecord(value)) fail('install must be an object')
    if (kind === 'tool') fail('a tool installs nothing, so it cannot carry an install block')
    if (kind === 'skill') return { ok: true, install: skillInstall(value) }
    if (kind === 'instructions') return { ok: true, install: instructionsInstall(value) }
    if (kind === 'hooks') return { ok: true, install: hooksInstall(value, agents) }
    if (kind === 'mcp') return { ok: true, install: mcpInstall(value) }
    if (kind === 'extension') return { ok: true, install: extensionInstall(value) }
    return { ok: true, install: routineInstall(value) }
  } catch (error) {
    return { ok: false, why: error instanceof Bad ? error.message : 'this install block could not be read' }
  }
}

/**
 * The grammar's own pieces, for the one other file that reads a `terminaldeck.json`.
 *
 * A local plugin (`src/main/plugins/manifest.ts`) is not a store kind — its
 * code *is* what running it means, which is the one thing this grammar exists
 * to refuse — but it is described in the same file, with the same header and
 * the same rules: an id is {@link SAFE_ID}, a version is three numbers, a path
 * stays inside the item, and a key this build does not know is a refusal with
 * the key named. Handed over rather than copied, for the reason
 * {@link readInstallBlock} gives: a second, looser copy of a rule is the copy
 * that drifts. `fail` throws what `isRefusal` recognises.
 */
export const MANIFEST_GRAMMAR = Object.freeze({
  SAFE_ID,
  VERSION,
  isRecord,
  onlyKeys,
  text,
  oneOf,
  list,
  insidePath,
  fail,
  isRefusal: (error: unknown): error is Error => error instanceof Bad,
})

/**
 * Turn the bytes of a manifest into a manifest, or say exactly why not.
 *
 * `expected` is what the *catalogue* holds, and a manifest whose own publisher
 * or id disagrees with it is refused. That is `parseRecipe`'s check, one level
 * up: the row a person read said one thing and the file says another, and the
 * honest answer to a disagreement between them is neither.
 *
 * Never throws. Every refusal is a sentence a person can read on the row.
 */
export function parseManifest(bytes: string, expected: { publisher: string; id: string }): ManifestParse {
  try {
    if (Buffer.byteLength(bytes, 'utf8') > MAX_MANIFEST_BYTES) {
      fail(`a manifest must be ${MAX_MANIFEST_BYTES} bytes or fewer`)
    }
    let raw: unknown
    try {
      raw = JSON.parse(bytes)
    } catch {
      fail('this is not valid JSON')
    }
    if (!isRecord(raw)) fail('a manifest must be a JSON object')

    onlyKeys('the manifest', raw, [
      'terminaldeck',
      'publisher',
      'id',
      'kind',
      'name',
      'summary',
      'version',
      'licence',
      'category',
      'tags',
      'agents',
      'platforms',
      'delivery',
      'pricing',
      'licenceEnv',
      'aiFile',
      'links',
      'needs',
      'install',
    ])

    if (raw.terminaldeck !== MANIFEST_FORMAT) {
      fail(`this manifest is written for format ${String(raw.terminaldeck)}, and this app reads format ${MANIFEST_FORMAT}`)
    }

    const publisher = text('publisher', raw.publisher, 40)
    if (!SAFE_ID.test(publisher)) fail('publisher must be lower-case letters, digits and hyphens')
    if (publisher !== expected.publisher) {
      fail(`this manifest says it belongs to ${publisher}, and it was offered as ${expected.publisher}`)
    }

    const id = text('id', raw.id, 40)
    if (!SAFE_ID.test(id)) fail('id must be lower-case letters, digits and hyphens')
    if (id !== expected.id) fail(`this manifest calls itself ${id}, and it was offered as ${expected.id}`)

    const kind = oneOf('kind', raw.kind, STORE_KINDS)
    const name = text('name', raw.name, 60)
    const summary = text('summary', raw.summary, 120)
    const version = text('version', raw.version, 20)
    if (!VERSION.test(version)) fail('version must look like 1.2.3')
    const licence = oneOf('licence', raw.licence, STORE_LICENCES)
    const category = oneOf('category', raw.category, STORE_CATEGORIES)

    const tags: string[] = []
    for (const [index, entry] of list('tags', raw.tags, 12).entries()) {
      const tag = text(`tags[${index}]`, entry, 24)
      if (!TAG.test(tag)) fail(`tags[${index}] must be lower-case letters, digits and hyphens`)
      if (!tags.includes(tag)) tags.push(tag)
    }

    const agents: ManifestAgent[] = []
    for (const [index, entry] of list('agents', raw.agents, MANIFEST_AGENTS.length).entries()) {
      const agent = oneOf(`agents[${index}]`, entry, MANIFEST_AGENTS)
      if (!agents.includes(agent)) agents.push(agent)
    }
    if (agents.length === 0) fail('agents must name at least one agent this was tested with')

    const platforms: ManifestPlatform[] = []
    for (const [index, entry] of list('platforms', raw.platforms, MANIFEST_PLATFORMS.length).entries()) {
      const platform = oneOf(`platforms[${index}]`, entry, MANIFEST_PLATFORMS)
      if (!platforms.includes(platform)) platforms.push(platform)
    }
    if (platforms.length === 0) fail('platforms must name at least one system this runs on')

    const delivery = oneOf('delivery', raw.delivery, STORE_DELIVERIES)

    if (!isRecord(raw.pricing)) fail('pricing must be an object')
    onlyKeys('pricing', raw.pricing, ['model', 'note', 'url'])
    const model = oneOf('pricing.model', raw.pricing.model, STORE_COSTS)
    const note = optionalText('pricing.note', raw.pricing.note, 160)
    if (model !== 'free' && note === null) {
      /*
       * The rule Asad set, and it is not relaxed for strangers: never imply free
       * when a key costs money. Both existing catalogue tests already fail a row
       * that skips this on our own rows.
       */
      fail('pricing.note is required for anything that is not free, in one sentence, before the button')
    }
    const url = raw.pricing.url === undefined || raw.pricing.url === null ? null : httpsUrl('pricing.url', raw.pricing.url, null)

    const licenceEnv = optionalText('licenceEnv', raw.licenceEnv, 64)
    if (licenceEnv !== null && !ENV_NAME.test(licenceEnv)) {
      fail('licenceEnv must be an environment variable name, in capitals')
    }

    const aiFile =
      raw.aiFile === undefined || raw.aiFile === null ? null : insidePath('aiFile', raw.aiFile, false)
    if (aiFile !== null && !(aiFile.toLowerCase().endsWith('.txt') || aiFile.toLowerCase().endsWith('.md'))) {
      fail('aiFile must be a .txt or a .md file')
    }

    if (!isRecord(raw.links)) fail('links must be an object')
    onlyKeys('links', raw.links, ['repo', 'home', 'docs'])
    const links: ManifestLinks = {
      repo: httpsUrl('links.repo', raw.links.repo, REPO_HOSTS),
      home: raw.links.home === undefined || raw.links.home === null ? null : httpsUrl('links.home', raw.links.home, null),
      docs: raw.links.docs === undefined || raw.links.docs === null ? null : httpsUrl('links.docs', raw.links.docs, null),
    }

    const needs: StoreNeed[] = []
    for (const [index, entry] of list('needs', raw.needs, STORE_NEEDS.length).entries()) {
      const need = oneOf(`needs[${index}]`, entry, STORE_NEEDS)
      if (!needs.includes(need)) needs.push(need)
    }

    const hasInstall = raw.install !== undefined && raw.install !== null
    if (delivery === 'off-site') {
      if (hasInstall) fail('an off-site listing installs nothing here, so it cannot carry an install block')
      if (url === null) fail('an off-site listing must say where to get it, in pricing.url')
    }
    if (kind === 'tool') {
      if (hasInstall) fail('a tool is a program you install yourself, so it cannot carry an install block')
    } else if (delivery === 'repo' && !hasInstall) {
      fail(`a ${kind} must say what to install, in an install block`)
    }

    let install: InstallBlock | null = null
    if (hasInstall) {
      if (!isRecord(raw.install)) fail('install must be an object')
      const block = raw.install
      if (kind === 'skill') install = skillInstall(block)
      else if (kind === 'instructions') install = instructionsInstall(block)
      else if (kind === 'hooks') install = hooksInstall(block, agents)
      else if (kind === 'mcp') install = mcpInstall(block)
      else if (kind === 'extension') install = extensionInstall(block)
      else if (kind === 'routine') install = routineInstall(block)
    }

    return {
      ok: true,
      manifest: {
        terminaldeck: MANIFEST_FORMAT,
        publisher,
        id,
        kind,
        name,
        summary,
        version,
        licence,
        category,
        tags,
        agents,
        platforms,
        delivery,
        pricing: { model, note, url },
        licenceEnv,
        aiFile,
        links,
        needs,
        install,
      },
    }
  } catch (error) {
    return { ok: false, why: error instanceof Bad ? error.message : 'this manifest could not be read' }
  }
}
