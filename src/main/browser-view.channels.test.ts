import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { FIND_CHANNEL, KEY_CHANNEL, PROGRESS_CHANNEL, RECORDING_CHANNEL } from './browser-view'

/**
 * The two push channels, held against the preload that listens on them.
 *
 * ## The bug this exists for
 *
 * `browser-view.ts` pushed on `browser-view:recording` and
 * `browser-view:progress`. `src/preload/index.ts` subscribed to
 * `browser:recording` and `browser:progress`. Neither side can see the other:
 * `webContents.send` to a channel with no listener is a no-op, and
 * `ipcRenderer.on` for a channel nobody sends is a no-op. Both files read
 * correctly on their own, both typecheck, and every unit test on both sides
 * passes — the seam is `unknown` by design, so there is nothing for the compiler
 * to compare.
 *
 * What it produced, on camera on 2026-08-16: a Flow counter stuck at `Flow (1)`
 * across about forty clicks. The one step it had was the opening `Go <url>`,
 * which arrives as the *return value* of the record invoke; every step after it
 * travels by push and none of them ever landed. The page's load-progress bar was
 * dead for the same reason and nobody had ever noticed.
 *
 * ## Why this is a source-text test
 *
 * The main process may not import the preload and the preload may not import the
 * main process — that boundary is right and this test does not cross it. It
 * reads the preload as text and looks for the channel names in the subscriptions
 * it actually registers, which is the only place the truth lives.
 */

const preload = readFileSync(join(__dirname, '..', 'preload', 'index.ts'), 'utf8')

/** Every channel the preload calls `ipcRenderer.on` for. */
function subscribedChannels(source: string): string[] {
  return [...source.matchAll(/ipcRenderer\.on\(\s*'([^']+)'/g)].map((match) => match[1])
}

describe('the browser’s push channels reach the renderer', () => {
  const channels = subscribedChannels(preload)

  it('the preload subscribes to the recording channel this module pushes on', () => {
    expect(channels, `preload does not listen on ${RECORDING_CHANNEL}`).toContain(RECORDING_CHANNEL)
  })

  it('the preload subscribes to the progress channel this module pushes on', () => {
    expect(channels, `preload does not listen on ${PROGRESS_CHANNEL}`).toContain(PROGRESS_CHANNEL)
  })

  it('the preload subscribes to the find channel, or the match count never lands', () => {
    // The exact failure shape recording had: a bar that draws, a count frozen
    // at nothing, and both sides individually correct.
    expect(channels, `preload does not listen on ${FIND_CHANNEL}`).toContain(FIND_CHANNEL)
  })

  it('the preload subscribes to the page-chord channel, or ⌘F inside a page does nothing', () => {
    expect(channels, `preload does not listen on ${KEY_CHANNEL}`).toContain(KEY_CHANNEL)
  })

  it('nothing in this module still pushes on the old names', () => {
    // The literals, not the constants: a rename that changed one call site and
    // left the other would pass the cases above.
    const source = readFileSync(join(__dirname, 'browser-view.ts'), 'utf8')
    const pushes = [...new Set([...source.matchAll(/send\(entry,\s*([A-Z_]+|'[^']+')/g)].map((m) => m[1]))]
    expect(pushes.sort()).toEqual([
      'FIND_CHANNEL',
      'KEY_CHANNEL',
      'PROGRESS_CHANNEL',
      'RECORDING_CHANNEL',
    ])
  })

  it('reads a preload that really does register subscriptions', () => {
    // If the regex above ever stops matching — the preload is reformatted, the
    // subscriptions move behind a helper — every case here would pass by finding
    // nothing. This is the case that fails instead.
    expect(channels.length).toBeGreaterThan(5)
    expect(channels).toContain('session:data')
  })
})
