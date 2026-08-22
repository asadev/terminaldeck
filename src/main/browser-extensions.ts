import { createHash, timingSafeEqual } from 'node:crypto'
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import {
  CANNOT_INSTALL_CRX,
  displayName,
  everywhere,
  loadability,
  mayAskToReach,
  missingApis,
  optionsPageOf,
  parseManifest,
  popupPage,
  reachOf,
  usesStaticRulesets,
  type ExtensionManifest,
} from './browser-extension-support'
import { openCrx } from './browser-extension-crx'
import { applyCompat, planCompat, type CompatReport } from './browser-extension-compat'
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
 * and `ExtensionRow` prints it before the button rather than after.
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
export type ExtensionVerdict = 'works' | 'partly' | 'no' | 'unmeasured'

/**
 * Where a row sits in the store, so a catalogue this size browses instead of
 * scrolling.
 *
 * Sections rather than tags: an extension belongs to one of these, and a row
 * that appeared under three headings would make the store look bigger than it
 * is, which is the one thing a store must never do about itself.
 */
/**
 * Something a person has to bring before a row can do its job — not something
 * this browser is missing.
 *
 * Deliberately narrow, and it stays narrow — two values, not a general-purpose
 * `setup` that would have made the filter answer a question nobody asked.
 *
 * It was written when it could say something stronger: *"a browser extension
 * needs nothing from you: you install it and it runs"*, with exactly two
 * exceptions in the catalogue. That held while every row was an open-source
 * project. It stopped holding on 2026-08-23, when the store gained the
 * extensions people actually arrive looking for — Grammarly, LastPass, Loom,
 * the Google ones — every one of which is a client for an account and does
 * nothing at all without one.
 *
 * So `account` is now a fact about ten rows rather than one, and
 * `companion-app` is still exactly one: a second program running on this
 * machine really is rare. What did not change is that most of the catalogue
 * needs nothing, and `browser-extension-catalogue.test.ts` holds it there — an
 * extension store where most rows want an account would be a store of services
 * with a browser attached.
 *
 * The MCP store's version of this facet has different values for the same
 * reason: an MCP server genuinely can want an API key or a directory, and
 * pretending both catalogues need the same vocabulary would mean one of them
 * offering a filter that matches nothing.
 */
export type ExtensionNeed =
  /** An account with a service, signed into inside the extension. */
  | 'account'
  /** A second program running on this machine that it talks to. */
  | 'companion-app'

/**
 * What using the extension costs, once it is installed.
 *
 * ## Why an extension store needs this at all
 *
 * Because the catalogue stopped being all open source. Asad:
 *
 *   > *"maybe some other tools paid ones too not just open source … and also all
 *   > other regular tools too like google's ones or like this."*
 *
 * Every extension in a browser store is a free download — that is what a browser
 * store *is* — and for the open-source half that was the whole story. It is not
 * the story for 1Password, whose extension is free and useless without a
 * subscription, or for Loom, whose free plan caps a recording at five minutes.
 * A row that said nothing would be letting *free to install* stand in for *free
 * to use*, and those are different sentences.
 *
 * Five values, mirroring `store/storefront.ts`, which argues them. `unknown` is
 * for the one row this app genuinely cannot answer for: something a person added
 * themselves, which it has never seen and will not guess about.
 */
export type ExtensionCost = 'free' | 'account' | 'metered' | 'paid' | 'unknown'

export type ExtensionCategory =
  | 'blocking'
  | 'privacy'
  | 'appearance'
  | 'media'
  | 'passwords'
  | 'writing'
  | 'work'
  | 'shopping'
  | 'research'
  | 'scripting'
  | 'your-own'

/** The categories, in the order the store draws them, with the name each wears. */
export const EXTENSION_CATEGORIES: readonly { id: ExtensionCategory; name: string }[] = [
  { id: 'blocking', name: 'Blocking ads and trackers' },
  { id: 'privacy', name: 'Privacy and cleaning up' },
  { id: 'appearance', name: 'How pages look' },
  { id: 'media', name: 'Video and audio' },
  { id: 'passwords', name: 'Passwords' },
  { id: 'writing', name: 'Writing and language' },
  { id: 'work', name: 'Documents and work' },
  { id: 'shopping', name: 'Shopping' },
  { id: 'research', name: 'Saving and research' },
  { id: 'scripting', name: 'Scripting and the keyboard' },
  { id: 'your-own', name: 'Added by you' },
]

