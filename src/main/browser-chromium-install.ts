import { createHash, timingSafeEqual } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { unzip } from './browser-extension-unzip'
import { currentPlatform, type Platform } from './platform/host'
import { userDataDir } from './platform/paths'

/**
 * Acquiring the Chromium a headless server drives — the same download-and-verify
 * discipline the extension store and the tools store already keep, pointed at
 * chrome-for-testing instead of a GitHub release.
 *
 * ## Why this binary and not the one that is already here
 *
 * The desktop shell has a Chromium — Electron's — and this file does not use it.
 * A server has no Electron and no window, so `browser-chromium-launch.ts` needs
 * a standalone browser to spawn, and it has to be one that can actually load an
 * extension. Two Chromium builds published by Google were candidates and only
 * one survives the requirement:
 *
 *  - **chrome-headless-shell** is small and made for automation, and it has
 *    *zero* extension support — `--load-extension` is silently ignored. The
 *    whole point of `browser-extension-support.ts` is that extensions load and
 *    run, so a runtime that cannot load one is not this product's runtime.
 *  - **the system `chrome`** is whatever the box happens to have, at whatever
 *    version, patched out from under us on the distro's schedule. The extension
 *    behaviour in `browser-extension-support.ts` and `browser-extension-compat.ts`
 *    was *measured*, against one exact Chromium, and a measurement against a
 *    version that drifts is a measurement that expires without telling anyone.
 *
 * So this fetches the **full `chrome`** build from chrome-for-testing, pinned to
 * a version, unpacked under this app's own user-data directory where nothing
 * else can rewrite it.
 *
 * ## Which version, and why that exact one
 *
 * `browser-extension-support.ts` pins `CHROMIUM_MEASURED = '146.0.7680.216'` —
 * the Chromium inside the Electron this app ships, and the version every
 * extension-compat measurement was taken against. To keep those measurements
 * valid the standalone runtime has to be the same Chromium. chrome-for-testing
 * does **not** publish `146.0.7680.216` (Electron builds its own Chromium
 * revisions), so this pins the nearest published build in the same
 * `146.0.7680` patch family — {@link PINNED_CHROMIUM_VERSION} — which shares the
 * milestone, the feature set and the extension surface. If chrome-for-testing
 * ever publishes `.216` itself, this constant should move to it; the family is
 * the invariant, not the literal.
 *
 * ## The integrity check, said honestly
 *
 * The tools store and the extension store verify a **sha256 pinned in this
 * app's own bytes** before a single byte is written — the strongest arrangement,
 * because the digest travels in the program rather than beside the download.
 * chrome-for-testing's `known-good-versions-with-downloads.json` publishes the
 * download **URL** but no digest at all, so for the build this app actually ships
 * the digest is pinned here instead: {@link PINNED_CHROMIUM_SHA256} holds the
 * sha256 of each platform's archive for {@link PINNED_CHROMIUM_VERSION}, and it
 * is the default authority ({@link defaultPinnedSha256}). A caller may still
 * override it with an explicit {@link InstallOptions.pinnedSha256}, and when
 * neither the caller nor the map has a sha256 for the build in hand — a version
 * other than the pinned one — the fallback verifies the bytes against the **md5
 * that Google Cloud Storage publishes for that exact object** in its
 * `x-goog-hash` response header. All three are a checksum verified before use;
 * none is a silent "trust the download". When neither a pin nor a header digest
 * is available the install is a *named error* and nothing is written — the same
 * refusal the extension store makes, never a fallback to unverified bytes.
 *
 * ## Air-gapped override
 *
 * {@link CHROMIUM_PATH_ENV} points the runtime at a side-loaded binary and skips
 * the download entirely, matching the `TERMINALDECK_RELAY_URL` precedent in
 * `remote/relay-client.ts`: the environment wins over what is compiled in, for
 * an operator running their own copy, and it is a supported thing to do rather
 * than a downgrade. The one check kept is that the path actually exists — a
 * missing override is a named error, not a later spawn failure.
 *
 * ## Nothing here reaches Electron
 *
 * This module is in the headless closure `seam.test.ts` walks, so it imports
 * only `node:*`, the shared `browser-extension-unzip.ts` (itself `node:zlib` and
 * nothing else) and the `platform/paths.ts` seam. `userDataDir()` is read at
 * call time, and only when no explicit root is supplied, so a test never needs
 * `installPaths` and production reads the directory the shell installed at boot.
 */

/* --------------------------------------------------------------- the pin -- */

