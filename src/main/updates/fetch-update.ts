/**
 * Fetch a release and prove it is the one the feed promised. Nothing installs.
 *
 * `updater.ts` explains why this app cannot update itself: every build is
 * unsigned, and Squirrel.Mac refuses to swap a bundle it cannot verify a
 * signature for. That leaves the user replacing the app by hand, and *that* is
 * the gap this module closes — it does the download and the verification, and
 * ends holding a `.app` in a staging directory plus the path to it. Whether
 * anything is done with that path is somebody else's decision, taken by a
 * person. There is no `quitAndInstall` here, no copy into `/Applications`, and
 * no code that touches the running bundle.
 *
 * ## The checksum is the whole point
 *
 * HTTPS proves you are talking to GitHub. It says nothing about what GitHub
 * was handed at upload time, what a proxy did in between, or whether the disk
 * wrote every byte it accepted. The sha512 in the feed is the only statement
 * anyone makes about the *bytes*, and on an unsigned build there is no second
 * line of defence behind it — no code signature, no notarisation ticket,
 * nothing Gatekeeper will refuse on our behalf. So the hash is checked before
 * the archive is renamed to its final name, before it is extracted, and before
 * any path to it is returned, and a mismatch deletes the file.
 *
 * "The size looks right" is not the check. Length is a cheap early-out that
 * catches a truncated transfer without reading 119 MB twice; it is asserted in
 * addition to the digest and never instead of it.
 *
 * The digest is verified against the real release rather than assumed:
 *
 *     $ openssl dgst -sha512 -binary terminaldeck-0.1.0-arm64.zip \
 *         | openssl base64 -A
 *     HyckKuCltIQ1t6OkRtigLH/TQu4FjnfjIKMh6TVE1t+bu3PY+…
 *
 * which is byte-for-byte the `sha512:` the published `latest-mac.yml` carries
 * for that file. So base64-of-raw-digest is the encoding, not hex, and not
 * base64-of-hex.
 *
 * ## Reading the feed without a YAML parser
 *
 * Four fields do not justify a dependency, so the feed is hand-parsed — but
 * against the real file, fetched and printed rather than imagined:
 *
 *     version: 0.1.0
 *     files:
 *       - url: terminaldeck-0.1.0-arm64.zip
 *         sha512: Hyck…fQ==
 *         size: 119570501
 *       - url: terminaldeck-0.1.0-arm64.dmg
 *         sha512: ayaO…72w==
 *         size: 119552577
 *     path: terminaldeck-0.1.0-arm64.zip
 *     sha512: Hyck…fQ==
 *     releaseDate: '2026-08-13T09:26:05.671Z'
 *
 * Three things in that shape are easy to get wrong by guessing:
 *
 *  - **`url` is a bare filename, not a URL.** It is resolved against the feed's
 *    own address, which is what makes `…/releases/latest/download/latest-mac.yml`
 *    point at `…/releases/latest/download/terminaldeck-0.1.0-arm64.zip`.
 *  - **The list ends by dedenting.** `path:`, `sha512:` and `releaseDate:` sit
 *    at column 0 *after* the entries. A parser that keeps appending keys to the
 *    last list item silently rewrites the dmg's hash with the zip's, which is a
 *    checksum failure blamed on the network. Indentation ends the block here.
 *  - **base64 contains `/`, `+` and `=`,** and a value may be quoted. Splitting
 *    on the first colon and unquoting handles both; splitting on every colon
 *    does not.
 *
 * The top-level `path:`/`sha512:` pair is deliberately ignored. It carries no
 * size, so it cannot support the length check, and preferring it would mean two
 * code paths disagreeing about which file is being fetched.
 *
 * ## The zip, never the dmg
 *
 * Both are published and both are ~119 MB. A zip is a plain archive that can be
 * unpacked in a directory this process owns. A dmg has to be attached — a real
 * mount on the user's machine, with a volume appearing in Finder, a detach that
 * has to happen even when something throws in between, and a name collision if
 * one is already mounted. None of that is needed to look inside an archive.
 *
 * ## `ditto`, and what was actually measured about `unzip`
 *
 * Extraction runs `/usr/bin/ditto -x -k`, by absolute path so nothing earlier
 * on `PATH` can answer instead. ditto is Apple's own archiver, ships with the
 * OS, and is bundle-aware: resource forks, extended attributes and symlinks are
 * its job rather than an extension someone bolted on.
 *
 * The usual justification — "unzip mangles the framework symlinks" — was tested
 * on the real release zip rather than repeated, and on this machine it did not
 * reproduce: the archive carries no `__MACOSX` entries, and Apple's patched
 * `unzip 6.00` restored `Electron Framework.framework/Versions/Current -> A`
 * as a symlink with the executable bit intact. So the reason ditto is used here
 * is not that unzip was seen to fail; it is that ditto is the tool Apple
 * documents for copying bundles, it is guaranteed to be at a fixed absolute
 * path on every Mac, and its behaviour does not depend on which Info-ZIP build
 * a user happens to have. The bundle is then checked structurally anyway, so a
 * mangled extraction is caught rather than trusted.
 *
 * ## Restartable, not resumable
 *
 * Bytes land in `<name>.zip.part` and the file is renamed only after the digest
 * passes, so an interrupted run leaves something that cannot be mistaken for a
 * finished download — the completed name is, by construction, only ever given
 * to verified bytes.
 *
 * ## The same rule, applied to the *unpacked* tree
 *
 * A verified archive is not the thing the caller uses; the extracted `.app` is,
 * and until the marker below existed there was no equivalent of `.part` for it.
 * That gap was demonstrated rather than imagined — a test drives it — and it had
 * two halves:
 *
 *  - A tree that inspects as a bundle at the right version was reused **without
 *    any evidence it came from this archive**. A crash partway through `ditto`
 *    can leave exactly that: `Info.plist` and `Contents/MacOS/<binary>` written,
 *    `Frameworks/` still missing. Structurally it passes every check here, and
 *    it is what `stagedBundlePath` would have handed to the installer — which
 *    swaps it over `/Applications`, sees a `Contents/MacOS`, calls the swap good
 *    and deletes the backup. The user ends up with an app that will not launch
 *    and nothing to roll back to. That is the worst outcome this module can
 *    cause, and it was reachable.
 *  - A freshly downloaded, freshly verified archive was **not extracted at all**
 *    when some tree at that version already sat there. Same version number,
 *    different bytes is not hypothetical: `release/` was rebuilt on 2026-08-13
 *    and stopped matching the published 0.1.0.
 *
 * So a completed extraction ends by writing `bundle/.verified-sha512`, holding
 * the digest of the archive it came out of. It lives *inside* the tree, so it
 * cannot outlive it, and it is written last, so it exists only after the tree
 * has been shown to be a bundle at the promised version. A tree with no marker,
 * or a marker naming other bytes, is deleted and extracted again — never
 * trusted, never handed onwards.
 *
 * It proves provenance, not integrity: it says these bytes were unpacked from
 * that archive by a run that finished. It cannot detect a file edited inside the
 * tree afterwards — that needs a per-file manifest, which the release does not
 * publish — which is why staging lives under `userData` and not anywhere another
 * account can write.
 *
 * ## One at a time
 *
 * Calls against the same `userData` are serialised. Two overlapping runs shared
 * one `.part` path, and the second one's opening `rm` unlinked the file the
 * first was still writing into, so a run could `rm` or `rename` a file that
 * belonged to another one; the observed result was a download that failed with a
 * sentence about a file that had vanished. Nothing corrupt reached the verified
 * name — the digest is checked by path, immediately before the rename — but
 * "the user pressed the button twice" should not be able to fail an update at
 * all. The second caller now waits and then finds the first one's work staged.
 * The `.part` file is also opened `wx`, so a *second process* is refused rather
 * than allowed to write into a file this one owns.
 *
 * An interrupted download restarts from zero rather than resuming with a
 * `Range` request. GitHub redirects release assets to short-lived signed URLs
 * (`release-assets.githubusercontent.com`, `se=…` a few minutes out), so a
 * resume would often be a 403 against a stale signature, and the bookkeeping to
 * tell that apart from a truncated file buys back only bandwidth on a transfer
 * that is verified end-to-end either way.
 *
 * ## What is injected
 *
 * `fetch`, the userData path and `process.platform`, so the tests never open a
 * socket and never write outside a temp directory. `ditto` and `plutil` are
 * injectable too but the tests use the real ones: the point of this module is
 * what a real archive does on a real disk, and a fake unarchiver would prove
 * nothing about either.
 */

