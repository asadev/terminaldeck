import { randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { app, session, type IpcMain, type Session } from 'electron'
import { attachDownloads } from './browser-downloads'
import { writeRecordPreload } from './browser-record-preload'

/**
 * Browser profiles — separate people, or separate logins, in the same window.
 *
 * ## What he asked for, and what of it is actually possible
 *
 * From the recorded review of 2026-08-17, of the embedded browser:
 *
 *   > *"Password saving, like Chrome — profiles, saved logins."*
 *
 * and again in Settings:
 *
 *   > *"Browser — start page, cookies, and Chrome profile settings, so people
 *   > get Chrome's own features while browsing."*
 *
 * Two of those three are Chromium features Electron exposes directly, and this
 * module is the first of them. A profile here is a **persistent session
 * partition**: `session.fromPartition('persist:…')` gives a completely separate
 * cookie jar, `localStorage`, IndexedDB, cache, service workers and per-origin
 * zoom, written to its own directory under `<userData>/Partitions/`. That is
 * not an approximation of a Chrome profile — it is the same mechanism Chrome
 * uses, reached through Electron's own API, and it was verified to survive a
 * restart in `browser-session.ts`.
 *
 * The third — saved passwords — is **not** exposed by Electron at any version,
 * and pretending otherwise is the failure mode the whole review is about. That
 * one is answered honestly in `browser-passwords.ts`, which builds a real store
 * rather than a screen that looks like one.
 *
 * ## The default profile keeps the partition that already exists
 *
 * `persist:terminaldeck-browser` is the partition every tab in every build so far
 * has used, and somebody upgrading into this feature is signed into things in
 * it. So the default profile is not a new partition with a nice name; it *is*
 * that string, and this module is careful never to mint a profile that could
 * collide with it. A "profiles" feature whose first act is to sign you out of
 * everything is a feature nobody turns on twice.
 *
 * ## Why a switch reopens the page instead of reconfiguring it
 *
 * A `WebContents`' session is fixed when it is constructed and cannot be
 * swapped afterwards. `browser-tab.ts` already documents this for the per-tab
 * Isolated toggle — *"switching replaces the page rather than reconfiguring
 * it"* — and profiles inherit the same physics rather than inventing a second
 * story about them. Switching profile therefore changes what the *next* page
 * opens into, and the panel offers to reopen the current one.
 */

/* ------------------------------------------------------------------ shape -- */

/** The id of the profile whose partition predates this feature. Never minted. */
export const DEFAULT_PROFILE_ID = 'default'

/** Must equal `GUEST_PARTITION` in `browser-tab.ts` and `browser-session.ts`. */
export const DEFAULT_PARTITION = 'persist:terminaldeck-browser'

/** Every other profile's partition is this plus its id. */
export const PROFILE_PARTITION_PREFIX = 'persist:terminaldeck-browser-'

/** A name longer than this is a paragraph somebody pasted, not a label. */
export const MAX_PROFILE_NAME = 40

export interface BrowserProfile {
  id: string
  name: string
  /** The Electron partition string. Shown nowhere; used by every other module. */
  partition: string
  /** Milliseconds since the epoch, so the list can be ordered by age. */
  createdAt: number
  /** True for the one profile that cannot be deleted. */
  isDefault: boolean
}

export interface ProfileState {
  profiles: BrowserProfile[]
  activeId: string
}

/* ------------------------------------------------------------- validation -- */

/**
 * The partition for a profile id, or null when the id is not one we minted.
 *
 * Ids reach this module from the renderer over IPC, and `fromPartition` will
 * happily create a directory for *any* string — including one with a path
 * separator in it. So the shape is checked rather than trusted: either the
 * literal default, or a UUID. The same discipline `isIsolationKey` applies in
 * `browser-isolation.ts`, and for the same reason.
 */
export function partitionFor(id: unknown): string | null {
  if (id === DEFAULT_PROFILE_ID) return DEFAULT_PARTITION
  if (typeof id !== 'string') return null
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) return null
  return `${PROFILE_PARTITION_PREFIX}${id}`
}

/**
 * Tidy a name a person typed, or fall back to one that reads like a name.
 *
 * Control characters are stripped rather than escaped: the name is drawn in the
 * menu and read out by a screen reader, and a newline in the middle of a menu
 * row is a rendering bug that a person cannot see the cause of.
 */
export function cleanProfileName(raw: unknown, fallback = 'Profile'): string {
  if (typeof raw !== 'string') return fallback
  const flat = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()
  if (flat === '') return fallback
  return flat.length > MAX_PROFILE_NAME ? flat.slice(0, MAX_PROFILE_NAME) : flat
}

/**
 * A stored file, read defensively into a state that is always usable.
 *
 * Anything unrecognised collapses to "one default profile, active" rather than
 * throwing, because the alternative is a browser panel that will not open at all
 * because a JSON file has a stray comma in it. The default profile is
 * re-inserted if it went missing, and the active id is pulled back to a profile
 * that exists — a dangling active id would send every new tab to a partition
 * with nothing in it and no way to say why.
 */