/**
 * The chrome-for-testing build this runtime installs.
 *
 * The nearest published build to `CHROMIUM_MEASURED` (`146.0.7680.216`) in the
 * `146.0.7680` family — see the module header. Kept as a bare literal rather
 * than imported from `browser-extension-support.ts` so this file adds nothing to
 * the headless closure beyond `node:*` and the two seams it already needs; the
 * derivation lives in the comment, which is where a future bump reconciles it.
 */
export const PINNED_CHROMIUM_VERSION = '146.0.7680.165'

/**
 * The sha256 of each platform's `chrome-<platform>.zip` for
 * {@link PINNED_CHROMIUM_VERSION} — the app-owned digest, pinned in this
 * program's own bytes.
 *
 * ## Why this exists and what it upgrades
 *
 * chrome-for-testing's index publishes a download **URL** and no digest at all,
 * so before this map the only thing to verify the archive against was the **md5
 * Google Cloud Storage prints in the object's `x-goog-hash` response header** —
 * a checksum that travels *beside* the download and vouches for it with the same
 * authority that served it. That is the fallback, not the floor. The extension
 * store and the tools store both verify a sha256 that ships **inside the
 * application**, and this brings the standalone-Chromium install up to the same
 * discipline: for the pinned build the digest is now app-owned, and the server's
 * md5 is consulted only when no pin exists for a build (see
 * {@link defaultPinnedSha256} and {@link verifyChecksum}).
 *
 * ## How these were derived, and how to re-derive them on a bump
 *
 * Each value is the sha256 of the exact object at
 * {@link downloadUrlFor}`(PINNED_CHROMIUM_VERSION, platform)`, computed on
 * 2026-08-22 and cross-checked against the md5 GCS publishes for that same
 * object — the download's bytes were confirmed to reproduce the header md5
 * before being sha256'd, so a truncated fetch could not have seeded a wrong pin.
 * The one-liner, per platform:
 *
 *     curl -sSL "$(url)" | shasum -a 256
 *
 * When {@link PINNED_CHROMIUM_VERSION} moves, recompute all four and replace
 * them in the same commit; a version whose sha is stale here would be refused by
 * its own integrity check rather than fall back — which is the safe direction,
 * but a self-inflicted outage all the same, so the two constants move together.
 */
export const PINNED_CHROMIUM_SHA256: Record<CftPlatform, string> = {
  linux64: '0436ed08838d35a05ef0b0f20b07cca5fddb88ec6a0c76c143d6c137d6f70ed1',
  'mac-arm64': '41f692f646dd3ce07ed377d71a15f90e8f2f9a3e3af383c5dde0718f034d6b52',
  'mac-x64': '266fe088699a2bdaec210ecb5a4951d9f6047ab5a54d58b220d9602ca0b00a5f',
  win64: '65d1d4d993da8b24fc871f59f7c8100ffc3719afd58cbf843d81d6ada9bc9880',
}

/**
 * The app-owned sha256 to verify a download against, or `undefined` when there
 * is none for this exact build.
 *
 * Keyed on version as well as platform because {@link PINNED_CHROMIUM_SHA256} is
 * a digest of one build's bytes: it is the authority for
 * {@link PINNED_CHROMIUM_VERSION} and says nothing about any other version, so a
 * caller installing a different one (a test, or a future bump before its shas are
 * filled in) gets `undefined` here and falls back to the server-published md5
 * rather than being checked against the wrong digest.
 */
export function defaultPinnedSha256(version: string, platform: CftPlatform): string | undefined {
  return version === PINNED_CHROMIUM_VERSION ? PINNED_CHROMIUM_SHA256[platform] : undefined
}

/** The versions index chrome-for-testing publishes, with per-platform URLs. */
export const KNOWN_GOOD_VERSIONS_URL =
  'https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json'

/**
 * Point the runtime at a side-loaded Chromium instead of downloading one.
 *
 * The env-not-a-setting precedent from `RELAY_URL_ENV`: an operator on an
 * air-gapped or bandwidth-metered box drops a `chrome` on disk and names it
 * here, and the install returns it untouched.
 */
export const CHROMIUM_PATH_ENV = 'TERMINALDECK_CHROMIUM_PATH'

/* ------------------------------------------------------------- ceilings -- */

