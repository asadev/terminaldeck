/**
 * One conversation history, several accounts — Option C from `ACCOUNT-MODEL.md`.
 *
 * ## What this is for
 *
 * An account is a config directory (`profiles.ts` is the whole argument), and a
 * conversation is a file inside it at `projects/<encoded cwd>/<id>.jsonl`. So
 * changing account changes the store, and the conversation on screen is on the
 * other side of a wall — measured, twice, in `session-switch.ts` and again in
 * `ACCOUNT-MODEL.md`:
 *
 *     ONE  -p "remember the word PLATYPUS"       → conversation 6fcb822c
 *     TWO  --continue -p "what word"             → NEW conversation 4f131dc1
 *     TWO  --resume 6fcb822c                     → No conversation found
 *
 * That is what a person hitting their limit forty minutes into a piece of work
 * actually loses. Option C is the fix that costs nothing: leave every account's
 * credential, settings and permission grants exactly where they are, and share
 * **only** `projects/`. Measured on 2026-08-17 against the real CLI, one linear
 * conversation written by two different accounts:
 *
 *     user: remember the word PLATYPUS | sid dbebd1aa      ← ACCOUNT-ONE
 *     user: what word                  | sid dbebd1aa      ← ACCOUNT-TWO
 *
 * The app holds no credential to do it, which is the entire reason C was
 * recommended over the two options that work better on paper.
 *
 * ## The direction of the link, which is not a detail
 *
 * `ACCOUNT-MODEL.md` names this first of the three things C has to be built
 * with: **do not symlink `~/.claude/projects`.** That directory holds this
 * machine's real history — 73 project directories of it — and replacing it with
 * a link is restructuring a folder somebody is working in, which is the one
 * thing this repository's rules refuse outright.
 *
 * So the shared location *is* `~/.claude/projects`, and each **managed**
 * profile's `projects/` is linked into it. Additive, reversible, and the user's
 * own directory is never touched. The side effect is worth saying out loud
 * rather than letting somebody discover it: their terminal `claude` and their
 * Deck sessions then write one history. That is almost certainly what they
 * want — it is the whole point — but it is a sentence the screen has to say.
 *
 * ## What is deliberately not shared
 *
 * Everything else in a config directory, and each for its own reason
 * (`ACCOUNT-MODEL.md`, "What must not be shared"): `.credentials.json` is the
 * login; `.claude.json` holds `oauthAccount`, `userID` and every account-scoped
 * cache along with per-project `allowedTools` and `hasTrustDialogAccepted`;
 * `sessions/`, `backups/` and `history.jsonl` are one account's own. Sharing
 * `.claude.json` would put two accounts on one `oauthAccount` field and one set
 * of trust approvals. `--continue` does not read `lastSessionId` — it scans
 * `projects/` — which is exactly why sharing that one directory is sufficient.
 *
 * ## The hazard this opens, and where it is closed
 *
 * Two sessions continuing the *same* conversation at the same time fork it
 * silently: two branches, one session id, one file, no error, and whichever
 * branch `--continue` lands on next orphans the other. That is not closed here.
 * It is closed at the spawn point, in `host-core.ts`, by way of
 * `conversationScope` — which keys on the store this module resolves rather
 * than on the config directory, so two accounts sharing `projects/` are
 * correctly understood to be in one conversation. See `session-restore.ts`.
 */

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  unlinkSync,
} from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import {
  findProfile,
  getState as profilesState,
  isManagedConfigDir,
  ProfileError,
  type Profile,
} from './profiles'
import { currentPlatform, type Platform } from './platform/host'
/*
 * The memo that has to be dropped when either of the two acts below runs.
 *
 * `conversationStore()` answers with a `realpathSync` of `<configDir>/projects`
 * and caches it, because it is asked once per candidate in `planRestore`'s
 * claim pass and once per open tab in the switch handler — for an answer that
 * changes only when somebody presses a button in Settings. This module *is*
 * that button: relinking `projects/` changes precisely what that realpath
 * answers. See the calls at the end of `shareProjects` and `unshareProjects`.
 *
 * The import goes this way and not the other. `session-restore.ts` does not
 * import this module — it names it in a comment and nothing more — so there is
 * no cycle to create here.
 */
import { resetConversationStores } from './session-restore'
import { claudeConfigDir } from './transcript'

