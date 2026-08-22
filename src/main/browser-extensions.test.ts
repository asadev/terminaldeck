import { createHash } from 'node:crypto'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { makeExtensionZip, makeSignedCrx, plainManifest } from './browser-extension-zip.fixture'
import {
  createExtensionStore,
  digestMatches,
  isSideloadId,
  orphanExtensionIds,
  profileExtensionsRoot,
  safeProfileId,
  sideloadId,
  type ExtensionCatalogue,
  type ExtensionEntry,
} from './browser-extensions'

const PROFILE = 'default'
const OTHER = '11111111-2222-3333-4444-555555555555'

function digest(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex')
}

function entryFor(id: string, archive: Buffer, over: Partial<ExtensionEntry> = {}): ExtensionEntry {
  return {
    id,
    name: 'Test Extension',
    summary: 'Does a thing.',
    homepage: 'https://example.com/repo',
    licence: 'MIT',
    version: '1.0.0',
    category: 'scripting',
    tags: ['test'],
    works: 'works',
    measured: 'Watched working.',
    reach: ['https://example.com/*'],
    source: { url: 'https://example.com/a.zip', bytes: archive.byteLength, sha256: digest(archive) },
    ...over,
  }
}

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-extensions-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

function storeWith(catalogue: ExtensionCatalogue, archive: Buffer | null, over: Partial<{ ok: boolean; message: string }> = {}) {
  return createExtensionStore({
    userData: root,
    catalogue,
    now: () => 1_700_000_000_000,
    fetchArchive: async () =>
      archive === null
        ? { ok: false, bytes: Buffer.alloc(0), message: over.message ?? 'the network is down' }
        : { ok: true, bytes: archive, message: '' },
  })
}

describe('the compatibility layer, at install time', () => {
  /*
   * The store is where the layer is actually applied, and the failure mode it
   * guards against is specific: an install that reports success while the layer
   * never reached the disk gives a row that says an extension works over a copy
   * that will die on its first line, exactly as it did before any of this.
   */
  it('writes the layer into the unpacked copy and into the background it named', async () => {
    const archive = makeExtensionZip(
      plainManifest({ background: { service_worker: 'bg.js' } }),
      [{ path: 'bg.js', bytes: Buffer.from('(function () { self.ran = true })()\n', 'utf8') }],
    )
    const store = storeWith([entryFor('test', archive)], archive)
    const result = await store.install(PROFILE, 'test')
    expect(result.ok).toBe(true)
    const dir = join(profileExtensionsRoot(root, PROFILE) ?? '', 'test')
    expect(existsSync(join(dir, 'td-compat.js'))).toBe(true)
    const background = readFileSync(join(dir, 'bg.js'), 'utf8')
    expect(background.split('\n')[0]).toBe("importScripts('td-compat.js');")
    expect(background).toContain('self.ran = true')
  })

  it('names the layer in the confirmation rather than editing somebody’s extension in silence', async () => {
    const archive = makeExtensionZip(
      plainManifest({ background: { service_worker: 'bg.js' }, permissions: ['storage', 'contextMenus'] }),
      [{ path: 'bg.js', bytes: Buffer.from('var a = 1\n', 'utf8') }],
    )
    const store = storeWith(
      [entryFor('test', archive, { reach: ['https://example.com/*'] })],
      archive,
    )
    const result = await store.install(PROFILE, 'test')
    expect(result.message).toContain('This app fills in')
    expect(result.message).toContain('chrome.contextMenus')
    expect(result.message).toContain('its right-click menu entries are not shown')
  })

  it('shows on the row what it filled in and what is still not there', async () => {
    const archive = makeExtensionZip(
      plainManifest({ background: { service_worker: 'bg.js' }, permissions: ['storage', 'webNavigation'] }),
      [{ path: 'bg.js', bytes: Buffer.from('var a = 1\n', 'utf8') }],
    )
    const store = storeWith([entryFor('test', archive)], archive)
    await store.install(PROFILE, 'test')
    const row = store.view(PROFILE, 'Default').extensions.find((entry) => entry.id === 'test')
    expect(row?.provides).toContain('webNavigation')
    expect(row?.inert.join(' ')).toContain('main-frame navigations only')
    /*
     * And it no longer appears under "Not available here", which is the half of
     * this that would otherwise go on being false: the row would name a
     * namespace as missing that the app had just supplied.
     */
    expect(row?.missing).not.toContain('webNavigation')
  })
})

