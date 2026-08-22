import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { makeExtensionZip, makeSignedCrx, plainManifest } from './browser-extension-zip.fixture'
import type { ExtensionEntry } from './browser-extensions'

/**
 * The seam where the disk's answer and the browser's answer can disagree.
 *
 * `browser-extensions.ts` records what *should* be running; the live session
 * decides what *is*. Everything worth testing here is one of the three ways
 * those two come apart, and each one, left alone, produces a control that looks
 * like it works and does not:
 *
 *  - An extension is installed and switched on, and Electron refused to load it.
 *    The row must not draw a checked switch over a program that is not running.
 *  - Somebody switches one on and the load throws. The switch must not settle
 *    into the on position and report success.
 *  - Somebody presses Install and the load throws. The button must not say it
 *    worked.
 *
 * `electron` and `browser-profiles` are both mocked, the way
 * `browser-profiles.test.ts` mocks `electron`, so the whole of this runs with no
 * app — the extension "session" is an object whose `loadExtension` this file
 * decides the outcome of.
 */

/** What the fake session does next time it is asked to load something. */
let loadOutcome: 'ok' | Error = 'ok'
const loadedIds: string[] = []
const removedIds: string[] = []

const fakeSession = {
  extensions: {
    loadExtension: vi.fn(async (dir: string) => {
      if (loadOutcome !== 'ok') throw loadOutcome
      const id = `electron-${dir.split('/').pop() ?? 'x'}`
      loadedIds.push(id)
      return { id }
    }),
    removeExtension: vi.fn((id: string) => {
      removedIds.push(id)
    }),
  },
}

const PROFILE = 'default'
const OTHER = '11111111-2222-3333-4444-555555555555'

vi.mock('electron', () => ({
  app: { getPath: () => '/tmp/unused' },
  BrowserWindow: class {},
  session: { fromPartition: () => fakeSession },
}))

vi.mock('./browser-profiles', () => ({
  activeProfile: () => ({ id: PROFILE, name: 'Default' }),
  profileState: () => ({
    profiles: [
      { id: PROFILE, name: 'Default' },
      { id: OTHER, name: 'Work' },
    ],
    activeId: PROFILE,
  }),
  partitionFor: (id: unknown) =>
    id === PROFILE || id === OTHER ? `persist:terminaldeck-browser-${String(id)}` : null,
  sessionForPartition: () => fakeSession,
}))

const {
  currentProfileId,
  installBrowserExtensions,
  installedExtensionsFor,
  isLoaded,
  loadInstalledExtensions,
  profileNameFor,
  registerBrowserExtensionIpc,
  resetBrowserExtensions,
  setExtensionEnabled,
} = await import('./browser-extensions-ipc')

/**
 * Just enough `ipcMain` to call a handler.
 *
 * The handlers are where install, load and the row's view are stitched
 * together, and that stitching is the part that can go wrong without any single
 * module being wrong — so it is exercised through the channel rather than
 * around it.
 */
type Handler = (event: unknown, ...args: unknown[]) => unknown
function wire(): (channel: string, ...args: unknown[]) => Promise<unknown> {
  const handlers = new Map<string, Handler>()
  registerBrowserExtensionIpc({
    handle: (channel: string, handler: Handler) => handlers.set(channel, handler),
  } as unknown as Parameters<typeof registerBrowserExtensionIpc>[0])
  return async (channel, ...args) => {
    const handler = handlers.get(channel)
    if (handler === undefined) throw new Error(`no handler for ${channel}`)
    return handler(null, ...args)
  }
}

interface ViewRow {
  id: string
  state: string
  enabled: boolean
  message: string
  reach: string[]
}
interface ListAnswer {
  view: { extensions: ViewRow[]; profileName: string }
  limits: string[]
  profiles: Array<{ id: string; name: string }>
}

const ARCHIVE = makeExtensionZip(plainManifest({ host_permissions: ['<all_urls>'] }))