import { execFile } from 'node:child_process'
import { createHash, timingSafeEqual } from 'node:crypto'
import { mkdir, open, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

/* ------------------------------------------------------------------ types -- */

/** One entry from the feed's `files:` list. */
export interface FeedFile {
  /** Exactly as written — usually a bare filename, resolved against the feed. */
  url: string
  /** base64 of the raw sha512 digest, as electron-builder writes it. */
  sha512: string
  size: number
}

export interface Feed {
  version: string
  files: FeedFile[]
}

/**
 * A progress tick. `transferred` and `percent` only ever grow, and `percent` is
 * clamped: a server that sends more than the feed declared still reports 100.
 */
export interface FetchProgress {
  version: string
  transferred: number
  /** The size the feed declared. Always positive — it is validated on parse. */
  total: number
  /** 0–100, integer, monotonic. */
  percent: number
}

/**
 * Why a fetch stopped, as a closed set.
 *
 * Kept apart rather than collapsed into "failed" for the same reason
 * `github.ts` keeps its kinds apart: the fixes are different. A feed that will
 * not parse is a build-side bug, a checksum mismatch is a corrupted or tampered
 * download that should be retried once and then reported, and a bundle that is
 * not a bundle means the archive is not what its name says.
 */
export type FetchFailureReason =
  | 'unsupported-platform'
  | 'feed-unreachable'
  | 'feed-unreadable'
  | 'no-zip'
  | 'download-failed'
  | 'size-mismatch'
  | 'checksum-mismatch'
  | 'extract-failed'
  | 'not-a-bundle'
  | 'version-mismatch'
  | 'cancelled'

export type FetchUpdateResult =
  | {
      ok: true
      version: string
      /** The verified archive on disk. */
      archivePath: string
      /** The extracted `<name>.app`. */
      bundlePath: string
      /** The archive's length, as verified against the feed. */
      sizeBytes: number
      /** True when everything was already staged and no bytes were fetched. */
      reused: boolean
    }
  | {
      ok: false
      reason: FetchFailureReason
      /** One sentence, plain language, naming what did not match. */
      message: string
      /** Raw tool or server output, or null. */
      detail: string | null
    }

/** The slice of `fetch` this module uses. `globalThis.fetch` satisfies it. */
export interface FetchLike {
  (
    url: string,
    init?: { signal?: AbortSignal; headers?: Record<string, string> },
  ): Promise<HttpResponse>
}

export interface HttpResponse {
  ok: boolean
  status: number
  headers: { get(name: string): string | null }
  body: ReadableStream<Uint8Array> | null
}

/** Unpacks `archivePath` into `destDir`, throwing on failure. */
export type Extractor = (archivePath: string, destDir: string) => Promise<void>

/** Reads a plist into a plain object, throwing when it is not one. */
export type PlistReader = (path: string) => Promise<Record<string, unknown>>

export interface FetchUpdateOptions {
  /** Absolute https URL of `latest-mac.yml`. */
  feedUrl: string
  /** `app.getPath('userData')`. Everything written lives under `<it>/updates`. */
  userDataPath: string
  /** `process.platform`. */
  platform: NodeJS.Platform
  fetch: FetchLike
  onProgress?: (progress: FetchProgress) => void
  signal?: AbortSignal
  /** Defaults to `/usr/bin/ditto -x -k`. */
  extract?: Extractor
  /** Defaults to `/usr/bin/plutil -convert json`. */
  readPlist?: PlistReader
  /** Floor between progress events. 0 emits one per chunk. */
  progressIntervalMs?: number
  now?: () => number
}

/* -------------------------------------------------------------- constants -- */

/**
 * How often progress may be reported.
 *
 * A 119 MB body arrives in roughly two thousand chunks, and an IPC message per
 * chunk is two thousand renders of a bar that can only occupy a few hundred
 * pixels. Four a second is faster than anyone reads and slow enough to be free.
 */
export const PROGRESS_INTERVAL_MS = 250

/**
 * The feed is a few hundred bytes; a megabyte is already absurd.
 *
 * Enforced while streaming rather than after `text()`, because a body with no
 * `Content-Length` would otherwise be buffered in full before anyone could
 * object to its size.
 */
export const MAX_FEED_BYTES = 1024 * 1024

/** sha512 is 64 bytes. A feed value that decodes to anything else is garbage. */
const SHA512_BYTES = 64

/** Absolute paths so `PATH` cannot decide which unarchiver runs. */
const DITTO = '/usr/bin/ditto'
const PLUTIL = '/usr/bin/plutil'

/**
 * A version has to be usable as a single directory name.
 *
 * The value arrives from a network feed, and it is concatenated into a path.
 * Requiring the first character to be alphanumeric is what makes `..` and
 * `.config` unrepresentable, and the character class keeps out separators, so
 * `join(root, version)` cannot leave `root`.
 */
const SAFE_VERSION = /^[0-9A-Za-z][0-9A-Za-z._+-]*$/

/* ----------------------------------------------------------- feed parsing -- */

function unquote(value: string): string {
  const single = /^'(.*)'$/s.exec(value)
  if (single) return single[1]
  const double = /^"(.*)"$/s.exec(value)
  return double ? double[1] : value
}

/**
 * `key: value` on the first colon only.
 *
 * The first colon and not the last, because both halves can contain one — a
 * `url:` may be absolute and a `releaseDate:` is an ISO timestamp. The key
 * pattern is what stops a stray line of base64 or a bare URL from being read as
 * a key/value pair at all.
 */
function splitKeyValue(line: string): { key: string; value: string } | null {
  const colon = line.indexOf(':')
  if (colon <= 0) return null
  const key = line.slice(0, colon).trim()
  if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(key)) return null
  return { key, value: unquote(line.slice(colon + 1).trim()) }
}

