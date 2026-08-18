import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { LINK_TAB_CHANNEL } from './link-open'

/**
 * The push channel that carries a link into a tab, held against the preload
 * that has to be listening on it.
 *
 * ## Why this is worth a test of its own
 *
 * Because the identical mistake has already shipped once in this feature area.
 * `browser-view.ts` pushed on `browser-view:recording` while the preload
 * subscribed to `browser:recording`; both files read correctly, both
 * typechecked, and the flow recorder sat at one step across forty clicks
 * because `webContents.send` to a channel with no listener is a no-op and
 * `ipcRenderer.on` for a channel nobody sends is a no-op. The seam is
 * `unknown` by design, so there is nothing for the compiler to compare — see
 * `browser-view.channels.test.ts`, which is this test's older sibling.
 *
 * The failure here would be worse to diagnose than the recorder's, because it
 * is silent on both sides: clicking a repository would simply do nothing at
 * all, which reads as a dead button rather than as a broken channel.
 *
 * A source-text test, because the main process may not import the preload and
 * the preload may not import the main process. That boundary is right and this
 * does not cross it.
 */

const preload = readFileSync(join(__dirname, '..', 'preload', 'index.ts'), 'utf8')

/** Every channel the preload calls `ipcRenderer.on` for. */
const subscribed = [...preload.matchAll(/ipcRenderer\.on\(\s*'([^']+)'/g)].map((match) => match[1])

describe('a link reaches the renderer that has to open it', () => {
  it('the preload subscribes to the channel this module pushes on', () => {
    expect(subscribed, `preload does not listen on ${LINK_TAB_CHANNEL}`).toContain(LINK_TAB_CHANNEL)
  })

  it('reads a preload that really does register subscriptions', () => {
    // Guards the guard: a regex that matched nothing would make the case above
    // pass for a preload that had lost the line entirely.
    expect(subscribed.length).toBeGreaterThan(3)
  })

  it('every push in this module goes through the exported constant', () => {
    // The literal, not the constant: a rename that changed the export and left
    // a hardcoded string behind would pass the first case.
    const source = readFileSync(join(__dirname, 'link-open.ts'), 'utf8')
    const pushes = [...source.matchAll(/\.send\(\s*([A-Z_]+|'[^']+')/g)].map((m) => m[1])
    expect(new Set(pushes)).toEqual(new Set(['LINK_TAB_CHANNEL']))
  })
})

/**
 * The two callers, pinned as *call sites* rather than as behaviour.
 *
 * Their behaviour is covered by `link-open.test.ts` and `browser-tab.test.ts`.
 * What those cannot see is somebody quietly putting `shell.openExternal` back
 * into either handler, which is the exact line this change removed and the
 * exact shape of the bug Asad reported. Both files are large and both are
 * edited often.
 */
describe('nothing routes a link straight to the system browser again', () => {
  const read = (name: string): string => readFileSync(join(__dirname, name), 'utf8')

  it('the app shell’s window-open handler routes through openAppLink', () => {
    const index = read('index.ts')
    const handler = /setWindowOpenHandler\(\(\{ url \}\) => \{([\s\S]*?)\n  \}\)/.exec(index)
    expect(handler, 'index.ts has no window-open handler any more').not.toBeNull()
    expect(handler?.[1]).toContain('openAppLink')
    expect(handler?.[1], 'a link from the app shell must not go straight out').not.toContain(
      'openExternal',
    )
  })

  it('the guest’s window-open handler routes a link through openGuestLink', () => {
    const tab = read('browser-tab.ts')
    // The parameter is `details` rather than `{ url }` since sign-in pop-ups
    // started being routed on their disposition — the handler needs the frame
    // name and the features as well as the address. See `browser-popup.ts`.
    const handler = /setWindowOpenHandler\(\(details\) => \{([\s\S]*?)\n  \}\)/.exec(tab)
    expect(handler, 'browser-tab.ts has no window-open handler any more').not.toBeNull()
    expect(handler?.[1]).toContain('openGuestLink')
    // The refusal has to survive as well: it is what keeps a page from opening
    // anything that is not http(s).
    expect(handler?.[1]).toContain('fail(')
    expect(handler?.[1], 'a link from a guest page must not go straight out').not.toContain(
      'openExternal',
    )
  })

  /**
   * A pop-up is allowed, and that is the one thing that must not be undone by
   * somebody tidying the handler back to a single `deny`.
   *
   * The whole of the sign-in complaint in the 2026-08-17 review — the QR that
   * stopped, the stuck verification link — was `deny` making `window.open()`
   * return `null`. Reverting to it would look like a simplification and would
   * break every OAuth flow again, silently, because nothing throws.
   */
  it('a genuine sign-in pop-up is still allowed to become a real window', () => {
    const tab = read('browser-tab.ts')
    const handler = /setWindowOpenHandler\(\(details\) => \{([\s\S]*?)\n  \}\)/.exec(tab)
    expect(handler?.[1]).toContain('wantsPopupWindow')
    expect(handler?.[1]).toContain("action: 'allow'")
  })
})
