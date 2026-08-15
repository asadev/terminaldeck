import { describe, expect, it, vi } from 'vitest'
import { remoteSessionCreator, remoteSessionStart, type SessionStarter } from './session-create'
import type { SessionMeta } from '../../shared/types'

/**
 * The one decision in starting a session from a phone: which folder.
 *
 * Everything else — PATH, provider detection, the profile's config directory,
 * the PTY itself — is the desktop's existing `session:create` path and is
 * exercised by starting the app. What is worth a test here is the rule, and
 * specifically its two failure modes, which pull in opposite directions:
 * accepting a path nobody offered, and *silently substituting* the default for
 * one it will not accept. The second is the dangerous one — a New Session that
 * quietly starts somewhere else is a command typed into the wrong project.
 *
 * Since folders became per device there is a third: answering one device with
 * another device's list. That one is checked here at the level this file owns —
 * the id reaching `folders()` — and end to end against a real grant store in
 * `folder-grants.test.ts`.
 */

const META: SessionMeta = {
  id: 'sess-new',
  cwd: '/Users/apple/Projects/terminaldeck',
  title: 'terminaldeck',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_760_000_000_000,
}

/** The device asking, when a test does not care which one it is. */
const PHONE = 'device-phone'

function starter(overrides: Partial<SessionStarter> = {}): SessionStarter & { spawn: ReturnType<typeof vi.fn> } {
  const spawn = vi.fn(async (input: { cwd: string; cols: number; rows: number }) => ({ ...META, cwd: input.cwd }))
  const base: SessionStarter = {
    folders: () => ['/Users/apple/Projects/terminaldeck', '/Users/apple/Projects/imza'],
    spawn,
  }
  // Kept after the spread so a test overriding `folders` still gets the spy,
  // and so the returned object's `spawn` is the same function the test asserts
  // against rather than a second one.
  return { ...base, ...overrides, spawn: overrides.spawn ?? spawn } as SessionStarter & {
    spawn: ReturnType<typeof vi.fn>
  }
}

describe('a request that names no folder', () => {
  it('lands in the first folder this device may use', async () => {
    const deps = starter()
    const create = remoteSessionCreator(deps)

    const outcome = await create({ deviceId: PHONE, cols: 100, rows: 30 })
    expect(outcome.ok).toBe(true)
    expect(deps.spawn).toHaveBeenCalledWith({
      cwd: '/Users/apple/Projects/terminaldeck',
      cols: 100,
      rows: 30,
      // Carried all the way down rather than stopping at the folder rule. What
      // reads it is the git isolation: which device this session belongs to
      // decides whose configuration it runs with and whose phone answers when
      // git asks for a password. A spawn that did not know could only give every
      // remote session the same answer, or none.
      deviceId: PHONE,
    })
  })

  it('uses a plain 80x24 when the phone has not measured its terminal', async () => {
    const deps = starter()
    await remoteSessionCreator(deps)({ deviceId: PHONE })
    expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ cols: 80, rows: 24 }))
  })

  it('refuses rather than inventing one when the device may use none', async () => {
    // The hole this closes: there used to be a `home()` fallback for an empty
    // list, which was right when the list was the desktop's own projects — an
    // empty one meant a first launch — and became wrong the moment a person
    // could empty it themselves. Falling back would turn "this device may use
    // no folders" into "this device may start a shell in my home directory".
    const deps = starter({ folders: () => [] })
    const outcome = await remoteSessionCreator(deps, 'darwin')({ deviceId: PHONE })

    expect(outcome).toMatchObject({ ok: false, code: 'unauthorized' })
    expect(deps.spawn).not.toHaveBeenCalled()
    // Actionable, and about the machine the folders live on rather than about
    // the phone reading it.
    if (!outcome.ok) expect(outcome.message).toContain('Choose one in its remote access settings')
  })
})