/**
 * The most the archive may be, and unpack to.
 *
 * A chrome-for-testing `linux64` zip is ~183 MB and unpacks to ~600 MB; these
 * leave headroom for a version that grows without leaving room for an archive
 * trying to fill a disk. Applied — as `browser-extension-unzip.ts` insists — to
 * what actually arrives and to what actually comes out, never to a header's or a
 * zip index's claim about it.
 */
export const MAX_CHROMIUM_ZIP_BYTES = 400 * 1024 * 1024
export const MAX_CHROMIUM_UNPACKED_BYTES = 2 * 1024 * 1024 * 1024
export const MAX_CHROMIUM_FILES = 40_000

/**
 * The Chromium binaries that must come out of the archive executable.
 *
 * `unzip` deliberately drops a zip entry's unix mode bits — an extension is
 * loaded, never executed, so it has no use for them — but a downloaded Chromium
 * has to *run*, and its zip carries the exec bit that `unzip` discards. Rather
 * than teach the shared, security-hardened unpacker about modes (it is used by
 * another feature and by another lane, and widening it here would collide),
 * these named binaries are `chmod`ed after extraction. The main executable
 * always; the helpers only if the platform ships them.
 */
const EXECUTABLE_HELPERS = ['chrome_crashpad_handler', 'chrome_sandbox']

/* ---------------------------------------------------------- the platform -- */

export type CftPlatform = 'linux64' | 'mac-arm64' | 'mac-x64' | 'win64'

/**
 * The chrome-for-testing platform key for a host, or `null` when there is no
 * build for it.
 *
 * A parameter for the reason `platform/host.ts` gives at length: a branch on the
 * running machine can only be tested on that machine, and this code's whole job
 * is to resolve keys for platforms it is never built on. `linux64` is the only
 * key this milestone actually launches; the rest resolve correctly so the code
 * is not linux-hardcoded, and an arch with no published build is a named `null`
 * rather than a wrong guess — chrome-for-testing publishes no Linux arm64 and no
 * 32-bit build.
 */
export function cftPlatformFor(platform: Platform, arch: string): CftPlatform | null {
  if (platform === 'linux') return arch === 'x64' ? 'linux64' : null
  if (platform === 'win32') return arch === 'x64' ? 'win64' : null
  if (platform === 'darwin') {
    if (arch === 'arm64') return 'mac-arm64'
    if (arch === 'x64') return 'mac-x64'
    return null
  }
  return null
}

/** Where `chrome` lives inside the archive's single top-level directory. */
export function chromeExecutableRel(platform: CftPlatform): string {
  switch (platform) {
    case 'linux64':
      return 'chrome'
    case 'win64':
      return 'chrome.exe'
    case 'mac-arm64':
    case 'mac-x64':
      return 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'
  }
}

/** The top-level directory a chrome-for-testing archive unwraps to. */
export function archiveTopDir(platform: CftPlatform): string {
  return `chrome-${platform}`
}

/* --------------------------------------------------------- URL resolution -- */

export type ResolveResult =
  | { ok: true; version: string; platform: CftPlatform; url: string }
  | { ok: false; why: string }

/** The expected canonical download URL for a version and platform. */
export function downloadUrlFor(version: string, platform: CftPlatform): string {
  return `https://storage.googleapis.com/chrome-for-testing-public/${version}/${platform}/chrome-${platform}.zip`
}

/**
 * Find one version's `chrome` download for one platform in the known-good index.
 *
 * Pure over the parsed JSON so `browser-chromium-install.test.ts` can drive it
 * against a fixture with no network. Every failure is a sentence naming what was
 * not found rather than a throw, because the caller turns it straight into the
 * install's own named error.
 *
 * The URL the index gives is checked against {@link downloadUrlFor} rather than
 * trusted: the index is fetched over https but is not this app's own bytes, and
 * an entry that points somewhere other than the canonical object — a different
 * host, a different version — is refused. This is the same instinct as
 * `httpsFetchArchive`'s "the scheme is still checked on the URL this app holds":
 * the digest is the real guard, and this is the cheap structural one in front of
 * it.
 */