describe('a profile id is a directory name, so it is checked', () => {
  it('takes exactly what `partitionFor` takes and nothing else', async () => {
    /*
     * The one piece of this module that could drift: `safeProfileId` is written
     * out again rather than imported, because `browser-profiles.ts` reaches for
     * `electron` at its top level and everything here is testable without an
     * app. So the two are compared against a table instead.
     */
    const { partitionFor } = await import('./browser-profiles')
    const table = [
      'default',
      OTHER,
      '../escape',
      '',
      'Default',
      'not-a-uuid',
      '11111111-2222-3333-4444-55555555555',
    ]
    for (const id of table) {
      expect([id, safeProfileId(id) !== null]).toEqual([id, partitionFor(id) !== null])
    }
  })

  it('gives no folder at all for an id it does not recognise', () => {
    expect(profileExtensionsRoot(root, '../escape')).toBeNull()
  })
})

describe('the digest', () => {
  it('refuses anything that is not 64 hex characters', () => {
    // A truncated or differently-encoded digest gets caught here rather than
    // being blamed on the download.
    const bytes = Buffer.from('x')
    expect(digestMatches(bytes, digest(bytes).slice(0, 32))).toBe(false)
    expect(digestMatches(bytes, 'zz')).toBe(false)
  })

  it('matches the bytes it was computed over, and nothing else', () => {
    expect(digestMatches(Buffer.from('x'), digest(Buffer.from('x')))).toBe(true)
    expect(digestMatches(Buffer.from('y'), digest(Buffer.from('x')))).toBe(false)
  })
})