/**
 * The feed as `version` plus its `files:` entries, or null if it is not one.
 *
 * Indentation-driven: the `files:` block runs until a line at or left of the
 * column `files:` itself sits on, which is exactly how the trailing top-level
 * `path:`/`sha512:`/`releaseDate:` keys stay out of the last file entry.
 *
 * An entry is kept only when all three fields it needs are present and sane. A
 * file with no size cannot be length-checked and a file with no digest cannot
 * be verified at all, so a partial entry is dropped rather than half-trusted.
 */
export function parseFeed(text: string): Feed | null {
  let version: string | null = null
  const files: FeedFile[] = []

  let inFiles = false
  let filesIndent = 0
  let current: Partial<FeedFile> | null = null

  const flush = (): void => {
    if (
      current &&
      typeof current.url === 'string' &&
      current.url !== '' &&
      typeof current.sha512 === 'string' &&
      current.sha512 !== '' &&
      typeof current.size === 'number'
    ) {
      files.push({ url: current.url, sha512: current.sha512, size: current.size })
    }
    current = null
  }

  for (const raw of text.split(/\r?\n/)) {
    const trimmed = raw.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue
    const indent = raw.length - raw.trimStart().length

    if (inFiles && indent <= filesIndent) {
      flush()
      inFiles = false
    }

    if (!inFiles) {
      if (trimmed === 'files:') {
        inFiles = true
        filesIndent = indent
        continue
      }
      const pair = splitKeyValue(trimmed)
      if (pair && pair.key === 'version' && version === null) version = pair.value
      continue
    }

    let body = trimmed
    if (body === '-') {
      flush()
      current = {}
      continue
    }
    if (body.startsWith('- ')) {
      flush()
      current = {}
      body = body.slice(2).trim()
    }

    const pair = splitKeyValue(body)
    if (!pair || current === null) continue
    if (pair.key === 'url') current.url = pair.value
    else if (pair.key === 'sha512') current.sha512 = pair.value
    else if (pair.key === 'size') {
      const size = Number(pair.value)
      if (Number.isSafeInteger(size) && size > 0) current.size = size
    }
  }
  flush()

  if (version === null || !SAFE_VERSION.test(version) || version.length > 64) return null
  return { version, files }
}

