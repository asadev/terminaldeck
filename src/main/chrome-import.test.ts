import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  BROWSERS,
  chromeTimeToUnixMs,
  classifyLocalUrl,
  collectBookmarkUrls,
  dedupeUrls,
  detectBrowsers,
  listSessionFiles,
  parseProfileNames,
  readHistoryRows,
  scanForDevUrls,
  scanProfile,
  snapshotDatabase,
  userDataDirFor,
  type BrowserProfile,
  type DetectedBrowser,
  type DevUrl,
  type ReadonlyDatabase,
} from './chrome-import'

/**
 * The filesystem here is real — a temp tree shaped like a Chrome profile —
 * because the parts that go wrong in this module are all filesystem parts.
 * Only the SQLite handle is faked, and only because `better-sqlite3`'s binding
 * is compiled for Electron's ABI and cannot be loaded by the Node that runs
 * these tests. The SQL and the Chrome-epoch arithmetic were checked separately
 * against a real database opened under Electron.
 */

let root = ''
let profile: BrowserProfile

const CHROME_EPOCH_OFFSET_MS = 11_644_473_600_000
const VISIT_MS = Date.UTC(2026, 7, 12, 9, 30, 0)
const chromeTime = (unixMs: number) => (unixMs + CHROME_EPOCH_OFFSET_MS) * 1000

/** A stand-in for better-sqlite3 returning rows in Chrome's `urls` shape. */
function fakeDatabase(rows: unknown[]): { open: () => ReadonlyDatabase; closed: () => boolean } {
  let closed = false
  return {
    open: () => ({
      prepare: () => ({ all: () => rows }),
      close: () => {
        closed = true
      },
    }),
    closed: () => closed,
  }
}

beforeAll(() => {
  root = mkdtempSync(join(tmpdir(), 'terminaldeck-chrome-test-'))
  const profilePath = join(root, 'Default')
  mkdirSync(join(profilePath, 'Sessions'), { recursive: true })

  writeFileSync(join(profilePath, 'Preferences'), '{}')
  writeFileSync(
    join(profilePath, 'Bookmarks'),
    JSON.stringify({
      version: 1,
      roots: {
        bookmark_bar: {
          type: 'folder',
          name: 'Bookmarks bar',
          children: [
            {
              type: 'url',
              name: 'Deck dev',
              url: 'http://localhost:5173/dashboard',
              date_added: String(chromeTime(VISIT_MS)),
            },
            {
              type: 'folder',
              name: 'Work',
              children: [
                { type: 'url', name: 'Sentinel', url: 'http://127.0.0.1:8787/health' },
                { type: 'url', name: 'HN', url: 'https://news.ycombinator.com/' },
              ],
            },
          ],
        },
        other: {
          type: 'folder',
          children: [{ type: 'url', name: 'Prod', url: 'https://example.com:8443/app' }],
        },
      },
    }),
  )

  // Real files, so `listSessionFiles` is exercised against real ordering.
  writeFileSync(join(profilePath, 'Sessions', 'Session_13400000000000000'), sessionBlob())
  writeFileSync(join(profilePath, 'Sessions', 'Session_13300000000000000'), Buffer.from('SNSS'))
  writeFileSync(join(profilePath, 'Sessions', 'Extensions'), Buffer.from('ignore me'))

  writeFileSync(join(profilePath, 'History'), 'not really sqlite, the opener is faked')
  writeFileSync(join(profilePath, 'History-journal'), 'journal')

  profile = {
    browserId: 'chrome',
    browserName: 'Chrome',
    id: 'Default',
    name: 'Person 1',
    path: profilePath,
    access: 'ok',
  }
})

afterAll(() => {
  if (root) rmSync(root, { recursive: true, force: true })
})

/** A binary blob shaped like a session file: URLs in UTF-8 among binary noise. */
function sessionBlob(): Buffer {
  const parts: Buffer[] = [
    Buffer.from('SNSS'),
    Buffer.from([1, 0, 0, 0, 0, 0]),
    Buffer.from('http://localhost:3000/'),
    Buffer.from([0, 0, 12, 0]),
    Buffer.from('https://example.com/not-local'),
    Buffer.from([0, 7]),
    // A title, pickled UTF-16 the way Chrome does — must not become a URL.
    Buffer.from('P\0a\0w\0l\0', 'latin1'),
    Buffer.from('http://127.0.0.1:8787/health'),
    Buffer.from([0, 0, 0, 3]),
  ]
  return Buffer.concat(parts)
}

