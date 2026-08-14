import { describe, expect, it, vi } from 'vitest'
import { remoteSessionCreator, type SessionStarter } from './session-create'
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
 */

const META: SessionMeta = {
  id: 'sess-new',
  cwd: '/Users/apple/Projects/terminaldeck',
  title: 'terminaldeck',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_760_000_000_000,
}

function starter(overrides: Partial<SessionStarter> = {}): SessionStarter & { spawn: ReturnType<typeof vi.fn> } {
  const spawn = vi.fn(async (input: { cwd: string; cols: number; rows: number }) => ({ ...META, cwd: input.cwd }))
  return {
    folders: () => ['/Users/apple/Projects/terminaldeck', '/Users/apple/Projects/imza'],
    home: () => '/Users/apple',
    spawn,
    ...overrides,
    // Kept after the spread so a test overriding `folders` still gets the spy.
    ...(overrides.spawn ? {} : { spawn }),
  } as SessionStarter & { spawn: ReturnType<typeof vi.fn> }
}

describe('a request that names no folder', () => {
  it('lands in the desktop’s most recent project', async () => {
    const deps = starter()
    const create = remoteSessionCreator(deps)

    const outcome = await create({ cols: 100, rows: 30 })
    expect(outcome.ok).toBe(true)
    expect(deps.spawn).toHaveBeenCalledWith({
      cwd: '/Users/apple/Projects/terminaldeck',
      cols: 100,
      rows: 30,
    })
  })

  it('falls back to home when this Mac has no projects at all', async () => {
    // A first launch, which is exactly when a phone starting a session is most
    // useful and least able to name a folder.
    const deps = starter({ folders: () => [] })
    await remoteSessionCreator(deps)({})
    expect(deps.spawn).toHaveBeenCalledWith({ cwd: '/Users/apple', cols: 80, rows: 24 })
  })

  it('uses a plain 80x24 when the phone has not measured its terminal', async () => {
    const deps = starter()
    await remoteSessionCreator(deps)({})
    expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ cols: 80, rows: 24 }))
  })
})

describe('a request that names one', () => {
  it('accepts a folder the desktop is already offering', async () => {
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ cwd: '/Users/apple/Projects/imza' })

    expect(outcome).toMatchObject({ ok: true })
    expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ cwd: '/Users/apple/Projects/imza' }))
  })

  it('accepts the same folder written a different way', async () => {
    // The phone echoes back what it was sent, but a project stored with a
    // trailing slash and a session's cwd without one are the same directory,
    // and refusing over that would be a refusal nobody could act on.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ cwd: '/Users/apple/Projects/imza/' })
    expect(outcome).toMatchObject({ ok: true })
  })

  it('refuses one it is not offering, and starts nothing', async () => {
    const deps = starter()
    // The platform is pinned because the message names the machine, and this
    // suite runs on the Windows runner too — where the unpinned answer is
    // "This PC" and the sentence would be asserted against the runner rather
    // than against the code.
    const outcome = await remoteSessionCreator(deps, 'darwin')({ cwd: '/etc' })

    expect(outcome).toEqual({
      ok: false,
      code: 'unauthorized',
      message: 'This Mac will not start a session in that folder. Open it there first.',
    })
    // The assertion that matters. A refusal that had already spawned a shell
    // would be the worst kind of pass.
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('never quietly substitutes the default for a folder it refuses', async () => {
    // The failure this rule exists to prevent: the user taps New Session on a
    // project, gets a shell somewhere else, and types into it.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ cwd: '/Users/apple/Projects/gone' })
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
      expect((await remoteSessionCreator(deps)({ cwd })).ok, cwd).toBe(false)
    }
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('refuses a relative path rather than resolving it against this process', async () => {
    // `normalize('projects/..')` is `'.'`, which would then lose a comparison
    // against absolute paths for the wrong reason. Refused for the true one.
    const deps = starter()
    for (const cwd of ['Projects/imza', '.', '..', '~/Projects/imza']) {
      expect((await remoteSessionCreator(deps)({ cwd })).ok, cwd).toBe(false)
    }
  })

  it('reads the folder list per request, so a project opened since is offered', async () => {
    let folders = ['/Users/apple/Projects/terminaldeck']
    const deps = starter({ folders: () => folders })
    const create = remoteSessionCreator(deps)

    expect((await create({ cwd: '/Users/apple/Projects/new-one' })).ok).toBe(false)
    folders = [...folders, '/Users/apple/Projects/new-one']
    expect((await create({ cwd: '/Users/apple/Projects/new-one' })).ok).toBe(true)
  })
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
    const outcome = await remoteSessionCreator(failing)({})
    quiet.mockRestore()

    expect(outcome).toMatchObject({ ok: false, code: 'unavailable' })
  })

  it('never echoes the folder back in the sentence it sends', async () => {
    // The value came off the network and the sentence goes back over it and
    // onto a screen. Quoting it buys nothing and costs an output channel.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ cwd: '/etc/<script>alert(1)</script>' })
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.message).not.toContain('script')
  })
})

describe('the session it reports back', () => {
  it('is the real one, with the id the desktop gave it', async () => {
    const outcome = await remoteSessionCreator(starter())({ cwd: '/Users/apple/Projects/imza' })
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
    return starter({ folders: () => ['C:\\Users\\Asad\\Projects\\deck'], home: () => 'C:\\Users\\Asad' })
  }

  it.each([
    ['the same spelling', 'C:\\Users\\Asad\\Projects\\deck'],
    ['a lower-cased drive letter', 'c:\\Users\\Asad\\Projects\\deck'],
    ['a differently cased path', 'C:\\users\\asad\\projects\\Deck'],
    ['a trailing separator as well', 'c:\\users\\asad\\projects\\deck\\'],
    ['forward slashes, which Windows accepts', 'C:/Users/Asad/Projects/deck'],
  ])('accepts %s', async (_label, cwd) => {
    const deps = windowsStarter()
    const outcome = await remoteSessionCreator(deps, 'win32')({ cwd, cols: 100, rows: 30 })
    expect(outcome.ok, `${cwd} was refused`).toBe(true)
    expect(deps.spawn).toHaveBeenCalledWith({ cwd, cols: 100, rows: 30 })
  })

  it('still refuses a folder nobody offered', async () => {
    const deps = windowsStarter()
    const outcome = await remoteSessionCreator(deps, 'win32')({ cwd: 'C:\\Windows\\System32' })
    expect(outcome.ok).toBe(false)
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('tells the reader about the machine they are actually using', async () => {
    const outcome = await remoteSessionCreator(windowsStarter(), 'win32')({ cwd: 'C:\\Windows' })
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
    const deps = starter({ folders: () => ['/Users/apple/Projects/Deck'], home: () => '/Users/apple' })
    const outcome = await remoteSessionCreator(deps, 'darwin')({ cwd: '/users/apple/projects/deck' })
    expect(outcome.ok).toBe(false)
    expect(deps.spawn).not.toHaveBeenCalled()
  })
})