describe('installing', () => {
  it('unpacks a verified archive into the profile that asked for it', async () => {
    const archive = makeExtensionZip(plainManifest(), [
      { path: 'js/background.js', bytes: Buffer.from('console.log(1)') },
    ])
    const store = storeWith([entryFor('test', archive)], archive)

    const result = await store.install(PROFILE, 'test')
    expect(result.ok, result.message).toBe(true)

    const dir = join(root, 'browser-extensions', PROFILE, 'test')
    expect(existsSync(join(dir, 'manifest.json'))).toBe(true)
    expect(readFileSync(join(dir, 'js/background.js'), 'utf8')).toBe('console.log(1)')
  })

  it('puts it in one profile and not the other', () => {
    /*
     * The property the whole per-profile design rests on. An extension with
     * `<all_urls>` reads every page in the profile it is loaded into, so an
     * install leaking across profiles would put a program into a jar somebody
     * made specifically to keep something apart.
     */
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive)], archive)
    return store.install(PROFILE, 'test').then(() => {
      expect(store.installed(PROFILE)).toHaveLength(1)
      expect(store.installed(OTHER)).toHaveLength(0)
      expect(store.view(OTHER, 'Other').extensions[0].state).toBe('available')
    })
  })

  it('refuses a download of the wrong length before it hashes anything', async () => {
    const archive = makeExtensionZip(plainManifest())
    const entry = entryFor('test', archive)
    entry.source = { ...entry.source!, bytes: archive.byteLength + 1 }
    const result = await storeWith([entry], archive).install(PROFILE, 'test')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('bytes and this app expects')
  })

  it('refuses a download whose digest is not the one written down, and saves nothing', async () => {
    const archive = makeExtensionZip(plainManifest())
    const entry = entryFor('test', archive)
    entry.source = { ...entry.source!, sha256: digest(Buffer.from('something else')) }
    const store = storeWith([entry], archive)
    const result = await store.install(PROFILE, 'test')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('Nothing was saved')
    expect(existsSync(join(root, 'browser-extensions', PROFILE, 'test'))).toBe(false)
  })

  it('says which check refused it when the network is the problem', async () => {
    const result = await storeWith([entryFor('test', makeExtensionZip(plainManifest()))], null).install(
      PROFILE,
      'test',
    )
    expect(result.ok).toBe(false)
    expect(result.message).toContain('the network is down')
  })

  it('refuses an archive with no manifest in it', async () => {
    const archive = makeExtensionZip({} as Record<string, unknown>)
    // A manifest that parses as JSON but has no name — caught by the manifest
    // reader rather than by `loadExtension` three seconds later.
    const result = await storeWith([entryFor('test', archive)], archive).install(PROFILE, 'test')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('manifest')
  })

  it('refuses a shape Chromium will not load, before writing a byte', async () => {
    /*
     * An MV2 event page using webRequest installs cleanly and then fails at
     * every launch, so the row would say Installed forever about a program that
     * has never once run.
     */
    const archive = makeExtensionZip(
      plainManifest({
        manifest_version: 2,
        permissions: ['webRequest'],
        background: { scripts: ['bg.js'], persistent: false },
      }),
      [{ path: 'bg.js', bytes: Buffer.from('') }],
    )
    const store = storeWith([entryFor('test', archive)], archive)
    const result = await store.install(PROFILE, 'test')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('event page')
    expect(existsSync(join(root, 'browser-extensions', PROFILE, 'test'))).toBe(false)
  })

  it('will not install an entry this app measured failing', async () => {
    /*
     * Reachable over IPC even though no button draws for it. The refusal repeats
     * the measurement, so a caller that went round the screen gets exactly the
     * sentence the screen would have given.
     */
    const store = storeWith(
      [
        {
          ...entryFor('ublock-origin', Buffer.alloc(0)),
          works: 'no',
          measured: 'It loads, and then blocks nothing.',
          source: null,
        },
      ],
      null,
    )
    const result = await store.install(PROFILE, 'ublock-origin')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('blocks nothing')
    expect(store.view(PROFILE, 'Default').extensions[0].state).toBe('unavailable')
  })

  it('replaces rather than merges when it is installed again', async () => {
    // A directory left over from an older release, with files the new one no
    // longer ships, is a mixture of two extensions — and `loadExtension` runs it.
    const first = makeExtensionZip(plainManifest(), [
      { path: 'old.js', bytes: Buffer.from('gone') },
    ])
    const second = makeExtensionZip(plainManifest({ version: '2.0.0' }), [
      { path: 'new.js', bytes: Buffer.from('here') },
    ])
    const dir = join(root, 'browser-extensions', PROFILE, 'test')

    await storeWith([entryFor('test', first)], first).install(PROFILE, 'test')
    expect(existsSync(join(dir, 'old.js'))).toBe(true)

    await storeWith([entryFor('test', second)], second).install(PROFILE, 'test')
    expect(existsSync(join(dir, 'old.js'))).toBe(false)
    expect(existsSync(join(dir, 'new.js'))).toBe(true)
  })

  it('refuses a release that reaches wider than the row a person read', async () => {
    /*
     * The disclosure check, and the reason a row states its reach before the
     * button rather than after. A project that widened `host_permissions`
     * between releases would otherwise install quietly under a row still saying
     * the old, narrower thing — and reach is the whole of what somebody agreed
     * to when they pressed Install.
     */
    const archive = makeExtensionZip(plainManifest({ host_permissions: ['<all_urls>'] }))
    const store = storeWith([entryFor('test', archive, { reach: ['https://example.com/*'] })], archive)
    const result = await store.install(PROFILE, 'test')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('<all_urls>')
    expect(result.message).toContain('this store row says it reaches')
    expect(existsSync(join(root, 'browser-extensions', PROFILE, 'test'))).toBe(false)
  })

  it('does not refuse a release that reaches less than the row said', async () => {
    // The row over-stated, the person agreed to more than they got, and nobody
    // is worse off. A refusal here would be pedantry with a cost.
    const archive = makeExtensionZip(plainManifest({ host_permissions: ['https://example.com/*'] }))
    const store = storeWith(
      [entryFor('test', archive, { reach: ['https://example.com/*', 'https://other.com/*'] })],
      archive,
    )
    expect((await store.install(PROFILE, 'test')).ok).toBe(true)
  })

  it('states the reach on a row before anything is installed', async () => {
    // The tools store's rule, applied here: the row is the disclosure, so it has
    // to say what it reaches while Install is still the button on it.
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive, { reach: ['<all_urls>'] })], archive)
    const row = store.view(PROFILE, 'Default').extensions[0]
    expect(row.state).toBe('available')
    expect(row.reach).toEqual(['<all_urls>'])
    expect(row.everywhere).toBe(true)
  })

  it('names what the extension asks for that this browser has not got', async () => {
    const archive = makeExtensionZip(plainManifest({ permissions: ['storage', 'contextMenus'] }))
    const result = await storeWith([entryFor('test', archive)], archive).install(PROFILE, 'test')
    expect(result.ok).toBe(true)
    expect(result.message).toContain('chrome.contextMenus')
  })

  it('says it switched the static rulesets on, because this browser will not', async () => {
    const archive = makeExtensionZip(
      plainManifest({
        permissions: ['declarativeNetRequest'],
        declarative_net_request: { rule_resources: [{ id: 'a', enabled: true, path: 'a.json' }] },
      }),
      [{ path: 'a.json', bytes: Buffer.from('[]') }],
    )
    const result = await storeWith([entryFor('test', archive)], archive).install(PROFILE, 'test')
    expect(result.ok).toBe(true)
    /*
     * This used to assert a warning. The sentence changed when
     * `browser-extension-compat.ts` started switching these on — a row that went
     * on warning about something the app had already handled would be talking
     * somebody out of an install that works.
     */
    expect(result.message).toContain('declarativeNetRequest ruleset')
    expect(result.message).toContain('switched it on')
  })
})