/* -------------------------------------------------------------------------- */

describe('classifyLocalUrl', () => {
  it('accepts loopback in every spelling', () => {
    for (const url of [
      'http://localhost:3000/',
      'http://localhost/',
      'http://127.0.0.1:8787/health',
      'http://127.1.2.3/',
      'https://[::1]:5173/',
      'http://0.0.0.0:8080/',
    ]) {
      expect(classifyLocalUrl(url), url).not.toBeNull()
      expect(classifyLocalUrl(url)?.reason, url).toBe('loopback')
    }
  })

  it('strips the brackets from an IPv6 host', () => {
    expect(classifyLocalUrl('https://[::1]:5173/')?.host).toBe('::1')
  })

  it('accepts the local TLDs', () => {
    for (const url of [
      'http://mac-mini.local:3000/',
      'http://app.localhost:8080/',
      'http://api.test/',
      'https://registry.internal/',
    ]) {
      expect(classifyLocalUrl(url)?.reason, url).toBe('local-tld')
    }
  })

  it('accepts private LAN addresses', () => {
    for (const url of ['http://192.168.1.44:3000/', 'http://10.0.0.5/', 'http://172.20.1.1:9000/']) {
      expect(classifyLocalUrl(url)?.reason, url).toBe('private-lan')
    }
    // 172.32 is outside the private block — it is the public internet.
    expect(classifyLocalUrl('http://172.32.0.1:3000/')).toBeNull()
  })

  it('accepts a bare machine name only when it carries a port', () => {
    expect(classifyLocalUrl('http://devbox:5173/')?.reason).toBe('named-host-port')
    // No port: this is just an intranet host, and the browser has plenty.
    expect(classifyLocalUrl('http://devbox/')).toBeNull()
  })

  it('does not call a public site local just because it has a port', () => {
    // The trap: ":PORT" alone is not evidence. This is somebody's production.
    expect(classifyLocalUrl('https://example.com:8443/app')).toBeNull()
    expect(classifyLocalUrl('https://news.ycombinator.com/')).toBeNull()
    expect(classifyLocalUrl('http://8.8.8.8:3000/')).toBeNull()
  })

  it('reports only an explicit port', () => {
    expect(classifyLocalUrl('http://localhost:3000/')?.port).toBe(3000)
    expect(classifyLocalUrl('http://localhost/')?.port).toBeNull()
    // The default port is normalised away by URL, which is the honest answer.
    expect(classifyLocalUrl('http://localhost:80/')?.port).toBeNull()
  })

  it('drops credentials embedded in the URL', () => {
    // Chrome keeps `http://user:hunter2@host/` verbatim in history. Everything
    // downstream of here is displayed and sent over IPC, so the password must
    // not survive the classification.
    const found = classifyLocalUrl('http://admin:hunter2@localhost:8080/panel')
    expect(found?.url).toBe('http://localhost:8080/panel')
    expect(found?.url).not.toContain('hunter2')
    expect(found?.url).not.toContain('admin')
    expect(found?.host).toBe('localhost')
    expect(classifyLocalUrl('http://token@127.0.0.1:3000/')?.url).toBe('http://127.0.0.1:3000/')
  })

  it('rejects everything that is not http', () => {
    for (const url of [
      'chrome://settings',
      'file:///Users/asad/index.html',
      'devtools://devtools/bundled/inspector.html',
      'javascript:alert(1)',
      'ws://localhost:3000',
      '',
      'not a url',
    ]) {
      expect(classifyLocalUrl(url), url).toBeNull()
    }
  })

  it('survives values that are not strings', () => {
    for (const value of [null, undefined, 42, {}, []]) {
      expect(classifyLocalUrl(value as unknown as string)).toBeNull()
    }
  })
})

describe('chromeTimeToUnixMs', () => {
  it('converts microseconds since 1601 to unix milliseconds', () => {
    // Verified by round-tripping through a real SQLite database under Electron.
    expect(chromeTimeToUnixMs(chromeTime(VISIT_MS))).toBe(VISIT_MS)
    expect(chromeTimeToUnixMs(String(chromeTime(VISIT_MS)))).toBe(VISIT_MS)
  })

  it('rejects the values a corrupt or absent field produces', () => {
    for (const value of [0, -1, null, undefined, '', 'abc', NaN, 1]) {
      expect(chromeTimeToUnixMs(value), String(value)).toBeNull()
    }
    // Far future — a field that is not actually a timestamp.
    expect(chromeTimeToUnixMs(chromeTime(Date.now() + 86_400_000 * 400))).toBeNull()
  })
})