const ENTRY: ExtensionEntry = {
  id: 'test',
  name: 'Test Extension',
  summary: 'Does a thing.',
  homepage: 'https://example.com/repo',
  licence: 'MIT',
  version: '1.0.0',
  category: 'scripting',
  tags: ['test'],
  works: 'works',
  measured: 'Watched working.',
  reach: ['<all_urls>'],
  source: {
    url: 'https://example.com/a.zip',
    bytes: ARCHIVE.byteLength,
    sha256: createHash('sha256').update(ARCHIVE).digest('hex'),
  },
}

let root = ''

/** What the two Add dialogs answer next. `null` is a cancel, not a failure. */
let chosenFolder: string | null = null
let chosenCrx: string | null = null

function build() {
  return installBrowserExtensions({
    userData: () => root,
    catalogue: [ENTRY],
    fetchArchive: async () => ({ ok: true, bytes: ARCHIVE, message: '' }),
    chooseFolder: async () => chosenFolder,
    chooseCrx: async () => chosenCrx,
  })
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-ext-ipc-'))
  loadOutcome = 'ok'
  chosenFolder = null
  chosenCrx = null
  loadedIds.length = 0
  removedIds.length = 0
  fakeSession.extensions.loadExtension.mockClear()
  fakeSession.extensions.removeExtension.mockClear()
})

afterEach(() => {
  resetBrowserExtensions()
  rmSync(root, { recursive: true, force: true })
})

describe('which profile a caller means', () => {
  it('is the one switched on, when nobody says', () => {
    build()
    expect(currentProfileId()).toBe(PROFILE)
    expect(profileNameFor(PROFILE)).toBe('Default')
  })

  it('names a profile this app does not have by its id rather than guessing', () => {
    build()
    expect(profileNameFor('nope')).toBe('nope')
  })
})

describe('installing', () => {
  it('loads it into the session straight away, not at the next launch', async () => {
    /*
     * An install that needed a restart to do anything would be a button whose
     * effect is invisible, and the person pressing it has no way to tell that
     * from one that failed.
     */
    const store = build()
    expect((await store.install(PROFILE, 'test')).ok).toBe(true)
    await setExtensionEnabled(PROFILE, 'test', true)
    expect(isLoaded(PROFILE, 'test')).toBe(true)
    expect(loadedIds).toHaveLength(1)
  })

  it('puts it in one profile and not the other', async () => {
    const store = build()
    await store.install(OTHER, 'test')
    await setExtensionEnabled(OTHER, 'test', true)
    expect(isLoaded(OTHER, 'test')).toBe(true)
    expect(isLoaded(PROFILE, 'test')).toBe(false)
    expect(installedExtensionsFor(PROFILE)).toHaveLength(0)
  })
})

describe('the switch', () => {
  it('unloads from the live session when it goes off', async () => {
    // Off means the program stops now, not at the next launch. `removeExtension`
    // is what makes that true, and it is the whole reason a switch is honest.
    const store = build()
    await store.install(PROFILE, 'test')
    await setExtensionEnabled(PROFILE, 'test', true)
    expect(isLoaded(PROFILE, 'test')).toBe(true)

    const off = await setExtensionEnabled(PROFILE, 'test', false)
    expect(off.ok).toBe(true)
    expect(removedIds).toHaveLength(1)
    expect(isLoaded(PROFILE, 'test')).toBe(false)
    expect(installedExtensionsFor(PROFILE)[0].enabled).toBe(false)
  })

  it('reports a failure to switch on rather than settling into the on position', async () => {
    /*
     * On disk it is now on and in the browser it is not. Said plainly, because a
     * switch that flipped and changed nothing is exactly the control this app
     * refuses to ship.
     */
    const store = build()
    await store.install(PROFILE, 'test')
    await setExtensionEnabled(PROFILE, 'test', false)

    loadOutcome = new Error('the manifest is unreadable')
    const on = await setExtensionEnabled(PROFILE, 'test', true)
    expect(on.ok).toBe(false)
    expect(on.message).toContain('the manifest is unreadable')
    expect(isLoaded(PROFILE, 'test')).toBe(false)
  })

  it('refuses to switch something that is not installed in that profile', async () => {
    build()
    const result = await setExtensionEnabled(PROFILE, 'test', true)
    expect(result.ok).toBe(false)
  })
})