describe('what a row says once it is installed', () => {
  it('reads reach off the manifest on disk rather than off the catalogue', async () => {
    const archive = makeExtensionZip(plainManifest({ host_permissions: ['<all_urls>'] }))
    const store = storeWith([entryFor('test', archive, { reach: ['<all_urls>'] })], archive)
    await store.install(PROFILE, 'test')
    const row = store.view(PROFILE, 'Default').extensions[0]
    expect(row.state).toBe('installed')
    expect(row.everywhere).toBe(true)
    expect(row.reach).toEqual(['<all_urls>'])
  })

  it('goes damaged when the manifest on disk stops being readable', async () => {
    /*
     * `<userData>` is writable by every process running as this user. An install
     * that quietly disappeared would be indistinguishable from one that was
     * never made, so it is reported with a sentence instead.
     */
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive)], archive)
    await store.install(PROFILE, 'test')
    writeFileSync(join(root, 'browser-extensions', PROFILE, 'test', 'manifest.json'), '{ broken')
    const row = store.view(PROFILE, 'Default').extensions[0]
    expect(row.state).toBe('damaged')
    expect(row.message).toContain('manifest.json')
  })

  it('goes damaged when the release on disk is not the one this build offers', async () => {
    const first = makeExtensionZip(plainManifest())
    const second = makeExtensionZip(plainManifest({ version: '9.9.9' }))
    await storeWith([entryFor('test', first)], first).install(PROFILE, 'test')
    // A newer build of the app, pinning a different release, over the old install.
    const later = storeWith([entryFor('test', second)], second)
    const row = later.view(PROFILE, 'Default').extensions[0]
    expect(row.state).toBe('damaged')
    expect(row.message).toContain('different release')
  })
})

describe('the switch', () => {
  it('writes off and back on without touching the files', async () => {
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive)], archive)
    await store.install(PROFILE, 'test')
    expect(store.installed(PROFILE)[0].enabled).toBe(true)

    expect(store.setEnabled(PROFILE, 'test', false).ok).toBe(true)
    expect(store.installed(PROFILE)[0].enabled).toBe(false)
    // Off is not gone. That distinction is the reason the switch exists beside
    // Remove at all: turning something off must not cost it what it has stored.
    expect(existsSync(join(root, 'browser-extensions', PROFILE, 'test', 'manifest.json'))).toBe(true)

    expect(store.setEnabled(PROFILE, 'test', true).ok).toBe(true)
    expect(store.installed(PROFILE)[0].enabled).toBe(true)
  })

  it('refuses to switch something that is not installed here', () => {
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive)], archive)
    expect(store.setEnabled(PROFILE, 'test', true).ok).toBe(false)
  })
})

