import { createHash, timingSafeEqual } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import {
  CANNOT_INSTALL_CRX,
  displayName,
  everywhere,
  loadability,
  missingApis,
  parseManifest,
  popupPage,
  reachOf,
  usesStaticRulesets,
  type ExtensionManifest,
} from './browser-extension-support'
import { manifestPrefix, unzip } from './browser-extension-unzip'

/**
 * The extension store: what may be offered, what is unpacked on disk, and the
 * verification between the two.
 *
 * ## What he asked for
 *
 *   > *"extensions store needs to be a proper store from where we can see most
 *   > famous open source tools to attach to the browser and use there with
 *   > session ai."*
 *
 * The tools store beside this one is a different thing and stays a different
 * thing: it installs **recipes**, which are selectors this app's own code runs,
 * and its whole safety argument is that *"an agent contributes data and never
 * code"*. This one installs **programs written by other people that run inside
 * the browser**. Nothing about the first argument transfers, so this module does
 * not borrow it. What it borrows is the discipline: a pinned digest checked
 * before anything is written, a remove that reads the disk back, and a refusal
 * that says which check refused it.
 *
 * ## Per profile, because everything else in this browser is
 *
 * An install lands in `<userData>/browser-extensions/<profileId>/<id>/`, and the
 * extension is loaded into that profile's session and no other. Two reasons, and
 * the second is not optional:
 *
 *  1. `browser-profiles.ts` exists so that *"separate people, or separate
 *     logins"* have separate cookie jars. An extension with `<all_urls>` reads
 *     every page in the profile it is loaded into. A store that installed
 *     globally would put a program with that reach into a profile somebody
 *     created specifically to keep something apart.
 *  2. Electron gives no choice about part of it: extensions load into a
 *     `Session`, and *"Extensions cannot be loaded in a temporary session"*.
 *     Sessions here are per profile. There is no global place to put one.
 *
 * A consequence worth knowing: because Electron derives an extension's id from
 * its **directory path**, the same extension installed in two profiles has two
 * different `chrome-extension://` ids. Nothing keys on that id across profiles,
 * and this module's own id — the catalogue's — is what every screen and every
 * tool names.
 *
 * ## The four questions, and this store's answers
 *
 * **Where do the bytes come from and how is identity checked?** From the entry's
 * pinned `https` URL, at a pinned byte count, against a pinned sha256 that lives
 * in this app's own bytes. Length first as a cheap early-out, then the digest
 * over everything that passes — the same order and the same reasoning as
 * `browser-store.ts` and `verifyArchive`. A download that does not match is not
 * unpacked, and nothing is written.
 *
 * **May a new extension gain reach nobody disclosed?** The manifest inside the
 * archive is read *before the archive is written to disk*, and what it asks for
 * is reported. Unlike the tools store this is disclosure rather than a bound:
 * Electron has no way to load an extension with fewer permissions than its
 * manifest asks for, so the honest arrangement is to say exactly what it will
 * have and let somebody decide, not to imply a ceiling that does not exist.
 * {@link installedExtensions} therefore reports `reach` on every row, always,
 * and `ExtensionsPanel` prints it before the button rather than after.
 *
 * **Do install and remove both work?** {@link ExtensionStore.remove} deletes the
 * directory and then reads the disk back, for the reason its neighbour gives:
 * three scripts in the pipeline this app comes out of *"reported success while
 * doing nothing"*, and an uninstall is the worst place for that. Removing also
 * unloads it from the live session, through the seam in
 * `browser-extensions-ipc.ts` — a row that said Removed while the program was
 * still running in the browser would be a lie of the exact kind this round is
 * about.
 *
 * **What if it cannot be verified?** It does not install, and the sentence names
 * the check: the length, the digest, the archive, the manifest, or the network.
 *
 * ## What is deliberately not here
 *
 * No `.crx`, ever — {@link CANNOT_INSTALL_CRX}. No "install from a URL you
 * typed": the digest is the whole security model and there is nothing to check
 * an arbitrary URL against. No auto-update: Electron has no update channel for
 * extensions, and a store that quietly re-downloaded would be replacing a
 * verified program with an unverified one on a timer.
 */