/** The `.zip` entry, or null. Query strings are ignored; `.dmg` never matches. */
export function chooseArchive(feed: Feed): FeedFile | null {
  return (
    feed.files.find((file) => {
      const path = file.url.split(/[?#]/)[0]
      return path.toLowerCase().endsWith('.zip')
    }) ?? null
  )
}

/**
 * The absolute URL of an asset, and the local name to save it under.
 *
 * https only, and the same origin as the feed. The feed is untrusted text, and a
 * `url:` of `http://…` or `file:///…` would be a silent downgrade out of the one
 * guarantee transport security does give — that the host is who it claims to be.
 *
 * The origin check is the other half of that. `new URL(value, feedUrl)` resolves
 * a bare filename against the feed, which is the normal case and what
 * electron-builder writes — but it accepts an absolute URL too, so a feed body
 * alone could name any host on the internet as the source of the bytes that
 * replace the user's application. The digest in that same feed would then prove
 * only that the two halves of one attacker's document agree with each other. So
 * the asset has to live where the feed lives; a release that moves its assets
 * elsewhere fails loudly here rather than being followed quietly.
 *
 * The local name is the URL's last segment, percent-decoded, and then required
 * to be a plain filename. Decoding matters because electron-builder escapes
 * spaces in artifact names; the check after it matters because the decoded
 * string is about to become a path component.
 */
export function resolveAsset(
  file: FeedFile,
  feedUrl: string,
): { url: string; fileName: string } | null {
  let resolved: URL
  let feed: URL
  try {
    feed = new URL(feedUrl)
    resolved = new URL(file.url, feedUrl)
  } catch {
    return null
  }
  if (resolved.protocol !== 'https:') return null
  if (resolved.origin !== feed.origin) return null

  let fileName: string
  try {
    fileName = decodeURIComponent(basename(resolved.pathname))
  } catch {
    return null
  }
  if (fileName === '' || fileName.startsWith('-') || fileName.includes('/')) return null
  if (fileName.includes('\\') || fileName === '.' || fileName === '..') return null
  if (!fileName.toLowerCase().endsWith('.zip')) return null

  return { url: resolved.toString(), fileName }
}

/* ---------------------------------------------------------------- layout -- */

/** `<userData>/updates` — the only directory this module creates or removes. */
export function updatesRoot(userDataPath: string): string {
  return join(userDataPath, 'updates')
}

/** `<userData>/updates/<version>` — archive, part file and extraction. */
export function stagingDir(version: string, userDataPath: string): string {
  return join(updatesRoot(userDataPath), version)
}

/** The sibling directory the archive is unpacked into. */
export function extractDir(version: string, userDataPath: string): string {
  return join(stagingDir(version, userDataPath), 'bundle')
}

/**
 * The file that says an extraction finished, and which bytes it finished on.
 *
 * A sibling of the `.app` rather than something inside it: the bundle has to
 * stay exactly what came out of the archive, because it is what gets installed.
 * Inside the extraction directory rather than beside it, because the tree and
 * the claim about the tree have to die together — a marker one level up survives
 * `rm -rf bundle/` and would then vouch for whatever appeared next.
 */
const EXTRACTION_MARKER = '.verified-sha512'

/** The digest an existing tree claims to have come from, or null. */
async function readExtractionMarker(bundleDir: string): Promise<string | null> {
  try {
    const value = (await readFile(join(bundleDir, EXTRACTION_MARKER), 'utf8')).trim()
    return value === '' ? null : value
  } catch {
    return null
  }
}

/**
 * The feed's digest in one canonical spelling.
 *
 * Written through the decoder so the marker cannot be compared against a value
 * that differs only in padding or whitespace — the same reason the digest itself
 * is compared as bytes rather than as text.
 */
function canonicalDigest(sha512: string): string | null {
  return decodeSha512(sha512)?.toString('base64') ?? null
}

/* ------------------------------------------------------------ verification -- */

/** The feed's base64 digest as raw bytes, or null when it is not a sha512. */
export function decodeSha512(value: string): Buffer | null {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return null
  const bytes = Buffer.from(value, 'base64')
  return bytes.length === SHA512_BYTES ? bytes : null
}

/**
 * sha512 of a file, read back off the disk a megabyte at a time.
 *
 * Deliberately a second pass rather than a digest accumulated while the bytes
 * stream past. What has to be true is that *the file on disk* is the release —
 * that is what gets extracted — and hashing the stream proves only what went
 * through this process. A short write, a full volume or a failed flush all land
 * in the gap between the two, and this is also the function the reuse path
 * needs, so there is one implementation of "prove these bytes" rather than two.
 */
async function sha512OfFile(path: string): Promise<Buffer> {
  const hash = createHash('sha512')
  const handle = await open(path, 'r')
  try {
    const buffer = Buffer.allocUnsafe(1024 * 1024)
    for (;;) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, null)
      if (bytesRead === 0) break
      hash.update(buffer.subarray(0, bytesRead))
    }
  } finally {
    await handle.close()
  }
  return hash.digest()
}

/**
 * Whether a staged file is the one the feed described.
 *
 * Length first: it is a `stat`, it is the failure a truncated transfer actually
 * produces, and reporting it as "the file is 4 MB short" is more useful than
 * reporting a digest that did not match. The digest still runs on every file
 * that passes the length check — the length is an early-out, never a substitute.
 *
 * `timingSafeEqual` over the raw bytes rather than `===` over the base64. No
 * secret is being compared and the timing does not matter; what matters is that
 * comparing decoded 64-byte buffers forces the feed's value to be *decoded and
 * length-checked* first, which is where a truncated, re-padded or hex-encoded
 * hash gets caught. String equality would call all three of those a mismatch
 * and blame the download.
 */
export type VerifyOutcome =
  | { ok: true }
  | { ok: false; reason: 'size-mismatch' | 'checksum-mismatch'; message: string }

export async function verifyArchive(path: string, expected: FeedFile): Promise<VerifyOutcome> {
  const digest = decodeSha512(expected.sha512)
  if (!digest) {
    return {
      ok: false,
      reason: 'checksum-mismatch',
      message: 'The release feed carried a sha512 that is not a valid base64 sha512 digest.',
    }
  }

  const actualSize = (await stat(path)).size
  if (actualSize !== expected.size) {
    return {
      ok: false,
      reason: 'size-mismatch',
      message:
        `The download is ${actualSize} bytes but the release feed says ` +
        `${expected.size}. The file was removed.`,
    }
  }

  const actual = await sha512OfFile(path)
  if (actual.length !== digest.length || !timingSafeEqual(actual, digest)) {
    return {
      ok: false,
      reason: 'checksum-mismatch',
      message:
        'The download is the right length but its sha512 does not match the release ' +
        'feed, so these are not the published bytes. The file was removed.',
    }
  }
  return { ok: true }
}

/* -------------------------------------------------------- the macOS tools -- */

/**
 * How long the two external tools may take before they are treated as wedged.
 *
 * Not performance limits — they are absurdity limits. Unpacking 300 MB takes
 * seconds on the internal disk and could take minutes on a tired external one,
 * so fifteen minutes says nothing about a slow machine and everything about a
 * process that is never coming back. Without a bound, a wedged `ditto` leaves
 * this call pending forever, and since calls against one staging directory are
 * serialised, it would take every later call with it.
 *
 * Note that the timeout *firing* is the one branch in this module with no test
 * behind it: making a real `ditto` hang on demand is not something these tests
 * can arrange honestly. The success path runs through the same option on every
 * end-to-end test.
 */
