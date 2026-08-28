import { createHash } from 'node:crypto'
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { BRAND } from '../shared/brand'
import {
  composeMcpCommand,
  deriveTier,
  MANIFEST_AGENTS,
  parseManifest,
  STORE_MANIFEST_FILE,
  type InstallBlock,
  type Manifest,
  type ManifestAgent,
  type McpInstall,
  type StoreCategory,
  type StoreKind,
  type StoreLicence,
  type StoreTier,
  type TierFile,
} from '../shared/store-manifest'
import type { StoreKey } from '../shared/store-key'
import { writeFileAtomic } from './atomic-write'
import { resolveAgentBinary } from './agent-binaries'
import { addMcpServer, removeMcpServer, tokenizeCommand } from './mcp-add'
import { buildInstall } from './mcp-store'
import { currentPlatform, withPath } from './platform/host'
import { loginPath, PROVIDERS } from './providers'
import { parseRoutine, serializeRoutine, splitDocument } from './routines/format'
import { routineFilePath, routinesDirFor } from './routines/store'
import {
  artifactMatches,
  DIGEST_REFUSAL,
  loadStoreIndex,
  revocationFor,
  storeCacheDir,
  type StoreIndex,
  type StoreRow,
} from './store-index'
import {
  fileAt,
  filesUnder,
  LARGE_ITEM_LIMITS,
  readArchive,
  SMALL_ITEM_LIMITS,
  stripSingleRoot,
  type ArchiveFile,
  type ArchiveLimits,
} from './store-archive'

/**
 * Installing somebody else's work onto this machine, and taking it off again.
 *
 * ## The one rule the whole file is built around
 *
 * **Nothing in the catalogue ever supplies a command.** `store-manifest.ts`
 * closes that door in the grammar — there is no field a command line could be
 * written into — and this file is the other half of the same argument: every
 * command that runs here is composed by code in this repository out of a
 * runtime and a package name, and every path written to is built from this
 * app's own constants plus an identifier the grammar has already constrained to
 * lowercase letters, digits and hyphens.
 *
 * ## Four checks before a byte is written, in this order
 *
 *  1. **The length**, against what the catalogue said. Cheap, and it is
 *     *in addition to* the digest rather than instead of it — the same order
 *     `fetch-update.ts` uses.
 *  2. **The digest**, over the archive exactly as it was served, through
 *     `artifactMatches`, which is `timingSafeEqual` underneath.
 *  3. **The manifest**, parsed out of the archive by the same closed grammar
 *     that read the catalogue row, and refused when it disagrees with the row —
 *     the kind, the version, or the install block. The rule is the one
 *     `widerThanRow` states in the extension store: *the row is the disclosure,
 *     the thing that runs is the thing that runs, and when they disagree the
 *     honest answer is neither.*
 *  4. **The tier, recomputed from the bytes that actually arrived.** Higher than
 *     the row claimed is a refusal naming both answers. Lower is not: the row
 *     over-stated, the person agreed to more than they got, nobody is worse off.
 *
 * ## The ledger, which is what makes Remove honest
 *
 * Every install writes one record naming every absolute path it created outside
 * the item's own folder, and every MCP server name it asked an agent to add.
 * Remove reverses exactly that list, in reverse order, and never globs — a store
 * that removes `<skills>/<something>*` is a store that will one day delete a
 * folder a person made by hand. Anything that could not be reversed stays in the
 * record and is named in the message, so pressing Remove again retries only what
 * is left.
 *
 * ## What is here and what is not
 *
 * Four kinds install in this version: `skill`, `instructions`, `mcp` and
 * `routine`. `hooks` and `extension` are refused by name with the reason,
 * because both have an owner in this app already — `hooks.ts` and the extension
 * store — and wiring them is a separate piece of work rather than a line here.
 * `tool` installs nothing by definition: it is a listing with an outbound link.
 *
 * No Electron is imported, in this file or anything it reaches. It takes a
 * `userData` directory and a fetcher, which is the seam the tool store already
 * uses and the reason its tests need no app.
 */

/* ------------------------------------------------------------- the agents -- */

/**
 * Where each agent keeps the configuration this store writes into.
 *
 * **Measured on this machine, not assumed**, and one of the three is not what
 * the variable's name suggests:
 *
 *  - `CLAUDE_CONFIG_DIR` **is** the directory. Unset, it is `~/.claude`.
 *  - `CODEX_HOME` **is** the directory. Unset, it is `~/.codex`.
 *  - `GEMINI_CLI_HOME` is the **parent** of the directory. Running
 *    `GEMINI_CLI_HOME=<dir> gemini skills install …` against a scratch home
 *    wrote to `<dir>/.gemini/skills/…` and said so in its own output. So the
 *    home is joined with `.gemini` whether the variable is set or not, and a
 *    build that treated it like the other two would write every Gemini install
 *    one directory above the place Gemini reads.
 */
export function agentHome(agent: ManifestAgent, env: NodeJS.ProcessEnv, home: string): string {
  if (agent === 'claude') {
    const configured = env.CLAUDE_CONFIG_DIR?.trim()
    return configured !== undefined && configured !== '' ? configured : join(home, '.claude')
  }
  if (agent === 'codex') {
    const configured = env.CODEX_HOME?.trim()
    return configured !== undefined && configured !== '' ? configured : join(home, '.codex')
  }
  const configured = env.GEMINI_CLI_HOME?.trim()
  return join(configured !== undefined && configured !== '' ? configured : home, '.gemini')
}

/** Every agent's configuration directory, in one object the sheet can draw. */
export function agentHomes(env: NodeJS.ProcessEnv, home: string): Record<ManifestAgent, string> {
  return {
    claude: agentHome('claude', env, home),
    codex: agentHome('codex', env, home),
    gemini: agentHome('gemini', env, home),
  }
}

/**
 * The file each agent reads as its standing instructions, inside that home.
 *
 * Three different names for one idea, which is why this is a table and not a
 * constant. An `instructions` item writes its own file beside these and adds one
 * marked line to whichever of them belongs to the agent that was chosen.
 */
const MEMORY_FILE: Readonly<Record<ManifestAgent, string>> = Object.freeze({
  claude: 'CLAUDE.md',
  codex: 'AGENTS.md',
  gemini: 'GEMINI.md',
})