/* -------------------------------------------------------------- the shapes -- */

/** Where an entry's bytes come from. `null` for an entry that cannot be installed. */
export interface ExtensionSource {
  /** An exact https URL to a release asset. */
  url: string
  /** Its exact byte count, so a short transfer is refused before it is hashed. */
  bytes: number
  /** Hex sha256 of the archive, pinned in this app and nowhere else. */
  sha256: string
}

/**
 * How this app found the extension behaving on the Electron it ships.
 *
 * Three values and no fourth. `works` is reserved for an extension that was
 * watched doing the thing it exists to do — not one that loaded, and not one
 * whose manifest looks fine. The distinction is the entire honesty of this
 * feature: every extension in the catalogue loads.
 */
export type ExtensionVerdict = 'works' | 'partly' | 'no'

/** One row of the curated table. */
export interface ExtensionEntry {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  works: ExtensionVerdict
  /** What was observed, in a sentence. Never a claim about what should happen. */
  measured: string
  /**
   * The host patterns its manifest asks for, copied out of the release this row
   * pins, so a row states its reach **before** anybody installs it.
   *
   * The tools store next door does the same thing with grants and origins and
   * gives the reason: the row is the disclosure, so *"what is on screen and what
   * runs are the same thing or neither happens"*. That is enforced here the same
   * way — {@link agreesWithRow} refuses an install whose manifest asks for more
   * than this line said, so a release that quietly widened its reach between
   * versions is caught by the row it disagrees with rather than by nobody.
   */
  reach: readonly string[]
  /** `null` when `works` is `no` — there is nothing worth pinning. */
  source: ExtensionSource | null
}

export type ExtensionCatalogue = readonly ExtensionEntry[]

/** What a row is doing right now, on one profile. */
export type ExtensionState = 'available' | 'installed' | 'damaged' | 'unavailable'

/** One row as a panel draws it. */
export interface StoreExtension {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  works: ExtensionVerdict
  measured: string
  /** `''` for an entry with no download. */
  url: string
  sha256: string
  bytes: number
  state: ExtensionState
  /** The version of the manifest actually on disk, when there is one. */
  installedVersion: string
  installedAt: number
  /** Whether it is loaded into the profile's session right now. */
  enabled: boolean
  /** What its manifest asks to reach. Read off the disk once installed. */
  reach: string[]
  /** True when its content scripts run on every page. */
  everywhere: boolean
  /** `chrome.*` it asks for that this browser does not have. */
  missing: string[]
  /** The page its toolbar button opens, or `''`. */
  popup: string
  /**
   * True when its blocking rests on manifest `declarativeNetRequest` rulesets.
   *
   * On the row because those are measured not to be switched on when an
   * extension loads here, and nothing else on a row would show it: the extension
   * installs, loads, draws its button and blocks nothing. See
   * `browser-extension-support.ts` for the measurement.
   */
  staticRulesets: boolean
  /** Why it is damaged or unavailable, or `''`. */
  message: string
}

export interface ExtensionStoreView {
  profileId: string
  profileName: string
  extensions: StoreExtension[]
  /** Absolute, so a panel can say where installs live. */
  folder: string
}

export type ExtensionResult = { ok: boolean; message: string }

/** An installed, verified extension, as the loader needs it. */
export interface InstalledExtension {
  entry: ExtensionEntry
  /** The directory to hand `loadExtension`. */
  dir: string
  manifest: ExtensionManifest
  installedAt: number
  enabled: boolean
}

/* -------------------------------------------------------------- the digest -- */

export function sha256Hex(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex')
}

/**
 * Are these the bytes the catalogue wrote down?
 *
 * Lifted in shape from `browser-store.ts` and for its stated reason: comparing
 * decoded buffers forces the expected digest to be decoded and length-checked
 * first, *"which is where a truncated or differently-encoded digest gets caught
 * instead of being blamed on the download."*
 */