const EXTRACT_TIMEOUT_MS = 15 * 60_000
const PLIST_TIMEOUT_MS = 60_000

/** `ditto -x -k`. `--` so an archive name can never be read as a flag. */
export const dittoExtract: Extractor = async (archivePath, destDir) => {
  await run(DITTO, ['-x', '-k', '--', archivePath, destDir], { timeout: EXTRACT_TIMEOUT_MS })
}

/**
 * A plist as an object, via `plutil`.
 *
 * Shelling out rather than parsing XML for the same reason extraction shells
 * out: the OS ships the converter, it reads the binary format too — which
 * `Info.plist` is allowed to be, even though electron-builder writes XML — and
 * a hand-rolled reader for someone else's file format is a second place to be
 * wrong about entities and nesting.
 */
export const plutilReadPlist: PlistReader = async (path) => {
  const { stdout } = await run(PLUTIL, ['-convert', 'json', '-o', '-', '--', path], {
    maxBuffer: 4 * 1024 * 1024,
    timeout: PLIST_TIMEOUT_MS,
  })
  const parsed: unknown = JSON.parse(stdout)
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('the plist did not convert to an object')
  }
  return parsed as Record<string, unknown>
}

/* ----------------------------------------------------- bundle inspection -- */

export interface BundleFacts {
  /** Absolute path to `<name>.app`. */
  path: string
  /** `CFBundleExecutable`. */
  executableName: string
  /** Absolute path to `Contents/MacOS/<CFBundleExecutable>`. */
  executablePath: string
  /** `CFBundleShortVersionString`. */
  version: string
}

export type BundleVerdict = { ok: true; bundle: BundleFacts } | { ok: false; message: string }

function stringField(plist: Record<string, unknown>, key: string): string | null {
  const value = plist[key]
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

/**
 * Whether what came out of the archive is an app bundle.
 *
 * "It extracted without an error" is not the same claim. ditto will happily
 * unpack a zip of one text file, and the caller would then be handed a path to
 * a directory of nothing. Four things are checked, in the order that a wrong
 * archive fails them: exactly one `.app` at the top level, an `Info.plist`
 * inside it, a `CFBundleExecutable` that names a file in `Contents/MacOS`, and
 * a mode with an execute bit somewhere in it.
 *
 * The executable name is rejected if it contains a path separator. It comes out
 * of a plist that came out of a downloaded archive, and it is concatenated onto
 * `Contents/MacOS/`; a value of `../../../../bin/sh` would otherwise make this
 * function report that some file well outside the bundle exists and is
 * executable, which is true and completely beside the point.
 *
 * More than one `.app` is refused rather than resolved by picking the first.
 * A release zip contains one bundle; two means the archive is not what its name
 * says, and guessing which one to hand back is how the wrong one gets handed
 * back.
 */
export async function inspectBundle(
  directory: string,
  readPlist: PlistReader = plutilReadPlist,
): Promise<BundleVerdict> {
  let entries: string[]
  try {
    entries = (await readdir(directory, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory() && entry.name.endsWith('.app'))
      .map((entry) => entry.name)
  } catch {
    return { ok: false, message: 'The archive did not extract into a readable directory.' }
  }

  if (entries.length === 0) {
    return { ok: false, message: 'The archive contains no .app bundle, so it is not an app.' }
  }
  if (entries.length > 1) {
    return {
      ok: false,
      message: `The archive contains ${entries.length} .app bundles; a release contains one.`,
    }
  }

  const bundlePath = join(directory, entries[0])
  const plistPath = join(bundlePath, 'Contents', 'Info.plist')
  let plist: Record<string, unknown>
  try {
    plist = await readPlist(plistPath)
  } catch {
    return { ok: false, message: `${entries[0]} has no readable Contents/Info.plist.` }
  }

  const executableName = stringField(plist, 'CFBundleExecutable')
  const version = stringField(plist, 'CFBundleShortVersionString')
  if (!executableName || !version) {
    return {
      ok: false,
      message: `${entries[0]} has an Info.plist with no CFBundleExecutable or no version.`,
    }
  }
  if (executableName.includes('/') || executableName.includes('\\')) {
    return { ok: false, message: `${entries[0]} names an executable outside its own bundle.` }
  }

  const executablePath = join(bundlePath, 'Contents', 'MacOS', executableName)
  let mode: number
  try {
    const info = await stat(executablePath)
    if (!info.isFile()) {
      return { ok: false, message: `${entries[0]} has no binary at Contents/MacOS/${executableName}.` }
    }
    mode = info.mode
  } catch {
    return { ok: false, message: `${entries[0]} has no binary at Contents/MacOS/${executableName}.` }
  }
  if ((mode & 0o111) === 0) {
    return {
      ok: false,
      message: `${entries[0]}'s binary is not executable, so the extraction lost its permissions.`,
    }
  }

  return { ok: true, bundle: { path: bundlePath, executableName, executablePath, version } }
}

/**
 * The `.app` staged for `version`, or null when there is not a usable one.
 *
 * A real look at the disk, not a path guess: the answer to "is this version
 * already downloaded" has to be false when the directory exists but holds a
 * half-extracted tree, which is exactly the state a crash during extraction
 * leaves behind.
 *
 * Structure alone does not answer that, which is why the completion marker is
 * required here too. A tree can be missing `Frameworks/` and still have an
 * `Info.plist` and an executable — it inspects clean and it will not launch. The
 * caller of this function is the installer: it is about to move whatever this
 * returns over the user's application and then delete the backup. "I am not
 * sure" has to come back as null.
 *
 * It does not re-hash the archive. The marker proves the tree came out of a
 * verified archive by a run that finished; whether *that* archive is still the
 * one the current feed names is a question only the feed can answer, so callers
 * needing that guarantee should call {@link fetchUpdate}, which returns the same
 * path and re-verifies before reusing anything.
 */
export async function stagedBundlePath(
  version: string,
  userDataPath: string,
  readPlist: PlistReader = plutilReadPlist,
): Promise<string | null> {
  if (!SAFE_VERSION.test(version)) return null
  const bundleDir = extractDir(version, userDataPath)
  if ((await readExtractionMarker(bundleDir)) === null) return null
  const verdict = await inspectBundle(bundleDir, readPlist)
  if (!verdict.ok) return null
  return verdict.bundle.version === version ? verdict.bundle.path : null
}

/* -------------------------------------------------------------- download -- */

class Cancelled extends Error {}

/**
 * Emits progress at most once per interval, and never backwards.
 *
 * Monotonicity is structural rather than asserted: `transferred` only ever has
 * chunk lengths added to it, and `percent` is floored and clamped, so it cannot
 * reach 100 before the last byte and cannot pass it if the server sends more
 * than the feed declared.
 */
function progressReporter(
  version: string,
  total: number,
  emit: ((progress: FetchProgress) => void) | undefined,
  intervalMs: number,
  now: () => number,
): { tick: (transferred: number) => void; final: (transferred: number) => void } {
  let lastEmitAt = 0
  let lastPercent = -1

  const send = (transferred: number): void => {
    if (!emit) return
    const percent = Math.min(100, Math.floor((transferred / total) * 100))
    lastEmitAt = now()
    lastPercent = percent
    emit({ version, transferred, total, percent })
  }

  return {
    tick: (transferred) => {
      if (!emit) return
      if (now() - lastEmitAt < intervalMs) return
      send(transferred)
    },
    // The last tick is unconditional: a throttle that swallows it leaves a bar
    // stopped at 97% next to a finished download.
    final: (transferred) => {
      if (!emit) return
      const percent = Math.min(100, Math.floor((transferred / total) * 100))
      if (percent === lastPercent && lastPercent === 100) return
      send(transferred)
    },
  }
}

/**
 * Stream a response body to `destination`, reporting progress.
 *
 * Nothing is buffered: chunks go straight from the reader to the file handle,
 * so peak memory is one chunk regardless of whether the release is 119 MB or
 * 500. `sync()` before returning is what makes the rename that follows mean
 * something — a rename is atomic with respect to the directory entry, not with
 * respect to data still sitting in the page cache.
 */
async function streamToFile(
  body: ReadableStream<Uint8Array>,
  destination: string,
  report: { tick: (transferred: number) => void; final: (transferred: number) => void },
  signal: AbortSignal | undefined,
): Promise<number> {
  // `wx`, not `w`: this is the one file two runs would otherwise share, and the
  // failure it produces is silent — two writers at independent offsets in one
  // inode, then whichever finishes first renames it out from under the other.
  // Overlapping calls inside this process are already serialised; a second
  // *process* can only be refused, and being refused with EEXIST is the useful
  // outcome. The caller unlinks any leftover from an interrupted run first, so
  // this cannot trip on stale state.
  const handle = await open(destination, 'wx')
  const reader = body.getReader()
  let transferred = 0
  try {
    for (;;) {
      if (signal?.aborted) throw new Cancelled()
      const { done, value } = await reader.read()
      if (done) break
      if (!value || value.length === 0) continue
      await handle.write(value)
      transferred += value.length
      report.tick(transferred)
    }
    await handle.sync()
  } finally {
    await reader.cancel().catch(() => {})
    await handle.close()
  }
  report.final(transferred)
  return transferred
}

/** Distinguishes "the feed is absurd" from "the feed did not arrive". */
class FeedTooLarge extends Error {}

/** Read a bounded amount of text, so an oversized feed is refused mid-flight. */
async function readTextBounded(body: ReadableStream<Uint8Array>, max: number): Promise<string> {
  const reader = body.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (!value) continue
      size += value.length
      if (size > max) throw new FeedTooLarge(`the feed exceeded ${max} bytes`)
      chunks.push(value)
    }
  } finally {
    await reader.cancel().catch(() => {})
  }
  return Buffer.concat(chunks).toString('utf8')
}

