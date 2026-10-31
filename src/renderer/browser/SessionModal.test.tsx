import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The cookies dialog, which is now opened from a row in the profile menu.
 *
 * Held as source rather than as markup, and the reason is mechanical: `Modal`
 * portals into `document.body`, and this suite has no DOM to portal into —
 * `renderToStaticMarkup` throws on the first `createPortal`. The behaviour was
 * checked where it actually renders instead, in the running app: the dialog
 * opened from the *non-active* `Default` row while `Work` was switched on, and
 * reported `persist:terminaldeck-browser` and that profile's two cookies —
 * `review-2026-08-20/shots/browser-chrome/e7-live-03-sites-dialog.png`.
 *
 * What is pinned here is the copy, because copy is what comes back. Each of
 * these was a sentence on screen, and the rule he repeated more than any other
 * is that they should not be:
 *
 *   > *"don't put any single statement in anywhere … I don't want any kind of
 *   > long descriptions anywhere. Just if somewhere it's very required, give the
 *   > i icon like other ones."*
 */
const source = readFileSync(join(__dirname, 'SessionModal.tsx'), 'utf8')

/** Only the strings this file would put on screen — comments quote the old ones. */
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('the cookies dialog says nothing it does not have to', () => {
  it('does not explain itself under its own title', () => {
    // The sentence that stood here said where the data is kept and that it
    // survives a restart — both of which are rows in the list below it.
    expect(onScreen).not.toContain('separate from the app')
    expect(onScreen).not.toContain('across restarts')
  })

  it('puts the isolated-tab caveat behind the ⓘ every other pane uses', () => {
    expect(onScreen).toContain('HoverNote')
    expect(onScreen).not.toContain('there is nothing here to clear for it')
  })

  it('does not tell anybody how to get a cookie', () => {
    expect(onScreen).not.toContain('Sign in to a site')
  })

  it('does not ask the reader to report a bug', () => {
    expect(onScreen).not.toContain('tell someone')
  })

  it('names the profile it was opened for', () => {
    // Every profile row has its own door into this now — see `ProfileMenu`. One
    // title over four different jars is the ambiguity the *"we always need a
    // truth"* thread is about.
    expect(onScreen).toContain('Cookies and site data — ${profileName}')
  })

  it('carries the profile through every call it makes', () => {
    // A dialog titled `Work` whose Clear emptied `Default` would be worse than
    // the limitation it replaced.
    for (const call of [
      'browserSessionInfo(profileId)',
      'browserCookies(profileId)',
      'browserClearCookies(undefined, profileId)',
      'browserClearStorage(undefined, profileId)',
      'browserClearCache(profileId)',
      'browserClearCookies(domain.domain, profileId)',
      'browserClearStorage(domain.domain, profileId)',
    ]) {
      expect(onScreen).toContain(call)
    }
  })
})
