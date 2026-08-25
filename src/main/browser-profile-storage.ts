import { existsSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { join } from 'node:path'

/**
 * Where a browser profile's bytes are, and who is allowed to say so.
 *
 * ## The defect this module exists to end
 *
 * "Clear this profile" on the phone reached `browserProfilesFor` in
 * `remote/server.ts`, which rebuilt the directory out of the partition string:
 *
 *     const partition = row.partition.replace(/^persist:/, '')
 *     await rm(join(dir, 'browser', partition), { recursive: true, force: true })
 *
 * There has never been a `browser/` directory under either host's state
 * directory. Measured on this Mac on 2026-08-25, against the desktop's own
 * `app.getPath('userData')` — `~/Library/Application Support/Terminal Deck`:
 * twenty-three entries, `Partitions/terminaldeck-browser` among them, and no
 * `browser` anywhere. `rm` with `force: true` treats a missing path as success,
 * so the call resolved, the fresh profile list went back to the phone, the
 * screen redrew, and **every cookie and every signed-in session was still
 * there**. Somebody who cleared a profile to sign out was still signed in and
 * had been told otherwise. That is the one thing this codebase says a control
 * may never do.
 *
 * The cause is not the typo. The cause is that the path was rebuilt from a
 * string in a second place, four hundred lines away from the module that
 * creates it, where nothing could ever disagree with it out loud. So the path
 * is built **here**, once, for both host shapes, and the only other statement of
 * it — the headless host's `profileDir` — is now a call into this file.
 *
 * ## The two shapes, and why both are looked for
 *
 * A profile is a cookie jar on a disk, and this product puts one there in two
 * different ways:
 *
 *  - **The desktop.** `browser-profiles.ts` mints an Electron `persist:` session
 *    partition, and Electron writes it to `<userData>/Partitions/<name>`, where
 *    `<name>` is the partition string with the `persist:` prefix removed.
 *    `browser-session.ts` states the same path — *"`persist:` partitions write
 *    to `<userData>/Partitions/<name>`"* — and it is Electron's layout rather
 *    than this app's convention: on the same machine, `Claude`, `Notion`,
 *    `Codex` and `vibeyard` all keep their partitions in exactly that shape.
 *  - **A server.** `browser-headless-host.ts` launches one real Chromium per
 *    profile with `--user-data-dir=<userData>/Partitions/<profileId>`. The leaf
 *    is the profile **id**, not the partition string, because there is no
 *    Electron to hand a partition name to — which is precisely the difference
 *    the broken line could not have known about.
 *
 * Both are looked for and both are emptied, rather than the host being sniffed
 * first, and that is deliberate. `stateDir` is `app.getPath('userData')` on the
 * desktop and the daemon's own state directory on a server, and on a machine
 * where those are the same directory — a person running both against one
 * install — one profile genuinely has bytes under both spellings. "Empty this
 * profile" means empty it, not empty the half this process happens to have
 * launched.
 *
 * ## Chromium holds files open, so the browser is told first
 *
 * `rm -rf` over a live profile is not a clear. On Windows the unlink fails
 * outright while the browser holds the files; on macOS and Linux it succeeds and
 * the *running* browser keeps the jar it already has in memory and can write it
 * back. Either way the phone would have been told the profile was empty.
 *
 * So whoever owns the directory gets asked to let go of it first, through
 * {@link ProfileStorageOwner}, and only a host that is actually running one
 * registers as an owner. {@link HeadlessDriveHost} does: it closes that
 * profile's targets, stops its Chromium and waits for the process to be gone
 * before a single file is removed. A desktop registers nothing, because the
 * Electron session that would have to be dropped lives behind `electron`'s
 * `session` module, which this file may never import — `remote/server.ts` is in
 * the headless bundle's import graph and `src/headless/seam.test.ts` walks it.
 * What a desktop gets instead is the truth, in two parts. The removal is
 * attempted, the directory is looked at again afterwards, and a profile whose
 * files are still there comes back as {@link ProfileClear} `'held'` rather than
 * as a success — which is the Windows case, where the unlink fails outright.
 * And a clear that nothing let go of comes back with `stopped: false`, which is
 * what `browserProfilesFor` turns into a sentence for the person: the bytes are
 * gone, and a page already open in that profile keeps the cookies its network
 * service loaded until the app reopens it. Unlinking a file does not reach into
 * a running process, and a clear that said nothing about that would be the same
 * defect one size smaller.
 *
 * ## Nothing here reports a clear it did not perform
 *
 * Three outcomes, because there are three things that can happen and a caller
 * that could only say "done" is how this defect shipped:
 *
 *  - `cleared` — the directory existed and is gone, checked after the fact.
 *  - `empty` — there was nothing on this machine for that profile. Not an error
 *    and not a success either: a person who pressed Clear to sign out is owed
 *    the difference between "your sign-ins are gone" and "this machine was
 *    holding none".
 *  - `held` — something still has those files. The one outcome that used to be
 *    invisible.
 */

/* ---------------------------------------------------------------- the ids -- */

/**
 * The id of the profile whose partition predates the profiles feature.
 *
 * `browser-profiles.ts`'s `DEFAULT_PROFILE_ID`, `DEFAULT_PARTITION` and
 * `PROFILE_PARTITION_PREFIX`, restated in a module with no Electron in it.
 *
 * They are restated rather than imported because that module reaches `app` and
 * `session` on its first line and would drag the whole desktop profile stack —
 * and Electron itself — into the headless bundle. `browser-headless-host.ts`
 * carried its own copy of the first of these for exactly that reason, with its
 * own paragraph explaining why; there is now one copy instead of two, and
 * `browser-profile-storage.test.ts` reads `browser-profiles.ts` as text and
 * fails if the values ever drift apart. Two independent statements of one truth,
 * the arrangement `browser-cdp.test.ts` already keeps between the CDP screen and
 * the fetch rules.
 */
export const DEFAULT_PROFILE_ID = 'default'

/** The partition every tab in every build before profiles existed used. */
export const DEFAULT_PARTITION = 'persist:terminaldeck-browser'

/** Every other profile's partition is this plus its id. */
export const PROFILE_PARTITION_PREFIX = 'persist:terminaldeck-browser-'

/** A name longer than this is a paragraph somebody pasted, not a label. */
export const MAX_PROFILE_NAME = 40

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/**
 * Is this an id this app mints profiles under?
 *
 * The same shape `partitionFor` checks in `browser-profiles.ts`, and it is a
 * check rather than a formality for the reason that module gives: an id reaches
 * these functions from a phone over the wire, every one of them becomes the last
 * segment of a path, and a string with a separator in it is a path somewhere
 * else. Either the literal default, or a UUID — nothing else has ever been
 * minted, so nothing else is accepted.
 */
export function isProfileId(value: unknown): value is string {
  if (value === DEFAULT_PROFILE_ID) return true
  return typeof value === 'string' && UUID.test(value)
}

/** The Electron partition string for a profile id, or null when the id is not one. */
export function partitionForProfile(id: unknown): string | null {
  if (id === DEFAULT_PROFILE_ID) return DEFAULT_PARTITION
  if (!isProfileId(id)) return null
  return `${PROFILE_PARTITION_PREFIX}${id}`
}

/* -------------------------------------------------------------- the paths -- */

/**
 * The directory Electron writes a `persist:` partition to.
 *
 * `<userData>/Partitions/<name>`, the name being the partition string without
 * its prefix. Chromium lower-cases the ASCII of a partition name when it makes
 * the directory; every partition this app mints is already lower case — a fixed
 * string and a UUID — so the two spellings coincide, and {@link clearProfileStorage}
 * looks for both rather than resting on that.
 */
export function electronProfileDir(userData: string, partition: string): string {
  return join(userData, 'Partitions', partitionDirName(partition))
}

/**
 * The `--user-data-dir` a headless host launches a profile's Chromium with.
 *
 * The same `Partitions` root, keyed by the profile id, because there is no
 * partition string on this side — the browser is a process with a directory
 * rather than a session with a name.
 */
export function headlessProfileDir(userData: string, profileId: string): string {
  return join(userData, 'Partitions', profileId)
}

/**
 * The last path segment for a partition string.
 *
 * Anything that is not a plain name collapses to the empty string, which
 * {@link clearProfileStorage} treats as "no directory to name" rather than
 * joining it: a partition read out of a JSON file somebody edited by hand must
 * not be able to point a recursive delete at a parent directory.
 */
export function partitionDirName(partition: string): string {
  const name = partition.replace(/^persist:/, '')
  if (name === '' || name === '.' || name === '..') return ''
  if (/[\\/]/.test(name)) return ''
  return name
}

/* ------------------------------------------------------------- the owner -- */

/**
 * Whatever is holding a profile's files open in this process.
 *
 * One at a time, and only a host that actually launched a browser registers:
 * this is not a plugin point, it is the answer to "is there something running
 * that has to let go before these files can be deleted". A process with no
 * registration is a process where nothing of ours is holding the jar, which is
 * the ordinary case on a desktop whose profile has not been opened this run.
 */
export interface ProfileStorageOwner {
  /**
   * The directory this owner's browser keeps that profile in, or null when it
   * does not hold that profile at all.
   *
   * Answered whether or not a browser has been launched for it: the owner knows
   * the layout, and whether there are bytes there is a question for the disk.
   */
  directoryFor(profileId: string): string | null
  /**
   * Stop holding that profile's files, and say whether it let go.
   *
   * `released: false` is a refusal to proceed rather than a caveat — a clear
   * over a browser that is still running is the failure this whole module is
   * about.
   */
  release(profileId: string): Promise<{ released: boolean; why: string }>
}

let owner: ProfileStorageOwner | null = null

/**
 * Register the owner of this process's profile directories.
 *
 * Returns the function that unregisters it, which the owner calls when it stops
 * — an owner that has torn down its browsers is no longer holding anything, and
 * a stale one would answer for directories nobody has open.
 */
export function ownProfileStorage(next: ProfileStorageOwner): () => void {
  owner = next
  return () => {
    if (owner === next) owner = null
  }
}

/** The registered owner, or null. Exported for the tests that pin the wiring. */
export function profileStorageOwner(): ProfileStorageOwner | null {
  return owner
}

/** For tests, which must not inherit each other's owner. */
export function resetProfileStorageForTests(): void {
  owner = null
}

/* -------------------------------------------------------------- the clear -- */

/** What actually happened to a profile's bytes. */
export type ProfileClear =
  | {
      state: 'cleared'
      /** Every directory that was there and is not any more. */
      dirs: readonly string[]
      /** Whether a running browser was stopped first. False when none was running. */
      stopped: boolean
    }
  | { state: 'empty'; dirs: readonly string[] }
  | { state: 'held'; dirs: readonly string[]; why: string }

/**
 * Empty one profile, and answer with what was actually done.
 *
 * The order is the whole of the correctness: name every directory the two host
 * shapes could have put this profile in, look at the disk before touching it,
 * make the browser let go, remove, and then **look again**. The last step is the
 * one the broken version had no equivalent of — it reported on the call it made
 * rather than on the state it left behind, and `rm(..., { force: true })` does
 * not fail for a path that was never there.
 */
export async function clearProfileStorage(input: {
  /** Where this host keeps its state — `app.getPath('userData')`, or the daemon's. */
  userData: string
  profileId: string
  /** The partition string, for the Electron spelling of the same profile. */
  partition: string
}): Promise<ProfileClear> {
  const candidates = profileDirCandidates(input)
  if (candidates.length === 0) {
    return { state: 'empty', dirs: [] }
  }

  const present = candidates.filter((dir) => existsSync(dir))
  if (present.length === 0) {
    // Nothing to clear is not a clear. Said as its own outcome so the caller
    // cannot spell it as success — which is exactly what happened when the path
    // was wrong and `force: true` swallowed the difference.
    return { state: 'empty', dirs: candidates }
  }

  let stopped = false
  if (owner !== null && owner.directoryFor(input.profileId) !== null) {
    const letGo = await owner.release(input.profileId)
    if (!letGo.released) {
      return { state: 'held', dirs: present, why: letGo.why }
    }
    stopped = true
  }

  for (const dir of present) {
    await rm(dir, { recursive: true, force: true }).catch(() => undefined)
  }

  const left = present.filter((dir) => existsSync(dir))
  if (left.length > 0) {
    return {
      state: 'held',
      dirs: left,
      why:
        'something on this machine still has those files open, so they could not all be removed. ' +
        'A browser window open in that profile will be holding them.',
    }
  }
  return { state: 'cleared', dirs: present, stopped }
}

/**
 * Every directory this machine could be keeping that profile in.
 *
 * The owner's answer first, because it is the only one that comes from the
 * process that actually launched the browser, then the two layouts derived from
 * the id and the partition. Duplicates collapse: on a server the owner's answer
 * and the headless layout are the same string, and removing it twice would make
 * the second look like a directory that was never there.
 */
function profileDirCandidates(input: {
  userData: string
  profileId: string
  partition: string
}): string[] {
  const dirs: string[] = []
  const add = (dir: string | null): void => {
    if (dir === null || dir === '') return
    if (!dirs.includes(dir)) dirs.push(dir)
  }

  if (!isProfileId(input.profileId)) return dirs
  add(owner?.directoryFor(input.profileId) ?? null)
  add(headlessProfileDir(input.userData, input.profileId))

  const partition = partitionForProfile(input.profileId) ?? input.partition
  const name = partitionDirName(partition)
  if (name !== '') add(electronProfileDir(input.userData, partition))
  // And the lower-cased spelling, when Chromium's own naming would differ from
  // the string. Never true for an id this app mints; here so that a partition
  // that arrived some other way is still found rather than silently missed.
  const lower = name.toLowerCase()
  if (lower !== name) add(join(input.userData, 'Partitions', lower))
  return dirs
}

/* ------------------------------------------------------------- the roster -- */

/** One profile, as the machine's own `browser-profiles.json` holds it. */
export interface StoredProfile {
  id: string
  name: string
  /** The one character drawn in the badge, or `''` for the name's initial. */
  avatar: string
  /** Derived from the id, never read from the file. See {@link readStoredProfiles}. */
  partition: string
}

export interface StoredProfiles {
  activeId: string
  profiles: StoredProfile[]
}

/** Where the machine keeps its profile list. `browser-profiles.ts`'s `profilesPath`. */
export function profilesFile(stateDir: string): string {
  return join(stateDir, 'browser-profiles.json')
}

/**
 * The stored profile list, read defensively out of the file's text.
 *
 * `readProfileState` in `browser-profiles.ts` is the desktop's version of this
 * function and this one keeps its three properties on purpose, because the two
 * read the same file and a phone that saw a different list from the window three
 * feet away would be describing a different machine:
 *
 *  - **The partition is derived from the id, never trusted from the file.** A
 *    row whose id is not one this app mints is dropped rather than carried, so
 *    there is no path from a hand-edited JSON file to a directory name — which
 *    matters here more than it does there, because on this side the row travels
 *    to a phone and comes back as the subject of a recursive delete.
 *  - **The default profile is re-inserted if it went missing**, because "this
 *    browser has no profiles" is not a thing a browser can be.
 *  - **The active id is pulled back to a profile that exists**, since a dangling
 *    one sends every new window to a jar nothing can name.
 *
 * Pure over the file's text — including `null` for a machine that has never been
 * asked — so the IO stays with the caller and every branch is drivable in a test.
 */
export function readStoredProfiles(text: string | null): StoredProfiles {
  const fallback: StoredProfiles = {
    activeId: DEFAULT_PROFILE_ID,
    profiles: [{ id: DEFAULT_PROFILE_ID, name: 'Default', avatar: '', partition: DEFAULT_PARTITION }],
  }
  if (text === null) return fallback

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    // A file with a stray comma in it must not be a browser panel that will not
    // open. The same posture `browser-profiles.ts` takes over the same bytes.
    return fallback
  }
  if (typeof parsed !== 'object' || parsed === null) return fallback
  const value = parsed as Record<string, unknown>
  const list = Array.isArray(value.profiles) ? value.profiles : []

  const profiles: StoredProfile[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const partition = partitionForProfile(record.id)
    if (partition === null) continue
    const id = record.id as string
    if (profiles.some((profile) => profile.id === id)) continue
    profiles.push({
      id,
      name: cleanProfileName(record.name, id === DEFAULT_PROFILE_ID ? 'Default' : 'Profile'),
      avatar: cleanAvatar(record.avatar),
      partition,
    })
  }
  if (!profiles.some((profile) => profile.id === DEFAULT_PROFILE_ID)) {
    profiles.unshift({ id: DEFAULT_PROFILE_ID, name: 'Default', avatar: '', partition: DEFAULT_PARTITION })
  }

  const wanted = value.activeId
  const activeId =
    typeof wanted === 'string' && profiles.some((profile) => profile.id === wanted)
      ? wanted
      : DEFAULT_PROFILE_ID
  return { activeId, profiles }
}

/**
 * Tidy a name a person typed. `cleanProfileName` in `browser-profiles.ts`.
 *
 * Control characters are stripped rather than escaped: this name is drawn in a
 * list on a phone and read out by a screen reader, and a newline in the middle
 * of a row is a rendering fault whose cause nobody can see.
 */
export function cleanProfileName(raw: unknown, fallback = 'Profile'): string {
  if (typeof raw !== 'string') return fallback
  const flat = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()
  if (flat === '') return fallback
  return flat.length > MAX_PROFILE_NAME ? flat.slice(0, MAX_PROFILE_NAME) : flat
}

/**
 * One character for a badge, or `''`. `cleanAvatar` in `browser-profiles.ts`.
 *
 * Split by code point rather than by `charAt`, because an emoji cut in half is
 * half a surrogate pair, which draws as a replacement box.
 */
export function cleanAvatar(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  const trimmed = raw.replace(/[\u0000-\u001f\u007f]/g, '').trim()
  if (trimmed === '') return ''
  return [...trimmed][0] ?? ''
}