/** One row of the curated table. */
export interface ExtensionEntry {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  /** Which shelf it sits on. */
  category: ExtensionCategory
  /**
   * Words somebody might type that are in neither the name nor the summary.
   *
   * Not a second set of shelves — a row still sits on exactly one of those. This
   * is what makes *adblock* find uBlock Origin, whose summary is the four words
   * "The wide-spectrum content blocker" and contains neither *ad* nor *block* as
   * a word anybody would type. Before this, the single most likely thing to type
   * into an extension store matched nothing at all.
   */
  tags: readonly string[]
  /** What a person has to bring. Absent on almost everything, and that is the point. */
  needs?: readonly ExtensionNeed[]
  /** What using it costs. See {@link ExtensionCost}. */
  cost: ExtensionCost
  /**
   * The price reality in one sentence, on the row, **before** anything is
   * pressed. Required for everything that is not `free`, and
   * `browser-extension-catalogue.test.ts` fails a row that skips it.
   */
  costNote: string
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
  /**
   * What it may **ask** to reach later and never gets, from the release this row
   * pins. Empty for almost everything.
   *
   * On the row because `optional_host_permissions` is a real part of a manifest
   * and this browser can never grant one: there is no runtime prompt, and the
   * compatibility layer answers `permissions.request()` with `false`. An
   * extension built around asking for more when it needs it therefore stays at
   * whatever it declared, and a person deciding whether to install it is
   * entitled to know that before rather than after.
   */
  mayAskToReach?: readonly string[]
  /**
   * Why this app pins no download, for a row it never ran.
   *
   * The third answer to *"where is Vimium"*, and it exists because the other two
   * were both wrong. "It is not in the list" is what somebody gets today, and it
   * reads as *never heard of it*. "It cannot work here" is a lie — nothing was
   * run, because there was nothing to run: the project publishes its extension
   * through the Chrome Web Store and its releases carry no file this app could
   * fetch and pin a fingerprint to.
   *
   * Set only on a row whose {@link works} is `unmeasured`, and such a row has no
   * source, no button, and no verdict borrowed from anywhere.
   */
  noRelease?: string
  /** `null` when there is nothing worth pinning: a measured refusal, or no release. */
  source: ExtensionSource | null
}

export type ExtensionCatalogue = readonly ExtensionEntry[]

/**
 * What a row is doing right now, on one profile.
 *
 * `unavailable` and `not-offered` are both buttonless and they are not the same
 * thing, which is the whole reason for the second one: `unavailable` is *this
 * app ran it here and watched it fail*, and `not-offered` is *this app has never
 * run it, because its project publishes nothing to run*. Collapsing them would
 * put a measurement's authority behind a row nobody measured.
 */
export type ExtensionState =
  | 'available'
  | 'installed'
  | 'damaged'
  | 'unavailable'
  | 'not-offered'