/**
 * Which of them read an `@path` line as an import of another file?
 *
 * Claude Code and the Gemini CLI both do. Codex has no such syntax — its
 * `AGENTS.md` is read as text — so its block names the file in a plain sentence
 * rather than writing a line that would look like an import and do nothing.
 * Wrong quietly is the one outcome worth spending three lines to avoid.
 */
const IMPORTS_FILES: Readonly<Record<ManifestAgent, boolean>> = Object.freeze({
  claude: true,
  codex: false,
  gemini: true,
})

/**
 * Which of them read a `skills/` folder inside their own home?
 *
 * Two do. **Codex has no skills concept at all** — `codex --help` lists exec,
 * review, login, logout, mcp, plugin, mcp-server, app-server, remote-control,
 * app, completion, update, doctor, sandbox, debug, apply, resume, archive,
 * delete, unarchive, fork, cloud, exec-server and features, and nothing else —
 * so a skill installed for it is written to the same place and named in one
 * marked line inside the file it *does* read. That line is the whole difference
 * between a folder on disk and a skill the agent knows about, and pretending
 * otherwise would be house rule four shipped as a lie: all three offered, one of
 * them doing nothing.
 */
const READS_SKILLS_FOLDER: Readonly<Record<ManifestAgent, boolean>> = Object.freeze({
  claude: true,
  codex: false,
  gemini: true,
})

/* -------------------------------------------------------------- the ledger -- */

/** One thing an install did, and the only description Remove ever reads. */
export interface LedgerWrite {
  /**
   * `file` and `dir` are paths this install created. `block` is a marked region
   * inside a file this install did not create. `server` is a name an agent's own
   * command line tool was asked to add, and only that tool can take it away.
   */
  kind: 'file' | 'dir' | 'block' | 'server'
  /** Absolute path, or the server name for `server`. */
  path: string
  agent?: ManifestAgent
}

/** What is on this machine, and enough about it to undo it exactly. */
export interface InstalledRecord {
  /** `<publisher>/<id>`, the same key the catalogue joins on. */
  id: string
  publisher: string
  item: string
  kind: StoreKind
  name: string
  summary: string
  version: string
  licence: StoreLicence
  category: StoreCategory
  /** The repository this came out of, so a row can still name it once delisted. */
  repo: string
  /** The commit the artifact was pinned to, kept so the row can show the pin. */
  commit: string
  /** The digest of the archive this came out of, checked again at install time. */
  sha256: string
  tier: StoreTier
  agents: ManifestAgent[]
  installedAt: string
  /** This app's own copy of the item, under `userData`. */
  root: string
  /** A fingerprint over the unpacked tree, re-checked every time the list loads. */
  tree: string
  writes: LedgerWrite[]
}

interface Ledger {
  v: 1
  items: InstalledRecord[]
}

/** Where this app keeps its own copy of every installed item. */
export function itemsDir(userData: string): string {
  return join(storeCacheDir(userData), 'items')
}

/** The one file that says what is installed. Beside the kept catalogue. */
export function ledgerPath(userData: string): string {
  return join(storeCacheDir(userData), 'installed.json')
}

/** Where a copy of any file this store edited is kept, before the first edit. */
export function backupsDir(userData: string): string {
  return join(storeCacheDir(userData), 'backups')
}

/** `<publisher>.<id>` — the folder name and the marker name, minted once. */
export function itemFolderName(publisher: string, item: string): string {
  return `${publisher}.${item}`
}

/**
 * Read the ledger, treating anything unreadable as an empty one.
 *
 * A ledger that cannot be parsed is a ledger that cannot be trusted to describe
 * somebody's disk, and acting on a half-understood one is how a Remove deletes
 * the wrong thing. Empty means the rows draw as available and an install writes
 * a fresh record; nothing is deleted on the strength of a guess.
 */
export function readLedger(userData: string): InstalledRecord[] {
  try {
    const raw: unknown = JSON.parse(readFileSync(ledgerPath(userData), 'utf8'))
    if (typeof raw !== 'object' || raw === null) return []
    const items = (raw as { items?: unknown }).items
    if (!Array.isArray(items)) return []
    return items.filter((entry): entry is InstalledRecord => {
      if (typeof entry !== 'object' || entry === null) return false
      const record = entry as Partial<InstalledRecord>
      return typeof record.id === 'string' && typeof record.root === 'string' && Array.isArray(record.writes)
    })
  } catch {
    return []
  }
}

function writeLedger(userData: string, items: readonly InstalledRecord[]): void {
  mkdirSync(storeCacheDir(userData), { recursive: true })
  const ledger: Ledger = { v: 1, items: [...items] }
  writeFileAtomic(ledgerPath(userData), `${JSON.stringify(ledger, null, 2)}\n`)
}

/**
 * A fingerprint over an unpacked tree — the paths as well as the bytes.
 *
 * Over the paths too, because a tree with one file renamed is a different tree
 * and a digest over the contents alone would call it the same one. Recomputed
 * from disk every time the list is drawn, for the reason the tool store already
 * gives about its own downloads: `<userData>` is writable by everything running
 * as this person, so a copy that is believed because we wrote it is a copy
 * anything on this machine can edit.
 */
export function treeDigest(files: readonly { path: string; bytes: Buffer }[]): string {
  const hash = createHash('sha256')
  for (const file of [...files].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))) {
    hash.update(file.path)
    hash.update('\0')
    hash.update(createHash('sha256').update(file.bytes).digest())
    hash.update('\n')
  }
  return hash.digest('hex')
}

/** Every file under a folder, as relative `/`-separated paths with their bytes. */
function readTree(root: string, prefix = ''): { path: string; bytes: Buffer }[] {
  const out: { path: string; bytes: Buffer }[] = []
  let entries: string[]
  try {
    entries = readdirSync(root)
  } catch {
    return out
  }
  for (const name of entries.sort()) {
    const full = join(root, name)
    const at = prefix === '' ? name : `${prefix}/${name}`
    let stats
    try {
      stats = statSync(full)
    } catch {
      continue
    }
    if (stats.isDirectory()) out.push(...readTree(full, at))
    else if (stats.isFile()) out.push({ path: at, bytes: readFileSync(full) })
  }
  return out
}

