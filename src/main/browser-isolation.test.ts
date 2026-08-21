import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { describe, expect, it, vi } from 'vitest'

/**
 * The claims about Electron's own behaviour — that a bare partition name is
 * in-memory, that the same name returns the same session and that two isolated
 * partitions cannot see each other's cookies — were checked against a real
 * Electron 41.10.5 run and are recorded in the module's own comment. They cannot
 * be checked here, because `session` is a stub.
 *
 * What *is* checkable here is everything this module decides for itself, and it
 * is all one bug away from an "isolated" tab that is not: a key that slipped
 * through with a `persist:` prefix, two tabs sharing a partition, a partition
 * that skipped the hardening the shared one gets.
 */

interface FakeSession {
  partition: string
  permissionRequestHandler: unknown
  permissionCheckHandler: unknown
  events: string[]
  preloads: unknown[]
  cleared: number
}

const created = new Map<string, FakeSession>()

function fakeSession(partition: string): FakeSession {
  const existing = created.get(partition)
  if (existing) return existing
  const ses: FakeSession = {
    partition,
    permissionRequestHandler: null,
    permissionCheckHandler: null,
    events: [],
    preloads: [],
    cleared: 0,
  }
  Object.assign(ses, {
    setPermissionRequestHandler: (fn: unknown) => {
      ses.permissionRequestHandler = fn
    },
    setPermissionCheckHandler: (fn: unknown) => {
      ses.permissionCheckHandler = fn
    },
    on: (event: string) => {
      ses.events.push(event)
      return ses
    },
    registerPreloadScript: (options: unknown) => {
      ses.preloads.push(options)
      return 'preload-id'
    },
    clearStorageData: async () => {
      ses.cleared += 1
    },
  })
  created.set(partition, ses)
  return ses
}

vi.mock('electron', () => ({
  app: { getPath: () => mkdtempSync(join(tmpdir(), 'terminaldeck-isolation-test-')) },
  session: { fromPartition: (partition: string) => fakeSession(partition) },
}))

const {
  ISOLATED_PREFIX,
  disposeAllIsolatedSessions,
  disposeIsolatedSession,
  isIsolatedGuestSession,
  isIsolationKey,
  isolatedSession,
  isolatedSessionCount,
  newIsolationKey,
  registerBrowserIsolationIpc,
} = await import('./browser-isolation')

/* -------------------------------------------------------------------- keys -- */

describe('isolation keys', () => {
  it('mints a key that is not a persistent partition', () => {
    const key = newIsolationKey()
    expect(key.startsWith(ISOLATED_PREFIX)).toBe(true)
    // The one character that would quietly put an "isolated" tab on disk.
    expect(key.startsWith('persist:')).toBe(false)
    expect(key).not.toContain('persist:')
    expect(isIsolationKey(key)).toBe(true)
  })

  it('mints a different key every time, so two isolated tabs never share one', () => {
    const keys = new Set(Array.from({ length: 50 }, () => newIsolationKey()))
    expect(keys.size).toBe(50)
  })

  it('refuses a key the renderer made up', () => {
    // A partition name is a string Electron creates *anything* for, including a
    // persistent one, so nothing off the wire is taken at face value.
    expect(isIsolationKey('persist:terminaldeck-browser')).toBe(false)
    expect(isIsolationKey(`persist:${ISOLATED_PREFIX}whatever`)).toBe(false)
    expect(isIsolationKey(`${ISOLATED_PREFIX}not-a-uuid`)).toBe(false)
    expect(isIsolationKey(`${ISOLATED_PREFIX}${'0'.repeat(36)}`)).toBe(false)
    expect(isIsolationKey('')).toBe(false)
    expect(isIsolationKey(null)).toBe(false)
    expect(isIsolationKey(42)).toBe(false)
  })
})

/* ---------------------------------------------------------------- sessions -- */