/** One row as a panel draws it. */
export interface StoreExtension {
  id: string
  name: string
  summary: string
  homepage: string
  licence: string
  version: string
  works: ExtensionVerdict
  category: ExtensionCategory
  /** Words to search on that are in neither the name nor the summary. */
  tags: string[]
  /** What a person has to bring before it can do its job. Usually empty. */
  needs: ExtensionNeed[]
  /** What using it costs. See {@link ExtensionCost}. */
  cost: ExtensionCost
  /** The price reality in a sentence, or `''` for a row that is simply free. */
  costNote: string
  measured: string
  /** Why there is no download for a row nothing was measured on, or `''`. */
  noRelease: string
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
  /** What it may ask to reach later, and never gets here. */
  mayAsk: string[]
  /** True when its content scripts run on every page. */
  everywhere: boolean
  /**
   * `chrome.*` it asks for that this browser does not have **and this app does
   * not fill in**.
   *
   * Narrowed deliberately when `browser-extension-compat.ts` arrived. Before it,
   * this was every missing namespace and the row said each one meant "whatever
   * it uses those for will not work" — which was true then and is false now for
   * the ones the layer defines. A row that goes on printing a sentence the code
   * underneath it stopped meaning is the same defect as a button that does
   * nothing, only quieter.
   */
  missing: string[]
  /** `chrome.*` this app fills in for it, so its start-up survives. */
  provides: string[]
  /** What stays inert even with the layer, in the words a row shows. */
  inert: string[]
  /** How many manifest declarativeNetRequest rulesets this app switches on. */
  rulesetsSwitchedOn: number
  /** The page its toolbar button opens, or `''`. */
  popup: string
  /**
   * Its own settings page, or `''`.
   *
   * On the row for the same reason the popup is, and it closes a dead end the
   * popup alone left open: an extension with an options page and no
   * `default_popup` — Search by Image and Web Archives both — had **no**
   * reachable interface at all in this browser, because nothing drew a toolbar
   * and nothing offered the settings. A row that says Installed over a program
   * with no way in is the shape of dead control this store exists to remove.
   */
  optionsPage: string
  /**
   * True when its blocking rests on manifest `declarativeNetRequest` rulesets.
   *
   * On the row because those are measured not to be switched on when an
   * extension loads here, and nothing else on a row would show it: the extension
   * installs, loads, draws its button and blocks nothing. See
   * `browser-extension-support.ts` for the measurement.
   */
  staticRulesets: boolean
  /** True for an extension a person added themselves, from a folder or a .crx. */
  sideloaded: boolean
  /** Where a sideloaded one came from: the folder or file that was chosen. */
  origin: string
  /**
   * For one opened from a `.crx`: the id its own signature yields.
   *
   * Shown because it is the only thing about a `.crx` that is checkable, and
   * because it is comparable — it is the id in a Chrome Web Store URL. It is
   * **not** an endorsement, and `ExtensionRow` says what it is worth beside it.
   */
  crxId: string
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
  /** True for something a person added themselves. Absent means a catalogue row. */
  sideloaded: boolean
  /** A sideload's own name, so a row can be drawn with no catalogue entry behind it. */
  name: string
  /** Where it came from: the folder or the `.crx` that was chosen. */
  origin: string
  /** How it arrived. */
  kind: 'folder' | 'crx' | ''
  /** For a `.crx`: the id its signature yields. */
  crxId: string
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
      sideloaded: value.sideloaded === true,
      name: typeof value.name === 'string' ? value.name : '',
      origin: typeof value.origin === 'string' ? value.origin : '',
      kind: value.kind === 'folder' || value.kind === 'crx' ? value.kind : '',
      crxId: typeof value.crxId === 'string' ? value.crxId : '',
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
  /** Add an unpacked extension from a folder somebody chose. */
  addFolder(profileId: string, folder: string): ExtensionResult
  /** Add one from a `.crx` somebody chose, after checking its own signature. */
  addCrx(profileId: string, file: string): ExtensionResult
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
  /*
   * A row that already says *every page* cannot be out-reached, and saying so
   * here is what lets such a row stay readable. `reachOf` now includes content
   * script matches, and ClearURLs alone declares 196 of them — all of them
   * inside the `<all_urls>` its row already discloses. Listing them on the row
   * to satisfy a string comparison would bury the one line somebody reads under
   * two hundred they never will, and would not make the disclosure truer by a
   * word.
   */
  if (everywhereIn(entry.reach)) return ''
  const asked = reachOf(manifest)
  const extra = asked.filter((pattern) => !entry.reach.includes(pattern))
  if (extra.length === 0) return ''
  return `it asks to read ${extra.join(', ')}, which is not what this store row says it reaches`
}

/* ------------------------------------------------------------- your own -- */

/** The prefix on every id this app mints for an extension a person added. */
export const SIDELOAD_PREFIX = 'own-'

/** Is this an id this app minted for something somebody added themselves? */
export function isSideloadId(id: string): boolean {
  return id.startsWith(SIDELOAD_PREFIX)
}