/* ------------------------------------------------------------- the fetcher -- */

export interface FetchedArtifact {
  ok: boolean
  bytes: Buffer
  message: string
}

export type FetchArtifact = (url: string, limit: number) => Promise<FetchedArtifact>

/** Long enough for a slow line, short enough that a hung store is not a hung app. */
export const ARTIFACT_TIMEOUT_MS = 60_000

/**
 * Fetch one artifact, over https, up to a ceiling on what arrives.
 *
 * Redirects are followed here, where `httpsFetchIndex` refuses them, and the
 * difference is deliberate: a repository host's archive URL is *defined* to
 * redirect to object storage, so refusing would mean no item could ever be
 * installed — the argument `browser-extensions.ts` already makes about release
 * assets. What makes following safe is that the bytes are worthless unless they
 * match a digest that arrived inside a signed catalogue, and the digest is
 * checked before anything is opened.
 *
 * Plain http reaches here only for loopback, which is what the local proof run
 * uses. Every other address must be https, and it is `resolveStoreApi` that
 * decides the base in the first place.
 */
export const httpsFetchArtifact: FetchArtifact = async (url, limit) => {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, bytes: Buffer.alloc(0), message: 'that is not a URL' }
  }
  const loopback = ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(parsed.hostname.toLowerCase())
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && loopback)) {
    return { ok: false, bytes: Buffer.alloc(0), message: 'this item can only be downloaded over https' }
  }
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(ARTIFACT_TIMEOUT_MS) })
    if (!response.ok) {
      return { ok: false, bytes: Buffer.alloc(0), message: `the download answered ${response.status}` }
    }
    const bytes = Buffer.from(await response.arrayBuffer())
    if (bytes.byteLength > limit) {
      return { ok: false, bytes: Buffer.alloc(0), message: 'the download is larger than this app will read' }
    }
    return { ok: true, bytes, message: '' }
  } catch (error) {
    return {
      ok: false,
      bytes: Buffer.alloc(0),
      message: error instanceof Error ? `the download failed: ${error.message}` : 'the download failed',
    }
  }
}

/* --------------------------------------------------------- running an agent -- */

export interface AgentRun {
  ok: boolean
  message: string
}

/** One invocation of an agent's own command line tool, with its argv already built. */
export type RunAgent = (agent: ManifestAgent, argv: readonly string[]) => Promise<AgentRun>

const AGENT_TIMEOUT_MS = 30_000

/**
 * Run `<agent> <args…>`, through the copy of it this machine can actually start.
 *
 * `resolveAgentBinary` rather than the bare name, because the npm launcher for
 * one of the three is broken on this machine and the catalogue already carries
 * the alternate path for it. Everything else — the login shell's PATH, the
 * Windows command processor, `windowsHide` — is the same set of decisions
 * `mcp-add.ts` documents at length, and this is the second caller rather than a
 * second copy of the reasoning.
 */
export const runAgentCommand: RunAgent = async (agent, argv) => {
  const { execFile } = await import('node:child_process')
  const path = await loginPath()
  const binary = await resolveAgentBinary(agent, { path })
  if (binary.runnable === null) {
    return {
      ok: false,
      message: `${PROVIDERS[agent].label}’s command line tool could not be found, and it is what writes this configuration. Install it, then try again.`,
    }
  }
  const platform = currentPlatform()
  const windows = platform === 'win32'
  const command = windows ? PROVIDERS[agent].spawn.command : binary.runnable
  const head = windows ? ['/c', binary.runnable] : []
  return await new Promise<AgentRun>((resolve) => {
    execFile(
      command,
      [...head, ...argv],
      {
        cwd: homedir(),
        env: withPath(process.env, path, platform),
        timeout: AGENT_TIMEOUT_MS,
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        const said = [String(stdout), String(stderr)]
          .map((part) => part.trim())
          .filter((part) => part !== '')
          .join('\n')
        if (error === null) {
          resolve({ ok: true, message: said })
          return
        }
        resolve({ ok: false, message: said === '' ? error.message : said })
      },
    )
  })
}

/* ---------------------------------------------------------------- the view -- */

export type StoreItemState = 'available' | 'installed' | 'outdated' | 'damaged' | 'withdrawn' | 'unsupported'

export interface StoreItemView {
  row: StoreRow
  state: StoreItemState
  /** One sentence about the state, or null when there is nothing to say. */
  note: string | null
  installed: InstalledRecord | null
}

export interface StoreView {
  /** False when there is no catalogue at all — not even a kept one. */
  ok: boolean
  /** Why there is no catalogue. Null whenever there is one. */
  why: string | null
  items: StoreItemView[]
  /** Where the list came from: fetched now, or the last good copy. */
  from: 'store' | 'kept' | null
  /** When that copy was taken. */
  at: string | null
  /** A sentence about the list's age, or null when it is current. */
  stale: string | null
  /** Why the store could not be reached, when a kept list is being shown. */
  because: string | null
  /** Every agent's configuration directory, so a sheet can name real folders. */
  homes: Record<ManifestAgent, string>
  /** Where this app keeps its own copies. Shown, never guessed at. */
  folder: string
}

export interface InstallChoice {
  /** Which agents to install into. Must be agents the item claims and this app knows. */
  agents?: readonly string[]
  /** Values for an `mcp` item's declared inputs, keyed by their `key`. */
  values?: Record<string, string>
  /** The folder a `routine` will run in. A routine cannot ship one. */
  folder?: string
}

export interface StoreResult {
  ok: boolean
  message: string
}

export interface StoreInstallDeps {
  /** `app.getPath('userData')`, read per call the way every other store reads it. */
  userData(): string
  /** The catalogue base. Resolved in the process that has an environment. */
  base(): string
  env?: NodeJS.ProcessEnv
  home?: () => string
  now?: () => Date
  fetchArtifact?: FetchArtifact
  runAgent?: RunAgent
  /** The MCP writers for Claude Code, which already exist and are already tested. */
  claudeMcp?: {
    add: typeof addMcpServer
    remove: typeof removeMcpServer
  }
  /** Names the login shell already exports, so a key need not be written down twice. */
  environmentNames?: () => Promise<ReadonlySet<string>>
  loadIndex?: typeof loadStoreIndex
  keys?: readonly StoreKey[]
}

