/**
 * Multiple agent profiles — separate agent logins running side by side.
 *
 * An agent CLI keeps everything about "who you are" inside one config
 * directory, and each of them has a variable that moves that directory. Point
 * two sessions at two directories and they are two different logins: separate
 * accounts, separate history, separate transcripts.
 *
 * **An account belongs to one agent.** That is newer than the rest of this file
 * and it is the reason `Profile` carries a `provider`: `CLAUDE_CONFIG_DIR` and
 * `CODEX_HOME` are two different directories holding two different file
 * layouts, and a directory full of Codex's `auth.json` handed to Claude Code is
 * not a login, it is a broken session. Which agents have a mechanism at all,
 * which of those move the *login* rather than only the configuration, and how
 * each one was measured is in `provider-accounts.ts` — this module owns the
 * list, the directories and the precedence, and asks that one for the rest.
 * Gemini is deliberately refused there; the reason is written out in full.
 *
 * Verified on this machine against the real CLI (2.1.206), because every part
 * of this is the kind of thing that is easy to assume and wrong:
 *
 * 1. `CLAUDE_CONFIG_DIR=<fresh dir> claude config ls` reports "Not logged in"
 *    while the same command without it is logged in. Isolation is real.
 * 2. It creates `.claude.json`, `projects/`, `sessions/` and `backups/` inside
 *    that directory. Transcripts move with it — see `transcriptDir()`.
 * 3. **On macOS**, credentials live in the login Keychain, not in the directory,
 *    and the Keychain service name carries a suffix derived from the config dir:
 *    `Claude Code-credentials` for the default, `Claude Code-credentials-<hex>`
 *    for a custom one. Both exist on this machine. So logging into a second
 *    profile cannot overwrite the first one's token — and, the other way
 *    round, deleting a profile's directory does NOT log it out.
 *
 *    That paragraph is a statement about macOS and nothing else. Point 1 — the
 *    part that makes profiles work at all — is an environment variable and is
 *    not platform-specific; point 3 is about where a program this app does not
 *    own puts its secrets, and it has never been checked anywhere but here.
 *    `platform/credential-store.ts` says which platforms it is claimed for,
 *    `profileStatus` reports that per profile, and Windows gets an honest "not
 *    established" rather than a copy of the sentence above. It also explains why
 *    Electron's `safeStorage` is not a fix for it: this app never holds the
 *    credential, so there is nothing here for DPAPI to protect.
 * 4. **Setting the variable to the default path is not a no-op.** With
 *    `CLAUDE_CONFIG_DIR=$HOME/.claude` the CLI looks for
 *    `~/.claude/.claude.json`, but a default install keeps its config at
 *    `~/.claude.json` — one level up. Doing that "harmlessly" makes the user's
 *    normal login look unconfigured. The system profile therefore spawns with
 *    the variable *unset*, never set to its own path. This is the single
 *    reason `sessionEnv()` returns `{}` for it.
 *
 * The user's real `~/.claude` is represented as a synthesised, unpersisted
 * profile that this module will not rename, relocate or delete.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import type { ProviderId } from '../shared/types'
import { profileIsolation, type ProfileIsolation } from './platform/credential-store'
import { currentPlatform, type Platform } from './platform/host'
import { userDataDir } from './platform/paths'
import {
  ACCOUNT_PROVIDERS,
  ACCOUNT_STRATEGIES,
  accountEnv,
  supportsAccounts,
  unsupportedAccountReason,
} from './provider-accounts'
import { claudeConfigDir, transcriptDir } from './transcript'

/* ---------------------------------------------------------------- model -- */

export interface Profile {
  id: string
  name: string
  /**
   * Which agent this account is a login of.
   *
   * Not decoration and not a label: it decides which environment variable the
   * directory is exported as, and therefore whether the directory is handed to
   * the CLI that wrote it. Absent in every record written before accounts had
   * providers, and those were all Claude — see `sanitizeProfile`, which fills
   * it in rather than dropping the profile.
   */
  provider: ProviderId
  /** Absolute path handed to the CLI as its config-directory variable. */
  configDir: string
  /** The user's own install. Synthesised on read, never written to disk. */
  system: boolean
  /**
   * A custom property name from `tokens.css`, not a colour value — the picker
   * wraps it in `var()`. Keeps the palette in one file, as the style rules require.
   */
  color: string
  createdAt: number
  lastUsedAt: number | null
}

export interface ProfilesState {
  version: number
  /** User-created profiles only. The system profile is never in here. */
  profiles: Profile[]
  /** Global fallback. Null means "the user's own install". */
  defaultProfileId: string | null
  /** Canonical project path -> profile id. */
  projectDefaults: Record<string, string>
}

export interface ResolveInput {
  /** Chosen in the new-session dialog. Beats everything else. */
  sessionProfileId?: string | null
  /** Folder the session will run in, used to find a per-project default. */
  projectPath?: string | null
  /**
   * The agent the session will run, when the caller knows it.
   *
   * Every level of the chain is then checked against it, so a Codex account
   * remembered as a folder's default does not win a Claude session — it falls
   * through to the next level exactly as a *deleted* account does, which is the
   * behaviour this chain already had for the other way of being unusable.
   *
   * Optional, and omitting it means "do not filter". That is deliberate rather
   * than lazy: `sessionEnv` refuses a mismatch on its own at the last moment
   * before the spawn, so a caller that has not been taught about providers
   * yet degrades to a session running under the machine's own login rather than
   * one pointed at another agent's directory.
   */
  provider?: ProviderId | null
}

export const SYSTEM_PROFILE_ID = 'system'
export const STATE_VERSION = 1
export const MAX_NAME_LENGTH = 60

/**
 * The id of the user's own install of an agent, per agent.
 *
 * Claude's keeps the bare `system` it has always had, because that string is
 * already written into `profiles.json` as a global or per-project default on
 * every machine this app has ever run on, and renaming it would silently reset
 * those. The others are suffixed.
 */
