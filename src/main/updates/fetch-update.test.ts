import { execFile } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { existsSync, lstatSync, readdirSync, statSync } from 'node:fs'
import { chmod, mkdir, readFile, rm, symlink, truncate, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import {
  chooseArchive,
  decodeSha512,
  extractDir,
  fetchUpdate,
  inspectBundle,
  MAX_FEED_BYTES,
  parseFeed,
  plutilReadPlist,
  resolveAsset,
  stagedBundlePath,
  stagingDir,
  updatesRoot,
  verifyArchive,
  type FeedFile,
  type FetchLike,
  type FetchProgress,
  type HttpResponse,
} from './fetch-update'

const run = promisify(execFile)

/**
 * These tests are about the one promise this module makes: what it hands back
 * is the release the feed described, or it is nothing.
 *
 * So they are deliberately not built on a mocked filesystem or a fake
 * unarchiver. A real `.app` is assembled in a temp directory, zipped with the
 * real `ditto`, hashed with the real `createHash`, and served to `fetchUpdate`
 * by a fake `fetch` that streams those exact bytes. Only the network is
 * pretended. That is what makes "the checksum caught it" and "the extraction
 * produced a bundle" mean something — a stubbed extractor would have proved
 * that the code calls a function, which was never in doubt.
 *
 * The fixture is shaped like the real artifact rather than like the easiest
 * thing to build: `ditto -c -k --keepParent`, which is what the published
 * `terminaldeck-0.1.0-arm64.zip` looks like on inspection — no `__MACOSX`
 * entries, symlinks stored with their Unix mode bits. It carries a symlink and
 * an executable so that "the extraction lost its permissions" is a failure
 * these tests could actually observe.
 *
 * Everything lives under one temp directory, keyed by pid so parallel runs
 * cannot collide, and it is removed at the end.
 */

/**
 * Everything below the pure parsers needs a real `.app` and a real archive, and
 * both are built with `/usr/bin/ditto` — Apple's own archiver, which is the
 * point of the module rather than an implementation detail of the fixture (see
 * its header). There is no Windows stand-in worth substituting: the thing under
 * test is a macOS bundle, and `fetchUpdate` refuses every platform but darwin
 * before it opens a socket.
 *
 * So the fixture build and its dependants are gated on darwin. Without the
 * gate, `spawn('/usr/bin/ditto')` fails ENOENT in `beforeAll` on Windows and
 * takes the whole file down with it — including the parser tests, which are
 * plain string work and run anywhere.
 */
const MAC = process.platform === 'darwin'

/* -------------------------------------------------------------- fixtures -- */

const ROOT = join(tmpdir(), `terminaldeck-fetch-update-${process.pid}`)
const FIXTURES = join(ROOT, 'fixtures')
const USER_DATA = join(ROOT, 'userData')

const FEED_URL = 'https://github.com/asadev/terminaldeck/releases/latest/download/latest-mac.yml'
const APP_VERSION = '9.9.9'
const APP_NAME = 'Fake App.app'
const ARCHIVE_NAME = 'terminaldeck-9.9.9-arm64.zip'

/** The real release feed, byte-for-byte as it is published. */
const REAL_FEED = [
  'version: 0.1.0',
  'files:',
  '  - url: terminaldeck-0.1.0-arm64.zip',
  '    sha512: HyckKuCltIQ1t6OkRtigLH/TQu4FjnfjIKMh6TVE1t+bu3PY+4gBskBRgW958alTu/wMSwurn63PfSlYRVuqfQ==',
  '    size: 119570501',
  '  - url: terminaldeck-0.1.0-arm64.dmg',
  '    sha512: ayaOfBoiNxQcqJr0P9HgJ+vfCQB+45GlT78R8R30TY56lWrZUh6qnn7M4JhIanI5I15PDVEsIWFtKijLIUt72w==',
  '    size: 119552577',
  'path: terminaldeck-0.1.0-arm64.zip',
  'sha512: HyckKuCltIQ1t6OkRtigLH/TQu4FjnfjIKMh6TVE1t+bu3PY+4gBskBRgW958alTu/wMSwurn63PfSlYRVuqfQ==',
  "releaseDate: '2026-08-13T09:26:05.671Z'",
  '',
].join('\n')

const ZIP_SHA512 = 'HyckKuCltIQ1t6OkRtigLH/TQu4FjnfjIKMh6TVE1t+bu3PY+4gBskBRgW958alTu/wMSwurn63PfSlYRVuqfQ=='
const DMG_SHA512 = 'ayaOfBoiNxQcqJr0P9HgJ+vfCQB+45GlT78R8R30TY56lWrZUh6qnn7M4JhIanI5I15PDVEsIWFtKijLIUt72w=='

/** A real app zip, and a real zip that is not an app. */
let appZip: Buffer
let notAppZip: Buffer

function plist(version: string, executable: string): string {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ' +
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '  <key>CFBundleExecutable</key>',
    `  <string>${executable}</string>`,
    '  <key>CFBundleShortVersionString</key>',
    `  <string>${version}</string>`,
    '</dict>',
    '</plist>',
    '',
  ].join('\n')
}