describe('removing', () => {
  it('deletes the files and reads the disk back before saying so', async () => {
    const archive = makeExtensionZip(plainManifest(), [
      { path: 'js/a.js', bytes: Buffer.from('x') },
    ])
    const store = storeWith([entryFor('test', archive)], archive)
    await store.install(PROFILE, 'test')
    const dir = join(root, 'browser-extensions', PROFILE, 'test')
    expect(existsSync(dir)).toBe(true)

    const result = store.remove(PROFILE, 'test')
    expect(result.ok).toBe(true)
    expect(result.message).toContain('deleted')
    expect(existsSync(dir)).toBe(false)
    expect(store.installed(PROFILE)).toHaveLength(0)
    expect(store.view(PROFILE, 'Default').extensions[0].state).toBe('available')
  })

  it('says so plainly when there was nothing to remove', () => {
    const archive = makeExtensionZip(plainManifest())
    expect(storeWith([entryFor('test', archive)], archive).remove(PROFILE, 'test')).toEqual({
      ok: true,
      message: 'It was not installed.',
    })
  })

  it('removes from one profile without touching the other', async () => {
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive)], archive)
    await store.install(PROFILE, 'test')
    await store.install(OTHER, 'test')
    store.remove(PROFILE, 'test')
    expect(store.installed(PROFILE)).toHaveLength(0)
    expect(store.installed(OTHER)).toHaveLength(1)
  })
})

describe('which profiles the launch has to look at', () => {
  it('is only the ones with something installed', async () => {
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('test', archive)], archive)
    expect(store.profilesWithExtensions()).toEqual([])
    await store.install(OTHER, 'test')
    expect(store.profilesWithExtensions()).toEqual([OTHER])
  })
})

describe('folders this build can no longer name', () => {
  it('are reported, so something can offer a Remove for them', async () => {
    /*
     * Megabytes of unpacked files, written by this app, that nothing above would
     * ever name again — a leak that survives reinstalling.
     */
    const archive = makeExtensionZip(plainManifest())
    const store = storeWith([entryFor('withdrawn', archive)], archive)
    await store.install(PROFILE, 'withdrawn')
    expect(orphanExtensionIds(root, PROFILE, [])).toEqual(['withdrawn'])
    expect(orphanExtensionIds(root, PROFILE, [entryFor('withdrawn', archive)])).toEqual([])
  })
})

/* ----------------------------------------------------- adding your own -- */

/** An unpacked extension on disk, the way somebody building one would have it. */
function folderWith(
  manifest: Record<string, unknown> = plainManifest(),
  extra: Record<string, string> = { 'bg.js': 'self.ran = true\n' },
): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-own-'))
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest))
  for (const [name, body] of Object.entries(extra)) writeFileSync(join(dir, name), body)
  return dir
}