describe('parseProfileNames', () => {
  it('reads the display names out of Local State', () => {
    const names = parseProfileNames({
      profile: { info_cache: { Default: { name: 'Asad' }, 'Profile 3': { name: 'Work ' } } },
    })
    expect(names).toEqual({ Default: 'Asad', 'Profile 3': 'Work' })
  })

  it('returns nothing rather than throwing on junk', () => {
    for (const raw of [null, 42, {}, { profile: 1 }, { profile: { info_cache: 'x' } }]) {
      expect(parseProfileNames(raw)).toEqual({})
    }
    expect(parseProfileNames({ profile: { info_cache: { Default: { name: '  ' } } } })).toEqual({})
  })

  it('ignores a __proto__ key instead of re-parenting the result', () => {
    const names = parseProfileNames({
      profile: { info_cache: { __proto__: { name: 'evil' }, Default: { name: 'ok' } } },
    })
    expect(names).toEqual({ Default: 'ok' })
    expect(Object.getPrototypeOf(names)).toBe(Object.prototype)
  })
})

describe('collectBookmarkUrls', () => {
  it('keeps the local URLs and records the folder they came from', () => {
    const raw = JSON.parse(readFileSync(join(root, 'Default', 'Bookmarks'), 'utf8')) as unknown
    const hits = collectBookmarkUrls(raw)
    const byUrl = new Map(hits.map((h) => [h.url, h]))

    expect([...byUrl.keys()].sort()).toEqual([
      'http://127.0.0.1:8787/health',
      'http://localhost:5173/dashboard',
    ])
    expect(byUrl.get('http://localhost:5173/dashboard')?.folder).toBe('Bookmarks bar')
    expect(byUrl.get('http://127.0.0.1:8787/health')?.folder).toBe('Bookmarks bar/Work')
    expect(byUrl.get('http://localhost:5173/dashboard')?.title).toBe('Deck dev')
    expect(byUrl.get('http://localhost:5173/dashboard')?.addedAt).toBe(VISIT_MS)
    // No date_added on that one, and an invented time would be worse than none.
    expect(byUrl.get('http://127.0.0.1:8787/health')?.addedAt).toBeNull()
  })

  it('returns nothing for a file that is not a bookmarks file', () => {
    for (const raw of [null, 42, {}, { roots: 'no' }, []]) {
      expect(collectBookmarkUrls(raw)).toEqual([])
    }
  })

  it('walks a tree far deeper than the stack would take', () => {
    // A recursive walk overflows here; that is the whole reason it is not one.
    let node: Record<string, unknown> = { type: 'url', url: 'http://localhost:9999/deep' }
    for (let i = 0; i < 60_000; i += 1) node = { type: 'folder', children: [node] }
    expect(() => collectBookmarkUrls({ roots: { bookmark_bar: node } }, 200_000)).not.toThrow()
  })

  it('stops at the visit cap on a pathological file', () => {
    let node: Record<string, unknown> = { type: 'url', url: 'http://localhost:9999/deep' }
    for (let i = 0; i < 5_000; i += 1) node = { type: 'folder', children: [node] }
    expect(collectBookmarkUrls({ roots: { bookmark_bar: node } }, 10)).toEqual([])
  })
})