describe('replaying at launch', () => {
  it('loads what was switched on and leaves what was switched off alone', async () => {
    const store = build()
    await store.install(PROFILE, 'test')
    store.setEnabled(PROFILE, 'test', false)
    resetBrowserExtensions()

    // A second run of the app, over the same disk.
    build()
    await loadInstalledExtensions()
    expect(isLoaded(PROFILE, 'test')).toBe(false)
    expect(fakeSession.extensions.loadExtension).not.toHaveBeenCalled()

    resetBrowserExtensions()
    const third = build()
    third.setEnabled(PROFILE, 'test', true)
    await loadInstalledExtensions()
    expect(isLoaded(PROFILE, 'test')).toBe(true)
  })

  it('looks only at profiles that have something installed', async () => {
    // A profile directory under `browser-extensions/` exists only because
    // somebody installed into it, so nothing mints a session for the rest.
    const store = build()
    await store.install(OTHER, 'test')
    resetBrowserExtensions()
    build()
    await loadInstalledExtensions()
    expect(isLoaded(OTHER, 'test')).toBe(true)
    expect(isLoaded(PROFILE, 'test')).toBe(false)
  })
})

describe('what an agent is told', () => {
  it('sees nothing until something is installed in the profile it asked about', async () => {
    const store = build()
    expect(installedExtensionsFor(PROFILE)).toHaveLength(0)
    await store.install(PROFILE, 'test')
    expect(installedExtensionsFor(PROFILE)).toHaveLength(1)
    // Read per call rather than snapshotted, so an install lands at once instead
    // of at the next relaunch.
    expect(installedExtensionsFor(PROFILE)[0].manifest.host_permissions).toEqual(['<all_urls>'])
  })

  it('answers an empty list rather than throwing when the store was never built', () => {
    resetBrowserExtensions()
    expect(installedExtensionsFor(PROFILE)).toEqual([])
    expect(isLoaded(PROFILE, 'test')).toBe(false)
  })
})

describe('the row a panel draws', () => {
  it('cannot show On over an extension the browser did not load', async () => {
    /*
     * The single most important claim this feature makes. The store reads
     * `enabled` off the disk, which is what *should* be true; the handler
     * corrects it to what **is** true, and carries the reason. Without this,
     * an extension that threw at load has a checked switch above it and nothing
     * anywhere says otherwise.
     */
    const store = build()
    await store.install(PROFILE, 'test')
    // On disk: installed and switched on. In the browser: never loaded.
    resetBrowserExtensions()
    build()
    const again = wire()
    loadOutcome = new Error('it threw on load')
    await loadInstalledExtensions()

    const answer = (await again('browser-extension:list', PROFILE)) as ListAnswer
    const row = answer.view.extensions.find((one) => one.id === 'test')
    expect(row?.state).toBe('installed')
    expect(row?.enabled).toBe(false)
    expect(row?.message).toContain('it threw on load')
  })

  it('shows On when it really is running, and the reach off the disk', async () => {
    const store = build()
    const call = wire()
    await store.install(PROFILE, 'test')
    await setExtensionEnabled(PROFILE, 'test', true)
    const answer = (await call('browser-extension:list', PROFILE)) as ListAnswer
    const row = answer.view.extensions.find((one) => one.id === 'test')
    expect(row?.enabled).toBe(true)
    expect(row?.reach).toEqual(['<all_urls>'])
  })

  it('carries the limits and the profile list, so nothing is written twice', async () => {
    // One copy of the limits, in the module that measured them, so the sentence
    // a person reads and the one an agent gets cannot drift apart.
    const call = wire()
    build()
    const answer = (await call('browser-extension:list', PROFILE)) as ListAnswer
    expect(answer.limits.join(' ')).toContain('Chrome Web Store')
    expect(answer.profiles.map((one) => one.id)).toEqual([PROFILE, OTHER])
  })

  it('answers about the profile switched on when asked about one that does not exist', async () => {
    // A panel asking a question about a stale id should get the profile in front
    // of it rather than an exception — the judgement `profileSession` makes.
    const call = wire()
    build()
    const answer = (await call('browser-extension:list', '../escape')) as ListAnswer
    expect(answer.view.profileName).toBe('Default')
  })
})