/** Assemble `<name>.app` under `parent` and return its path. */
async function buildApp(parent: string, version: string): Promise<string> {
  const app = join(parent, APP_NAME)
  await mkdir(join(app, 'Contents', 'MacOS'), { recursive: true })
  await mkdir(join(app, 'Contents', 'Resources'), { recursive: true })
  await writeFile(join(app, 'Contents', 'Info.plist'), plist(version, 'Fake App'))
  await writeFile(join(app, 'Contents', 'MacOS', 'Fake App'), '#!/bin/sh\nexit 0\n')
  await chmod(join(app, 'Contents', 'MacOS', 'Fake App'), 0o755)
  // Incompressible padding, so the archive is big enough for the progress
  // stream to have a shape rather than being one chunk.
  await writeFile(join(app, 'Contents', 'Resources', 'blob.bin'), randomBytes(256 * 1024))
  // The thing a careless unarchiver flattens. Frameworks inside a real Electron
  // bundle are held together by exactly this.
  await symlink('Contents/MacOS/Fake App', join(app, 'link-to-binary'))
  return app
}

async function zipDirectory(parent: string, name: string, destination: string): Promise<Buffer> {
  await rm(destination, { force: true })
  await run('/usr/bin/ditto', ['-c', '-k', '--keepParent', '--', name, destination], { cwd: parent })
  return readFile(destination)
}

beforeAll(async () => {
  if (!MAC) return
  await rm(ROOT, { recursive: true, force: true })
  await mkdir(FIXTURES, { recursive: true })

  const source = join(FIXTURES, 'src')
  await mkdir(source, { recursive: true })
  await buildApp(source, APP_VERSION)
  appZip = await zipDirectory(source, APP_NAME, join(FIXTURES, 'app.zip'))

  const plain = join(FIXTURES, 'plain')
  await mkdir(join(plain, 'notes'), { recursive: true })
  await writeFile(join(plain, 'notes', 'readme.txt'), 'this is not an application\n')
  notAppZip = await zipDirectory(plain, 'notes', join(FIXTURES, 'notes.zip'))
}, 60_000)

afterAll(async () => {
  await rm(ROOT, { recursive: true, force: true })
})

beforeEach(async () => {
  if (!MAC) return
  // Each test starts from an empty userData so "already staged" is only ever
  // true because the test under way put it there.
  await rm(USER_DATA, { recursive: true, force: true })
  await mkdir(USER_DATA, { recursive: true })
})

/* ------------------------------------------------------------ the network -- */

function base64Sha512(bytes: Buffer): string {
  return createHash('sha512').update(bytes).digest('base64')
}

function feedFor(
  version: string,
  fileName: string,
  bytes: Buffer,
  overrides: Partial<FeedFile> = {},
): string {
  const sha512 = overrides.sha512 ?? base64Sha512(bytes)
  const size = overrides.size ?? bytes.length
  return [
    `version: ${version}`,
    'files:',
    `  - url: ${overrides.url ?? fileName}`,
    `    sha512: ${sha512}`,
    `    size: ${size}`,
    `  - url: ${fileName.replace(/\.zip$/, '.dmg')}`,
    '    sha512: ayaOfBoiNxQcqJr0P9HgJ+vfCQB+45GlT78R8R30TY56lWrZUh6qnn7M4JhIanI5I15PDVEsIWFtKijLIUt72w==',
    `    size: ${size + 1}`,
    `path: ${fileName}`,
    `sha512: ${sha512}`,
    "releaseDate: '2026-08-13T09:26:05.671Z'",
    '',
  ].join('\n')
}

function streamOf(
  bytes: Buffer,
  chunkSize: number,
  onOpen: () => void = () => {},
  delayMs = 0,
): ReadableStream<Uint8Array> {
  let offset = 0
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (offset >= bytes.length) {
        controller.close()
        return
      }
      if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs))
      const end = Math.min(offset + chunkSize, bytes.length)
      controller.enqueue(new Uint8Array(bytes.subarray(offset, end)))
      offset = end
    },
  })
  const getReader = stream.getReader.bind(stream)
  Object.defineProperty(stream, 'getReader', {
    value: () => {
      onOpen()
      return getReader()
    },
  })
  return stream
}

interface Route {
  status?: number
  bytes: Buffer
  headers?: Record<string, string>
  chunkSize?: number
  /** Milliseconds per chunk, for the tests that need two runs to overlap. */
  delayMs?: number
}

interface FakeNetwork {
  fetch: FetchLike
  /** How many times each URL was requested. */
  calls: Map<string, number>
  countFor(url: string): number
  /**
   * How many times the module attached a reader to each URL's body.
   *
   * The difference between "refused it" and "downloaded it and then threw it
   * away" is invisible in the staging directory — both leave it empty — and it
   * is the whole claim of the content-length early-out. `getReader` is the
   * moment the module commits to reading a body, so it is the honest place to
   * count; the stream pulls a chunk on its own the moment it is constructed,
   * which says nothing about whether anyone asked for it.
   */
  bodyOpenedFor(url: string): number
}

/**
 * A `fetch` that serves fixed bytes and counts requests.
 *
 * `content-length` is sent by default because that is what GitHub's asset host
 * does, and the module has an early-out that depends on it. A route can drop it
 * to exercise the path where the only length anyone knows is the feed's.
 */