export function digestMatches(bytes: Buffer, expectedHex: string): boolean {
  if (!/^[0-9a-f]{64}$/i.test(expectedHex)) return false
  const expected = Buffer.from(expectedHex.toLowerCase(), 'hex')
  const actual = Buffer.from(sha256Hex(bytes), 'hex')
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

/* --------------------------------------------------------------- the paths -- */

/** An entry id is a directory name, so it is checked before it is ever joined. */
const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/

/**
 * A profile id is a directory name too.
 *
 * Must accept exactly what `partitionFor` in `browser-profiles.ts` accepts: the
 * literal `default`, or a UUID. Written out again rather than imported because
 * that module reaches for `electron` at its top level and everything in this one
 * is testable without an app. `browser-extensions.test.ts` asserts the two agree
 * on a table of ids, which is the part that would otherwise drift.
 */
export function safeProfileId(id: unknown): string | null {
  if (id === 'default') return 'default'
  if (typeof id !== 'string') return null
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id) ? id : null
}

export function extensionsRoot(userData: string): string {
  return join(userData, 'browser-extensions')
}

export function profileExtensionsRoot(userData: string, profileId: string): string | null {
  const safe = safeProfileId(profileId)
  return safe === null ? null : join(extensionsRoot(userData), safe)
}

/* ------------------------------------------------------------- the ceiling -- */

/**
 * The most an extension archive may be, and unpack to.
 *
 * uBlock Origin Lite's release is 9.7 MB packed and the largest thing the
 * catalogue has ever pointed at; 32 MB packed and 256 MB unpacked leaves room
 * for a project that grows without leaving room for an archive that is trying
 * to fill a disk. Applied to what actually arrives and to what actually comes
 * out, never to what a header or a zip index claims.
 */
export const MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
export const MAX_UNPACKED_BYTES = 256 * 1024 * 1024
export const MAX_FILES = 20_000

/* -------------------------------------------------------------- fetching -- */

export interface FetchedArchive {
  ok: boolean
  bytes: Buffer
  message: string
}

export type FetchArchive = (url: string, limit: number) => Promise<FetchedArchive>

/**
 * Read a pinned URL, over https, up to a hard byte ceiling.
 *
 * `redirect: 'follow'` here, where the tools store uses `'error'`, and the
 * difference is not carelessness: a GitHub release asset URL is *defined* to
 * redirect to object storage, so refusing redirects would mean this store could
 * never fetch anything at all. What makes that safe is that the redirect target
 * is never trusted with anything — the archive is checked against a digest
 * pinned in this app's bytes, so a redirect to a hostile host produces a refusal
 * rather than an install. The scheme is still checked on the URL this app holds.
 */
export const httpsFetchArchive: FetchArchive = async (url, limit) => {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, bytes: Buffer.alloc(0), message: 'that is not a URL' }
  }
  if (parsed.protocol !== 'https:') {
    return { ok: false, bytes: Buffer.alloc(0), message: 'an extension can only be fetched over https' }
  }
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(120_000) })
    if (!response.ok) {
      return { ok: false, bytes: Buffer.alloc(0), message: `the download answered ${response.status}` }
    }
    const buffer = Buffer.from(await response.arrayBuffer())
    if (buffer.byteLength > limit) {
      return { ok: false, bytes: Buffer.alloc(0), message: `the download is larger than ${limit} bytes` }
    }
    return { ok: true, bytes: buffer, message: '' }
  } catch (error) {
    return {
      ok: false,
      bytes: Buffer.alloc(0),
      message: error instanceof Error ? `the download failed: ${error.message}` : 'the download failed',
    }
  }
}

/* ---------------------------------------------------------------- on disk -- */

interface OnDisk {
  version: string
  sha256: string
  installedAt: number
  enabled: boolean
}

const RECORD = 'installed.json'

