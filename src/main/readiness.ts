/**
 * AI readiness — how well a project is set up for an agent to work in it.
 *
 * Each check is independent: it reads the project, decides pass / warn / fail,
 * explains what it found in a sentence a human can act on, and optionally
 * offers a *described* fix. A fix is never applied by a scan. `scanReadiness`
 * only reads; `applyReadinessFix` only runs when the renderer asks for one fix
 * by id, after showing the user its description.
 *
 * Scoring is weighted, and the secrets check is a gate rather than just a
 * heavy weight: a project that has committed a `.env` is capped below every
 * band, however good the rest of it is. A tidy repo that leaks its API keys is
 * not "87% ready" — it is an incident waiting to happen, and the number has to
 * say so.
 */

import { execFile } from 'node:child_process'
import { readdir, readFile, stat, writeFile } from 'node:fs/promises'
import { isAbsolute } from 'node:path'
import { promisify } from 'node:util'
import { AGENT_CATALOG } from '../shared/agent-catalog'
import type { ProviderId } from '../shared/types'
import { compileIgnorePattern, parseIgnoreFile, safeJoin, type IgnoreRule } from './fs-tree'
import { findGitDir, readGitStatus } from './git'
import { currentPlatform, isWindows, withPath, type Platform } from './platform/host'
import { loginPath } from './providers'
import { launchSpec } from './tool-probe'

const run = promisify(execFile)

/* ------------------------------------------------------------------ types -- */

export type ReadinessStatus = 'pass' | 'warn' | 'fail' | 'skip'

export type ReadinessCheckId =
  | 'secrets'
  | 'claude-md'
  | 'readme'
  | 'test-script'
  | 'typecheck-script'
  | 'lint-script'
  | 'gitignore'
  | 'git-repo'
  | 'git-clean'
  | 'lockfile'

export type ReadinessFixId =
  /*
   * One id per agent, because the file each one reads is a different file.
   *
   * `create-claude-md` kept its name when the other two were added: an id is
   * never read on screen, and renaming this one would orphan every dismissal
   * and every score history keyed on it. What it writes is stated by the fix
   * that carries it, which is built from {@link INSTRUCTIONS_AGENTS} rather
   * than spelled out three times.
   */
  | 'create-claude-md'
  | 'create-agents-md'
  | 'create-gemini-md'
  | 'create-readme'
  | 'create-gitignore'
  | 'patch-gitignore'
  | 'git-init'
  | 'ignore-secrets'
  | 'untrack-secrets'
  | 'add-test-script'
  | 'replace-test-script'
  | 'add-typecheck-script'
  | 'add-lint-script'
  | 'create-lockfile'
  | 'upgrade-agent-cli'

/**
 * Fixes that are about the machine rather than about one project.
 *
 * There is one of them and it is {@link upgradeAgentCli}. It rides this channel
 * because this is the only route the preload already exposes that can *run*
 * something on the person's behalf, and because the alternative — a button that
 * copies a command for somebody to paste into a terminal — is precisely the
 * shape of help the audience for this app cannot use. The review's words about
 * readiness were "an action button that actually does it", and a machine-level
 * problem does not stop being actionable because it is not a property of a
 * folder.
 *
 * The consequence for the channel is small and deliberate: a machine fix is
 * dispatched *before* the project path is validated, so the caller can send an
 * empty one. Nothing else about the contract moves — the id still comes from a
 * closed set, and this module still owns what the id means.
 */
export const MACHINE_FIX_IDS: ReadonlySet<ReadinessFixId> = new Set<ReadinessFixId>([
  'upgrade-agent-cli',
])

/**
 * A fix is a *description* of an action, not the action itself. It is rendered
 * next to the check, and nothing happens until the user asks for it by id.
 */
export interface ReadinessFix {
  id: ReadinessFixId
  /** Button text — an imperative verb phrase. */
  label: string
  /** Everything it will do, in full, so the user can decide before it runs. */
  description: string
  /**
   * What it creates or edits, as the panel prints it under "Changes".
   *
   * Project-relative paths for all but one of them, and paths are what this
   * field was: `.gitignore`, `package.json`, `git index`. A path is the best
   * answer here because it cannot drift from the code the way a sentence can,
   * and because the person reading it is deciding whether to let something
   * write into their repository.
   *
   * The exception is `FIX_CREATE_CLAUDE_MD`, which names the *category* of file
   * instead — the one path in this list that is one vendor's filename, standing
   * always-visible on a panel that runs on any repository with any agent in it.
   * The long note on that fix argues it and states what the substitution costs.
   * Anything added here is read by `neutral-naming.test.ts` as copy, so a new
   * vendor filename in this field fails the suite rather than reaching a screen.
   */
  touches: string[]
  /**
   * Touches git's index rather than only files. The panel asks a second time
   * for these, because undoing them is not a matter of deleting a file.
   */
  destructive: boolean
}

export interface ReadinessCheck {
  id: ReadinessCheckId
  title: string
  status: ReadinessStatus
  /** Share of the score this check can move. Skipped checks score nothing and
   *  are removed from the denominator, so a Rust project is not marked down
   *  for having no npm test script. */
  weight: number
  /** What was actually found, and why an agent cares. */
  detail: string
  fix: ReadinessFix | null
  /** True only for the check that caps the whole score when it is not passing. */
  gate: boolean
  /**
   * The project-relative file this row is *about*, when there is exactly one.
   *
   * Carried so that a row with no automatic fix still has something to press.
   * "Your instructions file is a stub" and "your README is effectively a title"
   * are both true, both worth saying, and neither can be repaired by a machine —
   * what a person needs there is the file open in front of them, which the
   * renderer can do with the path and nothing else.
   *
   * Null wherever a row is not about one file. A dirty working tree is about
   * twenty of them and a missing lockfile is about none, and inventing a path
   * for those would put a button on a row that opens the wrong thing.
   */
  opens: string | null
}

export type ReadinessBand = 'strong' | 'fair' | 'weak' | 'at-risk'

/**
 * The same project, graded for one named agent.
 *
 * ## Why the report is not one list any more
 *
 * Asad, on the readiness page, 2026-08-21:
 *
 *   > *"And now here we also don't know which AI it is talking about."*
 *
 * The page had one row reading *"Agent instructions present and useful — No
 * instructions file at the project root"* and a button reading *"Create
 * instructions file"*, and nothing anywhere on it said Claude, Codex or Gemini,
 * or which of `CLAUDE.md`, `AGENTS.md` and `GEMINI.md` the button was about to
 * write. Every other check on the page is a fact about the project — a
 * lockfile is a lockfile whoever reads it — but that one is a fact about *an
 * agent*, and it had been written as though there were only one.
 *
 * So the scan answers for each agent as well as for the project. Everything but
 * the instructions check is shared, because nothing else here differs by agent;
 * what varies is that check, and therefore the weighted score, which is why
 * each variant carries its own — a page that swapped one row and left the ring
 * showing the other agent's number would be the arithmetic that does not add up
 * (T67) wearing a new hat.
 *
 * The neutral list is still the top-level one, and stays the answer for
 * everything that asks this module a question without naming an agent — the
 * Overview's readiness tile, chiefly. See {@link checkInstructions} for what
 * "neutral" grades.
 */
export interface ReadinessForAgent {
  agent: ProviderId
  /** What that agent is called on screen, from the one catalogue that names it. */
  label: string
  /** The file it reads at a project root, and the one its fix would write. */
  file: string
  /** The instructions check as it reads for this agent. */
  check: ReadinessCheck
  score: number
  band: ReadinessBand
  cappedBy: string | null
}

export interface ReadinessReport {
  projectPath: string
  /** 0–100, weighted over the applicable checks, then gated. */
  score: number
  band: ReadinessBand
  checks: ReadinessCheck[]
  /** Why the score was held below what the weights alone produced, if it was. */
  cappedBy: string | null
  /**
   * The same scan, graded for each agent this build knows the instructions file
   * of. Ordered as {@link INSTRUCTIONS_AGENTS} is, which is the catalogue's own
   * order — never "the one this machine has installed first", which would make
   * the page's default depend on the reader's machine.
   */
  agents: ReadinessForAgent[]
  scannedAt: string
}

export interface ReadinessFixResult {
  ok: boolean
  /** Shown verbatim under the check — success or the reason it did nothing. */
  message: string
  /** Project-relative paths that actually changed. */
  changed: string[]
}

/* ---------------------------------------------------------------- scoring -- */

/** Half credit for a warning: it is a real cost, but not a missing foundation. */
export const STATUS_CREDIT: Record<ReadinessStatus, number> = {
  pass: 1,
  warn: 0.5,
  fail: 0,
  skip: 0,
}

/**
 * Weights. The secrets check is the heaviest single item *and* the gate, so
 * there is no arithmetic path to a respectable score while keys are exposed.
 */
export const CHECK_WEIGHTS: Record<ReadinessCheckId, number> = {
  secrets: 30,
  'claude-md': 18,
  'test-script': 14,
  'git-repo': 12,
  gitignore: 10,
  readme: 8,
  'typecheck-script': 8,
  'git-clean': 8,
  'lint-script': 6,
  lockfile: 6,
}

/**
 * Caps applied when the secrets gate is not clean. 39 is deliberate: it sits
 * below the bottom of the 'weak' band, so a leaking project always renders as
 * 'at-risk' no matter how complete everything else is.
 */
export const SECRET_FAIL_CAP = 39
export const SECRET_WARN_CAP = 79

const BANDS: ReadonlyArray<{ min: number; band: ReadinessBand }> = [
  { min: 85, band: 'strong' },
  { min: 65, band: 'fair' },
  { min: 40, band: 'weak' },
  { min: 0, band: 'at-risk' },
]

export function bandFor(score: number): ReadinessBand {
  return BANDS.find((entry) => score >= entry.min)?.band ?? 'at-risk'
}

/**
 * Pure scoring, kept separate from every filesystem read so the weighting and
 * the gate can be tested on hand-built check lists.
 */
export function scoreChecks(checks: ReadinessCheck[]): {
  score: number
  band: ReadinessBand
  cappedBy: string | null
} {
  let earned = 0
  let applicable = 0
  for (const check of checks) {
    if (check.status === 'skip') continue
    applicable += check.weight
    earned += check.weight * STATUS_CREDIT[check.status]
  }

  let score = applicable > 0 ? Math.round((earned / applicable) * 100) : 0
  let cappedBy: string | null = null

  for (const check of checks) {
    if (!check.gate || check.status === 'pass' || check.status === 'skip') continue
    const cap = check.status === 'fail' ? SECRET_FAIL_CAP : SECRET_WARN_CAP
    if (score > cap) {
      score = cap
      cappedBy = check.title
    }
  }

  return { score, band: bandFor(score), cappedBy }
}

/* ------------------------------------------------------------------ files -- */

/** A package.json bigger than this is not a package.json worth parsing. */
const MAX_JSON_BYTES = 2 * 1024 * 1024
/** Instruction and readme files are read whole; cap them the same way. */
const MAX_TEXT_BYTES = 1024 * 1024