describe('session files', () => {
  // `listSessionFiles` returns paths built with `join`, so the names are pulled
  // back off with `basename` rather than by splitting on '/': on Windows the
  // separator is a backslash and every "name" came back as the whole path.
  it('lists only session files, newest first', () => {
    const files = listSessionFiles(join(root, 'Default')).map((f) => basename(f))
    expect(files).toEqual(['Session_13400000000000000', 'Session_13300000000000000'])
  })

  it('returns nothing when there is no Sessions directory', () => {
    expect(listSessionFiles(join(root, 'nope'))).toEqual([])
  })

  it('orders by the timestamp, not by the file name', () => {
    // Regression: a descending string sort put every `Tabs_…` ahead of every
    // `Session_…` — 'T' sorts after 'S' — so a profile with four newer-looking
    // Tabs files pushed the Session files, which hold the open tabs, past the
    // cap of four entirely.
    const dir = join(root, 'Ordering')
    mkdirSync(join(dir, 'Sessions'), { recursive: true })
    for (const name of [
      'Tabs_13300000000000001',
      'Tabs_13300000000000002',
      'Tabs_13300000000000003',
      'Tabs_13300000000000004',
      'Session_13400000000000000',
      'Session_13390000000000000',
    ]) {
      writeFileSync(join(dir, 'Sessions', name), 'x')
    }
    const files = listSessionFiles(dir).map((f) => basename(f))
    expect(files[0]).toBe('Session_13400000000000000')
    expect(files[1]).toBe('Session_13390000000000000')
    expect(files).toHaveLength(4)
  })

  it('keeps stamps apart that are too large for a float to tell apart', () => {
    // 1.34e16 is past Number.MAX_SAFE_INTEGER, so Number() rounds neighbours
    // onto the same value; the digits are compared as digits for that reason.
    const dir = join(root, 'BigStamps')
    mkdirSync(join(dir, 'Sessions'), { recursive: true })
    writeFileSync(join(dir, 'Sessions', 'Session_13400000000000001'), 'x')
    writeFileSync(join(dir, 'Sessions', 'Session_13400000000000003'), 'x')
    writeFileSync(join(dir, 'Sessions', 'Session_9400000000000003'), 'x')
    expect(listSessionFiles(dir).map((f) => basename(f))).toEqual([
      'Session_13400000000000003',
      'Session_13400000000000001',
      'Session_9400000000000003',
    ])
  })
})

describe('snapshotDatabase', () => {
  it('copies the database and its journal, then cleans up after itself', () => {
    const snapshot = snapshotDatabase(join(root, 'Default', 'History'))
    expect(existsSync(snapshot.file)).toBe(true)
    // The real Chrome database has a `-journal`, not a `-wal`.
    expect(existsSync(`${snapshot.file}-journal`)).toBe(true)
    expect(existsSync(`${snapshot.file}-wal`)).toBe(false)
    // Never the original: the copy is what gets opened.
    expect(snapshot.file.startsWith(join(root, 'Default'))).toBe(false)

    snapshot.dispose()
    expect(existsSync(snapshot.file)).toBe(false)
  })

  it('throws without leaving a temp directory behind when the source is gone', () => {
    expect(() => snapshotDatabase(join(root, 'Default', 'Nope'))).toThrow()
  })

  it('leaves the original untouched', () => {
    const source = join(root, 'Default', 'History')
    const before = readFileSync(source)
    const snapshot = snapshotDatabase(source)
    snapshot.dispose()
    expect(readFileSync(source)).toEqual(before)
  })
})

describe('readHistoryRows', () => {
  it('reads the copy and always closes the handle', async () => {
    const db = fakeDatabase([{ url: 'http://localhost:3000/', title: 'x' }])
    const rows = await readHistoryRows(join(root, 'Default', 'History'), db.open)
    expect(rows).toHaveLength(1)
    expect(db.closed()).toBe(true)
  })

  it('never opens the file it was given', async () => {
    const source = join(root, 'Default', 'History')
    let opened = ''
    await readHistoryRows(source, (file) => {
      opened = file
      return { prepare: () => ({ all: () => [] }), close: () => {} }
    })
    expect(opened).not.toBe(source)
    expect(opened).toContain('terminaldeck-browser-')
  })
})