export function resolveChromeDownload(
  json: unknown,
  version: string,
  platform: CftPlatform,
): ResolveResult {
  if (typeof json !== 'object' || json === null) {
    return { ok: false, why: 'the chrome-for-testing versions index was not an object' }
  }
  const versions = (json as { versions?: unknown }).versions
  if (!Array.isArray(versions)) {
    return { ok: false, why: 'the chrome-for-testing versions index had no versions array' }
  }

  const entry = versions.find(
    (row): row is { version: string; downloads?: unknown } =>
      typeof row === 'object' &&
      row !== null &&
      (row as { version?: unknown }).version === version,
  )
  if (entry === undefined) {
    return {
      ok: false,
      why: `chrome-for-testing does not publish version ${version}`,
    }
  }

  const downloads = (entry.downloads as { chrome?: unknown } | undefined)?.chrome
  if (!Array.isArray(downloads)) {
    return { ok: false, why: `version ${version} lists no chrome downloads` }
  }
  const download = downloads.find(
    (row): row is { platform: string; url: string } =>
      typeof row === 'object' &&
      row !== null &&
      (row as { platform?: unknown }).platform === platform &&
      typeof (row as { url?: unknown }).url === 'string',
  )
  if (download === undefined) {
    return {
      ok: false,
      why: `version ${version} has no chrome build for ${platform}`,
    }
  }

  const expected = downloadUrlFor(version, platform)
  if (download.url !== expected) {
    return {
      ok: false,
      why: `the index points ${platform} at ${download.url}, not the expected ${expected}`,
    }
  }
  return { ok: true, version, platform, url: download.url }
}

/* ------------------------------------------------------------- checksums -- */

export type ChecksumUsed = 'sha256' | 'md5' | 'none'

export interface ChecksumResult {
  ok: boolean
  used: ChecksumUsed
  why: string
}

/** Constant-time compare of a computed digest against an expected one. */
function digestMatches(bytes: Buffer, algorithm: 'sha256' | 'md5', expected: Buffer): boolean {
  const actual = createHash(algorithm).update(bytes).digest()
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

/** Pull the `md5=` value out of a GCS `x-goog-hash` header, or `''`. */
export function md5FromGoogHash(header: string | null | undefined): string {
  if (typeof header !== 'string') return ''
  const match = /(?:^|[,\s])md5=([A-Za-z0-9+/]+={0,2})/.exec(header)
  return match ? match[1] : ''
}

/**
 * Are these the bytes we are willing to unpack?
 *
 * A pinned sha256 is the authority when supplied — it travels in this app's own
 * bytes. Otherwise the GCS-published md5 for the exact object is checked. With
 * neither there is nothing to verify against, and unverified bytes are refused,
 * never unpacked.
 */
export function verifyChecksum(
  bytes: Buffer,
  expected: { sha256?: string; md5?: string },
): ChecksumResult {
  const sha = expected.sha256?.trim() ?? ''
  if (sha !== '') {
    if (!/^[0-9a-f]{64}$/i.test(sha)) {
      return { ok: false, used: 'sha256', why: 'the pinned sha256 is not 64 hex characters' }
    }
    const ok = digestMatches(bytes, 'sha256', Buffer.from(sha.toLowerCase(), 'hex'))
    return {
      ok,
      used: 'sha256',
      why: ok ? '' : 'the download does not match the pinned sha256',
    }
  }

  const md5 = expected.md5?.trim() ?? ''
  if (md5 !== '') {
    let decoded: Buffer
    try {
      decoded = Buffer.from(md5, 'base64')
    } catch {
      return { ok: false, used: 'md5', why: 'the published md5 was not valid base64' }
    }
    if (decoded.length !== 16) {
      return { ok: false, used: 'md5', why: 'the published md5 was not 16 bytes' }
    }
    const ok = digestMatches(bytes, 'md5', decoded)
    return {
      ok,
      used: 'md5',
      why: ok ? '' : 'the download does not match the md5 the download server published for it',
    }
  }

  return {
    ok: false,
    used: 'none',
    why: 'the download carried no checksum to verify it against, so it was not unpacked',
  }
}

/* ------------------------------------------------------------- fetching -- */

export interface FetchedJson {
  ok: boolean
  json: unknown
  message: string
}

export interface FetchedZip {
  ok: boolean
  status: number
  bytes: Buffer
  /** The base64 md5 from `x-goog-hash`, or `''`. */
  md5: string
  message: string
}

export type FetchJson = (url: string) => Promise<FetchedJson>
export type FetchZip = (url: string, limit: number) => Promise<FetchedZip>

/** Read the versions index over https. Seam-injectable; the default uses `fetch`. */
export const httpsFetchJson: FetchJson = async (url) => {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(30_000) })
    if (!response.ok) {
      return { ok: false, json: null, message: `the versions index answered ${response.status}` }
    }
    return { ok: true, json: await response.json(), message: '' }
  } catch (error) {
    return {
      ok: false,
      json: null,
      message: error instanceof Error ? `the versions index could not be read: ${error.message}` : 'the versions index could not be read',
    }
  }
}