/**
 * "Not there" and "there but too big to read" are different findings, and a
 * check that conflates them tells the user something untrue — a 2 MB CLAUDE.md
 * reported as "No CLAUDE.md", with a create-it fix that can only ever refuse.
 * Every reader distinguishes the two; `readTextAt` collapses them only where
 * the caller genuinely does not care.
 */
type TextRead =
  | { kind: 'text'; text: string }
  | { kind: 'too-big'; bytes: number }
  | { kind: 'missing' }

async function readTextEntry(
  root: string,
  relPath: string,
  limit = MAX_TEXT_BYTES,
): Promise<TextRead> {
  try {
    const file = safeJoin(root, relPath)
    const info = await stat(file)
    if (!info.isFile()) return { kind: 'missing' }
    if (info.size > limit) return { kind: 'too-big', bytes: info.size }
    return { kind: 'text', text: await readFile(file, 'utf8') }
  } catch {
    return { kind: 'missing' }
  }
}

async function readTextAt(root: string, relPath: string): Promise<string | null> {
  const entry = await readTextEntry(root, relPath)
  return entry.kind === 'text' ? entry.text : null
}

/** Sizes in a detail line are for a human deciding what to do, not for maths. */
export function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`
  return `${bytes} bytes`
}

/** A readable list that cannot grow without bound in a detail string. */
export function listPaths(paths: string[], max = 4): string {
  const shown = paths.slice(0, max).join(', ')
  return paths.length > max ? `${shown} and ${paths.length - max} more` : shown
}

async function exists(root: string, relPath: string): Promise<boolean> {
  try {
    await stat(safeJoin(root, relPath))
    return true
  } catch {
    return false
  }
}

interface PackageJson {
  scripts: Record<string, string>
  deps: Record<string, string>
  /**
   * Corepack's `packageManager` field, verbatim, or null when there is none.
   *
   * Read for exactly one decision: whether the lockfile fix is allowed to run
   * npm. A project that declares `pnpm@9` and has no lockfile would get a
   * `package-lock.json` from an npm run, which is not the file it wanted and is
   * a worse state than the one it was in.
   */
  packageManager: string | null
  /** Raw text, so a fix can rewrite it without losing formatting choices. */
  raw: string
}

async function readPackageJson(root: string): Promise<PackageJson | null> {
  // Read to the JSON limit rather than the prose one: a 1.5 MB package.json is
  // unusual but real (generated manifests), and treating it as absent silently
  // *skips* three checks, which lifts the score instead of lowering it.
  const entry = await readTextEntry(root, 'package.json', MAX_JSON_BYTES)
  if (entry.kind !== 'text') return null
  const raw = entry.text

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    // Malformed package.json: every npm-shaped check degrades to "cannot tell"
    // rather than claiming the scripts are missing.
    return null
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null

  const root_ = parsed as Record<string, unknown>
  return {
    scripts: stringMap(root_.scripts),
    deps: { ...stringMap(root_.dependencies), ...stringMap(root_.devDependencies) },
    packageManager: typeof root_.packageManager === 'string' ? root_.packageManager : null,
    raw,
  }
}

/**
 * Would running npm here produce the lockfile this project actually wants?
 *
 * Only when nothing says otherwise. An undeclared project gets npm because npm
 * is what ships with Node and is what an undeclared project is overwhelmingly
 * likely to be using; a project that names a different manager is left alone
 * rather than handed a file from the wrong tool.
 */
export function npmIsTheManager(pkg: PackageJson | null): boolean {
  if (pkg === null) return false
  return pkg.packageManager === null || /^npm@/.test(pkg.packageManager)
}

function stringMap(value: unknown): Record<string, string> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return {}
  const out: Record<string, string> = {}
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    if (typeof entry === 'string') out[key] = entry
  }
  return out
}

/**
 * Lines that carry information: blanks, horizontal rules and HTML comments are
 * not context, and a 200-line file of them is still a stub.
 */
/**
 * Is this file still exactly the skeleton one of the fixes below wrote?
 *
 * This is the half of the "create README" button that was missing, and it is
 * the reason the review says that button "is the right idea but not done
 * properly". Pressing it wrote a file of headings and `<!-- fill this in -->`
 * comments, and the very next scan counted thirteen meaningful lines and turned
 * the row green. One click took a project from "no README" to "README for
 * humans ✓" without a single word about the project existing anywhere on disk.
 * The score went up and nothing got better, which is the definition of a fake
 * control — and the same was true of the instructions file, which cleared both
 * its length floor and its "names a runnable command" test on the strength of
 * the empty fenced blocks in its own template.
 *
 * The test is exact rather than heuristic: every non-blank line of the file has
 * to be a line the template already contained. Add one sentence of your own and
 * it is no longer a skeleton; delete half of it and it still is. That way the
 * finding cannot misfire on a real README that happens to share a heading, and
 * it cannot be satisfied by whitespace.
 */
export function isUnfilledSkeleton(text: string, template: string): boolean {
  const written = new Set(template.split(/\r?\n/).map((line) => line.trim()))
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== '')
  return lines.length > 0 && lines.every((line) => written.has(line))
}

export function meaningfulLines(text: string): number {
  let count = 0
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim()
    if (trimmed === '') continue
    if (/^(-{3,}|={3,}|\*{3,})$/.test(trimmed)) continue
    if (trimmed.startsWith('<!--')) continue
    count++
  }
  return count
}

/* -------------------------------------------------------------- git access -- */

const GIT_TIMEOUT_MS = 8000
const MAX_BUFFER = 16 * 1024 * 1024

interface GitRunOptions {
  /** A read may skip the index lock; a write must take it. */
  write?: boolean
}

async function git(cwd: string, args: string[], options: GitRunOptions = {}): Promise<string> {
  const PATH = await loginPath()
  const { stdout } = await run('git', args, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
    env: {
      // `withPath`, not `{ ...process.env, PATH }`: the literal key leaves
      // Windows holding both `Path` and `PATH`. See `platform/host.ts`.
      ...withPath(process.env, PATH, currentPlatform()),
      ...(options.write ? {} : { GIT_OPTIONAL_LOCKS: '0' }),
      LC_ALL: 'C',
    },
  })
  return stdout
}

/** Every path git is tracking under this folder, or null when git cannot say. */
async function trackedFiles(root: string): Promise<string[] | null> {
  try {
    const out = await git(root, ['ls-files', '-z'])
    return out.split('\0').filter((entry) => entry !== '')
  } catch {
    return null
  }
}

/* ---------------------------------------------------------------- secrets -- */

/**
 * Filenames that carry credentials often enough to be worth stopping for.
 * Deliberately filename-based rather than content-based: grepping a whole repo
 * for entropy is slow and produces false alarms on fixtures and test data,
 * whereas a committed `.env` is unambiguous every single time.
 */
const SECRET_FILE_RE =
  /(^|\/)(\.env(\.[^/]+)?|[^/]+\.(pem|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.pgpass|secrets?\.(json|ya?ml)|credentials\.json|serviceaccount[^/]*\.json)$/i

/** `.env.example` is documentation every repo should ship, not a leak. */
const EXAMPLE_SUFFIX_RE = /\.(example|sample|template|dist|defaults?)$/i

/** An npmrc only matters when it carries a registry token. */
const NPMRC_TOKEN_RE = /^\s*(\/\/.*:)?_auth(Token)?\s*=/im

export function looksLikeSecretFile(relPath: string): boolean {
  if (EXAMPLE_SUFFIX_RE.test(relPath)) return false
  return SECRET_FILE_RE.test(relPath)
}

const NPMRC_RE = /(^|\/)\.npmrc$/

/**
 * Which of these paths actually carry credentials.
 *
 * The one place that answers this question. It used to be answered twice —
 * once by the check and once by the fix — and the two answers differed: an
 * .npmrc is a secret only when it holds a token, which the check tested for
 * and the fix did not, so the check reported a failure and offered a button
 * that then said "git is no longer tracking any secret files" and did nothing.
 */
async function secretPathsAmong(root: string, paths: string[]): Promise<string[]> {
  const found: string[] = []
  for (const path of paths) {
    if (looksLikeSecretFile(path)) {
      found.push(path)
      continue
    }
    if (!NPMRC_RE.test(path)) continue
    const text = await readTextAt(root, path)
    if (text !== null && NPMRC_TOKEN_RE.test(text)) found.push(path)
  }
  return found
}

/** Patterns written into .gitignore by the secret fixes. */
const SECRET_IGNORE_PATTERNS = [
  '.env',
  '.env.*',
  '!.env.example',
  '*.pem',
  '*.p12',
  '*.pfx',
  'id_rsa',
  'id_ed25519',
  '.netrc',
]

/* ----------------------------------------------------------- ignore rules -- */

/**
 * Does any rule in a .gitignore cover this path?
 *
 * `createIgnoreMatcher` in fs-tree cannot answer this: it force-ignores
 * `node_modules` and `.git` whatever the rules say, which is right for a file
 * tree and wrong here — it would report a pass for a .gitignore that never
 * mentions node_modules at all. So the compiled rules are reused and evaluated
 * directly, last match winning, exactly as git resolves them.
 */
export function ignoreCovers(rules: IgnoreRule[], relPath: string, isDir: boolean): boolean {
  const segments = relPath.split('/').filter((segment) => segment !== '')
  if (segments.length === 0) return false

  for (let i = 0; i < segments.length; i++) {
    const last = i === segments.length - 1
    const path = segments.slice(0, i + 1).join('/')
    let covered = false
    for (const rule of rules) {
      if (rule.dirOnly && !(last ? isDir : true)) continue
      if (rule.re.test(path)) covered = !rule.negated
    }
    // An ignored ancestor settles it — nothing beneath it can be re-included.
    if (covered) return true
    if (last) return false
  }
  return false
}

async function readIgnoreRules(root: string): Promise<IgnoreRule[] | null> {
  const text = await readTextAt(root, '.gitignore')
  return text === null ? null : parseIgnoreFile(text)
}

/* ----------------------------------------------------------------- checks -- */

function check(
  id: ReadinessCheckId,
  title: string,
  status: ReadinessStatus,
  detail: string,
  fix: ReadinessFix | null = null,
  gate = false,
  opens: string | null = null,
): ReadinessCheck {
  return { id, title, status, weight: CHECK_WEIGHTS[id], detail, fix, gate, opens }
}

const FIX_IGNORE_SECRETS: ReadinessFix = {
  id: 'ignore-secrets',
  label: 'Ignore secret files',
  description:
    'Appends the standard secret patterns (.env, .env.*, *.pem, id_rsa and friends) to .gitignore, keeping .env.example allowed. Creates .gitignore if it does not exist. Nothing is deleted, and no file on disk is touched.',
  touches: ['.gitignore'],
  destructive: false,
}

const FIX_UNTRACK_SECRETS: ReadinessFix = {
  id: 'untrack-secrets',
  label: 'Untrack and ignore',
  description:
    'Adds the secret patterns to .gitignore, then runs `git rm --cached` on the tracked secret files so git stops following them. The files stay on your disk. This does NOT erase them from past commits — anything already pushed must be treated as leaked, and those keys rotated.',
  touches: ['.gitignore', 'git index'],
  destructive: true,
}

/**
 * The gate. Fails on a secret git is already tracking, warns on one sitting in
 * the project unignored — a single `git add .` away from the first case.
 */
async function checkSecrets(root: string, tracked: string[] | null): Promise<ReadinessCheck> {
  const committed = await secretPathsAmong(root, tracked ?? [])

  if (committed.length > 0) {
    return check(
      'secrets',
      'No secrets committed',
      'fail',
      `git is tracking ${committed.length} credential file${committed.length === 1 ? '' : 's'}: ${listPaths(committed)}. Anything an agent reads it can also quote back into a transcript, a commit message or a pull request — and if this repo has ever been pushed, those keys are already public. Untrack them, then rotate them.`,
      FIX_UNTRACK_SECRETS,
      true,
    )
  }

  // Depth 1 only: a full-tree walk is O(repo) on every scan, and a stray .env
  // at the root is the case that actually happens.
  let names: string[] = []
  try {
    names = (await readdir(root, { withFileTypes: true }))
      .filter((entry) => entry.isFile())
      .map((entry) => entry.name)
  } catch {
    names = []
  }

  const present = names.filter(looksLikeSecretFile)
  if (present.length === 0) {
    return check(
      'secrets',
      'No secrets committed',
      'pass',
      'No credential files are tracked by git or sitting unignored in the project root.',
      null,
      true,
    )
  }

  const rules = await readIgnoreRules(root)
  const exposed = present.filter((name) => !rules || !ignoreCovers(rules, name, false))
  if (exposed.length === 0) {
    return check(
      'secrets',
      'No secrets committed',
      'pass',
      `${present.length} credential file${present.length === 1 ? ' is' : 's are'} present but covered by .gitignore, so git will not pick ${present.length === 1 ? 'it' : 'them'} up.`,
      null,
      true,
    )
  }

  return check(
    'secrets',
    'No secrets committed',
    'warn',
    `${listPaths(exposed)} ${exposed.length === 1 ? 'is' : 'are'} in the project and not covered by .gitignore. Nothing has leaked yet, but the next \`git add .\` — yours or an agent's — commits ${exposed.length === 1 ? 'it' : 'them'}.`,
    FIX_IGNORE_SECRETS,
    true,
  )
}