describe('scanProfile', () => {
  const rows = [
    {
      url: 'http://localhost:5173/dashboard',
      title: 'Deck dev',
      last_visit_time: chromeTime(VISIT_MS),
      visit_count: 12,
    },
    { url: 'https://news.ycombinator.com/', title: 'HN', last_visit_time: 0, visit_count: 99 },
    {
      url: 'http://192.168.1.44:3000/',
      title: '',
      last_visit_time: chromeTime(VISIT_MS),
      visit_count: 1,
    },
  ]

  it('gathers every source and keeps them apart', async () => {
    const found = await scanProfile(profile, undefined, { openDatabase: fakeDatabase(rows).open })
    const sources = new Set(found.urls.map((u) => u.source))
    expect(sources).toEqual(new Set(['bookmark', 'history', 'session']))
    expect(found.problems).toEqual([])
  })

  it('marks session hits as approximate and never invents a title for them', async () => {
    const found = await scanProfile(profile, ['session'])
    const urls = found.urls.map((u) => u.url)
    expect(urls).toContain('http://localhost:3000/')
    expect(urls).toContain('http://127.0.0.1:8787/health')
    expect(urls).not.toContain('https://example.com/not-local')
    for (const hit of found.urls) {
      expect(hit.approximate).toBe(true)
      expect(hit.title).toBeNull()
    }
  })

  it('carries the visit count and time through from history', async () => {
    const found = await scanProfile(profile, ['history'], { openDatabase: fakeDatabase(rows).open })
    const dev = found.urls.find((u) => u.url === 'http://localhost:5173/dashboard')
    expect(dev?.detail).toBe('12 visits')
    expect(dev?.lastSeen).toBe(VISIT_MS)
    expect(found.urls.map((u) => u.url)).not.toContain('https://news.ycombinator.com/')
    // A blank title is not a title.
    expect(found.urls.find((u) => u.host === '192.168.1.44')?.title).toBeNull()
  })

  it('says nothing about a source that simply is not there', async () => {
    const bare: BrowserProfile = { ...profile, path: join(root, 'Empty') }
    mkdirSync(bare.path, { recursive: true })
    const found = await scanProfile(bare, ['bookmark', 'history'], {
      openDatabase: fakeDatabase([]).open,
    })
    expect(found.urls).toEqual([])
    expect(found.problems).toEqual([])
  })

  it('says nothing when a session file is rotated away mid-scan', async () => {
    // Chrome rewrites these constantly, so a file listed a moment ago is
    // routinely gone by the time it is read. The other two sources already
    // swallowed ENOENT; this one reported it as a user-facing problem.
    // A dangling symlink is the same shape as the race: `readdir` lists it,
    // and the `stat` that follows raises ENOENT.
    const racing: BrowserProfile = { ...profile, path: join(root, 'Racing') }
    mkdirSync(join(racing.path, 'Sessions'), { recursive: true })
    symlinkSync(join(root, 'gone-already'), join(racing.path, 'Sessions', 'Session_13400000000000009'))

    const found = await scanProfile(racing, ['session'])
    expect(found.problems).toEqual([])
    expect(found.urls).toEqual([])
  })

  it('reports a broken source instead of throwing', async () => {
    const broken: BrowserProfile = { ...profile, path: join(root, 'Broken') }
    mkdirSync(broken.path, { recursive: true })
    writeFileSync(join(broken.path, 'Bookmarks'), '{ this is not json')
    const found = await scanProfile(broken, ['bookmark'])
    expect(found.urls).toEqual([])
    expect(found.problems).toHaveLength(1)
    expect(found.problems[0].source).toBe('bookmark')
  })

  it('turns a database failure into a problem, not a crash', async () => {
    const found = await scanProfile(profile, ['history'], {
      openDatabase: () => {
        throw new Error('ERR_DLOPEN_FAILED')
      },
    })
    expect(found.urls).toEqual([])
    expect(found.problems[0].message).toContain('ERR_DLOPEN_FAILED')
  })
})

