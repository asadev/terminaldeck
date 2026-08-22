import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { makeZip } from './browser-extension-zip.fixture'
import {
  CHROMIUM_PATH_ENV,
  PINNED_CHROMIUM_VERSION,
  cftPlatformFor,
  chromeExecutableRel,
  downloadUrlFor,
  installChromium,
  md5FromGoogHash,
  resolveChromeDownload,
  verifyChecksum,
  type FetchJson,
  type FetchZip,
} from './browser-chromium-install'

/* --------------------------------------------------------------- fixtures -- */

const VERSION = PINNED_CHROMIUM_VERSION

/** A known-good-versions index carrying one version's chrome downloads. */
function versionsIndex(version = VERSION): unknown {
  const platforms = ['linux64', 'mac-arm64', 'mac-x64', 'win64'] as const
  return {
    timestamp: '2026-01-01T00:00:00Z',
    versions: [
      {
        version,
        revision: '1582197',
        downloads: {
          chrome: platforms.map((platform) => ({ platform, url: downloadUrlFor(version, platform) })),
        },
      },
    ],
  }
}

/** A fake chrome-for-testing archive: the binary, a helper, and a resource. */
function fakeChromeZip(): Buffer {
  return makeZip([
    { path: 'chrome-linux64/chrome', bytes: Buffer.from('#!/fake-elf\n') },
    { path: 'chrome-linux64/chrome_crashpad_handler', bytes: Buffer.from('#!/fake-crashpad\n') },
    { path: 'chrome-linux64/lib/libEGL.so', bytes: Buffer.from('not really a library') },
  ])
}

function md5Base64(bytes: Buffer): string {
  return createHash('md5').update(bytes).digest('base64')
}

function fetchJsonReturning(json: unknown): FetchJson {
  return async () => ({ ok: true, json, message: '' })
}

function fetchZipReturning(bytes: Buffer, md5: string): FetchZip {
  return async () => ({ ok: true, status: 200, bytes, md5, message: '' })
}

let root: string

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-chromium-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

/* --------------------------------------------------------- URL resolution -- */

describe('resolving a download out of the versions index', () => {
  it('finds the chrome build for a platform', () => {
    const result = resolveChromeDownload(versionsIndex(), VERSION, 'linux64')
    expect(result).toEqual({
      ok: true,
      version: VERSION,
      platform: 'linux64',
      url: downloadUrlFor(VERSION, 'linux64'),
    })
  })

  it('resolves every platform key, not just linux', () => {
    for (const platform of ['linux64', 'mac-arm64', 'mac-x64', 'win64'] as const) {
      const result = resolveChromeDownload(versionsIndex(), VERSION, platform)
      expect(result.ok).toBe(true)
    }
  })

  it('names a version the index does not publish', () => {
    const result = resolveChromeDownload(versionsIndex(), '999.0.0.0', 'linux64')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('999.0.0.0')
  })

  it('names a platform the version has no build for', () => {
    const index = {
      versions: [{ version: VERSION, downloads: { chrome: [{ platform: 'win64', url: downloadUrlFor(VERSION, 'win64') }] } }],
    }
    const result = resolveChromeDownload(index, VERSION, 'linux64')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('linux64')
  })

  it('refuses an index whose url is not the canonical object', () => {
    const index = {
      versions: [{ version: VERSION, downloads: { chrome: [{ platform: 'linux64', url: 'https://evil.example/chrome.zip' }] } }],
    }
    const result = resolveChromeDownload(index, VERSION, 'linux64')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('evil.example')
  })

  it('refuses junk instead of throwing', () => {
    expect(resolveChromeDownload(null, VERSION, 'linux64').ok).toBe(false)
    expect(resolveChromeDownload({}, VERSION, 'linux64').ok).toBe(false)
    expect(resolveChromeDownload({ versions: 'no' }, VERSION, 'linux64').ok).toBe(false)
  })
})