/**
 * Which file each agent reads for its project instructions, and which one this
 * app would write for it.
 *
 * ## Every line of this table was read off the CLI itself
 *
 * The rule the agent catalogue states — never declare something about an agent
 * that has not been checked against the real thing — applies with more force
 * here, because a wrong filename does not fail loudly: it grades somebody's
 * project against a file their agent never reads, and then offers to create a
 * second one beside the one they already have. Measured on this machine on
 * 2026-08-21:
 *
 *     Claude Code 2.1.238   the binary carries the string
 *                           "CLAUDE.md / AGENTS.md discovery", so it reads both
 *     Codex 0.146.0-alpha   `AGENTS.md` in the shipped binary
 *                           (`~/.codex/plugins/.plugin-appserver/codex`; the npm
 *                           launcher on PATH has no vendored binary — see the
 *                           catalogue's note on `alternateBins`)
 *     Gemini CLI 0.46.0     `DEFAULT_CONTEXT_FILENAME = "GEMINI.md"` in three
 *                           of its bundle chunks
 *
 * `.claude/CLAUDE.md` stays in Claude Code's candidates because the check has
 * accepted it since it was written and a project that keeps its instructions
 * there is instructed; nothing in this pass established a second location for
 * the other two, so neither gets one invented.
 *
 * `shell` is absent and it is the only member of `ProviderId` that is: a login
 * shell reads no instructions file, so a row for it would be a check that can
 * never pass and never matter.
 *
 * ## Naming the files at all
 *
 * `neutral-naming.test.ts` refuses two of these three filenames anywhere in
 * copy, for a reason that is exactly right and exactly why they belong here:
 * *"a settings pane that says 'edit your CLAUDE.md' has silently chosen one of
 * three agents on a screen where all three are possible."* This screen chooses
 * nothing — it offers all three, the reader picks, and the file named is the
 * file that reader's agent reads. That is part 3 of the rule satisfied rather
 * than dodged, and `ReadinessPanel.test.tsx` pins it the way the guard's own
 * note says part 3 has to be pinned: by asserting the screen offers all of them.
 */
interface InstructionsAgent {
  agent: ProviderId
  /** Files this agent reads at the project root, best first. */
  candidates: string[]
  /** The one it would be given if it has none. Always `candidates[0]`. */
  file: string
  fixId: ReadinessFixId
}

export const INSTRUCTIONS_AGENTS: readonly InstructionsAgent[] = [
  { agent: 'claude', candidates: ['CLAUDE.md', '.claude/CLAUDE.md', 'AGENTS.md'], file: 'CLAUDE.md', fixId: 'create-claude-md' },
  { agent: 'codex', candidates: ['AGENTS.md'], file: 'AGENTS.md', fixId: 'create-agents-md' },
  { agent: 'gemini', candidates: ['GEMINI.md'], file: 'GEMINI.md', fixId: 'create-gemini-md' },
]

/**
 * Every file any known agent would read, in the order they are looked for.
 *
 * This is what the neutral check grades, and it is a union rather than one
 * agent's list: a project with only `GEMINI.md` in it *is* instructed, and
 * before this table existed the scan told its owner they had no instructions
 * file at all.
 */
const CLAUDE_MD_CANDIDATES = [...new Set(INSTRUCTIONS_AGENTS.flatMap((entry) => entry.candidates))]

/** Below this an instructions file is a stub that tells an agent nothing. */
export const CLAUDE_MD_MIN_LINES = 12
/** Above this it is paying rent in every single prompt. */
export const CLAUDE_MD_BLOAT_LINES = 400

/**
 * Text that reads like a command an agent could actually run: a fenced block,
 * or a named tool anywhere in the prose. Inline spans count — plenty of good
 * instruction files write `npm test` mid-sentence rather than in a block.
 */