export function systemProfileId(provider: ProviderId): string {
  return provider === 'claude' ? SYSTEM_PROFILE_ID : `${SYSTEM_PROFILE_ID}:${provider}`
}

/**
 * Which agent's own install an id names, or null when it names a real account.
 *
 * Matched against the providers that actually have accounts rather than by
 * splitting on the colon, so `system:gemini` — a string a hand-edited file or a
 * build that offered more agents could contain — is *not* a system profile
 * here. It resolves to nothing and falls through the chain, which is the same
 * treatment a deleted account gets.
 */
export function systemProfileProvider(id: string): ProviderId | null {
  return ACCOUNT_PROVIDERS.find((provider) => systemProfileId(provider) === id) ?? null
}

/** True for any agent's own install. */
export function isSystemProfileId(id: string): boolean {
  return systemProfileProvider(id) !== null
}

/**
 * Assigned round-robin so two profiles are never the same colour until there
 * are more profiles than colours. Property names, resolved by the renderer.
 */
export const PROFILE_COLORS: readonly string[] = [
  '--accent',
  '--status-completed',
  '--status-waiting',
  '--status-input',
  '--color-warning',
  '--color-critical',
]

const EMPTY_STATE: ProfilesState = {
  version: STATE_VERSION,
  profiles: [],
  defaultProfileId: null,
  projectDefaults: {},
}

/* ----------------------------------------------------------- validation -- */

export class ProfileError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ProfileError'
  }
}

/**
 * MS-DOS device names, which Windows still refuses as filenames anywhere in a
 * path. `mkdir con` fails there with EINVAL — so a profile called "Con" would
 * slug to `con`, fail to create, and take the whole dialog down with an errno
 * nobody can read. Only the exact names are reserved; `console` is fine.
 */
const WINDOWS_RESERVED_NAMES = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/

/**
 * A profile id becomes a directory name, so it has to survive a filesystem
 * round-trip on any platform: no separators, no dots that could climb a level,
 * nothing Windows reserves.
 *
 * The last clause was a claim rather than a behaviour until the Windows port —
 * the character class handles separators and dots, and nothing handled the
 * device names. Applied on every platform on purpose: an id is written into
 * `profiles.json`, and a file written on a Mac gets opened on a PC.
 */
export function slugifyProfileId(name: string): string {
  const slug = name
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 32)
  // A name of only punctuation ("!!!") would slug to nothing, and an empty
  // directory name would silently resolve to the profiles root itself.
  if (slug === '') return 'profile'
  return WINDOWS_RESERVED_NAMES.test(slug) ? `${slug}-profile` : slug
}

/** Append -2, -3 … until the id is free. Two "Work" profiles are legal. */
export function uniqueProfileId(base: string, taken: ReadonlySet<string>): string {
  if (!taken.has(base) && base !== SYSTEM_PROFILE_ID) return base
  for (let n = 2; n < 1000; n++) {
    const candidate = `${base}-${n}`
    if (!taken.has(candidate)) return candidate
  }
  throw new ProfileError('could not allocate a profile id')
}

/**
 * Control and format characters, replaced rather than stripped so `a\nb` reads
 * as two words instead of one.
 *
 * `\p{Cc}` catches NUL, which is not whitespace and so survives both `trim()`
 * and `\s+`. `\p{Cf}` catches the bidi overrides — a name of
 * `Work <U+202E>gro.exe` renders in the picker as if it ended in `.org`, and
 * the picker's whole job is to show honestly which account is selected.
 */
const CONTROL_CHARS = /[\p{Cc}\p{Cf}]/gu

export function normalizeProfileName(raw: unknown): string {
  if (typeof raw !== 'string') throw new ProfileError('a profile needs a name')
  const name = raw.replace(CONTROL_CHARS, ' ').trim().replace(/\s+/g, ' ')
  if (name === '') throw new ProfileError('a profile needs a name')
  if (name.length > MAX_NAME_LENGTH) {
    throw new ProfileError(`profile names are limited to ${MAX_NAME_LENGTH} characters`)
  }
  return name
}

/** Same folder however the user typed it — `/w/app` and `/w/app/` are one project. */
export function canonicalProjectKey(projectPath: string): string {
  return resolve(projectPath)
}

/* --------------------------------------------------------------- paths -- */

function userData(): string {
  return userDataDir()
}

/** Where profiles this app created live. Nothing outside it is ever deleted. */
export function profilesRoot(): string {
  return join(userData(), 'profiles')
}

function stateFile(): string {
  return join(userData(), 'profiles.json')
}

/**
 * True only for a directory this app created for a profile.
 *
 * The deletion guard. A profile may legitimately point at a directory the user
 * already had (`~/.claude-work`), and removing that on "delete profile" would
 * destroy data the app never created. `root` itself is excluded so an empty or
 * malformed configDir cannot resolve to the whole profiles folder.
 */
export function isManagedConfigDir(configDir: string, root = profilesRoot()): boolean {
  if (typeof configDir !== 'string' || configDir === '' || !isAbsolute(configDir)) return false
  const rel = relative(resolve(root), resolve(configDir))
  if (rel === '' || rel === '..') return false
  return !rel.startsWith(`..${sep}`) && !isAbsolute(rel)
}

/**
 * Directories that must never be handed to a delete, whatever the state file
 * says. Belt and braces over `isManagedConfigDir` — a corrupted or
 * hand-edited profiles.json is exactly how a path like `$HOME` gets in here.
 */