describe('a request that names one', () => {
  it('accepts a folder the desktop is already offering', async () => {
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, cwd: '/Users/apple/Projects/imza' })

    expect(outcome).toMatchObject({ ok: true })
    expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ cwd: '/Users/apple/Projects/imza' }))
  })

  it('accepts the same folder written a different way', async () => {
    // The phone echoes back what it was sent, but a project stored with a
    // trailing slash and a session's cwd without one are the same directory,
    // and refusing over that would be a refusal nobody could act on.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, cwd: '/Users/apple/Projects/imza/' })
    expect(outcome).toMatchObject({ ok: true })
  })

  it('refuses one it is not offering, and starts nothing', async () => {
    const deps = starter()
    // The platform is pinned because the message names the machine, and this
    // suite runs on the Windows runner too — where the unpinned answer is
    // "This PC" and the sentence would be asserted against the runner rather
    // than against the code.
    const outcome = await remoteSessionCreator(deps, 'darwin')({ deviceId: PHONE, cwd: '/etc' })

    expect(outcome).toEqual({
      ok: false,
      code: 'unauthorized',
      message: 'This Mac is not offering that folder to this device. Pick one from the list it sent.',
    })
    // The assertion that matters. A refusal that had already spawned a shell
    // would be the worst kind of pass.
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('never quietly substitutes the default for a folder it refuses', async () => {
    // The failure this rule exists to prevent: the user taps New Session on a
    // project, gets a shell somewhere else, and types into it.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, cwd: '/Users/apple/Projects/gone' })
    expect(outcome.ok).toBe(false)
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('does not let a traversal walk out of an offered folder', async () => {
    const deps = starter()
    for (const cwd of [
      '/Users/apple/Projects/terminaldeck/../../.ssh',
      '/Users/apple/Projects/imza/..',
      '/Users/apple/Projects/terminaldeck/node_modules',
    ]) {
      expect((await remoteSessionCreator(deps)({ deviceId: PHONE, cwd })).ok, cwd).toBe(false)
    }
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('refuses a relative path rather than resolving it against this process', async () => {
    // `normalize('projects/..')` is `'.'`, which would then lose a comparison
    // against absolute paths for the wrong reason. Refused for the true one.
    const deps = starter()
    for (const cwd of ['Projects/imza', '.', '..', '~/Projects/imza']) {
      expect((await remoteSessionCreator(deps)({ deviceId: PHONE, cwd })).ok, cwd).toBe(false)
    }
  })

  it('reads the folder list per request, so a project opened since is offered', async () => {
    let folders = ['/Users/apple/Projects/terminaldeck']
    const deps = starter({ folders: () => folders })
    const create = remoteSessionCreator(deps)

    expect((await create({ deviceId: PHONE, cwd: '/Users/apple/Projects/new-one' })).ok).toBe(false)
    folders = [...folders, '/Users/apple/Projects/new-one']
    expect((await create({ deviceId: PHONE, cwd: '/Users/apple/Projects/new-one' })).ok).toBe(true)
  })
})

/**
 * The device the request came from reaches the rule.
 *
 * This is the bug the whole feature turns on: the connection has always known
 * which phone was speaking and the request went down to this file without it,
 * so the only answer available was one every device shared. Two phones with two
 * lists is not a thing that can be tested at all until the id arrives here.
 */
describe('who is asking', () => {
  /** Two devices, two lists, one desktop — the arrangement the panel produces. */
  function twoPhones(): SessionStarter & { spawn: ReturnType<typeof vi.fn> } {
    return starter({
      folders: (deviceId) =>
        deviceId === 'device-a' ? ['/Users/apple/Projects/alpha'] : ['/Users/apple/Projects/beta'],
    })
  }

  it('passes it to the folder lookup on every request', async () => {
    const folders = vi.fn(() => ['/Users/apple/Projects/alpha'])
    const deps = starter({ folders })
    const create = remoteSessionCreator(deps)

    await create({ deviceId: 'device-a', cwd: '/Users/apple/Projects/alpha' })
    await create({ deviceId: 'device-b' })

    expect(folders.mock.calls).toEqual([['device-a'], ['device-b']])
  })

  it('starts a session in a folder granted to that device', async () => {
    const deps = twoPhones()
    const outcome = await remoteSessionCreator(deps)({
      deviceId: 'device-a',
      cwd: '/Users/apple/Projects/alpha',
    })
    expect(outcome).toMatchObject({ ok: true })
    expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ cwd: '/Users/apple/Projects/alpha' }))
  })

  it('refuses a folder granted to a different device', async () => {
    // The one that would look like it works: `/Users/apple/Projects/beta` is a
    // real folder, on this desktop, granted to a phone that is paired and
    // approved — just not to the one asking.
    const deps = twoPhones()
    const outcome = await remoteSessionCreator(deps)({
      deviceId: 'device-a',
      cwd: '/Users/apple/Projects/beta',
    })
    expect(outcome).toMatchObject({ ok: false, code: 'unauthorized' })
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('sends each device to its own default when neither names a folder', async () => {
    const deps = twoPhones()
    const create = remoteSessionCreator(deps)
    await create({ deviceId: 'device-a' })
    await create({ deviceId: 'device-b' })

    expect(deps.spawn.mock.calls.map(([input]) => input.cwd)).toEqual([
      '/Users/apple/Projects/alpha',
      '/Users/apple/Projects/beta',
    ])
  })

  it('takes a folder away between two requests, with no reconnect in between', async () => {
    // What the settings panel does: the same connection, the same creator, and
    // a list that changed underneath it. Nothing here re-reads a snapshot,
    // because there is no snapshot to re-read.
    const granted = new Map([['device-a', ['/Users/apple/Projects/alpha']]])
    const deps = starter({ folders: (deviceId) => granted.get(deviceId) ?? [] })
    const create = remoteSessionCreator(deps)

    expect((await create({ deviceId: 'device-a', cwd: '/Users/apple/Projects/alpha' })).ok).toBe(true)
    granted.set('device-a', [])
    expect((await create({ deviceId: 'device-a', cwd: '/Users/apple/Projects/alpha' })).ok).toBe(false)
    expect(deps.spawn).toHaveBeenCalledTimes(1)
  })
})

/**
 * The list the phone is shown and the list it is held to are one list.
 *
 * A picker built from anywhere else eventually offers a folder that is refused
 * on tap, and from the phone there is nothing to read that explains it.
 */
describe('the two halves handed out together', () => {
  it('answers the picker with exactly what create will accept', async () => {
    const deps = twoLists()
    const start = remoteSessionStart(deps)

    expect(start.folders('device-a')).toEqual(['/Users/apple/Projects/alpha'])
    expect((await start.create({ deviceId: 'device-a', cwd: '/Users/apple/Projects/alpha' })).ok).toBe(true)
    expect((await start.create({ deviceId: 'device-a', cwd: '/Users/apple/Projects/beta' })).ok).toBe(false)
  })

  it('asks the starter again each time, rather than caching a list', () => {
    const folders = vi.fn(() => ['/Users/apple/Projects/alpha'])
    const start = remoteSessionStart(starter({ folders }))
    start.folders('device-a')
    start.folders('device-a')
    expect(folders).toHaveBeenCalledTimes(2)
  })

  function twoLists(): SessionStarter & { spawn: ReturnType<typeof vi.fn> } {
    return starter({
      folders: (deviceId) =>
        deviceId === 'device-a' ? ['/Users/apple/Projects/alpha'] : ['/Users/apple/Projects/beta'],
    })
  }
})

describe('when it cannot start one', () => {
  it('reports it as something to try again, not as a permission problem', async () => {
    // A folder listed a minute ago and deleted since is somebody else's action.
    // Calling that `unauthorized` sends the user to the pairing screen.
    const failing = starter({
      spawn: async () => {
        throw new Error('chdir failed: ENOENT')
      },
    })
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => {})
    const outcome = await remoteSessionCreator(failing)({ deviceId: PHONE })
    quiet.mockRestore()

    expect(outcome).toMatchObject({ ok: false, code: 'unavailable' })
  })

  it('never echoes the folder back in the sentence it sends', async () => {
    // The value came off the network and the sentence goes back over it and
    // onto a screen. Quoting it buys nothing and costs an output channel.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({
      deviceId: PHONE,
      cwd: '/etc/<script>alert(1)</script>',
    })
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.message).not.toContain('script')
  })
})

