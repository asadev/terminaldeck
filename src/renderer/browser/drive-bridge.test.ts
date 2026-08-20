import { beforeEach, describe, expect, it } from 'vitest'
import {
  claimDriveOpen,
  driveAvailable,
  driveChipText,
  IDLE_DRIVE,
  readDriveOpen,
  readDriveStatus,
  resetDriveClaimsForTests,
  resolveDriveApi,
} from './drive-bridge'

beforeEach(() => {
  resetDriveClaimsForTests()
})

describe('one panel answers an open request, and only one', () => {
  it('lets the first caller through and nobody after', () => {
    /*
     * A browser page is a row in the sidebar, so several `BrowserWorkspace`
     * components can be mounted at once and the main process's push reaches
     * every one of them. Without this the copilot asking for one tab would open
     * one in each panel, and the main process would use the first reply — the
     * rest being pages nobody asked for, in panels nobody was looking at.
     */
    expect(claimDriveOpen('req-1')).toBe(true)
    expect(claimDriveOpen('req-1')).toBe(false)
    expect(claimDriveOpen('req-1')).toBe(false)
  })

  it('treats a second request as a second request', () => {
    expect(claimDriveOpen('req-1')).toBe(true)
    expect(claimDriveOpen('req-2')).toBe(true)
  })
})

describe('what crosses the bridge is narrowed before anything acts on it', () => {
  it('reads a well-formed open request', () => {
    expect(
      readDriveOpen({ id: 'a', url: 'https://x.test', isolate: true, pane: 'browser:1' }),
    ).toEqual({
      id: 'a',
      url: 'https://x.test',
      isolate: true,
      pane: 'browser:1',
    })
  })

  it('carries no pane when main named none, so an older main still opens a page', () => {
    // `pane` addresses the request at one panel. A main process that predates
    // the field names nobody, and the old first-to-answer behaviour is all
    // there is — a null here must not become the string "null" or a panel that
    // refuses everything.
    expect(readDriveOpen({ id: 'a', url: 'https://x.test', isolate: true })?.pane).toBeNull()
    expect(readDriveOpen({ id: 'a', url: 'https://x.test', pane: '' })?.pane).toBeNull()
    expect(readDriveOpen({ id: 'a', url: 'https://x.test', pane: 7 })?.pane).toBeNull()
  })

  it('refuses a request with nothing to open or nothing to answer', () => {
    // An older or newer main process must be a no-op in an effect, not a throw.
    expect(readDriveOpen({ url: 'https://x.test' })).toBeNull()
    expect(readDriveOpen({ id: 'a' })).toBeNull()
    expect(readDriveOpen({ id: '', url: 'https://x.test' })).toBeNull()
    expect(readDriveOpen(null)).toBeNull()
    expect(readDriveOpen('open please')).toBeNull()
  })

  it('defaults isolate to false rather than to whatever was sent', () => {
    // The isolated partition is a *narrower* thing than the shared one, so the
    // safe default is the one the person's own tabs use — anything else would
    // silently open a logged-out tab and report success.
    expect(readDriveOpen({ id: 'a', url: 'https://x.test' })?.isolate).toBe(false)
    expect(readDriveOpen({ id: 'a', url: 'https://x.test', isolate: 'yes' })?.isolate).toBe(false)
  })

  it('reads a status and refuses a state it does not know', () => {
    expect(readDriveStatus({ state: 'human', tabId: 't', step: '', prompt: 'sign in', url: 'https://x' })).toEqual({
      state: 'human',
      tabId: 't',
      step: '',
      prompt: 'sign in',
      url: 'https://x',
    })
    expect(readDriveStatus({ state: 'driving' })).toBeNull()
    expect(readDriveStatus(undefined)).toBeNull()
  })

  it('fills in the fields an older main process would not send', () => {
    expect(readDriveStatus({ state: 'agent' })).toEqual(IDLE_DRIVE_WITH('agent'))
  })
})

function IDLE_DRIVE_WITH(state: 'idle' | 'agent' | 'human') {
  return { ...IDLE_DRIVE, state }
}

describe('a half-wired preload is treated as no drive at all', () => {
  it('needs every one of the five methods', () => {
    // A banner that can be drawn but not answered is worse than no banner: it
    // is a page the person has been told to act on with no way to say they are
    // finished. The same bargain `isolationAvailable` makes.
    const full = {
      onBrowserDriveOpen: () => () => undefined,
      browserDriveOpened: () => undefined,
      browserDriveStatus: async () => null,
      onBrowserDriveState: () => () => undefined,
      browserDriveResume: () => undefined,
    }
    expect(driveAvailable(resolveDriveApi(full))).toBe(true)
    for (const name of Object.keys(full)) {
      const partial = { ...full } as Record<string, unknown>
      delete partial[name]
      expect(driveAvailable(resolveDriveApi(partial))).toBe(false)
    }
  })

  it('ignores anything on the host that is not a function', () => {
    const api = resolveDriveApi({ browserDriveResume: 'yes please', onBrowserDriveOpen: null })
    expect(driveAvailable(api)).toBe(false)
    expect(api.browserDriveResume).toBeUndefined()
  })

  it('answers empty for a host that is not an object', () => {
    expect(driveAvailable(resolveDriveApi(null))).toBe(false)
    expect(driveAvailable(resolveDriveApi(7))).toBe(false)
  })
})

describe('what the strip says', () => {
  it('says nothing at all when nothing is being driven', () => {
    expect(driveChipText(IDLE_DRIVE)).toBe('')
  })

  it('names the step in the present tense, because there is no cursor to watch', () => {
    // CDP input does not move the OS pointer and nothing HTML can be drawn over
    // a WebContentsView, so a driven click simply happens. This sentence is the
    // only feedback it has.
    expect(driveChipText({ ...IDLE_DRIVE, state: 'agent', step: 'clicking “Sign in”' })).toBe(
      'Copilot is clicking “Sign in”',
    )
  })

  it('falls back to a plain statement between steps', () => {
    expect(driveChipText({ ...IDLE_DRIVE, state: 'agent', step: '' })).toBe('Copilot is driving')
  })

  it('says whose turn it is, and not what the agent was doing', () => {
    expect(driveChipText({ ...IDLE_DRIVE, state: 'human', step: 'clicking “Sign in”' })).toBe('Your turn')
  })
})