export function isProtectedDir(configDir: string): boolean {
  const target = resolve(configDir)
  return (
    target === resolve(homedir()) ||
    target === dirname(target) || // filesystem root
    // Every agent's own install, not just Claude's. `systemConfigDir` is the
    // single list, so admitting a fourth agent to `ACCOUNT_PROVIDERS` protects
    // its home directory in the same edit rather than in a file nobody thinks
    // to open — and `~/.codex` holds a live `auth.json`, so a recursive delete
    // reaching it would sign the user out of ChatGPT for real.
    ACCOUNT_PROVIDERS.some((provider) => target === resolve(systemConfigDir(provider))) ||
    target === resolve(join(homedir(), '.claude'))
  )
}

/* ------------------------------------------------------------ the system -- */

/**
 * Where an agent keeps the user's own login, when nothing has been redirected.
 *
 * Claude's comes from `claudeConfigDir()` rather than a hardcoded `~/.claude`:
 * if Deck itself was launched with `CLAUDE_CONFIG_DIR` set, that *is* the
 * user's install, and sessions inherit the same variable. Codex's follows the
 * same rule through `CODEX_HOME`, and falls back to `~/.codex`, which is where
 * the CLI puts `auth.json`, `config.toml` and `sessions/` — observed on this
 * machine rather than assumed.
 */
export function systemConfigDir(provider: ProviderId, env = process.env): string {
  if (provider === 'claude') return claudeConfigDir()
  const key = ACCOUNT_STRATEGIES[provider]?.configEnv
  const inherited = key ? env[key] : undefined
  if (typeof inherited === 'string' && inherited.trim() !== '') return inherited
  return join(homedir(), `.${provider}`)
}

/**
 * The user's own install of an agent, presented as a profile so the picker has
 * something to select and the resolution chain always terminates.
 */
export function systemProfileFor(provider: ProviderId): Profile {
  return {
    id: systemProfileId(provider),
    /*
     * Claude's keeps the bare "Default" it has always had, and the others carry
     * the agent's name.
     *
     * Not decoration. Once there is more than one agent there is more than one
     * "your own install", and a list showing two rows both called "Default" is
     * a list where the whole point — telling two logins apart — has been lost.
     * Claude's is left alone because that string is already on screen in a
     * shipped build and in `profiles.json` name-collision checks.
     */
    name: provider === 'claude' ? 'Default' : `Default (${ACCOUNT_STRATEGIES[provider].label})`,
    provider,
    configDir: systemConfigDir(provider),
    system: true,
    color: PROFILE_COLORS[0],
    createdAt: 0,
    lastUsedAt: null,
  }
}

/**
 * Claude's own install.
 *
 * Kept as its own name because it is the terminator of the resolution chain —
 * `resolveProfile` falls back to it when nothing else resolves — and because
 * every existing caller means exactly this one.
 */
export function systemProfile(): Profile {
  return systemProfileFor('claude')
}

/* ------------------------------------------------------------ persistence -- */

/**
 * Which agent a stored record is an account of.
 *
 * Missing means the record predates accounts having providers, and every one of
 * those was a Claude account — that was the only kind the app could make. So the
 * absent case is filled in rather than treated as corrupt: dropping the record
 * would delete a working account on upgrade, and refusing to default it would
 * leave a login with no variable to be exported as.
 *
 * A *present* value is still checked against the strategy table. A file that
 * has been hand-edited to say `gemini`, or written by a future build that
 * offered an agent this one refuses, must not resurrect that agent's accounts
 * here — `accountEnv` would decline the mismatch anyway, but an account listed
 * under an agent this build will not isolate is a row that promises something
 * the app cannot do.
 */
function sanitizeProvider(raw: unknown): ProviderId | null {
  if (raw === undefined || raw === null) return 'claude'
  if (typeof raw !== 'string') return null
  const provider = raw as ProviderId
  return supportsAccounts(provider) ? provider : null
}

function sanitizeProfile(raw: unknown): Profile | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Partial<Profile>
  if (typeof value.id !== 'string' || value.id === '' || value.id === SYSTEM_PROFILE_ID) return null
  if (typeof value.name !== 'string' || value.name.trim() === '') return null
  if (typeof value.configDir !== 'string' || !isAbsolute(value.configDir)) return null
  const provider = sanitizeProvider(value.provider)
  if (provider === null) return null
  return {
    id: value.id,
    name: value.name,
    provider,
    configDir: value.configDir,
    // Never trusted from disk: a persisted record claiming to be the system
    // profile would inherit the protections meant for the real one.
    system: false,
    color: typeof value.color === 'string' ? value.color : PROFILE_COLORS[0],
    createdAt: typeof value.createdAt === 'number' ? value.createdAt : Date.now(),
    lastUsedAt: typeof value.lastUsedAt === 'number' ? value.lastUsedAt : null,
  }
}

export function sanitizeState(raw: unknown): ProfilesState {
  if (typeof raw !== 'object' || raw === null) return structuredClone(EMPTY_STATE)
  const value = raw as Partial<ProfilesState>

  const profiles: Profile[] = []
  const seen = new Set<string>()
  if (Array.isArray(value.profiles)) {
    for (const entry of value.profiles) {
      const profile = sanitizeProfile(entry)
      if (!profile || seen.has(profile.id)) continue
      seen.add(profile.id)
      profiles.push(profile)
    }
  }

  const projectDefaults: Record<string, string> = {}
  if (typeof value.projectDefaults === 'object' && value.projectDefaults !== null) {
    for (const [path, id] of Object.entries(value.projectDefaults)) {
      // A default pointing at a profile that no longer exists is dropped on
      // load rather than resolved around forever.
      if (typeof id !== 'string') continue
      if (!isSystemProfileId(id) && !seen.has(id)) continue
      projectDefaults[canonicalProjectKey(path)] = id
    }
  }

  const defaultId = value.defaultProfileId
  const defaultProfileId =
    typeof defaultId === 'string' && (isSystemProfileId(defaultId) || seen.has(defaultId))
      ? defaultId
      : null

  return { version: STATE_VERSION, profiles, defaultProfileId, projectDefaults }
}

let cached: ProfilesState | null = null