/**
 * The id for a folder or a `.crx` somebody chose.
 *
 * Derived from the path so that adding the same folder twice **replaces** rather
 * than accumulates: a person iterating on an extension they are writing presses
 * Add after every build, and a store that grew a new row each time would be
 * unusable by the third press. Hashed rather than slugged because a path is not
 * a directory name — it has slashes, spaces and anything else a filesystem
 * allows — and {@link SAFE_ID} is what decides where this app is willing to
 * write.
 */
export function sideloadId(kind: 'folder' | 'crx', source: string): string {
  return SIDELOAD_PREFIX + createHash('sha256').update(`${kind}:${source}`).digest('hex').slice(0, 12)
}

interface Gathered {
  ok: boolean
  files: { path: string; bytes: Buffer }[]
  why: string
}

/**
 * Every file under a folder, with the same ceilings the zip path has.
 *
 * Symlinks are **skipped, never followed**. A folder somebody picked in a file
 * dialog is not hostile by assumption, but a symlink inside it pointing at their
 * home directory would have this app copy that home directory into a profile and
 * then load it as a program, and no amount of trust in the person who pressed
 * the button makes that a thing to do.
 */
function gatherFolder(root: string, limits: { maxBytes: number; maxFiles: number }): Gathered {
  const files: { path: string; bytes: Buffer }[] = []
  let total = 0
  const walk = (dir: string, prefix: string): string => {
    let entries: { name: string; isSymbolicLink(): boolean; isDirectory(): boolean; isFile(): boolean }[]
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch (error) {
      return `${prefix === '' ? 'the folder' : prefix} could not be read: ${error instanceof Error ? error.message : 'no reason given'}`
    }
    for (const entry of entries) {
      const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`
      if (entry.isSymbolicLink()) continue
      if (entry.isDirectory()) {
        const why = walk(join(dir, entry.name), relative)
        if (why !== '') return why
        continue
      }
      if (!entry.isFile()) continue
      if (files.length >= limits.maxFiles) return `it holds more than ${limits.maxFiles} files`
      let bytes: Buffer
      try {
        bytes = readFileSync(join(dir, entry.name))
      } catch (error) {
        return `${relative} could not be read: ${error instanceof Error ? error.message : 'no reason given'}`
      }
      total += bytes.byteLength
      if (total > limits.maxBytes) return `it is larger than ${limits.maxBytes} bytes`
      files.push({ path: relative, bytes })
    }
    return ''
  }
  const why = walk(root, '')
  if (why !== '') return { ok: false, files: [], why }
  return { ok: true, files, why: '' }
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

  /* ------------------------------------------------------- somebody's own -- */

  /** Every `own-` folder in a profile that has a record and a manifest. */
  function sideloadIds(profileId: string): string[] {
    const root = profileExtensionsRoot(options.userData, profileId)
    if (root === null) return []
    let names: string[]
    try {
      names = readdirSync(root, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => entry.name)
    } catch {
      return []
    }
    return names.filter((name) => isSideloadId(name) && SAFE_ID.test(name)).sort()
  }

  /**
   * Read one back off the disk, the way {@link load} does for a catalogue row.
   *
   * The digest check that guards a catalogue install is deliberately **not**
   * here, and its absence is the whole difference: there is no pinned
   * fingerprint for a folder somebody chose, and inventing one — hashing what
   * this app itself just wrote and comparing it to itself — would be a check
   * that can never fail, which is worse than no check because it looks like one.
   * What is checked is what can be: the record exists, the manifest parses, and
   * the manifest is what the row is drawn from.
   */
  function loadSideload(
    profileId: string,
    id: string,
  ): { extension: InstalledExtension; disk: OnDisk } | { why: string } | null {
    const dir = dirFor(profileId, id)
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
    if (disk === null || !disk.sideloaded) {
      return { why: 'this app has no record of adding it — remove it and add it again' }
    }
    const name = displayName(parsed.manifest, disk.name === '' ? id : disk.name)
    return {
      disk,
      extension: {
        entry: {
          id,
          name,
          summary:
            disk.kind === 'crx'
              ? `Added by you, from ${basename(disk.origin) || 'a .crx'}.`
              : 'Added by you, from a folder on this machine.',
          homepage: '',
          licence: '',
          version: typeof parsed.manifest.version === 'string' ? parsed.manifest.version : '',
          category: 'your-own',
          tags: [],
          /* Nothing is known about it, so nothing is claimed. `free` would be
             this app pricing a program it has never opened. */
          cost: 'unknown',
          costNote: '',
          works: 'unmeasured',
          measured:
            'This app has measured nothing about it. It was not fetched, no fingerprint was ' +
            'checked against it, and no verdict here is about it — it is running because you ' +
            'said so.',
          reach: reachOf(parsed.manifest),
          source: null,
        },
        dir,
        manifest: parsed.manifest,
        installedAt: disk.installedAt,
        enabled: disk.enabled,
      },
    }
  }

  /** The rows for everything somebody added, drawn from the disk alone. */
  function sideloadRows(profileId: string): StoreExtension[] {
    const out: StoreExtension[] = []
    for (const id of sideloadIds(profileId)) {
      const loaded = loadSideload(profileId, id)
      if (loaded === null) continue
      const disk = readOnDisk(dirFor(profileId, id) ?? '')
      const base: StoreExtension = {
        id,
        name: disk?.name === '' || disk?.name === undefined ? id : disk.name,
        summary: '',
        homepage: '',
        licence: '',
        version: disk?.version ?? '',
        works: 'unmeasured',
        category: 'your-own',
        /* Its own name is the only thing anybody could search for. Nothing was
           measured about it, and inventing tags for a folder somebody dropped in
           would be this app describing a program it has never read. */
        tags: [],
        needs: [],
        cost: 'unknown',
        costNote: '',
        measured: '',
        noRelease: '',
        url: '',
        sha256: '',
        bytes: 0,
        state: 'damaged',
        installedVersion: disk?.version ?? '',
        installedAt: disk?.installedAt ?? 0,
        enabled: false,
        reach: [],
        mayAsk: [],
        everywhere: false,
        missing: [],
        provides: [],
        inert: [],
        rulesetsSwitchedOn: 0,
        popup: '',
        optionsPage: '',
        sideloaded: true,
        origin: disk?.origin ?? '',
        crxId: disk?.crxId ?? '',
        staticRulesets: false,
        message: '',
      }
      if ('why' in loaded) {
        out.push({ ...base, message: loaded.why })
        continue
      }
      const { manifest, installedAt, enabled } = loaded.extension
      const compat = planCompat(manifest)
      out.push({
        ...base,
        name: loaded.extension.entry.name,
        summary: loaded.extension.entry.summary,
        measured: loaded.extension.entry.measured,
        state: 'installed',
        version: loaded.extension.entry.version,
        installedVersion: loaded.extension.entry.version,
        installedAt,
        enabled,
        reach: reachOf(manifest),
        mayAsk: mayAskToReach(manifest),
        everywhere: everywhere(manifest),
        missing: missingApis(manifest).filter((api) => !compat.provides.includes(api)),
        provides: compat.provides,
        inert: compat.inert,
        rulesetsSwitchedOn: compat.rulesets.length,
        popup: popupPage(manifest),
        optionsPage: optionsPageOf(manifest),
        staticRulesets: usesStaticRulesets(manifest),
      })
    }
    return out
  }

  /**
   * Put a folder or a `.crx` somebody chose into a profile.
   *
   * The order is the same as an install's and for the same reasons: read the
   * manifest **before** anything is written, refuse the shapes Chromium refuses
   * at load, write, apply the compatibility layer, then record. What is missing
   * compared to an install is the digest, and every sentence this produces says
   * so rather than letting the confidence of the pinned rows leak onto a row
   * that has not earned it.
   */
  function addOwn(profileId: string, kind: 'folder' | 'crx', chosen: string): ExtensionResult {
    const root = profileExtensionsRoot(options.userData, profileId)
    if (root === null) return { ok: false, message: 'That is not a profile this app knows.' }
    if (typeof chosen !== 'string' || chosen.trim() === '' || !isAbsolute(chosen)) {
      return { ok: false, message: 'Nothing was added: that is not a path on this machine.' }
    }
    const source = resolve(chosen)
    let files: { path: string; bytes: Buffer }[]
    let crxId = ''
    if (kind === 'folder') {
      if (!existsSync(join(source, 'manifest.json'))) {
        return {
          ok: false,
          message:
            'Nothing was added: there is no manifest.json in that folder. Pick the folder that ' +
            'has the manifest.json in it, not the one above it.',
        }
      }
      const gathered = gatherFolder(source, {
        maxBytes: MAX_UNPACKED_BYTES,
        maxFiles: MAX_FILES,
      })
      if (!gathered.ok) return { ok: false, message: `Nothing was added: ${gathered.why}.` }
      files = gathered.files
    } else {
      let bytes: Buffer
      try {
        const size = statSync(source).size
        if (size > MAX_ARCHIVE_BYTES) {
          return { ok: false, message: `Nothing was added: that file is larger than ${MAX_ARCHIVE_BYTES} bytes.` }
        }
        bytes = readFileSync(source)
      } catch (error) {
        return {
          ok: false,
          message: `Nothing was added: that file could not be read${error instanceof Error ? ` — ${error.message}` : ''}.`,
        }
      }
      const opened = openCrx(bytes)
      if (!opened.ok) return { ok: false, message: `Nothing was added: ${opened.why}.` }
      crxId = opened.crx.crxId
      const unzipped = unzip(opened.crx.zip, {
        maxTotalBytes: MAX_UNPACKED_BYTES,
        maxFiles: MAX_FILES,
      })
      if (!unzipped.ok) return { ok: false, message: `Nothing was added: ${unzipped.why}.` }
      const prefix = manifestPrefix(unzipped.files)
      if (prefix === null) {
        return { ok: false, message: 'Nothing was added: there is no manifest.json inside that .crx.' }
      }
      files = unzipped.files
        .filter((file) => file.path.startsWith(prefix) && file.path !== prefix)
        .map((file) => ({ path: file.path.slice(prefix.length), bytes: file.bytes }))
    }

    const manifestFile = files.find((file) => file.path === 'manifest.json')
    const parsed = parseManifest(manifestFile?.bytes.toString('utf8') ?? '')
    if (!parsed.ok) return { ok: false, message: `Nothing was added: ${parsed.why}.` }
    const can = loadability(parsed.manifest)
    if (!can.ok) return { ok: false, message: `Nothing was added: ${can.why}.` }

    const id = sideloadId(kind, source)
    const dir = dirFor(profileId, id)
    if (dir === null) return { ok: false, message: 'Nothing was added: that profile is not one this app knows.' }
    const name = displayName(parsed.manifest, basename(source) || id)

    let compat: CompatReport = { ok: true, provides: [], inert: [], why: '' }
    try {
      rmSync(dir, { recursive: true, force: true })
      mkdirSync(dir, { recursive: true })
      for (const file of files) {
        if (file.path === '' || NOT_AN_EXTENSION.has(file.path)) continue
        const target = join(dir, file.path)
        mkdirSync(dirname(target), { recursive: true })
        writeFileSync(target, file.bytes)
      }
      compat = applyCompat(dir, parsed.manifest)
      writeRecord(dir, {
        id,
        version: typeof parsed.manifest.version === 'string' ? parsed.manifest.version : '',
        sha256: '',
        installedAt: now(),
        enabled: true,
        sideloaded: true,
        name,
        origin: source,
        kind,
        crxId,
      })
    } catch (error) {
      try {
        rmSync(dir, { recursive: true, force: true })
      } catch {
        /* The message below says nothing was added, which stays true. */
      }
      return {
        ok: false,
        message: `Nothing was added: ${error instanceof Error ? error.message : 'it could not be saved'}.`,
      }
    }

    const gaps = missingApis(parsed.manifest).filter((api) => !compat.provides.includes(api))
    const note =
      gaps.length === 0
        ? ''
        : ` It asks for ${gaps.map((api) => `chrome.${api}`).join(', ')}, which this browser does not have, so whatever it uses those for will not work.`
    const filled =
      compat.provides.length === 0
        ? ''
        : ` This app fills in ${compat.provides.map((api) => `chrome.${api}`).join(', ')} so it can start.`
    const inert = compat.inert.length === 0 ? '' : ` Even so, ${compat.inert.join('; ')}.`
    const signed =
      kind === 'crx'
        ? ` Its signature matched its contents, which says the file has not changed since it was packed and says nothing about who packed it. Its signing key gives the id ${crxId}.`
        : ''
    return {
      ok: true,
      message:
        `${name} was copied into this profile from ${source} and switched on. This app measured ` +
        `nothing about it and checked no fingerprint against it.${signed}${filled}${inert}${note}`,
    }
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
          category: entry.category,
          tags: [...entry.tags],
          needs: [...(entry.needs ?? [])],
          cost: entry.cost,
          costNote: entry.costNote,
          measured: entry.measured,
          noRelease: entry.noRelease ?? '',
          url: entry.source?.url ?? '',
          sha256: entry.source?.sha256 ?? '',
          bytes: entry.source?.bytes ?? 0,
          installedVersion: '',
          installedAt: 0,
          enabled: false,
          // Stated from the catalogue before there is a manifest, and replaced
          // by the manifest's own answer the moment there is one.
          reach: [...entry.reach],
          mayAsk: [...(entry.mayAskToReach ?? [])],
          everywhere: everywhereIn(entry.reach),
          missing: [] as string[],
          provides: [] as string[],
          inert: [] as string[],
          rulesetsSwitchedOn: 0,
          popup: '',
          optionsPage: '',
          sideloaded: false,
          origin: '',
          crxId: '',
          staticRulesets: false,
          message: '',
        }
        /*
         * A row nobody ran, because there was nothing to run. Separate from the
         * refusal below and separate from silence: see {@link ExtensionEntry.noRelease}.
         */
        if (entry.works === 'unmeasured') {
          return { ...base, state: 'not-offered' as const, message: entry.noRelease ?? '' }
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
        const compat = planCompat(manifest)
        return {
          ...base,
          state: 'installed' as const,
          installedVersion: typeof manifest.version === 'string' ? manifest.version : '',
          installedAt,
          enabled,
          reach: reachOf(manifest),
          mayAsk: mayAskToReach(manifest),
          everywhere: everywhere(manifest),
          missing: missingApis(manifest).filter((api) => !compat.provides.includes(api)),
          provides: compat.provides,
          inert: compat.inert,
          rulesetsSwitchedOn: compat.rulesets.length,
          popup: popupPage(manifest),
          optionsPage: optionsPageOf(manifest),
          staticRulesets: usesStaticRulesets(manifest),
        }
      })
      return {
        profileId,
        profileName,
        extensions: [...extensions, ...sideloadRows(profileId)],
        folder: root ?? '',
      }
    },

    addFolder(profileId: string, folder: string): ExtensionResult {
      return addOwn(profileId, 'folder', folder)
    },

    addCrx(profileId: string, file: string): ExtensionResult {
      return addOwn(profileId, 'crx', file)
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

      let compat: CompatReport = { ok: true, provides: [], inert: [], why: '' }
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
        /*
         * The compatibility layer goes in before the record is written, so a row
         * can never say Installed over a copy that has not had it. It runs after
         * the digest check and after every byte is on disk, which is the whole
         * of why it is allowed to touch somebody else's bundle: what was
         * verified is what was unpacked, and this is this app's own code being
         * added to this app's own per-profile copy afterwards.
         */
        compat = applyCompat(dir, parsed.manifest)

        writeRecord(dir, {
          id,
          version: typeof parsed.manifest.version === 'string' ? parsed.manifest.version : '',
          sha256: entry.source.sha256,
          installedAt: now(),
          enabled: true,
          sideloaded: false,
          name: entry.name,
          origin: entry.source.url,
          kind: '',
          crxId: '',
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
      const plan = planCompat(parsed.manifest)
      const gaps = missingApis(parsed.manifest).filter((api) => !compat.provides.includes(api))
      const note =
        gaps.length === 0
          ? ''
          : ` It asks for ${gaps.map((api) => `chrome.${api}`).join(', ')}, which this browser does not have, so whatever it uses those for will not work.`
      /*
       * The layer is named rather than left silent. It rewrote files inside the
       * extension, and an app that quietly edits a program somebody just agreed
       * to install and then does not mention it is keeping a secret it has no
       * reason to keep.
       */
      const filled =
        compat.provides.length === 0
          ? ''
          : ` This app fills in ${compat.provides.map((api) => `chrome.${api}`).join(', ')} so it can start.`
      const inert = compat.inert.length === 0 ? '' : ` Even so, ${compat.inert.join('; ')}.`
      const layerFailed = compat.ok ? '' : ` The compatibility layer could not be written: ${compat.why}.`
      const one = plan.rulesets.length === 1
      const rulesets =
        plan.rulesets.length > 0
          ? ` Its ${plan.rulesets.length} manifest declarativeNetRequest ruleset${one ? '' : 's'} ${one ? 'is' : 'are'} not switched on when an extension loads here, so this app switched ${one ? 'it' : 'them'} on.`
          : usesStaticRulesets(parsed.manifest)
            ? ' Its filter lists ship as manifest declarativeNetRequest rulesets, which this browser does not switch on.'
            : ''
      return {
        ok: true,
        message: `${name} is installed in this profile and switched on.${filled}${inert}${note}${rulesets}${layerFailed}`,
      }
    },

    remove(profileId: string, id: string): ExtensionResult {
      const dir = dirFor(profileId, id)
      if (dir === null) return { ok: false, message: 'That is not an extension this app installed.' }
      const entry = entryFor(id)
      if (!existsSync(dir)) return { ok: true, message: 'It was not installed.' }
      // Read before deleting: the name a sideloaded row wears lives in the file
      // this is about to remove, and a confirmation that could only say "the
      // extension" about a thing the person named themselves is a worse
      // sentence than the one it replaces.
      const readOnDiskName = readOnDisk(dir)?.name
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
      const own = isSideloadId(id) ? (readOnDiskName ?? '') : ''
      return {
        ok: true,
        message: `${entry?.name ?? (own === '' ? 'The extension' : own)} is removed. Its files are deleted.`,
      }
    },

    setEnabled(profileId: string, id: string, on: boolean): ExtensionResult {
      const dir = dirFor(profileId, id)
      const entry = entryFor(id)
      if (dir === null || (entry === null && !isSideloadId(id))) {
        return { ok: false, message: 'That is not an extension this app installed.' }
      }
      const disk = readOnDisk(dir)
      if (disk === null) return { ok: false, message: 'It is not installed in this profile.' }
      try {
        writeRecord(dir, { ...disk, id, enabled: on })
      } catch (error) {
        return {
          ok: false,
          message: `That could not be saved: ${error instanceof Error ? error.message : 'the file would not write'}.`,
        }
      }
      const name = entry?.name ?? (disk.name === '' ? id : disk.name)
      return {
        ok: true,
        message: on ? `${name} is switched on.` : `${name} is switched off.`,
      }
    },

    installed(profileId: string): InstalledExtension[] {
      const out: InstalledExtension[] = []
      for (const entry of options.catalogue) {
        const loaded = load(profileId, entry)
        if (loaded !== null && 'extension' in loaded) out.push(loaded.extension)
      }
      /*
       * And everything somebody added themselves. On this list because it is
       * what the launch loader replays and what `browser.extensions` answers
       * with: an extension the person added is running in their browser exactly
       * as a catalogue one is, and a list that left it out would have an agent
       * reading a page altered by a program the list said was not there.
       */
      for (const id of sideloadIds(profileId)) {
        const loaded = loadSideload(profileId, id)
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
  /*
   * An `own-` folder is not an orphan. It has no catalogue row and never will —
   * that is what it is — and reporting it under *No longer offered* would tell
   * somebody that the extension they added themselves five minutes ago had been
   * withdrawn from the app.
   */
  return names
    .filter((name) => SAFE_ID.test(name) && !known.has(name) && !isSideloadId(name))
    .sort()
}