export interface StoreInstaller {
  view(): Promise<StoreView>
  install(id: string, choice?: InstallChoice): Promise<StoreResult>
  remove(id: string): Promise<StoreResult>
  installed(): InstalledRecord[]
}

/* ---------------------------------------------------------- the small parts -- */

/** The kinds this version installs. The other three say so rather than failing. */
const INSTALLABLE: readonly StoreKind[] = ['skill', 'instructions', 'mcp', 'routine']

/** Why a kind this build does not install is not being installed. */
const NOT_YET: Readonly<Partial<Record<StoreKind, string>>> = Object.freeze({
  hooks: 'Hook sets are not installed from the store in this version. The Hooks screen writes them.',
  extension:
    'Browser extensions are not installed from this shelf in this version. The browser’s own extension store installs them.',
  tool: 'This is a listing, not a download. Open it with the link on the row.',
})

/** The marker that owns a block, minted from the brand rather than spelled out. */
export function blockMarkers(name: string): { start: string; end: string } {
  return { start: `<!-- ${BRAND.id}-store ${name} -->`, end: `<!-- /${BRAND.id}-store ${name} -->` }
}

/**
 * Put a block into a file, replacing our own previous one and nothing else.
 *
 * The discipline is the one `hooks.ts` established for the same problem: a
 * marker minted from the brand, a first-touch backup of a file this app did not
 * create, an atomic write, and never a byte touched outside the two markers. A
 * store that appends to somebody's standing instructions and cannot find its own
 * addition again is a store that leaves litter no one can identify.
 */
export function writeBlock(file: string, name: string, body: string, backups: string | null): void {
  const { start, end } = blockMarkers(name)
  const existed = existsSync(file)
  const current = existed ? readFileSync(file, 'utf8') : ''
  if (existed && backups !== null) backupOnce(file, backups)

  const stripped = stripBlock(current, name)
  const spacer = stripped === '' || stripped.endsWith('\n\n') ? '' : stripped.endsWith('\n') ? '\n' : '\n\n'
  mkdirSync(dirname(file), { recursive: true })
  writeFileAtomic(file, `${stripped}${spacer}${start}\n${body}\n${end}\n`)
}

/** The file without our block. Returns the text unchanged when there is none. */
export function stripBlock(text: string, name: string): string {
  const { start, end } = blockMarkers(name)
  const from = text.indexOf(start)
  if (from === -1) return text
  const to = text.indexOf(end, from)
  if (to === -1) return text
  const after = to + end.length
  const head = text.slice(0, from).replace(/\n+$/, '\n')
  const tail = text.slice(after).replace(/^\n+/, '')
  return `${head}${tail}`.replace(/^\n+/, '')
}

/** Take our block back out of a file. True when there was one to take out. */
export function removeBlock(file: string, name: string): boolean {
  if (!existsSync(file)) return false
  const current = readFileSync(file, 'utf8')
  const stripped = stripBlock(current, name)
  if (stripped === current) return false
  writeFileAtomic(file, stripped)
  return true
}

/** One copy of a file we are about to edit, kept the first time we edit it. */
function backupOnce(file: string, backups: string): void {
  const name = file.replace(/[^A-Za-z0-9._-]+/g, '_')
  const kept = join(backups, name)
  if (existsSync(kept)) return
  try {
    mkdirSync(backups, { recursive: true })
    copyFileSync(file, kept)
  } catch {
    /* A backup we cannot take is not a reason to refuse; the block is reversible either way. */
  }
}

/**
 * Delete a folder and the folders inside it, but only where nothing is left.
 *
 * Depth first, so a tree whose files have all been deleted goes entirely, and a
 * tree holding one file a person added keeps that file, its folder, and every
 * folder above it. Never `rm -r`.
 */
function pruneEmpty(dir: string): void {
  if (!existsSync(dir)) return
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return
  }
  for (const name of entries) {
    const full = join(dir, name)
    try {
      if (statSync(full).isDirectory()) pruneEmpty(full)
    } catch {
      /* Something else is moving underneath us; leaving it alone is the safe answer. */
    }
  }
  try {
    // `rmdirSync`, not `rmSync`: without `recursive` the general one refuses a
    // directory outright, so the empty folder would silently survive every
    // Remove — which is exactly how this was first written and what the test
    // above caught.
    if (readdirSync(dir).length === 0) rmdirSync(dir)
  } catch {
    /* Not empty, or not ours to remove. Either way it stays. */
  }
}