/** Keys of ours. Anything else in the file belongs to someone else. */
const KNOWN_STATE_KEYS: ReadonlySet<string> = new Set([
  'version',
  'profiles',
  'defaultProfileId',
  'projectDefaults',
])

/**
 * Top-level keys we did not recognise, kept verbatim so writing the file back
 * does not delete settings a newer version of the app put there. `getState`
 * fills this; `persist` merges it under our own keys.
 */
let carriedForward: Record<string, unknown> = {}

/**
 * Set when `profiles.json` exists but this process could not make sense of it —
 * unreadable, unparseable, or written by a version that knows more than we do.
 *
 * That file is the user's only copy of their profile list, and an empty state
 * in memory is indistinguishable from a real one by the time `persist` runs.
 * Without this flag the first write of the session — `markProfileUsed`, which
 * fires on every session spawn — replaces the lot with `{"profiles": []}`.
 */
let backupBeforeWrite = false

/** Drop the in-memory copy. Exported for tests, which swap userData per case. */
export function resetProfilesCache(): void {
  cached = null
  carriedForward = {}
  backupBeforeWrite = false
}

function unknownStateKeys(raw: object): Record<string, unknown> {
  const extras: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(raw)) {
    if (!KNOWN_STATE_KEYS.has(key)) extras[key] = value
  }
  return extras
}

export function getState(): ProfilesState {
  if (cached) return cached
  cached = structuredClone(EMPTY_STATE)
  carriedForward = {}
  backupBeforeWrite = false

  let text: string
  try {
    text = readFileSync(stateFile(), 'utf8')
  } catch (cause) {
    // Absent is first run and the only case where an empty state is the truth.
    // EACCES, EMFILE, EISDIR mean a file we cannot see is still holding the
    // user's profiles, and it must survive this session either way.
    backupBeforeWrite = (cause as NodeJS.ErrnoException | null)?.code !== 'ENOENT'
    return cached
  }

  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    // Corrupt. Boot anyway — a launch failure is worse than a lost list — but
    // do not let the next write be the thing that makes the loss permanent.
    backupBeforeWrite = true
    return cached
  }

  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    backupBeforeWrite = true
    return cached
  }

  cached = sanitizeState(raw)
  carriedForward = unknownStateKeys(raw)

  // A file from a newer version: we keep its unknown keys, but we cannot know
  // what it did to the ones we do parse, so keep a copy before rewriting it.
  const version = (raw as Partial<ProfilesState>).version
  if (typeof version === 'number' && version > STATE_VERSION) backupBeforeWrite = true

  return cached
}

function persist(state: ProfilesState): void {
  const file = stateFile()
  mkdirSync(dirname(file), { recursive: true })

  // Overwriting a file we could not read is the one irreversible thing this
  // module does to a user's config. Move it somewhere recoverable first.
  if (backupBeforeWrite) {
    try {
      renameSync(file, `${file}.bak-${Date.now()}`)
    } catch {
      // Already gone, or the directory is unwritable — in both cases there is
      // nothing left to preserve and the write below will report the problem.
    }
    backupBeforeWrite = false
  }

  // Composed field by field rather than serialising `state` directly: the
  // in-memory object is ours, the file is shared, and unknown keys go back
  // exactly as they came.
  const payload = {
    ...carriedForward,
    version: STATE_VERSION,
    profiles: state.profiles,
    defaultProfileId: state.defaultProfileId,
    projectDefaults: state.projectDefaults,
  }

  // Temp file plus rename, so a crash mid-write cannot truncate the list and
  // orphan every profile directory on disk.
  const tmp = `${file}.tmp`
  writeFileSync(tmp, JSON.stringify(payload, null, 2), 'utf8')
  renameSync(tmp, file)
}

/* ------------------------------------------------------------ resolution -- */

/** Ids that can actually be selected right now, every system id among them. */
export function knownProfileIds(state: ProfilesState): Set<string> {
  return new Set([
    ...ACCOUNT_PROVIDERS.map(systemProfileId),
    ...state.profiles.map((profile) => profile.id),
  ])
}

/**
 * Which agent an id is an account of, or null when the id names nothing.
 *
 * Answered without building a `Profile`, because the resolution chain asks it
 * once per candidate and most candidates are rejected.
 */
function providerOfId(state: ProfilesState, id: string): ProviderId | null {
  const system = systemProfileProvider(id)
  if (system !== null) return system
  return state.profiles.find((profile) => profile.id === id)?.provider ?? null
}

/**
 * Which profile a new session runs under.
 *
 * Precedence: the choice made for this session, then the project's default,
 * then the global default, then the user's own install.
 *
 * Every level is checked against the profiles that currently exist, and an id
 * that has since been deleted falls through to the next level instead of
 * throwing. A stale per-project default is the common case — the user deletes
 * a profile and would otherwise be unable to start a session in that folder.
 *
 * With `input.provider` set, "currently exists" also means "is an account of
 * the agent about to run". A folder whose remembered account is a Codex one
 * cannot decide a Claude session, and the fallback is that agent's own install
 * rather than Claude's — otherwise asking for Codex in a folder with no Codex
 * account would resolve to `~/.claude`, and `sessionEnv` would then have to
 * throw the answer away, leaving nothing on screen to explain the discrepancy.
 */
export function resolveProfileId(state: ProfilesState, input: ResolveInput = {}): string {
  const known = knownProfileIds(state)
  const wanted = input.provider ?? null
  const projectDefault =
    typeof input.projectPath === 'string' && input.projectPath !== ''
      ? state.projectDefaults[canonicalProjectKey(input.projectPath)]
      : undefined

  for (const candidate of [input.sessionProfileId, projectDefault, state.defaultProfileId]) {
    if (typeof candidate !== 'string' || !known.has(candidate)) continue
    if (wanted !== null && providerOfId(state, candidate) !== wanted) continue
    return candidate
  }
  // An agent with no account mechanism has no system id of its own, so it
  // terminates on Claude's exactly as it did before providers existed —
  // `sessionEnv` then exports nothing for it, which is the honest answer.
  return wanted !== null && supportsAccounts(wanted) ? systemProfileId(wanted) : SYSTEM_PROFILE_ID
}