describe('isolatedSession', () => {
  it('returns null when no key was asked for, so the caller falls back to shared', () => {
    expect(isolatedSession(undefined)).toBeNull()
    expect(isolatedSession(null)).toBeNull()
    expect(isolatedSession('persist:terminaldeck-browser')).toBeNull()
  })

  it('gives one session per key and reuses it for the same tab', () => {
    const key = newIsolationKey()
    const first = isolatedSession(key)
    expect(first).not.toBeNull()
    expect(isolatedSession(key)).toBe(first)
    expect(isolatedSession(newIsolationKey())).not.toBe(first)
  })

  it('hardens an isolated partition exactly as the shared one is hardened', () => {
    const key = newIsolationKey()
    isolatedSession(key)
    const ses = created.get(key)
    expect(ses).toBeDefined()
    expect(typeof ses?.permissionRequestHandler).toBe('function')
    expect(typeof ses?.permissionCheckHandler).toBe('function')
    /*
     * `will-download` used to be a refusal here and is now the downloads module
     * taking the event — `browser-downloads.ts` explains why a download is not
     * one of the permissions the two handlers above refuse. What this assertion
     * has always pinned is the same either way and is the reason it exists: an
     * isolated tab must behave like every other tab. A build where only the
     * shared partition subscribed would download from an ordinary tab and do
     * nothing at all from an isolated one, silently, which is the shape of
     * defect the whole 2026-08-21 review is about.
     */
    expect(ses?.events).toContain('will-download')
  })

  it('registers the recorder preload, or recording dies the moment a tab is isolated', () => {
    const key = newIsolationKey()
    isolatedSession(key)
    expect(created.get(key)?.preloads).toEqual([
      { type: 'frame', filePath: expect.stringContaining('browser-record-preload.js') },
    ])
  })

  it('refuses every permission a guest page can ask for', () => {
    const key = newIsolationKey()
    isolatedSession(key)
    const ses = created.get(key)
    let answered: unknown = 'not called'
    ;(ses?.permissionRequestHandler as (a: unknown, b: unknown, cb: (v: boolean) => void) => void)(
      null,
      'media',
      (value) => {
        answered = value
      },
    )
    expect(answered).toBe(false)
    expect((ses?.permissionCheckHandler as () => boolean)()).toBe(false)
  })
})

describe('isIsolatedGuestSession', () => {
  it('recognises a partition this module handed out and nothing else', () => {
    const key = newIsolationKey()
    const ses = isolatedSession(key)
    expect(ses).not.toBeNull()
    if (!ses) return
    expect(isIsolatedGuestSession(ses)).toBe(true)
    // browser-view.ts leans on this to claim isolated views; a false here is a
    // tab with no zoom, no screenshots and no recording, and no error anywhere.
    expect(isIsolatedGuestSession({} as never)).toBe(false)
  })
})

describe('disposal', () => {
  it('clears a partition and forgets it', async () => {
    const key = newIsolationKey()
    const before = isolatedSessionCount()
    isolatedSession(key)
    expect(isolatedSessionCount()).toBe(before + 1)

    await disposeIsolatedSession(key)
    expect(created.get(key)?.cleared).toBe(1)
    expect(isolatedSessionCount()).toBe(before)
  })

  it('ignores a key it never handed out', async () => {
    await expect(disposeIsolatedSession('persist:terminaldeck-browser')).resolves.toBeUndefined()
    await expect(disposeIsolatedSession(newIsolationKey())).resolves.toBeUndefined()
  })

  it('empties the whole registry on quit', async () => {
    isolatedSession(newIsolationKey())
    isolatedSession(newIsolationKey())
    await disposeAllIsolatedSessions()
    expect(isolatedSessionCount()).toBe(0)
  })
})

/* ------------------------------------------------------------------- ipc -- */

describe('registerBrowserIsolationIpc', () => {
  it('registers every channel with handle, so the preload must use invoke', () => {
    const channels: string[] = []
    registerBrowserIsolationIpc({
      handle: (channel: string) => {
        channels.push(channel)
      },
    } as unknown as IpcMain)
    expect(channels.sort()).toEqual([
      'browser-isolation:count',
      'browser-isolation:dispose',
      'browser-isolation:key',
    ])
  })

  it('hands the renderer a key it will accept back', async () => {
    const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    registerBrowserIsolationIpc({
      handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        handlers.set(channel, fn)
      },
    } as unknown as IpcMain)

    const key = (await handlers.get('browser-isolation:key')?.({})) as string
    expect(isIsolationKey(key)).toBe(true)
    expect(isolatedSession(key)).not.toBeNull()
    await handlers.get('browser-isolation:dispose')?.({}, key)
    expect(created.get(key)?.cleared).toBe(1)
  })
})