/** Sorted-key JSON, so two objects built by the same grammar compare by value. */
function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  if (typeof value === 'object' && value !== null) {
    const record = value as Record<string, unknown>
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stable(record[key])}`)
      .join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

/** Does the install block in the archive say the same thing as the one on the row? */
export function sameInstall(a: InstallBlock | null, b: InstallBlock | null): boolean {
  return stable(a) === stable(b)
}

/** What the archive says, reduced to what the tier rule reads. */
function tierFiles(files: readonly ArchiveFile[]): TierFile[] {
  return files.map((file) => ({ path: file.path, bytes: file.bytes.byteLength, mode: file.mode }))
}

/** The ceilings for this kind. Two rows, and the reason is in `store-archive.ts`. */
function limitsFor(kind: StoreKind): ArchiveLimits {
  return kind === 'extension' ? LARGE_ITEM_LIMITS : SMALL_ITEM_LIMITS
}

/**
 * Write a tree of files under a folder, and say exactly what was written.
 *
 * The bytes go down as bytes rather than through the atomic text writer, and
 * that is not a shortcut: a skill may ship a picture beside its markdown, and
 * `writeFileAtomic` takes a string, so a round trip through UTF-8 would replace
 * every byte it could not read with a replacement character. Nothing else is
 * reading this folder while it is being written — it is created by this call,
 * under a name derived from the item — so there is no half-written file for
 * anything to see.
 */
function writeTree(root: string, files: readonly ArchiveFile[]): LedgerWrite[] {
  const writes: LedgerWrite[] = [{ kind: 'dir', path: root }]
  mkdirSync(root, { recursive: true })
  for (const file of files) {
    const target = join(root, ...file.path.split('/'))
    mkdirSync(dirname(target), { recursive: true })
    writeFileSync(target, file.bytes)
    writes.push({ kind: 'file', path: target })
  }
  return writes
}

/**
 * The folders and files an install would write, worked out before it is pressed.
 *
 * Exported because the sheet in front of the Install button has to say *exactly*
 * which folders will be written into, and a sheet that describes it in general
 * terms is a sheet nobody can check. This is the same table the installers use,
 * so the sheet cannot drift from what happens.
 */
export function plannedTargets(
  row: { kind: StoreKind; publisher: string; id: string },
  agents: readonly ManifestAgent[],
  homes: Record<ManifestAgent, string>,
  userData: string,
): string[] {
  const item = row.id.split('/')[1] ?? row.id
  const folder = itemFolderName(row.publisher, item)
  const out: string[] = [join(itemsDir(userData), folder)]

  if (row.kind === 'routine') {
    out.push(join(routinesDirFor(userData), `${row.publisher}-${item}.md`))
    return out
  }
  if (row.kind === 'mcp') {
    for (const agent of agents) {
      out.push(`${PROVIDERS[agent].label}: an MCP server called ${mcpNameFor(row)}`)
    }
    return out
  }
  for (const agent of agents) {
    if (row.kind === 'skill') {
      out.push(join(homes[agent], 'skills', folder))
      if (!READS_SKILLS_FOLDER[agent]) out.push(join(homes[agent], MEMORY_FILE[agent]))
    }
    if (row.kind === 'instructions') {
      out.push(join(homes[agent], 'instructions', `${folder}.md`))
      out.push(join(homes[agent], MEMORY_FILE[agent]))
    }
  }
  return out
}

/** The name an MCP server is written under. Built here, never taken from the row. */
export function mcpNameFor(row: { publisher: string; id: string }): string {
  return `${row.publisher}-${row.id.split('/')[1] ?? row.id}`
}

/* ------------------------------------------------------------- the installer -- */

export function createStoreInstaller(deps: StoreInstallDeps): StoreInstaller {
  const env = deps.env ?? process.env
  const home = deps.home ?? homedir
  const now = deps.now ?? ((): Date => new Date())
  const fetchArtifact = deps.fetchArtifact ?? httpsFetchArtifact
  const runAgent = deps.runAgent ?? runAgentCommand
  const claudeMcp = deps.claudeMcp ?? { add: addMcpServer, remove: removeMcpServer }
  const loadIndex = deps.loadIndex ?? loadStoreIndex
  const environmentNames = deps.environmentNames ?? (async (): Promise<ReadonlySet<string>> => new Set<string>())

  const homes = (): Record<ManifestAgent, string> => agentHomes(env, home())

  async function readIndex(): Promise<
    | { ok: true; index: StoreIndex; from: 'store' | 'kept'; at: string; stale: string | null; because: string | null }
    | { ok: false; why: string }
  > {
    return await loadIndex({
      base: deps.base(),
      userData: deps.userData,
      now,
      keys: deps.keys,
    })
  }

  function stateOf(row: StoreRow, record: InstalledRecord | null, index: StoreIndex): StoreItemView {
    const withdrawn = revocationFor(index, row.id, record?.version ?? row.version)
    if (record === null) {
      if (withdrawn !== null) {
        return { row, state: 'withdrawn', note: `Withdrawn: ${withdrawn.reason}`, installed: null }
      }
      if (!INSTALLABLE.includes(row.kind)) {
        return { row, state: 'unsupported', note: NOT_YET[row.kind] ?? null, installed: null }
      }
      if (!runsHere(row)) {
        return { row, state: 'unsupported', note: 'This item does not run on this kind of computer.', installed: null }
      }
      return { row, state: 'available', note: null, installed: null }
    }
    if (treeDigest(readTree(record.root)) !== record.tree) {
      return {
        row,
        state: 'damaged',
        note: 'The copy on this machine no longer matches what was installed. Remove it and install it again.',
        installed: record,
      }
    }
    if (withdrawn !== null) {
      return { row, state: 'withdrawn', note: `Withdrawn after you installed it: ${withdrawn.reason}`, installed: record }
    }
    if (record.version !== row.version) {
      return { row, state: 'outdated', note: `Version ${row.version} is available.`, installed: record }
    }
    return { row, state: 'installed', note: null, installed: record }
  }

  async function view(): Promise<StoreView> {
    const userData = deps.userData()
    const records = readLedger(userData)
    const loaded = await readIndex()
    if (!loaded.ok) {
      return {
        ok: false,
        why: loaded.why,
        items: [],
        from: null,
        at: null,
        stale: null,
        because: null,
        homes: homes(),
        folder: itemsDir(userData),
      }
    }
    const items = loaded.index.items.map((row) =>
      stateOf(row, records.find((record) => record.id === row.id) ?? null, loaded.index),
    )
    /*
     * An installed item the catalogue no longer carries still has to appear.
     * It is on this person's disk; a list that stops mentioning it is a list
     * that has quietly taken away the only Remove button there is.
     */
    for (const record of records) {
      if (items.some((item) => item.row.id === record.id)) continue
      items.push({
        row: rowFromRecord(record),
        state: 'withdrawn',
        note: 'This is no longer listed in the store. It is still installed here.',
        installed: record,
      })
    }
    return {
      ok: true,
      why: null,
      items,
      from: loaded.from,
      at: loaded.at,
      stale: loaded.stale,
      because: loaded.because,
      homes: homes(),
      folder: itemsDir(userData),
    }
  }

  async function install(id: string, choice: InstallChoice = {}): Promise<StoreResult> {
    const userData = deps.userData()
    const records = readLedger(userData)
    if (records.some((record) => record.id === id)) {
      return { ok: false, message: 'This is already installed. Remove it first to install it again.' }
    }

    const loaded = await readIndex()
    if (!loaded.ok) return { ok: false, message: loaded.why }
    const row = loaded.index.items.find((entry) => entry.id === id)
    if (row === undefined) return { ok: false, message: 'This store has no item with that name.' }

    const withdrawn = revocationFor(loaded.index, row.id, row.version)
    if (withdrawn !== null) return { ok: false, message: `This has been withdrawn: ${withdrawn.reason}` }
    if (!INSTALLABLE.includes(row.kind)) {
      return { ok: false, message: NOT_YET[row.kind] ?? 'This app does not install that kind of item.' }
    }
    if (!runsHere(row)) {
      return { ok: false, message: 'This item does not run on this kind of computer.' }
    }
    if (row.delivery !== 'repo' || row.artifact === null || row.install === null) {
      return { ok: false, message: 'This item is a listing rather than a download, so there is nothing to install.' }
    }

    const agents = chosenAgents(row, choice)
    if (!agents.ok) return { ok: false, message: agents.why }

    /* ---- the bytes, and the two checks that come before anything is opened ---- */

    const limits = limitsFor(row.kind)
    const downloaded = await fetchArtifact(row.artifact.url, limits.maxArchiveBytes)
    if (!downloaded.ok) return { ok: false, message: downloaded.message }
    if (downloaded.bytes.byteLength !== row.artifact.bytes) {
      return { ok: false, message: DIGEST_REFUSAL }
    }
    if (!artifactMatches(downloaded.bytes, row.artifact.sha256)) {
      return { ok: false, message: DIGEST_REFUSAL }
    }

    const opened = readArchive(downloaded.bytes, limits)
    if (!opened.ok) return { ok: false, message: opened.why }
    const inRepo = stripSingleRoot(opened.files)
    const files = filesUnder(inRepo, row.source.path)
    if (files.length === 0) {
      return { ok: false, message: `This item's archive has nothing at ${row.source.path}.` }
    }

    /* ---- the manifest, read by the same grammar that read the row ---- */

    const manifestFile = fileAt(files, STORE_MANIFEST_FILE)
    if (manifestFile === null) {
      return { ok: false, message: `This item ships no ${STORE_MANIFEST_FILE}, so there is nothing to check it against.` }
    }
    const item = row.id.split('/')[1] ?? row.id
    const parsed = parseManifest(manifestFile.bytes.toString('utf8'), { publisher: row.publisher, id: item })
    if (!parsed.ok) return { ok: false, message: parsed.why }
    const manifest: Manifest = parsed.manifest

    const disagreement = disagrees(row, manifest)
    if (disagreement !== null) return { ok: false, message: disagreement }

    /* ---- the tier, recomputed from the bytes that actually arrived ---- */

    const derived = deriveTier(row.kind, tierFiles(files))
    if (derived.tier > row.tier) {
      return {
        ok: false,
        message:
          `The store says this reaches less of your machine than it does: the list says ${row.tier}, ` +
          `and what arrived is ${derived.tier}, because ${derived.because}. Nothing was installed.`,
      }
    }

    /* ---- our own copy first, then the install ---- */

    const folder = itemFolderName(row.publisher, item)
    const root = join(itemsDir(userData), folder)
    if (existsSync(root)) rmSync(root, { recursive: true, force: true })
    const writes = writeTree(root, files)

    const result = await installKind({
      row,
      manifest,
      item,
      folder,
      root,
      files,
      agents: agents.agents,
      choice,
      userData,
    })
    if (!result.ok) {
      await undo(result.writes, folder)
      rmSync(root, { recursive: true, force: true })
      return { ok: false, message: result.message }
    }

    const record: InstalledRecord = {
      id: row.id,
      publisher: row.publisher,
      item,
      kind: row.kind,
      name: row.name,
      summary: row.summary,
      version: row.version,
      licence: row.licence,
      category: row.category,
      repo: row.source.repo,
      commit: row.source.commit,
      sha256: row.artifact.sha256,
      tier: derived.tier,
      agents: agents.agents,
      installedAt: now().toISOString(),
      root,
      tree: treeDigest(files.map((file) => ({ path: file.path, bytes: file.bytes }))),
      writes: [...writes, ...result.writes],
    }
    writeLedger(userData, [...records, record])
    return { ok: true, message: result.message }
  }

  async function remove(id: string): Promise<StoreResult> {
    const userData = deps.userData()
    const records = readLedger(userData)
    const record = records.find((entry) => entry.id === id)
    if (record === undefined) return { ok: false, message: 'That is not installed.' }

    const left: LedgerWrite[] = []
    const problems: string[] = []
    for (const write of [...record.writes].reverse()) {
      const undone = await undoOne(write, record)
      if (undone === null) continue
      left.unshift(write)
      problems.push(undone)
    }

    if (left.length > 0) {
      writeLedger(
        userData,
        records.map((entry) => (entry.id === id ? { ...entry, writes: left } : entry)),
      )
      return { ok: false, message: `Some of it could not be removed: ${problems.join(' ')}` }
    }
    writeLedger(
      userData,
      records.filter((entry) => entry.id !== id),
    )
    return { ok: true, message: `Removed ${record.name}.` }
  }

  /* ------------------------------------------------------------ the six steps -- */

  interface KindInput {
    row: StoreRow
    manifest: Manifest
    item: string
    folder: string
    root: string
    files: readonly ArchiveFile[]
    agents: ManifestAgent[]
    choice: InstallChoice
    userData: string
  }

  interface KindResult extends StoreResult {
    writes: LedgerWrite[]
  }

  async function installKind(input: KindInput): Promise<KindResult> {
    const install = input.manifest.install
    if (install === null) return { ok: false, message: 'This item declares nothing to install.', writes: [] }
    if (install.kind === 'skill') return installSkill(input, install.dir)
    if (install.kind === 'instructions') return installInstructions(input, install.file)
    if (install.kind === 'mcp') return await installMcp(input, install)
    if (install.kind === 'routine') return installRoutine(input, install.file)
    return { ok: false, message: NOT_YET[install.kind] ?? 'This app does not install that kind of item.', writes: [] }
  }

  function installSkill(input: KindInput, dir: string): KindResult {
    const writes: LedgerWrite[] = []
    const files = filesUnder(input.files, dir)
    if (fileAt(files, 'SKILL.md') === null) {
      return { ok: false, message: `This skill has no SKILL.md${dir === '.' ? '' : ` in ${dir}`}.`, writes }
    }
    const places = homes()
    for (const agent of input.agents) {
      const target = join(places[agent], 'skills', input.folder)
      if (existsSync(target)) {
        return { ok: false, message: `There is already a folder at ${target}, so nothing was written.`, writes }
      }
      writes.push(...writeTree(target, files))
      if (!READS_SKILLS_FOLDER[agent]) {
        // See READS_SKILLS_FOLDER. The line lives between our own markers, so
        // removing it later takes nothing else in the file with it.
        const memory = join(places[agent], MEMORY_FILE[agent])
        writeBlock(
          memory,
          input.folder,
          `Skill available: ${input.manifest.name} — ${target}/SKILL.md`,
          backupsDir(input.userData),
        )
        writes.push({ kind: 'block', path: memory, agent })
      }
    }
    return { ok: true, message: `Installed ${input.manifest.name}.`, writes }
  }

  function installInstructions(input: KindInput, file: string): KindResult {
    const writes: LedgerWrite[] = []
    const source = fileAt(input.files, file)
    if (source === null) return { ok: false, message: `This item has no ${file} in it.`, writes }
    const text = source.bytes.toString('utf8')
    const places = homes()
    for (const agent of input.agents) {
      const target = join(places[agent], 'instructions', `${input.folder}.md`)
      mkdirSync(dirname(target), { recursive: true })
      writeFileAtomic(target, text)
      writes.push({ kind: 'file', path: target })
      const memory = join(places[agent], MEMORY_FILE[agent])
      const body = IMPORTS_FILES[agent]
        ? `@instructions/${input.folder}.md`
        : `Standing instructions: ${input.manifest.name} — ${target}`
      writeBlock(memory, input.folder, body, backupsDir(input.userData))
      writes.push({ kind: 'block', path: memory, agent })
    }
    return { ok: true, message: `Installed ${input.manifest.name}.`, writes }
  }

  async function installMcp(input: KindInput, install: McpInstall): Promise<KindResult> {
    const writes: LedgerWrite[] = []
    const name = mcpNameFor(input.row)
    let built: { command: string; extras: string[] }
    try {
      /*
       * The command is composed here, out of this repository's own words. The
       * manifest names a runtime and a package; `npx`, `-y` and `uvx` come from
       * `store-manifest.ts`, and the values a person typed are put in by
       * `buildInstall`, which is the same function the built-in catalogue's
       * Install button uses — including its rule that a key already exported by
       * the login shell is inherited rather than written into a file.
       */
      built = buildInstall(
        { name: input.manifest.name, command: composeMcpCommand(install), inputs: install.inputs },
        input.choice.values ?? {},
        await environmentNames(),
      )
    } catch (error) {
      return { ok: false, message: error instanceof Error ? error.message : String(error), writes }
    }

    const argv = tokenizeCommand(built.command)
    for (const agent of input.agents) {
      const added =
        agent === 'claude'
          ? await claudeMcp.add({
              name,
              scope: 'user',
              transport: 'stdio',
              command: built.command,
              url: '',
              extras: built.extras,
              projectPath: null,
            })
          : await runAgent(agent, mcpAddArgs(agent, name, argv, built.extras))
      if (!added.ok) return { ok: false, message: added.message, writes }
      writes.push({ kind: 'server', path: name, agent })
    }
    return { ok: true, message: `Added ${name}.`, writes }
  }

  function installRoutine(input: KindInput, file: string): KindResult {
    const writes: LedgerWrite[] = []
    const source = fileAt(input.files, file)
    if (source === null) return { ok: false, message: `This item has no ${file} in it.`, writes }
    const folder = (input.choice.folder ?? '').trim()
    if (folder === '') {
      return { ok: false, message: 'Choose the folder this routine will run in before installing it.', writes }
    }

    const id = `${input.row.publisher}-${input.item}`
    const withFolder = setRoutineFolder(source.bytes.toString('utf8'), folder)
    const parsed = parseRoutine(id, withFolder)
    if (!parsed.ok) return { ok: false, message: parsed.problems.join(' '), writes }

    /*
     * Off, whatever the file said. A routine that arrived from the internet and
     * armed itself is a stranger's agent session running on a trigger nobody
     * agreed to. Turning it on is one switch on the routines screen, and it is a
     * switch a person presses rather than one an item presses for them.
     */
    const routine = { ...parsed.routine, enabled: false }
    const dir = routinesDirFor(input.userData)
    let target: string
    try {
      target = routineFilePath(dir, id)
    } catch (error) {
      return { ok: false, message: error instanceof Error ? error.message : String(error), writes }
    }
    if (existsSync(target)) {
      return { ok: false, message: `There is already a routine called ${id}, so nothing was written.`, writes }
    }
    mkdirSync(dir, { recursive: true })
    writeFileAtomic(target, serializeRoutine(routine))
    writes.push({ kind: 'file', path: target })
    return { ok: true, message: `Installed ${input.manifest.name}, switched off.`, writes }
  }

  /* --------------------------------------------------------------- undoing -- */

  /** Reverse one write. Returns null when it is gone, or a sentence when it is not. */
  async function undoOne(write: LedgerWrite, record: InstalledRecord): Promise<string | null> {
    try {
      if (write.kind === 'server') {
        const agent = write.agent ?? 'claude'
        const gone =
          agent === 'claude'
            ? await claudeMcp.remove({ name: write.path, scope: 'user', projectPath: null })
            : await runAgent(agent, mcpRemoveArgs(agent, write.path))
        return gone.ok ? null : `${PROVIDERS[agent].label} could not remove ${write.path}: ${gone.message}`
      }
      if (write.kind === 'block') {
        removeBlock(write.path, itemFolderName(record.publisher, record.item))
        return null
      }
      if (write.kind === 'file') {
        rmSync(write.path, { force: true })
        return null
      }
      /*
       * A folder, and only when nothing is left in it. The files this install
       * wrote have already been deleted above — they are recorded one by one —
       * so what `pruneEmpty` clears is the empty scaffolding between them, and
       * what it leaves behind is anything a person put in there afterwards.
       * A store that deletes a folder recursively because it once created it is
       * a store that will one day take somebody's own work with it.
       */
      pruneEmpty(write.path)
      return null
    } catch (error) {
      return `${write.path}: ${error instanceof Error ? error.message : String(error)}`
    }
  }

  /**
   * Undo a half-finished install, so a failure leaves nothing behind.
   *
   * The same reversal Remove performs, on the writes made so far, and it matters
   * most in the case that is easy to miss: an item installing into three tools
   * writes into the first two and is refused by the third, and without this the
   * person is left with two configurations they never agreed to and no row
   * offering to take them away. A `block` comes out by its marker rather than by
   * deleting the file it lives in.
   */
  async function undo(writes: readonly LedgerWrite[], marker: string): Promise<void> {
    for (const write of [...writes].reverse()) {
      try {
        if (write.kind === 'file') rmSync(write.path, { force: true })
        else if (write.kind === 'dir' && existsSync(write.path)) rmSync(write.path, { recursive: true, force: true })
        else if (write.kind === 'block') removeBlock(write.path, marker)
        else if (write.kind === 'server') {
          const agent = write.agent ?? 'claude'
          if (agent === 'claude') await claudeMcp.remove({ name: write.path, scope: 'user', projectPath: null })
          else await runAgent(agent, mcpRemoveArgs(agent, write.path))
        }
      } catch {
        /* Nothing to say here that the caller's own message does not already say. */
      }
    }
  }

  return {
    view,
    install,
    remove,
    installed: () => readLedger(deps.userData()),
  }
}