/* --------------------------------------------------------------- the root -- */

/**
 * The one location every sharing account's `projects/` points at.
 *
 * `claudeConfigDir()` rather than a hardcoded `~/.claude`, for the reason
 * `systemConfigDir` gives: if Deck itself was launched with `CLAUDE_CONFIG_DIR`
 * set then *that* is the user's own install, and the shared history belongs
 * beside it rather than in a directory nothing is reading.
 */
export function sharedProjectsRoot(): string {
  return join(claudeConfigDir(), 'projects')
}

/** `<configDir>/projects` — where the CLI files this account's conversations. */
export function accountProjectsDir(profile: Profile): string {
  return join(profile.configDir, 'projects')
}

/* --------------------------------------------------------------- reading -- */

/**
 * What `<configDir>/projects` actually is on disk right now.
 *
 *  - `shared`     a link, and it points at the shared root.
 *  - `elsewhere`  a link, but somebody pointed it somewhere else. Left alone.
 *  - `separate`   a real directory: this account keeps its own history.
 *  - `absent`     nothing there yet. The CLI would create it on first run.
 *  - `unmanaged`  not a directory this app created, or not an agent whose
 *                 history this app knows the shape of. Never touched.
 */
export type ProjectsLink = 'shared' | 'elsewhere' | 'separate' | 'absent' | 'unmanaged'

export interface ProjectsShareState {
  profileId: string
  link: ProjectsLink
  /** Where the link points, when it is one. */
  target: string | null
  /** The shared root, so a screen can name it without recomputing it. */
  root: string
  /**
   * How many project directories this account's own `projects/` holds.
   *
   * Only ever counted for a `separate` state, and it is the number a person
   * needs before pressing anything: it is what would be merged into the shared
   * history, and — if they ever delete the account — what would be lost. Zero
   * is the common case and makes sharing a one-way door nobody has to think
   * about.
   */
  ownProjects: number
}

/**
 * Whether this account is one this module may relink at all.
 *
 * Three conditions and each rules out a real mistake. It has to be a Claude
 * account, because `projects/<encoded cwd>/*.jsonl` is Claude Code's layout and
 * Codex keeps `sessions/` in a shape this app does not read. It has to be a
 * *managed* directory — one this app created under `profiles/` — because a
 * person who pointed an account at `~/.claude-work` did that on purpose and
 * this must not restructure it. And it must not be a system profile, which is
 * the user's own install and is the link's destination rather than its source.
 */
export function canShareProjects(profile: Profile): boolean {
  return profile.provider === 'claude' && !profile.system && isManagedConfigDir(profile.configDir)
}

function countProjectDirs(dir: string): number {
  try {
    return readdirSync(dir, { withFileTypes: true }).filter((entry) => entry.isDirectory()).length
  } catch {
    return 0
  }
}

export function shareState(profile: Profile): ProjectsShareState {
  const root = sharedProjectsRoot()
  const path = accountProjectsDir(profile)
  const base = { profileId: profile.id, root, target: null as string | null, ownProjects: 0 }

  if (!canShareProjects(profile)) return { ...base, link: 'unmanaged' }

  let stat
  try {
    // `lstat`, never `stat`: the whole question is whether this *is* a link, and
    // `stat` answers about whatever it points at, which for a working share is
    // the shared root and reads as an ordinary directory.
    stat = lstatSync(path)
  } catch {
    return { ...base, link: 'absent' }
  }

  if (stat.isSymbolicLink()) {
    let target: string | null = null
    try {
      target = resolve(dirname(path), readlinkSync(path))
    } catch {
      // A link we cannot read is a link we must not replace.
      return { ...base, link: 'elsewhere' }
    }
    return { ...base, target, link: target === resolve(root) ? 'shared' : 'elsewhere' }
  }

  return { ...base, link: 'separate', ownProjects: countProjectDirs(path) }
}

/* --------------------------------------------------------------- writing -- */

/**
 * What happened, in the terms a screen has to report it.
 *
 * `moved` counts what came into the shared history; `kept` counts what could
 * not — and that is now only ever a file whose exact name the shared history
 * already holds **with different contents**, which for transcripts named by a
 * random conversation id does not happen in practice.
 */