const COMMAND_HINT_RE =
  /```|(^|[\s`("'])(npm|pnpm|yarn|bun|npx|make|cargo|pytest|uv|dotnet|gradle|mvn|docker|deno|rake|tox|go (run|test|build)|python3? -m|\.\/[\w.-]+\.sh)\b/i

/**
 * The fix that writes one agent's instructions file.
 *
 * ## The label names the file now, and that is the whole of T68
 *
 * It read "Create instructions file", on a page that named no agent, above a
 * finding that named no file. Asad: *"here we also don't know which AI it is
 * talking about."* Pressing it wrote `CLAUDE.md` — correct for one of the three
 * agents this app runs, invisible before the press for all of them.
 *
 * The rule this appears to cross is the one that says a screen must not pick an
 * agent for a reader who runs another, and it is satisfied rather than
 * sidestepped: the page above this button offers Claude Code, Codex CLI and
 * Gemini CLI, the reader picks, and this button then names *that* reader's
 * file. Naming it is disclosure — what is about to appear on their disk — and
 * it is the same disclosure the description has carried since it was written,
 * moved to where it is read without a hover. See {@link INSTRUCTIONS_AGENTS}.
 *
 * ## `touches` names the file too
 *
 * `touches` is the always-visible line, printed under "Changes" the moment the
 * row is drawn. It said "your instructions file" — the category — because a
 * vendor's filename standing there unprompted on a page that grades any
 * repository was the thing the 2026-08-17 review objected to. On a page where
 * the agent is chosen above it, the category phrase is the one that is now
 * unhelpful: it is the file this button is about to create, and the reader is
 * deciding whether to let it.
 */
function createInstructionsFix(entry: InstructionsAgent): ReadinessFix {
  const label = AGENT_CATALOG[entry.agent].label
  return {
    id: entry.fixId,
    label: `Create ${entry.file}`,
    description: `Writes an instructions skeleton at the project root for ${label} — what this is, how to run it, how to test it, layout and conventions — each section left as a prompt for you to fill in. Refuses if one is already there.`,
    touches: [entry.file],
    destructive: false,
  }
}

/**
 * What this check is called on screen, written once because it is said eight
 * times.
 *
 * It was a literal title spelled out at every return in
 * {@link checkInstructions} and once more in `scanReadiness`, and the naming
 * sweep is only half the reason it is a constant now. Nine copies of a title is
 * nine chances for one of them to drift, and a readiness row whose heading
 * changes depending on *which* branch answered is a row that looks like two
 * different checks.
 *
 * The name describes the category rather than one vendor's filename. Which
 * agent a given variant is about is said in the row's own finding, where it is
 * a fact about what was looked for rather than a heading that would have to
 * change under a pill.
 */
const AGENT_INSTRUCTIONS_TITLE = 'Agent instructions present and useful'

/**
 * The instructions check, for one agent or for the project as a whole.
 *
 * `agent` is null for the neutral answer — the one the top-level report and the
 * Overview's tile carry — and it grades *any* file a known agent would read. A
 * project with only `GEMINI.md` in it is instructed, and saying otherwise was a
 * real defect rather than a wording problem: the scan told its owner they had
 * no instructions file while the file sat in the root.
 *
 * With an agent, it grades only what that agent reads and its finding says so
 * by name. The two share every rule below the search — the skeleton test, the
 * length floor, the bloat ceiling, the runnable-command test — because those
 * are properties of an instructions file and not of whose it is.
 */
async function checkInstructions(
  root: string,
  agent: InstructionsAgent | null,
): Promise<ReadinessCheck> {
  const candidates = agent === null ? CLAUDE_MD_CANDIDATES : agent.candidates
  const who = agent === null ? 'An agent' : AGENT_CATALOG[agent.agent].label
  const fix = agent === null ? null : createInstructionsFix(agent)

  let found: string | null = null
  let text: string | null = null
  for (const candidate of candidates) {
    const entry = await readTextEntry(root, candidate)
    // Present but unreadably large is a finding of its own — never "missing".
    if (entry.kind === 'too-big') {
      return check(
        'claude-md',
        AGENT_INSTRUCTIONS_TITLE,
        'warn',
        `${candidate} is ${formatBytes(entry.bytes)}. It is re-read on every prompt, so at that size it crowds out your own source — and it is too large for this scan to read at all. Cut it to the essentials and link the rest.`,
        null,
        false,
        candidate,
      )
    }
    if (entry.kind === 'text') {
      found = candidate
      text = entry.text
      break
    }
  }

  if (text === null || found === null) {
    /*
     * The only branch that cannot name a file on disk, because there is not one
     * — so it names the file that is missing instead.
     *
     * It used to recite the three names the scan accepts in one sentence, which
     * was removed on 2026-08-19 as *defining the category* by one vendor's
     * filenames on a panel that a person running another agent would read. That
     * argument stands, and the answer to it is not silence: it is that the
     * reader has chosen an agent two centimetres above this row, and the file
     * named here is the file *that* agent reads. The neutral variant, which is
     * the one nobody has chosen anything for, still names no file — it lists
     * how many were looked for and leaves the choice on the pills.
     */
    return check(
      'claude-md',
      AGENT_INSTRUCTIONS_TITLE,
      'fail',
      agent === null
        ? `No instructions file at the project root — none of the ${candidates.length} files a known agent reads is here. Every session starts by re-deriving your build commands, your layout and your conventions from scratch — slower, more expensive, and wrong more often.`
        : `${who} reads ${listPaths(agent.candidates, 3)}, and this project ${agent.candidates.length === 1 ? 'has no such file' : 'has none of them'}. Every session starts by re-deriving your build commands, your layout and your conventions from scratch — slower, more expensive, and wrong more often.`,
      fix,
    )
  }

  // Before the length and the command test, both of which this app's own
  // template passes on the strength of its empty fenced blocks. See
  // `isUnfilledSkeleton`.
  if (isUnfilledSkeleton(text, instructionsTemplate(basenameOf(found)))) {
    return check(
      'claude-md',
      AGENT_INSTRUCTIONS_TITLE,
      'warn',
      `${found} is still the skeleton this app wrote — every line in it is a heading or a placeholder. Fill in what the project is, how to run it, how to test it and the conventions you enforce; until then it tells ${agent === null ? 'an agent' : who} nothing it could not guess.`,
      null,
      false,
      found,
    )
  }

  const lines = meaningfulLines(text)
  if (lines < CLAUDE_MD_MIN_LINES) {
    return check(
      'claude-md',
      AGENT_INSTRUCTIONS_TITLE,
      'warn',
      `${found} exists but holds only ${lines} meaningful line${lines === 1 ? '' : 's'}. A stub is barely better than nothing: cover what the project is, how to run it, how to test it, and the conventions you actually enforce.`,
      null,
      false,
      found,
    )
  }
  if (lines > CLAUDE_MD_BLOAT_LINES) {
    return check(
      'claude-md',
      AGENT_INSTRUCTIONS_TITLE,
      'warn',
      `${found} is ${lines} meaningful lines. It is re-read on every prompt, so past roughly ${CLAUDE_MD_BLOAT_LINES} lines it competes with your own source for context. Move the depth into linked files.`,
      null,
      false,
      found,
    )
  }
  if (!COMMAND_HINT_RE.test(text)) {
    return check(
      'claude-md',
      AGENT_INSTRUCTIONS_TITLE,
      'warn',
      `${found} is a good length (${lines} lines) but names no runnable commands. Without the exact build and test commands an agent guesses, and guesses badly on anything with custom scripts.`,
      null,
      false,
      found,
    )
  }

  return check(
    'claude-md',
    AGENT_INSTRUCTIONS_TITLE,
    'pass',
    `${found} is ${lines} meaningful lines and documents commands ${agent === null ? 'an agent' : who} can run.`,
    null,
    false,
    found,
  )
}

const FIX_CREATE_README: ReadinessFix = {
  id: 'create-readme',
  label: 'Create README.md',
  description:
    'Writes a short README.md at the project root — title, one-line summary, install, run, test — with placeholders to fill in. Refuses if a README already exists.',
  touches: ['README.md'],
  destructive: false,
}

/** Below this a README is a title and nothing else. */
const README_MIN_LINES = 5

async function checkReadme(root: string): Promise<ReadinessCheck> {
  let name: string | null = null
  try {
    const entries = await readdir(root, { withFileTypes: true })
    name = entries.find((entry) => entry.isFile() && /^readme(\.|$)/i.test(entry.name))?.name ?? null
  } catch {
    name = null
  }

  if (name === null) {
    return check(
      'readme',
      'README for humans',
      'fail',
      // "The instructions file", not one agent's name for it. This sentence is
      // about the *relationship* between two documents, and it reads a line
      // under the instructions check, which now calls the thing by the same
      // words. Two names for one file across two adjacent rows is how somebody
      // concludes their project is missing a third document.
      'No README. It is the file an agent opens when the instructions file does not answer the question, and the one a new contributor opens first.',
      FIX_CREATE_README,
    )
  }

  const entry = await readTextEntry(root, name)
  // Too large to read is emphatically not "effectively a title".
  if (entry.kind !== 'text') {
    return check(
      'readme',
      'README for humans',
      'pass',
      entry.kind === 'too-big'
        ? `${name} is ${formatBytes(entry.bytes)} — too large to measure here, but nobody could call it a stub.`
        : `${name} is present but could not be read; taking it at face value.`,
      null,
      false,
      name,
    )
  }

  // The skeleton this app writes clears the line floor comfortably, so this has
  // to be asked before the count is. See `isUnfilledSkeleton`.
  if (isUnfilledSkeleton(entry.text, readmeTemplate(basenameOf(root)))) {
    return check(
      'readme',
      'README for humans',
      'warn',
      `${name} is still the skeleton this app wrote — headings and placeholders, and nothing about this project. Open it and say what this is, how to install it and how to run it.`,
      null,
      false,
      name,
    )
  }

  const lines = meaningfulLines(entry.text)
  if (lines < README_MIN_LINES) {
    return check(
      'readme',
      'README for humans',
      'warn',
      `${name} has ${lines} meaningful line${lines === 1 ? '' : 's'} — effectively a title. Say what this is and how to run it.`,
      null,
      false,
      name,
    )
  }
  return check(
    'readme',
    'README for humans',
    'pass',
    `${name} is ${lines} meaningful lines.`,
    null,
    false,
    name,
  )
}

/* ------------------------------------------------------- package scripts -- */

/** npm's own placeholder, which exits 1 and tests nothing. */
const PLACEHOLDER_TEST_RE = /no test specified/i

interface ScriptRunner {
  /** Name of the script to add, and the command to add for it. */
  script: string
  command: string
}

/** Which installed tool a script would be built on, if any. */
function detectTestRunner(deps: Record<string, string>): ScriptRunner | null {
  if (deps.vitest) return { script: 'test', command: 'vitest run' }
  if (deps.jest) return { script: 'test', command: 'jest' }
  if (deps.mocha) return { script: 'test', command: 'mocha' }
  if (deps.ava) return { script: 'test', command: 'ava' }
  if (deps.playwright || deps['@playwright/test']) {
    return { script: 'test', command: 'playwright test' }
  }
  return null
}

function detectLinter(deps: Record<string, string>): ScriptRunner | null {
  if (deps.eslint) return { script: 'lint', command: 'eslint .' }
  if (deps['@biomejs/biome']) return { script: 'lint', command: 'biome check .' }
  if (deps.oxlint) return { script: 'lint', command: 'oxlint' }
  if (deps.prettier) return { script: 'lint', command: 'prettier --check .' }
  return null
}

function scriptMatching(scripts: Record<string, string>, name: RegExp, body: RegExp): string | null {
  for (const [key, value] of Object.entries(scripts)) {
    if (name.test(key) || body.test(value)) return key
  }
  return null
}

function fixAddScript(id: ReadinessFixId, label: string, runner: ScriptRunner): ReadinessFix {
  return {
    id,
    label,
    description: `Adds "${runner.script}": "${runner.command}" to the scripts block in package.json, using the tool already in your dependencies. Existing scripts are left alone, and it refuses if "${runner.script}" is already defined.`,
    touches: ['package.json'],
    destructive: false,
  }
}

/**
 * Overwrite npm's own placeholder with the runner that is actually installed.
 *
 * Marked destructive so the panel asks a second time, and the second question
 * is worth asking even though the line being replaced does nothing: a value in
 * somebody's package.json is being changed, and a fix that edits an existing key
 * without saying so is how one-click repairs lose people's trust. The refusal
 * side is what keeps the promise narrow — it will only ever replace the exact
 * string npm generates, never a script anybody wrote.
 */
function fixReplaceScript(runner: ScriptRunner): ReadinessFix {
  return {
    id: 'replace-test-script',
    label: 'Replace the placeholder',
    description: `Replaces npm's placeholder test script with "${runner.command}", the runner already in your dependencies. It refuses unless the current value is still that placeholder, so a script you wrote yourself cannot be overwritten.`,
    touches: ['package.json'],
    destructive: true,
  }
}

/** Non-npm projects still have tests; look for the obvious markers. */
async function otherTestMarker(root: string): Promise<string | null> {
  const pyproject = await readTextAt(root, 'pyproject.toml')
  if (pyproject && /\bpytest\b/.test(pyproject)) return 'pyproject.toml (pytest)'
  if (await exists(root, 'Cargo.toml')) return 'Cargo.toml (cargo test)'
  if (await exists(root, 'go.mod')) return 'go.mod (go test)'
  const makefile = await readTextAt(root, 'Makefile')
  if (makefile && /^test\s*:/m.test(makefile)) return 'Makefile (make test)'
  return null
}

async function checkTestScript(root: string, pkg: PackageJson | null): Promise<ReadinessCheck> {
  if (pkg === null) {
    const marker = await otherTestMarker(root)
    if (marker !== null) {
      return check(
        'test-script',
        'Tests can be run with one command',
        'pass',
        `${marker} gives an agent a single command to verify its own changes.`,
      )
    }
    return check(
      'test-script',
      'Tests can be run with one command',
      'skip',
      'No package.json or other recognised project manifest, so there is no test entry point to look for.',
    )
  }

  const value = pkg.scripts.test
  if (typeof value === 'string' && value.trim() !== '' && !PLACEHOLDER_TEST_RE.test(value)) {
    return check(
      'test-script',
      'Tests can be run with one command',
      'pass',
      `\`npm test\` runs \`${value}\`. An agent can check its own work before handing it back.`,
    )
  }

  const runner = detectTestRunner(pkg.deps)
  const placeholder = typeof value === 'string' && PLACEHOLDER_TEST_RE.test(value)
  const detail = placeholder
    ? "The test script is still npm's placeholder, which exits 1 without running anything. An agent that runs it sees a failure it cannot explain."
    : runner
      ? `No test script, although \`${runner.command.split(' ')[0]}\` is installed. Without one, an agent writes code it has no way to verify.`
      : 'No test script and no test runner in the dependencies. An agent cannot verify its own changes, so every mistake reaches you instead of the test output.'

  /*
   * The placeholder used to be the one shape of this finding with no button,
   * and there was no reason for it beyond `addScript` refusing to touch a key
   * that already exists. A project with a runner installed and npm's stub still
   * in the scripts block is the *easiest* of the three to repair — the value
   * being replaced is a string npm generated, matched exactly, that has never
   * run a test in its life. It gets its own fix id rather than a flag, because
   * "add" and "overwrite what is there" are different promises and a person is
   * entitled to see which one they are pressing.
   */
  return check(
    'test-script',
    'Tests can be run with one command',
    'fail',
    detail,
    runner
      ? placeholder
        ? fixReplaceScript(runner)
        : fixAddScript('add-test-script', 'Add test script', runner)
      : null,
    false,
    'package.json',
  )
}

async function checkTypecheckScript(root: string, pkg: PackageJson | null): Promise<ReadinessCheck> {
  const hasTsconfig = await exists(root, 'tsconfig.json')
  const hasTypescript = pkg !== null && Boolean(pkg.deps.typescript)
  if (!hasTsconfig && !hasTypescript) {
    return check(
      'typecheck-script',
      'Types can be checked without building',
      'skip',
      'Not a TypeScript project.',
    )
  }
  if (pkg === null) {
    return check(
      'typecheck-script',
      'Types can be checked without building',
      'warn',
      'A tsconfig.json is present but there is no package.json to hang a typecheck script on.',
      null,
      false,
      'tsconfig.json',
    )
  }

  const found = scriptMatching(pkg.scripts, /^(typecheck|type-check|check-types|tsc)$/i, /tsc\b[^&|]*--noEmit/)
  if (found !== null) {
    return check(
      'typecheck-script',
      'Types can be checked without building',
      'pass',
      `\`npm run ${found}\` type-checks the project. That is the fastest signal an agent has that an edit is sound.`,
      null,
      false,
      'package.json',
    )
  }

  return check(
    'typecheck-script',
    'Types can be checked without building',
    'fail',
    'No typecheck script. An agent either runs a full build to find a type error — slow — or ships the error.',
    hasTypescript
      ? fixAddScript('add-typecheck-script', 'Add typecheck script', {
          script: 'typecheck',
          command: 'tsc --noEmit',
        })
      : null,
    false,
    'package.json',
  )
}

function checkLintScript(pkg: PackageJson | null): ReadinessCheck {
  if (pkg === null) {
    return check('lint-script', 'Lint or format check', 'skip', 'No package.json to look for a lint script in.')
  }

  const found = scriptMatching(
    pkg.scripts,
    /^(lint|format|fmt|check)$/i,
    /\b(eslint|biome|oxlint|prettier|standard)\b/,
  )
  if (found !== null) {
    return check(
      'lint-script',
      'Lint or format check',
      'pass',
      `\`npm run ${found}\` checks style, so generated code lands in your house style rather than the model's.`,
      null,
      false,
      'package.json',
    )
  }

  const linter = detectLinter(pkg.deps)
  return check(
    'lint-script',
    'Lint or format check',
    linter ? 'fail' : 'warn',
    linter
      ? 'A linter is installed but no script exposes it. An agent will not find it, so nothing it writes is checked.'
      : 'No lint or format script. Without one, every agent edit drifts a little further from your conventions and reviews get noisier.',
    linter ? fixAddScript('add-lint-script', 'Add lint script', linter) : null,
    false,
    'package.json',
  )
}

/* ---------------------------------------------------------------- git bits -- */

const FIX_CREATE_GITIGNORE: ReadinessFix = {
  id: 'create-gitignore',
  label: 'Create .gitignore',
  description:
    'Writes a .gitignore covering dependencies, build output, logs, editor and OS junk, and every common secret file — with .env.example still allowed through.',
  touches: ['.gitignore'],
  destructive: false,
}

const FIX_PATCH_GITIGNORE: ReadinessFix = {
  id: 'patch-gitignore',
  label: 'Add missing patterns',
  description:
    'Appends only the essential patterns your .gitignore is missing, under a comment saying where they came from. Existing lines are never edited or reordered.',
  touches: ['.gitignore'],
  destructive: false,
}

/** Patterns a .gitignore is expected to carry, given what the project is. */
async function essentialPatterns(root: string, pkg: PackageJson | null): Promise<string[]> {
  const wanted = ['.env']
  if (pkg !== null) wanted.push('node_modules')
  if (await exists(root, 'dist')) wanted.push('dist')
  if (await exists(root, 'build')) wanted.push('build')
  return wanted
}

async function checkGitignore(root: string, pkg: PackageJson | null): Promise<ReadinessCheck> {
  const rules = await readIgnoreRules(root)
  if (rules === null) {
    return check(
      'gitignore',
      '.gitignore covers the basics',
      'fail',
      'No .gitignore. Build output, dependencies and — worse — secrets are all one `git add .` from being committed, and agents run `git add .` constantly.',
      FIX_CREATE_GITIGNORE,
    )
  }

  const wanted = await essentialPatterns(root, pkg)
  const missing = wanted.filter((path) => !ignoreCovers(rules, path, path !== '.env'))
  if (missing.length === 0) {
    return check(
      'gitignore',
      '.gitignore covers the basics',
      'pass',
      `.gitignore has ${rules.length} rule${rules.length === 1 ? '' : 's'} and covers ${wanted.join(', ')}.`,
      null,
      false,
      '.gitignore',
    )
  }

  return check(
    'gitignore',
    '.gitignore covers the basics',
    'warn',
    `.gitignore does not cover ${missing.join(', ')}. Uncovered paths become noise in every diff an agent reads — and one of them is where credentials live.`,
    FIX_PATCH_GITIGNORE,
    false,
    '.gitignore',
  )
}

const FIX_GIT_INIT: ReadinessFix = {
  id: 'git-init',
  label: 'Initialise git',
  description:
    'Runs `git init` in the project folder. It creates a repository and commits nothing — no files are added, staged or changed.',
  touches: ['.git'],
  destructive: false,
}

async function checkGitRepo(root: string, gitDir: string | null): Promise<ReadinessCheck> {
  if (gitDir !== null) {
    return check(
      'git-repo',
      'Git repository initialised',
      'pass',
      'The project is a git repository, so an agent\'s work is reviewable and reversible.',
    )
  }
  return check(
    'git-repo',
    'Git repository initialised',
    'fail',
    'Not a git repository. Nothing an agent changes can be diffed, reviewed or undone — the single biggest safety net for AI-assisted work is missing.',
    (await exists(root, '.git')) ? null : FIX_GIT_INIT,
  )
}

/** Above this a dirty tree is no longer "a change in progress". */
const DIRTY_FAIL_FILES = 20

async function checkGitClean(root: string, gitDir: string | null): Promise<ReadinessCheck> {
  if (gitDir === null) {
    return check('git-clean', 'Working tree is reviewable', 'skip', 'Not a git repository.')
  }

  const status = await readGitStatus(root)
  if (!status.repo) {
    return check('git-clean', 'Working tree is reviewable', 'skip', status.message)
  }
  if (status.conflicted.length > 0) {
    return check(
      'git-clean',
      'Working tree is reviewable',
      'fail',
      `${status.conflicted.length} file${status.conflicted.length === 1 ? ' is' : 's are'} in a merge conflict. An agent editing around conflict markers makes the mess worse, not better.`,
    )
  }
  if (status.clean) {
    return check(
      'git-clean',
      'Working tree is reviewable',
      'pass',
      'Clean tree. Anything an agent changes from here shows up in `git diff` as its own work.',
    )
  }

  const dirty = new Set([
    ...status.staged.map((file) => file.path),
    ...status.unstaged.map((file) => file.path),
    ...status.untracked.map((file) => file.path),
  ]).size

  return check(
    'git-clean',
    'Working tree is reviewable',
    dirty > DIRTY_FAIL_FILES ? 'fail' : 'warn',
    `${dirty} uncommitted change${dirty === 1 ? '' : 's'} already in the tree. Commit or stash first, or an agent's diff arrives mixed into yours and neither can be reverted on its own.`,
  )
}

const FIX_CREATE_LOCKFILE: ReadinessFix = {
  id: 'create-lockfile',
  label: 'Generate the lockfile',
  /*
   * `--package-lock-only` is the whole reason this fix is safe enough to offer
   * behind one button. It resolves the dependency tree and writes the lockfile
   * and nothing else: no download of packages, no `node_modules`, no install
   * scripts from the registry running on somebody's machine at the press of a
   * button in a settings pane. `--ignore-scripts` is belt and braces on the
   * last of those.
   */
  description:
    'Works out the exact version of every dependency and writes package-lock.json. It does not download packages, create node_modules or run any install scripts — it needs the network to ask the registry, and it can take a minute on a large project.',
  touches: ['package-lock.json'],
  destructive: false,
}

const LOCKFILES = [
  'package-lock.json',
  'npm-shrinkwrap.json',
  'yarn.lock',
  'pnpm-lock.yaml',
  'bun.lockb',
  'bun.lock',
]

async function checkLockfile(root: string, pkg: PackageJson | null): Promise<ReadinessCheck> {
  if (pkg === null) {
    if (await exists(root, 'Cargo.toml')) {
      const locked = await exists(root, 'Cargo.lock')
      return check(
        'lockfile',
        'Dependencies are pinned',
        locked ? 'pass' : 'warn',
        locked ? 'Cargo.lock pins the dependency graph.' : 'Cargo.toml with no Cargo.lock.',
      )
    }
    return check('lockfile', 'Dependencies are pinned', 'skip', 'No package manifest to lock.')
  }

  for (const name of LOCKFILES) {
    if (await exists(root, name)) {
      return check(
        'lockfile',
        'Dependencies are pinned',
        'pass',
        `${name} pins the dependency graph, so an agent running an install gets what you have.`,
      )
    }
  }

  return check(
    'lockfile',
    'Dependencies are pinned',
    'warn',
    npmIsTheManager(pkg)
      ? 'No lockfile. An agent that runs an install can pull different versions than you have, and the failure it then debugs is not the one you would see.'
      : `No lockfile, and package.json declares ${pkg.packageManager ?? 'another package manager'} — so generating one is that tool's job, not this app's. Run its install once and commit the file it writes.`,
    npmIsTheManager(pkg) ? FIX_CREATE_LOCKFILE : null,
  )
}

/* ------------------------------------------------------------------- scan -- */

/**
 * A check that threw is reported, never swallowed and never silently passed.
 *
 * For an ordinary check that means 'skip' — it scored nothing and leaves the
 * denominator. For the *gate* it cannot: dropping the gate out of the report
 * takes the cap with it, so a permissions error while looking for credentials
 * would hand a leaking repository a clean 100. A gate that could not run is
 * unverified, and unverified is treated as a warning.
 */
export function failedCheck(
  id: ReadinessCheckId,
  title: string,
  error: unknown,
  gate = false,
): ReadinessCheck {
  const message = error instanceof Error ? error.message : String(error)
  return gate
    ? check(
        id,
        title,
        'warn',
        `This check could not run: ${message}. Until it can, this project is unverified and cannot be scored as safe.`,
        null,
        true,
      )
    : check(id, title, 'skip', `This check could not run: ${message}`)
}

async function guard(
  id: ReadinessCheckId,
  title: string,
  fn: () => Promise<ReadinessCheck>,
  gate = false,
): Promise<ReadinessCheck> {
  try {
    return await fn()
  } catch (error) {
    return failedCheck(id, title, error, gate)
  }
}

/**
 * Run every check against a project. Reads only — no fix ever runs from here,
 * however bad the finding.
 */
export async function scanReadiness(projectPath: string): Promise<ReadinessReport> {
  const root = projectPath
  const gitDir = await findGitDir(root)
  const [pkg, tracked] = await Promise.all([
    readPackageJson(root),
    gitDir === null ? Promise.resolve(null) : trackedFiles(root),
  ])

  const checks = await Promise.all([
    guard('secrets', 'No secrets committed', () => checkSecrets(root, tracked), true),
    guard('claude-md', AGENT_INSTRUCTIONS_TITLE, () => checkInstructions(root, null)),
    guard('test-script', 'Tests can be run with one command', () => checkTestScript(root, pkg)),
    guard('git-repo', 'Git repository initialised', () => checkGitRepo(root, gitDir)),
    guard('gitignore', '.gitignore covers the basics', () => checkGitignore(root, pkg)),
    guard('readme', 'README for humans', () => checkReadme(root)),
    guard('typecheck-script', 'Types can be checked without building', () =>
      checkTypecheckScript(root, pkg),
    ),
    guard('git-clean', 'Working tree is reviewable', () => checkGitClean(root, gitDir)),
    guard('lint-script', 'Lint or format check', async () => checkLintScript(pkg)),
    guard('lockfile', 'Dependencies are pinned', () => checkLockfile(root, pkg)),
  ])

  /*
   * The same project, once per agent — one instructions check swapped, the rest
   * of the list shared, the score re-run over the swap.
   *
   * Re-running `scoreChecks` rather than adjusting the number is what keeps the
   * ring and the rows telling one story: the weights, the gate and the caps are
   * all in that one function, and a second arithmetic here would be the second
   * copy that eventually disagrees. It costs nothing — the reads are already
   * done, and each variant is one more pass over ten objects.
   */
  const agents = await Promise.all(
    INSTRUCTIONS_AGENTS.map(async (entry) => {
      const check = await guard('claude-md', AGENT_INSTRUCTIONS_TITLE, () =>
        checkInstructions(root, entry),
      )
      const swapped = checks.map((existing) => (existing.id === 'claude-md' ? check : existing))
      const scored = scoreChecks(swapped)
      return {
        agent: entry.agent,
        label: AGENT_CATALOG[entry.agent].label,
        file: entry.file,
        check,
        score: scored.score,
        band: scored.band,
        cappedBy: scored.cappedBy,
      }
    }),
  )

  const { score, band, cappedBy } = scoreChecks(checks)
  return {
    projectPath: root,
    score,
    band,
    checks,
    cappedBy,
    agents,
    scannedAt: new Date().toISOString(),
  }
}

/* ------------------------------------------------------------------ fixes -- */

/**
 * The skeleton the instructions fix writes, titled with the file's own name.
 *
 * A function rather than a constant since 2026-08-21, because there are three
 * files now and a Markdown document titles itself with its own filename — the
 * convention every one of these follows. It is also read the other way round:
 * `isUnfilledSkeleton` compares a file on disk against the template for *that*
 * file, so a `GEMINI.md` full of nothing but headings is recognised as the
 * skeleton this app wrote rather than graded as somebody's real instructions.
 *
 * Everything below the title is identical for all three. What an agent needs to
 * be told about a repository is not a property of which agent it is.
 */
function instructionsTemplate(file: string): string {
  return `# ${file}

Instructions for an AI agent working in this repository.

## What this is

<!-- One paragraph: what the project does and who it is for. -->

## Run it

\`\`\`sh
# install
# start
\`\`\`

## Test it

\`\`\`sh
# the exact command that proves a change is sound
\`\`\`

## Layout

<!-- The three or four directories that matter, and what lives in each. -->

## Conventions

<!-- Style, naming and patterns you actually enforce in review. -->

## Do not

<!-- Files, directories or commands an agent must leave alone. -->
`
}

function readmeTemplate(name: string): string {
  return `# ${name}

<!-- One line: what this is. -->

## Install

\`\`\`sh
# install command
\`\`\`

## Run

\`\`\`sh
# run command
\`\`\`

## Test

\`\`\`sh
# test command
\`\`\`
`
}

const GITIGNORE_TEMPLATE = `# Dependencies
node_modules/

# Build output
dist/
build/
out/
*.tsbuildinfo

# Logs
*.log
npm-debug.log*

# Editor and OS
.DS_Store
.idea/
.vscode/*
!.vscode/extensions.json

# Secrets — never commit these
${SECRET_IGNORE_PATTERNS.join('\n')}
`

const TERMINALDECK_BLOCK_HEADER = '# added by Deck — AI readiness'

/** Paths per `git rm` invocation, to stay well inside the OS argument limit. */
const RM_BATCH = 100

/** Said after writing a skeleton, so nobody mistakes one for real context. */
const TEMPLATE_NOTE = 'Fill in the placeholders — a skeleton is a starting point, not context.'

function ok(message: string, changed: string[]): ReadinessFixResult {
  return { ok: true, message, changed }
}

function refuse(message: string): ReadinessFixResult {
  return { ok: false, message, changed: [] }
}

/**
 * Create a file, refusing rather than overwriting.
 *
 * `wx` makes that refusal atomic: a check-then-write would leave a window in
 * which a file that appeared in between gets clobbered, and clobbering a
 * CLAUDE.md someone was mid-way through writing is exactly the surprise a
 * one-click fix must never produce.
 */
async function createFile(
  root: string,
  relPath: string,
  body: string,
  note = '',
): Promise<ReadinessFixResult> {
  const target = safeJoin(root, relPath)
  try {
    await writeFile(target, body, { encoding: 'utf8', flag: 'wx' })
    return ok(`Created ${relPath}.${note ? ` ${note}` : ''}`, [relPath])
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      return refuse(`${relPath} already exists — nothing was changed.`)
    }
    throw error
  }
}

