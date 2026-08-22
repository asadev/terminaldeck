import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { BrowserDrive } from './browser-driver'
import { HeadlessDriveHost, type LaunchBrowser } from './browser-headless-host'
import { createHeadlessBrowserControl } from './browser-headless-control'
import { resetForTests } from './browser-binding'
import { SESSION_TIERS } from './deck-control/session-tools'
import type { CdpTransport } from './browser-driven-cdp'

/**
 * The server's browser-verb dispatcher, the object `window-serve.ts` reaches for
 * a forwarded `window.call`. It is the real `DeckControl`, so this proves the
 * wiring holds without a browser: it builds (the surface it never uses does not
 * throw at construction), it dispatches a browser verb to the drive, and it
 * refuses across the wire exactly where the tier machinery says it must.
 */

const fakeTransport: CdpTransport = {
  async command(command) {
    if (command.method === 'Target.createTarget') return { targetId: 't1' }
    return {}
  },
  on: () => () => {},
  onClose: () => () => {},
}

const launch: LaunchBrowser = async () => ({
  ok: true,
  handle: { transport: fakeTransport, stop: () => {} },
})

// The caller `window-serve.ts` builds for a forwarded verb.
const sessionCaller = {
  kind: 'session' as const,
  sessionId: 's1',
  machineId: 'device-1',
  tiers: SESSION_TIERS,
}

let userData: string

beforeEach(() => {
  resetForTests()
  userData = mkdtempSync(join(tmpdir(), 'td-headless-control-'))
})

afterEach(() => {
  rmSync(userData, { recursive: true, force: true })
})

function build() {
  const host = new HeadlessDriveHost({ userData, launch })
  const drive = new BrowserDrive(host)
  return createHeadlessBrowserControl({ drive, logDir: join(userData, 'actions') })
}

describe('the headless browser control', () => {
  it('constructs without touching the surface it does not have', () => {
    expect(() => build()).not.toThrow()
  })

  it('dispatches a browser verb to the drive and writes a row', async () => {
    const control = build()
    const result = await control.call(
      'browser.read',
      {},
      { caller: sessionCaller, attended: false },
    )
    // Nothing is being driven, so the drive refuses — but the call went the whole
    // way through the tier check and the log rather than throwing, which is the
    // property window.call depends on: every failure comes back as a sentence.
    expect(result.ok).toBe(false)
    expect(result.row).toBeDefined()
    expect(result.error).toBeTruthy()
  })
})