describe('mapping a host to a chrome-for-testing platform key', () => {
  it('maps the ones with a published build', () => {
    expect(cftPlatformFor('linux', 'x64')).toBe('linux64')
    expect(cftPlatformFor('darwin', 'arm64')).toBe('mac-arm64')
    expect(cftPlatformFor('darwin', 'x64')).toBe('mac-x64')
    expect(cftPlatformFor('win32', 'x64')).toBe('win64')
  })

  it('is null for an arch chrome-for-testing does not publish', () => {
    expect(cftPlatformFor('linux', 'arm64')).toBeNull()
    expect(cftPlatformFor('win32', 'arm64')).toBeNull()
  })

  it('points each platform at the right executable name', () => {
    expect(chromeExecutableRel('linux64')).toBe('chrome')
    expect(chromeExecutableRel('win64')).toBe('chrome.exe')
    expect(chromeExecutableRel('mac-arm64')).toContain('Google Chrome for Testing.app')
  })
})

/* ------------------------------------------------------------- checksums -- */

describe('verifying the download against a checksum', () => {
  const bytes = Buffer.from('the chromium archive')

  it('accepts bytes matching a pinned sha256', () => {
    const sha256 = createHash('sha256').update(bytes).digest('hex')
    const result = verifyChecksum(bytes, { sha256 })
    expect(result).toEqual({ ok: true, used: 'sha256', why: '' })
  })

  it('rejects bytes that do not match the pinned sha256', () => {
    const sha256 = createHash('sha256').update(Buffer.from('other')).digest('hex')
    const result = verifyChecksum(bytes, { sha256 })
    expect(result.ok).toBe(false)
    expect(result.used).toBe('sha256')
  })

  it('accepts bytes matching the published md5', () => {
    const result = verifyChecksum(bytes, { md5: md5Base64(bytes) })
    expect(result).toEqual({ ok: true, used: 'md5', why: '' })
  })

  it('rejects bytes that do not match the published md5', () => {
    const result = verifyChecksum(bytes, { md5: md5Base64(Buffer.from('other')) })
    expect(result.ok).toBe(false)
    expect(result.used).toBe('md5')
  })

  it('lets a pinned sha256 win over an md5', () => {
    const sha256 = createHash('sha256').update(bytes).digest('hex')
    // md5 is wrong; sha256 is right; sha256 is the authority, so this passes.
    const result = verifyChecksum(bytes, { sha256, md5: md5Base64(Buffer.from('other')) })
    expect(result.ok).toBe(true)
    expect(result.used).toBe('sha256')
  })

  it('refuses when there is no checksum at all', () => {
    const result = verifyChecksum(bytes, {})
    expect(result.ok).toBe(false)
    expect(result.used).toBe('none')
  })

  it('refuses a malformed pinned sha256 rather than trusting it', () => {
    expect(verifyChecksum(bytes, { sha256: 'not-hex' }).ok).toBe(false)
  })
})

describe('reading the md5 out of a GCS x-goog-hash header', () => {
  it('pulls md5 from a combined header', () => {
    expect(md5FromGoogHash('crc32c=JKfb+Q==,md5=5mu38j3wKRCjHKUQ/Mnvcw==')).toBe('5mu38j3wKRCjHKUQ/Mnvcw==')
  })

  it('pulls md5 when it is the only value', () => {
    expect(md5FromGoogHash('md5=5mu38j3wKRCjHKUQ/Mnvcw==')).toBe('5mu38j3wKRCjHKUQ/Mnvcw==')
  })

  it('is empty when there is no md5 or no header', () => {
    expect(md5FromGoogHash('crc32c=JKfb+Q==')).toBe('')
    expect(md5FromGoogHash(null)).toBe('')
    expect(md5FromGoogHash(undefined)).toBe('')
  })
})

/* ------------------------------------------------------------- installing -- */