function network(routes: Record<string, Route>): FakeNetwork {
  const calls = new Map<string, number>()
  const bodyOpens = new Map<string, number>()
  const fetch: FetchLike = async (url, init) => {
    calls.set(url, (calls.get(url) ?? 0) + 1)
    if (init?.signal?.aborted) throw new Error('aborted')

    const route = routes[url]
    if (!route) {
      const missing: HttpResponse = {
        ok: false,
        status: 404,
        headers: { get: () => null },
        body: null,
      }
      return missing
    }
    const headers: Record<string, string> = {
      'content-length': String(route.bytes.length),
      ...route.headers,
    }
    const status = route.status ?? 200
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (name) => headers[name.toLowerCase()] ?? null },
      body: streamOf(
        route.bytes,
        route.chunkSize ?? 8 * 1024,
        () => bodyOpens.set(url, (bodyOpens.get(url) ?? 0) + 1),
        route.delayMs ?? 0,
      ),
    }
  }
  return {
    fetch,
    calls,
    countFor: (url) => calls.get(url) ?? 0,
    bodyOpenedFor: (url) => bodyOpens.get(url) ?? 0,
  }
}

function assetUrl(fileName: string): string {
  return `https://github.com/asadev/terminaldeck/releases/latest/download/${fileName}`
}

/** The standard case: a feed and the app zip it describes. */
function goodNetwork(overrides: Partial<FeedFile> = {}, route: Partial<Route> = {}): FakeNetwork {
  return network({
    [FEED_URL]: { bytes: Buffer.from(feedFor(APP_VERSION, ARCHIVE_NAME, appZip, overrides)) },
    [assetUrl(ARCHIVE_NAME)]: { bytes: appZip, ...route },
  })
}

function options(net: FakeNetwork, extra: Record<string, unknown> = {}): Parameters<typeof fetchUpdate>[0] {
  return {
    feedUrl: FEED_URL,
    userDataPath: USER_DATA,
    platform: 'darwin',
    fetch: net.fetch,
    progressIntervalMs: 0,
    ...extra,
  }
}

/** What is sitting in the staging directory for a version, sorted. */
function stagedNames(version: string): string[] {
  const dir = stagingDir(version, USER_DATA)
  return existsSync(dir) ? readdirSync(dir).sort() : []
}

/* ---------------------------------------------------------- reading feeds -- */

describe('parseFeed', () => {
  /**
   * The trap this module was written around: `path:` and `sha512:` sit at
   * column 0 *after* the files list, and a parser that keeps appending keys to
   * the open entry gives the dmg the zip's hash. That failure is invisible —
   * the feed parses, the download runs, and only the checksum at the end says
   * anything, blaming the network for a parser bug.
   */
  it('reads the real published feed and does not let the trailing keys leak into the list', () => {
    const feed = parseFeed(REAL_FEED)
    expect(feed).not.toBeNull()
    expect(feed?.version).toBe('0.1.0')
    expect(feed?.files).toHaveLength(2)
    expect(feed?.files[0]).toEqual({
      url: 'terminaldeck-0.1.0-arm64.zip',
      sha512: ZIP_SHA512,
      size: 119570501,
    })
    // The dmg keeps its own hash. This is the assertion that fails when the
    // dedent is not handled.
    expect(feed?.files[1].sha512).toBe(DMG_SHA512)
    expect(feed?.files[1].size).toBe(119552577)
  })

  it('survives CRLF line endings and quoted values', () => {
    const feed = parseFeed(REAL_FEED.replace(/\n/g, '\r\n'))
    expect(feed?.version).toBe('0.1.0')
    expect(feed?.files[0].sha512).toBe(ZIP_SHA512)
  })

  it('keeps the base64 intact even though it contains slashes, plus signs and padding', () => {
    const feed = parseFeed(REAL_FEED)
    expect(feed?.files[0].sha512).toContain('/')
    expect(feed?.files[0].sha512).toContain('+')
    expect(feed?.files[0].sha512.endsWith('==')).toBe(true)
    expect(decodeSha512(feed?.files[0].sha512 ?? '')).toHaveLength(64)
  })

  it('drops an entry that is missing a size, because it could not be length-checked', () => {
    const feed = parseFeed(['version: 1.0.0', 'files:', '  - url: a.zip', '    sha512: abc'].join('\n'))
    expect(feed?.files).toEqual([])
  })

  it('refuses a version that would escape the staging directory', () => {
    expect(parseFeed('version: ../../etc\nfiles:\n')).toBeNull()
    expect(parseFeed('version: ..\nfiles:\n')).toBeNull()
    expect(parseFeed('files:\n  - url: a.zip\n')).toBeNull()
  })
})

describe('chooseArchive', () => {
  it('picks the zip and never the dmg', () => {
    const feed = parseFeed(REAL_FEED)
    expect(feed).not.toBeNull()
    expect(chooseArchive(feed!)?.url).toBe('terminaldeck-0.1.0-arm64.zip')
  })

  it('reports nothing rather than falling back to the dmg', () => {
    expect(chooseArchive({ version: '1.0.0', files: [{ url: 'x.dmg', sha512: 'a', size: 1 }] })).toBeNull()
  })
})