export function findProfile(state: ProfilesState, id: string): Profile | null {
  const system = systemProfileProvider(id)
  if (system !== null) return systemProfileFor(system)
  return state.profiles.find((profile) => profile.id === id) ?? null
}

export function resolveProfile(state: ProfilesState, input: ResolveInput = {}): Profile {
  return findProfile(state, resolveProfileId(state, input)) ?? systemProfile()
}

/** Every account of one agent, its own install first. */
export function listProfilesForProvider(
  provider: ProviderId,
  state = getState(),
): Profile[] {
  if (!supportsAccounts(provider)) return []
  return [
    systemProfileFor(provider),
    ...state.profiles.filter((profile) => profile.provider === provider),
  ]
}

/* ------------------------------------------------------------------ env -- */

/**
 * True when this provider can be isolated at all — the picker greys out the
 * rest, and the Add-account dialog refuses to offer it.
 *
 * The table and the evidence behind it live in `provider-accounts.ts`. This
 * name is kept because it is what the rest of the app already calls, and
 * because "profiles" and "accounts" are the same thing under two names that the
 * codebase has not finished merging.
 */
export function supportsProfiles(provider: ProviderId): boolean {
  return supportsAccounts(provider)
}

/**
 * Environment overrides a session must spawn with, merged over the inherited
 * environment by the caller.
 *
 * Empty for the system profile *on purpose*: `CLAUDE_CONFIG_DIR=$HOME/.claude`
 * is not equivalent to leaving it unset. A default install reads
 * `~/.claude.json`, one level above the config directory, and setting the
 * variable makes the CLI look inside `~/.claude/` instead and find nothing.
 * Verified — see the module header. The same reasoning applies to `CODEX_HOME`,
 * and `accountEnv` applies it the same way.
 *
 * Also empty when the account belongs to a different agent than the one being
 * spawned. That check is in `accountEnv`, at the last point before the spawn,
 * rather than only in whatever resolved the account: it is the one place no
 * caller can route around.
 */
export function sessionEnv(profile: Profile, provider: ProviderId): Record<string, string> {
  if (profile.system) return {}
  return accountEnv(provider, profile)
}

/**
 * Where this profile's transcripts land, so cost and inspector data follow the
 * profile instead of always reading the default install.
 */
export function profileTranscriptDir(profile: Profile, cwd: string): string {
  return transcriptDir(cwd, profile.configDir)
}

/* ------------------------------------------------------------------ crud -- */

export interface CreateProfileOptions {
  /**
   * Which agent this is an account of. Defaults to Claude.
   *
   * Defaulted rather than required so every existing caller keeps working and
   * keeps meaning what it meant — an account created before the Add-account
   * dialog asked the question was always a Claude one. A provider this build
   * will not isolate is refused with a sentence rather than silently downgraded.
   */
  provider?: ProviderId
  /** Adopt a config directory the user already has instead of making one. */
  configDir?: string
}

/**
 * Validate a config directory the user wants to adopt.
 *
 * Two ways to hand this feature a directory that quietly does the opposite of
 * what it promises, both of which the rest of the module already treats as
 * impossible:
 *
 * 1. The user's own install. `sessionEnv` would then export
 *    `CLAUDE_CONFIG_DIR=$HOME/.claude`, and per the module header that is not a
 *    no-op — the CLI looks for `~/.claude/.claude.json` while a default install
 *    keeps its config at `~/.claude.json`, so the user's normal login reads as
 *    unconfigured. `isProtectedDir` already names these paths for deletion;
 *    they are just as wrong as a destination.
 * 2. A directory another profile already uses. Same config dir is the same
 *    account, so the picker would offer two names for one login — the exact
 *    confusion this feature exists to remove.
 */
function adoptableConfigDir(state: ProfilesState, raw: string, provider: ProviderId): string {
  if (typeof raw !== 'string' || !isAbsolute(raw)) {
    throw new ProfileError('a config directory must be an absolute path')
  }
  const resolved = resolve(raw)

  if (isProtectedDir(resolved)) {
    throw new ProfileError(
      `that is your own ${ACCOUNT_STRATEGIES[provider].label} install — the default account already uses it, and pointing a second account at it would break the login`,
    )
  }

  const clash = state.profiles.find((entry) => resolve(entry.configDir) === resolved)
  if (clash) {
    throw new ProfileError(`"${clash.name}" already uses that config directory`)
  }
  return resolved
}

/**
 * Every account there is: each agent's own install, then the ones this app made.
 *
 * The system rows come first — they are the fallback every other level
 * collapses to, so they should read as the top of the list rather than as
 * entries among equals — and they come in `ACCOUNT_PROVIDERS` order, which puts
 * Claude's first, where it has always been.
 *
 * This used to answer with Claude's install and nothing else, which was right
 * while Claude was the only agent that could hold an account. It is not right
 * now: `resolveProfileId` can answer `system:codex`, and a screen built from a
 * list that has never heard of that id shows an account chip with nothing in it.
 */
export function listProfiles(state = getState()): Profile[] {
  return [...ACCOUNT_PROVIDERS.map(systemProfileFor), ...state.profiles]
}

