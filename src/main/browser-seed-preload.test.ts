import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  frameOrigin,
  GUEST_SEED_CHANNEL,
  GUEST_SEED_FILENAME,
  GUEST_SEED_SOURCE,
  writeSeedPreload,
} from './browser-seed-preload'

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-seed-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the script that writes stored keys into a worker', () => {
  it('carries no secret of its own, because a preload is a file on disk', () => {
    /*
     * The rule the whole lift is built on: a live session token never reaches a
     * file. If the seed were baked into this script, `<userData>` would hold a
     * credential for anybody with the folder — the exact thing
     * `browser-session-lift.ts` keeps out of a store, a log and an IPC reply.
     * So the script asks, and the main process answers from memory, once.
     */
    expect(GUEST_SEED_SOURCE).toContain(GUEST_SEED_CHANNEL)
    expect(GUEST_SEED_SOURCE).toContain('ipc.invoke(CH)')
  })

  it('tells the main process nothing about where it is', () => {
    /*
     * `ipc.invoke(CH)` and no arguments. The partition and the origin are read
     * off `event.sender` and `event.senderFrame` in `browser-workers-ipc.ts`,
     * which are Chromium's facts about the frame rather than the frame's claims
     * about itself. A page cannot reach `ipcRenderer` today — it is in the
     * isolated world — but a design whose only protection is that fact is one
     * bad Electron release away from handing a token to whoever asked politely.
     */
    expect(GUEST_SEED_SOURCE).not.toMatch(/ipc\.invoke\(CH,/)
    expect(GUEST_SEED_SOURCE).not.toContain('location.origin')
  })

  it('never opens anything, and never navigates', () => {
    // Item 11, at the smallest scale. The whole point of seeding through a
    // preload is that the person's own visible page load applies it; a script
    // that could navigate would be a hidden crawl in three lines.
    expect(GUEST_SEED_SOURCE).not.toContain('window.open')
    expect(GUEST_SEED_SOURCE).not.toContain('location.href')
    expect(GUEST_SEED_SOURCE).not.toContain('fetch(')
  })

  it('keeps going when one key will not go in', () => {
    // Quota, or storage disabled for an origin. One key that throws must not
    // take the rest of a login with it.
    expect(GUEST_SEED_SOURCE).toContain('store.setItem(pair[0], pair[1])')
    expect((GUEST_SEED_SOURCE.match(/try \{/g) ?? []).length).toBeGreaterThanOrEqual(4)
  })
})

describe('writing it out', () => {
  it('lands at a stable name, replaces what was there and is 0600', () => {
    const path = writeSeedPreload(dir)
    expect(path).toBe(join(dir, GUEST_SEED_FILENAME))
    expect(readFileSync(path, 'utf8')).toBe(GUEST_SEED_SOURCE)
    if (process.platform !== 'win32') {
      expect(statSync(path).mode & 0o777).toBe(0o600)
    }
    // Twice, because `wx` refuses an existing path and an older build's script
    // must not be what a new build runs.
    expect(() => writeSeedPreload(dir)).not.toThrow()
  })
})

describe('the origin a frame is allowed to be seeded for', () => {
  it('is derived from the frame’s own url', () => {
    expect(frameOrigin('https://shop.example.com/a/b?c=1')).toBe('https://shop.example.com')
    expect(frameOrigin('http://localhost:3000/x')).toBe('http://localhost:3000')
  })

  it('is nothing at all for a frame with no origin worth seeding', () => {
    // `''` matches no seed key that can exist, so each of these is refused by
    // the lookup rather than by a second rule somebody has to remember.
    for (const url of ['about:blank', 'data:text/html,x', 'file:///etc/passwd', '', undefined, 7]) {
      expect(frameOrigin(url)).toBe('')
    }
  })
})