function readOnDisk(dir: string): OnDisk | null {
  try {
    const raw: unknown = JSON.parse(readFileSync(join(dir, RECORD), 'utf8'))
    if (typeof raw !== 'object' || raw === null) return null
    const value = raw as Record<string, unknown>
    return {
      version: typeof value.version === 'string' ? value.version : '',
      sha256: typeof value.sha256 === 'string' ? value.sha256 : '',
      installedAt: typeof value.installedAt === 'number' ? value.installedAt : 0,
      // Absent means on. Everything written by this app writes the field, so an
      // absent one is a record from a build that had no switch — and the state
      // that build was in was loaded.
      enabled: value.enabled !== false,
    }
  } catch {
    return null
  }
}

/* --------------------------------------------------------------- the store -- */

export interface ExtensionStoreOptions {
  /** `<userData>`. Profile directories are made under it. */
  userData: string
  catalogue: ExtensionCatalogue
  /** Replaced in tests. Production passes nothing and gets {@link httpsFetchArchive}. */
  fetchArchive?: FetchArchive
  now?: () => number
}

export interface ExtensionStore {
  view(profileId: string, profileName: string): ExtensionStoreView
  install(profileId: string, id: string): Promise<ExtensionResult>
  remove(profileId: string, id: string): ExtensionResult
  /** Turn one on or off without deleting it. */
  setEnabled(profileId: string, id: string, on: boolean): ExtensionResult
  /** Every verified install for one profile. What the loader replays at launch. */
  installed(profileId: string): InstalledExtension[]
  /** Every profile that has anything installed, so launch knows where to look. */
  profilesWithExtensions(): string[]
}

/** The directories the loader must not treat as an extension. */
const NOT_AN_EXTENSION = new Set([RECORD])

/**
 * Does a stated reach cover every page?
 *
 * The catalogue's copy of the question {@link everywhere} answers about a
 * manifest, so a row can say "every page you open in this profile" before there
 * is a manifest to read. One rule, two inputs — and the install check below is
 * what stops the two answers ever being about different things.
 */
function everywhereIn(reach: readonly string[]): boolean {
  if (reach.includes('<all_urls>')) return true
  return reach.some((pattern) => /^\*:\/\/\*\/\*$|^https?:\/\/\*\/\*$/.test(pattern))
}

/**
 * The manifest may not ask for more than the row a person read.
 *
 * Lifted from `agreesWithRow` in `browser-store.ts`, and its argument applies
 * unchanged: *"The store row is the disclosure; the recipe is the thing that
 * runs. When they disagree the honest answer is neither."* Here the thing that
 * runs is a program with the reach its manifest declares, so a release that
 * widened `host_permissions` since this catalogue was written must not install
 * quietly under a row that still says the old, narrower thing.
 *
 * Narrower than the row is fine and is not a refusal: the row over-stated, the
 * person agreed to more than they got, and nobody is worse off.
 */
function widerThanRow(entry: ExtensionEntry, manifest: ExtensionManifest): string {
  const asked = reachOf(manifest)
  const extra = asked.filter((pattern) => !entry.reach.includes(pattern))
  if (extra.length === 0) return ''
  return `it asks to read ${extra.join(', ')}, which is not what this store row says it reaches`
}