export interface ShareResult {
  state: ProjectsShareState
  /** Entries moved from this account's own history into the shared one. */
  moved: number
  /** Files left behind because the shared history holds the same name with other contents. */
  kept: number
  /** Where they were left, when any were. */
  keptAt: string | null
}

/**
 * Move everything in `from` into `to`, one entry at a time, and answer how
 * many entries moved and which files could not.
 *
 * ## Why per file, where it used to refuse the whole folder
 *
 * A folder both histories had was refused outright, and the account's entire
 * `projects/` was renamed out of sight so the link could be made. The person
 * then switched account and the conversation on screen — which lived in that
 * folder — was nowhere the agent looked: hidden, on the first switch, by the
 * feature whose whole point was to keep it.
 *
 * The refusal was guarding against interleaving two accounts' lines inside one
 * transcript, and moving files does not do that. Claude Code names each
 * conversation's file after its own random id, so one account's
 * `<id>.jsonl` and another's never share a name; they sit side by side in the
 * folder exactly as two conversations of one account do, which is also exactly
 * what shared history does with every conversation written after the link.
 *
 * So: an entry the shared side lacks is moved; a folder both have is merged
 * into, recursively; a file both have with the **same bytes** is the same file
 * and the extra copy goes; and a file both have with different bytes — the one
 * case a merge would have to choose — is left where it is, to be set aside.
 */
function mergeInto(from: string, to: string): { moved: number; conflicts: number } {
  let moved = 0
  let conflicts = 0
  for (const entry of readdirSync(from, { withFileTypes: true })) {
    const source = join(from, entry.name)
    const destination = join(to, entry.name)
    if (!existsSync(destination)) {
      renameSync(source, destination)
      moved += 1
      continue
    }
    const there = statSync(destination)
    if (entry.isDirectory() && there.isDirectory()) {
      const inner = mergeInto(source, destination)
      moved += inner.moved
      conflicts += inner.conflicts
      if (inner.conflicts === 0) rmSync(source, { recursive: true, force: true })
      continue
    }
    if (entry.isFile() && there.isFile() && sameBytes(source, destination)) {
      unlinkSync(source)
      continue
    }
    conflicts += 1
  }
  return { moved, conflicts }
}

/** Do two files hold exactly the same bytes? */
function sameBytes(a: string, b: string): boolean {
  try {
    if (statSync(a).size !== statSync(b).size) return false
    return readFileSync(a).equals(readFileSync(b))
  } catch {
    return false
  }
}

/**
 * A directory symlink, spelled the way each platform will accept one.
 *
 * `'junction'` on Windows and not `'dir'`, and the difference decides whether
 * this feature exists there at all: creating a `dir` symlink needs
 * `SeCreateSymbolicLinkPrivilege`, which an ordinary account does not have
 * unless Developer Mode is on, and it fails with EPERM. A junction is an
 * ordinary reparse point, needs no privilege, and is resolved by every API that
 * resolves a symlink — including the CLI's own `readdir` of `projects/`.
 */
function linkDir(target: string, path: string, platform: Platform): void {
  symlinkSync(target, path, platform === 'win32' ? 'junction' : 'dir')
}

/**
 * Point this account's `projects/` at the shared history.
 *
 * The order is: make sure the destination exists, move anything this account
 * already has into it where that is unambiguous, remove the now-empty directory,
 * then link. Every step is skipped when it has nothing to do, so calling this on
 * an account that is already sharing is a read and nothing else.
 *
 * Nothing is deleted. `rmSync` is called on the account's own `projects/` only
 * once every directory inside it has been moved or explicitly kept, and the
 * kept ones are moved aside under a name that says what they are rather than
 * being removed — a conversation this app could not merge is still a
 * conversation somebody had.
 */