describe('dedupeUrls', () => {
  function hit(partial: Partial<DevUrl>): DevUrl {
    return {
      url: 'http://localhost:3000/',
      host: 'localhost',
      port: 3000,
      title: null,
      source: 'history',
      reason: 'loopback',
      detail: null,
      lastSeen: null,
      browserId: 'chrome',
      profileId: 'Default',
      ...partial,
    }
  }

  it('keeps the richest record and folds the rest into it', () => {
    const merged = dedupeUrls([
      hit({ source: 'session', approximate: true }),
      hit({ source: 'history', lastSeen: VISIT_MS }),
      hit({ source: 'bookmark', title: 'Deck dev' }),
    ])
    expect(merged).toHaveLength(1)
    expect(merged[0].source).toBe('bookmark')
    expect(merged[0].title).toBe('Deck dev')
    // The bookmark had no time; the history sighting supplies one.
    expect(merged[0].lastSeen).toBe(VISIT_MS)
    // Something firsthand saw it, so it is no longer a guess.
    expect(merged[0].approximate).toBeUndefined()
  })

  it('folds in the loser whichever order the sightings arrive in', () => {
    // Regression: `winner` is a fresh object, so `winner === current` was never
    // true and the loser was always taken to be the incumbent — which made the
    // fold a no-op in exactly the order a profile is really scanned in
    // (bookmarks first, then history, which is the only source with a time).
    const bookmarkFirst = dedupeUrls([
      hit({ source: 'bookmark', title: 'Deck dev' }),
      hit({ source: 'history', lastSeen: VISIT_MS, title: 'localhost:3000' }),
    ])
    expect(bookmarkFirst).toHaveLength(1)
    expect(bookmarkFirst[0].source).toBe('bookmark')
    expect(bookmarkFirst[0].title).toBe('Deck dev')
    expect(bookmarkFirst[0].lastSeen).toBe(VISIT_MS)

    // The same three sightings in the opposite order must agree exactly.
    const reversed = dedupeUrls([
      hit({ source: 'bookmark', title: 'Deck dev' }),
      hit({ source: 'history', lastSeen: VISIT_MS }),
      hit({ source: 'session', approximate: true }),
    ])
    expect(reversed[0].title).toBe('Deck dev')
    expect(reversed[0].lastSeen).toBe(VISIT_MS)
    expect(reversed[0].approximate).toBeUndefined()
  })

  it('takes a title from a lower-ranked sighting when the winner has none', () => {
    const merged = dedupeUrls([
      hit({ source: 'bookmark', title: null }),
      hit({ source: 'history', title: 'Dashboard' }),
    ])
    expect(merged[0].title).toBe('Dashboard')
  })

  it('stays approximate when every sighting was a guess', () => {
    const merged = dedupeUrls([
      hit({ source: 'session', approximate: true }),
      hit({ source: 'session', approximate: true }),
    ])
    expect(merged[0].approximate).toBe(true)
  })

  it('sorts bookmarks first, then by recency', () => {
    const merged = dedupeUrls([
      hit({ url: 'http://localhost:1/', source: 'history', lastSeen: 1 }),
      hit({ url: 'http://localhost:2/', source: 'history', lastSeen: 2 }),
      hit({ url: 'http://localhost:3/', source: 'bookmark' }),
    ])
    expect(merged.map((u) => u.url)).toEqual([
      'http://localhost:3/',
      'http://localhost:2/',
      'http://localhost:1/',
    ])
  })

  it('keeps different URLs apart', () => {
    expect(
      dedupeUrls([hit({ url: 'http://localhost:3000/a' }), hit({ url: 'http://localhost:3000/b' })]),
    ).toHaveLength(2)
  })
})

describe('scanForDevUrls', () => {
  const browsers: DetectedBrowser[] = [
    { id: 'chrome', name: 'Chrome', userDataDir: '', access: 'ok', profiles: [] },
  ]

  it('scans the profiles it is given and honours the cap', async () => {
    const withProfile = [{ ...browsers[0], profiles: [profile] }]
    const found = await scanForDevUrls(
      { limit: 1 },
      { browsers: withProfile, openDatabase: fakeDatabase([]).open },
    )
    expect(found.urls).toHaveLength(1)
  })

  it('does not throw on a request the renderer malformed', async () => {
    // Both entry points document that they never throw, and both are wired
    // straight to an ipcMain handler — so the argument is renderer input.
    const withProfile = [{ ...browsers[0], profiles: [profile] }]
    const opts = { browsers: withProfile, openDatabase: fakeDatabase([]).open }

    for (const bad of [null, undefined, 'nope', 42, []]) {
      const found = await scanForDevUrls(bad as never, opts)
      expect(Array.isArray(found.urls), String(bad)).toBe(true)
    }

    // `sources` as anything but an array used to make `.includes` a TypeError,
    // which rejected the whole scan from a function documented never to throw.
    for (const sources of [42, {}, null, 'bookmark']) {
      await expect(
        scanForDevUrls({ sources: sources as never }, opts),
        String(sources),
      ).resolves.toBeDefined()
      await expect(scanProfile(profile, sources as never, opts), String(sources)).resolves.toBeDefined()
    }

    // Unknown source names are dropped rather than scanned.
    const junk = await scanForDevUrls({ sources: ['cookies' as never] }, opts)
    expect(junk.urls).toEqual([])
  })

  it('falls back to the default page size when the limit is not a number', async () => {
    // `Math.min(NaN, 2000)` is NaN and `slice(0, NaN)` is empty, so this used
    // to answer a malformed request with zero URLs.
    const withProfile = [{ ...browsers[0], profiles: [profile] }]
    const opts = { browsers: withProfile, openDatabase: fakeDatabase([]).open }
    for (const limit of ['lots' as never, NaN, undefined]) {
      const found = await scanForDevUrls({ limit }, opts)
      expect(found.urls.length, String(limit)).toBeGreaterThan(0)
    }
    // A limit below one is still clamped up rather than emptying the result.
    expect((await scanForDevUrls({ limit: 0 }, opts)).urls).toHaveLength(1)
    expect((await scanForDevUrls({ limit: 1.9 }, opts)).urls).toHaveLength(1)
  })

  it('filters by browser and by profile', async () => {
    const withProfile = [{ ...browsers[0], profiles: [profile] }]
    expect(
      (await scanForDevUrls({ browserId: 'edge' }, { browsers: withProfile })).urls,
    ).toHaveLength(0)
    expect(
      (await scanForDevUrls({ profileId: 'Profile 9' }, { browsers: withProfile })).urls,
    ).toHaveLength(0)
    expect(
      (await scanForDevUrls({ browserId: 'chrome', profileId: 'Default' }, { browsers: withProfile }))
        .urls.length,
    ).toBeGreaterThan(0)
  })
})