/**
 * Read a pinned zip over https, up to a hard byte ceiling, keeping the md5 the
 * store published for it.
 *
 * https-only on the URL this app holds, and the `x-goog-hash` header is read for
 * the object's md5 so {@link verifyChecksum} has something to check the bytes
 * against. The ceiling is applied to what actually arrived.
 */
export const httpsFetchZip: FetchZip = async (url, limit) => {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, status: 0, bytes: Buffer.alloc(0), md5: '', message: 'that is not a URL' }
  }
  if (parsed.protocol !== 'https:') {
    return { ok: false, status: 0, bytes: Buffer.alloc(0), md5: '', message: 'Chromium can only be fetched over https' }
  }
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(600_000) })
    if (!response.ok) {
      return { ok: false, status: response.status, bytes: Buffer.alloc(0), md5: '', message: `the download answered ${response.status}` }
    }
    const buffer = Buffer.from(await response.arrayBuffer())
    if (buffer.byteLength > limit) {
      return { ok: false, status: response.status, bytes: Buffer.alloc(0), md5: '', message: `the download is larger than ${limit} bytes` }
    }
    return { ok: true, status: response.status, bytes: buffer, md5: md5FromGoogHash(response.headers.get('x-goog-hash')), message: '' }
  } catch (error) {
    return {
      ok: false,
      status: 0,
      bytes: Buffer.alloc(0),
      md5: '',
      message: error instanceof Error ? `the download failed: ${error.message}` : 'the download failed',
    }
  }
}

/* ---------------------------------------------------------------- on disk -- */

interface InstallRecord {
  version: string
  platform: CftPlatform
  checksum: ChecksumUsed
  installedAt: number
}

const RECORD = 'installed.json'

function readRecord(dir: string): InstallRecord | null {
  try {
    const raw: unknown = JSON.parse(readFileSync(join(dir, RECORD), 'utf8'))
    if (typeof raw !== 'object' || raw === null) return null
    const value = raw as Record<string, unknown>
    if (typeof value.version !== 'string' || typeof value.platform !== 'string') return null
    return {
      version: value.version,
      platform: value.platform as CftPlatform,
      checksum: (value.checksum as ChecksumUsed) ?? 'none',
      installedAt: typeof value.installedAt === 'number' ? value.installedAt : 0,
    }
  } catch {
    return null
  }
}

/** Where installs live: `<userData>/chromium`, or an explicit root in a test. */
export function chromiumRoot(root?: string): string {
  return root ?? join(userDataDir(), 'chromium')
}

/* --------------------------------------------------------------- install -- */

export interface InstallOptions {
  /** The version to install. Defaults to {@link PINNED_CHROMIUM_VERSION}. */
  version?: string
  /** The platform key. Defaults to this host's, resolved by {@link cftPlatformFor}. */
  platform?: CftPlatform
  /** Base directory for installs. Defaults to `<userData>/chromium`. */
  root?: string
  /** The environment to read the override from. Defaults to `process.env`. */
  env?: NodeJS.ProcessEnv
  /**
   * A sha256 to verify the download against, overriding the app-owned default in
   * {@link PINNED_CHROMIUM_SHA256}. Left unset, the pinned build is verified
   * against that default and any other version falls back to the server md5.
   */
  pinnedSha256?: string
  fetchJson?: FetchJson
  fetchZip?: FetchZip
  now?: () => number
}

export type InstallResult =
  | {
      ok: true
      /** The resolved `chrome` executable. */
      path: string
      version: string
      platform: CftPlatform
      /** True when an already-verified copy was reused, not refetched. */
      reused: boolean
      /** True when {@link CHROMIUM_PATH_ENV} pointed at a side-loaded binary. */
      sideloaded: boolean
    }
  | { ok: false; why: string }

/**
 * Resolve, download, verify and unpack the pinned Chromium — or return a named
 * error saying exactly which step declined.
 *
 * Idempotent: a version already unpacked with a matching record and a present
 * executable is returned as-is, never refetched. Air-gapped: the env override is
 * honoured before anything touches the network. Nothing partial is ever left on
 * disk — a failed unpack tears its own directory down, the way the extension
 * store does, because a half-written browser is worse than none.
 */