export function shareProjects(profile: Profile, platform: Platform = currentPlatform()): ShareResult {
  if (!canShareProjects(profile)) {
    throw new ProfileError(
      // Neutral on purpose, and not because the fact is unclear. `neutral-naming.test.ts`
      // holds the rule that a sentence on screen does not name a vendor unless the
      // module's whole subject is that vendor, and this module's subject is a
      // directory layout. Both halves of the refusal are still here: a directory the
      // person set up themselves is not restructured, and an agent that keeps its
      // conversations in another shape has nothing this can share.
      'Only an account this app created its own folder for can share history — an account pointed at a directory you already had is left exactly as you set it up, and an agent that keeps its conversations in another shape has nothing to share.',
    )
  }

  const before = shareState(profile)
  if (before.link === 'shared') return { state: before, moved: 0, kept: 0, keptAt: null }
  if (before.link === 'elsewhere') {
    throw new ProfileError(
      `This account's projects folder is already a link to ${before.target ?? 'somewhere else'}. Nothing here will replace a link somebody else made.`,
    )
  }

  const root = sharedProjectsRoot()
  mkdirSync(root, { recursive: true })

  const path = accountProjectsDir(profile)
  let moved = 0
  let kept = 0
  let keptAt: string | null = null

  if (before.link === 'separate') {
    const merged = mergeInto(path, root)
    moved = merged.moved
    kept = merged.conflicts

    if (kept > 0) {
      // Only the files that could not be merged are left in it. Moved aside
      // rather than deleted, outside `projects/` so no agent mistakes them for
      // live history, and named so that somebody finding it in six months knows
      // what it is.
      keptAt = `${path}.not-merged-${Date.now()}`
      renameSync(path, keptAt)
    } else {
      rmSync(path, { recursive: true, force: true })
    }
  }

  linkDir(root, path, platform)

  /*
   * The one-conversation guard keys on the store, not on the config directory,
   * and it remembers what the store was. `conversationScope` in
   * `session-restore.ts` is what stops two tabs continuing one conversation and
   * forking it silently — the failure this whole feature makes reachable — and
   * it tells two accounts apart by the realpath of their `projects/`. That
   * realpath answered something different one line ago. Left memoised, the two
   * accounts that now share one history would still key on the two separate
   * paths they had before the link, so the guard would go on believing they are
   * in different conversations at the exact moment they stopped being.
   */
  resetConversationStores()

  return { state: shareState(profile), moved, kept, keptAt }
}

/**
 * Give this account its own history back.
 *
 * The link is removed and an empty directory takes its place; the shared
 * history is not touched, which means the conversations this account could see
 * a moment ago are still on disk and are simply no longer its. That is the
 * honest shape of the operation and the sentence {@link describeUnshare} puts
 * on screen before it happens.
 */
export function unshareProjects(profile: Profile): ProjectsShareState {
  const state = shareState(profile)
  if (state.link !== 'shared') return state
  const path = accountProjectsDir(profile)
  // `unlink`, not `rm -r`. On a symlink the recursive form removes the link and
  // not the target on every platform this runs on — but the non-recursive one
  // cannot do anything else even if that stopped being true, and the target
  // here is the user's entire conversation history.
  unlinkSync(path)
  mkdirSync(path, { recursive: true })

  /*
   * Same memo, opposite direction, and just as wrong to leave. This account's
   * store is a real directory again, so it is no longer the shared one — and a
   * cached realpath from before the unlink would keep it grouped with every
   * account that is still sharing, refusing it a `--continue` it is now
   * entitled to. See the note beside the call in `shareProjects`.
   */
  resetConversationStores()

  return shareState(profile)
}

/* -------------------------------------------------------------- adopting -- */

/**
 * Does this account already read the shared history?
 *
 * Two ways to be true and only one of them is a link. An agent's *own* install
 * is where the shared history lives — `sharedProjectsRoot()` is
 * `<the user's config dir>/projects` — so it reads the shared history by being
 * it, and asking `shareState` about it answers `unmanaged`, which is correct
 * about the link and useless as an answer to this question. Missing that is how
 * a switch between the user's own login and a managed account would go on
 * reporting two separate stores after they had been joined.
 */
export function readsSharedHistory(profile: Profile): boolean {
  if (profile.provider !== 'claude') return false
  if (resolve(accountProjectsDir(profile)) === resolve(sharedProjectsRoot())) return true
  return shareState(profile).link === 'shared'
}

/** Could it be made to, without restructuring anything somebody set up by hand? */
export function canJoinSharedHistory(profile: Profile): boolean {
  if (readsSharedHistory(profile)) return true
  if (!canShareProjects(profile)) return false
  const link = shareState(profile).link
  return link === 'separate' || link === 'absent'
}