/* ------------------------------------------------------------ small helpers -- */

/**
 * `codex mcp add …` and `gemini mcp add …`, pinned by a snapshot test.
 *
 * Measured from each tool's own `--help`, and the two differ in a way a guess
 * would get wrong: one has no scope flag at all, and the other has one that
 * **defaults to the project folder**, so writing a user-wide server without
 * passing `-s user` would file it against whatever directory this app happened
 * to be running in.
 */
export function mcpAddArgs(
  agent: ManifestAgent,
  name: string,
  argv: readonly string[],
  extras: readonly string[],
): string[] {
  if (agent === 'codex') {
    return ['mcp', 'add', name, ...extras.flatMap((entry) => ['--env', entry]), '--', ...argv]
  }
  return ['mcp', 'add', '-s', 'user', '-t', 'stdio', ...extras.flatMap((entry) => ['-e', entry]), name, ...argv]
}

/** The other half of the same table. Same scope rule, same reason. */
export function mcpRemoveArgs(agent: ManifestAgent, name: string): string[] {
  return agent === 'codex' ? ['mcp', 'remove', name] : ['mcp', 'remove', '-s', 'user', name]
}

/** Which agents this install writes into, or why the answer is none. */
function chosenAgents(
  row: StoreRow,
  choice: InstallChoice,
): { ok: true; agents: ManifestAgent[] } | { ok: false; why: string } {
  const known = MANIFEST_AGENTS.filter((agent) => row.agents.includes(agent))
  if (row.kind === 'routine') {
    // A routine is run by this app, not by an agent's own configuration.
    return { ok: true, agents: [] }
  }
  if (known.length === 0) return { ok: false, why: 'This item names no coding tool this app can write to.' }
  const asked = choice.agents ?? known
  const picked = known.filter((agent) => asked.includes(agent))
  if (picked.length === 0) return { ok: false, why: 'Choose at least one tool to install this into.' }
  return { ok: true, agents: picked }
}

