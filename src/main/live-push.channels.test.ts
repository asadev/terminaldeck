import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  PREFS_CHANGED_CHANNEL,
  SESSION_REMOVED_CHANNEL,
  SETTINGS_CHANGED_CHANNEL,
} from './live-push'

/**
 * The three pushes, held against the preload that has to be listening.
 *
 * Same test as `browser-view.channels.test.ts` and for the same reason, which
 * that file records in full: `webContents.send` to a channel with no listener is
 * a no-op and `ipcRenderer.on` for a channel nobody sends is a no-op, the seam is
 * `unknown` by design, and both files read correctly on their own while the
 * feature is dead. That cost a week of a browser progress bar that never moved.
 *
 * These three exist because the same class of failure was found twice in one
 * audit — a theme written to disk that never reached the window, and a session
 * stopped in the main process whose row stayed in the sidebar — so they get the
 * guard on the day they are written rather than after the second time.
 *
 * A source-text test, because the main process may not import the preload and
 * the preload may not import the main process. That boundary is right and this
 * does not cross it: it reads the preload as text and looks for the channel names
 * in the subscriptions it actually registers, which is the only place the truth
 * lives.
 */

const preload = readFileSync(join(__dirname, '..', 'preload', 'index.ts'), 'utf8')

/** Every channel the preload calls `ipcRenderer.on` for. */
function subscribedChannels(source: string): string[] {
  return [...source.matchAll(/ipcRenderer\.on\(\s*'([^']+)'/g)].map((match) => match[1])
}

describe('the pushes that tell a window about a change it did not make', () => {
  const channels = subscribedChannels(preload)

  it('the preload listens for a preference changed from outside the window', () => {
    expect(channels, `preload does not listen on ${PREFS_CHANGED_CHANNEL}`).toContain(
      PREFS_CHANGED_CHANNEL,
    )
  })

  it('the preload listens for a setting changed from outside the window', () => {
    expect(channels, `preload does not listen on ${SETTINGS_CHANGED_CHANNEL}`).toContain(
      SETTINGS_CHANGED_CHANNEL,
    )
  })

  it('the preload listens for a session this app has stopped holding', () => {
    expect(channels, `preload does not listen on ${SESSION_REMOVED_CHANNEL}`).toContain(
      SESSION_REMOVED_CHANNEL,
    )
  })

  it('removal is its own channel, and is not confused with a process exiting', () => {
    /*
     * The distinction the whole fix rests on. A session that ends on its own
     * keeps its place in the manager, keeps its scrollback, and keeps its tab —
     * somebody wants to read what it printed. Reusing `session:exit` to mean
     * "take the row away" would delete the pane a person is reading the moment
     * their agent finished.
     */
    expect(SESSION_REMOVED_CHANNEL).not.toBe('session:exit')
    expect(channels).toContain('session:exit')
  })

  it('reads a preload that really does register subscriptions', () => {
    // If the regex above ever stops matching — the preload is reformatted, the
    // subscriptions move behind a helper — every case here would pass by finding
    // nothing. This is the case that fails instead.
    expect(channels.length).toBeGreaterThan(5)
    expect(channels).toContain('session:data')
  })

  it('the window is told by the main process, on those exact names', () => {
    // The senders, not just the listeners: a rename that changed the preload and
    // left `index.ts` pushing the old string would pass every case above.
    const main = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    expect(main).toContain('SESSION_REMOVED_CHANNEL')
    const surface = readFileSync(join(__dirname, 'deck-control', 'live-surface.ts'), 'utf8')
    expect(surface).toContain('SETTINGS_CHANGED_CHANNEL')
    expect(surface).toContain('PREFS_CHANGED_CHANNEL')
  })
})