/**
 * Put this account on the shared history, if it is not there and may be.
 *
 * Idempotent by construction — an account that is already sharing costs one
 * `lstat` — which is what lets the callers be blunt about it: the switch asks
 * on every plan, and boot asks about every account. Answers whether the account
 * reads the shared history *afterwards*, so a caller can tell the difference
 * between "joined" and "left alone on purpose".
 *
 * ## Why this is called rather than offered
 *
 * Asad, 2026-08-20, on the account switch as it shipped:
 *
 *   > *"It's not keeping the conversation history. If I go back, again that
 *   > message… It should at least keep the conversation there, history there,
 *   > memory there when I switch between the accounts."*
 *
 * The mechanism was built and measured — `ACCOUNT-MODEL.md` has account TWO
 * continuing account ONE's conversation and resuming it by id — and then it was
 * left switched off behind a control in Settings that nobody had pressed. His
 * accounts predate the feature, so their `projects/` are ordinary directories
 * and every switch he made genuinely could not see the conversation he was
 * looking at. The switch was working exactly as built and was useless to him,
 * which is the worst of both.
 *
 * A feature that only works if you find a toggle is not a feature. So the link
 * is made where it is needed, and Settings keeps the control for the person who
 * wants the two histories apart again.
 */
export function joinSharedHistory(profile: Profile): boolean {
  if (readsSharedHistory(profile)) return true
  if (!canJoinSharedHistory(profile)) return false
  shareProjects(profile)
  return readsSharedHistory(profile)
}

/** What a sweep over every account did, in the terms a log line needs. */
export interface AdoptResult {
  /** Accounts that were linked into the shared history by this call. */
  joined: string[]
  /** Ones already on it. */
  already: string[]
  /** Ones this must not touch — another agent, a directory somebody chose, a link of their own. */
  left: string[]
  /** Ones that threw, by id, with the reason. Never fatal: this runs at boot. */
  failed: Array<{ id: string; reason: string }>
}

/**
 * Bring every account this app created onto the shared history.
 *
 * The migration for accounts that predate the feature, and it is additive in
 * the only direction that matters: project directories move *into*
 * `~/.claude/projects` and the user's own history is never rewritten, which is
 * the first of the three conditions `ACCOUNT-MODEL.md` sets for Option C. A
 * folder the shared history already has is merged into file by file — each
 * conversation is its own uniquely named file, so nothing is interleaved — and
 * history an earlier build set aside is brought back the same way
 * (`restoreSetAside`). Existing files in the shared history are never touched.
 *
 * Nothing here may throw. It runs on the way up, before there is a window to
 * report to, and an account that cannot be linked is an account that keeps
 * working exactly as it did.
 */
export function adoptSharedHistory(profiles: readonly Profile[]): AdoptResult {
  const result: AdoptResult = { joined: [], already: [], left: [], failed: [] }
  for (const profile of profiles) {
    try {
      if (readsSharedHistory(profile)) {
        result.already.push(profile.id)
        restoreSetAside(profile)
        continue
      }
      if (!canJoinSharedHistory(profile)) {
        result.left.push(profile.id)
        continue
      }
      shareProjects(profile)
      result.joined.push(profile.id)
    } catch (cause) {
      result.failed.push({ id: profile.id, reason: cause instanceof Error ? cause.message : String(cause) })
    }
  }
  return result
}

/**
 * Bring back the history an earlier build set aside.
 *
 * Builds before 0.16.0 refused to merge a folder both histories had and moved
 * the account's whole `projects/` to `projects.not-merged-<time>` — so on a
 * machine that has already been through one switch, conversations are sitting
 * there where no agent looks. For an account that now reads the shared
 * history, each of those folders is merged in by the same per-file rule, and
 * removed once nothing is left in it; anything that still cannot be merged
 * stays exactly where it was. Answers how many entries came back.
 */
export function restoreSetAside(profile: Profile): number {
  if (!readsSharedHistory(profile) || !canShareProjects(profile)) return 0
  let restored = 0
  let names: string[]
  try {
    names = readdirSync(profile.configDir)
  } catch {
    return 0
  }
  const root = sharedProjectsRoot()
  for (const name of names) {
    if (!name.startsWith('projects.not-merged-')) continue
    const aside = join(profile.configDir, name)
    try {
      if (!statSync(aside).isDirectory()) continue
      const merged = mergeInto(aside, root)
      restored += merged.moved
      if (merged.conflicts === 0) rmSync(aside, { recursive: true, force: true })
    } catch {
      // Left exactly as it is; the next launch tries again.
    }
  }
  if (restored > 0) resetConversationStores()
  return restored
}