export function createExtensionStore(options: ExtensionStoreOptions): ExtensionStore {
  const fetchArchive = options.fetchArchive ?? httpsFetchArchive
  const now = options.now ?? Date.now
  const entryFor = (id: string): ExtensionEntry | null =>
    options.catalogue.find((entry) => entry.id === id) ?? null

  function dirFor(profileId: string, id: string): string | null {
    const root = profileExtensionsRoot(options.userData, profileId)
    if (root === null || !SAFE_ID.test(id)) return null
    return join(root, id)
  }

  /**
   * Read one installed extension back off the disk, verifying it on the way.
   *
   * The manifest is re-read rather than remembered. `<userData>` is writable by
   * every process running as this user, and the manifest is what decides what
   * the extension may reach — so a row that printed a `reach` remembered from
   * install time would keep printing the old answer after somebody widened it.
   */
  function load(
    profileId: string,
    entry: ExtensionEntry,
  ): { extension: InstalledExtension } | { why: string } | null {
    const dir = dirFor(profileId, entry.id)
    if (dir === null) return null
    const file = join(dir, 'manifest.json')
    if (!existsSync(file)) return null
    let bytes: string
    try {
      bytes = readFileSync(file, 'utf8')
    } catch {
      return { why: 'its manifest could not be read' }
    }
    const parsed = parseManifest(bytes)
    if (!parsed.ok) return { why: parsed.why }
    const disk = readOnDisk(dir)
    if (disk === null) {
      return { why: 'this app has no record of installing it — remove it and install again' }
    }
    if (disk.sha256 !== entry.source?.sha256) {
      /*
       * The install on disk came from a different download than the one this
       * build offers. Reported rather than silently replaced: replacing would
       * throw away whatever settings the extension had stored, and doing that
       * without asking is not a store's decision to make.
       */
      return {
        why: `it was installed from a different release than this version of the app offers — remove it and install again`,
      }
    }
    return {
      extension: {
        entry,
        dir,
        manifest: parsed.manifest,
        installedAt: disk.installedAt,
        enabled: disk.enabled,
      },
    }
  }

  function writeRecord(dir: string, record: OnDisk & { id: string }): void {
    writeFileAtomic(join(dir, RECORD), `${JSON.stringify(record, null, 2)}\n`)
  }

  return {
    view(profileId: string, profileName: string): ExtensionStoreView {
      const root = profileExtensionsRoot(options.userData, profileId)
      const extensions: StoreExtension[] = options.catalogue.map((entry) => {
        const base = {
          id: entry.id,
          name: entry.name,
          summary: entry.summary,
          homepage: entry.homepage,
          licence: entry.licence,
          version: entry.version,
          works: entry.works,
          measured: entry.measured,
          url: entry.source?.url ?? '',
          sha256: entry.source?.sha256 ?? '',
          bytes: entry.source?.bytes ?? 0,
          installedVersion: '',
          installedAt: 0,
          enabled: false,
          // Stated from the catalogue before there is a manifest, and replaced
          // by the manifest's own answer the moment there is one.
          reach: [...entry.reach],
          everywhere: everywhereIn(entry.reach),
          missing: [] as string[],
          popup: '',
          staticRulesets: false,
          message: '',
        }
        /*
         * An entry with no download is not "available". `available` is the state
         * whose button says Install, and an entry in this state has no bytes to
         * install — so it gets a state of its own and the panel draws no button
         * for it. A row that offered Install and could only ever fail is the
         * control-that-does-nothing this whole round exists to remove.
         */
        if (entry.source === null) {
          return { ...base, state: 'unavailable' as const, message: entry.measured }
        }
        const loaded = root === null ? null : load(profileId, entry)
        if (loaded === null) return { ...base, state: 'available' as const }
        if ('why' in loaded) {
          return {
            ...base,
            state: 'damaged' as const,
            installedVersion: readOnDisk(dirFor(profileId, entry.id) ?? '')?.version ?? '',
            message: loaded.why,
          }
        }
        const { manifest, installedAt, enabled } = loaded.extension
        return {
          ...base,
          state: 'installed' as const,
          installedVersion: typeof manifest.version === 'string' ? manifest.version : '',
          installedAt,
          enabled,
          reach: reachOf(manifest),
          everywhere: everywhere(manifest),
          missing: missingApis(manifest),
          popup: popupPage(manifest),
          staticRulesets: usesStaticRulesets(manifest),
        }
      })
      return {
        profileId,
        profileName,
        extensions,
        folder: root ?? '',
      }
    },

    async install(profileId: string, id: string): Promise<ExtensionResult> {
      const dir = dirFor(profileId, id)
      if (dir === null) return { ok: false, message: 'That is not an extension this app can install.' }
      const entry = entryFor(id)
      if (entry === null) return { ok: false, message: 'This store has no extension by that name.' }
      if (entry.source === null) {
        /*
         * Reachable over IPC even though no button draws for it, so it is
         * answered here rather than assumed impossible. The sentence is the
         * measurement itself — the same words the row shows, so a caller that
         * went round the screen gets the same truth the screen gives.
         */
        return {
          ok: false,
          message: `${entry.name} cannot work in this browser, so this app does not install it. ${entry.measured}`,
        }
      }
      if (entry.source.url.endsWith('.crx')) {
        return { ok: false, message: `${entry.name} was not installed: ${CANNOT_INSTALL_CRX}` }
      }

      const got = await fetchArchive(entry.source.url, Math.min(entry.source.bytes, MAX_ARCHIVE_BYTES))
      if (!got.ok) return { ok: false, message: `${entry.name} was not installed: ${got.message}.` }
      if (got.bytes.byteLength !== entry.source.bytes) {
        return {
          ok: false,
          message:
            `${entry.name} was not installed: the download is ${got.bytes.byteLength} bytes and ` +
            `this app expects ${entry.source.bytes}.`,
        }
      }
      if (!digestMatches(got.bytes, entry.source.sha256)) {
        return {
          ok: false,
          message:
            `${entry.name} was not installed: these are not the bytes this app has written down ` +
            `for it. Nothing was saved.`,
        }
      }

      const opened = unzip(got.bytes, { maxTotalBytes: MAX_UNPACKED_BYTES, maxFiles: MAX_FILES })
      if (!opened.ok) {
        return { ok: false, message: `${entry.name} was not installed: ${opened.why}.` }
      }
      const prefix = manifestPrefix(opened.files)
      if (prefix === null) {
        return {
          ok: false,
          message: `${entry.name} was not installed: the download has no manifest.json in it.`,
        }
      }
      const manifestFile = opened.files.find((file) => file.path === `${prefix}manifest.json`)
      const parsed = parseManifest(manifestFile?.bytes.toString('utf8') ?? '')
      if (!parsed.ok) {
        return { ok: false, message: `${entry.name} was not installed: ${parsed.why}.` }
      }
      const wider = widerThanRow(entry, parsed.manifest)
      if (wider !== '') {
        return { ok: false, message: `${entry.name} was not installed: ${wider}.` }
      }
      const can = loadability(parsed.manifest)
      if (!can.ok) {
        /*
         * Refused before anything is written, because this is a shape Chromium
         * rejects at load: it would install cleanly, then fail every time the
         * app started, and the row would say Installed forever about a program
         * that has never once run.
         */
        return { ok: false, message: `${entry.name} was not installed: ${can.why}.` }
      }

      /*
       * A reinstall replaces rather than merges. A directory left over from an
       * older release with files the new one no longer ships is a mixture of two
       * extensions, and `loadExtension` would run it.
       */
      try {
        rmSync(dir, { recursive: true, force: true })
        mkdirSync(dir, { recursive: true })
        for (const file of opened.files) {
          if (!file.path.startsWith(prefix)) continue
          const relative = file.path.slice(prefix.length)
          if (relative === '' || NOT_AN_EXTENSION.has(relative)) continue
          const target = join(dir, relative)
          mkdirSync(dirname(target), { recursive: true })
          writeFileSync(target, file.bytes)
        }
        writeRecord(dir, {
          id,
          version: typeof parsed.manifest.version === 'string' ? parsed.manifest.version : '',
          sha256: entry.source.sha256,
          installedAt: now(),
          enabled: true,
        })
      } catch (error) {
        // A half-written extension is worse than none: it has a manifest and
        // missing files, so it loads and misbehaves. Torn down rather than left.
        try {
          rmSync(dir, { recursive: true, force: true })
        } catch {
          /* Nothing better to do, and the message below says it did not install. */
        }
        return {
          ok: false,
          message: `${entry.name} was not installed: ${error instanceof Error ? error.message : 'it could not be saved'}.`,
        }
      }

      /*
       * The confirmation names a place, per `FEATURE-STORE.md`: *"a short
       * confirmation says **where to find it** — the menu, the panel, the
       * settings section."* Here that is the profile, because the profile is the
       * whole of where an extension is and is not.
       */
      const name = displayName(parsed.manifest, entry.name)
      const gaps = missingApis(parsed.manifest)
      const note =
        gaps.length === 0
          ? ''
          : ` It asks for ${gaps.map((api) => `chrome.${api}`).join(', ')}, which this browser does not have, so whatever it uses those for will not work.`
      const rulesets = usesStaticRulesets(parsed.manifest)
        ? ' Its filter lists ship as manifest declarativeNetRequest rulesets, which this browser does not switch on.'
        : ''
      return {
        ok: true,
        message: `${name} is installed in this profile and switched on.${note}${rulesets}`,
      }
    },

    remove(profileId: string, id: string): ExtensionResult {
      const dir = dirFor(profileId, id)
      if (dir === null) return { ok: false, message: 'That is not an extension this app installed.' }
      const entry = entryFor(id)
      if (!existsSync(dir)) return { ok: true, message: 'It was not installed.' }
      try {
        rmSync(dir, { recursive: true, force: true })
      } catch (error) {
        return {
          ok: false,
          message: `It could not be removed: ${error instanceof Error ? error.message : 'the folder would not go'}.`,
        }
      }
      // Read the disk back before saying it is gone — `browser-store.ts` has the
      // history that makes this non-negotiable.
      if (existsSync(dir)) {
        return { ok: false, message: 'It could not be removed: the folder is still on disk.' }
      }
      return {
        ok: true,
        message: `${entry?.name ?? 'The extension'} is removed. Its files are deleted.`,
      }
    },

    setEnabled(profileId: string, id: string, on: boolean): ExtensionResult {
      const dir = dirFor(profileId, id)
      const entry = entryFor(id)
      if (dir === null || entry === null) {
        return { ok: false, message: 'That is not an extension this app installed.' }
      }
      const disk = readOnDisk(dir)
      if (disk === null) return { ok: false, message: 'It is not installed in this profile.' }
      try {
        writeRecord(dir, { id, ...disk, enabled: on })
      } catch (error) {
        return {
          ok: false,
          message: `That could not be saved: ${error instanceof Error ? error.message : 'the file would not write'}.`,
        }
      }
      return {
        ok: true,
        message: on ? `${entry.name} is switched on.` : `${entry.name} is switched off.`,
      }
    },

    installed(profileId: string): InstalledExtension[] {
      const out: InstalledExtension[] = []
      for (const entry of options.catalogue) {
        const loaded = load(profileId, entry)
        if (loaded !== null && 'extension' in loaded) out.push(loaded.extension)
      }
      return out
    },

    profilesWithExtensions(): string[] {
      let names: string[]
      try {
        names = readdirSync(extensionsRoot(options.userData), { withFileTypes: true })
          .filter((entry) => entry.isDirectory())
          .map((entry) => entry.name)
      } catch {
        return []
      }
      return names.filter((name) => safeProfileId(name) !== null).sort()
    },
  }
}

/**
 * Directories under a profile's root with no catalogue row.
 *
 * The same leak `orphanIds` exists for next door: an extension withdrawn from
 * the app between releases leaves its unpacked files behind, and nothing above
 * would ever name them again. Reported rather than deleted on sight, so a panel
 * can offer a Remove — and these are megabytes rather than a JSON file, which is
 * what makes it worth the row.
 */
export function orphanExtensionIds(
  userData: string,
  profileId: string,
  catalogue: ExtensionCatalogue,
): string[] {
  const root = profileExtensionsRoot(userData, profileId)
  if (root === null) return []
  let names: string[]
  try {
    names = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
  } catch {
    return []
  }
  const known = new Set(catalogue.map((entry) => entry.id))
  return names.filter((name) => SAFE_ID.test(name) && !known.has(name)).sort()
}