export function readProfileState(raw: unknown): ProfileState {
  const fallback: ProfileState = { profiles: [defaultProfile()], activeId: DEFAULT_PROFILE_ID }
  if (typeof raw !== 'object' || raw === null) return fallback
  const value = raw as Record<string, unknown>
  const list = Array.isArray(value.profiles) ? value.profiles : []

  const profiles: BrowserProfile[] = []
  for (const entry of list) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const partition = partitionFor(record.id)
    if (partition === null) continue
    const id = record.id as string
    if (profiles.some((p) => p.id === id)) continue
    profiles.push({
      id,
      name: cleanProfileName(record.name, id === DEFAULT_PROFILE_ID ? 'Default' : 'Profile'),
      partition,
      createdAt: typeof record.createdAt === 'number' ? record.createdAt : 0,
      isDefault: id === DEFAULT_PROFILE_ID,
    })
  }
  if (!profiles.some((p) => p.id === DEFAULT_PROFILE_ID)) profiles.unshift(defaultProfile())

  const wanted = value.activeId
  const activeId =
    typeof wanted === 'string' && profiles.some((p) => p.id === wanted) ? wanted : DEFAULT_PROFILE_ID
  return { profiles, activeId }
}

function defaultProfile(): BrowserProfile {
  return {
    id: DEFAULT_PROFILE_ID,
    name: 'Default',
    partition: DEFAULT_PARTITION,
    createdAt: 0,
    isDefault: true,
  }
}

/* ----------------------------------------------------------- persistence -- */

export function profilesPath(userData: string): string {
  return join(userData, 'browser-profiles.json')
}

function load(userData: string): ProfileState {
  const path = profilesPath(userData)
  if (!existsSync(path)) return readProfileState(null)
  try {
    return readProfileState(JSON.parse(readFileSync(path, 'utf8')) as unknown)
  } catch {
    return readProfileState(null)
  }
}

function save(userData: string, state: ProfileState): void {
  const path = profilesPath(userData)
  mkdirSync(dirname(path), { recursive: true })
  // Through a temporary file for the same reason `voice.ts` writes its key that
  // way: a half-written file is indistinguishable from a corrupt one, and the
  // failure would land on the next launch rather than on this one.
  const temporary = `${path}.tmp`
  writeFileSync(temporary, JSON.stringify({ version: 1, ...state }, null, 2))
  renameSync(temporary, path)
}

/* ---------------------------------------------------------- the sessions -- */

/**
 * Live profile sessions, by partition.
 *
 * `session.fromPartition` already returns the same object for the same string,
 * so this map is not a cache — it is the record of which sessions this module
 * has *hardened*, which is what {@link isProfileGuestSession} answers and what
 * stops a page in a second profile being treated as a stray WebContents.
 */
const hardened = new Map<string, Session>()

let recordPreloadPath: string | null = null

/**
 * Harden a profile partition.
 *
 * Deliberately the same list as `hardenedGuestSession()` in `browser-tab.ts`
 * and `harden()` in `browser-isolation.ts`. A page being looked at has no
 * business asking for the camera, the clipboard or a notification, and there is
 * no UI here to ask the user with.
 *
 * Downloads used to be in that list — `ses.on('will-download', (event) =>
 * event.preventDefault())`, right here — and they are not any more. They never
 * belonged: the permissions above are things a page takes without being asked,
 * and a download is something a person clicked. Refusing it silently was the
 * whole of *"Then I need to have downloads option"*. `browser-downloads.ts`
 * takes the event now, and it is called from **both** copies of this function or
 * an isolated tab would behave differently from an ordinary one.
 *
 * The recorder's guest script is attached **per session**, so a profile that
 * skipped it would look like it was recording and capture nothing — the exact
 * fault `browser-isolation.ts` calls out in its own copy of this function.
 */
function harden(ses: Session): Session {
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false))
  ses.setPermissionCheckHandler(() => false)
  attachDownloads(ses)
  if (recordPreloadPath === null) recordPreloadPath = writeRecordPreload(app.getPath('userData'))
  ses.registerPreloadScript({ type: 'frame', filePath: recordPreloadPath })
  return ses
}

/** The hardened session for a partition, minted once per run. */
export function sessionForPartition(partition: string): Session {
  const existing = hardened.get(partition)
  if (existing) return existing
  const ses = harden(session.fromPartition(partition))
  hardened.set(partition, ses)
  return ses
}

/**
 * Does this session belong to a profile?
 *
 * `browser-view.ts` needs it. That module recognises guest pages by comparing
 * their session to the shared one, so without this a page opened in a second
 * profile would never be claimed — losing zoom, devtools, screenshots, load
 * progress and recording, all with nothing on screen to say why. The identical
 * trap `isIsolatedGuestSession` exists for.
 */
export function isProfileGuestSession(candidate: Session): boolean {
  for (const ses of hardened.values()) {
    if (ses === candidate) return true
  }
  return false
}

/* --------------------------------------------------------------- the API -- */

/**
 * The one place the rest of the app asks "which profile is on".
 *
 * Held in memory and written through on every change, rather than read from
 * disk per call: `browser:create` consults it for every new tab and a file read
 * per tab would be a syscall on a path a person is waiting on.
 */