/**
 * Where the row and the file disagree, in one sentence, or null when they agree.
 *
 * Three things are compared and nothing else: the kind, the version and the
 * install block. Those are what decide what happens on this machine; the name
 * and the summary are what a person read, and a publisher fixing a typo in one
 * of them between the indexer's visit and this download is not a reason to
 * refuse an install.
 */
function disagrees(row: StoreRow, manifest: Manifest): string | null {
  if (manifest.kind !== row.kind) {
    return `The store listed this as a ${row.kind} and the download says it is a ${manifest.kind}. Nothing was installed.`
  }
  if (manifest.version !== row.version) {
    return `The store listed version ${row.version} and the download says ${manifest.version}. Nothing was installed.`
  }
  if (!sameInstall(row.install, manifest.install)) {
    return 'What the store said this would do and what the download does are not the same. Nothing was installed.'
  }
  return null
}

/**
 * Put the chosen folder into a routine's own `in:` line.
 *
 * A published routine cannot know where it will run, and the format requires an
 * answer, so the person installing it gives one and it is written in through the
 * app's own parser rather than concatenated on. Any `in:` the file shipped with
 * is replaced rather than kept: a routine that arrived from the internet naming
 * a folder on this machine chose that folder for somebody.
 */
export function setRoutineFolder(text: string, folder: string): string {
  const { heading, header, prompt } = splitDocument(text)
  const kept = header.filter((line) => !/^\s*in\s*:/i.test(line))
  const lines = [...kept, `in: ${folder}`]
  const head = heading === null ? '' : `# ${heading}\n\n`
  // The `---` is not decoration: it is what separates the settings from the
  // prompt, and a rebuild that drops it turns the prompt into a run of settings
  // the parser then refuses line by line.
  return `${head}${lines.join('\n')}\n\n---\n\n${prompt ?? ''}\n`
}

