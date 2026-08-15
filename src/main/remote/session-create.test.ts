import { describe, expect, it, vi, type Mock } from 'vitest'
import { ConfinementUnavailableError } from '../confine'
import {
  knownProvider,
  providerNames,
  remoteSessionCreator,
  remoteSessionStart,
  type SessionStarter,
} from './session-create'
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

/**
 * The helper's `spawn`, typed from the interface rather than described again.
 *
 * `ReturnType<typeof vi.fn>` used to stand here, which is `Mock<Procedure>` —
 * a spy that accepts anything and returns anything. That is what forced the
 * `as SessionStarter & { … }` on the return: the object being built genuinely
 * did not have the type it claimed, because its `spawn` took three fields and
 * the interface's takes four. The cast hid a real drift. `deviceId` had already
 * been added to `SessionStarter['spawn']` for git isolation and the fake in
 * this file never grew it, so every `toHaveBeenCalledWith` below was checked
 * against a signature the product had left behind.
 */
type SpawnSpy = Mock<SessionStarter['spawn']>

/** What the default `spawn` answers: the fixture, relocated to the folder asked for. */
const defaultSpawn: SessionStarter['spawn'] = async (input) => ({ ...META, cwd: input.cwd })

/**
 * A `SessionStarter` whose `spawn` is always a spy, whatever the test supplied.
 *
 * Wrapping an override in `vi.fn` rather than passing it through is what lets
 * the return type promise a spy without asserting one: a test that hands in a
 * plain throwing function still gets back an object whose `spawn` can be
 * asserted against, and the promise is kept by construction instead of by a
 * cast.
 */
function starter(overrides: Partial<SessionStarter> = {}): SessionStarter & { spawn: SpawnSpy } {
  return {
    folders:
      overrides.folders ?? (() => ['/Users/apple/Projects/terminaldeck', '/Users/apple/Projects/imza']),
    spawn: vi.fn(overrides.spawn ?? defaultSpawn),
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
  function twoPhones(): SessionStarter & { spawn: SpawnSpy } {
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

  function twoLists(): SessionStarter & { spawn: SpawnSpy } {
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

  it('says something different when the folder could not be made a boundary', async () => {
    /*
     * Two failures, two remedies, and sharing a sentence would send a person to
     * the wrong one. "The folder may have moved" invites a retry and a look at
     * the folder; a session refused because it could not be confined will be
     * refused again for as long as the machine is in that state, and the thing
     * to look at is the machine.
     *
     * This is also the test for the rule that keeps the grant screen honest:
     * the spawn path throws rather than starting an unconfined session, so
     * something here has to turn that throw into a refusal instead of losing it.
     */
    const failing = starter({
      spawn: async () => {
        throw new ConfinementUnavailableError('sandbox-exec would not run a command with this profile')
      },
    })
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => {})
    const outcome = await remoteSessionCreator(failing)({ deviceId: PHONE })
    quiet.mockRestore()

    expect(outcome).toMatchObject({ ok: false, code: 'unavailable' })
    if (!outcome.ok) {
      expect(outcome.message).toContain('could not keep a session inside that folder')
      expect(outcome.message).not.toContain('may have moved')
      // The detail is for the log on the machine, not for a phone in another
      // room: it names a program and a profile and nobody holding a phone can
      // act on either.
      expect(outcome.message).not.toContain('sandbox-exec')
    }
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

/**
 * Which agent, and the substitution that must never happen again.
 *
 * The bug, measured on a real Windows PC: a request for `shell` produced a
 * `claude` session. Four layers were involved and none of them was wrong on its
 * own — the client sent `provider`, `parseClientMessage` did not list the field
 * and dropped it, the request arrived naming no agent, and the spawn filled the
 * hole with the desktop's default. The lesson is the one this file already
 * enforces about folders: a value this desktop cannot honour is refused with a
 * sentence, never replaced with a different one.
 */
describe('which agent it starts', () => {
  it('forwards the agent the client asked for', async () => {
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, provider: 'shell' })
    expect(outcome.ok).toBe(true)
    expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ provider: 'shell' }))
  })

  it('says nothing about an agent when the client named none', async () => {
    /*
     * Absent has to stay absent rather than becoming a value here. The spawn
     * reads `input.provider ?? <this desktop's default>`, so a `provider:
     * undefined` this file invented would be harmless and a `provider: 'claude'`
     * it invented would take the desktop's own preference away from it — a
     * person whose default is a plain shell would get an agent because a phone
     * said nothing at all.
     */
    const deps = starter()
    await remoteSessionCreator(deps)({ deviceId: PHONE })
    const [input] = deps.spawn.mock.calls[0]
    expect('provider' in input).toBe(false)
  })

  it('refuses a name it does not have, and starts nothing', async () => {
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, provider: 'copilot' })
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) {
      expect(outcome.code).toBe('unauthorized')
      // The sentence has to be actionable, which means naming what it *can*
      // start. "Could not start a session" would send someone to retry a request
      // that will never work.
      expect(outcome.message).toContain('shell')
      expect(outcome.message).toContain('claude')
    }
    // The whole point: refused means nothing started, rather than something else
    // starting.
    expect(deps.spawn).not.toHaveBeenCalled()
  })

  it('never echoes the requested name back in the sentence it sends', async () => {
    // Same rule the folder refusal follows: this text goes over the wire and
    // onto a phone, and quoting attacker-chosen input into it buys nothing and
    // costs an output channel.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, provider: 'evilagent' })
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.message).not.toContain('evilagent')
  })

  it('accepts every agent this build has, so the list and the rule cannot disagree', async () => {
    // `providerNames` is what the refusal above prints. If it ever listed
    // something `knownProvider` refuses, the sentence would be telling people to
    // ask for a thing that is then refused — which is the folder-picker failure
    // this file exists to prevent, wearing a different hat.
    for (const name of providerNames()) {
      const deps = starter()
      const outcome = await remoteSessionCreator(deps)({ deviceId: PHONE, provider: name })
      expect(outcome.ok).toBe(true)
      expect(deps.spawn).toHaveBeenCalledWith(expect.objectContaining({ provider: name }))
    }
  })

  it('narrows a name rather than trusting one', () => {
    // The function the refusal hangs off, checked directly. It is the only place
    // a `string` off the wire becomes a `ProviderId`, so it is the only place a
    // name that is not one could get through.
    expect(knownProvider('shell')).toBe('shell')
    for (const name of ['', 'Claude', 'claude ', 'copilot', 'toString', '__proto__', 'constructor']) {
      expect(knownProvider(name)).toBeNull()
    }
  })

  it('checks the folder before the agent, so the worse refusal wins', async () => {
    // Both wrong at once. The folder is the one that matters — it is about
    // access rather than about a typo — and reporting the agent instead would
    // send someone to fix a name while the real answer is that this device may
    // not use that folder at all.
    const deps = starter()
    const outcome = await remoteSessionCreator(deps)({
      deviceId: PHONE,
      cwd: '/etc',
      provider: 'copilot',
    })
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.message).toContain('folder')
    expect(deps.spawn).not.toHaveBeenCalled()
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
  function windowsStarter(): SessionStarter & { spawn: SpawnSpy } {
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