/**
 * A concrete path the pattern would match, so "is this already covered?" can be
 * asked of the existing rules rather than compared as strings — `.env` and
 * `.env*` are different lines that cover the same file.
 */
export function samplePathFor(pattern: string): { path: string; isDir: boolean } {
  const isDir = pattern.endsWith('/')
  const body = (isDir ? pattern.slice(0, -1) : pattern).replace(/^!/, '')
  return { path: body.replace(/\*\*\//g, '').replace(/\*/g, 'x') || 'x', isDir }
}

/**
 * Which of `patterns` this .gitignore does not already cover, as the block that
 * should be appended to it.
 *
 * Split out and exported because the ordering rule is the whole subtlety here.
 * Git resolves competing patterns by *last match wins*, so a negation is only
 * worth what follows it. Appending `.env.*` to a file that already says
 * `!.env.example` higher up starts ignoring `.env.example` — the exact file the
 * fix promises to keep. The negations in the set are therefore re-stated after
 * the appended block whenever the block would otherwise swallow them, even
 * though an identical line exists earlier in the file.
 */
export function ignoreBlockFor(existing: string, patterns: string[]): string[] {
  const lines = new Set(existing.split(/\r?\n/).map((line) => line.trim()))
  // Grows as the block is built, so a pattern already covered by an *earlier
  // line of this same block* is dropped too. Without that, untracking 250 keys
  // under one folder appends 250 lines that `*.pem` two rows above already
  // covers.
  const rules = parseIgnoreFile(existing)
  const additions: string[] = []

  for (const pattern of patterns) {
    if (pattern.startsWith('!')) continue
    if (lines.has(pattern)) continue
    const sample = samplePathFor(pattern)
    if (ignoreCovers(rules, sample.path, sample.isDir)) continue
    additions.push(pattern)
    const rule = compileIgnorePattern(pattern)
    if (rule) rules.push(rule)
  }

  // Nothing new to ignore means nothing to re-protect either: a lone negation
  // would change the file for no reason.
  if (additions.length === 0) return []

  const restated = patterns.filter((pattern) => {
    if (!pattern.startsWith('!')) return false
    const sample = samplePathFor(pattern)
    return ignoreCovers(rules, sample.path, sample.isDir)
  })

  return [...additions, ...restated]
}

/**
 * A .gitignore line matching exactly one path and nothing else.
 *
 * The leading slash anchors it to the project root, which also disarms a name
 * beginning `!` or `#` — those are a negation and a comment at the start of a
 * line, and a file really can be called `#notes.pem`. Glob characters in the
 * name are escaped so `keys/[old].pem` cannot quietly become a character class,
 * and a trailing space is escaped because git strips unescaped ones.
 */
export function anchoredIgnoreLine(relPath: string): string {
  const escaped = relPath.replace(/[\\*?[\]]/g, (char) => `\\${char}`)
  return `/${escaped.replace(/ $/, '\\ ')}`
}

/** Append the patterns a .gitignore is missing, creating the file if needed. */
async function appendIgnorePatterns(root: string, patterns: string[]): Promise<ReadinessFixResult> {
  const existing = await readTextAt(root, '.gitignore')
  // A file that does not exist yet is an empty one for the purposes of working
  // out the block — it must still be de-duplicated against itself.
  const block = ignoreBlockFor(existing ?? '', patterns)
  if (block.length === 0) return refuse('.gitignore already covers all of these — nothing was changed.')

  if (existing === null) {
    return createFile(root, '.gitignore', `${TERMINALDECK_BLOCK_HEADER}\n${block.join('\n')}\n`)
  }

  const separator = existing.endsWith('\n') ? '' : '\n'
  await writeFile(
    safeJoin(root, '.gitignore'),
    `${existing}${separator}\n${TERMINALDECK_BLOCK_HEADER}\n${block.join('\n')}\n`,
    'utf8',
  )
  return ok(`Added ${block.length} pattern${block.length === 1 ? '' : 's'} to .gitignore.`, ['.gitignore'])
}

/** Indent width the file already uses, so a fix does not reformat it. */
export function detectJsonIndent(text: string): string {
  const match = /\n([ \t]+)"/.exec(text)
  return match ? match[1] : '  '
}

/**
 * Add one script to package.json.
 *
 * The file is re-parsed and re-serialised rather than patched textually: a
 * regex insertion into JSON that already has a scripts block is the kind of
 * clever that eventually eats someone's manifest.
 *
 * `over` is the one value this is allowed to overwrite, and it exists so that
 * "replace npm's placeholder" can share every line of this function while still
 * being unable to touch anything else. Undefined means the ordinary promise:
 * refuse if the key is taken.
 */
async function addScript(
  root: string,
  runner: ScriptRunner,
  over?: RegExp,
): Promise<ReadinessFixResult> {
  const pkg = await readPackageJson(root)
  if (pkg === null) return refuse('package.json is missing or unreadable — nothing was changed.')
  const existing = pkg.scripts[runner.script]
  if (existing !== undefined && !(over !== undefined && over.test(existing))) {
    return refuse(`package.json already defines a "${runner.script}" script — nothing was changed.`)
  }

  const parsed = JSON.parse(pkg.raw) as Record<string, unknown>
  const scripts = { ...stringMap(parsed.scripts), [runner.script]: runner.command }
  const next = { ...parsed, scripts }
  const indent = detectJsonIndent(pkg.raw)
  const trailing = pkg.raw.endsWith('\n') ? '\n' : ''

  await writeFile(safeJoin(root, 'package.json'), `${JSON.stringify(next, null, indent)}${trailing}`, 'utf8')
  return ok(
    existing === undefined
      ? `Added "${runner.script}": "${runner.command}" to package.json.`
      : `Replaced the placeholder with "${runner.script}": "${runner.command}" in package.json.`,
    ['package.json'],
  )
}

/* ------------------------------------------------------- running a tool -- */

/** What a spawned tool did, whether or not it succeeded. */
export interface ToolRun {
  ok: boolean
  output: string
}

/**
 * Anything that can run a command line tool.
 *
 * The seam exists for one reason and it is not tidiness: without it, a test of
 * the upgrade path upgrades the machine the test is running on. That happened
 * once here — a first draft of `readiness.test.ts` moved this machine's agent
 * CLI from 0.32.1 to 0.46.0 while asserting that the channel dispatched — and a
 * suite with a side effect that large is a suite nobody can run twice.
 */
export type ToolRunner = (
  command: string,
  args: string[],
  options: { cwd?: string; timeout: number },
) => Promise<ToolRun>

/**
 * Run a command line tool and keep what it said, including when it failed.
 *
 * The output matters on the failure path more than on the success path, and
 * `execFile` hides it there: a non-zero exit, and a timeout in particular,
 * arrives as a thrown `Error` carrying `stdout` and `stderr` as properties of
 * the error rather than as a resolved value. Code that only reads the resolved
 * value turns "npm said EACCES on /usr/local/lib" into "Command failed", which
 * is the difference between a person fixing their own machine and a person
 * filing a bug. This app has already shipped that mistake once, in a place where
 * a package manager's prompt was reported as a fifteen-second hang.
 *
 * ## Why the command goes through `launchSpec`
 *
 * Every command this runner is ever handed is a package manager or an agent
 * CLI, and on Windows all three of them — `npm`, `npx`, `gemini` — are `.cmd`
 * shims, not executables. Node has refused to spawn a `.cmd` or `.bat` without
 * `shell: true` since 18.20.2/20.12.2, deliberately, as the fix for
 * CVE-2024-27980: `execFile` throws EINVAL before a process is created. This
 * function's `catch` is written for a tool that ran and failed, so it turned
 * that into `{ ok: false, output: 'spawn npm EINVAL' }` — every fix that shells
 * out silently did nothing on Windows and reported a sentence naming no cause.
 * `tool-probe.ts:launchSpec` is the one place the shim rule and its quoting
 * live; `prerequisites.ts:version` and `usage-probe.ts` route through it for
 * exactly this, and this runner was the one that did not.
 *
 * `resolved` is null because no lookup has been paid for here — which is the
 * safe end of `launchSpec`'s contract anyway: with nothing resolved it takes
 * the command processor, and cmd runs a shim and a real `.exe` alike.
 */

/** Everything about a tool spawn except the spawning, so it can be read here. */
export interface ToolSpawn {
  /** The `file` argument for `execFile`. Already quoted when `shell` is set. */
  file: string
  spawn: {
    cwd?: string
    timeout: number
    maxBuffer: number
    windowsHide: boolean
    shell: boolean
    env: Record<string, string | undefined>
  }
}

/**
 * The shape of the spawn, worked out without performing it.
 *
 * Pure and exported for one reason: the Windows half of this decision cannot be
 * observed on the machine this repo is written on, and a test that reaches it
 * by actually spawning `npm.cmd` would need a Windows PC — which is the whole
 * problem. Splitting the decision from the act lets both spellings be pinned in
 * one run on a Mac, which is the same technique `platform/lookup.ts` and
 * `tool-probe.ts:launchSpec` already use.
 */
export function toolSpawn(
  command: string,
  PATH: string,
  options: { cwd?: string; timeout: number },
  platform: Platform = currentPlatform(),
): ToolSpawn {
  const launch = launchSpec(command, null, platform)
  return {
    file: launch.command,
    spawn: {
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      timeout: options.timeout,
      maxBuffer: MAX_BUFFER,
      windowsHide: true,
      shell: launch.shell,
      // `withPath`, not `{ ...process.env, PATH }`: the literal key leaves a
      // Windows child holding both `Path` and `PATH` and no defined answer to
      // which it reads. See `platform/host.ts`.
      env: { ...withPath(process.env, PATH, platform), LC_ALL: 'C' },
    },
  }
}

async function runTool(
  command: string,
  args: string[],
  options: { cwd?: string; timeout: number },
  platform: Platform = currentPlatform(),
): Promise<ToolRun> {
  const PATH = await loginPath(platform)
  const { file, spawn } = toolSpawn(command, PATH, options, platform)
  try {
    const { stdout, stderr } = await run(file, args, spawn)
    return { ok: true, output: `${stdout}${stderr}`.trim() }
  } catch (error) {
    const carried = error as { stdout?: string; stderr?: string; message?: string }
    const said = `${carried.stdout ?? ''}${carried.stderr ?? ''}`.trim()
    return { ok: false, output: said === '' ? (carried.message ?? '') : said }
  }
}

/**
 * The one line of a tool's output worth putting on a row.
 *
 * Its *diagnosis*, preferred over its last words, and the difference showed up
 * the first time this was looked at on screen. Pressing Upgrade on a machine
 * that was already current printed "✔︎ JSON API packages.arm64_golden_gate.
 * jws.json Warning: gemini-cli 0.46.0 already installed" — the tail of the
 * output was two lines, and the first of them was a progress tick from a
 * download that had nothing to do with the answer. The sentence a person needs
 * is the one the tool prefixed as a warning or an error, wherever in the stream
 * it landed; the last line is the fallback for a tool that prefixes nothing.
 */
export function toolMessage(output: string): string {
  const lines = output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== '')
  if (lines.length === 0) return ''
  const diagnosis = [...lines]
    .reverse()
    .find((line) => /^(error|warning|fatal|npm err!)\b/i.test(line))
  return diagnosis ?? lines[lines.length - 1]
}

/* -------------------------------------------------------------- lockfile -- */

/** Long enough for a cold registry resolve on a big tree, short enough to end. */
const LOCKFILE_TIMEOUT_MS = 5 * 60 * 1000

async function createLockfile(root: string): Promise<ReadinessFixResult> {
  const pkg = await readPackageJson(root)
  if (pkg === null) return refuse('package.json is missing or unreadable — nothing was changed.')
  if (!npmIsTheManager(pkg)) {
    return refuse(
      `package.json declares ${pkg.packageManager ?? 'another package manager'}, so this would write the wrong kind of lockfile — nothing was changed.`,
    )
  }
  for (const name of LOCKFILES) {
    if (await exists(root, name)) return refuse(`${name} is already here — nothing was changed.`)
  }

  const result = await runTool('npm', ['install', '--package-lock-only', '--ignore-scripts'], {
    cwd: root,
    timeout: LOCKFILE_TIMEOUT_MS,
  })
  // Asked of the disk rather than of the exit code. npm can exit 0 having
  // decided there was nothing to resolve, and a message claiming a file that is
  // not there is worse than the missing file was.
  if (!(await exists(root, 'package-lock.json'))) {
    const said = toolMessage(result.output)
    return refuse(
      said === ''
        ? 'The resolve did not produce a lockfile — nothing was changed.'
        : `No lockfile was written. npm said: ${said}`,
    )
  }
  return ok('Wrote package-lock.json. Commit it — that is what makes it a pin.', ['package-lock.json'])
}

/* ----------------------------------------------------- the agent CLI --- */

/**
 * The one agent CLI on this machine whose own server turns it away when it is
 * out of date, and the two routes people install it by.
 *
 * These are identifiers, not copy. Which CLI it is, what it is measured
 * against, and the sentence a person reads about it all live in
 * `browser-signin.ts`, which owns that subject and records what was run on this
 * machine on 2026-08-18 to establish it. What lives here is only the *act* —
 * because this module owns the one channel the renderer already has that can
 * run something, and a button that copies a command for somebody to paste into
 * a terminal is not an answer for the people this app is for.
 *
 * The route is asked, never assumed. Telling somebody on one package manager to
 * upgrade through the other produces either a failure or, worse, a second copy
 * of the tool further down the PATH than the one that is actually running — at
 * which point the version reads the same afterwards and the app looks broken
 * rather than the advice.
 */
const AGENT_CLI = 'gemini'
const AGENT_CLI_FORMULA = 'gemini-cli'
const AGENT_CLI_PACKAGE = '@google/gemini-cli'

/** A package manager knows about it; there is no third answer worth guessing. */
export type UpgradeRoute = 'brew' | 'npm' | null

/** Detection is quick or it is not an answer — this is two `list` calls. */
const ROUTE_TIMEOUT_MS = 20 * 1000
/**
 * Ten minutes, because one of the two routes updates its whole formula index
 * before it upgrades anything and that is a git fetch of a large repository on
 * a slow morning. Leaving auto-update on is deliberate: with it off, the
 * upgrade consults a stale local index, finds nothing newer, exits 0, and the
 * person is told they are up to date while the sign-in keeps failing.
 */
const UPGRADE_TIMEOUT_MS = 10 * 60 * 1000

/**
 * How this machine installed the CLI, asked of the package managers themselves.
 *
 * Split out and exported so the branch can be tested with an injected runner:
 * the interesting case is a machine where *neither* manager claims it, which is
 * a real state — a manual install, a version manager, a vendored copy — and the
 * only honest thing to do there is to refuse and say so rather than run
 * something and hope.
 */
export async function upgradeRouteFor(
  exec: ToolRunner = runTool,
  platform: Platform = currentPlatform(),
): Promise<UpgradeRoute> {
  const probe = (command: string, args: string[]): Promise<ToolRun> =>
    exec(command, args, { timeout: ROUTE_TIMEOUT_MS })
  // Homebrew is not a Windows package manager, and there is no supported way to
  // put one on a Windows PC. Probing for it there is not merely a wasted spawn:
  // this runs on a click, `ROUTE_TIMEOUT_MS` is twenty seconds, and a failed
  // `brew` lookup is the *first* thing between the button and the answer — so
  // on Windows the route detection paid a spawn for a program that cannot
  // exist before it asked the one that can. Skipping it is not a reduction; the
  // brew branch has no reachable case on that platform at all.
  if (!isWindows(platform)) {
    if ((await probe('brew', ['list', '--formula', '--versions', AGENT_CLI_FORMULA])).ok) {
      return 'brew'
    }
  }
  if ((await probe('npm', ['ls', '-g', '--depth=0', AGENT_CLI_PACKAGE])).ok) return 'npm'
  return null
}

/** What a route runs, in one place, so the message and the act cannot differ. */
export function upgradeCommandFor(route: Exclude<UpgradeRoute, null>): {
  command: string
  args: string[]
} {
  return route === 'brew'
    ? { command: 'brew', args: ['upgrade', AGENT_CLI_FORMULA] }
    : { command: 'npm', args: ['install', '-g', `${AGENT_CLI_PACKAGE}@latest`] }
}

/**
 * What to say when neither package manager claims the CLI.
 *
 * This is the refusal a person is most likely to read, because it is the one
 * that fires on every machine that installed the tool some third way. It used
 * to name `brew upgrade gemini-cli` first, unconditionally — so a Windows user
 * who pressed Upgrade was refused and then told to run a command that does not
 * exist on their PC, cannot be made to exist on their PC, and is listed ahead
 * of the one that would have worked. That is worse than saying nothing: it
 * reads as the app being written for somebody else's computer, which is exactly
 * the impression the port is meant to remove.
 *
 * The npm line is identical on both platforms — the Homebrew formula and the
 * npm package are the same CLI — so Windows loses a route that does not exist
 * and gains nothing invented. No winget or choco line is offered because
 * nobody here has checked that the package is published under those, and a
 * confidently wrong command is the thing being fixed.
 *
 * Pure and exported so both sentences can be pinned from a Mac.
 */
export function noRouteAdvice(platform: Platform = currentPlatform()): string {
  const opening =
    'Neither package manager on this machine claims that agent, so upgrading it is not something this app can do for you.'
  const npm = `\`npm install -g ${AGENT_CLI_PACKAGE}@latest\``
  if (isWindows(platform)) {
    return `${opening} Run ${npm} in your own terminal.`
  }
  return `${opening} Run \`brew upgrade ${AGENT_CLI_FORMULA}\` or ${npm} in your own terminal, whichever matches how you installed it.`
}

/** What the CLI answers `--version` with, or null when it will not say. */
async function agentCliVersion(exec: ToolRunner): Promise<string | null> {
  const result = await exec(AGENT_CLI, ['--version'], { timeout: ROUTE_TIMEOUT_MS })
  if (!result.ok) return null
  const match = /(\d+\.\d+\.\d+)/.exec(result.output)
  return match ? match[1] : null
}

/**
 * Upgrade the agent CLI, and report what actually changed.
 *
 * The version is read before and after, from the binary rather than from the
 * package manager, because those two can disagree — an upgrade that installs a
 * new copy somewhere the PATH does not reach succeeds by every measure the
 * package manager has and leaves the person exactly where they were. Comparing
 * what the command *answers* is the only measurement that matches what breaks.
 */
export async function upgradeAgentCli(
  exec: ToolRunner = runTool,
  platform: Platform = currentPlatform(),
): Promise<ReadinessFixResult> {
  const before = await agentCliVersion(exec)
  if (before === null) {
    return refuse('That agent is not installed on this machine, so there is nothing to upgrade here.')
  }

  const route = await upgradeRouteFor(exec, platform)
  if (route === null) {
    return refuse(noRouteAdvice(platform))
  }

  const { command, args } = upgradeCommandFor(route)
  const result = await exec(command, args, { timeout: UPGRADE_TIMEOUT_MS })
  const after = await agentCliVersion(exec)

  if (after !== null && after !== before) {
    return ok(`Upgraded from ${before} to ${after}. Sign in again and it should hold.`, [])
  }
  const said = toolMessage(result.output)
  return refuse(
    `It still reports ${before} afterwards, so nothing moved.${said === '' ? '' : ` The upgrade said: ${said}`}`,
  )
}

/**
 * Apply one fix, by id, on explicit request.
 *
 * Every fix re-derives its own facts first. The report the button was rendered
 * from may be minutes old — the user may have created the file by hand, or
 * committed the very secret we are about to untrack — and acting on a stale
 * finding is how a "fix" becomes damage.
 */
export async function applyReadinessFix(
  projectPath: string,
  fixId: ReadinessFixId,
): Promise<ReadinessFixResult> {
  const root = projectPath

  switch (fixId) {
    /*
     * Three ids, one body of work, and the file each writes comes from the same
     * table the check searched — so a button that says it will create a file
     * and the file that appears cannot be two different names.
     */
    case 'create-claude-md':
    case 'create-agents-md':
    case 'create-gemini-md': {
      const entry = INSTRUCTIONS_AGENTS.find((candidate) => candidate.fixId === fixId)
      // Unreachable while the table covers every id in the union above, and
      // `readiness.test.ts` pins that. Refusing rather than asserting keeps a
      // future fourth agent's half-wired id from writing an empty-named file.
      if (!entry) return refuse('This build does not know which file that would create.')
      return createFile(root, entry.file, instructionsTemplate(entry.file), TEMPLATE_NOTE)
    }

    case 'create-readme':
      return createFile(root, 'README.md', readmeTemplate(basenameOf(root)), TEMPLATE_NOTE)

    case 'create-gitignore':
      return (await readTextAt(root, '.gitignore')) === null
        ? createFile(root, '.gitignore', GITIGNORE_TEMPLATE)
        : refuse('.gitignore already exists — use "Add missing patterns" instead.')

    case 'patch-gitignore': {
      const pkg = await readPackageJson(root)
      const wanted = await essentialPatterns(root, pkg)
      // '.env' is expanded to the full secret set: adding the one pattern that
      // was measured would leave .env.local exposed a line below it.
      const patterns = wanted.flatMap((entry) =>
        entry === '.env' ? SECRET_IGNORE_PATTERNS : [`${entry}/`],
      )
      return appendIgnorePatterns(root, patterns)
    }

    case 'ignore-secrets':
      return appendIgnorePatterns(root, SECRET_IGNORE_PATTERNS)

    case 'git-init': {
      if ((await findGitDir(root)) !== null) return refuse('This folder is already a git repository.')
      await git(root, ['init'], { write: true })
      return ok('Initialised an empty git repository. Nothing was staged or committed.', ['.git'])
    }

    case 'untrack-secrets': {
      const tracked = await trackedFiles(root)
      if (tracked === null) return refuse('git could not list this folder — nothing was changed.')
      // Derived here, never taken from the caller: this argument list is fed
      // straight to `git rm`, so it must not be reachable from the renderer.
      const secrets = await secretPathsAmong(root, tracked)
      if (secrets.length === 0) return refuse('git is no longer tracking any secret files.')

      // The standard patterns do not cover every shape this scan detects —
      // `credentials.json`, a tokened `.npmrc`, a stray `keys/app.jks`. Without
      // a line naming those, `git rm --cached` is undone by the very next
      // `git add .`, which is worse than useless: it *looks* fixed.
      const ignored = await appendIgnorePatterns(root, [
        ...SECRET_IGNORE_PATTERNS,
        ...secrets.map(anchoredIgnoreLine),
      ])

      // Batched: a repo that committed a whole `.ssh` directory can produce
      // more paths than the OS will accept in one argument list.
      for (let i = 0; i < secrets.length; i += RM_BATCH) {
        await git(root, ['rm', '--cached', '--quiet', '--', ...secrets.slice(i, i + RM_BATCH)], {
          write: true,
        })
      }
      return ok(
        `Untracked ${secrets.length} file${secrets.length === 1 ? '' : 's'} and ignored ${secrets.length === 1 ? 'it' : 'them'}. The files are still on disk. They remain in every past commit — rotate those credentials.`,
        [...(ignored.ok ? ['.gitignore'] : []), ...secrets],
      )
    }

    case 'add-test-script': {
      const pkg = await readPackageJson(root)
      const runner = pkg && detectTestRunner(pkg.deps)
      if (!runner) return refuse('No test runner found in the dependencies — nothing was changed.')
      return addScript(root, runner)
    }

    case 'replace-test-script': {
      const pkg = await readPackageJson(root)
      const runner = pkg && detectTestRunner(pkg.deps)
      if (!runner) return refuse('No test runner found in the dependencies — nothing was changed.')
      // The pattern is the promise: this may overwrite npm's placeholder and
      // nothing else, so a script written by a person is refused here rather
      // than by the caller remembering to check.
      return addScript(root, runner, PLACEHOLDER_TEST_RE)
    }

    case 'create-lockfile':
      return createLockfile(root)

    case 'upgrade-agent-cli':
      // Nothing to do with `root`. See `MACHINE_FIX_IDS`.
      return upgradeAgentCli()

    case 'add-typecheck-script': {
      const pkg = await readPackageJson(root)
      if (!pkg?.deps.typescript) return refuse('TypeScript is not a dependency here — nothing was changed.')
      return addScript(root, { script: 'typecheck', command: 'tsc --noEmit' })
    }

    case 'add-lint-script': {
      const pkg = await readPackageJson(root)
      const linter = pkg && detectLinter(pkg.deps)
      if (!linter) return refuse('No linter found in the dependencies — nothing was changed.')
      return addScript(root, linter)
    }

    default:
      return refuse('Unknown fix.')
  }
}

function basenameOf(path: string): string {
  const trimmed = path.replace(/[/\\]+$/, '')
  const cut = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'))
  return cut === -1 ? trimmed : trimmed.slice(cut + 1)
}

/* -------------------------------------------------------------------- ipc -- */

const FIX_IDS: ReadonlySet<string> = new Set<ReadinessFixId>([
  'create-claude-md',
  'create-readme',
  'create-gitignore',
  'patch-gitignore',
  'git-init',
  'ignore-secrets',
  'untrack-secrets',
  'add-test-script',
  'replace-test-script',
  'add-typecheck-script',
  'add-lint-script',
  'create-lockfile',
  'upgrade-agent-cli',
])

function asProjectPath(value: unknown): string | null {
  if (typeof value !== 'string' || value === '' || value.includes('\0')) return null
  return isAbsolute(value) ? value : null
}

/**
 * Wire the readiness channels. One call from the main process:
 *
 *     import { registerReadinessIpc } from './readiness'
 *     registerReadinessIpc(ipcMain)
 *
 * Channels:
 *  - `readiness:scan` (invoke, projectPath)        → ReadinessReport
 *  - `readiness:fix`  (invoke, projectPath, fixId) → ReadinessFixResult
 *
 * The fix channel takes an id from a closed set, never a command, a path or a
 * patch: the renderer chooses *which* described action to run, and this module
 * owns what that action actually does.
 */
export function registerReadinessIpc(ipcMain: Electron.IpcMain): void {
  ipcMain.handle('readiness:scan', async (_event, projectPath: unknown) => {
    const root = asProjectPath(projectPath)
    if (root === null) throw new Error('readiness: an absolute project path is required')
    return scanReadiness(root)
  })

  ipcMain.handle('readiness:fix', async (_event, projectPath: unknown, fixId: unknown) => {
    if (typeof fixId !== 'string' || !FIX_IDS.has(fixId)) {
      return refuse('That fix is not one this version knows how to apply.')
    }
    const id = fixId as ReadinessFixId
    // The id is checked first, and the *machine* fixes are answered before the
    // path is: they are about this computer rather than about a folder, so the
    // caller has no project to name and sending a made-up one would be worse
    // than sending none. Every other fix still needs a real absolute path and
    // is refused without one. See `MACHINE_FIX_IDS`.
    const root = MACHINE_FIX_IDS.has(id) ? '' : asProjectPath(projectPath)
    if (root === null) throw new Error('readiness: an absolute project path is required')
    try {
      return await applyReadinessFix(root, id)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return refuse(`The fix could not be applied: ${message}`)
    }
  })
}