describe('adding your own, from a folder', () => {
  /*
   * The half of the store with no fingerprint in it, which is exactly why these
   * tests exist. A catalogue install is guarded by a digest pinned in this app;
   * this path has nothing of the kind and must not pretend otherwise, in the
   * row it produces or in the sentence it answers with.
   */
  it('copies it in, records where it came from, and says nothing was checked', () => {
    const store = storeWith([], null)
    const folder = folderWith()
    try {
      const result = store.addFolder(PROFILE, folder)
      expect(result.ok, result.message).toBe(true)
      expect(result.message).toContain('measured nothing about it')
      expect(result.message).toContain('checked no fingerprint')

      const id = sideloadId('folder', folder)
      const dir = join(profileExtensionsRoot(root, PROFILE) ?? '', id)
      expect(existsSync(join(dir, 'manifest.json'))).toBe(true)
      expect(readFileSync(join(dir, 'bg.js'), 'utf8')).toContain('self.ran')

      const row = store.view(PROFILE, 'Default').extensions.find((one) => one.id === id)
      expect(row?.state).toBe('installed')
      expect(row?.sideloaded).toBe(true)
      expect(row?.origin).toBe(folder)
      expect(row?.category).toBe('your-own')
      // The verdict a row this app has never run is allowed to carry, and the
      // only one: not `works`, not `no`, and nothing borrowed from a measurement.
      expect(row?.works).toBe('unmeasured')
      expect(row?.crxId).toBe('')
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('is loaded like any other install, so a session sees it', () => {
    /*
     * `installed()` is what the launch loader replays and what
     * `browser.extensions` answers with. An extension the person added
     * themselves is running in their browser exactly as a catalogue one is, and
     * a list that left it out would have an agent read a page altered by a
     * program the list said was not there.
     */
    const store = storeWith([], null)
    const folder = folderWith()
    try {
      expect(store.addFolder(PROFILE, folder).ok).toBe(true)
      const installed = store.installed(PROFILE)
      expect(installed).toHaveLength(1)
      expect(isSideloadId(installed[0]?.entry.id ?? '')).toBe(true)
      expect(installed[0]?.entry.name).toBe('Test Extension')
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('replaces rather than accumulates when the same folder is added twice', () => {
    // Somebody iterating on an extension they are writing presses Add after
    // every build. A store that grew a row each time would be unusable by the
    // third press.
    const store = storeWith([], null)
    const folder = folderWith()
    try {
      expect(store.addFolder(PROFILE, folder).ok).toBe(true)
      expect(store.addFolder(PROFILE, folder).ok).toBe(true)
      expect(store.view(PROFILE, 'Default').extensions.filter((one) => one.sideloaded)).toHaveLength(1)
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('switches off, back on, and removes, the same as any other row', () => {
    const store = storeWith([], null)
    const folder = folderWith()
    try {
      store.addFolder(PROFILE, folder)
      const id = sideloadId('folder', folder)
      expect(store.setEnabled(PROFILE, id, false).ok).toBe(true)
      expect(store.installed(PROFILE)[0]?.enabled).toBe(false)
      expect(store.setEnabled(PROFILE, id, true).ok).toBe(true)
      expect(store.installed(PROFILE)[0]?.enabled).toBe(true)
      const removed = store.remove(PROFILE, id)
      expect(removed.ok).toBe(true)
      expect(removed.message).toContain('Test Extension')
      expect(existsSync(join(profileExtensionsRoot(root, PROFILE) ?? '', id))).toBe(false)
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('is never reported as an orphan', () => {
    /*
     * `orphanExtensionIds` names folders this build has no row for, so a person
     * can delete what a withdrawn extension left behind. Something they added
     * five minutes ago has no catalogue row either, by definition, and telling
     * them it was "no longer offered" would be nonsense.
     */
    const store = storeWith([], null)
    const folder = folderWith()
    try {
      store.addFolder(PROFILE, folder)
      expect(orphanExtensionIds(root, PROFILE, [])).toEqual([])
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('refuses a folder with no manifest, and says which folder to pick', () => {
    const store = storeWith([], null)
    const empty = mkdtempSync(join(tmpdir(), 'td-empty-'))
    try {
      const result = store.addFolder(PROFILE, empty)
      expect(result.ok).toBe(false)
      expect(result.message).toContain('no manifest.json in that folder')
      expect(result.message).toContain('not the one above it')
    } finally {
      rmSync(empty, { recursive: true, force: true })
    }
  })

  it('refuses a relative path outright', () => {
    // A path that is not absolute did not come out of a file dialog.
    const store = storeWith([], null)
    expect(store.addFolder(PROFILE, 'some/where').ok).toBe(false)
  })

  it('refuses a manifest Chromium would refuse at load, before writing anything', () => {
    const store = storeWith([], null)
    const folder = folderWith(
      plainManifest({
        manifest_version: 2,
        permissions: ['webRequest'],
        background: { scripts: ['bg.js'], persistent: false },
      }),
    )
    try {
      const result = store.addFolder(PROFILE, folder)
      expect(result.ok).toBe(false)
      expect(result.message).toContain('event page')
      expect(store.view(PROFILE, 'Default').extensions.filter((one) => one.sideloaded)).toHaveLength(0)
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('does not follow a symlink out of the folder it was given', () => {
    /*
     * The one that is not about tidiness. A folder somebody picked is not
     * hostile by assumption, and a symlink inside it pointing at their home
     * directory would have this app copy that home directory into a profile and
     * then load it as a program.
     */
    const store = storeWith([], null)
    const folder = folderWith()
    const outside = mkdtempSync(join(tmpdir(), 'td-outside-'))
    try {
      mkdirSync(join(outside, 'secrets'))
      writeFileSync(join(outside, 'secrets', 'key.txt'), 'do not copy me')
      symlinkSync(join(outside, 'secrets'), join(folder, 'linked'))
      expect(store.addFolder(PROFILE, folder).ok).toBe(true)
      const dir = join(profileExtensionsRoot(root, PROFILE) ?? '', sideloadId('folder', folder))
      expect(existsSync(join(dir, 'linked'))).toBe(false)
      expect(existsSync(join(dir, 'linked', 'key.txt'))).toBe(false)
    } finally {
      rmSync(folder, { recursive: true, force: true })
      rmSync(outside, { recursive: true, force: true })
    }
  })

  it('never writes an installed.json out of the folder into the copy', () => {
    // The store's own record lives under the same name. A folder that happened
    // to contain one would otherwise overwrite what this app wrote about it.
    const store = storeWith([], null)
    const folder = folderWith(plainManifest(), {
      'installed.json': JSON.stringify({ sideloaded: false, enabled: false, name: 'Lies' }),
    })
    try {
      expect(store.addFolder(PROFILE, folder).ok).toBe(true)
      const dir = join(profileExtensionsRoot(root, PROFILE) ?? '', sideloadId('folder', folder))
      const record = JSON.parse(readFileSync(join(dir, 'installed.json'), 'utf8')) as {
        sideloaded: boolean
        name: string
      }
      expect(record.sideloaded).toBe(true)
      expect(record.name).toBe('Test Extension')
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })
})

describe('adding your own, from a .crx', () => {
  function crxAt(zip: Buffer, options: { wrongId?: boolean } = {}): { path: string; id: string } {
    const packed = makeSignedCrx(zip, options)
    const dir = mkdtempSync(join(tmpdir(), 'td-crx-'))
    const path = join(dir, 'thing.crx')
    writeFileSync(path, packed.crx)
    return { path, id: packed.id }
  }

  it('opens it, unpacks it, and records the id its own signature yields', () => {
    const store = storeWith([], null)
    const { path, id } = crxAt(makeExtensionZip(plainManifest()))
    try {
      const result = store.addCrx(PROFILE, path)
      expect(result.ok, result.message).toBe(true)
      /*
       * The sentence has to be exactly this careful. A signature on a `.crx`
       * proves the file has not changed since it was packed and proves nothing
       * about who packed it, because the key travels inside the file. A message
       * that said "verified" would be this app lending its own credibility to a
       * stranger's self-signature.
       */
      expect(result.message).toContain('says nothing about who packed it')
      expect(result.message).toContain(id)

      const row = store
        .view(PROFILE, 'Default')
        .extensions.find((one) => one.id === sideloadId('crx', path))
      expect(row?.state).toBe('installed')
      expect(row?.crxId).toBe(id)
      expect(row?.sideloaded).toBe(true)
    } finally {
      rmSync(join(path, '..'), { recursive: true, force: true })
    }
  })

  it('refuses a tampered .crx and writes nothing', () => {
    const store = storeWith([], null)
    const { path } = crxAt(makeExtensionZip(plainManifest()))
    try {
      const bytes = readFileSync(path)
      bytes[bytes.length - 30] ^= 0xff
      writeFileSync(path, bytes)
      const result = store.addCrx(PROFILE, path)
      expect(result.ok).toBe(false)
      expect(result.message).toContain('Nothing was added')
      expect(result.message).toContain('signature does not match')
      expect(store.view(PROFILE, 'Default').extensions.filter((one) => one.sideloaded)).toHaveLength(0)
    } finally {
      rmSync(join(path, '..'), { recursive: true, force: true })
    }
  })

  it('refuses a file that is not a .crx at all', () => {
    const store = storeWith([], null)
    const dir = mkdtempSync(join(tmpdir(), 'td-crx-'))
    const path = join(dir, 'not.crx')
    try {
      writeFileSync(path, makeExtensionZip(plainManifest()))
      const result = store.addCrx(PROFILE, path)
      expect(result.ok).toBe(false)
      expect(result.message).toContain('not a .crx')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
