import { afterEach, describe, expect, it } from 'vitest'
import { CONFINE_GRANT, CONFINE_STATE, CONFINE_WITHDRAW, registerConfineIpc } from './ipc'
import { installWindowsTools, resetWindowsTools } from './tools'

/**
 * The button that decides whether a Windows session is held inside its folder.
 *
 * Everything under it was built and measured long before this file existed;
 * what was missing was a caller, and the consequence was not subtle — on every
 * Windows machine `confinementKind` answered `'none'`, so a session started
 * from a paired phone ran as the full user account. The tests here are about
 * the three properties that make the button honest rather than decorative:
 *
 *  1. **It describes before it performs.** Asking for the state must not
 *     elevate anything, on any platform.
 *  2. **It answers from the store, not from the press.** A person who dismisses
 *     the administrator prompt must see the screen stay exactly as it was.
 *  3. **macOS is confined without it**, and asking for a grant there is a
 *     no-op rather than an error — seatbelt needs no permission from anybody,
 *     which is why only one of the two platforms ever needed a button.
 */

function harness(overrides: Parameters<typeof registerConfineIpc>[1]) {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  registerConfineIpc({ handle: (name, fn) => void handlers.set(name, fn) }, overrides)
  return {
    state: () => handlers.get(CONFINE_STATE)?.(null) as { confining: boolean; canGrant: boolean; folders: string[]; note: string },
    grant: () => handlers.get(CONFINE_GRANT)?.(null) as Promise<{ result: { ok: boolean } | null; state: { confining: boolean } }>,
    withdraw: () => handlers.get(CONFINE_WITHDRAW)?.(null) as Promise<{ ok: boolean; state: { confining: boolean } }>,
    channels: () => [...handlers.keys()],
  }
}

const NOTHING = { path: () => '', accountHome: () => '/home/x' }

afterEach(() => {
  resetWindowsTools()
})

describe('describing the grant without performing it', () => {
  it('registers on every platform, so a window has one failure to tell apart instead of two', () => {
    // Not `if (win32)` around the registration. A channel that exists on one
    // platform and is missing on another gives the renderer "this build is too
    // old" and "this is a Mac" as the same symptom, when only one is true and
    // neither is interesting.
    const mac = harness({ ...NOTHING, platform: 'darwin' })
    expect(mac.channels().sort()).toEqual([CONFINE_GRANT, CONFINE_STATE, CONFINE_WITHDRAW].sort())
  })

  it('says a Mac is already holding sessions, with nothing granted', () => {
    // Seatbelt confines a process with no prior permission from anybody. That
    // asymmetry is the whole reason only Windows needed a button.
    const mac = harness({ ...NOTHING, platform: 'darwin' })
    expect(mac.state()).toMatchObject({ confining: true, canGrant: false })
  })

  it('reads Windows from the record on disk rather than from a constant', () => {
    installWindowsTools({ launcher: 'C:\\td\\tdconfine.exe', recordFile: 'C:\\td\\grant.json' })
    const before = harness({ ...NOTHING, platform: 'win32', ready: () => false })
    expect(before.state()).toMatchObject({ confining: false, canGrant: true })

    const after = harness({ ...NOTHING, platform: 'win32', ready: () => true })
    expect(after.state().confining).toBe(true)
  })

  it('cannot offer a grant on a build with no launcher', () => {
    // A development checkout before `build.ps1` has run. A button there is a
    // control that cannot act, which this app removes rather than greys.
    const noLauncher = harness({ ...NOTHING, platform: 'win32', ready: () => false })
    expect(noLauncher.state().canGrant).toBe(false)
  })

  it('never elevates just to answer what the grant would cover', async () => {
    installWindowsTools({ launcher: 'C:\\td\\tdconfine.exe', recordFile: 'C:\\td\\grant.json' })
    let elevated = 0
    const app = harness({
      ...NOTHING,
      platform: 'win32',
      ready: () => false,
      establish: async () => {
        elevated += 1
        return { ok: true, detail: '', grant: { read: [], ancestors: [] }, prompted: true }
      },
    })
    app.state()
    app.state()
    expect(elevated).toBe(0)
  })
})

describe('performing it', () => {
  it('answers with the state read afterwards, not with the press', async () => {
    /*
     * The property that stops this screen lying. `establishToolGrant` elevates,
     * and a person can dismiss the UAC dialog — at which point the honest
     * screen is the one that has not changed. Believing the button instead is
     * how a settings pane ends up promising a boundary nobody granted.
     */
    installWindowsTools({ launcher: 'C:\\td\\tdconfine.exe', recordFile: 'C:\\td\\grant.json' })
    const refused = harness({
      ...NOTHING,
      platform: 'win32',
      ready: () => false,
      establish: async () => ({
        ok: false,
        detail: 'the administrator prompt was dismissed',
        grant: { read: [], ancestors: [] },
        prompted: true,
      }),
    })
    const answer = await refused.grant()
    expect(answer.result?.ok).toBe(false)
    expect(answer.state.confining).toBe(false)
  })

  it('reports the machine holding sessions once the record is there', async () => {
    installWindowsTools({ launcher: 'C:\\td\\tdconfine.exe', recordFile: 'C:\\td\\grant.json' })
    let granted = false
    const app = harness({
      ...NOTHING,
      platform: 'win32',
      ready: () => granted,
      establish: async () => {
        granted = true
        return { ok: true, detail: '', grant: { read: ['C:\\node'], ancestors: [] }, prompted: true }
      },
    })
    expect(app.state().confining).toBe(false)
    const answer = await app.grant()
    expect(answer.result?.ok).toBe(true)
    expect(answer.state.confining).toBe(true)
  })

  it('does nothing at all on a Mac, and does not call it a failure', async () => {
    let elevated = 0
    const mac = harness({
      ...NOTHING,
      platform: 'darwin',
      establish: async () => {
        elevated += 1
        return { ok: true, detail: '', grant: { read: [], ancestors: [] }, prompted: true }
      },
    })
    const answer = await mac.grant()
    expect(elevated).toBe(0)
    expect(answer.result).toBeNull()
    // Still confined, because it always was.
    expect(answer.state.confining).toBe(true)
  })

  it('withdraws, and reports what the machine says afterwards', async () => {
    installWindowsTools({ launcher: 'C:\\td\\tdconfine.exe', recordFile: 'C:\\td\\grant.json' })
    let granted = true
    const app = harness({
      ...NOTHING,
      platform: 'win32',
      ready: () => granted,
      withdraw: async () => {
        granted = false
        return { ok: true, detail: '' }
      },
    })
    expect(app.state().confining).toBe(true)
    const answer = await app.withdraw()
    expect(answer.ok).toBe(true)
    expect(answer.state.confining).toBe(false)
  })
})