describe('installing Chromium end to end', () => {
  it('downloads, verifies against the md5, unpacks, and returns the executable', async () => {
    const zip = fakeChromeZip()
    const result = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      fetchJson: fetchJsonReturning(versionsIndex()),
      fetchZip: fetchZipReturning(zip, md5Base64(zip)),
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.reused).toBe(false)
    expect(result.sideloaded).toBe(false)
    expect(result.path).toBe(join(root, VERSION, 'chrome-linux64', 'chrome'))
    expect(existsSync(result.path)).toBe(true)
    // The exec bit `unzip` drops has been put back on the binary and the helper.
    // NTFS carries no Unix exec bit, so the check is only meaningful off Windows;
    // the install itself (a linux64 Chromium unpacked on any host) is exercised
    // on every platform, just not this one Unix-permission property.
    if (process.platform !== 'win32') {
      expect(statSync(result.path).mode & 0o111).not.toBe(0)
      expect(statSync(join(root, VERSION, 'chrome-linux64', 'chrome_crashpad_handler')).mode & 0o111).not.toBe(0)
    }
    // The record was written so a second install can reuse it.
    expect(existsSync(join(root, VERSION, 'installed.json'))).toBe(true)
  })

  it('accepts a pinned sha256 as the authority', async () => {
    const zip = fakeChromeZip()
    const sha256 = createHash('sha256').update(zip).digest('hex')
    const result = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      pinnedSha256: sha256,
      fetchJson: fetchJsonReturning(versionsIndex()),
      // md5 deliberately wrong: the pin is what must be trusted.
      fetchZip: fetchZipReturning(zip, md5Base64(Buffer.from('wrong'))),
    })
    expect(result.ok).toBe(true)
    if (result.ok) {
      const record = JSON.parse(readFileSync(join(root, VERSION, 'installed.json'), 'utf8'))
      expect(record.checksum).toBe('sha256')
    }
  })

  it('reuses an already-installed verified copy without refetching', async () => {
    const zip = fakeChromeZip()
    const first = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      fetchJson: fetchJsonReturning(versionsIndex()),
      fetchZip: fetchZipReturning(zip, md5Base64(zip)),
    })
    expect(first.ok).toBe(true)

    let secondFetched = false
    const result = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      fetchJson: async () => {
        secondFetched = true
        return { ok: true, json: versionsIndex(), message: '' }
      },
      fetchZip: async () => {
        secondFetched = true
        return { ok: true, status: 200, bytes: zip, md5: md5Base64(zip), message: '' }
      },
    })
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.reused).toBe(true)
    expect(secondFetched).toBe(false)
  })

  it('honours the air-gapped path override before any network', async () => {
    const sideloaded = join(root, 'my-chrome')
    // A real file so the existence check passes.
    writeFileSync(sideloaded, 'x')

    let fetched = false
    const result = await installChromium({
      root,
      env: { [CHROMIUM_PATH_ENV]: sideloaded },
      fetchJson: async () => {
        fetched = true
        return { ok: false, json: null, message: 'should not be called' }
      },
    })
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.sideloaded).toBe(true)
      expect(result.path).toBe(sideloaded)
    }
    expect(fetched).toBe(false)
  })

  it('is a named error when the override points at nothing', async () => {
    const result = await installChromium({
      root,
      env: { [CHROMIUM_PATH_ENV]: join(root, 'does-not-exist') },
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain(CHROMIUM_PATH_ENV)
  })

  it('refuses and writes nothing when the checksum does not match', async () => {
    const zip = fakeChromeZip()
    const result = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      fetchJson: fetchJsonReturning(versionsIndex()),
      fetchZip: fetchZipReturning(zip, md5Base64(Buffer.from('tampered'))),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('does not match')
    expect(existsSync(join(root, VERSION))).toBe(false)
  })

  it('refuses when the download carries no checksum', async () => {
    const zip = fakeChromeZip()
    const result = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      fetchJson: fetchJsonReturning(versionsIndex()),
      fetchZip: fetchZipReturning(zip, ''),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('no checksum')
  })

  it('surfaces a failed download as a named error', async () => {
    const result = await installChromium({
      root,
      platform: 'linux64',
      env: {},
      fetchJson: fetchJsonReturning(versionsIndex()),
      fetchZip: async () => ({ ok: false, status: 503, bytes: Buffer.alloc(0), md5: '', message: 'the download answered 503' }),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('503')
  })

  it('surfaces an unresolvable version as a named error', async () => {
    const zip = fakeChromeZip()
    const result = await installChromium({
      root,
      platform: 'linux64',
      version: '1.2.3.4',
      env: {},
      fetchJson: fetchJsonReturning(versionsIndex()),
      fetchZip: fetchZipReturning(zip, md5Base64(zip)),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('1.2.3.4')
  })
})