describe('resolveAsset', () => {
  const zip: FeedFile = { url: 'terminaldeck-0.1.0-arm64.zip', sha512: ZIP_SHA512, size: 1 }

  it('resolves a bare filename against the feed it came from', () => {
    expect(resolveAsset(zip, FEED_URL)).toEqual({
      url: 'https://github.com/asadev/terminaldeck/releases/latest/download/terminaldeck-0.1.0-arm64.zip',
      fileName: 'terminaldeck-0.1.0-arm64.zip',
    })
  })

  it('decodes an escaped filename, because artifact names may contain spaces', () => {
    expect(resolveAsset({ ...zip, url: 'Terminal%20Deck-0.1.0.zip' }, FEED_URL)?.fileName).toBe(
      'Terminal Deck-0.1.0.zip',
    )
  })

  it('refuses anything that is not https', () => {
    expect(resolveAsset({ ...zip, url: 'http://example.com/a.zip' }, FEED_URL)).toBeNull()
    expect(resolveAsset({ ...zip, url: 'file:///tmp/a.zip' }, FEED_URL)).toBeNull()
  })

  /**
   * A feed body that could name any host would mean the bytes replacing the
   * user's application come from wherever that text says, with the digest that
   * proves them written in the same document. The asset has to live where the
   * feed lives.
   */
  it('refuses an asset that does not live where the feed lives', () => {
    expect(resolveAsset({ ...zip, url: 'https://evil.example.com/a.zip' }, FEED_URL)).toBeNull()
    // Same host, different port and different scheme-host pair are both origins.
    expect(resolveAsset({ ...zip, url: 'https://github.com:8443/a.zip' }, FEED_URL)).toBeNull()
    // A path elsewhere on the same origin is still fine: only the origin is
    // pinned, and release layouts move.
    expect(resolveAsset({ ...zip, url: '/asadev/terminaldeck/releases/x/a.zip' }, FEED_URL)?.url).toBe(
      'https://github.com/asadev/terminaldeck/releases/x/a.zip',
    )
  })

  it('refuses a name that is not a plain zip filename', () => {
    expect(resolveAsset({ ...zip, url: 'a.dmg' }, FEED_URL)).toBeNull()
    expect(resolveAsset({ ...zip, url: '%2E%2E%2Fescape.zip' }, FEED_URL)).toBeNull()
  })
})

/* ------------------------------------------------------------- the digest -- */

describe('decodeSha512', () => {
  it('accepts the feed encoding and rejects everything shaped like a near miss', () => {
    expect(decodeSha512(ZIP_SHA512)).toHaveLength(64)
    // Hex, which is what you get from `shasum` and is the wrong encoding here.
    expect(decodeSha512(createHash('sha512').update('x').digest('hex'))).toBeNull()
    expect(decodeSha512('')).toBeNull()
    expect(decodeSha512('not base64!')).toBeNull()
    // Correct alphabet, wrong digest length.
    expect(decodeSha512(createHash('sha256').update('x').digest('base64'))).toBeNull()
  })
})

describe.skipIf(!MAC)('verifyArchive', () => {
  it('names the length when the length is wrong, and the digest when only the digest is', async () => {
    const path = join(FIXTURES, 'verify.bin')
    await writeFile(path, appZip)

    const short = await verifyArchive(path, {
      url: 'a.zip',
      sha512: base64Sha512(appZip),
      size: appZip.length + 10,
    })
    expect(short).toMatchObject({ ok: false, reason: 'size-mismatch' })

    const wrongHash = await verifyArchive(path, {
      url: 'a.zip',
      sha512: base64Sha512(Buffer.from('different bytes')),
      size: appZip.length,
    })
    expect(wrongHash).toMatchObject({ ok: false, reason: 'checksum-mismatch' })

    expect(
      await verifyArchive(path, { url: 'a.zip', sha512: base64Sha512(appZip), size: appZip.length }),
    ).toEqual({ ok: true })
  })
})

/* ---------------------------------------------------------------- bundles -- */

describe.skipIf(!MAC)('inspectBundle', () => {
  it('accepts a real bundle and reads its executable and version', async () => {
    const dir = join(FIXTURES, 'inspect-ok')
    await rm(dir, { recursive: true, force: true })
    await mkdir(dir, { recursive: true })
    await buildApp(dir, APP_VERSION)

    const verdict = await inspectBundle(dir)
    expect(verdict.ok).toBe(true)
    if (!verdict.ok) return
    expect(verdict.bundle.executableName).toBe('Fake App')
    expect(verdict.bundle.version).toBe(APP_VERSION)
  })

  it('refuses a bundle whose binary lost its executable bit', async () => {
    const dir = join(FIXTURES, 'inspect-mode')
    await rm(dir, { recursive: true, force: true })
    await mkdir(dir, { recursive: true })
    const app = await buildApp(dir, APP_VERSION)
    await chmod(join(app, 'Contents', 'MacOS', 'Fake App'), 0o644)

    const verdict = await inspectBundle(dir)
    expect(verdict).toMatchObject({ ok: false })
    if (verdict.ok) return
    expect(verdict.message).toMatch(/not executable/)
  })

  it('refuses an Info.plist that points outside the bundle', async () => {
    const dir = join(FIXTURES, 'inspect-escape')
    await rm(dir, { recursive: true, force: true })
    await mkdir(dir, { recursive: true })
    const app = await buildApp(dir, APP_VERSION)
    await writeFile(join(app, 'Contents', 'Info.plist'), plist(APP_VERSION, '../../../../bin/sh'))

    const verdict = await inspectBundle(dir)
    expect(verdict).toMatchObject({ ok: false })
    if (verdict.ok) return
    expect(verdict.message).toMatch(/outside its own bundle/)
  })
})

