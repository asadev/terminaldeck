import { describe, expect, it } from 'vitest'
import { BrowserDrive, boundKey, describeStep } from './browser-driver'

/**
 * The parts of the driver a test can hold still.
 *
 * The actionability loop, the input dispatch and the isolated-world reads are
 * all facts about a live page, and they are exercised against real websites by
 * `scripts/check-browser-drive.mjs`. What is here is what the driver decides
 * without a page: how it labels a step, and how it lets go of a window the
 * person disconnected.
 *
 * Nothing here needs Electron mocked. The driver stopped importing it when the
 * `DrivenPage` seam was extracted — the Electron half lives in
 * `browser-driven-electron.ts`, and the PNG masking, which used to sit here, is
 * `browser-png.ts`'s and is tested in `browser-png.test.ts`.
 */

describe('what the person sees the drive doing', () => {
  it('names the element the way it is labelled on screen', () => {
    // The only feedback a driven click has: CDP input does not move the OS
    // pointer, and nothing HTML can be drawn over a WebContentsView, so there
    // is no cursor to watch.
    expect(describeStep('click', 'Sign in', '#go')).toBe('clicking “Sign in”')
    expect(describeStep('type', 'Email', 'input#email')).toBe('typing into “Email”')
    expect(describeStep('submit', '', 'form#login')).toBe('submitting form#login')
  })

  it('falls back to the selector when the element has no name', () => {
    expect(describeStep('click', '   ', 'button.icon')).toBe('clicking button.icon')
  })
})

/**
 * Disconnect, from the driver's end.
 *
 *   > *"we should be have a button here to disconnect also, or it should only
 *   > this way."*
 *
 * "Only this way" is what these pin. The relation and the drive are two objects
 * in two modules, and the control is meant to be one act: `browser-binding-ipc`
 * ends the binding and calls in here with the shell tab id, which is the only
 * handle it has. So the key that files a window's slot has to be one spelling
 * and it has to be reachable from a shell tab id alone.
 */
describe('letting go of a window the person disconnected', () => {
  /** Enough `DriveHost` to hold a slot. Nothing here opens or steers a page. */
  const host = {
    openTab: async () => null,
    contentsFor: () => null,
    publish: () => undefined,
    now: () => 1_000,
  }

  const target = (browserTabId: string) => ({
    key: boundKey(browserTabId),
    viewId: `view:${browserTabId}`,
    browserTabId,
    name: 'B1',
  })

  it('files a window under one key, spelled in one place', () => {
    // `browser-tools.ts` mints its targets with this, and `releaseWindow` looks
    // them up with it. Two copies is a drive that keeps running under a key
    // nobody matched.
    expect(boundKey('browser:1:1')).toBe('bound:browser:1:1')
  })

  it('forgets what that window had been granted', () => {
    const drive = new BrowserDrive(host)
    const window = target('browser:1:1')
    drive.noteOriginGranted('https://app.example.com', window)
    expect(drive.originGranted('https://app.example.com', window)).toBe(true)

    drive.releaseWindow('browser:1:1')

    // A window that is nobody's carries nobody's permission. Reconnecting it
    // asks again, which is the point of the control being the truth.
    expect(drive.originGranted('https://app.example.com', window)).toBe(false)
    expect(drive.driving()).toEqual([])
  })

  it('leaves every other window alone', () => {
    const drive = new BrowserDrive(host)
    drive.noteOriginGranted('https://a.example.com', target('browser:1:1'))
    drive.noteOriginGranted('https://b.example.com', target('browser:1:2'))

    drive.releaseWindow('browser:1:1')

    expect(drive.originGranted('https://b.example.com', target('browser:1:2'))).toBe(true)
  })

  it('says nothing about a window it was never holding', () => {
    // The ordinary case: disconnecting a window no agent has ever driven.
    const drive = new BrowserDrive(host)
    expect(() => drive.releaseWindow('browser:9:9')).not.toThrow()
  })
})