export function createProfile(name: string, options: CreateProfileOptions = {}): Profile {
  const state = getState()
  const provider = options.provider ?? 'claude'
  if (!supportsAccounts(provider)) {
    // The refusal is a sentence rather than a silently-dropped field, because
    // the only way to get here is a caller that offered the agent — and a
    // created-but-shared account is the failure the whole strategy exists to
    // stop. `unsupportedAccountReason` says which agent and why.
    throw new ProfileError(unsupportedAccountReason(provider))
  }
  const clean = normalizeProfileName(name)
  if (
    listProfilesForProvider(provider, state).some(
      (profile) => profile.name.toLowerCase() === clean.toLowerCase(),
    )
  ) {
    // Scoped to the agent, not global. Two identically named accounts of the
    // *same* agent are indistinguishable in the picker and picking the wrong
    // login is the mistake this feature prevents — but "Work" on Claude and
    // "Work" on Codex are two different logins that the provider badge tells
    // apart on sight, and refusing that pair would force people to type the
    // agent's name into every account name.
    throw new ProfileError(`a ${provider} account called "${clean}" already exists`)
  }

  const id = uniqueProfileId(slugifyProfileId(clean), knownProfileIds(state))
  const configDir =
    options.configDir !== undefined
      ? adoptableConfigDir(state, options.configDir, provider)
      : join(profilesRoot(), id)

  // Created eagerly: the CLI would make it anyway, and a directory that exists
  // lets the picker show honestly whether a profile has ever been used.
  mkdirSync(configDir, { recursive: true })

  const profile: Profile = {
    id,
    name: clean,
    provider,
    configDir,
    system: false,
    /*
     * Round-robin, starting *after* the system profile's colour.
     *
     * `systemProfile()` wears `PROFILE_COLORS[0]`, and it is not in
     * `state.profiles` — so indexing by the array's length gave the first
     * account a person creates the same dot as their own install. Seen on
     * screen the moment the accounts list had two rows in it: two identical
     * blue dots, in the one place whose whole job is telling two logins apart.
     */
    color: PROFILE_COLORS[(state.profiles.length + 1) % PROFILE_COLORS.length],
    createdAt: Date.now(),
    lastUsedAt: null,
  }

  state.profiles.push(profile)
  persist(state)
  return profile
}

export function renameProfile(id: string, name: string): Profile {
  const state = getState()
  if (isSystemProfileId(id)) throw new ProfileError('the default profile cannot be renamed')
  const profile = state.profiles.find((entry) => entry.id === id)
  if (!profile) throw new ProfileError(`no profile with id ${id}`)

  const clean = normalizeProfileName(name)
  // Scoped to this account's own agent, matching `createProfile`. A rename that
  // enforced a stricter rule than creation would refuse a name the Add-account
  // dialog had just accepted.
  const clash = listProfilesForProvider(profile.provider, state).some(
    (entry) => entry.id !== id && entry.name.toLowerCase() === clean.toLowerCase(),
  )
  if (clash) throw new ProfileError(`a ${profile.provider} account called "${clean}" already exists`)

  profile.name = clean
  persist(state)
  return profile
}

export interface DeleteProfileResult {
  removed: boolean
  /** False when the directory was left alone — the app did not create it. */
  filesDeleted: boolean
  /**
   * True when the login survives this deletion, so recreating a profile at the
   * same path signs straight back in.
   *
   * On macOS that is always the case: credentials are in the login Keychain
   * under a service name derived from the config directory, and this only ever
   * removes the directory. It is **not** unconditional, which is why it is
   * computed rather than written as `true`. Where the credential turns out to
   * live inside the config directory — which is what a `.credentials.json`
   * there means, and is the only thing that can be established on Windows —
   * deleting the files does sign the profile out, and answering `true` there
   * would be a straightforward lie about work already done.
   *
   * No caller reads this field today; it is part of the IPC answer and nothing
   * puts it on screen. Computed correctly anyway, because the moment something
   * does show it, it will be showing whatever this returns.
   */
  credentialsRetained: boolean
}

export function deleteProfile(
  id: string,
  options: { deleteFiles?: boolean } = {},
  platform: Platform = currentPlatform(),
): DeleteProfileResult {
  const state = getState()
  const system = systemProfileProvider(id)
  if (system !== null) {
    throw new ProfileError(
      `the default account is your own ${ACCOUNT_STRATEGIES[system].label} install and cannot be deleted`,
    )
  }

  const index = state.profiles.findIndex((entry) => entry.id === id)
  if (index === -1) throw new ProfileError(`no profile with id ${id}`)
  const [profile] = state.profiles.splice(index, 1)

  // Read before the directory goes, because that is the only moment the
  // question "where does this profile's login live?" can still be answered.
  // The filename is the agent's, not Claude's: Codex writes `auth.json` and
  // asking it for `.credentials.json` would answer "no credential here" about a
  // directory that holds one, which flips `credentialsRetained` to a promise
  // that the login survives a delete when it does not.
  const isolation = profileIsolation(platform, hasCredentialFile(profile))

  // Every reference goes with it, so nothing resolves to a profile that is gone.
  if (state.defaultProfileId === id) state.defaultProfileId = null
  for (const [path, assigned] of Object.entries(state.projectDefaults)) {
    if (assigned === id) delete state.projectDefaults[path]
  }
  persist(state)

  let filesDeleted = false
  if (options.deleteFiles === true) {
    // Both guards, deliberately. `isManagedConfigDir` is the rule; `isProtectedDir`
    // is the backstop for a hand-edited or corrupted profiles.json, where a
    // configDir of `$HOME` would otherwise be handed to a recursive delete.
    if (isManagedConfigDir(profile.configDir) && !isProtectedDir(profile.configDir)) {
      rmSync(profile.configDir, { recursive: true, force: true })
      filesDeleted = true
    }
  }

  return {
    removed: true,
    filesDeleted,
    // Nothing was deleted, or the credential is somewhere this did not touch.
    credentialsRetained: !filesDeleted || isolation.store !== 'config-directory',
  }
}