describe('installing through the channel', () => {
  it('says it did not work when the browser refuses to load what was saved', async () => {
    build()
    const call = wire()
    loadOutcome = new Error('the manifest is unreadable')
    const result = (await call('browser-extension:install', PROFILE, 'test')) as {
      ok: boolean
      message: string
    }
    expect(result.ok).toBe(false)
    expect(result.message).toContain('the manifest is unreadable')
    expect(result.message).toContain('switched off')
  })

  it('reloads from the new files when it is installed over itself', async () => {
    /*
     * The bug this test was written for: reinstalling replaces the files under a
     * directory that is still loaded from, so without an unload in between the
     * loader hands back the old live id and the new bytes never run.
     */
    build()
    const call = wire()
    await call('browser-extension:install', PROFILE, 'test')
    expect(loadedIds).toHaveLength(1)

    await call('browser-extension:install', PROFILE, 'test')
    expect(removedIds).toHaveLength(1)
    expect(loadedIds).toHaveLength(2)
    expect(isLoaded(PROFILE, 'test')).toBe(true)
  })
})

describe('removing through the channel', () => {
  it('stops it running before deleting the files it is running from', async () => {
    // The other order deletes files out from under a live program, which is how
    // a browser ends up holding a half-mapped extension until the next launch.
    build()
    const call = wire()
    await call('browser-extension:install', PROFILE, 'test')
    const result = (await call('browser-extension:remove', PROFILE, 'test')) as { ok: boolean }
    expect(result.ok).toBe(true)
    expect(removedIds).toHaveLength(1)
    expect(isLoaded(PROFILE, 'test')).toBe(false)
    expect(installedExtensionsFor(PROFILE)).toHaveLength(0)
  })
})

describe('the popup', () => {
  it('refuses rather than opening an empty window for an extension without one', async () => {
    // The panel asks `popup` before it draws the control, so this is a second
    // line — but a caller that went round the screen gets a sentence, not a
    // blank window.
    build()
    const call = wire()
    await call('browser-extension:install', PROFILE, 'test')
    const result = (await call('browser-extension:popup', PROFILE, 'test')) as {
      ok: boolean
      message: string
    }
    expect(result.ok).toBe(false)
    expect(result.message).toContain('no panel of its own')
  })

  it('refuses when it is not switched on, because there is nothing running to show', async () => {
    build()
    const call = wire()
    await call('browser-extension:install', PROFILE, 'test')
    await setExtensionEnabled(PROFILE, 'test', false)
    const result = (await call('browser-extension:popup', PROFILE, 'test')) as {
      ok: boolean
      message: string
    }
    expect(result.ok).toBe(false)
    expect(result.message).toContain('not switched on')
  })
})

describe('the store that was never built', () => {
  it('refuses every write with a sentence rather than throwing', async () => {
    const call = wire()
    resetBrowserExtensions()
    for (const channel of [
      'browser-extension:install',
      'browser-extension:remove',
      'browser-extension:enable',
    ]) {
      const result = (await call(channel, PROFILE, 'test', true)) as { ok: boolean; message: string }
      expect(result.ok, channel).toBe(false)
      expect(result.message, channel).toContain('not available in this build')
    }
  })
})