/* ----------------------------------------------------------- housekeeping -- */

/**
 * Remove every staging directory except the one in flight.
 *
 * Runs before the download rather than after it, so the disk space a superseded
 * 119 MB release is holding is free by the time the new one needs it. Failures
 * are swallowed on purpose: not reclaiming space is not a reason to refuse to
 * download.
 */
async function removeOtherVersions(root: string, keep: string): Promise<void> {
  let entries: string[]
  try {
    entries = (await readdir(root, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
  } catch {
    return
  }
  for (const name of entries) {
    if (name === keep) continue
    await rm(join(root, name), { recursive: true, force: true }).catch(() => {})
  }
}

function failure(
  reason: FetchFailureReason,
  message: string,
  detail: string | null = null,
): FetchUpdateResult {
  return { ok: false, reason, message, detail }
}

/** A thrown value's `errno` code, without asserting a shape onto `unknown`. */
function errorCode(error: unknown): string {
  if (typeof error !== 'object' || error === null || !('code' in error)) return ''
  const { code } = error as { code?: unknown }
  return typeof code === 'string' ? code : ''
}

function detailOf(error: unknown): string | null {
  if (error instanceof Error) {
    const stderr = (error as { stderr?: unknown }).stderr
    if (typeof stderr === 'string' && stderr.trim() !== '') return stderr.trim().slice(0, 400)
    return error.message.trim().slice(0, 400) || null
  }
  const text = String(error).trim()
  return text === '' ? null : text.slice(0, 400)
}

/* ------------------------------------------------------------------ fetch -- */

/**
 * Read the feed, download the zip it names, prove it, and unpack it.
 *
 * The order is the contract. Nothing is renamed off `.part` until the digest
 * matches, nothing is extracted until the rename happened, and nothing is
 * returned until the extracted tree has been shown to be an app bundle at the
 * version the feed promised. Every failure between those steps leaves the
 * staging directory without a file that could be mistaken for a finished
 * download.
 *
 * Reuse is the same contract run against what is already on disk: a staged
 * archive is re-verified, not trusted because it is present. If it verifies but
 * the bundle beside it is missing or broken, it is unpacked again — that costs
 * seconds and no bandwidth. If it does not verify, it is deleted and refetched.
 */
async function runFetchUpdate(options: FetchUpdateOptions): Promise<FetchUpdateResult> {
  const {
    feedUrl,
    userDataPath,
    platform,
    fetch: fetchImpl,
    onProgress,
    signal,
    extract = dittoExtract,
    readPlist = plutilReadPlist,
    progressIntervalMs = PROGRESS_INTERVAL_MS,
    now = () => Date.now(),
  } = options

  // ditto, plutil and `.app` bundles are all macOS. On anything else this is
  // not "failed", it is "does not apply", and saying so is more use than a
  // spawn error naming a binary that was never going to be there.
  if (platform !== 'darwin') {
    return failure(
      'unsupported-platform',
      'Downloading an update this way is macOS-only; this build runs on ' + platform + '.',
    )
  }

  // A queued call can be cancelled while it waits for the one ahead of it. Ask
  // before opening a socket rather than after.
  if (signal?.aborted) return failure('cancelled', 'The update download was cancelled.')

  /* ---- the feed ---- */

  let feedText: string
  try {
    const response = await fetchImpl(feedUrl, { signal })
    if (!response.ok) {
      return failure(
        'feed-unreachable',
        `The release feed could not be read (HTTP ${response.status}).`,
      )
    }
    if (!response.body) return failure('feed-unreachable', 'The release feed came back empty.')
    feedText = await readTextBounded(response.body, MAX_FEED_BYTES)
  } catch (error) {
    if (signal?.aborted) return failure('cancelled', 'The update download was cancelled.')
    // "Too big to be a feed" is a different sentence from "it did not arrive",
    // and only one of them is worth retrying.
    if (error instanceof FeedTooLarge) {
      return failure(
        'feed-unreadable',
        `The release feed is larger than ${MAX_FEED_BYTES} bytes, so it is not a release feed.`,
      )
    }
    return failure('feed-unreachable', 'The release feed could not be reached.', detailOf(error))
  }

  const feed = parseFeed(feedText)
  if (!feed) {
    return failure(
      'feed-unreadable',
      'The release feed did not contain a usable version, so there is nothing to download.',
    )
  }

  const archive = chooseArchive(feed)
  if (!archive) {
    // Named precisely, because a feed with only a dmg is a packaging change on
    // our side rather than anything the user can retry. The listed names go in
    // the sentence so the packaging mistake is visible without reading the feed.
    const listed = feed.files.map((file) => file.url).join(', ')
    return failure(
      'no-zip',
      `Release ${feed.version} publishes no .zip to download` +
        (listed === ''
          ? '.'
          : `, only ${listed}. A .dmg cannot be unpacked without mounting it.`),
    )
  }

  const asset = resolveAsset(archive, feedUrl)
  if (!asset) {
    return failure(
      'feed-unreadable',
      `Release ${feed.version} names an archive this app will not fetch: it must be an https .zip.`,
    )
  }

  const { version } = feed
  const staging = stagingDir(version, userDataPath)
  const archivePath = join(staging, asset.fileName)
  const partPath = `${archivePath}.part`
  const bundleDir = extractDir(version, userDataPath)

  try {
    await mkdir(staging, { recursive: true })
  } catch (error) {
    return failure('download-failed', 'The staging directory could not be created.', detailOf(error))
  }
  await removeOtherVersions(updatesRoot(userDataPath), version)

  /* ---- unpack, check, and report — shared by the reuse and download paths ---- */

  // The digest the tree has to have come from. Non-null by the time this runs:
  // both callers verify the archive first, and verification decodes this value.
  const expectedDigest = canonicalDigest(archive.sha512)

  const finish = async (reused: boolean): Promise<FetchUpdateResult> => {
    // Provenance first, structure second. "It looks like a bundle at the right
    // version" is what a half-extracted tree also looks like; only the marker
    // distinguishes a tree an extraction finished on from one it stopped in the
    // middle of, and only the digest inside it distinguishes this release from
    // a differently built archive wearing the same version number.
    const marker = await readExtractionMarker(bundleDir)
    if (expectedDigest !== null && marker === expectedDigest) {
      const staged = await inspectBundle(bundleDir, readPlist)
      if (staged.ok && staged.bundle.version === version) {
        return {
          ok: true,
          version,
          archivePath,
          bundlePath: staged.bundle.path,
          sizeBytes: archive.size,
          reused,
        }
      }
    }

    // Whatever is there is not a finished extraction of this archive. Start from
    // an empty directory rather than letting ditto merge into a partial tree,
    // where a stale binary would survive under a new Info.plist — and delete it
    // before extracting, so the marker is gone for the whole time the tree is
    // incomplete.
    await rm(bundleDir, { recursive: true, force: true }).catch(() => {})
    try {
      await extract(archivePath, bundleDir)
    } catch (error) {
      return failure(
        'extract-failed',
        `The verified archive for ${version} could not be unpacked.`,
        detailOf(error),
      )
    }

    const verdict = await inspectBundle(bundleDir, readPlist)
    if (!verdict.ok) {
      await rm(bundleDir, { recursive: true, force: true }).catch(() => {})
      return failure('not-a-bundle', verdict.message)
    }
    if (verdict.bundle.version !== version) {
      await rm(bundleDir, { recursive: true, force: true }).catch(() => {})
      return failure(
        'version-mismatch',
        `The feed promised ${version} but the downloaded app reports ${verdict.bundle.version}.`,
      )
    }

    // Last, so the marker exists only once everything above has held. A failure
    // to write it is a failure of the whole step: the alternative is returning a
    // tree that the next run — and the installer, through `stagedBundlePath` —
    // has no way to tell apart from a half-finished one.
    if (expectedDigest !== null) {
      try {
        await writeFile(join(bundleDir, EXTRACTION_MARKER), `${expectedDigest}\n`)
      } catch (error) {
        await rm(bundleDir, { recursive: true, force: true }).catch(() => {})
        return failure(
          'extract-failed',
          `The update for ${version} unpacked but could not be recorded as verified, so it ` +
            'was discarded rather than left looking finished.',
          detailOf(error),
        )
      }
    }

    return {
      ok: true,
      version,
      archivePath,
      bundlePath: verdict.bundle.path,
      sizeBytes: archive.size,
      reused,
    }
  }

  /* ---- reuse what is already staged, if it still verifies ---- */

  let alreadyStaged = false
  try {
    alreadyStaged = (await stat(archivePath)).isFile()
  } catch {
    alreadyStaged = false
  }

  if (alreadyStaged) {
    const verified = await verifyArchive(archivePath, archive).catch(
      (): VerifyOutcome => ({
        ok: false,
        reason: 'checksum-mismatch',
        message: 'The staged archive could not be read.',
      }),
    )
    if (verified.ok) return finish(true)
    // A staged file that no longer verifies is not evidence of anything. It
    // goes, along with whatever was extracted from it, and the download runs.
    await rm(archivePath, { force: true }).catch(() => {})
    await rm(bundleDir, { recursive: true, force: true }).catch(() => {})
  }

  /* ---- download ---- */

  // Any leftover part file is from an interrupted run and has no claim on the
  // bytes about to arrive.
  await rm(partPath, { force: true }).catch(() => {})

  const report = progressReporter(version, archive.size, onProgress, progressIntervalMs, now)

  try {
    const response = await fetchImpl(asset.url, { signal })
    if (!response.ok) {
      return failure(
        'download-failed',
        `Downloading ${asset.fileName} failed (HTTP ${response.status}).`,
      )
    }
    if (!response.body) {
      return failure('download-failed', `The server returned no body for ${asset.fileName}.`)
    }

    // A declared length that disagrees with the feed is knowable before a
    // single byte is stored, and it is the same failure as a short download —
    // worth catching here rather than 119 MB later. Skipped when the body is
    // encoded, because then Content-Length describes the compressed stream and
    // has nothing to say about the file.
    const declared = response.headers.get('content-length')
    const encoded = response.headers.get('content-encoding')
    if (declared !== null && !encoded) {
      const length = Number(declared)
      if (Number.isSafeInteger(length) && length > 0 && length !== archive.size) {
        return failure(
          'size-mismatch',
          `The server offers ${asset.fileName} as ${length} bytes but the release feed says ` +
            `${archive.size}. Nothing was downloaded.`,
        )
      }
    }

    await streamToFile(response.body, partPath, report, signal)
  } catch (error) {
    // EEXIST means another process created the part file between the unlink
    // above and the open. Its bytes are not ours to delete, so this branch
    // returns *before* the cleanup below touches anything.
    if (errorCode(error) === 'EEXIST') {
      return failure(
        'download-failed',
        `Another copy of this app is already downloading ${asset.fileName}. Nothing was ` +
          'changed here; wait for that one to finish, or close it and try again.',
      )
    }
    await rm(partPath, { force: true }).catch(() => {})
    if (error instanceof Cancelled || signal?.aborted) {
      return failure('cancelled', 'The update download was cancelled.')
    }
    return failure(
      'download-failed',
      `Downloading ${asset.fileName} stopped before it finished.`,
      detailOf(error),
    )
  }

  /* ---- verify before anything else touches it ---- */

  let verified: VerifyOutcome
  try {
    verified = await verifyArchive(partPath, archive)
  } catch (error) {
    await rm(partPath, { force: true }).catch(() => {})
    return failure(
      'download-failed',
      `The download of ${asset.fileName} could not be read back to verify it.`,
      detailOf(error),
    )
  }
  if (!verified.ok) {
    await rm(partPath, { force: true }).catch(() => {})
    return failure(verified.reason, verified.message)
  }

  // The rename is the moment unverified bytes become a release. Nothing above
  // this line may use the finished name, and nothing below it may skip the
  // check that got here.
  try {
    await rename(partPath, archivePath)
  } catch (error) {
    await rm(partPath, { force: true }).catch(() => {})
    return failure(
      'download-failed',
      'The verified download could not be moved into place.',
      detailOf(error),
    )
  }

  return finish(false)
}

/**
 * One run at a time per `userData`, in this process.
 *
 * Keyed by the directory rather than held in a single global so a test can drive
 * two staging roots at once without one waiting on the other, and cleared when
 * the chain drains so nothing accumulates across a long-running app.
 */
const inFlight = new Map<string, Promise<void>>()

/**
 * {@link runFetchUpdate}, serialised.
 *
 * The user has one button and it is the kind people press twice. Two runs
 * against one staging directory used to race over a single `.part` path: the
 * second one's opening unlink took the file the first was still writing into,
 * and the first then failed on a path that had stopped existing — an update
 * refused for no reason the user could act on. Nothing corrupt ever reached the
 * verified name (the digest is taken by path immediately before the rename), so
 * this is a reliability fix rather than an integrity one, but the cheapest way
 * to keep that true is to have the second caller wait: it then finds the
 * archive staged and returns `reused: true` without spending a byte.
 */
export function fetchUpdate(options: FetchUpdateOptions): Promise<FetchUpdateResult> {
  const key = updatesRoot(options.userDataPath)
  const previous = inFlight.get(key) ?? Promise.resolve()
  // Both arms run the work: a run that failed says nothing about the next one.
  const result = previous.then(
    () => runFetchUpdate(options),
    () => runFetchUpdate(options),
  )
  const link: Promise<void> = result.then(
    () => {},
    () => {},
  )
  // Only the tail clears the entry, so a later caller that has already chained
  // onto this link is never dropped from the queue.
  void link.then(() => {
    if (inFlight.get(key) === link) inFlight.delete(key)
  })
  inFlight.set(key, link)
  return result
}