export function setGlobalDefault(id: string | null): ProfilesState {
  const state = getState()
  if (id !== null && !knownProfileIds(state).has(id)) throw new ProfileError(`no profile with id ${id}`)
  // Only *Claude's* system id collapses to null, because null has always meant
  // "the user's own Claude install" in this file and on disk. Choosing another
  // agent's own install is a real choice and is stored as the id it is —
  // collapsing it would make "run Codex as my own Codex login" indistinguishable
  // from "no global default", which resolves to Claude's directory.
  state.defaultProfileId = id === SYSTEM_PROFILE_ID ? null : id
  persist(state)
  return state
}

export function setProjectDefault(projectPath: string, id: string | null): ProfilesState {
  const state = getState()
  if (typeof projectPath !== 'string' || projectPath === '') {
    throw new ProfileError('a project path is required')
  }
  const key = canonicalProjectKey(projectPath)
  if (id === null) {
    delete state.projectDefaults[key]
  } else {
    if (!knownProfileIds(state).has(id)) throw new ProfileError(`no profile with id ${id}`)
    state.projectDefaults[key] = id
  }
  persist(state)
  return state
}

/** Recorded on spawn so the picker can order by recency. */
export function markProfileUsed(id: string): void {
  const state = getState()
  const profile = state.profiles.find((entry) => entry.id === id)
  if (!profile) return
  profile.lastUsedAt = Date.now()
  persist(state)
}

export interface ProfileStatus {
  id: string
  /** The config directory exists on disk. */
  exists: boolean
  /**
   * A `.claude.json` is present, i.e. the CLI has run under this profile.
   *
   * Not the same thing as "this profile has been used", and the difference is
   * newer than this field: `profiles-signin.ts` runs `claude auth status` under
   * the profile's directory to find out whether it is signed in, and the CLI
   * creates `.claude.json` on the way past — verified by running it against a
   * fresh directory, which came back `{"loggedIn": false}` and left a
   * `.claude.json`, a lock file and a `backups/` folder behind. So one visit to
   * the Accounts screen flips this to true for every account listed.
   *
   * `lastUsedAt` on the profile is the honest answer to "has this been used":
   * it is written by `markProfileUsed` when a session actually spawns, and by
   * nothing else.
   */
  initialized: boolean
  /**
   * Login state is deliberately absent. On macOS credentials live in the OS
   * keychain, not in the directory, so nothing here can tell whether a profile
   * is signed in without prompting for keychain access on every render.
   */
  configDir: string
  /** Which agent this account is a login of, so a row can badge it. */
  provider: ProviderId
  /**
   * Whether this profile's *login* is actually separate from the others, and on
   * what basis. Not decoration: on a platform where that has not been
   * established, `isolated` is false and `note` says so, because a picker that
   * shows two names for one login is the exact failure this feature exists to
   * prevent. See `platform/credential-store.ts`.
   *
   * NOT YET RENDERED. `ProfilePicker.tsx` reads `initialized` out of this
   * payload and nothing else, so the warning travels over IPC and stops there.
   * It is computed and honest; it is not yet something a user sees.
   */
  isolation: ProfileIsolation
}

/**
 * Whether the credential this account's agent writes is inside this account's
 * own directory.
 *
 * The filename is per agent — Claude writes `.credentials.json` and Codex
 * writes `auth.json` — so the question has to be asked of the strategy rather
 * than of a constant. A `stat`, never a keychain read: it costs nothing and
 * prompts for nothing, which is what lets it be asked on every render.
 */
function hasCredentialFile(profile: Profile): boolean {
  const name = ACCOUNT_STRATEGIES[profile.provider]?.credentialFile
  if (!name) return false
  return existsSync(join(profile.configDir, name))
}

/**
 * What each agent leaves behind once it has actually run in a directory.
 *
 * `initialized` means "the CLI has been here", and each CLI leaves a different
 * calling card. Asking Codex for `.claude.json` would answer "never used" about
 * a directory holding a full `sessions/` folder, and that row then wears a
 * "Never used" badge it does not deserve.
 *
 * Codex's list is what a real `$CODEX_HOME` on this machine contains and what a
 * fresh one does not. `tmp/` is deliberately **not** in it: a bare
 * `CODEX_HOME=<empty dir> codex login status` creates exactly that and nothing
 * else, so counting it would flip every listed account to "used" the first time
 * the Accounts screen asked whether they were signed in — which is the flaw the
 * comment on `initialized` already records for Claude.
 */
function initializedMarkers(provider: ProviderId): readonly string[] {
  return provider === 'claude' ? ['.claude.json'] : ['config.toml', 'auth.json', 'sessions']
}

export function profileStatus(profile: Profile, platform: Platform = currentPlatform()): ProfileStatus {
  return {
    id: profile.id,
    exists: existsSync(profile.configDir),
    initialized: initializedMarkers(profile.provider).some((name) =>
      existsSync(join(profile.configDir, name)),
    ),
    configDir: profile.configDir,
    provider: profile.provider,
    isolation: profileIsolation(platform, hasCredentialFile(profile)),
  }
}

/* ------------------------------------------------------------------- ipc -- */

function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string') throw new ProfileError(`${label} must be a string`)
  return value
}