describe('the session it reports back', () => {
  it('is the real one, with the id the desktop gave it', async () => {
    const outcome = await remoteSessionCreator(starter())({
      deviceId: PHONE,
      cwd: '/Users/apple/Projects/imza',
    })
    expect(outcome).toEqual({
      ok: true,
      session: {
        id: 'sess-new',
        title: 'terminaldeck',
        cwd: '/Users/apple/Projects/imza',
        provider: 'claude',
        // Nothing has printed yet, so there is nothing to read a status off.
        status: 'idle',
        exitCode: null,
      },
    })
  })
})

/**
 * The allowlist on the platform where two spellings are one directory.
 *
 * Pinned rather than run: every case below is the Windows answer, produced on a
 * Mac by passing the platform in, which is the whole reason `remoteSessionCreator`
 * takes one. The bug this guards is not theoretical — the drive letter alone
 * arrives capitalised from some APIs and lower-cased from others, so a phone
 * naming a folder that is visibly on its own list was told to go and open it
 * first.
 */
describe('a Windows desktop, where case is not a difference', () => {
  function windowsStarter(): SessionStarter & { spawn: ReturnType<typeof vi.fn> } {
    return starter({ folders: () => ['C:\\Users\\Asad\\Projects\\deck'] })
  }

  it.each([
    ['the same spelling', 'C:\\Users\\Asad\\Projects\\deck'],
    ['a lower-cased drive letter', 'c:\\Users\\Asad\\Projects\\deck'],
    ['a differently cased path', 'C:\\users\\asad\\projects\\Deck'],
    ['a trailing separator as well', 'c:\\users\\asad\\projects\\deck\\'],
    ['forward slashes, which Windows accepts', 'C:/Users/Asad/Projects/deck'],
  ])('accepts %s', async (_label, cwd) => {
    const deps = windowsStarter()
    const outcome = await remoteSessionCreator(deps, 'win32')({ deviceId: PHONE, cwd, cols: 100, rows: 30 })
    expect(outcome.ok, `${cwd} was refused`).toBe(true)
    expect(deps.spawn).toHaveBeenCalledWith({ cwd, cols: 100, rows: 30, deviceId: PHONE })
  })

  it('still refuses a folder nobody offered', async () => {
    const deps = windowsStarter()
    const outcome = await remoteSessionCreator(deps, 'win32')({ deviceId: PHONE, cwd: 'C:\\Windows\\System32' })
    expect(outcome.ok).toBe(false)
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('tells the reader about the machine they are actually using', async () => {
    const outcome = await remoteSessionCreator(windowsStarter(), 'win32')({ deviceId: PHONE, cwd: 'C:\\Windows' })
    expect(outcome.ok).toBe(false)
    // Sealed up and shown on a phone. "This Mac will not start a session" is a
    // sentence about a computer the reader does not own.
    if (!outcome.ok) {
      expect(outcome.message).toContain('This PC')
      expect(outcome.message).not.toMatch(/\bMac\b/)
    }
  })

  it('does not fold case on POSIX, where two spellings are two directories', async () => {
    // The mirror of the case above, and the reason the fold is not unconditional:
    // folding here would let a phone name a *different* directory than the one
    // the desktop offered, which is the hole the allowlist exists to close.
    const deps = starter({ folders: () => ['/Users/apple/Projects/Deck'] })
    const outcome = await remoteSessionCreator(deps, 'darwin')({
      deviceId: PHONE,
      cwd: '/users/apple/projects/deck',
    })
    expect(outcome.ok).toBe(false)
    expect(deps.spawn).not.toHaveBeenCalled()
  })
})