/* ------------------------------------------------------------- fetchUpdate -- */

describe.skipIf(!MAC)('fetchUpdate', () => {
  it('downloads, verifies and unpacks a real archive into a real bundle', async () => {
    const net = goodNetwork()
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: true, version: APP_VERSION, reused: false })
    if (!result.ok) return

    expect(result.bundlePath).toBe(join(extractDir(APP_VERSION, USER_DATA), APP_NAME))
    expect(result.sizeBytes).toBe(appZip.length)
    expect(existsSync(result.archivePath)).toBe(true)

    // The archive on disk is the archive the feed described, checked here
    // independently of the code that put it there.
    expect(base64Sha512(await readFile(result.archivePath))).toBe(base64Sha512(appZip))

    // ditto's job, asserted rather than assumed: the binary is still executable
    // and the symlink is still a symlink.
    const binary = statSync(join(result.bundlePath, 'Contents', 'MacOS', 'Fake App'))
    expect(binary.mode & 0o111).not.toBe(0)
    expect(lstatSync(join(result.bundlePath, 'link-to-binary')).isSymbolicLink()).toBe(true)

    // Nothing half-finished is left lying around.
    expect(stagedNames(APP_VERSION)).toEqual(['bundle', ARCHIVE_NAME])
  }, 30_000)

  it('rejects a hash mismatch and removes the file', async () => {
    // The right length, a plausible-looking digest, the wrong bytes. Length
    // alone would wave this through, which is the whole reason the digest runs.
    const net = goodNetwork({ sha512: base64Sha512(Buffer.concat([appZip, Buffer.from('!')])) })
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: false, reason: 'checksum-mismatch' })
    if (result.ok) return
    expect(result.message).toMatch(/sha512/)

    // Neither the finished name nor the part file survives, so a later run
    // cannot mistake any of it for a completed download.
    expect(stagedNames(APP_VERSION)).toEqual([])
    expect(existsSync(join(stagingDir(APP_VERSION, USER_DATA), `${ARCHIVE_NAME}.part`))).toBe(false)
  }, 30_000)

  it('rejects a truncated download and removes the file', async () => {
    // No content-length, so the shortfall can only be caught after the fact —
    // the case a server that hangs up mid-body actually produces.
    const truncated = appZip.subarray(0, appZip.length - 4096)
    const net = network({
      [FEED_URL]: { bytes: Buffer.from(feedFor(APP_VERSION, ARCHIVE_NAME, appZip)) },
      [assetUrl(ARCHIVE_NAME)]: { bytes: truncated, headers: { 'content-length': '' } },
    })
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: false, reason: 'size-mismatch' })
    if (result.ok) return
    expect(result.message).toContain(String(truncated.length))
    expect(result.message).toContain(String(appZip.length))
    expect(stagedNames(APP_VERSION)).toEqual([])
  }, 30_000)

  it('refuses before downloading when the server disagrees with the feed about the size', async () => {
    const net = goodNetwork({}, { headers: { 'content-length': '123' } })
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: false, reason: 'size-mismatch' })
    expect(stagedNames(APP_VERSION)).toEqual([])
    // "Nothing was downloaded" is a claim about the body, and an empty staging
    // directory does not make it: a run that streamed the whole thing and then
    // deleted it leaves exactly the same directory. The body was never opened.
    expect(net.bodyOpenedFor(assetUrl(ARCHIVE_NAME))).toBe(0)
    if (result.ok) return
    expect(result.message).toContain('Nothing was downloaded')
  })

  it('rejects an archive that is not an app bundle', async () => {
    const net = network({
      [FEED_URL]: { bytes: Buffer.from(feedFor(APP_VERSION, ARCHIVE_NAME, notAppZip)) },
      [assetUrl(ARCHIVE_NAME)]: { bytes: notAppZip },
    })
    const result = await fetchUpdate(options(net))

    // The bytes were exactly what the feed promised — the checksum passed. It is
    // the structural check that refuses this, which is the point: a verified
    // download of the wrong thing is still the wrong thing.
    expect(result).toMatchObject({ ok: false, reason: 'not-a-bundle' })
    if (result.ok) return
    expect(result.message).toMatch(/no \.app bundle/)
    expect(existsSync(extractDir(APP_VERSION, USER_DATA))).toBe(false)
  }, 30_000)

  it('rejects a bundle whose Info.plist disagrees with the version the feed promised', async () => {
    const net = network({
      // The feed claims 1.2.3; the bundle inside says 9.9.9.
      [FEED_URL]: { bytes: Buffer.from(feedFor('1.2.3', ARCHIVE_NAME, appZip)) },
      [assetUrl(ARCHIVE_NAME)]: { bytes: appZip },
    })
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: false, reason: 'version-mismatch' })
    if (result.ok) return
    expect(result.message).toContain('1.2.3')
    expect(result.message).toContain(APP_VERSION)
  }, 30_000)

  it('reports progress that only ever moves forward and never passes 100', async () => {
    const seen: FetchProgress[] = []
    const net = goodNetwork({}, { chunkSize: 4096 })
    const result = await fetchUpdate(
      options(net, { onProgress: (p: FetchProgress) => seen.push(p) }),
    )

    expect(result.ok).toBe(true)
    expect(seen.length).toBeGreaterThan(1)

    for (let i = 1; i < seen.length; i += 1) {
      expect(seen[i].transferred).toBeGreaterThanOrEqual(seen[i - 1].transferred)
      expect(seen[i].percent).toBeGreaterThanOrEqual(seen[i - 1].percent)
    }
    for (const tick of seen) {
      expect(tick.percent).toBeGreaterThanOrEqual(0)
      expect(tick.percent).toBeLessThanOrEqual(100)
      expect(tick.total).toBe(appZip.length)
      expect(tick.version).toBe(APP_VERSION)
      expect(Number.isInteger(tick.percent)).toBe(true)
    }

    // The bar has to arrive. A throttle that eats the last tick leaves it short
    // of the end next to a finished download.
    expect(seen[seen.length - 1].percent).toBe(100)
    expect(seen[seen.length - 1].transferred).toBe(appZip.length)
  }, 30_000)

  it('stays at or below 100 when the server sends more than the feed declared', async () => {
    const seen: FetchProgress[] = []
    const longer = Buffer.concat([appZip, randomBytes(50_000)])
    const net = network({
      // The feed describes the real archive; the server sends a longer body.
      [FEED_URL]: { bytes: Buffer.from(feedFor(APP_VERSION, ARCHIVE_NAME, appZip)) },
      [assetUrl(ARCHIVE_NAME)]: { bytes: longer, headers: { 'content-length': '' }, chunkSize: 4096 },
    })
    const result = await fetchUpdate(
      options(net, { onProgress: (p: FetchProgress) => seen.push(p) }),
    )

    expect(result).toMatchObject({ ok: false, reason: 'size-mismatch' })
    expect(Math.max(...seen.map((tick) => tick.percent))).toBe(100)
  }, 30_000)

  it('throttles progress rather than emitting one event per chunk', async () => {
    const seen: FetchProgress[] = []
    let clock = 0
    const net = goodNetwork({}, { chunkSize: 1024 })
    // A clock that never advances: every tick after the first is inside the
    // interval, so only the unconditional final one may get through.
    await fetchUpdate(
      options(net, {
        onProgress: (p: FetchProgress) => seen.push(p),
        progressIntervalMs: 250,
        now: () => clock,
      }),
    )

    expect(appZip.length / 1024).toBeGreaterThan(100)
    expect(seen.length).toBeLessThanOrEqual(2)
    expect(seen[seen.length - 1].percent).toBe(100)
    expect(clock).toBe(0)
  }, 30_000)

  it('does not download a version that is already staged and still verifies', async () => {
    const net = goodNetwork()
    const first = await fetchUpdate(options(net))
    expect(first).toMatchObject({ ok: true, reused: false })
    expect(net.countFor(assetUrl(ARCHIVE_NAME))).toBe(1)

    const second = await fetchUpdate(options(net))
    expect(second).toMatchObject({ ok: true, reused: true })
    if (!second.ok || !first.ok) return
    expect(second.bundlePath).toBe(first.bundlePath)

    // The feed is still read — that is how the version is known at all — but
    // the 119 MB is not fetched twice.
    expect(net.countFor(assetUrl(ARCHIVE_NAME))).toBe(1)
    expect(net.countFor(FEED_URL)).toBe(2)
  }, 60_000)

  it('re-downloads when the staged archive no longer verifies', async () => {
    const net = goodNetwork()
    const first = await fetchUpdate(options(net))
    expect(first.ok).toBe(true)
    if (!first.ok) return

    // Something ate four kilobytes off the end. "It is present" is not the
    // question the reuse path asks.
    await truncate(first.archivePath, appZip.length - 4096)

    const second = await fetchUpdate(options(net))
    expect(second).toMatchObject({ ok: true, reused: false })
    expect(net.countFor(assetUrl(ARCHIVE_NAME))).toBe(2)
  }, 60_000)

  it('re-extracts without re-downloading when the archive verifies but the bundle is gone', async () => {
    const net = goodNetwork()
    expect((await fetchUpdate(options(net))).ok).toBe(true)
    await rm(extractDir(APP_VERSION, USER_DATA), { recursive: true, force: true })

    const second = await fetchUpdate(options(net))
    expect(second).toMatchObject({ ok: true, reused: true })
    expect(net.countFor(assetUrl(ARCHIVE_NAME))).toBe(1)
    if (!second.ok) return
    expect(existsSync(second.bundlePath)).toBe(true)
  }, 60_000)

  /**
   * The state a crash partway through `ditto` leaves: a tree that inspects as a
   * bundle at the right version, with files still missing from it. Nothing about
   * its shape says where it came from, and `stagedBundlePath` hands it to the
   * installer, which moves it over the user's application and then deletes the
   * backup. So "some bundle at this version is sitting there" must not be enough
   * to reuse it.
   */
  it('will not reuse an extracted tree that did not come out of the verified archive', async () => {
    const net = goodNetwork()
    expect((await fetchUpdate(options(net))).ok).toBe(true)

    // Swap the real extraction for a hand-made bundle at the same version. Every
    // structural check passes on it; it simply is not what was downloaded.
    const bundleDir = extractDir(APP_VERSION, USER_DATA)
    await rm(bundleDir, { recursive: true, force: true })
    await mkdir(bundleDir, { recursive: true })
    const imposter = await buildApp(bundleDir, APP_VERSION)
    await writeFile(join(imposter, 'IMPOSTER'), 'never came out of the archive')

    // While it is there, the installer's handoff must refuse to name it.
    expect(await stagedBundlePath(APP_VERSION, USER_DATA)).toBeNull()

    const second = await fetchUpdate(options(net))
    expect(second).toMatchObject({ ok: true, reused: true })
    // Unpacked again from the archive that was verified, so the planted file is
    // gone rather than installed.
    expect(existsSync(join(imposter, 'IMPOSTER'))).toBe(false)
    expect(existsSync(join(bundleDir, APP_NAME, 'Contents', 'Resources', 'blob.bin'))).toBe(true)
    expect(await stagedBundlePath(APP_VERSION, USER_DATA)).toBe(join(bundleDir, APP_NAME))
    // And still no second download: the archive was intact the whole time.
    expect(net.countFor(assetUrl(ARCHIVE_NAME))).toBe(1)
  }, 60_000)

  /**
   * The marker's whole value is that it is written last.
   *
   * If it were written when the extraction returned rather than when the bundle
   * had been checked, a process killed in between would leave a tree vouching
   * for itself before anything had looked at it — which is the exact state the
   * marker exists to make impossible. Failure paths delete the tree either way,
   * so no assertion about the end state can tell the two orders apart. The
   * inspection itself has to be asked what it could see while it ran.
   */
  it('does not vouch for an extraction until after the bundle has been checked', async () => {
    const markerPath = join(extractDir(APP_VERSION, USER_DATA), '.verified-sha512')
    const seenDuringInspection: boolean[] = []
    const net = goodNetwork()
    const result = await fetchUpdate(
      options(net, {
        readPlist: async (path: string) => {
          seenDuringInspection.push(existsSync(markerPath))
          return plutilReadPlist(path)
        },
      }),
    )

    expect(result).toMatchObject({ ok: true })
    expect(seenDuringInspection.length).toBeGreaterThan(0)
    expect(seenDuringInspection).not.toContain(true)
    // And it is there once everything has held.
    expect(existsSync(markerPath)).toBe(true)
  }, 30_000)

  /**
   * Same version number, different bytes. Not hypothetical — `release/` was
   * rebuilt on 2026-08-13 and stopped matching the published 0.1.0 — and the
   * version string is the only thing the staging layout keys on.
   */
  it('replaces a staged tree when the release is re-cut under the same version', async () => {
    const net = goodNetwork()
    const first = await fetchUpdate(options(net))
    expect(first.ok).toBe(true)
    if (!first.ok) return
    expect(existsSync(join(first.bundlePath, 'Contents', 'Resources', 'blob.bin'))).toBe(true)

    // A different archive, same version: a second app with a file the first one
    // does not have, published over the top.
    const source = join(FIXTURES, 'recut')
    await rm(source, { recursive: true, force: true })
    await mkdir(source, { recursive: true })
    const rebuilt = await buildApp(source, APP_VERSION)
    await writeFile(join(rebuilt, 'Contents', 'Resources', 'RECUT'), 'the second cut')
    const recutZip = await zipDirectory(source, APP_NAME, join(FIXTURES, 'recut.zip'))

    // The old archive is gone — a tidy-up, a disk cleaner, a user reclaiming
    // 119 MB — and only the unpacked tree is left. Without it there is nothing
    // to re-verify, so the tree is the only thing standing between the download
    // and the caller, and "some bundle at 9.9.9 is already here" is exactly the
    // wrong answer.
    await rm(first.archivePath, { force: true })

    const after = network({
      [FEED_URL]: { bytes: Buffer.from(feedFor(APP_VERSION, ARCHIVE_NAME, recutZip)) },
      [assetUrl(ARCHIVE_NAME)]: { bytes: recutZip },
    })
    const second = await fetchUpdate(options(after))
    expect(second).toMatchObject({ ok: true, reused: false })
    if (!second.ok) return

    // The tree is the new one, not the one that happened to be there already.
    expect(existsSync(join(second.bundlePath, 'Contents', 'Resources', 'RECUT'))).toBe(true)
    expect(base64Sha512(await readFile(second.archivePath))).toBe(base64Sha512(recutZip))
  }, 60_000)

  /**
   * The button people press twice. Both runs used to write into one `.part`
   * path, and the second one's opening unlink took the file the first was still
   * filling, so a perfectly good update failed on a path that had stopped
   * existing.
   */
  it('serialises overlapping calls instead of racing them over one part file', async () => {
    const net = goodNetwork({}, { chunkSize: 4096, delayMs: 1 })
    const [first, second] = await Promise.all([
      fetchUpdate(options(net)),
      fetchUpdate(options(net)),
    ])

    expect(first).toMatchObject({ ok: true })
    expect(second).toMatchObject({ ok: true })
    // The second one waited and then found the work done: one download, not two,
    // and no part file left over from a writer that lost the race.
    expect(net.countFor(assetUrl(ARCHIVE_NAME))).toBe(1)
    expect(stagedNames(APP_VERSION)).toEqual(['bundle', ARCHIVE_NAME])
    if (!first.ok || !second.ok) return
    expect(base64Sha512(await readFile(first.archivePath))).toBe(base64Sha512(appZip))
    expect(second.bundlePath).toBe(first.bundlePath)
  }, 60_000)

  it('removes staging directories for versions other than the one in flight', async () => {
    const stale = stagingDir('0.0.1', USER_DATA)
    await mkdir(join(stale, 'bundle'), { recursive: true })
    await writeFile(join(stale, 'old.zip'), 'old release bytes')

    const net = goodNetwork()
    expect((await fetchUpdate(options(net))).ok).toBe(true)

    expect(existsSync(stale)).toBe(false)
    expect(readdirSync(updatesRoot(USER_DATA)).sort()).toEqual([APP_VERSION])
  }, 30_000)

  it('leaves nothing behind and asks for nothing when the download is cancelled', async () => {
    const controller = new AbortController()
    const net = goodNetwork({}, { chunkSize: 4096 })
    const result = await fetchUpdate(
      options(net, {
        signal: controller.signal,
        // Abort as soon as the first chunk has landed, mid-body.
        onProgress: () => controller.abort(),
      }),
    )

    expect(result).toMatchObject({ ok: false, reason: 'cancelled' })
    expect(stagedNames(APP_VERSION)).toEqual([])
  }, 30_000)

  it('reports an unreachable feed without touching the disk', async () => {
    const net = network({})
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: false, reason: 'feed-unreachable' })
    if (result.ok) return
    expect(result.message).toContain('404')
    expect(existsSync(updatesRoot(USER_DATA))).toBe(false)
  })

  it('reports a feed that lists no zip as exactly that', async () => {
    const net = network({
      [FEED_URL]: {
        bytes: Buffer.from(
          ['version: 1.0.0', 'files:', '  - url: a.dmg', '    sha512: x', '    size: 5', ''].join('\n'),
        ),
      },
    })
    const result = await fetchUpdate(options(net))
    expect(result).toMatchObject({ ok: false, reason: 'no-zip' })
    if (result.ok) return
    // The sentence names what the feed did list, so the packaging mistake is
    // visible without going and reading the feed.
    expect(result.message).toContain('a.dmg')
    expect(result.message).toMatch(/\.dmg cannot be unpacked/)
  })

  it('calls an absurdly large feed unreadable rather than unreachable', async () => {
    const net = network({ [FEED_URL]: { bytes: Buffer.alloc(MAX_FEED_BYTES + 1, 0x20) } })
    const result = await fetchUpdate(options(net))

    expect(result).toMatchObject({ ok: false, reason: 'feed-unreadable' })
    if (result.ok) return
    expect(result.message).toContain(String(MAX_FEED_BYTES))
  })

})