describe('adding your own, through the channel', () => {
  /*
   * The dialog is opened by the main process and its answer never crosses the
   * IPC boundary as an argument. That is the rule this suite pins: a renderer
   * that could name a folder could name any folder, and this app would copy it
   * into a profile and run it as a program.
   */
  it('takes the folder the dialog answered with, and loads it straight away', async () => {
    const folder = mkdtempSync(join(tmpdir(), 'td-own-ipc-'))
    writeFileSync(join(folder, 'manifest.json'), JSON.stringify(plainManifest()))
    build()
    const call = wire()
    chosenFolder = folder
    try {
      const result = (await call('browser-extension:add-folder', PROFILE)) as {
        ok: boolean
        message: string
      }
      expect(result.ok, result.message).toBe(true)
      // Loaded now, not at the next launch: an Add whose effect only appears
      // after a restart is a button whose effect is invisible, and the person
      // pressing it cannot tell that from one that failed.
      expect(loadedIds).toHaveLength(1)

      const answer = (await call('browser-extension:list', PROFILE)) as ListAnswer
      const own = answer.view.extensions.find((row) => row.id.startsWith('own-'))
      expect(own?.state).toBe('installed')
      expect(own?.enabled).toBe(true)
      // And it is not swept into "no longer offered", which is where a folder
      // with no catalogue row would otherwise land.
      expect((answer as unknown as { orphans: string[] }).orphans).toEqual([])
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('treats a cancelled dialog as nothing happening, not as a failure', async () => {
    /*
     * The row must not turn red because somebody changed their mind. `ok` with
     * an empty message is what the panel prints nothing for.
     */
    build()
    const call = wire()
    chosenFolder = null
    const result = (await call('browser-extension:add-folder', PROFILE)) as {
      ok: boolean
      message: string
    }
    expect(result.ok).toBe(true)
    expect(result.message).toBe('')
    expect(loadedIds).toHaveLength(0)
  })

  it('says the browser refused it rather than reporting a success it did not have', async () => {
    const folder = mkdtempSync(join(tmpdir(), 'td-own-ipc-'))
    writeFileSync(join(folder, 'manifest.json'), JSON.stringify(plainManifest()))
    build()
    const call = wire()
    chosenFolder = folder
    loadOutcome = new Error('Could not load extension')
    try {
      const result = (await call('browser-extension:add-folder', PROFILE)) as {
        ok: boolean
        message: string
      }
      expect(result.ok).toBe(false)
      expect(result.message).toContain('would not load it')
      expect(result.message).toContain('Could not load extension')
    } finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

  it('opens a .crx from the dialog and refuses one that has been altered', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'td-crx-ipc-'))
    const path = join(dir, 'thing.crx')
    const packed = makeSignedCrx(makeExtensionZip(plainManifest()))
    build()
    const call = wire()
    chosenCrx = path
    try {
      writeFileSync(path, packed.crx)
      const good = (await call('browser-extension:add-crx', PROFILE)) as {
        ok: boolean
        message: string
      }
      expect(good.ok, good.message).toBe(true)
      expect(good.message).toContain(packed.id)

      const bent = Buffer.from(packed.crx)
      bent[bent.length - 40] ^= 0xff
      writeFileSync(path, bent)
      const bad = (await call('browser-extension:add-crx', PROFILE)) as { ok: boolean; message: string }
      expect(bad.ok).toBe(false)
      expect(bad.message).toContain('Nothing was added')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('an extension’s settings page', () => {
  it('refuses with its own sentence when the extension has none', async () => {
    /*
     * The panel asks `optionsPage` before drawing the control, so this refusal
     * is a second line rather than the only one — but a caller that went round
     * the screen must get the same truth the screen gives.
     */
    build()
    const call = wire()
    await call('browser-extension:install', PROFILE, 'test')
    const result = (await call('browser-extension:options', PROFILE, 'test')) as {
      ok: boolean
      message: string
    }
    expect(result.ok).toBe(false)
    expect(result.message).toContain('no settings page of its own')
  })
})