/** Does this item say it runs on the kind of computer this is? */
function runsHere(row: StoreRow): boolean {
  const here: string = currentPlatform()
  return (row.platforms as readonly string[]).includes(here)
}

/**
 * A row for something installed that the catalogue no longer lists.
 *
 * Built from the ledger rather than invented, which is why the ledger keeps the
 * summary, the licence and the repository at install time: a delisted item still
 * has to draw a row a person can read and press Remove on, and a row with a
 * made-up licence on it would be this store telling somebody they may do
 * something with a stranger's work that nobody ever said.
 */
function rowFromRecord(record: InstalledRecord): StoreRow {
  return {
    id: record.id,
    publisher: record.publisher,
    listedBy: record.publisher,
    kind: record.kind,
    name: record.name,
    summary: record.summary,
    version: record.version,
    licence: record.licence,
    category: record.category,
    tags: [],
    agents: record.agents,
    platforms: [],
    tier: record.tier,
    needs: [],
    cost: 'free',
    costNote: null,
    delivery: 'repo',
    source: { repo: record.repo, commit: record.commit, path: '.', host: '' },
    artifact: null,
    install: null,
    /* No icon and no counts: both come off the catalogue and this row is being
       built precisely because the catalogue no longer carries it. Drawing the
       star count it had the day it was installed would be a number about a
       repository nobody has looked at since. */
    icon: null,
    repoStats: null,
    network: [],
    publishedAt: record.installedAt,
    updatedAt: record.installedAt,
  }
}