/**
 * Outside the block above on purpose: this is the one `fetchUpdate` case that
 * has to run *everywhere*, and it is the only one that can, because the refusal
 * happens before the feed is read and so needs no fixture behind it. An empty
 * network is enough, and it makes "nothing was requested" mean something
 * stronger than it would against a network with routes in it.
 */
describe('fetchUpdate off macOS', () => {
  it('does not pretend to work', async () => {
    const net = network({})
    const result = await fetchUpdate(options(net, { platform: 'win32' }))

    expect(result).toMatchObject({ ok: false, reason: 'unsupported-platform' })
    // Not one request was made, so nothing was spent finding out.
    expect(net.calls.size).toBe(0)
  })
})

describe('stagedBundlePath', () => {
  it.skipIf(!MAC)('is null before anything is staged and the bundle afterwards', async () => {
    expect(await stagedBundlePath(APP_VERSION, USER_DATA)).toBeNull()

    const net = goodNetwork()
    const result = await fetchUpdate(options(net))
    expect(result.ok).toBe(true)
    if (!result.ok) return

    expect(await stagedBundlePath(APP_VERSION, USER_DATA)).toBe(result.bundlePath)
    // A different version is not staged just because some version is.
    expect(await stagedBundlePath('0.0.1', USER_DATA)).toBeNull()
  }, 30_000)

  it('refuses a version that is a path', async () => {
    expect(await stagedBundlePath('../../etc', USER_DATA)).toBeNull()
    expect(await stagedBundlePath('..', USER_DATA)).toBeNull()
  })

  /**
   * The caller of this function moves what it returns over the user's
   * application and then deletes the backup. A tree with no record of a finished
   * extraction has to come back as null, however well-formed it looks.
   */
  it.skipIf(!MAC)('refuses a bundle that no completed extraction vouches for', async () => {
    const net = goodNetwork()
    const result = await fetchUpdate(options(net))
    expect(result.ok).toBe(true)
    expect(await stagedBundlePath(APP_VERSION, USER_DATA)).not.toBeNull()

    // Exactly what a crash between `ditto` finishing and the check finishing
    // leaves: the tree, without the record that anything completed.
    await rm(join(extractDir(APP_VERSION, USER_DATA), '.verified-sha512'), { force: true })
    expect(await stagedBundlePath(APP_VERSION, USER_DATA)).toBeNull()
  }, 30_000)
})

describe('the fetch seam', () => {
  /**
   * A compile-time check that the seam still fits the real thing. If
   * `globalThis.fetch` ever stops satisfying `FetchLike`, this file fails to
   * typecheck — which is the only way to find out without opening a socket.
   */
  it('is satisfied by the platform fetch', () => {
    const real: FetchLike = fetch
    expect(typeof real).toBe('function')
  })
})