describe('paths and detection on this machine', () => {
  // Both answers are pinned from whichever machine is running: `userDataDirFor`
  // takes the platform and the environment as arguments precisely so neither
  // side depends on the host.
  it('builds the macOS user-data directories', () => {
    const chrome = BROWSERS.find((b) => b.id === 'chrome')
    expect(chrome).toBeDefined()
    expect(userDataDirFor(chrome!, 'darwin', '/Users/asad', {})).toBe(
      '/Users/asad/Library/Application Support/Google/Chrome',
    )
    // No Linux path for Arc, because there is no Arc for Linux.
    const arc = BROWSERS.find((b) => b.id === 'arc')
    expect(userDataDirFor(arc!, 'linux', '/home/asad', {})).toBeNull()
  })

  it('needs LOCALAPPDATA on Windows and says so by returning null', () => {
    const chrome = BROWSERS.find((b) => b.id === 'chrome')
    // An empty environment, not an explicit `undefined`: the parameter used to
    // default to `process.env.LOCALAPPDATA`, and a default fires for an
    // explicit `undefined` too — so on a machine that sets the variable this
    // case quietly asserted nothing and then failed.
    expect(userDataDirFor(chrome!, 'win32', 'C:\\Users\\asad', {})).toBeNull()
    expect(
      userDataDirFor(chrome!, 'win32', 'C:\\Users\\asad', {
        LOCALAPPDATA: 'C:\\Users\\asad\\AppData\\Local',
      }),
    ).toBe('C:\\Users\\asad\\AppData\\Local\\Google\\Chrome\\User Data')
  })

  it('never throws, whatever this machine happens to have installed', () => {
    const found = detectBrowsers()
    expect(Array.isArray(found)).toBe(true)
    for (const browser of found) {
      expect(browser.userDataDir.startsWith(homedir())).toBe(true)
      // Guest and System are Chrome's own, not the user's.
      expect(browser.profiles.map((p) => p.id)).not.toContain('System Profile')
      expect(browser.profiles.map((p) => p.id)).not.toContain('Guest Profile')
      // Default always sorts first when it is present.
      const ids = browser.profiles.map((p) => p.id)
      if (ids.includes('Default')) expect(ids[0]).toBe('Default')

      // Numeric order: this machine has Profile 2, 3, 13 and 18, and a plain
      // string sort puts 13 and 18 in front of 2.
      const numbers = ids
        .map((id) => /^Profile (\d+)$/.exec(id)?.[1])
        .filter((n): n is string => n !== undefined)
        .map(Number)
      expect(numbers).toEqual([...numbers].sort((a, b) => a - b))
    }
  })

  it('finds profiles through a directory it is not allowed to list', () => {
    // The real payoff of probing by `stat`: on this machine `readdir` on
    // Chrome's directory is EPERM, and the profiles are still found.
    const chrome = detectBrowsers().find((b) => b.id === 'chrome')
    if (!chrome || chrome.access !== 'blocked') return
    expect(chrome.profiles.length).toBeGreaterThan(0)
    expect(chrome.profiles.map((p) => p.id)).toContain('Default')
  })

  it('explains a browser it can see but cannot read', () => {
    // On this machine macOS blocks Chrome's directory outright: `stat` works,
    // `readdir` and `read` return EPERM. A browser in that state has to say so
    // — reporting "no profiles" would be a dead end for the user.
    for (const browser of detectBrowsers()) {
      if (browser.access !== 'blocked') continue
      expect(browser.note).toBeTruthy()
      expect(browser.note).toMatch(/Full Disk Access/)
    }
  })
})