/* ---------------------------------------------------------------- saying -- */

/**
 * What sharing will do, before it is done.
 *
 * Written here rather than in the window for the reason the rest of this
 * subsystem gives: the counts come from the disk, and a sentence composed from
 * a number the renderer guessed at is the failure mode this whole feature is
 * meant to avoid.
 */
export function describeShare(state: ProjectsShareState): string {
  const shared =
    `Conversations will be kept in ${state.root}, which is also where your own ` +
    `terminal \`claude\` writes them — so this account and your normal login will ` +
    `see one history, and a conversation survives switching between them. ` +
    `Logins, permissions and settings stay separate.`
  if (state.link === 'separate' && state.ownProjects > 0) {
    return (
      `${shared} This account already has ${state.ownProjects} folder${state.ownProjects === 1 ? '' : 's'} ` +
      `of its own history; every conversation in them is moved into the shared history, ` +
      `including folders both histories already have.`
    )
  }
  return shared
}

/** What stopping sharing will do. */
export function describeUnshare(state: ProjectsShareState): string {
  return (
    `This account goes back to its own history and starts empty. Nothing is deleted — ` +
    `the conversations it can see now stay in ${state.root} and belong to your own ` +
    `install — but this account will no longer continue them.`
  )
}

/**
 * What deleting this account's files takes with it.
 *
 * The rule this answers is explicit: never delete a config directory holding
 * transcripts without saying exactly what is lost. There are two quite
 * different answers and confusing them is how somebody loses a year of history
 * to a button that promised otherwise — a *sharing* account owns no transcripts
 * at all, because its `projects/` is a link, and removing a link removes a link.
 */
export function describeDelete(state: ProjectsShareState): string {
  if (state.link === 'shared') {
    return (
      `No conversations are lost: this account's history is shared, so its projects ` +
      `folder is a link into ${state.root} and only the link is removed. Its own ` +
      `settings and permission grants go.`
    )
  }
  if (state.link === 'separate' && state.ownProjects > 0) {
    return (
      `${state.ownProjects} folder${state.ownProjects === 1 ? '' : 's'} of conversation history ` +
      `belonging to this account will be deleted along with its settings. They are not ` +
      `shared with any other account, so nothing else can read them afterwards.`
    )
  }
  return 'This account has no conversation history on disk. Its settings and permission grants go.'
}

/* ------------------------------------------------------------------- ipc -- */

export const SHARED_PROJECTS_STATE_CHANNEL = 'accounts:history-state'
export const SHARED_PROJECTS_SHARE_CHANNEL = 'accounts:history-share'
export const SHARED_PROJECTS_UNSHARE_CHANNEL = 'accounts:history-unshare'

function subject(id: unknown): Profile {
  if (typeof id !== 'string' || id === '') throw new ProfileError('an account id is required')
  const profile = findProfile(profilesState(), id)
  if (!profile) throw new ProfileError(`no account with id ${id}`)
  return profile
}

/**
 * Wire the shared-history channels. Called once from `registerIpc()`.
 *
 * Three channels rather than one toggle, and the extra one is the read: a
 * screen must never draw "shared" from the fact that a button was pressed. The
 * state channel answers from `lstat`, so what is on screen is what is on disk.
 */
export function registerSharedProjectsIpc(ipcMain: IpcMain): void {
  ipcMain.handle(SHARED_PROJECTS_STATE_CHANNEL, (_e: IpcMainInvokeEvent, id: unknown) => {
    const state = shareState(subject(id))
    return { state, share: describeShare(state), unshare: describeUnshare(state), remove: describeDelete(state) }
  })
  ipcMain.handle(SHARED_PROJECTS_SHARE_CHANNEL, (_e: IpcMainInvokeEvent, id: unknown) =>
    shareProjects(subject(id)),
  )
  ipcMain.handle(SHARED_PROJECTS_UNSHARE_CHANNEL, (_e: IpcMainInvokeEvent, id: unknown) =>
    unshareProjects(subject(id)),
  )
}