let state: ProfileState | null = null
let userDataDir: string | null = null

function ensure(userData: string): ProfileState {
  if (state === null || userDataDir !== userData) {
    userDataDir = userData
    state = load(userData)
  }
  return state
}

/** For tests, which must not inherit each other's state. */
export function resetProfilesForTests(): void {
  state = null
  userDataDir = null
  hardened.clear()
}

export function profileState(userData: string): ProfileState {
  return ensure(userData)
}

/** The session every new tab joins, unless it asked to be Isolated. */
export function activeProfileSession(userData: string): Session {
  const current = ensure(userData)
  const profile = current.profiles.find((p) => p.id === current.activeId)
  return sessionForPartition(profile ? profile.partition : DEFAULT_PARTITION)
}

/** The active profile itself, for anything that needs its name or partition. */
export function activeProfile(userData: string): BrowserProfile {
  const current = ensure(userData)
  return current.profiles.find((p) => p.id === current.activeId) ?? defaultProfile()
}

export function createProfile(userData: string, name: unknown): BrowserProfile {
  const current = ensure(userData)
  const id = randomUUID()
  const partition = partitionFor(id)
  // Unreachable — `randomUUID` produces exactly the shape `partitionFor`
  // accepts — but a throw here is better than a profile with a null partition
  // reaching `fromPartition` and creating a directory called "null".
  if (partition === null) throw new Error('browser-profiles: could not mint a partition')
  const profile: BrowserProfile = {
    id,
    name: cleanProfileName(name, `Profile ${current.profiles.length + 1}`),
    partition,
    createdAt: Date.now(),
    isDefault: false,
  }
  current.profiles.push(profile)
  save(userData, current)
  return profile
}

export function renameProfile(userData: string, id: unknown, name: unknown): ProfileState {
  const current = ensure(userData)
  const profile = current.profiles.find((p) => p.id === id)
  if (profile) {
    profile.name = cleanProfileName(name, profile.name)
    save(userData, current)
  }
  return current
}

export function activateProfile(userData: string, id: unknown): ProfileState {
  const current = ensure(userData)
  if (current.profiles.some((p) => p.id === id)) {
    current.activeId = id as string
    save(userData, current)
  }
  return current
}

/**
 * Delete a profile and everything in it.
 *
 * The default one is refused rather than silently ignored: it holds the logins
 * from every build before this feature existed, and "delete" is not a word to be
 * quietly disobeyed. Deleting the *active* profile falls back to the default,
 * because leaving `activeId` pointing at something gone would send every new tab
 * to an empty partition with nothing on screen to explain it.
 *
 * The storage is cleared before the entry goes. If it were the other way round a
 * failed clear would leave a directory on disk that nothing in the app could
 * ever name again, which is a leak that survives reinstalling.
 */
export async function deleteProfile(userData: string, id: unknown): Promise<ProfileState> {
  const current = ensure(userData)
  if (id === DEFAULT_PROFILE_ID) throw new Error('The default profile cannot be deleted.')
  const index = current.profiles.findIndex((p) => p.id === id)
  if (index < 0) return current
  const [gone] = current.profiles.splice(index, 1)
  try {
    const ses = sessionForPartition(gone.partition)
    await ses.clearStorageData()
    await ses.clearCache()
    hardened.delete(gone.partition)
  } catch {
    // A partition that was never opened has nothing to clear, and a clear that
    // fails is not a reason to keep an entry the person asked to be rid of.
  }
  if (current.activeId === gone.id) current.activeId = DEFAULT_PROFILE_ID
  save(userData, current)
  return current
}

/* -------------------------------------------------------------- register -- */

/**
 * Wire browser profiles. Call once from `registerIpc()`:
 *
 *     import { registerBrowserProfileIpc } from './browser-profiles'
 *     registerBrowserProfileIpc(ipcMain, () => app.getPath('userData'))
 *
 * Channels:
 * - `browser-profile:list`     (invoke)             → {@link ProfileState}
 * - `browser-profile:create`   (invoke, name)       → {@link ProfileState}
 * - `browser-profile:rename`   (invoke, id, name)   → {@link ProfileState}
 * - `browser-profile:activate` (invoke, id)         → {@link ProfileState}
 * - `browser-profile:delete`   (invoke, id)         → {@link ProfileState}
 */
export function registerBrowserProfileIpc(ipcMain: IpcMain, userData: () => string): void {
  ipcMain.handle('browser-profile:list', () => profileState(userData()))
  ipcMain.handle('browser-profile:create', (_event, name: unknown) => {
    createProfile(userData(), name)
    return profileState(userData())
  })
  ipcMain.handle('browser-profile:rename', (_event, id: unknown, name: unknown) =>
    renameProfile(userData(), id, name),
  )
  ipcMain.handle('browser-profile:activate', (_event, id: unknown) => activateProfile(userData(), id))
  ipcMain.handle('browser-profile:delete', (_event, id: unknown) => deleteProfile(userData(), id))
}
