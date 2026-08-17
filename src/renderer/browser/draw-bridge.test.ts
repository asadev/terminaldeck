import { describe, expect, it } from 'vitest'
import { BRIDGE_METHODS } from './bridge'
import { drawAvailable, readFrame, readMarkedShot, resolveDrawApi } from './draw-bridge'

/**
 * Draw mode's two methods are optional, and this is the test that keeps them so.
 *
 * The failure being guarded is not subtle. `resolveBrowserBridge` returns null
 * when any name in `BRIDGE_METHODS` is missing, and the workspace then renders
 * "The browser is not connected" *instead of the browser*. Adding these two to
 * that list would blank the entire panel on every build whose preload had not
 * caught up — which includes the one running while this was written.
 */

describe('the required-bridge list', () => {
  it('does not contain draw mode’s methods', () => {
    expect(BRIDGE_METHODS as readonly string[]).not.toContain('browserFrame')
    expect(BRIDGE_METHODS as readonly string[]).not.toContain('browserScreenshotMarked')
  })
})

describe('resolving the optional half', () => {
  it('finds both methods on a preload that has them', () => {
    const host = {
      browserFrame: async () => ({}),
      browserScreenshotMarked: async () => ({}),
    }
    expect(drawAvailable(resolveDrawApi(host))).toBe(true)
  })

  it('is unavailable when either half is missing', () => {
    // Not one-sided, unlike isolation's: a canvas you cannot send is worse than
    // no Draw button, because opening it takes the page away.
    expect(drawAvailable(resolveDrawApi({ browserFrame: async () => ({}) }))).toBe(false)
    expect(drawAvailable(resolveDrawApi({ browserScreenshotMarked: async () => ({}) }))).toBe(false)
    expect(drawAvailable(resolveDrawApi({}))).toBe(false)
    expect(drawAvailable(resolveDrawApi(null))).toBe(false)
  })

  it('calls through the host rather than tearing the method off it', async () => {
    // A detached method loses `this`, and the failure then shows up at the first
    // click instead of at mount.
    const host = {
      id: 'kept',
      browserFrame(this: { id: string }, tab: string): Promise<unknown> {
        return Promise.resolve({ image: 'data:image/png;base64,x', width: 2, height: 1, url: this.id + tab })
      },
      browserScreenshotMarked: async () => ({}),
    }
    const api = resolveDrawApi(host)
    expect(readFrame(await api.browserFrame?.('-1'))?.url).toBe('kept-1')
  })
})

describe('reading what the main process sent', () => {
  it('accepts a real frame', () => {
    expect(
      readFrame({ image: 'data:image/png;base64,AA', width: 2000, height: 1250, url: 'http://x/' }),
    ).toEqual({ image: 'data:image/png;base64,AA', width: 2000, height: 1250, url: 'http://x/' })
  })

  it('refuses a frame with nothing to draw on', () => {
    // Each of these would otherwise reach a canvas as `undefined` and paint a
    // blank rectangle that looks exactly like a page that failed to load.
    expect(readFrame(null)).toBeNull()
    expect(readFrame({ width: 10, height: 10 })).toBeNull()
    expect(readFrame({ image: 'http://example.com/x.png', width: 10, height: 10 })).toBeNull()
    expect(readFrame({ image: 'data:image/png;base64,AA', width: 0, height: 10 })).toBeNull()
    expect(readFrame({ image: 'data:image/png;base64,AA', width: NaN, height: 10 })).toBeNull()
  })

  it('accepts a missing URL, because a page can genuinely be at none', () => {
    expect(readFrame({ image: 'data:image/png;base64,AA', width: 4, height: 4 })?.url).toBe('')
  })

  it('refuses a saved shot with no path, which is the one field with no default', () => {
    expect(readMarkedShot({ width: 10, height: 10, url: 'http://x/' })).toBeNull()
    expect(readMarkedShot({ path: '' })).toBeNull()
    expect(readMarkedShot(undefined)).toBeNull()
  })

  it('keeps a saved shot whose size did not survive, rather than losing the file', () => {
    // The path is what Reveal opens and what the agent is told to look at. A
    // missing width is a worse label, not a lost screenshot.
    expect(readMarkedShot({ path: '/tmp/a-marked.png' })).toEqual({
      path: '/tmp/a-marked.png',
      width: 0,
      height: 0,
      url: '',
    })
  })
})