export async function installChromium(options: InstallOptions = {}): Promise<InstallResult> {
  const env = options.env ?? process.env

  // 1. The air-gapped override wins over everything, before any network.
  const override = env[CHROMIUM_PATH_ENV]
  if (typeof override === 'string' && override.trim() !== '') {
    const path = override.trim()
    if (!existsSync(path)) {
      return {
        ok: false,
        why: `${CHROMIUM_PATH_ENV} points at ${path}, which does not exist`,
      }
    }
    return { ok: true, path, version: 'sideloaded', platform: 'linux64', reused: true, sideloaded: true }
  }

  // 2. Resolve version and platform.
  const version = options.version ?? PINNED_CHROMIUM_VERSION
  const platform =
    options.platform ?? cftPlatformFor(currentPlatform(), process.arch)
  if (platform === null) {
    return {
      ok: false,
      why: `chrome-for-testing publishes no build for ${currentPlatform()}/${process.arch}`,
    }
  }

  const installDir = join(chromiumRoot(options.root), version)
  const exePath = join(installDir, archiveTopDir(platform), chromeExecutableRel(platform))

  // 3. A verified copy already on disk is reused rather than refetched.
  const record = readRecord(installDir)
  if (record !== null && record.version === version && record.platform === platform && existsSync(exePath)) {
    return { ok: true, path: exePath, version, platform, reused: true, sideloaded: false }
  }

  // 4. Fetch the index and resolve the download URL.
  const fetchJson = options.fetchJson ?? httpsFetchJson
  const indexResult = await fetchJson(KNOWN_GOOD_VERSIONS_URL)
  if (!indexResult.ok) return { ok: false, why: indexResult.message }
  const resolved = resolveChromeDownload(indexResult.json, version, platform)
  if (!resolved.ok) return { ok: false, why: resolved.why }

  // 5. Download.
  const fetchZip = options.fetchZip ?? httpsFetchZip
  const got = await fetchZip(resolved.url, MAX_CHROMIUM_ZIP_BYTES)
  if (!got.ok) return { ok: false, why: got.message }

  // 6. Verify before a single byte is written. A caller's explicit pin wins;
  //    otherwise the app-owned digest for this build is the authority, and the
  //    server-published md5 is the fallback only when neither exists.
  const sha256 = options.pinnedSha256 ?? defaultPinnedSha256(version, platform)
  const checksum = verifyChecksum(got.bytes, { sha256, md5: got.md5 })
  if (!checksum.ok) return { ok: false, why: `Chromium ${version} was not installed: ${checksum.why}` }

  // 7. Unpack, with the shared, hardened unpacker (safe paths, no symlinks, ceilings).
  const opened = unzip(got.bytes, {
    maxTotalBytes: MAX_CHROMIUM_UNPACKED_BYTES,
    maxFiles: MAX_CHROMIUM_FILES,
  })
  if (!opened.ok) return { ok: false, why: `Chromium ${version} was not installed: ${opened.why}` }

  // 8. Write it out fresh. A reinstall replaces rather than merges.
  try {
    rmSync(installDir, { recursive: true, force: true })
    mkdirSync(installDir, { recursive: true })
    for (const file of opened.files) {
      const target = join(installDir, file.path)
      mkdirSync(dirname(target), { recursive: true })
      writeFileSync(target, file.bytes)
    }

    // The exec bit `unzip` drops has to be put back on the binaries that run.
    if (!existsSync(exePath)) {
      return {
        ok: false,
        why: `Chromium ${version} was not installed: the archive had no ${chromeExecutableRel(platform)} in it`,
      }
    }
    chmodSync(exePath, 0o755)
    const binDir = join(installDir, archiveTopDir(platform))
    for (const helper of EXECUTABLE_HELPERS) {
      const helperPath = join(binDir, helper)
      if (existsSync(helperPath) && statSync(helperPath).isFile()) chmodSync(helperPath, 0o755)
    }

    const now = options.now ?? Date.now
    const written: InstallRecord = { version, platform, checksum: checksum.used, installedAt: now() }
    writeFileSync(join(installDir, RECORD), JSON.stringify(written))
  } catch (error) {
    // A half-written browser has an executable and missing libraries: it looks
    // installed and dies on launch. Torn down rather than left, exactly as the
    // extension store tears down a half-written extension.
    try {
      rmSync(installDir, { recursive: true, force: true })
    } catch {
      /* Nothing better to do; the message below says it did not install. */
    }
    return {
      ok: false,
      why: `Chromium ${version} was not installed: ${error instanceof Error ? error.message : 'it could not be saved'}`,
    }
  }

  return { ok: true, path: exePath, version, platform, reused: false, sideloaded: false }
}