function optionalId(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

export interface ProfilesSnapshot {
  profiles: Profile[]
  defaultProfileId: string | null
  projectDefaults: Record<string, string>
}

/**
 * @param provider narrows the list to one agent's accounts. The Accounts screen
 *   wants everything, badged; a new-session dialog wants only the accounts the
 *   agent it is about to start could actually run as, and offering it the rest
 *   is offering a choice `sessionEnv` will decline.
 */
function snapshot(provider: ProviderId | null = null): ProfilesSnapshot {
  const state = getState()
  return {
    profiles: provider === null ? listProfiles(state) : listProfilesForProvider(provider, state),
    defaultProfileId: state.defaultProfileId,
    projectDefaults: { ...state.projectDefaults },
  }
}

/**
 * A provider id off the wire, or null.
 *
 * Null for anything unrecognised rather than a throw: this is a filter, and the
 * safe failure is showing every account rather than refusing to list any.
 */
function optionalProvider(value: unknown): ProviderId | null {
  if (typeof value !== 'string') return null
  const provider = value as ProviderId
  return supportsAccounts(provider) ? provider : null
}

export interface AccountProviderView {
  id: ProviderId
  label: string
  /** Whether adding an account of this agent is offered at all. */
  supported: boolean
  /** The variable that would carry the account directory. Shown as evidence. */
  configEnv: string | null
  /** Why not, when `supported` is false. Rendered verbatim; never generic. */
  reason: string | null
}

export interface AccountProvidersView {
  providers: AccountProviderView[]
}

/**
 * The answer to "which agents can I add an account for", as a screen needs it.
 *
 * Every provider is listed, including the refused ones, because a missing row
 * is indistinguishable from a bug. `reason` is what the refused rows say, and
 * it is the agent's own sentence — see `provider-accounts.ts`, where each one is
 * written next to the measurement it came from.
 */
export function accountProvidersView(): AccountProvidersView {
  return {
    providers: (Object.values(ACCOUNT_STRATEGIES) as Array<(typeof ACCOUNT_STRATEGIES)[ProviderId]>)
      .filter((strategy) => strategy.provider !== 'shell')
      .map((strategy) => ({
        id: strategy.provider,
        label: strategy.label,
        supported: supportsAccounts(strategy.provider),
        configEnv: strategy.configEnv,
        reason: supportsAccounts(strategy.provider)
          ? null
          : unsupportedAccountReason(strategy.provider),
      })),
  }
}

/**
 * Wire the profile channels. Call once from `registerIpc()`:
 * `registerProfilesIpc(ipcMain)`.
 *
 * Channels:
 * - `profiles:list` (provider?) → {@link ProfilesSnapshot}
 * - `profiles:create` (name, options?) → {@link Profile}
 * - `profiles:rename` (id, name) → {@link Profile}
 * - `profiles:delete` (id, options?) → {@link DeleteProfileResult}
 * - `profiles:set-default` (id | null) → {@link ProfilesSnapshot}
 * - `profiles:set-project-default` (projectPath, id | null) → {@link ProfilesSnapshot}
 * - `profiles:resolve` ({ sessionProfileId?, projectPath?, provider? }) → {@link Profile}
 * - `profiles:status` (id) → {@link ProfileStatus}
 * - `profiles:account-providers` → {@link AccountProvidersView}
 *
 * Errors reject with the `ProfileError` message, which the picker shows as-is —
 * "a profile called Work already exists" is the whole explanation the user needs.
 */
export function registerProfilesIpc(ipcMain: IpcMain): void {
  ipcMain.handle('profiles:list', (_e: IpcMainInvokeEvent, provider: unknown) =>
    snapshot(optionalProvider(provider)),
  )

  /**
   * Which agents can hold an account, and the sentence for each one that
   * cannot.
   *
   * The renderer has its own copy of this in `ProviderPicker.tsx`, because a
   * dialog has to draw before any IPC answers and a picker that cannot say what
   * it offers until a round trip completes flickers. This channel is what makes
   * the two provable: the renderer's copy is a rendering of an answer that lives
   * here, and `provider-accounts.test.ts` fails if they disagree.
   */
  ipcMain.handle('profiles:account-providers', () => accountProvidersView())

  ipcMain.handle('profiles:create', (_e: IpcMainInvokeEvent, name: unknown, options: unknown) => {
    const raw =
      typeof options === 'object' && options !== null
        ? (options as { configDir?: unknown; provider?: unknown })
        : {}
    return createProfile(requireString(name, 'name'), {
      configDir: typeof raw.configDir === 'string' ? raw.configDir : undefined,
      // Narrowed rather than passed through: this value crosses from the
      // renderer and decides which environment variable a config directory is
      // exported as. An unrecognised name falls back to Claude, which is what a
      // caller that names nothing has always meant; a *recognised but refused*
      // one — Gemini — reaches `createProfile` and is rejected with its own
      // sentence, because silently making it a Claude account would be worse.
      ...(typeof raw.provider === 'string' ? { provider: raw.provider as ProviderId } : {}),
    })
  })

  ipcMain.handle('profiles:rename', (_e: IpcMainInvokeEvent, id: unknown, name: unknown) =>
    renameProfile(requireString(id, 'id'), requireString(name, 'name')),
  )

  ipcMain.handle('profiles:delete', (_e: IpcMainInvokeEvent, id: unknown, options: unknown) => {
    const deleteFiles =
      typeof options === 'object' && options !== null &&
      (options as { deleteFiles?: unknown }).deleteFiles === true
    return deleteProfile(requireString(id, 'id'), { deleteFiles })
  })

  ipcMain.handle('profiles:set-default', (_e: IpcMainInvokeEvent, id: unknown) => {
    setGlobalDefault(optionalId(id))
    return snapshot()
  })

  ipcMain.handle(
    'profiles:set-project-default',
    (_e: IpcMainInvokeEvent, projectPath: unknown, id: unknown) => {
      setProjectDefault(requireString(projectPath, 'projectPath'), optionalId(id))
      return snapshot()
    },
  )

  ipcMain.handle('profiles:resolve', (_e: IpcMainInvokeEvent, input: unknown) => {
    const request = (typeof input === 'object' && input !== null ? input : {}) as ResolveInput
    return resolveProfile(getState(), {
      sessionProfileId: optionalId(request.sessionProfileId),
      projectPath: typeof request.projectPath === 'string' ? request.projectPath : null,
      provider: optionalProvider(request.provider),
    })
  })

  ipcMain.handle('profiles:status', (_e: IpcMainInvokeEvent, id: unknown) => {
    const profile = findProfile(getState(), requireString(id, 'id'))
    if (!profile) throw new ProfileError(`no profile with id ${id}`)
    return profileStatus(profile)
  })
}
